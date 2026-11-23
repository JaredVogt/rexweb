import AppKit

Engine.make = { WebKitEngine(tab: $0) }
Engine.setCookies = WebKitEngine.setCookies

let app = NSApplication.shared
app.delegate = App.shared
app.setActivationPolicy(.accessory)
app.run()
