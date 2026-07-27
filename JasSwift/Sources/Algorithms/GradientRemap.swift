import Foundation

/// Re-express a LINEAR gradient's stop locations on a sub-region of the element
/// it was authored on. Geometry-only: no document, no element.
///
/// Port of `jas_dioxus/src/algorithms/gradient_remap.rs`. Keep in lockstep; the
/// cross-language corpus (`test_fixtures/algorithms/gradient_remap.json`) gates
/// the pair.
///
/// # Why this exists
///
/// A gradient in this model carries **no position**. A linear gradient is an
/// `angle` plus a list of stops, and the painter resolves it against the
/// element's OWN bounding box: the ramp runs from `centre - halfDiag * u` to
/// `centre + halfDiag * u`, where `u = (cos t, -sin t)` and `halfDiag` is half
/// the bbox diagonal.
///
/// So when an element is SPLIT — a severing path erase, whose fragments each
/// inherit the parent's gradient verbatim — every fragment re-fits the whole
/// ramp to its own smaller box. Three fragments of a red-to-blue hull each run
/// the full red-to-blue instead of each showing its slice.
///
/// # What it does NOT do
///
/// - **RADIAL is not remapped.** A radial gradient's centre is forced to the
///   bbox centre and the model has nowhere to record an anchor, so a fragment
///   necessarily re-centres. JYH accepted the recentre (2026-07-26); a
///   "gradient anchor" field is banked as a separate stone. Callers must not
///   route radial through here.
/// - **FREEFORM is not remapped.** Freeform gradients carry nodes, not stops,
///   and the painter builds no brush for them.
/// - **`midpointToNext` is carried through unchanged.** It is the one field
///   this remap does not correct, and it is not a visible error today because
///   the painter never reads it: it builds its colour stops from `location`,
///   `color` and `opacity` only.

/// A bounding box as `(x, y, w, h)`.
public typealias GradientBBox = (Double, Double, Double, Double)

/// Scalar position of a bbox centre along the gradient direction, and half the
/// bbox diagonal — the two numbers that place a linear ramp.
///
/// `u = (cos t, -sin t)` matches the painter exactly, y-down negation included.
private func gradientAxisFrame(_ bbox: GradientBBox,
                               _ angleDeg: Double) -> (Double, Double) {
    let (bx, by, bw, bh) = bbox
    let rad = angleDeg * Double.pi / 180.0
    let ux = cos(rad)
    let uy = -sin(rad)
    let cx = bx + bw / 2.0
    let cy = by + bh / 2.0
    let halfDiag = (bw * bw + bh * bh).squareRoot() / 2.0
    return (cx * ux + cy * uy, halfDiag)
}

/// Linear blend of two stops' colour and opacity at fraction `t` from `a` to
/// `b`, channel-wise in sRGB — the space the ramp is interpolated in
/// downstream. A stop's colour is stored as a hex string, so the result
/// re-quantises to 8 bits per channel; Rust's twin rounds identically
/// (`round`, half away from zero) and the corpus compares the hex exactly.
private func gradientBlend(_ a: GradientStop, _ b: GradientStop,
                           _ t: Double) -> (String, Double) {
    let ca = Color.fromHex(a.color) ?? Color.black
    let cb = Color.fromHex(b.color) ?? Color.black
    let (ar, ag, ab, aa) = ca.toRgba()
    let (br, bg, bb, ba) = cb.toRgba()
    func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
    let blended = Color(r: mix(ar, br), g: mix(ag, bg),
                        b: mix(ab, bb), a: mix(aa, ba))
    return (blended.toHex(), mix(a.opacity, b.opacity))
}

/// Colour and opacity of the ramp at remapped location `at`, given stops whose
/// `location`s are the REMAPPED ones (already possibly outside `[0, 100]`) in
/// non-decreasing order. Before the first stop and after the last, a linear
/// gradient paints the end colour flat, which is what the clamped arms return.
private func gradientSample(_ remapped: [GradientStop],
                            _ at: Double) -> (String, Double) {
    let first = remapped[0]
    let last = remapped[remapped.count - 1]
    if at <= first.location { return (first.color, first.opacity) }
    if at >= last.location { return (last.color, last.opacity) }
    for i in 0..<(remapped.count - 1) {
        let a = remapped[i], b = remapped[i + 1]
        if at >= a.location && at <= b.location {
            let span = b.location - a.location
            // Coincident stops are a hard colour break; take the later one,
            // which is what a zero-width segment means.
            if span <= 0.0 { return (b.color, b.opacity) }
            return gradientBlend(a, b, (at - a.location) / span)
        }
    }
    return (last.color, last.opacity)
}

/// Remap `stops` (a LINEAR gradient's, authored against `parent`) onto the
/// sub-region `fragment`, both at the same `angleDeg`.
///
/// Returns stops whose `location`s all lie in `[0, 100]` and which paint the
/// same colours over `fragment` that the parent's ramp painted there.
///
/// Returns the input unchanged when there is nothing to do or nothing to do it
/// with: fewer than two stops (the painter refuses to build a brush at all), or
/// a fragment whose diagonal is zero (a degenerate box has no span to map onto,
/// and dividing by it would produce infinities).
public func remapLinearStops(_ stops: [GradientStop],
                             angleDeg: Double,
                             parent: GradientBBox,
                             fragment: GradientBBox) -> [GradientStop] {
    if stops.count < 2 { return stops }
    let (parentCentre, parentHalf) = gradientAxisFrame(parent, angleDeg)
    let (fragCentre, fragHalf) = gradientAxisFrame(fragment, angleDeg)
    if fragHalf <= 0.0 { return stops }

    // A stop at parent location L sits at absolute position
    //   parentCentre + (2L/100 - 1) * parentHalf
    // and the fragment's own ramp spans fragCentre +/- fragHalf, so
    //   L' = 50 * ( (absolute - fragCentre) / fragHalf + 1 ).
    let remapped: [GradientStop] = stops.map { s in
        let absolute = parentCentre + (2.0 * s.location / 100.0 - 1.0) * parentHalf
        return GradientStop(color: s.color, opacity: s.opacity,
                            location: 50.0 * ((absolute - fragCentre) / fragHalf + 1.0),
                            midpointToNext: s.midpointToNext)
    }

    // Clip to [0, 100]. Interior stops survive as they are; the two ends are
    // replaced by SAMPLES of the remapped ramp, so the colour at the fragment's
    // own edges is the colour the parent's ramp had there.
    var out: [GradientStop] = []
    out.reserveCapacity(remapped.count + 2)
    let (c0, o0) = gradientSample(remapped, 0.0)
    out.append(GradientStop(color: c0, opacity: o0, location: 0.0,
                            midpointToNext: remapped[0].midpointToNext))
    for s in remapped where s.location > 0.0 && s.location < 100.0 {
        out.append(s)
    }
    let (c1, o1) = gradientSample(remapped, 100.0)
    out.append(GradientStop(color: c1, opacity: o1, location: 100.0,
                            midpointToNext: remapped[remapped.count - 1].midpointToNext))
    return out
}
