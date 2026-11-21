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
