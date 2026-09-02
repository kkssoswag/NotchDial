import AppKit
import SwiftUI
import ServiceManagement

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

    /// One NotchDial at a time. A redeploy launches the new build while the old one is
    /// still running; two copies then fight over the notch — and each runs its own
    /// helpers (the nettop stream), so a leak in one is a leak times two. The newest
    /// launch wins: ask the others to quit, force it if they haven't within 3s.
    func retireOtherInstances() {
        guard let bid = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            .filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return }
        for o in others { o.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            for o in others where !o.isTerminated { o.forceTerminate() }
        }
    }

    /// Take the helper processes down with us. nettop would die on its own on the
    /// next write to a closed pipe, but "would" is not a guarantee we want to test.
    func applicationWillTerminate(_ note: Notification) {
        statusMon.stop()
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        UserDefaults.standard.register(defaults: ["statusEnabled": true])
        if UserDefaults.standard.object(forKey: "lastIndex") != nil {
            state.rotation = Double(UserDefaults.standard.integer(forKey: "lastIndex"))
        } else { state.rotation = 1 }
        state.mode = UserDefaults.standard.integer(forKey: "mode")
        if CommandLine.arguments.contains("--neon") { state.mode = 1 }
        // Tests, probes and one-shot chores run instead of the app, never beside it.
        if runOneShotFlag() { return }
        // pre-warm heavy assets so the first hover is instant
        DispatchQueue.global(qos: .userInitiated).async {
            _ = SpaceAssets.nebulaCG
            _ = SpaceAssets.nebulaCG2
            _ = SpaceAssets.planets
        }
        DispatchQueue.main.async {
            for t in kTargets { _ = IconCache.icon(for: t) }
        }
        observeRunningApps()
        retireOtherInstances()
        rebuildPanel()
        setupStatusItem()
        statusMon.onChange = { [weak self] st in self?.state.work = st }
        statusMon.onTimes = { [weak self] ts in self?.state.workSince = ts }
        statusMon.onSessions = { [weak self] ss in self?.state.workSessions = ss }
        if UserDefaults.standard.bool(forKey: "statusEnabled") { statusMon.start() }
        installInputMonitors()
        if pinned { expand() }
        runScriptedFlag()
    }

    /// Event-driven running indicators (no polling), and the moment an app quits,
    /// everything believed about it goes too.
    func observeRunningApps() {
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
    }

    /// The pointer is read three ways on purpose: the global monitor sees it over
    /// other apps' windows, the local one over our own panel, and the slow poll is
    /// the belt to those braces — a pointer that stops dead exactly on a boundary
    /// produces no event at all.
    func installInputMonitors() {
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

    // collapsed hover zones: 1 = the notch itself → open the switcher;
    // 2 = the widened status bar beside it → reveal the status card; 0 = neither.
    func collapsedZone(_ m: NSPoint, extCount: Int) -> Int {
        guard let g = geo else { return 0 }
        if g.notchRect.insetBy(dx: -8, dy: 0).contains(m) { return 1 }
        let ext = IslandRoot.statusExtension(count: extCount)
        guard ext > 0 else { return 0 }
        let fl = IslandRoot.flare(ext: ext, grown: state.showCard, open: false)
        let cap = NSRect(x: g.windowRect.midX - state.notchWidth / 2 - ext - fl,
                         y: g.windowRect.maxY - state.notchHeight,
                         width: state.notchWidth + 2 * (ext + fl),
                         height: state.notchHeight)
        return cap.contains(m) ? 2 : 0
    }

    /// The apps the ledger is showing: the frozen set while it is open, the live one before.
    var ledgerIDs: [Int] { state.cardLatch.isEmpty ? state.liveRows : state.cardLatch }

    // the grown bar's global rect — the hover keep-alive region while the ledger is out
    func statusCardRect() -> NSRect {
        guard let g = geo else { return .zero }
        let ids = ledgerIDs
        // width follows the icon deck (one per app); height follows the receipt rows
        // (one per session) — the drawn shape uses the same two numbers
        let ext = IslandRoot.statusExtension(count: ids.count)
        let fl = IslandRoot.flare(ext: ext, grown: true, open: false)
        let h = state.notchHeight + IslandRoot.statusGrowth(rows: state.ledgerRowCount(for: ids))
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
        switch state.phase {
        case .collapsed:
            // Where you came in decides what you get, and it keeps deciding until you
            // leave. Sliding from the ledger across the notch used to swap you into the
            // switcher mid-gesture — the shape changing under a moving cursor, which is
            // the opposite of the calm this thing is supposed to have.
            let card = statusCardRect()
            let near = card.insetBy(dx: -Self.hoverSlack, dy: -Self.hoverSlack).contains(m)
            switch Self.hoverIntent(ledgerOpen: state.showCard,
                                    zone: collapsedZone(m, extCount: ledgerIDs.count),
                                    nearLedger: near) {
            case .openSwitcher:
                expand()
            case .openLedger:
                state.cardLatch = state.liveRows   // freeze the rows for as long as you're reading them
                state.showCard = true
                panel?.ignoresMouseEvents = true   // still in the top strip: menu bar stays clickable
            case .holdLedger:
                // in the grown ledger below the strip: rows take clicks
                let inStrip = m.y > g.windowRect.maxY - state.notchHeight - 2
                panel?.ignoresMouseEvents = inStrip || !card.contains(m)
            case .dropLedger:
                state.showCard = false
                state.cardLatch = []
                panel?.ignoresMouseEvents = true
            case .nothing:
                break
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
