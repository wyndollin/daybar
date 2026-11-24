import AppKit
import FoundationModels
import ServiceManagement

// `DayBar --check-ai`: can quick-add run here? Prints one word and exits; the installer uses it.
//   0 ready · 3 off (Apple Intelligence not turned on) · 4 downloading · 5 this Mac can't run it
if CommandLine.arguments.contains("--check-ai") {
    switch SystemLanguageModel.default.availability {
    case .available: print("ready"); exit(0)
    case .unavailable(.appleIntelligenceNotEnabled): print("off"); exit(3)
    case .unavailable(.modelNotReady): print("downloading"); exit(4)
    case .unavailable: print("unsupported"); exit(5)
    }
}

// `DayBar --parse "dentist friday 10:30 for 1h"`: print what quick-add would make of it, then exit.
if let i = CommandLine.arguments.firstIndex(of: "--parse"), i + 1 < CommandLine.arguments.count {
    let input = CommandLine.arguments[i + 1]
    Task {
        do {
            let d = try await Parser.parse(input)
            let f = DateFormatter(); f.dateFormat = "EEE yyyy-MM-dd HH:mm"
            print("""
                \(d.kind == .event ? "event" : "reminder"): \(d.title)
                  start: \(d.start.map(f.string(from:)) ?? "none")\(d.hasTime ? "" : " (no time)")
                  end:   \(d.end.map(f.string(from:)) ?? "none")\(d.urgent ? "\n  urgent" : "")\(d.location.isEmpty ? "" : "\n  where: \(d.location)")\(d.repeats == .never ? "" : "\n  repeats: \(d.repeats.label(from: d.start, days: d.repeatDays))")
                """)
            exit(0)
        } catch {
            print("error: \(error.localizedDescription)"); exit(1)
        }
    }
    dispatchMain()
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)

// Start at login like LimitBar; only registered once, so turning it off in System Settings sticks.
if !Store.isDemo && !UserDefaults.standard.bool(forKey: "loginRegistered") {
    try? SMAppService.mainApp.register()
    UserDefaults.standard.set(true, forKey: "loginRegistered")
}

app.run()
