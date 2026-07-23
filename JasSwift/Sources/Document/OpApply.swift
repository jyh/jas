import Foundation

/// The single op dispatcher — `opApply` (OP_LOG.md §4 / §9, Increment 3b-B).
///
/// STAGED-ASTERISK: this is the promoted, production-shared form of what was the
/// `#if DEBUG` `applyFixtureOp` dispatcher in the cross-language harness. It is
/// the §4 single-path end-state built in the increment that needs it. In 3b-B it
/// is adopted from production for **exactly three replay-safe verbs** —
/// `select_rect`, `copy_selection`, and `move_selection` — which are the ones
/// `captureRecipe` consumes. Those three populate `targets:[common.id]` (Fork 4);
/// EVERY OTHER verb here keeps `targets: []` and is reachable only from the
/// harness (which shims through this module so harness + production share ONE
/// dispatcher and ONE `recordOp` site). The other ~30 `doc.*` production verbs,
/// the AppState-level Layers-panel handlers (Duplicate / Duplicate Artboard),
/// the per-frame drag coalescing, and the full verb unification are explicitly
/// deferred per OP_LOG.md §9.
///
/// Production input must never crash, so every param read is hardened: numbers
/// resolve with a 0.0 default; a missing REQUIRED field (a path, an id, a
/// transform) returns/skips rather than force-unwrapping. The harness fixtures
/// (which always carry well-formed params) replay byte-identically.
///
/// CRITICAL (Swift): `Model.document` is the mutation chokepoint, but it does
/// NOT self-bracket a transaction the way Rust's `edit_document` does. The lazy
/// `beginTxn` here (excluding `select_rect`) is therefore the ONLY safeguard
/// against the subsequent-drag-frame journaling hole — a bare drag frame (no
/// preceding `doc.snapshot`) still opens and records into a transaction, which
/// the batch owner (`runEffects`) names and commits. So ALL THREE journaled-verb
/// paths MUST flow through `opApply`, never a direct `Controller` call.
///
/// Mirrors `jas_dioxus`'s `document/op_apply.rs`.

/// Parse a JSON array of indices into an `ElementPath`. Returns nil if the field
/// is absent or not an array of integers (a malformed production payload skips
/// the op rather than crashing).
private func parsePath(_ v: Any?) -> ElementPath? {
    guard let arr = v as? [Any] else { return nil }
    return arr.map { ($0 as? NSNumber)?.intValue ?? 0 }
}

/// Read a string field, or nil if absent / not a string.
private func strField(_ op: [String: Any], _ key: String) -> String? {
    op[key] as? String
}

/// Read an f64 field, defaulting to 0.0 (the non-crashing number form).
private func numField(_ op: [String: Any], _ key: String) -> Double {
    (op[key] as? NSNumber)?.doubleValue ?? 0.0
}

/// Read a list-of-strings field (the `ids` payload for the artboard move
/// verbs). Non-string entries are dropped; a missing/non-array field yields [].
private func strListField(_ op: [String: Any], _ key: String) -> [String] {
    (op[key] as? [Any])?.compactMap { $0 as? String } ?? []
}

/// Read a usize field (an index), defaulting to 0 (the non-crashing form).
private func uintField(_ op: [String: Any], _ key: String) -> Int {
    max(0, (op[key] as? NSNumber)?.intValue ?? 0)
}

/// Parse a `transform` field — a 6-element matrix `[a,b,c,d,e,f]` — into a
/// `Transform`, defaulting to identity when absent or malformed (CONCEPTS.md §10
/// `promote`). Hardened: a wrong-length / non-numeric array is identity, never a
/// crash. Mirrors Rust `parse_transform`.
private func parseTransform(_ v: Any?) -> Transform {
    guard let arr = v as? [Any], arr.count == 6 else { return .identity }
    let m = arr.map { ($0 as? NSNumber)?.doubleValue ?? 0.0 }
    return Transform(a: m[0], b: m[1], c: m[2], d: m[3], e: m[4], f: m[5])
}

// MARK: - id-primary op family (OP_LOG.md §5 Fork 4 / RECORDED_ELEMENTS.md)
//
// The id-primary verbs `select_by_ids` / `move_by_ids` / `copy_by_ids` promote
// the recorded-recipe vocabulary (input-addressed, side-effect-free) to a
// first-class op family `opApply` can execute, so a captured recipe IS a
// replayable journal segment (RECORDED_ELEMENTS.md §7) and `captureRecipe`
// collapses to a pass-through. They are ADDITIVE: the selection-relative verbs
// (`select_rect` / `move_selection` / `copy_selection`) keep their params
// VERBATIM (OP_LOG.md §7 — selection is serialized Document state, so the
// byte-gate reproduces it); this is a NEW family, not a params rewrite. The
// decisive property (OP_LOG.md §7 determinism rule): the operand ids come from
// the OP'S OWN PARAMS, never inferred from doc.selection, so snapshot and
// replay apply identical operands and a recorded recipe survives source edits
// with NO selection dependency.
//
// THE BYTE-GATE RECONCILIATION (OP_LOG.md §6, the gate compares
// documentToTestJson INCLUDING selection): the family is committed as the
// canonical PAIR `[select_by_ids, <op>_by_ids]`, AND each `<op>_by_ids` ALSO
// re-establishes the working selection from its OWN ids before mutating. So the
// replayed selection is byte-identical to `[select_rect, move_selection]` for
// the same elements: `select_by_ids` resolves ids to paths and writes
// `ElementSelection.all(path)` in DOCUMENT ORDER (the same order `selectFlat`/
// `select_rect` produces — and the selection serializer sorts by path, so the
// emitted bytes match regardless), then the mutator routes through the SAME
// shared `Controller` body (no divergent second mutation path). Hardened reads:
// an unknown id / a non-array params is SKIPPED, never a crash.

/// Walk the element tree (Group/Layer children only — the SAME descent
/// discipline as the IdIndex builder `collectRefIds`) collecting `(id, path)`
/// for every id-bearing element, in DOCUMENT ORDER. The id-primary selection
/// builder uses this so a `select_by_ids` produces the SAME ordered selection a
/// `select_rect` over the same elements would. Top-level layer ids are NOT
/// resolution targets (mirroring the IdIndex), so the walk starts at each
/// layer's children, exactly like `rebuildIdIndex`. Mirrors Rust
/// `id_paths_in_document_order`.
private func idPathsInDocumentOrder(_ doc: Document) -> [(String, ElementPath)] {
    var out: [(String, ElementPath)] = []
    func walk(_ elem: Element, _ path: ElementPath) {
        if let id = elem.id { out.append((id, path)) }
        switch elem {
        case .group(let g):
            for (i, child) in g.children.enumerated() { walk(child, path + [i]) }
        case .layer(let l):
            for (i, child) in l.children.enumerated() { walk(child, path + [i]) }
        default:
            break
        }
    }
    for (li, layer) in doc.layers.enumerated() {
        for (ci, child) in layer.children.enumerated() {
            walk(child, [li, ci])
        }
    }
    return out
}

/// Build the selection (in DOCUMENT ORDER) for the elements whose `id` is in
/// `ids`, as `ElementSelection.all(path)` entries. Document order — NOT the
/// order of `ids` — so the result is byte-identical to what `select_rect` would
/// produce for the same set (the byte-gate reconciliation; the selection
/// serializer also sorts by path). An id that resolves to no element is silently
/// dropped (hardened: a stale/unknown id is a skip). Mirrors Rust
/// `selection_for_ids`.
private func selectionForIds(_ doc: Document, _ ids: [String]) -> Selection {
    let wanted = Set(ids)
    var sel: Selection = []
    for (id, path) in idPathsInDocumentOrder(doc) where wanted.contains(id) {
        sel.insert(ElementSelection.all(path))
    }
    return sel
}

/// Resolve `ids` to their selection and write it BY PATH (selection-only,
/// non-undoable — like `select_rect`, this goes through the unbracketed
/// selection write via `Controller.setSelection`). The id-primary
/// `select_by_ids` body, SHARED by the standalone `select_by_ids` op and by
/// `move_by_ids`/`copy_by_ids` (which re-establish the working selection from
/// their own ids before the mutation). Returns the resolved selection ids (in
/// document order) for `targets`. Mirrors Rust `apply_select_by_ids`.
@discardableResult
func applySelectByIds(_ model: Model, _ controller: Controller, _ ids: [String]) -> [String] {
    let selection = selectionForIds(model.document, ids)
    controller.setSelection(selection)
    return selectionToIds(model.document)
}

/// Read a bool field, defaulting to `def`. Distinguishes a JSON bool from a
/// JSON number (JSONSerialization maps both to NSNumber) via `isBool`.
private func boolField(_ op: [String: Any], _ key: String, _ def: Bool) -> Bool {
    if let n = op[key] as? NSNumber, n.isBool { return n.boolValue }
    if let b = op[key] as? Bool { return b }
    return def
}

/// Convert a RESOLVED JSON value (the `value` op param, from
/// JSONSerialization: NSNumber / String / NSNull) into the interpreter `Value`
/// enum. Mirrors serde_json type discrimination: a JSON bool → `.bool`, a JSON
/// number → `.number`, a JSON string → `.string`. A non-matching type yields
/// nil, which the per-field arms treat as "skip" exactly like Rust's
/// `as_bool()`/`as_f64()`/`as_str()` returning None. Used by the print-config
/// and artboard setters so the field-coerce + type-mismatch-skip is
/// byte-identical to the production handler (which builds the same `Value`).
private func jsonToValue(_ v: Any?) -> Value? {
    if let n = v as? NSNumber {
        return n.isBool ? .bool(n.boolValue) : .number(n.doubleValue)
    }
    if let b = v as? Bool { return .bool(b) }
    if let s = v as? String { return .string(s) }
    return nil
}

