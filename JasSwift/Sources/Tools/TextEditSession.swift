import Foundation

/// Cursor blink half-period in milliseconds (matches the macOS default).
public let textEditBlinkHalfPeriodMs: Double = 530.0

/// Wall-clock milliseconds since the Unix epoch. Shared by the type tools.
public func textEditNowMs() -> Double {
    Date().timeIntervalSince1970 * 1000.0
}

/// Whether the caret is currently visible given a `blinkEpochMs` reset point.
public func textEditCursorVisible(_ epochMs: Double) -> Bool {
    let elapsed = max(0, textEditNowMs() - epochMs)
    let phase = Int(elapsed / textEditBlinkHalfPeriodMs)
    return phase % 2 == 0
}

// MARK: - In-place text editing session
//
// Mirrors the design of `text_edit.rs` / `.ml` / `.py`. The session is the
// logical state of one in-canvas editing session: which element is being
// edited, the current content, the cursor and selection (in *char*
// indices), undo/redo stacks, and the blink-epoch timestamp. Mouse and
// keyboard handling live in TypeTool / TypeOnPathTool — this type only
// owns pure operations.

public enum EditTarget {
    case text
    case textPath
}

private struct EditSnapshot {
    let content: String
    let insertion: Int
    let anchor: Int
}

public final class TextEditSession {
    public let path: ElementPath
    public let target: EditTarget
    public private(set) var content: String
    public private(set) var insertion: Int
    public private(set) var anchor: Int
    /// Caret side at a tspan boundary. Defaults to `.left` per
    /// `TSPAN.md` ("new text inherits attributes of the previous
    /// character"); `.right` is set by callers that crossed a boundary
    /// rightward. External char-index APIs keep working unchanged —
    /// the affinity only matters at joins.
    public var caretAffinity: Affinity = .left
    public var dragActive: Bool = false
    public var blinkEpochMs: Double = 0.0
    /// Session-scoped tspan clipboard. Captured on cut/copy from the
    /// current element's tspan structure; consumed on paste when the
    /// system-clipboard flat text matches. Preserves per-range
    /// overrides across cut/paste within a single edit session.
    public var tspanClipboard: (flat: String, tspans: [Tspan])? = nil
    /// Next-typed-character override: a `Tspan` template whose
    /// non-`nil` fields are applied to characters inserted from
    /// `pendingCharStart` to the current `insertion` at commit time.
    /// Primed by Character-panel writes when there is no selection
    /// (bare caret); cleared by any caret move with no selection
    /// extension and by undo/redo. Not persisted to the document —
    /// see `TSPAN.md` Text-edit session integration.
    public var pendingOverride: Tspan? = nil
    /// Char position where `pendingOverride` was primed. `nil` iff
    /// `pendingOverride` is `nil`.
    public var pendingCharStart: Int? = nil

    private var undoStack: [EditSnapshot] = []
    private var redoStack: [EditSnapshot] = []

    public init(path: ElementPath, target: EditTarget, content: String, insertion: Int) {
        self.path = path
        self.target = target
        self.content = content
        let n = content.count
        let ins = max(0, min(insertion, n))
        self.insertion = ins
        self.anchor = ins
    }

    public var hasSelection: Bool { insertion != anchor }

    public var selectionRange: (Int, Int) { orderedRange(insertion, anchor) }

    /// Prime the next-typed-character state. Non-`nil` fields of
    /// `overrides` are merged into the existing pending template;
    /// the anchor position is captured on the first call (later
    /// calls layer on more attributes without moving the anchor).
    public func setPendingOverride(_ overrides: Tspan) {
        if pendingOverride == nil {
            pendingOverride = Tspan.defaultTspan()
            pendingCharStart = insertion
        }
        pendingOverride = mergeTspanOverrides(pendingOverride!, overrides)
    }

    public func clearPendingOverride() {
        pendingOverride = nil
        pendingCharStart = nil
    }

    public var hasPendingOverride: Bool { pendingOverride != nil }

    private func snapshot() {
        undoStack.append(EditSnapshot(content: content, insertion: insertion, anchor: anchor))
        redoStack.removeAll()
        // Bound the stack. `removeFirst` on a Swift Array is O(n) but the
        // cap is small (200) and the cap is hit at most once per edit, so
        // this is negligible compared to one character render.
        if undoStack.count > 200 { undoStack.removeFirst() }
    }

