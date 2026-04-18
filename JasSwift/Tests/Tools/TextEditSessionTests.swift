import Testing
@testable import JasLib

// Mirrors `text_edit_test.py`, `text_edit_test.ml`, and the unit tests
// in `jas_dioxus/src/tools/text_edit.rs`.

private func session(_ content: String) -> TextEditSession {
    TextEditSession(path: [0, 0], target: .text, content: content, insertion: 0)
}

@Test func newSessionHasCaretAtInsertion() {
    let s = TextEditSession(path: [0, 0], target: .text, content: "abc", insertion: 2)
    #expect(s.insertion == 2)
    #expect(s.anchor == 2)
    #expect(!s.hasSelection)
}

@Test func insertAtCaretAdvancesPosition() {
    let s = session("hello")
    s.setInsertion(5, extend: false)
    s.insert(" world")
    #expect(s.content == "hello world")
    #expect(s.insertion == 11)
}

@Test func insertReplacesSelection() {
    let s = session("hello")
    s.setInsertion(0, extend: false)
    s.setInsertion(5, extend: true)
    s.insert("hi")
    #expect(s.content == "hi")
    #expect(s.insertion == 2)
    #expect(!s.hasSelection)
}

@Test func backspaceDeletesCharBeforeCursor() {
    let s = session("hello")
    s.setInsertion(5, extend: false)
    s.backspace()
    #expect(s.content == "hell")
    #expect(s.insertion == 4)
}

@Test func backspaceAtStartIsNoop() {
    let s = session("hi")
    s.setInsertion(0, extend: false)
    s.backspace()
    #expect(s.content == "hi")
}

@Test func backspaceWithSelectionDeletesRange() {
    let s = session("hello")
    s.setInsertion(1, extend: false)
    s.setInsertion(4, extend: true)
    s.backspace()
    #expect(s.content == "ho")
    #expect(s.insertion == 1)
}

@Test func deleteForwardRemovesCharAfter() {
    let s = session("hello")
    s.setInsertion(0, extend: false)
    s.deleteForward()
    #expect(s.content == "ello")
}

@Test func deleteForwardAtEndIsNoop() {
    let s = session("hi")
    s.setInsertion(2, extend: false)
    s.deleteForward()
    #expect(s.content == "hi")
}

@Test func selectAllExtendsToFullContent() {
    let s = session("hello")
    s.selectAll()
    let (lo, hi) = s.selectionRange
    #expect(lo == 0 && hi == 5)
}

@Test func copySelectionReturnsSubstring() {
    let s = session("hello")
    s.setInsertion(1, extend: false)
    s.setInsertion(4, extend: true)
    #expect(s.copySelection() == "ell")
}

@Test func copyWithNoSelectionReturnsNil() {
    let s = session("hello")
    #expect(s.copySelection() == nil)
}

@Test func undoRestoresPreviousState() {
    let s = session("")
    s.insert("a")
    s.insert("b")
    #expect(s.content == "ab")
    s.undo()
    #expect(s.content == "a")
    s.undo()
    #expect(s.content == "")
}

@Test func redoReplaysUndoneState() {
    let s = session("")
    s.insert("a")
    s.undo()
    s.redo()
    #expect(s.content == "a")
}

@Test func newEditClearsRedo() {
    let s = session("")
    s.insert("a")
    s.undo()
    s.insert("b")
    s.redo()
    #expect(s.content == "b")
}

@Test func setInsertionClampsPastEnd() {
    let s = session("hi")
    s.setInsertion(99, extend: false)
    #expect(s.insertion == 2)
    #expect(s.anchor == 2)
}

@Test func extendSelectionKeepsAnchor() {
    let s = session("hello")
    s.setInsertion(2, extend: false)
    s.setInsertion(4, extend: true)
    #expect(s.hasSelection)
    #expect(s.anchor == 2)
    #expect(s.insertion == 4)
    let (lo, hi) = s.selectionRange
    #expect(lo == 2 && hi == 4)
}

@Test func reverseSelectionOrdersRange() {
    let s = session("hello")
    s.setInsertion(4, extend: false)
    s.setInsertion(1, extend: true)
    let (lo, hi) = s.selectionRange
    #expect(lo == 1 && hi == 4)
}

@Test func selectAllThenInsertReplacesEverything() {
    let s = session("hello")
    s.selectAll()
    s.insert("X")
    #expect(s.content == "X")
    #expect(s.insertion == 1)
    #expect(!s.hasSelection)
}

@Test func multiUndoRedoWalksHistory() {
    let s = session("")
    s.insert("a")
    s.insert("b")
    s.insert("c")
    #expect(s.content == "abc")
    s.undo(); s.undo()
    #expect(s.content == "a")
    s.redo()
    #expect(s.content == "ab")
    s.redo()
    #expect(s.content == "abc")
}

@Test func undoAtBottomOfStackIsNoop() {
    let s = session("hi")
    s.undo()
    #expect(s.content == "hi")
}

@Test func deleteForwardWithSelectionDeletesRange() {
    let s = session("hello")
    s.setInsertion(1, extend: false)
    s.setInsertion(4, extend: true)
    s.deleteForward()
    #expect(s.content == "ho")
}

