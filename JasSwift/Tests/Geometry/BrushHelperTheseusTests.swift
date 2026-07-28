import Testing
@testable import JasLib

/// EDIT_SEMANTICS_FREEZE.md §3.1, applied to the four same-kind `Path` rebuilds
/// that are STILL open in `Element.swift` after cb7e2a78 claimed the class
/// closed there.
///
/// A fresh mechanical pass over the file at HEAD — brace-matched declaration
/// boundaries, then every UpperCamel-identifier-followed-by-`(` treated as a
/// candidate constructor call and each site read — finds SEVEN element-struct
/// constructor sites, not the three cross-kind promotions that commit named:
///
///   cross-kind (as claimed)   `moveControlPoints` Rect→Polygon
///                             `promoteToPathForBrush` Line→Path, Polyline→Path
///   SAME-KIND, still open     `withStrokeBrush` `.path` arm
///                             `withStrokeBrush` `.line`/`.polyline` arm, which
///                               rebuilds the PROMOTION's own Path output
///                             `withStrokeBrushOverrides` `.path` arm
///                             `withStrokeBrushOverrides` `.line`/`.polyline` arm
///
/// All four list all 18 of `Path`'s stored fields today (measured by diffing the
/// parsed argument labels against the struct's stored properties), so there is
/// no live field drop — but nothing makes the compiler enumerate them when
/// `Path` gains a field, which is the whole omission class. The only battery
/// that reached them, `FillRulePreservationTests`, watches ONE field
/// (`fillRule`) out of eighteen.
///
/// This file does not repair them; it pins them where they stand, by the
/// `CopyApiTheseusTests` method: the no-op law, a `Mirror` walk over the payload
/// for everything outside the subject, a direct value assertion that the subject
/// actually moved, a MANDATORY geometry-value pairing (the `Mirror` walk cannot
/// see an edit that did nothing, or did its thing twice), and the shared
/// anti-vacuity fixtures from `TheseusFixtures.swift`.

private let probeBrush = "calligraphic/round-12pt"
private let probeOverrides = "{\"angle\":17,\"size\":3}"

/// The populated `Path` fixture, unwrapped. Everything here is a Path-only
/// claim: `strokeBrush` is a `Path` field, and no other kind carries it.
private func populatedPath() -> Path {
    for (kind, e) in mvPopulated() where kind == "path" {
        guard case .path(let p) = e else { break }
        return p
    }
    Issue.record("mvPopulated() no longer carries a populated path fixture")
    return Path(d: mvPathD, fillRule: .nonzero)
}

/// The source element's own vertex list, so the promotion arms' geometry pairing
/// is stated against the SOURCE rather than against the promotion's output.
private func sourcePoints(_ e: Element) -> [[Double]] {
    switch e {
    case .line(let v):     return [[v.x1, v.y1], [v.x2, v.y2]]
    case .polyline(let v): return v.points.map { [$0.0, $0.1] }
    default:
        Issue.record("sourcePoints called on a kind it does not model")
        return []
    }
}

// MARK: - withStrokeBrush, the `.path` arm

/// Writing the brush a path already carries must be the identity.
@Test func withStrokeBrushIsIdentityWhenUnchanged() {
    let p = populatedPath()
    #expect(p.strokeBrush != nil, "fixture carries no brush, so this is vacuous")
    #expect(withStrokeBrush(.path(p), strokeBrush: p.strokeBrush) == .path(p),
            "withStrokeBrush dropped a field on a path")
}

/// Writing a different brush must change `strokeBrush` and nothing else.
@Test func withStrokeBrushChangesOnlyTheBrushOnAPath() {
    let p = populatedPath()
    #expect(p.strokeBrush != probeBrush, "probe equals the fixture, so this is vacuous")
    guard case .path(let after) = withStrokeBrush(.path(p), strokeBrush: probeBrush) else {
        Issue.record("withStrokeBrush turned a path into something else")
        return
    }
    #expect(after.strokeBrush == probeBrush, "withStrokeBrush did not set the brush")
    mvExpectOnlySubjectsChanged(p, after, subjects: ["strokeBrush"],
                                "withStrokeBrush on a path")
    // MANDATORY value pairing: the Mirror walk above is structurally blind to
    // geometry that was rebuilt into an equal-DESCRIPTION but different value,
    // and to an edit that never happened.
    #expect(mvEndpoints(after.d).map { [$0.0, $0.1] }
                == mvEndpoints(p.d).map { [$0.0, $0.1] },
            "withStrokeBrush moved the geometry")
    #expect(after.d.count == p.d.count, "withStrokeBrush changed the command count")
}

/// Clearing the brush is the same edit in the other direction, and it must NOT
/// promote (BRUSHES.md §Stroke styling interaction: clearing is not an
/// application).
@Test func withStrokeBrushClearedChangesOnlyTheBrushOnAPath() {
    let p = populatedPath()
    guard case .path(let after) = withStrokeBrush(.path(p), strokeBrush: nil) else {
        Issue.record("withStrokeBrush(nil) turned a path into something else")
        return
    }
    #expect(after.strokeBrush == nil, "withStrokeBrush(nil) did not clear the brush")
    mvExpectOnlySubjectsChanged(p, after, subjects: ["strokeBrush"],
                                "withStrokeBrush(nil) on a path")
    #expect(mvEndpoints(after.d).map { [$0.0, $0.1] }
                == mvEndpoints(p.d).map { [$0.0, $0.1] },
            "withStrokeBrush(nil) moved the geometry")
}

// MARK: - withStrokeBrushOverrides, the `.path` arm

