import AppKit

/// `shot <path>`: the app's own window content, drawn in-process to a PNG at
/// `path` (atomically, replacing), for the test-only `--test-fifo` channel.
///
/// An outside capture (`screencapture -l<id>`) needs an unlocked, awake
/// console: under a locked screen it refuses ("could not create image from
/// display") or writes a blank frame. This draws the view hierarchy through
/// `cacheDisplay`, which does not go through the window server's capture, so
/// a harness can read the window while the console is locked.
///
/// What it does NOT draw: anything outside the content view (the title bar,
/// menus, sheets, popovers in their own windows) and whatever the window
/// server composites on top. It is the app's view tree as the app draws it.
public enum FifoShot {
    /// Draw `view` and write it as a PNG. Returns the size in POINTS (the PNG
    /// is at the backing scale), so a harness can map a point to a pixel.
    /// Refuses, writing nothing, a view with no area.
    @MainActor @discardableResult
    public static func write(view: NSView, to path: String) throws -> NSSize {
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1 else {
            throw FifoReadError(description: "shot REFUSED (the view has no area: \(bounds.size))")
        }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw FifoReadError(description: "shot REFUSED (no bitmap for \(bounds.size))")
        }
        view.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw FifoReadError(description: "shot REFUSED (PNG encoding failed)")
        }
        try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        return bounds.size
    }
}
