import AppKit
import CommonCrypto
import SQLite3
import CoreGraphics
import Network
import Security

struct Config {
  var top: Double?, left: Double?, right: Double?, bottom: Double?
  var gap: Double?, header: Double?, radius: Double?
  var port = 18802
  var chromiumPort = 18803
  var chromiumDebugPort = 0
  var defaultEngine = "webkit"
  var searchURL = "https://www.google.com/search?q=%s"
  var fallbackBrowser = ""
  var linkTarget = "split"
  /// Minutes a background tab may sit unused before it is unloaded. 0 turns unloading off.
  var tabUnloadMinutes = 30.0
  var rexBin = ""
  var configError: String?

  static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".rexweb")

  static func findRex() -> String {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser.path
    var candidates: [String] = []
    for root in ["/Applications", "\(home)/Applications"] {
      for app in ["Rex", "Rex Beta"] {
        candidates.append("\(root)/\(app).app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex")
      }
    }
    candidates += ["/opt/homebrew/bin/rex", "/usr/local/bin/rex", "\(home)/.local/bin/rex"]
    return candidates.first { fm.isExecutableFile(atPath: $0) } ?? "rex"
  }

  static func load() -> Config {
    var c = Config()
    defer {
      if let bin = ProcessInfo.processInfo.environment["REX_BIN"], !bin.isEmpty { c.rexBin = bin }
      if c.rexBin.isEmpty { c.rexBin = findRex() }
    }
    let url = dir.appendingPathComponent("config.json")
    guard let data = try? Data(contentsOf: url) else { return c }
    guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      c.configError = "~/.rexweb/config.json isn't a valid JSON object"
      return c
    }
    func n(_ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
    c.top = n("top"); c.left = n("left"); c.right = n("right"); c.bottom = n("bottom")
    c.gap = n("gap"); c.header = n("header"); c.radius = n("radius")
    if let p = o["port"] as? NSNumber { c.port = p.intValue }
    if let p = o["chromium_port"] as? NSNumber { c.chromiumPort = p.intValue }
    if let p = o["chromium_debug_port"] as? NSNumber { c.chromiumDebugPort = p.intValue }
    if let e = o["engine"] as? String {
      if ["webkit", "chromium"].contains(e) { c.defaultEngine = e } else { c.configError = "engine must be \"webkit\" or \"chromium\"" }
    }
    if let b = o["rex_bin"] as? String { c.rexBin = b }
    if let u = o["search_url"] as? String {
      if u.contains("%s") { c.searchURL = u } else { c.configError = "search_url needs %s where the query goes" }
    }
    if let f = o["fallback_browser"] as? String { c.fallbackBrowser = f }
    if let m = n("tab_unload_minutes") {
      if m >= 0 { c.tabUnloadMinutes = m } else { c.configError = "tab_unload_minutes must be 0 (off) or more" }
    }
    if let t = o["links"] as? String {
      if ["tab", "split"].contains(t) { c.linkTarget = t } else { c.configError = "links must be \"split\" or \"tab\"" }
    }
    return c
  }
}

var config = Config.load()

enum Auth {
  static let file = Config.dir.appendingPathComponent("token")

  static let token: String = {
    let fm = FileManager.default
    try? fm.createDirectory(at: Config.dir, withIntermediateDirectories: true)
    if let t = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 32 {
      try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      return t
    }
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let t = bytes.map { String(format: "%02x", $0) }.joined()
    // RexWeb and RexWebChromium share this file and can start together, so
    // only one of them may create it; the other reads what was written.
    let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    if fd >= 0 {
      _ = Data(t.utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
      Darwin.close(fd)
      return t
    }
    for _ in 0..<20 {
      if let other = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), other.count >= 32 { return other }
      usleep(50_000)
    }
    // The file is there but unusable (empty or cut short). Replace it whole,
    // so the CLI and the other app read the same token this app answers to.
    let tmp = file.appendingPathExtension("new-\(ProcessInfo.processInfo.processIdentifier)")
    if fm.createFile(atPath: tmp.path, contents: Data(t.utf8), attributes: [.posixPermissions: 0o600]),
       rename(tmp.path, file.path) == 0 { return t }
    try? fm.removeItem(at: tmp)
    return t
  }()

  static func matches(_ given: String?) -> Bool {
    guard let given else { return false }
    let a = Array(given.utf8), b = Array(token.utf8)
    guard a.count == b.count else { return false }
    return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
  }
}

struct Insets: Equatable {
  var top, left, right, bottom, gap, header, radius: Double
  var floatHeader = 36.0
  var floatTop = 38.0, floatLeft = 0.0, floatRight = 0.0
}

enum RexChrome {
  static let domain = "com.superlogical.rex" as CFString

  static func value(_ key: String) -> Any? {
    CFPreferencesCopyAppValue("Workspace.\(key)" as CFString, domain)
  }

  /// The size Rex last saved for its Settings window, or nil if it has never
  /// shown one. AppKit saves the frame as "x y width height" and then the
  /// screen's frame.
  static func settingsSize() -> CGSize? {
    let key = "NSWindow Frame com_apple_SwiftUI_Settings_window" as CFString
    guard let s = CFPreferencesCopyAppValue(key, domain) as? String else { return nil }
    let n = s.split(separator: " ").compactMap { Double($0) }
    return n.count >= 4 ? CGSize(width: n[2], height: n[3]) : nil
  }

  static func read() -> Insets {
    CFPreferencesAppSynchronize(domain)
    let compact = value("paneDensity") as? String == "compact"
    let e = compact ? 0.0 : 8.0
    var i = compact
      ? Insets(top: 41, left: e, right: e, bottom: e, gap: 2, header: 35, radius: 0)
      : Insets(top: 46, left: e, right: e, bottom: e, gap: 8, header: 36, radius: 10)
    let headers = value("paneHeaderVisibility") as? String
      ?? (((value("showsPaneHeaders") as? NSNumber)?.boolValue ?? true) ? "always" : "never")
    if headers != "always" { i.header = 0; i.floatHeader = 0 }
    let toolbar = value("toolbarBehavior") as? String ?? "alwaysShow"
    i.floatTop = i.top - e
    if value("tabStyle") as? String != "vertical", toolbar != "alwaysShow" { i.top = e; i.floatTop = 0 }
    if value("tabStyle") as? String == "vertical" {
      i.top = e
      i.floatTop = 38
      let collapsed = (value("sidebarCollapsed") as? NSNumber)?.boolValue ?? false
      if !collapsed {
        let w = (value("sidebarWidth") as? NSNumber)?.doubleValue ?? 0
        if value("sidebarPosition") as? String == "right" { i.right = w; i.floatRight = w } else { i.left = w; i.floatLeft = w; i.floatTop = 0 }
      }
    }
    if let t = config.top { i.top = t }
    if let l = config.left { i.left = l }
    if let r = config.right { i.right = r }
    if let b = config.bottom { i.bottom = b }
    if let g = config.gap { i.gap = g }
    if let h = config.header { i.header = h }
    if let r = config.radius { i.radius = r }
    return i
  }
}

func orNull(_ v: Any?) -> Any { v ?? NSNull() }

func log(_ s: String) {
  FileHandle.standardError.write(("[rexweb] " + s + "\n").data(using: .utf8)!)
  LogFile.write(s)
}

/// A debugging log on disk: `~/.rexweb/rexweb.log`, or `rexweb-chromium.log`
/// for the Chromium app. The app is started with `open`, so nothing reads
/// its standard error. Lines hold page addresses, so the file is made
/// readable by its owner only. Past 1 MB it becomes `.log.1`, replacing the
/// one before, and a new file starts.
enum LogFile {
  static let maxBytes: UInt64 = 1 << 20
  private static let queue = DispatchQueue(label: "rexweb.log")
  private static var handle: FileHandle?
  private static var size: UInt64 = 0
  private static let stamp: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
    return f
  }()
  static var path: String {
    NSHomeDirectory() + "/.rexweb/" + (Engine.name == "chromium" ? "rexweb-chromium.log" : "rexweb.log")
  }

  static func write(_ s: String) {
    let now = Date()
    queue.async {
      guard let data = "\(stamp.string(from: now))  \(s)\n".data(using: .utf8) else { return }
      if size + UInt64(data.count) > maxBytes, handle != nil {
        try? handle?.close()
        handle = nil
        _ = try? FileManager.default.removeItem(atPath: path + ".1")
        _ = try? FileManager.default.moveItem(atPath: path, toPath: path + ".1")
      }
      if handle == nil {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
          guard fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
        }
        guard let h = FileHandle(forWritingAtPath: path) else { return }
        size = (try? h.seekToEnd()) ?? 0
        handle = h
      }
      if (try? handle?.write(contentsOf: data)) != nil { size += UInt64(data.count) }
    }
  }
}

enum Rex {
  static let queue = DispatchQueue(label: "rexweb.rex", attributes: .concurrent)

