import Testing
@testable import JasLib

/// Helper: create a Selection from element paths.
private func sel(_ paths: ElementPath...) -> Selection {
    Set(paths.map { ElementSelection(path: $0) })
}

/// Helper: create a Selection with each path selected as a whole.
private func selAllCPs(_ doc: Document, _ paths: ElementPath...) -> Selection {
    Set(paths.map { p in
        let _ = doc.getElement(p)
        return ElementSelection.all(p)
    })
}

/// Helper: extract the set of paths from a Selection.
private func selPaths(_ selection: Selection) -> Set<ElementPath> {
    Set(selection.map(\.path))
}

@Test func controllerDefaultDocument() {
    let ctrl = Controller()
    #expect(ctrl.model.filename.hasPrefix("Untitled-"))
    #expect(ctrl.document.layers.count == 1)
}

@Test func controllerInitialFilename() {
    let model = Model(filename: "Test")
    let ctrl = Controller(model: model)
    #expect(ctrl.model.filename == "Test")
}

@Test func controllerSetFilename() {
    let ctrl = Controller()
    ctrl.setFilename("New Name")
    #expect(ctrl.model.filename == "New Name")
}

@Test func controllerAddLayer() {
    let ctrl = Controller()
    let layer = Layer(name: "L1", children: [.rect(Rect(x: 0, y: 0, width: 10, height: 10))])
    ctrl.addLayer(layer)
    #expect(ctrl.document.layers.count == 2)
    #expect(ctrl.document.layers[1].name == "L1")
}

@Test func controllerRemoveLayer() {
    let l1 = Layer(name: "A", children: [])
    let l2 = Layer(name: "B", children: [])
    let model = Model(document: Document(layers: [l1, l2]))
    let ctrl = Controller(model: model)
    ctrl.removeLayer(at: 0)
    #expect(ctrl.document.layers.count == 1)
    #expect(ctrl.document.layers[0].name == "B")
}

@Test func controllerSetDocument() {
    let ctrl = Controller()
    ctrl.setDocument(Document(layers: []))
    #expect(ctrl.document.layers.count == 0)
}

@Test func controllerSetDocumentNotifiesModel() {
    let model = Model()
    let ctrl = Controller(model: model)
    var received: [Int] = []
    model.onDocumentChanged { doc in received.append(doc.layers.count) }
    ctrl.setDocument(Document(layers: []))
    #expect(received == [0])
}

// MARK: - Selection controller tests

private func makeSelectionCtrl() -> Controller {
    let rect = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let line1 = Element.line(Line(x1: 0, y1: 0, x2: 5, y2: 5))
    let line2 = Element.line(Line(x1: 1, y1: 1, x2: 2, y2: 2))
    let group = Element.group(Group(children: [line1, line2]))
    let layer = Layer(name: "L0", children: [rect, group])
    let doc = Document(layers: [layer])
    return Controller(model: Model(document: doc))
}

@Test func controllerSetSelection() {
    let ctrl = makeSelectionCtrl()
    let s = sel([0, 0])
    ctrl.setSelection(s)
    #expect(selPaths(ctrl.document.selection) == [[0, 0]])
}

@Test func controllerSetSelectionClears() {
    let ctrl = makeSelectionCtrl()
    ctrl.setSelection(sel([0, 0]))
    ctrl.setSelection([])
    #expect(ctrl.document.selection.isEmpty)
}

@Test func controllerSelectElementDirectChild() {
    let ctrl = makeSelectionCtrl()
    ctrl.selectElement([0, 0])
    #expect(selPaths(ctrl.document.selection) == [[0, 0]])
}

@Test func controllerSelectElementInGroup() {
    let ctrl = makeSelectionCtrl()
    ctrl.selectElement([0, 1, 0])
    #expect(selPaths(ctrl.document.selection) == [[0, 1], [0, 1, 0], [0, 1, 1]])
}

@Test func controllerSelectElementInGroupOtherChild() {
    let ctrl = makeSelectionCtrl()
    ctrl.selectElement([0, 1, 1])
    #expect(selPaths(ctrl.document.selection) == [[0, 1], [0, 1, 0], [0, 1, 1]])
}

@Test func controllerSelectElementNotifies() {
    let ctrl = makeSelectionCtrl()
    var count = 0
    ctrl.model.onDocumentChanged { _ in count += 1 }
    ctrl.selectElement([0, 0])
    #expect(count == 1)
}

@Test func controllerSelectElementLayerPath() {
    let ctrl = makeSelectionCtrl()
    ctrl.selectElement([0])
    #expect(selPaths(ctrl.document.selection) == [[0]])
}

// MARK: - Marquee selection tests

private func makeMarqueeCtrl() -> Controller {
    let rectFar = Element.rect(Rect(x: 100, y: 100, width: 10, height: 10))
    let line1 = Element.line(Line(x1: 0, y1: 0, x2: 5, y2: 5))
    let line2 = Element.line(Line(x1: 1, y1: 1, x2: 2, y2: 2))
    let group = Element.group(Group(children: [line1, line2]))
    let layer = Layer(name: "L0", children: [rectFar, group])
    return Controller(model: Model(document: Document(layers: [layer])))
}

