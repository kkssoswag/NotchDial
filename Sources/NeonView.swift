import SwiftUI
import AppKit

struct NeonView: View {
    @ObservedObject var state: IslandState
    var onLaunch: (AppTarget) -> Void
    @State private var shown: Int = 1
    @State private var lit: [Bool] = []
    @State private var glyphOn = true
    @State private var busy = false
    @State private var surge = false
    @State private var humTask: Task<Void, Never>? = nil

    private var app: AppTarget { kTargets[shown] }

    var body: some View {
        VStack(spacing: 12) {
            NeonGlyph(kind: app.id, on: glyphOn, tint: app.tint)
                .frame(width: 64, height: 46)
            HStack(spacing: 0) {
                let chars = Array(app.name.uppercased())
                ForEach(chars.indices, id: \.self) { k in
                    let on = k < lit.count && lit[k]
                    Text(String(chars[k]))
                        .font(.system(size: 25, weight: .heavy, design: .rounded))
                        .tracking(3.5)
                        .foregroundColor(on ? .white : Color(white: 0.15))
                        .shadow(color: on ? .white.opacity(0.85) : .clear, radius: 1.5)
                        .shadow(color: on ? app.tint.opacity(0.9) : .clear, radius: 6)
                        .shadow(color: on ? app.tint.opacity(0.6) : .clear, radius: 15)
                }
            }
            HStack(spacing: 9) {
                ForEach(kTargets) { t in
                    Group {
                        switch state.work[t.id] ?? .idle {
                        case .working:
                            WorkSpinner(tint: t.tint, size: 10, lineWidth: 1.8)
                        case .done:
                            DoneCheck(size: 10)
                        case .idle:
                            Circle()
                                .fill(t.id == state.centeredIndex ? t.tint : Color(white: 0.16))
                                .frame(width: 6, height: 6)
                                .shadow(color: t.id == state.centeredIndex ? t.tint : .clear, radius: 5)
                        }
                    }
                    .frame(width: 13, height: 13)
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, state.notchHeight * 0.55)
        .brightness(surge ? 0.42 : 0)
        .contentShape(Rectangle())
        .onTapGesture {
            guard state.phase == .expanded else { return }
            Task { @MainActor in
                surge = true
                try? await Task.sleep(nanoseconds: 130_000_000)
                surge = false
                try? await Task.sleep(nanoseconds: 80_000_000)
                surge = true
                try? await Task.sleep(nanoseconds: 130_000_000)
                surge = false
            }
            onLaunch(kTargets[state.centeredIndex])
        }
        .onAppear {
            shown = state.centeredIndex
            lit = Array(repeating: true, count: kTargets[state.centeredIndex].name.count)
            glyphOn = true
            startHum()
        }
        .onDisappear { humTask?.cancel() }
        .onChange(of: state.centeredIndex) { nv in
            if !busy { transition(to: nv) }
        }
    }

    private func transition(to nv: Int) {
        guard nv != shown else { return }
        busy = true
        Task { @MainActor in
            for k in stride(from: lit.count - 1, through: 0, by: -1) {
                lit[k] = false
                if Int.random(in: 0..<4) == 0 {
                    try? await Task.sleep(nanoseconds: 28_000_000)
                    lit[k] = true
                    try? await Task.sleep(nanoseconds: 38_000_000)
                    lit[k] = false
                }
                try? await Task.sleep(nanoseconds: 18_000_000)
            }
            glyphOn = false
            try? await Task.sleep(nanoseconds: 130_000_000)
            shown = nv
            lit = Array(repeating: false, count: kTargets[nv].name.count)
            try? await Task.sleep(nanoseconds: 60_000_000)
            glyphOn = true
            for k in 0..<lit.count {
                lit[k] = true
                if Int.random(in: 0..<4) == 0 {
                    try? await Task.sleep(nanoseconds: 32_000_000)
                    lit[k] = false
                    try? await Task.sleep(nanoseconds: 42_000_000)
                    lit[k] = true
                }
                try? await Task.sleep(nanoseconds: 36_000_000)
            }
            busy = false
            if state.centeredIndex != shown { transition(to: state.centeredIndex) }
        }
    }

    private func startHum() {
        humTask?.cancel()
        humTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 2.4...4.8) * 1_000_000_000))
                if Task.isCancelled { break }
                guard !busy, state.phase == .expanded, !lit.isEmpty else { continue }
                let k = Int.random(in: 0..<lit.count)
                lit[k] = false
                try? await Task.sleep(nanoseconds: 45_000_000)
                lit[k] = true
                try? await Task.sleep(nanoseconds: 60_000_000)
                lit[k] = false
                try? await Task.sleep(nanoseconds: 32_000_000)
                lit[k] = true
            }
        }
    }
}

struct NeonGlyph: View {
    let kind: Int
    let on: Bool
    let tint: Color
    var body: some View {
        Group {
            if kind == 0 {
                Text("❯_")
                    .font(.system(size: 32, weight: .heavy, design: .monospaced))
                    .kerning(-2)
                    .foregroundColor(on ? .white : Color(white: 0.15))
            } else if kind == 1 {
                CubeShape()
                    .stroke(on ? Color.white : Color(white: 0.15),
                            style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            } else {
                BurstShape()
                    .stroke(on ? Color.white : Color(white: 0.15),
                            style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }
        }
        .shadow(color: on ? .white.opacity(0.8) : .clear, radius: 1.5)
        .shadow(color: on ? tint.opacity(0.9) : .clear, radius: 7)
        .shadow(color: on ? tint.opacity(0.55) : .clear, radius: 16)
    }
}

struct CubeShape: Shape {
    func path(in r: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + x / 48 * r.width, y: r.minY + y / 48 * r.height)
        }
        var p = Path()
        p.move(to: pt(24, 5)); p.addLine(to: pt(43, 15.5)); p.addLine(to: pt(24, 26)); p.addLine(to: pt(5, 15.5)); p.closeSubpath()
        p.move(to: pt(5, 15.5)); p.addLine(to: pt(5, 34.5)); p.addLine(to: pt(24, 45)); p.addLine(to: pt(24, 26))
        p.move(to: pt(43, 15.5)); p.addLine(to: pt(43, 34.5)); p.addLine(to: pt(24, 45))
        return p
    }
}

struct BurstShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY)
        let R = min(r.width, r.height) / 2
        for i in 0..<8 {
            let a = Double(i) * .pi / 4
            let tip = CGPoint(x: c.x + CGFloat(cos(a)) * R, y: c.y + CGFloat(sin(a)) * R)
            let b1 = CGPoint(x: c.x + CGFloat(cos(a + 0.38)) * R * 0.2, y: c.y + CGFloat(sin(a + 0.38)) * R * 0.2)
            let b2 = CGPoint(x: c.x + CGFloat(cos(a - 0.38)) * R * 0.2, y: c.y + CGFloat(sin(a - 0.38)) * R * 0.2)
            p.move(to: b1); p.addLine(to: tip); p.addLine(to: b2); p.closeSubpath()
        }
        return p
    }
}