// MARK: - Print-config field setters (OP_LOG.md §9 Phase P1)
//
// The eight print-config doc.* setters journal real ops through `opApply`. Each
// op carries a RESOLVED `field`/`value` (and `index` for ink) — the value is a
// literal, NOT a YAML expr (replay has no eval context). The mutation routes
// through the SAME `applyPrintPrefField` / `applyMarksAndBleedField` / ...
// helpers (PDF.swift) the production print-dialog handlers (LayersPanel.swift)
// use, so the field-match + type-coerce + write are byte-identical on both
// paths (the checkpoint_equivalence gate, OP_LOG.md §6). A type mismatch (a
// string where a bool is wanted, etc.) SKIPS rather than mutating. Returns
// `true` iff the field matched AND the value coerced — the caller records the op
// only on `true`, so a type-mismatch skip journals nothing.

let PRINT_CONFIG_VERBS: Set<String> = [
    "set_color_management_field",
    "set_document_setup_field",
    "set_graphics_field",
    "set_marks_and_bleed_field",
    "set_output_field",
    "set_output_ink_field",
    "set_print_preferences_field",
    "set_advanced_field",
]

/// Apply one print-config field setter to `model`. `verb` selects which struct;
/// `field` names the field; `val` is the RESOLVED literal; `index` is the ink
/// index (only `set_output_ink_field` reads it). Returns `true` iff the field
/// matched and the value coerced. Mirrors Rust `apply_print_config_field`.
func applyPrintConfigField(
    _ model: Model, verb: String, field: String, val: Value, index: Int
) -> Bool {
    let doc = model.document
    switch verb {
    case "set_print_preferences_field":
        guard let np = applyPrintPrefField(doc.printPreferences, field: field, val: val)
        else { return false }
        model.setDocument(withPrintPreferences(doc, np))
        return true
    case "set_marks_and_bleed_field":
        guard let np = applyMarksAndBleedField(doc.printPreferences, field: field, val: val)
        else { return false }
        model.setDocument(withPrintPreferences(doc, np))
        return true
    case "set_output_field":
        guard let np = applyOutputField(doc.printPreferences, field: field, val: val)
        else { return false }
        model.setDocument(withPrintPreferences(doc, np))
        return true
    case "set_output_ink_field":
        guard let np = applyOutputInkField(doc.printPreferences, index: index, field: field, val: val)
        else { return false }
        model.setDocument(withPrintPreferences(doc, np))
        return true
    case "set_graphics_field":
        guard let np = applyGraphicsField(doc.printPreferences, field: field, val: val)
        else { return false }
        model.setDocument(withPrintPreferences(doc, np))
        return true
    case "set_color_management_field":
        guard let np = applyColorManagementField(doc.printPreferences, field: field, val: val)
        else { return false }
        model.setDocument(withPrintPreferences(doc, np))
        return true
    case "set_advanced_field":
        guard let np = applyAdvancedField(doc.printPreferences, field: field, val: val)
        else { return false }
        model.setDocument(withPrintPreferences(doc, np))
        return true
    case "set_document_setup_field":
        guard let ns = applyDocumentSetupField(doc.documentSetup, field: field, val: val)
        else { return false }
        model.setDocument(withDocumentSetup(doc, ns))
        return true
    default:
        return false
    }
}

/// Apply one document-setup field. Mirrors the `docSetDocumentSetupFieldHandler`
/// switch (LayersPanel.swift) exactly, but at the document layer over a `Value`.
/// Returns the new DocumentSetup, or nil on a type mismatch / unknown field.
private func applyDocumentSetupField(
    _ s: DocumentSetup, field: String, val: Value
) -> DocumentSetup? {
    func num() -> Double? { if case .number(let n) = val { return n }; return nil }
    func bool() -> Bool? { if case .bool(let b) = val { return b }; return nil }
    func str() -> String? { if case .string(let s) = val { return s }; return nil }
    switch field {
    case "bleed_top": guard let n = num() else { return nil }; return _withDocSetup(s, bleedTop: n)
    case "bleed_right": guard let n = num() else { return nil }; return _withDocSetup(s, bleedRight: n)
    case "bleed_bottom": guard let n = num() else { return nil }; return _withDocSetup(s, bleedBottom: n)
    case "bleed_left": guard let n = num() else { return nil }; return _withDocSetup(s, bleedLeft: n)
    case "bleed_uniform": guard let b = bool() else { return nil }; return _withDocSetup(s, bleedUniform: b)
    case "show_images_outline": guard let b = bool() else { return nil }; return _withDocSetup(s, showImagesOutline: b)
    case "highlight_substituted_glyphs": guard let b = bool() else { return nil }; return _withDocSetup(s, highlightSubstitutedGlyphs: b)
    case "simulate_colored_paper": guard let b = bool() else { return nil }; return _withDocSetup(s, simulateColoredPaper: b)
    case "discard_white_overprint": guard let b = bool() else { return nil }; return _withDocSetup(s, discardWhiteOverprint: b)
    case "grid_size": guard let n = num() else { return nil }; return _withDocSetup(s, gridSize: n)
    case "grid_color": guard let g = str() else { return nil }; return _withDocSetup(s, gridColor: g)
    case "paper_color": guard let g = str() else { return nil }; return _withDocSetup(s, paperColor: g)
    case "transparency_flattener_preset":
        guard let g = str(), let p = FlattenerPreset(rawValue: g) else { return nil }
        return _withDocSetup(s, transparencyFlattenerPreset: p)
    default: return nil
    }
}

/// Rebuild `doc` with a new printPreferences (Document is immutable-by-convention).
private func withPrintPreferences(_ doc: Document, _ pp: PrintPreferences) -> Document {
    Document(layers: doc.layers, symbols: doc.symbols, selectedLayer: doc.selectedLayer,
             selection: doc.selection, artboards: doc.artboards,
             artboardOptions: doc.artboardOptions, documentSetup: doc.documentSetup,
             printPreferences: pp)
}

/// Rebuild `doc` with a new documentSetup.
private func withDocumentSetup(_ doc: Document, _ ds: DocumentSetup) -> Document {
    Document(layers: doc.layers, symbols: doc.symbols, selectedLayer: doc.selectedLayer,
             selection: doc.selection, artboards: doc.artboards,
             artboardOptions: doc.artboardOptions, documentSetup: ds,
             printPreferences: doc.printPreferences)
}

/// Rebuild `doc` with new artboards.
private func withArtboards(_ doc: Document, _ abs: [Artboard]) -> Document {
    Document(layers: doc.layers, symbols: doc.symbols, selectedLayer: doc.selectedLayer,
             selection: doc.selection, artboards: abs,
             artboardOptions: doc.artboardOptions, documentSetup: doc.documentSetup,
             printPreferences: doc.printPreferences)
}

/// Rebuild `doc` with new artboardOptions.
private func withArtboardOptions(_ doc: Document, _ opts: ArtboardOptions) -> Document {
    Document(layers: doc.layers, symbols: doc.symbols, selectedLayer: doc.selectedLayer,
             selection: doc.selection, artboards: doc.artboards,
             artboardOptions: opts, documentSetup: doc.documentSetup,
             printPreferences: doc.printPreferences)
}

/// Rebuild `doc` with new top-level layers (Layer array).
private func withLayers(_ doc: Document, _ layers: [Layer]) -> Document {
    Document(layers: layers, symbols: doc.symbols, selectedLayer: doc.selectedLayer,
             selection: doc.selection, artboards: doc.artboards,
             artboardOptions: doc.artboardOptions, documentSetup: doc.documentSetup,
             printPreferences: doc.printPreferences)
}

// MARK: - Artboard doc.* setters (OP_LOG.md §9 Phase P2/P3)

/// Apply one field of one artboard (by id). `val` is a RESOLVED literal. Returns
/// `true` iff the artboard exists AND the field matched AND the value coerced.
/// Mirrors Rust `apply_set_artboard_field`.
func applySetArtboardField(_ model: Model, id: String, field: String, val: Value) -> Bool {
    var abs = model.document.artboards
    guard let i = abs.firstIndex(where: { $0.id == id }) else { return false }
    guard let updated = applyArtboardFieldValue(abs[i], field: field, val: val) else { return false }
    abs[i] = updated
    model.setDocument(withArtboards(model.document, abs))
    return true
}

/// Apply one RESOLVED field literal to an Artboard, returning the updated
/// artboard (nil on a type mismatch / unknown field). Mirrors the field set +
/// type coercion of Rust `apply_set_artboard_field` / `apply_artboard_field_in_place`.
private func applyArtboardFieldValue(_ ab: Artboard, field: String, val: Value) -> Artboard? {
    func num() -> Double? { if case .number(let n) = val { return n }; return nil }
    func bool() -> Bool? { if case .bool(let b) = val { return b }; return nil }
    func str() -> String? { if case .string(let s) = val { return s }; return nil }
    switch field {
    case "name": guard let s = str() else { return nil }; return ab.with(name: s)
    case "x": guard let n = num() else { return nil }; return ab.with(x: n)
    case "y": guard let n = num() else { return nil }; return ab.with(y: n)
    case "width": guard let n = num() else { return nil }; return ab.with(width: n)
    case "height": guard let n = num() else { return nil }; return ab.with(height: n)
    case "fill": guard let s = str() else { return nil }; return ab.with(fill: ArtboardFill.fromCanonical(s))
    case "show_center_mark": guard let b = bool() else { return nil }; return ab.with(showCenterMark: b)
    case "show_cross_hairs": guard let b = bool() else { return nil }; return ab.with(showCrossHairs: b)
    case "show_video_safe_areas": guard let b = bool() else { return nil }; return ab.with(showVideoSafeAreas: b)
    case "video_ruler_pixel_aspect_ratio": guard let n = num() else { return nil }; return ab.with(videoRulerPixelAspectRatio: n)
    default: return nil
    }
}

