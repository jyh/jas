import Testing
import CoreGraphics
@testable import JasLib

// THE CAP-DIRECTION QUESTION, SETTLED BY MEASUREMENT RATHER THAN BY READING.
//
// Before the geometry was split out of the rasterisation, the two ports handed
// the same four numbers to two differently-spelled platform calls:
//
//     Rust    ctx.arc_with_anticlockwise(cx, cy, r, a0, a1, /* anticlockwise */ true)
//     Swift   path.addArc(center:radius:startAngle:endAngle:, clockwise: true)
//
// and Swift then drew that path into a CGContext carrying a y-flip
// (`CanvasSubwindow` is an `isFlipped` view). A divergence was FLAGGED on the
// strength of the two words disagreeing. A later reading concluded it was
// probably absent -- and recorded itself, correctly, as a READING AND NOT A
// MEASUREMENT.
//
// These tests are the measurement. They do not ask what Apple's prose says;
// they build a real CGMutablePath and read the points back out of it.
//
// WHAT REMAINS A READING, stated so nobody mistakes this file for more than it
// is: the OTHER half of the pair. There is no browser in a `swift test` and
// none in a `cargo test`, so what `anticlockwise: true` does on a canvas is
// taken from the WHATWG specification (the arc is traced "going anti-clockwise
// if counterclockwise is true", and canvas angles are measured from the
// positive x-axis in a y-down space, so anti-clockwise IS decreasing angle).
// That asymmetry is exactly why the product no longer depends on the answer:
// both ports now flatten the cap through the shared arithmetic in
// `flattenOutline` and neither asks its platform to interpret a sweep flag.

/// The on-curve points of a CGPath, in order. CoreGraphics turns an arc into
/// cubic segments whose CONTROL points sit off the circle, so only the segment
/// endpoints are collected -- a test that averaged the control points in would
/// be measuring the approximation, not the sweep.
private func onCurvePoints(_ path: CGPath) -> [CGPoint] {
    var pts: [CGPoint] = []
    path.applyWithBlock { element in
        let e = element.pointee
        switch e.type {
        case .moveToPoint, .addLineToPoint:
            pts.append(e.points[0])
        case .addQuadCurveToPoint:
            pts.append(e.points[1])
        case .addCurveToPoint:
            pts.append(e.points[2])
        case .closeSubpath:
            break
        @unknown default:
            break
        }
    }
    return pts
}

@Test func coreGraphicsClockwiseTrueSweepsTowardDecreasingAngle() {
    // The exact call the start cap of an eastward 10pt stroke makes: centred
    // on the origin, radius 5, from the right rail at -90 degrees to the left
    // rail at +90 degrees.
    let path = CGMutablePath()
    path.addArc(center: CGPoint(x: 0, y: 0), radius: 5,
                startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: true)
    let pts = onCurvePoints(path)

    #expect(pts.count >= 3)

    // It begins and ends ON the two rails.
    #expect(abs(pts.first!.x - 0) < 1e-9)
    #expect(abs(pts.first!.y - -5) < 1e-9)
    #expect(abs(pts.last!.x - 0) < 1e-9)
    #expect(abs(pts.last!.y - 5) < 1e-9)

    // Every on-curve point is on the circle.
    for p in pts {
        #expect(abs(sqrt(p.x * p.x + p.y * p.y) - 5) < 1e-9)
    }

    // THE ANSWER. `clockwise: true` takes the sweep round the side where x is
    // NEGATIVE -- through angle 180, i.e. toward DECREASING angle -- and not
    // through angle 0. That is the same sweep the WHATWG canvas spec gives
    // `anticlockwise: true` for these arguments, so the two spellings denote
    // the same arc and the flagged divergence IS ABSENT.
    #expect(pts.contains { $0.x < -1e-9 })
    #expect(!pts.contains { $0.x > 1e-9 })
}