@Test func selectRectHitsElement() {
    let ctrl = makeMarqueeCtrl()
    ctrl.selectRect(x: 99, y: 99, width: 12, height: 12)
    #expect(selPaths(ctrl.document.selection).contains([0, 0]))
}

@Test func selectRectMissesAll() {
    let ctrl = makeMarqueeCtrl()
    ctrl.selectRect(x: 200, y: 200, width: 10, height: 10)
    #expect(ctrl.document.selection.isEmpty)
}

@Test func selectRectGroupExpansion() {
    let ctrl = makeMarqueeCtrl()
    ctrl.selectRect(x: -1, y: -1, width: 7, height: 7)
    #expect(selPaths(ctrl.document.selection) == [[0, 1], [0, 1, 0], [0, 1, 1]])
}

@Test func selectRectReplacesPrevious() {
    let ctrl = makeMarqueeCtrl()
    ctrl.setSelection(sel([0, 0]))
    ctrl.selectRect(x: 200, y: 200, width: 10, height: 10)
    #expect(ctrl.document.selection.isEmpty)
}

@Test func selectRectMultipleElements() {
    let ctrl = makeMarqueeCtrl()
    ctrl.selectRect(x: -1, y: -1, width: 120, height: 120)
    let paths = selPaths(ctrl.document.selection)
    #expect(paths.contains([0, 0]))
    #expect(paths.contains([0, 1, 0]))
    #expect(paths.contains([0, 1, 1]))
}

// MARK: - Precise geometric hit-testing tests

@Test func selectRectMissesDiagonalLineCorner() {
    let line = Element.line(Line(x1: 0, y1: 0, x2: 100, y2: 100))
    let layer = Layer(name: "L0", children: [line])
    let ctrl = Controller(model: Model(document: Document(layers: [layer])))
    ctrl.selectRect(x: 80, y: 0, width: 20, height: 20)
    #expect(ctrl.document.selection.isEmpty)
}

@Test func selectRectHitsDiagonalLine() {
    let line = Element.line(Line(x1: 0, y1: 0, x2: 100, y2: 100))
    let layer = Layer(name: "L0", children: [line])
    let ctrl = Controller(model: Model(document: Document(layers: [layer])))
    ctrl.selectRect(x: 40, y: 40, width: 20, height: 20)
    #expect(selPaths(ctrl.document.selection).contains([0, 0]))
}

@Test func selectRectStrokeOnlyRectInteriorMisses() {
    let r = Element.rect(Rect(x: 0, y: 0, width: 100, height: 100))
    let layer = Layer(name: "L0", children: [r])
    let ctrl = Controller(model: Model(document: Document(layers: [layer])))
    ctrl.selectRect(x: 30, y: 30, width: 10, height: 10)
    #expect(ctrl.document.selection.isEmpty)
}

@Test func selectRectFilledRectInteriorHits() {
    let r = Element.rect(Rect(x: 0, y: 0, width: 100, height: 100,
                                  fill: Fill(color: Color(r: 1, g: 0, b: 0))))
    let layer = Layer(name: "L0", children: [r])
    let ctrl = Controller(model: Model(document: Document(layers: [layer])))
    ctrl.selectRect(x: 30, y: 30, width: 10, height: 10)
    #expect(selPaths(ctrl.document.selection).contains([0, 0]))
}

// MARK: - Control point selection tests

@Test func selectControlPoint() {
    let line = Element.line(Line(x1: 10, y1: 20, x2: 50, y2: 60))
    let layer = Layer(name: "L0", children: [line])
    let ctrl = Controller(model: Model(document: Document(layers: [layer])))
    ctrl.selectControlPoint(path: [0, 0], index: 1)
    #expect(ctrl.document.selection.count == 1)
    let es = ctrl.document.selection.first!
    #expect(es.path == [0, 0])
    #expect(es.kind == .partial(SortedCps([1])))
}

@Test func defaultElementSelectionFlags() {
    let ctrl = makeSelectionCtrl()
    ctrl.selectElement([0, 0])
    let es = ctrl.document.selection.first!
    // selectElement marks the element as a whole.
    #expect(es.kind == .all)
}

// MARK: - Direct selection tests

@Test func directSelectRectNoGroupExpansion() {
    let line1 = Element.line(Line(x1: 0, y1: 0, x2: 5, y2: 5))
    let line2 = Element.line(Line(x1: 50, y1: 50, x2: 55, y2: 55))
    let group = Element.group(Group(children: [line1, line2]))
    let layer = Layer(name: "L0", children: [group])
    let ctrl = Controller(model: Model(document: Document(layers: [layer])))
    ctrl.directSelectRect(x: -1, y: -1, width: 7, height: 7)
    let paths = selPaths(ctrl.document.selection)
    #expect(paths.contains([0, 0, 0]))
    #expect(!paths.contains([0, 0, 1]))
}

@Test func directSelectRectSelectsOnlyHitCPs() {
    let r = Element.rect(Rect(x: 0, y: 0, width: 100, height: 100))
    let layer = Layer(name: "L0", children: [r])
    let ctrl = Controller(model: Model(document: Document(layers: [layer])))
    ctrl.directSelectRect(x: -5, y: -5, width: 10, height: 10)
    #expect(ctrl.document.selection.count == 1)
    let es = ctrl.document.selection.first!
    #expect(es.path == [0, 0])
    #expect(es.kind == .partial(SortedCps([0])))
}

