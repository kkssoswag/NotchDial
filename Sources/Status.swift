import AppKit
import SwiftUI
import Darwin

// MARK: - Agent work status
// Three signals, merged per target, in order of authority:
//   1. Accessibility (exact, read from the app's own UI): the sidebar row that says
//      "Running <name>" / "Mark as unread <name>" and the composer's interrupt control.
//      Where this can read the app, nothing else gets a vote.
//   2. Network inflow (automatic fallback): tokens streaming in from the cloud, for a
//      backgrounded app whose a11y tree Chromium has torn down.
//   3. File protocol (explicit, agent-reported): ~/.notchdial/status/<slug>[.<session>]
//      slug = target name lowercased, spaces → "-"  (codex, cursor, claude-code)
//      content = "working" | "done" | "idle". Written by the bundled hooks plugin.
// Two signals we measured and removed: CPU utilization (an idle app spiked to 51%,
// a streaming one sat at 1%) and local-storage writes (22x HIGHER while idle). Both
// lied more often than they helped, and CPU sampling cost a proc_pidpath syscall per
// process on the machine every second on the main thread.
// A finished task shows ✓ until the user actually switches to that app (or keeps
// it frontmost for a beat) — then the state clears and the status file is removed.

enum WorkState: Equatable { case idle, working, done }

final class StatusMonitor {
    // tunables
    // The Accessibility signal is exact — a turn that really ran deserves its stamp
    // however short it was, so the floor below is only there to drop a one-sweep blip.
    var axMinWork: TimeInterval = 2
    var workingTTL: TimeInterval = 30 * 60 // stale "working" files are ignored (crashed agent)
    var doneTTL: TimeInterval = 12 * 3600
    // How long a finished stamp stays visible when you are ALREADY looking at that
    // app. Counted from completion, in seconds — not in poll ticks: publish() runs
    // more than once per second, so a tick counter made the stamp flash for under a
    // second and the completion went unnoticed.
    var doneLinger: TimeInterval = 8

