import Testing
@testable import JasLib

// The canvas's double-click ORDER (docs/TESTING.md section 6, flask STATUS
// 757-758): AppKit, like WinUI, reports the double on the SECOND PRESS
// (`clickCount == 2` on mouseDown). The grammar and the browser's `dblclick`
// put it AFTER the second release: press, release, press, release, double.
// The canvas holds the double until that release.

@Test func clickOrderASingleClickIsAPressAndARelease() {
    var o = CanvasClickOrder()
    #expect(o.down(clickCount: 1) == [.press])
    #expect(o.up() == [.release])
}

@Test func clickOrderADoubleClickGivesTheGrammarsOrder() {
    var o = CanvasClickOrder()
    let acts = o.down(clickCount: 1) + o.up() + o.down(clickCount: 2) + o.up()
    #expect(acts == [.press, .release, .press, .release, .doubleClick])
}

// The double fires once, at the second click, as a browser's `dblclick` does
// (`detail == 2`); a third click in the run is a plain click.
@Test func clickOrderATripleClickFiresTheDoubleOnce() {
    var o = CanvasClickOrder()
    var acts: [CanvasPointerAct] = []
    for n in 1...3 { acts += o.down(clickCount: n) + o.up() }
    #expect(acts == [.press, .release, .press, .release, .doubleClick, .press, .release])
}

// A pending double does not leak into the next click run.
@Test func clickOrderThePendingDoubleIsSpentByItsRelease() {
    var o = CanvasClickOrder()
    _ = o.down(clickCount: 2)
    _ = o.up()
    #expect(o.down(clickCount: 1) == [.press])
    #expect(o.up() == [.release])
}

// A run whose release never reached `up()` (no tool context at mouseUp) does
// not leak its double into the next run.
@Test func clickOrderAnUnreleasedDoubleDoesNotLeak() {
    var o = CanvasClickOrder()
    _ = o.down(clickCount: 2)
    #expect(o.down(clickCount: 1) == [.press])
    #expect(o.up() == [.release])
}
