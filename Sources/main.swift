import AppKit
import SwiftUI
import ServiceManagement

// MARK: - Notch geometry
struct NotchGeometry {
    let screen: NSScreen
    let notchRect: NSRect
    let windowRect: NSRect
    static let panelSize = NSSize(width: 660, height: 340)

    static func find() -> NotchGeometry? {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) else { return nil }
        let f = screen.frame
        let topInset = screen.safeAreaInsets.top
        var left = f.midX - 105
        var right = f.midX + 105
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            left = l.maxX
            right = r.minX
        }
        let notch = NSRect(x: left, y: f.maxY - topInset, width: right - left, height: topInset)
        let win = NSRect(x: f.midX - panelSize.width / 2, y: f.maxY - panelSize.height,
                         width: panelSize.width, height: panelSize.height)
        return NotchGeometry(screen: screen, notchRect: notch, windowRect: win)
    }
}

// MARK: - Shared state
final class IslandState: ObservableObject {
    enum Phase: Equatable { case collapsed, expanded, launching }
    @Published var phase: Phase = .collapsed
    @Published var rotation: Double = 0
    @Published var mode: Int = 0
    @Published var notchWidth: CGFloat = 210
    @Published var notchHeight: CGFloat = 32
    @Published var runningIDs: Set<Int> = []
    @Published var work: [Int: WorkState] = [:]   // agent status: only non-idle entries
    @Published var showCard = false               // status card, revealed by hovering the widened bar
    /// Row order frozen while the ledger is open, so nothing moves under the cursor.
    @Published var cardLatch: [Int] = []
    /// When each agent entered its current state, for the ledger's elapsed counter.
    @Published var workSince: [Int: Date] = [:]
    /// The sessions behind each app's aggregate state. One app runs several at once,
    /// and "Claude Code · working" tells you nothing when three of them are.
    @Published var workSessions: [Int: [StatusMonitor.SessionInfo]] = [:]
    /// Rows currently worth showing, in slot order.
    var liveRows: [Int] { kTargets.compactMap { work[$0.id] != nil && work[$0.id] != .idle ? $0.id : nil } }

    var centeredIndex: Int {
        let n = kTargets.count
        let i = Int(rotation.rounded()) % n
        return (i + n) % n
    }
    var selectedTarget: AppTarget { kTargets[centeredIndex] }

    /// One knob for how large the switcher draws. The three modes were tuned against
    /// each other, so this scales the whole composition rather than any single number:
    /// their internal proportions survive untouched, the island just sits lighter on
    /// the screen. Everything that hit-tests the island multiplies by this too.
    static let uiScale: CGFloat = 0.85

    /// The box each mode was composed inside. Modes lay out at these numbers and are
    /// only *rendered* smaller, so a mode that fills the space it is offered (Neon)
    /// doesn't get shrunk twice.
    func baseSize() -> CGSize {
        if mode == 0 { return CGSize(width: 620, height: 196) }
        if mode == 2 { return CGSize(width: 470, height: 285) }
        return CGSize(width: 470, height: 180)
    }

    func openSize() -> CGSize {
        let b = baseSize(), s = IslandState.uiScale
        return CGSize(width: (b.width * s).rounded(), height: (b.height * s).rounded())
    }
}

