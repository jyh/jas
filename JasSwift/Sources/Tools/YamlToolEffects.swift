// YAML tool-runtime effects — the platformEffects set that YamlTool
// (SWIFT_TOOL_RUNTIME.md Phase 5) registers before dispatching a tool
// handler. Mirrors the doc.* dispatcher the Rust port built inline in
// interpreter/effects.rs.
//
// Phase 2 of the Swift migration covers the selection-family effects
// that only depend on existing Controller APIs:
//   doc.snapshot
//   doc.clear_selection
//   doc.set_selection          { paths: [...] }
//   doc.add_to_selection       path  (raw array or expr)
//   doc.toggle_selection       path
//   doc.translate_selection    { dx, dy }
//   doc.copy_selection         { dx, dy }
//   doc.select_in_rect         { x1, y1, x2, y2, additive }
//   doc.partial_select_in_rect { x1, y1, x2, y2, additive }
//
// Later phases add doc.add_element, the buffer.* / anchor.* effects,
// and the doc.path.* suite as their supporting infra lands.

import Foundation

// MARK: - Public entrypoint

/// Build the platformEffects map YamlTool will hand to runEffects on
/// each dispatch. The returned closures capture `model` by reference
/// (Model is a class), so mutations apply in place.
///
/// Internal (not public) because `PlatformEffect` is a module-private
/// typealias in Effects.swift; same-module callers still see this.
func buildYamlToolEffects(model: Model) -> [String: PlatformEffect] {
    var effects: [String: PlatformEffect] = [:]

    // doc.snapshot — push current document onto the undo stack.
    effects["doc.snapshot"] = { _, _, _ in
        model.snapshot()
        return nil
    }

    // doc.clear_selection — drop the whole selection.
    effects["doc.clear_selection"] = { _, _, _ in
        Controller(model: model).setSelection([])
        return nil
    }

    // doc.set_selection — { paths: [<path-spec>, ...] }. Invalid paths
    // (no element at path) are filtered out, matching the Rust port.
    effects["doc.set_selection"] = { spec, ctx, store in
        let paths = extractPathList(spec, store: store, ctx: ctx)
        let doc = model.document
        let valid = paths.compactMap { p -> ElementSelection? in
            isValidPath(doc, p) ? ElementSelection.all(p) : nil
        }
        Controller(model: model).setSelection(Set(valid))
        return nil
    }

    // doc.add_to_selection — `path` (raw array or expression).
    // Idempotent: no-op if the path is already in the selection.
    effects["doc.add_to_selection"] = { spec, ctx, store in
        guard let path = extractPath(spec, store: store, ctx: ctx) else {
            return nil
        }
        var sel = model.document.selection
        if sel.contains(where: { $0.path == path }) {
            return nil
        }
        sel.insert(ElementSelection.all(path))
        Controller(model: model).setSelection(sel)
        return nil
    }

    // doc.toggle_selection — add if absent, remove if present.
    effects["doc.toggle_selection"] = { spec, ctx, store in
        guard let path = extractPath(spec, store: store, ctx: ctx) else {
            return nil
        }
        var sel = model.document.selection
        if let existing = sel.first(where: { $0.path == path }) {
            sel.remove(existing)
        } else {
            sel.insert(ElementSelection.all(path))
        }
        Controller(model: model).setSelection(sel)
        return nil
    }

    // doc.translate_selection — { dx, dy } (either numbers or expressions).
    effects["doc.translate_selection"] = { spec, ctx, store in
        guard let args = spec as? [String: Any] else { return nil }
        let dx = evalNumber(args["dx"], store: store, ctx: ctx)
        let dy = evalNumber(args["dy"], store: store, ctx: ctx)
        if dx == 0 && dy == 0 { return nil }
        Controller(model: model).moveSelection(dx: dx, dy: dy)
        return nil
    }

    // doc.copy_selection — { dx, dy }. Duplicates the selected elements
    // at an offset and reselects the copies.
    effects["doc.copy_selection"] = { spec, ctx, store in
        guard let args = spec as? [String: Any] else { return nil }
        let dx = evalNumber(args["dx"], store: store, ctx: ctx)
        let dy = evalNumber(args["dy"], store: store, ctx: ctx)
        Controller(model: model).copySelection(dx: dx, dy: dy)
        return nil
    }

    // doc.select_in_rect — { x1, y1, x2, y2, additive }. Uses the
    // axis-aligned box between (x1,y1) and (x2,y2); additive bool
    // maps to the Controller's `extend` flag.
    effects["doc.select_in_rect"] = { spec, ctx, store in
        guard let args = spec as? [String: Any] else { return nil }
        let (rx, ry, rw, rh, additive) = normalizeRectArgs(args, store: store, ctx: ctx)
        Controller(model: model).selectRect(x: rx, y: ry, width: rw, height: rh, extend: additive)
        return nil
    }

    // doc.partial_select_in_rect — same shape, routes through
    // directSelectRect so each entry becomes SelectionKind.partial
    // (control-point granularity) rather than .all.
    effects["doc.partial_select_in_rect"] = { spec, ctx, store in
        guard let args = spec as? [String: Any] else { return nil }
        let (rx, ry, rw, rh, additive) = normalizeRectArgs(args, store: store, ctx: ctx)
        Controller(model: model).directSelectRect(x: rx, y: ry, width: rw, height: rh, extend: additive)
        return nil
    }

    // doc.add_element — { element: { type: rect|line|polygon|star, ... } }.
    // Builds an Element from the spec and appends it to the document via
    // Controller.addElement (which targets the selected layer, matching
    // the native drawing-tool semantics). Unknown types no-op.
    effects["doc.add_element"] = { spec, ctx, store in
        guard let args = spec as? [String: Any],
              let elemSpec = args["element"] as? [String: Any] else {
            return nil
        }
        guard let element = buildElement(
            elemSpec, model: model, store: store, ctx: ctx
        ) else { return nil }
        Controller(model: model).addElement(element)
        return nil
    }

    // doc.path.delete_anchor_near — { x, y, hit_radius? }.
    // Finds the anchor under the cursor and deletes it via
    // deleteAnchorFromPath. If the path would drop below 2 anchors, the
    // whole element is removed. Snapshots once on commit.
    effects["doc.path.delete_anchor_near"] = { spec, ctx, store in
        guard let args = spec as? [String: Any] else { return nil }
        let x = evalNumber(args["x"], store: store, ctx: ctx)
        let y = evalNumber(args["y"], store: store, ctx: ctx)
        let rawR = evalNumber(args["hit_radius"], store: store, ctx: ctx)
        let radius = rawR == 0 ? 8.0 : rawR
        pathDeleteAnchorNear(model: model, x: x, y: y, radius: radius)
        return nil
    }

    // doc.path.insert_anchor_on_segment_near — { x, y, hit_radius? }.
    // Walks all unlocked Paths in the document, finds the segment
    // closest to (x, y), and inserts a new anchor at that t. Snapshots
    // once on commit.
    effects["doc.path.insert_anchor_on_segment_near"] = { spec, ctx, store in
        guard let args = spec as? [String: Any] else { return nil }
        let x = evalNumber(args["x"], store: store, ctx: ctx)
        let y = evalNumber(args["y"], store: store, ctx: ctx)
        let rawR = evalNumber(args["hit_radius"], store: store, ctx: ctx)
        let radius = rawR == 0 ? 8.0 : rawR
        pathInsertAnchorOnSegmentNear(model: model, x: x, y: y, radius: radius)
        return nil
    }

    // doc.path.erase_at_rect — { last_x, last_y, x, y, eraser_size? }.
    // Sweeps a rectangle from (last_x, last_y) to (x, y) expanded by
    // eraser_size. Paths whose bbox fits inside get deleted; hit paths
    // are split via De Casteljau-preserving geometry. Snapshot is the
    // YAML handler's responsibility (typically on mousedown).
    effects["doc.path.erase_at_rect"] = { spec, ctx, store in
        guard let args = spec as? [String: Any] else { return nil }
        let lastX = evalNumber(args["last_x"], store: store, ctx: ctx)
        let lastY = evalNumber(args["last_y"], store: store, ctx: ctx)
        let x = evalNumber(args["x"], store: store, ctx: ctx)
        let y = evalNumber(args["y"], store: store, ctx: ctx)
        let raw = evalNumber(args["eraser_size"], store: store, ctx: ctx)
        let eraserSize = raw == 0 ? 2.0 : raw
        pathEraseAtRect(model: model, lastX: lastX, lastY: lastY,
                        x: x, y: y, eraserSize: eraserSize)
        return nil
    }

    // doc.path.smooth_at_cursor — { x, y, radius?, fit_error? }.
    // Iterates selected unlocked Paths, finds the contiguous flat
    // range within `radius` of (x, y), re-fits it via fitCurve with
    // the given error tolerance (defaults radius=100, fit_error=8).
    effects["doc.path.smooth_at_cursor"] = { spec, ctx, store in
        guard let args = spec as? [String: Any] else { return nil }
        let x = evalNumber(args["x"], store: store, ctx: ctx)
        let y = evalNumber(args["y"], store: store, ctx: ctx)
        let rawR = evalNumber(args["radius"], store: store, ctx: ctx)
        let radius = rawR == 0 ? 100.0 : rawR
        let rawE = evalNumber(args["fit_error"], store: store, ctx: ctx)
        let fitError = rawE == 0 ? 8.0 : rawE
        pathSmoothAtCursor(model: model, x: x, y: y,
                           radius: radius, fitError: fitError)
        return nil
    }

    // doc.path.probe_anchor_hit — { x, y, hit_radius? }. Hit-tests in
    // priority order (handle → smooth → corner) and stashes the result
    // on the anchor_point tool scope (`mode`, `handle_type`,
    // `hit_anchor_idx`, `hit_path` as a {__path__: [ints]} dict).
    effects["doc.path.probe_anchor_hit"] = { spec, ctx, store in
        guard let args = spec as? [String: Any] else { return nil }
        let x = evalNumber(args["x"], store: store, ctx: ctx)
        let y = evalNumber(args["y"], store: store, ctx: ctx)
        let rawR = evalNumber(args["hit_radius"], store: store, ctx: ctx)
        let radius = rawR == 0 ? 8.0 : rawR
        pathProbeAnchorHit(model: model, store: store,
                           x: x, y: y, radius: radius)
        return nil
    }

    // doc.path.commit_anchor_edit — { target_x, target_y, origin_x,
    // origin_y }. Reads the latched anchor_point state and applies the
    // corresponding mutation: smooth→corner, corner→smooth-at-target,
    // handle→move-by-delta.
    effects["doc.path.commit_anchor_edit"] = { spec, ctx, store in
        guard let args = spec as? [String: Any] else { return nil }
        let tx = evalNumber(args["target_x"], store: store, ctx: ctx)
        let ty = evalNumber(args["target_y"], store: store, ctx: ctx)
        let ox = evalNumber(args["origin_x"], store: store, ctx: ctx)
        let oy = evalNumber(args["origin_y"], store: store, ctx: ctx)
        pathCommitAnchorEdit(model: model, store: store,
                             originX: ox, originY: oy,
                             targetX: tx, targetY: ty)
        return nil
    }

    // doc.path.probe_partial_hit — { x, y, hit_radius?, shift }. Hit
    // priority: handle on selected Path (→ "handle"), any unlocked CP
    // (→ "moving_pending" plus selection update), else "marquee".
    effects["doc.path.probe_partial_hit"] = { spec, ctx, store in
        guard let args = spec as? [String: Any] else { return nil }
        let x = evalNumber(args["x"], store: store, ctx: ctx)
        let y = evalNumber(args["y"], store: store, ctx: ctx)
        let rawR = evalNumber(args["hit_radius"], store: store, ctx: ctx)
        let radius = rawR == 0 ? 8.0 : rawR
        let shift = evalBool(args["shift"], store: store, ctx: ctx)
        pathProbePartialHit(model: model, store: store,
                            x: x, y: y, radius: radius, shift: shift)
        return nil
    }

    // doc.move_path_handle — { dx, dy }. Reads the latched
    // partial_selection handle state and applies a handle move by
    // (dx, dy). No-op if nothing's latched.
    effects["doc.move_path_handle"] = { spec, ctx, store in
        guard let args = spec as? [String: Any] else { return nil }
        let dx = evalNumber(args["dx"], store: store, ctx: ctx)
        let dy = evalNumber(args["dy"], store: store, ctx: ctx)
        pathMoveLatchedHandle(model: model, store: store, dx: dx, dy: dy)
        return nil
    }

    // doc.path.commit_partial_marquee — { x1, y1, x2, y2, additive }.
    // Called on mouseup in Partial Selection's marquee mode; empty-ish
    // rects without shift clear the selection.
    effects["doc.path.commit_partial_marquee"] = { spec, ctx, store in
        guard let args = spec as? [String: Any] else { return nil }
        let (rx, ry, rw, rh, additive) = normalizeRectArgs(args, store: store, ctx: ctx)
        if rw > 1.0 || rh > 1.0 {
            model.snapshot()
            Controller(model: model).directSelectRect(
                x: rx, y: ry, width: rw, height: rh, extend: additive)
        } else if !additive {
            Controller(model: model).setSelection([])
        }
        return nil
    }

    // ── Buffer effects (Phase 3) ─────────────────────────────────

    // buffer.push: { buffer, x, y } — append to named point buffer.
    effects["buffer.push"] = { spec, ctx, store in
        guard let args = spec as? [String: Any],
              let name = args["buffer"] as? String else { return nil }
        let x = evalNumber(args["x"], store: store, ctx: ctx)
        let y = evalNumber(args["y"], store: store, ctx: ctx)
        pointBuffersPush(name, x, y)
        return nil
    }

    // buffer.clear: { buffer }
    effects["buffer.clear"] = { spec, ctx, _ in
        guard let args = spec as? [String: Any],
              let name = args["buffer"] as? String else { return nil }
        pointBuffersClear(name)
        return nil
    }

    // anchor.push: { buffer, x, y } — append a corner anchor.
    effects["anchor.push"] = { spec, ctx, store in
        guard let args = spec as? [String: Any],
              let name = args["buffer"] as? String else { return nil }
        let x = evalNumber(args["x"], store: store, ctx: ctx)
        let y = evalNumber(args["y"], store: store, ctx: ctx)
        anchorBuffersPush(name, x, y)
        return nil
    }

    // anchor.set_last_out: { buffer, hx, hy } — convert last anchor
    // into smooth, mirroring the in-handle.
    effects["anchor.set_last_out"] = { spec, ctx, store in
        guard let args = spec as? [String: Any],
              let name = args["buffer"] as? String else { return nil }
        let hx = evalNumber(args["hx"], store: store, ctx: ctx)
        let hy = evalNumber(args["hy"], store: store, ctx: ctx)
        anchorBuffersSetLastOutHandle(name, hx, hy)
        return nil
    }

    // anchor.pop: { buffer } — drop last anchor.
    effects["anchor.pop"] = { spec, _, _ in
        guard let args = spec as? [String: Any],
              let name = args["buffer"] as? String else { return nil }
        anchorBuffersPop(name)
        return nil
    }

    // anchor.clear: { buffer }
    effects["anchor.clear"] = { spec, _, _ in
        guard let args = spec as? [String: Any],
              let name = args["buffer"] as? String else { return nil }
        anchorBuffersClear(name)
        return nil
    }

    // doc.select_polygon_from_buffer: { buffer, additive }
    // Uses the named point buffer as a selection polygon.
    effects["doc.select_polygon_from_buffer"] = { spec, ctx, store in
        guard let args = spec as? [String: Any],
              let name = args["buffer"] as? String else { return nil }
        let additive = evalBool(args["additive"], store: store, ctx: ctx)
        let points = pointBuffersPoints(name)
        guard points.count >= 3 else { return nil }
        Controller(model: model).selectPolygon(polygon: points, extend: additive)
        return nil
    }

    // doc.add_path_from_buffer: { buffer, fit_error? }
    // Runs fitCurve on the named buffer and appends a cubic-Bezier
    // Path to the document. Used by Pencil.
    effects["doc.add_path_from_buffer"] = { spec, ctx, store in
        guard let args = spec as? [String: Any],
              let name = args["buffer"] as? String else { return nil }
        let fitError = evalNumberWithDefault(args["fit_error"],
                                             default: 4.0,
                                             store: store, ctx: ctx)
        let points = pointBuffersPoints(name)
        guard points.count >= 2 else { return nil }
        let segments = fitCurve(points: points, error: fitError)
        guard !segments.isEmpty else { return nil }
        // FitSegment: p1 = start, c1/c2 = control handles, p2 = end.
        var cmds: [PathCommand] = []
        cmds.append(.moveTo(segments[0].p1x, segments[0].p1y))
        for seg in segments {
            cmds.append(.curveTo(
                x1: seg.c1x, y1: seg.c1y,
                x2: seg.c2x, y2: seg.c2y,
                x: seg.p2x, y: seg.p2y
            ))
        }
        let pathElem = makePathFromCommands(
            cmds, model: model, spec: args,
            store: store, ctx: ctx)
        Controller(model: model).addElement(.path(pathElem))
        return nil
    }

    // doc.add_path_from_anchor_buffer: { buffer, closed }
    // Walks the anchor buffer emitting MoveTo + CurveTo per adjacent
    // pair; appends a closing CurveTo + ClosePath when closed=true.
    effects["doc.add_path_from_anchor_buffer"] = { spec, ctx, store in
        guard let args = spec as? [String: Any],
              let name = args["buffer"] as? String else { return nil }
        let closed = evalBool(args["closed"], store: store, ctx: ctx)
        let anchors = anchorBuffersAnchors(name)
        guard anchors.count >= 2 else { return nil }
        var cmds: [PathCommand] = [.moveTo(anchors[0].x, anchors[0].y)]
        for i in 1..<anchors.count {
            let prev = anchors[i - 1]
            let curr = anchors[i]
            cmds.append(.curveTo(
                x1: prev.hxOut, y1: prev.hyOut,
                x2: curr.hxIn, y2: curr.hyIn,
                x: curr.x, y: curr.y
            ))
        }
        if closed {
            let last = anchors.last!
            let first = anchors[0]
            cmds.append(.curveTo(
                x1: last.hxOut, y1: last.hyOut,
                x2: first.hxIn, y2: first.hyIn,
                x: first.x, y: first.y
            ))
            cmds.append(.closePath)
        }
        let pathElem = makePathFromCommands(
            cmds, model: model, spec: args,
            store: store, ctx: ctx)
        Controller(model: model).addElement(.path(pathElem))
        return nil
    }

    return effects
}

