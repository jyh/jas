import AppKit
import Foundation

// MARK: - Tool context

/// Facade passed to tools giving access to model, controller, and canvas services.
class ToolContext {
    let model: Model
    let controller: Controller
    let hitTestSelection: (NSPoint) -> Bool
    let hitTestHandle: (NSPoint) -> (path: ElementPath, anchorIdx: Int, handleType: String)?
    let hitTestText: (NSPoint) -> (ElementPath, Text)?
    let hitTestPathCurve: (Double, Double) -> (ElementPath, Element)?
    let requestUpdate: () -> Void
    let startTextEdit: (ElementPath, Element) -> Void
    let commitTextEdit: () -> Void
    let drawElementOverlayFn: (CGContext, Element, Set<Int>) -> Void

    init(model: Model,
         controller: Controller,
         hitTestSelection: @escaping (NSPoint) -> Bool,
         hitTestHandle: @escaping (NSPoint) -> (path: ElementPath, anchorIdx: Int, handleType: String)?,
         hitTestText: @escaping (NSPoint) -> (ElementPath, Text)?,
         hitTestPathCurve: @escaping (Double, Double) -> (ElementPath, Element)?,
         requestUpdate: @escaping () -> Void,
         startTextEdit: @escaping (ElementPath, Element) -> Void,
         commitTextEdit: @escaping () -> Void,
         drawElementOverlay: @escaping (CGContext, Element, Set<Int>) -> Void) {
        self.model = model
        self.controller = controller
        self.hitTestSelection = hitTestSelection
        self.hitTestHandle = hitTestHandle
        self.hitTestText = hitTestText
        self.hitTestPathCurve = hitTestPathCurve
        self.requestUpdate = requestUpdate
        self.startTextEdit = startTextEdit
        self.commitTextEdit = commitTextEdit
        self.drawElementOverlayFn = drawElementOverlay
    }

    var document: Document { model.document }

    func snapshot() { model.snapshot() }
}

// MARK: - CanvasTool protocol

/// Interface for canvas interaction tools.
protocol CanvasTool: AnyObject {
    func onPress(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool)
    func onMove(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, dragging: Bool)
    func onRelease(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool)
    func onDoubleClick(_ ctx: ToolContext, x: Double, y: Double)
    func onKey(_ ctx: ToolContext, keyCode: UInt16) -> Bool
    func onKeyUp(_ ctx: ToolContext, keyCode: UInt16) -> Bool
    func drawOverlay(_ ctx: ToolContext, _ cgCtx: CGContext)
    func activate(_ ctx: ToolContext)
    func deactivate(_ ctx: ToolContext)
}

/// Default implementations for optional protocol methods.
extension CanvasTool {
    func onDoubleClick(_ ctx: ToolContext, x: Double, y: Double) {}
    func onKey(_ ctx: ToolContext, keyCode: UInt16) -> Bool { false }
    func onKeyUp(_ ctx: ToolContext, keyCode: UInt16) -> Bool { false }
    func activate(_ ctx: ToolContext) {}
    func deactivate(_ ctx: ToolContext) {}
}

// MARK: - Helpers

// MARK: - Shared tool constants

let hitRadius: CGFloat = 8.0        // pixels to detect a click on a control point
let handleDrawSize: CGFloat = 10.0  // diameter of control-point handles in pixels
let dragThreshold: Double = 4.0     // pixels of movement before a click becomes a drag
let pasteOffset: Double = 24.0      // translation in pt applied when pasting
let longPressDuration: Double = 0.5 // seconds before a press becomes a long-press
let polygonSides = 5                // default number of sides for the polygon tool
let flattenSteps = elementFlattenSteps  // shared constant from Element.swift

let toolSelectionColor = CGColor(red: 0, green: 0.47, blue: 1.0, alpha: 1.0)

func constrainAngle(_ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double) -> (Double, Double) {
    let dx = ex - sx, dy = ey - sy
    let dist = hypot(dx, dy)
    guard dist > 0 else { return (ex, ey) }
    let angle = atan2(dy, dx)
    let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
    return (sx + dist * cos(snapped), sy + dist * sin(snapped))
}

func regularPolygonPoints(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ n: Int) -> [(Double, Double)] {
    let ex = x2 - x1, ey = y2 - y1
    let s = hypot(ex, ey)
    guard s > 0 else { return Array(repeating: (x1, y1), count: n) }
    let mx = (x1 + x2) / 2, my = (y1 + y2) / 2
    let px = -ey / s, py = ex / s
    let d = s / (2 * tan(.pi / Double(n)))
    let cx = mx + d * px, cy = my + d * py
    let r = s / (2 * sin(.pi / Double(n)))
    let theta0 = atan2(y1 - cy, x1 - cx)
    return (0..<n).map { k in
        let angle = theta0 + 2 * .pi * Double(k) / Double(n)
        return (cx + r * cos(angle), cy + r * sin(angle))
    }
}

// MARK: - Tool registry

/// Create one instance of each tool, keyed by Tool enum.
func createTools() -> [Tool: CanvasTool] {
    [
        .selection: SelectionTool(),
        .directSelection: DirectSelectionTool(),
        .groupSelection: GroupSelectionTool(),
        .pen: PenTool(),
        .addAnchorPoint: AddAnchorPointTool(),
        .deleteAnchorPoint: DeleteAnchorPointTool(),
        .pencil: PencilTool(),
        .pathEraser: PathEraserTool(),
        .smooth: SmoothTool(),
        .typeTool: TypeTool(),
        .textPath: TextPathTool(),
        .line: LineTool(),
        .rect: RectTool(),
        .roundedRect: RoundedRectTool(),
        .polygon: PolygonTool(),
        .star: StarTool(),
    ]
}