    public func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(EditSnapshot(content: content, insertion: insertion, anchor: anchor))
        content = prev.content
        insertion = prev.insertion
        anchor = prev.anchor
        clearPendingOverride()
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(EditSnapshot(content: content, insertion: insertion, anchor: anchor))
        content = next.content
        insertion = next.insertion
        anchor = next.anchor
        clearPendingOverride()
    }

    private func deleteSelectionInner() {
        let (lo, hi) = selectionRange
        let lower = content.index(content.startIndex, offsetBy: lo)
        let upper = content.index(content.startIndex, offsetBy: hi)
        content.removeSubrange(lower..<upper)
        insertion = lo
        anchor = lo
    }

    /// Insert `text` at the caret, replacing the selection if any.
    public func insert(_ text: String) {
        snapshot()
        if hasSelection { deleteSelectionInner() }
        let at = content.index(content.startIndex, offsetBy: insertion)
        content.insert(contentsOf: text, at: at)
        insertion += text.count
        anchor = insertion
    }

    /// Backspace: delete the selection if any, else the char before the caret.
    public func backspace() {
        if hasSelection {
            snapshot()
            deleteSelectionInner()
            return
        }
        if insertion == 0 { return }
        snapshot()
        let from = content.index(content.startIndex, offsetBy: insertion - 1)
        let to = content.index(content.startIndex, offsetBy: insertion)
        content.removeSubrange(from..<to)
        insertion -= 1
        anchor = insertion
    }

    /// Forward delete: delete the selection if any, else the char after the caret.
    public func deleteForward() {
        if hasSelection {
            snapshot()
            deleteSelectionInner()
            return
        }
        if insertion >= content.count { return }
        snapshot()
        let from = content.index(content.startIndex, offsetBy: insertion)
        let to = content.index(content.startIndex, offsetBy: insertion + 1)
        content.removeSubrange(from..<to)
        anchor = insertion
    }

    /// Move the caret. If `extend`, the anchor stays put to grow the selection.
    public func setInsertion(_ pos: Int, extend: Bool) {
        let n = content.count
        let newPos = max(0, min(pos, n))
        // Non-extending caret movement cancels any pending next-typed-
        // character override (the user abandoned the position where
        // the override was primed).
        if !extend && newPos != insertion { clearPendingOverride() }
        insertion = newPos
        if !extend { anchor = insertion }
    }

    /// Move the caret with an explicit affinity. Use this when
    /// crossing a tspan boundary — arrow-right lands with `.right`,
    /// arrow-left with `.left`.
    public func setInsertion(_ pos: Int, affinity: Affinity, extend: Bool) {
        let n = content.count
        let newPos = max(0, min(pos, n))
        if !extend && newPos != insertion { clearPendingOverride() }
        insertion = newPos
        caretAffinity = affinity
        if !extend { anchor = insertion }
    }

    /// Resolve the caret's `(tspanIdx, offset)` using `caretAffinity`.
    /// Used by the next-typed-character path and by any consumer that
    /// needs to know which tspan the caret belongs to at a boundary.
    public func insertionTspanPos(_ elementTspans: [Tspan]) -> (tspanIdx: Int, offset: Int) {
        charToTspanPos(elementTspans, insertion, caretAffinity)
    }

    /// Resolve the selection anchor's `(tspanIdx, offset)`. Anchors
    /// do not have an independent affinity; they track the caret's.
    public func anchorTspanPos(_ elementTspans: [Tspan]) -> (tspanIdx: Int, offset: Int) {
        charToTspanPos(elementTspans, anchor, caretAffinity)
    }

    public func selectAll() {
        anchor = 0
        insertion = content.count
    }

    public func copySelection() -> String? {
        guard hasSelection else { return nil }
        let (lo, hi) = selectionRange
        let from = content.index(content.startIndex, offsetBy: lo)
        let to = content.index(content.startIndex, offsetBy: hi)
        return String(content[from..<to])
    }

    /// Capture the current selection's flat text *and* its tspan
    /// structure (from `elementTspans`) into the session clipboard.
    /// Returns the flat text for the system clipboard. `nil` when
    /// there is no selection.
    public func copySelectionWithTspans(_ elementTspans: [Tspan]) -> String? {
        guard hasSelection else { return nil }
        let (lo, hi) = selectionRange
        let from = content.index(content.startIndex, offsetBy: lo)
        let to = content.index(content.startIndex, offsetBy: hi)
        let flat = String(content[from..<to])
        let tspans = copyTspanRange(elementTspans, charStart: lo, charEnd: hi)
        tspanClipboard = (flat: flat, tspans: tspans)
        return flat
    }

    /// Try a tspan-aware paste: if the clipboard's flat text equals
    /// `text`, splice the captured tspans into `elementTspans` at
    /// the caret via `insertTspansAt`. Returns `nil` when the
    /// clipboard is absent or stale; the caller falls back to the
    /// flat `insert` path.
    public func tryPasteTspans(_ elementTspans: [Tspan], text: String) -> [Tspan]? {
        guard let (flat, payload) = tspanClipboard, flat == text else {
            return nil
        }
        return insertTspansAt(elementTspans, charPos: insertion, payload)
    }

    /// Set content / insertion / anchor atomically after an external
    /// tspan-aware edit (paste) rewrote the element. Keeps the
    /// session's flat view in sync with the document.
    public func setContent(_ newContent: String, insertion: Int, anchor: Int) {
        self.content = newContent
        let n = newContent.count
        self.insertion = max(0, min(insertion, n))
        self.anchor = max(0, min(anchor, n))
    }

    /// Tspan-aware commit: reconcile the session's flat content against
    /// the element's current tspan structure via `reconcileTspanContent`.
    /// Unchanged prefix and suffix regions keep their original tspan
    /// assignments (and all per-range overrides); the changed middle
    /// is absorbed into the first overlapping tspan, with adjacent-
    /// equal tspans collapsed by the merge pass.
    public func applyToDocument(_ doc: Document) -> Document? {
        // Defensive: avoid out-of-range crashes if the path is stale.
        guard pathIsValid(doc, path) else { return nil }
        let elem = doc.getElement(path)
        switch (target, elem) {
        case (.text, .text(let t)):
            let reconciled = reconcileTspanContent(t.tspans, content)
            let newTspans = applyPendingTo(reconciled)
            return doc.replaceElement(path, with: .text(t.withTspans(newTspans)))
        case (.textPath, .textPath(let tp)):
            let reconciled = reconcileTspanContent(tp.tspans, content)
            let newTspans = applyPendingTo(reconciled)
            return doc.replaceElement(path, with: .textPath(tp.withTspans(newTspans)))
        default:
            return nil
        }
    }

    /// Apply the pending next-typed-character override to the range
    /// `[pendingCharStart, insertion)` of `tspans`, then merge.
    /// Passthrough when pending is nil or the range is empty.
    private func applyPendingTo(_ tspans: [Tspan]) -> [Tspan] {
        guard let pending = pendingOverride,
              let start = pendingCharStart,
              start < insertion
        else { return tspans }
        let (split, first, last) = splitTspanRange(tspans,
                                                   charStart: start,
                                                   charEnd: insertion)
        guard let f = first, let l = last else { return split }
        var out = split
        for i in f...l {
            out[i] = mergeTspanOverrides(out[i], pending)
        }
        return mergeTspans(out)
    }
}

/// Returns true if `path` resolves to an element in `doc` without trapping.
public func pathIsValid(_ doc: Document, _ path: ElementPath) -> Bool {
    if path.isEmpty { return false }
    if path[0] < 0 || path[0] >= doc.layers.count { return false }
    var children = doc.layers[path[0]].children
    for k in 1..<path.count {
        let idx = path[k]
        if idx < 0 || idx >= children.count { return false }
        if k == path.count - 1 { return true }
        switch children[idx] {
        case .group(let g): children = g.children
        default: return false
        }
    }
    return true
}

/// Build a new Text element with empty content for the type tool's
/// "click on empty canvas" path.
public func emptyTextElem(x: Double, y: Double, width: Double, height: Double) -> Text {
    Text(x: x, y: y, content: "",
         fontFamily: "sans-serif", fontSize: 16.0,
         width: width, height: height,
         fill: Fill(color: Color(r: 0, g: 0, b: 0)))
}

public func emptyTextPathElem(d: [PathCommand]) -> TextPath {
    TextPath(d: d, content: "", startOffset: 0.0,
             fontFamily: "sans-serif", fontSize: 16.0,
             fill: Fill(color: Color(r: 0, g: 0, b: 0)))
}
