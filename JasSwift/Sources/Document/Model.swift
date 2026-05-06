import Foundation
import Combine

/// The target that drawing tools operate on. The default is the
/// document's normal content; mask-editing mode switches the
/// target to a specific element's mask subtree so new shapes land
/// inside ``element.mask.subtree`` instead of the selected layer.
/// Mirrors ``EditingTarget`` in ``jas_dioxus``. OPACITY.md
/// §Preview interactions.
public enum EditingTarget: Equatable {
    /// The document's normal content (default).
    case content
    /// Mask-editing mode: the element at ``path`` has its mask
    /// subtree as the drawing target.
    case mask([Int])
}

private var nextUntitled = 1

private func freshFilename() -> String {
    let name = "Untitled-\(nextUntitled)"
    nextUntitled += 1
    return name
}

/// Observable model that holds the current document.
///
/// Views register callbacks via onDocumentChanged to be notified
/// whenever the document is replaced.
public class Model: ObservableObject {
    @Published public var document: Document {
        didSet { notify() }
    }
    @Published public var filename: String
    @Published public var defaultFill: Fill? = nil
    @Published public var defaultStroke: Stroke? = Stroke(color: .black)
    @Published public var fillOnTop: Bool = true
    /// Per-document list of recently committed colors (hex strings, no #), newest first. Max 10.
    @Published public var recentColors: [String] = []
    /// Shared StateStore for panel-scoped state. Panels call
    /// `initPanel` on first render and `setPanel` on every widget
    /// write; the store survives across re-renders so edits persist.
    /// A panel-state mutation bumps `panelStateVersion` so SwiftUI
    /// re-renders the bound views.
    public let stateStore: StateStore = StateStore()
    @Published public var panelStateVersion: Int = 0
    /// Stack of isolated container paths for the Layers panel. Each entry
    /// is a top-level path [Int]. Written by enter/exit_isolation_mode
    /// actions via YAML dispatch (see LayersPanel.dispatchYamlAction).
    @Published public var layersIsolationStack: [[Int]] = []
    /// Mask-editing mode state. ``.content`` is the default (drawing
    /// tools add to the selected layer); ``.mask(path)`` switches
    /// the editing target to ``element.mask.subtree`` at ``path``.
    /// Flipped by clicking the Opacity panel's OPACITY_PREVIEW or
    /// MASK_PREVIEW. OPACITY.md §Preview interactions.
    @Published public var editingTarget: EditingTarget = .content
    /// Mask-isolation path. When non-nil, the canvas renders only
    /// the mask subtree of the element at this path, hiding
    /// everything else. Entered by Alt/Option-clicking MASK_PREVIEW;
    /// exited by Alt-clicking MASK_PREVIEW again (or Escape in a
    /// future increment). OPACITY.md §Preview interactions.
    @Published public var maskIsolationPath: [Int]? = nil
    /// Per-document view state (per ZOOM_TOOL.md §State persistence).
    /// Persists across tab switches within a session; reset to
    /// defaults on document open. Not serialized to disk in Phase 1.
    @Published public var zoomLevel: Double = 1.0
    @Published public var viewOffsetX: Double = 0.0
    @Published public var viewOffsetY: Double = 0.0
    /// Canvas viewport dimensions in screen-space pixels. Updated by
    /// the canvas widget on layout / resize. Read by doc.zoom.fit_*
    /// effects to compute the new zoom factor that fits a rect into
    /// the visible canvas area. Defaults match
    /// workspace/layout.yaml's canvas_pane default_position.
    @Published public var viewportW: Double = 888.0
    @Published public var viewportH: Double = 900.0
    /// Live reference to the active in-place text-editing session, if
    /// any. TypeTool and TypeOnPathTool publish their session here
    /// while editing so the Character-panel write pipeline can route
    /// panel writes to the session's next-typed-character state when a
    /// bare caret is placed. Cleared when the session ends.
    public var currentEditSession: TextEditSession? = nil
    public private(set) var savedDocument: Document
    private var listeners: [(Document) -> Void] = []
    private var undoStack: [Document] = []
    private var redoStack: [Document] = []
    private let maxUndo = 100

    public var isModified: Bool { document != savedDocument }

    public init(document: Document = Document(), filename: String? = nil) {
        self.document = document
        self.savedDocument = document
        self.filename = filename ?? freshFilename()
        // Center the current artboard in the default viewport at
        // construction time. Per ZOOM_TOOL.md §Document-open
        // behavior. The first canvas-size sync re-centers using the
        // real viewport dimensions.
        self.centerViewOnCurrentArtboard()
    }

