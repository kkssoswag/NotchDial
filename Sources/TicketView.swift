import SwiftUI
import AppKit

final class TicketPhys: ObservableObject {
    @Published var tick = 0
    // paper feed (root stays in the slot; this is how far the paper has fed out)
    var feed = [CGFloat](repeating: -300, count: 3)
    var feedV = [CGFloat](repeating: 0, count: 3)
    var feedTarget = [CGFloat](repeating: 0, count: 3)   // 0 = fed out; negative = retracted into the slot
    // paper bend (0 at the root, grows toward the tip)
    var bend = [Double](repeating: 0, count: 3)
    var bendV = [Double](repeating: 0, count: 3)
    // torn stub free-fall
    var torn = [false, false, false]
    var stubY = [CGFloat](repeating: 0, count: 3)
    var stubVY = [CGFloat](repeating: 0, count: 3)
    var stubA = [Double](repeating: 0, count: 3)
    var stubVA = [Double](repeating: 0, count: 3)
    private var timer: Timer?
    private var seed: UInt64 = 20260820
    private func rnd() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double((seed >> 33) & 0xFFFFFF) / Double(0xFFFFFF)
    }

    func drop(len: CGFloat) {
        for i in 0..<3 {
            feed[i] = -(len + 24); feedV[i] = 0; feedTarget[i] = 0
            bend[i] = 0; bendV[i] = 0
            torn[i] = false; stubY[i] = 0; stubVY[i] = 0; stubA[i] = 0; stubVA[i] = 0
        }
        for i in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.10) { [weak self] in
                guard let self = self else { return }
                self.feedV[i] = 180
                self.bendV[i] = (self.rnd() - 0.5) * 2.4
                self.start()
            }
        }
        start()
    }

    func tear(_ i: Int) {
        guard !torn[i] else { return }
        torn[i] = true
        stubY[i] = 0
        stubVY[i] = -50
        stubA[i] = 0
        stubVA[i] = (rnd() > 0.5 ? 1 : -1) * (2.0 + rnd() * 1.6)
        bendV[i] += (rnd() > 0.5 ? 1 : -1) * 2.2   // recoil of the remaining paper
        start()
    }

    func retract(len: CGFloat) {
        for i in 0..<3 {
            feedTarget[i] = -(len + 30)
            feedV[i] = min(feedV[i], -60)   // upward kick so the pull-back starts instantly
        }
        start()
    }

    func nudge(_ i: Int, _ imp: Double) {
        guard !torn[i] else { return }
        bendV[i] += imp
        start()
    }

    func start() {
        guard timer == nil else { return }
        let tm = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] tm in
            guard let self = self else { tm.invalidate(); return }
            self.stepPhys()
        }
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
    }

    private func stepPhys() {
        let dt = 1.0 / 60.0
        var active = false
        for i in 0..<3 {
            // paper feed: critically-ish damped so the root never detaches from the slot
            let retracting = feedTarget[i] != 0
            let kk = retracting ? 180.0 : 90.0
            let cc = retracting ? 22.0 : 15.0
            let fy = -kk * Double(feed[i] - feedTarget[i]) - cc * Double(feedV[i])
            feedV[i] += CGFloat(fy * dt)
            feed[i] += feedV[i] * CGFloat(dt)
            // bend sway
            bendV[i] += (-9.0 * sin(bend[i]) - 1.5 * bendV[i]) * dt
            bend[i] += bendV[i] * dt
            if bend[i] > 0.065 { bend[i] = 0.065; bendV[i] = min(0, bendV[i]) }
            if bend[i] < -0.065 { bend[i] = -0.065; bendV[i] = max(0, bendV[i]) }
            if abs(feed[i] - feedTarget[i]) > 0.4 || abs(feedV[i]) > 0.4 || abs(bend[i]) > 0.003 || abs(bendV[i]) > 0.008 { active = true }
            // stub fall
            if torn[i] && stubY[i] < 480 {
                stubVY[i] += 1400 * CGFloat(dt)
                stubY[i] += stubVY[i] * CGFloat(dt)
                stubA[i] += stubVA[i] * dt
                stubVA[i] *= 0.99
                active = true
            }
        }
        tick &+= 1
        if !active { timer?.invalidate(); timer = nil }
    }

    deinit { timer?.invalidate() }
}