/// Build a Path element from a command list, applying model defaults
/// for fill/stroke when the spec omits them. Shared by
/// doc.add_path_from_buffer and doc.add_path_from_anchor_buffer.
///
/// Also threads an optional `stroke_brush` expression from spec onto
/// the new Path. The Paintbrush tool's on_mouseup handler passes
/// `stroke_brush: "state.stroke_brush"` so the active brush from the
/// panel rides through to the canvas renderer's brush dispatch
/// (BRUSHES.md §Stroke styling interaction).
private func makePathFromCommands(
    _ cmds: [PathCommand],
    model: Model,
    spec: [String: Any],
    store: StateStore,
    ctx: [String: Any]
) -> Path {
    let fill = resolveFillField(spec["fill"], hasKey: spec.keys.contains("fill"),
                                 default: model.defaultFill,
                                 store: store, ctx: ctx)
    let stroke = resolveStrokeField(spec["stroke"], hasKey: spec.keys.contains("stroke"),
                                     default: model.defaultStroke,
                                     store: store, ctx: ctx)
    let strokeBrush = resolveStrokeBrushField(spec["stroke_brush"],
                                              hasKey: spec.keys.contains("stroke_brush"),
                                              store: store, ctx: ctx)
    return Path(d: cmds, fill: fill, stroke: stroke,
                strokeBrush: strokeBrush)
}