    /// Center the canvas view on the current artboard using the
    /// stored viewportW / viewportH. If the artboard fits at the
    /// current zoom, set pan to center it; otherwise apply
    /// fit-inside semantics with 20px screen-space padding.
    /// Per ZOOM_TOOL.md §Document-open behavior.
    public func centerViewOnCurrentArtboard() {
        guard let ab = document.artboards.first else { return }
        guard viewportW > 0, viewportH > 0 else { return }
        let abW = Double(ab.width)
        let abH = Double(ab.height)
        let abX = Double(ab.x)
        let abY = Double(ab.y)
        let fits = abW * zoomLevel <= viewportW
            && abH * zoomLevel <= viewportH
        if fits {
            viewOffsetX = viewportW / 2.0 - (abX + abW / 2.0) * zoomLevel
            viewOffsetY = viewportH / 2.0 - (abY + abH / 2.0) * zoomLevel
        } else {
            let pad = 20.0
            let availW = viewportW - 2.0 * pad
            let availH = viewportH - 2.0 * pad
            if availW > 0, availH > 0 {
                let zFit = min(availW / abW, availH / abH)
                let zClamped = min(max(zFit, 0.1), 64.0)
                zoomLevel = zClamped
                viewOffsetX = viewportW / 2.0 - (abX + abW / 2.0) * zClamped
                viewOffsetY = viewportH / 2.0 - (abY + abH / 2.0) * zClamped
            }
        }
    }

    public func markSaved() {
        savedDocument = document
        objectWillChange.send()
    }

    /// View shortcuts shared between the canvas keyDown handler and
    /// the View menu commands. Both paths must call into the same
    /// place — otherwise the SwiftUI menu's keyboardShortcut steals
    /// the chord before the canvas sees it, leaving the menu button
    /// the only working invocation surface (and a stub menu button is
    /// what bit us in the smoke before this landed). Hard-coded zoom
    /// limits match workspace prefs (zoom_step 1.2, min/max 0.1 / 64).
    public func zoomIn() { applyZoomCentered(factor: 1.2) }
    public func zoomOut() { applyZoomCentered(factor: 1.0 / 1.2) }
    public func zoomToActualSize() {
        zoomLevel = min(max(1.0, 0.1), 64.0)
    }
    public func fitActiveArtboard() {
        guard let ab = document.artboards.first else { return }
        fitRect(x: Double(ab.x), y: Double(ab.y),
                w: Double(ab.width), h: Double(ab.height))
    }
    public func fitAllArtboards() {
        let abs = document.artboards
        guard !abs.isEmpty else { return }
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        for ab in abs {
            minX = min(minX, Double(ab.x))
            minY = min(minY, Double(ab.y))
            maxX = max(maxX, Double(ab.x + ab.width))
            maxY = max(maxY, Double(ab.y + ab.height))
        }
        fitRect(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
    }

    private func applyZoomCentered(factor: Double) {
        let cx = viewportW / 2.0
        let cy = viewportH / 2.0
        let docCx = (cx - viewOffsetX) / zoomLevel
        let docCy = (cy - viewOffsetY) / zoomLevel
        let z = min(max(zoomLevel * factor, 0.1), 64.0)
        zoomLevel = z
        viewOffsetX = cx - docCx * z
        viewOffsetY = cy - docCy * z
    }

    private func fitRect(x: Double, y: Double, w: Double, h: Double) {
        guard w > 0, h > 0, viewportW > 0, viewportH > 0 else { return }
        let pad = 20.0
        let availW = viewportW - 2 * pad
        let availH = viewportH - 2 * pad
        guard availW > 0, availH > 0 else { return }
        let z = min(max(min(availW / w, availH / h), 0.1), 64.0)
        zoomLevel = z
        viewOffsetX = viewportW / 2.0 - (x + w / 2.0) * z
        viewOffsetY = viewportH / 2.0 - (y + h / 2.0) * z
    }

    public func onDocumentChanged(_ callback: @escaping (Document) -> Void) {
        listeners.append(callback)
    }

    public func snapshot() {
        undoStack.append(document)
        if undoStack.count > maxUndo {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    /// Out-of-band document snapshot used by dialog Preview flows
    /// (Scale Options, Rotate Options, Shear Options). Captured at
    /// dialog open, restored on Cancel, cleared on OK. Distinct
    /// from the undo stack so preview-driven applies do not
    /// pollute undo history. See SCALE_TOOL.md §Preview.
    private var previewDocSnapshot: Document?

    public func capturePreviewSnapshot() {
        previewDocSnapshot = document
    }

    public func restorePreviewSnapshot() {
        if let snap = previewDocSnapshot {
            document = snap
            notify()
            objectWillChange.send()
        }
    }

    public func clearPreviewSnapshot() {
        previewDocSnapshot = nil
    }

    public var hasPreviewSnapshot: Bool { previewDocSnapshot != nil }

    public func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(document)
        document = prev
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document)
        document = next
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    private func notify() {
        for listener in listeners {
            listener(document)
        }
    }
}
