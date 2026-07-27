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
/// The kinds covered are the eleven struct kinds — the nine `withMask` rebuilds
/// plus `.text` / `.textPath`, added when `withFill` and the two `withTspans`
/// helpers joined this battery. `.live` delegates to `LiveVariant.withMask`,
/// which is already clone-then-mutate.
///
/// Both text fixtures deliberately carry TWO tspans, because the open-coded
/// rebuilds route through the `content:` convenience initializer, which
/// concatenates the run structure into a single tspan. A one-tspan fixture
/// would round-trip through that collapse unchanged and see nothing.

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
/// TWO runs — see the header note on why one would be blind.
private let richTspans = [Tspan(id: 0, content: "Hel"),
                          Tspan(id: 1, content: "lo")]

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
        ("text", .text(Text(x: 1, y: 2, tspans: richTspans,
                            fontFamily: "Georgia", fontSize: 22,
                            fontWeight: "bold", fontStyle: "italic",
                            textDecoration: "underline",
                            textTransform: "uppercase", fontVariant: "small-caps",
                            baselineShift: "super", lineHeight: "1.5",
                            letterSpacing: "2", xmlLang: "fr",
                            aaMode: "crisp", rotate: "5",
                            horizontalScale: "120", verticalScale: "80",
                            kerning: "3", width: 40, height: 20,
                            fill: richFill, stroke: richStroke,
                            opacity: 0.42, transform: Transform.translate(7, 11),
                            locked: true, visibility: .outline, blendMode: .multiply,
                            mask: probe(10), name: "my-text", id: "text-1"))),
        ("textPath", .textPath(TextPath(d: [.moveTo(0, 0), .lineTo(10, 10)],
                            tspans: richTspans, startOffset: 12,
                            fontFamily: "Georgia", fontSize: 22,
                            fontWeight: "bold", fontStyle: "italic",
                            textDecoration: "underline",
                            textTransform: "uppercase", fontVariant: "small-caps",
                            baselineShift: "super", lineHeight: "1.5",
                            letterSpacing: "2", xmlLang: "fr",
                            aaMode: "crisp", rotate: "5",
                            horizontalScale: "120", verticalScale: "80",
                            kerning: "3",
                            fill: richFill, stroke: richStroke,
                            opacity: 0.42, transform: Transform.translate(7, 11),
                            locked: true, visibility: .outline, blendMode: .multiply,
                            mask: probe(11), name: "my-textpath", id: "textpath-1"))),
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
        ("text", .text(Text(x: 1, y: 2, tspans: richTspans))),
        ("textPath", .textPath(TextPath(d: [.moveTo(0, 0), .lineTo(10, 10)],
                                        tspans: richTspans))),
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
        // `tspans` is a text element's payload, the counterpart of `d` /
        // `points` — equal by construction, and it is the SUBJECT of the
        // withTspans battery, which asserts on it directly.
        let geometry: Set<String> = ["x1", "y1", "x2", "y2", "x", "y", "width",
                                     "height", "cx", "cy", "r", "rx", "ry",
                                     "points", "d", "children", "tspans"]
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

// MARK: - withVisibility / withLocked
//
// The same clause and the same method, on the two Element-level helpers whose
// subject is a single non-paint flag. `withVisibility` is the layers-panel eye
// and `hide_selection`; `withLocked` is Object > Lock and `lockSelection`. Both
// were open-coded rebuilds in the same omission class — hiding a named group
// destroyed its id and name — and the corpus fixture
// `operations/bystander_containers.json` catches the `withVisibility` half
// across both ports. These are its per-port inner loop, and the ONLY thing
// watching `withLocked`.

@Test func withVisibilityIsIdentityWhenUnchanged() {
    for (kind, e) in populated() {
        #expect(e.withVisibility(e.visibility) == e,
                "withVisibility dropped a field on \(kind)")
    }
}

@Test func withVisibilityChangesOnlyTheVisibility() {
    for (kind, e) in populated() {
        let after = e.withVisibility(.invisible)
        #expect(after.visibility == .invisible,
                "withVisibility did not set the visibility on \(kind)")
        expectOnlySubjectChanged(payload(e), payload(after),
                                 subject: "visibility", "withVisibility on \(kind)")
    }
}

@Test func withLockedIsIdentityWhenUnchanged() {
    for (kind, e) in populated() {
        #expect(e.withLocked(e.isLocked) == e,
                "withLocked dropped a field on \(kind)")
    }
}

@Test func withLockedChangesOnlyTheLockedFlag() {
    for (kind, e) in populated() {
        let after = e.withLocked(false)   // every fixture is locked: true
        #expect(after.isLocked == false,
                "withLocked did not clear the locked flag on \(kind)")
        expectOnlySubjectChanged(payload(e), payload(after),
                                 subject: "locked", "withLocked on \(kind)")
    }
}

