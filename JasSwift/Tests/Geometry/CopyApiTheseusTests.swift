import Testing
@testable import JasLib

/// EDIT_SEMANTICS_FREEZE.md **§3.1, the Theseus clause**: a 1→1 edit preserves
/// every field it does not speak to.
///
/// `withMask` speaks to exactly `mask`. `withWidthPoints` speaks to exactly
/// `widthPoints`. Both are 1→1: they hand back the SAME element with one field
/// rewritten, so §3.1 applies in full — `id` and `name` included. Both were
/// open-coded rebuilds that restated each field by hand, and per §3.5:
///
///   * `withMask`, `.path` arm — dropped `fillGradient`, `strokeGradient`,
///     `strokeBrush`, `strokeBrushOverrides`, `toolOrigin`, `name`, `id`; the
///     `.line` arm additionally dropped `strokeGradient`; every non-Layer arm
///     dropped `name` and `id`.
///   * `withWidthPoints`, `.path` arm — dropped those seven plus `blendMode`
///     and `mask`; the `.line` arm likewise.
///
/// Rust's twins are `..e.clone()` / clone-then-`common_mut()` and conform, so
/// each of these was a one-sided live divergence: masking a cited path, or
/// setting a width profile from the Stroke panel or the eyedropper, destroyed
/// the identity that references, symbols and the ledger are keyed on.
///
/// METHOD. Three assertions per copy API, none of them carrying a field list:
///
///   1. **The no-op law.** Writing a field the value it already holds must be
///      the identity: `withMask(e, mask: e.mask) == e`. Equatable compares
///      every stored property, so any dropped field fails it.
///   2. **The subject law.** Writing a DIFFERENT value must change that field
///      and nothing else — a `Mirror` walk over the payload struct comparing
///      every stored property except the subject, plus a direct assertion that
///      the subject itself did change. That direct assertion is the
///      geometry/value pairing the enforcement doctrine requires: a
///      field-list-free walk is structurally blind to whether the edit landed,
///      and a `withMask` that returned its input unchanged would satisfy the
///      walk alone.
///   3. **The anti-vacuity guard** (§3.1(i)): every non-subject stored property
///      of every fixture differs from a default-constructed element's, because
///      a field sitting at its default is one whose loss the other two
///      assertions cannot see. It also asserts the reflected child count is
///      non-zero per kind, so a payload Mirror cannot silently walk nothing.
///
/// The kinds covered are the nine struct kinds `withMask` rebuilds field by
/// field. `.text` / `.textPath` are NOT covered here (their fixtures are a
/// separate body of work) and `.live` delegates to `LiveVariant.withMask`,
/// which is already clone-then-mutate.

// MARK: - Fixture helpers

private func probe(_ tag: Double) -> Mask {
    Mask(subtreeElement: .rect(Rect(x: tag, y: tag, width: 3, height: 4)),
         clip: false, invert: true, disabled: true, linked: false,
         unlinkTransform: Transform.translate(tag, tag))
}

private func grad(_ angle: Double) -> Gradient {
    Gradient(type: .radial, angle: angle, aspectRatio: 200, method: .smooth,
             dither: true, strokeSubMode: .within,
             stops: [GradientStop(color: "#00ff00", opacity: 100, location: 0, midpointToNext: 50),
                     GradientStop(color: "#0000ff", opacity: 100, location: 100, midpointToNext: 50)])
}

private let richFill = Fill(color: Color(r: 0.2, g: 0.4, b: 0.6))
private let richStroke = Stroke(color: Color(r: 0.9, g: 0.1, b: 0.1), width: 3.5)
private let richWidthPoints = [StrokeWidthPoint(t: 0, widthLeft: 0.5, widthRight: 2.5),
                               StrokeWidthPoint(t: 1, widthLeft: 2.5, widthRight: 0.5)]

