import Testing
import AppKit
import SwiftUI
@testable import JasLib

// The test-only `--test-fifo` `shot <path>` command: the app renders its own
// window's content view to a PNG. An outside capture (`screencapture -l`)
// needs an unlocked, awake console and returns a BLANK frame or refuses
// without one; this one draws the view hierarchy in-process, so a harness
// can read the Mac app's window while the console is locked.

/// A view that fills itself with one colour, so a pixel read is exact.
private final class SolidView: NSView {
    let fill: NSColor
    init(frame: NSRect, fill: NSColor) {
        self.fill = fill
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("unused") }
    override func draw(_ dirtyRect: NSRect) {
        // `bounds`, not `dirtyRect`: off-window, cacheDisplay hands a subview
        // a dirty rect that is not clipped to it, so filling it paints the
        // whole host (measured: a two-colour host read all one colour).
        fill.setFill()
        bounds.fill()
    }
}

private func tempPath(_ name: String) -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("fifo-shot-\(UUID().uuidString)-\(name)").path
}

/// Which channel of one pixel is saturated: "r", "g", "b", or "mixed". The
/// cached bitmap is in Generic RGB, so a pure sRGB colour reads back near, not
/// at, its bytes (measured: sRGB red reads (255, 37, 0)); the arms ask which
/// colour a region is, and the margin (> 200 vs < 80) is wider than that drift.
private func channel(_ p: (r: Int, g: Int, b: Int)?) -> String {
    guard let p else { return "unreadable" }
    let hi = 200, lo = 80
    if p.r > hi && p.g < lo && p.b < lo { return "r" }
    if p.g > hi && p.r < lo && p.b < lo { return "g" }
    if p.b > hi && p.r < lo && p.g < lo { return "b" }
    return "mixed \(p)"
}

/// The sRGB bytes of one pixel of a PNG, at a point measured from the TOP-left
/// in view points (the PNG may be at backing scale).
private func pixel(_ path: String, x: Double, yFromTop: Double, viewWidth: Double)
    -> (r: Int, g: Int, b: Int)? {
    guard let rep = NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()),
          let c = rep.colorAt(x: Int(x * Double(rep.pixelsWide) / viewWidth),
                              y: Int(yFromTop * Double(rep.pixelsWide) / viewWidth))?
            .usingColorSpace(.sRGB)
    else { return nil }
    return (Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
            Int((c.blueComponent * 255).rounded()))
}

@Test @MainActor func shotWritesTheViewsPixelsAsAPng() throws {
    let path = tempPath("solid.png")
    let view = SolidView(frame: NSRect(x: 0, y: 0, width: 40, height: 30),
                         fill: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    let size = try FifoShot.write(view: view, to: path)
    // The report names the size in POINTS, so a harness can map a point.
    #expect(size.width == 40 && size.height == 30)
    let p = pixel(path, x: 20, yFromTop: 15, viewWidth: 40)
    #expect(channel(p) == "r")
}

@Test @MainActor func shotKeepsTopAndBottomInTheirPlaces() throws {
    // A view with a blue top half and a green bottom half: a shot that flips
    // the image (AppKit's y is up, a PNG's is down) puts blue at the bottom.
    let path = tempPath("halves.png")
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 40))
    host.addSubview(SolidView(frame: NSRect(x: 0, y: 20, width: 20, height: 20),
                              fill: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)))
    host.addSubview(SolidView(frame: NSRect(x: 0, y: 0, width: 20, height: 20),
                              fill: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)))
    _ = try FifoShot.write(view: host, to: path)
    let top = pixel(path, x: 10, yFromTop: 5, viewWidth: 20)
    let bottom = pixel(path, x: 10, yFromTop: 35, viewWidth: 20)
    #expect(channel(top) == "b")
    #expect(channel(bottom) == "g")
}

@Test @MainActor func shotDrawsSwiftUIContent() throws {
    // The app's dock and panels are SwiftUI inside an NSHostingView. A shot
    // that draws only AppKit views would return the window's background for
    // every panel, so this arm is the one that says the instrument reads the
    // dock at all.
    let path = tempPath("swiftui.png")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 30, height: 30),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let hosting = NSHostingView(rootView:
        Rectangle().fill(SwiftUI.Color(.sRGB, red: 0, green: 0, blue: 1)).frame(width: 30, height: 30))
    hosting.frame = NSRect(x: 0, y: 0, width: 30, height: 30)
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    _ = try FifoShot.write(view: hosting, to: path)
    let p = pixel(path, x: 15, yFromTop: 15, viewWidth: 30)
    #expect(channel(p) == "b")
}