/// Resolve an optional `stroke_brush:` field on a path-creating
/// effect. Absent or evaluates to null/empty → nil (plain native
/// stroke); a non-empty string → that brush slug. Mirrors the JS and
/// Rust passthroughs.
private func resolveStrokeBrushField(
    _ arg: Any?, hasKey: Bool,
    store: StateStore, ctx: [String: Any]
) -> String? {
    guard hasKey else { return nil }
    let v = evalExprAsValue(arg, store: store, ctx: ctx)
    if case .string(let s) = v, !s.isEmpty {
        return s
    }
    return nil
}

/// Resolve an optional `fill:` field. Absent → default; null → nil;
/// explicit color (Value or hex string) → Fill with that color.
private func resolveFillField(
    _ arg: Any?, hasKey: Bool, default defVal: Fill?,
    store: StateStore, ctx: [String: Any]
) -> Fill? {
    guard hasKey else { return defVal }
    let v = evalExprAsValue(arg, store: store, ctx: ctx)
    switch v {
    case .null: return nil
    case .color(let c): return Color.fromHex(c).map { Fill(color: $0) } ?? defVal
    case .string(let s): return Color.fromHex(s).map { Fill(color: $0) } ?? defVal
    default: return defVal
    }
}

/// Resolve an optional `stroke:` field — same semantics as
/// resolveFillField, building a 1pt-wide Stroke with default caps/joins.
private func resolveStrokeField(
    _ arg: Any?, hasKey: Bool, default defVal: Stroke?,
    store: StateStore, ctx: [String: Any]
) -> Stroke? {
    guard hasKey else { return defVal }
    let v = evalExprAsValue(arg, store: store, ctx: ctx)
    switch v {
    case .null: return nil
    case .color(let c):
        return Color.fromHex(c).map { Stroke(color: $0, width: 1.0) } ?? defVal
    case .string(let s):
        return Color.fromHex(s).map { Stroke(color: $0, width: 1.0) } ?? defVal
    default: return defVal
    }
}

