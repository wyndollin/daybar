import AppKit
import ServiceManagement

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)

// Start at login like LimitBar; only registered once, so turning it off in System Settings sticks.
if !UserDefaults.standard.bool(forKey: "loginRegistered") {
    try? SMAppService.mainApp.register()
    UserDefaults.standard.set(true, forKey: "loginRegistered")
}

app.run()
