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

/// Look up a tool spec inside an already-loaded workspace and build
/// a YamlTool from it. Returns nil only when the spec is missing or
/// malformed — workspace failure is reported by [loadWorkspaceTools]
/// up-front, not per call. The dispatcher in CanvasSubwindow keys
/// the tool dict with optional chaining (tools[currentTool]?), so a
/// missing tool downgrades to a no-op rather than a crash.
func loadYamlTool(_ id: String, in ws: WorkspaceData) -> YamlTool? {
    guard let tools = ws.data["tools"] as? [String: Any],
          let spec = tools[id] as? [String: Any] else {
        return nil
    }
    return YamlTool.fromWorkspaceTool(spec)
}

/// Load workspace tools and assemble the registry. Tiered failure
/// modes:
///   * Workspace nil → fatalError. The whole app cannot run without
///     workspace.json; failing fast is correct.
///   * Per-tool nil → log + omit. Other tools still load, the omitted
///     tool just won't activate when chosen. This is the right
///     trade-off because adding a new tool spec shouldn't be able to
///     brick the app.
/// Native-only tools (Type / TypeOnPath per NATIVE_BOUNDARY.md §6)
/// are added unconditionally.
func createTools() -> [Tool: CanvasTool] {
    guard let ws = WorkspaceData.load() else {
        fatalError("workspace/workspace.json missing or malformed — cannot run without it")
    }
    let yamlTools: [(Tool, String)] = [
        (.selection,           "selection"),
        (.partialSelection,    "partial_selection"),
        (.interiorSelection,   "interior_selection"),
        (.pen,                 "pen"),
        (.addAnchorPoint,      "add_anchor_point"),
        (.deleteAnchorPoint,   "delete_anchor_point"),
        (.anchorPoint,         "anchor_point"),
        (.pencil,              "pencil"),
        (.pathEraser,          "path_eraser"),
        (.smooth,              "smooth"),
        (.line,                "line"),
        (.rect,                "rect"),
        (.roundedRect,         "rounded_rect"),
        (.polygon,             "polygon"),
        (.star,                "star"),
        (.lasso,               "lasso"),
    ]
    var registry: [Tool: CanvasTool] = [
        .typeTool:   TypeTool(),
        .typeOnPath: TypeOnPathTool(),
    ]
    for (kind, id) in yamlTools {
        if let tool = loadYamlTool(id, in: ws) {
            registry[kind] = tool
        } else {
            NSLog("[Jas] tool \"%@\" not loaded — workspace.json missing the spec", id)
        }
    }
    return registry
}
