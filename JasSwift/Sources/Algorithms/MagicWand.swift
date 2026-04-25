// Magic Wand match predicate.
//
// Pure function: given a seed element, a candidate element, and the
// nine `state.magic_wand_*` configuration values, decide whether
// the candidate is "similar" to the seed under the enabled
// criteria.
//
// See `transcripts/MAGIC_WAND_TOOL.md` §Predicate for the rules.
// Cross-language parity is mechanical — the OCaml / Rust / Python
// ports of this module use the same logic.

import Foundation

/// The five-criterion configuration mirrors `state.magic_wand_*`.
/// Each criterion has an enabled flag (true = participate in the
/// predicate) and, where applicable, a tolerance.
public struct MagicWandConfig: Equatable {
    /// Fill Color criterion enabled.
    public var fillColor: Bool
    /// Maximum Euclidean RGB distance on the 0–255 scale.
    public var fillTolerance: Double

    /// Stroke Color criterion enabled.
    public var strokeColor: Bool
    /// Maximum Euclidean RGB distance on the 0–255 scale.
    public var strokeTolerance: Double

    /// Stroke Weight criterion enabled.
    public var strokeWeight: Bool
    /// Maximum |Δ width| in pt.
    public var strokeWeightTolerance: Double

    /// Opacity criterion enabled.
    public var opacity: Bool
    /// Maximum |Δ opacity| × 100 in percentage points.
    public var opacityTolerance: Double

    /// Blending Mode criterion enabled. Exact-match only.
    public var blendingMode: Bool

    public init(
        fillColor: Bool = true,
        fillTolerance: Double = 32,
        strokeColor: Bool = true,
        strokeTolerance: Double = 32,
        strokeWeight: Bool = true,
        strokeWeightTolerance: Double = 5.0,
        opacity: Bool = true,
        opacityTolerance: Double = 5,
        blendingMode: Bool = false
    ) {
        self.fillColor = fillColor
        self.fillTolerance = fillTolerance
        self.strokeColor = strokeColor
        self.strokeTolerance = strokeTolerance
        self.strokeWeight = strokeWeight
        self.strokeWeightTolerance = strokeWeightTolerance
        self.opacity = opacity
        self.opacityTolerance = opacityTolerance
        self.blendingMode = blendingMode
    }
}

/// Decide whether `candidate` is similar to `seed` under the
/// enabled criteria. AND across all enabled criteria. When all
/// criteria are disabled this returns false (the wand is a
/// no-op; the click handler treats this as "select only the seed
/// itself" — but that's the *caller's* responsibility).
public func magicWandMatch(
    seed: Element,
    candidate: Element,
    config: MagicWandConfig
) -> Bool {
    let anyEnabled = config.fillColor || config.strokeColor
        || config.strokeWeight || config.opacity || config.blendingMode
    if !anyEnabled { return false }

    if config.fillColor
        && !mwFillColorMatches(seed.fill, candidate.fill,
                               tolerance: config.fillTolerance) {
        return false
    }
    if config.strokeColor
        && !mwStrokeColorMatches(seed.stroke, candidate.stroke,
                                 tolerance: config.strokeTolerance) {
        return false
    }
    if config.strokeWeight
        && !mwStrokeWeightMatches(seed.stroke, candidate.stroke,
                                  tolerance: config.strokeWeightTolerance) {
        return false
    }
    if config.opacity
        && !mwOpacityMatches(mwElementOpacity(seed),
                             mwElementOpacity(candidate),
                             tolerance: config.opacityTolerance) {
        return false
    }
    if config.blendingMode
        && seed.blendMode != candidate.blendMode {
        return false
    }
    return true
}

/// Top-level opacity accessor for an Element. Each variant carries
/// its own opacity field; default is 1.0 across the model.
public func mwElementOpacity(_ e: Element) -> Double {
    switch e {
    case .line(let v): return v.opacity
    case .rect(let v): return v.opacity
    case .circle(let v): return v.opacity
    case .ellipse(let v): return v.opacity
    case .polyline(let v): return v.opacity
    case .polygon(let v): return v.opacity
    case .path(let v): return v.opacity
    case .text(let v): return v.opacity
    case .textPath(let v): return v.opacity
    case .group(let v): return v.opacity
    case .layer(let v): return v.opacity
    case .live(let v):
        switch v {
        case .compoundShape(let cs): return cs.opacity
        }
    }
}

// MARK: - Per-criterion helpers

private func mwFillColorMatches(_ seed: Fill?, _ cand: Fill?,
                                 tolerance: Double) -> Bool {
    switch (seed, cand) {
    case (nil, nil): return true
    case (.some(let s), .some(let c)):
        return mwRgbDistance(s.color.toRgba(), c.color.toRgba()) <= tolerance
    default: return false
    }
}

private func mwStrokeColorMatches(_ seed: Stroke?, _ cand: Stroke?,
                                   tolerance: Double) -> Bool {
    switch (seed, cand) {
    case (nil, nil): return true
    case (.some(let s), .some(let c)):
        return mwRgbDistance(s.color.toRgba(), c.color.toRgba()) <= tolerance
    default: return false
    }
}

private func mwStrokeWeightMatches(_ seed: Stroke?, _ cand: Stroke?,
                                    tolerance: Double) -> Bool {
    switch (seed, cand) {
    case (nil, nil): return true
    case (.some(let s), .some(let c)):
        return abs(s.width - c.width) <= tolerance
    default: return false
    }
}

private func mwOpacityMatches(_ seed: Double, _ cand: Double,
                               tolerance: Double) -> Bool {
    return abs(seed - cand) * 100.0 <= tolerance
}

/// Euclidean RGB distance on the 0-255 scale. Inputs are
/// `Color.toRgba()` outputs (R, G, B, A) in `[0.0, 1.0]`; we scale
/// R, G, B to `[0, 255]` and ignore alpha (Fill / Stroke carry
/// their own opacity field).
private func mwRgbDistance(_ a: (Double, Double, Double, Double),
                            _ b: (Double, Double, Double, Double)) -> Double {
    let dr = (a.0 - b.0) * 255.0
    let dg = (a.1 - b.1) * 255.0
    let db = (a.2 - b.2) * 255.0
    return (dr * dr + dg * dg + db * db).squareRoot()
}
