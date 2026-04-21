import AppKit
import Foundation

// MARK: - Add Anchor Point Tool

/// Clicking on a path inserts a new smooth anchor point at that location,
/// splitting the clicked bezier segment into two while preserving the
/// curve shape (de Casteljau subdivision).
///
/// Drag after click: adjust outgoing handle (smooth mirrors incoming).
/// Alt+drag: cusp (only outgoing handle moves).
/// Alt+click on existing anchor: toggle smooth/corner.

private let addPointThreshold: Double = hitRadius + 2.0

/// State for an in-progress drag after inserting an anchor point.
private struct DragState {
    /// Path to the element in the document tree.
    var elemPath: ElementPath
    /// Index of the first of the two new CurveTo commands.
    var firstCmdIdx: Int
    /// The anchor point position.
    var anchorX: Double
    var anchorY: Double
    /// Last mouse position (for space-drag repositioning).
    var lastX: Double
    var lastY: Double
}

final class AddAnchorPointTool: CanvasTool {
    private var drag: DragState?
    private var spaceHeld: Bool = false

    /// macOS key code for the Space bar.
    private static let spaceKeyCode: UInt16 = 49

    // MARK: - De Casteljau subdivision

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + t * (b - a)
    }

    /// Split a cubic bezier at parameter t using de Casteljau's algorithm.
    /// Returns two sets of control points for the two halves.
    static func splitCubic(
        x0: Double, y0: Double,
        x1: Double, y1: Double,
        x2: Double, y2: Double,
        x3: Double, y3: Double,
        t: Double
    ) -> ((Double, Double, Double, Double, Double, Double),
          (Double, Double, Double, Double, Double, Double)) {
        // Level 1
        let a1x = lerp(x0, x1, t), a1y = lerp(y0, y1, t)
        let a2x = lerp(x1, x2, t), a2y = lerp(y1, y2, t)
        let a3x = lerp(x2, x3, t), a3y = lerp(y2, y3, t)
        // Level 2
        let b1x = lerp(a1x, a2x, t), b1y = lerp(a1y, a2y, t)
        let b2x = lerp(a2x, a3x, t), b2y = lerp(a2y, a3y, t)
        // Level 3 (the split point)
        let mx = lerp(b1x, b2x, t), my = lerp(b1y, b2y, t)
        return ((a1x, a1y, b1x, b1y, mx, my),
                (b2x, b2y, a3x, a3y, x3, y3))
    }

    // MARK: - Closest segment finding

    /// Evaluate a cubic bezier at parameter t.
    private static func evalCubic(
        x0: Double, y0: Double,
        x1: Double, y1: Double,
        x2: Double, y2: Double,
        x3: Double, y3: Double,
        t: Double
    ) -> (Double, Double) {
        let mt = 1.0 - t
        let x = mt * mt * mt * x0
            + 3 * mt * mt * t * x1
            + 3 * mt * t * t * x2
            + t * t * t * x3
        let y = mt * mt * mt * y0
            + 3 * mt * mt * t * y1
            + 3 * mt * t * t * y2
            + t * t * t * y3
        return (x, y)
    }

    /// Find closest point on a line segment, return (distance, t).
    private static func closestOnLine(
        x0: Double, y0: Double, x1: Double, y1: Double,
        px: Double, py: Double
    ) -> (Double, Double) {
        let dx = x1 - x0, dy = y1 - y0
        let lenSq = dx * dx + dy * dy
        if lenSq == 0 {
            return (hypot(px - x0, py - y0), 0.0)
        }
        let t = max(0, min(1, ((px - x0) * dx + (py - y0) * dy) / lenSq))
        let qx = x0 + t * dx, qy = y0 + t * dy
        return (hypot(px - qx, py - qy), t)
    }

    /// Find closest point on a cubic bezier by sampling + ternary search refinement.
    private static func closestOnCubic(
        x0: Double, y0: Double,
        x1: Double, y1: Double,
        x2: Double, y2: Double,
        x3: Double, y3: Double,
        px: Double, py: Double
    ) -> (Double, Double) {
        let steps = 50
        var bestDist = Double.infinity
        var bestT = 0.0
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let (bx, by) = evalCubic(x0: x0, y0: y0, x1: x1, y1: y1,
                                     x2: x2, y2: y2, x3: x3, y3: y3, t: t)
            let d = hypot(px - bx, py - by)
            if d < bestDist { bestDist = d; bestT = t }
        }
        // Ternary search refinement
        var lo = max(bestT - 1.0 / Double(steps), 0.0)
        var hi = min(bestT + 1.0 / Double(steps), 1.0)
        for _ in 0..<20 {
            let t1 = lo + (hi - lo) / 3.0
            let t2 = hi - (hi - lo) / 3.0
            let (bx1, by1) = evalCubic(x0: x0, y0: y0, x1: x1, y1: y1,
                                       x2: x2, y2: y2, x3: x3, y3: y3, t: t1)
            let (bx2, by2) = evalCubic(x0: x0, y0: y0, x1: x1, y1: y1,
                                       x2: x2, y2: y2, x3: x3, y3: y3, t: t2)
            let d1 = hypot(px - bx1, py - by1)
            let d2 = hypot(px - bx2, py - by2)
            if d1 < d2 { hi = t2 } else { lo = t1 }
        }
        bestT = (lo + hi) / 2.0
        let (bx, by) = evalCubic(x0: x0, y0: y0, x1: x1, y1: y1,
                                 x2: x2, y2: y2, x3: x3, y3: y3, t: bestT)
        bestDist = hypot(px - bx, py - by)
        return (bestDist, bestT)
    }

    /// Find which segment of the path the point is closest to, and the parameter t.
    /// Returns (command_index, t).
    static func closestSegmentAndT(_ d: [PathCommand], px: Double, py: Double) -> (Int, Double)? {
        var bestDist = Double.infinity
        var bestSeg = 0
        var bestT = 0.0
        var cx = 0.0, cy = 0.0

        for (i, cmd) in d.enumerated() {
            switch cmd {
            case .moveTo(let x, let y):
                cx = x; cy = y
            case .lineTo(let x, let y):
                let (dist, t) = closestOnLine(x0: cx, y0: cy, x1: x, y1: y, px: px, py: py)
                if dist < bestDist { bestDist = dist; bestSeg = i; bestT = t }
                cx = x; cy = y
            case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
                let (dist, t) = closestOnCubic(x0: cx, y0: cy, x1: x1, y1: y1,
                                               x2: x2, y2: y2, x3: x, y3: y, px: px, py: py)
                if dist < bestDist { bestDist = dist; bestSeg = i; bestT = t }
                cx = x; cy = y
            case .closePath:
                break
            default:
                // Skip other command types
                if let ep = cmd.endpoint { cx = ep.0; cy = ep.1 }
            }
        }
        return bestDist < Double.infinity ? (bestSeg, bestT) : nil
    }

    // MARK: - Insert point

    struct InsertResult {
        let commands: [PathCommand]
        let firstNewIdx: Int
        let anchorX: Double
        let anchorY: Double
    }

    /// Insert a new anchor point into the path commands at the given segment
    /// and parameter t. Returns new commands, index of first new command, and anchor position.
    static func insertPointInPath(
        _ d: [PathCommand], segIdx: Int, t: Double
    ) -> InsertResult {
        var result: [PathCommand] = []
        var cx = 0.0, cy = 0.0
        var firstNewIdx = 0
        var anchorX = 0.0, anchorY = 0.0

        for (i, cmd) in d.enumerated() {
            if i == segIdx {
                switch cmd {
                case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
                    let ((a1x, a1y, b1x, b1y, mx, my), (b2x, b2y, a3x, a3y, ex, ey)) =
                        splitCubic(x0: cx, y0: cy, x1: x1, y1: y1,
                                   x2: x2, y2: y2, x3: x, y3: y, t: t)
                    firstNewIdx = result.count
                    anchorX = mx; anchorY = my
                    result.append(.curveTo(x1: a1x, y1: a1y, x2: b1x, y2: b1y, x: mx, y: my))
                    result.append(.curveTo(x1: b2x, y1: b2y, x2: a3x, y2: a3y, x: ex, y: ey))
                    cx = x; cy = y
                    continue
                case .lineTo(let x, let y):
                    let mx = Self.lerp(cx, x, t)
                    let my = Self.lerp(cy, y, t)
                    firstNewIdx = result.count
                    anchorX = mx; anchorY = my
                    result.append(.lineTo(mx, my))
                    result.append(.lineTo(x, y))
                    cx = x; cy = y
                    continue
                default:
                    break
                }
            }

            switch cmd {
            case .moveTo(let x, let y):
                cx = x; cy = y
            case .lineTo(let x, let y):
                cx = x; cy = y
            case .curveTo(_, _, _, _, let x, let y):
                cx = x; cy = y
            default:
                if let ep = cmd.endpoint { cx = ep.0; cy = ep.1 }
            }
            result.append(cmd)
        }
        return InsertResult(commands: result, firstNewIdx: firstNewIdx,
                            anchorX: anchorX, anchorY: anchorY)
    }

    // MARK: - Handle updates

    /// Update handles of the newly inserted anchor point.
    /// If cusp is false (smooth), outgoing = drag position and incoming = mirror.
    /// If cusp is true, only the outgoing handle moves.
    static func updateHandles(
        _ cmds: inout [PathCommand],
        firstCmdIdx: Int,
        anchorX: Double, anchorY: Double,
        dragX: Double, dragY: Double,
        cusp: Bool
    ) {
        // Outgoing handle = drag position
        if case .curveTo(_, _, let x2, let y2, let x, let y) = cmds[firstCmdIdx + 1] {
            cmds[firstCmdIdx + 1] = .curveTo(x1: dragX, y1: dragY, x2: x2, y2: y2, x: x, y: y)
        }
        // Incoming handle: mirror (smooth) or leave unchanged (cusp)
        if !cusp {
            if case .curveTo(let x1, let y1, _, _, let x, let y) = cmds[firstCmdIdx] {
                cmds[firstCmdIdx] = .curveTo(x1: x1, y1: y1,
                                             x2: 2.0 * anchorX - dragX,
                                             y2: 2.0 * anchorY - dragY,
                                             x: x, y: y)
            }
        }
    }

    /// Reposition the anchor point, moving handles by the same delta.
    static func repositionAnchor(
        _ cmds: inout [PathCommand],
        firstCmdIdx: Int,
        newAX: Double, newAY: Double,
        dx: Double, dy: Double
    ) {
        if case .curveTo(let x1, let y1, let x2, let y2, _, _) = cmds[firstCmdIdx] {
            cmds[firstCmdIdx] = .curveTo(x1: x1, y1: y1,
                                         x2: x2 + dx, y2: y2 + dy,
                                         x: newAX, y: newAY)
        }
        if firstCmdIdx + 1 < cmds.count {
            if case .curveTo(let x1, let y1, let x2, let y2, let x, let y) = cmds[firstCmdIdx + 1] {
                cmds[firstCmdIdx + 1] = .curveTo(x1: x1 + dx, y1: y1 + dy,
                                                  x2: x2, y2: y2,
                                                  x: x, y: y)
            }
        }
    }

    // MARK: - Hit test existing anchors

    /// Find an existing anchor point on any path near (px, py).
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

    /// Find the command index of an anchor near (px, py).
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

    // MARK: - Hit test path

    /// Find the closest path element in the document to (x, y).
    private static func hitTestPath(
        _ doc: Document, x: Double, y: Double
    ) -> (ElementPath, Path)? {
        for (li, layer) in doc.layers.enumerated() {
            for (ci, child) in layer.children.enumerated() {
                if case .path(let pe) = child {
                    if pathDistanceToPoint(pe.d, px: x, py: y) <= addPointThreshold {
                        return ([li, ci], pe)
                    }
                }
                if case .group(let g) = child, !g.locked {
                    for (gi, gc) in g.children.enumerated() {
                        if case .path(let pe) = gc {
                            if pathDistanceToPoint(pe.d, px: x, py: y) <= addPointThreshold {
                                return ([li, ci, gi], pe)
                            }
                        }
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Toggle smooth/corner

    private static func findPrevAnchor(_ cmds: [PathCommand], _ idx: Int) -> (Double, Double)? {
        for i in stride(from: idx - 1, through: 0, by: -1) {
            switch cmds[i] {
            case .moveTo(let x, let y), .lineTo(let x, let y): return (x, y)
            case .curveTo(_, _, _, _, let x, let y): return (x, y)
            default: continue
            }
        }
        return nil
    }

    private static func findNextAnchor(_ cmds: [PathCommand], _ idx: Int) -> (Double, Double)? {
        for i in (idx + 1)..<cmds.count {
            switch cmds[i] {
            case .moveTo(let x, let y), .lineTo(let x, let y): return (x, y)
            case .curveTo(_, _, _, _, let x, let y): return (x, y)
            default: continue
            }
        }
        return nil
    }

    /// Toggle a point between smooth and corner.
    private static func toggleSmoothCorner(_ cmds: inout [PathCommand], anchorIdx: Int) {
        let (ax, ay): (Double, Double)
        switch cmds[anchorIdx] {
        case .moveTo(let x, let y): (ax, ay) = (x, y)
        case .lineTo(let x, let y): (ax, ay) = (x, y)
        case .curveTo(_, _, _, _, let x, let y): (ax, ay) = (x, y)
        default: return
        }

        // Check if currently a corner (handles at anchor position)
        let inAtAnchor: Bool
        if case .curveTo(_, _, let x2, let y2, _, _) = cmds[anchorIdx] {
            inAtAnchor = abs(x2 - ax) < 0.5 && abs(y2 - ay) < 0.5
        } else {
            inAtAnchor = true
        }

        let outAtAnchor: Bool
        if anchorIdx + 1 < cmds.count,
           case .curveTo(let x1, let y1, _, _, _, _) = cmds[anchorIdx + 1] {
            outAtAnchor = abs(x1 - ax) < 0.5 && abs(y1 - ay) < 0.5
        } else {
            outAtAnchor = true
        }

        let isCorner = inAtAnchor && outAtAnchor

        if isCorner {
            // Convert corner to smooth: extend handles along prev-to-next direction
            guard let (px, py) = findPrevAnchor(cmds, anchorIdx),
                  let (nx, ny) = findNextAnchor(cmds, anchorIdx) else { return }
            let dx = nx - px, dy = ny - py
            let len = hypot(dx, dy)
            guard len > 0 else { return }
            let prevDist = hypot(ax - px, ay - py)
            let nextDist = hypot(nx - ax, ny - ay)
            let ux = dx / len, uy = dy / len
            let inLen = prevDist / 3.0
            let outLen = nextDist / 3.0
            // Set incoming handle
            if case .curveTo(let x1, let y1, _, _, let x, let y) = cmds[anchorIdx] {
                cmds[anchorIdx] = .curveTo(x1: x1, y1: y1,
                                           x2: ax - ux * inLen, y2: ay - uy * inLen,
                                           x: x, y: y)
            }
            // Set outgoing handle
            if anchorIdx + 1 < cmds.count,
               case .curveTo(_, _, let x2, let y2, let x, let y) = cmds[anchorIdx + 1] {
                cmds[anchorIdx + 1] = .curveTo(x1: ax + ux * outLen, y1: ay + uy * outLen,
                                               x2: x2, y2: y2, x: x, y: y)
            }
        } else {
            // Convert smooth to corner: collapse handles to anchor
            if case .curveTo(let x1, let y1, _, _, let x, let y) = cmds[anchorIdx] {
                cmds[anchorIdx] = .curveTo(x1: x1, y1: y1, x2: ax, y2: ay, x: x, y: y)
            }
            if anchorIdx + 1 < cmds.count,
               case .curveTo(_, _, let x2, let y2, let x, let y) = cmds[anchorIdx + 1] {
                cmds[anchorIdx + 1] = .curveTo(x1: ax, y1: ay, x2: x2, y2: y2, x: x, y: y)
            }
        }
    }

    // MARK: - CanvasTool protocol

    func onPress(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        drag = nil
        let doc = ctx.document

        // Alt+click on existing anchor: toggle smooth/corner
        if alt {
            if let (path, pe, anchorIdx) = Self.hitTestAnchor(doc, px: x, py: y) {
                ctx.snapshot()
                var newCmds = pe.d
                Self.toggleSmoothCorner(&newCmds, anchorIdx: anchorIdx)
                let newElem = Element.path(Path(d: newCmds, fill: pe.fill, stroke: pe.stroke,
                                                opacity: pe.opacity, transform: pe.transform,
                                                locked: pe.locked))
                let newDoc = doc.replaceElement(path, with: newElem)
                ctx.controller.setDocument(newDoc)
                ctx.requestUpdate()
                return
            }
        }

        // Click on path: insert anchor point
        if let (path, pe) = Self.hitTestPath(doc, x: x, y: y) {
            if let (segIdx, t) = Self.closestSegmentAndT(pe.d, px: x, py: y) {
                ctx.snapshot()
                let ins = Self.insertPointInPath(pe.d, segIdx: segIdx, t: t)
                let newElem = Element.path(Path(d: ins.commands, fill: pe.fill, stroke: pe.stroke,
                                                opacity: pe.opacity, transform: pe.transform,
                                                locked: pe.locked))
                var newDoc = doc.replaceElement(path, with: newElem)

                // Update selection: shift CP indices after the insertion
                // point and add the new anchor. If the previous selection
                // was `.all`, the new anchor is automatically included.
                let newAnchorIdx = ins.firstNewIdx
                if let oldSel = doc.getElementSelection(path) {
                    let newKind: SelectionKind
                    switch oldSel.kind {
                    case .all:
                        newKind = .all
                    case .partial(let s):
                        var shifted: [Int] = []
                        for cp in s.toArray() {
                            shifted.append(cp >= newAnchorIdx ? cp + 1 : cp)
                        }
                        shifted.append(newAnchorIdx)
                        newKind = .partial(SortedCps(shifted))
                    }
                    let newSelEntry = ElementSelection(path: path, kind: newKind)
                    var newSelection = newDoc.selection.filter { $0.path != path }
                    newSelection.insert(newSelEntry)
                    newDoc = Document(layers: newDoc.layers, selectedLayer: newDoc.selectedLayer,
                                     selection: newSelection,
                                     artboards: newDoc.artboards,
                                     artboardOptions: newDoc.artboardOptions)
                }

                ctx.controller.setDocument(newDoc)
                ctx.requestUpdate()

                // Allow handle dragging if the split produced CurveTo pairs
                if ins.firstNewIdx + 1 < ins.commands.count,
                   case .curveTo = ins.commands[ins.firstNewIdx],
                   case .curveTo = ins.commands[ins.firstNewIdx + 1] {
                    drag = DragState(
                        elemPath: path,
                        firstCmdIdx: ins.firstNewIdx,
                        anchorX: ins.anchorX,
                        anchorY: ins.anchorY,
                        lastX: x, lastY: y
                    )
                }
            }
        }
    }

    func onMove(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, dragging: Bool) {
        guard dragging, var d = drag else { return }
        let alt = NSEvent.modifierFlags.contains(.option)

        let elemPath = d.elemPath
        let idx = d.firstCmdIdx

        let doc = ctx.document
        let elem = doc.getElement(elemPath)
        guard case .path(let pe) = elem else { return }
        var newCmds = pe.d

        if spaceHeld {
            let dx = x - d.lastX, dy = y - d.lastY
            d.lastX = x; d.lastY = y
            d.anchorX += dx; d.anchorY += dy
            Self.repositionAnchor(&newCmds, firstCmdIdx: idx,
                                  newAX: d.anchorX, newAY: d.anchorY,
                                  dx: dx, dy: dy)
        } else {
            d.lastX = x; d.lastY = y
            Self.updateHandles(&newCmds, firstCmdIdx: idx,
                               anchorX: d.anchorX, anchorY: d.anchorY,
                               dragX: x, dragY: y, cusp: alt)
        }
        self.drag = d

        let newElem = Element.path(Path(d: newCmds, fill: pe.fill, stroke: pe.stroke,
                                        opacity: pe.opacity, transform: pe.transform,
                                        locked: pe.locked))
        let newDoc = doc.replaceElement(elemPath, with: newElem)
        ctx.controller.setDocument(newDoc)
        ctx.requestUpdate()
    }

    func onRelease(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        drag = nil
        spaceHeld = false
    }

    func onKey(_ ctx: ToolContext, keyCode: UInt16) -> Bool {
        if keyCode == Self.spaceKeyCode && drag != nil {
            spaceHeld = true
            return true
        }
        return false
    }

    func onKeyUp(_ ctx: ToolContext, keyCode: UInt16) -> Bool {
        if keyCode == Self.spaceKeyCode {
            spaceHeld = false
            return true
        }
        return false
    }

    func drawOverlay(_ ctx: ToolContext, _ cgCtx: CGContext) {
        guard let d = drag else { return }
        let doc = ctx.document
        let elem = doc.getElement(d.elemPath)
        guard case .path(let pe) = elem else { return }
        let idx = d.firstCmdIdx
        guard idx + 1 < pe.d.count else { return }

        // Extract handle positions
        let (inX, inY): (Double, Double)
        let (outX, outY): (Double, Double)
        if case .curveTo(_, _, let x2, let y2, _, _) = pe.d[idx] {
            (inX, inY) = (x2, y2)
        } else { return }
        if case .curveTo(let x1, let y1, _, _, _, _) = pe.d[idx + 1] {
            (outX, outY) = (x1, y1)
        } else { return }

        let ax = d.anchorX, ay = d.anchorY

        // Check if cusp
        let dInX = inX - ax, dInY = inY - ay
        let dOutX = outX - ax, dOutY = outY - ay
        let cross = dInX * dOutY - dInY * dOutX
        let dot = dInX * dOutX + dInY * dOutY
        let inLen = hypot(dInX, dInY)
        let outLen = hypot(dOutX, dOutY)
        let maxLen = max(inLen, outLen)
        let isCusp = maxLen > 0.5 && (abs(cross) > maxLen * 0.01 || dot > 0.0)

        cgCtx.setStrokeColor(toolSelectionColor)
        cgCtx.setLineWidth(1.0)

        if isCusp {
            cgCtx.beginPath()
            cgCtx.move(to: CGPoint(x: ax, y: ay))
            cgCtx.addLine(to: CGPoint(x: inX, y: inY))
            cgCtx.strokePath()
            cgCtx.beginPath()
            cgCtx.move(to: CGPoint(x: ax, y: ay))
            cgCtx.addLine(to: CGPoint(x: outX, y: outY))
            cgCtx.strokePath()
        } else {
            cgCtx.beginPath()
            cgCtx.move(to: CGPoint(x: inX, y: inY))
            cgCtx.addLine(to: CGPoint(x: outX, y: outY))
            cgCtx.strokePath()
        }

        // Handle circles
        let r = 3.0
        cgCtx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        cgCtx.setStrokeColor(toolSelectionColor)
        for (hx, hy) in [(inX, inY), (outX, outY)] {
            cgCtx.fillEllipse(in: CGRect(x: hx - r, y: hy - r, width: r * 2, height: r * 2))
            cgCtx.strokeEllipse(in: CGRect(x: hx - r, y: hy - r, width: r * 2, height: r * 2))
        }

        // Anchor point square
        let half = handleDrawSize / 2.0
        cgCtx.setFillColor(toolSelectionColor)
        cgCtx.fill(CGRect(x: ax - half, y: ay - half, width: handleDrawSize, height: handleDrawSize))
    }
}