/// Apply one document-global artboard-options field (bool only). Returns `true`
/// iff the field matched and the value coerced to a bool. Mirrors Rust
/// `apply_set_artboard_options_field`.
func applySetArtboardOptionsField(_ model: Model, field: String, val: Value) -> Bool {
    guard case .bool(let flag) = val else { return false }
    let o = model.document.artboardOptions
    let newOpts: ArtboardOptions
    switch field {
    case "fade_region_outside_artboard":
        newOpts = ArtboardOptions(fadeRegionOutsideArtboard: flag,
                                  updateWhileDragging: o.updateWhileDragging)
    case "update_while_dragging":
        newOpts = ArtboardOptions(fadeRegionOutsideArtboard: o.fadeRegionOutsideArtboard,
                                  updateWhileDragging: flag)
    default:
        return false
    }
    model.setDocument(withArtboardOptions(model.document, newOpts))
    return true
}

/// Delete the artboard whose id == `id`. Returns `true` iff one was removed (a
/// missing id is a no-op that journals nothing). Mirrors Rust
/// `apply_delete_artboard_by_id`.
func applyDeleteArtboardById(_ model: Model, id: String) -> Bool {
    var abs = model.document.artboards
    let before = abs.count
    abs.removeAll { $0.id == id }
    guard abs.count < before else { return false }
    model.setDocument(withArtboards(model.document, abs))
    return true
}

/// Swap-with-neighbor-skipping-selected for Move Up, in place. Returns `true`
/// iff any swap occurred. Mirrors Rust `move_artboards_up_in_place`.
func moveArtboardsUpInPlace(_ abs: inout [Artboard], _ selectedIds: [String]) -> Bool {
    let selected = Set(selectedIds)
    var changed = false
    var i = 0
    while i < abs.count {
        defer { i += 1 }
        if !selected.contains(abs[i].id) { continue }
        if i == 0 { continue }
        if selected.contains(abs[i - 1].id) { continue }
        abs.swapAt(i - 1, i)
        changed = true
    }
    return changed
}

/// Symmetric Move Down. Returns `true` iff any swap occurred. Mirrors Rust
/// `move_artboards_down_in_place`.
func moveArtboardsDownInPlace(_ abs: inout [Artboard], _ selectedIds: [String]) -> Bool {
    let selected = Set(selectedIds)
    var changed = false
    let n = abs.count
    var i = n - 1
    while i >= 0 {
        defer { i -= 1 }
        if !selected.contains(abs[i].id) { continue }
        if i + 1 >= n { continue }
        if selected.contains(abs[i + 1].id) { continue }
        abs.swapAt(i, i + 1)
        changed = true
    }
    return changed
}

/// Apply Move Up. Returns `true` iff any swap occurred.
func applyMoveArtboardsUp(_ model: Model, _ ids: [String]) -> Bool {
    var abs = model.document.artboards
    guard moveArtboardsUpInPlace(&abs, ids) else { return false }
    model.setDocument(withArtboards(model.document, abs))
    return true
}

/// Apply Move Down. Returns `true` iff any swap occurred.
func applyMoveArtboardsDown(_ model: Model, _ ids: [String]) -> Bool {
    var abs = model.document.artboards
    guard moveArtboardsDownInPlace(&abs, ids) else { return false }
    model.setDocument(withArtboards(model.document, abs))
    return true
}

/// Append a new artboard with the GIVEN (already-minted) `id`, applying the
/// RESOLVED `fields` overrides on top of the canonical default. `id` is taken
/// VERBATIM — no minting. A type mismatch on a field SKIPS that field. Always an
/// effective change (an artboard is appended). Mirrors Rust `apply_create_artboard`.
func applyCreateArtboard(_ model: Model, id: String, fields: [String: Any]?) {
    var ab = Artboard.defaultWithId(id)
    if let map = fields {
        // Apply fields in a STABLE order (the field set is independent across
        // fields, so the result is order-insensitive; sorting only keeps the
        // application deterministic). Each field coerces via the same path as
        // set_artboard_field; a type mismatch keeps the default.
        for key in map.keys.sorted() {
            if let val = jsonToValue(map[key]), let updated = applyArtboardFieldValue(ab, field: key, val: val) {
                ab = updated
            }
        }
    }
    var abs = model.document.artboards
    abs.append(ab)
    model.setDocument(withArtboards(model.document, abs))
}

/// Clone the artboard whose id == `sourceId`, assign the GIVEN (already-minted)
/// `newId` and `name` VERBATIM, and offset its position by `(ox, oy)`. Returns
/// `true` iff the source existed (a missing source is a no-op). Mirrors Rust
/// `apply_duplicate_artboard`.
func applyDuplicateArtboard(
    _ model: Model, sourceId: String, newId: String, name: String, ox: Double, oy: Double
) -> Bool {
    var abs = model.document.artboards
    guard let src = abs.first(where: { $0.id == sourceId }) else { return false }
    let dup = Artboard(
        id: newId, name: name, x: src.x + ox, y: src.y + oy,
        width: src.width, height: src.height, fill: src.fill,
        showCenterMark: src.showCenterMark, showCrossHairs: src.showCrossHairs,
        showVideoSafeAreas: src.showVideoSafeAreas,
        videoRulerPixelAspectRatio: src.videoRulerPixelAspectRatio)
    abs.append(dup)
    model.setDocument(withArtboards(model.document, abs))
    return true
}

// MARK: - Structural tree-mutation verbs (OP_LOG.md §9 Phase P4)
//
// The two INSERTING verbs use the VALUE-IN-OP strategy at full strength
// (OP_LOG.md §7): the op carries the ENTIRE element to insert as LITERAL serde
// JSON in the params. On replay `parseSerdeElement` deserializes the element
// from that serde-externally-tagged JSON ({"Rect": {...}} / {"Layer": {...}})
// and inserts it BYTE-IDENTICALLY; the element keeps whatever id it had. A
// malformed/absent element or path SKIPS rather than crashing.

/// Deserialize the `element` op param (Rust serde externally-tagged JSON) into
/// an `Element`. Returns nil if the field is absent or is not a recognized
/// variant (a malformed payload skips the op rather than crashing). Mirrors
/// Rust `parse_element` (which uses `serde_json::from_value::<Element>`).
///
/// Swift has no derived Codable for the externally-tagged `Element`, so this
/// converts the serde shape to the canonical test_json flat shape `parseElement`
/// already consumes, then delegates. Only the variants the fixtures carry (Rect,
/// Layer) are mapped; an unknown tag returns nil.
///
/// VALUE-IN-OP — production fast path (OP_LOG.md §9): the cross-language fixtures
/// carry `element` as a serde-externally-tagged `[String: Any]` dict (the
/// portable, disk-shareable form Rust emits via `serde_json::to_value`); the
/// SWIFT production handlers (`doc.insert_after` / `doc.insert_at`) already hold
/// an in-memory `Element` (Swift lacks a serde ENCODER, only the decoder below),
/// so they pass that `Element` VERBATIM under the SAME `element` key. This fast
/// path returns it directly — additive and fixture-neutral (a fixture never
/// stores a Swift `Element` value), so the byte-gated dispatch arms are
/// unchanged. The in-process journal replays the same `[String: Any]` op dict
/// (which holds the `Element`), so checkpoint_equivalence holds in-process.
func parseSerdeElement(_ op: [String: Any]) -> Element? {
    if let e = op["element"] as? Element { return e }
    guard let el = op["element"] as? [String: Any] else { return nil }
    guard let dict = serdeElementToTestJson(el) else { return nil }
    return parseElement(dict)
}

/// Convert a Rust serde externally-tagged element JSON (`{"Rect": {...}}`,
/// `{"Layer": {...}}`, `{"Group": {...}}`) into the canonical test_json flat
/// dict that `parseElement` consumes. Returns nil for an unrecognized variant
/// tag (a malformed payload skips the op). Only the variants the shared
/// structural fixtures carry are mapped (Rect, Layer, Group + nested children).
private func serdeElementToTestJson(_ el: [String: Any]) -> [String: Any]? {
    guard let (tag, body) = el.first, let fields = body as? [String: Any] else { return nil }
    switch tag {
    case "Rect":
        var d = serdeCommonToTestJson(fields["common"] as? [String: Any])
        d["type"] = "rect"
        d["x"] = fields["x"]; d["y"] = fields["y"]
        d["width"] = fields["width"]; d["height"] = fields["height"]
        d["rx"] = fields["rx"]; d["ry"] = fields["ry"]
        if let fill = serdeFillToTestJson(fields["fill"]) { d["fill"] = fill }
        if let stroke = serdeStrokeToTestJson(fields["stroke"]) { d["stroke"] = stroke }
        return d
    case "Layer":
        var d = serdeCommonToTestJson(fields["common"] as? [String: Any])
        d["type"] = "layer"
        d["children"] = serdeChildrenToTestJson(fields["children"])
        return d
    case "Group":
        var d = serdeCommonToTestJson(fields["common"] as? [String: Any])
        d["type"] = "group"
        d["children"] = serdeChildrenToTestJson(fields["children"])
        return d
    default:
        return nil
    }
}