@Test func withStrokeBrushOverridesIsIdentityWhenUnchanged() {
    let p = populatedPath()
    #expect(p.strokeBrushOverrides != nil, "fixture carries no overrides — vacuous")
    #expect(withStrokeBrushOverrides(.path(p), overrides: p.strokeBrushOverrides)
                == .path(p),
            "withStrokeBrushOverrides dropped a field on a path")
}

@Test func withStrokeBrushOverridesChangesOnlyTheOverridesOnAPath() {
    let p = populatedPath()
    #expect(p.strokeBrushOverrides != probeOverrides, "probe equals the fixture — vacuous")
    guard case .path(let after) =
            withStrokeBrushOverrides(.path(p), overrides: probeOverrides) else {
        Issue.record("withStrokeBrushOverrides turned a path into something else")
        return
    }
    #expect(after.strokeBrushOverrides == probeOverrides,
            "withStrokeBrushOverrides did not set the overrides")
    mvExpectOnlySubjectsChanged(p, after, subjects: ["strokeBrushOverrides"],
                                "withStrokeBrushOverrides on a path")
    #expect(mvEndpoints(after.d).map { [$0.0, $0.1] }
                == mvEndpoints(p.d).map { [$0.0, $0.1] },
            "withStrokeBrushOverrides moved the geometry")
}

@Test func withStrokeBrushOverridesClearedChangesOnlyTheOverridesOnAPath() {
    let p = populatedPath()
    guard case .path(let after) =
            withStrokeBrushOverrides(.path(p), overrides: nil) else {
        Issue.record("withStrokeBrushOverrides(nil) turned a path into something else")
        return
    }
    #expect(after.strokeBrushOverrides == nil,
            "withStrokeBrushOverrides(nil) did not clear the overrides")
    mvExpectOnlySubjectsChanged(p, after, subjects: ["strokeBrushOverrides"],
                                "withStrokeBrushOverrides(nil) on a path")
}

// MARK: - the promotion arms

/// SITE: `withStrokeBrush`'s `.line`/`.polyline` arm, which takes the Path that
/// `promoteToPathForBrush` just produced and rebuilds it field-by-field only to
/// set one field.
///
/// Pinned against the promotion's OWN output rather than against a restated
/// field list, so this battery cannot drift out of step with the promotion: the
/// two must agree on all 18 fields but `strokeBrush`.
@Test func withStrokeBrushOnLineAndPolylineRebuildsThePromotionFaithfully() {
    for (kind, e) in mvPopulated() where kind == "line" || kind == "polyline" {
        guard case .path(let promoted) = promoteToPathForBrush(e) else {
            Issue.record("\(kind) did not promote")
            continue
        }
        guard case .path(let after) = withStrokeBrush(e, strokeBrush: probeBrush) else {
            Issue.record("withStrokeBrush did not promote \(kind) to a path")
            continue
        }
        #expect(after.strokeBrush == probeBrush,
                "withStrokeBrush did not set the brush promoting \(kind)")
        mvExpectOnlySubjectsChanged(promoted, after, subjects: ["strokeBrush"],
                                    "withStrokeBrush promoting \(kind)")
        // Geometry pairing against the SOURCE, not the promotion, so a promotion
        // that lost the geometry cannot make this pass by agreeing with itself.
        #expect(!after.d.isEmpty, "promoted \(kind) has no geometry")
        #expect(mvEndpoints(after.d).map { [$0.0, $0.1] } == sourcePoints(e),
                """
                withStrokeBrush moved \(kind)'s geometry promoting it: \
                \(mvEndpoints(after.d)) vs \(sourcePoints(e))
                """)
    }
}

/// SITE: `withStrokeBrushOverrides`'s `.line`/`.polyline` arm — same claim.
@Test func withStrokeBrushOverridesOnLineAndPolylineRebuildsThePromotionFaithfully() {
    for (kind, e) in mvPopulated() where kind == "line" || kind == "polyline" {
        guard case .path(let promoted) = promoteToPathForBrush(e) else {
            Issue.record("\(kind) did not promote")
            continue
        }
        guard case .path(let after) =
                withStrokeBrushOverrides(e, overrides: probeOverrides) else {
            Issue.record("withStrokeBrushOverrides did not promote \(kind)")
            continue
        }
        #expect(after.strokeBrushOverrides == probeOverrides,
                "withStrokeBrushOverrides did not set the overrides promoting \(kind)")
        mvExpectOnlySubjectsChanged(promoted, after, subjects: ["strokeBrushOverrides"],
                                    "withStrokeBrushOverrides promoting \(kind)")
        #expect(!after.d.isEmpty, "promoted \(kind) has no geometry")
        #expect(mvEndpoints(after.d).map { [$0.0, $0.1] } == sourcePoints(e),
                """
                withStrokeBrushOverrides moved \(kind)'s geometry promoting it: \
                \(mvEndpoints(after.d)) vs \(sourcePoints(e))
                """)
    }
}

/// Clearing never promotes, in either helper — the T4 bystander clause read
/// through BRUSHES.md: a Line that is not having a brush APPLIED must come back
/// a Line, untouched.
@Test func clearingNeverPromotesALineOrPolyline() {
    for (kind, e) in mvPopulated() where kind == "line" || kind == "polyline" {
        #expect(withStrokeBrush(e, strokeBrush: nil) == e,
                "withStrokeBrush(nil) touched \(kind)")
        #expect(withStrokeBrushOverrides(e, overrides: nil) == e,
                "withStrokeBrushOverrides(nil) touched \(kind)")
    }
}
