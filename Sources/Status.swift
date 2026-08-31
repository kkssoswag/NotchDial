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
    var cpuOn = 0.20                       // ≥ this utilization (1.0 = one core) is a hot sample
    var cpuOff = 0.06                      // ≤ this is a cold sample; between = ambiguous
    var hotNeeded = 4                      // consecutive hot samples to latch working (~6 s)
    var coldNeeded = 4                     // consecutive cold samples to release
    var minWorkForDone: TimeInterval = 8   // shorter bursts end silently, not with a ✓
    var workingTTL: TimeInterval = 30 * 60 // stale "working" files are ignored (crashed agent)
    var doneTTL: TimeInterval = 12 * 3600

    var dirPath = (NSHomeDirectory() as NSString).appendingPathComponent(".notchdial/status")
    var frontmostBundlePath: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleURL?.path }
    var onChange: (([Int: WorkState]) -> Void)?

    private(set) var states: [Int: WorkState] = [:]   // only non-idle entries
    private var timer: Timer?
    private var prevCPU: [Int: Double] = [:]
    private var prevTime: Date?
    private var hot: [Int: Int] = [:]
    private var cold: [Int: Int] = [:]
    private var autoWorking: Set<Int> = []
    private var autoDone: Set<Int> = []
    private var workStart: [Int: Date] = [:]
    private var doneFrontTicks: [Int: Int] = [:]

    static func slug(_ t: AppTarget) -> String {
        t.name.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    func start() {
        guard timer == nil else { return }
        let d = UserDefaults.standard
        if d.object(forKey: "statusCpuOn") != nil { cpuOn = d.double(forKey: "statusCpuOn") }
        let tm = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
        // switching to a finished app acknowledges its ✓
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self = self,
                  let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let path = app.bundleURL?.path else { return }
            for t in kTargets where t.path == path && self.states[t.id] == .done {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
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
        hot = [:]; cold = [:]; prevCPU = [:]; prevTime = nil; doneFrontTicks = [:]
        onChange?(states)
    }

    func clearDone(_ t: AppTarget) {
        autoDone.remove(t.id)
        doneFrontTicks[t.id] = nil
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

    // one sampling step; cpuSample/now injectable for the self-test
    func tick(cpuSample: [Int: Double]? = nil, now: Date = Date()) {
        let cpu = cpuSample ?? Self.cpuSecondsByTarget()
        if let pt = prevTime, now > pt {
            let dt = now.timeIntervalSince(pt)
            for t in kTargets {
                let prev = prevCPU[t.id] ?? (cpu[t.id] ?? 0)
                let util = max(0, (cpu[t.id] ?? 0) - prev) / dt
                if util >= cpuOn { hot[t.id, default: 0] += 1; cold[t.id] = 0 }
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
        publish()
    }

    private func publish() {
        var out: [Int: WorkState] = [:]
        let front = frontmostBundlePath()
        for t in kTargets {
            let fs = fileState(t)
            var s: WorkState = .idle
            if fs == .working || autoWorking.contains(t.id) { s = .working }
            else if fs == .done || autoDone.contains(t.id) { s = .done }
            if fs == .idle && !autoWorking.contains(t.id) { s = .idle; autoDone.remove(t.id) }
            // ✓ while you are already looking at that app → acknowledge after ~3 s
            if s == .done, front == t.path {
                doneFrontTicks[t.id, default: 0] += 1
                if doneFrontTicks[t.id, default: 0] >= 2 {
                    autoDone.remove(t.id); removeFile(t)
                    doneFrontTicks[t.id] = nil
                    s = .idle
                }
            } else {
                doneFrontTicks[t.id] = nil
            }
            if s != .idle { out[t.id] = s }
        }
        if out != states {
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

struct WorkSpinner: View {
    let tint: Color
    var size: CGFloat = 11
    var lineWidth: CGFloat = 1.8
    @State private var spin = false
    var body: some View {
        Circle()
            .trim(from: 0, to: 0.74)
            .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .shadow(color: tint.opacity(0.5), radius: 3)
            .onAppear {
                spin = false
                withAnimation(.linear(duration: 1.05).repeatForever(autoreverses: false)) { spin = true }
            }
    }
}

struct DoneCheck: View {
    var size: CGFloat = 11
    static let green = Color(red: 0.30, green: 0.86, blue: 0.40)
    @State private var pop = false
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: size, weight: .black))
            .foregroundColor(Self.green)
            .shadow(color: Self.green.opacity(0.85), radius: 4)
            .scaleEffect(pop ? 1 : 0.25)
            .opacity(pop ? 1 : 0)
            .onAppear {
                pop = false
                withAnimation(.interpolatingSpring(stiffness: 420, damping: 15)) { pop = true }
            }
    }
}

// One badge, three dialects: dark modes get a glowing glyph, paper gets stamped ink.
struct StatusBadge: View {
    let ws: WorkState
    let tint: Color
    var paper = false
    var size: CGFloat = 11
    static let stampInk = Color(red: 0.13, green: 0.50, blue: 0.27)
    @State private var stamped = false
    var body: some View {
        switch ws {
        case .working:
            WorkSpinner(tint: tint, size: size, lineWidth: paper ? 1.6 : 1.8)
        case .done:
            if paper {
                ZStack {
                    Circle().stroke(Self.stampInk, lineWidth: 1.4)
                        .frame(width: size + 6, height: size + 6)
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.74, weight: .heavy))
                        .foregroundColor(Self.stampInk)
                }
                .rotationEffect(.degrees(-12))
                .opacity(stamped ? 0.92 : 0)
                .scaleEffect(stamped ? 1 : 1.9)
                .onAppear {
                    stamped = false
                    withAnimation(.interpolatingSpring(stiffness: 500, damping: 22)) { stamped = true }
                }
            } else {
                DoneCheck(size: size)
            }
        case .idle:
            EmptyView()
        }
    }
}
