import AppKit
import CefKit

/// Carries a value out of `MainActor.assumeIsolated`, which only returns
/// Sendable types. Everything in this app runs on the main thread.
struct MainBox<T>: @unchecked Sendable { let value: T }

func onMain<T>(_ body: @MainActor () -> T) -> T {
  MainActor.assumeIsolated { MainBox(value: body()) }.value
}

func foundation(_ json: CefJSON) -> Any? {
  if json.isNull { return nil }
  return try? JSONSerialization.jsonObject(with: json.data, options: [.fragmentsAllowed])
}

@MainActor
final class ChromiumEngine: @preconcurrency PageEngine, CefPageDelegate {
  static let networkLimit = 1000

  weak var panel: Panel?
  let page: CefPage
  let host: CefWindowedPageView
  var timer: Timer?
  var tasks: [Task<Void, Never>] = []

  var wasLoading = false
  /// A load was asked for or seen, and its end hasn't been reported yet.
  var awaiting = false
  var pendingLoadUntil = Date.distantPast
  /// The browser exists and the protocol domains are on. A load asked for
  /// before then waits in `queued`, so its requests and console are captured.
  var ready = false
  var queued: URL?
  var loadFailed = false
  var seen = ""

  var network: [[String: Any]] = []
  var networkSeq = 0
  var networkDropped = 0
  var requestSeq: [String: Int] = [:]
  /// Changes that arrived before their request did, as a blocked request's failure can.
  var early: [String: [(inout [String: Any]) -> Void]] = [:]

  var view: NSView { host }
  var url: URL? { page.url }
  var title: String { page.title }
  var isLoading: Bool { page.isLoading || awaiting }
  var canGoBack: Bool { page.canGoBack }
  var canGoForward: Bool { page.canGoForward }
  var zoom: Double {
    get { pow(1.2, page.zoomLevel) }
    set { page.zoomLevel = log(max(0.1, newValue)) / log(1.2) }
  }