  @discardableResult
  static func run(_ args: [String]) -> Data? {
    let p = Process()
    if config.rexBin.contains("/") {
      p.executableURL = URL(fileURLWithPath: config.rexBin)
      p.arguments = args
    } else {
      p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      p.arguments = [config.rexBin] + args
    }
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { log("rex failed: \(error)"); return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 ? data : nil
  }

  static func view(_ session: String) -> [String: Any]? {
    let args = String(data: try! JSONSerialization.data(withJSONObject: ["session_id": session]), encoding: .utf8)!
    guard let data = run(["api", "call", "session.view", args]) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  static func async(_ args: [String]) { queue.async { run(args) } }

  static var version: String?
  static func checkVersion() {
    queue.async {
      let v = run(["version"]).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
      DispatchQueue.main.async { version = v }
      if v == nil { log("can't run rex at \(config.rexBin); set rex_bin in ~/.rexweb/config.json") }
    }
  }

  struct Grid { let columns, rows, cellWidth, cellHeight: Double }

  static func size(block: String, session: String) -> (displayed: Bool, grid: Grid?)? {
    guard let data = run(["block", "call", "-s", session, "-b", block, "size"]),
          let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let shown = !((o["desired"] as? [Any]) ?? []).isEmpty
    func n(_ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
    guard let c = n("columns"), let r = n("rows"), let w = n("cell_width_px"), let h = n("cell_height_px") else { return (shown, nil) }
    return (shown, Grid(columns: c, rows: r, cellWidth: w, cellHeight: h))
  }

  static let labelQueue = DispatchQueue(label: "rexweb.label")
  static var pendingLabels: [String: (String, String)] = [:]
  static let labelLock = NSLock()

  static func setLabel(block: String, session: String, _ label: String) {
    labelLock.lock(); pendingLabels[block] = (session, label); labelLock.unlock()
    labelQueue.async {
      labelLock.lock(); let next = pendingLabels.removeValue(forKey: block); labelLock.unlock()
      guard let (session, label) = next else { return }
      run(["block", "rename", "-s", session, block, label])
    }
  }
}

final class OverlayWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}


/// What a browser engine provides to a pane. RexWeb.app registers WebKit;
/// RexWebChromium.app registers Chromium. Everything else in this file is
/// shared by both apps.
protocol PageEngine: AnyObject {
  var view: NSView { get }
  var url: URL? { get }
  var title: String { get }
  var isLoading: Bool { get }
  var canGoBack: Bool { get }
  var canGoForward: Bool { get }
  var zoom: Double { get set }
  func load(_ url: URL)
  func goBack()
  func goForward()
  func reload(fromOrigin: Bool)
  /// Runs `body` as the body of an async function whose one parameter is `args`.
  func call(_ body: String, _ args: [String: Any], _ done: @escaping (Any?, String?) -> Void)
  /// Clicks at a point in CSS pixels from the page's top-left corner.
  func click(x: Double, y: Double)
  func press(_ name: String) -> Bool
  func insertText(_ text: String)
  /// PNG data of the page as shown.
  func screenshot(_ done: @escaping (Data?, String?) -> Void)
  func focus()
  /// Asks whether the page can be unloaded without losing something: sound
  /// that is playing, a popup, a half-filled form, an open DevTools window.
  /// Calls back with nil when it can, or with a few words on what keeps it.
  func unloadBlocker(_ done: @escaping (String?) -> Void)
  func close()
}

enum Engine {
  static var name = "webkit"
  static var label = "WebKit"
  static var make: (Tab) -> PageEngine = { _ in fatalError("no page engine registered") }
  static var setCookies: ([HTTPCookie], @escaping () -> Void) -> Void = { _, done in done() }
  /// Routes only one engine has. Returns false when the route isn't its own.
  static var route: ((String, Tab, [String: Any], @escaping (Int, Any) -> Void) -> Bool)?
  /// API routes that only work on a page that is drawing. A command on one
  /// of these routes aimed at a background tab borrows the pane: the tab's
  /// page is unhidden behind the tab on show, the command waits a moment and
  /// runs, and the page is hidden again after the reply. The tab on show,
  /// the keyboard, the tab strip and the address bar stay as they were. Each
  /// app sets this for its engine; a route left out runs on the hidden page.
  static var needsVisible: Set<String> = []
}

/// One page in a pane. A pane always has at least one tab, and shows one.
///
/// A tab is either live, with a page engine, or asleep: only its address,
/// title and console log are kept. Tabs restored after a restart start asleep,
/// and background tabs left unused go to sleep to give their memory back.
/// Reading `engine` wakes a tab. Code that only lists tabs must use `url`,
/// `title`, `isLive` and `live`, which never wake one.
final class Tab {
  let id: String
  private(set) weak var panel: Panel?
  /// The engine, when the tab is awake. Reading this never wakes the tab.
  private(set) var live: PageEngine?
  private(set) var closed = false
  var console: [[String: Any]] = []
  var consoleSeq = 0
  var consoleDropped = 0
  var loadWaiters: [(String?) -> Void] = []
  var lastError: String?
  var requested: URL?
  /// When the tab was last selected, or a command addressed to it began or ended.
  var lastUsed = Date()
  /// API commands running on this tab now. A busy tab is never unloaded.
  var busy = 0
  /// Why the unload timer last left this idle tab loaded, if it did.
  var unloadBlocked: String?
  /// What a sleeping tab shows and reloads.
  private(set) var savedURL: String
  private(set) var savedTitle: String

  init(panel: Panel, id: String, url: String = "", title: String = "", asleep: Bool = false) {
    self.panel = panel
    self.id = id
    savedURL = url
    savedTitle = title
    if !asleep { live = Engine.make(self) }
  }

  var isLive: Bool { live != nil && !closed }
  var isActive: Bool { panel?.activeTab === self }
  /// The tab is the one on show in a pane that is on screen.
  var visible: Bool { (panel?.visible ?? false) && isActive }
  /// The page's address. While the page has none of its own, because a first
  /// load is on its way or failed, this is the address asked for.
  var url: String {
    guard let live else { return savedURL }
    let now = live.url?.absoluteString ?? ""
    if now.isEmpty || now == "about:blank", let r = requested, r.scheme != "about" { return r.absoluteString }
    return live.url == nil ? savedURL : now
  }
  var title: String { live.map { $0.title } ?? savedTitle }
  var isLoading: Bool { isLive && (live?.isLoading ?? false) }

  /// The tab's page engine. Wakes the tab if it is asleep: makes the engine,
  /// puts its view in the pane, and loads the saved address.
  var engine: PageEngine {
    if let live { return live }
    let made = Engine.make(self)
    live = made
    // A closed tab can still be reached by a reply that was waiting on it.
    // Hand that an engine that does nothing.
    if closed { made.close(); return made }
    panel?.attach(self)
    if !savedURL.isEmpty, let u = URL(string: savedURL) {
      requested = u
      made.load(u)
    }
    panel?.tabChanged(self)
    return made
  }

  /// Gives the page's memory back. The address, title and console log stay;
  /// the page's history and, on Chromium, its network log go with the engine.
  func sleep() {
    guard let engine = live, !closed, !isActive else { return }
    savedURL = url
    savedTitle = engine.title.isEmpty ? savedTitle : engine.title
    finishWaiters("the tab was unloaded")
    engine.view.removeFromSuperview()
    engine.close()
    live = nil
    lastError = nil
    record(level: "navigation", text: "Tab unloaded to save memory. It reloads when used.", url: savedURL)
  }

  func info() -> [String: Any] {
    ["id": panel?.id ?? "", "session": panel?.session ?? "", "url": url, "title": title,
     "loading": isLoading, "visible": visible, "pane_visible": panel?.visible ?? false,
     "error": orNull(lastError), "engine": Engine.name,
     "label": panel?.lastLabel ?? "", "active": (panel?.lastActive ?? Date()).timeIntervalSince1970,
     "tab": id, "tab_index": (panel?.tabs.firstIndex { $0 === self } ?? 0) + 1, "tabs": panel?.tabs.count ?? 0,
     "tab_active": isActive, "tab_asleep": !isLive]
  }

  /// Loads an address. On a sleeping tab this makes the engine and loads the
  /// new address only, not the saved one first. `raw` is read as something a
  /// person typed, unless `exact` says it is a whole address already.
  func load(_ raw: String, exact: Bool = false, done: ((String?) -> Void)? = nil) {
    guard let url = exact ? URL(string: raw) : Panel.normalize(raw) else { done?("bad url"); return }
    if closed { done?("closed"); return }
    requested = url
    if let done { loadWaiters.append(done) }
    if let live {
      live.load(url)
    } else {
      savedURL = url.absoluteString
      _ = engine
    }
  }

  var refusedError: String? {
    guard let live, let req = requested, req.scheme != "about", live.url == nil || live.url?.absoluteString == "about:blank" else { return nil }
    return "\(Engine.label) didn't load \(req.absoluteString). Its port may be one \(Engine.label) blocks"
  }

  func waitForLoad(_ done: @escaping (String?) -> Void) {
    // A closed tab's engine reports nothing more, so a waiter would never be called.
    if closed { done("closed"); return }
    if !engine.isLoading { done(lastError ?? refusedError); return }
    loadWaiters.append(done)
  }

  func finishWaiters(_ err: String?) {
    let w = loadWaiters
    loadWaiters = []
    w.forEach { $0(err) }
  }

  /// While set, drops the "Script error." that eval's expression-first attempt
  /// raises when the code turns out to be statements.
  var probingUntil = Date.distantPast

  func record(level: String, text: String, url: String, source: String? = nil) {
    if level == "error", text == "Uncaught Script error.", Date() < probingUntil { return }
    consoleSeq += 1
    var entry: [String: Any] = [
      "seq": consoleSeq, "time": Date().timeIntervalSince1970,
      "level": Panel.consoleLevels.contains(level) ? level : "log",
      "text": String(text.prefix(8000)), "url": String(url.prefix(2000)),
    ]
    if let source, !source.isEmpty { entry["source"] = String(source.prefix(2000)) }
    console.append(entry)
    if console.count > Panel.consoleLimit {
      consoleDropped += console.count - Panel.consoleLimit
      console.removeFirst(console.count - Panel.consoleLimit)
    }
  }

  // Called by the engine.

  func engineChanged() { panel?.tabChanged(self) }
  func engineStarted() { lastError = nil }
  func engineCommitted(_ url: String? = nil) {
    let u = url ?? live?.url?.absoluteString ?? ""
    record(level: "navigation", text: "Navigated to \(u)", url: u)
    panel?.tabChanged(self)
  }
  func engineFinished() { lastError = nil; finishWaiters(nil); panel?.tabChanged(self) }
  func engineFailed(_ message: String, url: String) {
    lastError = message
    record(level: "error", text: "Page failed to load: \(message)", url: url)
    finishWaiters(lastError)
  }

  /// The kinds of address a link may open in a new tab or pane. A link of any
  /// other kind, such as mailto: or tel:, does nothing there, as it does
  /// nothing when clicked plainly in a pane.
  static let linkSchemes: Set<String> = ["http", "https", "file", "about", "data", "blob"]

  private func opens(_ url: String) -> Bool {
    if let scheme = URL(string: url)?.scheme?.lowercased(), Tab.linkSchemes.contains(scheme) { return true }
    record(level: "warn", text: "Didn't open \(url.prefix(200)): only web addresses open in a tab or pane.", url: self.url)
    return false
  }

  /// Opens `url` in a new tab of this tab's pane, placed right after this
  /// tab. `foreground` shows the new tab; otherwise it loads behind this one.
  /// `url` is a whole address from a link, loaded as given. The new tab is a
  /// separate page with no `window.opener`. Returns nil when this tab's pane
  /// is gone or the address isn't one a pane can show.
  @discardableResult
  func openTab(_ url: String, foreground: Bool) -> Tab? {
    guard opens(url) else { return nil }
    return panel?.newTab(url: url, foreground: foreground, after: self, exact: true)
  }

  /// Opens `url`, a whole address from a link, in a new browser pane to the
  /// right of this tab's pane, with the same engine.
  func openBeside(_ url: String) {
    guard let panel, opens(url) else { return }
    App.shared.openPane(beside: panel.id, session: panel.session, url: url)
  }

  func close() {
    closed = true
    finishWaiters("closed")
    live?.view.removeFromSuperview()
    live?.close()
  }
}

/// The row of tabs above the address bar. Shown when a pane has two or more.
final class TabStrip: NSView {
  struct Item: Equatable { let title: String; let active: Bool; let asleep: Bool }

  var onSelect: (Int) -> Void = { _ in }
  var onClose: (Int) -> Void = { _ in }
  var onNew: () -> Void = {}
  private var items: [Item] = []
  private var cells: [TabCell] = []
  private let plus = NSButton()

  override init(frame: NSRect) {
    super.init(frame: frame)
    plus.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
    plus.imageScaling = .scaleProportionallyDown
    plus.bezelStyle = .accessoryBarAction
    plus.isBordered = false
    plus.toolTip = "New Tab"
    plus.target = self
    plus.action = #selector(newTab)
    addSubview(plus)
  }
  required init?(coder: NSCoder) { fatalError("not used") }

  @objc func newTab() { onNew() }

  /// Redraws only when something a person can see has changed.
  func show(_ new: [Item]) {
    guard new != items else { return }
    if new.count == cells.count {
      for (i, item) in new.enumerated() where item != items[i] { cells[i].show(item) }
    } else {
      cells.forEach { $0.removeFromSuperview() }
      cells = new.enumerated().map { i, item in
        let c = TabCell()
        c.show(item)
        c.onSelect = { [weak self] in self?.onSelect(i) }
        c.onClose = { [weak self] in self?.onClose(i) }
        addSubview(c)
        return c
      }
      needsLayout = true
    }
    items = new
  }

  override func layout() {
    super.layout()
    let plusWidth: CGFloat = 26
    let room = max(0, bounds.width - plusWidth - 10)
    let w = cells.isEmpty ? 0 : min(200, max(44, room / CGFloat(cells.count)))
    for (i, c) in cells.enumerated() { c.frame = NSRect(x: 6 + CGFloat(i) * w, y: 2, width: w - 2, height: bounds.height - 4) }
    plus.frame = NSRect(x: min(bounds.width - plusWidth, 6 + CGFloat(cells.count) * w + 2), y: 2, width: 22, height: bounds.height - 4)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    for (i, c) in cells.enumerated() where i < items.count { c.show(items[i]) }
  }
}

final class TabCell: NSView {
  var onSelect: () -> Void = {}
  var onClose: () -> Void = {}
  private let label = NSTextField(labelWithString: "")
  private let closeButton = NSButton()

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 5
    label.font = .systemFont(ofSize: 11)
    label.lineBreakMode = .byTruncatingTail
    addSubview(label)
    closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
    closeButton.imageScaling = .scaleProportionallyDown
    closeButton.bezelStyle = .accessoryBarAction
    closeButton.isBordered = false
    closeButton.toolTip = "Close Tab"
    closeButton.target = self
    closeButton.action = #selector(close)
    addSubview(closeButton)
  }
  required init?(coder: NSCoder) { fatalError("not used") }

  func show(_ item: TabStrip.Item) {
    label.stringValue = item.title
    label.textColor = item.active ? .labelColor : (item.asleep ? .tertiaryLabelColor : .secondaryLabelColor)
    toolTip = item.asleep ? "\(item.title) (unloaded; click to reload)" : item.title
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = item.active ? NSColor.labelColor.withAlphaComponent(0.12).cgColor : NSColor.clear.cgColor
    }
  }

  override func layout() {
    super.layout()
    let showClose = bounds.width >= 60
    closeButton.isHidden = !showClose
    closeButton.frame = NSRect(x: bounds.width - 20, y: (bounds.height - 14) / 2, width: 14, height: 14)
    label.frame = NSRect(x: 8, y: (bounds.height - 15) / 2, width: max(0, bounds.width - (showClose ? 30 : 12)), height: 15)
  }

  /// The label would swallow clicks meant for the tab.
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let hit = super.hitTest(point) else { return nil }
    return hit === closeButton ? hit : self
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  @objc func close() { onClose() }
  override func mouseDown(with event: NSEvent) { onSelect() }
  override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 { onClose() } }
}

