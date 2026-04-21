import Foundation
import CoreGraphics

/// Delete Anchor Point tool.
///
/// Clicking on an anchor point removes it from the path, merging the
/// adjacent segments into a single curve that preserves the outer
/// control handles.
final class DeleteAnchorPointTool: CanvasTool {
    private static let hitRadius: Double = 8.0

    // MARK: - Hit testing

    private static func findAnchorAt(
        _ pe: Path, px: Double, py: Double, threshold: Double
    ) -> Int? {
        for (i, cmd) in pe.d.enumerated() {
            let (ax, ay): (Double, Double)
            switch cmd {
            case .moveTo(let x, let y): (ax, ay) = (x, y)
            case .lineTo(let x, let y): (ax, ay) = (x, y)
            case .curveTo(_, _, _, _, let x, let y): (ax, ay) = (x, y)
            default: continue
            }
            if hypot(px - ax, py - ay) <= threshold {
                return i
            }
        }
        return nil
    }

    private static func hitTestAnchor(
        _ doc: Document, px: Double, py: Double
    ) -> (ElementPath, Path, Int)? {
        let threshold = hitRadius
        for (li, layer) in doc.layers.enumerated() {
            for (ci, child) in layer.children.enumerated() {
                if case .path(let pe) = child {
                    if let idx = findAnchorAt(pe, px: px, py: py, threshold: threshold) {
                        return ([li, ci], pe, idx)
                    }
                }
                if case .group(let g) = child, !g.locked {
                    for (gi, gc) in g.children.enumerated() {
                        if case .path(let pe) = gc {
                            if let idx = findAnchorAt(pe, px: px, py: py, threshold: threshold) {
                                return ([li, ci, gi], pe, idx)
                            }
                        }
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Delete logic

    /// Delete the anchor at `anchorIdx`, merging adjacent segments.
    /// Returns nil if the path would have fewer than 2 anchors.
    static func deleteAnchorFromPath(
        _ d: [PathCommand], anchorIdx: Int
    ) -> [PathCommand]? {
        let anchorCount = d.filter { cmd in
            switch cmd {
            case .moveTo, .lineTo, .curveTo: return true
            default: return false
            }
        }.count
        guard anchorCount > 2 else { return nil }

        // Case 1: Deleting the first point (MoveTo)
        if anchorIdx == 0 {
            guard d.count > 1 else { return nil }
            let nx: Double, ny: Double
            switch d[1] {
            case .lineTo(let x, let y): (nx, ny) = (x, y)
            case .curveTo(_, _, _, _, let x, let y): (nx, ny) = (x, y)
            default: return nil
            }
            return [.moveTo(nx, ny)] + Array(d[2...])
        }

        // Case 2: Deleting the last anchor
        let lastIdx = d.count - 1
        let effectiveLast: Int
        if case .closePath = d[lastIdx] {
            effectiveLast = lastIdx - 1
        } else {
            effectiveLast = lastIdx
        }

        if anchorIdx == effectiveLast {
            var result = Array(d[0..<anchorIdx])
            if effectiveLast < lastIdx {
                result.append(.closePath)
            }
            return result
        }

        // Case 3: Interior anchor - merge adjacent segments
        let cmdAt = d[anchorIdx]
        let cmdAfter = d[anchorIdx + 1]

        var result: [PathCommand] = []
        for (i, cmd) in d.enumerated() {
            if i == anchorIdx {
                // Merge this and the next command
                switch (cmdAt, cmdAfter) {
                case (.curveTo(let x1, let y1, _, _, _, _),
                      .curveTo(_, _, let x2, let y2, let x, let y)):
                    result.append(.curveTo(x1: x1, y1: y1, x2: x2, y2: y2, x: x, y: y))
                case (.curveTo(let x1, let y1, _, _, _, _),
                      .lineTo(let x, let y)):
                    result.append(.curveTo(x1: x1, y1: y1, x2: x, y2: y, x: x, y: y))
                case (.lineTo, .curveTo(_, _, let x2, let y2, let x, let y)):
                    let (px, py): (Double, Double)
                    if anchorIdx > 0 {
                        switch d[anchorIdx - 1] {
                        case .moveTo(let mx, let my),
                             .lineTo(let mx, let my),
                             .curveTo(_, _, _, _, let mx, let my):
                            (px, py) = (mx, my)
                        default: (px, py) = (0, 0)
                        }
                    } else {
                        (px, py) = (0, 0)
                    }
                    result.append(.curveTo(x1: px, y1: py, x2: x2, y2: y2, x: x, y: y))
                case (.lineTo, .lineTo(let x, let y)):
                    result.append(.lineTo(x, y))
                default:
                    break
                }
                continue
            }
            if i == anchorIdx + 1 {
                continue
            }
            result.append(cmd)
        }

        return result
    }

    // MARK: - CanvasTool protocol

    func onPress(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        let doc = ctx.document
        guard let (path, pe, anchorIdx) = Self.hitTestAnchor(doc, px: x, py: y) else {
            return
        }
        ctx.snapshot()
        if let newCmds = Self.deleteAnchorFromPath(pe.d, anchorIdx: anchorIdx) {
            let newElem = Element.path(Path(d: newCmds, fill: pe.fill, stroke: pe.stroke,
                                            opacity: pe.opacity, transform: pe.transform,
                                            locked: pe.locked))
            var newDoc = doc.replaceElement(path, with: newElem)
            // Select the element as a whole after the deletion.
            let _ = newElem.controlPointCount
            let newSelEntry = ElementSelection.all(path)
            var newSelection = newDoc.selection.filter { $0.path != path }
            newSelection.insert(newSelEntry)
            newDoc = Document(layers: newDoc.layers, selectedLayer: newDoc.selectedLayer,
                              selection: newSelection,
                              artboards: newDoc.artboards,
                              artboardOptions: newDoc.artboardOptions)
            ctx.controller.setDocument(newDoc)
        } else {
            // Path too small - remove entirely
            let newDoc = doc.deleteElement(path)
            ctx.controller.setDocument(newDoc)
        }
        ctx.requestUpdate()
    }

    func onMove(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, dragging: Bool) {
    }

    func onRelease(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
    }

    func drawOverlay(_ ctx: ToolContext, _ cgCtx: CGContext) {
    }
}