// MARK: - Path-editing helpers (doc.path.* effects)

/// Walk layers (one level of group nesting) looking for a Path whose
/// command list has an anchor within `radius` of (x, y). Returns
/// `(element path, command index)`.
private func findPathAnchorNear(
    _ doc: Document, x: Double, y: Double, radius: Double
) -> (ElementPath, Int)? {
    for (li, layer) in doc.layers.enumerated() {
        for (ci, child) in layer.children.enumerated() {
            if case .path(let pe) = child, !pe.locked,
               let idx = anchorIndexNear(pe.d, x: x, y: y, radius: radius) {
                return ([li, ci], idx)
            }
            if case .group(let g) = child, !g.locked {
                for (gi, gc) in g.children.enumerated() {
                    if case .path(let pe) = gc, !pe.locked,
                       let idx = anchorIndexNear(pe.d, x: x, y: y, radius: radius) {
                        return ([li, ci, gi], idx)
                    }
                }
            }
        }
    }
    return nil
}

/// Return the command index of the anchor on `d` closest to (x, y)
/// within `radius`. Only MoveTo / LineTo / CurveTo count as anchors.
private func anchorIndexNear(
    _ d: [PathCommand], x: Double, y: Double, radius: Double
) -> Int? {
    for (i, cmd) in d.enumerated() {
        let pt: (Double, Double)
        switch cmd {
        case .moveTo(let px, let py): pt = (px, py)
        case .lineTo(let px, let py): pt = (px, py)
        case .curveTo(_, _, _, _, let px, let py): pt = (px, py)
        default: continue
        }
        let dx = x - pt.0, dy = y - pt.1
        if (dx * dx + dy * dy).squareRoot() <= radius {
            return i
        }
    }
    return nil
}

/// Reconstruct a Path element with replaced command list, carrying
/// over fill/stroke/opacity/transform/lock state. Shared by all
/// doc.path.* effects that rewrite a path's d.
private func pathWithCommands(_ pe: Path, _ cmds: [PathCommand]) -> Path {
    return Path(d: cmds, fill: pe.fill, stroke: pe.stroke,
                opacity: pe.opacity, transform: pe.transform,
                locked: pe.locked,
                visibility: pe.visibility,
                blendMode: pe.blendMode,
                mask: pe.mask,
                fillGradient: pe.fillGradient,
                strokeGradient: pe.strokeGradient)
}

/// Implementation of doc.path.delete_anchor_near.
private func pathDeleteAnchorNear(
    model: Model, x: Double, y: Double, radius: Double
) {
    guard let (path, anchorIdx) = findPathAnchorNear(
        model.document, x: x, y: y, radius: radius
    ) else { return }
    guard case .path(let pe) = model.document.getElement(path) else { return }
    model.snapshot()
    if let newCmds = deleteAnchorFromPath(pe.d, anchorIdx) {
        let newPe = pathWithCommands(pe, newCmds)
        var doc = model.document.replaceElement(path, with: .path(newPe))
        // Keep the path in the selection (matches native Delete-anchor).
        var sel = doc.selection
        sel = sel.filter { $0.path != path }
        sel.insert(ElementSelection.all(path))
        doc = Document(layers: doc.layers, selectedLayer: doc.selectedLayer,
                       selection: sel,
                       artboards: doc.artboards,
                       artboardOptions: doc.artboardOptions)
        model.document = doc
    } else {
        // Path too small — remove the element entirely.
        model.document = model.document.deleteElement(path)
    }
}

