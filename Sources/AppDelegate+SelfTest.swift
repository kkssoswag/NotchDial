import AppKit
import SwiftUI

// MARK: - Self test
// `--selftest`: the gesture engine replayed from real trackpad flick profiles, the
// hit regions, and the whole status state machine driven by synthetic evidence — no
// timers, no live apps, nothing spawned. Every monitor here is cut off from AX and
// nettop so the suite can run next to the real app without disturbing anything.
extension AppDelegate {
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
            state.mode = 0
            chk("星轨主体可点", NSPoint(x: cx, y: top - 120), true)
            chk("星轨侧翼穿透", NSPoint(x: cx + 340, y: top - 120), false)
        }
        // work-status state machine over the file protocol: a temp status dir, no timers,
        // no live apps — every monitor built here is cut off from AX and nettop, so the
        // suite can run beside the real app without sweeping (or disturbing) anything.
        func isolated() -> StatusMonitor {
            let m = StatusMonitor()
            m.axEnabled = false; m.netEnabled = false
            m.isRunning = { _ in true }
            m.frontmostBundlePath = { nil }
            return m
        }
        let mon = isolated()
        mon.dirPath = NSTemporaryDirectory() + "nd-status-selftest-\(ProcessInfo.processInfo.processIdentifier)"
        try? FileManager.default.createDirectory(atPath: mon.dirPath, withIntermediateDirectories: true)
        mon.doneLinger = 2
        var mNow = Date(timeIntervalSince1970: 1_000_000)
        func mtick() { mNow = mNow.addingTimeInterval(1.5); mon.tick(now: mNow) }
        mtick(); mtick()
        results.append(mon.states[0] == nil && mon.states[2] == nil ? "PASS 状态·初始空闲" : "FAIL 状态·初始空闲")
        let fp = (mon.dirPath as NSString).appendingPathComponent("claude-code")
        try? "working".write(toFile: fp, atomically: true, encoding: .utf8)
        mtick()
        results.append(mon.states[2] == .working ? "PASS 状态·文件working" : "FAIL 状态·文件working")
        try? "done".write(toFile: fp, atomically: true, encoding: .utf8)
        mtick()
        results.append(mon.states[2] == .done ? "PASS 状态·文件done" : "FAIL 状态·文件done")
        mon.frontmostBundlePath = { kTargets[2].path }
        mtick(); mtick()
        let fileGone = !FileManager.default.fileExists(atPath: fp)
        results.append(mon.states[2] == nil && fileGone ? "PASS 状态·确认后清理文件" : "FAIL 状态·确认后清理文件")
        // acknowledging one session's ✓ must not silence another that is still working
        let fpA = (mon.dirPath as NSString).appendingPathComponent("claude-code.a")
        let fpB = (mon.dirPath as NSString).appendingPathComponent("claude-code.b")
        try? "done".write(toFile: fpA, atomically: true, encoding: .utf8)
        try? "working".write(toFile: fpB, atomically: true, encoding: .utf8)
        mtick()
        mon.clearDone(kTargets[2])
        results.append(FileManager.default.fileExists(atPath: fpB) && !FileManager.default.fileExists(atPath: fpA)
            ? "PASS 状态·确认不删还在跑的会话文件" : "FAIL 状态·确认不删还在跑的会话文件")
        try? FileManager.default.removeItem(atPath: mon.dirPath)
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
        let axm = isolated()
        axm.dirPath = NSTemporaryDirectory() + "nd-ax-selftest-\(ProcessInfo.processInfo.processIdentifier)"
        axm.frontmostBundlePath = { nil }
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
        let vm = isolated()
        vm.dirPath = NSTemporaryDirectory() + "nd-verdict-selftest-\(ProcessInfo.processInfo.processIdentifier)"
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
        let wm = isolated()
        wm.dirPath = NSTemporaryDirectory() + "nd-watchdog-selftest-\(ProcessInfo.processInfo.processIdentifier)"
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
        let qm = isolated()
        qm.dirPath = NSTemporaryDirectory() + "nd-quit-selftest-\(ProcessInfo.processInfo.processIdentifier)"
        qm.frontmostBundlePath = { "/nonexistent" }
        var qNow = Date(timeIntervalSince1970: 7_000_000)
        qNow = qNow.addingTimeInterval(1)
        qm.applyAX([0: .init(nodes: 90, running: [sess])], now: qNow)
        let wasWorking = qm.states[0] == .working
        qm.targetTerminated(0, pid: nil)
        results.append(wasWorking && qm.states[0] == nil ? "PASS 状态·退出即清除" : "FAIL 状态·退出即清除")
        // Losing the grant must release AX's exclusive claim, or the fallbacks it
        // suppresses stay suppressed and the last reading is frozen in place.
        let tm2 = isolated()
        tm2.dirPath = NSTemporaryDirectory() + "nd-trust-selftest-\(ProcessInfo.processInfo.processIdentifier)"
        tm2.frontmostBundlePath = { "/nonexistent" }
        var tNow = Date(timeIntervalSince1970: 8_000_000)
        tNow = tNow.addingTimeInterval(1)
        tm2.applyAX([0: .init(nodes: 90, running: [sess])], now: tNow)
        let heldBefore = tm2.states[0] == .working
        tm2.forgetAX(0)
        tm2.applyAX([Int: StatusMonitor.AXRead](), now: tNow.addingTimeInterval(1))
        results.append(heldBefore && tm2.states[0] == nil ? "PASS 状态·失去授权即释放" : "FAIL 状态·失去授权即释放")

        // ---- network fallback: the path that works where AX goes dark ------------
        // nettop line parsing: "<time> <Name>.<pid>   <bytes>" — the name is truncated
        // to 15 characters and may contain spaces and dots; only the pid is trusted
        let np = NetMonitor.parse("16:34:35.721 Claude Helper.731                     18607952")
        results.append(np?.pid == 731 && np?.bytes == 18607952
            ? "PASS 网络·解析行" : "FAIL 网络·解析行")
        let npT = NetMonitor.parse("19:37:26.453482 Cursor Helper (.88406                4391")
        results.append(npT?.pid == 88406 && npT?.bytes == 4391
            ? "PASS 网络·截断的进程名也能取到 pid" : "FAIL 网络·截断的进程名也能取到 pid")
        results.append(NetMonitor.parse("time                          bytes_in") == nil
            ? "PASS 网络·表头不误解析" : "FAIL 网络·表头不误解析")
        // Attribution is by executable path, resolved once per pid. This is what lets
        // ChatGPT's Codex traffic count for ChatGPT — it flows through "Codex (Service)"
        // and a `codex` binary the app ships, neither of which is called ChatGPT — and
        // what keeps the `claude` command-line tool from lighting up Claude.app.
        let paths: [pid_t: String] = [
            900: "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/1/Helpers/Codex (Service).app/Contents/MacOS/Codex (Service)",
            901: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper",
            902: "/usr/local/bin/claude",
            903: "/Applications/ChatGPT.app/Contents/Resources/codex",
        ]
        let nm = NetMonitor(targets: kTargets, pathOf: { paths[$0] })   // id0=ChatGPT id1=Cursor id2=Claude
        results.append(nm.target(of: 900) == 0 && nm.target(of: 903) == 0 && nm.target(of: 901) == 2
            && nm.target(of: 902) == nil && nm.target(of: 77) == nil
            ? "PASS 网络·按可执行路径归属到 app" : "FAIL 网络·按可执行路径归属到 app")
        nm.ingest("t Codex (Service).900   1000")
        nm.ingest("t Claude Helper.901   5000")
        nm.ingest("t claude.902   100")
        _ = nm.drain()                            // establish baselines
        nm.ingest("t Codex (Service).900   1000")  // ChatGPT idle: no growth
        nm.ingest("t Claude Helper.901   9000")   // Claude +4000
        nm.ingest("t claude.902   999100")        // the CLI streams a megabyte: not ours
        let d = nm.drain()
        results.append((d[0] ?? 0) == 0 && (d[2] ?? 0) == 4000 && d.count == 1
            ? "PASS 网络·增量按 app 归并，同名 CLI 不算" : "FAIL 网络·增量按 app 归并，同名 CLI 不算 \(d)")
        nm.ingest("t Claude Helper.901   3000")   // counter reset (pid recycled) → clamp, not negative
        results.append((nm.drain()[2] ?? 0) == 0
            ? "PASS 网络·计数器回退夹到0" : "FAIL 网络·计数器回退夹到0")
        // a byte stream cut mid-character must lose nothing: lines split at newline bytes
        let fm = NetMonitor(targets: kTargets, pathOf: { paths[$0] })
        let l1 = Array("t Claude Helper.901   100\n".utf8), l2 = Array("t Cödex (Service).900   50\n".utf8)
        fm.feed(Data(l1 + l2[0..<4]))            // the "ö" is cut in two by the pipe
        fm.feed(Data(l2[4...]))
        _ = fm.drain()
        fm.feed(Data("t Claude Helper.901   400\nt Cödex (Service).900   80\n".utf8))
        let fd = fm.drain()
        results.append(fd[2] == 300 && fd[0] == 30
            ? "PASS 网络·跨读边界的多字节字符不丢行" : "FAIL 网络·跨读边界的多字节字符不丢行 \(fd)")

        // the working/quiet state machine, driven by injected byte counts
        let xm = isolated()
        xm.dirPath = NSTemporaryDirectory() + "nd-net-selftest-\(ProcessInfo.processInfo.processIdentifier)"
        xm.frontmostBundlePath = { "/nonexistent" }   // target is backgrounded
        xm.netEnabled = true                           // isolated() turns it off; this test IS the network path
        xm.netOnRate = 800; xm.netHotNeeded = 2; xm.netQuiet = 6; xm.minWorkForDone = 2
        var xNow = Date(timeIntervalSince1970: 13_000_000)
        func ntick(_ bytes: Int, _ step: TimeInterval = 1) {
            xNow = xNow.addingTimeInterval(step)
            xm.applyNet(now: xNow, bytesOverride: [0: bytes], dt: step)
            xm.publishForTest(now: xNow)
        }
        ntick(3000); ntick(3000)                  // sustained inflow, 2 samples
        results.append(xm.states[0] == .working ? "PASS 网络·持续入站→工作中" : "FAIL 网络·持续入站→工作中")
        ntick(0); ntick(0); ntick(0); ntick(0); ntick(0); ntick(0); ntick(0)  // quiet past netQuiet
        results.append(xm.states[0] == .done ? "PASS 网络·静默够久→收工" : "FAIL 网络·静默够久→收工")
        // a single blip is not a turn
        let ym = isolated()
        ym.dirPath = NSTemporaryDirectory() + "nd-net2-selftest-\(ProcessInfo.processInfo.processIdentifier)"
        ym.frontmostBundlePath = { "/nonexistent" }
        ym.netEnabled = true
        ym.netOnRate = 800; ym.netHotNeeded = 2
        var yNow = Date(timeIntervalSince1970: 14_000_000)
        yNow = yNow.addingTimeInterval(1); ym.applyNet(now: yNow, bytesOverride: [0: 5000], dt: 1); ym.publishForTest(now: yNow)
        yNow = yNow.addingTimeInterval(1); ym.applyNet(now: yNow, bytesOverride: [0: 0], dt: 1); ym.publishForTest(now: yNow)
        results.append(ym.states[0] == nil ? "PASS 网络·单次脉冲不误报" : "FAIL 网络·单次脉冲不误报")
        // One app, several sessions. The probe used to stop at the first live row, so
        // whichever one finished first stamped ✓ for the whole app while the others
        // were still going — measured live with two Claude sessions running.
        let mm = isolated()
        mm.dirPath = NSTemporaryDirectory() + "nd-multi-selftest-\(ProcessInfo.processInfo.processIdentifier)"
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
        let fm2 = isolated()
        fm2.dirPath = NSTemporaryDirectory() + "nd-files-selftest-\(ProcessInfo.processInfo.processIdentifier)"
        fm2.frontmostBundlePath = { "/nonexistent" }
        try? FileManager.default.createDirectory(atPath: fm2.dirPath, withIntermediateDirectories: true)
        let slug = StatusMonitor.slug(kTargets[0])
        func put(_ suffix: String, _ w: String) {
            try? w.write(toFile: (fm2.dirPath as NSString).appendingPathComponent("\(slug).\(suffix)"),
                         atomically: true, encoding: .utf8)
        }
        var fNow = Date(timeIntervalSince1970: 10_000_000)
        put("s1", "done"); put("s2", "working")
        fNow = fNow.addingTimeInterval(1); fm2.tick(now: fNow)
        results.append(fm2.states[0] == .working ? "PASS 多会话·文件里有人在跑就算跑" : "FAIL 多会话·文件里有人在跑就算跑")
        put("s2", "done")
        fNow = fNow.addingTimeInterval(1); fm2.tick(now: fNow)
        results.append(fm2.states[0] == .done ? "PASS 多会话·文件全收工才盖章" : "FAIL 多会话·文件全收工才盖章")
        // THE root cause, pinned. "Running <name>" tracks token emission, so it drops
        // out for the whole length of a tool call and the status flickers several
        // times per turn. The interrupt control does not: a turn is interruptible for
        // exactly as long as it lasts. Where they disagree about the visible session,
        // the composer wins.
        let om = isolated()
        om.dirPath = NSTemporaryDirectory() + "nd-open-selftest-\(ProcessInfo.processInfo.processIdentifier)"
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
        let gm = isolated()
        gm.dirPath = NSTemporaryDirectory() + "nd-grace-selftest-\(ProcessInfo.processInfo.processIdentifier)"
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
        let lm = isolated()
        lm.dirPath = NSTemporaryDirectory() + "nd-linger-selftest-\(ProcessInfo.processInfo.processIdentifier)"
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
        // ---- the defects the deep review found, pinned ---------------------------
        // An app mid-turn whose tree Chromium tears down answers with a complete tree
        // of one node. That used to drop `axUsable` AND the timestamp the release
        // watchdog needs, so `axBusy` was stranded and the spinner outlived the turn
        // by the rest of the process. Now the dark patch is ridden out for axUsableTTL,
        // then everything is released and the fallback may speak.
        let dm = isolated()
        dm.dirPath = NSTemporaryDirectory() + "nd-dark-selftest-\(ProcessInfo.processInfo.processIdentifier)"
        dm.axUsableTTL = 12
        dm.frontmostBundlePath = { "/nonexistent" }
        var dNow = Date(timeIntervalSince1970: 15_000_000)
        func dtick(_ r: StatusMonitor.AXRead, _ step: TimeInterval = 1) {
            dNow = dNow.addingTimeInterval(step); dm.applyAX([0: r], now: dNow)
        }
        dtick(.init(nodes: 90, running: [sess])); dtick(.init(nodes: 90, running: [sess]))
        for _ in 0..<5 { dtick(.init(nodes: 1, complete: true)) }     // torn down, 5 s in
        let ridden = dm.states[0] == .working
        for _ in 0..<10 { dtick(.init(nodes: 1, complete: true)) }    // 15 s dark: past the TTL
        results.append(ridden && dm.states[0] == nil && (dm.sessions[0] ?? []).isEmpty
            ? "PASS 状态·AX树被拆后不再卡住转圈" : "FAIL 状态·AX树被拆后不再卡住转圈(\(ridden),\(String(describing: dm.states[0])))")
        // …and the network fallback is then allowed to take the app over
        dm.netEnabled = true
        dNow = dNow.addingTimeInterval(1); dm.applyNet(now: dNow, bytesOverride: [0: 5000], dt: 1); dm.publishForTest(now: dNow)
        dNow = dNow.addingTimeInterval(1); dm.applyNet(now: dNow, bytesOverride: [0: 5000], dt: 1); dm.publishForTest(now: dNow)
        results.append(dm.states[0] == .working ? "PASS 状态·AX放手后网络信号接管" : "FAIL 状态·AX放手后网络信号接管")
        // The app quits while the network signal says working: no spinner, and no ✓
        // that nothing could ever dismiss.
        dm.targetTerminated(0, pid: nil)
        dNow = dNow.addingTimeInterval(10); dm.applyNet(now: dNow, bytesOverride: [0: 0], dt: 1); dm.publishForTest(now: dNow)
        results.append(dm.states[0] == nil ? "PASS 状态·退出的 app 不留网络残影" : "FAIL 状态·退出的 app 不留网络残影 \(String(describing: dm.states[0]))")
        // A starved run loop hands one drain ten seconds of keepalive bytes. Divided by
        // the nominal second that was a burst; divided by the real interval it is the
        // trickle it always was.
        let sm = isolated()
        sm.dirPath = NSTemporaryDirectory() + "nd-starve-selftest-\(ProcessInfo.processInfo.processIdentifier)"
        sm.netEnabled = true
        sm.frontmostBundlePath = { "/nonexistent" }
        var sNow = Date(timeIntervalSince1970: 16_000_000)
        for _ in 0..<2 {
            sNow = sNow.addingTimeInterval(10)
            sm.applyNet(now: sNow, bytesOverride: [0: 1500], dt: 10)   // 150 B/s, over 10 s
            sm.publishForTest(now: sNow)
        }
        results.append(sm.states[0] == nil ? "PASS 网络·卡顿累积的字节不算突发" : "FAIL 网络·卡顿累积的字节不算突发")
        // The ledger's hover rect and its drawn shape must grow by the same count —
        // rows (one per session), not apps.
        if let g = geo {
            state.work = [2: .working, 1: .working]
            state.workSessions = [2: [
                .init(target: 2, name: "甲", state: .working, since: Date()),
                .init(target: 2, name: "乙", state: .working, since: Date()),
                .init(target: 2, name: "丙", state: .done, since: Date())]]
            state.cardLatch = []
            let rect = statusCardRect()
            let want = state.notchHeight + IslandRoot.statusGrowth(rows: 4)
            results.append(abs(rect.height - want) < 0.5 && abs(rect.maxY - g.windowRect.maxY) < 0.5
                ? "PASS 账单·悬停区按会话行数长高" : "FAIL 账单·悬停区按会话行数长高 (\(rect.height) vs \(want))")
            state.work = [:]; state.workSessions = [:]
        }
        for r in results { print(r) }
        print(results.allSatisfy { $0.hasPrefix("PASS") } ? "SELFTEST ALL PASS" : "SELFTEST HAS FAILURES")
        exit(0)
    }
}