/// Convert a serde `common` block to the test_json flat common fields.
private func serdeCommonToTestJson(_ common: [String: Any]?) -> [String: Any] {
    var d: [String: Any] = [:]
    guard let c = common else { return d }
    d["opacity"] = c["opacity"]
    d["locked"] = c["locked"]
    // serde Visibility is PascalCase ("Preview"); test_json wants lowercase.
    if let v = c["visibility"] as? String { d["visibility"] = v.lowercased() }
    if let t = c["transform"] { d["transform"] = t }   // null or {a..f} (same shape)
    if let name = c["name"] { d["name"] = name }
    if let id = c["id"] { d["id"] = id }
    return d
}

/// Convert a serde Fill (`{"color": {"Rgb": {r,g,b,a}}, "opacity": ...}`) to the
/// test_json shape (`{"color": {r,g,b,a,space:"rgb"}, "opacity": ...}`).
private func serdeFillToTestJson(_ v: Any?) -> [String: Any]? {
    guard let f = v as? [String: Any] else { return nil }
    var out: [String: Any] = [:]
    if let color = serdeColorToTestJson(f["color"]) { out["color"] = color }
    out["opacity"] = f["opacity"]
    return out
}

/// Convert a serde Stroke to the test_json stroke shape.
private func serdeStrokeToTestJson(_ v: Any?) -> [String: Any]? {
    guard let s = v as? [String: Any] else { return nil }
    var out: [String: Any] = [:]
    if let color = serdeColorToTestJson(s["color"]) { out["color"] = color }
    out["width"] = s["width"]
    if let lc = s["linecap"] as? String { out["linecap"] = lc }
    if let lj = s["linejoin"] as? String { out["linejoin"] = lj }
    out["opacity"] = s["opacity"]
    return out
}

/// Convert a serde Color (`{"Rgb": {r,g,b,a}}` / `{"Hsb": {...}}` /
/// `{"Cmyk": {...}}`) to the test_json shape (flat with a `space` key).
private func serdeColorToTestJson(_ v: Any?) -> [String: Any]? {
    guard let c = v as? [String: Any], let (tag, body) = c.first,
          var fields = body as? [String: Any] else { return nil }
    switch tag {
    case "Rgb": fields["space"] = "rgb"
    case "Hsb": fields["space"] = "hsb"
    case "Cmyk": fields["space"] = "cmyk"
    default: return nil
    }
    return fields
}

/// Convert a serde children array (of externally-tagged elements) to a test_json
/// children array (flat dicts). A child that fails to convert is dropped.
private func serdeChildrenToTestJson(_ v: Any?) -> [[String: Any]] {
    guard let arr = v as? [[String: Any]] else { return [] }
    return arr.compactMap { serdeElementToTestJson($0) }
}

/// The element's common.id, or nil. For `targets` (Fork 4 merge metadata).
private func elementId(_ el: Element) -> String? { el.id }

/// Delete the element at `path`. Returns (changed, targets): `changed` is false
/// (no-op) when the path resolves to nothing. Mirrors Rust
/// `apply_delete_element_at`.
func applyDeleteElementAt(_ model: Model, _ path: ElementPath) -> (Bool, [String]) {
    guard let existing = model.document.tryGetElement(path) else { return (false, []) }
    let targets = elementId(existing).map { [$0] } ?? []
    model.setDocument(model.document.deleteElement(path))
    return (true, targets)
}

/// Delete every currently-selected element. Returns the pre-deletion selection
/// ids and `true` iff the selection was non-empty. Mirrors Rust
/// `apply_delete_selection`.
func applyDeleteSelection(_ model: Model) -> (Bool, [String]) {
    if model.document.selection.isEmpty { return (false, []) }
    let targets = selectionToIds(model.document)
    model.setDocument(model.document.deleteSelection())
    return (true, targets)
}

/// Insert `element` immediately after the element at `path` (value-in-op). Returns
/// the inserted element's id (if any) for targets. Mirrors Rust
/// `apply_insert_element_after`.
func applyInsertElementAfter(_ model: Model, _ path: ElementPath, _ element: Element) -> [String] {
    let targets = elementId(element).map { [$0] } ?? []
    model.setDocument(model.document.insertElementAfter(path, element: element))
    return targets
}

/// Insert `element` at `index` under `parentPath` (an empty parentPath inserts
/// into the top-level layers array). Mirrors Rust `apply_insert_element_at`.
func applyInsertElementAt(
    _ model: Model, _ parentPath: ElementPath, _ index: Int, _ element: Element
) -> [String] {
    let targets = elementId(element).map { [$0] } ?? []
    if parentPath.isEmpty {
        // Top-level layers insert. The element must be a Layer; if it is not,
        // this mirrors Rust's `layers.insert` over an Element vec — but Swift's
        // top level is [Layer], so a non-layer top-level insert is a no-op (the
        // fixtures always carry a Layer for an empty parent_path).
        guard case .layer(let l) = element else { return targets }
        var layers = model.document.layers
        let idx = min(index, layers.count)
        layers.insert(l, at: idx)
        model.setDocument(withLayers(model.document, layers))
    } else {
        model.setDocument(insertElementAtPath(model.document, parentPath, index, element))
    }
    return targets
}

/// Insert `element` at `parentPath + [index]`. Builds the target insertion path
/// (parent path plus the final index) and delegates to the document's
/// path-addressed insert. Mirrors Rust's
/// `new_doc.insert_element_at(&insert_path, element)` for the non-empty parent.
private func insertElementAtPath(
    _ doc: Document, _ parentPath: ElementPath, _ index: Int, _ element: Element
) -> Document {
    // Resolve the parent container's child count to clamp the index, then insert
    // by inserting-after the element currently at (index-1), or prepending when
    // index == 0. The Document exposes insertElementAfter (path-addressed); we
    // synthesize an insert-at by reusing it on the sibling, falling back to a
    // rebuild of the parent's children when index == 0.
    let children = childrenOfPath(doc, parentPath)
    let clamped = min(max(0, index), children.count)
    if clamped == 0 {
        // Prepend: insert before the current first child. With no children, the
        // parent is empty — insert as the parent's sole child.
        if children.isEmpty {
            return setChildrenOfPath(doc, parentPath, [element])
        }
        var newChildren = children
        newChildren.insert(element, at: 0)
        return setChildrenOfPath(doc, parentPath, newChildren)
    }
    var newChildren = children
    newChildren.insert(element, at: clamped)
    return setChildrenOfPath(doc, parentPath, newChildren)
}

/// The children of an element if it is a container (Group / Layer / live
/// compound), else []. Local mirror of Document's private `childrenOf`.
private func containerChildren(_ elem: Element) -> [Element] {
    switch elem {
    case .group(let g): return g.children
    case .layer(let l): return l.children
    case .live(.compoundShape(let c)): return c.operands
    default: return []
    }
}

/// The children of the container at `path` (a Layer or Group). An empty path
/// addresses the top-level layers (returned as `.layer` elements).
private func childrenOfPath(_ doc: Document, _ path: ElementPath) -> [Element] {
    if path.isEmpty { return doc.layers.map { .layer($0) } }
    return containerChildren(doc.getElement(path))
}

/// Rebuild a container element with `newChildren` (Group / Layer). Other element
/// types are returned unchanged.
private func withContainerChildren(_ elem: Element, _ newChildren: [Element]) -> Element {
    switch elem {
    case .group(let g): return .group(g.withChildren(newChildren))
    case .layer(let l): return .layer(l.withChildren(newChildren))
    default: return elem
    }
}

/// Rebuild the document with the container at `path` carrying `newChildren`.
private func setChildrenOfPath(_ doc: Document, _ path: ElementPath, _ newChildren: [Element]) -> Document {
    if path.isEmpty {
        let layers: [Layer] = newChildren.compactMap { if case .layer(let l) = $0 { return l }; return nil }
        return withLayers(doc, layers)
    }
    let container = doc.getElement(path)
    let rebuilt = withContainerChildren(container, newChildren)
    return doc.replaceElement(path, with: rebuilt)
}

// MARK: - Group/layer wrapping verbs (OP_LOG.md §9 Phase P5)
//
// Each is a MULTI-STEP mutation (collect elements at paths, reverse-delete them,
// build a container, insert it) that replays as ONE deterministic op. The op
// carries the RESOLVED plain index-array `paths` and (wrap_in_layer) the
// RESOLVED `name` LITERAL plus an optional value-in-op `id`.

/// Parse the `paths` op param (a JSON array of index arrays) into `[ElementPath]`.
/// Returns nil if absent or not an array-of-int-arrays (a malformed payload skips
/// the op). An empty top-level array yields `[]` (the caller treats as no-op).
/// Mirrors Rust `parse_path_list`.
private func parsePathList(_ v: Any?) -> [ElementPath]? {
    guard let arr = v as? [Any] else { return nil }
    var out: [ElementPath] = []
    for item in arr {
        guard let inner = item as? [Any] else { return nil }
        var path: ElementPath = []
        for n in inner {
            guard let num = n as? NSNumber, !num.isBool, num.intValue >= 0 else { return nil }
            path.append(num.intValue)
        }
        out.append(path)
    }
    return out
}