/// Implementation of doc.path.insert_anchor_on_segment_near.
private func pathInsertAnchorOnSegmentNear(
    model: Model, x: Double, y: Double, radius: Double
) {
    var best: (ElementPath, Int, Double, Double)? = nil
    func tryPath(_ pe: Path, at path: ElementPath) {
        guard let (segIdx, t) = closestSegmentAndT(pe.d, x, y) else { return }
        let dist = projectionDistance(pe.d, segIdx: segIdx, x: x, y: y)
        if let cur = best, cur.3 <= dist { return }
        best = (path, segIdx, t, dist)
    }
    for (li, layer) in model.document.layers.enumerated() {
        for (ci, child) in layer.children.enumerated() {
            if case .path(let pe) = child, !pe.locked {
                tryPath(pe, at: [li, ci])
            }
            if case .group(let g) = child, !g.locked {
                for (gi, gc) in g.children.enumerated() {
                    if case .path(let pe) = gc, !pe.locked {
                        tryPath(pe, at: [li, ci, gi])
                    }
                }
            }
        }
    }
    guard let hit = best, hit.3 <= radius else { return }
    guard case .path(let pe) = model.document.getElement(hit.0) else { return }
    model.snapshot()
    let ins = insertPointInPath(pe.d, hit.1, hit.2)
    let newPe = pathWithCommands(pe, ins.commands)
    model.document = model.document.replaceElement(hit.0, with: .path(newPe))
}

/// Re-project (x, y) onto the segment at `segIdx` to recover the
/// distance value (closestSegmentAndT returns (idx, t) only).
private func projectionDistance(
    _ d: [PathCommand], segIdx: Int, x: Double, y: Double
) -> Double {
    var cx: Double = 0, cy: Double = 0
    for (i, cmd) in d.enumerated() {
        switch cmd {
        case .moveTo(let mx, let my): cx = mx; cy = my
        case .lineTo(let lx, let ly):
            if i == segIdx {
                let (dist, _) = closestOnLine(cx, cy, lx, ly, x, y)
                return dist
            }
            cx = lx; cy = ly
        case .curveTo(let x1, let y1, let x2, let y2, let ex, let ey):
            if i == segIdx {
                let (dist, _) = closestOnCubic(cx, cy, x1, y1, x2, y2, ex, ey, x, y)
                return dist
            }
            cx = ex; cy = ey
        default: break
        }
    }
    return .infinity
}

/// Implementation of doc.path.erase_at_rect.
private func pathEraseAtRect(
    model: Model, lastX: Double, lastY: Double,
    x: Double, y: Double, eraserSize: Double
) {
    let minX = min(lastX, x) - eraserSize
    let minY = min(lastY, y) - eraserSize
    let maxX = max(lastX, x) + eraserSize
    let maxY = max(lastY, y) + eraserSize

    var newLayers = model.document.layers
    var changed = false
    for li in 0..<newLayers.count {
        let layer = newLayers[li]
        var newChildren: [Element] = []
        var layerChanged = false
        for child in layer.children {
            guard case .path(let pe) = child, !pe.locked else {
                newChildren.append(child)
                continue
            }
            let flat = flattenPathCommands(pe.d)
            guard flat.count >= 2 else {
                newChildren.append(child)
                continue
            }
            guard let hit = findEraserHit(
                flat, minX, minY, maxX, maxY
            ) else {
                newChildren.append(child)
                continue
            }
            let bounds = pe.bounds
            if bounds.width <= eraserSize * 2 && bounds.height <= eraserSize * 2 {
                // bbox fits inside the eraser — drop entirely.
                layerChanged = true
                continue
            }
            let isClosed = pe.d.contains { if case .closePath = $0 { return true }; return false }
            let results = splitPathAtEraser(pe.d, hit, isClosed)
            for cmds in results where cmds.count >= 2 {
                let open = cmds.filter { if case .closePath = $0 { return false }; return true }
                newChildren.append(.path(pathWithCommands(pe, open)))
            }
            layerChanged = true
        }
        if layerChanged {
            newLayers[li] = Layer(name: layer.name, children: newChildren,
                                   opacity: layer.opacity, transform: layer.transform,
                                   locked: layer.locked,
                                   visibility: layer.visibility,
                                   blendMode: layer.blendMode,
                                   isolatedBlending: layer.isolatedBlending,
                                   knockoutGroup: layer.knockoutGroup,
                                   mask: layer.mask)
            changed = true
        }
    }
    if changed {
        let doc = model.document
        model.document = Document(
            layers: newLayers, selectedLayer: doc.selectedLayer,
            selection: [],
            artboards: doc.artboards,
            artboardOptions: doc.artboardOptions
        )
    }
}

// MARK: - Anchor / handle probe helpers

/// Serialize an ElementPath into the `{"__path__": [Int]}` dict
/// representation used by tool-scope state.
private func encodePath(_ path: ElementPath) -> [String: Any] {
    return ["__path__": path as [Any]]
}

/// Decode a path from tool-scope state. Returns nil on malformed input.
private func decodePath(_ v: Any?) -> ElementPath? {
    guard let obj = v as? [String: Any], let arr = obj["__path__"] as? [Any] else {
        return nil
    }
    var out: ElementPath = []
    for item in arr {
        if let n = item as? NSNumber { out.append(n.intValue) }
        else if let i = item as? Int { out.append(i) }
        else { return nil }
    }
    return out
}

/// Find a path-handle hit: (element path, anchor index, "in"|"out").
private func findPathHandleNear(
    _ doc: Document, x: Double, y: Double, radius: Double
) -> (ElementPath, Int, String)? {
    func check(_ pe: Path, at path: ElementPath)
        -> (ElementPath, Int, String)?
    {
        let anchors = Element.path(pe).controlPointPositions
        for ai in anchors.indices {
            let (hIn, hOut) = pathHandlePositions(pe.d, anchorIdx: ai)
            if let h = hIn {
                let dx = x - h.0, dy = y - h.1
                if (dx * dx + dy * dy).squareRoot() < radius {
                    return (path, ai, "in")
                }
            }
            if let h = hOut {
                let dx = x - h.0, dy = y - h.1
                if (dx * dx + dy * dy).squareRoot() < radius {
                    return (path, ai, "out")
                }
            }
        }
        return nil
    }
    for (li, layer) in doc.layers.enumerated() {
        for (ci, child) in layer.children.enumerated() {
            if case .path(let pe) = child, !pe.locked,
               let r = check(pe, at: [li, ci]) { return r }
            if case .group(let g) = child, !g.locked {
                for (gi, gc) in g.children.enumerated() {
                    if case .path(let pe) = gc, !pe.locked,
                       let r = check(pe, at: [li, ci, gi]) { return r }
                }
            }
        }
    }
    return nil
}