@Test @MainActor func shotRefusesAViewWithNoArea() {
    // A zero-size view has no pixels to write; refused by name, never an
    // empty file a harness would read as a blank window.
    let view = NSView(frame: .zero)
    let path = tempPath("empty.png")
    #expect(throws: FifoReadError.self) { try FifoShot.write(view: view, to: path) }
    #expect(!FileManager.default.fileExists(atPath: path))
}

// ── The Window menu's layout verbs, shared by the menu and the FIFO ──
// The FIFO's `action` verb runs the generic YAML dispatcher, which does not
// apply a Window verb's layout op, so `action toggle_panel {"panel":"layers"}`
// did nothing to the dock. `WindowLayoutVerb.op` is the ONE mapping from a
// Window menu action to its shared layout op; the menu and the FIFO both
// apply what it returns, so a harness drives the menu's own path.

@Test func theWindowVerbsMapToTheirSharedLayoutOps() {
    let panel = WindowLayoutVerb.op("toggle_panel", params: ["panel": "layers"])
    #expect(panel?["op"] as? String == "toggle_panel")
    #expect(panel?["kind"] as? String == (opTogglePanel(.layers)["kind"] as? String))
    let pane = WindowLayoutVerb.op("toggle_pane", params: ["pane": "dock"])
    #expect(pane?["op"] as? String == "toggle_pane")
    #expect(WindowLayoutVerb.op("tile_panes", params: [:])?["op"] as? String == "tile_panes")
}

@Test func aWindowVerbWithAnUnknownSubjectOrANonWindowActionIsNotAVerb() {
    // nil means "not mine": the caller falls through (the FIFO to the generic
    // dispatcher), never applies an empty op.
    #expect(WindowLayoutVerb.op("toggle_panel", params: ["panel": "no_such_panel"]) == nil)
    #expect(WindowLayoutVerb.op("toggle_panel", params: [:]) == nil)
    #expect(WindowLayoutVerb.op("toggle_pane", params: ["pane": "no_such_pane"]) == nil)
    #expect(WindowLayoutVerb.op("select_all", params: [:]) == nil)
}

@Test func applyingTheLayersVerbRevealsTheLayersPanel() {
    // The op the verb returns, applied to a dock without Layers, is what the
    // menu does: the first toggle shows the panel, the second hides it.
    var l = WorkspaceLayout.fromParts(
        version: layoutVersion, name: "Test",
        anchored: [(.right, Dock(id: DockId(0), groups: [PanelGroup(panels: [.color])],
                                 width: defaultDockWidth))],
        floating: [], hiddenPanels: [], zOrder: [], focusedPanel: nil,
        appearance: "dark_gray", paneLayout: nil, nextId: 1)
    let verb = WindowLayoutVerb.op("toggle_panel", params: ["panel": "layers"])!
    #expect(!l.isPanelVisible(.layers))
    layoutApply(&l, verb)
    #expect(l.panelOnScreen(.layers), "shown by the first toggle")
    layoutApply(&l, verb)
    #expect(!l.isPanelVisible(.layers), "hidden by the second")
}

// ── `repaints <path>`: how many times the canvas's repaint gate fired ──
// `shot` draws on demand, so it cannot tell whether the window was ever
// invalidated (row 207: the mutant with the precision field missing from the
// signature shot the same image). The gate's own count can: a harness reads
// it, changes state through the app, and reads it again.

@Test @MainActor func theRepaintCountStepsOnlyWhenTheGateFires() {
    let view = CanvasNSView()
    view.frame = NSRect(x: 0, y: 0, width: 50, height: 50)
    let model = Model(document: Document.newEmptyDocument())
    view.controller = Controller(model: model)
    let start = FifoLive.canvasRepaints
    #expect(view.repaintIfRenderStateChanged(), "the first check always repaints")
    #expect(FifoLive.canvasRepaints == start + 1)
    #expect(!view.repaintIfRenderStateChanged(), "nothing changed")
    #expect(FifoLive.canvasRepaints == start + 1, "an unchanged signature does not count")
    model.stateStore.set("boolean_precision", 5.0)
    #expect(view.repaintIfRenderStateChanged(), "row 207: precision is in the signature")
    #expect(FifoLive.canvasRepaints == start + 2)
}

@Test func theRepaintReportIsOneParsableObject() throws {
    let json = FifoRepaints.json(count: 7)
    let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    #expect(obj?["repaints"] as? Int == 7, "\(json)")
}
