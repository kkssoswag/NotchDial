import SwiftUI
import AppKit

// The collapsed bar's silhouette: concave top flares melt into the screen edge
// (surface-tension style, like the notch itself), convex rounded bottom corners.
struct NotchShape: Shape {
    var flare: CGFloat
    var bottomRadius: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(flare, bottomRadius) }
        set { flare = newValue.first; bottomRadius = newValue.second }
    }
    func path(in r: CGRect) -> Path {
        let f = flare, rad = bottomRadius
        let x0 = r.minX + f, x1 = r.maxX - f
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: x0, y: r.minY + f), control: CGPoint(x: x0, y: r.minY))
        p.addLine(to: CGPoint(x: x0, y: r.maxY - rad))
        p.addQuadCurve(to: CGPoint(x: x0 + rad, y: r.maxY), control: CGPoint(x: x0, y: r.maxY))
        p.addLine(to: CGPoint(x: x1 - rad, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: x1, y: r.maxY - rad), control: CGPoint(x: x1, y: r.maxY))
        p.addLine(to: CGPoint(x: x1, y: r.minY + f))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: x1, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct IslandRoot: View {
    @ObservedObject var state: IslandState
    var onLaunch: (AppTarget) -> Void
    var onTapItem: (Int) -> Void
    var onCardTap: (AppTarget) -> Void
    @State private var hoverRow = -1
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
    // how far the collapsed bar grows on EACH side of the notch. Each agent gets one
    // pill (icon + its glyph) and the pills are split evenly left/right of the notch,
    // so the bar stays compact and symmetric instead of stretching for a single app.
    static func statusExtension(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let perSide = (count + 1) / 2          // 1 app → 1 side, 2 → 1+1, 3 → 2+1
        return CGFloat(perSide) * 46 + 14
    }
    private var capsuleExt: CGFloat { Self.statusExtension(count: statusList.count) }

    // extra height when the bar grows into its status ledger (hover on the widened part)
    static func statusGrowth(rows: Int) -> CGFloat {
        rows == 0 ? 0 : CGFloat(rows) * 34 + CGFloat(rows - 1) + 10
    }

    private var island: some View {
        let ext = isOpen ? 0 : capsuleExt
        let grown = !isOpen && state.showCard && !statusList.isEmpty
        let growH = grown ? Self.statusGrowth(rows: statusList.count) : 0
        let flare: CGFloat = (!isOpen && ext > 0) ? (grown ? 14 : 10) : 0
        let barW = state.notchWidth + 2 * ext
        let sz = isOpen ? state.openSize() : CGSize(width: barW + 2 * flare, height: state.notchHeight + growH)
        let r: CGFloat = isOpen ? 34 : (grown ? 19 : 10)
        let shape = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: r,
                                           bottomTrailingRadius: r, topTrailingRadius: 0, style: .continuous)
        return ZStack(alignment: .top) {
            if !isOpen {
                NotchShape(flare: flare, bottomRadius: r)
                    .fill(Color.black)
                    .transition(.identity)
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
                statusCapsule(width: barW, height: sz.height, grown: grown)
                    .transition(.opacity)
            }
            shape.strokeBorder(Color.white.opacity(isOpen && state.mode == 1 ? 0.09 : 0), lineWidth: 1)
        }
        .frame(width: sz.width, height: sz.height)
        .compositingGroup()
        .shadow(color: .black.opacity(isOpen ? (state.mode == 1 ? 0.55 : 0) : (grown ? 0.38 : 0)),
                radius: isOpen ? 22 : 14, y: isOpen ? 9 : 6)
        .animation(.interpolatingSpring(stiffness: 300, damping: 24), value: isOpen)
        .animation(.interpolatingSpring(stiffness: 280, damping: 25), value: state.mode)
        .animation(.interpolatingSpring(stiffness: 330, damping: 20), value: capsuleExt)
        .animation(.interpolatingSpring(stiffness: 330, damping: 21), value: state.work)
        .animation(.interpolatingSpring(stiffness: 320, damping: 25), value: state.showCard)
    }

    // one agent = one pill: its icon, then its own state glyph — never split apart
    @ViewBuilder private func statusPill(_ e: StatusEntry, iconS: CGFloat) -> some View {
        HStack(spacing: 6) {
            if let img = IconCache.icon(for: e.t) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: iconS, height: iconS)
                    .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
            }
            StatusBadge(ws: e.s, tint: e.t.tint, size: iconS * 0.62)
                .id("cap-\(e.t.id)-\(e.s == .working ? "w" : "d")")
        }
        .transition(.asymmetric(
            insertion: .scale(scale: 0.3).combined(with: .opacity),
            removal: .scale(scale: 0.4).combined(with: .opacity)))
    }

    // collapsed live-status bar: one pill per agent, split evenly around the notch.
    // Everything springs out from behind the notch, as if the black bar squeezed it out.
    // On hover the bar grows downward into a small status ledger — one line per agent,
    // rubber-stamped once its task is done. One continuous shape; nothing floats.
    @ViewBuilder private func statusCapsule(width: CGFloat, height: CGFloat, grown: Bool) -> some View {
        let iconS = min(22, state.notchHeight - 9)
        let perSide = (statusList.count + 1) / 2
        let left = Array(statusList.prefix(perSide))
        let right = Array(statusList.dropFirst(perSide))
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // each agent travels as one pill: its icon and its own glyph, side by side
                HStack(spacing: 14) {
                    ForEach(left) { e in statusPill(e, iconS: iconS) }
                }
                .padding(.leading, 12)
                Spacer(minLength: state.notchWidth)
                HStack(spacing: 14) {
                    ForEach(right) { e in statusPill(e, iconS: iconS) }
                }
                .padding(.trailing, 12)
            }
            .frame(width: width, height: state.notchHeight)
            // while the ledger is out, the strip's glyph row would just repeat it
            .opacity(grown ? 0 : 1)
            if grown {
                // receipt rows: icon + name, state told by the glyph alone — click to jump
                VStack(spacing: 0) {
                    ForEach(Array(statusList.enumerated()), id: \.element.id) { idx, e in
                        HStack(spacing: 9) {
                            if let img = IconCache.icon(for: e.t) {
                                Image(nsImage: img)
                                    .resizable()
                                    .interpolation(.high)
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 20, height: 20)
                            }
                            Text(e.t.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white.opacity(0.94))
                            Spacer(minLength: 24)
                            if e.s == .working {
                                WorkSpinner(tint: e.t.tint, size: 15, lineWidth: 2.2)
                            } else {
                                RubberStamp(size: 26)
                            }
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.white.opacity(hoverRow == e.id ? 0.08 : 0))
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { onCardTap(e.t) }
                        .onHover { h in
                            if h { hoverRow = e.id } else if hoverRow == e.id { hoverRow = -1 }
                        }
                        if idx < statusList.count - 1 {
                            Line()
                                .stroke(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                                .frame(height: 1)
                                .padding(.horizontal, 22)
                        }
                    }
                }
                .padding(.horizontal, 9)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: width, height: height, alignment: .top)
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
