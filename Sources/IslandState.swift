import AppKit
import SwiftUI

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
    /// Apps currently worth showing, in slot order.
    var liveRows: [Int] { kTargets.compactMap { work[$0.id] != nil && work[$0.id] != .idle ? $0.id : nil } }

    /// How many receipt rows the ledger shows for these apps: one per named session,
    /// or one for the app itself when it names none. The hover math and the drawn
    /// shape MUST agree on this number — computing the hover rect from the app count
    /// while the shape grew by the session count left the lower rows of a multi-
    /// session ledger outside the region that keeps it open, so it retracted under a
    /// pointer heading for exactly the row it wanted.
    func ledgerRowCount(for ids: [Int]) -> Int {
        ids.reduce(0) { $0 + max(1, workSessions[$1]?.count ?? 0) }
    }

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