final class Panel: NSObject, NSTextFieldDelegate {
  let id: String
  let session: String
  private(set) var tabs: [Tab] = []
  /// The tab on show: the one the user sees and a command with no tab acts
  /// on. It is always live. A borrow doesn't change it.
  private(set) var activeTab: Tab!
  private var tabCounter = 0
  /// The pane was built from a saved tab list rather than started empty.
  private(set) var restored = false
  /// Set while commands have a background tab's page drawing behind the tab
  /// on show. `count` is how many commands share it. See `Engine.needsVisible`.
  private(set) var borrow: (to: Tab, count: Int, token: Int, started: Date)?
  private var borrowSeq = 0

  /// The engine of the tab on show.
  var engine: PageEngine { activeTab.engine }

  static let consoleLimit = 1000
  static let consoleLevels: Set<String> = ["log", "info", "warn", "error", "debug", "navigation"]
  let window: OverlayWindow
  let strip = TabStrip()
  let bar = NSView()
  let urlField = NSTextField()
  let backButton = NSButton()
  let forwardButton = NSButton()
  let reloadButton = NSButton()
  var lastLabel = ""
  var visible = false
  var lastFrame = NSRect.zero
  var layoutKey = ""
  var settleUntil = Date.distantPast
  var lastActive = Date()
  var focusedInRex = false
  var pendingFocus = false
  var focusURLWhenShown = false

  static let barHeight: CGFloat = 30
  static let stripHeight: CGFloat = 26

  /// `restore` is a saved tab list, as `savedState` writes it.
  init(id: String, session: String, restore: [String: Any]? = nil) {
    self.id = id
    self.session = session
    window = OverlayWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                           styleMask: [.borderless], backing: .buffered, defer: false)
    super.init()

    window.isReleasedWhenClosed = false
    window.hasShadow = false
    window.backgroundColor = .clear
    window.isOpaque = false
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    let root = NSView()
    root.wantsLayer = true
    root.layer?.cornerRadius = 10
    root.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    root.layer?.masksToBounds = true
    root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    window.contentView = root

    for (b, sym, tip, sel) in [(backButton, "chevron.left", "Back", #selector(goBack)),
                               (forwardButton, "chevron.right", "Forward", #selector(goForward)),
                               (reloadButton, "arrow.clockwise", "Reload", #selector(reload))] {
      b.image = NSImage(systemSymbolName: sym, accessibilityDescription: tip)
      b.bezelStyle = .accessoryBarAction
      b.isBordered = false
      b.toolTip = tip
      b.target = self
      b.action = sel
      bar.addSubview(b)
    }
    urlField.placeholderString = "Search or enter address"
    urlField.font = .systemFont(ofSize: 12)
    urlField.bezelStyle = .roundedBezel
    urlField.focusRingType = .none
    urlField.lineBreakMode = .byTruncatingTail
    urlField.usesSingleLineMode = true
    urlField.delegate = self
    urlField.target = self
    urlField.action = #selector(submitURL)
    bar.addSubview(urlField)

    strip.onSelect = { [weak self] i in
      guard let self, i < self.tabs.count else { return }
      self.select(self.tabs[i])
      self.engine.focus()
    }
    strip.onClose = { [weak self] i in
      guard let self, i < self.tabs.count else { return }
      self.closeTab(self.tabs[i])
    }
    strip.onNew = { [weak self] in self?.newTabFromUI() }
    strip.isHidden = true
    root.addSubview(strip)
    root.addSubview(bar)

    // Blank tabs aren't worth bringing back; the tab on show moves to the
    // nearest one before it that is. Each tab keeps the ID it had, and the
    // counter carries on from where it was, so an ID a script still holds
    // names the same page or nothing. A file from before IDs were saved has
    // none, and its tabs are numbered from t1.
    let saved = restore?["tabs"] as? [[String: Any]] ?? []
    let wanted = (restore?["active"] as? NSNumber)?.intValue ?? 0
    var ids: [String?] = []
    for s in saved {
      let tid = s["id"] as? String ?? ""
      let ok = tid.range(of: #"^t[1-9][0-9]{0,8}$"#, options: .regularExpression) != nil && !ids.contains(tid)
      ids.append(ok ? tid : nil)
    }
    tabCounter = max((restore?["counter"] as? NSNumber)?.intValue ?? 0, ids.compactMap { $0.flatMap { Int($0.dropFirst()) } }.max() ?? 0)
    var chosen = 0
    for (i, s) in saved.enumerated() {
      let url = s["url"] as? String ?? ""
      if url.isEmpty || url == "about:blank" { continue }
      if i <= wanted { chosen = tabs.count }
      _ = makeTab(id: ids[i], url: url, title: s["title"] as? String ?? "", asleep: true)
    }
    if tabs.isEmpty {
      activeTab = makeTab()
    } else {
      restored = true
      activeTab = tabs[chosen]
    }
    activeTab.engine.view.isHidden = false
    layout()
    NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
      self?.layout()
    }
    NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
      guard let self else { return }
      self.lastActive = Date()
      Rex.async(["focus", "-s", self.session, self.id])
    }
    tabsChanged()
  }

  // MARK: Tabs

  private func makeTab(id: String? = nil, url: String = "", title: String = "", asleep: Bool = false, at index: Int? = nil) -> Tab {
    if id == nil { tabCounter += 1 }
    let t = Tab(panel: self, id: id ?? "t\(tabCounter)", url: url, title: title, asleep: asleep)
    tabs.insert(t, at: min(index ?? tabs.count, tabs.count))
    if t.isLive { attach(t) }
    return t
  }

  /// Puts a live tab's view in the pane, hidden unless the tab is on show.
  func attach(_ t: Tab) {
    guard let root = window.contentView, let view = t.live?.view, tabs.contains(where: { $0 === t }) else { return }
    view.isHidden = !(activeTab === t)
    if view.superview !== root { root.addSubview(view, positioned: .below, relativeTo: bar) }
    orderPages()
    layout()
  }

  private static func rank(_ v: NSView, in p: Panel) -> Int {
    v === p.bar || v === p.strip ? 2 : (v === p.activeTab?.live?.view ? 1 : 0)
  }

  /// Keeps the page on show above every other page, so a page that a borrow
  /// unhides stays out of sight and out of reach of the mouse.
  private func orderPages() {
    window.contentView?.sortSubviews({ a, b, context in
      let p = Unmanaged<Panel>.fromOpaque(context!).takeUnretainedValue()
      let x = Panel.rank(a, in: p), y = Panel.rank(b, in: p)
      return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
    }, context: Unmanaged.passUnretained(self).toOpaque())
  }

  // MARK: Borrowing

  /// Whether a command on `t` must wait for another tab's borrow to end.
  func borrowedByAnother(_ t: Tab) -> Bool { borrow != nil && borrow!.to !== t }

  /// Has a background tab's page draw, behind the tab on show, until the
  /// matching `endBorrow`. Calls `ready` once the page has had a moment to
  /// start drawing, with the token to end the borrow with. A second command
  /// on the same tab shares the borrow and waits out what is left of that moment.
  func beginBorrow(_ t: Tab, ready: @escaping (Int) -> Void) {
    let settle = 0.15
    if var b = borrow {
      b.count += 1
      borrow = b
      let left = max(0, settle - Date().timeIntervalSince(b.started))
      if left == 0 { return ready(b.token) }
      return DispatchQueue.main.asyncAfter(deadline: .now() + left) { ready(b.token) }
    }
    borrowSeq += 1
    let token = borrowSeq
    borrow = (to: t, count: 1, token: token, started: Date())
    t.engine.view.isHidden = false
    DispatchQueue.main.asyncAfter(deadline: .now() + settle) { ready(token) }
  }

  func endBorrow(_ token: Int) {
    guard var b = borrow, b.token == token else { return }
    b.count -= 1
    if b.count > 0 { borrow = b; return }
    borrow = nil
    if b.to !== activeTab { b.to.live?.view.isHidden = true }
  }

  /// Finds a tab by its ID, such as t3, or by its position counted from 1.
  /// Nothing means the tab on show.
  func tab(_ raw: Any?) -> Tab? {
    let s = (raw as? String) ?? (raw as? NSNumber)?.stringValue ?? ""
    if s.isEmpty { return activeTab }
    if let t = tabs.first(where: { $0.id == s }) { return t }
    if let n = Int(s), n >= 1, n <= tabs.count { return tabs[n - 1] }
    return nil
  }

  /// Adds a tab, after `after` or at the end, and loads `url` in it if given.
  /// `exact` is for a whole address, as `Tab.load` takes it.
  @discardableResult
  func newTab(url: String, foreground: Bool, after: Tab? = nil, exact: Bool = false) -> Tab {
    let index = after.flatMap { a in tabs.firstIndex { $0 === a } }.map { $0 + 1 }
    let t = makeTab(at: index)
    if !url.isEmpty { t.load(url, exact: exact) }
    if foreground { select(t) } else { tabsChanged() }
    return t
  }

  func newTabFromUI() {
    newTab(url: "", foreground: true)
    focusURL()
  }

  /// Shows a tab, waking it if it is asleep.
  func select(_ t: Tab) {
    guard tabs.contains(where: { $0 === t }) else { return }
    t.lastUsed = Date()
    t.unloadBlocked = nil
    guard let old = activeTab, old !== t else { return }
    old.lastUsed = Date()
    if editingURL { urlField.abortEditing() }
    activeTab = t
    let view = t.engine.view
    // A page that a command has borrowed stays drawing, now behind this one.
    if borrow?.to !== old { old.live?.view.isHidden = true }
    view.isHidden = false
    orderPages()
    layout()
    // Keys sent to the window go to its first responder, which must not stay
    // the page that was just hidden. This doesn't bring the window forward.
    t.engine.focus()
    tabsChanged()
  }

  /// The address field has the keyboard.
  var editingURL: Bool { urlField.currentEditor() != nil && window.firstResponder === urlField.currentEditor() }

  func selectNext(_ step: Int) {
    guard tabs.count > 1, let i = tabs.firstIndex(where: { $0 === activeTab }) else { return }
    select(tabs[(i + step + tabs.count) % tabs.count])
    engine.focus()
  }

  /// Closes a tab. Closing the last one closes the pane.
  func closeTab(_ t: Tab) {
    guard let i = tabs.firstIndex(where: { $0 === t }) else { return }
    if tabs.count == 1 { Rex.async(["block", "close", id]); return }
    if borrow?.to === t { borrow = nil }
    tabs.remove(at: i)
    if activeTab === t {
      let editing = editingURL
      if editing { urlField.abortEditing() }
      activeTab = tabs[min(i, tabs.count - 1)]
      activeTab.lastUsed = Date()
      t.close()
      activeTab.engine.view.isHidden = false
      orderPages()
      activeTab.engine.focus()
    } else {
      t.close()
    }
    tabsChanged()
  }

  /// A tab's address, title or load state changed.
  func tabChanged(_ t: Tab) {
    if t === activeTab { updateChrome() }
    refreshStrip()
    App.shared.saveTabsSoon()
  }

  /// The set of tabs, their order, or the one on show changed.
  func tabsChanged() {
    updateChrome()
    refreshStrip()
    layout()
    App.shared.saveTabsSoon()
  }

  func refreshStrip() {
    strip.isHidden = tabs.count < 2
    strip.show(tabs.map { t in
      let title = t.title.isEmpty ? (URL(string: t.url)?.host ?? (t.url.isEmpty || t.url == "about:blank" ? "New Tab" : t.url)) : t.title
      return TabStrip.Item(title: String(title.prefix(60)), active: t === activeTab, asleep: !t.isLive)
    })
    layout()
  }

  /// A background tab nothing is using: no command running on it or waiting
  /// for it, not loading, not borrowed, and untouched since `cutoff`.
  private func isIdle(_ t: Tab, since cutoff: Date) -> Bool {
    t.isLive && !t.isActive && t.busy == 0 && t.lastUsed < cutoff && !t.isLoading && t.loadWaiters.isEmpty
      && borrow?.to !== t && tabs.contains { $0 === t }
  }

  /// Puts background tabs nobody has used for `minutes` to sleep, each one
  /// only if its engine says nothing would be lost. A tab that is kept says
  /// why in `unloadBlocked`.
  func sleepIdleTabs(olderThan minutes: Double) {
    let cutoff = Date().addingTimeInterval(-minutes * 60)
    for t in tabs where isIdle(t, since: cutoff) {
      guard let engine = t.live else { continue }
      var answered = false
      let decide = { [weak self, weak t] (reason: String?) in
        guard !answered else { return }
        answered = true
        guard let self, let t else { return }
        if let reason { t.unloadBlocked = reason; return }
        guard self.isIdle(t, since: cutoff) else { return }
        t.unloadBlocked = nil
        t.sleep()
        self.refreshStrip()
      }
      engine.unloadBlocker(decide)
      // No answer keeps the tab: better loaded than wrongly unloaded.
      DispatchQueue.main.asyncAfter(deadline: .now() + 10) { decide("the page didn't answer whether it could be unloaded") }
    }
  }

  /// What session restore keeps for this pane.
  var savedState: (active: Int, counter: Int, tabs: [[String: String]]) {
    (tabs.firstIndex { $0 === activeTab } ?? 0, tabCounter, tabs.map { ["id": $0.id, "url": $0.url, "title": $0.title] })
  }

  func tabsInfo() -> [String: Any] {
    ["id": id, "active": activeTab.id, "tabs": tabs.enumerated().map { i, t -> [String: Any] in
      ["id": t.id, "index": i + 1, "url": t.url, "title": t.title, "active": t === activeTab,
       "asleep": !t.isLive, "loading": t.isLoading,
       "unload_blocked": orNull(t.isLive && !t.isActive ? t.unloadBlocked : nil)]
    }]
  }

  // MARK: Layout and chrome

  /// Sets a frame only when it differs, so a call that changes nothing repaints nothing.
  private func place(_ v: NSView, _ r: NSRect) { if v.frame != r { v.frame = r } }

  func layout() {
    guard let root = window.contentView else { return }
    let b = root.bounds
    let h = Panel.barHeight
    let s = strip.isHidden ? 0 : Panel.stripHeight
    place(strip, NSRect(x: 0, y: b.height - s, width: b.width, height: s))
    place(bar, NSRect(x: 0, y: b.height - s - h, width: b.width, height: h))
    place(backButton, NSRect(x: 6, y: 4, width: 24, height: 22))
    place(forwardButton, NSRect(x: 30, y: 4, width: 24, height: 22))
    place(reloadButton, NSRect(x: 54, y: 4, width: 24, height: 22))
    place(urlField, NSRect(x: 84, y: 4, width: max(40, b.width - 92), height: 22))
    let page = NSRect(x: 0, y: 0, width: b.width, height: max(0, b.height - h - s))
    for t in tabs { if let v = t.live?.view { place(v, page) } }
  }

  func updateChrome() {
    guard let t = activeTab else { return }
    let back = t.live?.canGoBack ?? false, forward = t.live?.canGoForward ?? false
    if backButton.isEnabled != back { backButton.isEnabled = back }
    if forwardButton.isEnabled != forward { forwardButton.isEnabled = forward }
    if window.firstResponder != urlField.currentEditor(), urlField.stringValue != t.url {
      urlField.stringValue = t.url
    }
    guard let title = (t.title.isEmpty ? URL(string: t.url)?.host : t.title), !title.isEmpty else { return }
    let label = String(title.prefix(80))
    if label != lastLabel {
      lastLabel = label
      Rex.setLabel(block: id, session: session, label)
    }
  }

  func info() -> [String: Any] { activeTab.info() }

  static func normalize(_ raw: String) -> URL? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return nil }
    if s.contains("://") || s.hasPrefix("about:") || s.hasPrefix("data:") { return URL(string: s) }
    if s.hasPrefix("localhost") || s.hasPrefix("127.") || s.hasPrefix("[::1]") || s.range(of: #"^\d+$"#, options: .regularExpression) != nil {
      let hostPort = s.range(of: #"^\d+$"#, options: .regularExpression) != nil ? "localhost:\(s)" : s
      return URL(string: "http://" + hostPort)
    }
    if !s.contains(" ") && s.contains(".") { return URL(string: "https://" + s) }
    let q = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? s
    return URL(string: config.searchURL.replacingOccurrences(of: "%s", with: q))
  }

