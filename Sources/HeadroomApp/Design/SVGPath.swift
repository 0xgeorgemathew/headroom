import CoreGraphics
import Foundation

/// Parses SVG path data (`d`) into a CGPath. Supports the full command set, including arcs,
/// so the published brand marks render exactly as shipped in `assets/brand`.
enum SVGPath {
    static func parse(_ d: String) -> CGPath {
        var scanner = Scanner(Array(d.utf8))
        let path = CGMutablePath()
        var current = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint? = nil
        var lastQuad: CGPoint? = nil
        var command: UInt8 = 0

        while scanner.skipSeparators() {
            if let c = scanner.peekCommand() {
                command = c
                scanner.index += 1
            } else if command == 0 {
                break
            }
            let rel = command >= 97 // lowercase
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { rel ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y) }

            switch command | 0x20 {
            case UInt8(ascii: "m"):
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = pt(x, y); start = current
                path.move(to: current)
                command = rel ? UInt8(ascii: "l") : UInt8(ascii: "L") // implicit lineto
                lastControl = nil; lastQuad = nil
            case UInt8(ascii: "l"):
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = pt(x, y); path.addLine(to: current)
                lastControl = nil; lastQuad = nil
            case UInt8(ascii: "h"):
                guard let x = scanner.number() else { return path }
                current = CGPoint(x: rel ? current.x + x : x, y: current.y); path.addLine(to: current)
                lastControl = nil; lastQuad = nil
            case UInt8(ascii: "v"):
                guard let y = scanner.number() else { return path }
                current = CGPoint(x: current.x, y: rel ? current.y + y : y); path.addLine(to: current)
                lastControl = nil; lastQuad = nil
            case UInt8(ascii: "c"):
                guard let x1 = scanner.number(), let y1 = scanner.number(), let x2 = scanner.number(),
                      let y2 = scanner.number(), let x = scanner.number(), let y = scanner.number() else { return path }
                let c1 = pt(x1, y1), c2 = pt(x2, y2), end = pt(x, y)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2; lastQuad = nil; current = end
            case UInt8(ascii: "s"):
                guard let x2 = scanner.number(), let y2 = scanner.number(), let x = scanner.number(), let y = scanner.number() else { return path }
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = pt(x2, y2), end = pt(x, y)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2; lastQuad = nil; current = end
            case UInt8(ascii: "q"):
                guard let x1 = scanner.number(), let y1 = scanner.number(), let x = scanner.number(), let y = scanner.number() else { return path }
                let c = pt(x1, y1), end = pt(x, y)
                path.addQuadCurve(to: end, control: c)
                lastQuad = c; lastControl = nil; current = end
            case UInt8(ascii: "t"):
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                let c = lastQuad.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let end = pt(x, y)
                path.addQuadCurve(to: end, control: c)
                lastQuad = c; lastControl = nil; current = end
            case UInt8(ascii: "a"):
                guard let rx = scanner.number(), let ry = scanner.number(), let rot = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let end = pt(x, y)
                addArc(to: path, from: current, to: end, rx: rx, ry: ry, rotation: rot, largeArc: large, sweep: sweep)
                current = end; lastControl = nil; lastQuad = nil
            case UInt8(ascii: "z"):
                path.closeSubpath()
                current = start; lastControl = nil; lastQuad = nil
                command = 0
            default:
                return path
            }
        }
        return path
    }

    /// Endpoint-parameterized arc → center parameterization → Bézier segments (SVG 1.1 F.6.5).
    private static func addArc(to path: CGMutablePath, from p1: CGPoint, to p2: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat, rotation: CGFloat, largeArc: Bool, sweep: Bool) {
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 || p1 == p2 { path.addLine(to: p2); return }
        let phi = rotation * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx = (p1.x - p2.x) / 2, dy = (p1.y - p2.y) / 2
        let x1p = cosP * dx + sinP * dy
        let y1p = -sinP * dx + cosP * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { let s = sqrt(lambda); rx *= s; ry *= s }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = sqrt(max(0, num / den))
        if largeArc == sweep { coef = -coef }
        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * -(ry * x1p / rx)
        let cx = cosP * cxp - sinP * cyp + (p1.x + p2.x) / 2
        let cy = sinP * cxp + cosP * cyp + (p1.y + p2.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let t = 4 / 3 * tan(step / 4)
        var a = theta1
        for _ in 0..<segments {
            let c1 = cos(a), s1 = sin(a), c2 = cos(a + step), s2 = sin(a + step)
            func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: cx + rx * x * cosP - ry * y * sinP, y: cy + rx * x * sinP + ry * y * cosP)
            }
            path.addCurve(
                to: map(c2, s2),
                control1: map(c1 - t * s1, s1 + t * c1),
                control2: map(c2 + t * s2, s2 - t * c2)
            )
            a += step
        }
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0
        init(_ b: [UInt8]) { bytes = b }

        /// Skips whitespace and commas; returns false at end of input.
        mutating func skipSeparators() -> Bool {
            while index < bytes.count, bytes[index] == 32 || bytes[index] == 44 || bytes[index] == 9 || bytes[index] == 10 || bytes[index] == 13 {
                index += 1
            }
            return index < bytes.count
        }

        func peekCommand() -> UInt8? {
            guard index < bytes.count else { return nil }
            let b = bytes[index] | 0x20
            return (b >= 97 && b <= 122 && b != 101) ? bytes[index] : nil // letters except 'e'
        }

        mutating func flag() -> Bool? {
            _ = skipSeparators()
            guard index < bytes.count else { return nil }
            let b = bytes[index]
            guard b == 48 || b == 49 else { return nil }
            index += 1
            return b == 49
        }

        mutating func number() -> CGFloat? {
            _ = skipSeparators()
            let startIndex = index
            if index < bytes.count, bytes[index] == 45 || bytes[index] == 43 { index += 1 }
            var sawDot = false, sawDigit = false
            while index < bytes.count {
                let b = bytes[index]
                if b >= 48 && b <= 57 { sawDigit = true; index += 1 }
                else if b == 46 && !sawDot { sawDot = true; index += 1 }
                else { break }
            }
            if index < bytes.count, bytes[index] | 0x20 == 101, sawDigit {
                index += 1
                if index < bytes.count, bytes[index] == 45 || bytes[index] == 43 { index += 1 }
                while index < bytes.count, bytes[index] >= 48 && bytes[index] <= 57 { index += 1 }
            }
            guard sawDigit, let s = String(bytes: bytes[startIndex..<index], encoding: .ascii), let v = Double(s) else {
                index = startIndex
                return nil
            }
            return CGFloat(v)
        }
    }
}
