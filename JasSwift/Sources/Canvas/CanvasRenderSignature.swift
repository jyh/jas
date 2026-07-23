import Foundation

/// A compact, Equatable fingerprint of exactly the state the canvas `draw(_:)`
/// pass reads. `updateNSView` recomputes it on every SwiftUI update and repaints
/// ONLY when it changed since the last render — so the frequent @Published churn
/// that does NOT affect the canvas (panelStateVersion, recentColors, defaultFill,
/// filename, hover, …) no longer forces a whole-canvas repaint.
///
/// Membership rule: include a field only if `draw` (or a pass it calls) reads it,
/// because a MISSING field means a real change would not repaint (a stale-canvas
/// bug), while an EXTRA field only costs a harmless redundant repaint. Interactive
/// changes that already invalidate directly (tool-overlay updates during a
/// gesture via the requestUpdate closure; pan/zoom via applyNavIntent /
/// runViewAction) are intentionally out of scope here — they repaint through
/// their own `needsDisplay` path, not through updateNSView.
struct CanvasRenderSignature: Equatable {
    /// Identity of the active model — distinguishes two tabs whose independent
    /// generation counters could otherwise collide at the same value.
    let modelId: ObjectIdentifier
    /// Document + selection version (bumped on every `document` didSet).
    let generation: UInt64
    // View transform.
    let zoom: Double
    let offX: Double
    let offY: Double
    let viewportW: Double
    let viewportH: Double
    // Active tool (drives cursor + overlay selection).
    let tool: Tool
    // Isolation / mask-editing render state.
    let maskIsolation: [Int]?
    let editingTarget: EditingTarget
    let layersIsolation: [[Int]]
    // Chrome that rides on non-document state.
    let artboardsPanelSelection: [String]
    let keyObjectPath: [Int]?

    init(model: Model, tool: Tool, artboardsPanelSelection: [String]) {
        self.modelId = ObjectIdentifier(model)
        self.generation = model.generation
        self.zoom = model.zoomLevel
        self.offX = model.viewOffsetX
        self.offY = model.viewOffsetY
        self.viewportW = model.viewportW
        self.viewportH = model.viewportH
        self.tool = tool
        self.maskIsolation = model.maskIsolationPath
        self.editingTarget = model.editingTarget
        self.layersIsolation = model.layersIsolationStack
        self.artboardsPanelSelection = artboardsPanelSelection
        // Mirrors draw()'s align key-object read.
        self.keyObjectPath = {
            guard let dict = model.stateStore.get("align_key_object_path") as? [String: Any],
                  let arr = dict["__path__"] as? [Int]
            else { return nil }
            return arr
        }()
    }
}
