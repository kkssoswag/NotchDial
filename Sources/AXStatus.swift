import AppKit
import ApplicationServices

// MARK: - Ground-truth status via the Accessibility API
//
// Every *inference* signal we tried is unreliable for cloud-run agent sessions
// (measured: local storage writes were 22x HIGHER while the agent was idle than
// while it was streaming, because the desktop app is only a viewer and batches
// its persistence). The one thing that is never wrong is the app's own UI: while
// an agent works, its composer shows a stop/interrupt control instead of send.
//
// So we read exactly what the user reads. Requires a one-time Accessibility grant
// (System Settings → Privacy & Security → Accessibility), and nothing else — no
// hooks, no per-session setup, and it works the same for Claude, Cursor and Codex.
enum AXStatus {
    // string literals rather than the SDK constants: same values, no API drift
    private static let kRole = "AXRole" as CFString
    private static let kChildren = "AXChildren" as CFString
    private static let kWindows = "AXWindows" as CFString
    private static let labelAttrs = ["AXTitle", "AXDescription", "AXHelp", "AXIdentifier", "AXValue"]

    /// Label PREFIXES that mean "this agent is currently producing something".
    /// Prefix rather than substring on purpose: Claude's sidebar labels a live
    /// session "Running <name>" and a finished one "Mark as unread <name>", so a
    /// chat literally called "Running shoes" must not read as busy.
    static var busyPrefixes = ["running", "stop", "停止", "中断", "interrupt", "cancel generation", "generating", "thinking"]
    /// Prefixes that look busy but aren't the agent working.
    static var ignorePrefixes = ["stop sharing", "stop recording", "stop screen"]

    static var maxNodes = 2600
    static var maxDepth = 26

    // MARK: permission
    static func trusted(prompt: Bool = false) -> Bool {
        let opts = ["AXTrustedCheckOptionPrompt" as CFString: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// Chromium (so: every Electron app — Claude, Cursor, VS Code…) keeps its web
    /// accessibility tree switched OFF until an assistive client asks for it, which
    /// is why a plain scan finds only the window's own chrome. Writing
    /// AXManualAccessibility on the app element is Chromium's documented opt-in and
    /// makes the real UI — composer, send/stop control — appear in the tree.
    /// Cheap and idempotent, but only worth doing once per app launch.
    private static var activated: Set<pid_t> = []
    private static let lock = NSLock()
    static func enableWebTree(pid: pid_t, force: Bool = false) -> Bool {
        lock.lock()
        let fresh = force || !activated.contains(pid)
        activated.insert(pid)
        lock.unlock()
        guard fresh else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return true
    }
    static func forgetActivation(pid: pid_t) {
        lock.lock(); activated.remove(pid); lock.unlock()
    }

    // MARK: element helpers
    private static func copy(_ el: AXUIElement, _ attr: CFString) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr, &v) == .success else { return nil }
        return v
    }
    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        copy(el, attr as CFString) as? String
    }
    private static func kids(_ el: AXUIElement) -> [AXUIElement] {
        copy(el, kChildren) as? [AXUIElement] ?? []
    }
    private static func role(_ el: AXUIElement) -> String {
        copy(el, kRole) as? String ?? ""
    }

    /// Pure label test — the whole busy/idle decision, unit-testable without any app.
    static func labelIsBusy(_ s: String) -> Bool {
        let low = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ignorePrefixes.contains(where: { low.hasPrefix($0) }) { return false }
        return busyPrefixes.contains(where: { low.hasPrefix($0) })
    }

    private static func matches(_ el: AXUIElement) -> String? {
        for a in labelAttrs {
            guard let s = string(el, a), !s.isEmpty, s.count < 90 else { continue }
            if labelIsBusy(s) { return "\(a)=\(s)" }
        }
        return nil
    }

    /// AX calls are synchronous IPC; a wedged app must never stall our poll.
    static func setTimeout(pid: pid_t, _ seconds: Float) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateApplication(pid), seconds)
    }

    struct Probe {
        var busy = false
        var nodes = 0
        var ms = 0
        var hit = ""
    }

    /// Breadth-first scan of one app's AX tree for a stop/interrupt control.
    /// Buttons live near the composer, which is deep but not enormous; the node
    /// budget keeps a pathological tree from ever stalling the poll.
    static func probe(pid: pid_t) -> Probe {
        var p = Probe()
        let t0 = Date()
        let app = AXUIElementCreateApplication(pid)
        var level: [AXUIElement] = copy(app, kWindows) as? [AXUIElement] ?? kids(app)
        var depth = 0
        outer: while !level.isEmpty, depth < maxDepth, p.nodes < maxNodes {
            var next: [AXUIElement] = []
            for el in level {
                p.nodes += 1
                if p.nodes >= maxNodes { break outer }
                let r = role(el)
                if r == "AXButton" || r == "AXRadioButton" || r == "AXMenuButton" || r == "AXImage" || r == "AXStaticText" {
                    if let hit = matches(el) {
                        p.busy = true
                        p.hit = "\(r) \(hit)"
                        break outer
                    }
                }
                // a live progress spinner in the app's own UI is just as truthful
                if r == "AXProgressIndicator" || r == "AXBusyIndicator" {
                    p.busy = true
                    p.hit = r
                    break outer
                }
                next.append(contentsOf: kids(el))
            }
            level = next
            depth += 1
        }
        p.ms = Int(Date().timeIntervalSince(t0) * 1000)
        return p
    }

    static func pid(for t: AppTarget) -> pid_t? {
        let url = URL(fileURLWithPath: t.path)
        return NSWorkspace.shared.runningApplications
            .first { $0.bundleURL == url }?.processIdentifier
    }

    /// Dumps every button-ish label in the tree — used by --axdump to learn what a
    /// given app actually calls its stop control, so busyWords can be tuned.
    static func dumpLabels(pid: pid_t, limit: Int = 400) -> [String] {
        var out: [String] = []
        let app = AXUIElementCreateApplication(pid)
        var level: [AXUIElement] = copy(app, kWindows) as? [AXUIElement] ?? kids(app)
        var depth = 0
        var n = 0
        while !level.isEmpty, depth < maxDepth, n < maxNodes, out.count < limit {
            var next: [AXUIElement] = []
            for el in level {
                n += 1
                if n >= maxNodes { break }
                let r = role(el)
                if r == "AXButton" || r == "AXRadioButton" || r == "AXMenuButton" || r == "AXProgressIndicator" {
                    var bits: [String] = [r]
                    for a in labelAttrs {
                        if let s = string(el, a), !s.isEmpty, s.count < 60 { bits.append("\(a)=\(s)") }
                    }
                    if bits.count > 1 { out.append(bits.joined(separator: " · ")) }
                }
                next.append(contentsOf: kids(el))
            }
            level = next
            depth += 1
        }
        return out
    }
}