/// Find a path-anchor hit using the control-point enumeration.
/// Returns (element path, anchor index within controlPointPositions).
private func findPathAnchorByCp(
    _ doc: Document, x: Double, y: Double, radius: Double
) -> (ElementPath, Int)? {
    func check(_ pe: Path, at path: ElementPath) -> (ElementPath, Int)? {
        let anchors = Element.path(pe).controlPointPositions
        for (i, pt) in anchors.enumerated() {
            let dx = x - pt.0, dy = y - pt.1
            if (dx * dx + dy * dy).squareRoot() < radius {
                return (path, i)
            }
        }
        return nil
    }
    for (li, layer) in doc.layers.enumerated() {
        for (ci, child) in layer.children.enumerated() {
            if case .path(let pe) = child, !pe.locked,
               let r = check(pe, at: [li, ci]) { return r }
            if case .group(let g) = child, !g.locked {
                for (gi, gc) in g.children.enumerated() {
                    if case .path(let pe) = gc, !pe.locked,
                       let r = check(pe, at: [li, ci, gi]) { return r }
                }
            }
        }
    }
    return nil
}

/// Implementation of doc.path.probe_anchor_hit. Writes state into the
/// `anchor_point` tool scope.
private func pathProbeAnchorHit(
    model: Model, store: StateStore,
    x: Double, y: Double, radius: Double
) {
    if let (path, anchorIdx, handleType) = findPathHandleNear(
        model.document, x: x, y: y, radius: radius
    ) {
        store.setTool("anchor_point", "mode", "pressed_handle")
        store.setTool("anchor_point", "handle_type", handleType)
        store.setTool("anchor_point", "hit_anchor_idx", anchorIdx)
        store.setTool("anchor_point", "hit_path", encodePath(path))
        return
    }
    if let (path, anchorIdx) = findPathAnchorByCp(
        model.document, x: x, y: y, radius: radius
    ) {
        guard case .path(let pe) = model.document.getElement(path) else { return }
        let mode = isSmoothPoint(pe.d, anchorIdx: anchorIdx)
            ? "pressed_smooth" : "pressed_corner"
        store.setTool("anchor_point", "mode", mode)
        store.setTool("anchor_point", "hit_anchor_idx", anchorIdx)
        store.setTool("anchor_point", "hit_path", encodePath(path))
        return
    }
    store.setTool("anchor_point", "mode", "idle")
}

/// Implementation of doc.path.commit_anchor_edit.
private func pathCommitAnchorEdit(
    model: Model, store: StateStore,
    originX: Double, originY: Double,
    targetX: Double, targetY: Double
) {
    let mode = (store.getTool("anchor_point", "mode") as? String) ?? "idle"
    if mode == "idle" { return }
    guard let path = decodePath(store.getTool("anchor_point", "hit_path")) else {
        return
    }
    let anchorIdx: Int = {
        if let n = store.getTool("anchor_point", "hit_anchor_idx") as? Int { return n }
        if let n = store.getTool("anchor_point", "hit_anchor_idx") as? NSNumber { return n.intValue }
        return 0
    }()
    guard case .path(let pe) = model.document.getElement(path) else { return }
    switch mode {
    case "pressed_smooth":
        model.snapshot()
        let newCmds = convertSmoothToCorner(pe.d, anchorIdx: anchorIdx)
        model.document = model.document.replaceElement(
            path, with: .path(pathWithCommands(pe, newCmds)))
    case "pressed_corner":
        let moved = hypot(targetX - originX, targetY - originY)
        if moved <= 1.0 { return }
        model.snapshot()
        let newCmds = convertCornerToSmooth(
            pe.d, anchorIdx: anchorIdx, hx: targetX, hy: targetY)
        model.document = model.document.replaceElement(
            path, with: .path(pathWithCommands(pe, newCmds)))
    case "pressed_handle":
        let handleType = (store.getTool("anchor_point", "handle_type") as? String) ?? ""
        let dx = targetX - originX, dy = targetY - originY
        if abs(dx) <= 0.5 && abs(dy) <= 0.5 { return }
        model.snapshot()
        let newCmds = movePathHandleIndependent(
            pe.d, anchorIdx: anchorIdx,
            handleType: handleType, dx: dx, dy: dy)
        model.document = model.document.replaceElement(
            path, with: .path(pathWithCommands(pe, newCmds)))
    default: break
    }
}

/// Implementation of doc.path.probe_partial_hit.
private func pathProbePartialHit(
    model: Model, store: StateStore,
    x: Double, y: Double, radius: Double, shift: Bool
) {
    // 1. Handle hit on a selected Path.
    for es in model.document.selection {
        guard case .path(let pe) = model.document.getElement(es.path) else { continue }
        let anchors = Element.path(pe).controlPointPositions
        for ai in anchors.indices {
            let (hIn, hOut) = pathHandlePositions(pe.d, anchorIdx: ai)
            func matches(_ h: (Double, Double)?) -> Bool {
                guard let h = h else { return false }
                return hypot(x - h.0, y - h.1) < radius
            }
            if matches(hIn) {
                store.setTool("partial_selection", "mode", "handle")
                store.setTool("partial_selection", "handle_anchor_idx", ai)
                store.setTool("partial_selection", "handle_type", "in")
                store.setTool("partial_selection", "handle_path", encodePath(es.path))
                return
            }
            if matches(hOut) {
                store.setTool("partial_selection", "mode", "handle")
                store.setTool("partial_selection", "handle_anchor_idx", ai)
                store.setTool("partial_selection", "handle_type", "out")
                store.setTool("partial_selection", "handle_path", encodePath(es.path))
                return
            }
        }
    }
    // 2. Control-point hit on any unlocked element (recurses into groups).
    if let (path, cpIdx) = findElementCpNear(
        model.document, x: x, y: y, radius: radius
    ) {
        let alreadySelected = model.document.selection.contains { es in
            es.path == path && es.kind.contains(cpIdx)
        }
        if !alreadySelected || shift {
            model.snapshot()
            if shift {
                var sel = Array(model.document.selection)
                if let pos = sel.firstIndex(where: { $0.path == path }) {
                    let elem = model.document.getElement(path)
                    let total = elem.controlPointCount
                    var cps = sel[pos].kind.toSorted(total: total).toArray()
                    if let p = cps.firstIndex(of: cpIdx) {
                        cps.remove(at: p)
                    } else {
                        cps.append(cpIdx)
                    }
                    sel[pos] = ElementSelection.partial(path, cps)
                } else {
                    sel.append(ElementSelection.partial(path, [cpIdx]))
                }
                Controller(model: model).setSelection(Set(sel))
            } else {
                Controller(model: model).selectControlPoint(path: path, index: cpIdx)
            }
        }
        store.setTool("partial_selection", "mode", "moving_pending")
        return
    }
    store.setTool("partial_selection", "mode", "marquee")
}