// Multibyte (Swift Character) handling — Swift uses extended grapheme
// clusters, so 'é' is a single Character regardless of underlying bytes.

@Test func insertHandlesMultibyteContent() {
    let s = session("aéb")
    s.setInsertion(2, extend: false)
    s.insert("X")
    #expect(s.content == "aéXb")
}

@Test func copySelectionHandlesMultibyte() {
    let s = session("aéb")
    s.setInsertion(0, extend: false)
    s.setInsertion(2, extend: true)
    #expect(s.copySelection() == "aé")
}

// MARK: - applyToDocument

@Test func applyToDocumentReturnsNilOnStalePath() {
    let s = session("X")
    let doc = Document()  // empty: path [0, 0] does not resolve
    #expect(s.applyToDocument(doc) == nil)
}

@Test func applyToDocumentWritesContentBack() {
    let layer = Layer(name: "L", children: [.text(emptyTextElem(x: 0, y: 0, width: 0, height: 0))])
    let doc = Document(layers: [layer])
    let s = session("")
    s.insert("hi")
    let newDoc = s.applyToDocument(doc)
    #expect(newDoc != nil)
    if let nd = newDoc, case .text(let t) = nd.layers[0].children[0] {
        #expect(t.content == "hi")
    } else {
        Issue.record("Expected text element with updated content")
    }
}

// MARK: - session-scoped tspan clipboard

@Test func copySelectionWithTspansCapturesAndReturnsFlat() {
    let elementTspans = [
        Tspan(id: 0, content: "foo"),
        Tspan(id: 1, content: "bar", fontWeight: "bold"),
    ]
    let s = TextEditSession(path: [0, 0], target: .text,
                             content: "foobar", insertion: 0)
    s.setInsertion(1, extend: false)
    s.setInsertion(5, extend: true) // select "ooba"
    let flat = s.copySelectionWithTspans(elementTspans)
    #expect(flat == "ooba")
    guard let (savedFlat, saved) = s.tspanClipboard else {
        Issue.record("clipboard should be populated"); return
    }
    #expect(savedFlat == "ooba")
    #expect(saved.count == 2)
    #expect(saved[0].content == "oo")
    #expect(saved[0].fontWeight == nil)
    #expect(saved[1].content == "ba")
    #expect(saved[1].fontWeight == "bold")
}

@Test func tryPasteTspansMatchesClipboardAndSplices() {
    let elementTspans = [Tspan(id: 0, content: "foo")]
    let s = TextEditSession(path: [0, 0], target: .text,
                             content: "foo", insertion: 0)
    s.tspanClipboard = (
        flat: "X",
        tspans: [Tspan(id: 0, content: "X", fontWeight: "bold")]
    )
    s.setInsertion(1, extend: false)
    guard let result = s.tryPasteTspans(elementTspans, text: "X") else {
        Issue.record("expected paste result"); return
    }
    #expect(result.count == 3)
    #expect(result[0].content == "f")
    #expect(result[1].content == "X")
    #expect(result[1].fontWeight == "bold")
    #expect(result[2].content == "oo")
}

@Test func tryPasteTspansReturnsNilWhenTextDoesntMatch() {
    let elementTspans = [Tspan(id: 0, content: "foo")]
    let s = TextEditSession(path: [0, 0], target: .text,
                             content: "foo", insertion: 0)
    s.tspanClipboard = (flat: "X", tspans: [])
    #expect(s.tryPasteTspans(elementTspans, text: "DIFFERENT") == nil)
}

// MARK: - caret affinity

@Test func newSessionCaretHasLeftAffinity() {
    let s = session("abc")
    #expect(s.caretAffinity == .left)
}

@Test func insertionTspanPosLeftDefaultAtBoundary() {
    let tspans = [
        Tspan(id: 0, content: "foo"),
        Tspan(id: 1, content: "bar", fontWeight: "bold"),
    ]
    let s = session("foobar")
    s.setInsertion(3, extend: false)
    #expect(s.caretAffinity == .left)
    let pos = s.insertionTspanPos(tspans)
    #expect(pos.tspanIdx == 0 && pos.offset == 3)
}

@Test func setInsertionWithAffinityRightCrossesBoundary() {
    let tspans = [
        Tspan(id: 0, content: "foo"),
        Tspan(id: 1, content: "bar", fontWeight: "bold"),
    ]
    let s = session("foobar")
    s.setInsertion(3, affinity: .right, extend: false)
    #expect(s.caretAffinity == .right)
    let pos = s.insertionTspanPos(tspans)
    #expect(pos.tspanIdx == 1 && pos.offset == 0)
}

@Test func anchorTspanPosUsesCaretAffinity() {
    let tspans = [
        Tspan(id: 0, content: "foo"),
        Tspan(id: 1, content: "bar"),
    ]
    let s = session("foobar")
    s.setInsertion(3, extend: false)
    s.setInsertion(5, affinity: .right, extend: true)
    let anchor = s.anchorTspanPos(tspans)
    #expect(anchor.tspanIdx == 1 && anchor.offset == 0)
    let caret = s.insertionTspanPos(tspans)
    #expect(caret.tspanIdx == 1 && caret.offset == 2)
}