  init(panel: Panel) {
    self.panel = panel
    page = CefPage(url: URL(string: "about:blank")!)
    host = CefWindowedPageView(page: page)
    page.delegate = self
    timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.poll() }
    }
    listen()
  }

  // MARK: Load state

  func poll() {
    let loading = page.isLoading
    if loading && !wasLoading { loadFailed = false; awaiting = true; panel?.engineStarted() }
    // A load can start and end between two polls, so a requested load that
    // never shows as loading still ends once its grace period is over.
    if !loading && awaiting && queued == nil && (wasLoading || Date() > pendingLoadUntil) { finish() }
    // A load the page started itself can begin and end between two polls,
    // after a caller saw it loading and began to wait. Don't leave it waiting.
    if !loading && !awaiting, let p = panel, !p.loadWaiters.isEmpty {
      if loadFailed { p.finishWaiters(p.lastError) } else { p.engineFinished() }
    }
    wasLoading = loading
    let now = "\(page.url?.absoluteString ?? "") \(page.title) \(page.canGoBack) \(page.canGoForward)"
    if now != seen { seen = now; panel?.engineChanged() }
  }

  func finish() {
    awaiting = false
    pendingLoadUntil = .distantPast
    if !loadFailed { panel?.engineFinished() }
  }

  func page(_ page: CefPage, didFinishLoadWithStatus httpStatus: Int) {
    emulateFocus()
    if awaiting && !page.isLoading { finish() }
  }

  func page(_ page: CefPage, didFailLoad error: CefLoadError) {
    if error.code == -3 { return }  // ERR_ABORTED: another navigation replaced this one
    loadFailed = true
    awaiting = false
    pendingLoadUntil = .distantPast
    panel?.engineFailed(error.message.isEmpty ? "error \(error.code)" : error.message, url: error.url?.absoluteString ?? "")
  }

  /// Marks a load as under way before Chromium reports it, so a caller that
  /// waits right after asking for one doesn't see the page as already idle.
  func expectLoad() {
    awaiting = true
    loadFailed = false
    pendingLoadUntil = Date().addingTimeInterval(1.5)
  }

  /// Cmd-click opens a pane beside this one, a sized popup (such as a
  /// sign-in window) opens natively so it keeps its opener, and any other
  /// new-window request loads in this pane, as WebKit panes do.
  func page(_ page: CefPage, decideWindowOpenFor request: CefWindowOpenRequest) -> CefWindowOpenDecision {
    switch request.disposition {
    case .newBackgroundTab:
      guard let url = request.targetURL else { return .deny }
      panel?.openBeside(url.absoluteString)
      return .handled
    case .newPopup:
      return request.hasUserGesture ? .allowNativePopup : .default(for: request)
    case .newForegroundTab, .newWindow:
      return request.hasUserGesture && request.targetURL != nil ? .openInCurrentPage : .default(for: request)
    default:
      return .default(for: request)
    }
  }

  func load(_ url: URL) {
    expectLoad()
    if ready { _ = page.load(url) } else { queued = url }
  }
  func goBack() { if page.canGoBack { expectLoad() }; page.goBack() }
  func goForward() { if page.canGoForward { expectLoad() }; page.goForward() }
  func reload(fromOrigin: Bool) { expectLoad(); page.reload(ignoringCache: fromOrigin) }

  // MARK: DevTools Protocol

  func send(_ method: String, _ params: CefJSON = [:], _ done: ((CefJSON?, String?) -> Void)? = nil) {
    Task { @MainActor in
      do { done?(try await page.devTools.send(method, params), nil) } catch { done?(nil, "\(error)") }
    }
  }

  func on(_ event: String, _ handler: @escaping @MainActor (CefJSON) -> Void) {
    let stream = page.devTools.events(event)
    tasks.append(Task { @MainActor in for await e in stream { handler(e) } })
  }

  func listen() {
    on("Runtime.consoleAPICalled") { [weak self] e in self?.consoleCall(e) }
    on("Runtime.exceptionThrown") { [weak self] e in self?.exception(e["exceptionDetails"]) }
    on("Log.entryAdded") { [weak self] e in self?.logEntry(e["entry"]) }
    on("Page.frameNavigated") { [weak self] e in
      if e["frame"]["parentId"].stringValue == nil { self?.panel?.engineCommitted(e["frame"]["url"].stringValue) }
    }
    on("Network.requestWillBeSent") { [weak self] e in self?.requestStarted(e) }
    on("Network.responseReceived") { [weak self] e in self?.responseReceived(e) }
    on("Network.loadingFinished") { [weak self] e in
      self?.update(e["requestId"].stringValue) { $0["done"] = true; $0["bytes"] = e["encodedDataLength"].intValue ?? 0 }
    }
    on("Network.loadingFailed") { [weak self] e in
      self?.update(e["requestId"].stringValue) {
        $0["done"] = true
        var why: [String] = []
        if let t = e["errorText"].stringValue, !t.isEmpty { why.append(t) }
        if let b = e["blockedReason"].stringValue { why.append("blocked: \(b)") }
        if let c = e["corsErrorStatus"]["corsError"].stringValue { why.append("CORS: \(c)") }
        $0["error"] = why.isEmpty ? "failed" : why.joined(separator: ", ")
        if e["canceled"].boolValue == true { $0["canceled"] = true }
      }
    }
    tasks.append(Task { @MainActor [weak self] in
      guard let self else { return }
      do { try await self.page.ready() } catch { log("page not ready: \(error)") }
      for domain in ["Runtime", "Log", "Page", "Network"] {
        do { _ = try await self.page.devTools.send("\(domain).enable") }
        catch { log("\(domain).enable failed: \(error)") }
      }
      self.emulateFocus()
      self.ready = true
      if let url = self.queued {
        self.queued = nil
        self.expectLoad()
        _ = self.page.load(url)
      }
    })
  }

  static func text(of arg: CefJSON) -> String {
    if let s = arg["value"].stringValue, arg["type"].stringValue == "string" { return s }
    if !arg["value"].isNull { return arg["value"].text }
    if let p = arg["preview"].objectValue, let props = p["properties"]?.arrayValue, arg["subtype"].stringValue != "error" {
      let body = props.map { "\($0["name"].stringValue ?? ""): \($0["value"].stringValue ?? "")" }.joined(separator: ", ")
      let open = arg["subtype"].stringValue == "array" ? "[" : "{", shut = arg["subtype"].stringValue == "array" ? "]" : "}"
      return open + body + (p["overflow"]?.boolValue == true ? ", …" : "") + shut
    }
    return arg["description"].stringValue ?? arg["type"].stringValue ?? ""
  }

  static func place(_ url: String?, _ line: Int?, _ column: Int?) -> String? {
    guard let url, !url.isEmpty else { return nil }
    return "\(url):\((line ?? 0) + 1):\((column ?? 0) + 1)"
  }

  func consoleCall(_ e: CefJSON) {
    let kind = e["type"].stringValue ?? "log"
    let level = ["warning": "warn", "error": "error", "assert": "error", "info": "info", "debug": "debug"][kind] ?? "log"
    let text = (e["args"].arrayValue ?? []).map(ChromiumEngine.text).joined(separator: " ")
    let top = e["stackTrace"]["callFrames"].arrayValue?.first
    panel?.record(level: level, text: text, url: page.url?.absoluteString ?? "",
                  source: ChromiumEngine.place(top?["url"].stringValue, top?["lineNumber"].intValue, top?["columnNumber"].intValue))
  }

  func exception(_ d: CefJSON) {
    let text = d["exception"]["description"].stringValue ?? d["text"].stringValue ?? "Uncaught error"
    let top = d["stackTrace"]["callFrames"].arrayValue?.first
    let where_ = ChromiumEngine.place(d["url"].stringValue ?? top?["url"].stringValue, d["lineNumber"].intValue, d["columnNumber"].intValue)
    panel?.record(level: "error", text: text.hasPrefix("Uncaught") ? text : "Uncaught \(text)", url: page.url?.absoluteString ?? "", source: where_)
  }

  func logEntry(_ entry: CefJSON) {
    let level = ["warning": "warn", "error": "error", "info": "info", "verbose": "debug"][entry["level"].stringValue ?? ""] ?? "log"
    let from = entry["source"].stringValue ?? "browser"
    panel?.record(level: level, text: "[\(from)] \(entry["text"].stringValue ?? "")", url: page.url?.absoluteString ?? "",
                  source: ChromiumEngine.place(entry["url"].stringValue, entry["lineNumber"].intValue.map { $0 - 1 }, nil)
                    ?? entry["url"].stringValue)
  }

  func requestStarted(_ e: CefJSON) {
    guard let id = e["requestId"].stringValue else { return }
    // A redirect reuses the request's id for the next hop; close the hop it replaces.
    let redirect = e["redirectResponse"]
    if !redirect.isNull {
      update(id) { $0["done"] = true; $0["status"] = redirect["status"].intValue ?? 0 }
    }
    networkSeq += 1
    requestSeq[id] = networkSeq
    network.append([
      "seq": networkSeq, "time": Date().timeIntervalSince1970, "method": e["request"]["method"].stringValue ?? "GET",
      "url": String((e["request"]["url"].stringValue ?? "").prefix(2000)), "type": (e["type"].stringValue ?? "other").lowercased(),
      "done": false,
    ])
    if let changes = early.removeValue(forKey: id) { for c in changes { c(&network[network.count - 1]) } }
    if network.count > ChromiumEngine.networkLimit {
      let extra = network.count - ChromiumEngine.networkLimit
      networkDropped += extra
      network.removeFirst(extra)
      if requestSeq.count > ChromiumEngine.networkLimit * 2 {
        let oldest = network.first?["seq"] as? Int ?? 0
        requestSeq = requestSeq.filter { $0.value >= oldest }
      }
    }
  }

  func update(_ id: String?, _ change: @escaping (inout [String: Any]) -> Void) {
    guard let id else { return }
    guard let seq = requestSeq[id] else {
      if early.count > 200 { early.removeAll() }
      early[id, default: []].append(change)
      return
    }
    guard let first = network.first?["seq"] as? Int, seq >= first, seq - first < network.count else { return }
    change(&network[seq - first])
  }

  func responseReceived(_ e: CefJSON) {
    update(e["requestId"].stringValue) {
      $0["status"] = e["response"]["status"].intValue ?? 0
      $0["mime"] = e["response"]["mimeType"].stringValue ?? ""
      if e["response"]["fromDiskCache"].boolValue == true { $0["cached"] = true }
    }
  }

  // MARK: Scripting and input

  func call(_ body: String, _ args: [String: Any], _ done: @escaping (Any?, String?) -> Void) {
    let json = (try? JSONSerialization.data(withJSONObject: args)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    let expression = "(async (args) => {\n\(body)\n})(\(json))"
    send("Runtime.evaluate", ["expression": .string(expression), "returnByValue": true, "awaitPromise": true]) { reply, err in
      guard let reply else { return done(nil, err ?? "evaluate failed") }
      let details = reply["exceptionDetails"]
      if !details.isNull {
        let text = details["exception"]["description"].stringValue ?? details["exception"]["value"].stringValue
          ?? details["text"].stringValue ?? "JavaScript error"
        return done(nil, text.split(separator: "\n").first.map(String.init) ?? text)
      }
      done(foundation(reply["result"]["value"]), nil)
    }
  }

  func click(x: Double, y: Double) {
    let z = zoom
    sendInOrder(["mouseMoved", "mousePressed", "mouseReleased"].map { type in
      ("Input.dispatchMouseEvent", ["type": .string(type), "x": .number(x * z), "y": .number(y * z),
                                    "button": type == "mouseMoved" ? "none" : "left", "clickCount": type == "mouseMoved" ? 0 : 1])
    })
  }

  func press(_ name: String) -> Bool {
    let keys: [String: (key: String, code: String, vk: Int, text: String?)] = [
      "enter": ("Enter", "Enter", 13, "\r"), "return": ("Enter", "Enter", 13, "\r"), "tab": ("Tab", "Tab", 9, nil),
      "escape": ("Escape", "Escape", 27, nil), "esc": ("Escape", "Escape", 27, nil),
      "backspace": ("Backspace", "Backspace", 8, nil), "delete": ("Delete", "Delete", 46, nil), "space": (" ", "Space", 32, " "),
      "up": ("ArrowUp", "ArrowUp", 38, nil), "down": ("ArrowDown", "ArrowDown", 40, nil),
      "left": ("ArrowLeft", "ArrowLeft", 37, nil), "right": ("ArrowRight", "ArrowRight", 39, nil),
      "home": ("Home", "Home", 36, nil), "end": ("End", "End", 35, nil),
      "pageup": ("PageUp", "PageUp", 33, nil), "pagedown": ("PageDown", "PageDown", 34, nil),
    ]
    guard let k = keys[name.lowercased()] else { return false }
    var down: [String: CefJSON] = ["type": k.text == nil ? "rawKeyDown" : "keyDown", "key": .string(k.key), "code": .string(k.code),
                                   "windowsVirtualKeyCode": .number(Double(k.vk)), "nativeVirtualKeyCode": .number(Double(k.vk))]
    if let t = k.text { down["text"] = .string(t) }
    sendInOrder([("Input.dispatchKeyEvent", .object(down)),
                 ("Input.dispatchKeyEvent", ["type": "keyUp", "key": .string(k.key), "code": .string(k.code),
                                             "windowsVirtualKeyCode": .number(Double(k.vk)), "nativeVirtualKeyCode": .number(Double(k.vk))])])
    return true
  }

  func insertText(_ text: String) { send("Input.insertText", ["text": .string(text)]) }

  /// Sends input events one after another. Chromium drops a press and its release when they arrive
  /// out of order, which separate `send` tasks do not rule out.
  func sendInOrder(_ steps: [(String, CefJSON)]) {
    Task { @MainActor [weak self] in
      for (method, params) in steps {
        guard let self else { return }
        do { _ = try await self.page.devTools.send(method, params) } catch { log("\(method) failed: \(error)"); return }
      }
    }
  }

  /// Chromium drops scripted clicks and keys while the page is unfocused, and a pane driven from the
  /// CLI rarely has the keyboard. Focus emulation makes the page act focused without taking it.
  func emulateFocus() { send("Emulation.setFocusEmulationEnabled", ["enabled": true]) }

  func screenshot(_ done: @escaping (Data?, String?) -> Void) {
    send("Page.captureScreenshot", ["format": "png"]) { reply, err in
      guard let b64 = reply?["data"].stringValue, let png = Data(base64Encoded: b64) else { return done(nil, err ?? "screenshot failed") }
      done(png, nil)
    }
  }

  func focus() { host.window?.makeFirstResponder(host) }

  func close() {
    timer?.invalidate()
    tasks.forEach { $0.cancel() }
    tasks = []
    page.close(force: true)
  }

  // MARK: Chromium-only routes

  func route(_ route: String, _ input: [String: Any], _ reply: @escaping (Int, Any) -> Void) -> Bool {
    switch route {
    case "/network":
      let since = (input["since"] as? NSNumber)?.intValue ?? 0
      let failedOnly = input["failed"] as? Bool == true
      var rows = network.filter { r in
        guard (r["seq"] as? Int ?? 0) > since else { return false }
        if !failedOnly { return true }
        return r["error"] != nil || (r["status"] as? Int ?? 0) >= 400
      }
      if let limit = (input["limit"] as? NSNumber)?.intValue, limit > 0, rows.count > limit { rows = Array(rows.suffix(limit)) }
      let result: [String: Any] = ["requests": rows, "last": networkSeq, "dropped": networkDropped]
      if input["clear"] as? Bool == true { network = []; requestSeq = [:]; early = [:] }
      reply(200, result)
      return true
    case "/cdp":
      guard let method = input["method"] as? String, !method.isEmpty else { reply(400, ["error": "method required"]); return true }
      send(method, CefJSON(foundationValue: input["params"] ?? [String: Any]())) { result, err in
        if let result { reply(200, ["result": foundation(result) ?? NSNull()]) } else { reply(400, ["error": err ?? "\(method) failed"]) }
      }
      return true
    case "/devtools":
      if input["close"] as? Bool == true { page.closeDevTools() } else { page.showDevTools() }
      reply(200, ["devtools": input["close"] as? Bool == true ? "closed" : "open"])
      return true
    default:
      return false
    }
  }

  static func setCookies(_ cookies: [HTTPCookie], _ done: @escaping () -> Void) {
    Task { @MainActor in
      for c in cookies {
        let cookie = CefProfile.Cookie(name: c.name, value: c.value, domain: c.domain, path: c.path, isSecure: c.isSecure,
                                       isHTTPOnly: c.isHTTPOnly, expirationDate: c.expiresDate)
        do { try await CefProfile.default.setCookie(cookie) } catch { log("cookie \(c.name) for \(c.domain) not set: \(error)") }
      }
      try? await CefProfile.default.flushCookies()
      done()
    }
  }
}
