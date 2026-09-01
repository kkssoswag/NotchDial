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
    // Every attribute here costs one synchronous IPC round-trip per node per sweep.
    // Measured on the real apps, only these two ever carry a status label; reading
    // the other three tripled the traffic for nothing.
    private static let labelAttrs = ["AXTitle", "AXDescription"]

    /// Label PREFIXES that mean "this agent is currently producing something".
    /// Prefix rather than substring on purpose: Claude's sidebar labels a live
    /// session "Running <name>" and a finished one "Mark as unread <name>", so a
    /// chat literally called "Running shoes" must not read as busy.
    static var busyPrefixes = ["running", "stop", "停止", "中断", "interrupt", "cancel generation", "generating", "thinking"]
    /// Prefixes that look busy but aren't the agent working.
    static var ignorePrefixes = ["stop sharing", "stop recording", "stop screen"]

    /// The two faces of one sidebar row. Claude labels a session row "Running <name>"
    /// while it is live and "Mark as unread <name>" when it is not — so the row is a
    /// *two-sided* signal, and that is what makes it trustworthy: "Mark as unread X"
    /// is positive evidence that X finished, which a mere absence of "Running X" is
    /// not. The AX tree of an Electron app comes back partial while it re-renders,
    /// and a partial tree must never be read as "the agent stopped".
    static var runPrefix = "running "
    static var settledPrefix = "mark as unread "

    /// The name a session row carries, if the label is one of the two known forms.
    static func sessionName(_ s: String, prefix: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.lowercased().hasPrefix(prefix) else { return nil }
        let name = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    // Big, because a cold find has to cross a rendered conversation to reach the
    // sidebar, and it only ever happens when both caches have missed.
    static var maxNodes = 14000
    static var maxDepth = 40

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
    /// Last error from the root read, so an empty tree can name its own cause:
    /// a real denial (-25204/-25211) looks nothing like a genuinely bare app.
    static var lastRootError: AXError = .success

    private static func copy(_ el: AXUIElement, _ attr: CFString) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr, &v) == .success else { return nil }
        return v
    }

    /// Why is this app's tree empty? Three very different answers look identical
    /// from a node count of zero: macOS refusing us, the app exposing nothing, and
    /// the app simply having no open windows.
    static func rootReport(pid: pid_t) -> String {
        let app = AXUIElementCreateApplication(pid)
        var wins: CFTypeRef?
        let e = AXUIElementCopyAttributeValue(app, kWindows, &wins)
        var roleV: CFTypeRef?
        let re = AXUIElementCopyAttributeValue(app, kRole, &roleV)
        var names: CFArray?
        AXUIElementCopyAttributeNames(app, &names)
        let attrs = (names as? [String]) ?? []
        let w = (wins as? [AXUIElement])?.count ?? -1
        return "role=\(roleV as? String ?? "?")/\(re.rawValue) windows=\(w)/\(e.rawValue) attrs=\(attrs.count) manualAX=\(attrs.contains("AXManualAccessibility"))"
    }
    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        copy(el, attr as CFString) as? String
    }
    private static func ancestor(_ el: AXUIElement, up: Int) -> AXUIElement {
        var cur = el
        for _ in 0..<up {
            guard let p = copy(cur, "AXParent" as CFString) else { break }
            cur = unsafeBitCast(p, to: AXUIElement.self)
        }
        return cur
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
        var busy = false          // a stop/interrupt control is on screen
        var nodes = 0
        var ms = 0
        var hit = ""
        var running: [String] = []   // sessions the sidebar says are live
        var settled: [String] = []   // sessions the sidebar says are NOT live
        /// False when the walk stopped on a budget rather than running out of tree.
        /// A truncated walk can only ever prove "busy" — never "idle".
        var complete = true
    }

    /// Breadth-first scan of one app's AX tree for a stop/interrupt control.
    /// Buttons live near the composer, which is deep but not enormous; the node
    /// budget keeps a pathological tree from ever stalling the poll.
    /// The one sidebar row worth watching, kept between sweeps.
    ///
    /// This is the difference between a status indicator and a denial-of-service on
    /// the app you are indicating. A full walk is thousands of synchronous IPC calls;
    /// running one every second made all three Electron apps stop reporting their
    /// windows entirely (measured: `windows=0` while NotchDial polled, `windows=1`
    /// the moment it was killed). Once the row has been found, re-reading that single
    /// element is two calls, and it answers the whole question — the row itself flips
    /// between "Running <name>" and "Mark as unread <name>".
    private static var rowCache: [pid_t: AXUIElement] = [:]
    /// An ancestor of the row — the sidebar, roughly. When the row element itself is
    /// re-rendered away, re-finding it inside this subtree costs a few dozen nodes
    /// instead of a walk across the whole window.
    private static var scopeCache: [pid_t: AXUIElement] = [:]
    private static var lastFull: [pid_t: Date] = [:]
    /// Floor between full walks. The cached row carries the signal at 1 Hz; walking
    /// is only for (re)finding it, and must stay rare enough to be harmless.
    static var fullScanEvery: TimeInterval = 4
    static func forgetRows() { rowCache = [:]; scopeCache = [:]; lastFull = [:] }

    /// Roles that cannot contain a sidebar row, so the walk never descends into them.
    /// This is what keeps a long conversation from eating the node budget: the
    /// transcript is thousands of text nodes, and the row we want is a button in the
    /// navigation list. Measured: the row sits at BFS depth 18, and with the
    /// transcript rendered, levels 10-17 alone blew past 2600 nodes — so the search
    /// simply never arrived, and the status went silent for over an hour.
    static let opaqueRoles: Set<String> = [
        "AXStaticText", "AXHeading", "AXParagraph", "AXLink", "AXImage",
        "AXTextField", "AXTextArea", "AXCell", "AXMenuBar", "AXToolbar",
    ]

    /// Read the cached row, if it still exists and still says something we know.
    private static func readCachedRow(_ pid: pid_t) -> Probe? {
        guard let el = rowCache[pid] else { return nil }
        for a in labelAttrs {
            guard let s = string(el, a), !s.isEmpty else { continue }
            if let n = sessionName(s, prefix: runPrefix) {
                return Probe(busy: true, nodes: 1, ms: 0, hit: "cached \(a)=\(s)", running: [n], settled: [], complete: true)
            }
            if let n = sessionName(s, prefix: settledPrefix) {
                return Probe(busy: false, nodes: 1, ms: 0, hit: "", running: [], settled: [n], complete: true)
            }
        }
        rowCache[pid] = nil          // re-rendered away; the next walk will find it again
        return nil
    }

    static func probe(pid: pid_t) -> Probe {
        let t0 = Date()
        if var c = readCachedRow(pid) {
            c.ms = Int(Date().timeIntervalSince(t0) * 1000)
            return c
        }
        // The row element died but the list it lives in probably didn't. Re-finding it
        // inside that subtree is tens of nodes; starting from the window is thousands.
        if let scope = scopeCache[pid] {
            var s = walk(from: [scope], pid: pid, budget: 900)
            if !s.running.isEmpty || !s.settled.isEmpty {
                s.ms = Int(Date().timeIntervalSince(t0) * 1000)
                s.hit = s.hit.isEmpty ? s.hit : "scoped " + s.hit
                return s
            }
            scopeCache[pid] = nil
        }
        if let last = lastFull[pid], Date().timeIntervalSince(last) < fullScanEvery {
            // Not allowed to walk yet, and nothing cached: say so honestly rather
            // than reporting an idle we did not actually observe.
            return Probe(busy: false, nodes: 0, ms: 0, hit: "", running: [], settled: [], complete: false)
        }
        lastFull[pid] = Date()
        let roots: [AXUIElement] = copy(AXUIElementCreateApplication(pid), kWindows) as? [AXUIElement]
            ?? kids(AXUIElementCreateApplication(pid))
        var p = walk(from: roots, pid: pid, budget: maxNodes)
        p.ms = Int(Date().timeIntervalSince(t0) * 1000)
        return p
    }

    private static func walk(from roots: [AXUIElement], pid: pid_t, budget: Int) -> Probe {
        var p = Probe()
        var level: [AXUIElement] = roots
        var depth = 0
        // Walking the whole tree and reading five attributes per node is thousands of
        // synchronous IPC calls into an Electron app — once a second, forever, that is
        // enough to hurt the app we are watching. So: stop at the first row that says
        // "live", which is the common case while an agent works. Only when nothing is
        // live do we pay for the full walk, and that is exactly when we need it —
        // the finished label ("Mark as unread <name>") is the evidence that a session
        // really stopped, and an idle app is cheap to read.
        outer: while !level.isEmpty, depth < maxDepth, p.nodes < budget {
            var next: [AXUIElement] = []
            for el in level {
                p.nodes += 1
                if p.nodes >= budget { p.complete = false; break }
                let r = role(el)
                if r == "AXButton" || r == "AXRadioButton" || r == "AXMenuButton" || r == "AXImage" || r == "AXStaticText" {
                    for a in labelAttrs {
                        guard let s = string(el, a), !s.isEmpty, s.count < 90 else { continue }
                        if let n = sessionName(s, prefix: runPrefix) {
                            p.running.append(n)
                            p.busy = true
                            if p.hit.isEmpty { p.hit = "\(r) \(a)=\(s)" }
                            // Remember the row itself. It is the same element that will
                            // later read "Mark as unread <name>", so from here on the
                            // whole signal costs two IPC calls instead of a walk.
                            rowCache[pid] = el
                            scopeCache[pid] = ancestor(el, up: 4)
                            break outer
                        }
                        if let n = sessionName(s, prefix: settledPrefix) { p.settled.append(n); break }
                        if labelIsBusy(s) {
                            p.busy = true
                            if p.hit.isEmpty { p.hit = "\(r) \(a)=\(s)" }
                            break
                        }
                    }
                }
                // a live progress spinner in the app's own UI is just as truthful
                if r == "AXProgressIndicator" || r == "AXBusyIndicator" {
                    p.busy = true
                    if p.hit.isEmpty { p.hit = r }
                }
                if !opaqueRoles.contains(r) { next.append(contentsOf: kids(el)) }
            }
            if !p.complete { break }
            level = next
            depth += 1
        }
        // Running out of DEPTH is not the same as running out of room. With the
        // content leaves pruned, reaching depth 40 means we examined everything that
        // could plausibly hold a control — so that still counts as a complete look.
        // Only exhausting the node budget means we genuinely stopped early, and only
        // that may be reported as "I could not tell".
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
