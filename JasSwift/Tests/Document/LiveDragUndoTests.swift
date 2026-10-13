import Testing
@testable import JasLib

// A LIVE DRAG IS ONE UNDO STEP BACK TO BEFORE THE DRAG. A colour drag writes
// each tick live (`mapSelectionFillLive`, off the undo stack) and commits at
// release. The commit's checkpoint must be the document BEFORE the drag: taken
// at the release it was the last live tick, so Undo after a drag restored the
// dragged colour, not the original. Mirrors the Rust arms in
// `document::controller::tests` (`a_live_drag_and_its_commit_...`).

private let rectSvg = """
<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">\
<rect x="0" y="0" width="72" height="36" fill="#0000ff"/></svg>
"""

private func rectModel() -> (Model, Controller) {
    let model = Model(document: svgToDocument(rectSvg))
    let ctrl = Controller(model: model)
    ctrl.selectAll()
    precondition(model.document.selection.count == 1, "the rect is selected")
    return (model, ctrl)
}

private func doc(_ m: Model) -> String { documentToTestJson(m.document) }

private func to(_ c: Color) -> (Fill?) -> Fill? { { _ in Fill(color: c) } }

private let red = Color.rgb(r: 1, g: 0, b: 0, a: 1)
private let yellow = Color.rgb(r: 1, g: 1, b: 0, a: 1)
private let green = Color.rgb(r: 0, g: 1, b: 0, a: 1)

@Test func aLiveDragAndItsCommitAreOneUndoStepBackToBeforeTheDrag() {
    let (m, c) = rectModel()
    let before = doc(m)
    c.mapSelectionFillLive(to(red))
    #expect(doc(m) != before, "CONTROL: the live tick changed the document")
    c.mapSelectionFillLive(to(yellow))
    #expect(!m.canUndo, "live ticks are off the undo stack")
    c.mapSelectionFill(to(green))
    let committed = doc(m)
    m.undo()
    #expect(doc(m) == before, "Undo returns to before the drag, not to a live tick")
    #expect(!m.canUndo, "the drag was ONE step")
    m.redo()
    #expect(doc(m) == committed, "Redo returns the committed colour")
}

@Test func undoDuringALiveDragDropsItsBaseline() {
    let (m, c) = rectModel()
    let start = doc(m)
    c.mapSelectionFill(to(green))
    c.mapSelectionFillLive(to(red))
    m.undo()
    #expect(doc(m) == start)
    c.mapSelectionFillLive(to(yellow))
    c.mapSelectionFill(to(red))
    m.undo()
    #expect(doc(m) == start, "the second drag's Undo returns to where IT began")
}

@Test func redoDuringALiveDragDropsItsBaseline() {
    let (m, c) = rectModel()
    c.mapSelectionFill(to(green))
    let greenDoc = doc(m)
    m.undo()
    c.mapSelectionFillLive(to(red))
    m.redo()
    #expect(doc(m) == greenDoc)
    c.mapSelectionFill(to(yellow))
    m.undo()
    #expect(doc(m) == greenDoc, "the edit after the redo undoes to the redone state")
}

@Test func aSnapshotAfterALiveDragAlsoUndoesToBeforeIt() {
    let (m, c) = rectModel()
    let before = doc(m)
    c.mapSelectionFillLive(to(red))
    m.snapshot()
    m.undo()
    #expect(doc(m) == before)
}

@Test func theBaselineIsSpentByTheCommitItServes() {
    let (m, c) = rectModel()
    c.mapSelectionFillLive(to(red))
    c.mapSelectionFill(to(green))
    let committed = doc(m)
    c.mapSelectionFill(to(yellow))
    m.undo()
    #expect(doc(m) == committed)
}

@Test func aDragThatSnapshotsAtItsStartKeepsItsOwnUndoStep() {
    // The artboard tool's shape: `doc.snapshot` at the drag threshold, THEN
    // live ticks through the same `.liveDrag` channel, and a commit that
    // pushes no checkpoint. That drag owns its undo step, so the next edit
    // undoes to the DRAGGED document, not back past the drag.
    let (m, c) = rectModel()
    m.snapshot()
    let (other, oc) = rectModel()
    oc.mapSelectionFill(to(red))
    m.setDocumentUnbracketed(other.document, intent: .liveDrag)
    let afterDrag = doc(m)
    c.mapSelectionFill(to(green))
    m.undo()
    #expect(doc(m) == afterDrag, "the edit after the drag undoes to the dragged state")
}

@Test func aLiveStrokeDragIsOneUndoStepToo() {
    let (m, c) = rectModel()
    let before = doc(m)
    c.mapSelectionStrokeLive { _ in Stroke(color: red, width: 2) }
    #expect(doc(m) != before, "CONTROL: the live tick changed the stroke")
    c.mapSelectionStroke { _ in Stroke(color: green, width: 2) }
    m.undo()
    #expect(doc(m) == before)
}

@Test func anEditWithNoLiveDragCheckpointsTheDocumentItEdits() {
    let (m, c) = rectModel()
    c.mapSelectionFill(to(red))
    let redDoc = doc(m)
    c.mapSelectionFill(to(green))
    m.undo()
    #expect(doc(m) == redDoc, "CONTROL: a plain edit's Undo is the edit before it")
}