/// Collect (in sorted document order) clones of the elements at `paths`, plus
/// their ids. Returns (children, childIds, sortedPaths). A path that resolves to
/// nothing is silently dropped. Mirrors Rust `collect_children_for_wrap`.
private func collectChildrenForWrap(
    _ doc: Document, _ paths: [ElementPath]
) -> ([Element], [String], [ElementPath]) {
    let sorted = paths.sorted { $0.lexicographicallyPrecedes($1) }
    var children: [Element] = []
    var ids: [String] = []
    for p in sorted {
        if let elem = doc.tryGetElement(p) {
            if let id = elementId(elem) { ids.append(id) }
            children.append(elem)
        }
    }
    return (children, ids, sorted)
}

/// Wrap the elements at `paths` in a new Group, inserting it at the TOPMOST
/// source index. Optional value-in-op `id`. Returns (changed, targets). Mirrors
/// Rust `apply_wrap_in_group`.
func applyWrapInGroup(_ model: Model, _ paths: [ElementPath], _ id: String?) -> (Bool, [String]) {
    let doc = model.document
    let (children, childIds, sorted) = collectChildrenForWrap(doc, paths)
    if children.isEmpty { return (false, []) }
    let first = sorted[0]
    if first.isEmpty { return (false, []) }
    let insertParent = Array(first.dropLast())
    let insertIndex = first[first.count - 1]
    // Reverse-delete the sources (descending paths keep indices valid).
    var newDoc = doc
    for p in sorted.reversed() {
        newDoc = newDoc.deleteElement(p)
    }
    let group = Element.group(Group(
        children: children, opacity: 1.0, transform: nil,
        locked: false, visibility: .preview, name: nil, id: id))
    var targets = childIds
    if let gid = id { targets.append(gid) }
    if insertParent.isEmpty {
        var layers = newDoc.layers
        // Top-level insert: the group is wrapped in synthetic position via the
        // children machinery (top level holds Layers, but a Group at top level
        // is not representable). Mirrors Rust inserting an Element::Group into
        // layers; Swift's top level is [Layer], so the fixtures wrap nested
        // siblings (non-empty parent). Guard: if parent empty + group, no-op.
        // The shared fixtures only wrap nested siblings, so this branch is not
        // exercised; keep a faithful best-effort that drops a non-layer group.
        _ = layers
        return (false, [])
    } else {
        newDoc = insertElementAtPath(newDoc, insertParent, insertIndex, group)
    }
    model.setDocument(newDoc)
    return (true, targets)
}

/// Wrap the elements at `paths` in a new top-level Layer with the RESOLVED
/// `name` LITERAL; always APPENDS the new Layer. Optional value-in-op `id`.
/// Returns (changed, targets). Mirrors Rust `apply_wrap_in_layer`.
func applyWrapInLayer(_ model: Model, _ paths: [ElementPath], _ name: String, _ id: String?) -> (Bool, [String]) {
    let doc = model.document
    let (children, childIds, sorted) = collectChildrenForWrap(doc, paths)
    if children.isEmpty { return (false, []) }
    var newDoc = doc
    for p in sorted.reversed() {
        newDoc = newDoc.deleteElement(p)
    }
    let newLayer = Layer(
        name: name, children: children, opacity: 1.0, transform: nil,
        locked: false, visibility: .preview, id: id)
    var targets = childIds
    if let lid = id { targets.append(lid) }
    var layers = newDoc.layers
    layers.append(newLayer)
    model.setDocument(withLayers(newDoc, layers))
    return (true, targets)
}

/// Unpack the Group at `path`: extract its children, delete the group, and
/// re-insert the children at the vacated position with ascending indices
/// (children keep their ids). A non-Group target (or absent path) is a no-op.
/// Returns (changed, targets). Mirrors Rust `apply_unpack_group_at`.
func applyUnpackGroupAt(_ model: Model, _ path: ElementPath) -> (Bool, [String]) {
    let doc = model.document
    guard let elem = doc.tryGetElement(path), case .group(let g) = elem else { return (false, []) }
    let children = g.children
    let targets = children.compactMap { elementId($0) }
    var newDoc = doc.deleteElement(path)
    var insertPath = path
    for child in children {
        newDoc = insertElementAtPath(newDoc, Array(insertPath.dropLast()), insertPath[insertPath.count - 1], child)
        insertPath[insertPath.count - 1] += 1
    }
    model.setDocument(newDoc)
    return (true, targets)
}

// MARK: - set_attr_on_selection (OP_LOG.md §9 Phase P6)

/// Apply one `set_attr_on_selection` brush attribute. `attr` selects the
/// Controller mutator; `value` is the RESOLVED literal — `Some(s)` sets, nil
/// (an empty resolved string) clears. Returns (changed, targets): `changed` is
/// false for an unknown attr OR when the write left every selected element
/// unchanged. Mirrors Rust `apply_set_attr_on_selection`.
func applySetAttrOnSelection(
    _ model: Model, _ controller: Controller, _ attr: String, _ value: String?
) -> (Bool, [String]) {
    if attr != "stroke_brush" && attr != "stroke_brush_overrides" { return (false, []) }
    let targets = selectionToIds(model.document)
    // Snapshot pre-edit layers to detect an effective change — the canonical
    // no-op rule (commitTxn) is blind to strokeBrush (documentToTestJson omits
    // it), so detect it here via Element equality.
    let before = model.document.layers
    switch attr {
    case "stroke_brush": controller.setSelectionStrokeBrush(value)
    case "stroke_brush_overrides": controller.setSelectionStrokeBrushOverrides(value)
    default: return (false, [])
    }
    let changed = model.document.layers != before
    return (changed, targets)
}

// MARK: - Transform trio (OP_LOG.md §9 Phase P7)
//
// scale_transform / rotate_transform / shear_transform journal the CONFIRM apply
// through the SHARED helpers, so the production confirm path and these replay
// arms compose the IDENTICAL matrix (the byte-gate). Each op carries RESOLVED
// LITERALS only (factors/angle/axis, resolved reference point rx/ry, scale flags).

/// True when a scale is the identity (both factors ≈ 1.0).
private func isScaleIdentity(_ sx: Double, _ sy: Double) -> Bool {
    abs(sx - 1.0) < 1e-9 && abs(sy - 1.0) < 1e-9
}

/// Compose `matrix` against every element at `paths` in `doc` (pre-multiplying
/// the element's existing transform), returning the new document. Honors
/// `strokeFactor` (scale_strokes) and `corners` (scale_corners). Mirrors Rust
/// `op_apply::compose_matrix_over_paths`.
func composeMatrixOverPaths(
    _ doc: Document, _ paths: [ElementPath], _ matrix: Transform,
    strokeFactor: Double?, corners: (Double, Double)?
) -> Document {
    var newDoc = doc
    for path in paths {
        guard newDoc.tryGetElement(path) != nil else { continue }
        let elem = newDoc.getElement(path)
        var newElem = elem.withTransformPremultiplied(matrix)
        if let f = strokeFactor { newElem = scaleElemStrokeWidth(newElem, f) }
        if let (sxAbs, syAbs) = corners { newElem = scaleElemCorners(newElem, sxAbs, syAbs) }
        newDoc = newDoc.replaceElement(path, with: newElem)
    }
    return newDoc
}

/// Multiply an element's stroke-width by `factor` (no-op without a stroke).
private func scaleElemStrokeWidth(_ elem: Element, _ factor: Double) -> Element {
    guard let stroke = elem.stroke else { return elem }
    let newStroke = Stroke(
        color: stroke.color, width: stroke.width * factor,
        linecap: stroke.linecap, linejoin: stroke.linejoin,
        miterLimit: stroke.miterLimit, align: stroke.align,
        dashPattern: stroke.dashPattern,
        startArrow: stroke.startArrow, endArrow: stroke.endArrow,
        startArrowScale: stroke.startArrowScale, endArrowScale: stroke.endArrowScale,
        arrowAlign: stroke.arrowAlign, opacity: stroke.opacity)
    return withStroke(elem, stroke: newStroke)
}

/// Scale a rounded-rect's rx/ry (no-op on other element types).
private func scaleElemCorners(_ elem: Element, _ sxAbs: Double, _ syAbs: Double) -> Element {
    if case .rect(let r) = elem {
        return .rect(Rect(
            x: r.x, y: r.y, width: r.width, height: r.height,
            rx: r.rx * sxAbs, ry: r.ry * syAbs,
            fill: r.fill, stroke: r.stroke, opacity: r.opacity,
            transform: r.transform, locked: r.locked, visibility: r.visibility))
    }
    return elem
}

/// The resolved selection path list (in selection order).
private func selectionPaths(_ doc: Document) -> [ElementPath] {
    doc.selection.map { $0.path }
}

/// Apply a scale around `(rx, ry)` with RESOLVED factors + flags. Returns
/// (changed, targets); false (no-op) for an IDENTITY scale. Mirrors Rust `apply_scale`.
func applyScale(
    _ model: Model, sx: Double, sy: Double, rx: Double, ry: Double,
    scaleStrokes: Bool, scaleCorners: Bool
) -> (Bool, [String]) {
    if isScaleIdentity(sx, sy) { return (false, []) }
    let targets = selectionToIds(model.document)
    let matrix = TransformApply.scaleMatrix(sx: sx, sy: sy, rx: rx, ry: ry)
    let strokeFactor = scaleStrokes ? TransformApply.strokeWidthFactor(sx: sx, sy: sy) : nil
    let corners = scaleCorners ? (abs(sx), abs(sy)) : nil
    let paths = selectionPaths(model.document)
    model.setDocument(composeMatrixOverPaths(model.document, paths, matrix, strokeFactor: strokeFactor, corners: corners))
    return (true, targets)
}

