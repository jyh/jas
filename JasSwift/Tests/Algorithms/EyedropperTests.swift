import Foundation
import Testing
@testable import JasLib

// Mirrors the eyedropper test suite in
// jas_dioxus/src/algorithms/eyedropper.rs.

private func makeRect(fill: Fill?, stroke: Stroke?) -> Element {
    .rect(Rect(
        x: 0, y: 0, width: 10, height: 10,
        rx: 0, ry: 0,
        fill: fill, stroke: stroke,
        opacity: 1.0, transform: nil,
        locked: false, visibility: .preview,
        blendMode: .normal
    ))
}

private func redFill() -> Fill {
    Fill(color: Color(r: 1.0, g: 0.0, b: 0.0))
}

private func blueStroke() -> Stroke {
    Stroke(
        color: Color(r: 0.0, g: 0.0, b: 1.0),
        width: 4.0,
        linecap: .round,
        linejoin: .bevel,
        align: .inside
    )
}

@Test func extractRectWithFillAndStroke() {
    let el = makeRect(fill: redFill(), stroke: blueStroke())
    let app = extractEyedropperAppearance(el)
    #expect(app.fill == redFill())
    #expect(app.stroke == blueStroke())
    #expect(app.opacity == 1.0)
    #expect(app.blendMode == .normal)
    #expect(app.strokeBrush == nil)
}

@Test func extractLineHasNoFill() {
    let line: Element = .line(Line(
        x1: 0, y1: 0, x2: 10, y2: 10,
        stroke: blueStroke()
    ))
    let app = extractEyedropperAppearance(line)
    #expect(app.fill == nil)
    #expect(app.stroke == blueStroke())
}

@Test func appearanceJsonRoundtrip() {
    let app = EyedropperAppearance(
        fill: redFill(),
        stroke: blueStroke(),
        opacity: 0.75,
        blendMode: .multiply,
        strokeBrush: "calligraphic_default"
    )
    let dict = app.toDict()
    let back = EyedropperAppearance(dict: dict)
    #expect(back != nil)
    #expect(back?.fill == app.fill)
    #expect(back?.stroke == app.stroke)
    #expect(back?.opacity == app.opacity)
    #expect(back?.blendMode == app.blendMode)
    #expect(back?.strokeBrush == app.strokeBrush)
}

@Test func applyMasterOffSkipsGroup() {
    let src = makeRect(fill: redFill(), stroke: blueStroke())
    let app = extractEyedropperAppearance(src)
    let target = makeRect(fill: nil, stroke: nil)
    var cfg = EyedropperConfig()
    cfg.fill = false
    cfg.stroke = false
    cfg.opacity = false
    let out = applyEyedropperAppearance(target, appearance: app, config: cfg)
    #expect(out.fill == nil)
    #expect(out.stroke == nil)
}

@Test func applyStrokeColorSubOnly() {
    let src = makeRect(fill: nil, stroke: blueStroke())
    let app = extractEyedropperAppearance(src)
    let existing = Stroke(
        color: Color(r: 0.5, g: 0.5, b: 0.5),
        width: 2.0,
        linecap: .square
    )
    let target = makeRect(fill: nil, stroke: existing)
    var cfg = EyedropperConfig()
    cfg.stroke = true
    cfg.strokeColor = true
    cfg.strokeWeight = false
    cfg.strokeCapJoin = false
    cfg.strokeAlign = false
    cfg.strokeDash = false
    cfg.strokeArrowheads = false
    cfg.strokeBrush = false
    cfg.strokeProfile = false
    let out = applyEyedropperAppearance(target, appearance: app, config: cfg)
    let outStroke = out.stroke!
    // Color copied from source...
    #expect(outStroke.color == Color(r: 0.0, g: 0.0, b: 1.0))
    // ...but weight, cap preserved from target.
    #expect(outStroke.width == 2.0)
    #expect(outStroke.linecap == .square)
}

@Test func sourceEligibilityFiltersHiddenAndContainers() {
    let visible = makeRect(fill: nil, stroke: nil)
    #expect(isSourceEligible(visible))

    let hidden: Element = .rect(Rect(
        x: 0, y: 0, width: 10, height: 10, rx: 0, ry: 0,
        fill: nil, stroke: nil, opacity: 1.0,
        transform: nil, locked: false, visibility: .invisible,
        blendMode: .normal
    ))
    #expect(!isSourceEligible(hidden))

    let locked: Element = .rect(Rect(
        x: 0, y: 0, width: 10, height: 10, rx: 0, ry: 0,
        fill: nil, stroke: nil, opacity: 1.0,
        transform: nil, locked: true, visibility: .preview,
        blendMode: .normal
    ))
    // Locked is OK on source side.
    #expect(isSourceEligible(locked))

    let group: Element = .group(Group(children: []))
    #expect(!isSourceEligible(group))
}

@Test func targetEligibilityFiltersLockedAndContainers() {
    let unlocked = makeRect(fill: nil, stroke: nil)
    #expect(isTargetEligible(unlocked))

    let locked: Element = .rect(Rect(
        x: 0, y: 0, width: 10, height: 10, rx: 0, ry: 0,
        fill: nil, stroke: nil, opacity: 1.0,
        transform: nil, locked: true, visibility: .preview,
        blendMode: .normal
    ))
    #expect(!isTargetEligible(locked))

    // Hidden is OK on target side.
    let hidden: Element = .rect(Rect(
        x: 0, y: 0, width: 10, height: 10, rx: 0, ry: 0,
        fill: nil, stroke: nil, opacity: 1.0,
        transform: nil, locked: false, visibility: .invisible,
        blendMode: .normal
    ))
    #expect(isTargetEligible(hidden))

    let group: Element = .group(Group(children: []))
    #expect(!isTargetEligible(group))
}
