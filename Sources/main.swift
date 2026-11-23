import AppKit

Engine.make = { WebKitEngine(tab: $0) }
Engine.setCookies = WebKitEngine.setCookies
// A background WebKit tab takes clicks, keys and typed text directly, so only
// a screenshot borrows the pane: a hidden page runs no animation frames or
// transitions, and its picture would show them where they stopped.
Engine.needsVisible = ["/shot"]

let app = NSApplication.shared
app.delegate = App.shared
app.setActivationPolicy(.accessory)
app.run()
