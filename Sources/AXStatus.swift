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
    /// Assert "an assistive client is here" — EVERY sweep, not once. This is the
    /// whole ballgame, and I had it wrong for days. Chromium keeps its web tree off
    /// until it sees this attribute set, and re-evaluates continuously: set it once
    /// and walk away, and the tree comes up for a moment and then Chromium decides
    /// nobody is listening and tears it back down. Measured, that left the tree dark
    /// ~82% of the time for a backgrounded app. Re-asserting it on every sweep (one
    /// cheap IPC write, ~0ms) keeps the tree continuously alive and fast even in the
    /// background — measured 7–66ms full reads, zero dropouts over minutes. The DoS I
    /// once saw came from an unbounded *walk*, never from this write.
    ///
    /// Returns true the first time for a pid, so the caller can skip that one sweep's
    /// read and let Chromium finish building the tree before we look.
    static func enableWebTree(pid: pid_t, force: Bool = false) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        lock.lock()
        let fresh = force || !activated.contains(pid)
        activated.insert(pid)
        lock.unlock()
        return fresh
    }
    /// Drop everything keyed to a pid. macOS reuses pids, and every one of these
    /// caches is a promise about a process that no longer exists: `activated` would
    /// make us skip the AXManualAccessibility opt-in for the new occupant (silently
    /// killing the signal for that app until restart), and the element caches would
    /// hand out references into a dead tree.
    static func forget(pid: pid_t) {
        lock.lock()
        activated.remove(pid); rowCache[pid] = nil; scopeCache[pid] = nil
        composerCache[pid] = nil; webAreaCache[pid] = nil
        lastFull[pid] = nil; lastDiscover[pid] = nil; emptyStreak[pid] = nil
        lock.unlock()
    }
    // MARK: element helpers
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
            guard let p = copy(cur, "AXParent" as CFString),
                  CFGetTypeID(p) == AXUIElementGetTypeID() else { break }
            cur = (p as! AXUIElement)
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
        /// The session the window is currently showing, from the web area's title.
        var openSession: String?
        /// Whether that session is inside a turn — see `stopPrefixes`.
        var openBusy = false
        /// Whether this sweep was actually able to look for the stop control. An
        /// unchecked composer is not the same as an absent stop button.
        var openChecked = false
    }

    /// The composer's interrupt control. THIS is the turn-level signal, and the
    /// reason the sidebar label was never going to work: "Running <name>" tracks the
    /// model *emitting tokens*, so it goes quiet for the thirty seconds a tool call
    /// takes and the status flickers several times per turn. You can interrupt a turn
    /// at any point of it, including mid-tool — so the interrupt control is present
    /// for exactly as long as the turn is, which is the quantity we actually want.
    static var stopPrefixes = ["stop response", "stop generating", "stop streaming",
                               "停止响应", "停止生成", "停止", "中断", "interrupt", "cancel generation"]
    static func labelIsStop(_ s: String) -> Bool {
        let low = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ignorePrefixes.contains(where: { low.hasPrefix($0) }) { return false }
        return stopPrefixes.contains(where: { low.hasPrefix($0) })
    }

    /// "可用工具检查 - Claude" → "可用工具检查". The window title names the session the
    /// stop control belongs to, which is what lets one app's several sessions be told
    /// apart by a control that only ever exists for the visible one.
    static func openSessionName(_ title: String) -> String? {
        guard let r = title.range(of: " - ", options: .backwards) else { return nil }
        let n = String(title[title.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? nil : n
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
    /// Every session row the sidebar shows, by name — not just the one that happened
    /// to be running when we last walked. One app runs many sessions at once, and
    /// watching only the first meant the notch stamped ✓ the moment *that* one
    /// finished while the others were still going. Rows are kept whatever they say:
    /// a session already in the list flips to "Running" the instant you send, so
    /// holding its element is what makes a new turn show up immediately.
    private static var rowCache: [pid_t: [String: AXUIElement]] = [:]
    /// Bound on how many rows we agree to watch; a long sidebar is not a reason to
    /// spend unbounded IPC every second.
    static var maxWatchedRows = 24
    /// An ancestor of the row — the sidebar, roughly. When the row element itself is
    /// re-rendered away, re-finding it inside this subtree costs a few dozen nodes
    /// instead of a walk across the whole window.
    private static var scopeCache: [pid_t: AXUIElement] = [:]
    /// The composer subtree, so the interrupt control can be re-checked for a few
    /// dozen nodes instead of a walk. The button itself cannot be cached — it does
    /// not exist between turns, which is the whole point of it.
    private static var composerCache: [pid_t: AXUIElement] = [:]
    private static var webAreaCache: [pid_t: AXUIElement] = [:]
    private static var lastFull: [pid_t: Date] = [:]
    /// Floor between full walks. The cached row carries the signal at 1 Hz; walking
    /// is only for (re)finding it, and must stay rare enough to be harmless.
    static var fullScanEvery: TimeInterval = 4
    private static var lastDiscover: [pid_t: Date] = [:]
    /// Consecutive walks that came back with nothing at all. Chromium switches its
    /// accessibility tree back OFF when it decides no assistive client is listening,
    /// and our opt-in was once-per-pid — so once it went dark it stayed dark, and the
    /// indicator was silent until the app or NotchDial restarted. Re-assert the
    /// opt-in, and back off while doing it: hammering an app that is not answering is
    /// also how it got there.
    private static var emptyStreak: [pid_t: Int] = [:]
    /// How often to go looking for sessions we have never seen. Known rows are read
    /// every sweep, so this only has to catch a brand-new chat.
    static var discoverEvery: TimeInterval = 12

    /// Bring a session to the front by pressing its own sidebar row. We are already
    /// holding the element, so "jump to that session" is one AX call rather than a
    /// guess at the app's URL scheme.
    static func press(pid: pid_t, name: String) -> Bool {
        lock.lock(); let el = rowCache[pid]?[name]; lock.unlock()
        guard let el = el else { return false }
        return AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
    }

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

    /// Read every cached row. Each one reports for itself, so N sessions cost 2N IPC
    /// calls and the answer is exact for all of them rather than for whichever was
    /// found first.
    private static func readCachedRows(_ pid: pid_t) -> Probe? {
        lock.lock(); let cached = rowCache[pid] ?? [:]; lock.unlock()
        guard !cached.isEmpty else { return nil }
        var p = Probe(); p.complete = true
        var dead: [String] = []
        for (name, el) in cached {
            var seen = false
            for a in labelAttrs {
                guard let s = string(el, a), !s.isEmpty else { continue }
                if let n = sessionName(s, prefix: runPrefix) {
                    p.running.append(n); p.busy = true
                    if p.hit.isEmpty { p.hit = "cached \(a)=\(s)" }
                    seen = true; break
                }
                if let n = sessionName(s, prefix: settledPrefix) { p.settled.append(n); seen = true; break }
            }
            if !seen { dead.append(name) }
        }
        p.nodes = cached.count - dead.count
        if !dead.isEmpty {
            lock.lock(); for n in dead { rowCache[pid]?[n] = nil }; lock.unlock()
        }
        // A row can be renamed as well as re-rendered, so a name we no longer see is
        // not proof the session ended — only a walk can say that.
        return p.nodes > 0 ? p : nil
    }

    static func probe(pid: pid_t) -> Probe {
        let t0 = Date()
        if var c = readCachedRows(pid) {
            // Known rows answered. Still go looking for sessions we have never seen,
            // but rarely — a brand-new chat is the only thing this can discover, and
            // an existing one already flips under us the moment it starts.
            lock.lock(); let seen = lastDiscover[pid]; lock.unlock()
            if seen == nil || Date().timeIntervalSince(seen!) >= discoverEvery {
                lock.lock(); lastDiscover[pid] = Date(); lock.unlock()
                let roots: [AXUIElement] = copy(AXUIElementCreateApplication(pid), kWindows) as? [AXUIElement] ?? []
                let w = walk(from: roots, pid: pid, budget: maxNodes)
                if w.complete, !(w.running.isEmpty && w.settled.isEmpty) {
                    var m = w
                    m.openChecked = true
                    m.ms = Int(Date().timeIntervalSince(t0) * 1000)
                    return m
                }
            }
            readOpen(pid, into: &c)
            c.ms = Int(Date().timeIntervalSince(t0) * 1000)
            return c
        }
        // The row element died but the list it lives in probably didn't. Re-finding it
        // inside that subtree is tens of nodes; starting from the window is thousands.
        lock.lock(); let scope = scopeCache[pid]; let last = lastFull[pid]; lock.unlock()
        if let scope = scope {
            var s = walk(from: [scope], pid: pid, budget: 900)
            if !s.running.isEmpty || !s.settled.isEmpty {
                s.ms = Int(Date().timeIntervalSince(t0) * 1000)
                s.hit = s.hit.isEmpty ? s.hit : "scoped " + s.hit
                return s
            }
            lock.lock(); scopeCache[pid] = nil; lock.unlock()
        }
        lock.lock(); let streak = emptyStreak[pid] ?? 0; lock.unlock()
        // A gentle floor between full walks of an app that keeps coming back empty —
        // 4s rising to at most 20s. The old cap was five minutes, on the theory that
        // "retrying is what keeps the tree down." That theory was measured BEFORE we
        // re-asserted AXManualAccessibility every sweep, when the retries were bare
        // walks Chromium ignored. Now the re-assert IS the thing that brings the tree
        // back, so a long dark stretch is no longer self-inflicted — it just means we
        // are not looking. Keep the floor small so recovery is quick.
        let backoff = min(fullScanEvery * pow(2, Double(min(streak, 3))), 20)
        if let last = last, Date().timeIntervalSince(last) < backoff {
            // Not allowed to walk yet, and nothing cached: say so honestly rather
            // than reporting an idle we did not actually observe.
            return Probe(busy: false, nodes: 0, ms: 0, hit: "", running: [], settled: [], complete: false)
        }
        lock.lock(); lastFull[pid] = Date(); lock.unlock()
        let roots: [AXUIElement] = copy(AXUIElementCreateApplication(pid), kWindows) as? [AXUIElement]
            ?? kids(AXUIElementCreateApplication(pid))
        var p = walk(from: roots, pid: pid, budget: maxNodes)
        lock.lock(); emptyStreak[pid] = p.nodes < 8 ? streak + 1 : 0; lock.unlock()
        // A walk that saw nothing cannot report on the composer either.
        p.openChecked = p.nodes >= 8
        p.ms = Int(Date().timeIntervalSince(t0) * 1000)
        return p
    }

    /// Re-check just the composer and the window title: which session is on screen,
    /// and is it inside a turn. Tens of nodes, and it is the authoritative answer for
    /// the session the user is actually looking at.
    private static func readOpen(_ pid: pid_t, into p: inout Probe) {
        lock.lock(); let wa = webAreaCache[pid]; let comp = composerCache[pid]; lock.unlock()
        if let wa = wa, let t = string(wa, "AXTitle"), let n = openSessionName(t) {
            p.openSession = n
        } else if wa != nil {
            lock.lock(); webAreaCache[pid] = nil; lock.unlock()
        }
        guard let comp = comp else { return }
        // A cached element that Electron has since re-rendered away still *counts* as
        // a node when walked from (the root is tallied before anything is read), so
        // "nodes > 0" could never fail and a dead composer kept answering "checked,
        // no interrupt control" for the rest of the session — which settled the open
        // session the moment its sidebar row went quiet for a tool call: a ✓ mid-turn,
        // then a spinner again, once per tool call. The composer is a container; a
        // live one has children. Anything less is a dead element, and we look again.
        let scan = walk(from: [comp], pid: pid, budget: 260)
        guard scan.nodes > 1 else {
            lock.lock(); composerCache[pid] = nil; lock.unlock()
            return
        }
        p.openChecked = true
        if scan.openBusy { p.openBusy = true; p.busy = true; if p.hit.isEmpty { p.hit = scan.hit } }
    }

    /// Keep the row element, and the list it hangs in. Watching a row that is merely
    /// finished is the point: it is the same element that flips to "Running" the
    /// instant that session is given something to do.
    private static func remember(pid: pid_t, name: String, el: AXUIElement) {
        lock.lock()
        var m = rowCache[pid] ?? [:]
        if m[name] == nil && m.count >= maxWatchedRows { lock.unlock(); return }
        m[name] = el
        rowCache[pid] = m
        let needScope = scopeCache[pid] == nil
        lock.unlock()
        // The ancestor lookup is four synchronous IPC round-trips into the app, each
        // with a 0.4 s timeout. Not under the lock: the main thread takes it to press
        // a row or forget a pid, and a slow app must never make the island wait.
        guard needScope else { return }
        let a = ancestor(el, up: 4)
        lock.lock(); if scopeCache[pid] == nil { scopeCache[pid] = a }; lock.unlock()
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
        while !level.isEmpty, depth < maxDepth, p.nodes < budget {
            var next: [AXUIElement] = []
            for el in level {
                // The budget is a count of nodes examined; the one that would exceed
                // it is the one we stop at, unexamined, and only then is the walk
                // incomplete. (Stopping *at* the budget left a tree of exactly that
                // size reported as "could not tell" after it had all been read.)
                if p.nodes >= budget { p.complete = false; break }
                p.nodes += 1
                let r = role(el)
                if r == "AXWebArea", p.openSession == nil, let t = string(el, "AXTitle"),
                   let n = openSessionName(t) {
                    p.openSession = n
                    lock.lock(); webAreaCache[pid] = el; lock.unlock()
                }
                if r == "AXButton" || r == "AXRadioButton" || r == "AXMenuButton" || r == "AXImage" || r == "AXStaticText" {
                    for a in labelAttrs {
                        guard let s = string(el, a), !s.isEmpty, s.count < 90 else { continue }
                        if let n = sessionName(s, prefix: runPrefix) {
                            p.running.append(n)
                            p.busy = true
                            if p.hit.isEmpty { p.hit = "\(r) \(a)=\(s)" }
                            remember(pid: pid, name: n, el: el)
                            break
                        }
                        if let n = sessionName(s, prefix: settledPrefix) {
                            p.settled.append(n)
                            remember(pid: pid, name: n, el: el)
                            break
                        }
                        if labelIsStop(s) {
                            p.openBusy = true; p.busy = true
                            if p.hit.isEmpty { p.hit = "STOP \(r) \(a)=\(s)" }
                            let anc = ancestor(el, up: 3)
                            lock.lock(); composerCache[pid] = anc; lock.unlock()
                            break
                        }
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

    static func pid(for t: AppTarget) -> pid_t? { RunningApps.pid(for: t) }

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
