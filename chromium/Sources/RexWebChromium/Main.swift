import AppKit
import CefKit

@main
@MainActor
enum Main {
  static func main() {
    CefApplication.install()
    config.port = config.chromiumPort
    Engine.name = "chromium"
    Engine.label = "Chromium"
    Engine.make = { tab in onMain { ChromiumEngine(tab: tab) } }
    Engine.setCookies = { cookies, done in onMain { ChromiumEngine.setCookies(cookies, done) } }
    Engine.route = { route, tab, input, reply in
      onMain { (tab.engine as? ChromiumEngine)?.route(route, input, reply) ?? false }
    }
    // Chromium takes scripted clicks, keys and text, and captures the page,
    // on a tab that isn't on show, so no command borrows the pane.
    Engine.needsVisible = []

    var configuration = CefRuntime.Configuration.embedded
    // The embedded preset turns this off; panes visit arbitrary sites, so keep
    // certificate revocation and Safe Browsing lists current.
    configuration.services.componentUpdates = .automatic
    configuration.rootCacheDirectory = Config.dir.appendingPathComponent("chromium", isDirectory: true)
    if config.chromiumDebugPort > 0 { configuration.remoteDebuggingPort = config.chromiumDebugPort }
    do { try CefRuntime.shared.initialize(configuration: configuration) } catch {
      log("Chromium failed to start: \(error)")
      exit(1)
    }

    NSApp.delegate = App.shared
    NSApp.setActivationPolicy(.accessory)
    NSApp.run()
  }
}