/// Apply a rotation of `thetaDeg` around `(rx, ry)`. Rigid — no stroke/corner
/// options. Returns (changed, targets); false for a zero-angle no-op. Mirrors
/// Rust `apply_rotate`.
func applyRotate(_ model: Model, thetaDeg: Double, rx: Double, ry: Double) -> (Bool, [String]) {
    if abs(thetaDeg) < 1e-9 { return (false, []) }
    let targets = selectionToIds(model.document)
    let matrix = TransformApply.rotateMatrix(thetaDeg: thetaDeg, rx: rx, ry: ry)
    let paths = selectionPaths(model.document)
    model.setDocument(composeMatrixOverPaths(model.document, paths, matrix, strokeFactor: nil, corners: nil))
    return (true, targets)
}

/// Apply a shear of `angleDeg` along `axis` (with `axisAngleDeg` for custom)
/// around `(rx, ry)`. Returns (changed, targets); false for a zero-angle no-op.
/// Mirrors Rust `apply_shear`.
func applyShear(
    _ model: Model, angleDeg: Double, axis: String, axisAngleDeg: Double, rx: Double, ry: Double
) -> (Bool, [String]) {
    if abs(angleDeg) < 1e-9 { return (false, []) }
    let targets = selectionToIds(model.document)
    let matrix = TransformApply.shearMatrix(angleDeg: angleDeg, axis: axis, axisAngleDeg: axisAngleDeg, rx: rx, ry: ry)
    let paths = selectionPaths(model.document)
    model.setDocument(composeMatrixOverPaths(model.document, paths, matrix, strokeFactor: nil, corners: nil))
    return (true, targets)
}

// MARK: - The op-error channel (Arc 1 S3)
//
// `opApply` SIGNALS a rejected op without changing document behavior: the
// silent-skip DOCUMENT semantics are golden-pinned spec (every skip mutates
// nothing and journals nothing, exactly as before), but the dispatcher now
// reports WHY an op was skipped. The invariant: an op errs exactly when the
// dispatcher rejects it for a FAULT before `recordOp` — a malformed envelope,
// an unknown verb, a missing/mistyped required param, or an addressed target
// that does not exist. Benign no-ops (empty-selection delete, identity
// transforms, move-up-at-top, empty wrap paths) and by-design defaults stay
// nil (success) — they are fully processed ops whose effect is legitimately
// nothing. Journals only ever contain succeeded ops, so replaying a journal
// must never err (the fixture runner asserts this). Mirrors Rust `OpError`.
//
// The five classes are FROZEN (the cross-language taxonomy; fixtures assert
// the bare class name via per-op `expected_error` fields). Detail payloads
// (param name / verb / target id) are description-only diagnostics.
public enum OpApplyError: Equatable, CustomStringConvertible {
    /// The op envelope has no string `"op"` verb.
    case malformedEnvelope
    /// The verb is not in the dispatch vocabulary.
    case unknownVerb(name: String)
    /// A required param is absent from the op object.
    case missingParam(name: String)
    /// A required param is present but has the wrong type / an unaccepted value.
    case badParamType(name: String)
    /// The op addresses a target (id or path) that does not exist.
    case missingTarget(id: String)

    /// The bare class name — the cross-language `expected_error` contract
    /// (fixtures assert exactly this string). Mirrors Rust `class_name()`.
    public var className: String {
        switch self {
        case .malformedEnvelope: return "MalformedEnvelope"
        case .unknownVerb: return "UnknownVerb"
        case .missingParam: return "MissingParam"
        case .badParamType: return "BadParamType"
        case .missingTarget: return "MissingTarget"
        }
    }

    public var description: String {
        switch self {
        case .malformedEnvelope: return "MalformedEnvelope"
        case .unknownVerb(let name): return "UnknownVerb(\(name))"
        case .missingParam(let name): return "MissingParam(\(name))"
        case .badParamType(let name): return "BadParamType(\(name))"
        case .missingTarget(let id): return "MissingTarget(\(id))"
        }
    }
}

/// Classify a failed required-param read: absent key ⇒ `missingParam`,
/// present-but-unparsable (wrong type / unaccepted value) ⇒ `badParamType`.
/// The parse helpers (`parsePath` / `strField` / `parseSerdeElement` / …)
/// merge both cases into nil; this splits them. Mirrors Rust `req_err`.
private func reqErr(_ op: [String: Any], _ name: String) -> OpApplyError {
    op[name] == nil ? .missingParam(name: name) : .badParamType(name: name)
}

