import Testing
@testable import JasLib

/// EDIT_SEMANTICS_FREEZE.md **§3.1, the Theseus clause**: a 1→1 edit preserves
/// every field it does not speak to.
///
/// `Element.translated(dx:dy:)` and `Element.moveControlPoints(_:dx:dy:)` are
/// the two geometry-baking 1→1 edits in `Element.swift`. Each speaks to
/// POSITION and nothing else: `translated` is the Align panel's mover
/// (ALIGN.md §Translation semantics), `moveControlPoints` is the
/// partial-selection tool's anchor drag. Both were open-coded rebuilds that
/// restated every field by hand, and both stopped short:
///
///   * `moveControlPoints`, `.path` arm — dropped `visibility`, `blendMode`,
///     `mask`, `fillGradient`, `strokeGradient`, `strokeBrush`,
///     `strokeBrushOverrides`, `toolOrigin`, `name`, `id` (10 of 18 fields);
///     the `.textPath` arm dropped those (minus the two gradients TextPath
///     does not carry) PLUS `tspans` and all 11 character-panel fields —
///     20 of 29. Both sat in the same `switch` as five conforming siblings.
///   * `translated`, `.path` arm — dropped `strokeBrush`,
///     `strokeBrushOverrides`, `toolOrigin`; the `.text` and `.textPath` arms
///     each dropped the same 11 character-panel fields (`textTransform`,
///     `fontVariant`, `baselineShift`, `lineHeight`, `letterSpacing`,
///     `xmlLang`, `aaMode`, `rotate`, `horizontalScale`, `verticalScale`,
///     `kerning`).
///
/// Rust's twins are `PathElem { d: …, ..e.clone() }` / `TextElem { x: …,
/// ..e.clone() }` (`translate_element`, `move_control_points` in
/// `jas_dioxus/src/geometry/element.rs`) and conform, so every one of these
/// was a one-sided live divergence: nudging a brushed path with the Align
/// panel stripped its brush, and dragging an anchor of a named, masked path
/// destroyed the identity references and the ledger are keyed on.
///
/// METHOD — the same three assertions as `CopyApiTheseusTests`, none of them
/// carrying a field list:
///
///   1. **The no-op law.** A zero-delta edit must be the identity:
///      `e.translated(dx: 0, dy: 0) == e`. `Equatable` compares every stored
///      property, so any dropped field fails it. (Applied to
///      `moveControlPoints` only for the arms whose zero-delta arithmetic is
///      exact — the `.text` corner-scale arm divides and multiplies by a
///      diagonal ratio, so it is covered by the walk instead.)
///   2. **The subject law.** A NON-zero delta must change position and
///      nothing else — a `Mirror` walk over the payload struct comparing every
///      stored property outside the position set — PLUS a direct assertion on
///      where the geometry LANDED. That value pairing is mandatory
///      (banked 2026-07-26): a field-list-free walk is structurally blind to
///      whether the translation was applied at all, or applied twice.
///   3. **The anti-vacuity guard** (§3.1(i)): every non-position stored
///      property of every fixture differs from a minimally-constructed
///      element's, because a field sitting at its default is one whose loss
///      the other two assertions cannot see.
///
/// The text fixtures carry TWO tspans deliberately: the `moveControlPoints`
/// `.textPath` rebuild routed through the `content:` convenience initializer,
/// which concatenates the run structure into a single tspan. A one-tspan
/// fixture would round-trip through that collapse unchanged and see nothing.

// MARK: - The anti-vacuity guard

@Test func moveAndTranslateFixturesDifferFromDefaultInEveryField() {
    let mins = Dictionary(uniqueKeysWithValues: mvMinimal())
    for (kind, rich) in mvPopulated() {
        guard let plain = mins[kind] else {
            Issue.record("no minimal counterpart for \(kind)"); continue
        }
        let r = mvLabelled(mvPayload(rich))
        let p = mvLabelled(mvPayload(plain))
        #expect(!r.isEmpty, "\(kind): reflected zero stored properties")
        // Geometry has no default and is equal by construction; `tspans` is a
        // text element's geometry payload in the same sense.
        let geometry: Set<String> = ["x1", "y1", "x2", "y2", "x", "y", "width",
                                     "height", "cx", "cy", "r", "rx", "ry",
                                     "points", "d", "children", "tspans"]
        for (label, value) in r where !geometry.contains(label) {
            #expect(value != p[label],
                    "\(kind).\(label) is at its default in the fixture — a drop of that field would be invisible to these tests")
        }
    }
}