/// Every stored property set away from its default (except the geometry, which
/// has no default), for each kind `withMask` rebuilds by hand.
private func populated() -> [(String, Element)] {
    [
        ("line", .line(Line(x1: 1, y1: 2, x2: 3, y2: 4,
                            stroke: richStroke, widthPoints: richWidthPoints,
                            opacity: 0.42, transform: Transform.translate(7, 11),
                            locked: true, visibility: .outline, blendMode: .multiply,
                            mask: probe(1), strokeGradient: grad(60),
                            name: "my-line", id: "line-1"))),
        ("rect", .rect(Rect(x: 1, y: 2, width: 3, height: 4, rx: 5, ry: 6,
                            fill: richFill, stroke: richStroke,
                            opacity: 0.42, transform: Transform.translate(7, 11),
                            locked: true, visibility: .outline, blendMode: .multiply,
                            mask: probe(2), fillGradient: grad(30), strokeGradient: grad(60),
                            name: "my-rect", id: "rect-1"))),
        ("circle", .circle(Circle(cx: 1, cy: 2, r: 3,
                                  fill: richFill, stroke: richStroke,
                                  opacity: 0.42, transform: Transform.translate(7, 11),
                                  locked: true, visibility: .outline, blendMode: .multiply,
                                  mask: probe(3), fillGradient: grad(30), strokeGradient: grad(60),
                                  name: "my-circle", id: "circle-1"))),
        ("ellipse", .ellipse(Ellipse(cx: 1, cy: 2, rx: 3, ry: 4,
                                     fill: richFill, stroke: richStroke,
                                     opacity: 0.42, transform: Transform.translate(7, 11),
                                     locked: true, visibility: .outline, blendMode: .multiply,
                                     mask: probe(4), fillGradient: grad(30), strokeGradient: grad(60),
                                     name: "my-ellipse", id: "ellipse-1"))),
        ("polyline", .polyline(Polyline(points: [(0, 0), (10, 10)],
                                        fill: richFill, stroke: richStroke,
                                        opacity: 0.42, transform: Transform.translate(7, 11),
                                        locked: true, visibility: .outline, blendMode: .multiply,
                                        mask: probe(5), fillGradient: grad(30), strokeGradient: grad(60),
                                        name: "my-polyline", id: "polyline-1"))),
        ("polygon", .polygon(Polygon(points: [(0, 0), (10, 0), (10, 10)],
                                     fill: richFill, stroke: richStroke,
                                     opacity: 0.42, transform: Transform.translate(7, 11),
                                     locked: true, visibility: .outline, blendMode: .multiply,
                                     mask: probe(6), fillGradient: grad(30), strokeGradient: grad(60),
                                     name: "my-polygon", id: "polygon-1"))),
        ("path", .path(Path(d: [.moveTo(0, 0), .lineTo(10, 10)],
                            fill: richFill, stroke: richStroke,
                            widthPoints: richWidthPoints,
                            opacity: 0.42, transform: Transform.translate(7, 11),
                            locked: true, visibility: .outline, blendMode: .multiply,
                            mask: probe(7), fillGradient: grad(30), strokeGradient: grad(60),
                            strokeBrush: "calligraphic/flat-6pt",
                            strokeBrushOverrides: "{\"angle\":45}",
                            toolOrigin: "blob_brush",
                            name: "my-path", id: "path-1", fillRule: .evenodd))),
        ("group", .group(Group(children: [.rect(Rect(x: 0, y: 0, width: 1, height: 1))],
                               opacity: 0.42, transform: Transform.translate(7, 11),
                               locked: true, visibility: .outline, blendMode: .multiply,
                               isolatedBlending: true, knockoutGroup: true,
                               mask: probe(8), name: "my-group", id: "group-1"))),
        ("layer", .layer(Layer(name: "my-layer",
                               children: [.rect(Rect(x: 0, y: 0, width: 1, height: 1))],
                               opacity: 0.42, transform: Transform.translate(7, 11),
                               locked: true, visibility: .outline, blendMode: .multiply,
                               isolatedBlending: true, knockoutGroup: true,
                               mask: probe(9), id: "layer-1"))),
    ]
}

/// The same nine kinds with nothing but their geometry — the defaults the
/// anti-vacuity guard measures the fixtures against.
private func minimal() -> [(String, Element)] {
    [
        ("line", .line(Line(x1: 1, y1: 2, x2: 3, y2: 4))),
        ("rect", .rect(Rect(x: 1, y: 2, width: 3, height: 4))),
        ("circle", .circle(Circle(cx: 1, cy: 2, r: 3))),
        ("ellipse", .ellipse(Ellipse(cx: 1, cy: 2, rx: 3, ry: 4))),
        ("polyline", .polyline(Polyline(points: [(0, 0), (10, 10)]))),
        ("polygon", .polygon(Polygon(points: [(0, 0), (10, 0), (10, 10)]))),
        ("path", .path(Path(d: [.moveTo(0, 0), .lineTo(10, 10)], fillRule: .nonzero))),
        ("group", .group(Group(children: [.rect(Rect(x: 0, y: 0, width: 1, height: 1))]))),
        ("layer", .layer(Layer(children: [.rect(Rect(x: 0, y: 0, width: 1, height: 1))]))),
    ]
}

/// The struct behind an `Element` case. `Mirror` over the enum yields exactly
/// one child — the associated value — so one hop reaches the payload for every
/// non-`.live` kind.
private func payload(_ e: Element) -> Any {
    guard let v = Mirror(reflecting: e).children.first?.value else {
        Issue.record("Element case has no associated value")
        return e
    }
    return v
}