// MARK: - App delegate
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let state = IslandState()
    let statusMon = StatusMonitor()
    var panel: NSPanel?
    var geo: NotchGeometry?
    var statusItem: NSStatusItem?
    var pollTimer: Timer?
    var enabled = true
    let pinned = CommandLine.arguments.contains("--pin")
    var lastRunCheck = Date.distantPast
    var modeItems: [NSMenuItem] = []
    var axItem: NSMenuItem?
    // gesture state
    var gestureAcc: CGFloat = 0
    var stepsInGesture = 0
    var idleWork: DispatchWorkItem?
    var flightTimer: Timer?
    var instantSteps = false
    var dryLaunch = false

    func animateRotation(to target: Double, duration: TimeInterval) {
        flightTimer?.invalidate()
        let start = state.rotation
        let t0 = Date()
        let tm = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] tm in
            guard let self = self else { tm.invalidate(); return }
            let x = min(1, Date().timeIntervalSince(t0) / duration)
            let p = 1 - pow(1 - x, 3)
            self.state.rotation = start + (target - start) * p
            if x >= 1 { tm.invalidate(); self.flightTimer = nil; self.state.rotation = target }
        }
        RunLoop.main.add(tm, forMode: .common)
        flightTimer = tm
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        UserDefaults.standard.register(defaults: ["statusEnabled": true])
        if UserDefaults.standard.object(forKey: "lastIndex") != nil {
            state.rotation = Double(UserDefaults.standard.integer(forKey: "lastIndex"))
        } else { state.rotation = 1 }
        state.mode = UserDefaults.standard.integer(forKey: "mode")
        if CommandLine.arguments.contains("--neon") { state.mode = 1 }
        if CommandLine.arguments.contains("--enable-login") {
            if #available(macOS 13.0, *) {
                do { try SMAppService.mainApp.register(); print("LOGIN ITEM STATUS: \(SMAppService.mainApp.status == .enabled ? "enabled" : "pending")") }
                catch { print("LOGIN ITEM ERROR: \(error)") }
            }
            exit(0)
        }
        // pre-warm heavy assets so the first hover is instant
        DispatchQueue.global(qos: .userInitiated).async {
            _ = SpaceAssets.nebulaCG
            _ = SpaceAssets.nebulaCG2
            _ = SpaceAssets.planets
        }
        DispatchQueue.main.async {
            for t in kTargets { _ = IconCache.icon(for: t) }
        }
        // event-driven running indicators (no polling)
        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            RunningApps.invalidate()
            self?.refreshRunning(force: true)
        }
        wnc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let gone = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            let pid = gone?.processIdentifier
            let path = gone?.bundleURL?.path
            RunningApps.invalidate()
            guard let self = self else { return }
            // Everything AX believes about this app is now about a process that does
            // not exist — including the pid, which macOS will hand to someone else.
            if let p = pid { AXStatus.forget(pid: p) }
            for t in kTargets where t.path == path { self.statusMon.targetTerminated(t.id, pid: pid) }
            self.refreshRunning(force: true)
        }
        if CommandLine.arguments.contains("--dumpplanets") {
            for (i, cg) in SpaceAssets.planets.enumerated() {
                if let cg = cg {
                    let rep = NSBitmapImageRep(cgImage: cg)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/planet_\(i).png"))
                }
            }
            exit(0)
        }
        if CommandLine.arguments.contains("--selftest") { runSelfTest(); return }
        if CommandLine.arguments.contains("--cpuprobe") { runCpuProbe(); return }
        if CommandLine.arguments.contains("--axprobe") { runAxProbe(dump: false); return }
        if CommandLine.arguments.contains("--axdump") { runAxProbe(dump: true); return }
        if CommandLine.arguments.contains("--hovertest") {
            geo = NotchGeometry.find()
            if let g = geo { state.notchWidth = g.notchRect.width; state.notchHeight = g.notchRect.height }
            rebuildPanel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.runHoverTest() }
            return
        }
        rebuildPanel()
        setupStatusItem()
        statusMon.onChange = { [weak self] st in self?.state.work = st }
        statusMon.onTimes = { [weak self] ts in self?.state.workSince = ts }
        statusMon.onSessions = { [weak self] ss in self?.state.workSessions = ss }
        if UserDefaults.standard.bool(forKey: "statusEnabled") { statusMon.start() }
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in self?.mouseMoved() }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] e in self?.mouseMoved(); return e }
        let t = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in self?.mouseMoved() }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            self?.handleScroll(e)
            return e
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.rebuildPanel()
        }
        if pinned { expand() }
        if CommandLine.arguments.contains("--clicktest") {
            dryLaunch = true
            enabled = false   // deterministic: the real cursor must not collapse the island mid-test
            expand()
            let xs: [CGFloat] = [165, 235, 305]
            for (k, x) in xs.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8 + Double(k) * 1.0) { [weak self] in
                    guard let self = self, let p = self.panel else { return }
                    let pt = NSPoint(x: (p.frame.width - 470) / 2 + x, y: p.frame.height - 150)
                    let ts = ProcessInfo.processInfo.systemUptime
                    if let dn = NSEvent.mouseEvent(with: .leftMouseDown, location: pt, modifierFlags: [],
                                                   timestamp: ts, windowNumber: p.windowNumber, context: nil,
                                                   eventNumber: 0, clickCount: 1, pressure: 1) { p.sendEvent(dn) }
                    if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: pt, modifierFlags: [],
                                                   timestamp: ts + 0.05, windowNumber: p.windowNumber, context: nil,
                                                   eventNumber: 0, clickCount: 1, pressure: 1) { p.sendEvent(up) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.4) { NSApp.terminate(nil) }
        }
        if CommandLine.arguments.contains("--launchtest") {
            Launcher.timing = true
            enabled = false
            expand()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self = self else { return }
                self.launch(kTargets[self.state.centeredIndex])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { NSApp.terminate(nil) }
        }
        if CommandLine.arguments.contains("--teartest") {
            enabled = false
            state.mode = 2
            expand()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self, let p = self.panel else { return }
                let pt = NSPoint(x: (p.frame.width - 470) / 2 + 235, y: p.frame.height - 150)
                let ts = ProcessInfo.processInfo.systemUptime
                if let dn = NSEvent.mouseEvent(with: .leftMouseDown, location: pt, modifierFlags: [],
                                               timestamp: ts, windowNumber: p.windowNumber, context: nil,
                                               eventNumber: 0, clickCount: 1, pressure: 1) { p.sendEvent(dn) }
                if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: pt, modifierFlags: [],
                                               timestamp: ts + 0.05, windowNumber: p.windowNumber, context: nil,
                                               eventNumber: 0, clickCount: 1, pressure: 1) { p.sendEvent(up) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { NSApp.terminate(nil) }
        }
        if let di = CommandLine.arguments.firstIndex(of: "--demo"), di + 1 < CommandLine.arguments.count {
            let m = Int(CommandLine.arguments[di + 1]) ?? 2
            dryLaunch = true
            enabled = false
            state.mode = m
            func synthClick(_ xIsland: CGFloat, _ yTop: CGFloat, after t: Double) {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                    guard let self = self, let p = self.panel else { return }
                    let pt = NSPoint(x: (p.frame.width - 470) / 2 + xIsland, y: p.frame.height - yTop)
                    let ts = ProcessInfo.processInfo.systemUptime
                    if let dn = NSEvent.mouseEvent(with: .leftMouseDown, location: pt, modifierFlags: [],
                                                   timestamp: ts, windowNumber: p.windowNumber, context: nil,
                                                   eventNumber: 0, clickCount: 1, pressure: 1) { p.sendEvent(dn) }
                    if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: pt, modifierFlags: [],
                                                   timestamp: ts + 0.05, windowNumber: p.windowNumber, context: nil,
                                                   eventNumber: 0, clickCount: 1, pressure: 1) { p.sendEvent(up) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.expand() }
            if m == 2 {
                synthClick(165, 150, after: 2.2)
                synthClick(235, 150, after: 3.6)
                synthClick(305, 150, after: 5.0)
                DispatchQueue.main.asyncAfter(deadline: .now() + 6.4) { [weak self] in self?.collapse() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 7.4) { NSApp.terminate(nil) }
            } else if m == 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in self?.step(1) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.8) { [weak self] in self?.step(1) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) { [weak self] in self?.step(-1) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6.6) { [weak self] in self?.collapse() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 7.6) { NSApp.terminate(nil) }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { [weak self] in self?.step(1) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in self?.step(1) }
                synthClick(235, 120, after: 5.1)
                DispatchQueue.main.asyncAfter(deadline: .now() + 6.3) { [weak self] in self?.collapse() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 7.2) { NSApp.terminate(nil) }
            }
        }
        if CommandLine.arguments.contains("--statustest") {
            // scripted status choreography through the real file-protocol pipeline
            enabled = false
            let dir = statusMon.dirPath
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            func put(_ slug: String, _ v: String, after t: Double) {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                    try? v.write(toFile: (dir as NSString).appendingPathComponent(slug), atomically: true, encoding: .utf8)
                }
            }
            put("claude-code", "working", after: 0.6)   // one spinner
            put("cursor", "working", after: 3.4)        // two spinners
            put("claude-code", "done", after: 6.2)      // ✓ pops beside the spinner
            DispatchQueue.main.asyncAfter(deadline: .now() + 9.2) { [weak self] in self?.expand() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12.4) { [weak self] in self?.collapse() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 13.6) {
                for s in ["claude-code", "cursor", "codex"] {
                    try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent(s))
                }
                NSApp.terminate(nil)
            }
        }
        if CommandLine.arguments.contains("--cardtest") {
            // renders the grown status ledger (spinner + stamp rows) and verifies a row click
            enabled = false
            dryLaunch = true
            let dir = statusMon.dirPath
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? "working".write(toFile: (dir as NSString).appendingPathComponent("cursor"), atomically: true, encoding: .utf8)
            try? "done".write(toFile: (dir as NSString).appendingPathComponent("claude-code"), atomically: true, encoding: .utf8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
                self?.state.showCard = true
                self?.panel?.ignoresMouseEvents = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.6) { [weak self] in
                // synthetic click on the second ledger row (Claude Code · done)
                guard let self = self, let p = self.panel else { return }
                let yTop = self.state.notchHeight + 34 + 1 + 17
                let pt = NSPoint(x: p.frame.width / 2, y: p.frame.height - yTop)
                let ts = ProcessInfo.processInfo.systemUptime
                if let dn = NSEvent.mouseEvent(with: .leftMouseDown, location: pt, modifierFlags: [],
                                               timestamp: ts, windowNumber: p.windowNumber, context: nil,
                                               eventNumber: 0, clickCount: 1, pressure: 1) { p.sendEvent(dn) }
                if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: pt, modifierFlags: [],
                                               timestamp: ts + 0.05, windowNumber: p.windowNumber, context: nil,
                                               eventNumber: 0, clickCount: 1, pressure: 1) { p.sendEvent(up) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.4) { [weak self] in self?.state.showCard = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) {
                for s in ["claude-code", "cursor", "codex"] {
                    try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent(s))
                }
                NSApp.terminate(nil)
            }
        }
        if let fi = CommandLine.arguments.firstIndex(of: "--film"), fi + 1 < CommandLine.arguments.count {
            let dir = CommandLine.arguments[fi + 1]
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            enabled = false
            expand()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.step(1)
                var frame = 0
                let tm = Timer(timeInterval: 0.07, repeats: true) { tm in
                    if let v = self?.panel?.contentView,
                       let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        if let d = rep.representation(using: .png, properties: [:]) {
                            try? d.write(to: URL(fileURLWithPath: dir + "/frame_" + String(format: "%02d", frame) + ".png"))
                        }
                    }
                    frame += 1
                    if frame >= 16 { tm.invalidate(); NSApp.terminate(nil) }
                }
                RunLoop.main.add(tm, forMode: .common)
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snap"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            enabled = false
            expand()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
                if let v = self?.panel?.contentView,
                   let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: path))
                    }
                }
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: gesture-based scroll: one flick = exactly one step
    func handleScroll(_ e: NSEvent) {
        let raw = abs(e.scrollingDeltaX) >= abs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY
        let isMomentum = !e.momentumPhase.isEmpty
        let ended = e.phase.contains(.ended) || e.phase.contains(.cancelled)
        gestureScroll(raw: raw, isMomentum: isMomentum, ended: ended)
        idleWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.gestureAcc = 0
            self.stepsInGesture = 0
            self.settle()
        }
        idleWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30, execute: w)
    }

    func gestureScroll(raw: CGFloat, isMomentum: Bool, ended: Bool) {
        guard state.phase == .expanded else { return }
        if state.mode == 2 { return }   // ticket mode: click only, no scroll
        if isMomentum { return }                      // momentum never moves selection
        if ended {
            gestureAcc = 0
            stepsInGesture = 0
            settle()
            return
        }
        guard raw != 0 else { return }
        if gestureAcc != 0 && (gestureAcc > 0) != (raw > 0) { gestureAcc = 0 }
        gestureAcc += raw
        // live rubber feedback (orbit only, tiny, direct)
        if state.mode == 0 && stepsInGesture == 0 && flightTimer == nil {
            let rubber = Double(max(-0.14, min(0.14, gestureAcc / 620)))
            state.rotation = state.rotation.rounded() - rubber
        }
        let threshold: CGFloat = stepsInGesture == 0 ? 55 : 170
        if abs(gestureAcc) > threshold {
            let dir: Double = gestureAcc > 0 ? -1 : 1
            gestureAcc = 0
            stepsInGesture += 1
            step(dir)
        }
    }

    /// One step = one duration, whoever asked for it. Each mode has its own because
    /// each mode's motion is a different physical idea: a planet crossing space, paper
    /// feeding, a sign relighting.
    static func stepDuration(_ mode: Int) -> Double { mode == 0 ? 0.85 : (mode == 2 ? 0.4 : 0.18) }

    func step(_ dir: Double) {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        let target = state.rotation.rounded() + dir
        if instantSteps { state.rotation = target }
        else { animateRotation(to: target, duration: Self.stepDuration(state.mode)) }
        UserDefaults.standard.set(wrapIndex(target), forKey: "lastIndex")
    }

    func wrapIndex(_ r: Double) -> Int {
        let n = kTargets.count
        let i = Int(r.rounded()) % n
        return (i + n) % n
    }

    func settle() {
        guard state.phase == .expanded else { return }
        if flightTimer == nil && state.rotation != state.rotation.rounded() {
            animateRotation(to: state.rotation.rounded(), duration: 0.2)
        }
    }

    // MARK: self test — replays real trackpad flick profiles, verifies 1 flick = 1 step
    func runSelfTest() {
        instantSteps = true
        state.phase = .expanded
        state.mode = 0
        state.rotation = 1
        var results: [String] = []
        func run(_ name: String, _ fingers: [CGFloat], _ momentum: [CGFloat], expect: Int) {
            let r0 = state.rotation.rounded()
            for d in fingers { gestureScroll(raw: d, isMomentum: false, ended: false) }
            gestureScroll(raw: 0, isMomentum: false, ended: true)
            for d in momentum { gestureScroll(raw: d, isMomentum: true, ended: false) }
            let moved = Int(state.rotation.rounded() - r0)
            let ok = moved == expect
            results.append("\(ok ? "PASS" : "FAIL") \(name): moved \(moved), expect \(expect)")
        }
        run("轻扫", [6, 10, 16, 22, 20, 12, 6], [28, 22, 16, 10, 6, 3], expect: -1)
        run("重扫", [10, 20, 34, 44, 40, 30, 16, 8], [60, 48, 36, 24, 14, 8, 4], expect: -1)
        run("反向轻扫", [-8, -14, -20, -18, -10], [-24, -16, -8], expect: 1)
        run("慢速短拖", [4, 6, 8, 8, 8, 8, 8, 8, 8], [], expect: -1)
        run("超长拖动(两格)", Array(repeating: 12, count: 22), [], expect: -2)
        state.mode = 1
        run("霓虹模式轻扫", [8, 14, 20, 18, 10], [22, 14, 6], expect: -1)
        // hit-region logic: clicks pass through everywhere except real content
        geo = NotchGeometry.find()
        if let g = geo {
            state.notchWidth = g.notchRect.width
            state.notchHeight = g.notchRect.height
            let top = g.windowRect.maxY
            let cx = g.windowRect.midX
            func chk(_ name: String, _ p: NSPoint, _ expect: Bool) {
                let ok = clickableRegionContains(p) == expect
                results.append("\(ok ? "PASS" : "FAIL") 命中区·\(name)")
            }
            state.mode = 2
            let s = IslandState.uiScale
            let spacing = max(70, (state.notchWidth - 60) / 2) * s
            chk("菜单栏穿透", NSPoint(x: cx + 200, y: top - 10), false)
            chk("票带可点", NSPoint(x: cx, y: top - 150), true)
            chk("侧票带可点", NSPoint(x: cx + spacing, y: top - 150), true)
            chk("票缝穿透", NSPoint(x: cx + spacing / 2, y: top - 150), spacing / 2 <= 37 * s)
            chk("岛下方穿透", NSPoint(x: cx, y: top - 330), false)
            // entry point locks the mode — the shape must not change under a moving cursor
            func hi(_ open: Bool, _ zone: Int, _ near: Bool) -> AppDelegate.HoverIntent {
                AppDelegate.hoverIntent(ledgerOpen: open, zone: zone, nearLedger: near)
            }
            results.append(hi(true, 1, true) == .holdLedger
                ? "PASS 入口锁·开着账单划过刘海不切换" : "FAIL 入口锁·开着账单划过刘海不切换")
            results.append(hi(false, 1, false) == .openSwitcher
                ? "PASS 入口锁·刘海入口开切换器" : "FAIL 入口锁·刘海入口开切换器")
            results.append(hi(false, 2, false) == .openLedger
                ? "PASS 入口锁·延长区入口开账单" : "FAIL 入口锁·延长区入口开账单")
            results.append(hi(true, 0, false) == .dropLedger
                ? "PASS 入口锁·离开轮廓即收" : "FAIL 入口锁·离开轮廓即收")
            // The notch is the one spot the cursor crosses by accident all day: every
            // trip between the left menus and the right status icons goes through it.
            // The trigger must be smaller than the notch, not larger.
            let nr = g.notchRect
            let tr = AppDelegate.triggerRect(nr)
            // Never WIDER than the notch — the old region ran 8pt past it on each
            // side, which is how it caught traffic that was only passing by.
            results.append(tr.width <= nr.width && tr.height <= nr.height
                ? "PASS 触发区·不宽于刘海本身" : "FAIL 触发区·不宽于刘海本身")
            // …and never narrower either: the cursor is invisible over the cutout, so
            // people aim at the edge of the black shape, not at its middle.
            results.append(tr.contains(NSPoint(x: nr.minX + 2, y: nr.maxY - 2))
                && tr.contains(NSPoint(x: nr.maxX - 2, y: nr.maxY - 2))
                ? "PASS 触发区·刘海边缘可触发" : "FAIL 触发区·刘海边缘可触发")
            results.append(!tr.contains(NSPoint(x: nr.minX - 6, y: nr.maxY - 2))
                && !tr.contains(NSPoint(x: nr.maxX + 6, y: nr.maxY - 2))
                ? "PASS 触发区·刘海之外不触发" : "FAIL 触发区·刘海之外不触发")
            // The top edge is where the pointer LANDS when you throw it at the notch,
            // so it must stay live — height cannot separate intent, only dwell can.
            results.append(tr.contains(NSPoint(x: nr.midX, y: nr.maxY - 2))
                ? "PASS 触发区·顶边仍然可触发" : "FAIL 触发区·顶边仍然可触发")
            results.append(tr.contains(NSPoint(x: nr.midX, y: nr.minY + 4))
                ? "PASS 触发区·刘海正中下方触发" : "FAIL 触发区·刘海正中下方触发")
            state.mode = 0
            chk("星轨主体可点", NSPoint(x: cx, y: top - 120), true)
            chk("星轨侧翼穿透", NSPoint(x: cx + 340, y: top - 120), false)
        }
        // work-status state machine: synthetic CPU samples + a temp status dir, no timers
        let mon = StatusMonitor()
        mon.dirPath = NSTemporaryDirectory() + "nd-status-selftest-\(ProcessInfo.processInfo.processIdentifier)"
        try? FileManager.default.createDirectory(atPath: mon.dirPath, withIntermediateDirectories: true)
        mon.frontmostBundlePath = { nil }
        mon.doneLinger = 2
        var mNow = Date(timeIntervalSince1970: 1_000_000)
        var mCum = 0.0
        func mtick(_ util: Double) {
            mCum += util * 1.5
            mNow = mNow.addingTimeInterval(1.5)
            mon.tick(cpuSample: [0: mCum], now: mNow)
        }
        mtick(0)
        for _ in 0..<3 { mtick(0) }
        results.append(mon.states[0] == nil ? "PASS 状态·初始空闲" : "FAIL 状态·初始空闲")
        for _ in 0..<5 { mtick(0.9) }
        results.append(mon.states[0] == nil ? "PASS 状态·短脉冲不触发" : "FAIL 状态·短脉冲不触发")
        mtick(0.9)
        results.append(mon.states[0] == .working ? "PASS 状态·持续高载→工作中" : "FAIL 状态·持续高载→工作中")
        for _ in 0..<6 { mtick(0.9) }
        for _ in 0..<4 { mtick(0) }
        results.append(mon.states[0] == .done ? "PASS 状态·收工→对勾" : "FAIL 状态·收工→对勾")
        mon.frontmostBundlePath = { kTargets[0].path }
        mtick(0); mtick(0)
        results.append(mon.states[0] == nil ? "PASS 状态·看过后清除" : "FAIL 状态·看过后清除")
        for _ in 0..<10 { mtick(0.9) }   // still frontmost: heavy use must never read as work
        results.append(mon.states[0] == nil ? "PASS 状态·前台使用不误报" : "FAIL 状态·前台使用不误报")
        mon.frontmostBundlePath = { nil }
        let fp = (mon.dirPath as NSString).appendingPathComponent("claude-code")
        try? "working".write(toFile: fp, atomically: true, encoding: .utf8)
        mtick(0)
        results.append(mon.states[2] == .working ? "PASS 状态·文件working" : "FAIL 状态·文件working")
        try? "done".write(toFile: fp, atomically: true, encoding: .utf8)
        mtick(0)
        results.append(mon.states[2] == .done ? "PASS 状态·文件done" : "FAIL 状态·文件done")
        mon.frontmostBundlePath = { kTargets[2].path }
        mtick(0); mtick(0)
        let fileGone = !FileManager.default.fileExists(atPath: fp)
        results.append(mon.states[2] == nil && fileGone ? "PASS 状态·确认后清理文件" : "FAIL 状态·确认后清理文件")
        try? FileManager.default.removeItem(atPath: mon.dirPath)
        // heartbeat: streaming storage commits latch fast; one-off writes never trigger
        let hb = StatusMonitor()
        hb.dirPath = NSTemporaryDirectory() + "nd-hb-selftest-\(ProcessInfo.processInfo.processIdentifier)"
        hb.frontmostBundlePath = { nil }
        hb.doneLinger = 2
        var hNow = Date(timeIntervalSince1970: 2_000_000)
        var hSize: UInt64 = 100_000
        func htick(_ grow: UInt64) {
            hSize += grow
            hNow = hNow.addingTimeInterval(1.0)
            hb.hbSample(2, size: hSize, now: hNow)
            hb.tick(cpuSample: [:], now: hNow)
        }
        htick(0)
        htick(2000)
        htick(2000)
        results.append(hb.states[2] == .working ? "PASS 状态·心跳→秒亮" : "FAIL 状态·心跳→秒亮")
        for _ in 0..<4 { htick(1600); htick(0); htick(0) }   // real cadence: a commit every ~3 s
        results.append(hb.states[2] == .working ? "PASS 状态·间歇提交保持亮" : "FAIL 状态·间歇提交保持亮")
        for _ in 0..<12 { htick(0) }
        results.append(hb.states[2] == .done ? "PASS 状态·心跳停→出章" : "FAIL 状态·心跳停→出章")
        hb.frontmostBundlePath = { kTargets[2].path }
        htick(0); htick(0)
        htick(300); htick(0); htick(0)
        results.append(hb.states[2] == nil ? "PASS 状态·单次写不误亮" : "FAIL 状态·单次写不误亮")
        for _ in 0..<8 { htick(0) }
        htick(5000)
        results.append(hb.states[2] == .working ? "PASS 状态·大提交→即亮" : "FAIL 状态·大提交→即亮")
        // AX label logic — the whole busy decision, checked without touching any app
        let axCases: [(String, Bool)] = [
            ("Running 可用工具检查", true), ("running notchdial build", true),
            ("Stop response", true), ("停止生成", true), ("Interrupt", true),
            ("Mark as unread Running shoes", false), ("Stop sharing", false),
            ("New", false), ("Projects", false), ("此按钮也可以执行缩放窗口的操作", false),
        ]
        let axBad = axCases.filter { AXStatus.labelIsBusy($0.0) != $0.1 }.map { $0.0 }
        results.append(axBad.isEmpty ? "PASS 状态·AX标签判定" : "FAIL 状态·AX标签判定 \(axBad)")
        // an AX tree that only yields window chrome must not be trusted
        let axm = StatusMonitor()
        axm.dirPath = NSTemporaryDirectory() + "nd-ax-selftest-\(ProcessInfo.processInfo.processIdentifier)"
        axm.frontmostBundlePath = { nil }
        axm.axEnabled = false
        var aNow = Date(timeIntervalSince1970: 3_000_000)
        func atick(_ busy: Bool, nodes: Int, step: TimeInterval = 2) {
            aNow = aNow.addingTimeInterval(step)
            axm.applyAX([0: (busy, nodes)], now: aNow)
        }
        atick(true, nodes: 4)
        results.append(axm.states[0] == nil ? "PASS 状态·空AX树不采信" : "FAIL 状态·空AX树不采信")
        atick(true, nodes: 90)
        results.append(axm.states[0] == .working ? "PASS 状态·AX→立刻工作中" : "FAIL 状态·AX→立刻工作中")
        for _ in 0..<5 { atick(true, nodes: 90) }
        atick(false, nodes: 90)
        results.append(axm.states[0] == .done ? "PASS 状态·AX收工→出章" : "FAIL 状态·AX收工→出章")
        axm.clearDone(kTargets[0])   // nothing pending: a bare flicker must mint nothing
        atick(true, nodes: 90); atick(false, nodes: 90, step: 1)
        results.append(axm.states[0] == nil ? "PASS 状态·AX瞬时抖动不出章" : "FAIL 状态·AX瞬时抖动不出章")
        // a genuinely short turn still earns its stamp — AX is exact, not a guess
        atick(true, nodes: 90); atick(true, nodes: 90); atick(false, nodes: 90)
        results.append(axm.states[0] == .done ? "PASS 状态·AX短回合也盖章" : "FAIL 状态·AX短回合也盖章")
        // Measured at a real turn boundary (03:00:24 done → 03:00:25 BUSY/209n →
        // 03:00:26 idle): one spurious sweep used to wipe a stamp nobody had seen
        // yet, because the burst was too short to mint a replacement. The spinner
        // may cover the ✓ while it lasts, but the ✓ has to come back.
        axm.clearDone(kTargets[0])
        for _ in 0..<5 { atick(true, nodes: 90) }
        atick(false, nodes: 90)
        atick(true, nodes: 209, step: 1)
        let hidden = axm.states[0] == .working
        atick(false, nodes: 219, step: 1)
        results.append(hidden && axm.states[0] == .done ? "PASS 状态·抖动不抹掉未看的章" : "FAIL 状态·抖动不抹掉未看的章")

        // ---- three-valued reading: busy / finished / UNKNOWN -------------------
        // The bug this pins: an Electron AX tree comes back partial while the app
        // re-renders, and a partial tree that fails to find the row was being read
        // as "the agent stopped". Absence of evidence is not evidence of absence.
        let vm = StatusMonitor()
        vm.dirPath = NSTemporaryDirectory() + "nd-verdict-selftest-\(ProcessInfo.processInfo.processIdentifier)"
        vm.hbEnabled = false
        vm.bgSettleDelay = 60       // evidence, not timing — and explicit settles skip the wait
        vm.frontmostBundlePath = { "/nonexistent" }
        var vNow = Date(timeIntervalSince1970: 5_000_000)
        func vtick(_ r: StatusMonitor.AXRead, _ step: TimeInterval = 1) {
            vNow = vNow.addingTimeInterval(step)
            vm.applyAX([0: r], now: vNow)
        }
        let sess = "可用工具检查"
        vtick(.init(nodes: 90, running: [sess]))
        results.append(vm.states[0] == .working ? "PASS 状态·会话行在跑→工作中" : "FAIL 状态·会话行在跑→工作中")
        // the tree loses the row mid-turn (exactly what the log showed at 03:04:21)
        for _ in 0..<6 { vtick(.init(nodes: 219, complete: false)) }
        results.append(vm.states[0] == .working ? "PASS 状态·残缺树不判收工" : "FAIL 状态·残缺树不判收工")
        // even a COMPLETE tree that simply lacks the row proves nothing about it
        for _ in 0..<6 { vtick(.init(nodes: 219, settled: ["别的会话"])) }
        results.append(vm.states[0] == .working ? "PASS 状态·别的会话收工不算数" : "FAIL 状态·别的会话收工不算数")
        // only the row's own finished face settles it
        vtick(.init(nodes: 219, settled: [sess]))
        results.append(vm.states[0] == .done ? "PASS 状态·本会话收工→盖章" : "FAIL 状态·本会话收工→盖章")
        // and holding "working" cannot last forever if the row never returns
        let wm = StatusMonitor()
        wm.dirPath = NSTemporaryDirectory() + "nd-watchdog-selftest-\(ProcessInfo.processInfo.processIdentifier)"
        wm.hbEnabled = false
        wm.axUnknownGrace = 10
        wm.bgSettleDelay = 0
        wm.frontmostBundlePath = { "/nonexistent" }
        var wNow = Date(timeIntervalSince1970: 6_000_000)
        func wtick(_ r: StatusMonitor.AXRead, _ step: TimeInterval = 1) {
            wNow = wNow.addingTimeInterval(step)
            wm.applyAX([0: r], now: wNow)
        }
        wtick(.init(nodes: 90, running: [sess]))
        for _ in 0..<5 { wtick(.init(nodes: 219, complete: false)) }
        let stillHeld = wm.states[0] == .working
        for _ in 0..<8 { wtick(.init(nodes: 219, complete: false)) }
        results.append(stillHeld && wm.states[0] != .working ? "PASS 状态·未知超时看守生效" : "FAIL 状态·未知超时看守生效")
        // An app that quits never appears in another sweep, so nothing could ever
        // clear its spinner — the notch kept asserting a process that was gone.
        let qm = StatusMonitor()
        qm.dirPath = NSTemporaryDirectory() + "nd-quit-selftest-\(ProcessInfo.processInfo.processIdentifier)"
        qm.hbEnabled = false
        qm.frontmostBundlePath = { "/nonexistent" }
        var qNow = Date(timeIntervalSince1970: 7_000_000)
        qNow = qNow.addingTimeInterval(1)
        qm.applyAX([0: .init(nodes: 90, running: [sess])], now: qNow)
        let wasWorking = qm.states[0] == .working
        qm.targetTerminated(0, pid: nil)
        results.append(wasWorking && qm.states[0] == nil ? "PASS 状态·退出即清除" : "FAIL 状态·退出即清除")
        // Losing the grant must release AX's exclusive claim, or the fallbacks it
        // suppresses stay suppressed and the last reading is frozen in place.
        let tm2 = StatusMonitor()
        tm2.dirPath = NSTemporaryDirectory() + "nd-trust-selftest-\(ProcessInfo.processInfo.processIdentifier)"
        tm2.hbEnabled = false
        tm2.frontmostBundlePath = { "/nonexistent" }
        var tNow = Date(timeIntervalSince1970: 8_000_000)
        tNow = tNow.addingTimeInterval(1)
        tm2.applyAX([0: .init(nodes: 90, running: [sess])], now: tNow)
        let heldBefore = tm2.states[0] == .working
        tm2.forgetAX(0)
        tm2.applyAX([Int: StatusMonitor.AXRead](), now: tNow.addingTimeInterval(1))
        results.append(heldBefore && tm2.states[0] == nil ? "PASS 状态·失去授权即释放" : "FAIL 状态·失去授权即释放")
        // One app, several sessions. The probe used to stop at the first live row, so
        // whichever one finished first stamped ✓ for the whole app while the others
        // were still going — measured live with two Claude sessions running.
        let mm = StatusMonitor()
        mm.dirPath = NSTemporaryDirectory() + "nd-multi-selftest-\(ProcessInfo.processInfo.processIdentifier)"
        mm.hbEnabled = false
        mm.bgSettleDelay = 0        // ditto: aggregation, not timing
        mm.frontmostBundlePath = { "/nonexistent" }
        var mNow2 = Date(timeIntervalSince1970: 9_000_000)
        func mtick(_ running: [String], _ settled: [String], _ step: TimeInterval = 1) {
            mNow2 = mNow2.addingTimeInterval(step)
            mm.applyAX([0: .init(nodes: 90, running: running, settled: settled)], now: mNow2)
        }
        let a = "会话甲", b = "会话乙"
        mtick([a, b], [])
        mtick([a, b], []); mtick([a, b], [])
        results.append(mm.sessions[0]?.count == 2 ? "PASS 多会话·两个都记上" : "FAIL 多会话·两个都记上")
        mtick([b], [a])                      // A finished, B still going
        let stillBusy = mm.states[0] == .working
        let aDone = mm.sessions[0]?.first { $0.name == a }?.state == .done
        let bWorking = mm.sessions[0]?.first { $0.name == b }?.state == .working
        results.append(stillBusy && aDone && bWorking
            ? "PASS 多会话·一个收工不代表整体收工" : "FAIL 多会话·一个收工不代表整体收工")
        mtick([], [a, b])                    // now both are done
        results.append(mm.states[0] == .done ? "PASS 多会话·全部收工才盖章" : "FAIL 多会话·全部收工才盖章")
        mm.clearDone(kTargets[0])
        results.append((mm.sessions[0] ?? []).isEmpty ? "PASS 多会话·确认后清空明细" : "FAIL 多会话·确认后清空明细")
        // The file protocol had the identical bug: one file per app meant whichever
        // session finished first wrote "done" over the fact that another was working.
        let fm2 = StatusMonitor()
        fm2.dirPath = NSTemporaryDirectory() + "nd-files-selftest-\(ProcessInfo.processInfo.processIdentifier)"
        fm2.axEnabled = false; fm2.hbEnabled = false
        fm2.frontmostBundlePath = { "/nonexistent" }
        try? FileManager.default.createDirectory(atPath: fm2.dirPath, withIntermediateDirectories: true)
        let slug = StatusMonitor.slug(kTargets[0])
        func put(_ suffix: String, _ w: String) {
            try? w.write(toFile: (fm2.dirPath as NSString).appendingPathComponent("\(slug).\(suffix)"),
                         atomically: true, encoding: .utf8)
        }
        var fNow = Date(timeIntervalSince1970: 10_000_000)
        put("s1", "done"); put("s2", "working")
        fNow = fNow.addingTimeInterval(1); fm2.tick(cpuSample: [:], now: fNow)
        results.append(fm2.states[0] == .working ? "PASS 多会话·文件里有人在跑就算跑" : "FAIL 多会话·文件里有人在跑就算跑")
        put("s2", "done")
        fNow = fNow.addingTimeInterval(1); fm2.tick(cpuSample: [:], now: fNow)
        results.append(fm2.states[0] == .done ? "PASS 多会话·文件全收工才盖章" : "FAIL 多会话·文件全收工才盖章")
        // THE root cause, pinned. "Running <name>" tracks token emission, so it drops
        // out for the whole length of a tool call and the status flickers several
        // times per turn. The interrupt control does not: a turn is interruptible for
        // exactly as long as it lasts. Where they disagree about the visible session,
        // the composer wins.
        let om = StatusMonitor()
        om.dirPath = NSTemporaryDirectory() + "nd-open-selftest-\(ProcessInfo.processInfo.processIdentifier)"
        om.hbEnabled = false
        om.frontmostBundlePath = { "/nonexistent" }
        var oNow = Date(timeIntervalSince1970: 11_000_000)
        func otick(_ r: StatusMonitor.AXRead, _ step: TimeInterval = 1) {
            oNow = oNow.addingTimeInterval(step); om.applyAX([0: r], now: oNow)
        }
        let open = "可用工具检查"
        otick(.init(nodes: 90, running: [open], openSession: open, openBusy: true, openChecked: true))
        otick(.init(nodes: 90, running: [open], openSession: open, openBusy: true, openChecked: true))
        // mid-turn tool call: the sidebar goes quiet, the stop button does not
        otick(.init(nodes: 90, running: [], settled: [open], openSession: open, openBusy: true, openChecked: true))
        otick(.init(nodes: 90, running: [], settled: [open], openSession: open, openBusy: true, openChecked: true))
        results.append(om.states[0] == .working
            ? "PASS 回合·工具调用中不算收工" : "FAIL 回合·工具调用中不算收工")
        // the turn really ends: the interrupt control goes away
        otick(.init(nodes: 90, running: [], settled: [open], openSession: open, openBusy: false, openChecked: true))
        results.append(om.states[0] == .done ? "PASS 回合·停止键消失才收工" : "FAIL 回合·停止键消失才收工")
        // The other blind spot, measured live: at 09:15:05 the user hit send, the
        // sidebar flipped instantly, and the interrupt control had not appeared yet.
        // Letting the composer veto the sidebar stamped ✓ three seconds into a turn.
        om.clearDone(kTargets[0])
        otick(.init(nodes: 90, running: [open], openSession: open, openBusy: false, openChecked: true))
        otick(.init(nodes: 90, running: [open], openSession: open, openBusy: false, openChecked: true))
        results.append(om.states[0] == .working
            ? "PASS 回合·停止键还没出现不算收工" : "FAIL 回合·停止键还没出现不算收工")
        otick(.init(nodes: 90, running: [], settled: [open], openSession: open, openBusy: false, openChecked: true))
        results.append(om.states[0] == .done ? "PASS 回合·两个都静了才收工" : "FAIL 回合·两个都静了才收工")
        // A background session has only the sidebar, and the sidebar goes quiet for
        // the length of every tool call. It gets a minute of grace; the visible
        // session, which the composer can answer for, gets none.
        let gm = StatusMonitor()
        gm.dirPath = NSTemporaryDirectory() + "nd-grace-selftest-\(ProcessInfo.processInfo.processIdentifier)"
        gm.hbEnabled = false
        gm.bgSettleDelay = 60
        gm.frontmostBundlePath = { "/nonexistent" }
        let bgOnly = "后台会话"
        var gNow = Date(timeIntervalSince1970: 12_000_000)
        func gtick(_ running: [String], _ step: TimeInterval = 1) {
            gNow = gNow.addingTimeInterval(step)
            // running empty AND not settled: the row is simply not readable this sweep
            gm.applyAX([0: .init(nodes: 90, running: running)], now: gNow)
        }
        gtick([bgOnly]); gtick([bgOnly])
        gtick([], 30)                       // 30 s into a tool call
        results.append(gm.states[0] == .working ? "PASS 后台·安静半分钟仍算在跑" : "FAIL 后台·安静半分钟仍算在跑")
        gtick([bgOnly], 5); gtick([], 40)       // it came back, then went quiet again
        results.append(gm.states[0] == .working ? "PASS 后台·恢复后重新计时" : "FAIL 后台·恢复后重新计时")
        gtick([], 70)                       // now genuinely out of sight past the minute
        results.append(gm.states[0] == .done ? "PASS 后台·失联满一分钟才收工" : "FAIL 后台·失联满一分钟才收工")
        // but a row that says so itself does not wait at all
        gm.clearDone(kTargets[0])
        gtick([bgOnly]); gtick([bgOnly])
        gNow = gNow.addingTimeInterval(1)
        gm.applyAX([0: .init(nodes: 90, running: [], settled: [bgOnly])], now: gNow)
        results.append(gm.states[0] == .done ? "PASS 后台·行明说收工就不等" : "FAIL 后台·行明说收工就不等")
        // a background session the composer cannot speak for still uses the sidebar
        om.clearDone(kTargets[0])
        let bg = "后台会话"
        otick(.init(nodes: 90, running: [bg], settled: [open], openSession: open, openBusy: false, openChecked: true))
        results.append(om.states[0] == .working ? "PASS 回合·后台会话仍看侧边栏" : "FAIL 回合·后台会话仍看侧边栏")
        try? FileManager.default.removeItem(atPath: fm2.dirPath)
        // a stamp must stay on screen long enough to be seen, even if you never left
        let lm = StatusMonitor()
        lm.dirPath = NSTemporaryDirectory() + "nd-linger-selftest-\(ProcessInfo.processInfo.processIdentifier)"
        lm.axEnabled = false
        lm.doneLinger = 4
        lm.frontmostBundlePath = { kTargets[0].path }   // you are sitting in that app
        var lNow = Date(timeIntervalSince1970: 4_000_000)
        func ltick(_ busy: Bool, _ step: TimeInterval = 1) {
            lNow = lNow.addingTimeInterval(step)
            lm.applyAX([0: (busy, 90)], now: lNow)
        }
        for _ in 0..<10 { ltick(true) }
        ltick(false)
        let stamped = lm.states[0] == .done
        ltick(false); ltick(false)
        let stillThere = lm.states[0] == .done      // 2 s in, must still be visible
        for _ in 0..<4 { ltick(false) }
        let gone = lm.states[0] == nil              // past the linger, acknowledged
        results.append(stamped && stillThere && gone
                       ? "PASS 状态·盖章停留够久" : "FAIL 状态·盖章停留够久(\(stamped),\(stillThere),\(gone))")
        try? FileManager.default.removeItem(atPath: lm.dirPath)
        try? FileManager.default.removeItem(atPath: axm.dirPath)
        // stacked deck: each extra agent costs only the overlap step, never a full slot
        let e0 = IslandRoot.statusExtension(count: 0)
        let e1 = IslandRoot.statusExtension(count: 1)
        let e2 = IslandRoot.statusExtension(count: 2)
        let e3 = IslandRoot.statusExtension(count: 3)
        results.append(e0 == 0 && e1 >= 46 && e2 > e1 && e3 > e2
                       && e3 - e1 <= 2 * IslandRoot.stackStep + 1
                       ? "PASS 状态·叠摞胶囊宽度" : "FAIL 状态·叠摞胶囊宽度")
        // collapsed hover zones: notch → switcher, widened bar → status card
        if let g = geo {
            let top = g.windowRect.maxY
            let cx = g.windowRect.midX
            let sideX = cx + state.notchWidth / 2 + 40   // inside ext(1)=76, outside the notch
            let z1 = collapsedZone(NSPoint(x: cx, y: top - 10), extCount: 1)
            let z2 = collapsedZone(NSPoint(x: sideX, y: top - 10), extCount: 1)
            let z0 = collapsedZone(NSPoint(x: sideX, y: top - 10), extCount: 0)
            results.append(z1 == 1 ? "PASS 状态·刘海入口→切换器" : "FAIL 状态·刘海入口→切换器")
            results.append(z2 == 2 ? "PASS 状态·延长区入口→卡片" : "FAIL 状态·延长区入口→卡片")
            results.append(z0 == 0 ? "PASS 状态·无状态时延长区无效" : "FAIL 状态·无状态时延长区无效")
        }
        for r in results { print(r) }
        print(results.allSatisfy { $0.hasPrefix("PASS") } ? "SELFTEST ALL PASS" : "SELFTEST HAS FAILURES")
        exit(0)
    }

    // Verifies the one signal that cannot be wrong: the app's own stop control.
    // --axprobe polls each target for 20 s; --axdump lists every button label once
    // so busyWords can be tuned per app.
    /// Drive the real cursor through the real trigger region and report what the app
    /// actually did. A unit test on the rectangle cannot tell you the rectangle is
    /// somewhere the pointer never goes; this can.
    func runHoverTest() {
        guard let g = geo else { print("HOVER: no notched display"); exit(1) }
        let f = g.screen.frame
        let tr = Self.triggerRect(g.notchRect)
        print("screen \(Int(f.width))x\(Int(f.height))  notch \(Int(g.notchRect.width))x\(Int(g.notchRect.height)) at y \(Int(g.notchRect.minY))–\(Int(g.notchRect.maxY))")
        print("trigger \(Int(tr.width))x\(Int(tr.height)) at x \(Int(tr.minX))–\(Int(tr.maxX)), y \(Int(tr.minY))–\(Int(tr.maxY))")
        let saved = NSEvent.mouseLocation
        var pass = 0, fail = 0
        // flipped coords for the warp; NSEvent.mouseLocation is bottom-left origin
        func warpFast(_ p: NSPoint) {
            CGWarpMouseCursorPosition(CGPoint(x: p.x, y: f.maxY - p.y))
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        func warp(_ p: NSPoint) { warpFast(p); usleep(60_000) }
        func check(_ name: String, _ p: NSPoint, _ want: Bool) {
            warp(p)
            let dwellEnd = Date().addingTimeInterval(Self.openDwell + 0.35)
            var opened = false
            while Date() < dwellEnd {
                mouseMoved()
                if state.phase == .expanded { opened = true; break }
                usleep(40_000)
            }
            let ok = opened == want
            print("\(ok ? "PASS" : "FAIL") 悬停·\(name)  at (\(Int(p.x)),\(Int(p.y))) opened=\(opened) want=\(want)")
            ok ? (pass += 1) : (fail += 1)
            collapse()
            warp(NSPoint(x: f.midX, y: f.midY))   // park well away
            mouseMoved()
            usleep(60_000)
        }
        let n = g.notchRect
        check("扔到顶边正中（最常见的手势）", NSPoint(x: n.midX, y: f.maxY - 1), true)
        check("刘海正中偏下", NSPoint(x: n.midX, y: n.minY + 6), true)
        check("刘海左内侧", NSPoint(x: tr.minX + 3, y: f.maxY - 2), true)
        check("刘海外左侧 20pt", NSPoint(x: n.minX - 20, y: f.maxY - 2), false)
        check("刘海外右侧 20pt", NSPoint(x: n.maxX + 20, y: f.maxY - 2), false)
        check("屏幕正中", NSPoint(x: f.midX, y: f.midY), false)

        // The whole point of the dwell: sweeping from the left-hand menus to the
        // right-hand status icons crosses the notch, and must not open anything.
        func sweep(_ name: String, from x0: CGFloat, to x1: CGFloat, ms: Int) {
            collapse()
            let steps = 24
            var opened = false
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                warpFast(NSPoint(x: x0 + (x1 - x0) * t, y: f.maxY - 2))
                usleep(useconds_t(ms * 1000 / steps))
                mouseMoved()
                if state.phase == .expanded { opened = true; break }
            }
            let ok = !opened
            print("\(ok ? "PASS" : "FAIL") 悬停·\(name)  opened=\(opened) want=false")
            ok ? (pass += 1) : (fail += 1)
            collapse()
        }
        sweep("横穿刘海 300ms（去点右边状态栏）", from: n.minX - 120, to: n.maxX + 120, ms: 300)
        sweep("横穿刘海 600ms（慢一点）", from: n.minX - 120, to: n.maxX + 120, ms: 600)
        // A three-second crawl through the notch used to be in here, asserting it
        // must not open. Deleted deliberately: at 140 pt/s it is not distinguishable
        // from a slow hover — because it *is* one. Nobody spends three seconds
        // accidentally dragging through the notch, while people hover gently all the
        // time. The test was demanding a distinction that does not exist, and paying
        // for it with the gesture the user actually makes.

        // A hand is not a teleport. It travels in, and then it rests — badly, with a
        // couple of points of tremor. Warping straight to a point and holding it
        // perfectly still is a test that a real hand can still fail.
        func handApproach(_ name: String, _ p: NSPoint) {
            collapse()
            var opened = false
            for i in 0...20 {                                  // travel up to the notch
                warpFast(NSPoint(x: p.x, y: f.midY + (p.y - f.midY) * CGFloat(i) / 20))
                usleep(12_000); mouseMoved()
            }
            for _ in 0..<40 {                                  // and rest, unsteadily
                warpFast(NSPoint(x: p.x + .random(in: -3...3), y: p.y + .random(in: -2...2)))
                usleep(50_000); mouseMoved()
                if state.phase == .expanded { opened = true; break }
            }
            print("\(opened ? "PASS" : "FAIL") 悬停·\(name)  opened=\(opened) want=true")
            opened ? (pass += 1) : (fail += 1)
            collapse()
        }
        handApproach("一只手移上去、停住、手抖", NSPoint(x: n.midX, y: f.maxY - 3))

        // Straight from a recording of a real attempt: the pointer inside the notch
        // for seconds on end, gliding gently around, never opening. Nobody hovering a
        // target actually stops — they slow down. This is the case that mattered.
        func glide(_ name: String, ms: Int) {
            collapse()
            var opened = false
            let steps = ms / 16
            for i in 0...steps {                     // ~6pt per event, the measured rate
                let t = CGFloat(i)
                warpFast(NSPoint(x: n.midX + 40 * sin(t / 7), y: f.maxY - 4 - 10 * abs(cos(t / 11))))
                usleep(16_000); mouseMoved()
                if state.phase == .expanded { opened = true; break }
            }
            print("\(opened ? "PASS" : "FAIL") 悬停·\(name)  opened=\(opened) want=true")
            opened ? (pass += 1) : (fail += 1)
            collapse()
        }
        glide("在刘海里慢慢滑动（视频里的动作）", ms: 1500)
        handApproach("瞄准刘海左边缘", NSPoint(x: n.minX + 3, y: f.maxY - 3))
        handApproach("瞄准刘海右边缘", NSPoint(x: n.maxX - 3, y: f.maxY - 3))
        // …but parking in it still opens, which is the line we are drawing
        check("穿过之后停住", NSPoint(x: n.midX, y: f.maxY - 2), true)
        CGWarpMouseCursorPosition(CGPoint(x: saved.x, y: f.maxY - saved.y))
        print(fail == 0 ? "HOVERTEST ALL PASS (\(pass))" : "HOVERTEST \(fail) FAILED")
        exit(fail == 0 ? 0 : 1)
    }

    func runAxProbe(dump: Bool) {
        let ok = AXStatus.trusted(prompt: true)
        print("AX TRUSTED: \(ok)")
        if !ok {
            print("→ 打开 系统设置 › 隐私与安全性 › 辅助功能，把 NotchDial 打开，然后重跑本命令")
        }
        // Electron keeps its web AX tree off until an assistive client opts in
        for t in kTargets {
            if let pid = AXStatus.pid(for: t) {
                _ = AXStatus.enableWebTree(pid: pid, force: true)
                // -25204 apiDisabled / -25211 notImplemented → macOS is refusing us,
                // which is a very different problem from an app with a bare tree.
                print("AX \(t.name): pid \(pid) — 已请求网页 AX 树  \(AXStatus.rootReport(pid: pid))")
            } else {
                print("AX \(t.name): 未运行")
            }
        }
        let settle = 2.5
        print("等待 \(settle)s 让 Chromium 建树…")
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
            for t in kTargets {
                guard let pid = AXStatus.pid(for: t) else { continue }
                if dump {
                    let labels = AXStatus.dumpLabels(pid: pid)
                    print("AX DUMP \(t.name) — \(labels.count) 个可点元素:")
                    for l in labels.prefix(45) { print("   \(l)") }
                } else {
                    let p = AXStatus.probe(pid: pid)
                    print("AX \(t.name): busy=\(p.busy) nodes=\(p.nodes) \(p.ms)ms hit=\(p.hit)")
                }
            }
            if dump { exit(0) }
        }
        guard !dump else { RunLoop.main.run(); return }
        var n = 0
        let tm = Timer(timeInterval: 2.0, repeats: true) { tm in
            n += 1
            var line = "t+\(n * 2)s "
            for t in kTargets {
                guard let pid = AXStatus.pid(for: t) else { continue }
                let p = AXStatus.probe(pid: pid)
                line += "| \(t.name): \(p.busy ? "BUSY" : "idle ") \(p.nodes)n/\(p.ms)ms "
            }
            print(line)
            if n >= 12 { tm.invalidate(); exit(0) }
        }
        tm.fireDate = Date().addingTimeInterval(settle)
        RunLoop.main.add(tm, forMode: .common)
    }

    // measures real per-target utilization over 4 s — settles the rusage unit question empirically
    func runCpuProbe() {
        let a = StatusMonitor.cpuSecondsByTarget()
        let t0 = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            let b = StatusMonitor.cpuSecondsByTarget()
            let dt = Date().timeIntervalSince(t0)
            for t in kTargets {
                let u = max(0, (b[t.id] ?? 0) - (a[t.id] ?? 0)) / dt
                print("CPUPROBE \(t.name): \(String(format: "%.4f", u))")
            }
            exit(0)
        }
    }

    func rebuildPanel() {
        panel?.orderOut(nil)
        panel = nil
        guard let g = NotchGeometry.find() else { geo = nil; return }
        geo = g
        state.notchWidth = g.notchRect.width
        state.notchHeight = g.notchRect.height
        let p = NSPanel(contentRect: g.windowRect, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar   // above windows & the menu bar, below system menus/popovers so they never get click-blocked
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.ignoresMouseEvents = (state.phase == .collapsed)
        let root = IslandRoot(state: state,
                              onLaunch: { [weak self] t in self?.launch(t) },
                              onTapItem: { [weak self] i in self?.rotateTo(i) },
                              onCardTap: { [weak self] t, sess in self?.launchFromCard(t, session: sess) })
        let host = PassthroughHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: g.windowRect.size)
        p.contentView = host
        p.setFrame(g.windowRect, display: true)
        p.orderFrontRegardless()
        panel = p
    }

    /// The pointer has to be properly *inside* the notch, not merely near it, and not
    /// grazing the very top edge.
    ///
    /// The notch sits in the middle of the menu bar, which makes it the one place on
    /// screen the cursor crosses by accident all day: every trip from the left-hand
    /// menus to the right-hand status icons goes straight through it, and every reach
    /// for the top of the screen lands on it. The old zone was the notch *widened* by
    /// 8pt on each side and running to the screen edge — larger than the thing it
    /// represents, in exactly the two directions that traffic comes from.
    /// Exactly the notch — no wider, and no narrower either. Narrower was a mistake
    /// I could only see on the real machine: the notch is a physical cutout, the
    /// cursor is invisible while it is over it, so people aim at the *edge* of the
    /// black shape rather than its middle. Insetting 18pt put the target in a place
    /// the user cannot see and would not aim for. The old region ran 8pt PAST the
    /// notch on each side, which is what made it catch stray traffic; matching the
    /// notch exactly is the honest boundary, and the dwell does the filtering.
    static let triggerInsetX: CGFloat = 0
    /// No dead strip at the top, and the reason is worth writing down because I got
    /// it backwards once already: on a notched Mac the natural way to aim at the
    /// notch is to throw the pointer at the top edge, where it stops at y = maxY-1.
    /// Making the top dead did not filter out accidental traffic — accidental and
    /// deliberate arrive at exactly the same height — it just made the switcher
    /// impossible to open. Height cannot separate intent here. Only dwell can.
    static let triggerTopDead: CGFloat = 0

    /// The notch region that opens the switcher.
    static func triggerRect(_ notch: NSRect) -> NSRect {
        NSRect(x: notch.minX + triggerInsetX, y: notch.minY,
               width: max(24, notch.width - 2 * triggerInsetX),
               height: max(8, notch.height - triggerTopDead))
    }

    // collapsed hover zones: 1 = the notch itself → open the switcher;
    // 2 = the widened status bar beside it → reveal the status card; 0 = neither.
    func collapsedZone(_ m: NSPoint, extCount: Int) -> Int {
        guard let g = geo else { return 0 }
        if Self.triggerRect(g.notchRect).contains(m) { return 1 }
        let ext = IslandRoot.statusExtension(count: extCount)
        guard ext > 0 else { return 0 }
        let fl = IslandRoot.flare(ext: ext, grown: state.showCard, open: false)
        let cap = NSRect(x: g.windowRect.midX - state.notchWidth / 2 - ext - fl,
                         y: g.windowRect.maxY - state.notchHeight,
                         width: state.notchWidth + 2 * (ext + fl),
                         height: state.notchHeight)
        return cap.contains(m) ? 2 : 0
    }

    // the grown bar's global rect — the hover keep-alive region while the ledger is out
    func statusCardRect() -> NSRect {
        guard let g = geo else { return .zero }
        let n = state.cardLatch.isEmpty ? state.liveRows.count : state.cardLatch.count
        let ext = IslandRoot.statusExtension(count: n)
        let fl = IslandRoot.flare(ext: ext, grown: true, open: false)
        let h = state.notchHeight + IslandRoot.statusGrowth(rows: n)
        return NSRect(x: g.windowRect.midX - state.notchWidth / 2 - ext - fl,
                      y: g.windowRect.maxY - h,
                      width: state.notchWidth + 2 * (ext + fl),
                      height: h)
    }

    /// How far past its own outline the island stays awake. This used to be 28pt,
    /// which is most of a fingertip — you could leave the shape entirely and it would
    /// still be sitting there. Small enough that leaving *looks* like leaving, big
    /// enough to survive the pixel of overshoot at the end of a fast move.
    static let hoverSlack: CGFloat = 8

    /// How long the pointer must hold still inside the notch before the switcher
    /// opens. Passing through takes well under this; deciding to open it does not.
    /// Shrinking the region alone would still fire on a fast diagonal across it.
    static var openDwell: TimeInterval = 0.22
    /// …and it has to have actually stopped. A pure timer cannot tell a slow drag
    /// from an arrival: sweeping across the top at a leisurely pace keeps the pointer
    /// inside the region for longer than any dwell you would be willing to wait
    /// through. Requiring it to settle within a few points separates the two at any
    /// speed, and keeps the dwell short enough that a deliberate hover feels instant.
    /// Speed, not stillness. Requiring the pointer to stay within a few points of
    /// where the dwell began sounds like the same thing and is not: nobody hovering
    /// a target actually stops, they *slow down*, and the log of a real attempt is
    /// wall-to-wall `dwell restart moved=13` — inside the region for seconds, gliding
    /// gently, never opening. Transits are what we want to reject, and transits are
    /// distinguished by how fast they are going, not by how far they have got.
    /// A menu-bar crossing runs 800–2000 pt/s; a hover glide is a few hundred.
    static var maxHoverSpeed: CGFloat = 600
    private var zoneSince: Date?
    private var lastPos: NSPoint = .zero
    private var lastPosAt: Date?
    private var speed: CGFloat = 0

    /// Exponentially smoothed pointer speed in points/second.
    private func trackSpeed(_ m: NSPoint, now: Date) {
        defer { lastPos = m; lastPosAt = now }
        guard let t = lastPosAt else { return }
        let dt = now.timeIntervalSince(t)
        guard dt > 0.002 else { return }
        let v = hypot(m.x - lastPos.x, m.y - lastPos.y) / CGFloat(dt)
        speed = speed * 0.6 + v * 0.4
    }
    private var lastHoverLog = ""
    /// What the RUNNING app decides, moment to moment. The unit tests and even the
    /// cursor-warping hover test drive `mouseMoved()` by hand in a fresh process;
    /// the deployed app is driven by a global event monitor and a timer instead, and
    /// that difference is exactly where a working test can sit beside a dead feature.
    func hoverLog(_ zone: Int, _ m: NSPoint, _ note: String) {
        guard StatusMonitor.debug else { return }
        let line = "zone=\(zone) phase=\(state.phase) \(note)"
        guard line != lastHoverLog else { return }
        lastHoverLog = line
        statusMon.logExternal("HOVER \(line) at (\(Int(m.x)),\(Int(m.y)))")
    }

    /// What a pointer position means, given what is already open.
    enum HoverIntent { case nothing, openSwitcher, openLedger, holdLedger, dropLedger }

    /// Entry point locks the mode. Pure, so the rule can be pinned in --selftest
    /// instead of living only inside a mouse handler nobody can test.
    static func hoverIntent(ledgerOpen: Bool, zone: Int, nearLedger: Bool) -> HoverIntent {
        if ledgerOpen { return nearLedger ? .holdLedger : .dropLedger }
        if zone == 1 { return .openSwitcher }
        if zone == 2 { return .openLedger }
        return .nothing
    }

    func mouseMoved() {
        guard enabled, let g = geo else { return }
        let m = NSEvent.mouseLocation
        trackSpeed(m, now: Date())
        switch state.phase {
        case .collapsed:
            // Where you came in decides what you get, and it keeps deciding until you
            // leave. Sliding from the ledger across the notch used to swap you into the
            // switcher mid-gesture — the shape changing under a moving cursor, which is
            // the opposite of the calm this thing is supposed to have.
            let card = statusCardRect()
            let near = card.insetBy(dx: -Self.hoverSlack, dy: -Self.hoverSlack).contains(m)
            switch Self.hoverIntent(ledgerOpen: state.showCard,
                                    zone: collapsedZone(m, extCount: state.cardLatch.isEmpty ? state.liveRows.count : state.cardLatch.count),
                                    nearLedger: near) {
            case .openSwitcher:
                let began = zoneSince ?? Date()
                if zoneSince == nil { zoneSince = began }
                let held = Date().timeIntervalSince(began)
                if held >= Self.openDwell && speed < Self.maxHoverSpeed {
                    zoneSince = nil; expand()
                    hoverLog(1, m, "OPEN held=\(Int(held * 1000))ms v=\(Int(speed))")
                } else {
                    hoverLog(1, m, "held=\(Int(held * 1000))ms v=\(Int(speed))")
                }
            case .openLedger:
                zoneSince = nil
                state.cardLatch = state.liveRows   // freeze the rows for as long as you're reading them
                state.showCard = true
                panel?.ignoresMouseEvents = true   // still in the top strip: menu bar stays clickable
            case .holdLedger:
                zoneSince = nil
                // in the grown ledger below the strip: rows take clicks
                let inStrip = m.y > g.windowRect.maxY - state.notchHeight - 2
                panel?.ignoresMouseEvents = inStrip || !card.contains(m)
            case .dropLedger:
                zoneSince = nil
                state.showCard = false
                state.cardLatch = []
                panel?.ignoresMouseEvents = true
            case .nothing:
                zoneSince = nil
            }
        case .expanded:
            let island = hoverRectGlobal()
            let nearNotch = g.notchRect.insetBy(dx: -4, dy: 0).contains(m)
            let inside = island.insetBy(dx: -Self.hoverSlack, dy: -Self.hoverSlack).contains(m) || nearNotch
            if !inside && !pinned { collapse() }
            else { panel?.ignoresMouseEvents = !clickableRegionContains(m) }
        case .launching:
            break
        }
    }

    /// TicketView.LEN — how far the paper feeds out of the slot.
    static let ticketLength: CGFloat = 236

    func islandRectGlobal() -> NSRect {
        guard let g = geo else { return .zero }
        let w = g.windowRect
        let s = state.openSize()
        return NSRect(x: w.midX - s.width / 2, y: w.maxY - s.height, width: s.width, height: s.height)
    }

    /// What the island actually *looks* like, for deciding when the pointer has left.
    /// In ticket mode the drawn thing is three narrow strips, not the 400pt box they
    /// hang in — keeping the island alive across a hundred points of bare desktop on
    /// either side is the same "why is this still open" complaint, just wider.
    func hoverRectGlobal() -> NSRect {
        let r = islandRectGlobal()
        guard state.mode == 2, let g = geo else { return r }
        let s = IslandState.uiScale
        let spacing = max(70, (state.notchWidth - 60) / 2) * s
        let halfW = spacing + 37 * s
        let yTop = g.windowRect.maxY - (state.notchHeight - 4) * s
        return NSRect(x: r.midX - halfW, y: yTop - Self.ticketLength * s,
                      width: 2 * halfW, height: Self.ticketLength * s + (state.notchHeight - 4) * s)
    }

    // The only places allowed to swallow a click. Everything else — the menu-bar strip,
    // the gaps between tickets, the flanks, below the island — passes through to whatever is beneath.
    func clickableRegionContains(_ m: NSPoint) -> Bool {
        guard let g = geo else { return false }
        let island = islandRectGlobal()
        // the top strip (menu bar / notch height) never takes clicks
        if m.y > g.windowRect.maxY - state.notchHeight - 2 { return false }
        if state.mode == 2 {
            // ticket mode: only the three paper strips are clickable. The strips are
            // drawn through the island's scale, so their hit boxes travel with it.
            let s = IslandState.uiScale
            let spacing = max(70, (state.notchWidth - 60) / 2) * s
            // Both ends of the band live inside the scaled composition, so both scale.
            // Leaving yTop unscaled left the top of every ticket dead and swallowed
            // clicks in the empty strip below it.
            let yTop = g.windowRect.maxY - (state.notchHeight - 4) * s
            guard m.y <= yTop && m.y >= yTop - Self.ticketLength * s else { return false }
            for i in 0..<3 where abs(m.x - (island.midX + CGFloat(i - 1) * spacing)) <= 37 * s { return true }
            return false
        }
        // orbit / neon: the island body is the scroll + click surface
        return island.insetBy(dx: -4, dy: 0).contains(m)
    }

    func expand() {
        state.phase = .expanded
        state.showCard = false
        state.cardLatch = []
        panel?.ignoresMouseEvents = false
        panel?.orderFrontRegardless()
        refreshRunning(force: true)
    }

    func collapse() {
        state.phase = .collapsed
        state.showCard = false
        state.cardLatch = []
        zoneSince = nil
        panel?.ignoresMouseEvents = true
        gestureAcc = 0
        stepsInGesture = 0
    }

    func rotateTo(_ idx: Int) {
        let n = Double(kTargets.count)
        var d = (Double(idx) - state.rotation).truncatingRemainder(dividingBy: n)
        if d > n / 2 { d -= n }
        if d < -n / 2 { d += n }
        let target = (state.rotation + d).rounded()
        // Same visual change as a swipe, so the same duration. Hardcoding 0.85 here
        // made a click in Neon take 4.7x longer than a swipe doing the identical step.
        animateRotation(to: target, duration: Self.stepDuration(state.mode))
        UserDefaults.standard.set(wrapIndex(target), forKey: "lastIndex")
    }

    func launch(_ t: AppTarget) {
        if dryLaunch { print("CLICK->\(t.name)"); return }
        guard state.phase == .expanded else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
        Launcher.launch(t)   // fire immediately — the app switches while the animation plays on top
        panel?.ignoresMouseEvents = true   // drop the click wall the moment the app switches
        withAnimation(.easeIn(duration: 0.30)) { state.phase = .launching }
        let linger = state.mode == 2 ? 0.72 : 0.46   // ticket mode: let the torn stub fall clear
        DispatchQueue.main.asyncAfter(deadline: .now() + linger) { [weak self] in
            guard let self = self, !self.pinned else { self?.state.phase = .expanded; return }
            self.collapse()
        }
    }

    /// A click on a ledger row jumps to that app — and, when the row is a named
    /// session, to that session. We are already holding the sidebar row's own
    /// element, so opening it is a press on the same control the user would have
    /// clicked, rather than a guess at a URL scheme the app may not have.
    func launchFromCard(_ t: AppTarget, session: String? = nil) {
        if dryLaunch {
            print("CARDCLICK->\(t.name)\(session.map { "/\($0)" } ?? "")")
            state.showCard = false; return
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
        Launcher.launch(t)
        if let session = session, let pid = AXStatus.pid(for: t) {
            // after activation, or the press lands on a window that is not frontmost
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                _ = AXStatus.press(pid: pid, name: session)
            }
        }
        state.showCard = false
        panel?.ignoresMouseEvents = true
    }

    func refreshRunning(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastRunCheck) > 2 else { return }
        lastRunCheck = Date()
        var ids = Set<Int>()
        for t in kTargets where t.isRunning { ids.insert(t.id) }
        if ids != state.runningIDs { state.runningIDs = ids }
    }

    func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.portrait.fill", accessibilityDescription: "NotchDial")
        let menu = NSMenu()
        menu.delegate = self
        let mo = NSMenuItem(title: "模式：星轨 · 黑洞", action: #selector(setModeOrbit(_:)), keyEquivalent: "1")
        mo.target = self
        let mn = NSMenuItem(title: "模式：霓虹招牌", action: #selector(setModeNeon(_:)), keyEquivalent: "2")
        mn.target = self
        let mt = NSMenuItem(title: "模式：撕票", action: #selector(setModeTicket(_:)), keyEquivalent: "3")
        mt.target = self
        menu.addItem(mo); menu.addItem(mn); menu.addItem(mt)
        modeItems = [mo, mn, mt]
        menu.addItem(.separator())
        let login = NSMenuItem(title: "登录时自动启动", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        if #available(macOS 13.0, *) { login.state = SMAppService.mainApp.status == .enabled ? .on : .off }
        menu.addItem(login)
        let toggle = NSMenuItem(title: "暂停悬停触发", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let st = NSMenuItem(title: "工作状态指示", action: #selector(toggleStatus(_:)), keyEquivalent: "")
        st.target = self
        st.state = UserDefaults.standard.bool(forKey: "statusEnabled") ? .on : .off
        menu.addItem(st)
        let ax = NSMenuItem(title: "精确状态：辅助功能权限", action: #selector(fixAX(_:)), keyEquivalent: "")
        ax.target = self
        menu.addItem(ax)
        axItem = ax
        refreshAxItem()
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 NotchDial", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
        refreshModeChecks()
    }

    // the island must never sit under (or fight with) an open menu
    func menuWillOpen(_ menu: NSMenu) {
        if !pinned { collapse() }
        refreshAxItem()
    }

    func refreshAxItem() {
        guard let ax = axItem else { return }
        let ok = AXStatus.trusted()
        ax.state = ok ? .on : .off
        ax.title = ok ? "精确状态：已授权 ✓" : "精确状态：点此授权辅助功能"
    }

    // Without this grant we can only guess; with it we read the app's own UI.
    @objc func fixAX(_ item: NSMenuItem) {
        if AXStatus.trusted() { refreshAxItem(); return }
        _ = AXStatus.trusted(prompt: true)
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
    }

    func refreshModeChecks() {
        for (k, it) in modeItems.enumerated() { it.state = (state.mode == k) ? .on : .off }
    }

    @objc func setModeOrbit(_ s: Any?) { setMode(0) }
    @objc func setModeNeon(_ s: Any?)  { setMode(1) }
    @objc func setModeTicket(_ s: Any?) { setMode(2) }
    func setMode(_ m: Int) {
        withAnimation(.interpolatingSpring(stiffness: 280, damping: 24)) { state.mode = m }
        UserDefaults.standard.set(m, forKey: "mode")
        refreshModeChecks()
    }

    @objc func toggleLogin(_ item: NSMenuItem) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch { NSLog("login item: \(error)") }
        item.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func toggleEnabled(_ item: NSMenuItem) {
        enabled.toggle()
        item.title = enabled ? "暂停悬停触发" : "恢复悬停触发"
        if !enabled { collapse() }
    }

    @objc func toggleStatus(_ item: NSMenuItem) {
        let on = !UserDefaults.standard.bool(forKey: "statusEnabled")
        UserDefaults.standard.set(on, forKey: "statusEnabled")
        item.state = on ? .on : .off
        if on { statusMon.start() } else { statusMon.stop() }
    }
}

// MARK: - Passthrough hosting view
final class PassthroughHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if abs(point.x - bounds.midX) > 315 { return nil }
        return super.hitTest(point)
    }
}

// MARK: - Bootstrap
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