// MARK: - translated(dx:dy:)

/// A zero-delta translation must be the identity on every kind.
@Test func translatedIsIdentityAtZeroDelta() {
    for (kind, e) in mvPopulated() {
        #expect(e.translated(dx: 0, dy: 0) == e,
                "translated dropped a field on \(kind)")
    }
}

/// A non-zero translation must move position and touch nothing else.
@Test func translatedChangesOnlyPosition() {
    for (kind, e) in mvPopulated() {
        let after = e.translated(dx: 13, dy: -7)
        mvExpectOnlyPositionChanged(mvPayload(e), mvPayload(after),
                                    "translated on \(kind)")
    }
}

/// Value pairing: the geometry actually landed at source + delta — once, not
/// twice, and not at all is not acceptable either.
@Test func translatedMovesTheGeometryByExactlyTheDelta() {
    let dx = 13.0, dy = -7.0
    for (kind, e) in mvPopulated() {
        let after = e.translated(dx: dx, dy: dy)
        switch (e, after) {
        case (.line(let a), .line(let b)):
            #expect((b.x1, b.y1, b.x2, b.y2) == (a.x1 + dx, a.y1 + dy, a.x2 + dx, a.y2 + dy),
                    "\(kind) endpoints")
        case (.rect(let a), .rect(let b)):
            #expect((b.x, b.y, b.width, b.height) == (a.x + dx, a.y + dy, a.width, a.height),
                    "\(kind) origin")
        case (.circle(let a), .circle(let b)):
            #expect((b.cx, b.cy, b.r) == (a.cx + dx, a.cy + dy, a.r), "\(kind) centre")
        case (.ellipse(let a), .ellipse(let b)):
            #expect((b.cx, b.cy, b.rx, b.ry) == (a.cx + dx, a.cy + dy, a.rx, a.ry),
                    "\(kind) centre")
        case (.polyline(let a), .polyline(let b)):
            #expect(b.points.map { [$0.0, $0.1] } == a.points.map { [$0.0 + dx, $0.1 + dy] },
                    "\(kind) points")
        case (.polygon(let a), .polygon(let b)):
            #expect(b.points.map { [$0.0, $0.1] } == a.points.map { [$0.0 + dx, $0.1 + dy] },
                    "\(kind) points")
        case (.path(let a), .path(let b)):
            #expect(mvEndpoints(b.d).map { [$0.0, $0.1] }
                    == mvEndpoints(a.d).map { [$0.0 + dx, $0.1 + dy] }, "\(kind) d")
        case (.text(let a), .text(let b)):
            #expect((b.x, b.y, b.fontSize) == (a.x + dx, a.y + dy, a.fontSize), "\(kind) origin")
        case (.textPath(let a), .textPath(let b)):
            #expect(mvEndpoints(b.d).map { [$0.0, $0.1] }
                    == mvEndpoints(a.d).map { [$0.0 + dx, $0.1 + dy] }, "\(kind) d")
        case (.group, .group), (.layer, .layer):
            break  // containers recurse; see the child-value test below
        default:
            Issue.record("translated changed the element KIND on \(kind)")
        }
    }
}

/// Containers translate by recursing, so the value pairing is on the child.
@Test func translatedMovesContainerChildren() {
    for (kind, e) in mvPopulated() where kind == "group" || kind == "layer" {
        let after = e.translated(dx: 13, dy: -7)
        let kids: [Element]
        switch after {
        case .group(let g): kids = g.children
        case .layer(let l): kids = l.children
        default: kids = []
        }
        guard case .rect(let r) = kids.first else {
            Issue.record("\(kind): expected a rect child"); continue
        }
        #expect((r.x, r.y) == (13.0, -7.0), "\(kind) child did not move")
    }
}

