import AppKit
import SwiftUI

struct AppTarget: Identifiable {
    let id: Int
    let name: String
    let path: String
    let tint: Color
    let planetHi: Color
    let planetLo: Color

    /// Built once. URL(fileURLWithPath:) stats the path to decide the trailing
    /// slash, so constructing it per call was a filesystem hit inside a 1 Hz loop.
    var url: URL { TargetURLs.shared.map[path] ?? URL(fileURLWithPath: path) }

    var isRunning: Bool { RunningApps.pid(for: self) != nil }
}

final class TargetURLs {
    static let shared = TargetURLs()
    let map: [String: URL]
    private init() {
        map = Dictionary(uniqueKeysWithValues: kTargets.map { ($0.path, URL(fileURLWithPath: $0.path)) })
    }
}

/// One enumeration of NSWorkspace.runningApplications, kept fresh by the launch and
/// terminate notifications the app already listens for. It used to be re-enumerated
/// three times a second by the status poll and again on every system-wide app event.
enum RunningApps {
    private static var map: [Int: pid_t] = [:]
    private static var primed = false
    static func invalidate() { primed = false }
    private static func prime() {
        var m: [Int: pid_t] = [:]
        for a in NSWorkspace.shared.runningApplications {
            guard let u = a.bundleURL else { continue }
            for t in kTargets where t.url == u { m[t.id] = a.processIdentifier }
        }
        map = m
        primed = true
    }
    static func pid(for t: AppTarget) -> pid_t? {
        if !primed { prime() }
        return map[t.id]
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
