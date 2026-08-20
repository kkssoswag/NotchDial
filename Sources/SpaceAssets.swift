import AppKit
import SwiftUI

// Pre-rendered space assets: nebula texture + textured planet sprites
enum SpaceAssets {
    static let nebulaCG: CGImage? = generate(w: 930, h: 294)
    static let nebulaCG2: CGImage? = generateTeal(w: 930, h: 294)
    static let planets: [CGImage?] = (0..<3).map { planetSprite(app: $0, px: 240) }

    private static func hash(_ x: Int, _ y: Int) -> CGFloat {
        var h = UInt64(bitPattern: Int64(x &* 374761393 &+ y &* 668265263))
        h = (h ^ (h >> 13)) &* 1274126177
        h = h ^ (h >> 16)
        return CGFloat(h & 0xFFFF) / 65535.0
    }
    private static func smooth(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }
    private static func vnoise(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
        let xi = Int(floor(x)), yi = Int(floor(y))
        let fx = smooth(x - floor(x)), fy = smooth(y - floor(y))
        let a = hash(xi, yi), b = hash(xi + 1, yi)
        let c = hash(xi, yi + 1), d = hash(xi + 1, yi + 1)
        return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy
    }
    private static func fbm(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
        var v: CGFloat = 0, amp: CGFloat = 0.5, fx = x, fy = y
        for _ in 0..<4 {
            v += amp * vnoise(fx, fy)
            fx *= 2.03; fy *= 2.01; amp *= 0.5
        }
        return v
    }
    private static func gauss(_ x: CGFloat, _ y: CGFloat, _ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGFloat {
        let dx = (x - cx) / rx, dy = (y - cy) / ry
        return exp(-(dx * dx + dy * dy))
    }

    // MARK: nebula
    private static func generate(w: Int, h: Int) -> CGImage? {
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let W = CGFloat(w), H = CGFloat(h)
        for py in 0..<h {
            for px in 0..<w {
                let u = CGFloat(px), v = CGFloat(py)
                let wx = fbm(u * 0.0048 + 3.7, v * 0.0080 + 1.3)
                let wy = fbm(u * 0.0056 + 9.2, v * 0.0086 + 5.8)
                let n = fbm(u * 0.0058 + wx * 2.0, v * 0.0096 + wy * 2.0)
                var m = min(1.0,
                            gauss(u, v, W * 0.18, H * 0.58, W * 0.26, H * 0.55)
                          + gauss(u, v, W * 0.82, H * 0.46, W * 0.26, H * 0.58) * 0.95
                          + gauss(u, v, W * 0.50, H * 1.10, W * 0.50, H * 0.28) * 0.35)
                m *= (1.0 - gauss(u, v, W * 0.50, H * 0.30, W * 0.24, H * 0.52) * 0.9)
                let ef = min(1.0, min(u, W - u) / 78) * min(1.0, min(v, H - v) / 42)
                var a = pow(max(0, n - 0.40) / 0.60, 1.7) * m * ef
                a = min(0.5, a)
                let tmix = smooth(max(0, min(1, (n - 0.45) / 0.45)))
                var r = 16 + (52 - 16) * tmix
                var g = 14 + (40 - 14) * tmix
                var b = 44 + (112 - 44) * tmix
                let hi = smooth(max(0, min(1, (n - 0.78) / 0.22)))
                r += (118 - r) * hi; g += (138 - g) * hi; b += (198 - b) * hi
                if hash(px &* 7 &+ 1, py &* 13 &+ 5) > 0.995 {
                    let sa = 0.35 * m * ef
                    r = 220; g = 226; b = 255
                    a = max(a, sa)
                }
                let idx = (py * w + px) * 4
                buf[idx]     = UInt8(max(0, min(255, r * a)))
                buf[idx + 1] = UInt8(max(0, min(255, g * a)))
                buf[idx + 2] = UInt8(max(0, min(255, b * a)))
                buf[idx + 3] = UInt8(max(0, min(255, a * 255)))
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return ctx.makeImage()
    }

    private static func generateTeal(w: Int, h: Int) -> CGImage? {
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let W = CGFloat(w), H = CGFloat(h)
        for py in 0..<h {
            for px in 0..<w {
                let u = CGFloat(px), v = CGFloat(py)
                let wx = fbm(u * 0.0044 + 13.1, v * 0.0074 + 7.9)
                let wy = fbm(u * 0.0052 + 4.4, v * 0.0090 + 2.2)
                let n = fbm(u * 0.0054 + wx * 2.1, v * 0.0090 + wy * 2.1)
                var m = min(1.0,
                            gauss(u, v, W * 0.50, H * 0.10, W * 0.34, H * 0.42) * 0.85
                          + gauss(u, v, W * 0.06, H * 0.92, W * 0.30, H * 0.50)
                          + gauss(u, v, W * 0.94, H * 0.86, W * 0.26, H * 0.44) * 0.8)
                m *= (1.0 - gauss(u, v, W * 0.50, H * 0.34, W * 0.20, H * 0.42) * 0.6)
                let ef = min(1.0, min(u, W - u) / 78) * min(1.0, min(v, H - v) / 42)
                var a = pow(max(0, n - 0.42) / 0.58, 1.8) * m * ef
                a = min(0.42, a)
                let tmix = smooth(max(0, min(1, (n - 0.46) / 0.44)))
                var r = 10 + (26 - 10) * tmix
                var g = 26 + (68 - 26) * tmix
                var b = 30 + (76 - 30) * tmix
                let hi = smooth(max(0, min(1, (n - 0.80) / 0.20)))
                r += (92 - r) * hi; g += (160 - g) * hi; b += (162 - b) * hi
                let idx = (py * w + px) * 4
                buf[idx]     = UInt8(max(0, min(255, r * a)))
                buf[idx + 1] = UInt8(max(0, min(255, g * a)))
                buf[idx + 2] = UInt8(max(0, min(255, b * a)))
                buf[idx + 3] = UInt8(max(0, min(255, a * 255)))
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return ctx.makeImage()
    }

    // MARK: textured planets
    private struct Pal { let hi: (CGFloat, CGFloat, CGFloat); let lo: (CGFloat, CGFloat, CGFloat); let ac: (CGFloat, CGFloat, CGFloat) }
    private static let pals: [Pal] = [
        Pal(hi: (0.66, 0.72, 1.00), lo: (0.09, 0.11, 0.32), ac: (0.38, 0.30, 0.86)),   // Codex: indigo gas giant
        Pal(hi: (0.86, 0.86, 0.90), lo: (0.07, 0.07, 0.09), ac: (0.42, 0.44, 0.52)),   // Cursor: silver rock
        Pal(hi: (0.98, 0.66, 0.42), lo: (0.26, 0.09, 0.05), ac: (0.80, 0.34, 0.18)),   // Claude: clay desert
    ]

    private static func planetSprite(app: Int, px: Int) -> CGImage? {
        var buf = [UInt8](repeating: 0, count: px * px * 4)
        let half = CGFloat(px) / 2
        let R = half * 0.80
        let p = pals[app]
        for y in 0..<px {
            for x in 0..<px {
                let dx = (CGFloat(x) - half) / R
                let dy = (CGFloat(y) - half) / R
                let rr = dx * dx + dy * dy
                let idx = (y * px + x) * 4
                if rr <= 1.0 {
                    let dz = sqrt(1 - rr)
                    let edgeA = min(1, max(0, (1 - sqrt(rr)) * R / 1.6))
                    var diff = max(0, dx * (-0.45) + dy * (-0.50) + dz * 0.74)
                    diff = 0.10 + 0.90 * diff
                    let n = fbm(CGFloat(x) * 0.05 + CGFloat(app) * 41.7, CGFloat(y) * 0.09 + CGFloat(app) * 13.3)
                    let swirl = fbm(CGFloat(x) * 0.016 + n * 3.0, CGFloat(y) * 0.03 + CGFloat(app) * 7.7)
                    let band = 0.5 + 0.5 * sin((dy * 3.0 + swirl * 3.4 + n * 0.8) * 3.14159)
                    let tex = 0.30 + 0.70 * (0.55 * band + 0.45 * n)
                    var r = p.lo.0 + (p.hi.0 - p.lo.0) * tex
                    var g = p.lo.1 + (p.hi.1 - p.lo.1) * tex
                    var b = p.lo.2 + (p.hi.2 - p.lo.2) * tex
                    let sw = smooth(max(0, min(1, (swirl - 0.60) / 0.40)))
                    r += (p.ac.0 - r) * sw * 0.55
                    g += (p.ac.1 - g) * sw * 0.55
                    b += (p.ac.2 - b) * sw * 0.55
                    let limb = 0.52 + 0.48 * dz
                    r *= diff * limb; g *= diff * limb; b *= diff * limb
                    let spec = pow(max(0, dx * (-0.48) + dy * (-0.52) + dz * 0.71), 26) * 0.45
                    r = min(1, r + spec); g = min(1, g + spec); b = min(1, b + spec)
                    let a = edgeA
                    buf[idx]     = UInt8(max(0, min(255, r * 255 * a)))
                    buf[idx + 1] = UInt8(max(0, min(255, g * 255 * a)))
                    buf[idx + 2] = UInt8(max(0, min(255, b * 255 * a)))
                    buf[idx + 3] = UInt8(max(0, min(255, a * 255)))
                } else {
                    let d = (sqrt(rr) - 1) * R
                    let glow = max(0, 1 - d / (half - R + 1))
                    if glow > 0 {
                        let a = glow * glow * 0.5
                        buf[idx]     = UInt8(max(0, min(255, p.hi.0 * 255 * a)))
                        buf[idx + 1] = UInt8(max(0, min(255, p.hi.1 * 255 * a)))
                        buf[idx + 2] = UInt8(max(0, min(255, p.hi.2 * 255 * a)))
                        buf[idx + 3] = UInt8(max(0, min(255, a * 255)))
                    }
                }
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &buf, width: px, height: px, bitsPerComponent: 8,
                                  bytesPerRow: px * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return ctx.makeImage()
    }
}
