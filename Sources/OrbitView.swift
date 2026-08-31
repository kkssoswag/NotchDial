import SwiftUI
import AppKit

struct OrbitView: View {
    @ObservedObject var state: IslandState
    var onLaunch: (AppTarget) -> Void
    var onTap: (Int) -> Void
    @State private var ringT: CGFloat = -1
    @State private var hoverID: Int = -1
    @State private var launched = false   // latch: once flying into the hole, never interpolate back
    @State private var sparks = SparkBox()

    private let W: CGFloat = 620
    private let H: CGFloat = 196
    private let holeC = CGPoint(x: 310, y: 12)

    private struct Star {
        let x: CGFloat; let y: CGFloat; let r: CGFloat; let ph: Double; let far: Bool
    }
    private static let stars: [Star] = {
        var arr: [Star] = []
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func rnd() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) & 0xFFFFFF) / CGFloat(0xFFFFFF)
        }
        for i in 0..<95 {
            arr.append(Star(x: rnd() * 620, y: rnd() * 196,
                            r: rnd() < 0.85 ? 1.1 : 1.8,
                            ph: Double(rnd() * 6.28), far: i % 3 != 0))
        }
        return arr
    }()

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 1.0 / 40.0)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                Canvas { ctx, _ in
                    // The nebula layers are drawn wider than this canvas so their own
                    // soft edges land outside it — which left a hard-cut rectangle of
                    // haze sitting on the desktop. Clip everything to an ellipse that
                    // is opaque at the notch and fully transparent at the island's
                    // left, right and bottom edges, so the scene has no border at all.
                    ctx.clipToLayer { c in
                        c.scaleBy(x: 1, y: H / (W / 2))
                        c.fill(Path(ellipseIn: CGRect(x: 0, y: -W / 2, width: W, height: W)),
                               with: .radialGradient(
                                   Gradient(stops: [
                                       .init(color: .white, location: 0),
                                       .init(color: .white, location: 0.5),
                                       .init(color: .white.opacity(0.34), location: 0.8),
                                       .init(color: .white.opacity(0), location: 1),
                                   ]),
                                   center: CGPoint(x: W / 2, y: 0),
                                   startRadius: 0,
                                   endRadius: W / 2))
                    }
                    drawSpace(&ctx, t: t)
                }
            }
            .allowsHitTesting(false)
            ForEach(kTargets) { tg in
                orbitItem(tg)
            }
            if ringT >= 0 {
                Ellipse()
                    .stroke(Color.white.opacity(Double(1 - ringT) * 0.9), lineWidth: 2)
                    .frame(width: 50 + 230 * ringT, height: (50 + 230 * ringT) * 0.36)
                    .position(holeC)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: W, height: H)
        .onChange(of: state.phase) { ph in
            if ph == .launching {
                launched = true
                ringT = 0
                withAnimation(.easeOut(duration: 0.55)) { ringT = 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) { ringT = -1 }
            } else if ph == .expanded {
                launched = false
            }
        }
    }

    private func wrapped(_ idx: Int) -> Double {
        let n = Double(kTargets.count)
        var d = (Double(idx) - state.rotation).truncatingRemainder(dividingBy: n)
        if d > n / 2 { d -= n }
        if d < -n / 2 { d += n }
        return d
    }

    private func lerpP(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    static func flightPos(u: CGFloat, sgn: CGFloat) -> CGPoint {
        let e = u * u * (3 - 2 * u)
        return CGPoint(x: 310 + sgn * 345 * u, y: 122 - 98 * e)
    }

    private func morphAmount(_ u: CGFloat) -> CGFloat {
        let a: CGFloat = 0.14, b: CGFloat = 0.34
        let x = max(0, min(1, (b - u) / (b - a)))
        return x * x * (3 - 2 * x)
    }

    @ViewBuilder private func orbitItem(_ tg: AppTarget) -> some View {
        let d = wrapped(tg.id)
        let sgn: CGFloat = d >= 0 ? 1 : -1
        let u = CGFloat(min(1.0, abs(d)))
        let base = OrbitView.flightPos(u: u, sgn: sgn)
        let band: CGFloat = (u > 0.10 && u < 0.45) ? (1 - abs((u - 0.275) / 0.175)) : 0
        let x = base.x + CGFloat(sin(Double(u) * 92)) * 2.4 * band
        let y = base.y + CGFloat(cos(Double(u) * 71)) * 2.0 * band
        let s: CGFloat = 1 - 0.72 * u
        let alpha: Double = abs(d) >= 1.0 ? 0 : (u < 0.72 ? 1 : max(0, 1 - Double((u - 0.72) / 0.26)))
        let isCenter = abs(d) < 0.5
        let sess = state.phase == .launching || launched
        let launchingMe = sess && isCenter
        let size: CGFloat = 92 * s
        let morph = morphAmount(u)
        VStack(spacing: 7) {
            ZStack {
                PlanetView(appID: tg.id, size: size)
                    .rotationEffect(.degrees(Double(u * sgn) * -170))
                    .scaleEffect(1 + morph * 0.42)
                    .opacity(Double(1 - morph))
                    .blur(radius: morph * 3.5)
                Circle()
                    .fill(tg.tint.opacity(sin(Double(morph) * Double.pi) * 0.30))
                    .frame(width: size * 1.3, height: size * 1.3)
                    .blur(radius: 9)
                if let img = IconCache.icon(for: tg) {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size, height: size)
                        .shadow(color: .black.opacity(0.55), radius: 6, y: 3)
                        .shadow(color: isCenter && !launchingMe ? tg.tint.opacity(0.7) : .clear, radius: 15)
                        .rotation3DEffect(.degrees(Double(1 - morph) * -30),
                                          axis: (x: 0.1, y: 1, z: 0), perspective: 0.7)
                        .scaleEffect(0.5 + 0.5 * morph)
                        .opacity(Double(morph))
                }
                Circle()
                    .stroke(Color.white.opacity(sin(Double(morph) * Double.pi) * 0.6), lineWidth: 2)
                    .frame(width: size, height: size)
                    .blur(radius: 1.5)
            }
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                if let ws = state.work[tg.id], morph > 0.55, !sess, alpha > 0 {
                    StatusBadge(ws: ws, tint: tg.tint, size: 11)
                        .padding(4)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .offset(x: 8, y: -6)
                }
            }
            .scaleEffect(hoverID == tg.id && isCenter && !launchingMe ? 1.07 : 1)
            .animation(.easeOut(duration: 0.15), value: hoverID)
            Text(tg.name)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.95))
                .shadow(color: .black.opacity(0.75), radius: 3)
                .fixedSize()
                .opacity(isCenter && !launchingMe && morph > 0.9 ? 1 : 0)
        }
        .contentShape(Rectangle().scale(1.3))
        .onTapGesture {
            if isCenter { onLaunch(tg) }
        }
        .onHover { h in
            if h { hoverID = tg.id } else if hoverID == tg.id { hoverID = -1 }
        }
        .allowsHitTesting(isCenter)
        .scaleEffect(x: launchingMe ? 0.22 : 1, y: launchingMe ? 2.6 : 1)
        .opacity(sess ? 0 : alpha)   // on launch everything dissolves; nothing ever falls back
        .blur(radius: u * 1.1)
        .position(x: launchingMe ? holeC.x : x,
                  y: launchingMe ? holeC.y + 8 : y)
        .zIndex(Double(2 - u))
    }

    private func edgeFade(_ x: CGFloat, _ y: CGFloat) -> Double {
        let fx = min(x, W - x) / 46
        let fy = min(y, H - y) / 26
        return Double(max(0, min(1, min(fx, fy))))
    }

    private func drawSpace(_ ctx: inout GraphicsContext, t: TimeInterval) {
        let tint = state.selectedTarget.tint
        let C = holeC
        // deep-space nebula — two parallax layers, no veil, composited straight onto the desktop
        if let cg = SpaceAssets.nebulaCG {
            let img = Image(decorative: cg, scale: 1.0)
            let dx = CGFloat(sin(t * 0.05)) * 8
            let dy = CGFloat(cos(t * 0.04)) * 4
            ctx.draw(img, in: CGRect(x: dx, y: dy - 4, width: 620, height: 204))
            ctx.opacity = 0.3
            let dx2 = CGFloat(sin(t * 0.032 + 2.0)) * 14
            ctx.draw(img, in: CGRect(x: -30 + dx2, y: -14, width: 680, height: 222))
            ctx.opacity = 1
        }
        if let cg2 = SpaceAssets.nebulaCG2 {
            let img2 = Image(decorative: cg2, scale: 1.0)
            let dx3 = CGFloat(sin(t * 0.041 + 4.5)) * 10
            ctx.opacity = 0.85
            ctx.draw(img2, in: CGRect(x: dx3, y: CGFloat(cos(t * 0.03)) * 3 - 2, width: 620, height: 204))
            ctx.opacity = 1
        }
        // distant planet silhouettes
        let sd1 = CGFloat(sin(t * 0.03)) * 5
        ctx.stroke(Path(ellipseIn: CGRect(x: 62 + sd1 - 52, y: 96, width: 104, height: 104)),
                   with: .color(.white.opacity(0.07)), lineWidth: 1)
        var ringP = Path()
        ringP.addEllipse(in: CGRect(x: -1, y: -0.26, width: 2, height: 0.52))
        let rtr = CGAffineTransform(translationX: 62 + sd1, y: 148).rotated(by: -0.32).scaledBy(x: 92, y: 92)
        ctx.stroke(ringP.applying(rtr), with: .color(.white.opacity(0.05)), lineWidth: 1)
        let sd2 = CGFloat(cos(t * 0.024)) * 4
        ctx.stroke(Path(ellipseIn: CGRect(x: 546 + sd2 - 25, y: 44, width: 50, height: 50)),
                   with: .color(.white.opacity(0.055)), lineWidth: 1)
        var cres = Path()
        cres.addArc(center: CGPoint(x: 546 + sd2, y: 69), radius: 25,
                    startAngle: .radians(-1.15), endAngle: .radians(1.15), clockwise: false)
        ctx.stroke(cres, with: .color(.white.opacity(0.13)), lineWidth: 1.5)
        ctx.stroke(Path(ellipseIn: CGRect(x: 428, y: 152, width: 26, height: 26)),
                   with: .color(.white.opacity(0.045)), lineWidth: 1)
        // parallax starfield with gravitational lensing
        for st in Self.stars {
            let speed: Double = st.far ? 2.0 : 4.6
            var x = st.x + CGFloat((t * speed).truncatingRemainder(dividingBy: 620))
            if x > 620 { x -= 620 }
            var y = st.y
            let dx = x - C.x
            let dy = y - C.y
            let r = max(0.001, sqrt(dx * dx + dy * dy))
            if r < 120 {
                let push = (900 / max(r, 12)) * (1 - r / 120)
                x += dx / r * push
                y += dy / r * push
            }
            let vis = min(1, max(0, (r - 40) / 50))
            let tw = 0.55 + 0.45 * sin(t * 2 + st.ph)
            let a = (st.far ? 0.5 : 0.8) * Double(vis) * tw * edgeFade(x, y)
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: st.r, height: st.r)),
                     with: .color(Color(red: 0.85, green: 0.88, blue: 1.0).opacity(a)))
        }
        // photon ring
        var ring = Path()
        ring.addEllipse(in: CGRect(x: C.x - 34, y: C.y - 12, width: 68, height: 24))
        ctx.stroke(ring, with: .color(.white.opacity(0.25)), lineWidth: 1.3)
        ctx.stroke(ring, with: .color(tint.opacity(0.16)), lineWidth: 4)
        // accretion arcs
        let rings: [(Double, Double, Double, CGFloat, Double)] = [
            (150, 40, 0.52, 4, 0.30),
            (188, 52, 0.34, 2.2, 0.20)
        ]
        for cfg in rings {
            let rx = cfg.0, ry = cfg.1, sp = cfg.2
            for seg in 0..<3 {
                let a0 = t * sp + Double(seg) * 2.094
                var p = Path()
                p.addArc(center: .zero, radius: 1,
                         startAngle: .radians(a0), endAngle: .radians(a0 + 1.45), clockwise: false)
                let tr = CGAffineTransform(translationX: C.x, y: C.y + 5)
                    .scaledBy(x: CGFloat(rx), y: CGFloat(ry))
                let path = p.applying(tr)
                ctx.stroke(path,
                           with: .linearGradient(Gradient(colors: [tint.opacity(0), tint.opacity(cfg.4), tint.opacity(0)]),
                                                 startPoint: CGPoint(x: C.x - CGFloat(rx), y: 0),
                                                 endPoint: CGPoint(x: C.x + CGFloat(rx), y: 0)),
                           style: StrokeStyle(lineWidth: cfg.3, lineCap: .round))
            }
        }
        // infalling dust
        for k in 0..<14 {
            let s = ((t * 0.055) + Double(k) / 14).truncatingRemainder(dividingBy: 1)
            let ang = s * 12 + Double(k) * 1.7
            let rad = (1 - s) * 175 + 14
            let px = C.x + CGFloat(cos(ang) * rad)
            let py = C.y + 6 + CGFloat(sin(ang) * rad * 0.3)
            let a = min(0.55, (1 - s) * s * 2.2) * edgeFade(px, py)
            ctx.fill(Path(ellipseIn: CGRect(x: px, y: py, width: 2.2, height: 2.2)),
                     with: .color(tint.opacity(a)))
        }
        // event horizon void
        ctx.fill(Path(ellipseIn: CGRect(x: C.x - 46, y: C.y - 17, width: 92, height: 34)),
                 with: .radialGradient(Gradient(colors: [.black, .black.opacity(0)]),
                                       center: C, startRadius: 6, endRadius: 46))
        // planet disintegration shards
        let dt = sparks.lastT == 0 ? 0.025 : min(0.05, t - sparks.lastT)
        sparks.lastT = t
        for tg in kTargets {
            let dd = wrapped(tg.id)
            let uu = CGFloat(min(1, abs(dd)))
            guard uu > 0.14 && uu < 0.34 && abs(dd) < 1 else { continue }
            let bb = 1 - abs((uu - 0.24) / 0.10)
            let sg: CGFloat = dd >= 0 ? 1 : -1
            let pp = OrbitView.flightPos(u: uu, sgn: sg)
            if sparks.parts.count < 110 {
                for _ in 0..<(2 + Int(bb * 3)) {
                    let a = Double(sparks.rnd()) * 6.283
                    let sp = (0.6 + sparks.rnd() * 2.0) * (0.7 + bb * 1.5)
                    sparks.parts.append(SparkBox.P(
                        x: pp.x + (sparks.rnd() - 0.5) * 30, y: pp.y + (sparks.rnd() - 0.5) * 30,
                        vx: CGFloat(cos(a)) * sp + sg * 0.8, vy: CGFloat(sin(a)) * sp - 0.3,
                        life: 0.55 + sparks.rnd() * 0.35,
                        rot: CGFloat(Double(sparks.rnd()) * 6.28), vr: (sparks.rnd() - 0.5) * 0.35,
                        app: tg.id, white: sparks.rnd() < 0.3,
                        size: (1.8 + sparks.rnd() * 2.8) * (0.6 + bb * 0.7)))
                }
            }
        }
        sparks.parts.removeAll { $0.life <= 0 }
        for i in sparks.parts.indices {
            sparks.parts[i].x += sparks.parts[i].vx
            sparks.parts[i].y += sparks.parts[i].vy
            sparks.parts[i].vx *= 0.965
            sparks.parts[i].vy = sparks.parts[i].vy * 0.965 + 0.05
            sparks.parts[i].rot += sparks.parts[i].vr
            sparks.parts[i].life -= CGFloat(dt) * 1.5
            let p = sparks.parts[i]
            let a = Double(max(0, min(1, p.life)))
            guard a > 0 else { continue }
            var rp = Path(CGRect(x: -p.size / 2, y: -p.size / 2, width: p.size, height: p.size))
            rp = rp.applying(CGAffineTransform(translationX: p.x, y: p.y).rotated(by: p.rot))
            let col = p.white ? Color.white.opacity(a * 0.85) : kTargets[p.app].tint.opacity(a * 0.8)
            ctx.fill(rp, with: .color(col))
        }
    }
}

struct PlanetView: View {
    let appID: Int
    let size: CGFloat
    var body: some View {
        if let cg = SpaceAssets.planets[appID] {
            Image(decorative: cg, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: size * 1.25, height: size * 1.25)
        }
    }
}


final class SparkBox {
    struct P {
        var x: CGFloat; var y: CGFloat; var vx: CGFloat; var vy: CGFloat
        var life: CGFloat; var rot: CGFloat; var vr: CGFloat
        var app: Int; var white: Bool; var size: CGFloat
    }
    var parts: [P] = []
    var lastT: TimeInterval = 0
    private var seed: UInt64 = 987654321
    func rnd() -> CGFloat {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((seed >> 33) & 0xFFFFFF) / CGFloat(0xFFFFFF)
    }
}
