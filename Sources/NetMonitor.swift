import Foundation
import Darwin

// MARK: - Network-inbound signal (works exactly where the Accessibility tree does not)
//
// The a11y tree is only alive while an Electron app is active or foreground; a
// long-idle backgrounded app tears it down and neither re-asserting the attribute
// nor a brief foreground revives it (measured, all three apps). That is the one
// place the AX signal is blind — and it is the place that matters, because "I
// switched away and want to know when it finishes" IS the backgrounded case.
//
// Tokens arriving from the cloud are a physical fact independent of the a11y tree:
// while a turn streams, bytes come in over the websocket; between turns they don't.
// Measured, the separation is clean — idle apps showed EXACTLY zero inbound bytes
// over seconds, an active session showed KB-scale bursts. CPU, by contrast, was
// noise (an idle app spiked to 51%). So: read per-app inbound bytes and treat
// sustained inflow as "working".
//
// The bytes come from one long-lived `nettop` process (the same private
// NetworkStatistics source Activity Monitor uses), parsed as a stream. One process,
// not a spawn per sample — spawning nettop repeatedly costs seconds.
//
// Which app a row belongs to is decided by the process's executable path, not its
// name. Electron's traffic flows through helpers ("Claude Helper", "Codex (Service)",
// the `codex` binary ChatGPT ships in its Resources), nettop truncates names to 15
// characters ("Cursor Helper (.88406"), and the `claude` command-line tool is a
// different program that happens to share a name with the app. Every helper of an
// app bundle lives under <bundle>.app/, so a pid resolves to exactly one target.
final class NetMonitor {
    /// bytes accumulated per target id since the last drain()
    private var bytesSince: [Int: Int] = [:]
    /// last cumulative reading per pid, to turn nettop's running totals into deltas
    private var lastCum: [pid_t: Int] = [:]
    /// pid → target id, resolved once from the executable path; nil = not one of ours
    private var owner: [pid_t: Int?] = [:]
    /// when each pid last appeared, so the tables forget processes that are gone
    private var lastSeen: [pid_t: Date] = [:]
    private var lastPrune = Date()
    private let lock = NSLock()
    private var proc: Process?
    private var buf = Data()
    /// bundle path + "/" per target: the prefix every one of its executables shares
    private let prefixes: [(id: Int, prefix: String)]
    /// Executable path of a pid. proc_pidpath by default; the self-test injects.
    private let pathOf: (pid_t) -> String?
    /// How long a pid may be absent from the stream before its tables are dropped.
    static let forgetAfter: TimeInterval = 120