@Test func directSelectRectBodyOnlyYieldsPartialEmpty() {
    // The marquee covers the line's body (it crosses through
    // (40,40)–(60,60)) but neither endpoint is inside. The Direct
    // Selection tool must not promote "body intersects" to "every CP
    // selected" (which is what `.all` would mean) — the element is
    // selected with an empty CP set instead.
    let line = Element.line(Line(x1: 0, y1: 0, x2: 100, y2: 100))
    let layer = Layer(name: "L0", children: [line])
    let ctrl = Controller(model: Model(document: Document(layers: [layer])))
    ctrl.directSelectRect(x: 40, y: 40, width: 20, height: 20)
    #expect(ctrl.document.selection.count == 1)
    let es = ctrl.document.selection.first!
    #expect(es.kind == .partial(SortedCps([])))
}

@Test func directSelectRectMissesElement() {
    let r = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let layer = Layer(name: "L0", children: [r])
    let ctrl = Controller(model: Model(document: Document(layers: [layer])))
    ctrl.directSelectRect(x: 200, y: 200, width: 10, height: 10)
    #expect(ctrl.document.selection.isEmpty)
}

@Test func moveControlPointsPartialEmptyIsNoop() {
    // `moveControlPoints` on a Rect with `.partial([])` must return
    // the element unchanged — no position change and critically no
    // primitive-type change. Prior to the guard, the Rect would
    // fall through to the polygon-conversion branch (since
    // `isAll(4)` is false for an empty set) and be silently
    // converted to a Polygon at its original coordinates.
    let rect = Element.rect(Rect(x: 1, y: 2, width: 10, height: 20))
    let moved = rect.moveControlPoints(.partial(SortedCps([])), dx: 5, dy: 7)
    #expect(moved == rect)
    if case .rect = moved {} else {
        Issue.record("expected rect to stay a Rect, got \(moved)")
    }
}

// MARK: - Visibility / Hide / Show All

@Test func visibilityOrderingInvisibleLessOutlineLessPreview() {
    #expect(Visibility.invisible < Visibility.outline)
    #expect(Visibility.outline < Visibility.preview)
    #expect(min(Visibility.preview, Visibility.outline) == .outline)
    #expect(min(Visibility.outline, Visibility.invisible) == .invisible)
}

@Test func hideSelectionSetsInvisibleAndClearsSelection() {
    let r = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let layer = Layer(name: "L0", children: [r])
    let ctrl = Controller(model: Model(document: Document(layers: [layer])))
    ctrl.selectElement([0, 0])
    ctrl.hideSelection()
    #expect(ctrl.document.selection.isEmpty)
    #expect(ctrl.document.getElement([0, 0]).visibility == .invisible)
}

@Test func hiddenElementNotSelectableViaRect() {
    let r = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let layer = Layer(name: "L0", children: [r])
    let ctrl = Controller(model: Model(document: Document(layers: [layer])))
    ctrl.selectElement([0, 0])
    ctrl.hideSelection()
    ctrl.selectRect(x: -1, y: -1, width: 12, height: 12)
    let paths = selPaths(ctrl.document.selection)
    #expect(!paths.contains([0, 0]))
}

@Test func hiddenElementNotSelectableViaSelectElement() {
    let r = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let layer = Layer(name: "L0", children: [r])
    let ctrl = Controller(model: Model(document: Document(layers: [layer])))
    ctrl.selectElement([0, 0])
    ctrl.hideSelection()
    ctrl.selectElement([0, 0])
    #expect(ctrl.document.selection.isEmpty)
}

@Test func invisibleGroupCapsChildren() {
    let r = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let g = Element.group(Group(children: [r]))
    let layer = Layer(name: "L0", children: [g])
    let ctrl = Controller(model: Model(document: Document(layers: [layer])))
    ctrl.selectElement([0, 0])
    ctrl.hideSelection()
    let doc = ctrl.document
    // Group itself is Invisible
    #expect(doc.getElement([0, 0]).visibility == .invisible)
    // Child's own flag is unchanged
    #expect(doc.getElement([0, 0, 0]).visibility == .preview)
    // But effective visibility of child is Invisible
    #expect(doc.effectiveVisibility([0, 0, 0]) == .invisible)
}

@Test func showAllResetsAndSelectsNewlyShown() {
    let r1 = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let r2 = Element.rect(Rect(x: 50, y: 50, width: 10, height: 10))
    let layer = Layer(name: "L0", children: [r1, r2])
    let ctrl = Controller(model: Model(document: Document(layers: [layer])))
    ctrl.setSelection([
        ElementSelection.all([0, 0]),
        ElementSelection.all([0, 1]),
    ])
    ctrl.hideSelection()
    ctrl.showAll()
    let doc = ctrl.document
    #expect(doc.getElement([0, 0]).visibility == .preview)
    #expect(doc.getElement([0, 1]).visibility == .preview)
    let paths = selPaths(doc.selection)
    #expect(paths.contains([0, 0]))
    #expect(paths.contains([0, 1]))
    #expect(paths.count == 2)
}

