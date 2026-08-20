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

    private var island: some View {
        let sz = isOpen ? state.openSize() : CGSize(width: state.notchWidth, height: state.notchHeight)
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
            shape.strokeBorder(Color.white.opacity(isOpen && state.mode == 1 ? 0.09 : 0), lineWidth: 1)
        }
        .frame(width: sz.width, height: sz.height)
        .compositingGroup()
        .shadow(color: .black.opacity(isOpen && state.mode == 1 ? 0.55 : 0), radius: 22, y: 9)
        .animation(.interpolatingSpring(stiffness: 300, damping: 24), value: isOpen)
        .animation(.interpolatingSpring(stiffness: 280, damping: 25), value: state.mode)
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