// MARK: - withFill
//
// The Color panel's write path (`Controller.setSelectionFill` →
// `fillApplied` → `withFill`), and the widest omission in the class: the
// open-coded rebuild it replaced stopped at `visibility:`, so setting a fill
// colour on a named, cited, masked, brush-stroked path destroyed its `name`,
// `id`, `mask`, `blendMode`, `strokeGradient`, `strokeBrush`,
// `strokeBrushOverrides` and `toolOrigin` — and on a Text it collapsed every
// tspan run into one. Rust's `with_fill` is `RectElem { fill, ..e.clone() }`
// and always conformed.
//
// SUBJECT. `withFill` speaks to `fill` AND to `fillGradient`, which shadows it
// on the render chain (`apply_fill` returns early on the gradient branch):
// EDIT_SEMANTICS_FREEZE.md T1's SHADOWING-FAMILY closure says an edit that
// writes one member of a shadowing family speaks to the whole family, so the
// gradient goes to the fresh default rather than being carried. That is what
// this port does and has always done, and it is what these tests pin.
//
// NAMED CROSS-PORT DELTA, not repaired here: Rust's `..e.clone()` CARRIES
// `fill_gradient`, so a colour pick on a gradient-filled element leaves the
// gradient shadowing the new colour there and clears it here. Which port is
// right is the §3.6 gradients-as-paint AMENDMENT — a ruling that must land in
// both ports at once — so this battery deliberately preserves Swift's current
// answer rather than silently legislating either way.

@Test func withFillIsIdentityWhenUnchanged() {
    for (kind, e) in populated() {
        switch e {
        case .line, .group, .layer:
            // No fill slot: returned unchanged, itself a preservation claim.
            #expect(withFill(e, fill: e.fill) == e, "withFill altered \(kind)")
        default:
            // `fillGradient` is spoken to (shadowing family), so the identity
            // law here is "everything BUT the fill family survives".
            let after = withFill(e, fill: e.fill)
            #expect(after.fillGradient == nil,
                    "withFill must clear the shadowing gradient on \(kind)")
            #expect(withFillGradient(after, fillGradient: e.fillGradient) == e,
                    "withFill dropped a field outside the fill family on \(kind)")
        }
    }
}

@Test func withFillChangesOnlyTheFillFamily() {
    let fresh = Fill(color: Color(r: 0.05, g: 0.95, b: 0.15))
    for (kind, e) in populated() {
        let after = withFill(e, fill: fresh)
        switch e {
        case .line, .group, .layer:
            #expect(after == e, "withFill altered \(kind), which has no fill")
            continue
        default:
            break
        }
        // Value pairing: the subject actually moved.
        #expect(after.fill == fresh, "withFill did not set the fill on \(kind)")
        #expect(after.fillGradient == nil,
                "withFill must clear the shadowing gradient on \(kind)")
        // Compare everything else by restoring the two fill-family fields.
        let restored = withFillGradient(withFill(after, fill: e.fill),
                                        fillGradient: e.fillGradient)
        #expect(restored == e, "withFill changed a field outside the fill family on \(kind)")
    }
}

// MARK: - Text.withTspans / TextPath.withTspans / with(content:)
//
// `TextEditSession.applyToDocument`'s write path. Same clause, same class:
// each was an open-coded rebuild that stopped at `locked:`, dropping
// `visibility`, `blendMode`, `mask`, `name` and `id` — so committing a text
// edit destroyed the element's identity. `withTspans`' own doc comment claimed
// "Preserves every other field", which it did not; Rust's twin is
// `t.clone()` + `new_t.tspans = ...` (tools/text_edit.rs) and conforms.

@Test func textWithTspansIsIdentityWhenUnchanged() {
    guard case .text(let t) = populated().first(where: { $0.0 == "text" })!.1,
          case .textPath(let tp) = populated().first(where: { $0.0 == "textPath" })!.1
    else { Issue.record("missing text fixtures"); return }
    #expect(t.withTspans(t.tspans) == t, "Text.withTspans dropped a field")
    #expect(tp.withTspans(tp.tspans) == tp, "TextPath.withTspans dropped a field")
}

@Test func textWithTspansChangesOnlyTheTspans() {
    let fresh = [Tspan(id: 7, content: "new")]
    guard case .text(let t) = populated().first(where: { $0.0 == "text" })!.1,
          case .textPath(let tp) = populated().first(where: { $0.0 == "textPath" })!.1
    else { Issue.record("missing text fixtures"); return }
    let a = t.withTspans(fresh)
    #expect(a.tspans == fresh, "Text.withTspans did not set the tspans")
    expectOnlySubjectChanged(t, a, subject: "tspans", "Text.withTspans")
    let b = tp.withTspans(fresh)
    #expect(b.tspans == fresh, "TextPath.withTspans did not set the tspans")
    expectOnlySubjectChanged(tp, b, subject: "tspans", "TextPath.withTspans")
}

