import Testing
@testable import JasLib

/// Helper: extract the set of paths from a Selection.
private func selPaths(_ selection: Selection) -> Set<ElementPath> {
    Set(selection.map(\.path))
}

/// Helper: create a controller with two sibling rects on one layer.
private func makeTwoRectCtrl() -> Controller {
    let r1 = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let r2 = Element.rect(Rect(x: 20, y: 20, width: 10, height: 10))
    let layer = Layer(name: "L0", children: [r1, r2])
    let doc = Document(layers: [layer])
    return Controller(model: Model(document: doc))
}

// MARK: - groupSelection tests

@Test func groupSelectionCreatesSingleGroup() {
    let ctrl = makeTwoRectCtrl()
    // Select both rects
    ctrl.setSelection([
        ElementSelection.all([0, 0]),
        ElementSelection.all([0, 1]),
    ])
    ctrl.groupSelection()
    let doc = ctrl.document
    // Layer should now have 1 child (the group)
    #expect(doc.layers[0].children.count == 1)
    // That child should be a group containing 2 children
    if case .group(let g) = doc.layers[0].children[0] {
        #expect(g.children.count == 2)
        // First child should be a rect at (0,0)
        if case .rect(let r) = g.children[0] {
            #expect(r.x == 0 && r.y == 0)
        } else {
            Issue.record("Expected rect as first group child")
        }
        // Second child should be a rect at (20,20)
        if case .rect(let r) = g.children[1] {
            #expect(r.x == 20 && r.y == 20)
        } else {
            Issue.record("Expected rect as second group child")
        }
    } else {
        Issue.record("Expected a group element")
    }
    // Selection should be the group path
    let paths = selPaths(doc.selection)
    #expect(paths.contains([0, 0]))
    #expect(paths.count == 1)
}

@Test func groupSelectionRequiresAtLeastTwo() {
    let ctrl = makeTwoRectCtrl()
    // Select only one rect -- grouping should be a no-op
    ctrl.setSelection([ElementSelection.all([0, 0])])
    ctrl.groupSelection()
    let doc = ctrl.document
    // Should still have 2 children (no group created)
    #expect(doc.layers[0].children.count == 2)
}

// MARK: - ungroupSelection tests

@Test func ungroupSelectionRestoresChildren() {
    let ctrl = makeTwoRectCtrl()
    // Group them first
    ctrl.setSelection([
        ElementSelection.all([0, 0]),
        ElementSelection.all([0, 1]),
    ])
    ctrl.groupSelection()
    // Now select the group and ungroup
    ctrl.setSelection([ElementSelection.all([0, 0])])
    ctrl.ungroupSelection()
    let doc = ctrl.document
    // Layer should have 2 children again (the original rects)
    #expect(doc.layers[0].children.count == 2)
    // Both should be rects
    if case .rect(let r1) = doc.layers[0].children[0] {
        #expect(r1.x == 0 && r1.y == 0)
    } else {
        Issue.record("Expected rect at index 0")
    }
    if case .rect(let r2) = doc.layers[0].children[1] {
        #expect(r2.x == 20 && r2.y == 20)
    } else {
        Issue.record("Expected rect at index 1")
    }
    // Selection should contain both child paths
    let paths = selPaths(doc.selection)
    #expect(paths.contains([0, 0]))
    #expect(paths.contains([0, 1]))
}

@Test func ungroupSelectionIgnoresNonGroup() {
    let ctrl = makeTwoRectCtrl()
    // Select a rect (not a group) and try to ungroup
    ctrl.setSelection([ElementSelection.all([0, 0])])
    ctrl.ungroupSelection()
    let doc = ctrl.document
    // Nothing should change
    #expect(doc.layers[0].children.count == 2)
}

// MARK: - lockSelection tests

@Test func lockSelectionLocksAndClearsSelection() {
    let ctrl = makeTwoRectCtrl()
    ctrl.setSelection([
        ElementSelection.all([0, 0]),
        ElementSelection.all([0, 1]),
    ])
    ctrl.lockSelection()
    let doc = ctrl.document
    // Both elements should now be locked
    #expect(doc.getElement([0, 0]).isLocked)
    #expect(doc.getElement([0, 1]).isLocked)
    // Selection should be cleared
    #expect(doc.selection.isEmpty)
}

