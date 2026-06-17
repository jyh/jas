import Foundation
import Combine
import Collections

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
        didSet {
            // The document setter is the single mutation chokepoint
            // (every edit goes through `model.document = ...`), so refresh
            // the paired id->element index here (REFERENCE_GRAPH.md §2.4
            // Phase 4b, Option B "rebuild-at-chokepoint"). undo/redo restore
            // a SNAPSHOT-CARRIED index in O(1) instead of rebuilding, so they
            // hand it in via `restoringIndex`; every other write rebuilds.
            if let carried = restoringIndex {
                idIndex = carried
                restoringIndex = nil
            } else {
                refreshIdIndex()
            }
            notify()
        }
    }
    /// Persistent id->element index paired with `document`
    /// (REFERENCE_GRAPH.md §2.4 Phase 4b). A pure function of `document`
    /// (always equal to `rebuildIdIndex(document)`; checked by the
    /// `assert` gate in `refreshIdIndex`), so it is never serialized and
    /// never part of Document equality. Stored here, alongside the snapshot,
    /// so paint reads it without rebuilding and undo carries it in O(1)
    /// (TreeDictionary structure sharing — the undo/redo stacks pair each
    /// Document with its index for the same reason). Mirrors Rust's
    /// `Model.id_index`.
    public private(set) var idIndex: IdIndex
    /// Set by undo/redo to the snapshot-carried index just before the paired
    /// document assignment, so the setter's `didSet` adopts it in O(1) rather
    /// than rebuilding from scratch. nil for all other writes.
    private var restoringIndex: IdIndex? = nil
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
    /// Undo/redo stacks pair each Document with its id->element index so
    /// undo/redo restore the index in O(1) without a rebuild (TreeDictionary
    /// copy is O(1) structure sharing). Mirrors Rust's `Vec<(Document,
    /// IdIndex)>`.
    private var undoStack: [(Document, IdIndex)] = []
    private var redoStack: [(Document, IdIndex)] = []
    private let maxUndo = 100

    public var isModified: Bool { document != savedDocument }

    public init(document: Document = Document(), filename: String? = nil) {
        // Build the companion index BEFORE assigning `document`, because the
        // setter's `didSet` reads `idIndex`/`restoringIndex` (both must be
        // initialized first). The didSet then rebuilds it from `document`, so
        // the stored value equals a fresh rebuild from the first observable
        // point. Mirrors Rust building the index in `Model::new`.
        self.idIndex = rebuildIdIndex(document)
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
        // Pair the index with the document on the stack so undo/redo restore
        // it in O(1) without a rebuild (TreeDictionary copy is O(1) structure
        // sharing). Mirrors Rust `snapshot` pushing `(document, id_index)`.
        undoStack.append((document, idIndex))
        if undoStack.count > maxUndo {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    /// Rebuild the id->element index from the current document and assert it
    /// equals a from-scratch rebuild. Called from the `document` `didSet`
    /// chokepoint (every non-undo/redo write). The `assert` is the trust gate
    /// (REFERENCE_GRAPH.md §2.3): active in debug — the whole test suite runs
    /// in debug — so it proves the stored index always matches a fresh
    /// rebuild, with zero release-build cost. Mirrors Rust's
    /// `refresh_id_index` + `debug_assert!`.
    private func refreshIdIndex() {
        idIndex = rebuildIdIndex(document)
        assert(idIndex == rebuildIdIndex(document),
               "id index diverged from rebuild after refresh")
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
        guard let (prevDoc, prevIndex) = undoStack.popLast() else { return }
        redoStack.append((document, idIndex))
        // Hand the snapshot-carried index to the setter so its didSet adopts
        // it in O(1) instead of rebuilding (Option B O(1) carry). The
        // refresh-path assert below confirms it still equals a fresh rebuild.
        restoringIndex = prevIndex
        document = prevDoc
        assert(idIndex == rebuildIdIndex(document),
               "id index diverged from rebuild after undo")
    }

    public func redo() {
        guard let (nextDoc, nextIndex) = redoStack.popLast() else { return }
        undoStack.append((document, idIndex))
        restoringIndex = nextIndex
        document = nextDoc
        assert(idIndex == rebuildIdIndex(document),
               "id index diverged from rebuild after redo")
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    private func notify() {
        for listener in listeners {
            listener(document)
        }
    }
}