    var dirPath = (NSHomeDirectory() as NSString).appendingPathComponent(".notchdial/status")
    var frontmostBundlePath: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleURL?.path }
    /// Injectable so the self-test does not depend on which apps happen to be open.
    var isRunning: (AppTarget) -> Bool = { $0.isRunning }
    var onChange: (([Int: WorkState]) -> Void)?
    var onTimes: (([Int: Date]) -> Void)?

    private lazy var net: NetMonitor? = NetMonitor(targets: kTargets)

    // MARK: accessibility signal (authoritative)
    // The app's own UI is the only source that cannot be wrong: Claude's sidebar
    // labels a live session "Running <name>", Cursor/Codex show a stop control.
    // Where AX gives us a real tree we trust it exclusively and ignore the
    // guessing signals below, which measurably lie for cloud-run sessions.
    var axEnabled = true
    private let axQueue = DispatchQueue(label: "com.dd.notchdial.ax", qos: .utility)
    private var axInFlight = false
    private var axGeneration: UInt64 = 0
    private var axBusy: Set<Int> = []          // agents the UI says are working
    private var axUsable: Set<Int> = []        // apps whose AX tree we can actually read
    private var axLastGood: [Int: Date] = [:]  // last sweep that actually read something
    /// How long an app may go without a single readable sweep before we stop
    /// treating AX as its source of truth and let the fallback back in. Long enough
    /// to ride out a brief dark patch, short enough that a genuinely unreadable app
    /// doesn't sit there frozen on a stale reading.
    var axUsableTTL: TimeInterval = 12
    private var axStart: [Int: Date] = [:]
    /// Consecutive sweeps that must agree before an idle app is shown working. One
    /// sweep is a rumour: a row caught mid-re-render, a label read as it changes.
    /// Two in a row, a second apart, is the app telling us the same thing twice.
    /// Costs one second of latency on the spinner; the ✓ path is unaffected.
    var axConfirmSweeps = 2
    private var axStreak: [Int: Int] = [:]
    private var axStreakStart: [Int: Date] = [:]
    /// The session on screen, as the web area last named it. This is how a finished
    /// session gets acknowledged *individually*: you are in the app, that session is
    /// the one you are looking at, and it stays that way for a beat.
    private var lastOpen: [Int: String] = [:]
    private var sessSeenAt: [Int: [String: Date]] = [:]
    /// A ✓ the user has not looked at yet. A new burst hides it behind the spinner,
    /// but must not *pay* it: if that burst is too short to earn a stamp of its own,
    /// the old one comes back. Without this, one flickering sweep right after a
    /// finished turn erases the stamp before anyone could have seen it.
    private var axOwed: Set<Int> = []
    /// Sessions this app's sidebar has shown as live. We only believe the agent
    /// stopped once the very same session reappears wearing its finished label —
    /// absence proves nothing, because the tree comes back partial under load.
    private var axLive: [Int: Set<String>] = [:]
    private var axUnknownSince: [Int: Date] = [:]
    /// If a row we were tracking never comes back at all (session closed, sidebar
    /// scrolled away, app quit), holding "working" forever would be its own lie.
    var axUnknownGrace: TimeInterval = 300

    /// One agent session inside an app. Claude runs several at once, so "is Claude
    /// working" is an aggregate — this is the detail behind it, and the only thing
    /// worth putting in a ledger you opened in order to find out what is running.
    struct SessionInfo: Equatable, Identifiable {
        var target: Int
        var name: String
        var state: WorkState
        var since: Date
        var id: String { "\(target)/\(name)" }
    }
    private(set) var sessions: [Int: [SessionInfo]] = [:]
    var onSessions: (([Int: [SessionInfo]]) -> Void)?
    private var sessState: [Int: [String: WorkState]] = [:]
    private var sessSince: [Int: [String: Date]] = [:]

    /// Fold one sweep's session evidence into the per-session view.
    private func applySessions(_ id: Int, _ r: AXRead, now: Date) {
        guard !r.running.isEmpty || !r.settled.isEmpty || (r.openChecked && r.openSession != nil) else { return }
        var st = sessState[id] ?? [:]
        var sn = sessSince[id] ?? [:]
        // Same settle rule as the app-level verdict, so a row cannot say "done"
        // while the aggregate still says "working".
        let running = axLive[id] ?? []
        var settledNames = r.settled
        settledNames.removeAll { running.contains($0) }
        if let open = r.openSession, r.openChecked, !r.openBusy, !running.contains(open),
           !settledNames.contains(open) { settledNames.append(open) }
        for n in running where st[n] != .working {
            st[n] = .working; sn[n] = now
        }
        for n in settledNames {
            // Only a session we watched working earns a stamp; a row that was already
            // finished when we first saw it is just part of the furniture.
            if st[n] == .working {
                let began = sn[n] ?? now
                if now.timeIntervalSince(began) >= axMinWork { st[n] = .done; sn[n] = now }
                else { st[n] = nil; sn[n] = nil }
            }
        }
        sessState[id] = st; sessSince[id] = sn
    }

    private func rebuildSessions() {
        var out: [Int: [SessionInfo]] = [:]
        for (id, m) in sessState {
            let rows = m.compactMap { (n, s) -> SessionInfo? in
                guard s != .idle else { return nil }
                return SessionInfo(target: id, name: n, state: s, since: sessSince[id]?[n] ?? Date())
            }
            // newest first: the thing you just started is the thing you are looking for
            if !rows.isEmpty { out[id] = rows.sorted { $0.since > $1.since } }
        }
        if out != sessions { sessions = out; onSessions?(out) }
    }

    /// One sweep's worth of evidence about a single app.
    struct AXRead {
        var busy = false
        var nodes = 0
        var running: [String] = []
        var settled: [String] = []
        var complete = true
        var openSession: String?
        var openBusy = false
        var openChecked = false
        init(busy: Bool = false, nodes: Int = 0, running: [String] = [], settled: [String] = [],
             complete: Bool = true, openSession: String? = nil, openBusy: Bool = false,
             openChecked: Bool = false) {
            self.busy = busy; self.nodes = nodes
            self.running = running; self.settled = settled; self.complete = complete
            self.openSession = openSession; self.openBusy = openBusy; self.openChecked = openChecked
        }
    }

    /// What one sweep is allowed to conclude.
    enum AXVerdict { case working, finished, unknown }

    /// How long a session may simply *not be visible* before we believe it finished.
    /// This is not a debounce on a signal that said "stopped" — a row explicitly
    /// reading "Mark as unread <name>" settles immediately, and the visible session
    /// settles the moment the interrupt control goes too. This covers the case where
    /// the evidence goes missing rather than negative: a partial tree, a re-rendered
    /// row, an app too busy to answer, a background agent whose row we lose while it
    /// works. Silence is not the same as an answer, and for a minute we decline to
    /// treat it as one.
    var bgSettleDelay: TimeInterval = 60
    private var quietSince: [Int: [String: Date]] = [:]

    /// The sessions this app should still be considered running, after the settle
    /// rule. Called once per sweep; it owns `axLive`.
    private func liveNames(_ id: Int, _ r: AXRead, now: Date) -> Set<String> {
        var live = axLive[id] ?? []
        var q = quietSince[id] ?? [:]
        let running = Set(r.running)
        let openLive: String? = (r.openChecked && r.openBusy) ? r.openSession : nil
        live.formUnion(running)
        if let o = openLive { live.insert(o) }
        let settled = Set(r.settled)
        for n in live {
            if running.contains(n) || n == openLive { q[n] = nil; continue }
            // Its own row saying "Mark as unread <name>" is positive evidence that it
            // stopped. The grace below is for LOSING SIGHT of a session — a partial
            // tree, a re-rendered row, an app too busy to answer — not for a session
            // that told us plainly.
            if settled.contains(n) { live.remove(n); q[n] = nil; continue }
            // The composer speaks for the session on screen, so when both it and the
            // sidebar are quiet there is nothing left to wait for.
            if r.openChecked, n == r.openSession {
                live.remove(n); q[n] = nil; continue
            }
            let since = q[n] ?? now
            q[n] = since
            if now.timeIntervalSince(since) >= bgSettleDelay { live.remove(n); q[n] = nil }
        }
        quietSince[id] = q
        axLive[id] = live
        return live
    }

    private(set) var states: [Int: WorkState] = [:]   // only non-idle entries
    /// When each current state began — the ledger's whole reason to exist is telling
    /// you how long a thing has been running, and that needs a start, not just a flag.
    private(set) var since: [Int: Date] = [:]
    private var timer: Timer?
    /// When the previous tick ran, so a starved run loop is measured rather than
    /// assumed: a byte count that piled up over ten seconds is not a ten-fold rate.
    private var lastTick: Date?
    /// A ✓ minted by a signal, waiting to be seen. (The file protocol's "done" lives
    /// in its file instead.)
    private var autoDone: Set<Int> = []
    private var doneAt: [Int: Date] = [:]

    static func slug(_ t: AppTarget) -> String {
        t.name.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    // `defaults write com.dd.notchdial statusDebug -bool true` → ~/Library/Logs/NotchDial/status.log
    static let debug = UserDefaults.standard.bool(forKey: "statusDebug")
    /// Diagnostics that show a matched label are enormously more useful, and the
    /// label is the title of the user's chat — read out of another application's
    /// window. That never belongs in a log by default, and it certainly never
    /// belonged in world-readable /tmp. Opt in explicitly to see the text.
    static let logLabels = UserDefaults.standard.bool(forKey: "statusDebugLabels")
    /// Keep the shape, drop the content. Which rule fired and on what kind of element
    /// is the whole diagnostic value; the text after the `=` is the user's chat title
    /// and is none of the log's business.
    static func redact(_ s: String) -> String {
        guard !logLabels, !s.isEmpty else { return s }
        guard let eq = s.firstIndex(of: "=") else { return "‹\(s.count)›" }
        return String(s[s.startIndex...eq]) + "‹\(s.distance(from: s.index(after: eq), to: s.endIndex))›"
    }
    private static let stamper: ISO8601DateFormatter = ISO8601DateFormatter()
    private static let logDir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/NotchDial")
    static let logPath = (logDir as NSString).appendingPathComponent("status.log")
    private static let logMaxBytes = 4 << 20
    private var logHandle: FileHandle?
    /// The self-test builds a dozen monitors; their chatter has no business in the
    /// log the real one keeps, where it reads like handovers that never happened.
    var logEnabled = true
    func logExternal(_ s: String) { log(s) }
    private func log(_ s: String) {
        guard Self.debug, logEnabled else { return }
        guard let d = "\(Self.stamper.string(from: Date())) \(s)\n".data(using: .utf8) else { return }
        if logHandle == nil {
            try? FileManager.default.createDirectory(atPath: Self.logDir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            // O_NOFOLLOW: /tmp was a symlink-follow write primitive — anyone could
            // point the log at a dotfile and have us append to it once a second.
            let fd = open(Self.logPath, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { return }
            logHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        guard let fh = logHandle else { return }
        if fh.offsetInFile > UInt64(Self.logMaxBytes) {          // rotate: keep one old file
            try? fh.close(); logHandle = nil
            try? FileManager.default.removeItem(atPath: Self.logPath + ".1")
            try? FileManager.default.moveItem(atPath: Self.logPath, toPath: Self.logPath + ".1")
            return log(s)
        }
        fh.write(d)
    }

    func start() {
        guard timer == nil else { return }
        let tm = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
        if netEnabled, UserDefaults.standard.object(forKey: "statusNet") as? Bool ?? true { net?.start() }
        else { netEnabled = false }
        log("START axEnabled=\(axEnabled) trusted=\(AXStatus.trusted()) net=\(netEnabled) pids=\(kTargets.compactMap { AXStatus.pid(for: $0) })")
        // Exact status needs one Accessibility grant. Ask once, ever; the menu item
        // stays available for later. Without it we quietly fall back to guessing.
        if axEnabled, !AXStatus.trusted(), !UserDefaults.standard.bool(forKey: "axPromptShown") {
            UserDefaults.standard.set(true, forKey: "axPromptShown")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { _ = AXStatus.trusted(prompt: true) }
        }
        // Switching to a finished app acknowledges its ✓: publish() clears a stamp that
        // has been frontmost for doneLinger, on every tick. (This used to also arm a
        // one-shot timer from the activation notification, which could not be cancelled
        // and would wipe a *newer* stamp minted after it was scheduled.)
        tick()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        net?.stop()
        netWorking = []; netCarry = []; netLastActive = [:]; netStart = [:]; netLastBytes = [:]
        states = [:]; autoDone = []; doneAt = [:]; lastTick = nil
        axBusy = []; axUsable = []; axStart = [:]; axOwed = []; axStreak = [:]; axStreakStart = [:]
        axLive = [:]; axUnknownSince = [:]; since = [:]; axLastGood = [:]; lastOpen = [:]; sessSeenAt = [:]
        sessState = [:]; sessSince = [:]; sessions = [:]; quietSince = [:]; onSessions?([:])
        axGeneration &+= 1; axSweepID &+= 1; axInFlight = false; axSweepStarted = nil; axWedged = false
        axWasTrusted = true
        onChange?(states)
        onTimes?(since)
    }

    /// The user has seen this app's ✓ — by switching to the app, or by clicking its
    /// ledger row. Drops the stamp and everything that would re-mint it.
    func clearDone(_ t: AppTarget) {
        autoDone.remove(t.id)
        axOwed.remove(t.id)      // seen — the debt is paid
        for (n, s) in sessState[t.id] ?? [:] where s == .done { sessState[t.id]?[n] = nil; sessSince[t.id]?[n] = nil }
        sessSeenAt[t.id] = nil
        rebuildSessions()
        doneAt[t.id] = nil
        removeFile(t)
        publish()
    }

    /// The user has seen ONE session's ✓ — clicked its row, or sat with it open. Only
    /// that row goes. The app's own stamp follows only when no other finished session
    /// is still waiting to be seen: with three tasks in one app, jumping to the one
    /// that finished must not silently acknowledge the other two.
    func acknowledge(_ t: AppTarget, session: String?) {
        guard let s = session else { clearDone(t); return }
        guard sessState[t.id]?[s] == .done else { return }
        sessState[t.id]?[s] = nil; sessSince[t.id]?[s] = nil; sessSeenAt[t.id]?[s] = nil
        log("ACK id=\(t.id) session=\(Self.redact("s=" + s))")
        let otherDone = (sessState[t.id] ?? [:]).values.contains(.done)
        if !otherDone, !axBusy.contains(t.id), !netWorking.contains(t.id) {
            autoDone.remove(t.id); axOwed.remove(t.id); doneAt[t.id] = nil; removeFile(t)
        }
        rebuildSessions()
        publish()
    }

    /// Acknowledging a ✓ removes the files that said "done" — never one that still
    /// says "working": a session that is mid-turn is not ours to silence.
    private func removeFile(_ t: AppTarget) {
        for f in statusFiles(t, in: listStatusDir()) {
            let p = (dirPath as NSString).appendingPathComponent(f)
            if let (w, _) = word(inFile: p), w == "working" { continue }
            try? FileManager.default.removeItem(atPath: p)
        }
    }

    /// One directory listing per pass — publish() asks about every target, and the
    /// answer for all of them is in the same listing.
    private func listStatusDir() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dirPath)) ?? []
    }

    /// Every file belonging to this target: the bare slug, and one per session
    /// (`claude-code.<session>`). Concurrent sessions each report for themselves —
    /// sharing one file meant session A's "done" erased the fact that B was still
    /// working, which is the same bug the Accessibility path had.
    private func statusFiles(_ t: AppTarget, in names: [String]) -> [String] {
        let base = Self.slug(t)
        return [base, base + ".txt"] + names.filter { $0.hasPrefix(base + ".") && $0 != base + ".txt" }.sorted()
    }

    /// Read one word out of one file, cheaply and with a bound. A runaway hook that
    /// appends instead of overwriting should not turn into an unbounded allocation
    /// twice a second.
    private func word(inFile p: String) -> (String, TimeInterval)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: p),
              (a[.type] as? FileAttributeType) == .typeRegular else { return nil }
        guard let fh = FileHandle(forReadingAtPath: p) else { return nil }
        defer { try? fh.close() }
        let head = (try? fh.read(upToCount: 64)) ?? Data()
        guard let raw = String(data: head, encoding: .utf8) else { return nil }
        let w = raw.split(whereSeparator: { $0.isNewline || $0 == " " }).first.map(String.init)?.lowercased() ?? ""
        let mtime = a[.modificationDate] as? Date
        return (w, mtime.map { Date().timeIntervalSince($0) } ?? .infinity)
    }

    private func fileState(_ t: AppTarget, in names: [String]) -> WorkState? {
        var agg: WorkState? = nil
        for f in statusFiles(t, in: names) {
            let p = (dirPath as NSString).appendingPathComponent(f)
            guard let (w, age) = word(inFile: p) else { continue }
            // any session working wins; a stamp only survives if nothing is working
            if w == "working" && age < workingTTL { return .working }
            if w == "done" && age < doneTTL { agg = .done }
            if w == "idle" && agg == nil { agg = .idle }
        }
        return agg
    }

    /// Everything we believe about one app, dropped. Called when the app quits and
    /// when the Accessibility grant goes away — two situations that used to strand
    /// the indicator: a quit app never appears in a sweep again, so nothing could
    /// ever clear its spinner, and an untrusted app kept `axUsable`, which is what
    /// suppresses the fallback signals. Either way the notch kept asserting
    /// something it had no way to still know.
    func forgetAX(_ id: Int) {
        axUsable.remove(id); axBusy.remove(id); axOwed.remove(id); axLastGood[id] = nil
        axLive[id] = nil; axStart[id] = nil; axUnknownSince[id] = nil; quietSince[id] = nil
        axStreak[id] = nil; axStreakStart[id] = nil; lastOpen[id] = nil; sessSeenAt[id] = nil
        sessState[id] = nil; sessSince[id] = nil
        rebuildSessions()
    }

    /// The tree went dark on a turn AX was watching. The turn does not stop existing
    /// because we lost the ability to read it — so the network signal finishes it:
    /// inbound bytes keep it alive, a long silence ends it and mints the stamp AX
    /// would have. The sessions AX had live ride along, so the ledger keeps its rows.
    /// An app that was *idle* when its tree went dark gets nothing: nothing started,
    /// so there is nothing to finish, and the network is never allowed to invent one.
    private func handOver(_ id: Int, start: Date, sessions: [(String, Date)], now: Date) {
        netWorking.insert(id); netCarry.insert(id)
        netStart[id] = start; netLastActive[id] = now
        var st = sessState[id] ?? [:], sn = sessSince[id] ?? [:]
        for (n, s) in sessions { st[n] = .working; sn[n] = s }
        sessState[id] = st; sessSince[id] = sn
        log("HANDOVER id=\(id) → network, sessions=\(sessions.count)")
    }

    /// The app is gone. Every signal about it goes with it — including the network
    /// one, which used to survive this and then mint a ✓ that nothing could dismiss
    /// (a stamp is acknowledged by bringing the app frontmost, and a quit app never is).
    func targetTerminated(_ id: Int, pid: pid_t?) {
        if let p = pid { AXStatus.forget(pid: p) }
        forgetAX(id)
        netWorking.remove(id); netCarry.remove(id); netLastActive[id] = nil; netStart[id] = nil
        autoDone.remove(id); doneAt[id] = nil
        log("TERMINATED id=\(id)")
        publish()
    }

    private var axWasTrusted = true
    private var axSweepStarted: Date?
    /// A sweep that never comes back used to disable AX for the rest of the process:
    /// `axInFlight` is only cleared by the completion hop, so one wedged app was a
    /// permanent outage with no log line and no fallback.
    var axSweepTimeout: TimeInterval = 10
    /// Set once a wedged sweep has been given up on, so it is logged and released once.
    private var axWedged = false
    /// Identifies the sweep currently in flight, so a sweep that outlived a stop()/
    /// start() cycle cannot release the flag on behalf of the one dispatched after it.
    private var axSweepID: UInt64 = 0

    /// One AX sweep, off the main thread so a wedged app can never stall the island.
    private func pollAX() {
        guard axEnabled else { return }
        let trusted = AXStatus.trusted()
        if trusted != axWasTrusted {
            axWasTrusted = trusted
            log("AX TRUST → \(trusted)")
            if !trusted { for t in kTargets { forgetAX(t.id) }; publish() }
        }
        guard trusted else { return }
        if axInFlight {
            guard let s = axSweepStarted, Date().timeIntervalSince(s) > axSweepTimeout, !axWedged else { return }
            // The sweep queue is serial, so "start over" cannot mean dispatching another
            // sweep — it would only queue behind the wedge, one more every timeout,
            // against an app that is already not answering. Give up on this sweep's
            // result, release AX's claim so the fallback speaks, and wait for it to
            // actually return before asking again.
            log("AX sweep wedged for \(Int(Date().timeIntervalSince(s)))s — result discarded, fallback released")
            axWedged = true
            axGeneration &+= 1
            for t in kTargets { forgetAX(t.id) }
            publish()
            return
        }
        var pids: [(Int, pid_t)] = []
        var missing: [Int] = []
        for t in kTargets {
            if let p = AXStatus.pid(for: t) { pids.append((t.id, p)) } else { missing.append(t.id) }
        }
        for id in missing where axUsable.contains(id) || axBusy.contains(id) {
            targetTerminated(id, pid: nil)
        }
        guard !pids.isEmpty else { return }
        axInFlight = true
        axWedged = false
        axSweepStarted = Date()
        axSweepID &+= 1
        let gen = axGeneration, mine = axSweepID
        axQueue.async { [weak self] in
            var out: [Int: AXRead] = [:]
            var hits: [Int: String] = [:]
            for (id, pid) in pids {
                AXStatus.setTimeout(pid: pid, 0.4)   // every sweep: a relaunched app is a new pid
                if AXStatus.enableWebTree(pid: pid) {
                    continue   // Chromium needs a beat to build the tree; read it next sweep
                }
                let p = AXStatus.probe(pid: pid)
                out[id] = AXRead(busy: p.busy, nodes: p.nodes,
                                 running: p.running, settled: p.settled, complete: p.complete,
                                 openSession: p.openSession, openBusy: p.openBusy,
                                 openChecked: p.openChecked)
                if p.busy { hits[id] = p.hit }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                // The sweep is over whether or not anyone still wants its answer. It
                // releases the in-flight flag only if it is still the current sweep, and
                // a stale generation (stop(), or a wedge given up on) throws the answer away.
                if mine == self.axSweepID { self.axInFlight = false; self.axSweepStarted = nil }
                guard gen == self.axGeneration else { return }
                self.applyAX(out, hits: hits, now: Date())
            }
        }
    }

    /// A tree with only the window's own chrome in it (a handful of nodes) means the
    /// app never opted in — that app keeps using the fallback signals.
    func applyAX(_ res: [Int: (Bool, Int)], hits: [Int: String] = [:], now: Date) {
        applyAX(res.mapValues { AXRead(busy: $0.0, nodes: $0.1) }, hits: hits, now: now)
    }

    /// Weigh one sweep's evidence for one app. The whole point is the third answer:
    /// a sweep that simply failed to find the row must not be allowed to say "idle".
    func verdict(_ id: Int, _ r: AXRead, now: Date) -> AXVerdict {
        // The interrupt control is the only turn-level thing in the tree: it exists
        // for exactly as long as the turn does, because a turn is by definition
        // interruptible. The sidebar's "Running <name>" only tracks token emission,
        // so it drops out for the length of every tool call. Where the two disagree
        // about the visible session, the composer wins.
        // Measured over 796 sweeps the two agree 99.6% of the time, and where they
        // disagree each is covering the other's blind spot — so take the union for
        // "working" and require both to be quiet for "finished". The sidebar flips
        // the instant you hit send but goes quiet during a tool call; the interrupt
        // control spans the whole turn but takes a beat to appear. Letting either one
        // veto the other produced a false ✓ three seconds into a turn.
        let evidence = !r.running.isEmpty || !r.settled.isEmpty || (r.openChecked && r.openSession != nil)
        let tracking = !(axLive[id]?.isEmpty ?? true)
        // A tree we failed to read is not evidence that anything stopped.
        if !evidence && !r.complete && tracking { return .unknown }
        if evidence || tracking {
            return liveNames(id, r, now: now).isEmpty ? .finished : .working
        }
        // Apps with no session vocabulary (Cursor, Codex): a stop control means
        // working, and only a walk that actually finished may mean idle.
        if r.busy { return .working }
        return r.complete ? .finished : .unknown
    }

    func applyAX(_ res: [Int: AXRead], hits: [Int: String] = [:], now: Date) {
        for (id, r) in res {
            // What counts as "we can read this app": a real tree, a cached row, or a
            // named session. Each of those refreshes a timestamp.
            let good = r.nodes >= 20 || !r.running.isEmpty || !r.settled.isEmpty
            if good { axUsable.insert(id); axLastGood[id] = now }
            else if r.complete { axUsable.remove(id) }
            // The bug that made status "never match": a truncated/empty read neither
            // inserted nor removed, so once an app was usable it stayed authoritative
            // FOREVER through blind sweeps — which also suppressed the fallback. So an
            // app that has not produced a single readable sweep in axUsableTTL is no
            // longer trusted as the source of truth, and the fallback can take over.
            //
            // The timestamp must survive a bare-but-complete read. Clearing it there
            // made this branch unreachable in exactly the case it exists for: an app
            // mid-turn whose tree Chromium tears down answers with a complete tree of
            // one node, `axUsable` dropped, and the `continue` below skipped everything
            // that could have released `axBusy` — a spinner for the rest of the process.
            if let last = axLastGood[id], now.timeIntervalSince(last) >= axUsableTTL {
                // A turn we were watching is handed to the network to finish (see
                // handOver); everything else about the app is forgotten.
                let carry: (Date, [(String, Date)])? = axBusy.contains(id)
                    ? (axStart[id] ?? now,
                       (sessState[id] ?? [:]).filter { $0.value == .working }
                           .map { ($0.key, sessSince[id]?[$0.key] ?? now) })
                    : nil
                axUsable.remove(id); forgetAX(id)   // also clears axLastGood
                if let c = carry { handOver(id, start: c.0, sessions: c.1, now: now) }
            }
            guard axUsable.contains(id) else { continue }
            if let o = r.openSession { lastOpen[id] = o }
            let busy: Bool
            let v = verdict(id, r, now: now)
            applySessions(id, r, now: now)
            switch v {
            case .working:
                axUnknownSince[id] = nil
                if axBusy.contains(id) { busy = true }
                else {
                    // Not yet shown working: the app has to say so twice in a row.
                    let n = (axStreak[id] ?? 0) + 1
                    axStreak[id] = n
                    if n == 1 { axStreakStart[id] = now }
                    guard n >= axConfirmSweeps else { continue }
                    busy = true
                }
            case .finished:
                busy = false
                axUnknownSince[id] = nil
                axStreak[id] = 0
            case .unknown:
                // Hold whatever we last knew — but not forever.
                let since = axUnknownSince[id] ?? now
                axUnknownSince[id] = since
                if now.timeIntervalSince(since) >= axUnknownGrace {
                    axLive[id] = []; axUnknownSince[id] = nil
                    busy = false                       // watchdog: stop pretending
                } else {
                    continue                           // no state change at all
                }
            }
            if busy {
                if !axBusy.contains(id) {
                    axBusy.insert(id)
                    axStart[id] = axStreakStart[id] ?? now   // the turn began at the first sweep, not the confirming one
                    if autoDone.contains(id) { axOwed.insert(id) }   // debt, not payment
                    autoDone.remove(id)
                }
            } else if axBusy.contains(id) {
                axBusy.remove(id)
                let earned = now.timeIntervalSince(axStart[id] ?? now) >= axMinWork
                if earned || axOwed.contains(id) { autoDone.insert(id) }
                axOwed.remove(id)
            }
        }
        if !res.isEmpty {
            // the hit string is what makes a spurious BUSY identifiable after the fact —
            // without it every flicker in the log is indistinguishable from a real turn
            let why = hits.isEmpty ? "" : " hit=\(hits.map { "\($0.key):\(Self.redact($0.value))" }.sorted())"
            // which signal actually decided this sweep — sidebar or composer
            let op = res.compactMap { (k, v) -> String? in
                guard v.openChecked || v.openSession != nil else { return nil }
                return "\(k):\(v.openChecked ? (v.openBusy ? "STOP" : "idle") : "unchecked")/\(v.openSession == nil ? "?" : "named")"
            }.sorted()
            let opened = op.isEmpty ? " open=none" : " open=\(op)"
            let nw = netWorking.isEmpty ? "" : " net=\(netWorking.sorted())"
            // raw drained bytes for the apps AX can't read — proves the pipe is alive
            let nb = netLastBytes.filter { $0.value > 0 && !axUsable.contains($0.key) }
            let nbs = nb.isEmpty ? "" : " netB=\(nb.map { "\($0.key):\($0.value)" }.sorted())"
            let live = axLive.filter { !$0.value.isEmpty }
            let held = live.isEmpty ? "" : " live=\(live.map { "\($0.key):\(Self.redact($0.value.sorted().joined(separator: "|")))" }.sorted())"
            log("AX res=\(res.map { "\($0.key):\($0.value.busy ? "BUSY" : "idle")/\($0.value.nodes)n\($0.value.complete ? "" : "~")" }.sorted()) usable=\(axUsable.sorted()) busy=\(axBusy.sorted())\(opened)\(nw)\(nbs)\(held)\(why)")
        }
        rebuildSessions()
        publish(now: now)
    }

    /// One sampling step. `now` is injectable for the self-test.
    func tick(now: Date = Date()) {
        pollAX()
        // Real elapsed time, not the nominal second: if the run loop was starved the
        // drained bytes cover the whole gap, and dividing them by 1 s would turn an
        // idle app's keepalive trickle into a "working" burst.
        let dt = lastTick.map { max(0.25, now.timeIntervalSince($0)) } ?? 1
        lastTick = now
        applyNet(now: now, dt: dt)
        publish(now: now)
    }

    // MARK: network — finishes a turn AX lost sight of; never starts one.
    // Tokens streaming in from the cloud are what the a11y tree cannot see once a
    // backgrounded app has torn it down. For a while this signal was allowed to
    // *start* a turn on its own, and it lied constantly: over three working hours it
    // lit up 27 times with no turn behind it — Cursor syncing, ChatGPT phoning home —
    // and minted twelve false stamps on Cursor alone. Sustained inflow is not a turn.
    // What it can honestly say is "still streaming": so it only speaks for an app AX
    // watched *begin* a turn and then went dark on (handOver), keeping that turn alive
    // while bytes arrive and ending it after a long silence. An app that was idle when
    // its tree went dark shows nothing, however much it downloads.
    // `defaults write com.dd.notchdial statusNet -bool false` turns it off.
    var netEnabled = true
    var netOnRate: Double = 800      // bytes/sec that count as "still streaming"
    /// Silence before a handed-over turn is called finished. A tool call is silent
    /// for its whole length and the sidebar is unreadable by then — so this is the
    /// same minute a background session gets when we lose sight of it (bgSettleDelay),
    /// not a six-second debounce. Late is fine; a ✓ in the middle of a turn is not.
    var netQuiet: TimeInterval = 60
    private var netWorking: Set<Int> = []
    /// Apps whose turn the network is finishing on AX's behalf (always ⊆ netWorking).
    private var netCarry: Set<Int> = []
    private var netLastActive: [Int: Date] = [:]
    private var netStart: [Int: Date] = [:]

    /// last drained bytes, for the diagnostic log only
    private(set) var netLastBytes: [Int: Int] = [:]

    func applyNet(now: Date, bytesOverride: [Int: Int]? = nil, dt: TimeInterval = 1) {
        guard netEnabled else { return }
        // relaunch a nettop that died (no-op while it runs; rate-limited inside)
        if bytesOverride == nil { net?.start() }
        let bytes = bytesOverride ?? net?.drain() ?? [:]
        netLastBytes = bytes
        for t in kTargets {
            let rate = Double(bytes[t.id] ?? 0) / max(0.001, dt)
            // AX can read the app again (or it quit): the network has nothing to add.
            if axUsable.contains(t.id) || !isRunning(t) {
                netWorking.remove(t.id); netCarry.remove(t.id)
                continue
            }
            // Never a trigger. Without a turn handed over by AX, bytes are just bytes.
            guard netWorking.contains(t.id) else { continue }
            if rate >= netOnRate { netLastActive[t.id] = now; continue }
            guard now.timeIntervalSince(netLastActive[t.id] ?? now) >= netQuiet else { continue }
            // Quiet for a whole minute: the turn AX saw begin is over, and it earned its stamp.
            netWorking.remove(t.id); netCarry.remove(t.id)
            autoDone.insert(t.id)
            var st = sessState[t.id] ?? [:]
            for (n, s) in st where s == .working { st[n] = .done; sessSince[t.id]?[n] = now }
            sessState[t.id] = st
            rebuildSessions()
            log("NET QUIET id=\(t.id) → done after \(Int(now.timeIntervalSince(netStart[t.id] ?? now)))s")
        }
    }

    func publishForTest(now: Date) { publish(now: now) }

    private func publish(now: Date = Date()) {
        var out: [Int: WorkState] = [:]
        let front = frontmostBundlePath()
        let names = listStatusDir()
        for t in kTargets {
            let fs = fileState(t, in: names)
            // where AX can read the app's UI it is the only signal that counts
            let guessWorking = !axUsable.contains(t.id) && netWorking.contains(t.id)
            let live = axBusy.contains(t.id) || guessWorking
            var s: WorkState = .idle
            if fs == .working || live { s = .working }
            else if fs == .done || autoDone.contains(t.id) { s = .done }
            if fs == .idle && !live { s = .idle; autoDone.remove(t.id) }
            // The stamp is the completion feedback, so it must be seen. Give it
            // doneLinger seconds on screen; only then does being in that app count
            // as having acknowledged it. Away from the app it waits indefinitely.
            if s == .done {
                let at = doneAt[t.id] ?? now
                if doneAt[t.id] == nil { doneAt[t.id] = at }
                if front == t.path, now.timeIntervalSince(at) >= doneLinger {
                    autoDone.remove(t.id); axOwed.remove(t.id); removeFile(t)
                    for (n, ss) in sessState[t.id] ?? [:] where ss == .done {
                        sessState[t.id]?[n] = nil; sessSince[t.id]?[n] = nil
                    }
                    sessSeenAt[t.id] = nil
                    doneAt[t.id] = nil
                    s = .idle
                }
            } else {
                doneAt[t.id] = nil
            }
            // The app is still working on something else, and one of its finished
            // sessions is the one on screen in front of you. Sitting with it for the
            // same beat acknowledges that row — that row only; the others wait.
            if s == .working, front == t.path, let o = lastOpen[t.id], sessState[t.id]?[o] == .done {
                let at = sessSeenAt[t.id]?[o] ?? now
                sessSeenAt[t.id, default: [:]][o] = at
                if now.timeIntervalSince(at) >= doneLinger {
                    sessState[t.id]?[o] = nil; sessSince[t.id]?[o] = nil; sessSeenAt[t.id]?[o] = nil
                    rebuildSessions()
                }
            } else {
                sessSeenAt[t.id] = nil
            }
            if s != .idle { out[t.id] = s }
        }
        if out != states {
            log("PUBLISH \(out.map { "\($0.key)=\($0.value)" }.sorted())")
            for (id, v) in out where states[id] != v { since[id] = now }
            for id in since.keys where out[id] == nil { since[id] = nil }
            states = out
            onChange?(states)
            onTimes?(since)
        }
    }
}