private func labelled(_ v: Any) -> [String: String] {
    Dictionary(uniqueKeysWithValues:
        Mirror(reflecting: v).children.compactMap { c -> (String, String)? in
            guard let l = c.label else { return nil }
            return (l, String(describing: c.value))
        })
}

/// Compare every stored property of two payloads except `subject`.
private func expectOnlySubjectChanged(_ before: Any, _ after: Any,
                                      subject: String, _ what: String) {
    let b = labelled(before)
    let a = labelled(after)
    #expect(!a.isEmpty, "\(what): reflected zero stored properties")
    #expect(a.keys.sorted() == b.keys.sorted(), "\(what): field sets differ")
    for (label, value) in a where label != subject {
        #expect(value == b[label], "\(what) changed \(label)")
    }
}

// MARK: - The anti-vacuity guard

@Test func copyApiFixturesDifferFromDefaultInEveryField() {
    let mins = Dictionary(uniqueKeysWithValues: minimal())
    for (kind, rich) in populated() {
        guard let plain = mins[kind] else {
            Issue.record("no minimal counterpart for \(kind)"); continue
        }
        let r = labelled(payload(rich))
        let p = labelled(payload(plain))
        #expect(!r.isEmpty, "\(kind): reflected zero stored properties")
        // Geometry fields have no default and are equal by construction; the
        // guard covers every field a copy helper could silently drop.
        let geometry: Set<String> = ["x1", "y1", "x2", "y2", "x", "y", "width",
                                     "height", "cx", "cy", "r", "rx", "ry",
                                     "points", "d", "children"]
        for (label, value) in r where !geometry.contains(label) {
            #expect(value != p[label],
                    "\(kind).\(label) is at its default in the fixture — a drop of that field would be invisible to these tests")
        }
    }
}

// MARK: - withMask

/// Writing the mask an element already carries must be the identity.
@Test func withMaskIsIdentityWhenTheMaskIsUnchanged() {
    for (kind, e) in populated() {
        #expect(withMask(e, mask: e.mask) == e,
                "withMask dropped a field on \(kind)")
    }
}

/// Writing a different mask must change `mask` and nothing else.
@Test func withMaskChangesOnlyTheMask() {
    let fresh = probe(99)
    for (kind, e) in populated() {
        let after = withMask(e, mask: fresh)
        // Value pairing: the subject actually moved.
        #expect(after.mask == fresh, "withMask did not set the mask on \(kind)")
        expectOnlySubjectChanged(payload(e), payload(after),
                                 subject: "mask", "withMask on \(kind)")
    }
    // Removing a mask is the same edit in the other direction.
    for (kind, e) in populated() {
        let after = withMask(e, mask: nil)
        #expect(after.mask == nil, "withMask(nil) did not clear the mask on \(kind)")
        expectOnlySubjectChanged(payload(e), payload(after),
                                 subject: "mask", "withMask(nil) on \(kind)")
    }
}

// MARK: - withWidthPoints

/// Only Line and Path carry width points; every other kind is returned
/// untouched, which is itself a preservation claim worth pinning.
@Test func withWidthPointsIsIdentityWhenUnchanged() {
    for (kind, e) in populated() {
        let same: [StrokeWidthPoint]
        switch e {
        case .line(let v): same = v.widthPoints
        case .path(let v): same = v.widthPoints
        default: same = []
        }
        #expect(withWidthPoints(e, widthPoints: same) == e,
                "withWidthPoints dropped a field on \(kind)")
    }
}

@Test func withWidthPointsChangesOnlyTheWidthPoints() {
    let fresh = [StrokeWidthPoint(t: 0, widthLeft: 9, widthRight: 9),
                 StrokeWidthPoint(t: 0.5, widthLeft: 1, widthRight: 1),
                 StrokeWidthPoint(t: 1, widthLeft: 9, widthRight: 9)]
    for (kind, e) in populated() {
        let after = withWidthPoints(e, widthPoints: fresh)
        switch after {
        case .line(let v):
            // Value pairing: the subject actually moved.
            #expect(v.widthPoints == fresh, "withWidthPoints did not set them on \(kind)")
        case .path(let v):
            #expect(v.widthPoints == fresh, "withWidthPoints did not set them on \(kind)")
        default:
            #expect(after == e, "withWidthPoints altered \(kind), which has no width points")
            continue
        }
        expectOnlySubjectChanged(payload(e), payload(after),
                                 subject: "widthPoints", "withWidthPoints on \(kind)")
    }
}
