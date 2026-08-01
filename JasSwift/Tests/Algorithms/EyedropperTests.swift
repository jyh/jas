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

/// A source stroke that is loud in every field the artist did NOT tick,
/// so a value leaking through from the source is unmistakable.
private func dashedMagentaStroke() -> Stroke {
    Stroke(
        color: Color(r: 1.0, g: 0.0, b: 1.0),
        width: 9.0,
        dashPattern: [6.0, 3.0]
    )
}

/// CASE 1, THE SEED — RULED (JYH 2026-07-31).
///
/// Target has no stroke; source has a dashed one; the artist ticked
/// `strokeDash` but deselected `strokeColor` and `strokeWeight`. A dash
/// needs a stroke to live on, so one is fabricated — and the colour and
/// width of that fabrication come from the APP's default
/// (`workspace/state.yaml`: `stroke_color: "#000000"`, `stroke_width:
/// 1.0`), never from the source. Sourcing them transfers two attributes
/// the artist switched off.
@Test func fabricatedStrokeSeedsFromAppDefaultNotSource() {
    let src = makeRect(fill: nil, stroke: dashedMagentaStroke())
    let app = extractEyedropperAppearance(src)
    let target = makeRect(fill: redFill(), stroke: nil) // no stroke at all
    var cfg = EyedropperConfig()
    cfg.fill = false
    cfg.stroke = true
    cfg.strokeColor = false
    cfg.strokeWeight = false
    cfg.strokeCapJoin = false
    cfg.strokeAlign = false
    cfg.strokeDash = true
    cfg.strokeArrowheads = false
    cfg.strokeBrush = false
    cfg.strokeProfile = false
    cfg.opacity = false

    let out = applyEyedropperAppearance(target, appearance: app, config: cfg)
    guard let s = out.stroke else {
        Issue.record("a ticked dash sub-toggle should fabricate a stroke")
        return
    }

    // The one attribute the artist ticked does come from the source.
    #expect(s.dashPattern == [6.0, 3.0])

    // The two the artist deselected come from the app default.
    #expect(s.color == Color.black, "fabricated colour leaked from the source")
    #expect(s.width == 1.0, "fabricated width leaked from the source")
}

/// The seed is the app default even when the ticked sub-toggle is not
/// the dash — `strokeAlign` alone is enough to force a fabrication, and
/// it must not drag the source's paint along with it.
@Test func fabricatedStrokeSeedsFromAppDefaultForAnySubToggle() {
    let src = makeRect(fill: nil, stroke: dashedMagentaStroke())
    let app = extractEyedropperAppearance(src)
    let target = makeRect(fill: nil, stroke: nil)
    var cfg = EyedropperConfig()
    cfg.fill = false
    cfg.stroke = true
    cfg.strokeColor = false
    cfg.strokeWeight = false
    cfg.strokeCapJoin = false
    cfg.strokeAlign = true
    cfg.strokeDash = false
    cfg.strokeArrowheads = false
    cfg.strokeBrush = false
    cfg.strokeProfile = false
    cfg.opacity = false

    let out = applyEyedropperAppearance(target, appearance: app, config: cfg)
    guard let s = out.stroke else {
        Issue.record("a ticked align sub-toggle should fabricate a stroke")
        return
    }
    #expect(s.align == .center) // the source's align, which is center
    #expect(s.color == Color.black, "fabricated colour leaked from the source")
    #expect(s.width == 1.0, "fabricated width leaked from the source")
}

/// CASE 2, THE DEFECT. Master ON + source has NO stroke used to clear
/// the target outright, ignoring every sub-toggle — asymmetric with the
/// non-nil branch, which honours them. "No stroke" is a value of the
/// `strokeColor` attribute (EYEDROPPER_TOOL.md §Stroke: that sub-toggle
/// covers "color, none, gradient, or pattern"), so with `strokeColor`
/// OFF the artist never asked for the target's paint to change, and
/// nothing about the target's stroke may move.
@Test func sourceWithoutStrokeRespectsStrokeColorOff() {
    let src = makeRect(fill: redFill(), stroke: nil) // source has no stroke
    let app = extractEyedropperAppearance(src)
    let target = makeRect(fill: nil, stroke: blueStroke())
    var cfg = EyedropperConfig()
    cfg.fill = false
    cfg.stroke = true
    cfg.strokeColor = false // every OTHER stroke sub-toggle stays ON
    cfg.opacity = false

    let out = applyEyedropperAppearance(target, appearance: app, config: cfg)
    #expect(out.stroke == blueStroke(),
            "a stroke-less source wiped the target with strokeColor off")
}

/// The same branch under EYE-112: master ON, source has no stroke, EVERY
/// stroke sub-toggle off → the target is left alone, exactly as the
/// non-nil branch's all-subs-off short-circuit leaves it alone.
@Test func sourceWithoutStrokeAllSubsOffLeavesTargetAlone() {
    let src = makeRect(fill: redFill(), stroke: nil)
    let app = extractEyedropperAppearance(src)
    let target = makeRect(fill: nil, stroke: blueStroke())
    var cfg = EyedropperConfig()
    cfg.fill = false
    cfg.stroke = true
    cfg.strokeColor = false
    cfg.strokeWeight = false
    cfg.strokeCapJoin = false
    cfg.strokeAlign = false
    cfg.strokeDash = false
    cfg.strokeArrowheads = false
    cfg.strokeBrush = false
    cfg.strokeProfile = false
    cfg.opacity = false

    let out = applyEyedropperAppearance(target, appearance: app, config: cfg)
    #expect(out.stroke == blueStroke())
}

/// EYE-111, the other half of the same branch, kept as a guard: with
/// `strokeColor` ON a stroke-less source still means "no stroke", and
/// the target's stroke goes. This passed before the CASE 2 repair and
/// must keep passing after it.
@Test func sourceWithoutStrokeClearsTargetWhenStrokeColorOn() {
    let src = makeRect(fill: redFill(), stroke: nil)
    let app = extractEyedropperAppearance(src)
    let target = makeRect(fill: nil, stroke: blueStroke())
    var cfg = EyedropperConfig()
    cfg.fill = false
    cfg.stroke = true
    cfg.strokeColor = true
    cfg.opacity = false

    let out = applyEyedropperAppearance(target, appearance: app, config: cfg)
    #expect(out.stroke == nil)
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
