// Variable-width outline of a path stroked with a Calligraphic brush.
// Faithful port of jas_dioxus/src/algorithms/calligraphic_outline.rs
// (which itself ports jas_flask/static/js/engine/geometry.mjs's
// `calligraphicOutline`).
//
// Brush parameters (BRUSHES.md §Brush types > Calligraphic):
//   angle     — degrees, screen-fixed orientation of the oval major axis
//   roundness — percent, 100 = circular, < 100 = elongated perpendicular to angle
//   size      — pt, major-axis length
//
// Per-point offset distance perpendicular to the path tangent:
//   φ = θ_brush − (θ_path + π/2)
//   d(φ) = √((a/2 · cos φ)² + (b/2 · sin φ)²)
// where a = brush.size, b = brush.size · brush.roundness / 100.
//
// Phase 1 limits: only the `fixed` variation mode is honoured;
// multi-subpath paths render the first subpath only.

import Foundation

public struct CalligraphicBrush: Equatable {
    public let angle: Double      // degrees, screen-fixed
    public let roundness: Double  // 0...100
    public let size: Double       // pt

    public init(angle: Double, roundness: Double, size: Double) {
        self.angle = angle
        self.roundness = roundness
        self.size = size
    }
}

private let SAMPLE_INTERVAL_PT: Double = 1.0
private let CUBIC_SAMPLES: Int = 32
private let QUADRATIC_SAMPLES: Int = 24

/// Compute the variable-width outline of `commands` stroked with a
/// Calligraphic brush. Returns the closed polygon's points (forward
/// along the left-offset, then back along the right-offset). Empty
/// array on degenerate input.
public func calligraphicOutline(_ commands: [PathCommand],
                                _ brush: CalligraphicBrush) -> [(Double, Double)] {
    let samples = sampleStrokePath(commands)
    if samples.count < 2 { return [] }

    let a = brush.size / 2.0
    let b = (brush.size * (brush.roundness / 100.0)) / 2.0
    let thetaBrush = brush.angle * .pi / 180.0

    var left: [(Double, Double)] = []
    var right: [(Double, Double)] = []
    left.reserveCapacity(samples.count)
    right.reserveCapacity(samples.count)
    for s in samples {
        let phi = thetaBrush - (s.tangent + .pi / 2.0)
        let d = (pow(a * cos(phi), 2) + pow(b * sin(phi), 2)).squareRoot()
        let nx = -sin(s.tangent)
        let ny = cos(s.tangent)
        left.append((s.x + nx * d, s.y + ny * d))
        right.append((s.x - nx * d, s.y - ny * d))
    }
    var out = left
    out.reserveCapacity(left.count + right.count)
    for p in right.reversed() { out.append(p) }
    return out
}

private struct Sample {
    let x: Double
    let y: Double
    let tangent: Double // radians
}

private func sampleStrokePath(_ commands: [PathCommand]) -> [Sample] {
    var out: [Sample] = []
    var cx: Double = 0.0, cy: Double = 0.0
    var sx: Double = 0.0, sy: Double = 0.0
    var started = false

    for cmd in commands {
        switch cmd {
        case .moveTo(let x, let y):
            if started { return out }
            cx = x; cy = y; sx = x; sy = y
        case .lineTo(let x, let y):
            sampleLine(&out, x0: cx, y0: cy, x1: x, y1: y)
            cx = x; cy = y; started = true
        case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
            sampleCubic(&out, x0: cx, y0: cy, x1: x1, y1: y1,
                        x2: x2, y2: y2, x3: x, y3: y)
            cx = x; cy = y; started = true
        case .quadTo(let x1, let y1, let x, let y):
            sampleQuadratic(&out, x0: cx, y0: cy, x1: x1, y1: y1, x2: x, y2: y)
            cx = x; cy = y; started = true
        case .closePath:
            if cx != sx || cy != sy {
                sampleLine(&out, x0: cx, y0: cy, x1: sx, y1: sy)
            }
            return out
        default:
            // Smooth/arc variants unsupported in Phase 1; bail.
            return out
        }
    }
    return out
}

private func sampleLine(_ out: inout [Sample],
                        x0: Double, y0: Double, x1: Double, y1: Double) {
    let len = ((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0)).squareRoot()
    if len == 0.0 { return }
    let tangent = atan2(y1 - y0, x1 - x0)
    let n = max(1, Int((len / SAMPLE_INTERVAL_PT).rounded(.up)))
    let startI = out.isEmpty ? 0 : 1
    for i in startI...n {
        let t = Double(i) / Double(n)
        out.append(Sample(
            x: x0 + (x1 - x0) * t,
            y: y0 + (y1 - y0) * t,
            tangent: tangent))
    }
}

private func sampleCubic(_ out: inout [Sample],
                         x0: Double, y0: Double, x1: Double, y1: Double,
                         x2: Double, y2: Double, x3: Double, y3: Double) {
    let startI = out.isEmpty ? 0 : 1
    for i in startI...CUBIC_SAMPLES {
        let t = Double(i) / Double(CUBIC_SAMPLES)
        let u = 1.0 - t
        let x = u*u*u * x0 + 3*u*u*t * x1 + 3*u*t*t * x2 + t*t*t * x3
        let y = u*u*u * y0 + 3*u*u*t * y1 + 3*u*t*t * y2 + t*t*t * y3
        let dx = 3*u*u * (x1 - x0) + 6*u*t * (x2 - x1) + 3*t*t * (x3 - x2)
        let dy = 3*u*u * (y1 - y0) + 6*u*t * (y2 - y1) + 3*t*t * (y3 - y2)
        let tangent: Double
        if dx == 0.0 && dy == 0.0 {
            tangent = atan2(y3 - y0, x3 - x0)
        } else {
            tangent = atan2(dy, dx)
        }
        out.append(Sample(x: x, y: y, tangent: tangent))
    }
}

private func sampleQuadratic(_ out: inout [Sample],
                             x0: Double, y0: Double, x1: Double, y1: Double,
                             x2: Double, y2: Double) {
    let startI = out.isEmpty ? 0 : 1
    for i in startI...QUADRATIC_SAMPLES {
        let t = Double(i) / Double(QUADRATIC_SAMPLES)
        let u = 1.0 - t
        let x = u*u * x0 + 2*u*t * x1 + t*t * x2
        let y = u*u * y0 + 2*u*t * y1 + t*t * y2
        let dx = 2*u * (x1 - x0) + 2*t * (x2 - x1)
        let dy = 2*u * (y1 - y0) + 2*t * (y2 - y1)
        let tangent: Double
        if dx == 0.0 && dy == 0.0 {
            tangent = atan2(y2 - y0, x2 - x0)
        } else {
            tangent = atan2(dy, dx)
        }
        out.append(Sample(x: x, y: y, tangent: tangent))
    }
}