@Test func showAllNothingHiddenLeavesEmptySelection() {
    let r = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let layer = Layer(name: "L0", children: [r])
    let ctrl = Controller(model: Model(document: Document(layers: [layer])))
    ctrl.showAll()
    #expect(ctrl.document.selection.isEmpty)
}

// MARK: - Group selection tests

@Test func groupSelectRectNoGroupExpansion() {
    let line1 = Element.line(Line(x1: 0, y1: 0, x2: 5, y2: 5))
    let line2 = Element.line(Line(x1: 50, y1: 50, x2: 55, y2: 55))
    let group = Element.group(Group(children: [line1, line2]))
    let layer = Layer(name: "L0", children: [group])
    let ctrl = Controller(model: Model(document: Document(layers: [layer])))
    ctrl.groupSelectRect(x: -1, y: -1, width: 7, height: 7)
    let paths = selPaths(ctrl.document.selection)
    #expect(paths.contains([0, 0, 0]))
    #expect(!paths.contains([0, 0, 1]))
}

@Test func groupSelectRectSelectsAllCPs() {
    let r = Element.rect(Rect(x: 0, y: 0, width: 100, height: 100))
    let layer = Layer(name: "L0", children: [r])
    let ctrl = Controller(model: Model(document: Document(layers: [layer])))
    ctrl.groupSelectRect(x: -5, y: -5, width: 10, height: 10)
    #expect(ctrl.document.selection.count == 1)
    let es = ctrl.document.selection.first!
    #expect(es.kind == .all)
}

@Test func groupSelectRectMissesElement() {
    let r = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let layer = Layer(name: "L0", children: [r])
    let ctrl = Controller(model: Model(document: Document(layers: [layer])))
    ctrl.groupSelectRect(x: 200, y: 200, width: 10, height: 10)
    #expect(ctrl.document.selection.isEmpty)
}

// MARK: - Extend (shift-toggle) selection tests

@Test func extendAddsNewElement() {
    let r1 = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let r2 = Element.rect(Rect(x: 50, y: 50, width: 10, height: 10))
    let layer = Layer(name: "L0", children: [r1, r2])
    let ctrl = Controller(model: Model(document: Document(layers: [layer])))
    ctrl.selectRect(x: -1, y: -1, width: 12, height: 12)
    #expect(selPaths(ctrl.document.selection) == [[0, 0]])
    ctrl.selectRect(x: 49, y: 49, width: 12, height: 12, extend: true)
    #expect(selPaths(ctrl.document.selection) == [[0, 0], [0, 1]])
}

@Test func extendRemovesExistingElement() {
    let r1 = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let r2 = Element.rect(Rect(x: 50, y: 50, width: 10, height: 10))
    let layer = Layer(name: "L0", children: [r1, r2])
    let ctrl = Controller(model: Model(document: Document(layers: [layer])))
    ctrl.selectRect(x: -1, y: -1, width: 70, height: 70)
    #expect(selPaths(ctrl.document.selection) == [[0, 0], [0, 1]])
    ctrl.selectRect(x: -1, y: -1, width: 12, height: 12, extend: true)
    #expect(selPaths(ctrl.document.selection) == [[0, 1]])
}

@Test func extendDirectSelect() {
    let l1 = Element.line(Line(x1: 0, y1: 0, x2: 5, y2: 5))
    let l2 = Element.line(Line(x1: 50, y1: 50, x2: 55, y2: 55))
    let layer = Layer(name: "L0", children: [l1, l2])
    let ctrl = Controller(model: Model(document: Document(layers: [layer])))
    ctrl.directSelectRect(x: -1, y: -1, width: 7, height: 7)
    #expect(selPaths(ctrl.document.selection) == [[0, 0]])
    ctrl.directSelectRect(x: 49, y: 49, width: 7, height: 7, extend: true)
    #expect(selPaths(ctrl.document.selection) == [[0, 0], [0, 1]])
}

@Test func extendDirectSelectTogglesCPs() {
    // Rect at (0,0) size 10x10 — CPs at (0,0), (10,0), (10,10), (0,10)
    let r = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let layer = Layer(name: "L0", children: [r])
    let ctrl = Controller(model: Model(document: Document(layers: [layer])))
    // Direct select top-left corner CP 0 at (0,0)
    ctrl.directSelectRect(x: -1, y: -1, width: 2, height: 2)
    let sel0 = ctrl.document.selection.first { $0.path == [0, 0] }!
    #expect(sel0.kind == .partial(SortedCps([0])))
    // Shift-direct-select top-right corner CP 1 at (10,0) — should add CP
    ctrl.directSelectRect(x: 9, y: -1, width: 2, height: 2, extend: true)
    let sel1 = ctrl.document.selection.first { $0.path == [0, 0] }!
    #expect(sel1.kind == .partial(SortedCps([0, 1])))
    // Shift-direct-select top-left again — should remove CP 0, keep CP 1
    ctrl.directSelectRect(x: -1, y: -1, width: 2, height: 2, extend: true)
    let sel2 = ctrl.document.selection.first { $0.path == [0, 0] }!
    #expect(sel2.kind == .partial(SortedCps([1])))
}

