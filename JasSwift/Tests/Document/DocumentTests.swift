import Testing
@testable import JasLib

@Test func defaultDocument() {
    let doc = Document()
    #expect(doc.layers.count == 1)
}

@Test func emptyDocument() {
    let doc = Document()
    let b = doc.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 0 && b.height == 0)
}

@Test func singleLayerDocument() {
    let layer = Layer(name: "Layer 1", children: [.rect(Rect(x: 0, y: 0, width: 10, height: 10))])
    let doc = Document(layers: [layer])
    let b = doc.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 10 && b.height == 10)
}

@Test func multipleLayersDocument() {
    let l1 = Layer(name: "Background", children: [.rect(Rect(x: 0, y: 0, width: 10, height: 10))])
    let l2 = Layer(name: "Foreground", children: [.circle(Circle(cx: 50, cy: 50, r: 5))])
    let doc = Document(layers: [l1, l2])
    let b = doc.bounds
    #expect(b.x == 0 && b.y == 0 && b.width == 55 && b.height == 55)
}

@Test func documentLayersAccessible() {
    let l1 = Layer(name: "A", children: [])
    let l2 = Layer(name: "B", children: [])
    let doc = Document(layers: [l1, l2])
    #expect(doc.layers.count == 2)
    #expect(doc.layers[0].name == "A")
    #expect(doc.layers[1].name == "B")
}

// MARK: - Selection tests

private func makeTestDoc() -> Document {
    let rect = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let circle = Element.circle(Circle(cx: 50, cy: 50, r: 5))
    let line = Element.line(Line(x1: 0, y1: 0, x2: 1, y2: 1))
    let group = Element.group(Group(children: [line]))
    let layer0 = Layer(name: "L0", children: [rect, circle, group])
    let layer1 = Layer(name: "L1", children: [rect])
    return Document(layers: [layer0, layer1])
}

@Test func defaultSelectionEmpty() {
    let doc = makeTestDoc()
    #expect(doc.selection.isEmpty)
}

@Test func selectionWithPaths() {
    let sel: Selection = [ElementSelection(path: [0, 0]), ElementSelection(path: [0, 1])]
    let doc = Document(layers: makeTestDoc().layers, selection: sel)
    #expect(doc.selection.count == 2)
    #expect(doc.selectedPaths.contains([0, 0]))
    #expect(doc.selectedPaths.contains([0, 1]))
}

@Test func getElementLayer() {
    let doc = makeTestDoc()
    let elem = doc.getElement([0])
    if case .layer(let l) = elem {
        #expect(l.name == "L0")
    } else {
        Issue.record("Expected layer")
    }
}

@Test func getElementChild() {
    let doc = makeTestDoc()
    let elem = doc.getElement([0, 1])
    if case .circle = elem {
        // ok
    } else {
        Issue.record("Expected circle")
    }
}

@Test func getElementNested() {
    let doc = makeTestDoc()
    let elem = doc.getElement([0, 2, 0])
    if case .line = elem {
        // ok
    } else {
        Issue.record("Expected line")
    }
}

@Test func replaceElementChild() {
    let doc = makeTestDoc()
    let newRect = Element.rect(Rect(x: 5, y: 5, width: 20, height: 20))
    let doc2 = doc.replaceElement([0, 0], with: newRect)
    #expect(doc2.getElement([0, 0]) == newRect)
    // original unchanged
    #expect(doc.getElement([0, 0]) == Element.rect(Rect(x: 0, y: 0, width: 10, height: 10)))
}

@Test func replaceElementNested() {
    let doc = makeTestDoc()
    let newLine = Element.line(Line(x1: 1, y1: 2, x2: 3, y2: 4))
    let doc2 = doc.replaceElement([0, 2, 0], with: newLine)
    #expect(doc2.getElement([0, 2, 0]) == newLine)
}

