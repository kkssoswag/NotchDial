import SwiftUI
import AppKit

struct IslandRoot: View {
    @ObservedObject var state: IslandState
    var onLaunch: (AppTarget) -> Void
    var onTapItem: (Int) -> Void
    private var isOpen: Bool { state.phase != .collapsed }

    var body: some View {
        VStack(spacing: 0) { island; Spacer(minLength: 0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // targets with a live status, in slot order
    private struct StatusEntry: Identifiable {
        let t: AppTarget
        let s: WorkState
        var id: Int { t.id }
    }
    private var statusList: [StatusEntry] {
        kTargets.compactMap { t in
            guard let s = state.work[t.id], s != .idle else { return nil }
            return StatusEntry(t: t, s: s)
        }
    }
    // how far the collapsed bar grows on EACH side of the notch
    static func statusExtension(count: Int) -> CGFloat {
        count == 0 ? 0 : CGFloat(count) * 28 + 16
    }
    private var capsuleExt: CGFloat { Self.statusExtension(count: statusList.count) }

    private var island: some View {
        let ext = isOpen ? 0 : capsuleExt
        let sz = isOpen ? state.openSize() : CGSize(width: state.notchWidth + 2 * ext, height: state.notchHeight)
        let r: CGFloat = isOpen ? 34 : 10
        let shape = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: r,
                                           bottomTrailingRadius: r, topTrailingRadius: 0, style: .continuous)
        return ZStack(alignment: .top) {
            if !isOpen {
                shape.fill(Color.black).transition(.identity)
            } else if state.mode == 1 {
                shape.fill(Color.black).transition(.opacity)
            }
            if isOpen {
                if state.mode == 0 || state.mode == 2 {
                    content
                        .frame(width: sz.width, height: sz.height, alignment: .top)
                        .transition(.opacity)
                } else {
                    content
                        .frame(width: sz.width, height: sz.height, alignment: .top)
                        .clipShape(shape)
                        .transition(.opacity)
                }
            }
            if !isOpen && ext > 0 {
                statusCapsule(width: sz.width, height: sz.height)
                    .transition(.opacity)
            }
            shape.strokeBorder(Color.white.opacity(isOpen && state.mode == 1 ? 0.09 : 0), lineWidth: 1)
        }
        .frame(width: sz.width, height: sz.height)
        .compositingGroup()
        .shadow(color: .black.opacity(isOpen && state.mode == 1 ? 0.55 : 0), radius: 22, y: 9)
        .animation(.interpolatingSpring(stiffness: 300, damping: 24), value: isOpen)
        .animation(.interpolatingSpring(stiffness: 280, damping: 25), value: state.mode)
        .animation(.interpolatingSpring(stiffness: 330, damping: 20), value: capsuleExt)
        .animation(.interpolatingSpring(stiffness: 330, damping: 21), value: state.work)
    }

    // collapsed live-status bar: app icons on the left of the notch, state glyphs on the right.
    // Everything springs out from behind the notch, as if the black bar squeezed it out.
    @ViewBuilder private func statusCapsule(width: CGFloat, height: CGFloat) -> some View {
        let iconS = min(22, height - 9)
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(statusList) { e in
                    if let img = IconCache.icon(for: e.t) {
                        Image(nsImage: img)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: iconS, height: iconS)
                            .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .scale(scale: 0.35)).combined(with: .opacity),
                                removal: .scale(scale: 0.4).combined(with: .opacity)))
                    }
                }
            }
            .padding(.leading, 10)
            Spacer(minLength: state.notchWidth)
            HStack(spacing: 9) {
                ForEach(statusList) { e in
                    StatusBadge(ws: e.s, tint: e.t.tint, size: iconS * 0.72)
                        .id("cap-\(e.t.id)-\(e.s == .working ? "w" : "d")")
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading).combined(with: .scale(scale: 0.35)).combined(with: .opacity),
                            removal: .scale(scale: 0.4).combined(with: .opacity)))
                }
            }
            .padding(.trailing, 11)
        }
        .frame(width: width, height: height)
    }

    @ViewBuilder private var content: some View {
        if state.mode == 0 {
            OrbitView(state: state, onLaunch: onLaunch, onTap: onTapItem)
        } else if state.mode == 2 {
            TicketView(state: state, onLaunch: onLaunch)
        } else {
            NeonView(state: state, onLaunch: onLaunch)
        }
    }
}