/// `with(content:)` is `withTspans` over a single freshly-built run; it is in
/// the same class and was open-coded the same way.
@Test func textWithContentChangesOnlyTheTspans() {
    guard case .text(let t) = populated().first(where: { $0.0 == "text" })!.1,
          case .textPath(let tp) = populated().first(where: { $0.0 == "textPath" })!.1
    else { Issue.record("missing text fixtures"); return }
    let a = t.with(content: "brand new")
    #expect(a.content == "brand new", "Text.with(content:) did not set the content")
    expectOnlySubjectChanged(t, a, subject: "tspans", "Text.with(content:)")
    let b = tp.with(content: "brand new")
    #expect(b.content == "brand new", "TextPath.with(content:) did not set the content")
    expectOnlySubjectChanged(tp, b, subject: "tspans", "TextPath.with(content:)")
}

// MARK: - withFillGradient / withStrokeGradient
//
// The same clause and the same method, on the two Element-level helpers the
// Gradient panel writes through (`Controller.setSelectionFillGradient` /
// `setSelectionStrokeGradient`). Both were open-coded rebuilds: NO arm of
// either passed `name:` or `id:`, and the `.path` arm of each also omitted
// `toolOrigin:`, `strokeBrush:` and `strokeBrushOverrides:`. Setting a fill
// gradient on a named, cited, brush-stroked path therefore destroyed its
// identity, its brush and its blob-brush tool origin on a 1→1 edit.
//
// Rust's twins are `RectElem { fill_gradient: gradient, ..e.clone() }` at
// every arm and conform, so each of these was a one-sided live divergence in
// the same class as `withMask` / `withWidthPoints`.
//
// The kinds each helper actually rewrites differ, and the "returned
// unchanged" arms are themselves a preservation claim: `withFillGradient`
// rewrites six kinds (Line has no fill gradient), `withStrokeGradient`
// rewrites seven.

/// Writing the fill gradient an element already carries must be the identity.
@Test func withFillGradientIsIdentityWhenUnchanged() {
    for (kind, e) in populated() {
        #expect(withFillGradient(e, fillGradient: e.fillGradient) == e,
                "withFillGradient dropped a field on \(kind)")
    }
}

/// Writing a different fill gradient must change `fillGradient` and nothing
/// else — including on the kinds that have none, which must come back whole.
@Test func withFillGradientChangesOnlyTheFillGradient() {
    let fresh = grad(123)
    for (kind, e) in populated() {
        let after = withFillGradient(e, fillGradient: fresh)
        switch after {
        case .rect, .circle, .ellipse, .polyline, .polygon, .path:
            // Value pairing: the subject actually moved.
            #expect(after.fillGradient == fresh,
                    "withFillGradient did not set the gradient on \(kind)")
            expectOnlySubjectChanged(payload(e), payload(after),
                                     subject: "fillGradient",
                                     "withFillGradient on \(kind)")
        default:
            #expect(after == e,
                    "withFillGradient altered \(kind), which has no fill gradient")
        }
    }
    // Clearing a gradient is the same edit in the other direction.
    for (kind, e) in populated() {
        let after = withFillGradient(e, fillGradient: nil)
        switch after {
        case .rect, .circle, .ellipse, .polyline, .polygon, .path:
            #expect(after.fillGradient == nil,
                    "withFillGradient(nil) did not clear the gradient on \(kind)")
            expectOnlySubjectChanged(payload(e), payload(after),
                                     subject: "fillGradient",
                                     "withFillGradient(nil) on \(kind)")
        default:
            #expect(after == e,
                    "withFillGradient(nil) altered \(kind), which has no fill gradient")
        }
    }
}

/// Writing the stroke gradient an element already carries must be the identity.
@Test func withStrokeGradientIsIdentityWhenUnchanged() {
    for (kind, e) in populated() {
        #expect(withStrokeGradient(e, strokeGradient: e.strokeGradient) == e,
                "withStrokeGradient dropped a field on \(kind)")
    }
}

/// Writing a different stroke gradient must change `strokeGradient` and
/// nothing else.
@Test func withStrokeGradientChangesOnlyTheStrokeGradient() {
    let fresh = grad(123)
    for (kind, e) in populated() {
        let after = withStrokeGradient(e, strokeGradient: fresh)
        switch after {
        case .line, .rect, .circle, .ellipse, .polyline, .polygon, .path:
            #expect(after.strokeGradient == fresh,
                    "withStrokeGradient did not set the gradient on \(kind)")
            expectOnlySubjectChanged(payload(e), payload(after),
                                     subject: "strokeGradient",
                                     "withStrokeGradient on \(kind)")
        default:
            #expect(after == e,
                    "withStrokeGradient altered \(kind), which has no stroke gradient")
        }
    }
    for (kind, e) in populated() {
        let after = withStrokeGradient(e, strokeGradient: nil)
        switch after {
        case .line, .rect, .circle, .ellipse, .polyline, .polygon, .path:
            #expect(after.strokeGradient == nil,
                    "withStrokeGradient(nil) did not clear the gradient on \(kind)")
            expectOnlySubjectChanged(payload(e), payload(after),
                                     subject: "strokeGradient",
                                     "withStrokeGradient(nil) on \(kind)")
        default:
            #expect(after == e,
                    "withStrokeGradient(nil) altered \(kind), which has no stroke gradient")
        }
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