/// The single op dispatcher (OP_LOG.md §4). Applies one primitive op to the
/// model (via `controller`) and records it into the open transaction (the
/// `checkpoint_equivalence` gate, §5-6). History-navigation ops
/// (`snapshot`/`undo`/`redo`) manage the transaction boundary / journal cursor
/// and are NOT primitive ops, so they return WITHOUT being journaled. `recordOp`
/// is a no-op when no transaction is open, so this is safe to call
/// unconditionally. Mirrors Rust `op_apply`.
///
/// Returns the `OpApplyError` exactly when the op was rejected for a fault
/// before `recordOp` (Arc 1 S3 — a SIGNAL, not a behavior change: every error
/// path mutates nothing and journals nothing, byte-identical to the prior
/// silent skip); nil on success, including the benign no-ops. Deliberately an
/// Optional return, NOT `throws`: all production call sites are statement-
/// position and stay compile-safe under `@discardableResult`; the fixture
/// runners assert the result against per-op `expected_error` fields, and
/// journal replay asserts nil.
@discardableResult
public func opApply(
    _ model: Model, _ controller: Controller, _ op: [String: Any]
) -> OpApplyError? {
    guard let name = op["op"] as? String else {
        // A primitive op with no verb is malformed; skip it (never crash).
        return .malformedEnvelope
    }
    // History-navigation ops (OP_LOG.md §5): they manage transaction boundaries
    // / the journal cursor and are NOT primitive ops, so they are never
    // journaled. `snapshot` commits the prior action's transaction and opens a
    // new one; undo/redo end the open context and move the cursor.
    switch name {
    case "snapshot":
        model.commitTxn()
        model.beginTxn()
        return nil
    case "undo":
        model.undo()
        return nil
    case "redo":
        model.redo()
        return nil
    default:
        break
    }
    // OP_LOG.md §9 (Increment 3b-B) — close the subsequent-drag-frame journaling
    // hole. Every verb below except `select_rect` is an UNDOABLE mutation. On a
    // bare drag frame (selection.yaml emits `doc.snapshot` only on the FIRST
    // mousemove), no transaction is open, so `recordOp` would drop the op and
    // the batch owner's `nameTxn`/`commitTxn` would have nothing to commit.
    // Opening the transaction HERE — and leaving it OPEN — makes the mutation
    // land in `recordOp` and the batch owner (`runEffects`) names + commits the
    // single transaction. `beginTxn` is a no-op while one is already open, so
    // the harness (which always brackets around `opApply`) and the snapshot-led
    // first frame are byte-unchanged. `select_rect` is EXCLUDED: it only changes
    // selection (non-undoable, serialized state), so a bare marquee must stay
    // journal-neutral — opening a txn for it would spuriously journal a
    // selection-only batch as an undoable step. `select_by_ids` is the
    // id-primary twin (selection-only, non-undoable), so it is excluded for the
    // identical reason.
    if name != "select_rect" && name != "select_by_ids" && !model.isInTxn {
        model.beginTxn()
    }
    // Fork-4 `targets` (OP_LOG.md §9). Populated for the THREE replay-safe verbs
    // `captureRecipe` consumes; every other verb keeps it empty.
    // `move_selection`/`copy_selection` resolve the source ids BEFORE the
    // mutation (a copy is born id-less; a move can change which ids are
    // selected — pre-mutation avoids the post-mutation-id hazard). `select_rect`
    // resolves AFTER its Controller call (the selection it just established IS
    // the keystone targets).
    var targets: [String] = []
    if name == "move_selection" || name == "copy_selection" {
        targets = selectionToIds(model.document)
    }
    switch name {
    // id-primary op family (OP_LOG.md §5 Fork 4 / RECORDED_ELEMENTS.md).
    // Operand ids come from the OP'S OWN PARAMS (never doc.selection), so
    // snapshot and replay apply identical operands (the §7 determinism rule).
    // Each `*_by_ids` re-establishes the working selection from its own ids
    // (via the SHARED `applySelectByIds` body) BEFORE routing through the SAME
    // `Controller` mutator the selection-relative verb uses, so the replayed
    // document+selection is byte-identical to `[select_rect, move_selection]`
    // (the byte-gate reconciliation, OP_LOG.md §6).
    case "select_by_ids":
        // Selection-only / non-undoable (like select_rect): write the resolved
        // selection BY PATH in document order; targets = the resolved ids (the
        // keystone the recipe seeds its working set from).
        let ids = strListField(op, "ids")
        targets = applySelectByIds(model, controller, ids)
    case "move_by_ids":
        // Set the working selection from the OP's ids, then run the SAME
        // mutator `move_selection` uses. targets = the operand ids (from
        // params, resolved to the selection) — never inferred post-mutation.
        let ids = strListField(op, "ids")
        targets = applySelectByIds(model, controller, ids)
        controller.moveSelection(dx: numField(op, "dx"), dy: numField(op, "dy"))
    case "copy_by_ids":
        // Set the working selection from the OP's `from` ids, then run the SAME
        // mutator `copy_selection` uses. targets = the source ids (the produced
        // copies are born id-less, so the source is the operand).
        let from = strListField(op, "from")
        targets = applySelectByIds(model, controller, from)
        controller.copySelection(dx: numField(op, "dx"), dy: numField(op, "dy"))
    case "select_rect":
        controller.selectRect(
            x: numField(op, "x"),
            y: numField(op, "y"),
            width: numField(op, "width"),
            height: numField(op, "height"),
            extend: (op["extend"] as? NSNumber)?.isBool == true
                ? (op["extend"] as! NSNumber).boolValue
                : (op["extend"] as? Bool ?? false))
        // Keystone: the resolved selection is this op's targets, so
        // captureRecipe can seed its working set (empty targets ⇒ empty
        // recipe). Resolved AFTER the Controller call.
        targets = selectionToIds(model.document)
    case "move_selection":
        controller.moveSelection(dx: numField(op, "dx"), dy: numField(op, "dy"))
    case "copy_selection":
        controller.copySelection(dx: numField(op, "dx"), dy: numField(op, "dy"))
    case "assign_id":
        guard let path = parsePath(op["path"]) else { return reqErr(op, "path") }
        guard let id = strField(op, "id") else { return reqErr(op, "id") }
        controller.assignId(path, id: id)
    case "create_reference":
        guard let targetPath = parsePath(op["target_path"]) else {
            return reqErr(op, "target_path")
        }
        guard let targetId = strField(op, "target_id") else { return reqErr(op, "target_id") }
        guard let refId = strField(op, "ref_id") else { return reqErr(op, "ref_id") }
        controller.createReference(targetPath, targetId: targetId, refId: refId)
    // Symbols P2 operations (SYMBOLS.md §7). Value-in-op: the ids and paths are
    // read literally from the payload, exactly like the create_reference arm.
    case "make_symbol":
        guard let path = parsePath(op["path"]) else { return reqErr(op, "path") }
        guard let masterId = strField(op, "master_id") else { return reqErr(op, "master_id") }
        guard let refId = strField(op, "ref_id") else { return reqErr(op, "ref_id") }
        controller.makeSymbol(path, masterId: masterId, refId: refId)
    case "place_instance":
        guard let masterId = strField(op, "master_id") else { return reqErr(op, "master_id") }
        guard let refId = strField(op, "ref_id") else { return reqErr(op, "ref_id") }
        controller.placeInstance(masterId: masterId, refId: refId)
    // ── Concept-pack ops (CONCEPTS.md §6-7) ──
    // The two verbs the Concepts panel emits, given journal-replay arms so a
    // placed/edited concept instance survives capture+replay byte-identically
    // (the §7 determinism rule). Both carry every operand VALUE-IN-OP: the
    // concept id, the RESOLVED default params, and the minted elem id (place);
    // the path, param name, and committed value (set). Nothing is re-derived on
    // replay (the registry could have changed), so replay reconstructs the
    // exact Generated instance the live edit produced. A malformed payload SKIPS
    // (never crashes, never journals).
    case "place_concept_instance":
        guard let conceptId = strField(op, "concept_id") else { return reqErr(op, "concept_id") }
        guard let elemId = strField(op, "elem_id") else { return reqErr(op, "elem_id") }
        let params = (op["params"] as? [String: Any]) ?? [:]
        controller.placeConceptInstance(
            conceptId: conceptId, params: params, elemId: elemId)
    case "set_concept_param":
        guard let path = parsePath(op["path"]) else { return reqErr(op, "path") }
        guard let pname = strField(op, "name") else { return reqErr(op, "name") }
        controller.setConceptParam(path, name: pname, value: numField(op, "value"))
    // Apply a concept operation (CONCEPTS.md §9). `op_id` rides as journal
    // metadata (the semantic verb); `changes` is the production-RESOLVED param
    // map (value-in-op) that is actually applied — replay merges it and never
    // re-evaluates the operation's expressions nor consults the registry. A
    // malformed / missing payload SKIPS (the controller no-ops on an empty /
    // non-object `changes`, so nothing journals).
    case "apply_concept_operation":
        guard let path = parsePath(op["path"]) else { return reqErr(op, "path") }
        guard let changes = op["changes"] as? [String: Any] else {
            return reqErr(op, "changes")
        }
        controller.applyConceptOperation(path, changes: changes)
    // Promote a raw shape to a Generated concept instance (CONCEPTS.md §10 — the
    // fitter / `promote`). Every operand is value-in-op: the detection ran at
    // production time, so replay just rebuilds the element. The `transform` is the
    // 6-element matrix `[a,b,c,d,e,f]` (default identity); `params` defaults to
    // empty. A malformed / missing path or concept_id SKIPS (never crashes, never
    // journals). Mirrors the Rust `promote_to_concept` arm.
    case "promote_to_concept":
        guard let path = parsePath(op["path"]) else { return reqErr(op, "path") }
        guard let conceptId = strField(op, "concept_id") else { return reqErr(op, "concept_id") }
        let params = (op["params"] as? [String: Any]) ?? [:]
        let transform = parseTransform(op["transform"])
        controller.promoteToConcept(
            path, conceptId: conceptId, params: params, transform: transform)
    case "detach":
        guard let path = parsePath(op["path"]) else { return reqErr(op, "path") }
        controller.detach(path)
    case "redefine":
        guard let masterId = strField(op, "master_id") else { return reqErr(op, "master_id") }
        guard let path = parsePath(op["path"]) else { return reqErr(op, "path") }
        guard let refId = strField(op, "ref_id") else { return reqErr(op, "ref_id") }
        controller.redefine(masterId: masterId, path, refId: refId)
    case "delete_symbol":
        guard let masterId = strField(op, "master_id") else { return reqErr(op, "master_id") }
        controller.deleteSymbol(masterId: masterId)
    // Symbols P4 (SYMBOLS.md §4 / Fork F2). Value-in-op: the instance transform
    // is carried in the payload as {a,b,c,d,e,f} and applied verbatim.
    case "set_instance_transform":
        guard let path = parsePath(op["path"]) else { return reqErr(op, "path") }
        guard let t = op["transform"] as? [String: Any] else {
            return reqErr(op, "transform")
        }
        let transform = Transform(
            a: numField(t, "a"), b: numField(t, "b"), c: numField(t, "c"),
            d: numField(t, "d"), e: numField(t, "e"), f: numField(t, "f"))
        controller.setInstanceTransform(path, transform: transform)
    // Structural tree-mutation verbs (OP_LOG.md §9 Phase P4). delete_at /
    // delete_selection / insert_after / insert_at mutate the element TREE through
    // the SHARED helpers, so the production handlers and these arms share ONE
    // mutation body. The inserting verbs carry the WHOLE element as LITERAL serde
    // JSON (value-in-op) — `parseSerdeElement` deserializes it defensively (a
    // non-Element value SKIPS). A no-op edit (absent delete path / empty
    // selection) journals nothing.
    case "delete_at":
        guard let path = parsePath(op["path"]) else { return reqErr(op, "path") }
        // An empty path addresses no element (mirrors Rust, where getElement
        // on [] resolves nothing) — the addressed target is missing.
        guard !path.isEmpty else { return .missingTarget(id: "[]") }
        let (changed, t) = applyDeleteElementAt(model, path)
        if !changed {
            // The path resolves to no element — the addressed target is
            // missing (distinct from the benign empty-selection delete).
            return .missingTarget(id: String(describing: path))
        }
        targets = t
    case "delete_selection":
        let (changed, t) = applyDeleteSelection(model)
        if !changed {
            // Benign no-op: an empty-selection delete succeeds by the S3
            // taxonomy (the operand set is legitimately empty).
            return nil
        }
        targets = t
    case "insert_after":
        guard let path = parsePath(op["path"]) else { return reqErr(op, "path") }
        // Swift skips an empty-path insert_after (the top level is [Layer]);
        // classified as a missing target. (Rust journals it as a document-layer
        // no-op — an out-of-corpus divergence predating the error channel.)
        guard !path.isEmpty else { return .missingTarget(id: "[]") }
        guard let element = parseSerdeElement(op) else { return reqErr(op, "element") }
        targets = applyInsertElementAfter(model, path, element)
    case "insert_at":
        guard let parentPath = parsePath(op["parent_path"]) else {
            return reqErr(op, "parent_path")
        }
        guard let element = parseSerdeElement(op) else { return reqErr(op, "element") }
        let index = uintField(op, "index")
        targets = applyInsertElementAt(model, parentPath, index, element)
    // Group/layer wrapping verbs (OP_LOG.md §9 Phase P5). Each is a MULTI-STEP
    // mutation (collect, reverse-delete, build container, insert) that replays as
    // ONE deterministic op. `paths` is parsed defensively (malformed list SKIPS;
    // empty list is a no-op). `wrap_in_layer` carries the RESOLVED name LITERAL.
    // An optional value-in-op `id` assigns the container id.
    case "wrap_in_group":
        guard let paths = parsePathList(op["paths"]) else { return reqErr(op, "paths") }
        if paths.isEmpty {
            // Benign no-op: an empty paths list succeeds by the S3 taxonomy
            // (like an empty-selection delete).
            return nil
        }
        let (changed, t) = applyWrapInGroup(model, paths, strField(op, "id"))
        if !changed {
            // Non-empty paths but no source element resolved — the addressed
            // targets are missing.
            return .missingTarget(id: String(describing: paths))
        }
        targets = t
    case "wrap_in_layer":
        guard let paths = parsePathList(op["paths"]) else { return reqErr(op, "paths") }
        if paths.isEmpty {
            // Benign no-op (see wrap_in_group).
            return nil
        }
        let nm = strField(op, "name") ?? ""
        let (changed, t) = applyWrapInLayer(model, paths, nm, strField(op, "id"))
        if !changed {
            return .missingTarget(id: String(describing: paths))
        }
        targets = t
    case "unpack_group_at":
        guard let path = parsePath(op["path"]) else { return reqErr(op, "path") }
        let (changed, t) = applyUnpackGroupAt(model, path)
        if !changed {
            // No Group at the path (absent element or a non-Group) — the
            // addressed target is missing.
            return .missingTarget(id: String(describing: path))
        }
        targets = t
    case "lock_selection":
        controller.lockSelection()
    case "unlock_all":
        controller.unlockAll()
    case "hide_selection":
        controller.hideSelection()
    case "show_all":
        controller.showAll()
    // set_attr_on_selection (OP_LOG.md §9 Phase P6). A Model-runner verb, routed
    // through the SHARED helper so production and replay run the SAME Controller
    // mutator. An absent `value` key SKIPS; an empty `value` string maps to a
    // CLEAR (nil). An unknown attr or an ineffective edit records nothing.
    case "set_attr_on_selection":
        guard let attr = strField(op, "attr") else { return reqErr(op, "attr") }
        // An unsupported attribute is a param whose value is outside the
        // accepted domain — badParamType (classified here so the helper's
        // merged `changed == false` can stay the benign ineffective-edit
        // success below). Behavior-identical: the helper skips the same way.
        if attr != "stroke_brush" && attr != "stroke_brush_overrides" {
            return .badParamType(name: "attr")
        }
        // A missing `value` key is a hard skip (no silent clear). When present,
        // an empty string clears (nil); a non-empty string sets.
        guard op.keys.contains("value") else { return .missingParam(name: "value") }
        let value = (op["value"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let (changed, t) = applySetAttrOnSelection(model, controller, attr, value)
        if !changed {
            // Benign no-op: the write left every selected element unchanged
            // (or the selection is empty) — success by the taxonomy.
            return nil
        }
        targets = t
    // Transform trio (OP_LOG.md §9 Phase P7). scale_transform / rotate_transform
    // / shear_transform journal the CONFIRM apply through the SHARED helpers, so
    // the production confirm path and these replay arms compose the IDENTICAL
    // matrix. Each op carries RESOLVED LITERALS only. An IDENTITY transform is a
    // no-op that journals nothing. For copy=true the production confirm path
    // journals `copy_selection` as a SEPARATE op before the transform op.
    case "scale_transform":
        let (changed, t) = applyScale(
            model, sx: numField(op, "sx"), sy: numField(op, "sy"),
            rx: numField(op, "rx"), ry: numField(op, "ry"),
            scaleStrokes: boolField(op, "scale_strokes", true),
            scaleCorners: boolField(op, "scale_corners", false))
        if !changed {
            // Benign no-op: an identity transform succeeds by the S3 taxonomy.
            return nil
        }
        targets = t
    case "rotate_transform":
        let (changed, t) = applyRotate(
            model, thetaDeg: numField(op, "angle"),
            rx: numField(op, "rx"), ry: numField(op, "ry"))
        if !changed {
            // Benign no-op: a zero-angle rotation succeeds by the S3 taxonomy.
            return nil
        }
        targets = t
    case "shear_transform":
        let (changed, t) = applyShear(
            model, angleDeg: numField(op, "angle"),
            axis: strField(op, "axis") ?? "horizontal",
            axisAngleDeg: numField(op, "axis_angle"),
            rx: numField(op, "rx"), ry: numField(op, "ry"))
        if !changed {
            // Benign no-op: a zero-angle shear succeeds by the S3 taxonomy.
            return nil
        }
        targets = t
    // Boolean ops (OP_LOG.md §9): the destructive boolean combines the ≥2
    // selected sibling paths; `simplify` refits the (now-selected) output. Both
    // join the open transaction so the pair is one journaled Transaction.
    case "boolean_union":
        controller.applyDestructiveBoolean("union")
    case "simplify":
        controller.simplifySelection(precision: (op["precision"] as? NSNumber)?.doubleValue ?? 0.5)
    // Print-config field setters (OP_LOG.md §9 Phase P1). The eight print-config
    // doc.* verbs journal real ops: each op carries a RESOLVED `field`/`value`
    // (and `index` for ink). Routes through the SAME apply helpers as the print
    // dialog handlers. A type-mismatch skip mutates nothing AND records nothing.
    // targets stays EMPTY (document-global config).
    case let v where PRINT_CONFIG_VERBS.contains(v):
        guard let field = strField(op, "field") else { return reqErr(op, "field") }
        guard op.keys.contains("value") else { return .missingParam(name: "value") }
        guard let val = jsonToValue(op["value"]) else { return .badParamType(name: "value") }
        let index = uintField(op, "index")
        if !applyPrintConfigField(model, verb: v, field: field, val: val, index: index) {
            // Type-mismatch / unknown-field / out-of-range-ink-index skip: the
            // helper merges the three; the class is badParamType (the
            // field/value pair did not apply), matching Rust.
            return .badParamType(name: "value")
        }
    // Artboard doc.* setters (OP_LOG.md §9 Phase P2). Each carries RESOLVED
    // literals; the helper skips on a malformed payload / type mismatch / missing
    // id / no-op edit, in which case we journal nothing. targets carries the
    // written artboard id(s).
    case "set_artboard_field":
        guard let id = strField(op, "id") else { return reqErr(op, "id") }
        guard let field = strField(op, "field") else { return reqErr(op, "field") }
        guard op.keys.contains("value") else { return .missingParam(name: "value") }
        guard let val = jsonToValue(op["value"]) else { return .badParamType(name: "value") }
        // Split the helper's merged `false` for the error channel: a missing
        // artboard is missingTarget; an existing artboard with a field/value
        // that did not apply is badParamType. The existence pre-check reads
        // the same artboard list the helper does, so the behavior (skip,
        // journal nothing) is unchanged. Mirrors Rust.
        guard model.document.artboards.contains(where: { $0.id == id }) else {
            return .missingTarget(id: id)
        }
        if !applySetArtboardField(model, id: id, field: field, val: val) {
            return .badParamType(name: "value")
        }
        targets = [id]
    case "set_artboard_options_field":
        guard let field = strField(op, "field") else { return reqErr(op, "field") }
        guard op.keys.contains("value") else { return .missingParam(name: "value") }
        guard let val = jsonToValue(op["value"]) else { return .badParamType(name: "value") }
        if !applySetArtboardOptionsField(model, field: field, val: val) {
            // Non-bool value / unknown field (the helper merges both).
            return .badParamType(name: "value")
        }
    case "delete_artboard_by_id":
        guard let id = strField(op, "id") else { return reqErr(op, "id") }
        if !applyDeleteArtboardById(model, id: id) {
            // No artboard with this id — the addressed target is missing.
            return .missingTarget(id: id)
        }
        targets = [id]
    case "move_artboards_up":
        let ids = strListField(op, "ids")
        if !applyMoveArtboardsUp(model, ids) {
            // Benign no-op: move-up-at-top (or ids that select nothing)
            // succeeds by the S3 taxonomy.
            return nil
        }
        targets = ids
    case "move_artboards_down":
        let ids = strListField(op, "ids")
        if !applyMoveArtboardsDown(model, ids) {
            // Benign no-op (see move_artboards_up).
            return nil
        }
        targets = ids
    // Artboard id-minting verbs (OP_LOG.md §9 Phase P3). VALUE-IN-OP: the id was
    // minted ONCE at production capture time and recorded as a LITERAL; this arm
    // reads it VERBATIM and NEVER mints. targets carry the new id.
    case "create_artboard":
        // A missing id is missingParam; a present non-string / empty id is
        // badParamType (reqErr splits them). This arm must NEVER mint.
        guard let id = strField(op, "id"), !id.isEmpty else { return reqErr(op, "id") }
        let fields = op["fields"] as? [String: Any]
        applyCreateArtboard(model, id: id, fields: fields)
        targets = [id]
    case "duplicate_artboard":
        guard let sourceId = strField(op, "id"), !sourceId.isEmpty else {
            return reqErr(op, "id")
        }
        guard let newId = strField(op, "new_id"), !newId.isEmpty else {
            return reqErr(op, "new_id")
        }
        let name = strField(op, "name") ?? ""
        if !applyDuplicateArtboard(model, sourceId: sourceId, newId: newId, name: name,
                                   ox: numField(op, "offset_x"), oy: numField(op, "offset_y")) {
            // No artboard with the source id — the addressed target is missing.
            return .missingTarget(id: sourceId)
        }
        targets = [newId]
    // Unknown verb: a malformed/unsupported production payload is skipped rather
    // than crashing. (The harness corpus only carries known verbs, so this never
    // fires under test — the byte-gate would catch a typo.)
    default:
        return .unknownVerb(name: name)
    }
    // Capture the op into the open transaction so the journal replays to the same
    // document — the checkpoint_equivalence gate (OP_LOG.md §5-6). `targets`
    // (Fork 4) is populated above for the three replay-safe verbs; empty for
    // every other verb. recordOp is a no-op when no transaction is open. `params`
    // carries the full op dict verbatim (verb included), matching the harness
    // recordOp site; the journal serializer strips the redundant "op" key.
    model.recordOp(PrimitiveOp(op: name, params: op, targets: targets))
    return nil
}