@Test func coreGraphicsArcAndTheSharedFlattenerTraceTheSameCap() {
    // The replacement must not move the cap. Same arc, once through
    // CoreGraphics and once through the arithmetic both ports now share.
    let path = CGMutablePath()
    path.addArc(center: CGPoint(x: 0, y: 0), radius: 5,
                startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: true)
    let cg = onCurvePoints(path)

    let outline = variableWidthOutlinePath(
        [.moveTo(0, 0), .lineTo(10, 0)],
        widthPoints: [StrokeWidthPoint(t: 0, widthLeft: 5, widthRight: 5),
                      StrokeWidthPoint(t: 1, widthLeft: 5, widthRight: 5)],
        linecap: .round)
    guard case .round(let cx, let cy, let r, let a0, let a1, let decreasing) =
            outline.startCap
    else {
        Issue.record("the start cap of a round-capped stroke should be round")
        return
    }
    #expect(cx == 0 && cy == 0 && r == 5 && decreasing)
    #expect(abs(a0 - -.pi / 2) < 1e-12)
    #expect(abs(a1 - .pi / 2) < 1e-12)

    // Every CoreGraphics on-curve point lands on the flattened polyline's
    // circle at an angle inside the same sweep, traversed the same way.
    let poly = flattenOutline(outline, arcSteps: capArcSteps)
    // poly[0] is the rail the renderer moves to; poly[1...] begins the arc.
    let flat = Array(poly[1...(1 + capArcSteps)])
    #expect(abs(flat.first!.x - cg.first!.x) < 1e-9)
    #expect(abs(flat.first!.y - cg.first!.y) < 1e-9)
    #expect(abs(flat.last!.x - cg.last!.x) < 1e-9)
    #expect(abs(flat.last!.y - cg.last!.y) < 1e-9)
    // The polyline's chord error against the true circle, which is what the
    // switch from a platform arc to shared arithmetic costs: r*(1-cos(pi/2n)).
    let worst = 5.0 * (1 - cos(.pi / (2 * Double(capArcSteps))))
    #expect(worst < 0.01)
}

@Test func theYFlipCannotMoveTheCapToTheWrongEnd() {
    // The other half of the flagged finding: Swift draws this path into a
    // y-flipped context. Measured rather than argued -- the flip is applied to
    // the WHOLE polygon, rails and cap together, so the cap stays beyond the
    // end of the spine it belongs to.
    let outline = variableWidthOutlinePath(
        [.moveTo(0, 0), .lineTo(10, 0)],
        widthPoints: [StrokeWidthPoint(t: 0, widthLeft: 5, widthRight: 5),
                      StrokeWidthPoint(t: 1, widthLeft: 5, widthRight: 5)],
        linecap: .round)
    let poly = flattenOutline(outline, arcSteps: 8)
    let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 400)

    // The spine runs (0,0) -> (10,0); under the flip it runs (0,400) ->
    // (10,400), so "before the start" is still x < 0 and "after the end" is
    // still x > 10, in both spaces.
    for space in ["unflipped", "flipped"] {
        let ps = poly.map { p -> CGPoint in
            let q = CGPoint(x: p.x, y: p.y)
            return space == "flipped" ? q.applying(flip) : q
        }
        #expect(ps.contains { $0.x < -4.9 },
                "\(space): the start cap should reach behind x=0")
        #expect(ps.contains { $0.x > 14.9 },
                "\(space): the end cap should reach beyond x=10")
    }
}

@Test func aRoundCapBeginsOnTheRailItIsJoinedTo() {
    // The regression this family was written against, as an in-port test so a
    // Swift-only edit reds without waiting for the cross-language runner.
    // Two directions, because the defect was a REFLECTION: it agreed with the
    // truth along one axis and diverged by twice the angle everywhere else.
    for (dx, dy) in [(10.0, 0.0), (0.0, 10.0), (7.0, 7.0), (-3.0, 9.0)] {
        let outline = variableWidthOutlinePath(
            [.moveTo(0, 0), .lineTo(dx, dy)],
            widthPoints: [StrokeWidthPoint(t: 0, widthLeft: 5, widthRight: 5),
                          StrokeWidthPoint(t: 1, widthLeft: 5, widthRight: 5)],
            linecap: .round)
        guard case .round(let cx, let cy, let r, let a0, let a1, _) =
                outline.startCap else {
            Issue.record("expected a round start cap")
            return
        }
        let begin = CGPoint(x: cx + r * cos(a0), y: cy + r * sin(a0))
        let finish = CGPoint(x: cx + r * cos(a1), y: cy + r * sin(a1))
        let rail0 = outline.right[0], rail1 = outline.left[0]
        #expect(abs(begin.x - rail0.x) < 1e-9 && abs(begin.y - rail0.y) < 1e-9,
                "cap start off the right rail for direction (\(dx),\(dy))")
        #expect(abs(finish.x - rail1.x) < 1e-9 && abs(finish.y - rail1.y) < 1e-9,
                "cap end off the left rail for direction (\(dx),\(dy))")
    }
}
