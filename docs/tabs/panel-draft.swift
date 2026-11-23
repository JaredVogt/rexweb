/// One page in a pane. A pane always has at least one tab, and shows one.
///
/// A tab is either live, with a page engine, or asleep: only its address and
/// title are kept. Tabs restored after a restart start asleep, and background
/// tabs left unused go to sleep to give their memory back. Reading `engine`
/// wakes a tab.
final class Tab {
  let id: String
  unowned let panel: Panel
  private(set) var live: PageEngine?
  var console: [[String: Any]] = []
  var consoleSeq = 0
  var consoleDropped = 0
  var loadWaiters: [(String?) -> Void] = []
  var lastError: String?
  var requested: URL?
  var lastUsed = Date()
  /// What a sleeping tab shows and reloads.
  var savedURL: String
  var savedTitle: String

  init(panel: Panel, id: String, url: String = "", title: String = "", asleep: Bool = false) {
    self.panel = panel
    self.id = id
    savedURL = url
    savedTitle = title
    if !asleep { live = Engine.make(self) }
  }

  var isLive: Bool { live != nil }
  var isActive: Bool { panel.activeTab === self }
  var visible: Bool { panel.visible && isActive }
  var url: String { live?.url?.absoluteString ?? savedURL }
  var title: String { live.map { $0.title } ?? savedTitle }
  var isLoading: Bool { live?.isLoading ?? false }

  /// The tab's page engine. Wakes the tab if it is asleep.
  var engine: PageEngine {
    if let live { return live }
    let made = Engine.make(self)
    live = made
    panel.attach(self)
    if !savedURL.isEmpty, let u = URL(string: savedURL) {
      requested = u
      made.load(u)
    }
    return made
  }

  /// Gives the page's memory back. The address, title and console log stay.
  func sleep() {
    guard let engine = live, !isActive else { return }
    savedURL = engine.url?.absoluteString ?? savedURL
    savedTitle = engine.title.isEmpty ? savedTitle : engine.title
    finishWaiters("the tab was unloaded")
    engine.view.removeFromSuperview()
    engine.close()
    live = nil
    record(level: "navigation", text: "Tab unloaded to save memory. It reloads when used.", url: savedURL)
  }

  func info() -> [String: Any] {
    ["id": panel.id, "session": panel.session, "url": url, "title": title,
     "loading": isLoading, "visible": panel.visible, "error": orNull(lastError), "engine": Engine.name, "label": panel.lastLabel,
     "active": panel.lastActive.timeIntervalSince1970,
     "tab": id, "tab_index": (panel.tabs.firstIndex { $0 === self } ?? 0) + 1, "tabs": panel.tabs.count,
     "tab_active": isActive, "tab_asleep": !isLive]
  }

  func load(_ raw: String, done: ((String?) -> Void)? = nil) {
    guard let url = Panel.normalize(raw) else { done?("bad url"); return }
    requested = url
    savedURL = url.absoluteString
    if let done { loadWaiters.append(done) }
    if let live { live.load(url) } else { _ = engine }
  }

  var refusedError: String? {
    guard let live, let req = requested, req.scheme != "about", live.url == nil || live.url?.absoluteString == "about:blank" else { return nil }
    return "\(Engine.label) didn't load \(req.absoluteString). Its port may be one \(Engine.label) blocks"
  }

  func waitForLoad(_ done: @escaping (String?) -> Void) {
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

  func engineChanged() { panel.tabChanged(self) }
  func engineStarted() { lastError = nil }
  func engineCommitted(_ url: String? = nil) {
    let u = url ?? live?.url?.absoluteString ?? ""
    record(level: "navigation", text: "Navigated to \(u)", url: u)
    panel.tabChanged(self)
  }
  func engineFinished() { lastError = nil; finishWaiters(nil); panel.tabChanged(self) }
  func engineFailed(_ message: String, url: String) {
    lastError = message
    record(level: "error", text: "Page failed to load: \(message)", url: url)
    finishWaiters(lastError)
  }
  func openBeside(_ url: String) { App.shared.openPane(beside: panel.id, session: panel.session, url: url) }
  func openTab(_ url: String, foreground: Bool) { panel.newTab(url: url, foreground: foreground, after: self) }

  func close() {
    finishWaiters("closed")
    live?.view.removeFromSuperview()
    live?.close()
    live = nil
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
    }
    items = new
    needsLayout = true
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

  @objc func close() { onClose() }
  override func mouseDown(with event: NSEvent) { onSelect() }
  override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 { onClose() } }
}

final class Panel: NSObject, NSTextFieldDelegate {
  let id: String
  let session: String
  private(set) var tabs: [Tab] = []
  private(set) var activeTab: Tab!
  private var tabCounter = 0

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

    let saved = (restore?["tabs"] as? [[String: Any]] ?? []).filter { !(($0["url"] as? String) ?? "").isEmpty }
    if saved.isEmpty {
      activeTab = makeTab()
    } else {
      let chosen = min(max(0, (restore?["active"] as? NSNumber)?.intValue ?? 0), saved.count - 1)
      for s in saved { _ = makeTab(url: s["url"] as? String ?? "", title: s["title"] as? String ?? "", asleep: true) }
      activeTab = tabs[chosen]
      _ = activeTab.engine
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
    updateChrome()
  }

  // MARK: Tabs