@Test func extendGroupSelect() {
    let r1 = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let r2 = Element.rect(Rect(x: 50, y: 50, width: 10, height: 10))
    let layer = Layer(name: "L0", children: [r1, r2])
    let ctrl = Controller(model: Model(document: Document(layers: [layer])))
    ctrl.groupSelectRect(x: -1, y: -1, width: 12, height: 12)
    #expect(selPaths(ctrl.document.selection) == [[0, 0]])
    ctrl.groupSelectRect(x: 49, y: 49, width: 12, height: 12, extend: true)
    #expect(selPaths(ctrl.document.selection) == [[0, 0], [0, 1]])
}

// MARK: - Control point positions tests

@Test func lineControlPointPositions() {
    let line = Element.line(Line(x1: 10, y1: 20, x2: 30, y2: 40))
    let cps = line.controlPointPositions
    #expect(cps.count == 2)
    #expect(cps[0] == (10, 20))
    #expect(cps[1] == (30, 40))
}

@Test func rectControlPointPositions() {
    let r = Element.rect(Rect(x: 5, y: 10, width: 20, height: 30))
    let cps = r.controlPointPositions
    #expect(cps.count == 4)
    #expect(cps[0] == (5, 10))
    #expect(cps[1] == (25, 10))
    #expect(cps[2] == (25, 40))
    #expect(cps[3] == (5, 40))
}

@Test func circleControlPointPositions() {
    let c = Element.circle(Circle(cx: 50, cy: 50, r: 10))
    let cps = c.controlPointPositions
    #expect(cps.count == 4)
    #expect(cps[0] == (50, 40))
    #expect(cps[1] == (60, 50))
    #expect(cps[2] == (50, 60))
    #expect(cps[3] == (40, 50))
}

@Test func ellipseControlPointPositions() {
    let e = Element.ellipse(Ellipse(cx: 50, cy: 50, rx: 20, ry: 10))
    let cps = e.controlPointPositions
    #expect(cps.count == 4)
    #expect(cps[0] == (50, 40))
    #expect(cps[1] == (70, 50))
    #expect(cps[2] == (50, 60))
    #expect(cps[3] == (30, 50))
}

// MARK: - Move control points tests

@Test func moveLineBothCPs() {
    let line = Element.line(Line(x1: 10, y1: 20, x2: 30, y2: 40))
    let moved = line.moveControlPoints(.all, dx: 5, dy: -3)
    if case .line(let v) = moved {
        #expect(v.x1 == 15); #expect(v.y1 == 17)
        #expect(v.x2 == 35); #expect(v.y2 == 37)
    } else { Issue.record("Expected line") }
}

@Test func moveLineOneCP() {
    let line = Element.line(Line(x1: 0, y1: 0, x2: 10, y2: 10))
    let moved = line.moveControlPoints(.partial(SortedCps([1])), dx: 5, dy: 5)
    if case .line(let v) = moved {
        #expect(v.x1 == 0); #expect(v.y1 == 0)
        #expect(v.x2 == 15); #expect(v.y2 == 15)
    } else { Issue.record("Expected line") }
}

@Test func moveRectAllCPs() {
    let rect = Element.rect(Rect(x: 10, y: 20, width: 30, height: 40))
    let moved = rect.moveControlPoints(.all, dx: 5, dy: -5)
    if case .rect(let v) = moved {
        #expect(v.x == 15); #expect(v.y == 15)
        #expect(v.width == 30); #expect(v.height == 40)
    } else { Issue.record("Expected rect") }
}

@Test func moveRectOneCorner() {
    let rect = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let moved = rect.moveControlPoints(.partial(SortedCps([2])), dx: 5, dy: 5)
    if case .polygon(let v) = moved {
        #expect(v.points.count == 4)
        #expect(v.points[0] == (0, 0))
        #expect(v.points[1] == (10, 0))
        #expect(v.points[2] == (15, 15))
        #expect(v.points[3] == (0, 10))
    } else { Issue.record("Expected polygon") }
}

@Test func moveCircleAllCPs() {
    let circle = Element.circle(Circle(cx: 50, cy: 50, r: 10))
    let moved = circle.moveControlPoints(.all, dx: 10, dy: -10)
    if case .circle(let v) = moved {
        #expect(v.cx == 60); #expect(v.cy == 40); #expect(v.r == 10)
    } else { Issue.record("Expected circle") }
}

@Test func moveEllipseAllCPs() {
    let ellipse = Element.ellipse(Ellipse(cx: 50, cy: 50, rx: 20, ry: 10))
    let moved = ellipse.moveControlPoints(.all, dx: -5, dy: 5)
    if case .ellipse(let v) = moved {
        #expect(v.cx == 45); #expect(v.cy == 55)
        #expect(v.rx == 20); #expect(v.ry == 10)
    } else { Issue.record("Expected ellipse") }
}

// MARK: - Move selection tests

@Test func moveSelectedLine() {
    let line = Element.line(Line(x1: 10, y1: 20, x2: 30, y2: 40))
    let layer = Layer(children: [line])
    let doc = Document(layers: [layer],
                          selection: [ElementSelection.all([0, 0])])
    let ctrl = Controller(model: Model(document: doc))
    ctrl.moveSelection(dx: 5, dy: -3)
    if case .line(let v) = ctrl.document.layers[0].children[0] {
        #expect(v.x1 == 15); #expect(v.y1 == 17)
        #expect(v.x2 == 35); #expect(v.y2 == 37)
    } else { Issue.record("Expected line") }
}

