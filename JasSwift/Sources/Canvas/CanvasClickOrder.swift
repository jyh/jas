/// The order in which the canvas hands a click run to the active tool.
///
/// AppKit reports a double-click on the SECOND PRESS (`clickCount == 2` on
/// `mouseDown`), and so does WinUI's `DoubleTapped` (flask STATUS 758, measured
/// on the box). The input-script grammar (docs/TESTING.md section 6), the
/// browser's `dblclick` and the engine's `KIND_DOUBLE_CLICK` put it AFTER the
/// second release: press, release, press, release, double. So the canvas
/// takes the second press as a press, holds the double, and sends it after
/// that release. The double fires once per run, at the second click, as a
/// browser's `dblclick` does; a third click is a plain click.
enum CanvasPointerAct: Equatable {
    case press, release, doubleClick
}

struct CanvasClickOrder {
    private var pendingDouble = false

    mutating func down(clickCount: Int) -> [CanvasPointerAct] {
        // Set, never only raised: a run whose release never reached `up()`
        // (the canvas had no tool context) must not leak its double forward.
        pendingDouble = clickCount == 2
        return [.press]
    }

    mutating func up() -> [CanvasPointerAct] {
        defer { pendingDouble = false }
        return pendingDouble ? [.release, .doubleClick] : [.release]
    }
}