// MARK: - Shared status glyphs

// dim orbit track + a glowing comet arc sweeping it — reads "alive" even at a glance
struct WorkSpinner: View {
    let tint: Color
    var size: CGFloat = 16
    var lineWidth: CGFloat = 2.4
    var body: some View {
        // This glyph spins for as long as any agent works — most of the day. Any
        // SwiftUI animation of it (repeatForever, TimelineView) re-runs the view graph
        // every frame in *this* process: measured ~3% CPU on a 16 pt glyph, sampled to
        // the display cycle. So the comet is two CAShapeLayers and the rotation is a
        // CABasicAnimation, which the window server runs by itself. App cost: nothing.
        CometLayerView(tint: tint, lineWidth: lineWidth)
            .frame(width: size, height: size)
    }
}

/// The comet spinner as Core Animation layers: a dim track, a glowing 32% arc, and an
/// infinite rotation the render server owns. See WorkSpinner for why.
struct CometLayerView: NSViewRepresentable {
    let tint: Color
    let lineWidth: CGFloat
    /// one revolution
    static let period: TimeInterval = 0.9

    final class Host: NSView {
        let track = CAShapeLayer()
        let comet = CAShapeLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            // layer-hosting (layer set before wantsLayer): the sublayers are ours
            let root = CALayer()
            root.masksToBounds = false            // the glow reaches past the bounds
            root.isGeometryFlipped = true         // y-down, like SwiftUI: same arc, same spin direction
            layer = root
            wantsLayer = true
            for l in [track, comet] {
                l.fillColor = nil
                l.lineCap = .round
                l.masksToBounds = false
                root.addSublayer(l)
            }
            comet.strokeStart = 0
            comet.strokeEnd = 0.32
            comet.shadowOffset = .zero
            comet.shadowRadius = 3.5
            comet.shadowOpacity = 1
            // the blurred comet is rasterized once; the rotation transforms the raster
            comet.shouldRasterize = true
        }
        required init?(coder: NSCoder) { fatalError() }
        override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); needsLayout = true }

        func apply(tint: NSColor, lineWidth: CGFloat) {
            track.lineWidth = lineWidth
            comet.lineWidth = lineWidth
            track.strokeColor = tint.withAlphaComponent(0.22).cgColor
            comet.strokeColor = tint.cgColor
            comet.shadowColor = tint.withAlphaComponent(0.85).cgColor
        }

        override func layout() {
            super.layout()
            let b = bounds
            guard b.width > 0, b.height > 0 else { return }
            let scale = window?.backingScaleFactor ?? 2
            // SwiftUI's Circle().stroke centers the stroke on the frame's inscribed circle
            // (half the line outside the frame); same here, nothing is clipped
            let path = CGPath(ellipseIn: b, transform: nil)
            for l in [track, comet] {
                l.frame = b
                l.path = path
                l.contentsScale = scale
                l.rasterizationScale = scale
            }
            // the arc starts at 3 o'clock on a CGPath ellipse; SwiftUI's Circle.trim
            // starts there too, so the glyph looks exactly as it did
            spin()
        }

        func spin() {
            guard comet.animation(forKey: "spin") == nil else { return }
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0
            a.toValue = 2 * Double.pi
            a.duration = CometLayerView.period
            a.repeatCount = .infinity
            a.isRemovedOnCompletion = false
            comet.add(a, forKey: "spin")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // a layer that left the tree drops its animations; a fresh window means start over
            comet.removeAnimation(forKey: "spin")
            needsLayout = true
        }
    }

    func makeNSView(context: Context) -> Host {
        let v = Host(frame: .zero)
        v.apply(tint: NSColor(tint), lineWidth: lineWidth)
        return v
    }

    func updateNSView(_ v: Host, context: Context) {
        v.apply(tint: NSColor(tint), lineWidth: lineWidth)
        v.needsLayout = true
    }
}