  func load(_ raw: String, done: ((String?) -> Void)? = nil) { activeTab.load(raw, done: done) }

  @objc func goBack() { engine.goBack() }
  @objc func goForward() { engine.goForward() }
  @objc func reload() { engine.reload(fromOrigin: false) }
  @objc func submitURL() {
    load(urlField.stringValue)
    engine.focus()
  }

  func focusURL() {
    window.makeFirstResponder(urlField)
    urlField.currentEditor()?.selectAll(nil)
  }

  func close() {
    borrow = nil
    tabs.forEach { $0.close() }
    window.orderOut(nil)
    window.close()
  }
}

enum ChromeCookies {
  static let root = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Google/Chrome")

  static func database(profile: String?) throws -> URL {
    let fm = FileManager.default
    let profiles = profile.map { [$0] } ?? ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
    var found: [(URL, Date)] = []
    for p in profiles {
      for name in ["Network/Cookies", "Cookies"] {
        let u = root.appendingPathComponent(p).appendingPathComponent(name)
        if let a = try? fm.attributesOfItem(atPath: u.path), let d = a[.modificationDate] as? Date { found.append((u, d)) }
      }
    }
    guard let newest = found.max(by: { $0.1 < $1.1 }) else {
      throw NSError(domain: "rexweb", code: 1, userInfo: [NSLocalizedDescriptionKey: "no Chrome cookies database found"])
    }
    return newest.0
  }

