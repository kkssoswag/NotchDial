import AppKit
import SwiftUI
import Darwin

// MARK: - Agent work status
// Two signals, merged per target:
//   1. File protocol (precise, agent-reported):  ~/.notchdial/status/<slug>
//      slug = target name lowercased, spaces → "-"  (codex, cursor, claude-code)
//      content = "working" | "done" | "idle"
//   2. CPU fallback (automatic): sustained utilization of the app's process tree,
//      sampled via libproc — no processes spawned, no permissions needed.
// A finished task shows ✓ until the user actually switches to that app (or keeps
// it frontmost for a beat) — then the state clears and the status file is removed.

enum WorkState: Equatable { case idle, working, done }

final class StatusMonitor {
    // tunables
    var cpuOn = 0.30                       // ≥ this utilization (1.0 = one core) is a hot sample
    var cpuOff = 0.06                      // ≤ this is a cold sample; between = ambiguous
    var hotNeeded = 6                      // consecutive hot samples to latch working (~9 s)
    var coldNeeded = 4                     // consecutive cold samples to release
    var minWorkForDone: TimeInterval = 8   // shorter bursts end silently, not with a ✓
    // The 8 s floor above exists to stop the *guessing* signals from stamping every
    // CPU blip. The Accessibility signal is exact — a turn that really ran deserves
    // its stamp however short it was, so it gets its own much lower floor.
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
    var onChange: (([Int: WorkState]) -> Void)?
    var onTimes: (([Int: Date]) -> Void)?

    // MARK: live heartbeat (thin-client sync)
    // Cloud-side agents barely touch local CPU — but their desktop apps commit the
    // streaming conversation to local storage as tokens arrive. The Claude app writes
    // claude.ai's IndexedDB (LevelDB) within ~a second of you hitting send, and keeps
    // appending for as long as the agent is thinking/answering. Watching that
    // directory's byte growth gives instant, truthful working/done — no hooks needed.
    static let heartbeatDirs: [String: String] = [   // bundle-path suffix → storage dir
        "/Claude.app": NSHomeDirectory() + "/Library/Application Support/Claude/IndexedDB/https_claude.ai_0.indexeddb.leveldb"
    ]
    // Real-world pattern (measured): commits arrive in intermittent batches, every
    // 2–5 s while a session streams, up to ~6 KB each, dead silent when idle.
    // OFF by default: the controlled experiment showed storage writes are *higher*
    // while the agent is idle, so this signal lies more often than it helps. Kept
    // behind `defaults write com.dd.notchdial statusHeartbeat -bool true` only for
    // apps that persist locally in a way that really does track their work.
    var hbEnabled = UserDefaults.standard.bool(forKey: "statusHeartbeat")
    var hbGrowthOn: UInt64 = 256          // bytes of growth that count as one commit event
    var hbEventGap: TimeInterval = 6      // two commits this close together = live session
    var hbBigCommit: UInt64 = 4096        // a single commit this large latches instantly (the send itself)
    var hbQuiet: TimeInterval = 12        // this long without commits = the session went quiet
    private var hbDir: [Int: String] = [:]
    private var hbPrevSize: [Int: UInt64] = [:]
    private var hbLastEvent: [Int: Date] = [:]
    private var hbPrevEvent: [Int: Date] = [:]
    private var hbActive: Set<Int> = []
    private var hbStart: [Int: Date] = [:]

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
    private var axStart: [Int: Date] = [:]
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
        guard !r.running.isEmpty || !r.settled.isEmpty else { return }
        var st = sessState[id] ?? [:]
        var sn = sessSince[id] ?? [:]
        let running = Set(r.running)
        for n in running where st[n] != .working {
            st[n] = .working; sn[n] = now
        }
        for n in r.settled {
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
        init(busy: Bool = false, nodes: Int = 0, running: [String] = [], settled: [String] = [], complete: Bool = true) {
            self.busy = busy; self.nodes = nodes
            self.running = running; self.settled = settled; self.complete = complete
        }
    }

