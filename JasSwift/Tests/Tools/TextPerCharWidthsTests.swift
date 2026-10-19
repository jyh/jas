import Testing
@testable import JasLib

// A baseline shift scales the size the canvas DRAWS a run at
// (`t.fontSize ?? effectiveFs`), so the per-character widths its layout
// uses must be taken at that same size, as Rust's shared plan takes them
// (`jas_dioxus` `algorithms::text_runs::plan`). A tspan's own size is not
// scaled.

@Test func perCharWidthsTakeTheBaselineShiftsScale() {
    let plain = Tspan(id: 0, content: "ab")
    let sized = Tspan(id: 1, content: "c", fontSize: 30)
    let t = Text(x: 0, y: 0, tspans: [plain, sized], fontSize: 20, width: 0, height: 0)
    let at = { (size: Double) in
        makeMeasurer(family: t.fontFamily, weight: "normal", style: "normal", size: size)
    }
    let (m14, m30) = (at(14), at(30))
    #expect(textPerCharWidths(t.tspans, element: t, sizeScale: 0.7) == [m14("a"), m14("b"), m30("c")])
}

@Test func perCharWidthsWithoutAScaleAreUnchanged() {
    // CONTROL: the default is the element's size as written (the Type
    // tool's layout, which takes no shift, calls it this way).
    let plain = Tspan(id: 0, content: "ab")
    let t = Text(x: 0, y: 0, tspans: [plain], fontSize: 20, width: 0, height: 0)
    let m20 = makeMeasurer(family: t.fontFamily, weight: "normal", style: "normal", size: 20)
    #expect(textPerCharWidths(t.tspans, element: t) == [m20("a"), m20("b")])
    #expect(m20("a") != makeMeasurer(family: t.fontFamily, weight: "normal", style: "normal", size: 14)("a"),
            "the instrument can tell 20 from 14")
}

// Tracking and kerning: the canvas draws every character with a uniform
// `.kern` advance, so the widths its layout uses carry that advance too, as
// Rust's shared plan and flat path do.
@Test func perCharWidthsCarryTheDrawnSpacing() {
    let plain = Tspan(id: 0, content: "ab")
    let t = Text(x: 0, y: 0, tspans: [plain], fontSize: 20, width: 0, height: 0)
    let m20 = makeMeasurer(family: t.fontFamily, weight: "normal", style: "normal", size: 20)
    #expect(textPerCharWidths(t.tspans, element: t, spacing: 2) == [m20("a") + 2, m20("b") + 2])
}