    init(targets: [AppTarget], pathOf: ((pid_t) -> String?)? = nil) {
        prefixes = targets.map { ($0.id, $0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
        self.pathOf = pathOf ?? NetMonitor.executablePath
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    /// Parse one nettop line: "<time> <Name>.<pid>   <cumulativeBytesIn>".
    /// Returns the pid and the cumulative byte count. The name is whatever nettop
    /// felt like printing (truncated, with spaces and dots); only the pid is trusted.
    /// Pure and total, so the selftest can hammer it without a live nettop.
    static func parse(_ line: String) -> (pid: pid_t, bytes: Int)? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3, let bytes = Int(parts[parts.count - 1]) else { return nil }
        // drop the leading timestamp; the identity is everything up to the number
        let identity = parts[1..<(parts.count - 1)].joined(separator: " ")
        guard let dot = identity.lastIndex(of: "."),
              let pid = pid_t(identity[identity.index(after: dot)...]), pid > 0 else { return nil }
        return (pid, bytes)
    }

    /// Which target a pid belongs to, cached. Exposed for the selftest.
    func target(of pid: pid_t) -> Int? {
        lock.lock()
        if let known = owner[pid] { lock.unlock(); return known }
        lock.unlock()
        let path = pathOf(pid)
        let id = path.flatMap { p in prefixes.first { p.hasPrefix($0.prefix) }?.id }
        lock.lock(); owner[pid] = .some(id); lock.unlock()
        return id
    }

    /// Fold one line into the per-target accumulators. Exposed for the selftest.
    func ingest(_ line: String, now: Date = Date()) {
        guard let (pid, cum) = Self.parse(line) else { return }
        lock.lock()
        lastSeen[pid] = now
        let prev = lastCum[pid]
        lock.unlock()
        // A running total only ever grows. A drop means the pid was recycled — a new
        // process, possibly a different program, so its owner is re-resolved too — or
        // nettop reset its counters; either way it is not inbound traffic.
        if let prev = prev, cum < prev {
            lock.lock(); owner[pid] = nil; lastCum[pid] = cum; lock.unlock()
            return
        }
        guard let id = target(of: pid) else {
            lock.lock(); lastCum[pid] = cum; lock.unlock()
            return
        }
        lock.lock()
        lastCum[pid] = cum
        // only growth is traffic; a zero delta must not conjure a "0 bytes" entry
        if let prev = prev, cum > prev { bytesSince[id, default: 0] += cum - prev }
        lock.unlock()
    }

    /// Bytes since the previous drain, per target id, and reset. Called once a tick.
    func drain(now: Date = Date()) -> [Int: Int] {
        lock.lock()
        let out = bytesSince; bytesSince = [:]
        if now.timeIntervalSince(lastPrune) > 30 {
            lastPrune = now
            for (pid, seen) in lastSeen where now.timeIntervalSince(seen) > Self.forgetAfter {
                lastSeen[pid] = nil; lastCum[pid] = nil; owner[pid] = nil
            }
        }
        lock.unlock()
        return out
    }

    /// nettop's stdin. It MUST be a pipe we hold open and never write to.
    ///
    /// nettop keeps an interactive key loop even in `-x -l 0` logging mode. A GUI app
    /// launched by launchd has /dev/null on fd 0, and a child inherits it; /dev/null
    /// is *always readable* (instant EOF), so nettop's loop wakes, reads nothing,
    /// and wakes again — forever. Measured on the real machine: stdin=/dev/null →
    /// 121% CPU; stdin=an idle pipe → 0.4%. Two stacked NotchDial instances made
    /// that two hot cores and a screaming fan for ninety minutes. Never again.
    private var stdinHold: Pipe?
    /// Earliest time another nettop may be launched — a crash loop must not spawn
    /// a process a second.
    private var nextLaunch = Date.distantPast
    /// how often start() may relaunch a dead nettop
    static let relaunchGap: TimeInterval = 30

    /// Launch nettop, or relaunch it if it died. Cheap when it is already running,
    /// so the monitor's tick can call this every second.
    func start() {
        lock.lock()
        let running = proc != nil
        let tooSoon = Date() < nextLaunch
        lock.unlock()
        guard !running, !tooSoon else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        // -P per-process · -x plain · -J bytes_in one column · -s 1 sample every 1s
        // · -l 0 stream forever. One process for the life of the app.
        p.arguments = ["-P", "-x", "-J", "bytes_in", "-s", "1", "-l", "0"]
        let out = Pipe()
        let hold = Pipe()          // see stdinHold
        p.standardOutput = out
        p.standardInput = hold
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let d = fh.availableData
            // Empty data is EOF (nettop exited). Drop the handler, or *this* loop
            // becomes the spinner: an EOF'd pipe is readable forever too.
            guard !d.isEmpty else { fh.readabilityHandler = nil; return }
            self?.feed(d)
        }
        p.terminationHandler = { [weak self] dead in
            out.fileHandleForReading.readabilityHandler = nil
            guard let self = self else { return }
            self.lock.lock()
            if self.proc === dead { self.proc = nil; self.stdinHold = nil }
            self.lastCum = [:]; self.buf = Data()
            self.lock.unlock()
        }
        lock.lock()
        nextLaunch = Date().addingTimeInterval(Self.relaunchGap)
        proc = p; stdinHold = hold
        lock.unlock()
        do { try p.run() }
        catch {
            out.fileHandleForReading.readabilityHandler = nil
            lock.lock(); proc = nil; stdinHold = nil; lock.unlock()
        }
    }

    /// Split the stream into lines at newline *bytes*, and only then decode. Decoding
    /// the raw chunk first threw the whole read away whenever a pipe boundary fell
    /// inside a multi-byte character — a non-ASCII process name was enough.
    func feed(_ d: Data) {
        lock.lock()
        buf.append(d)
        guard let nl = buf.lastIndex(of: 0x0A) else { lock.unlock(); return }
        let complete = buf[buf.startIndex...nl]
        buf = Data(buf[buf.index(after: nl)...])
        lock.unlock()
        for line in complete.split(separator: 0x0A) where !line.isEmpty {
            ingest(String(decoding: line, as: UTF8.self))
        }
    }

    /// True while a nettop child is alive.
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return proc != nil }

    func stop() {
        lock.lock()
        let p = proc; proc = nil
        bytesSince = [:]; lastCum = [:]; buf = Data()
        nextLaunch = .distantPast      // a deliberate stop/start must not wait out the gap
        lock.unlock()
        guard let p = p else { return }
        // terminate before the stdin pipe is released: a still-alive nettop that
        // suddenly sees EOF on stdin is exactly the spinner described above
        p.terminationHandler = nil
        p.terminate()
        // bounded: a child that ignores SIGTERM does not get to hang the main thread
        let deadline = Date().addingTimeInterval(1)
        while p.isRunning, Date() < deadline { usleep(20_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL); p.waitUntilExit() }
        lock.lock(); stdinHold = nil; lock.unlock()
    }
}