@Test func moveSelectedRect() {
    let rect = Element.rect(Rect(x: 0, y: 0, width: 20, height: 10))
    let layer = Layer(children: [rect])
    let doc = Document(layers: [layer],
                          selection: [ElementSelection.all([0, 0])])
    let ctrl = Controller(model: Model(document: doc))
    ctrl.moveSelection(dx: 10, dy: 10)
    if case .rect(let v) = ctrl.document.layers[0].children[0] {
        #expect(v.x == 10); #expect(v.y == 10)
        #expect(v.width == 20); #expect(v.height == 10)
    } else { Issue.record("Expected rect") }
}

@Test func movePartialCPs() {
    let line = Element.line(Line(x1: 0, y1: 0, x2: 10, y2: 10))
    let layer = Layer(children: [line])
    let doc = Document(layers: [layer],
                          selection: [ElementSelection.partial([0, 0], [0])])
    let ctrl = Controller(model: Model(document: doc))
    ctrl.moveSelection(dx: 5, dy: 5)
    if case .line(let v) = ctrl.document.layers[0].children[0] {
        #expect(v.x1 == 5); #expect(v.y1 == 5)
        #expect(v.x2 == 10); #expect(v.y2 == 10)
    } else { Issue.record("Expected line") }
}

@Test func moveMultipleElements() {
    let line = Element.line(Line(x1: 0, y1: 0, x2: 10, y2: 10))
    let rect = Element.rect(Rect(x: 20, y: 20, width: 10, height: 10))
    let layer = Layer(children: [line, rect])
    let doc = Document(layers: [layer],
                          selection: [
                              ElementSelection.all([0, 0]),
                              ElementSelection.all([0, 1]),
                          ])
    let ctrl = Controller(model: Model(document: doc))
    ctrl.moveSelection(dx: 3, dy: 4)
    if case .line(let v) = ctrl.document.layers[0].children[0] {
        #expect(v.x1 == 3); #expect(v.y1 == 4)
        #expect(v.x2 == 13); #expect(v.y2 == 14)
    } else { Issue.record("Expected line") }
    if case .rect(let v) = ctrl.document.layers[0].children[1] {
        #expect(v.x == 23); #expect(v.y == 24)
    } else { Issue.record("Expected rect") }
}

// MARK: - Copy selection tests

@Test func copySelectionDuplicatesElement() {
    let rect = Element.rect(Rect(x: 10, y: 20, width: 30, height: 40))
    let layer = Layer(name: "L0", children: [rect])
    let baseDoc = Document(layers: [layer])
    let doc = Document(layers: baseDoc.layers,
                          selection: selAllCPs(baseDoc, [0, 0]))
    let ctrl = Controller(model: Model(document: doc))
    ctrl.copySelection(dx: 5, dy: 5)
    #expect(ctrl.document.layers[0].children.count == 2)
    if case .rect(let orig) = ctrl.document.layers[0].children[0] {
        #expect(orig.x == 10); #expect(orig.y == 20)
    } else { Issue.record("Expected rect") }
    if case .rect(let copy) = ctrl.document.layers[0].children[1] {
        #expect(copy.x == 15); #expect(copy.y == 25)
    } else { Issue.record("Expected rect") }
}

@Test func copySelectionUpdatesSelectionToCopy() {
    let rect = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let layer = Layer(name: "L0", children: [rect])
    let baseDoc = Document(layers: [layer])
    let doc = Document(layers: baseDoc.layers,
                          selection: selAllCPs(baseDoc, [0, 0]))
    let ctrl = Controller(model: Model(document: doc))
    ctrl.copySelection(dx: 1, dy: 1)
    let paths = selPaths(ctrl.document.selection)
    #expect(paths.contains([0, 1]))
    #expect(!paths.contains([0, 0]))
}

// MARK: - Delete selection with nested groups

@Test func deleteSelectionSimple() {
    let rect = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let circle = Element.circle(Circle(cx: 50, cy: 50, r: 5))
    let layer = Layer(name: "L0", children: [rect, circle])
    let doc = Document(layers: [layer],
                          selection: sel([0, 0]))
    let doc2 = doc.deleteSelection()
    #expect(doc2.layers[0].children.count == 1)
    if case .circle = doc2.layers[0].children[0] { } else { Issue.record("Expected circle") }
    #expect(doc2.selection.isEmpty)
}

@Test func deleteSelectionInGroup() {
    let line1 = Element.line(Line(x1: 0, y1: 0, x2: 1, y2: 1))
    let line2 = Element.line(Line(x1: 2, y1: 2, x2: 3, y2: 3))
    let group = Element.group(Group(children: [line1, line2]))
    let layer = Layer(name: "L0", children: [group])
    let doc = Document(layers: [layer],
                          selection: sel([0, 0, 0]))
    let doc2 = doc.deleteSelection()
    if case .group(let g) = doc2.layers[0].children[0] {
        #expect(g.children.count == 1)
        #expect(g.children[0] == line2)
    } else { Issue.record("Expected group") }
}

