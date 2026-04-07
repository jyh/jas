import Foundation

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
    public var dragActive: Bool = false
    public var blinkEpochMs: Double = 0.0

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

    private func snapshot() {
        undoStack.append(EditSnapshot(content: content, insertion: insertion, anchor: anchor))
        redoStack.removeAll()
        if undoStack.count > 200 { undoStack.removeFirst() }
    }

    public func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(EditSnapshot(content: content, insertion: insertion, anchor: anchor))
        content = prev.content
        insertion = prev.insertion
        anchor = prev.anchor
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(EditSnapshot(content: content, insertion: insertion, anchor: anchor))
        content = next.content
        insertion = next.insertion
        anchor = next.anchor
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
        insertion = max(0, min(pos, n))
        if !extend { anchor = insertion }
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

    /// Build a new Document with this session's content applied to `path`.
    /// Returns nil if the path no longer points at a compatible element.
    public func applyToDocument(_ doc: Document) -> Document? {
        // Defensive: avoid out-of-range crashes if the path is stale.
        guard pathIsValid(doc, path) else { return nil }
        let elem = doc.getElement(path)
        switch (target, elem) {
        case (.text, .text(let t)):
            let new = Text(x: t.x, y: t.y, content: content,
                           fontFamily: t.fontFamily, fontSize: t.fontSize,
                           fontWeight: t.fontWeight, fontStyle: t.fontStyle,
                           textDecoration: t.textDecoration,
                           width: t.width, height: t.height,
                           fill: t.fill, stroke: t.stroke,
                           opacity: t.opacity, transform: t.transform, locked: t.locked)
            return doc.replaceElement(path, with: .text(new))
        case (.textPath, .textPath(let tp)):
            let new = TextPath(d: tp.d, content: content, startOffset: tp.startOffset,
                               fontFamily: tp.fontFamily, fontSize: tp.fontSize,
                               fontWeight: tp.fontWeight, fontStyle: tp.fontStyle,
                               textDecoration: tp.textDecoration,
                               fill: tp.fill, stroke: tp.stroke,
                               opacity: tp.opacity, transform: tp.transform, locked: tp.locked)
            return doc.replaceElement(path, with: .textPath(new))
        default:
            return nil
        }
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