// MARK: - moveControlPoints(_:dx:dy:)

/// Kinds whose whole-element (`.all`) arm keeps the element's REPRESENTATION
/// and whose zero-delta arithmetic is exact. The `.text` corner-scale arm is
/// excluded (it divides by a diagonal ratio) and covered by the walk below.
private func mvSameKindUnderAll() -> [(String, Element)] {
    mvPopulated().filter { $0.0 != "group" && $0.0 != "layer" }
}

/// A zero-delta whole-element drag must be the identity.
@Test func moveControlPointsIsIdentityAtZeroDelta() {
    for (kind, e) in mvSameKindUnderAll() {
        #expect(e.moveControlPoints(.all, dx: 0, dy: 0) == e,
                "moveControlPoints dropped a field on \(kind)")
    }
}

/// A whole-element drag must move position and touch nothing else.
@Test func moveControlPointsChangesOnlyPosition() {
    for (kind, e) in mvSameKindUnderAll() {
        let after = e.moveControlPoints(.all, dx: 13, dy: -7)
        mvExpectOnlyPositionChanged(mvPayload(e), mvPayload(after),
                                    "moveControlPoints(.all) on \(kind)")
    }
}

/// Value pairing for the two arms this wave repaired: a single-anchor drag on
/// a Path / TextPath moves exactly that anchor and preserves every other
/// field. `.partial([0])` is the real gesture — one anchor under the cursor.
@Test func moveControlPointsSingleAnchorMovesOnlyThatAnchor() {
    let dx = 13.0, dy = -7.0
    let kind = SelectionKind.partial(SortedCps([0]))
    for (name, e) in mvPopulated() where name == "path" || name == "textPath" {
        let after = e.moveControlPoints(kind, dx: dx, dy: dy)
        mvExpectOnlyPositionChanged(mvPayload(e), mvPayload(after),
                                    "moveControlPoints(.partial) on \(name)")
        let before: [PathCommand]
        let now: [PathCommand]
        switch (e, after) {
        case (.path(let a), .path(let b)): before = a.d; now = b.d
        case (.textPath(let a), .textPath(let b)): before = a.d; now = b.d
        default:
            Issue.record("moveControlPoints changed the KIND on \(name)"); continue
        }
        // Anchor 0 is the `moveTo`; it moves, and so does the following
        // curve's first control handle (the arm's documented behaviour).
        // Anchor 1's endpoint (the curve's end) must NOT move.
        #expect(now[0] == .moveTo(0 + dx, 0 + dy), "\(name): anchor 0 did not move")
        #expect(now[2] == before[2], "\(name): an unselected anchor moved")
    }
}

/// The `.text` corner-scale arm keeps every non-position, non-size field. Its
/// subject is position AND size (it scales about the opposite corner), so the
/// value pairing asserts the scale landed rather than a pure translation.
@Test func moveControlPointsTextCornerScalePreservesEverythingElse() {
    guard let (_, e) = mvPopulated().first(where: { $0.0 == "text" }) else {
        Issue.record("no text fixture"); return
    }
    let after = e.moveControlPoints(.partial(SortedCps([0])), dx: -5, dy: -5)
    guard case .text(let a) = e, case .text(let b) = after else {
        Issue.record("moveControlPoints changed the text KIND"); return
    }
    let bl = mvLabelled(b), al = mvLabelled(a)
    let subject: Set<String> = ["x", "y", "fontSize", "width", "height"]
    #expect(!bl.isEmpty, "text: reflected zero stored properties")
    for (label, value) in bl where !subject.contains(label) {
        #expect(value == al[label], "text corner scale changed \(label)")
    }
    // Value pairing: dragging the top-left corner outward grew the element.
    #expect(b.fontSize > a.fontSize, "text corner scale did not scale the font")
    #expect(b.width > a.width && b.height > a.height, "text corner scale did not scale the box")
}