  static func key() throws -> Data {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-a", "Chrome", "-s", "Chrome Safe Storage", "-w"]
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    try p.run(); p.waitUntilExit()
    let secret = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard p.terminationStatus == 0, !secret.isEmpty else {
      throw NSError(domain: "rexweb", code: 2, userInfo: [NSLocalizedDescriptionKey: "couldn't read Chrome Safe Storage from the Keychain"])
    }
    var derived = Data(count: 16)
    let salt = Array("saltysalt".utf8)
    _ = derived.withUnsafeMutableBytes { d in
      CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), secret, secret.utf8.count, salt, salt.count,
                           CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, d.bindMemory(to: UInt8.self).baseAddress, 16)
    }
    return derived
  }

  static func decrypt(_ blob: Data, key: Data, integrityPrefix: Bool) -> String? {
    guard blob.count > 3, let tag = String(data: blob.prefix(3), encoding: .ascii), tag == "v10" || tag == "v20" else { return nil }
    let cipher = blob.dropFirst(3)
    var out = Data(count: cipher.count + kCCBlockSizeAES128)
    var moved = 0
    let iv = [UInt8](repeating: 0x20, count: 16)
    let outCount = out.count
    let status = out.withUnsafeMutableBytes { o in
      cipher.withUnsafeBytes { c in
        key.withUnsafeBytes { k in
          CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                  k.baseAddress, key.count, iv, c.baseAddress, cipher.count, o.baseAddress, outCount, &moved)
        }
      }
    }
    guard status == kCCSuccess else { return nil }
    var plain = out.prefix(moved)
    if integrityPrefix { plain = plain.dropFirst(32) }
    return String(data: plain, encoding: .utf8)
  }

  static func read(profile: String?, domains: [String]) throws -> (cookies: [HTTPCookie], skipped: Int) {
    let src = try database(profile: profile)
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rexweb-cookies-\(UUID().uuidString)")
    try FileManager.default.copyItem(at: src, to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    var db: OpaquePointer?
    guard sqlite3_open_v2(tmp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
      throw NSError(domain: "rexweb", code: 3, userInfo: [NSLocalizedDescriptionKey: "couldn't open Chrome's cookies database"])
    }
    defer { sqlite3_close(db) }
    func query(_ sql: String, _ row: (OpaquePointer) -> Void) {
      var st: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { return }
      while sqlite3_step(st) == SQLITE_ROW { row(st) }
      sqlite3_finalize(st)
    }
    var version = 0
    query("SELECT value FROM meta WHERE key = 'version'") { version = Int(String(cString: sqlite3_column_text($0, 0))) ?? 0 }
    let k = try key()
    let now = Date()
    var cookies: [HTTPCookie] = []
    var skipped = 0
    let wanted = domains.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
    query("SELECT host_key, name, path, is_secure, is_httponly, expires_utc, encrypted_value, samesite FROM cookies") { st in
      let host = String(cString: sqlite3_column_text(st, 0))
      let bare = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
      if !wanted.isEmpty && !wanted.contains(where: { bare == $0 || bare.hasSuffix("." + $0) }) { return }
      let len = Int(sqlite3_column_bytes(st, 6))
      guard len > 0, let ptr = sqlite3_column_blob(st, 6) else { return }
      guard let value = decrypt(Data(bytes: ptr, count: len), key: k, integrityPrefix: version >= 24) else { skipped += 1; return }
      let expiresUTC = sqlite3_column_int64(st, 5)
      var props: [HTTPCookiePropertyKey: Any] = [
        .domain: host, .name: String(cString: sqlite3_column_text(st, 1)), .value: value,
        .path: { let p = String(cString: sqlite3_column_text(st, 2)); return p.isEmpty ? "/" : p }(),
      ]
      if expiresUTC > 0 {
        let expires = Date(timeIntervalSince1970: Double(expiresUTC - 11_644_473_600_000_000) / 1e6)
        if expires < now { return }
        props[.expires] = expires
      }
      if sqlite3_column_int(st, 3) == 1 { props[.secure] = "TRUE" }
      if sqlite3_column_int(st, 4) == 1 { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
      switch sqlite3_column_int(st, 7) {
      case 0: props[.sameSitePolicy] = "none"
      case 1: props[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
      case 2: props[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue
      default: break
      }
      if let c = HTTPCookie(properties: props) { cookies.append(c) }
    }
    return (cookies, skipped)
  }
}

struct RexWindow { let number: Int; let name: String; let bounds: CGRect }

final class Tracker {
  var views: [String: [String: Any]] = [:]
  var displayed: [String: Bool] = [:]
  var grids: [String: Rex.Grid] = [:]
  var windowSession: [Int: String] = [:]
  var pendingPair: (Int, String)?
  var focusedSession: String?
  var refreshing = Set<String>()
  var dirty = Set<String>()
  var eventsProcess: Process?
  var rexWasActive = false
  var insets = RexChrome.read()

  func start() {
    Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
      self?.insets = RexChrome.read()
      Tracker.settingsSize = RexChrome.settingsSize()
      self?.learnWindows()
    }
    Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.refreshAll() }
    startEvents()
  }

  func startEvents() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: config.rexBin)
    p.arguments = ["events", "--all", "--json"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    out.fileHandleForReading.readabilityHandler = { [weak self] h in
      let d = h.availableData
      if d.isEmpty { return }
      DispatchQueue.main.async { self?.events(d) }
    }
    p.terminationHandler = { [weak self] _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.startEvents() }
    }
    do { try p.run(); eventsProcess = p } catch { log("events failed: \(error)") }
  }

  var eventBuffer = Data()
  var refreshScheduled = false

  /// Every `rex` command this app runs connects to the server and leaves
  /// again, and Rex reports both. Refreshing on those would run more
  /// commands, which report more events, without end.
  static let ownNoise: Set<String> = ["client_joined", "client_left", "client_connected", "client_disconnected"]

  static func changesLayout(_ line: Data) -> Bool {
    guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return true }
    let type = o["type"] as? String ?? ""
    if ownNoise.contains(type) { return false }
    if type == "session_event",
       let inner = ((o["payload"] as? [String: Any])?["event"] as? [String: Any])?["type"] as? String,
       ownNoise.contains(inner) { return false }
    return true
  }

  func events(_ d: Data) {
    eventBuffer.append(d)
    var relevant = false
    while let nl = eventBuffer.firstIndex(of: 10) {
      if Tracker.changesLayout(eventBuffer[eventBuffer.startIndex..<nl]) { relevant = true }
      eventBuffer.removeSubrange(eventBuffer.startIndex...nl)
    }
    if eventBuffer.count > 1 << 20 { eventBuffer.removeAll() }
    guard relevant, !refreshScheduled else { return }
    refreshScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      self?.refreshScheduled = false
      self?.refreshAll()
    }
  }

  func refreshAll() {
    for s in Set(App.shared.panels.values.map(\.session)) { refresh(s) }
  }

  func refresh(_ session: String) {
    if refreshing.contains(session) { dirty.insert(session); return }
    refreshing.insert(session)
    let ids = App.shared.panels.values.filter { $0.session == session }.map(\.id)
    Rex.queue.async {
      let v = Rex.view(session)
      var shown: [String: Bool] = [:]
      var grids: [String: Rex.Grid] = [:]
      for id in ids {
        guard let sz = Rex.size(block: id, session: session) else { continue }
        shown[id] = sz.displayed
        if let g = sz.grid { grids[id] = g }
      }
      DispatchQueue.main.async {
        self.refreshing.remove(session)
        for (id, d) in shown { self.displayed[id] = d }
        for (id, g) in grids { self.grids[id] = g }
        if let v { self.views[session] = v; self.reconcile(session) }
        if self.dirty.remove(session) != nil { self.refresh(session) }
      }
    }
  }

  func reconcile(_ session: String) {
    guard let v = views[session] else { return }
    let ids = Set(Tracker.allBlockIDs(v))
    for p in App.shared.panels.values where p.session == session && !ids.contains(p.id) {
      log("pane \(p.id.suffix(6)) closed: Rex no longer has its block")
      App.shared.closePanel(p.id)
    }
  }

  static func allBlockIDs(_ v: [String: Any]) -> [String] {
    var out: [String] = []
    for w in v["windows"] as? [[String: Any]] ?? [] {
      for l in w["layers"] as? [[String: Any]] ?? [] {
        for b in l["blocks"] as? [[String: Any]] ?? [] { if let id = b["block_id"] as? String { out.append(id) } }
      }
    }
    return out
  }

  static var settingsSize = RexChrome.settingsSize()

  /// How far, in points, a pane's terminal may be from its place in a window
  /// and still count as being there. Width and height are added together. A
  /// true match is off by the terminal's padding and part of a cell, and by
  /// more for a moment while the window is being resized.
  static let looseFit = 300.0

  static func rexWindows() -> (rex: [RexWindow], order: [Int]) {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    var rex: [RexWindow] = []
    var order: [Int] = []
    for w in list {
      guard let n = w[kCGWindowNumber as String] as? Int else { continue }
      order.append(n)
      let owner = w[kCGWindowOwnerName as String] as? String ?? ""
      let layer = w[kCGWindowLayer as String] as? Int ?? 0
      guard layer == 0, owner == "Rex" || owner.hasPrefix("Rex ") else { continue }
      guard let bd = w[kCGWindowBounds as String] as? NSDictionary,
            let r = CGRect(dictionaryRepresentation: bd), r.width > 200, r.height > 200 else { continue }
      guard onScreenFraction(r) >= 0.5 else { continue }
      // Rex's Settings window is a big Rex window too, and nothing in the
      // window list tells it from one that holds panes. Its saved size does.
      if let s = settingsSize, abs(r.width - s.width) < 1, abs(r.height - s.height) < 1 { continue }
      let name = w[kCGWindowName as String] as? String ?? ""
      if let twin = rex.firstIndex(where: { $0.bounds == r }) {
        if rex[twin].name.isEmpty { rex[twin] = RexWindow(number: rex[twin].number, name: name, bounds: r) }
        continue
      }
      rex.append(RexWindow(number: n, name: name, bounds: r))
    }
    return (rex, order)
  }

  static func onScreenFraction(_ r: CGRect) -> Double {
    var count: UInt32 = 0
    var displays = [CGDirectDisplayID](repeating: 0, count: 16)
    guard CGGetActiveDisplayList(16, &displays, &count) == .success, count > 0 else { return 1 }
    var area = 0.0
    for d in displays.prefix(Int(count)) {
      let shared = CGDisplayBounds(d).intersection(r)
      if !shared.isNull { area += Double(shared.width * shared.height) }
    }
    return area / Double(r.width * r.height)
  }

  static func placement(of id: String, in view: [String: Any]) -> (rect: CGRect, floating: Bool)? {
    guard let active = view["active_window_id"] as? String,
          let windows = view["windows"] as? [[String: Any]],
          let win = windows.first(where: { w in
            (w["layers"] as? [[String: Any]] ?? []).contains { l in
              (l["blocks"] as? [[String: Any]] ?? []).contains { $0["block_id"] as? String == id }
            }
          }),
          win["window_id"] as? String == active else { return nil }
    if let z = win["zoomed_block_id"] as? String, !z.isEmpty {
      return z == id ? (CGRect(x: 0, y: 0, width: 1, height: 1), false) : nil
    }
    for l in win["layers"] as? [[String: Any]] ?? [] {
      if let r = find(id, in: l["layout"]) {
        if l["kind"] as? String == "tiled" { return (r, false) }
        if (l["state"] as? String) == "minimized" { return nil }
        return (r, true)
      }
    }
    return nil
  }

  static func rect(_ any: Any?) -> CGRect? {
    guard let a = any as? [NSNumber], a.count == 4 else { return nil }
    return CGRect(x: a[0].doubleValue, y: a[1].doubleValue, width: a[2].doubleValue, height: a[3].doubleValue)
  }

  static func find(_ id: String, in node: Any?) -> CGRect? {
    if let d = node as? [String: Any] {
      if d["block_id"] as? String == id { return rect(d["rect"]) }
      for (_, v) in d { if let r = find(id, in: v) { return r } }
    } else if let a = node as? [Any] {
      for v in a { if let r = find(id, in: v) { return r } }
    }
    return nil
  }

  static func focused(in view: [String: Any]) -> String? {
    guard let active = view["active_window_id"] as? String,
          let w = (view["windows"] as? [[String: Any]])?.first(where: { $0["window_id"] as? String == active }) else { return nil }
    return w["focused_block_id"] as? String
  }

  var lastChange = Date()
  var lastRestackBoost = Date.distantPast
  var ticks = 0

  /// Runs 60 times a second while panes are moving, and 10 times a second
  /// once nothing has changed for a second: listing every window on screen is
  /// the expensive part, and an idle pane doesn't need it that often.
  func tick() {
    let panels = App.shared.panels.values
    if panels.isEmpty { return }
    ticks += 1
    if Date().timeIntervalSince(lastChange) > 1, ticks % 6 != 0 { return }
    let (rexWins, order) = Tracker.rexWindows()
    let rexActive = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.hasPrefix("com.superlogical.rex") == true
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0

    for p in panels {
      guard displayed[p.id] == true, let v = views[p.session], let place = Tracker.placement(of: p.id, in: v) else { hide(p); continue }
      let ins = insets
      let frac = place.rect
      guard let rw = window(for: p, place, v, rexWins, primaryHeight) else { hide(p); continue }

      let key = "\(frac) \(place.floating) \(ins) \(rw.number)"
      if key != p.layoutKey {
        // A floating pane's first placement is where it stays, so it needs
        // only a moment; anything else waits for Rex to finish moving panes.
        let settle = p.layoutKey.isEmpty && place.floating ? 0.05 : 0.4
        p.layoutKey = key
        lastChange = Date()
        p.settleUntil = Date().addingTimeInterval(settle)
        if p.window.isKeyWindow { p.pendingFocus = true }
      }
      if Date() < p.settleUntil { hide(p); continue }
      let (body, radius) = Tracker.body(frac, floating: place.floating, in: rw.bounds, ins)
      if let l = p.window.contentView?.layer, l.cornerRadius != CGFloat(radius) { l.cornerRadius = CGFloat(radius) }
      guard body.width > 20, body.height > 20 else { hide(p); continue }
      let x0 = (body.minX).rounded(.up), x1 = (body.maxX).rounded(.down)
      let y0 = (body.minY).rounded(.up), y1 = (body.maxY).rounded(.down)
      let ns = NSRect(x: x0, y: primaryHeight - y1, width: x1 - x0, height: y1 - y0)
      if ns != p.lastFrame { p.window.setFrame(ns, display: true); p.lastFrame = ns; lastChange = Date() }

      let mine = p.window.windowNumber
      let iMine = order.firstIndex(of: mine), iRex = order.firstIndex(of: rw.number)
      let ours = Set(App.shared.panels.values.map { $0.window.windowNumber })
      var stacked = false
      if let iMine, let iRex, iMine < iRex {
        stacked = order[(iMine + 1)..<iRex].allSatisfy { ours.contains($0) }
      }
      // Restacking alone doesn't keep the fast rate going: with the screen
      // locked the overlay never appears in the window list, so it would
      // restack on every tick forever.
      if !p.visible { lastChange = Date() }
      if !p.visible || !stacked {
        p.window.order(.above, relativeTo: rw.number)
        // Follow a restack at the fast rate for a fifth of a second, at most
        // once every two seconds.
        if Date().timeIntervalSince(lastRestackBoost) > 2 {
          lastRestackBoost = Date()
          lastChange = max(lastChange, Date().addingTimeInterval(-0.8))
        }
      }
      p.visible = true
      if p.pendingFocus {
        p.pendingFocus = false
        App.shared.focus(p)
      }

      let isFocused = Tracker.focused(in: v) == p.id
      if isFocused && !p.focusedInRex && rexActive {
        App.shared.focus(p)
      }
      p.focusedInRex = isFocused
    }
    rexWasActive = rexActive
  }

  func learnWindows() {
    let wins = Tracker.rexWindows().rex
    let live = Set(wins.map(\.number))
    windowSession = windowSession.filter { live.contains($0.key) }
    focusedSession = (RexChrome.value("lastFocusedSession") as? Data)
      .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["sessionID"] as? String
    let rexActive = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.hasPrefix("com.superlogical.rex") == true
    guard rexActive, let front = wins.first, let session = focusedSession else { pendingPair = nil; return }
    if let p = pendingPair, p.0 == front.number, p.1 == session {
      windowSession = windowSession.filter { $0.value != session }
      windowSession[front.number] = session
    }
    pendingPair = (front.number, session)
  }

  func window(for p: Panel, _ place: (rect: CGRect, floating: Bool), _ v: [String: Any], _ rexWins: [RexWindow], _ primaryHeight: CGFloat) -> RexWindow? {
    let label = v["label"] as? String ?? ""
    if let w = rexWins.first(where: { !$0.name.isEmpty && ($0.name == label || $0.name.hasSuffix(" - \(label)")) }) { return w }
    if let w = rexWins.first(where: { windowSession[$0.number] == p.session }) { return w }
    guard p.session == focusedSession else { return nil }
    let free = rexWins.filter { windowSession[$0.number] == nil }
    guard let g = grids[p.id] else { return free.count == 1 ? free[0] : nil }
    // A lone unclaimed window is only a guess. Take it if the pane's terminal
    // is about the size of the place the pane would have there. A Rex window
    // that holds no panes, such as a dialog, fails that.
    if free.count == 1 { return score(free[0]) < Tracker.looseFit ? free[0] : nil }
    guard free.count > 1 else { return nil }
    let ranked = free.map { ($0, score($0)) }.sorted { $0.1 < $1.1 }
    return ranked[1].1 - ranked[0].1 > 2 ? ranked[0].0 : nil
    func score(_ w: RexWindow) -> Double {
      let body = Tracker.body(place.rect, floating: place.floating, in: w.bounds, insets).body
      let s = Tracker.scale(at: w.bounds, primaryHeight: primaryHeight)
      return abs(body.width - g.columns * g.cellWidth / s) + abs(body.height - g.rows * g.cellHeight / s)
    }
  }

  static func body(_ frac: CGRect, floating: Bool, in b: CGRect, _ ins: Insets) -> (body: CGRect, radius: Double) {
    let area = floating
      ? CGRect(x: b.minX + ins.floatLeft, y: b.minY + ins.floatTop,
               width: b.width - ins.floatLeft - ins.floatRight, height: b.height - ins.floatTop)
      : CGRect(x: b.minX + ins.left, y: b.minY + ins.top,
               width: b.width - ins.left - ins.right, height: b.height - ins.top - ins.bottom)
    var card = CGRect(x: area.minX + frac.minX * area.width, y: area.minY + frac.minY * area.height,
                      width: frac.width * area.width, height: frac.height * area.height)
    var header = ins.header, radius = ins.radius
    if floating {
      card = card.insetBy(dx: 2, dy: 2)
      header = ins.floatHeader; radius = 10
    } else {
      let g = ins.gap / 2, eps = 0.001
      if frac.minX > eps { card.origin.x += g; card.size.width -= g }
      if frac.maxX < 1 - eps { card.size.width -= g }
      if frac.minY > eps { card.origin.y += g; card.size.height -= g }
      if frac.maxY < 1 - eps { card.size.height -= g }
    }
    return (CGRect(x: card.minX, y: card.minY + header, width: card.width, height: card.height - header), radius)
  }

  static func scale(at r: CGRect, primaryHeight: CGFloat) -> Double {
    let center = NSPoint(x: r.midX, y: primaryHeight - r.midY)
    return Double(NSScreen.screens.first { $0.frame.contains(center) }?.backingScaleFactor ?? 2)
  }

  func hide(_ p: Panel) {
    if p.visible { p.window.orderOut(nil); p.visible = false; lastChange = Date() }
  }
}

final class Server {
  var listener: NWListener!

  static func refuse(method: String, path: String, headers: [String: String]) -> (Int, String)? {
    if headers["origin"] != nil || headers["sec-fetch-site"] != nil || headers["sec-fetch-mode"] != nil {
      return (403, "rexweb doesn't accept requests from web pages")
    }
    let host = headers["host"] ?? ""
    guard host == "127.0.0.1:\(config.port)" || host == "localhost:\(config.port)" else {
      return (403, "rexweb only accepts requests to 127.0.0.1:\(config.port)")
    }
    guard method == "POST" else { return (405, "use POST") }
    let route = path.split(separator: "?").first.map(String.init) ?? path
    if route == "/health" { return nil }
    guard Auth.matches(headers["x-rexweb-token"]) else {
      return (401, "missing or wrong token; send the contents of ~/.rexweb/token in an x-rexweb-token header")
    }
    return nil
  }

