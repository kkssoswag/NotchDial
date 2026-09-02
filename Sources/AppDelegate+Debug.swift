import AppKit
import SwiftUI
import ServiceManagement

// MARK: - Debug flags
// Everything here runs *instead of* the app (one-shot chores, probes) or drives it
// through a fixed script (screen-recording demos, synthetic-click tests). None of it
// is reachable in normal use; it lives apart so the delegate proper reads as what the
// app does, not as what we once needed to check.
extension AppDelegate {
    /// Flags that replace the app for this launch. Returns true when one ran (the
    /// process either exits from inside it or idles for its own run loop).
    func runOneShotFlag() -> Bool {
        let args = CommandLine.arguments
        if args.contains("--enable-login") {
            if #available(macOS 13.0, *) {
                do { try SMAppService.mainApp.register(); print("LOGIN ITEM STATUS: \(SMAppService.mainApp.status == .enabled ? "enabled" : "pending")") }
                catch { print("LOGIN ITEM ERROR: \(error)") }
            }
            exit(0)
        }
        if args.contains("--dumpplanets") {
            for (i, cg) in SpaceAssets.planets.enumerated() {
                if let cg = cg {
                    let rep = NSBitmapImageRep(cgImage: cg)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/planet_\(i).png"))
                }
            }
            exit(0)
        }
        if args.contains("--selftest") { runSelfTest(); return true }
        if args.contains("--axprobe") { runAxProbe(dump: false); return true }
        if args.contains("--axdump") { runAxProbe(dump: true); return true }
        return false
    }

    /// Flags that run the real app through a script: synthetic clicks, demo
    /// choreography, frame capture. Each terminates the process when it is done.
    func runScriptedFlag() {
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

    // Verifies the one signal that cannot be wrong: the app's own stop control.
    // --axprobe polls each target for 20 s; --axdump lists every button label once
    // so busyWords can be tuned per app.
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
}
