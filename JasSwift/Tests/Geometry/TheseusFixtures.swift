import Testing
@testable import JasLib

/// Shared fixtures for the Element.swift Theseus batteries
/// (EDIT_SEMANTICS_FREEZE.md §3.1). One attribute-rich element per kind, one
/// minimal counterpart per kind, and the `Mirror` helpers the batteries walk
/// them with. Kept in one place so a new copy-site battery cannot quietly
/// pin a THINNER fixture than the one the anti-vacuity guard measures — the
/// failure mode the guard exists to catch, reintroduced one file over.

// MARK: - Fixtures

func mvProbe(_ tag: Double) -> Mask {
    Mask(subtreeElement: .rect(Rect(x: tag, y: tag, width: 3, height: 4)),
         clip: false, invert: true, disabled: true, linked: false,
         unlinkTransform: Transform.translate(tag, tag))
}

func mvGrad(_ angle: Double) -> Gradient {
    Gradient(type: .radial, angle: angle, aspectRatio: 200, method: .smooth,
             dither: true, strokeSubMode: .within,
             stops: [GradientStop(color: "#00ff00", opacity: 100, location: 0, midpointToNext: 50),
                     GradientStop(color: "#0000ff", opacity: 100, location: 100, midpointToNext: 50)])
}

let mvFill = Fill(color: Color(r: 0.2, g: 0.4, b: 0.6))
let mvStroke = Stroke(color: Color(r: 0.9, g: 0.1, b: 0.1), width: 3.5)
let mvWidthPoints = [StrokeWidthPoint(t: 0, widthLeft: 0.5, widthRight: 2.5),
                             StrokeWidthPoint(t: 1, widthLeft: 2.5, widthRight: 0.5)]
/// TWO runs — see the header note on why one would be blind.
let mvTspans = [Tspan(id: 0, content: "Hel"), Tspan(id: 1, content: "lo")]

/// A path whose commands exercise every branch of the anchor walk.
let mvPathD: [PathCommand] = [
    .moveTo(0, 0),
    .curveTo(x1: 1, y1: 2, x2: 3, y2: 4, x: 5, y: 6),
    .lineTo(10, 12),
]

/// Every stored property set away from its default, for each kind these two
/// edits rebuild by hand.
func mvPopulated() -> [(String, Element)] {
    [
        ("line", .line(Line(x1: 1, y1: 2, x2: 3, y2: 4,
                            stroke: mvStroke, widthPoints: mvWidthPoints,
                            opacity: 0.42, transform: Transform.translate(7, 11),
                            locked: true, visibility: .outline, blendMode: .multiply,
                            mask: mvProbe(1), strokeGradient: mvGrad(60),
                            name: "my-line", id: "line-1"))),
        ("rect", .rect(Rect(x: 1, y: 2, width: 3, height: 4, rx: 5, ry: 6,
                            fill: mvFill, stroke: mvStroke,
                            opacity: 0.42, transform: Transform.translate(7, 11),
                            locked: true, visibility: .outline, blendMode: .multiply,
                            mask: mvProbe(2), fillGradient: mvGrad(30),
                            strokeGradient: mvGrad(60),
                            name: "my-rect", id: "rect-1"))),
        ("circle", .circle(Circle(cx: 1, cy: 2, r: 3,
                                  fill: mvFill, stroke: mvStroke,
                                  opacity: 0.42, transform: Transform.translate(7, 11),
                                  locked: true, visibility: .outline, blendMode: .multiply,
                                  mask: mvProbe(3), fillGradient: mvGrad(30),
                                  strokeGradient: mvGrad(60),
                                  name: "my-circle", id: "circle-1"))),
        ("ellipse", .ellipse(Ellipse(cx: 1, cy: 2, rx: 3, ry: 4,
                                     fill: mvFill, stroke: mvStroke,
                                     opacity: 0.42, transform: Transform.translate(7, 11),
                                     locked: true, visibility: .outline, blendMode: .multiply,
                                     mask: mvProbe(4), fillGradient: mvGrad(30),
                                     strokeGradient: mvGrad(60),
                                     name: "my-ellipse", id: "ellipse-1"))),
        ("polyline", .polyline(Polyline(points: [(0, 0), (10, 10)],
                                        fill: mvFill, stroke: mvStroke,
                                        opacity: 0.42, transform: Transform.translate(7, 11),
                                        locked: true, visibility: .outline, blendMode: .multiply,
                                        mask: mvProbe(5), fillGradient: mvGrad(30),
                                        strokeGradient: mvGrad(60),
                                        name: "my-polyline", id: "polyline-1"))),
        ("polygon", .polygon(Polygon(points: [(0, 0), (10, 0), (10, 10)],
                                     fill: mvFill, stroke: mvStroke,
                                     opacity: 0.42, transform: Transform.translate(7, 11),
                                     locked: true, visibility: .outline, blendMode: .multiply,
                                     mask: mvProbe(6), fillGradient: mvGrad(30),
                                     strokeGradient: mvGrad(60),
                                     name: "my-polygon", id: "polygon-1"))),
        ("path", .path(Path(d: mvPathD,
                            fill: mvFill, stroke: mvStroke,
                            widthPoints: mvWidthPoints,
                            opacity: 0.42, transform: Transform.translate(7, 11),
                            locked: true, visibility: .outline, blendMode: .multiply,
                            mask: mvProbe(7), fillGradient: mvGrad(30),
                            strokeGradient: mvGrad(60),
                            strokeBrush: "calligraphic/flat-6pt",
                            strokeBrushOverrides: "{\"angle\":45}",
                            toolOrigin: "blob_brush",
                            name: "my-path", id: "path-1", fillRule: .evenodd))),
        ("text", .text(Text(x: 1, y: 2, tspans: mvTspans,
                            fontFamily: "Georgia", fontSize: 22,
                            fontWeight: "bold", fontStyle: "italic",
                            textDecoration: "underline",
                            textTransform: "uppercase", fontVariant: "small-caps",
                            baselineShift: "super", lineHeight: "1.5",
                            letterSpacing: "3", xmlLang: "fr",
                            aaMode: "crisp", rotate: "5",
                            horizontalScale: "120", verticalScale: "80",
                            kerning: "3", width: 40, height: 20,
                            fill: mvFill, stroke: mvStroke,
                            opacity: 0.42, transform: Transform.translate(7, 11),
                            locked: true, visibility: .outline, blendMode: .multiply,
                            mask: mvProbe(10), name: "my-text", id: "text-1"))),
        ("textPath", .textPath(TextPath(d: mvPathD,
                            tspans: mvTspans, startOffset: 12,
                            fontFamily: "Georgia", fontSize: 22,
                            fontWeight: "bold", fontStyle: "italic",
                            textDecoration: "underline",
                            textTransform: "uppercase", fontVariant: "small-caps",
                            baselineShift: "super", lineHeight: "1.5",
                            letterSpacing: "3", xmlLang: "fr",
                            aaMode: "crisp", rotate: "5",
                            horizontalScale: "120", verticalScale: "80",
                            kerning: "3",
                            fill: mvFill, stroke: mvStroke,
                            opacity: 0.42, transform: Transform.translate(7, 11),
                            locked: true, visibility: .outline, blendMode: .multiply,
                            mask: mvProbe(11), name: "my-textpath", id: "textpath-1"))),
        ("group", .group(Group(children: [.rect(Rect(x: 0, y: 0, width: 1, height: 1))],
                               opacity: 0.42, transform: Transform.translate(7, 11),
                               locked: true, visibility: .outline, blendMode: .multiply,
                               isolatedBlending: true, knockoutGroup: true,
                               mask: mvProbe(8), name: "my-group", id: "group-1"))),
        ("layer", .layer(Layer(name: "my-layer",
                               children: [.rect(Rect(x: 0, y: 0, width: 1, height: 1))],
                               opacity: 0.42, transform: Transform.translate(7, 11),
                               locked: true, visibility: .outline, blendMode: .multiply,
                               isolatedBlending: true, knockoutGroup: true,
                               mask: mvProbe(9), id: "layer-1"))),
    ]
}

