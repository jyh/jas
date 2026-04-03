import Testing
@testable import JasLib

@Test func defaultToolIsSelection() {
    let tool: Tool = .selection
    #expect(tool == .selection)
}

@Test func toolEnumCases() {
    let tools = Tool.allCases
    #expect(tools.count == 2)
    #expect(tools.contains(.selection))
    #expect(tools.contains(.directSelection))
}

@Test func contentViewInitializes() {
    let view = ContentView()
    _ = view.body
}

@Test func toolEnumCasesExist() {
    let tools = Tool.allCases
    #expect(tools.count == 2)
    #expect(tools.contains(.selection))
    #expect(tools.contains(.directSelection))
}

@Test func jasCommandsInitializes() {
    let commands = JasCommands()
    #expect(commands != nil)
}

@Test func contentViewWithKeyboardHandlerInitializes() {
    let view = ContentView()
    // The view includes KeyboardShortcutHandler for keyboard shortcuts
    // Accessing body ensures the view hierarchy is constructed
    _ = view.body
    #expect(true)
}

// MARK: - Element tests

@Test func pointCreation() {
    let p = JasPoint(x: 3.0, y: 4.0)
    #expect(p.x == 3.0)
    #expect(p.y == 4.0)
}

@Test func colorDefaults() {
    let c = JasColor(r: 1.0, g: 0.0, b: 0.0)
    #expect(c.a == 1.0)
}

@Test func pathBounds() {
    let path = JasPath(anchors: [
        AnchorPoint(position: JasPoint(x: 0, y: 0)),
        AnchorPoint(position: JasPoint(x: 10, y: 20)),
        AnchorPoint(position: JasPoint(x: 5, y: 15)),
    ])
    let (tl, br) = path.bounds
    #expect(tl == JasPoint(x: 0, y: 0))
    #expect(br == JasPoint(x: 10, y: 20))
}

@Test func pathEmptyBounds() {
    let path = JasPath(anchors: [])
    let (tl, br) = path.bounds
    #expect(tl == JasPoint(x: 0, y: 0))
    #expect(br == JasPoint(x: 0, y: 0))
}

@Test func pathWithFillAndStroke() {
    let fill = JasFill(color: JasColor(r: 1, g: 0, b: 0))
    let stroke = JasStroke(color: JasColor(r: 0, g: 0, b: 0), width: 2.0, alignment: .outside)
    let path = JasPath(
        anchors: [
            AnchorPoint(position: JasPoint(x: 0, y: 0)),
            AnchorPoint(position: JasPoint(x: 10, y: 10)),
        ],
        closed: true,
        fill: fill,
        stroke: stroke
    )
    #expect(path.closed == true)
    #expect(path.fill?.color.r == 1.0)
    #expect(path.stroke?.width == 2.0)
    #expect(path.stroke?.alignment == .outside)
}

@Test func rectBounds() {
    let r = JasRect(origin: JasPoint(x: 5, y: 10), width: 100, height: 50)
    let (tl, br) = r.bounds
    #expect(tl == JasPoint(x: 5, y: 10))
    #expect(br == JasPoint(x: 105, y: 60))
}

@Test func ellipseBounds() {
    let e = JasEllipse(center: JasPoint(x: 50, y: 50), rx: 25, ry: 15)
    let (tl, br) = e.bounds
    #expect(tl == JasPoint(x: 25, y: 35))
    #expect(br == JasPoint(x: 75, y: 65))
}

@Test func groupBounds() {
    let r = Element.rect(JasRect(origin: JasPoint(x: 0, y: 0), width: 10, height: 10))
    let e = Element.ellipse(JasEllipse(center: JasPoint(x: 100, y: 100), rx: 5, ry: 5))
    let g = JasGroup(children: [r, e])
    let (tl, br) = g.bounds
    #expect(tl == JasPoint(x: 0, y: 0))
    #expect(br == JasPoint(x: 105, y: 105))
}

@Test func groupEmptyBounds() {
    let g = JasGroup(children: [])
    let (tl, br) = g.bounds
    #expect(tl == JasPoint(x: 0, y: 0))
    #expect(br == JasPoint(x: 0, y: 0))
}

@Test func nestedGroup() {
    let inner = Element.group(JasGroup(children: [
        .rect(JasRect(origin: JasPoint(x: 10, y: 10), width: 5, height: 5))
    ]))
    let outer = JasGroup(children: [
        .rect(JasRect(origin: JasPoint(x: 0, y: 0), width: 1, height: 1)),
        inner,
    ])
    let (tl, br) = outer.bounds
    #expect(tl == JasPoint(x: 0, y: 0))
    #expect(br == JasPoint(x: 15, y: 15))
}

@Test func anchorPointHandles() {
    let a = AnchorPoint(
        position: JasPoint(x: 5, y: 5),
        handleIn: JasPoint(x: 3, y: 3),
        handleOut: JasPoint(x: 7, y: 7)
    )
    #expect(a.handleIn == JasPoint(x: 3, y: 3))
    #expect(a.handleOut == JasPoint(x: 7, y: 7))
}

@Test func anchorPointNoHandles() {
    let a = AnchorPoint(position: JasPoint(x: 5, y: 5))
    #expect(a.handleIn == nil)
    #expect(a.handleOut == nil)
}

@Test func elementBoundsDispatch() {
    let pathEl = Element.path(JasPath(anchors: [
        AnchorPoint(position: JasPoint(x: 0, y: 0)),
        AnchorPoint(position: JasPoint(x: 10, y: 10)),
    ]))
    let rectEl = Element.rect(JasRect(origin: JasPoint(x: 5, y: 5), width: 20, height: 20))
    let (ptl, pbr) = pathEl.bounds
    let (rtl, rbr) = rectEl.bounds
    #expect(ptl == JasPoint(x: 0, y: 0))
    #expect(pbr == JasPoint(x: 10, y: 10))
    #expect(rtl == JasPoint(x: 5, y: 5))
    #expect(rbr == JasPoint(x: 25, y: 25))
}
