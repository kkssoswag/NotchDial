import AppKit
import SwiftUI

struct AppTarget: Identifiable {
    let id: Int
    let name: String
    let path: String
    let tint: Color
    let planetHi: Color
    let planetLo: Color

    var isRunning: Bool {
        let url = URL(fileURLWithPath: path)
        return NSWorkspace.shared.runningApplications.contains { $0.bundleURL == url }
    }
}

let kTargets: [AppTarget] = [
    AppTarget(id: 0, name: "Codex",
              path: "/Applications/ChatGPT.app",
              tint: Color(red: 0.45, green: 0.55, blue: 0.98),
              planetHi: Color(red: 0.62, green: 0.68, blue: 1.0),
              planetLo: Color(red: 0.14, green: 0.16, blue: 0.40)),
    AppTarget(id: 1, name: "Cursor",
              path: "/Applications/Cursor.app",
              tint: Color(white: 0.92),
              planetHi: Color(white: 0.82),
              planetLo: Color(white: 0.10)),
    AppTarget(id: 2, name: "Claude Code",
              path: "/Applications/Claude.app",
              tint: Color(red: 0.85, green: 0.47, blue: 0.34),
              planetHi: Color(red: 0.96, green: 0.62, blue: 0.42),
              planetLo: Color(red: 0.32, green: 0.12, blue: 0.07)),
]

enum IconCache {
    private static var cache: [Int: NSImage] = [:]
    static func icon(for t: AppTarget) -> NSImage? {
        if let c = cache[t.id] { return c }
        guard FileManager.default.fileExists(atPath: t.path) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: t.path)
        img.size = NSSize(width: 256, height: 256)
        cache[t.id] = img
        return img
    }
}

enum Launcher {
    static var timing = false

    // Dock-click semantics, but instant: snap an already-running app frontmost
    // synchronously, then let LaunchServices handle launch/reopen behind it.
    static func launch(_ t: AppTarget) {
        let url = URL(fileURLWithPath: t.path)
        let t0 = Date()
        if timing {
            var obs: NSObjectProtocol?
            obs = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
                guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      a.bundleURL == url else { return }
                print("LAUNCH LATENCY \(t.name): \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
                if let o = obs { NSWorkspace.shared.notificationCenter.removeObserver(o) }
            }
        }
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL == url }) {
            running.activate(options: [.activateAllWindows])
            if timing { print("PATH: fast activate (already running)") }
        } else if timing {
            print("PATH: cold launch via LaunchServices")
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg, completionHandler: nil)
    }
}