/// Recurse through layer / group children looking for a control-point
/// hit on an unlocked, visible element.
private func findElementCpNear(
    _ doc: Document, x: Double, y: Double, radius: Double
) -> (ElementPath, Int)? {
    func recurse(_ elem: Element, _ path: ElementPath) -> (ElementPath, Int)? {
        if elem.visibility == .invisible { return nil }
        if case .group(let g) = elem {
            for (i, child) in g.children.enumerated().reversed() {
                if child.isLocked { continue }
                if let r = recurse(child, path + [i]) { return r }
            }
            return nil
        }
        let cps = elem.controlPointPositions
        for (i, pt) in cps.enumerated() {
            if hypot(x - pt.0, y - pt.1) < radius {
                return (path, i)
            }
        }
        return nil
    }
    for (li, layer) in doc.layers.enumerated() {
        if layer.visibility == .invisible { continue }
        for (ci, child) in layer.children.enumerated().reversed() {
            if child.isLocked { continue }
            if child.visibility == .invisible { continue }
            if let r = recurse(child, [li, ci]) { return r }
        }
    }
    return nil
}

/// Implementation of doc.move_path_handle.
private func pathMoveLatchedHandle(
    model: Model, store: StateStore, dx: Double, dy: Double
) {
    guard let path = decodePath(store.getTool("partial_selection", "handle_path")) else {
        return
    }
    let anchorIdx: Int = {
        if let n = store.getTool("partial_selection", "handle_anchor_idx") as? Int { return n }
        if let n = store.getTool("partial_selection", "handle_anchor_idx") as? NSNumber { return n.intValue }
        return 0
    }()
    let handleType = (store.getTool("partial_selection", "handle_type") as? String) ?? ""
    Controller(model: model).movePathHandle(
        path, anchorIdx: anchorIdx, handleType: handleType, dx: dx, dy: dy)
}

/// Implementation of doc.path.smooth_at_cursor.
private func pathSmoothAtCursor(
    model: Model, x: Double, y: Double, radius: Double, fitError: Double
) {
    let radiusSq = radius * radius
    var newDoc = model.document
    var changed = false
    for es in model.document.selection {
        let path = es.path
        guard case .path(let pe) = model.document.getElement(path),
              !pe.locked, pe.d.count >= 2 else { continue }
        let (flat, cmdMap) = flattenWithCmdMap(pe.d)
        guard flat.count >= 2 else { continue }
        var firstHit: Int? = nil
        var lastHit: Int? = nil
        for (i, pt) in flat.enumerated() {
            let dx = pt.0 - x, dy = pt.1 - y
            if dx * dx + dy * dy <= radiusSq {
                if firstHit == nil { firstHit = i }
                lastHit = i
            }
        }
        guard let fh = firstHit, let lh = lastHit else { continue }
        let firstCmd = cmdMap[fh], lastCmd = cmdMap[lh]
        guard firstCmd < lastCmd else { continue }
        let rangeFlat: [(Double, Double)] = flat.enumerated()
            .filter { (i, _) in cmdMap[i] >= firstCmd && cmdMap[i] <= lastCmd }
            .map { $0.1 }
        let startPt = cmdStartPoint(pe.d, firstCmd)
        var pointsToFit = [startPt]
        pointsToFit.append(contentsOf: rangeFlat)
        guard pointsToFit.count >= 2 else { continue }
        let segments = fitCurve(points: pointsToFit, error: fitError)
        guard !segments.isEmpty else { continue }
        var newCmds: [PathCommand] = []
        newCmds.append(contentsOf: pe.d[..<firstCmd])
        for seg in segments {
            newCmds.append(.curveTo(
                x1: seg.c1x, y1: seg.c1y,
                x2: seg.c2x, y2: seg.c2y,
                x: seg.p2x, y: seg.p2y))
        }
        newCmds.append(contentsOf: pe.d[(lastCmd + 1)...])
        guard newCmds.count < pe.d.count else { continue }
        newDoc = newDoc.replaceElement(path, with: .path(pathWithCommands(pe, newCmds)))
        changed = true
    }
    if changed {
        model.document = newDoc
    }
}

/// Build an Element from a `{ type, ...params }` spec. Supports rect
/// (incl. rx/ry), line, polygon (regular N-gon from first-edge spec),
/// and star (inscribed in an axis-aligned bounding box). Unknown types
/// return nil.
private func buildElement(
    _ spec: [String: Any], model: Model,
    store: StateStore, ctx: [String: Any]
) -> Element? {
    guard let type = spec["type"] as? String else { return nil }
    let hasFill = spec.keys.contains("fill")
    let hasStroke = spec.keys.contains("stroke")
    let fill = resolveFillField(spec["fill"], hasKey: hasFill,
                                 default: model.defaultFill,
                                 store: store, ctx: ctx)
    let stroke = resolveStrokeField(spec["stroke"], hasKey: hasStroke,
                                     default: model.defaultStroke,
                                     store: store, ctx: ctx)
    switch type {
    case "rect":
        let x = evalNumber(spec["x"], store: store, ctx: ctx)
        let y = evalNumber(spec["y"], store: store, ctx: ctx)
        let w = evalNumber(spec["width"], store: store, ctx: ctx)
        let h = evalNumber(spec["height"], store: store, ctx: ctx)
        let rx = evalNumber(spec["rx"], store: store, ctx: ctx)
        let ry = evalNumber(spec["ry"], store: store, ctx: ctx)
        return .rect(Rect(x: x, y: y, width: w, height: h,
                          rx: rx, ry: ry, fill: fill, stroke: stroke))
    case "line":
        let x1 = evalNumber(spec["x1"], store: store, ctx: ctx)
        let y1 = evalNumber(spec["y1"], store: store, ctx: ctx)
        let x2 = evalNumber(spec["x2"], store: store, ctx: ctx)
        let y2 = evalNumber(spec["y2"], store: store, ctx: ctx)
        return .line(Line(x1: x1, y1: y1, x2: x2, y2: y2, stroke: stroke))
    case "polygon":
        let x1 = evalNumber(spec["x1"], store: store, ctx: ctx)
        let y1 = evalNumber(spec["y1"], store: store, ctx: ctx)
        let x2 = evalNumber(spec["x2"], store: store, ctx: ctx)
        let y2 = evalNumber(spec["y2"], store: store, ctx: ctx)
        let sidesRaw = Int(evalNumber(spec["sides"], store: store, ctx: ctx))
        let sides = sidesRaw <= 0 ? 5 : sidesRaw
        let pts = regularPolygonPoints(x1, y1, x2, y2, sides)
        return .polygon(Polygon(points: pts, fill: fill, stroke: stroke))
    case "star":
        let x1 = evalNumber(spec["x1"], store: store, ctx: ctx)
        let y1 = evalNumber(spec["y1"], store: store, ctx: ctx)
        let x2 = evalNumber(spec["x2"], store: store, ctx: ctx)
        let y2 = evalNumber(spec["y2"], store: store, ctx: ctx)
        let raw = Int(evalNumber(spec["points"], store: store, ctx: ctx))
        let n = raw <= 0 ? 5 : raw
        let pts = starPoints(x1, y1, x2, y2, n)
        return .polygon(Polygon(points: pts, fill: fill, stroke: stroke))
    default:
        return nil
    }
}