@Test func deleteSelectionNestedGroup() {
    let line = Element.line(Line(x1: 0, y1: 0, x2: 1, y2: 1))
    let rect = Element.rect(Rect(x: 0, y: 0, width: 5, height: 5))
    let inner = Element.group(Group(children: [line, rect]))
    let outer = Element.group(Group(children: [inner]))
    let layer = Layer(name: "L0", children: [outer])
    let doc = Document(layers: [layer],
                          selection: sel([0, 0, 0, 1]))
    let doc2 = doc.deleteSelection()
    if case .group(let og) = doc2.layers[0].children[0],
       case .group(let ig) = og.children[0] {
        #expect(ig.children.count == 1)
        #expect(ig.children[0] == line)
    } else { Issue.record("Expected nested groups") }
}

@Test func deleteMultipleFromSameGroup() {
    let l1 = Element.line(Line(x1: 0, y1: 0, x2: 1, y2: 1))
    let l2 = Element.line(Line(x1: 2, y1: 2, x2: 3, y2: 3))
    let l3 = Element.line(Line(x1: 4, y1: 4, x2: 5, y2: 5))
    let group = Element.group(Group(children: [l1, l2, l3]))
    let layer = Layer(name: "L0", children: [group])
    let doc = Document(layers: [layer],
                          selection: sel([0, 0, 0], [0, 0, 2]))
    let doc2 = doc.deleteSelection()
    if case .group(let g) = doc2.layers[0].children[0] {
        #expect(g.children.count == 1)
        #expect(g.children[0] == l2)
    } else { Issue.record("Expected group") }
}

// MARK: - Fill/Stroke controller tests

@Test func setSelectionFillUpdatesRect() {
    let rect = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let layer = Layer(name: "L0", children: [rect])
    let ctrl = Controller(model: Model(document: Document(layers: [layer])))
    ctrl.selectElement([0, 0])
    let fill = Fill(color: Color(r: 1, g: 0, b: 0))
    ctrl.setSelectionFill(fill)
    if case .rect(let r) = ctrl.document.getElement([0, 0]) {
        #expect(r.fill == fill)
    } else {
        Issue.record("Expected Rect element")
    }
}

@Test func setSelectionStrokeUpdatesLine() {
    let line = Element.line(Line(x1: 0, y1: 0, x2: 10, y2: 10))
    let layer = Layer(name: "L0", children: [line])
    let ctrl = Controller(model: Model(document: Document(layers: [layer])))
    ctrl.selectElement([0, 0])
    let stroke = Stroke(color: Color(r: 0, g: 1, b: 0), width: 3.0)
    ctrl.setSelectionStroke(stroke)
    if case .line(let l) = ctrl.document.getElement([0, 0]) {
        #expect(l.stroke == stroke)
    } else {
        Issue.record("Expected Line element")
    }
}

@Test func setSelectionFillNoSelectionIsNoop() {
    let rect = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let layer = Layer(name: "L0", children: [rect])
    let ctrl = Controller(model: Model(document: Document(layers: [layer])))
    let fill = Fill(color: Color(r: 1, g: 0, b: 0))
    ctrl.setSelectionFill(fill)
    if case .rect(let r) = ctrl.document.getElement([0, 0]) {
        #expect(r.fill == nil)
    } else {
        Issue.record("Expected Rect element")
    }
}

@Test func fillSummaryNoSelection() {
    let ctrl = Controller()
    let summary = selectionFillSummary(ctrl.document)
    #expect(summary == .noSelection)
}

@Test func fillSummaryUniform() {
    let fill = Fill(color: Color(r: 1, g: 0, b: 0))
    let r1 = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10, fill: fill))
    let r2 = Element.rect(Rect(x: 20, y: 20, width: 10, height: 10, fill: fill))
    let layer = Layer(name: "L0", children: [r1, r2])
    let doc = Document(layers: [layer], selection: [
        ElementSelection.all([0, 0]),
        ElementSelection.all([0, 1]),
    ])
    let summary = selectionFillSummary(doc)
    #expect(summary == .uniform(fill))
}

@Test func fillSummaryMixed() {
    let fill1 = Fill(color: Color(r: 1, g: 0, b: 0))
    let fill2 = Fill(color: Color(r: 0, g: 1, b: 0))
    let r1 = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10, fill: fill1))
    let r2 = Element.rect(Rect(x: 20, y: 20, width: 10, height: 10, fill: fill2))
    let layer = Layer(name: "L0", children: [r1, r2])
    let doc = Document(layers: [layer], selection: [
        ElementSelection.all([0, 0]),
        ElementSelection.all([0, 1]),
    ])
    let summary = selectionFillSummary(doc)
    #expect(summary == .mixed)
}

@Test func strokeSummaryNoSelection() {
    let ctrl = Controller()
    let summary = selectionStrokeSummary(ctrl.document)
    #expect(summary == .noSelection)
}