// A proper rubber stamp: double ring, heavy check, slams down with a twist.
/// How long this agent has been in its current state. Tabular figures so the digits
/// don't jitter as they tick, and only the text is inside the TimelineView — the icons
/// beside it stay out of the redraw, per the invariant that keeps this app cheap.
struct ElapsedLabel: View {
    var since: Date?
    var running: Bool
    static func text(_ d: TimeInterval) -> String {
        let s = max(0, Int(d))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
    var body: some View {
        if let since {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(Self.text(ctx.date.timeIntervalSince(since)))
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundColor(.white.opacity(running ? 0.5 : 0.32))
            }
        }
    }
}

struct RubberStamp: View {
    var size: CGFloat = 44
    var ink: Color = RubberStamp.green
    static let green = Color(red: 0.24, green: 0.78, blue: 0.42)
    @State private var slam = false
    var body: some View {
        ZStack {
            Circle().stroke(ink, lineWidth: max(2.0, size * 0.058))
            Circle().stroke(ink.opacity(0.6), lineWidth: max(0.9, size * 0.026))
                .padding(size * 0.10)
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.44, weight: .black))
                .foregroundColor(ink)
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(slam ? -14 : -2))
        // 2.4x overflowed every container this lives in: a 26pt stamp opened at 62pt,
        // painting over the neighbouring rows and, in the unclipped collapsed strip,
        // flashing a green ring onto the wallpaper. 1.5 still lands like a stamp.
        .scaleEffect(slam ? 1 : 1.5)
        .opacity(slam ? 0.95 : 0)
        .onAppear {
            slam = false
            withAnimation(.interpolatingSpring(stiffness: 420, damping: 21)) { slam = true }
        }
    }
}

// One badge, two dialects: working = the app-tinted comet spinner;
// done = the same rubber stamp everywhere — bright green on dark, ink on paper.
struct StatusBadge: View {
    let ws: WorkState
    let tint: Color
    var paper = false
    var size: CGFloat = 13
    static let stampInk = Color(red: 0.13, green: 0.50, blue: 0.27)
    var body: some View {
        switch ws {
        case .working:
            WorkSpinner(tint: tint, size: size, lineWidth: paper ? 2.0 : 2.2)
        case .done:
            RubberStamp(size: size + (paper ? 11 : 6), ink: paper ? Self.stampInk : RubberStamp.green)
        case .idle:
            EmptyView()
        }
    }
}
