import AppKit
import Foundation

// Group Selection tool — marquee select that picks groups as units.

class GroupSelectionTool: SelectionToolBase {
    override func selectRect(_ ctx: ToolContext, x: Double, y: Double, w: Double, h: Double, extend: Bool) {
        ctx.controller.groupSelectRect(x: x, y: y, width: w, height: h, extend: extend)
    }
}