/// Evaluate a Value-returning arg, handling nil / number-literal /
/// string-expression cases.
private func evalExprAsValue(
    _ arg: Any?, store: StateStore, ctx: [String: Any]
) -> Value {
    guard let arg = arg else { return .null }
    if let s = arg as? String {
        let evalCtx = store.evalContext(extra: ctx)
        return evaluate(s, context: evalCtx)
    }
    return Value.fromJson(arg)
}

/// Evaluate a number-returning arg with a default when the spec omits
/// the field (nil — NOT the same as the field being present with a
/// 0-valued expression).
private func evalNumberWithDefault(
    _ arg: Any?, default defVal: Double,
    store: StateStore, ctx: [String: Any]
) -> Double {
    guard arg != nil else { return defVal }
    let v = evalNumber(arg, store: store, ctx: ctx)
    return v == 0 ? defVal : v
}

// MARK: - Path validity

/// True when `path` references an existing element in `doc`.
/// Document's `getElement(_:)` fatalErrors on invalid input, so this
/// helper does a defensive walk instead. `childrenOf` in Document is
/// private, so we inline the switch.
private func isValidPath(_ doc: Document, _ path: ElementPath) -> Bool {
    guard !path.isEmpty else { return false }
    guard path[0] >= 0 && path[0] < doc.layers.count else { return false }
    var node: Element = .layer(doc.layers[path[0]])
    for idx in path.dropFirst() {
        let children: [Element]
        switch node {
        case .group(let g): children = g.children
        case .layer(let l): children = l.children
        default: return false
        }
        guard idx >= 0 && idx < children.count else { return false }
        node = children[idx]
    }
    return true
}

// MARK: - Arg helpers

/// Evaluate a dx/dy/x1/... argument that may be a number literal, a
/// numeric string expression, or a JSON number. Missing → 0.
private func evalNumber(_ arg: Any?, store: StateStore, ctx: [String: Any]) -> Double {
    if arg == nil { return 0 }
    if let n = arg as? NSNumber { return n.doubleValue }
    if let d = arg as? Double { return d }
    if let i = arg as? Int { return Double(i) }
    if let s = arg as? String {
        let evalCtx = store.evalContext(extra: ctx)
        let v = evaluate(s, context: evalCtx)
        if case .number(let n) = v { return n }
    }
    return 0
}

private func evalBool(_ arg: Any?, store: StateStore, ctx: [String: Any]) -> Bool {
    if arg == nil { return false }
    if let b = arg as? Bool { return b }
    if let s = arg as? String {
        let evalCtx = store.evalContext(extra: ctx)
        let v = evaluate(s, context: evalCtx)
        if case .bool(let b) = v { return b }
    }
    return false
}

/// Extract a rect spec and normalize it to (x, y, w, h, additive).
/// Accepts {x1, y1, x2, y2, additive} with the axis-aligned rect
/// between the two corners — matches the Rust port.
private func normalizeRectArgs(
    _ args: [String: Any],
    store: StateStore, ctx: [String: Any]
) -> (Double, Double, Double, Double, Bool) {
    let x1 = evalNumber(args["x1"], store: store, ctx: ctx)
    let y1 = evalNumber(args["y1"], store: store, ctx: ctx)
    let x2 = evalNumber(args["x2"], store: store, ctx: ctx)
    let y2 = evalNumber(args["y2"], store: store, ctx: ctx)
    let additive = evalBool(args["additive"], store: store, ctx: ctx)
    return (min(x1, x2), min(y1, y2), abs(x2 - x1), abs(y2 - y1), additive)
}

/// Pull a single ElementPath out of a doc.* effect spec.
/// Accepts:
///   - a raw JSON array of ints
///   - a string that evaluates to Value.path (Path value)
///   - a string that evaluates to Value.list of integer Values
///   - {path: <expr>} dict (recurses)
private func extractPath(
    _ spec: Any?, store: StateStore, ctx: [String: Any]
) -> ElementPath? {
    if let arr = spec as? [Any] {
        var out: ElementPath = []
        for item in arr {
            if let n = item as? NSNumber {
                out.append(n.intValue)
            } else if let i = item as? Int {
                out.append(i)
            } else {
                return nil
            }
        }
        return out
    }
    if let s = spec as? String {
        let evalCtx = store.evalContext(extra: ctx)
        let v = evaluate(s, context: evalCtx)
        if case .path(let indices) = v {
            return indices
        }
        if case .list(let items) = v {
            // AnyJSON.value is Any — downcast each entry to an int.
            var out: ElementPath = []
            for item in items {
                if let n = item.value as? NSNumber {
                    out.append(n.intValue)
                } else if let i = item.value as? Int {
                    out.append(i)
                } else if let d = item.value as? Double, d == Double(Int(d)) {
                    out.append(Int(d))
                } else {
                    return nil
                }
            }
            return out
        }
        return nil
    }
    if let obj = spec as? [String: Any], let inner = obj["path"] {
        return extractPath(inner, store: store, ctx: ctx)
    }
    return nil
}

/// Pull a list of paths out of a `{paths: [...]}` spec. Items that
/// don't resolve to a path are dropped.
private func extractPathList(
    _ spec: Any?, store: StateStore, ctx: [String: Any]
) -> [ElementPath] {
    guard let obj = spec as? [String: Any],
          let paths = obj["paths"] as? [Any] else {
        return []
    }
    var out: [ElementPath] = []
    for item in paths {
        if let p = extractPath(item, store: store, ctx: ctx) {
            out.append(p)
        }
    }
    return out
}