  func start() {
    do {
      let params = NWParameters.tcp
      params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(config.port))!)
      params.allowLocalEndpointReuse = true
      listener = try NWListener(using: params)
    } catch { log("listen failed: \(error)"); exit(1) }
    listener.newConnectionHandler = { conn in
      conn.start(queue: .main)
      self.read(conn, Data())
    }
    listener.stateUpdateHandler = { st in
      if case .failed(let e) = st { log("listener failed: \(e)"); exit(1) }
    }
    listener.start(queue: .main)
  }

  func read(_ conn: NWConnection, _ sofar: Data) {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 22) { data, _, done, _ in
      var buf = sofar
      if let data { buf.append(data) }
      guard let split = buf.range(of: Data("\r\n\r\n".utf8)) else {
        return done ? conn.cancel() : self.read(conn, buf)
      }
      let head = String(decoding: buf[..<split.lowerBound], as: UTF8.self)
      let lines = head.split(separator: "\r\n")
      var headers: [String: String] = [:]
      for line in lines.dropFirst() {
        guard let c = line.firstIndex(of: ":") else { continue }
        headers[line[..<c].lowercased()] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
      }
      let length = Int(headers["content-length"] ?? "") ?? 0
      let body = buf[split.upperBound...]
      if body.count < length && !done { return self.read(conn, buf) }
      let request = lines.first?.split(separator: " ") ?? []
      let method = request.first.map(String.init) ?? ""
      let path = request.dropFirst().first.map(String.init) ?? "/"
      let respond = { (status: Int, out: Any) in
        let bytes = (try? JSONSerialization.data(withJSONObject: out, options: [.fragmentsAllowed])) ?? Data("{}".utf8)
        let top = "HTTP/1.1 \(status) X\r\ncontent-type: application/json\r\ncontent-length: \(bytes.count)\r\nconnection: close\r\n\r\n"
        conn.send(content: Data(top.utf8) + bytes, completion: .contentProcessed { _ in conn.cancel() })
      }
      if let refusal = Server.refuse(method: method, path: path, headers: headers) { return respond(refusal.0, ["error": refusal.1]) }
      let input = (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any] ?? [:]
      App.shared.handle(path: path, input: input, reply: respond)
    }
  }
}