  private func makeTab(url: String = "", title: String = "", asleep: Bool = false, at index: Int? = nil) -> Tab {
    tabCounter += 1
    let t = Tab(panel: self, id: "t\(tabCounter)", url: url, title: title, asleep: asleep)
    tabs.insert(t, at: min(index ?? tabs.count, tabs.count))
    if t.isLive { attach(t) }
    return t
  }

  /// Puts a live tab's view in the pane, hidden unless the tab is on show.
  func attach(_ t: Tab) {
    guard let root = window.contentView, let view = t.live?.view else { return }
    view.isHidden = !(activeTab === t)
    if view.superview !== root { root.addSubview(view, positioned: .below, relativeTo: bar) }
    layout()
  }

  /// Finds a tab by its ID, such as t3, or by its position counted from 1. Nothing means the tab on show.
  func tab(_ raw: Any?) -> Tab? {
    let s = (raw as? String) ?? (raw as? NSNumber)?.stringValue ?? ""
    if s.isEmpty { return activeTab }
    if let t = tabs.first(where: { $0.id == s }) { return t }
    if let n = Int(s), n >= 1, n <= tabs.count { return tabs[n - 1] }
    return nil
  }

  @discardableResult
  func newTab(url: String, foreground: Bool, after: Tab? = nil) -> Tab {
    let index = after.flatMap { a in tabs.firstIndex { $0 === a } }.map { $0 + 1 }
    let t = makeTab(at: index)
    if !url.isEmpty { t.load(url) }
    if foreground { select(t) } else { tabsChanged() }
    return t
  }

  func newTabFromUI() {
    newTab(url: config.home, foreground: true)
    if config.home.isEmpty { focusURL() } else { engine.focus() }
  }

  func select(_ t: Tab) {
    guard tabs.contains(where: { $0 === t }) else { return }
    let hadKeyboard = window.isKeyWindow && window.firstResponder !== urlField.currentEditor()
    let old = activeTab
    activeTab = t
    t.lastUsed = Date()
    old?.lastUsed = Date()
    let view = t.engine.view
    if old !== t { old?.live?.view.isHidden = true }
    view.isHidden = false
    layout()
    if hadKeyboard, old !== t { t.engine.focus() }
    tabsChanged()
  }

  func selectNext(_ step: Int) {
    guard tabs.count > 1, let i = tabs.firstIndex(where: { $0 === activeTab }) else { return }
    select(tabs[(i + step + tabs.count) % tabs.count])
    engine.focus()
  }

  /// Closes a tab. Closing the last one closes the pane.
  func closeTab(_ t: Tab) {
    guard let i = tabs.firstIndex(where: { $0 === t }) else { return }
    if tabs.count == 1 { Rex.async(["block", "close", id]); return }
    tabs.remove(at: i)
    if activeTab === t {
      activeTab = tabs[min(i, tabs.count - 1)]
      let hadKeyboard = window.isKeyWindow
      t.close()
      activeTab.engine.view.isHidden = false
      layout()
      if hadKeyboard { activeTab.engine.focus() }
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
    let wasHidden = strip.isHidden
    strip.isHidden = tabs.count < 2
    strip.show(tabs.map { t in
      let title = t.title.isEmpty ? (URL(string: t.url)?.host ?? (t.url.isEmpty ? "New Tab" : t.url)) : t.title
      return TabStrip.Item(title: String(title.prefix(60)), active: t === activeTab, asleep: !t.isLive)
    })
    if wasHidden != strip.isHidden { layout() }
  }

  /// Puts background tabs nobody has used for `minutes` to sleep.
  func sleepIdleTabs(olderThan minutes: Double) {
    let cutoff = Date().addingTimeInterval(-minutes * 60)
    var slept = false
    for t in tabs where t.isLive && !t.isActive && t.lastUsed < cutoff && !t.isLoading && t.loadWaiters.isEmpty {
      t.sleep()
      slept = true
    }
    if slept { refreshStrip() }
  }

  var savedState: [String: Any] {
    ["active": tabs.firstIndex { $0 === activeTab } ?? 0, "saved": Date().timeIntervalSince1970,
     "tabs": tabs.map { ["url": $0.url, "title": $0.title] }]
  }

  // MARK: Layout and chrome

  func layout() {
    guard let root = window.contentView else { return }
    let b = root.bounds
    let h = Panel.barHeight
    let s = strip.isHidden ? 0 : Panel.stripHeight
    strip.frame = NSRect(x: 0, y: b.height - s, width: b.width, height: s)
    bar.frame = NSRect(x: 0, y: b.height - s - h, width: b.width, height: h)
    backButton.frame = NSRect(x: 6, y: 4, width: 24, height: 22)
    forwardButton.frame = NSRect(x: 30, y: 4, width: 24, height: 22)
    reloadButton.frame = NSRect(x: 54, y: 4, width: 24, height: 22)
    urlField.frame = NSRect(x: 84, y: 4, width: max(40, b.width - 92), height: 22)
    let page = NSRect(x: 0, y: 0, width: b.width, height: max(0, b.height - h - s))
    for t in tabs { t.live?.view.frame = page }
  }

  func updateChrome() {
    guard let t = activeTab else { return }
    backButton.isEnabled = t.live?.canGoBack ?? false
    forwardButton.isEnabled = t.live?.canGoForward ?? false
    if window.firstResponder != urlField.currentEditor() {
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
    tabs.forEach { $0.close() }
    window.orderOut(nil)
    window.close()
  }
}