struct TicketView: View {
    @ObservedObject var state: IslandState
    var onLaunch: (AppTarget) -> Void
    @StateObject private var phys = TicketPhys()
    @State private var lastHoverX: CGFloat? = nil
    @State private var hoverTicket: Int = -1
    @State private var lastPhase: IslandState.Phase = .collapsed

    private let W: CGFloat = 470
    private let H: CGFloat = 310
    private let LEN: CGFloat = 236
    private let MAINH: CGFloat = 176
    private let STUBH: CGFloat = 60
    private let TW: CGFloat = 66
    static let paper = Color(red: 0.93, green: 0.91, blue: 0.86)
    static let ink = Color(red: 0.10, green: 0.10, blue: 0.11)
    static let accents: [Color] = [
        Color(red: 0.24, green: 0.44, blue: 0.38),
        Color(red: 0.20, green: 0.31, blue: 0.80),
        Color(red: 0.80, green: 0.38, blue: 0.16)
    ]

    private var slotSpacing: CGFloat { max(70, (state.notchWidth - 60) / 2) }
    private func slotX(_ i: Int) -> CGFloat { W / 2 + CGFloat(i - 1) * slotSpacing }

    var body: some View {
        ZStack(alignment: .top) {
            ForEach(0..<3, id: \.self) { i in
                ticket(i)
            }
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 13,
                                   bottomTrailingRadius: 13, topTrailingRadius: 0, style: .continuous)
                .fill(Color.black)
                .frame(width: state.notchWidth + 14, height: state.notchHeight + 10)
                .shadow(color: .black.opacity(0.30), radius: 6, y: 3)
                .position(x: W / 2, y: (state.notchHeight + 10) / 2)
                .zIndex(10)
                .allowsHitTesting(false)
        }
        .frame(width: W, height: H)
        .clipped()
        .onAppear { lastPhase = state.phase; phys.drop(len: LEN) }
        .onChange(of: state.phase) { ph in
            if ph == .expanded && (lastPhase == .collapsed || lastPhase == .launching) { phys.drop(len: LEN) }
            if ph == .launching { phys.retract(len: LEN) }   // pull the strips back the moment the app switches
            lastPhase = ph
        }
        .onContinuousHover(coordinateSpace: .local) { ph in
            switch ph {
            case .active(let p):
                if let lx = lastHoverX {
                    let dx = p.x - lx
                    if abs(dx) > 0.4 {
                        for i in 0..<3 {
                            let prox = max(0, 1 - abs(p.x - slotX(i)) / 85)
                            if prox > 0 { phys.nudge(i, Double(dx) * 0.0012 * Double(prox)) }
                        }
                    }
                }
                lastHoverX = p.x
            case .ended:
                lastHoverX = nil
            }
        }
    }

    @ViewBuilder private func ticket(_ i: Int) -> some View {
        let tg = kTargets[i]
        let acc = Self.accents[i]
        let torn = phys.torn[i]
        let dy = phys.feed[i]                       // <= ~0 while feeding, tiny overshoot hides behind dispenser
        let shear = CGFloat(tan(phys.bend[i]))      // paper bend: root row fixed, tip sways
        ZStack(alignment: .top) {
            // ---- main ticket (root lives in the slot, never detaches) ----
            ZStack(alignment: .top) {
                UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 0,
                                       bottomTrailingRadius: 0, topTrailingRadius: 5, style: .continuous)
                    .fill(Self.paper)
                    .overlay(
                        LinearGradient(colors: [Color.black.opacity(0.05), .clear, Color.black.opacity(0.04)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .overlay(
                        UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 0,
                                               bottomTrailingRadius: 0, topTrailingRadius: 5, style: .continuous)
                            .stroke(Self.ink.opacity(0.10), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.32), radius: 8, y: 5)
                motif(i).position(x: TW / 2, y: 26)
                Rectangle().fill(Self.ink.opacity(0.85))
                    .frame(width: 34, height: 1.5)
                    .position(x: TW / 2, y: 46)
                Text(tg.id == 2 ? "CLAUDE" : tg.name.uppercased())
                    .font(.system(size: 17, weight: .heavy))
                    .tracking(1.5)
                    .foregroundColor(Self.ink)
                    .fixedSize()
                    .rotationEffect(.degrees(90))
                    .position(x: TW / 2, y: 104)
                dashRow(acc).position(x: TW / 2, y: 148)
                if state.runningIDs.contains(i) {
                    Circle().fill(acc).frame(width: 4, height: 4)
                        .position(x: TW / 2, y: 160)
                }
                if let ws = state.work[i] {
                    StatusBadge(ws: ws, tint: acc, paper: true, size: 11)
                        .position(x: TW - 14, y: 16)
                }
                Line()
                    .stroke(Self.ink.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(width: TW - 12, height: 1)
                    .position(x: TW / 2, y: MAINH - 2)
            }
            .frame(width: TW, height: MAINH)
            // ---- tear-off stub below the perforation ----
            stub(i, acc: acc)
                .frame(width: TW, height: STUBH)
                .rotationEffect(.radians(torn ? phys.stubA[i] : 0))
                .offset(x: torn ? sin(phys.stubY[i] * 0.02) * 10 : 0,
                        y: MAINH + (torn ? phys.stubY[i] - dy : 0))   // world-fixed: keeps falling while the strip retracts
                .opacity(torn ? max(0, 1 - Double(phys.stubY[i]) / 340) : 1)
        }
        .frame(width: TW, height: LEN, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !torn, state.phase == .expanded else { return }
            phys.tear(i)
            onLaunch(tg)   // instant launch — tear animation plays while the app comes up
        }
        .onHover { h in
            if h { hoverTicket = i } else if hoverTicket == i { hoverTicket = -1 }
        }
        .scaleEffect(hoverTicket == i && !torn ? 1.02 : 1, anchor: .top)
        .animation(.easeOut(duration: 0.15), value: hoverTicket)
        .transformEffect(CGAffineTransform(a: 1, b: 0, c: shear, d: 1, tx: -shear * (state.notchHeight + 8), ty: 0))
        .offset(y: dy)
        .position(x: slotX(i), y: LEN / 2 + state.notchHeight - 4)
        .zIndex(torn ? 3 : 1)
    }

    @ViewBuilder private func stub(_ i: Int, acc: Color) -> some View {
        ZStack {
            TicketShape(bite: 6)
                .fill(Self.paper)
                .overlay(TicketShape(bite: 6).stroke(Self.ink.opacity(0.10), lineWidth: 1))
                .shadow(color: .black.opacity(0.32), radius: 8, y: 5)
            VStack(spacing: 5) {
                ZStack {
                    ForEach(0..<6, id: \.self) { k in
                        Rectangle().fill(acc)
                            .frame(width: 6, height: 30)
                            .rotationEffect(.degrees(24))
                            .offset(x: CGFloat(k - 3) * 9 + 4)
                    }
                }
                .frame(width: TW - 22, height: 18)
                .clipped()
                Text("COMMIT · TEAR")
                    .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                    .foregroundColor(Self.ink)
                    .fixedSize()
                    .padding(.vertical, 2.5)
                    .padding(.horizontal, 4)
                    .overlay(Rectangle().stroke(Self.ink, lineWidth: 1.1))
            }
        }
    }

    @ViewBuilder private func motif(_ id: Int) -> some View {
        let ink = Self.ink
        if id == 0 {
            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { _ in
                            Circle().fill(ink).frame(width: 3.6, height: 3.6)
                        }
                    }
                }
            }
        } else if id == 1 {
            VStack(spacing: 3.5) {
                ForEach(0..<2, id: \.self) { _ in
                    HStack(spacing: 3.5) {
                        ForEach(0..<2, id: \.self) { _ in
                            Rectangle().fill(ink).frame(width: 5.5, height: 5.5)
                        }
                    }
                }
            }
        } else {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    Rectangle().fill(ink).frame(width: 3.2, height: 17)
                }
            }
        }
    }

    private func dashRow(_ acc: Color) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { _ in
                Rectangle().fill(acc).frame(width: 6, height: 2)
            }
        }
    }
}

struct Line: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        return p
    }
}

struct TicketShape: Shape {
    var bite: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        let rad: CGFloat = 7
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - rad))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - rad, y: r.maxY), radius: rad)
        if bite > 0.5 {
            p.addLine(to: CGPoint(x: r.midX + bite, y: r.maxY))
            p.addArc(center: CGPoint(x: r.midX, y: r.maxY), radius: bite,
                     startAngle: .degrees(0), endAngle: .degrees(180), clockwise: true)
        }
        p.addLine(to: CGPoint(x: r.minX + rad, y: r.maxY))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - rad), radius: rad)
        p.closeSubpath()
        return p
    }
}