@Test func replaceElementPreservesOtherChildren() {
    let doc = makeTestDoc()
    let newRect = Element.rect(Rect(x: 99, y: 99, width: 1, height: 1))
    let doc2 = doc.replaceElement([0, 0], with: newRect)
    if case .circle = doc2.getElement([0, 1]) { } else { Issue.record("Expected circle") }
    if case .group = doc2.getElement([0, 2]) { } else { Issue.record("Expected group") }
}

@Test func replaceElementPreservesOtherLayers() {
    let doc = makeTestDoc()
    let newRect = Element.rect(Rect(x: 99, y: 99, width: 1, height: 1))
    let doc2 = doc.replaceElement([0, 0], with: newRect)
    #expect(doc2.layers[1] == doc.layers[1])
}

@Test func replaceElementPreservesSelection() {
    let sel: Selection = [ElementSelection(path: [0, 1])]
    let doc = Document(layers: makeTestDoc().layers, selection: sel)
    let doc2 = doc.replaceElement([0, 0], with: .rect(Rect(x: 1, y: 1, width: 2, height: 2)))
    #expect(doc2.selectedPaths == doc.selectedPaths)
}

@Test func replaceElementReturnsLayerType() {
    let doc = makeTestDoc()
    let newRect = Element.rect(Rect(x: 1, y: 1, width: 2, height: 2))
    let doc2 = doc.replaceElement([0, 0], with: newRect)
    // layers[0] should still be a Layer (struct type, always true if it compiles)
    #expect(doc2.layers[0].name == "L0")
}

// MARK: - D5a: the Layers LOCK button prunes the selection

// Mirror of jas_dioxus `renderer.rs`
// `toggle_element_lock_at_locks_and_prunes_the_selection` /
// `..._prunes_only_the_locked_subtree` / `..._unlock_leaves_the_selection_alone`.
//
// SCOPE-effective-locked.md §3, D5a: jas_dioxus dropped the locked element
// and its descendants from the selection; this port's closure had no
// equivalent, so a locked layer stayed selected -- and nothing downstream
// refuses to move or delete a selected element for being locked, so that is
// not cosmetic.
//
// PER-PORT: the Layers panel is reached through GUI event handlers no shared
// corpus drives, and no shared fixture can seed a locked document anyway
// (the SVG codec drops `locked` entirely).

/// One layer named "L" holding two rects, with `selection` seeded to the
/// whole tree: the layer and both of its children.
private func lockToggleDoc() -> Document {
    let layer = Layer(name: "L", children: [
        .rect(Rect(x: 0, y: 0, width: 10, height: 10)),
        .rect(Rect(x: 20, y: 0, width: 10, height: 10)),
    ])
    return Document(layers: [layer], selection: [
        ElementSelection.all([0]),
        ElementSelection.all([0, 0]),
        ElementSelection.all([0, 1]),
    ])
}

@Test func togglingElementLockLocksAndPrunesTheSelection() {
    let doc = lockToggleDoc()
    #expect(doc.selection.count == 3)   // control: everything starts selected
    let out = doc.togglingElementLock(at: [0])
    #expect(out.getElement([0]).isLocked)
    #expect(out.selection.isEmpty)
}

/// Locking a CHILD must prune that child only -- if the prune were written
/// as a whole-clear, or matched on the wrong end of the path, this is the
/// case that notices.
@Test func togglingElementLockPrunesOnlyTheLockedSubtree() {
    let out = lockToggleDoc().togglingElementLock(at: [0, 0])
    #expect(out.selectedPaths == [[0], [0, 1]])
}

/// UNlocking must not touch the selection at all -- the prune is keyed on
/// the direction of the toggle, not on the button being pressed.
@Test func togglingElementLockUnlockLeavesTheSelectionAlone() {
    let locked = lockToggleDoc().togglingElementLock(at: [0])
    #expect(locked.selection.isEmpty)
    let reselected = locked.replacing(selection: [ElementSelection.all([0])])
    let out = reselected.togglingElementLock(at: [0], savedToRestore: [false, false])
    #expect(!out.getElement([0]).isLocked)
    #expect(out.selection.count == 1)
}
