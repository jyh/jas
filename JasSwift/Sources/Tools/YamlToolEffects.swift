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
private func makePathFromCommands(
    _ cmds: [PathCommand],
    model: Model,
    spec: [String: Any],
    store: StateStore,
    ctx: [String: Any]
) -> Path {
    // Resolve fill: absent → model default, null → strip, explicit → parse.
    let fill: Fill? = {
        if !spec.keys.contains("fill") { return model.defaultFill }
        let v = evalExprAsValue(spec["fill"], store: store, ctx: ctx)
        switch v {
        case .null: return nil
        case .color(let c): return Fill(color: Color.fromHex(c) ?? .black)
        case .string(let s):
            if let c = Color.fromHex(s) { return Fill(color: c) }
            return model.defaultFill
        default: return model.defaultFill
        }
    }()
    let stroke: Stroke? = {
        if !spec.keys.contains("stroke") { return model.defaultStroke }
        let v = evalExprAsValue(spec["stroke"], store: store, ctx: ctx)
        switch v {
        case .null: return nil
        case .color(let c):
            return Color.fromHex(c).map { Stroke(color: $0, width: 1.0) }
        case .string(let s):
            if let c = Color.fromHex(s) {
                return Stroke(color: c, width: 1.0)
            }
            return model.defaultStroke
        default: return model.defaultStroke
        }
    }()
    return Path(d: cmds, fill: fill, stroke: stroke)
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