@Test func strokeSummaryUniform() {
    let stroke = Stroke(color: Color(r: 0, g: 0, b: 0), width: 2.0)
    let l1 = Element.line(Line(x1: 0, y1: 0, x2: 10, y2: 10, stroke: stroke))
    let l2 = Element.line(Line(x1: 20, y1: 20, x2: 30, y2: 30, stroke: stroke))
    let layer = Layer(name: "L0", children: [l1, l2])
    let doc = Document(layers: [layer], selection: [
        ElementSelection.all([0, 0]),
        ElementSelection.all([0, 1]),
    ])
    let summary = selectionStrokeSummary(doc)
    #expect(summary == .uniform(stroke))
}

// MARK: - Opacity mask lifecycle (Phase 3b)

private func setupTwoRectSelection() -> Controller {
    let r1 = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let r2 = Element.rect(Rect(x: 20, y: 0, width: 10, height: 10))
    let layer = Layer(name: "L0", children: [r1, r2])
    let doc = Document(layers: [layer], selection: [
        ElementSelection.all([0, 0]),
        ElementSelection.all([0, 1]),
    ])
    return Controller(model: Model(document: doc))
}

@Test func selectionHasMaskFalseForEmpty() {
    let ctrl = Controller()
    #expect(selectionHasMask(ctrl.document) == false)
}

@Test func selectionHasMaskFalseForUnmasked() {
    let ctrl = setupTwoRectSelection()
    #expect(selectionHasMask(ctrl.document) == false)
}

@Test func makeMaskCreatesMaskOnEverySelected() {
    let ctrl = setupTwoRectSelection()
    ctrl.makeMaskOnSelection(clip: true, invert: false)
    #expect(selectionHasMask(ctrl.document) == true)
    for es in ctrl.document.selection {
        let m = ctrl.document.getElement(es.path).mask
        #expect(m != nil)
        #expect(m?.clip == true)
        #expect(m?.invert == false)
        #expect(m?.disabled == false)
        #expect(m?.linked == true)
    }
}

@Test func makeMaskHonorsClipInvertArgs() {
    let ctrl = setupTwoRectSelection()
    ctrl.makeMaskOnSelection(clip: false, invert: true)
    guard let first = ctrl.document.selection.first else {
        Issue.record("expected a selection"); return
    }
    let m = ctrl.document.getElement(first.path).mask
    #expect(m?.clip == false)
    #expect(m?.invert == true)
}

@Test func makeMaskIsIdempotent() {
    let ctrl = setupTwoRectSelection()
    ctrl.makeMaskOnSelection(clip: true, invert: false)
    ctrl.setMaskInvertOnSelection(true)
    ctrl.makeMaskOnSelection(clip: true, invert: false)
    for es in ctrl.document.selection {
        let m = ctrl.document.getElement(es.path).mask
        #expect(m?.invert == true, "second make should not overwrite")
    }
}

@Test func releaseMaskClears() {
    let ctrl = setupTwoRectSelection()
    ctrl.makeMaskOnSelection(clip: true, invert: false)
    ctrl.releaseMaskOnSelection()
    #expect(selectionHasMask(ctrl.document) == false)
}

@Test func setMaskClipAndInvertPropagate() {
    let ctrl = setupTwoRectSelection()
    ctrl.makeMaskOnSelection(clip: true, invert: false)
    ctrl.setMaskClipOnSelection(false)
    ctrl.setMaskInvertOnSelection(true)
    for es in ctrl.document.selection {
        let m = ctrl.document.getElement(es.path).mask
        #expect(m?.clip == false)
        #expect(m?.invert == true)
    }
}

@Test func toggleMaskDisabledFlips() {
    let ctrl = setupTwoRectSelection()
    ctrl.makeMaskOnSelection(clip: true, invert: false)
    ctrl.toggleMaskDisabledOnSelection()
    for es in ctrl.document.selection {
        #expect(ctrl.document.getElement(es.path).mask?.disabled == true)
    }
    ctrl.toggleMaskDisabledOnSelection()
    for es in ctrl.document.selection {
        #expect(ctrl.document.getElement(es.path).mask?.disabled == false)
    }
}

@Test func toggleMaskLinkedFlipsAndCapturesTransform() {
    let ctrl = setupTwoRectSelection()
    ctrl.makeMaskOnSelection(clip: true, invert: false)
    ctrl.toggleMaskLinkedOnSelection()
    for es in ctrl.document.selection {
        let m = ctrl.document.getElement(es.path).mask
        #expect(m?.linked == false)
        #expect(m?.unlinkTransform == nil)  // Rects have no transform
    }
    ctrl.toggleMaskLinkedOnSelection()
    for es in ctrl.document.selection {
        let m = ctrl.document.getElement(es.path).mask
        #expect(m?.linked == true)
        #expect(m?.unlinkTransform == nil)
    }
}

@Test func firstMaskReturnsNilWhenFirstUnmasked() {
    let ctrl = setupTwoRectSelection()
    ctrl.makeMaskOnSelection(clip: true, invert: false)
    var doc = ctrl.document
    let firstPath = doc.selection.first!.path
    let elem = doc.getElement(firstPath)
    doc = doc.replaceElement(firstPath, with: withMask(elem, mask: nil))
    ctrl.model.document = doc
    #expect(firstMask(ctrl.document) == nil)
    #expect(selectionHasMask(ctrl.document) == false)
}
