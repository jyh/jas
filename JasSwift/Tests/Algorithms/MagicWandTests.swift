import Foundation
import Testing
@testable import JasLib

// Mirrors the magic_wand test suite in
// jas_dioxus/src/algorithms/magic_wand.rs.

private func makeRect(
    fill: Fill?, stroke: Stroke?, opacity: Double,
    blendMode: BlendMode
) -> Element {
    .rect(Rect(
        x: 0, y: 0, width: 10, height: 10,
        rx: 0, ry: 0,
        fill: fill, stroke: stroke,
        opacity: opacity,
        transform: nil,
        locked: false,
        visibility: .preview,
        blendMode: blendMode
    ))
}

@Test func magicWandAllDisabledNeverMatches() {
    var cfg = MagicWandConfig()
    cfg.fillColor = false
    cfg.strokeColor = false
    cfg.strokeWeight = false
    cfg.opacity = false
    cfg.blendingMode = false
    let seed = makeRect(fill: Fill(color: Color(r: 1.0, g: 0, b: 0)),
                        stroke: nil, opacity: 1.0, blendMode: .normal)
    #expect(!magicWandMatch(seed: seed, candidate: seed, config: cfg))
}

@Test func magicWandIdenticalElementsMatchUnderDefault() {
    let cfg = MagicWandConfig()
    let seed = makeRect(
        fill: Fill(color: Color(r: 1.0, g: 0, b: 0)),
        stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 2.0),
        opacity: 1.0, blendMode: .normal)
    #expect(magicWandMatch(seed: seed, candidate: seed, config: cfg))
}

@Test func magicWandFillColorWithinToleranceMatches() {
    var cfg = MagicWandConfig()
    cfg.strokeColor = false
    cfg.strokeWeight = false
    cfg.opacity = false
    cfg.blendingMode = false
    // Tolerance 32, seed = pure red. Candidate = (240, 10, 10):
    //   distance ≈ √(15² + 10² + 10²) ≈ 21.8, within 32.
    let seed = makeRect(fill: Fill(color: Color(r: 1.0, g: 0, b: 0)),
                        stroke: nil, opacity: 1.0, blendMode: .normal)
    let cand = makeRect(
        fill: Fill(color: Color(r: 240.0/255.0, g: 10.0/255.0, b: 10.0/255.0)),
        stroke: nil, opacity: 1.0, blendMode: .normal)
    #expect(magicWandMatch(seed: seed, candidate: cand, config: cfg))
}

@Test func magicWandFillColorOutsideToleranceMisses() {
    var cfg = MagicWandConfig()
    cfg.strokeColor = false
    cfg.strokeWeight = false
    cfg.opacity = false
    cfg.blendingMode = false
    cfg.fillTolerance = 10
    // Seed = pure red, candidate = (200, 0, 0). Distance = 55, > 10.
    let seed = makeRect(fill: Fill(color: Color(r: 1.0, g: 0, b: 0)),
                        stroke: nil, opacity: 1.0, blendMode: .normal)
    let cand = makeRect(
        fill: Fill(color: Color(r: 200.0/255.0, g: 0, b: 0)),
        stroke: nil, opacity: 1.0, blendMode: .normal)
    #expect(!magicWandMatch(seed: seed, candidate: cand, config: cfg))
}

@Test func magicWandNoneFillMatchesOnlyNoneFill() {
    var cfg = MagicWandConfig()
    cfg.strokeColor = false
    cfg.strokeWeight = false
    cfg.opacity = false
    cfg.blendingMode = false
    let noneFill = makeRect(fill: nil, stroke: nil,
                            opacity: 1.0, blendMode: .normal)
    let red = makeRect(fill: Fill(color: Color(r: 1.0, g: 0, b: 0)),
                       stroke: nil, opacity: 1.0, blendMode: .normal)
    #expect(magicWandMatch(seed: noneFill, candidate: noneFill, config: cfg))
    #expect(!magicWandMatch(seed: noneFill, candidate: red, config: cfg))
    #expect(!magicWandMatch(seed: red, candidate: noneFill, config: cfg))
}

@Test func magicWandStrokeWeightUsesPtDelta() {
    var cfg = MagicWandConfig()
    cfg.fillColor = false
    cfg.strokeColor = false
    cfg.opacity = false
    cfg.blendingMode = false
    cfg.strokeWeightTolerance = 1.0
    let s2 = makeRect(fill: nil,
                      stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 2.0),
                      opacity: 1.0, blendMode: .normal)
    let s2_5 = makeRect(fill: nil,
                        stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 2.5),
                        opacity: 1.0, blendMode: .normal)
    let s4 = makeRect(fill: nil,
                      stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 4.0),
                      opacity: 1.0, blendMode: .normal)
    #expect(magicWandMatch(seed: s2, candidate: s2_5, config: cfg))   // Δ 0.5
    #expect(!magicWandMatch(seed: s2, candidate: s4, config: cfg))    // Δ 2.0
}

@Test func magicWandOpacityUsesPercentagePointDelta() {
    var cfg = MagicWandConfig()
    cfg.fillColor = false
    cfg.strokeColor = false
    cfg.strokeWeight = false
    cfg.blendingMode = false
    cfg.opacityTolerance = 5.0
    let a = makeRect(fill: nil, stroke: nil, opacity: 1.0,
                     blendMode: .normal)
    let b = makeRect(fill: nil, stroke: nil, opacity: 0.97,
                     blendMode: .normal)
    let c = makeRect(fill: nil, stroke: nil, opacity: 0.80,
                     blendMode: .normal)
    #expect(magicWandMatch(seed: a, candidate: b, config: cfg))   // 3 ≤ 5
    #expect(!magicWandMatch(seed: a, candidate: c, config: cfg))  // 20 > 5
}

@Test func magicWandBlendingModeIsExactMatch() {
    var cfg = MagicWandConfig()
    cfg.fillColor = false
    cfg.strokeColor = false
    cfg.strokeWeight = false
    cfg.opacity = false
    cfg.blendingMode = true
    let normal = makeRect(fill: nil, stroke: nil, opacity: 1.0,
                          blendMode: .normal)
    let normal2 = makeRect(fill: nil, stroke: nil, opacity: 1.0,
                           blendMode: .normal)
    let multiply = makeRect(fill: nil, stroke: nil, opacity: 1.0,
                            blendMode: .multiply)
    #expect(magicWandMatch(seed: normal, candidate: normal2, config: cfg))
    #expect(!magicWandMatch(seed: normal, candidate: multiply, config: cfg))
}

@Test func magicWandAndAcrossCriteriaOneFailureMisses() {
    var cfg = MagicWandConfig()
    cfg.opacity = false
    cfg.blendingMode = false
    cfg.strokeWeightTolerance = 1.0
    let seed = makeRect(
        fill: Fill(color: Color(r: 1.0, g: 0, b: 0)),
        stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 2.0),
        opacity: 1.0, blendMode: .normal)
    let cand = makeRect(
        fill: Fill(color: Color(r: 1.0, g: 0, b: 0)),  // same fill
        stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 5.0),  // wider
        opacity: 1.0, blendMode: .normal)
    #expect(!magicWandMatch(seed: seed, candidate: cand, config: cfg))
}