/// The same kinds with nothing but their geometry — the defaults the
/// anti-vacuity guard measures the fixtures against.
func mvMinimal() -> [(String, Element)] {
    [
        ("line", .line(Line(x1: 1, y1: 2, x2: 3, y2: 4))),
        ("rect", .rect(Rect(x: 1, y: 2, width: 3, height: 4))),
        ("circle", .circle(Circle(cx: 1, cy: 2, r: 3))),
        ("ellipse", .ellipse(Ellipse(cx: 1, cy: 2, rx: 3, ry: 4))),
        ("polyline", .polyline(Polyline(points: [(0, 0), (10, 10)]))),
        ("polygon", .polygon(Polygon(points: [(0, 0), (10, 0), (10, 10)]))),
        ("path", .path(Path(d: mvPathD, fillRule: .nonzero))),
        ("text", .text(Text(x: 1, y: 2, tspans: mvTspans))),
        ("textPath", .textPath(TextPath(d: mvPathD, tspans: mvTspans))),
        ("group", .group(Group(children: [.rect(Rect(x: 0, y: 0, width: 1, height: 1))]))),
        ("layer", .layer(Layer(children: [.rect(Rect(x: 0, y: 0, width: 1, height: 1))]))),
    ]
}

// MARK: - Reflection helpers

func mvPayload(_ e: Element) -> Any {
    guard let v = Mirror(reflecting: e).children.first?.value else {
        Issue.record("Element case has no associated value")
        return e
    }
    return v
}

func mvLabelled(_ v: Any) -> [String: String] {
    Dictionary(uniqueKeysWithValues:
        Mirror(reflecting: v).children.compactMap { c -> (String, String)? in
            guard let l = c.label else { return nil }
            return (l, String(describing: c.value))
        })
}

/// The fields a POSITION edit is allowed to move. Everything else in the
/// payload is a bystander under §3.1. Deliberately excludes `width`,
/// `height`, `r`, `rx`, `ry` and `fontSize` — a translation must not resize.
let mvPositionFields: Set<String> = [
    "x", "y", "x1", "y1", "x2", "y2", "cx", "cy", "points", "d", "children",
]

/// Compare every stored property of two payloads except `subjects` — the
/// field-list-free half of the Theseus method. Always pair a call with a
/// direct assertion on the subject's VALUE: this walk cannot see an edit that
/// did nothing, or did its thing twice.
func mvExpectOnlySubjectsChanged(_ before: Any, _ after: Any,
                                 subjects: Set<String>, _ what: String) {
    let b = mvLabelled(before)
    let a = mvLabelled(after)
    #expect(!a.isEmpty, "\(what): reflected zero stored properties")
    #expect(a.keys.sorted() == b.keys.sorted(), "\(what): field sets differ")
    for (label, value) in a where !subjects.contains(label) {
        #expect(value == b[label], "\(what) changed \(label)")
    }
}

func mvExpectOnlyPositionChanged(_ before: Any, _ after: Any, _ what: String) {
    mvExpectOnlySubjectsChanged(before, after, subjects: mvPositionFields, what)
}

/// Endpoints of every command that has one, in order — the value pairing for
/// the two path-shaped kinds.
func mvEndpoints(_ d: [PathCommand]) -> [(Double, Double)] {
    d.compactMap { $0.endpoint }
}

