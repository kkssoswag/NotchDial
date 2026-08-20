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

    var centeredIndex: Int {
        let n = kTargets.count
        let i = Int(rotation.rounded()) % n
        return (i + n) % n
    }
    var selectedTarget: AppTarget { kTargets[centeredIndex] }

    func openSize() -> CGSize {
        if mode == 0 { return CGSize(width: 620, height: 196) }
        if mode == 2 { return CGSize(width: 470, height: 285) }
        return CGSize(width: 470, height: 180)
    }
}

// MARK: - App delegate
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = IslandState()
    var panel: NSPanel?
    var geo: NotchGeometry?
    var statusItem: NSStatusItem?
    var pollTimer: Timer?
    var enabled = true
    let pinned = CommandLine.arguments.contains("--pin")
    var lastRunCheck = Date.distantPast
    var modeItems: [NSMenuItem] = []
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
            self?.refreshRunning(force: true)
        }
        wnc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshRunning(force: true)
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
        rebuildPanel()
        setupStatusItem()
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

    func step(_ dir: Double) {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        let target = state.rotation.rounded() + dir
        if instantSteps { state.rotation = target }
        else { animateRotation(to: target, duration: state.mode == 0 ? 0.85 : (state.mode == 2 ? 0.4 : 0.18)) }
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
        for r in results { print(r) }
        print(results.allSatisfy { $0.hasPrefix("PASS") } ? "SELFTEST ALL PASS" : "SELFTEST HAS FAILURES")
        exit(0)
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
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.ignoresMouseEvents = (state.phase == .collapsed)
        let root = IslandRoot(state: state,
                              onLaunch: { [weak self] t in self?.launch(t) },
                              onTapItem: { [weak self] i in self?.rotateTo(i) })
        let host = PassthroughHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: g.windowRect.size)
        p.contentView = host
        p.setFrame(g.windowRect, display: true)
        p.orderFrontRegardless()
        panel = p
    }

    func mouseMoved() {
        guard enabled, let g = geo else { return }
        let m = NSEvent.mouseLocation
        switch state.phase {
        case .collapsed:
            if g.notchRect.insetBy(dx: -8, dy: 0).contains(m) { expand() }
        case .expanded:
            let island = islandRectGlobal()
            let inside = island.insetBy(dx: -28, dy: -28).contains(m)
                || g.notchRect.insetBy(dx: -8, dy: 0).contains(m)
            if !inside && !pinned { collapse() }
        case .launching:
            break
        }
    }

    func islandRectGlobal() -> NSRect {
        guard let g = geo else { return .zero }
        let w = g.windowRect
        let s = state.openSize()
        return NSRect(x: w.midX - s.width / 2, y: w.maxY - s.height, width: s.width, height: s.height)
    }

    func expand() {
        state.phase = .expanded
        panel?.ignoresMouseEvents = false
        panel?.orderFrontRegardless()
        refreshRunning(force: true)
    }

    func collapse() {
        state.phase = .collapsed
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
        animateRotation(to: target, duration: 0.85)
        UserDefaults.standard.set(wrapIndex(target), forKey: "lastIndex")
    }

    func launch(_ t: AppTarget) {
        if dryLaunch { print("CLICK->\(t.name)"); return }
        guard state.phase == .expanded else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
        Launcher.launch(t)   // fire immediately — the app switches while the animation plays on top
        withAnimation(.easeIn(duration: 0.30)) { state.phase = .launching }
        let linger = state.mode == 2 ? 0.72 : 0.46   // ticket mode: let the torn stub fall clear
        DispatchQueue.main.asyncAfter(deadline: .now() + linger) { [weak self] in
            guard let self = self, !self.pinned else { self?.state.phase = .expanded; return }
            self.collapse()
        }
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
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 NotchDial", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
        refreshModeChecks()
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
