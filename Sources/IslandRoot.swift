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
        count == 0 ? 0 : CGFloat(count) * 17 + 11
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
        .animation(.interpolatingSpring(stiffness: 300, damping: 26), value: capsuleExt)
    }

    // collapsed live-status bar: mini icons on the left of the notch, state glyphs on the right
    @ViewBuilder private func statusCapsule(width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(statusList) { e in
                    if let img = IconCache.icon(for: e.t) {
                        Image(nsImage: img)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 13, height: 13)
                            .shadow(color: .black.opacity(0.6), radius: 1)
                    }
                }
            }
            .padding(.leading, 8)
            Spacer(minLength: state.notchWidth)
            HStack(spacing: 7) {
                ForEach(statusList) { e in
                    StatusBadge(ws: e.s, tint: e.t.tint, size: 10)
                        .id("cap-\(e.t.id)-\(e.s == .working ? "w" : "d")")
                }
            }
            .padding(.trailing, 9)
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
