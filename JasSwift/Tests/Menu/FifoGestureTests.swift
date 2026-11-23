import Testing
import AppKit
@testable import JasLib

// The test-only `--test-fifo` `gesture <json>` command (STATUS-jas row 249):
// an input script's POINTER steps, in DOCUMENT units, delivered to the active
// canvas view's own mouseDown / mouseDragged / mouseUp / mouseMoved. It exists
// because `events` cannot reach the canvas with the console locked: the app is
// never active there (`active=0 key=0`, row 208), and AppKit spends a click on
// an inactive window's view that does not accept the first mouse on keying the
// window. What it does NOT witness: that first-mouse and key-window routing.

// MARK: parse

@Test func gestureParseReadsTheInputScriptPointerForm() throws {
    let steps = try FifoGesture.parse("""
        [{"kind":"press","x":36,"y":36},
         {"kind":"move","x":72,"y":60,"dragging":true,"shift":true},
         {"kind":"release","x":72.5,"y":60,"alt":true},
         {"kind":"move","x":1,"y":2}]
        """)
    #expect(steps == [
        .init(kind: .press, x: 36, y: 36, dragging: false, shift: false, alt: false),
        .init(kind: .move, x: 72, y: 60, dragging: true, shift: true, alt: false),
        .init(kind: .release, x: 72.5, y: 60, dragging: false, shift: false, alt: true),
        .init(kind: .move, x: 1, y: 2, dragging: false, shift: false, alt: false),
    ])
}

/// Every shape the verb cannot deliver exactly as written is refused BY NAME,
/// so a typo never delivers a shorter gesture than was asked.
@Test func gestureParseRefusesEachUndeliverableShapeByName() {
    let cases: [(String, String)] = [
        ("not json", "not a JSON array"),
        ("{}", "not a JSON array"),
        ("[]", "empty"),
        (#"[{"kind":"wiggle","x":1,"y":1}]"#, "unknown kind 'wiggle'"),
        (#"[{"kind":"double_click","x":1,"y":1}]"#, "unknown kind 'double_click'"),
        (#"[{"kind":"press","y":1}]"#, "step 0 needs a number 'x'"),
        (#"[{"kind":"press","x":"1","y":1}]"#, "step 0 needs a number 'x'"),
        (#"[{"kind":"press","x":1}]"#, "step 0 needs a number 'y'"),
        (#"[{"kind":"press","x":1,"y":1,"dragging":true}]"#, "step 0: only a move drags"),
        (#"[{"kind":"press","x":1,"y":1,"ctrl":true}]"#, "step 0: the canvas reads no 'ctrl'"),
        (#"[{"kind":"press","x":1,"y":1,"meta":true}]"#, "step 0: the canvas reads no 'meta'"),
        (#"[{"kind":"move","x":1,"y":1,"shift":true}]"#, "step 0: a move that does not drag reads no 'shift'"),
        (#"[{"kind":"press","x":1,"y":1,"bogus":1}]"#, "step 0: unknown field 'bogus'"),
        (#"[{"kind":"press","x":1,"y":1,"shift":1}]"#, "step 0: 'shift' must be true or false"),
    ]
    for (json, why) in cases {
        do {
            _ = try FifoGesture.parse(json)
            Issue.record("accepted \(json)")
        } catch {
            #expect("\(error)".contains(why), "\(json) -> \(error)")
        }
    }
}

// MARK: deliver, through the canvas view's own handlers

/// A canvas inside a container, inside a window, at zoom 2 and offset
/// (30, 40), so a document point, a view point and a window point all differ.
@MainActor
private func liveCanvas(_ children: [Element]) -> (NSWindow, CanvasNSView, Model) {
    let doc = Document(layers: [Layer(children: children)], selectedLayer: 0, selection: [])
    let model = Model(document: doc)
    model.viewportW = 300
    model.viewportH = 200
    model.zoomLevel = 2.0
    model.viewOffsetX = 30
    model.viewOffsetY = 40
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: true)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let view = CanvasNSView()
    view.frame = NSRect(x: 50, y: 20, width: 300, height: 200)
    view.document = model.document
    view.controller = Controller(model: model)
    view.currentTool = .selection
    view.onToolRead = { .selection }
    container.addSubview(view)
    window.contentView = container
    return (window, view, model)
}

private func rectAt(_ x: Double, _ y: Double) -> Element {
    .rect(Rect(x: x, y: y, width: 20, height: 20, fill: Fill(color: Color(r: 1, g: 0, b: 0))))
}

@MainActor
@Test func gestureClickInsideARectSelectsItAndAClickOutsideDoesNot() throws {
    // The selection tool's own hit test is the axis this arm reads: it was
    // written with no knowledge of how the gesture maps a document point.
    let (window, view, model) = liveCanvas([rectAt(10, 10)])
    _ = try FifoGesture.deliver(FifoGesture.parse(
        #"[{"kind":"press","x":20,"y":20},{"kind":"release","x":20,"y":20}]"#), to: view)
    #expect(model.document.selection == [ElementSelection.all([0, 0])])
    // The control: the same click 60 units right lands on nothing.
    _ = try FifoGesture.deliver(FifoGesture.parse(
        #"[{"kind":"press","x":80,"y":20},{"kind":"release","x":80,"y":20}]"#), to: view)
    #expect(model.document.selection.isEmpty)
    _ = window
}

@MainActor
@Test func gestureDragMovesTheRectByTheDocumentDelta() throws {
    let (window, view, model) = liveCanvas([rectAt(10, 10)])
    let receipt = try FifoGesture.deliver(FifoGesture.parse("""
        [{"kind":"press","x":20,"y":20},
         {"kind":"move","x":25,"y":22,"dragging":true},
         {"kind":"move","x":30,"y":25,"dragging":true},
         {"kind":"release","x":30,"y":25}]
        """), to: view)
    guard case .rect(let r) = model.document.layers[0].children[0] else {
        Issue.record("not a rect"); return
    }
    // Delivered at zoom 2: a view-point mapping error would move it by 2x
    // (or not at all), never by exactly (10, 5) document units.
    // (A Selection drag rewrites the geometry, transform null:
    // test_fixtures/input_scripts/selection.drag.expected.json.)
    #expect(r.x == 20 && r.y == 15, "rect at (\(r.x), \(r.y)), transform \(String(describing: r.transform))")
    #expect(receipt == "press@(20,20) drag@(25,22) drag@(30,25) release@(30,25)")
    _ = window
}

@MainActor
@Test func gestureCanvasIsFoundByItsModelAndRefusedWhenAbsent() throws {
    let (window, view, model) = liveCanvas([rectAt(10, 10)])
    #expect(try FifoGesture.canvas(for: model, in: window) === view)
    let other = Model()
    do {
        _ = try FifoGesture.canvas(for: other, in: window)
        Issue.record("found a canvas for a model with none")
    } catch {
        #expect("\(error)".contains("no canvas shows the active document"), "\(error)")
    }
}