@Test func lockSelectionLocksGroupRecursively() {
    let line1 = Element.line(Line(x1: 0, y1: 0, x2: 5, y2: 5))
    let line2 = Element.line(Line(x1: 10, y1: 10, x2: 15, y2: 15))
    let group = Element.group(Group(children: [line1, line2]))
    let layer = Layer(name: "L0", children: [group])
    let ctrl = Controller(model: Model(document: Document(layers: [layer])))
    ctrl.setSelection([ElementSelection.all([0, 0])])
    ctrl.lockSelection()
    let doc = ctrl.document
    // The group itself should be locked
    if case .group(let g) = doc.getElement([0, 0]) {
        #expect(g.locked)
    } else {
        Issue.record("Expected group")
    }
}

// MARK: - unlockAll tests

@Test func unlockAllUnlocksAndSelectsFormerlyLocked() {
    let ctrl = makeTwoRectCtrl()
    // Lock both
    ctrl.setSelection([
        ElementSelection.all([0, 0]),
        ElementSelection.all([0, 1]),
    ])
    ctrl.lockSelection()
    #expect(ctrl.document.getElement([0, 0]).isLocked)
    #expect(ctrl.document.getElement([0, 1]).isLocked)
    // Now unlock all
    ctrl.unlockAll()
    let doc = ctrl.document
    // Both should be unlocked
    #expect(!doc.getElement([0, 0]).isLocked)
    #expect(!doc.getElement([0, 1]).isLocked)
    // Selection should contain the formerly-locked paths
    let paths = selPaths(doc.selection)
    #expect(paths.contains([0, 0]))
    #expect(paths.contains([0, 1]))
}

@Test func unlockAllNothingLockedLeavesEmptySelection() {
    let ctrl = makeTwoRectCtrl()
    ctrl.unlockAll()
    #expect(ctrl.document.selection.isEmpty)
}

// MARK: - hideSelection tests

@Test func menuHideSelectionSetsInvisibleAndClears() {
    let ctrl = makeTwoRectCtrl()
    ctrl.setSelection([
        ElementSelection.all([0, 0]),
        ElementSelection.all([0, 1]),
    ])
    ctrl.hideSelection()
    let doc = ctrl.document
    // Both elements should be invisible
    #expect(doc.getElement([0, 0]).visibility == .invisible)
    #expect(doc.getElement([0, 1]).visibility == .invisible)
    // Selection should be cleared
    #expect(doc.selection.isEmpty)
}

@Test func hideSelectionSingleElement() {
    let ctrl = makeTwoRectCtrl()
    ctrl.setSelection([ElementSelection.all([0, 0])])
    ctrl.hideSelection()
    let doc = ctrl.document
    // First element invisible, second still preview
    #expect(doc.getElement([0, 0]).visibility == .invisible)
    #expect(doc.getElement([0, 1]).visibility == .preview)
}

// MARK: - showAll tests

@Test func showAllRestoresVisibilityAndSelects() {
    let ctrl = makeTwoRectCtrl()
    // Hide both
    ctrl.setSelection([
        ElementSelection.all([0, 0]),
        ElementSelection.all([0, 1]),
    ])
    ctrl.hideSelection()
    #expect(ctrl.document.getElement([0, 0]).visibility == .invisible)
    #expect(ctrl.document.getElement([0, 1]).visibility == .invisible)
    // Show all
    ctrl.showAll()
    let doc = ctrl.document
    // Both should be back to preview
    #expect(doc.getElement([0, 0]).visibility == .preview)
    #expect(doc.getElement([0, 1]).visibility == .preview)
    // Selection should contain the formerly-hidden paths
    let paths = selPaths(doc.selection)
    #expect(paths.contains([0, 0]))
    #expect(paths.contains([0, 1]))
}

@Test func menuShowAllNothingHiddenLeavesEmpty() {
    let ctrl = makeTwoRectCtrl()
    ctrl.showAll()
    #expect(ctrl.document.selection.isEmpty)
}

@Test func showAllPartialHide() {
    let ctrl = makeTwoRectCtrl()
    // Hide only first element
    ctrl.setSelection([ElementSelection.all([0, 0])])
    ctrl.hideSelection()
    // Show all
    ctrl.showAll()
    let doc = ctrl.document
    #expect(doc.getElement([0, 0]).visibility == .preview)
    #expect(doc.getElement([0, 1]).visibility == .preview)
    // Only the formerly-hidden element should be selected
    let paths = selPaths(doc.selection)
    #expect(paths.contains([0, 0]))
    #expect(!paths.contains([0, 1]))
}
