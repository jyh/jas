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

    // data.set — { path, value }. Writes a value at a dotted path
    // inside store.data. Mirrors the JS Phase 1.13 effect.
    effects["data.set"] = { spec, ctx, store in
        guard let args = spec as? [String: Any],
              let path = args["path"] as? String, !path.isEmpty
        else { return nil }
        let value = resolveValueOrExpr(args["value"], store: store, ctx: ctx)
        store.setDataPath(path, value)
        return nil
    }

    effects["data.list_append"] = { spec, ctx, store in
        guard let args = spec as? [String: Any],
              let path = args["path"] as? String, !path.isEmpty
        else { return nil }
        let value = resolveValueOrExpr(args["value"], store: store, ctx: ctx)
        var arr = (store.getDataPath(path) as? [Any]) ?? []
        arr.append(value ?? NSNull())
        store.setDataPath(path, arr)
        return nil
    }

    effects["data.list_remove"] = { spec, ctx, store in
        guard let args = spec as? [String: Any],
              let path = args["path"] as? String, !path.isEmpty
        else { return nil }
        let index = Int(evalNumber(args["index"], store: store, ctx: ctx))
        guard var arr = store.getDataPath(path) as? [Any] else { return nil }
        if index >= 0 && index < arr.count {
            arr.remove(at: index)
            store.setDataPath(path, arr)
        }
        return nil
    }

    effects["data.list_insert"] = { spec, ctx, store in
        guard let args = spec as? [String: Any],
              let path = args["path"] as? String, !path.isEmpty
        else { return nil }
        let value = resolveValueOrExpr(args["value"], store: store, ctx: ctx)
        let index = Int(evalNumber(args["index"], store: store, ctx: ctx))
        var arr = (store.getDataPath(path) as? [Any]) ?? []
        let i = max(0, min(index, arr.count))
        arr.insert(value ?? NSNull(), at: i)
        store.setDataPath(path, arr)
        return nil
    }

    // brush.options_confirm — per-mode dispatch reading dialog
    // state. Phase 1 Calligraphic only. Used by the YAML
    // brush_options_confirm action's effects chain.
    effects["brush.options_confirm"] = { spec, ctx, store in
        let dialog = store.getDialogState()
        let params = store.getDialogParams() ?? [:]
        let mode = (params["mode"] as? String) ?? "create"
        let library = (params["library"] as? String) ?? ""
        let brushSlug = (params["brush_slug"] as? String) ?? ""
        let name = (dialog["brush_name"] as? String) ?? "Brush"
        let brushType = (dialog["brush_type"] as? String) ?? "calligraphic"
        let angle = (dialog["angle"] as? Double) ?? 0.0
        let roundness = (dialog["roundness"] as? Double) ?? 100.0
        let size = (dialog["size"] as? Double) ?? 5.0
        let angleVar = (dialog["angle_variation"] as? [String: Any]) ?? ["mode": "fixed"]
        let roundnessVar = (dialog["roundness_variation"] as? [String: Any]) ?? ["mode": "fixed"]
        let sizeVar = (dialog["size_variation"] as? [String: Any]) ?? ["mode": "fixed"]

        var libKey = library
        if libKey.isEmpty {
            if let libs = store.getDataPath("brush_libraries") as? [String: Any],
               let firstKey = libs.keys.sorted().first {
                libKey = firstKey
            }
        }
        if libKey.isEmpty { return nil }

        switch mode {
        case "create":
            // Slug from name: lowercased, non-alphanum -> '_'.
            var raw = ""
            for ch in name {
                if ch.isLetter || ch.isNumber {
                    raw += String(ch).lowercased()
                } else {
                    raw += "_"
                }
            }
            let path = "brush_libraries.\(libKey).brushes"
            let existing: Set<String> = {
                guard let arr = store.getDataPath(path) as? [[String: Any]] else { return [] }
                return Set(arr.compactMap { $0["slug"] as? String })
            }()
            var slug = raw
            var n = 2
            while existing.contains(slug) {
                slug = "\(raw)_\(n)"
                n += 1
            }
            var brush: [String: Any] = [
                "name": name, "slug": slug, "type": brushType,
            ]
            if brushType == "calligraphic" {
                brush["angle"] = angle
                brush["roundness"] = roundness
                brush["size"] = size
                brush["angle_variation"] = angleVar
                brush["roundness_variation"] = roundnessVar
                brush["size_variation"] = sizeVar
            }
            brushAppendToLibrary(store: store, libId: libKey, brush: brush)
            syncCanvasBrushes(store: store)

        case "library_edit":
            if brushSlug.isEmpty { return nil }
            var patch: [String: Any] = ["name": name]
            if brushType == "calligraphic" {
                patch["angle"] = angle
                patch["roundness"] = roundness
                patch["size"] = size
                patch["angle_variation"] = angleVar
                patch["roundness_variation"] = roundnessVar
                patch["size_variation"] = sizeVar
            }
            brushUpdateInLibrary(store: store, libId: libKey, slug: brushSlug, patch: patch)
            syncCanvasBrushes(store: store)

        case "instance_edit":
            let overrides: [String: Any] = [
                "angle": angle, "roundness": roundness, "size": size,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: overrides),
               let s = String(data: data, encoding: .utf8) {
                Controller(model: model).setSelectionStrokeBrushOverrides(s)
            }

        default:
            break
        }
        return nil
    }

    // brush.delete_selected — filter library.brushes against the
    // selected slug list, clear panel.brushes.selected_brushes, and
    // sync the canvas brush registry. Mirrors the JS Phase 1.13
    // effect.
    effects["brush.delete_selected"] = { spec, ctx, store in
        guard let args = spec as? [String: Any] else { return nil }
        let libId = evalStringValue(args["library"], store: store, ctx: ctx)
        let slugs = evalStringList(args["slugs"], store: store, ctx: ctx)
        if libId.isEmpty || slugs.isEmpty { return nil }
        brushFilterLibraryBySlug(store: store, libId: libId, slugs: Set(slugs))
        store.setPanel("brushes", "selected_brushes", [String]())
        syncCanvasBrushes(store: store)
        return nil
    }

    // brush.duplicate_selected — same library, " copy" name suffix,
    // unique <slug>_copy[_N] slug. Selection becomes the new copies.
    effects["brush.duplicate_selected"] = { spec, ctx, store in
        guard let args = spec as? [String: Any] else { return nil }
        let libId = evalStringValue(args["library"], store: store, ctx: ctx)
        let slugs = evalStringList(args["slugs"], store: store, ctx: ctx)
        if libId.isEmpty || slugs.isEmpty { return nil }
        let newSlugs = brushDuplicateInLibrary(store: store, libId: libId, slugs: slugs)
        store.setPanel("brushes", "selected_brushes", newSlugs)
        syncCanvasBrushes(store: store)
        return nil
    }

    // brush.append — append a new brush to a library. Used by
    // brush_options_confirm in create mode.
    effects["brush.append"] = { spec, ctx, store in
        guard let args = spec as? [String: Any] else { return nil }
        let libId = evalStringValue(args["library"], store: store, ctx: ctx)
        guard !libId.isEmpty else { return nil }
        let brush = resolveValueOrExpr(args["brush"], store: store, ctx: ctx)
        if let brushDict = brush as? [String: Any] {
            brushAppendToLibrary(store: store, libId: libId, brush: brushDict)
            syncCanvasBrushes(store: store)
        }
        return nil
    }

    // brush.update — patch an existing master brush in place by slug.
    effects["brush.update"] = { spec, ctx, store in
        guard let args = spec as? [String: Any] else { return nil }
        let libId = evalStringValue(args["library"], store: store, ctx: ctx)
        let slug = evalStringValue(args["slug"], store: store, ctx: ctx)
        guard !libId.isEmpty, !slug.isEmpty else { return nil }
        let patch = resolveValueOrExpr(args["patch"], store: store, ctx: ctx)
        if let patchDict = patch as? [String: Any] {
            brushUpdateInLibrary(store: store, libId: libId, slug: slug, patch: patchDict)
            syncCanvasBrushes(store: store)
        }
        return nil
    }

    // doc.set_attr_on_selection — { attr, value }. Phase 1 supports
    // brush attributes only; other attrs ignored. Used by
    // apply_brush_to_selection / remove_brush_from_selection in
    // actions.yaml. Mirrors the JS Phase 1.8 effect.
    effects["doc.set_attr_on_selection"] = { spec, ctx, store in
        guard let args = spec as? [String: Any],
              let attr = args["attr"] as? String else { return nil }
        let value: String? = {
            let v = evalExprAsValue(args["value"], store: store, ctx: ctx)
            if case .string(let s) = v, !s.isEmpty { return s }
            return nil
        }()
        switch attr {
        case "stroke_brush":
            Controller(model: model).setSelectionStrokeBrush(value)
        case "stroke_brush_overrides":
            Controller(model: model).setSelectionStrokeBrushOverrides(value)
        default:
            // Phase 1: only brush attrs supported.
            break
        }
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

    // doc.paintbrush.edit_start — { x, y, within }.
    // Paintbrush edit-gesture target selection at mousedown. See
    // PAINTBRUSH_TOOL.md §Edit gesture. Scans selected Paths, picks
    // the one whose closest flat point is nearest and ≤ within px of
    // (x, y). Writes tool.paintbrush.mode='edit' + edit_target_path
    // + edit_entry_idx. Leaves tool state untouched when no target
    // qualifies (mode stays 'drawing').
    effects["doc.paintbrush.edit_start"] = { spec, ctx, store in
        guard let args = spec as? [String: Any] else { return nil }
        let x = evalNumber(args["x"], store: store, ctx: ctx)
        let y = evalNumber(args["y"], store: store, ctx: ctx)
        let within = evalNumber(args["within"], store: store, ctx: ctx)
        paintbrushEditStart(model: model, store: store,
                            x: x, y: y, within: within)
        return nil
    }

    // doc.paintbrush.edit_commit — { buffer, fit_error?, within }.
    // Paintbrush edit-gesture splice at mouseup. Reads target and
    // entry_idx stashed by edit_start, computes exit_idx on the
    // target's flat polyline nearest the buffer's last point, and if
    // within range, replaces the target's [c0..c1] command range
    // with a fit_curve of the drag buffer (start-point prepended for
    // seamless splice, mirroring pathSmoothAtCursor). Preserves all
    // non-`d` attributes on the target.
    effects["doc.paintbrush.edit_commit"] = { spec, ctx, store in
        guard let args = spec as? [String: Any],
              let buffer = args["buffer"] as? String else { return nil }
        let rawE = evalNumber(args["fit_error"], store: store, ctx: ctx)
        let fitError = rawE == 0 ? 4.0 : rawE
        let within = evalNumber(args["within"], store: store, ctx: ctx)
        paintbrushEditCommit(model: model, store: store,
                             buffer: buffer, fitError: fitError,
                             within: within)
        return nil
    }

    // doc.blob_brush.commit_painting — {
    //   buffer, fidelity_epsilon?,
    //   merge_only_with_selection?, keep_selected?
    // }.
    // Blob Brush painting-mode commit. Builds the swept region from
    // the named buffer, merges with qualifying existing blob-brush
    // elements (per BLOB_BRUSH_TOOL.md §Merge condition +
    // §Multi-element merge), and commits a single filled Path at the
    // lowest matching z-index (or appends to layer 0 when no matches).
    effects["doc.blob_brush.commit_painting"] = { spec, ctx, store in
        guard let args = spec as? [String: Any],
              let buffer = args["buffer"] as? String,
              !buffer.isEmpty else { return nil }
        let epsilon = evalNumber(args["fidelity_epsilon"], store: store, ctx: ctx)
        let mergeOnlyWithSelection = evalBool(
            args["merge_only_with_selection"], store: store, ctx: ctx)
        let keepSelected = evalBool(args["keep_selected"], store: store, ctx: ctx)
        blobBrushCommitPainting(
            model: model, store: store, ctx: ctx,
            buffer: buffer, fidelityEpsilon: epsilon,
            mergeOnlyWithSelection: mergeOnlyWithSelection,
            keepSelected: keepSelected)
        return nil
    }

    // doc.blob_brush.commit_erasing — { buffer, fidelity_epsilon? }.
    // Blob Brush erasing-mode commit. Same sweep-region generation as
    // painting; then boolean_subtract the region from each overlapping
    // jas:tool-origin == "blob_brush" element (fill match not
    // required). Empty remainder → delete; non-empty update in place.
    // See BLOB_BRUSH_TOOL.md §Erase gesture.
    effects["doc.blob_brush.commit_erasing"] = { spec, ctx, store in
        guard let args = spec as? [String: Any],
              let buffer = args["buffer"] as? String,
              !buffer.isEmpty else { return nil }
        let epsilon = evalNumber(args["fidelity_epsilon"], store: store, ctx: ctx)
        blobBrushCommitErasing(
            model: model, store: store, ctx: ctx,
            buffer: buffer, fidelityEpsilon: epsilon)
        return nil
    }

    // doc.scale.apply / doc.rotate.apply / doc.shear.apply.
    // Each accepts both calling conventions:
    //   - drag: press_x/y + cursor_x/y + shift + copy (from
    //     workspace/tools/<tool>.yaml on_mouseup)
    //   - dialog: tool-specific direct params (sx/sy, angle,
    //     axis, axis_angle) + copy (from workspace/actions.yaml
    //     <tool>_options_confirm)
    // Reference point comes from state.transform_reference_point
    // when set, else falls back to the selection's union bbox
    // center. See SCALE_TOOL.md / ROTATE_TOOL.md / SHEAR_TOOL.md
    // §Apply behavior.
    effects["doc.scale.apply"] = { spec, ctx, store in
        guard let args = spec as? [String: Any] else { return nil }
        let copy = evalBool(args["copy"], store: store, ctx: ctx)
        let (sx, sy): (Double, Double) = {
            if args["sx"] != nil {
                return (evalNumber(args["sx"], store: store, ctx: ctx),
                        evalNumber(args["sy"], store: store, ctx: ctx))
            }
            let (rx, ry) = resolveReferencePoint(model: model, store: store, ctx: ctx)
            let px = evalNumber(args["press_x"],  store: store, ctx: ctx)
            let py = evalNumber(args["press_y"],  store: store, ctx: ctx)
            let cx = evalNumber(args["cursor_x"], store: store, ctx: ctx)
            let cy = evalNumber(args["cursor_y"], store: store, ctx: ctx)
            let shift = evalBool(args["shift"], store: store, ctx: ctx)
            return dragToScaleFactors(px: px, py: py, cx: cx, cy: cy,
                                      rx: rx, ry: ry, shift: shift)
        }()
        scaleApply(model: model, store: store, ctx: ctx,
                   sx: sx, sy: sy, copy: copy)
        return nil
    }
    effects["doc.rotate.apply"] = { spec, ctx, store in
        guard let args = spec as? [String: Any] else { return nil }
        let copy = evalBool(args["copy"], store: store, ctx: ctx)
        let thetaDeg: Double = {
            if args["angle"] != nil {
                return evalNumber(args["angle"], store: store, ctx: ctx)
            }
            let (rx, ry) = resolveReferencePoint(model: model, store: store, ctx: ctx)
            let px = evalNumber(args["press_x"],  store: store, ctx: ctx)
            let py = evalNumber(args["press_y"],  store: store, ctx: ctx)
            let cx = evalNumber(args["cursor_x"], store: store, ctx: ctx)
            let cy = evalNumber(args["cursor_y"], store: store, ctx: ctx)
            let shift = evalBool(args["shift"], store: store, ctx: ctx)
            return dragToRotateAngle(px: px, py: py, cx: cx, cy: cy,
                                     rx: rx, ry: ry, shift: shift)
        }()
        rotateApply(model: model, store: store, ctx: ctx,
                    thetaDeg: thetaDeg, copy: copy)
        return nil
    }
    effects["doc.shear.apply"] = { spec, ctx, store in
        guard let args = spec as? [String: Any] else { return nil }
        let copy = evalBool(args["copy"], store: store, ctx: ctx)
        let (angleDeg, axis, axisAngleDeg): (Double, String, Double) = {
            if args["angle"] != nil && args["axis"] != nil {
                let a = evalNumber(args["angle"], store: store, ctx: ctx)
                let ax = evalStringValue(args["axis"], store: store, ctx: ctx)
                let aa = evalNumber(args["axis_angle"], store: store, ctx: ctx)
                return (a, ax, aa)
            }
            let (rx, ry) = resolveReferencePoint(model: model, store: store, ctx: ctx)
            let px = evalNumber(args["press_x"],  store: store, ctx: ctx)
            let py = evalNumber(args["press_y"],  store: store, ctx: ctx)
            let cx = evalNumber(args["cursor_x"], store: store, ctx: ctx)
            let cy = evalNumber(args["cursor_y"], store: store, ctx: ctx)
            let shift = evalBool(args["shift"], store: store, ctx: ctx)
            return dragToShearParams(px: px, py: py, cx: cx, cy: cy,
                                     rx: rx, ry: ry, shift: shift)
        }()
        shearApply(model: model, store: store, ctx: ctx,
                   angleDeg: angleDeg, axis: axis,
                   axisAngleDeg: axisAngleDeg, copy: copy)
        return nil
    }

    // doc.preview.capture / restore / clear — out-of-band document
    // snapshot for dialog Preview flows (Scale / Rotate / Shear).
    // See SCALE_TOOL.md §Preview.
    effects["doc.preview.capture"] = { _, _, _ in
        model.capturePreviewSnapshot()
        return nil
    }
    effects["doc.preview.restore"] = { _, _, _ in
        model.restorePreviewSnapshot()
        return nil
    }
    effects["doc.preview.clear"] = { _, _, _ in
        model.clearPreviewSnapshot()
        return nil
    }

    // doc.magic_wand.apply — { seed, mode? }.
    // Magic Wand selection per MAGIC_WAND_TOOL.md §Predicate.
    // Reads the seed path + mode (replace / add / subtract) from
    // the spec, walks the document, applies the eligibility filter
    // and the AND-of-enabled-criteria predicate, mutates the
    // selection accordingly.
    effects["doc.magic_wand.apply"] = { spec, ctx, store in
        guard let args = spec as? [String: Any],
              let seedPath = extractPath(args["seed"],
                                         store: store, ctx: ctx)
        else { return nil }
        let modeRaw = evalStringValue(args["mode"], store: store, ctx: ctx)
        let mode = modeRaw.isEmpty ? "replace" : modeRaw
        magicWandApply(
            model: model, store: store, ctx: ctx,
            seedPath: seedPath, mode: mode)
        return nil
    }

    // ──────────────────────────────────────────────────────────
    // doc.zoom.* and doc.pan.apply — view-state effects per
    // ZOOM_TOOL.md and HAND_TOOL.md. None of these modify document
    // content; they only update the per-tab view state on Model:
    // zoomLevel, viewOffsetX, viewOffsetY.
    // ──────────────────────────────────────────────────────────

    // doc.zoom.apply — apply a multiplicative factor anchored at
    // (anchor_x, anchor_y) in viewport-local pixels. Document
    // point under the anchor stays under the anchor after the
    // zoom. Clamps to [min_zoom, max_zoom]; the *actual* applied
    // factor (post-clamp) is used for pan recompute so the anchor
    // stays glued at the boundary. anchor_x / anchor_y default to
    // -1, meaning "viewport center" for keyboard / menu callers.
    effects["doc.zoom.apply"] = { spec, ctx, store in
        guard let args = spec as? [String: Any] else { return nil }
        let factor = evalNumber(args["factor"], store: store, ctx: ctx)
        let anchorXRaw = evalNumber(args["anchor_x"], store: store, ctx: ctx)
        let anchorYRaw = evalNumber(args["anchor_y"], store: store, ctx: ctx)
        let minZoom = readPrefNumber("min_zoom", default: 0.1)
        let maxZoom = readPrefNumber("max_zoom", default: 64.0)
        let z = model.zoomLevel
        let px = model.viewOffsetX
        let py = model.viewOffsetY
        let ax = anchorXRaw < 0 ? px : anchorXRaw
        let ay = anchorYRaw < 0 ? py : anchorYRaw
        let docAx = (ax - px) / z
        let docAy = (ay - py) / z
        let zNew = min(max(z * factor, minZoom), maxZoom)
        model.zoomLevel = zNew
        model.viewOffsetX = ax - docAx * zNew
        model.viewOffsetY = ay - docAy * zNew
        return nil
    }

    // doc.zoom.set — absolute zoom_level; pan unchanged. Used by
    // zoom_to_actual_size (level: 1.0).
    effects["doc.zoom.set"] = { spec, ctx, store in
        guard let args = spec as? [String: Any] else { return nil }
        let level = evalNumber(args["level"], store: store, ctx: ctx)
        let minZoom = readPrefNumber("min_zoom", default: 0.1)
        let maxZoom = readPrefNumber("max_zoom", default: 64.0)
        model.zoomLevel = min(max(level, minZoom), maxZoom)
        return nil
    }

    // doc.zoom.set_full — atomic write of zoom_level + offsets.
    // Used by Zoom-tool Escape-cancel to restore the press snapshot.
    effects["doc.zoom.set_full"] = { spec, ctx, store in
        guard let args = spec as? [String: Any] else { return nil }
        let zoom = evalNumber(args["zoom"], store: store, ctx: ctx)
        let offsetX = evalNumber(args["offset_x"], store: store, ctx: ctx)
        let offsetY = evalNumber(args["offset_y"], store: store, ctx: ctx)
        let minZoom = readPrefNumber("min_zoom", default: 0.1)
        let maxZoom = readPrefNumber("max_zoom", default: 64.0)
        model.zoomLevel = min(max(zoom, minZoom), maxZoom)
        model.viewOffsetX = offsetX
        model.viewOffsetY = offsetY
        return nil
    }

    // doc.zoom.scrubby — continuous scrubby zoom from press
    // snapshot. exp-gain factor from cumulative drag distance with
    // Alt-flip semantics. Anchored at the press point.
    effects["doc.zoom.scrubby"] = { spec, ctx, store in
        guard let args = spec as? [String: Any] else { return nil }
        let pressX = evalNumber(args["press_x"], store: store, ctx: ctx)
        let pressY = evalNumber(args["press_y"], store: store, ctx: ctx)
        let cursorX = evalNumber(args["cursor_x"], store: store, ctx: ctx)
        _ = evalNumber(args["cursor_y"], store: store, ctx: ctx)
        let altHeld = evalBool(args["alt_held"], store: store, ctx: ctx)
        let altAtPress = evalBool(args["alt_at_press"], store: store, ctx: ctx)
        let gain = readPrefNumber("scrubby_zoom_gain", default: 144.0)
        let minZoom = readPrefNumber("min_zoom", default: 0.1)
        let maxZoom = readPrefNumber("max_zoom", default: 64.0)
        let initialZoom = readToolZoomState(ctx, "initial_zoom", default: 1.0)
        let initialOffx = readToolZoomState(ctx, "initial_offx", default: 0.0)
        let initialOffy = readToolZoomState(ctx, "initial_offy", default: 0.0)
        let dx = cursorX - pressX
        let direction = (altAtPress != altHeld) ? -1.0 : 1.0
        let factor = exp(dx * direction / gain)
        let zNew = min(max(initialZoom * factor, minZoom), maxZoom)
        let docAx = (pressX - initialOffx) / initialZoom
        let docAy = (pressY - initialOffy) / initialZoom
        model.zoomLevel = zNew
        model.viewOffsetX = pressX - docAx * zNew
        model.viewOffsetY = pressY - docAy * zNew
        return nil
    }

    // doc.pan.apply — Hand-tool drag pan. Idempotent: recomputes
    // from press + initial offset each call rather than
    // accumulating per-event deltas.
    effects["doc.pan.apply"] = { spec, ctx, store in
        guard let args = spec as? [String: Any] else { return nil }
        let pressX = evalNumber(args["press_x"], store: store, ctx: ctx)
        let pressY = evalNumber(args["press_y"], store: store, ctx: ctx)
        let cursorX = evalNumber(args["cursor_x"], store: store, ctx: ctx)
        let cursorY = evalNumber(args["cursor_y"], store: store, ctx: ctx)
        let initialOffx = evalNumber(args["initial_offx"], store: store, ctx: ctx)
        let initialOffy = evalNumber(args["initial_offy"], store: store, ctx: ctx)
        model.viewOffsetX = initialOffx + (cursorX - pressX)
        model.viewOffsetY = initialOffy + (cursorY - pressY)
        return nil
    }

    // doc.zoom.fit_rect — fit a document-coordinate rectangle into
    // the visible canvas with screen-space padding. Used by
    // fit_active_artboard.
    effects["doc.zoom.fit_rect"] = { spec, ctx, store in
        guard let args = spec as? [String: Any] else { return nil }
        let rectX = evalNumber(args["rect_x"], store: store, ctx: ctx)
        let rectY = evalNumber(args["rect_y"], store: store, ctx: ctx)
        let rectW = evalNumber(args["rect_w"], store: store, ctx: ctx)
        let rectH = evalNumber(args["rect_h"], store: store, ctx: ctx)
        let padding = evalNumber(args["padding"], store: store, ctx: ctx)
        fitRectIntoViewport(model: model, x: rectX, y: rectY,
                            w: rectW, h: rectH, padding: padding)
        return nil
    }

    // doc.zoom.fit_marquee — fit a viewport-pixel marquee
    // (press → cursor) into the canvas. Exact fit. Below 10px in
    // either dimension is a no-op.
    effects["doc.zoom.fit_marquee"] = { spec, ctx, store in
        guard let args = spec as? [String: Any] else { return nil }
        let pressX = evalNumber(args["press_x"], store: store, ctx: ctx)
        let pressY = evalNumber(args["press_y"], store: store, ctx: ctx)
        let cursorX = evalNumber(args["cursor_x"], store: store, ctx: ctx)
        let cursorY = evalNumber(args["cursor_y"], store: store, ctx: ctx)
        let mx = min(pressX, cursorX)
        let my = min(pressY, cursorY)
        let mw = abs(pressX - cursorX)
        let mh = abs(pressY - cursorY)
        if mw < 10 || mh < 10 { return nil }
        let z = model.zoomLevel
        let px = model.viewOffsetX
        let py = model.viewOffsetY
        let docX = (mx - px) / z
        let docY = (my - py) / z
        let docW = mw / z
        let docH = mh / z
        fitRectIntoViewport(model: model, x: docX, y: docY,
                            w: docW, h: docH, padding: 0)
        return nil
    }

    // doc.zoom.fit_elements — fit the bounding box of all elements
    // with padding. Empty document → 100% centered on origin.
    effects["doc.zoom.fit_elements"] = { spec, ctx, store in
        guard let args = spec as? [String: Any] else { return nil }
        let padding = evalNumber(args["padding"], store: store, ctx: ctx)
        let bounds = documentBounds(model.document)
        if bounds.w <= 0 || bounds.h <= 0 {
            model.zoomLevel = 1.0
            model.viewOffsetX = model.viewportW / 2.0
            model.viewOffsetY = model.viewportH / 2.0
        } else {
            fitRectIntoViewport(model: model,
                                x: bounds.x, y: bounds.y,
                                w: bounds.w, h: bounds.h,
                                padding: padding)
        }
        return nil
    }

    // doc.zoom.fit_all_artboards — fit the union of all artboard
    // rectangles with padding.
    effects["doc.zoom.fit_all_artboards"] = { spec, ctx, store in
        guard let args = spec as? [String: Any] else { return nil }
        let padding = evalNumber(args["padding"], store: store, ctx: ctx)
        let abs = model.document.artboards
        guard !abs.isEmpty else { return nil }
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity
        for ab in abs {
            let x = Double(ab.x), y = Double(ab.y)
            let w = Double(ab.width), h = Double(ab.height)
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x + w)
            maxY = max(maxY, y + h)
        }
        fitRectIntoViewport(model: model, x: minX, y: minY,
                            w: maxX - minX, h: maxY - minY,
                            padding: padding)
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

    // doc.add_path_from_buffer: {
    //   buffer, fit_error?,
    //   stroke_brush?, stroke_brush_overrides?,  // Paintbrush semantics
    //   fill_new_strokes?, close?,
    //   fill?, stroke?                             // Pencil-style defaults
    // }
    //
    // Runs fitCurve on the named buffer and appends a cubic-Bezier Path
    // to the document. Used by Pencil (no stroke_brush key) and
    // Paintbrush (passes stroke_brush + friends). See
    // PAINTBRUSH_TOOL.md §Fill and stroke for the stroke-width commit
    // rule when stroke_brush is present.
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
        var cmds: [PathCommand] = []
        cmds.append(.moveTo(segments[0].p1x, segments[0].p1y))
        for seg in segments {
            cmds.append(.curveTo(
                x1: seg.c1x, y1: seg.c1y,
                x2: seg.c2x, y2: seg.c2y,
                x: seg.p2x, y: seg.p2y
            ))
        }
        // Paintbrush §Gestures close-at-release: when close=true, append
        // ClosePath after the last CurveTo.
        if evalBool(args["close"], store: store, ctx: ctx) {
            cmds.append(.closePath)
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

    // ── Artboard tool effects (ARTBOARD_TOOL.md) ────────────────

    // doc.artboard.create_commit — drag-to-create commit. Builds a
    // rect from (x1,y1)-(x2,y2), rounds to integer pt, clamps each
    // dimension to >= 1 pt, mints a fresh id (collision-retry),
    // picks the next "Artboard N" name, and appends to
    // document.artboards. Per ARTBOARD_TOOL.md §Drag-to-create.
    effects["doc.artboard.create_commit"] = { spec, ctx, store in
        guard let args = spec as? [String: Any] else { return nil }
        let x1 = evalNumber(args["x1"], store: store, ctx: ctx)
        let y1 = evalNumber(args["y1"], store: store, ctx: ctx)
        let x2 = evalNumber(args["x2"], store: store, ctx: ctx)
        let y2 = evalNumber(args["y2"], store: store, ctx: ctx)

        let rawX = (min(x1, x2)).rounded()
        let rawY = (min(y1, y2)).rounded()
        let rawW = max(abs(x1 - x2).rounded(), 1.0)
        let rawH = max(abs(y1 - y2).rounded(), 1.0)

        let doc = model.document
        let existing: Set<String> = Set(doc.artboards.map { $0.id })
        var newId = ""
        for _ in 0..<100 {
            let candidate = generateArtboardId()
            if !existing.contains(candidate) { newId = candidate; break }
        }
        guard !newId.isEmpty else { return nil }
        let newName = nextArtboardName(doc.artboards)
        let ab = Artboard(
            id: newId, name: newName,
            x: rawX, y: rawY, width: rawW, height: rawH)
        let newAbs = doc.artboards + [ab]
        model.document = Document(
            layers: doc.layers,
            selectedLayer: doc.selectedLayer,
            selection: doc.selection,
            artboards: newAbs,
            artboardOptions: doc.artboardOptions)
        return nil
    }

    return effects
}

/// Build a Path element from a command list, applying model defaults
/// for fill/stroke when the spec omits them. Shared by
/// doc.add_path_from_buffer and doc.add_path_from_anchor_buffer.
///
/// Pencil-style callers (no `stroke_brush` key) get the default-fill/
/// default-stroke behaviour from resolveFillField/resolveStrokeField.
///
/// Paintbrush-style callers (presence of `stroke_brush` key) switch on
/// the PAINTBRUSH_TOOL.md §Fill and stroke commit rules:
///   - stroke = Stroke(state.stroke_color, paintbrushStrokeWidth(...))
///     where the width is brush.size (Calligraphic/Scatter/Bristle)
///     or state.stroke_width (no brush, or Art/Pattern).
///   - fill = state.fill_color when fill_new_strokes is true, else nil.
///   - stroke_brush_overrides passed through onto the committed Path.
private func makePathFromCommands(
    _ cmds: [PathCommand],
    model: Model,
    spec: [String: Any],
    store: StateStore,
    ctx: [String: Any]
) -> Path {
    let hasStrokeBrushArg = spec.keys.contains("stroke_brush")
    let strokeBrush = resolveStrokeBrushField(spec["stroke_brush"],
                                              hasKey: hasStrokeBrushArg,
                                              store: store, ctx: ctx)
    let strokeBrushOverrides = resolveStrokeBrushField(
        spec["stroke_brush_overrides"],
        hasKey: spec.keys.contains("stroke_brush_overrides"),
        store: store, ctx: ctx)

    let fill: Fill? = {
        if spec.keys.contains("fill_new_strokes") {
            if evalBool(spec["fill_new_strokes"], store: store, ctx: ctx) {
                let v = evalExprAsValue("state.fill_color",
                                        store: store, ctx: ctx)
                switch v {
                case .color(let c): return Color.fromHex(c).map { Fill(color: $0) }
                case .string(let s): return Color.fromHex(s).map { Fill(color: $0) }
                default: return nil
                }
            }
            return nil
        }
        return resolveFillField(spec["fill"],
                                hasKey: spec.keys.contains("fill"),
                                default: model.defaultFill,
                                store: store, ctx: ctx)
    }()

    let stroke: Stroke? = {
        if hasStrokeBrushArg {
            let colorVal = evalExprAsValue("state.stroke_color",
                                           store: store, ctx: ctx)
            let color: Color
            switch colorVal {
            case .color(let c): color = Color.fromHex(c) ?? .black
            case .string(let s): color = Color.fromHex(s) ?? .black
            default: color = .black
            }
            let width = paintbrushStrokeWidth(
                strokeBrush: strokeBrush,
                overrides: strokeBrushOverrides,
                store: store, ctx: ctx)
            return Stroke(color: color, width: width)
        }
        return resolveStrokeField(spec["stroke"],
                                  hasKey: spec.keys.contains("stroke"),
                                  default: model.defaultStroke,
                                  store: store, ctx: ctx)
    }()

    return Path(d: cmds, fill: fill, stroke: stroke,
                strokeBrush: strokeBrush,
                strokeBrushOverrides: strokeBrushOverrides)
}

/// Paintbrush-tool stroke-width commit rule per PAINTBRUSH_TOOL.md
/// §Fill and stroke:
///   - No brush slug → state.stroke_width.
///   - Brush with `size` (Calligraphic / Scatter / Bristle) → effective
///     size (overrides.size first, else brush.size).
///   - Brush with no `size` field (Art / Pattern) → state.stroke_width.
private func paintbrushStrokeWidth(
    strokeBrush: String?,
    overrides: String?,
    store: StateStore,
    ctx: [String: Any]
) -> Double {
    let stateWidth: Double = {
        let v = evalExprAsValue("state.stroke_width", store: store, ctx: ctx)
        if case .number(let n) = v { return n }
        return 1.0
    }()
    guard let slug = strokeBrush else { return stateWidth }
    // overrides.size takes precedence.
    if let json = overrides,
       let data = json.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let sz = obj["size"] as? Double {
        return sz
    }
    // Parse "libId/brushSlug" and look up brush.size from libraries.
    let parts = slug.split(separator: "/", maxSplits: 1,
                           omittingEmptySubsequences: false)
    guard parts.count == 2 else { return stateWidth }
    let libId = String(parts[0])
    let brushSlug = String(parts[1])
    let path = "brush_libraries.\(libId).brushes"
    guard let arr = store.getDataPath(path) as? [[String: Any]] else {
        return stateWidth
    }
    for brush in arr {
        if let s = brush["slug"] as? String, s == brushSlug {
            if let sz = brush["size"] as? Double { return sz }
            if let sz = brush["size"] as? Int { return Double(sz) }
            return stateWidth
        }
    }
    return stateWidth
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

/// Implementation of doc.paintbrush.edit_start. See
/// PAINTBRUSH_TOOL.md §Edit gesture — Target selection.
private func paintbrushEditStart(
    model: Model, store: StateStore,
    x: Double, y: Double, within: Double
) {
    let withinSq = within * within
    var best: (path: ElementPath, entryIdx: Int, dsq: Double)? = nil
    for es in model.document.selection {
        guard case .path(let pe) = model.document.getElement(es.path),
              !pe.locked, pe.d.count >= 2 else { continue }
        let (flat, _) = flattenWithCmdMap(pe.d)
        guard !flat.isEmpty else { continue }
        for (i, pt) in flat.enumerated() {
            let dx = pt.0 - x, dy = pt.1 - y
            let dsq = dx * dx + dy * dy
            if dsq > withinSq { continue }
            if let b = best, b.dsq <= dsq { continue }
            best = (path: es.path, entryIdx: i, dsq: dsq)
        }
    }
    if let b = best {
        store.setTool("paintbrush", "mode", "edit")
        store.setTool("paintbrush", "edit_target_path", encodePath(b.path))
        store.setTool("paintbrush", "edit_entry_idx", b.entryIdx)
    }
}

/// Implementation of doc.paintbrush.edit_commit. See
/// PAINTBRUSH_TOOL.md §Edit gesture — Splice.
private func paintbrushEditCommit(
    model: Model, store: StateStore,
    buffer: String, fitError: Double, within: Double
) {
    guard let targetPath = decodePath(store.getTool("paintbrush", "edit_target_path")) else {
        return
    }
    let entryIdx: Int = {
        let v = store.getTool("paintbrush", "edit_entry_idx")
        if let n = v as? Int { return n }
        if let n = v as? NSNumber { return n.intValue }
        return -1
    }()
    guard entryIdx >= 0 else { return }
    let dragPoints = pointBuffersPoints(buffer)
    guard dragPoints.count >= 2 else { return }

    guard case .path(let targetPe) = model.document.getElement(targetPath),
          !targetPe.locked, targetPe.d.count >= 2 else { return }
    let (flat, cmdMap) = flattenWithCmdMap(targetPe.d)
    guard !flat.isEmpty, entryIdx < flat.count else { return }

    let last = dragPoints.last!
    let withinSq = within * within
    var best: (idx: Int, dsq: Double)? = nil
    for (i, pt) in flat.enumerated() {
        let dx = pt.0 - last.0, dy = pt.1 - last.1
        let dsq = dx * dx + dy * dy
        if let b = best, b.dsq <= dsq { continue }
        best = (idx: i, dsq: dsq)
    }
    guard let b = best, b.dsq <= withinSq else { return }
    let exitIdx = b.idx
    if exitIdx == entryIdx { return }

    let loFlat = min(entryIdx, exitIdx), hiFlat = max(entryIdx, exitIdx)
    let c0 = cmdMap[loFlat], c1 = cmdMap[hiFlat]
    if c0 >= c1 || c1 >= targetPe.d.count { return }

    // Reverse drag if user dragged back-to-front so splice matches
    // the path's flow.
    let orderedDrag: [(Double, Double)] =
        exitIdx < entryIdx ? dragPoints.reversed() : dragPoints
    let startPt = cmdStartPoint(targetPe.d, c0)
    var pointsToFit: [(Double, Double)] = [startPt]
    pointsToFit.append(contentsOf: orderedDrag)
    guard pointsToFit.count >= 2 else { return }

    let segments = fitCurve(points: pointsToFit, error: fitError)
    guard !segments.isEmpty else { return }

    var newCmds: [PathCommand] = []
    newCmds.append(contentsOf: targetPe.d[..<c0])
    for seg in segments {
        newCmds.append(.curveTo(
            x1: seg.c1x, y1: seg.c1y,
            x2: seg.c2x, y2: seg.c2y,
            x: seg.p2x, y: seg.p2y))
    }
    newCmds.append(contentsOf: targetPe.d[(c1 + 1)...])

    let newDoc = model.document.replaceElement(
        targetPath, with: .path(pathWithCommands(targetPe, newCmds)))
    model.document = newDoc
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

// MARK: - Blob Brush commit helpers + effects

/// Resolve the effective tip shape (size pt, angle deg, roundness
/// percent) at commit time per BLOB_BRUSH_TOOL.md §Runtime tip
/// resolution. When state.stroke_brush points to a Calligraphic
/// library brush, its size/angle/roundness drive the tip (with
/// state.stroke_brush_overrides layered on top). Otherwise the
/// dialog defaults state.blob_brush_* are used.
///
/// Variation modes other than `fixed` are evaluated as the base
/// value in Phase 1 (matches the Paintbrush Phase 1 decision for
/// pressure/tilt/bearing).
private func blobBrushEffectiveTip(
    store: StateStore, ctx: [String: Any]
) -> (Double, Double, Double) {
    func numOr(_ expr: String, _ def: Double) -> Double {
        if case .number(let n) = evalExprAsValue(expr, store: store, ctx: ctx) {
            return n
        }
        return def
    }
    let defaultSize = numOr("state.blob_brush_size", 10.0)
    let defaultAngle = numOr("state.blob_brush_angle", 0.0)
    let defaultRoundness = numOr("state.blob_brush_roundness", 100.0)

    let slugVal = evalExprAsValue("state.stroke_brush", store: store, ctx: ctx)
    let slug: String
    if case .string(let s) = slugVal, !s.isEmpty {
        slug = s
    } else {
        return (defaultSize, defaultAngle, defaultRoundness)
    }
    guard let slashIdx = slug.firstIndex(of: "/") else {
        return (defaultSize, defaultAngle, defaultRoundness)
    }
    let libId = String(slug[..<slashIdx])
    let brushSlug = String(slug[slug.index(after: slashIdx)...])
    guard let brushes = store.getDataPath("brush_libraries.\(libId).brushes") as? [[String: Any]],
          let brush = brushes.first(where: { ($0["slug"] as? String) == brushSlug }) else {
        return (defaultSize, defaultAngle, defaultRoundness)
    }
    guard (brush["type"] as? String) == "calligraphic" else {
        return (defaultSize, defaultAngle, defaultRoundness)
    }
    let size = (brush["size"] as? NSNumber)?.doubleValue ?? defaultSize
    let angle = (brush["angle"] as? NSNumber)?.doubleValue ?? defaultAngle
    let roundness = (brush["roundness"] as? NSNumber)?.doubleValue ?? defaultRoundness

    // Apply state.stroke_brush_overrides (compact JSON) if present.
    let overridesVal = evalExprAsValue("state.stroke_brush_overrides",
                                       store: store, ctx: ctx)
    guard case .string(let overridesRaw) = overridesVal,
          !overridesRaw.isEmpty,
          let data = overridesRaw.data(using: .utf8),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
        return (size, angle, roundness)
    }
    let sizeOut = (obj["size"] as? NSNumber)?.doubleValue ?? size
    let angleOut = (obj["angle"] as? NSNumber)?.doubleValue ?? angle
    let roundnessOut = (obj["roundness"] as? NSNumber)?.doubleValue ?? roundness
    return (sizeOut, angleOut, roundnessOut)
}

/// Generate a 16-segment polygon ring approximating an ellipse
/// centered at (cx, cy) with horizontal axis = size/2, vertical
/// axis = size × roundness/100 / 2, rotated by `angleDeg`.
private func blobBrushOvalRing(
    cx: Double, cy: Double,
    size: Double, angleDeg: Double, roundnessPct: Double
) -> BoolRing {
    let segments = 16
    let rx = size * 0.5
    let ry = size * (roundnessPct / 100.0) * 0.5
    let rad = angleDeg * .pi / 180.0
    let cs = cos(rad), sn = sin(rad)
    var out: BoolRing = []
    out.reserveCapacity(segments)
    for i in 0..<segments {
        let t = 2.0 * .pi * Double(i) / Double(segments)
        let lx = rx * cos(t)
        let ly = ry * sin(t)
        let x = cx + lx * cs - ly * sn
        let y = cy + lx * sn + ly * cs
        out.append((x, y))
    }
    return out
}

/// Arc-length resample a point sequence at uniform `spacing`
/// intervals, interpolating between input points so consecutive
/// output dabs are at most `spacing` apart regardless of input
/// density. Always keeps the first and last points.
private func blobBrushArcLengthSubsample(
    _ points: [(Double, Double)], spacing: Double
) -> [(Double, Double)] {
    if points.count < 2 || spacing <= 0 { return points }
    var out: [(Double, Double)] = [points[0]]
    var remaining = spacing
    for i in 0..<(points.count - 1) {
        let (ax, ay) = points[i]
        let (bx, by) = points[i + 1]
        let dx = bx - ax
        let dy = by - ay
        let segLen = (dx * dx + dy * dy).squareRoot()
        if segLen <= 0 { continue }
        var tAt = 0.0
        while tAt + remaining <= segLen {
            tAt += remaining
            let t = tAt / segLen
            out.append((ax + dx * t, ay + dy * t))
            remaining = spacing
        }
        remaining -= segLen - tAt
    }
    if let tail = points.last,
       let lastOut = out.last,
       (lastOut.0, lastOut.1) != tail {
        out.append(tail)
    }
    return out
}

/// Build the swept region from buffer points and tip params.
/// Subsamples the buffer at ½ × min tip dimension, places an oval
/// at each sample, and unions all ovals via booleanUnion.
private func blobBrushSweepRegion(
    _ points: [(Double, Double)],
    tip: (Double, Double, Double)
) -> BoolPolygonSet {
    let (size, angle, roundness) = tip
    let minDim = min(size, size * roundness / 100.0)
    let spacing = max(minDim * 0.5, 0.5)
    let samples = blobBrushArcLengthSubsample(points, spacing: spacing)
    var region: BoolPolygonSet = []
    for (cx, cy) in samples {
        let oval: BoolPolygonSet = [blobBrushOvalRing(
            cx: cx, cy: cy,
            size: size, angleDeg: angle, roundnessPct: roundness)]
        if region.isEmpty {
            region = oval
        } else {
            region = booleanUnion(region, oval)
        }
    }
    return region
}

/// Compare two Fill values for merge purposes per BLOB_BRUSH_TOOL.md
/// §Merge condition. Returns true iff both are solid colors with
/// matching sRGB hex and opacity, neither is nil.
private func blobBrushFillMatches(_ a: Fill?, _ b: Fill?) -> Bool {
    guard let fa = a, let fb = b else { return false }
    return fa.color.toHex().lowercased() == fb.color.toHex().lowercased()
        && abs(fa.opacity - fb.opacity) < 1e-9
}

/// Implementation of doc.blob_brush.commit_painting.
/// See BLOB_BRUSH_TOOL.md §Commit pipeline + §Multi-element merge.
private func blobBrushCommitPainting(
    model: Model, store: StateStore, ctx: [String: Any],
    buffer: String,
    fidelityEpsilon _: Double, // RDP simplify deferred to follow-up
    mergeOnlyWithSelection: Bool,
    keepSelected _: Bool // Selection update deferred; future follow-up
) {
    let points = pointBuffersPoints(buffer)
    if points.count < 2 { return }

    let tip = blobBrushEffectiveTip(store: store, ctx: ctx)
    let swept = blobBrushSweepRegion(points, tip: tip)
    if swept.isEmpty { return }

    // Resolve fill from state.fill_color.
    let fillVal = evalExprAsValue("state.fill_color", store: store, ctx: ctx)
    let fillColor: Color?
    switch fillVal {
    case .color(let c): fillColor = Color.fromHex(c)
    case .string(let s): fillColor = Color.fromHex(s)
    default: fillColor = nil
    }
    let newFill: Fill? = fillColor.map { Fill(color: $0) }

    // Find matching existing blob-brush elements in top-level layers'
    // children. Matching == toolOrigin == "blob_brush" + fill matches
    // newFill + (optional) selection-scoped.
    let doc = model.document
    let selectedPaths = Set(doc.selection.map { $0.path })
    var matches: [ElementPath] = []
    var unified = swept
    for (li, layer) in doc.layers.enumerated() {
        for (ci, child) in layer.children.enumerated() {
            guard case .path(let pe) = child else { continue }
            guard pe.toolOrigin == "blob_brush" else { continue }
            guard blobBrushFillMatches(pe.fill, newFill) else { continue }
            let path: ElementPath = [li, ci]
            if mergeOnlyWithSelection && !selectedPaths.contains(path) {
                continue
            }
            let existing = pathToPolygonSet(pe.d)
            // Cheap reject: skip if no spatial overlap.
            if booleanIntersect(unified, existing).isEmpty { continue }
            unified = booleanUnion(unified, existing)
            matches.append(path)
        }
    }

    // Insertion z = lowest matching (layer, child); default append.
    let insertLayer: Int
    let insertIdx: Int?
    if matches.isEmpty {
        insertLayer = 0
        insertIdx = nil
    } else {
        let lowest = matches[0]
        insertLayer = lowest[0]
        insertIdx = lowest[1]
    }

    let newD = polygonSetToPath(unified)
    if newD.isEmpty { return }
    let newElem = Path(
        d: newD,
        fill: newFill, stroke: nil,
        widthPoints: [],
        toolOrigin: "blob_brush"
    )

    // Build new document: remove matches in reverse (so earlier
    // indices stay valid), then insert the unified element.
    var newDoc = doc
    for path in matches.sorted(by: { $0.lexicographicallyPrecedes($1) }).reversed() {
        newDoc = newDoc.deleteElement(path)
    }
    if let idx = insertIdx {
        // Lowest matching (layer, child). The post-delete layer may
        // be shorter, but the lowest match's child index is still a
        // valid insertion point at (insertLayer, idx).
        newDoc = blobBrushInsertAt(newDoc, layerIdx: insertLayer,
                                   childIdx: idx, element: .path(newElem))
    } else {
        // No matches — append as a top-level child of layer 0.
        let children = newDoc.layers[insertLayer].children
        newDoc = blobBrushInsertAt(
            newDoc, layerIdx: insertLayer,
            childIdx: children.count, element: .path(newElem))
    }
    model.document = newDoc
}

/// Implementation of doc.blob_brush.commit_erasing.
/// See BLOB_BRUSH_TOOL.md §Erase gesture → Commit.
private func blobBrushCommitErasing(
    model: Model, store: StateStore, ctx: [String: Any],
    buffer: String,
    fidelityEpsilon _: Double
) {
    let points = pointBuffersPoints(buffer)
    if points.count < 2 { return }

    let tip = blobBrushEffectiveTip(store: store, ctx: ctx)
    let swept = blobBrushSweepRegion(points, tip: tip)
    if swept.isEmpty { return }

    let doc = model.document
    var newDoc = doc
    // Iterate in reverse so deletions don't invalidate earlier indices.
    for li in (0..<doc.layers.count).reversed() {
        let children = doc.layers[li].children
        for ci in (0..<children.count).reversed() {
            guard case .path(let pe) = children[ci] else { continue }
            guard pe.toolOrigin == "blob_brush" else { continue }
            let existing = pathToPolygonSet(pe.d)
            if booleanIntersect(existing, swept).isEmpty { continue }
            let remainder = booleanSubtract(existing, swept)
            let path: ElementPath = [li, ci]
            let newD = polygonSetToPath(remainder)
            if newD.isEmpty {
                newDoc = newDoc.deleteElement(path)
            } else {
                let newPe = Path(
                    d: newD,
                    fill: pe.fill, stroke: pe.stroke,
                    widthPoints: pe.widthPoints,
                    opacity: pe.opacity, transform: pe.transform,
                    locked: pe.locked, visibility: pe.visibility,
                    blendMode: pe.blendMode, mask: pe.mask,
                    fillGradient: pe.fillGradient,
                    strokeGradient: pe.strokeGradient,
                    strokeBrush: pe.strokeBrush,
                    strokeBrushOverrides: pe.strokeBrushOverrides,
                    toolOrigin: pe.toolOrigin)
                newDoc = newDoc.replaceElement(path, with: .path(newPe))
            }
        }
    }
    model.document = newDoc
}

/// Insert `element` at `doc.layers[layerIdx].children[childIdx]`,
/// shifting later children down. Used by blob_brush commit_painting
/// where Controller.addElement would always append + re-select.
private func blobBrushInsertAt(
    _ doc: Document, layerIdx: Int, childIdx: Int, element: Element
) -> Document {
    var layers = doc.layers
    guard layerIdx < layers.count else { return doc }
    let layer = layers[layerIdx]
    var children = layer.children
    let clamped = max(0, min(childIdx, children.count))
    children.insert(element, at: clamped)
    layers[layerIdx] = Layer(
        name: layer.name, children: children,
        opacity: layer.opacity, transform: layer.transform)
    return Document(
        layers: layers, selectedLayer: doc.selectedLayer,
        selection: doc.selection, artboards: doc.artboards,
        artboardOptions: doc.artboardOptions)
}

// MARK: - Path validity

/// True when `path` references an existing element in `doc`.
/// Document's `getElement(_:)` fatalErrors on invalid input, so this
/// helper does a defensive walk instead. `childrenOf` in Document is
/// private, so we inline the switch. `internal` so the transform-tool
/// overlay code in YamlTool.swift can reuse it.
internal func isValidPath(_ doc: Document, _ path: ElementPath) -> Bool {
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
// ──────────────────────────────────────────────────────────────────
// Transform tools (Scale / Rotate / Shear) apply effects.
// See SCALE_TOOL.md / ROTATE_TOOL.md / SHEAR_TOOL.md §Apply behavior.
// ──────────────────────────────────────────────────────────────────

/// Resolve the active reference point for a transform-tool apply.
/// Reads state.transform_reference_point — when it's a list of two
/// numbers, returns those as (rx, ry). Otherwise falls back to the
/// union bounding-box center of the current selection.
private func resolveReferencePoint(
    model: Model, store: StateStore, ctx: [String: Any]
) -> (Double, Double) {
    // Custom reference point.
    let evalCtx = store.evalContext(extra: ctx)
    let v = evaluate("state.transform_reference_point", context: evalCtx)
    if case .list(let items) = v, items.count >= 2 {
        let rx = (items[0].value as? NSNumber)?.doubleValue ?? Double.nan
        let ry = (items[1].value as? NSNumber)?.doubleValue ?? Double.nan
        if !rx.isNaN && !ry.isNaN { return (rx, ry) }
    }
    // Fallback: selection union bbox center.
    let doc = model.document
    let elements: [Element] = doc.selection.compactMap { es in
        isValidPath(doc, es.path) ? doc.getElement(es.path) : nil
    }
    if elements.isEmpty { return (0, 0) }
    let bb = alignUnionBounds(elements, alignGeometricBounds)
    return (bb.x + bb.width / 2, bb.y + bb.height / 2)
}

/// Convert drag inputs (press, cursor, ref) to scale factors per
/// SCALE_TOOL.md §Gestures: sx = (cx-rx)/(px-rx), sy = (cy-ry)/(py-ry).
/// Shift forces signed geometric mean onto both axes.
private func dragToScaleFactors(
    px: Double, py: Double, cx: Double, cy: Double,
    rx: Double, ry: Double, shift: Bool
) -> (Double, Double) {
    let denomX = px - rx
    let denomY = py - ry
    let sx = abs(denomX) < 1e-9 ? 1.0 : (cx - rx) / denomX
    let sy = abs(denomY) < 1e-9 ? 1.0 : (cy - ry) / denomY
    if shift {
        let prod = sx * sy
        let sign: Double = prod >= 0 ? 1.0 : -1.0
        let s = sign * sqrt(abs(prod))
        return (s, s)
    }
    return (sx, sy)
}

/// Convert drag inputs to a rotation angle (degrees) per
/// ROTATE_TOOL.md §Gestures. Shift snaps to nearest 45 deg.
private func dragToRotateAngle(
    px: Double, py: Double, cx: Double, cy: Double,
    rx: Double, ry: Double, shift: Bool
) -> Double {
    let thetaPress  = atan2(py - ry, px - rx)
    let thetaCursor = atan2(cy - ry, cx - rx)
    var thetaDeg = (thetaCursor - thetaPress) * 180.0 / .pi
    if shift { thetaDeg = (thetaDeg / 45.0).rounded() * 45.0 }
    return thetaDeg
}

/// Convert drag inputs to (angle_deg, axis, axis_angle_deg) per
/// SHEAR_TOOL.md §Gestures.
private func dragToShearParams(
    px: Double, py: Double, cx: Double, cy: Double,
    rx: Double, ry: Double, shift: Bool
) -> (Double, String, Double) {
    let dx = cx - px
    let dy = cy - py
    if shift {
        if abs(dx) >= abs(dy) {
            let denom = max(abs(py - ry), 1e-9)
            let k = dx / denom
            return (atan(k) * 180.0 / .pi, "horizontal", 0)
        } else {
            let denom = max(abs(px - rx), 1e-9)
            let k = dy / denom
            return (atan(k) * 180.0 / .pi, "vertical", 0)
        }
    }
    let ax = px - rx
    let ay = py - ry
    let axisLen = max(sqrt(ax * ax + ay * ay), 1e-9)
    let perpX = -ay / axisLen
    let perpY = ax / axisLen
    let perpDist = (cx - px) * perpX + (cy - py) * perpY
    let k = perpDist / axisLen
    let axisAngleDeg = atan2(ay, ax) * 180.0 / .pi
    return (atan(k) * 180.0 / .pi, "custom", axisAngleDeg)
}

/// Scale apply implementation. Pre-multiplies each selected
/// element's existing transform with the scale matrix. Honors
/// state.scale_strokes (geometric mean of |sx|, |sy|) and
/// state.scale_corners (rounded_rect rx/ry, axis-independent).
/// When copy is true, duplicates the selection first then applies
/// the matrix to the duplicates.
private func scaleApply(
    model: Model, store: StateStore, ctx: [String: Any],
    sx: Double, sy: Double, copy: Bool
) {
    if abs(sx - 1.0) < 1e-9 && abs(sy - 1.0) < 1e-9 { return }
    if copy { Controller(model: model).copySelection(dx: 0, dy: 0) }
    let (rx, ry) = resolveReferencePoint(model: model, store: store, ctx: ctx)
    let matrix = TransformApply.scaleMatrix(sx: sx, sy: sy, rx: rx, ry: ry)

    let evalCtx = store.evalContext(extra: ctx)
    let scaleStrokes: Bool = {
        if case .bool(let b) = evaluate("state.scale_strokes", context: evalCtx) { return b }
        return true
    }()
    let scaleCorners: Bool = {
        if case .bool(let b) = evaluate("state.scale_corners", context: evalCtx) { return b }
        return false
    }()
    let strokeFactor = TransformApply.strokeWidthFactor(sx: sx, sy: sy)

    var newDoc = model.document
    for es in newDoc.selection {
        guard isValidPath(newDoc, es.path) else { continue }
        let elem = newDoc.getElement(es.path)
        var newElem = elem.withTransformPremultiplied(matrix)
        if scaleStrokes {
            newElem = scaleElementStrokeWidth(newElem, factor: strokeFactor)
        }
        if scaleCorners {
            newElem = scaleElementCorners(newElem, sxAbs: abs(sx), syAbs: abs(sy))
        }
        newDoc = newDoc.replaceElement(es.path, with: newElem)
    }
    model.document = newDoc
}

/// Rotate apply. Rigid transform — no stroke / corner options.
private func rotateApply(
    model: Model, store: StateStore, ctx: [String: Any],
    thetaDeg: Double, copy: Bool
) {
    if abs(thetaDeg) < 1e-9 { return }
    if copy { Controller(model: model).copySelection(dx: 0, dy: 0) }
    let (rx, ry) = resolveReferencePoint(model: model, store: store, ctx: ctx)
    let matrix = TransformApply.rotateMatrix(thetaDeg: thetaDeg, rx: rx, ry: ry)

    var newDoc = model.document
    for es in newDoc.selection {
        guard isValidPath(newDoc, es.path) else { continue }
        let elem = newDoc.getElement(es.path)
        let newElem = elem.withTransformPremultiplied(matrix)
        newDoc = newDoc.replaceElement(es.path, with: newElem)
    }
    model.document = newDoc
}

/// Shear apply. Pure shear has determinant 1 — strokes preserved
/// naturally; no stroke / corner options.
private func shearApply(
    model: Model, store: StateStore, ctx: [String: Any],
    angleDeg: Double, axis: String, axisAngleDeg: Double, copy: Bool
) {
    if abs(angleDeg) < 1e-9 { return }
    if copy { Controller(model: model).copySelection(dx: 0, dy: 0) }
    let (rx, ry) = resolveReferencePoint(model: model, store: store, ctx: ctx)
    let matrix = TransformApply.shearMatrix(
        angleDeg: angleDeg, axis: axis,
        axisAngleDeg: axisAngleDeg, rx: rx, ry: ry)

    var newDoc = model.document
    for es in newDoc.selection {
        guard isValidPath(newDoc, es.path) else { continue }
        let elem = newDoc.getElement(es.path)
        let newElem = elem.withTransformPremultiplied(matrix)
        newDoc = newDoc.replaceElement(es.path, with: newElem)
    }
    model.document = newDoc
}

/// Multiply the element's stroke-width by `factor` if present.
private func scaleElementStrokeWidth(_ elem: Element, factor: Double) -> Element {
    guard let stroke = elem.stroke else { return elem }
    let newStroke = Stroke(
        color: stroke.color, width: stroke.width * factor,
        linecap: stroke.linecap, linejoin: stroke.linejoin,
        miterLimit: stroke.miterLimit, align: stroke.align,
        dashPattern: stroke.dashPattern,
        startArrow: stroke.startArrow, endArrow: stroke.endArrow,
        startArrowScale: stroke.startArrowScale,
        endArrowScale: stroke.endArrowScale,
        arrowAlign: stroke.arrowAlign, opacity: stroke.opacity)
    return withStroke(elem, stroke: newStroke)
}

/// Scale a rounded_rect's rx / ry by (sxAbs, syAbs). No-op on
/// other element types — corner radii are only modeled on Rect.
private func scaleElementCorners(_ elem: Element, sxAbs: Double, syAbs: Double) -> Element {
    if case .rect(let r) = elem {
        return .rect(Rect(
            x: r.x, y: r.y, width: r.width, height: r.height,
            rx: r.rx * sxAbs, ry: r.ry * syAbs,
            fill: r.fill, stroke: r.stroke, opacity: r.opacity,
            transform: r.transform, locked: r.locked, visibility: r.visibility))
    }
    return elem
}

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

/// Read a numeric viewport preference from workspace.json. Returns
/// the provided default if the workspace can't be loaded or the
/// field isn't a number. Used by doc.zoom.* effects that need
/// min_zoom / max_zoom / scrubby_zoom_gain from
/// preferences.viewport.* — mirrors read_pref_number in
/// jas_dioxus/src/interpreter/effects.rs.
internal func readPrefNumber(_ key: String, default defaultValue: Double) -> Double {
    guard let ws = WorkspaceData.load() else { return defaultValue }
    if let prefs = ws.data["preferences"] as? [String: Any],
       let viewport = prefs["viewport"] as? [String: Any],
       let n = viewport[key] as? NSNumber {
        return n.doubleValue
    }
    return defaultValue
}

/// Read a numeric tool.zoom.<key> from the eval context. Used by
/// doc.zoom.scrubby to recover the zoom + offset snapshot taken at
/// mousedown.
internal func readToolZoomState(_ ctx: [String: Any], _ key: String, default defaultValue: Double) -> Double {
    if let tool = ctx["tool"] as? [String: Any],
       let zoom = tool["zoom"] as? [String: Any],
       let n = zoom[key] as? NSNumber {
        return n.doubleValue
    }
    return defaultValue
}

/// Compute fit-to-viewport zoom + pan that places the document
/// rectangle (x, y, w, h) inside the viewport with `padding`
/// screen-space pixels of breathing room. Letterbox aspect-ratio
/// resolution; centered. No-op when inputs are degenerate.
internal func fitRectIntoViewport(model: Model, x: Double, y: Double,
                                  w: Double, h: Double, padding: Double) {
    if w <= 0 || h <= 0 { return }
    let vw = model.viewportW
    let vh = model.viewportH
    if vw <= 0 || vh <= 0 { return }
    let availW = vw - 2.0 * padding
    let availH = vh - 2.0 * padding
    if availW <= 0 || availH <= 0 { return }
    let minZoom = readPrefNumber("min_zoom", default: 0.1)
    let maxZoom = readPrefNumber("max_zoom", default: 64.0)
    let z = min(max(min(availW / w, availH / h), minZoom), maxZoom)
    let rectCx = x + w / 2.0
    let rectCy = y + h / 2.0
    model.zoomLevel = z
    model.viewOffsetX = vw / 2.0 - rectCx * z
    model.viewOffsetY = vh / 2.0 - rectCy * z
}

/// Document bounding box: union of all top-level layer bounds.
/// Returns (0, 0, 0, 0) for an empty document. Mirrors
/// Document::bounds() in Rust.
internal func documentBounds(_ doc: Document) -> (x: Double, y: Double, w: Double, h: Double) {
    if doc.layers.isEmpty {
        return (0, 0, 0, 0)
    }
    var minX = Double.infinity
    var minY = Double.infinity
    var maxX = -Double.infinity
    var maxY = -Double.infinity
    for layer in doc.layers {
        let b = layer.bounds
        let bx = Double(b.x), by = Double(b.y)
        let bw = Double(b.width), bh = Double(b.height)
        minX = min(minX, bx)
        minY = min(minY, by)
        maxX = max(maxX, bx + bw)
        maxY = max(maxY, by + bh)
    }
    if minX.isInfinite || minY.isInfinite { return (0, 0, 0, 0) }
    return (minX, minY, maxX - minX, maxY - minY)
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

// MARK: - data.* / brush.* effect helpers

/// Resolve a YAML value field. Strings are evaluated as expressions
/// (matching the doc.set_attr / set: convention); non-strings are
/// used verbatim. Lets brush.append etc. accept inline JSON
/// dictionaries where the expression language has no object literal
/// syntax. Mirrors the JS resolveValueOrExpr helper.
private func resolveValueOrExpr(_ spec: Any?, store: StateStore, ctx: [String: Any]) -> Any? {
    guard let spec = spec else { return nil }
    if let s = spec as? String {
        let v = evalExprAsValue(s, store: store, ctx: ctx)
        return valueToAny(v)
    }
    return spec
}

private func valueToAny(_ v: Value) -> Any? {
    switch v {
    case .null: return nil
    case .bool(let b): return b
    case .number(let n): return n
    case .string(let s): return s
    case .color(let c): return c
    case .list(let items): return items.map { $0.value }
    case .path(let p): return p
    case .closure: return nil
    }
}

private func evalStringValue(_ arg: Any?, store: StateStore, ctx: [String: Any]) -> String {
    guard let arg = arg else { return "" }
    if let s = arg as? String {
        if case .string(let rs) = evalExprAsValue(s, store: store, ctx: ctx) {
            return rs
        }
    }
    return ""
}

private func evalStringList(_ arg: Any?, store: StateStore, ctx: [String: Any]) -> [String] {
    if let arr = arg as? [Any] {
        return arr.compactMap { $0 as? String }
    }
    if let s = arg as? String {
        if case .list(let items) = evalExprAsValue(s, store: store, ctx: ctx) {
            return items.compactMap { $0.value as? String }
        }
    }
    return []
}

/// Filter out brushes whose slug appears in `slugs` from the named
/// library; writes the resulting list back into store.data.
private func brushFilterLibraryBySlug(store: StateStore, libId: String, slugs: Set<String>) {
    let path = "brush_libraries.\(libId).brushes"
    guard let raw = store.getDataPath(path) as? [[String: Any]] else { return }
    let next = raw.filter { brush in
        guard let slug = brush["slug"] as? String else { return true }
        return !slugs.contains(slug)
    }
    store.setDataPath(path, next)
}

/// Duplicate selected brushes within a library. Each copy gets
/// " copy" appended to the name and a unique <slug>_copy[_N] slug.
/// Returns the new slugs in insertion order.
private func brushDuplicateInLibrary(store: StateStore, libId: String, slugs: [String]) -> [String] {
    var newSlugs: [String] = []
    let path = "brush_libraries.\(libId).brushes"
    guard let brushes = store.getDataPath(path) as? [[String: Any]] else { return newSlugs }
    var existingSlugs: Set<String> = Set(brushes.compactMap { $0["slug"] as? String })
    var next: [[String: Any]] = []
    next.reserveCapacity(brushes.count)
    for b in brushes {
        next.append(b)
        guard let slug = b["slug"] as? String, slugs.contains(slug) else { continue }
        var copy = b
        let name = (b["name"] as? String) ?? "Brush"
        copy["name"] = "\(name) copy"
        var newSlug = "\(slug)_copy"
        var n = 2
        while existingSlugs.contains(newSlug) {
            newSlug = "\(slug)_copy_\(n)"
            n += 1
        }
        existingSlugs.insert(newSlug)
        copy["slug"] = newSlug
        newSlugs.append(newSlug)
        next.append(copy)
    }
    store.setDataPath(path, next)
    return newSlugs
}

private func brushAppendToLibrary(store: StateStore, libId: String, brush: [String: Any]) {
    let path = "brush_libraries.\(libId).brushes"
    var brushes = (store.getDataPath(path) as? [[String: Any]]) ?? []
    brushes.append(brush)
    store.setDataPath(path, brushes)
}

private func brushUpdateInLibrary(store: StateStore, libId: String, slug: String, patch: [String: Any]) {
    let path = "brush_libraries.\(libId).brushes"
    guard var brushes = store.getDataPath(path) as? [[String: Any]] else { return }
    for i in brushes.indices {
        if (brushes[i]["slug"] as? String) == slug {
            for (k, v) in patch {
                brushes[i][k] = v
            }
            break
        }
    }
    store.setDataPath(path, brushes)
}

/// Push the current data.brush_libraries through to the canvas
/// renderer's brush registry so the next paint sees the updates.
private func syncCanvasBrushes(store: StateStore) {
    let libs = (store.getDataPath("brush_libraries") as? [String: Any]) ?? [:]
    setCanvasBrushLibraries(libs)
}

// MARK: - Magic Wand effect

/// Implementation of doc.magic_wand.apply. See
/// MAGIC_WAND_TOOL.md §Predicate + §Eligibility filter.
private func magicWandApply(
    model: Model, store: StateStore, ctx: [String: Any],
    seedPath: ElementPath, mode: String
) {
    // Resolve the seed Element. Stale paths bail silently.
    let doc = model.document
    guard isValidPath(doc, seedPath) else { return }
    let seed = doc.getElement(seedPath)

    // Read state.magic_wand_* keys into a config.
    let cfg = readMagicWandConfig(store: store, ctx: ctx)

    // Walk the document and collect every leaf path that is (a)
    // eligible per §Eligibility filter and (b) similar to the
    // seed under cfg. The seed itself is always included
    // regardless of self-match.
    var matches: [ElementPath] = []
    var cur: ElementPath = []
    walkEligible(doc: doc, cur: &cur) { path, candidate in
        if path == seedPath {
            matches.append(path)
            return
        }
        if magicWandMatch(seed: seed, candidate: candidate, config: cfg) {
            matches.append(path)
        }
    }

    let newEntries = matches.map { ElementSelection.all($0) }
    switch mode {
    case "add":
        var existing = doc.selection
        for es in newEntries where !existing.contains(where: { $0.path == es.path }) {
            existing.insert(es)
        }
        Controller(model: model).setSelection(existing)
    case "subtract":
        let toRemove = Set(newEntries.map { $0.path })
        let kept = doc.selection.filter { !toRemove.contains($0.path) }
        Controller(model: model).setSelection(Set(kept))
    default:
        // "replace"
        Controller(model: model).setSelection(Set(newEntries))
    }
}

/// Read the nine state.magic_wand_* keys into a MagicWandConfig.
private func readMagicWandConfig(
    store: StateStore, ctx: [String: Any]
) -> MagicWandConfig {
    var cfg = MagicWandConfig()
    let boolAt = { (key: String, fallback: Bool) -> Bool in
        switch evalExprAsValue("state.\(key)", store: store, ctx: ctx) {
        case .bool(let b): return b
        default: return fallback
        }
    }
    let numAt = { (key: String, fallback: Double) -> Double in
        switch evalExprAsValue("state.\(key)", store: store, ctx: ctx) {
        case .number(let n): return n
        default: return fallback
        }
    }
    cfg.fillColor = boolAt("magic_wand_fill_color", cfg.fillColor)
    cfg.fillTolerance = numAt("magic_wand_fill_tolerance", cfg.fillTolerance)
    cfg.strokeColor = boolAt("magic_wand_stroke_color", cfg.strokeColor)
    cfg.strokeTolerance = numAt("magic_wand_stroke_tolerance",
                                cfg.strokeTolerance)
    cfg.strokeWeight = boolAt("magic_wand_stroke_weight", cfg.strokeWeight)
    cfg.strokeWeightTolerance = numAt(
        "magic_wand_stroke_weight_tolerance", cfg.strokeWeightTolerance)
    cfg.opacity = boolAt("magic_wand_opacity", cfg.opacity)
    cfg.opacityTolerance = numAt("magic_wand_opacity_tolerance",
                                 cfg.opacityTolerance)
    cfg.blendingMode = boolAt("magic_wand_blending_mode", cfg.blendingMode)
    return cfg
}

/// Walk the document tree, invoking visit(path, element) for every
/// leaf element that passes the §Eligibility filter — locked /
/// hidden elements skipped; Group / Layer containers descend into
/// children but are not themselves candidates.
private func walkEligible(
    doc: Document, cur: inout ElementPath,
    visit: (ElementPath, Element) -> Void
) {
    for (li, layer) in doc.layers.enumerated() {
        cur.append(li)
        walkEligibleIn(.layer(layer), cur: &cur, visit: visit)
        cur.removeLast()
    }
}

private func walkEligibleIn(
    _ elem: Element, cur: inout ElementPath,
    visit: (ElementPath, Element) -> Void
) {
    if elem.isLocked { return }
    if elem.visibility == .invisible { return }
    switch elem {
    case .group(let g):
        for (i, child) in g.children.enumerated() {
            cur.append(i)
            walkEligibleIn(child, cur: &cur, visit: visit)
            cur.removeLast()
        }
    case .layer(let l):
        for (i, child) in l.children.enumerated() {
            cur.append(i)
            walkEligibleIn(child, cur: &cur, visit: visit)
            cur.removeLast()
        }
    default:
        visit(cur, elem)
    }
}
