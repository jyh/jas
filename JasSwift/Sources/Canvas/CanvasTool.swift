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
    let drawElementOverlayFn: (CGContext, Element, SelectionKind) -> Void

    init(model: Model,
         controller: Controller,
         hitTestSelection: @escaping (NSPoint) -> Bool,
         hitTestHandle: @escaping (NSPoint) -> (path: ElementPath, anchorIdx: Int, handleType: String)?,
         hitTestText: @escaping (NSPoint) -> (ElementPath, Text)?,
         hitTestPathCurve: @escaping (Double, Double) -> (ElementPath, Element)?,
         requestUpdate: @escaping () -> Void,
         drawElementOverlay: @escaping (CGContext, Element, SelectionKind) -> Void) {
        self.model = model
        self.controller = controller
        self.hitTestSelection = hitTestSelection
        self.hitTestHandle = hitTestHandle
        self.hitTestText = hitTestText
        self.hitTestPathCurve = hitTestPathCurve
        self.requestUpdate = requestUpdate
        self.drawElementOverlayFn = drawElementOverlay
    }

    var document: Document { model.document }

    func snapshot() { model.snapshot() }
}

// MARK: - Keyboard modifiers

/// Modifier keys passed to `onKeyEvent`. `cmd` is true if the platform's
/// command key (NSEvent.modifierFlags.command on macOS) is held.
public struct KeyMods {
    public var shift: Bool
    public var ctrl: Bool
    public var alt: Bool
    public var cmd: Bool
    public init(shift: Bool = false, ctrl: Bool = false, alt: Bool = false, cmd: Bool = false) {
        self.shift = shift; self.ctrl = ctrl; self.alt = alt; self.cmd = cmd
    }
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

    // Optional in-place text editing surface (default no-op for most tools).
    func capturesKeyboard() -> Bool
    func isEditing() -> Bool
    func cursorOverride() -> String?
    func pasteText(_ ctx: ToolContext, _ text: String) -> Bool
    func onKeyEvent(_ ctx: ToolContext, _ key: String, _ mods: KeyMods) -> Bool
}

/// Default implementations for optional protocol methods.
extension CanvasTool {
    func onDoubleClick(_ ctx: ToolContext, x: Double, y: Double) {}
    func onKey(_ ctx: ToolContext, keyCode: UInt16) -> Bool { false }
    func onKeyUp(_ ctx: ToolContext, keyCode: UInt16) -> Bool { false }
    func activate(_ ctx: ToolContext) {}
    func deactivate(_ ctx: ToolContext) {}
    func capturesKeyboard() -> Bool { false }
    func isEditing() -> Bool { false }
    func cursorOverride() -> String? { nil }
    func pasteText(_ ctx: ToolContext, _ text: String) -> Bool { false }
    func onKeyEvent(_ ctx: ToolContext, _ key: String, _ mods: KeyMods) -> Bool { false }
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

// regularPolygonPoints lives in Geometry/RegularShapes.swift.

// MARK: - Tool registry

/// Load a YamlTool by id from the compiled workspace.json. Returns
/// nil when the workspace can't be loaded or the tool spec is
/// missing — callers fall back to the native implementation in that
/// case so tests stay green when the workspace file is unavailable.
func loadYamlTool(_ id: String) -> YamlTool? {
    guard let ws = WorkspaceData.load(),
          let tools = ws.data["tools"] as? [String: Any],
          let spec = tools[id] as? [String: Any] else {
        return nil
    }
    return YamlTool.fromWorkspaceTool(spec)
}

/// Create one instance of each tool, keyed by Tool enum.
func createTools() -> [Tool: CanvasTool] {
    // Tools migrated to YAML per SWIFT_TOOL_RUNTIME.md Phase 7.
    // Require the workspace to load — a missing workspace.json means
    // the whole app is non-functional anyway.
    guard let rectTool = loadYamlTool("rect"),
          let roundedRectTool = loadYamlTool("rounded_rect"),
          let lineTool = loadYamlTool("line"),
          let polygonTool = loadYamlTool("polygon"),
          let starTool = loadYamlTool("star"),
          let selectionTool = loadYamlTool("selection"),
          let interiorSelectionTool = loadYamlTool("interior_selection"),
          let lassoTool = loadYamlTool("lasso"),
          let pencilTool = loadYamlTool("pencil"),
          let penTool = loadYamlTool("pen") else {
        fatalError("workspace/workspace.json missing or malformed — cannot load YAML tools")
    }
    return [
        .selection: selectionTool,
        .partialSelection: PartialSelectionTool(),
        .interiorSelection: interiorSelectionTool,
        .pen: penTool,
        .addAnchorPoint: AddAnchorPointTool(),
        .deleteAnchorPoint: DeleteAnchorPointTool(),
        .anchorPoint: AnchorPointTool(),
        .pencil: pencilTool,
        .pathEraser: PathEraserTool(),
        .smooth: SmoothTool(),
        .typeTool: TypeTool(),
        .typeOnPath: TypeOnPathTool(),
        .line: lineTool,
        .rect: rectTool,
        .roundedRect: roundedRectTool,
        .polygon: polygonTool,
        .star: starTool,
        .lasso: lassoTool,
    ]
}
