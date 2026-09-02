import Foundation

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
final class NetMonitor {
    /// bytes accumulated per target id since the last drain()
    private var bytesSince: [Int: Int] = [:]
    /// last cumulative reading per "Name.pid" identity, to turn nettop's running
    /// totals into deltas and to survive a pid joining/leaving the sample set
    private var lastCum: [String: Int] = [:]
    private let lock = NSLock()
    private var proc: Process?
    private var buf = Data()
    /// name → target id, e.g. "chatgpt" → 0. Lowercased for a case-insensitive contains.
    private let matchers: [(needle: String, id: Int)]

    init(targets: [AppTarget]) {
        matchers = targets.map { (($0.path as NSString).lastPathComponent
            .replacingOccurrences(of: ".app", with: "").lowercased(), $0.id) }
    }

    /// Parse one nettop line: "<time> <Name>.<pid>   <cumulativeBytesIn>".
    /// Returns the process identity (Name.pid) and the cumulative byte count.
    /// Pure and total, so the selftest can hammer it without a live nettop.
    static func parse(_ line: String) -> (identity: String, bytes: Int)? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3, let bytes = Int(parts[parts.count - 1]) else { return nil }
        // drop the leading timestamp; the identity is everything up to the number
        let mid = parts[1..<(parts.count - 1)].joined(separator: " ")
        return mid.isEmpty ? nil : (mid, bytes)
    }

    /// Fold one line into the per-target accumulators. Exposed for the selftest.
    func ingest(_ line: String) {
        guard let (identity, cum) = Self.parse(line) else { return }
        let low = identity.lowercased()
        guard let m = matchers.first(where: { low.contains($0.needle) }) else { return }
        lock.lock()
        let prev = lastCum[identity]
        lastCum[identity] = cum
        // A running total only ever grows; a drop means nettop recycled the row
        // (pid gone / counters reset), which is not inbound traffic.
        if let prev = prev, cum >= prev { bytesSince[m.id, default: 0] += cum - prev }
        lock.unlock()
    }

    /// Bytes since the previous drain, per target id, and reset. Called once a tick.
    func drain() -> [Int: Int] {
        lock.lock(); let out = bytesSince; bytesSince = [:]; lock.unlock()
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
            guard let self = self else { return }
            self.lock.lock(); self.buf.append(d); let chunk = self.buf; self.buf = Data(); self.lock.unlock()
            guard var text = String(data: chunk, encoding: .utf8) else { return }
            // keep an unfinished last line in the buffer
            var tail = ""
            if !text.hasSuffix("\n"), let nl = text.lastIndex(of: "\n") {
                tail = String(text[text.index(after: nl)...])
                text = String(text[...nl])
            } else if !text.hasSuffix("\n") {
                tail = text; text = ""
            }
            if !tail.isEmpty { self.lock.lock(); self.buf = Data(tail.utf8) + self.buf; self.lock.unlock() }
            for line in text.split(separator: "\n") { self.ingest(String(line)) }
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

    /// True while a nettop child is alive.
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return proc != nil }

    func stop() {
        lock.lock()
        let p = proc; proc = nil
        bytesSince = [:]; lastCum = [:]; buf = Data()
        lock.unlock()
        // terminate before the stdin pipe is released: a still-alive nettop that
        // suddenly sees EOF on stdin is exactly the spinner described above
        p?.terminationHandler = nil
        p?.terminate()
        p?.waitUntilExit()
        lock.lock(); stdinHold = nil; lock.unlock()
    }
}