    /// What one sweep is allowed to conclude.
    enum AXVerdict { case working, finished, unknown }

    private(set) var states: [Int: WorkState] = [:]   // only non-idle entries
    /// When each current state began — the ledger's whole reason to exist is telling
    /// you how long a thing has been running, and that needs a start, not just a flag.
    private(set) var since: [Int: Date] = [:]
    private var timer: Timer?
    private var prevCPU: [Int: Double] = [:]
    private var prevTime: Date?
    private var hot: [Int: Int] = [:]
    private var cold: [Int: Int] = [:]
    private var autoWorking: Set<Int> = []
    private var autoDone: Set<Int> = []
    private var workStart: [Int: Date] = [:]
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
    static func redact(_ s: String) -> String {
        guard !logLabels, !s.isEmpty else { return s }
        return "‹\(s.count) chars›"
    }
    private static let stamper: ISO8601DateFormatter = ISO8601DateFormatter()
    private static let logDir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/NotchDial")
    static let logPath = (logDir as NSString).appendingPathComponent("status.log")
    private static let logMaxBytes = 4 << 20
    private var logHandle: FileHandle?
    /// Held so stop() can remove it. Toggling the feature off and on used to stack
    /// a fresh observer each time, against the same live monitor.
    private var activateObserver: NSObjectProtocol?
    private func log(_ s: String) {
        guard Self.debug else { return }
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
        let d = UserDefaults.standard
        if d.object(forKey: "statusCpuOn") != nil { cpuOn = d.double(forKey: "statusCpuOn") }
        for t in kTargets {
            for (suffix, dir) in Self.heartbeatDirs where t.path.hasSuffix(suffix) {
                if FileManager.default.fileExists(atPath: dir) { hbDir[t.id] = dir }
            }
        }
        let tm = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
        log("START axEnabled=\(axEnabled) trusted=\(AXStatus.trusted()) hb=\(hbEnabled) hbDirs=\(hbDir.count) pids=\(kTargets.compactMap { AXStatus.pid(for: $0) })")
        // Exact status needs one Accessibility grant. Ask once, ever; the menu item
        // stays available for later. Without it we quietly fall back to guessing.
        if axEnabled, !AXStatus.trusted(), !UserDefaults.standard.bool(forKey: "axPromptShown") {
            UserDefaults.standard.set(true, forKey: "axPromptShown")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { _ = AXStatus.trusted(prompt: true) }
        }
        // switching to a finished app acknowledges its ✓
        if let o = activateObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        activateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self = self,
                  let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let path = app.bundleURL?.path else { return }
            for t in kTargets where t.path == path && self.states[t.id] == .done {
                let shown = self.doneAt[t.id].map { Date().timeIntervalSince($0) } ?? 0
                let wait = max(1.5, self.doneLinger - shown)
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                    guard let self = self, self.states[t.id] == .done else { return }
                    self.clearDone(t)
                }
            }
        }
        tick()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        states = [:]; autoWorking = []; autoDone = []
        hot = [:]; cold = [:]; prevCPU = [:]; prevTime = nil; doneAt = [:]
        hbPrevSize = [:]; hbLastEvent = [:]; hbPrevEvent = [:]; hbActive = []; hbStart = [:]
        axBusy = []; axUsable = []; axStart = [:]; axOwed = []
        axLive = [:]; axUnknownSince = [:]; since = [:]
        sessState = [:]; sessSince = [:]; sessions = [:]; onSessions?([:])
        axGeneration &+= 1; axInFlight = false; axSweepStarted = nil
        if let o = activateObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        activateObserver = nil
        onChange?(states)
    }

    func clearDone(_ t: AppTarget) {
        autoDone.remove(t.id)
        axOwed.remove(t.id)      // seen — the debt is paid
        for (n, s) in sessState[t.id] ?? [:] where s == .done { sessState[t.id]?[n] = nil; sessSince[t.id]?[n] = nil }
        rebuildSessions()
        doneAt[t.id] = nil
        removeFile(t)
        publish()
    }

    private func removeFile(_ t: AppTarget) {
        for f in statusFiles(t) {
            try? FileManager.default.removeItem(atPath: (dirPath as NSString).appendingPathComponent(f))
        }
    }

    /// Every file belonging to this target: the bare slug, and one per session
    /// (`claude-code.<session>`). Concurrent sessions each report for themselves —
    /// sharing one file meant session A's "done" erased the fact that B was still
    /// working, which is the same bug the Accessibility path had.
    private func statusFiles(_ t: AppTarget) -> [String] {
        let base = Self.slug(t)
        var out = [base, base + ".txt"]
        if let names = try? FileManager.default.contentsOfDirectory(atPath: dirPath) {
            out += names.filter { $0.hasPrefix(base + ".") && $0 != base + ".txt" }.sorted()
        }
        return out
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

    private func fileState(_ t: AppTarget) -> WorkState? {
        var agg: WorkState? = nil
        for f in statusFiles(t) {
            let p = (dirPath as NSString).appendingPathComponent(f)
            guard let (w, age) = word(inFile: p) else { continue }
            // any session working wins; a stamp only survives if nothing is working
            if w == "working" && age < workingTTL { return .working }
            if w == "done" && age < doneTTL { agg = .done }
            if w == "idle" && agg == nil { agg = .idle }
        }
        return agg
    }

    // one heartbeat measurement + state step; injectable for the self-test
    func hbSample(_ id: Int, size: UInt64, now: Date) {
        let prev = hbPrevSize[id] ?? size
        hbPrevSize[id] = size
        let delta = size > prev ? size - prev : 0
        if delta >= hbGrowthOn {   // one storage commit
            let previous = hbLastEvent[id]
            hbPrevEvent[id] = previous
            hbLastEvent[id] = now
            let paired = previous.map { now.timeIntervalSince($0) <= hbEventGap } ?? false
            if !hbActive.contains(id), paired || delta >= hbBigCommit {
                hbActive.insert(id)
                autoDone.remove(id)
                hbStart[id] = previous ?? now
            }
        }
        if hbActive.contains(id), let last = hbLastEvent[id], now.timeIntervalSince(last) >= hbQuiet {
            hbActive.remove(id)
            if now.timeIntervalSince(hbStart[id] ?? now) >= minWorkForDone {
                autoDone.insert(id)
            }
        }
    }

    private func hbTotalSize(_ dir: String) -> UInt64 {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return 0 }
        var s: UInt64 = 0
        for n in names {
            if let a = try? fm.attributesOfItem(atPath: (dir as NSString).appendingPathComponent(n)),
               let sz = a[.size] as? UInt64 { s += sz }
        }
        return s
    }

    /// Everything we believe about one app, dropped. Called when the app quits and
    /// when the Accessibility grant goes away — two situations that used to strand
    /// the indicator: a quit app never appears in a sweep again, so nothing could
    /// ever clear its spinner, and an untrusted app kept `axUsable`, which is what
    /// suppresses the fallback signals. Either way the notch kept asserting
    /// something it had no way to still know.
    func forgetAX(_ id: Int) {
        axUsable.remove(id); axBusy.remove(id); axOwed.remove(id)
        axLive[id] = nil; axStart[id] = nil; axUnknownSince[id] = nil
        sessState[id] = nil; sessSince[id] = nil
        rebuildSessions()
    }

    func targetTerminated(_ id: Int, pid: pid_t?) {
        if let p = pid { AXStatus.forget(pid: p) }
        forgetAX(id)
        // a spinner for an app that is gone is just a lie with a shorter lifespan
        autoWorking.remove(id); hot[id] = 0; cold[id] = 0
        log("TERMINATED id=\(id)")
        publish()
    }

    private var axWasTrusted = true
    private var axSweepStarted: Date?
    /// A sweep that never comes back used to disable AX for the rest of the process:
    /// `axInFlight` is only cleared by the completion hop, so one wedged app was a
    /// permanent outage with no log line and no fallback.
    var axSweepTimeout: TimeInterval = 10

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
            guard let s = axSweepStarted, Date().timeIntervalSince(s) > axSweepTimeout else { return }
            log("AX sweep wedged for \(Int(Date().timeIntervalSince(s)))s — starting over")
            axGeneration &+= 1
            axInFlight = false
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
        axSweepStarted = Date()
        let gen = axGeneration
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
                                 running: p.running, settled: p.settled, complete: p.complete)
                if p.busy { hits[id] = p.hit }
            }
            DispatchQueue.main.async {
                guard let self = self, gen == self.axGeneration else { return }
                self.applyAX(out, hits: hits, now: Date())
                self.axInFlight = false
                self.axSweepStarted = nil
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
    func verdict(_ id: Int, _ r: AXRead) -> AXVerdict {
        if !r.running.isEmpty {                       // the row says live — done deal
            axLive[id] = Set(r.running)
            return .working
        }
        if let live = axLive[id], !live.isEmpty {
            // We know exactly which rows to look for. Only their *finished* labels
            // settle the question; anything else is a tree we failed to read.
            let settled = Set(r.settled)
            let stillOut = live.subtracting(settled)
            if stillOut.isEmpty { axLive[id] = []; return .finished }
            axLive[id] = stillOut
            return .unknown
        }
        // Apps with no session vocabulary (Cursor, Codex): a stop control means
        // working, and only a walk that actually finished may mean idle.
        if r.busy { return .working }
        return r.complete ? .finished : .unknown
    }

    func applyAX(_ res: [Int: AXRead], hits: [Int: String] = [:], now: Date) {
        for (id, r) in res {
            // A cached single-element read is worth far more than a big walk, so
            // usability can no longer be judged by node count alone — and a sweep we
            // were not allowed to make says nothing about whether the app is readable.
            if r.nodes >= 20 || !r.running.isEmpty || !r.settled.isEmpty { axUsable.insert(id) }
            else if r.complete { axUsable.remove(id) }
            guard axUsable.contains(id) else { continue }
            applySessions(id, r, now: now)
            let busy: Bool
            switch verdict(id, r) {
            case .working:
                busy = true
                axUnknownSince[id] = nil
            case .finished:
                busy = false
                axUnknownSince[id] = nil
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
                    axStart[id] = now
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
            let live = axLive.filter { !$0.value.isEmpty }
            let held = live.isEmpty ? "" : " live=\(live.map { "\($0.key):\(Self.redact($0.value.sorted().joined(separator: "|")))" }.sorted())"
            log("AX res=\(res.map { "\($0.key):\($0.value.busy ? "BUSY" : "idle")/\($0.value.nodes)n\($0.value.complete ? "" : "~")" }.sorted()) usable=\(axUsable.sorted()) busy=\(axBusy.sorted())\(held)\(why)")
        }
        rebuildSessions()
        publish(now: now)
    }

    // one sampling step; cpuSample/now injectable for the self-test
    func tick(cpuSample: [Int: Double]? = nil, now: Date = Date()) {
        pollAX()
        if hbEnabled {
            for (id, dir) in hbDir where !axUsable.contains(id) { hbSample(id, size: hbTotalSize(dir), now: now) }
        }
        // Sampling CPU means a proc_pidpath syscall for every process on the machine
        // — ~875 of them here, once a second, on the main thread. It is the fallback
        // for apps the Accessibility signal cannot read, so when there is no such app
        // the entire sweep is answered and then thrown away. Ask only when someone
        // is actually listening.
        let needsCPU = kTargets.contains { !axUsable.contains($0.id) && $0.isRunning }
        let cpu = cpuSample ?? (needsCPU ? Self.cpuSecondsByTarget() : [:])
        if cpuSample == nil && !needsCPU { prevCPU = [:]; prevTime = nil }
        let front = frontmostBundlePath()
        if let pt = prevTime, now > pt {
            let dt = now.timeIntervalSince(pt)
            for t in kTargets {
                let prev = prevCPU[t.id] ?? (cpu[t.id] ?? 0)
                let util = max(0, (cpu[t.id] ?? 0) - prev) / dt
                // The frontmost app is being *used*, which is not the same as *working*:
                // typing, scrolling and rendering all burn CPU. Auto detection therefore
                // only ever applies to background apps; file-reported states always win.
                if axUsable.contains(t.id) {
                    hot[t.id] = 0                 // AX knows the truth for this app
                    autoWorking.remove(t.id)
                } else if front == t.path {
                    hot[t.id] = 0
                    autoWorking.remove(t.id)
                } else if util >= cpuOn { hot[t.id, default: 0] += 1; cold[t.id] = 0 }
                else if util <= cpuOff { cold[t.id, default: 0] += 1; hot[t.id] = 0 }
                else { hot[t.id] = 0; cold[t.id] = 0 }
                if !autoWorking.contains(t.id), hot[t.id, default: 0] >= hotNeeded {
                    autoWorking.insert(t.id)
                    autoDone.remove(t.id)
                    workStart[t.id] = now.addingTimeInterval(-Double(hotNeeded) * dt)
                }
                if autoWorking.contains(t.id), cold[t.id, default: 0] >= coldNeeded {
                    autoWorking.remove(t.id)
                    if now.timeIntervalSince(workStart[t.id] ?? now) >= minWorkForDone {
                        autoDone.insert(t.id)
                    }
                }
            }
        }
        prevCPU = cpu
        prevTime = now
        publish(now: now)
    }

    private func publish(now: Date = Date()) {
        var out: [Int: WorkState] = [:]
        let front = frontmostBundlePath()
        for t in kTargets {
            let fs = fileState(t)
            // where AX can read the app's UI it is the only signal that counts
            let guessWorking = axUsable.contains(t.id)
                ? false
                : (autoWorking.contains(t.id) || hbActive.contains(t.id))
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
                    doneAt[t.id] = nil
                    s = .idle
                }
            } else {
                doneAt[t.id] = nil
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

    // cumulative CPU seconds per target's process tree — pure syscalls, nothing spawned.
    // Processes are matched by executable-path prefix: every helper of an app bundle
    // (Electron renderers, XPC services) lives under <bundle>.app/…
    static func cpuSecondsByTarget() -> [Int: Double] {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let toSec = Double(tb.numer) / Double(tb.denom) / 1_000_000_000
        var n = proc_listallpids(nil, 0)
        guard n > 0 else { return [:] }
        var pids = [Int32](repeating: 0, count: Int(n) + 64)
        n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard n > 0 else { return [:] }
        var res: [Int: Double] = [:]
        var buf = [CChar](repeating: 0, count: 4096)
        for i in 0..<Int(n) {
            let pid = pids[i]
            guard pid > 0 else { continue }
            let len = proc_pidpath(pid, &buf, UInt32(buf.count))
            guard len > 0 else { continue }
            let path = String(cString: buf)
            for t in kTargets where path.hasPrefix(t.path + "/") {
                var ru = rusage_info_current()
                let ok = withUnsafeMutablePointer(to: &ru) { p in
                    p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                        proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                    }
                }
                if ok == 0 {
                    res[t.id, default: 0] += Double(ru.ri_user_time &+ ru.ri_system_time) * toSec
                }
                break
            }
        }
        return res
    }
}

// MARK: - Shared status glyphs

// dim orbit track + a glowing comet arc sweeping it — reads "alive" even at a glance
struct WorkSpinner: View {
    let tint: Color
    var size: CGFloat = 16
    var lineWidth: CGFloat = 2.4
    @State private var spin = false
    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: 0.32)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(spin ? 360 : 0))
                .shadow(color: tint.opacity(0.85), radius: 3.5)
        }
        .frame(width: size, height: size)
        .onAppear {
            spin = false
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
        }
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
