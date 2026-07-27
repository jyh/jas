import Testing
@testable import JasLib

/// EDIT_SEMANTICS_FREEZE.md §3.1, applied to the LAST open-coded same-kind
/// rebuilds in `Element.swift`.
///
/// A mechanical enumeration of the file (every element-struct initializer call
/// site, argument labels vs the memberwise init's parameters) found three
/// element-returning functions still restating every field by hand at every
/// arm — 31 arms between them — and NO battery watching any of them:
///
///   * `withTransformSet` (11 arms), behind `withTransformTranslated` and
///     `withTransformPremultiplied` — the transform-tool family;
///   * `withCommon` (11 arms) — the Properties-panel apply;
///   * `withStroke` (9 arms) — the Stroke panel and the eyedropper.
///
/// Enumerated as COMPLETE at the commit before this file: unlike the five arms
/// the position-edit wave repaired, none of these was dropping a field. They
/// were the same SHAPE — an open-coded rebuild is where omission becomes
/// expressible, and three consecutive waves have now shown that shape failing.
/// So this battery is written first and pins them where they stand; the same
/// commit then converts them to clone-then-mutate so omission stops being
/// expressible at all.
///
/// The method is `CopyApiTheseusTests`': the no-op law, a `Mirror` walk over
/// the payload for everything outside the subject, a direct value assertion
/// that the subject actually moved, and the shared anti-vacuity fixtures.

// MARK: - withStroke

private let probeStroke = Stroke(color: Color(r: 0.05, g: 0.95, b: 0.35), width: 9.25,
                                 linecap: .round, linejoin: .bevel)

/// Writing the stroke an element already carries must be the identity.
@Test func withStrokeIsIdentityWhenUnchanged() {
    for (kind, e) in mvPopulated() {
        #expect(withStroke(e, stroke: e.stroke) == e,
                "withStroke dropped a field on \(kind)")
    }
}

/// Writing a different stroke must change `stroke` and nothing else. Group and
/// Layer have no stroke and are returned untouched, which is itself a
/// preservation claim worth pinning.
@Test func withStrokeChangesOnlyTheStroke() {
    for (kind, e) in mvPopulated() {
        let after = withStroke(e, stroke: probeStroke)
        switch e {
        case .group, .layer:
            #expect(after == e, "withStroke touched \(kind), which has no stroke")
        default:
            #expect(after.stroke == probeStroke, "withStroke did not set the stroke on \(kind)")
            mvExpectOnlySubjectsChanged(mvPayload(e), mvPayload(after),
                                        subjects: ["stroke"], "withStroke on \(kind)")
        }
    }
    // Clearing is the same edit in the other direction.
    for (kind, e) in mvPopulated() {
        let after = withStroke(e, stroke: nil)
        switch e {
        case .group, .layer:
            #expect(after == e, "withStroke(nil) touched \(kind)")
        default:
            #expect(after.stroke == nil, "withStroke(nil) did not clear the stroke on \(kind)")
            mvExpectOnlySubjectsChanged(mvPayload(e), mvPayload(after),
                                        subjects: ["stroke"], "withStroke(nil) on \(kind)")
        }
    }
}

// MARK: - withTransformTranslated / withTransformPremultiplied

/// A zero translation composes the identity matrix onto the existing
/// transform, so `transform` itself is unchanged and the whole element is.
@Test func withTransformTranslatedIsIdentityAtZeroDelta() {
    for (kind, e) in mvPopulated() {
        #expect(e.withTransformTranslated(dx: 0, dy: 0) == e,
                "withTransformTranslated dropped a field on \(kind)")
    }
}

/// A non-zero translation must change `transform` and nothing else — and the
/// element's RAW coordinates must not move (that is `translated`'s job, and
/// conflating the two is what doubles an align offset; ALIGN.md §Translation
/// semantics).
@Test func withTransformTranslatedChangesOnlyTheTransform() {
    for (kind, e) in mvPopulated() {
        let after = e.withTransformTranslated(dx: 13, dy: -7)
        let base = e.transform ?? .identity
        #expect(after.transform == base.translated(13, -7),
                "withTransformTranslated did not compose the delta on \(kind)")
        mvExpectOnlySubjectsChanged(mvPayload(e), mvPayload(after),
                                    subjects: ["transform"],
                                    "withTransformTranslated on \(kind)")
    }
}

/// Pre-multiplying the identity matrix must leave the element alone.
@Test func withTransformPremultipliedIsIdentityForTheIdentityMatrix() {
    for (kind, e) in mvPopulated() {
        #expect(e.withTransformPremultiplied(.identity) == e,
                "withTransformPremultiplied dropped a field on \(kind)")
    }
}

/// Pre-multiplying a real matrix must change `transform` and nothing else.
@Test func withTransformPremultipliedChangesOnlyTheTransform() {
    let m = Transform.scale(2, 3)
    for (kind, e) in mvPopulated() {
        let after = e.withTransformPremultiplied(m)
        #expect(after.transform == m.multiply(e.transform ?? .identity),
                "withTransformPremultiplied did not compose on \(kind)")
        mvExpectOnlySubjectsChanged(mvPayload(e), mvPayload(after),
                                    subjects: ["transform"],
                                    "withTransformPremultiplied on \(kind)")
    }
}

// MARK: - withCommon

/// `withCommon()` with every argument nil keeps every field.
@Test func withCommonIsIdentityWhenNothingIsWritten() {
    for (kind, e) in mvPopulated() {
        #expect(e.withCommon() == e, "withCommon dropped a field on \(kind)")
    }
}

/// Each of the three subjects, written alone, must move exactly itself.
@Test func withCommonChangesOnlyTheFieldItWrites() {
    let t = Transform.shear(0.25, 0.5)
    for (kind, e) in mvPopulated() {
        let a = e.withCommon(transform: t)
        #expect(a.transform == t, "withCommon(transform:) did not set it on \(kind)")
        mvExpectOnlySubjectsChanged(mvPayload(e), mvPayload(a),
                                    subjects: ["transform"], "withCommon(transform:) on \(kind)")

        let b = e.withCommon(opacity: 0.13)
        #expect(b.opacity == 0.13, "withCommon(opacity:) did not set it on \(kind)")
        mvExpectOnlySubjectsChanged(mvPayload(e), mvPayload(b),
                                    subjects: ["opacity"], "withCommon(opacity:) on \(kind)")

        let c = e.withCommon(blendMode: .screen)
        #expect(c.blendMode == .screen, "withCommon(blendMode:) did not set it on \(kind)")
        mvExpectOnlySubjectsChanged(mvPayload(e), mvPayload(c),
                                    subjects: ["blendMode"], "withCommon(blendMode:) on \(kind)")
    }
}
