import Testing
import AppKit
@testable import JasLib

// Session-based TypeTool / TypeOnPathTool integration tests. Mirrors the
// OCaml `tool_interaction_test.ml` cases for type tool sessions.

private func makeCtx(_ model: Model = Model(),
                     hitTestText: @escaping (NSPoint) -> (ElementPath, Text)? = { _ in nil },
                     hitTestPathCurve: @escaping (Double, Double) -> (ElementPath, Element)? = { _, _ in nil })
                     -> (ToolContext, Model, Controller) {
    let ctrl = Controller(model: model)
    let ctx = ToolContext(
        model: model,
        controller: ctrl,
        hitTestSelection: { _ in false },
        hitTestHandle: { _ in nil },
        hitTestText: hitTestText,
        hitTestPathCurve: hitTestPathCurve,
        requestUpdate: {},
        startTextEdit: { _, _ in },
        commitTextEdit: {},
        drawElementOverlay: { _, _, _ in }
    )
    return (ctx, model, ctrl)
}

// MARK: - TypeTool session tests

@Test func typeToolDragCreatesEmptyAreaTextAndSession() {
    let tool = TypeTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onMove(ctx, x: 110, y: 70, shift: false, dragging: true)
    tool.onRelease(ctx, x: 110, y: 70, shift: false, alt: false)
    let children = model.document.layers[0].children
    #expect(children.count == 1)
    if case .text(let t) = children[0] {
        #expect(t.content == "")
        #expect(t.width == 100)
        #expect(t.height == 50)
    } else {
        Issue.record("Expected empty area text element")
    }
    #expect(tool.isEditing())
}

@Test func typeToolClickCreatesEmptyPointTextAndSession() {
    let tool = TypeTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 30, y: 40, shift: false, alt: false)
    tool.onRelease(ctx, x: 31, y: 41, shift: false, alt: false)
    let children = model.document.layers[0].children
    #expect(children.count == 1)
    if case .text(let t) = children[0] {
        #expect(t.content == "")
    } else {
        Issue.record("Expected text element")
    }
    #expect(tool.isEditing())
}

@Test func typeToolClickOnExistingTextStartsSession() {
    // Seed a Text element. Point text uses (x, y) as the baseline, so the
    // visible bbox is (0, -16, ~27, 16). Click within that box.
    let existing = Text(x: 0, y: 16, content: "hello",
                        fill: Fill(color: Color(r: 0, g: 0, b: 0)))
    let layer = Layer(name: "L", children: [.text(existing)])
    let model = Model()
    model.document = Document(layers: [layer])
    let (ctx, _, _) = makeCtx(model, hitTestText: { _ in ([0, 0], existing) })
    let tool = TypeTool()
    tool.onPress(ctx, x: 5, y: 5, shift: false, alt: false)
    tool.onRelease(ctx, x: 5, y: 5, shift: false, alt: false)
    #expect(tool.isEditing())
    #expect(tool.currentSession?.content == "hello")
}

@Test func typeToolTypingIntoSessionUpdatesModel() {
    let tool = TypeTool()
    let (ctx, model, _) = makeCtx()
    // Start a fresh empty session via click.
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onRelease(ctx, x: 10, y: 20, shift: false, alt: false)
    #expect(tool.isEditing())
    _ = tool.onKeyEvent(ctx, "a", KeyMods())
    _ = tool.onKeyEvent(ctx, "b", KeyMods())
    if case .text(let t) = model.document.layers[0].children[0] {
        #expect(t.content == "ab")
    } else {
        Issue.record("Expected text element with content")
    }
}

@Test func typeToolEscapeEndsSessionKeepsElement() {
    let tool = TypeTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 5, y: 5, shift: false, alt: false)
    tool.onRelease(ctx, x: 5, y: 5, shift: false, alt: false)
    _ = tool.onKeyEvent(ctx, "Escape", KeyMods())
    #expect(!tool.isEditing())
    #expect(model.document.layers[0].children.count == 1)
}

// MARK: - TypeOnPathTool session tests

@Test func typeOnPathToolDragCreatesEmptyTextPathAndSession() {
    let tool = TypeOnPathTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onMove(ctx, x: 60, y: 80, shift: false, dragging: true)
    tool.onRelease(ctx, x: 60, y: 80, shift: false, alt: false)
    let children = model.document.layers[0].children
    #expect(children.count == 1)
    if case .textPath(let tp) = children[0] {
        #expect(tp.content == "")
    } else {
        Issue.record("Expected text-path element")
    }
    #expect(tool.isEditing())
}

@Test func typeOnPathToolClickOnExistingPathStartsSession() {
    // Existing Path element that the curve hit-test resolves to.
    let p = Path(d: [.moveTo(0, 0), .lineTo(100, 0)],
                 stroke: Stroke(color: Color(r: 0, g: 0, b: 0)))
    let layer = Layer(name: "L", children: [.path(p)])
    let model = Model()
    model.document = Document(layers: [layer])
    let pathElem: Element = .path(p)
    let (ctx, _, _) = makeCtx(model, hitTestPathCurve: { _, _ in ([0, 0], pathElem) })
    let tool = TypeOnPathTool()
    tool.onPress(ctx, x: 50, y: 0, shift: false, alt: false)
    tool.onRelease(ctx, x: 50, y: 0, shift: false, alt: false)
    #expect(tool.isEditing())
    if case .textPath(let tp) = model.document.layers[0].children[0] {
        #expect(tp.content == "")
    } else {
        Issue.record("Expected text-path conversion")
    }
}

@Test func typeOnPathToolClickOnEmptyCanvasDoesNothing() {
    let tool = TypeOnPathTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onRelease(ctx, x: 11, y: 21, shift: false, alt: false)
    #expect(model.document.layers[0].children.isEmpty)
    #expect(!tool.isEditing())
}

@Test func typeOnPathToolTypingIntoSessionUpdatesModel() {
    let tool = TypeOnPathTool()
    let (ctx, model, _) = makeCtx()
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onMove(ctx, x: 80, y: 80, shift: false, dragging: true)
    tool.onRelease(ctx, x: 80, y: 80, shift: false, alt: false)
    #expect(tool.isEditing())
    _ = tool.onKeyEvent(ctx, "H", KeyMods())
    _ = tool.onKeyEvent(ctx, "i", KeyMods())
    if case .textPath(let tp) = model.document.layers[0].children[0] {
        #expect(tp.content == "Hi")
    } else {
        Issue.record("Expected text-path element with content")
    }
}

@Test func typeOnPathToolEscapeEndsSession() {
    let tool = TypeOnPathTool()
    let (ctx, _, _) = makeCtx()
    tool.onPress(ctx, x: 10, y: 20, shift: false, alt: false)
    tool.onMove(ctx, x: 80, y: 80, shift: false, dragging: true)
    tool.onRelease(ctx, x: 80, y: 80, shift: false, alt: false)
    _ = tool.onKeyEvent(ctx, "Escape", KeyMods())
    #expect(!tool.isEditing())
}
