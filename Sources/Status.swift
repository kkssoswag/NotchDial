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
    private var axBusy: Set<Int> = []          // agents the UI says are working
    private var axUsable: Set<Int> = []        // apps whose AX tree we can actually read
    private var axStart: [Int: Date] = [:]

    private(set) var states: [Int: WorkState] = [:]   // only non-idle entries
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

    // `defaults write com.dd.notchdial statusDebug -bool true` → /tmp/nd-status.log
    static let debug = UserDefaults.standard.bool(forKey: "statusDebug")
    private func log(_ s: String) {
        guard Self.debug else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let d = "\(stamp) \(s)\n".data(using: .utf8) else { return }
        let p = "/tmp/nd-status.log"
        if let fh = FileHandle(forWritingAtPath: p) {
            fh.seekToEndOfFile(); fh.write(d); try? fh.close()
        } else {
            try? d.write(to: URL(fileURLWithPath: p))
        }
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
        NSWorkspace.shared.notificationCenter.addObserver(
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
        axBusy = []; axUsable = []; axStart = [:]
        onChange?(states)
    }

    func clearDone(_ t: AppTarget) {
        autoDone.remove(t.id)
        doneAt[t.id] = nil
        removeFile(t)
        publish()
    }

    private func removeFile(_ t: AppTarget) {
        for f in [Self.slug(t), Self.slug(t) + ".txt"] {
            try? FileManager.default.removeItem(atPath: (dirPath as NSString).appendingPathComponent(f))
        }
    }

    private func fileState(_ t: AppTarget) -> WorkState? {
        let fm = FileManager.default
        for f in [Self.slug(t), Self.slug(t) + ".txt"] {
            let p = (dirPath as NSString).appendingPathComponent(f)
            guard let data = fm.contents(atPath: p),
                  let raw = String(data: data, encoding: .utf8) else { continue }
            let word = raw.split(whereSeparator: { $0.isNewline || $0 == " " }).first.map(String.init)?.lowercased() ?? ""
            let mtime = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date
            let age = mtime.map { Date().timeIntervalSince($0) } ?? .infinity
            if word == "working" && age < workingTTL { return .working }
            if word == "done" && age < doneTTL { return .done }
            if word == "idle" { return .idle }
        }
        return nil
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

    /// One AX sweep, off the main thread so a wedged app can never stall the island.
    private func pollAX() {
        guard axEnabled, !axInFlight, AXStatus.trusted() else { return }
        var pids: [(Int, pid_t)] = []
        for t in kTargets { if let p = AXStatus.pid(for: t) { pids.append((t.id, p)) } }
        guard !pids.isEmpty else { return }
        axInFlight = true
        axQueue.async { [weak self] in
            var out: [Int: (Bool, Int)] = [:]
            for (id, pid) in pids {
                if AXStatus.enableWebTree(pid: pid) {
                    AXStatus.setTimeout(pid: pid, 0.4)
                    continue   // Chromium needs a beat to build the tree; read it next sweep
                }
                let p = AXStatus.probe(pid: pid)
                out[id] = (p.busy, p.nodes)
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.applyAX(out, now: Date())
                self.axInFlight = false
            }
        }
    }

    /// A tree with only the window's own chrome in it (a handful of nodes) means the
    /// app never opted in — that app keeps using the fallback signals.
    func applyAX(_ res: [Int: (Bool, Int)], now: Date) {
        for (id, r) in res {
            let (busy, nodes) = r
            if nodes >= 20 { axUsable.insert(id) } else { axUsable.remove(id) }
            guard axUsable.contains(id) else { continue }
            if busy {
                if !axBusy.contains(id) {
                    axBusy.insert(id)
                    axStart[id] = now
                    autoDone.remove(id)
                }
            } else if axBusy.contains(id) {
                axBusy.remove(id)
                if now.timeIntervalSince(axStart[id] ?? now) >= axMinWork {
                    autoDone.insert(id)
                }
            }
        }
        if !res.isEmpty { log("AX res=\(res.map { "\($0.key):\($0.value.0 ? "BUSY" : "idle")/\($0.value.1)n" }.sorted()) usable=\(axUsable.sorted()) busy=\(axBusy.sorted())") }
        publish(now: now)
    }

    // one sampling step; cpuSample/now injectable for the self-test
    func tick(cpuSample: [Int: Double]? = nil, now: Date = Date()) {
        pollAX()
        if hbEnabled {
            for (id, dir) in hbDir where !axUsable.contains(id) { hbSample(id, size: hbTotalSize(dir), now: now) }
        }
        let cpu = cpuSample ?? Self.cpuSecondsByTarget()
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
                    autoDone.remove(t.id); removeFile(t)
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
            states = out
            onChange?(states)
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
        .scaleEffect(slam ? 1 : 2.4)
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
