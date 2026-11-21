import AppKit
import WebKit

final class ConsoleRelay: NSObject, WKScriptMessageHandler {
  weak var panel: Panel?

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    guard let o = message.body as? [String: Any] else { return }
    panel?.record(level: o["level"] as? String ?? "log", text: o["text"] as? String ?? "",
                  url: o["url"] as? String ?? message.frameInfo.request.url?.absoluteString ?? "",
                  source: o["source"] as? String)
  }
}

final class WebKitEngine: NSObject, PageEngine, WKNavigationDelegate, WKUIDelegate {
  static let store = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "6F1C0D2A-9C3B-4E55-9B7A-5E3B0AEB0001")!)

  static func setCookies(_ cookies: [HTTPCookie], _ done: @escaping () -> Void) {
    let group = DispatchGroup()
    for c in cookies { group.enter(); store.httpCookieStore.setCookie(c) { group.leave() } }
    group.notify(queue: .main, execute: done)
  }

  weak var panel: Panel?
  let web: WKWebView
  let relay = ConsoleRelay()
  var popups: [Popup] = []

  var view: NSView { web }
  var url: URL? { web.url }
  var title: String { web.title ?? "" }
  var isLoading: Bool { web.isLoading }
  var canGoBack: Bool { web.canGoBack }
  var canGoForward: Bool { web.canGoForward }
  var zoom: Double {
    get { Double(web.pageZoom) }
    set { web.pageZoom = CGFloat(newValue) }
  }

  init(panel: Panel) {
    self.panel = panel
    let conf = WKWebViewConfiguration()
    conf.websiteDataStore = WebKitEngine.store
    conf.userContentController.addUserScript(WKUserScript(source: JS.consoleHook, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    conf.userContentController.add(relay, name: "rexwebConsole")
    conf.applicationNameForUserAgent = "Version/26.4 Safari/605.1.15"
    conf.preferences.isElementFullscreenEnabled = true
    conf.allowsAirPlayForMediaPlayback = true
    web = WKWebView(frame: .zero, configuration: conf)
    super.init()
    relay.panel = panel

    web.navigationDelegate = self
    web.uiDelegate = self
    web.isInspectable = true
    web.allowsBackForwardNavigationGestures = true
    web.allowsMagnification = true
    for k in WebKitEngine.observed { web.addObserver(self, forKeyPath: k, options: .new, context: nil) }
  }

  static let observed = ["title", "URL", "canGoBack", "canGoForward"]

  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
    panel?.engineChanged()
  }

  func load(_ url: URL) {
    if url.isFileURL {
      web.loadFileURL(url, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    } else {
      web.load(URLRequest(url: url))
    }
  }

  func goBack() { web.goBack() }
  func goForward() { web.goForward() }
  func reload(fromOrigin: Bool) { if fromOrigin { web.reloadFromOrigin() } else { web.reload() } }

  func call(_ body: String, _ args: [String: Any], _ done: @escaping (Any?, String?) -> Void) {
    web.callAsyncJavaScript(body, arguments: ["args": args], in: nil, in: .page) { r in
      switch r {
      case .success(let v): done(v, nil)
      case .failure(let e): done(nil, (e as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? e.localizedDescription)
      }
    }
  }

  func click(x: Double, y: Double) {
    guard let window = web.window else { return }
    let zoom = web.pageZoom * web.magnification
    let pt = web.convert(NSPoint(x: x * zoom, y: y * zoom), to: nil)
    let t = ProcessInfo.processInfo.systemUptime
    for (type, dt) in [(NSEvent.EventType.leftMouseDown, 0.0), (.leftMouseUp, 0.03)] {
      if let ev = NSEvent.mouseEvent(with: type, location: pt, modifierFlags: [], timestamp: t + dt,
                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
        window.sendEvent(ev)
      }
    }
  }

  func press(_ name: String) -> Bool {
    let keys: [String: (UInt16, String)] = [
      "enter": (36, "\r"), "return": (36, "\r"), "tab": (48, "\t"), "escape": (53, "\u{1b}"), "esc": (53, "\u{1b}"),
      "backspace": (51, "\u{7f}"), "delete": (117, "\u{f728}"), "space": (49, " "),
      "up": (126, "\u{f700}"), "down": (125, "\u{f701}"), "left": (123, "\u{f702}"), "right": (124, "\u{f703}"),
      "home": (115, "\u{f729}"), "end": (119, "\u{f72b}"), "pageup": (116, "\u{f72c}"), "pagedown": (121, "\u{f72d}"),
    ]
    guard let (code, chars) = keys[name.lowercased()] else { return false }
    guard let window = web.window else { return true }
    if window.firstResponder == nil || window.firstResponder === window { window.makeFirstResponder(web) }
    let t = ProcessInfo.processInfo.systemUptime
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      if let ev = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: t, windowNumber: window.windowNumber,
                                   context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
        window.sendEvent(ev)
      }
    }
    return true
  }

  func insertText(_ text: String) { web.insertText(text) }

  func screenshot(_ done: @escaping (Data?, String?) -> Void) {
    web.takeSnapshot(with: nil) { img, err in
      guard let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:]) else { return done(nil, err?.localizedDescription ?? "snapshot failed") }
      done(png, nil)
    }
  }

  func focus() { web.window?.makeFirstResponder(web) }

  func close() {
    popups.forEach { $0.window.close() }
    popups = []
    web.configuration.userContentController.removeScriptMessageHandler(forName: "rexwebConsole")
    for k in WebKitEngine.observed { web.removeObserver(self, forKeyPath: k) }
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { panel?.engineStarted() }
  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    guard webView === web else { return }
    panel?.engineCommitted()
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { panel?.engineFinished() }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }

  func failed(_ error: Error) {
    let e = error as NSError
    if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
    let failing = (e.userInfo[NSURLErrorFailingURLStringErrorKey] as? String) ?? web.url?.absoluteString ?? ""
    panel?.engineFailed(e.localizedDescription, url: failing)
  }

  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
               for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    let isPopup = windowFeatures.width != nil || windowFeatures.height != nil || navigationAction.navigationType == .other
    if !isPopup {
      if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
      return nil
    }
    guard let parent = web.window else { return nil }
    let popup = Popup(configuration: configuration, features: windowFeatures, parent: parent)
    popup.onClose = { [weak self, weak popup] in self?.popups.removeAll { $0 === popup } }
    popups.append(popup)
    return popup.web
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    if navigationAction.modifierFlags.contains(.command), let url = navigationAction.request.url,
       navigationAction.navigationType == .linkActivated {
      panel?.openBeside(url.absoluteString)
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
  }

  func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
    guard let window = web.window else { return completionHandler() }
    let a = NSAlert(); a.messageText = message; a.beginSheetModal(for: window) { _ in completionHandler() }
  }

  func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
    guard let window = web.window else { return completionHandler(false) }
    let a = NSAlert(); a.messageText = message; a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
    a.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
  }

  func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
    guard let window = web.window else { return completionHandler(nil) }
    let p = NSOpenPanel(); p.allowsMultipleSelection = parameters.allowsMultipleSelection
    p.canChooseDirectories = parameters.allowsDirectories
    p.beginSheetModal(for: window) { completionHandler($0 == .OK ? p.urls : nil) }
  }
}

final class Popup: NSObject, WKUIDelegate, WKNavigationDelegate, NSWindowDelegate {
  let web: WKWebView
  let window: NSWindow
  var onClose: (() -> Void)?

  init(configuration: WKWebViewConfiguration, features: WKWindowFeatures, parent: NSWindow) {
    let w = CGFloat(features.width?.doubleValue ?? 520), h = CGFloat(features.height?.doubleValue ?? 680)
    web = WKWebView(frame: NSRect(x: 0, y: 0, width: w, height: h), configuration: configuration)
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    super.init()
    window.isReleasedWhenClosed = false
    window.contentView = web
    window.delegate = self
    web.uiDelegate = self
    web.navigationDelegate = self
    web.isInspectable = true
    let pf = parent.frame
    window.setFrameOrigin(NSPoint(x: pf.midX - w / 2, y: pf.midY - h / 2))
    window.level = .floating
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func webViewDidClose(_ webView: WKWebView) { window.close() }
  func windowWillClose(_ n: Notification) { onClose?() }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { window.title = webView.title ?? "" }
}