enum JS {
  static let snapshot = #"""
  const max = args.max || 400;
  const sel = 'a[href],button,input,textarea,select,summary,[role=button],[role=link],[role=checkbox],[role=tab],[role=menuitem],[role=option],[role=switch],[contenteditable=""],[contenteditable=true],[onclick],[tabindex]:not([tabindex="-1"])';
  const vis = el => { const r = el.getBoundingClientRect(); const s = getComputedStyle(el);
    return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none'; };
  const name = el => (el.getAttribute('aria-label') || el.labels?.[0]?.innerText || el.innerText || el.value ||
    el.getAttribute('placeholder') || el.getAttribute('title') || el.getAttribute('alt') || el.getAttribute('name') || '')
    .replace(/\s+/g, ' ').trim().slice(0, 80);
  document.querySelectorAll('[data-rexweb-ref]').forEach(e => e.removeAttribute('data-rexweb-ref'));
  const lines = []; let n = 0;
  for (const el of document.querySelectorAll(sel)) {
    if (n >= max || !vis(el)) continue;
    const ref = 'e' + (++n); el.setAttribute('data-rexweb-ref', ref);
    const tag = el.tagName.toLowerCase();
    const role = el.getAttribute('role') || (tag === 'a' ? 'link' : tag === 'input' ? (el.type || 'text') : tag);
    let extra = '';
    if (tag === 'a') extra = ' -> ' + el.getAttribute('href');
    if ('checked' in el && (el.type === 'checkbox' || el.type === 'radio')) extra += el.checked ? ' [checked]' : ' [ ]';
    if ((tag === 'textarea' || (tag === 'input' && !['checkbox','radio','password','hidden','submit','button'].includes(el.type))) && el.value) extra += ' value=' + JSON.stringify(el.value.slice(0, 60));
    if (el.disabled) extra += ' [disabled]';
    lines.push(`[${ref}] ${role} "${name(el)}"${extra}`);
  }
  const text = (document.body?.innerText || '').replace(/\n{3,}/g, '\n\n').slice(0, args.textMax || 6000);
  return { url: location.href, title: document.title, elements: lines.join('\n'), text };
  """#

  static let resolve = #"""
  const t = args.target;
  const el = /^@?e\d+$/.test(t) ? document.querySelector(`[data-rexweb-ref="${t.replace('@','')}"]`) : document.querySelector(t);
  if (!el) return { error: 'no element for ' + t + ' (run snapshot first for e-refs)' };
  el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
  const r = el.getBoundingClientRect();
  return { x: r.left + r.width / 2, y: r.top + r.height / 2, tag: el.tagName.toLowerCase() };
  """#

  static let fill = #"""
  const t = args.target;
  let el = t ? (/^@?e\d+$/.test(t) ? document.querySelector(`[data-rexweb-ref="${t.replace('@','')}"]`) : document.querySelector(t)) : document.activeElement;
  if (!el) return { error: 'no element for ' + t };
  el.focus();
  if (el.isContentEditable) {
    const range = document.createRange();
    range.selectNodeContents(el);
    const sel = window.getSelection();
    sel.removeAllRanges(); sel.addRange(range);
    if (args.clear) { document.execCommand('delete'); } else { sel.collapseToEnd(); }
    return { native: true };
  } else {
    const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : el instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
    const set = Object.getOwnPropertyDescriptor(proto, 'value').set;
    set.call(el, (args.clear ? '' : el.value) + args.text);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }
  if (args.submit) {
    const f = el.form; if (f) { f.requestSubmit ? f.requestSubmit() : f.submit(); }
    else el.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true }));
  }
  return { ok: true };
  """#

  static func evaluate(_ code: String, asExpression: Bool) -> String {
    let body = asExpression ? "return (\n\(code)\n);" : code
    return """
    const __v = await (async () => { \(body) })();
    try { return JSON.parse(JSON.stringify(__v === undefined ? null : __v)); } catch (e) { return String(__v); }
    """
  }

  static let consoleHook = #"""
  (() => {
    const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.rexwebConsole;
    if (!handler) return;
    const post = handler.postMessage.bind(handler);
    const send = (level, text, source) => {
      try { post({ level, text: String(text).slice(0, 8000), url: location.href, source: source || '' }); } catch (e) {}
    };
    const fmt = v => {
      if (typeof v === 'string') return v;
      if (v === undefined) return 'undefined';
      if (v === null) return 'null';
      if (typeof v === 'function') return '[function ' + (v.name || 'anonymous') + ']';
      if (typeof v === 'symbol' || typeof v === 'bigint') return v.toString();
      if (v instanceof Error) {
        const head = (v.name || 'Error') + ': ' + v.message;
        return v.stack ? head + '\n' + String(v.stack).split('\n').map(l => '    at ' + l).join('\n') : head;
      }
      if (typeof Node !== 'undefined' && v instanceof Node) {
        return v.nodeType === 1 ? v.cloneNode(false).outerHTML.slice(0, 300) : v.nodeName;
      }
      if (typeof v === 'object') {
        try {
          const seen = new WeakSet();
          const out = JSON.stringify(v, (k, x) => {
            if (typeof x === 'object' && x !== null) { if (seen.has(x)) return '[circular]'; seen.add(x); }
            if (typeof x === 'bigint') return x.toString();
            if (typeof x === 'function') return '[function]';
            return x;
          });
          if (out !== undefined) return out;
        } catch (e) {}
      }
      try { return String(v); } catch (e) { return '[unprintable]'; }
    };
    for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
      const original = console[level];
      console[level] = function (...args) {
        send(level, args.map(fmt).join(' '));
        return original.apply(this, args);
      };
    }
    addEventListener('error', e => {
      const t = e.target;
      if (t && t !== window && t.tagName) {
        send('error', 'Failed to load <' + t.tagName.toLowerCase() + '> ' + (t.currentSrc || t.src || t.href || ''));
      } else {
        send('error', 'Uncaught ' + (e.error ? fmt(e.error) : e.message), e.filename ? e.filename + ':' + e.lineno + ':' + e.colno : '');
      }
    }, true);
    addEventListener('unhandledrejection', e => send('error', 'Unhandled promise rejection: ' + fmt(e.reason)));
    document.addEventListener('securitypolicyviolation', e => {
      send('error', 'Blocked by Content Security Policy (' + e.violatedDirective + '): ' + (e.blockedURI || 'inline'), e.sourceFile ? e.sourceFile + ':' + e.lineNumber : '');
    });
  })();
  """#

  /// What an engine's `unloadBlocker` asks the page. It answers with the reason to keep
  /// the page, or an empty string. A video that plays without sound doesn't
  /// count; a field counts once it holds something other than what the page
  /// put there.
  static let unloadProbe = #"""
  const sounding = m => !m.paused && !m.ended && !m.muted && m.volume > 0;
  if ([...document.querySelectorAll('video,audio')].some(sounding)) return 'it is playing audio or video';
  if (window.onbeforeunload) return 'the page asks before it is left';
  const skip = ['hidden', 'submit', 'button', 'reset', 'image'];
  const changed = e => {
    if (e.disabled) return false;
    if (e instanceof HTMLSelectElement) {
      const o = [...e.options];
      return o.some(x => x.defaultSelected) ? o.some(x => x.selected !== x.defaultSelected) : (!e.multiple && e.selectedIndex > 0) || (e.multiple && e.selectedIndex >= 0);
    }
    if (e instanceof HTMLTextAreaElement) return e.value !== e.defaultValue;
    if (skip.includes(e.type)) return false;
    if (e.type === 'checkbox' || e.type === 'radio') return e.checked !== e.defaultChecked;
    if (e.type === 'file') return e.files.length > 0;
    return e.value !== e.defaultValue;
  };
  if ([...document.querySelectorAll('input,textarea,select')].some(changed)) return 'a form on it has input that would be lost';
  return '';
  """#

  static let exists = #"""
  if (args.selector) return !!document.querySelector(args.selector);
  if (args.text) return (document.body?.innerText || '').includes(args.text);
  return document.readyState === 'complete';
  """#
}

enum Links {
  static let fallbackFile = Config.dir.appendingPathComponent("fallback-browser")
  static let selfID = Bundle.main.bundleIdentifier ?? "dev.coey.rexweb"

  static var fallbackID: String {
    if !config.fallbackBrowser.isEmpty { return config.fallbackBrowser }
    if let saved = try? String(contentsOf: fallbackFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
       !saved.isEmpty { return saved }
    for id in ["com.google.Chrome", "com.apple.Safari"] where NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil {
      return id
    }
    return "com.apple.Safari"
  }

  static func forward(_ url: URL) {
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: fallbackID)
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
      log("no browser to pass \(url) to"); return
    }
    NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
  }

  static func frontRexSession() -> String? {
    guard let win = Tracker.rexWindows().rex.first else { return nil }
    guard let data = Rex.run(["ls", "--json"]),
          let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let sessions = o["sessions"] as? [[String: Any]] else { return nil }
    let match = sessions.filter { s in
      guard let l = s["label"] as? String, !l.isEmpty else { return false }
      return win.name == l || win.name.hasSuffix(" - \(l)")
    }.max { ($0["label"] as? String ?? "").count < ($1["label"] as? String ?? "").count }
    return match?["session_id"] as? String
  }

  static func openInRex(_ url: URL) {
    let pane = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/rexweb-pane").path
    Rex.queue.async {
      var args = config.linkTarget == "tab" ? ["run"] : ["split", "--split=right"]
      if let s = frontRexSession() { args += ["-s", s] }
      args += ["--shell=none", "--label", "browser", "--", "env", "REXWEB_FOCUS=true", "REXWEB_ENGINE=\(config.defaultEngine)", pane, url.absoluteString]
      if Rex.run(args) == nil { DispatchQueue.main.async { forward(url) } }
    }
  }

  static func makeDefault(_ on: Bool, done: @escaping (String?) -> Void) {
    let probe = URL(string: "https://example.com")!
    let target: URL
    if on {
      if let current = NSWorkspace.shared.urlForApplication(toOpen: probe),
         let id = Bundle(url: current)?.bundleIdentifier, id != selfID {
        try? id.write(to: fallbackFile, atomically: true, encoding: .utf8)
      }
      target = Bundle.main.bundleURL
    } else {
      guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: fallbackID) else { return done("no browser to restore") }
      target = app
    }
    let wanted = Bundle(url: target)?.bundleIdentifier
    let check = { (err: Error?) in
      DispatchQueue.main.async {
        let now = ["http", "https"].map { NSWorkspace.shared.urlForApplication(toOpen: URL(string: "\($0)://example.com")!).flatMap { Bundle(url: $0)?.bundleIdentifier } }
        done(now.allSatisfy { $0 == wanted } ? nil : (err?.localizedDescription ?? "macOS didn't change the default browser"))
      }
    }
    NSWorkspace.shared.setDefaultApplication(at: target, toOpenURLsWithScheme: "http") { _ in
      NSWorkspace.shared.setDefaultApplication(at: target, toOpenURLsWithScheme: "https") { check($0) }
    }
  }
}

final class App: NSObject, NSApplicationDelegate {
  static let shared = App()
  var panels: [String: Panel] = [:]
  let tracker = Tracker()
  let server = Server()

  func applicationWillFinishLaunching(_ n: Notification) {
    NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_:reply:)),
                                                 forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
  }

  @objc func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
    guard let raw = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: raw) else { return }
    let pid = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value ?? 0
    let sender = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
    log("link from \(sender.isEmpty ? "pid \(pid)" : sender)")
    if sender.hasPrefix("com.superlogical.rex") { Links.openInRex(url) } else { Links.forward(url) }
  }

  func application(_ sender: NSApplication, open urls: [URL]) {
    urls.forEach { Links.openInRex($0) }
  }

  func applicationDidFinishLaunching(_ n: Notification) {
    try? FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true)
    _ = Auth.token
    Rex.checkVersion()
    if let e = config.configError { log(e) }
    buildMenu()
    server.start()
    tracker.start()
    startTabTimer()
    saveOnTerminate()
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.key(e) == true ? nil : e }
    log("listening on 127.0.0.1:\(config.port)")
  }

  func buildMenu() {
    let main = NSMenu()
    let appItem = NSMenuItem(); main.addItem(appItem)
    let appMenu = NSMenu(); appItem.submenu = appMenu
    // Cmd-Q in a browser pane means what it means in any other Rex pane: quit Rex.
    // Quitting this app instead would only blank every pane until the pane scripts restart it.
    appMenu.addItem(withTitle: "Quit Rex", action: #selector(quitRex(_:)), keyEquivalent: "q").target = self
    let editItem = NSMenuItem(); main.addItem(editItem)
    let edit = NSMenu(title: "Edit"); editItem.submenu = edit
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    NSApp.mainMenu = main
  }

  var keyPanel: Panel? { panels.values.first { $0.window.isKeyWindow } }

  func key(_ e: NSEvent) -> Bool {
    guard let p = keyPanel else { return false }
    let m = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let c = e.charactersIgnoringModifiers?.lowercased() ?? ""
    if m == .command {
      switch c {
      case "l": p.focusURL(); return true
      case "r": p.engine.reload(fromOrigin: false); return true
      case "[": p.engine.goBack(); return true
      case "]": p.engine.goForward(); return true
      case "=", "+": p.engine.zoom = min(3, p.engine.zoom + 0.1); return true
      case "-": p.engine.zoom = max(0.3, p.engine.zoom - 0.1); return true
      case "0": p.engine.zoom = 1; return true
      case "t": p.newTabFromUI(); return true
      case "w": p.closeTab(p.activeTab); return true
      default: break
      }
    }
    // Tab is key code 48. Cmd-1 to Cmd-9 and Shift-Cmd-[ and ] are left to Rex.
    if e.keyCode == 48, m == .control { p.selectNext(1); return true }
    if e.keyCode == 48, m == [.control, .shift] { p.selectNext(-1); return true }
    if m == [.command, .shift], c == "r" { p.engine.reload(fromOrigin: true); return true }
    if m == [.command, .shift], c == "b" { openPane(beside: p.id, session: p.session, url: ""); return true }
    if m == [.control, .option] || m == [.control, .option, .function] || m == [.control, .option, .numericPad, .function] {
      let dir: String? = [123: "left", 124: "right", 125: "down", 126: "up"][Int(e.keyCode)]
      if let dir { returnToRex(p, focus: dir); return true }
    }
    if m == [.control, .option], c == "`" { returnToRex(p, focus: nil); return true }
    return false
  }

  func returnToRex(_ p: Panel, focus dir: String?) {
    p.focusedInRex = true
    activateRex()
    if let dir { Rex.async(["focus", "-s", p.session, "-b", p.id, dir]) }
  }

  var rexApp: NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.superlogical.rex").first
      ?? NSWorkspace.shared.runningApplications.first {
        $0.localizedName?.hasPrefix("Rex") == true && $0.localizedName?.hasPrefix("RexWeb") != true && $0.activationPolicy == .regular
      }
  }

  func activateRex() { _ = rexApp?.activate() }

  /// Asks Rex to quit, as Cmd-Q in Rex would. Rex comes forward first, so any
  /// question it asks before quitting is on screen.
  @objc func quitRex(_ sender: Any?) {
    guard let rex = rexApp else { return }
    rex.activate()
    rex.terminate()
  }

  func focus(_ p: Panel) {
    p.lastActive = Date()
    guard p.visible else { p.pendingFocus = true; return }
    NSApp.activate(ignoringOtherApps: true)
    p.window.makeKey()
    p.engine.focus()
    if p.focusURLWhenShown { p.focusURLWhenShown = false; p.focusURL() }
  }

  func closePanel(_ id: String) {
    guard let p = panels.removeValue(forKey: id) else { return }
    p.close()
  }

  func openPane(beside id: String, session: String, url: String) {
    let pane = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/rexweb-pane").path
    Rex.async(["split", "-s", session, "-b", id, "--split=right", "--shell=none", "--label", "browser",
               "--", "env", "REXWEB_FOCUS=true", "REXWEB_ENGINE=\(Engine.name)", pane, url])
  }

  // MARK: Saved tabs

  /// Each pane's tabs, by pane ID, as written to `tabs-<engine>.json`. It
  /// also holds panes that haven't registered again since the app started.
  lazy var savedTabs: [String: [String: Any]] = loadSavedTabs()
  var savedTabsDirty = false
  var saveScheduled = false
  static let savedTabsMaxAge = 30.0 * 86400

  var tabsFile: URL { Config.dir.appendingPathComponent("tabs-\(Engine.name).json") }

  func loadSavedTabs() -> [String: [String: Any]] {
    guard let data = try? Data(contentsOf: tabsFile),
          let o = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [:] }
    let cutoff = Date().timeIntervalSince1970 - App.savedTabsMaxAge
    let kept = o.filter { (($0.value["saved"] as? NSNumber)?.doubleValue ?? 0) > cutoff }
    if kept.count != o.count { savedTabsDirty = true }
    return kept
  }

  /// Writes the tab list about a second from now, however many changes arrive before then.
  func saveTabsSoon() {
    guard !saveScheduled else { return }
    saveScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
      self?.saveScheduled = false
      self?.saveTabs()
    }
  }

  /// Writes the file only when a pane's tabs differ from what it holds, or a
  /// pane's entry is a day old and needs its date renewed.
  func saveTabs() {
    let now = Date().timeIntervalSince1970
    for p in panels.values {
      let s = p.savedState
      if let old = savedTabs[p.id], (old["active"] as? NSNumber)?.intValue == s.active,
         (old["counter"] as? NSNumber)?.intValue == s.counter, (old["tabs"] as? [[String: String]]) == s.tabs,
         now - ((old["saved"] as? NSNumber)?.doubleValue ?? 0) < 86400 { continue }
      savedTabs[p.id] = ["active": s.active, "counter": s.counter, "saved": now, "tabs": s.tabs]
      savedTabsDirty = true
    }
    guard savedTabsDirty else { return }
    guard let data = try? JSONSerialization.data(withJSONObject: savedTabs, options: [.sortedKeys]) else { return }
    // The list names every page open, so it is never readable by others, not
    // even for a moment: written to a private file, then moved into place.
    let tmp = tabsFile.appendingPathExtension("new-\(ProcessInfo.processInfo.processIdentifier)")
    unlink(tmp.path)
    let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard fd >= 0 else { return log("couldn't save tabs: \(String(cString: strerror(errno)))") }
    let wrote = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    Darwin.close(fd)
    if wrote == data.count, rename(tmp.path, tabsFile.path) == 0 {
      savedTabsDirty = false
    } else {
      log("couldn't save tabs: \(String(cString: strerror(errno)))")
      unlink(tmp.path)
    }
  }

  func applicationWillTerminate(_ n: Notification) { saveTabs() }

  var termSignal: DispatchSourceSignal?

  /// The apps are usually stopped with `pkill`, which sends SIGTERM and would
  /// lose a tab change made in the last second. Save, then go.
  func saveOnTerminate() {
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    source.setEventHandler { [weak self] in
      self?.saveTabs()
      exit(0)
    }
    source.resume()
    termSignal = source
  }

  func forgetTabs(_ id: String) {
    if savedTabs.removeValue(forKey: id) != nil { savedTabsDirty = true; saveTabsSoon() }
  }

  /// Once a minute: unloads idle background tabs and keeps the saved tab list fresh.
  func startTabTimer() {
    Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      guard let self else { return }
      if config.tabUnloadMinutes > 0 {
        for p in self.panels.values { p.sleepIdleTabs(olderThan: config.tabUnloadMinutes) }
      }
      self.saveTabs()
    }
  }

  func resolve(_ raw: Any?) -> Panel? {
    let s = (raw as? String) ?? ""
    if s.isEmpty { return panels.values.max { $0.lastActive < $1.lastActive } }
    if let p = panels[s] { return p }
    let m = panels.values.filter { $0.id.hasSuffix(s) || $0.lastLabel.localizedCaseInsensitiveContains(s) }
    return m.count == 1 ? m[0] : nil
  }

  func js(_ t: Tab, _ body: String, _ args: [String: Any], _ done: @escaping (Any?, String?) -> Void) {
    t.engine.call(body, args, done)
  }

  /// Routes that wake a sleeping tab themselves and don't wait for its page.
  static let noWake: Set<String> = ["/nav", "/open", "/focus"]

  func handle(path: String, input: [String: Any], reply: @escaping (Int, Any) -> Void) {
    let ok = { (v: Any) in reply(200, v) }
    let fail = { (s: String) in reply(400, ["error": s]) }
    let route = path.split(separator: "?").first.map(String.init) ?? path

    switch route {
    case "/health":
      let wins = Tracker.rexWindows().rex
      return ok([
        "ok": true, "pid": ProcessInfo.processInfo.processIdentifier, "panels": panels.count,
        "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
        "engine": Engine.name, "port": config.port, "rex_bin": config.rexBin, "rex_version": orNull(Rex.version),
        "rex_windows": wins.count,
        "window_names": wins.isEmpty ? NSNull() as Any : wins.contains { !$0.name.isEmpty } as Any,
        "config_error": orNull(config.configError),
      ])
    case "/list":
      return ok(["panels": panels.values.sorted { $0.lastActive > $1.lastActive }.map { $0.info() }])
    case "/register":
      guard let id = input["id"] as? String, let session = input["session"] as? String else { return fail("id and session required") }
      if let p = panels[id] { return ok(p.info()) }
      // A pane that still has saved tabs is coming back after the app
      // restarted. Its tabs win over the address the pane script sends.
      let p = Panel(id: id, session: session, restore: savedTabs[id])
      panels[id] = p
      tracker.refresh(session)
      let url = p.restored ? p.activeTab.url : (input["url"] as? String ?? "")
      if !p.restored, !url.isEmpty { p.load(url) }
      log("pane \(id.suffix(6)) registered in session \(session.suffix(6)), \(p.restored ? "with \(p.tabs.count) saved tab(s)" : "url \(url.isEmpty ? "(none)" : String(url.prefix(200)))")")
      if input["focus"] as? Bool == true {
        p.focusURLWhenShown = url.isEmpty
        self.focus(p)
      }
      return ok(p.info())
    case "/close":
      guard let id = input["id"] as? String else { return fail("id required") }
      if panels[id] != nil { log("pane \(id.suffix(6)) closed by its pane script or the CLI") }
      closePanel(id)
      forgetTabs(id)
      return ok(["closed": id])
    case "/cookies":
      let list = input["cookies"] as? [[String: Any]] ?? []
      var n = 0
      var made: [HTTPCookie] = []
      for item in list {
        var props: [HTTPCookiePropertyKey: Any] = [.name: item["name"] as? String ?? "", .value: item["value"] as? String ?? "",
                                                   .domain: item["domain"] as? String ?? "", .path: item["path"] as? String ?? "/"]
        if item["secure"] as? Bool == true { props[.secure] = "TRUE" }
        if let x = (item["expires"] as? NSNumber)?.doubleValue, x > 0 { props[.expires] = Date(timeIntervalSince1970: x) }
        if let c = HTTPCookie(properties: props) { made.append(c); n += 1 }
      }
      Engine.setCookies(made) { ok(["set": n]) }
      return
    case "/links":
      let current = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!).flatMap { Bundle(url: $0)?.bundleIdentifier } ?? ""
      return ok(["default": current, "on": current == Links.selfID, "fallback": Links.fallbackID])
    case "/default-browser":
      let on = input["on"] as? Bool ?? true
      Links.makeDefault(on) { err in
        err == nil ? ok(["default": on ? Links.selfID : Links.fallbackID, "fallback": Links.fallbackID]) : fail(err!)
      }
      return
    case "/cookies/import":
      let domains = input["domains"] as? [String] ?? []
      let profile = input["profile"] as? String
      Rex.queue.async {
        do {
          let (cookies, skipped) = try ChromeCookies.read(profile: profile, domains: domains)
          DispatchQueue.main.async {
            Engine.setCookies(cookies) {
              var reloadIDs: [String] = []
              if input["reload"] as? Bool == true {
                // Every live tab, not only the one on show. Sleeping tabs pick the cookies up when they wake.
                for p in self.panels.values {
                  for t in p.tabs { t.live?.reload(fromOrigin: false) }
                  reloadIDs.append(p.id)
                }
              }
              ok(["imported": cookies.count, "skipped": skipped, "reloaded": reloadIDs])
            }
          }
        } catch {
          DispatchQueue.main.async { fail(error.localizedDescription) }
        }
      }
      return
    default: break
    }

    guard let p = resolve(input["id"]) else {
      return fail(panels.isEmpty ? "no browser panes; open one with `rexweb open URL`" : "no single pane matches \(input["id"] ?? "")")
    }
    guard let t = p.tab(input["tab"]) else {
      return fail("no tab \(input["tab"] ?? "") in this pane. Use a tab ID such as t1, or a position from 1 to \(p.tabs.count)")
    }
    if route != "/info" { p.lastActive = Date(); t.lastUsed = Date(); t.unloadBlocked = nil }

    switch route {
    case "/tabs":
      return ok(p.tabsInfo())
    case "/tab/new":
      let url = input["url"] as? String ?? ""
      if !url.isEmpty, Panel.normalize(url) == nil { return fail("bad url") }
      let made = p.newTab(url: url, foreground: input["background"] as? Bool != true)
      return ok(made.info())
    case "/tab/select":
      guard input["tab"] != nil else { return fail("tab required: a tab ID such as t1, or a position counted from 1") }
      p.select(t)
      return ok(t.info())
    case "/tab/close":
      let last = p.tabs.count == 1
      p.closeTab(t)
      return ok(["id": p.id, "closed": t.id, "pane_closed": last, "tabs": last ? 0 : p.tabs.count,
                 "active": last ? NSNull() as Any : p.activeTab.id as Any])
    case "/info", "/console":
      return run(route, p, t, input, reply)
    default: break
    }

    // The command counts as running on its tab until it has replied, which
    // keeps the tab from being unloaded under it.
    t.busy += 1
    var replied = false
    dispatch(route, p, t, input) { status, out in
      guard !replied else { return }
      replied = true
      t.busy -= 1
      t.lastUsed = Date()
      reply(status, out)
    }
  }

  /// How long a command waits for a sleeping tab to load before it gives up.
  /// It is shorter than the 30 seconds the CLI waits for an answer.
  static let wakeTimeout = 20.0

  /// Gets a pane and tab ready for a page command, then runs it. The pane
  /// and tab were resolved once, by `handle`; a step that has to wait comes
  /// back here with the same two, never by looking them up again.
  func dispatch(_ route: String, _ p: Panel, _ t: Tab, _ input: [String: Any], waited: Int = 0, _ reply: @escaping (Int, Any) -> Void) {
    let fail = { (s: String) in reply(400, ["error": s]) }
    guard panels[p.id] === p else { return fail("the pane was closed") }
    guard p.tabs.contains(where: { $0 === t }) else { return fail("the tab was closed") }

    if ["/click", "/type", "/press"].contains(route), !p.visible {
      if waited >= 12 {
        return fail("this pane isn't on screen, so it can't take clicks or typing. Show its Rex window and try again. eval, snapshot, and screenshot still work.")
      }
      return DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.dispatch(route, p, t, input, waited: waited + 1, reply) }
    }

    // A sleeping tab wakes and finishes loading before the command runs.
    // /loaded and /wait do their own waiting, with the caller's timeout.
    if !t.isLive, !App.noWake.contains(route) {
      _ = t.engine
      if route == "/loaded" || route == "/wait" { return run(route, p, t, input, reply) }
      var went = false
      t.waitForLoad { err in
        guard !went else { return }
        went = true
        if err == "closed" { return fail("the tab was closed") }
        // Waking reloaded the page already.
        if route == "/reload" { return reply(200, t.info()) }
        self.dispatch(route, p, t, input, reply)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + App.wakeTimeout) {
        guard !went else { return }
        went = true
        reply(408, ["error": "the tab was unloaded and is still loading after \(Int(App.wakeTimeout))s, so the command didn't run. Wait for it with `rexweb wait -t \(t.id)`, then try again.", "url": t.url])
      }
      return
    }

    guard Engine.needsVisible.contains(route), t !== p.activeTab || p.borrow?.to === t else { return run(route, p, t, input, reply) }

    // The command needs its tab's page drawing. One tab at a time is
    // borrowed, so wait out a borrow of another tab first.
    if p.borrowedByAnother(t) {
      if waited >= 300 { return fail("another command is still using this pane. Try again.") }
      return DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.dispatch(route, p, t, input, waited: waited + 1, reply) }
    }
    p.beginBorrow(t) { [weak p] token in
      var ended = false
      let end = {
        guard !ended else { return }
        ended = true
        p?.endBorrow(token)
      }
      // A command that never replies must not keep the page drawing for good.
      DispatchQueue.main.asyncAfter(deadline: .now() + 60) { end() }
      guard let p else { return }
      self.run(route, p, t, input) { status, out in reply(status, out); end() }
    }
  }

  /// Runs a page command on a live tab.
  func run(_ route: String, _ p: Panel, _ t: Tab, _ input: [String: Any], _ reply: @escaping (Int, Any) -> Void) {
    let ok = { (v: Any) in reply(200, v) }
    let fail = { (s: String) in reply(400, ["error": s]) }

    switch route {
    case "/info":
      ok(t.info())
    case "/loaded":
      var replied = false
      let timeout = (input["timeout"] as? NSNumber)?.doubleValue ?? 30
      DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
        if !replied { replied = true; reply(408, ["error": "the page was still loading after \(Int(timeout))s", "url": t.url]) }
      }
      t.waitForLoad { err in
        guard !replied else { return }
        replied = true
        err == nil ? ok(t.info()) : reply(502, ["error": err!, "url": t.url])
      }
    case "/nav", "/open":
      guard let url = input["url"] as? String else { return fail("url required") }
      t.load(url) { err in
        let e = err ?? t.refusedError
        e == nil ? ok(t.info()) : reply(502, ["error": e!, "url": url])
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        if !t.isLoading, let e = t.refusedError { t.finishWaiters(e) }
      }
    case "/back": t.engine.goBack(); t.waitForLoad { _ in ok(t.info()) }
    case "/forward": t.engine.goForward(); t.waitForLoad { _ in ok(t.info()) }
    case "/reload": t.engine.reload(fromOrigin: false); t.waitForLoad { _ in ok(t.info()) }
    case "/focus":
      p.select(t)
      focus(p)
      ok(t.info())
    case "/eval":
      let code = input["js"] as? String ?? ""
      t.probingUntil = Date().addingTimeInterval(5)
      js(t, JS.evaluate(code, asExpression: true), [:]) { v, e in
        t.probingUntil = Date().addingTimeInterval(0.3)
        guard let e else { return ok(["value": v ?? NSNull()]) }
        if !e.contains("SyntaxError") && !e.contains("Unexpected") { return fail(e) }
        self.js(t, JS.evaluate(code, asExpression: false), [:]) { v, e in e == nil ? ok(["value": v ?? NSNull()]) : fail(e!) }
      }
    case "/console":
      let since = (input["since"] as? NSNumber)?.intValue ?? 0
      let levels = Set(input["levels"] as? [String] ?? [])
      if let bad = levels.first(where: { !Panel.consoleLevels.contains($0) }) {
        return fail("unknown level \(bad): use \(Panel.consoleLevels.sorted().joined(separator: ", "))")
      }
      var messages = t.console.filter { ($0["seq"] as? Int ?? 0) > since && (levels.isEmpty || levels.contains($0["level"] as? String ?? "")) }
      if let limit = (input["limit"] as? NSNumber)?.intValue, limit > 0, messages.count > limit { messages = Array(messages.suffix(limit)) }
      let result: [String: Any] = ["messages": messages, "last": t.consoleSeq, "dropped": t.consoleDropped]
      if input["clear"] as? Bool == true { t.console = [] }
      ok(result)
    case "/snapshot":
      let args: [String: Any] = ["max": input["max"] ?? 400, "textMax": input["text_max"] ?? 6000]
      func attempt(_ left: Int) {
        js(t, JS.snapshot, args) { v, e in
          if let e { return fail(e) }
          if v == nil || v is NSNull, left > 0 {
            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { attempt(left - 1) }
          }
          guard let v, !(v is NSNull) else { return fail("the page changed while it was read. Run snapshot again.") }
          ok(v)
        }
      }
      attempt(10)
    case "/click":
      js(t, JS.resolve, ["target": input["target"] as? String ?? ""]) { v, e in
        guard e == nil, let d = v as? [String: Any] else { return fail(e ?? "resolve failed") }
        if let err = d["error"] as? String { return fail(err) }
        let x = (d["x"] as? NSNumber)?.doubleValue ?? 0, y = (d["y"] as? NSNumber)?.doubleValue ?? 0
        t.engine.click(x: x, y: y)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { t.waitForLoad { _ in ok(t.info()) } }
      }
    case "/type":
      js(t, JS.fill, ["target": input["target"] as? String ?? "", "text": input["text"] as? String ?? "",
                     "clear": input["clear"] as? Bool ?? false, "submit": input["submit"] as? Bool ?? false]) { v, e in
        guard e == nil else { return fail(e!) }
        if let d = v as? [String: Any], let err = d["error"] as? String { return fail(err) }
        if let d = v as? [String: Any], d["native"] as? Bool == true {
          t.engine.focus()
          t.engine.insertText(input["text"] as? String ?? "")
          if input["submit"] as? Bool == true { _ = t.engine.press("enter") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { t.waitForLoad { _ in ok(t.info()) } }
      }
    case "/press":
      guard let k = input["key"] as? String else { return fail("key required") }
      if t.engine.press(k) { ok(["pressed": k]) } else { fail("unknown key \(k)") }
    case "/shot":
      let path = (input["path"] as? String) ?? NSTemporaryDirectory() + "rexweb-\(p.id.suffix(6))-\(Int(Date().timeIntervalSince1970)).png"
      guard path.lowercased().hasSuffix(".png") else { return fail("screenshot path must end in .png") }
      t.engine.screenshot { png, err in
        guard let png, let rep = NSBitmapImageRep(data: png) else { return fail(err ?? "snapshot failed") }
        do { try png.write(to: URL(fileURLWithPath: path)); ok(["path": path, "width": rep.pixelsWide, "height": rep.pixelsHigh]) }
        catch { fail(error.localizedDescription) }
      }
    case "/wait":
      let deadline = Date().addingTimeInterval((input["timeout"] as? NSNumber)?.doubleValue ?? 15)
      let args: [String: Any] = ["selector": input["selector"] as? String ?? "", "text": input["text"] as? String ?? ""]
      func poll() {
        js(t, JS.exists, args) { v, _ in
          if v as? Bool == true { return ok(t.info()) }
          if Date() > deadline { return reply(408, ["error": "timed out"]) }
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
        }
      }
      t.waitForLoad { err in
        if let err { return reply(502, ["error": err, "url": t.url]) }
        poll()
      }
      // The load itself can outlast the timeout; the first reply wins.
      DispatchQueue.main.asyncAfter(deadline: .now() + deadline.timeIntervalSinceNow + 0.5) { reply(408, ["error": "timed out"]) }
    default:
      if Engine.route?(route, t, input, reply) == true { return }
      reply(404, ["error": "unknown route \(route)"])
    }
  }
}
