import Foundation

/// Document controller (MVC pattern).
///
/// The Controller provides mutation operations on the Model's document.
/// Since Document is immutable (a struct), mutations produce a new
/// Document that replaces the old one in the Model.

// MARK: - Boolean-result common properties (EDIT_SEMANTICS_FREEZE.md §3.3/§3.6)

/// The non-paint fields a boolean result wears — the Swift stand-in for Rust's
/// `CommonProps`, which this port has no shared carrier for (§3.5's cross-port
/// field-vocabulary note). Defaults are exactly `CommonProps::default()` /
/// `Polygon.init`'s, so "falls to the documented default" is one shape here and
/// there.
///
/// `toolOrigin` is carried but only REPRESENTABLE on a Path result: in Rust it
/// lives on `CommonProps` for all eleven kinds, in Swift it is a stored
/// property of `Path` alone. The single-ring (Polygon) arm therefore cannot
/// hold a unanimous marker. That is the scheduled vocabulary divergence §3.5
/// names, not something `applyDestructiveBoolean` can fix from the inside.
struct BooleanCommon {
    var name: String? = nil
    var id: String? = nil
    var opacity: Double = 1.0
    var transform: Transform? = nil
    var locked: Bool = false
    var visibility: Visibility = .preview
    var blendMode: BlendMode = .normal
    var mask: Mask? = nil
    var toolOrigin: String? = nil

    /// The 1→1 survivor arms (SUBTRACT_FRONT / SUBTRACT_BACK / CROP / TRIM, and
    /// DIVIDE's designated operand): full Theseus preservation, §3.1. Rust's
    /// twin is `survivor.common().clone()`.
    init(preserving e: Element) {
        name = e.name
        id = e.id
        opacity = e.opacity
        transform = e.transform
        locked = e.isLocked
        visibility = e.visibility
        blendMode = e.blendMode
        mask = e.mask
        toolOrigin = booleanToolOrigin(e)
    }

    init() {}
}

/// `toolOrigin` reader over an `Element`. Path is the only Swift kind that
/// carries one; see `BooleanCommon`'s note.
private func booleanToolOrigin(_ e: Element) -> String? {
    if case .path(let v) = e { return v.toolOrigin }
    return nil
}

/// The `BooleanCommon` an N→1 merge product wears, minus its id (the caller
/// mints that). The exact twin of Rust's `merged_common`
/// (`jas_dioxus/src/document/controller.rs`).
///
/// PAINT rides from `front`: BOOLEAN.md §Operand and paint rules names four
/// properties — fill, stroke, `opacity`, blend mode — as what a boolean op
/// SPEAKS TO, and two of them (`opacity`, `blendMode`) live here.
///
/// EVERYTHING ELSE follows UNANIMITY: when every source agrees, carrying the
/// value IS preservation — well-defined, no winner elected — and when they
/// disagree the fresh element's documented default stands. Nothing geometric
/// ever breaks the tie; "the frontmost/largest source keeps it" was rejected in
/// both directions.
///
/// `name` follows ASSERTING-SOURCES unanimity (JYH's ratified answer (1)):
/// unanimity ranges over the sources that ASSERT a name, because absence is not
/// a competing claim. "hull" + unnamed → "hull"; "hull" + "keel" → the default.
///
/// `transform` is carried unanimously and no further. The flattening walk
/// (`elementToPolygonSet`) contains ZERO transform references, so the result
/// rings are RAW: a unanimous transform is the only one under which they are
/// meaningful. What changes is that no operand is elected to donate one.
func booleanMergedCommon(_ sources: [Element], front: Element) -> BooleanCommon {
    func unanimous<T: Equatable>(_ get: (Element) -> T) -> T? {
        guard let first = sources.first.map(get) else { return nil }
        return sources.allSatisfy { get($0) == first } ? first : nil
    }
    var c = BooleanCommon()
    // Paint, per the ratified four-property rule.
    c.opacity = front.opacity
    c.blendMode = front.blendMode
    if let v = unanimous({ $0.transform }) { c.transform = v }
    if let v = unanimous({ $0.isLocked }) { c.locked = v }
    if let v = unanimous({ $0.visibility }) { c.visibility = v }
    if let v = unanimous({ $0.mask }) { c.mask = v }
    if let v = unanimous({ booleanToolOrigin($0) }) { c.toolOrigin = v }
    // ASSERTING-SOURCES: silent sources are not voters.
    let named = sources.filter { $0.name != nil }
    if let first = named.first?.name,
       named.allSatisfy({ $0.name == first }) {
        c.name = first
    }
    return c
}

public class Controller {
    public let model: Model

    public init(model: Model = Model()) {
        self.model = model
    }

    public var document: Document {
        model.document
    }

    public func setDocument(_ document: Document) {
        model.editDocument(document)
    }

    public func setFilename(_ filename: String) {
        model.filename = filename
    }

    /// Append a layer. T4: this speaks to `layers` and nothing else, so it goes
    /// through `Document.replacing`. The inline `Document(...)` it replaced
    /// passed five of eight fields, and the designated init defaults the rest,
    /// so a call to THIS METHOD erased the off-canvas symbol masters
    /// (SYMBOLS.md §6), the Document Setup record and the Print preferences —
    /// the same failure mode `addElement` below carries a comment about.
    /// Scoped exactly: no production caller reaches this method today (its only
    /// callers are tests; the interactive add-layer path is `op_apply`'s
    /// `wrap_in_layer` / layer-insert arms, and Rust has no `add_layer` on
    /// Controller at all), so this repair removes a loaded trap rather than a
    /// user-visible bug.
    public func addLayer(_ layer: Layer) {
        let old = model.document
        model.editDocument(old.replacing(layers: old.layers + [layer]))
    }

    public func removeLayer(at index: Int) {
        var layers = model.document.layers
        layers.remove(at: index)
        model.editDocument(model.document.replacing(layers: layers))
    }

    /// Add an element to the current editing target and select the
    /// new element. In content-mode (the default), the element is
    /// appended to the selected layer. In mask-editing mode
    /// (OPACITY.md §Preview interactions) the element is appended
    /// to the masked element's mask subtree instead — mask-mode
    /// falls back to the layer path when the mask subtree isn't a
    /// container (shouldn't happen with masks created via
    /// ``makeMaskOnSelection``, but protects against
    /// externally-built masks).
    public func addElement(_ element: Element) {
        // Mask-mode: append to mask subtree and bail out on
        // success. On any "can't route here" failure we fall
        // through to the content path so the user's stroke isn't
        // lost.
        if case .mask(let path) = model.editingTarget {
            if addElementToMask(element, at: path) {
                return
            }
        }
        let doc = model.document
        let idx = doc.selectedLayer
        let target = doc.layers[idx]
        let childIdx = target.children.count
        // T4: the layer names no part of this edit — the op only appends to it —
        // so every one of ITS fields comes back unchanged. The inline
        // `Layer(name:children:opacity:transform:)` this replaced kept four of
        // eleven, silently erasing the target layer's `id`, `locked`,
        // `visibility`, `blendMode`, `isolatedBlending`, `knockoutGroup` and
        // `mask`. Scoped exactly: this is the commit path behind the
        // `doc.add_element` YAML effect (so every YAML drawing tool), plus
        // TypeTool, TypeOnPathTool and two path-committing arms in
        // YamlToolEffects — i.e. it fired on the artist's every shape. Rust
        // never had the hole: `add_element` appends through
        // `layers[idx].children_mut()`, so the layer is mutated, not rebuilt.
        let newLayer = target.withChildren(target.children + [element])
        var layers = doc.layers
        layers[idx] = newLayer
        let es = ElementSelection.all([idx, childIdx])
        // Preserve every non-layer document field the same structural way:
        // Document's designated initializer defaults symbols / artboards /
        // artboardOptions / documentSetup / printPreferences when they aren't
        // passed, so a shorter call wiped the artboard out from under the user
        // the moment they drew their first shape. `replacing` forwards
        // everything not named, so the off-canvas master store (SYMBOLS.md §6)
        // and the setup/print records survive without a field list to maintain.
        model.editDocument(doc.replacing(layers: layers,
                                         selectedLayer: idx,
                                         selection: [es]))
    }

    /// Stamp a stable `id` onto the element at `path` — the lazy
    /// assign-on-create primitive (REFERENCE_GRAPH.md §4). The id is
    /// minted by the initiator and carried in the operation payload,
    /// never minted here, so every app applies the identical value. A
    /// no-op when the path is invalid. The caller owns identity: this
    /// overwrites any existing id (re-identification is the initiator's
    /// responsibility; reference remapping arrives with the graph).
    public func assignId(_ path: ElementPath, id: String) {
        let doc = model.document
        guard let elem = doc.tryGetElement(path) else { return }
        model.editDocument(doc.replaceElement(path, with: elem.withId(id)))
    }

    /// Create a by-id reference to the element at `targetPath`
    /// (REFERENCE_GRAPH.md §4). Assign-on-create: stamp `targetId` onto the
    /// target *iff* it has no id yet (the lazy-mint trigger); if it already
    /// has one, that id names the edge and `targetId` is ignored. A new
    /// `ReferenceElem` (its own id = `refId`) is then appended via
    /// ``addElement``. Both ids are minted by the initiator and carried in
    /// the operation payload — never minted here — so every app applies the
    /// identical values. A no-op when `targetPath` is invalid. Mirrors Rust
    /// `Controller::create_reference`.
    public func createReference(_ targetPath: ElementPath, targetId: String, refId: String) {
        let doc = model.document
        guard let target = doc.tryGetElement(targetPath) else { return }
        let resolvedId: String
        if let existing = target.id {
            resolvedId = existing
        } else {
            model.editDocument(doc.replaceElement(targetPath, with: target.withId(targetId)))
            resolvedId = targetId
        }
        // A created reference is a 0 -> 1 BIRTH: it wears no operand's
        // identity (EDIT_SEMANTICS_FREEZE.md §3.4), so it is born unnamed.
        // Rust passes `CommonProps { id: Some(ref_id), ..default() }` here,
        // whose `name` is None.
        let reference = Element.live(.reference(ReferenceElem(
            target: ElementRef(resolvedId), name: nil, id: refId)))
        addElement(reference)
    }

    // MARK: - Symbols P2 — operations (SYMBOLS.md §7)
    //
    // Value-in-op: every id is minted by the initiator/UI and carried in the
    // op payload, never minted inside the Controller (same rule as
    // createReference / assignId), so all apps apply identical values. Each
    // clones the doc, mutates, and setDocument — no internal snapshot; the
    // caller owns undo.

    /// Make Symbol (promote): move the element at `path` into `doc.symbols` as
    /// a master and leave a `ReferenceElem` instance in its place (SYMBOLS.md
    /// §7, Fork S6 — the dual of Detach). Assign-on-create: if the element
    /// already has an id, that id is KEPT as the master key and `masterId` is
    /// ignored (mirrors createReference's target rule); otherwise `masterId`
    /// is stamped. The instance carries `id = refId` and targets the master
    /// id. Net: the master lives off-canvas in `symbols`, an instance sits
    /// where the element was, so the canvas looks unchanged (the instance
    /// resolves to the master geometry). A no-op on an invalid path. Mirrors
    /// Rust `Controller::make_symbol`.
    public func makeSymbol(_ path: ElementPath, masterId: String, refId: String) {
        let doc = model.document
        guard let target = doc.tryGetElement(path) else { return }
        // Resolve the master id: keep the element's own id if it has one, else
        // stamp the carried masterId (assign-on-create).
        let resolvedId = target.id ?? masterId
        // The master carries the resolved id.
        let master = target.withId(resolvedId)
        // The in-place instance targets the master id, with its own refId.
        // Born unnamed: the NAME rides with the master, which is `target`
        // itself (only its id is re-stamped). Rust passes a default
        // `CommonProps` here for the same reason.
        let reference = Element.live(.reference(ReferenceElem(
            target: ElementRef(resolvedId), name: nil, id: refId)))
        // Replace the element in place with the instance, then push the master
        // into the off-canvas store.
        let newDoc = doc.replaceElement(path, with: reference)
        model.editDocument(newDoc.replacing(symbols: newDoc.symbols + [master]))
    }

    /// Place Instance: append a `ReferenceElem` targeting an existing master
    /// (`masterId`) to the active layer via ``addElement`` (which auto-selects
    /// it) — exactly like createReference's final step (SYMBOLS.md §7). No
    /// offset: placement offset is a UI concern. It is fine if `masterId` does
    /// not currently exist; the instance simply renders empty until the master
    /// appears (dangling is already handled by the resolver). The instance
    /// carries `id = refId`, minted by the initiator. Mirrors Rust
    /// `Controller::place_instance`.
    public func placeInstance(masterId: String, refId: String) {
        // A placed instance is a 0 -> 1 birth; born unnamed, like Rust's
        // `place_instance` (default `CommonProps` but for the id).
        let reference = Element.live(.reference(ReferenceElem(
            target: ElementRef(masterId), name: nil, id: refId)))
        addElement(reference)
    }

    /// Append a new generated instance of `conceptId` (with the given default
    /// `params`) to the active layer and select it (CONCEPTS.md §6). The element
    /// id is minted by the initiator (value-in-op). Mirrors Rust
    /// `Controller::place_concept_instance`.
    public func placeConceptInstance(conceptId: String, params: [String: Any], elemId: String) {
        // A placed concept instance is a 0 -> 1 birth; born unnamed, like
        // Rust's `place_concept_instance` (default `CommonProps` but for id).
        let generated = Element.live(.generated(GeneratedElem(
            conceptId: conceptId, params: params, name: nil, id: elemId)))
        addElement(generated)
    }

    /// Set one parameter on the `GeneratedElem` at `path` to `value`, so the
    /// concept instance re-generates its geometry live (CONCEPTS.md §6.4 — "tune
    /// the same parameters without redoing anything"). Value-in-op: the new
    /// value is carried in the payload. No-op when `path` is invalid or the
    /// element there is not a generated instance. Mirrors Rust
    /// `Controller::set_concept_param`.
    public func setConceptParam(_ path: ElementPath, name: String, value: Double) {
        let doc = model.document
        guard let elem = doc.tryGetElement(path) else { return }
        guard case .live(.generated(var gen)) = elem else { return }
        gen.params[name] = value
        model.editDocument(doc.replaceElement(path, with: .live(.generated(gen))))
    }

    /// Apply a concept operation's RESOLVED `changes` to the generated instance
    /// at `path` (CONCEPTS.md §9): merge each `name -> value` of `changes` into
    /// the `GeneratedElem`'s params (a multi-param generalization of
    /// `setConceptParam`). `changes` is the production-resolved effect of an
    /// operation (value-in-op), so this performs no expression evaluation — it
    /// just writes the values; the geometry re-derives from the generator at the
    /// next render. No-op if `path` is invalid, the element there is not a
    /// generated instance, or `changes` is empty. Mirrors Rust
    /// `Controller::apply_concept_operation`.
    public func applyConceptOperation(_ path: ElementPath, changes: [String: Any]) {
        guard !changes.isEmpty else { return }
        let doc = model.document
        guard let elem = doc.tryGetElement(path) else { return }
        guard case .live(.generated(var gen)) = elem else { return }
        for (name, value) in changes {
            gen.params[name] = value
        }
        model.editDocument(doc.replaceElement(path, with: .live(.generated(gen))))
    }

    /// Promote the raw element at `path` to a live `GeneratedElem` of
    /// `conceptId` with the fitted `params` and placement `transform`
    /// (CONCEPTS.md §10 — the fitter / `promote`). The recovered params + the
    /// origin-centered generator + the placement transform re-render the same
    /// geometry the raw element drew. The original element's identity (id,
    /// opacity, locked, visibility, blend mode, mask) is PRESERVED; only the
    /// placement transform is (re)set. Every operand is value-in-op — the
    /// detection already happened at production time — so this just builds the
    /// element. No-op if `path` is missing. Mirrors Rust
    /// `Controller::promote_to_concept`.
    public func promoteToConcept(
        _ path: ElementPath, conceptId: String,
        params: [String: Any], transform: Transform
    ) {
        let doc = model.document
        guard let existing = doc.tryGetElement(path) else { return }
        // Preserve the raw element's identity; (re)set only the placement. The
        // promotable kinds (Polygon / Polyline) carry an opacity slot the flat
        // Element accessors do not expose, so read it from the concrete struct.
        let opacity: Double = {
            switch existing {
            case .polygon(let p): return p.opacity
            case .polyline(let p): return p.opacity
            default: return 1.0
            }
        }()
        let generated = GeneratedElem(
            conceptId: conceptId,
            params: params,
            // PROMOTE is 1 -> 1 and speaks to the GENERATOR, not the identity:
            // Rust clones the whole `common` here (its own battery is named
            // "preserving the original element's identity (id/name)"). This
            // port hand-listed six fields and could not list `name` at all,
            // so a promoted element silently came back unnamed.
            name: existing.name,
            id: existing.id,
            transform: transform,
            opacity: opacity,
            locked: existing.isLocked,
            visibility: existing.visibility,
            blendMode: existing.blendMode,
            mask: existing.mask)
        model.editDocument(doc.replaceElement(path, with: .live(.generated(generated))))
    }

    /// Detach (break the link / expand): replace the `ReferenceElem` instance
    /// at `path` with an INDEPENDENT copy of its resolved target (SYMBOLS.md
    /// §7, Fork S6 — the inverse of Make Symbol). The target id is resolved by
    /// a pure lookup over ALL id-bearing elements (`doc.symbols` AND `layers`;
    /// deterministic, no entropy). The copy is born id-less (``clearingIds``,
    /// per the duplication rule) and the instance's own overrides are applied
    /// onto it: its `transform` (set, or compose if the copy already has one)
    /// and its paint (`fill`/`stroke` applied only when non-nil). The master
    /// and every other instance are untouched, and nothing is minted. A no-op
    /// when the path is invalid, not a reference, or the target is
    /// unresolvable. Mirrors Rust `Controller::detach`.
    public func detach(_ path: ElementPath) {
        let doc = model.document
        guard let elem = doc.tryGetElement(path) else { return }
        // Must be a reference instance.
        guard case .live(.reference(let instance)) = elem else { return }
        // Resolve the target id over symbols + layers (a pure id->element map).
        guard let target = findElementById(doc, instance.target.id) else { return }

        // Independent copy of the resolved target, born id-less.
        var copy = target.clearingIds()

        // Apply the instance's transform overrides. The render composition is
        // `transform` (the render CTM) ∘ `instanceTransform` (Symbols P4 /
        // Fork F2); detach must fold BOTH onto the copy so neither is dropped.
        // Build the instance-side transform first (CTM ∘ instance field), then
        // pre-multiply onto any transform the copy already carries
        // (withTransformPremultiplied computes instCombined * (copy.transform ??
        // identity), matching the reference).
        let instCombined: Transform?
        switch (instance.transform, instance.instanceTransform) {
        case let (ct?, it?): instCombined = ct.multiply(it)
        case let (ct?, nil): instCombined = ct
        case let (nil, it?): instCombined = it
        case (nil, nil): instCombined = nil
        }
        if let instT = instCombined {
            copy = copy.withTransformPremultiplied(instT)
        }
        // Apply the instance's paint overrides (only when non-nil).
        if instance.fill != nil {
            copy = withFill(copy, fill: instance.fill)
        }
        if instance.stroke != nil {
            copy = withStroke(copy, stroke: instance.stroke)
        }

        model.editDocument(doc.replaceElement(path, with: copy))
    }

    /// Set the instance `transform` of the `ReferenceElem` at `path` (Symbols
    /// P4, SYMBOLS.md §4 / Fork F2). Value-in-op: the `transform` is carried in
    /// the payload (not minted), letting an instance be mirrored/scaled relative
    /// to its master. This is the instance transform, distinct from the render
    /// CTM (`transform`); the render composition is
    /// `transform` (CTM) ∘ instance `transform`. No-op when `path` is invalid
    /// or the element there is not a reference. Mirrors Rust
    /// `Controller::set_instance_transform`.
    public func setInstanceTransform(_ path: ElementPath, transform: Transform) {
        let doc = model.document
        guard let elem = doc.tryGetElement(path) else { return }
        guard case .live(.reference(var instance)) = elem else { return }
        // Rebuild the reference with the instance transform set, preserving the
        // target, render CTM, paint overrides, and common props.
        instance.instanceTransform = transform
        model.editDocument(doc.replaceElement(path, with: .live(.reference(instance))))
    }

    /// Redefine: replace the master with id `masterId` in `doc.symbols` with a
    /// clone of the element at `path` (re-id the clone to `masterId`), then
    /// replace the element at `path` in place with a `ReferenceElem` instance
    /// (`id = refId`, targeting `masterId`) — the selection becomes an
    /// instance of the redefined master (SYMBOLS.md §7, Fork S2). All other
    /// instances of `masterId` re-resolve to the new definition on the next
    /// paint. A no-op when `masterId` is not in `symbols` or `path` is
    /// invalid. Mirrors Rust `Controller::redefine`.
    public func redefine(masterId: String, _ path: ElementPath, refId: String) {
        let doc = model.document
        // The master must already exist.
        guard let masterIdx = doc.symbols.firstIndex(where: { $0.id == masterId })
        else { return }
        guard let source = doc.tryGetElement(path) else { return }

        // New master = clone of the selection, re-id'd to masterId.
        let newMaster = source.withId(masterId)

        // The selection becomes an instance of the redefined master. Born
        // unnamed — the name went to `newMaster`, which is the clone. Rust's
        // `redefine` passes a default `CommonProps` but for the id.
        let reference = Element.live(.reference(ReferenceElem(
            target: ElementRef(masterId), name: nil, id: refId)))
        let newDoc = doc.replaceElement(path, with: reference)
        var newSymbols = newDoc.symbols
        newSymbols[masterIdx] = newMaster
        model.editDocument(newDoc.replacing(symbols: newSymbols))
    }

    /// Delete Symbol: remove the master whose `common.id == masterId` from
    /// `doc.symbols` (SYMBOLS.md §7). No-op when no master carries that id.
    /// The instances (`ReferenceElem`s targeting `masterId`) are left
    /// untouched — they simply become dangling and resolve to empty until the
    /// master returns (recoverable via undo, since the caller owns the
    /// snapshot). The Symbols-panel confirm-before-delete warning is a UI
    /// concern, not part of this op. Mirrors Rust `Controller::delete_symbol`.
    public func deleteSymbol(masterId: String) {
        let doc = model.document
        guard let idx = doc.symbols.firstIndex(where: { $0.id == masterId })
        else { return }
        var newSymbols = doc.symbols
        newSymbols.remove(at: idx)
        model.editDocument(doc.replacing(symbols: newSymbols))
    }

    /// Append ``element`` to the mask subtree of the element at
    /// ``path``. Returns ``true`` when the append succeeded,
    /// ``false`` when the target element has no mask or the mask
    /// subtree root isn't a ``group`` element — the caller then
    /// falls back to layer-append. OPACITY.md §Preview
    /// interactions.
    private func addElementToMask(_ element: Element, at path: [Int]) -> Bool {
        let doc = model.document
        let target = doc.getElement(path)
        guard let mask = target.mask else { return false }
        // Only Group / Layer accept new children; on any other root
        // the caller falls back to layer-append.
        guard case .group(let g) = mask.subtreeElement else { return false }
        // T4: the mask's subtree root is a bystander this append rebuilds to
        // reach its children. The nine-argument literal this replaced looked
        // exhaustive and still dropped the two fields it never named — the
        // group's `name` and its `id` — which is precisely why the fix is a
        // structural one and not a longer list.
        let newGroup = g.withChildren(g.children + [element])
        let newMask = Mask(
            subtreeElement: .group(newGroup),
            clip: mask.clip,
            invert: mask.invert,
            disabled: mask.disabled,
            linked: mask.linked,
            unlinkTransform: mask.unlinkTransform
        )
        let newTarget = withMask(target, mask: newMask)
        var newDoc = doc.replaceElement(path, with: newTarget)
        // No canonical path for "inside a mask" — select the
        // mask-target element itself after the add.
        newDoc = newDoc.replacing(selection: [ElementSelection.all(path)])
        model.editDocument(newDoc)
        return true
    }

    /// XOR two selections per element. See the Rust port for the semantic
    /// table; mixed `.all` / `.partial` cases collapse to `.all`.
    ///
    /// ORDER IS PART OF THE RESULT (LAYER_STRUCTURE.md §10, D6). This used to
    /// iterate the two `Dictionary`s, so the surviving entries came out in hash
    /// order — the same defect twice over, since the result was a `Set` as well.
    /// The dictionaries are lookup-only now and emission walks `current` then
    /// `newSel` IN THEIR OWN ORDER. Byte-identical to Rust `toggle_selection`,
    /// which was repaired in the same shape and for the same reason.
    private func toggleSelection(_ current: Selection, _ newSel: Selection) -> Selection {
        let currentByPath = Dictionary(current.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let newByPath = Dictionary(newSel.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var result: Selection = []
        // Walk CURRENT in its own order: survivors keep their existing
        // z-position in the selection, and elements in BOTH are resolved here.
        for curEs in current {
            guard let newEs = newByPath[curEs.path] else {
                result.append(curEs)
                continue
            }
            switch (curEs.kind, newEs.kind) {
            case (.all, .all):
                // Cancel out — element drops out of selection.
                continue
            case (.partial(let a), .partial(let b)):
                // Keep the element even when the XOR is empty — it
                // stays selected as `.partial([])` ("element
                // selected, no CPs highlighted"). `.all` XOR `.all`
                // still drops above; that is the element-level
                // deselect gesture.
                let xor = a.symmetricDifference(b)
                result.append(ElementSelection(path: curEs.path, kind: .partial(xor)))
            default:
                // Mixed `.all` / `.partial` — keep `.all` to preserve
                // pre-refactor behavior for this rare case.
                result.append(ElementSelection.all(curEs.path))
            }
        }
        // Then NEW in its own order: newly-hit elements append behind them.
        for newEs in newSel where currentByPath[newEs.path] == nil {
            result.append(newEs)
        }
        return result
    }

    // MARK: - Selection helpers

    /// Flat 2-level selection with group expansion. Used by `selectRect`
    /// and `selectPolygon` — the only difference between them is the
    /// hit-test predicate.
    private func selectFlat(_ model: Model, predicate: (Element) -> Bool, extend: Bool) {
        let doc = model.document
        var selection: Selection = []
        for (li, layer) in doc.layers.enumerated() {
            let layerVis = layer.visibility
            // A locked layer's subtree is non-selectable by INHERITANCE — lock
            // is not materialized onto children (transcripts/LAYER_STRUCTURE.md
            // §13, RULED 2026-07-28), so the guard has to be an ancestor-aware
            // read at every level rather than a flag on each element. Mirrors
            // this port's own `docHitTest` / `docHitTestDeep` and jas_dioxus
            // `select_flat`.
            //
            // HONEST NOTE ON WHAT IS WATCHED. This walk is three levels deep,
            // and the layer guard on this line is the one that enforces at
            // levels 1 and 2: under it, `effectiveLocked` at those depths is
            // ALGEBRAICALLY the element's own flag, so those two reads are
            // expressive rather than behavioural and no mutation can turn them
            // red (measured: reverting either to `.isLocked` leaves the whole
            // suite green). The GRANDCHILD read below is the behavioural
            // change, and it does red.
            if doc.effectiveLocked([li]) || layerVis == .invisible { continue }
            for (ci, child) in layer.children.enumerated() {
                if doc.effectiveLocked([li, ci]) { continue }
                let childVis = min(layerVis, child.visibility)
                if childVis == .invisible { continue }
                if case .group(let g) = child {
                    // A locked grandchild neither TRIGGERS the group selection
                    // nor JOINS it. Before §13 the predicate ran over every
                    // grandchild unguarded, so a rubber band that touched only
                    // a locked member dragged the group and its unlocked
                    // siblings into the selection with it.
                    //
                    // §16.4 (RULED 2026-07-29): the band ASKS about members,
                    // but ANSWERS with the group alone. This branch used to
                    // push the group AND every unlocked member, which is the
                    // one selection shape no operation reads coherently:
                    // `copySelection` copies the group whole and then copies
                    // each member INTO the source group, so marquee-then-
                    // duplicate left the SOURCE holding four children instead
                    // of two. Move and delete survived it only by accident.
                    let anyHit = g.children.enumerated().contains {
                        !doc.effectiveLocked([li, ci, $0.offset]) && predicate($0.element)
                    }
                    if anyHit {
                        selection.append(ElementSelection.all([li, ci]))
                    }
                } else {
                    if predicate(child) {
                        selection.append(ElementSelection.all([li, ci]))
                    }
                }
            }
        }
        let finalSel = extend ? toggleSelection(doc.selection, selection) : selection
        // Selection-only: a non-undoable write (OP_LOG.md §7/§8).
        model.setDocumentUnbracketed(doc.replacing(selection: finalSel), intent: .selection)
    }

    /// Recursive selection with customizable leaf handling. Used by
    /// `groupSelectRect` and `directSelectRect` — they differ only in
    /// what happens when a leaf element is reached.
    private func selectRecursive(_ model: Model,
                                 leafHandler: ([Int], Element) -> ElementSelection?,
                                 extend: Bool) {
        let doc = model.document
        var selection: Selection = []

        func check(_ path: [Int], _ elem: Element, _ ancestorVis: Visibility) {
            if elem.isLocked { return }
            let effective = min(ancestorVis, elem.visibility)
            if effective == .invisible { return }
            switch elem {
            case .layer(let v):
                for (i, child) in v.children.enumerated() { check(path + [i], child, effective) }
            case .group(let v):
                for (i, child) in v.children.enumerated() { check(path + [i], child, effective) }
            default:
                if let es = leafHandler(path, elem) {
                    selection.append(es)
                }
            }
        }

        for (li, layer) in doc.layers.enumerated() {
            check([li], .layer(layer), .preview)
        }
        let finalSel = extend ? toggleSelection(doc.selection, selection) : selection
        // Selection-only: a non-undoable write (OP_LOG.md §7/§8).
        model.setDocumentUnbracketed(doc.replacing(selection: finalSel), intent: .selection)
    }

    // MARK: - Public selection methods

    public func selectRect(x: Double, y: Double, width: Double, height: Double, extend: Bool = false) {
        selectFlat(model, predicate: { elementIntersectsRect($0, x, y, width, height) }, extend: extend)
    }

    public func selectPolygon(polygon: [(Double, Double)], extend: Bool = false) {
        selectFlat(model, predicate: { elementIntersectsPolygon($0, polygon) }, extend: extend)
    }

    public func groupSelectRect(x: Double, y: Double, width: Double, height: Double, extend: Bool = false) {
        selectRecursive(model, leafHandler: { path, elem in
            elementIntersectsRect(elem, x, y, width, height)
                ? ElementSelection.all(path) : nil
        }, extend: extend)
    }

    public func directSelectRect(x: Double, y: Double, width: Double, height: Double, extend: Bool = false) {
        selectRecursive(model, leafHandler: { path, elem in
            let cps = elem.controlPointPositions
            let hitCPs: [Int] = cps.enumerated().compactMap { (i, pt) in
                pointInRect(pt.0, pt.1, x, y, width, height) ? i : nil
            }
            if !hitCPs.isEmpty {
                return ElementSelection.partial(path, hitCPs)
            } else if elementIntersectsRect(elem, x, y, width, height) {
                // Marquee covers the body but no CPs. Select the
                // element with an empty CP set — the Direct
                // Selection tool must not promote "body
                // intersects" to "every CP selected" (which is
                // what `.all` would mean).
                return ElementSelection.partial(path, [])
            }
            return nil
        }, extend: extend)
    }

    /// Select every TOP-LEVEL object: one entry per direct child of a layer,
    /// **a group counting as ONE**. RULED 2026-07-28 (JYH: "keep the Rust
    /// shape") — transcripts/LAYER_STRUCTURE.md §16. Locked and invisible
    /// objects are excluded, and "locked" is INHERITED (§13).
    ///
    /// THIS USED TO DELEGATE TO `selectFlat`, and that was the whole defect.
    /// `selectFlat`'s group branch inserts the group AND every unlocked
    /// grandchild, so a group of three yielded FOUR entries — a selection
    /// containing an element and its own descendants, which no operation has a
    /// coherent reading of: translate it and the group moves by 24 while each
    /// child, already carried by its parent, moves 24 again. The branch is not
    /// wrong; it was written for the MARQUEE, where "did anything inside the
    /// band match?" is the right question and the members belong in the answer.
    /// Select All called it with `predicate: { _ in true }`, so every group
    /// always hit and a rubber-band rule fired universally. jas_dioxus never had
    /// the bug because `select_all` is its own loop — so this is now its own
    /// loop too, and `selectRect` / `selectPolygon` keep `selectFlat` unchanged.
    ///
    /// ONE lock read, deliberately, exactly as Rust does it: `effectiveLocked`
    /// on the CHILD path already folds in the layer's own flag, so a layer-level
    /// short-circuit above the inner loop would be redundant — and a redundant
    /// guard is one no mutation can turn red, which is how a guard rots.
    public func selectAll() {
        let doc = model.document
        var entries: Selection = []
        for (li, layer) in doc.layers.enumerated() {
            let layerVis = layer.visibility
            if layerVis == .invisible { continue }
            for (ci, child) in layer.children.enumerated() {
                if doc.effectiveLocked([li, ci]) { continue }
                if min(layerVis, child.visibility) == .invisible { continue }
                entries.append(ElementSelection.all([li, ci]))
            }
        }
        // Selection-only: a non-undoable write (OP_LOG.md §7/§8).
        model.setDocumentUnbracketed(doc.replacing(selection: entries), intent: .selection)
    }

    public func setSelection(_ selection: Selection) {
        // Selection-only: a non-undoable write (OP_LOG.md §7/§8).
        model.setDocumentUnbracketed(model.document.replacing(selection: selection), intent: .selection)
    }

    /// Append `path` to the selection, IDEMPOTENTLY — a path already selected
    /// is a no-op. This is shift-click's additive seam (`doc.add_to_selection`).
    ///
    /// Rust has carried `Controller::add_to_selection` since the Vec selection
    /// was written, guard and all, because a `Vec` has no free dedup. This port
    /// inlined the same body in the YAML effect instead, so the guard lived in
    /// the interpreter rather than the Controller and nothing shared could reach
    /// it. Now the effect calls THIS, and the shared `add_to_selection` op verb
    /// drives the same function — LAYER_STRUCTURE.md §10 "THE MIGRATION HAZARD".
    /// Mirrors Rust `Controller::add_to_selection`.
    public func addToSelection(_ path: ElementPath) {
        let doc = model.document
        if doc.selection.contains(where: { $0.path == path }) { return }
        var sel = doc.selection
        sel.append(ElementSelection.all(path))
        // Selection-only: a non-undoable write (OP_LOG.md §7/§8).
        model.setDocumentUnbracketed(doc.replacing(selection: sel), intent: .selection)
    }

    public func selectElement(_ path: ElementPath) {
        guard !path.isEmpty else { fatalError("Path must be non-empty") }
        let doc = model.document
        let elem = doc.getElement(path)
        // Both reads below are INHERITED down the path. Until LOCKINHERIT the
        // first one read the element's OWN `isLocked` flag, one line above an
        // ancestor-aware visibility read — so a click on a child of a locked
        // layer selected it. transcripts/LAYER_STRUCTURE.md §13.
        if doc.effectiveLocked(path) { return }
        if doc.effectiveVisibility(path) == .invisible { return }
        if path.count >= 2 {
            let parentPath = Array(path.dropLast())
            let parent = doc.getElement(parentPath)
            if case .group(let g) = parent {
                var selection: Selection = [ElementSelection.all(parentPath)]
                for i in 0..<g.children.count {
                    selection.append(ElementSelection.all(parentPath + [i]))
                }
                // Selection-only: a non-undoable write (OP_LOG.md §7/§8).
                model.setDocumentUnbracketed(doc.replacing(selection: selection), intent: .selection)
                return
            }
        }
        let _ = elem
        // Selection-only: a non-undoable write (OP_LOG.md §7/§8).
        model.setDocumentUnbracketed(doc.replacing(selection: [ElementSelection.all(path)]), intent: .selection)
    }

    public func selectControlPoint(path: ElementPath, index: Int) {
        guard !path.isEmpty else { fatalError("Path must be non-empty") }
        let es = ElementSelection.partial(path, [index])
        // Selection-only: a non-undoable write (OP_LOG.md §7/§8).
        model.setDocumentUnbracketed(model.document.replacing(selection: [es]), intent: .selection)
    }

    public func movePathHandle(_ path: ElementPath, anchorIdx: Int,
                              handleType: String, dx: Double, dy: Double) {
        var doc = model.document
        let elem = doc.getElement(path)
        if case .path(let v) = elem {
            let newD = JasLib.movePathHandle(v.d, anchorIdx: anchorIdx, handleType: handleType, dx: dx, dy: dy)
            // Rust's twin is `PathElem { d: new_cmds, ..elem.clone() }`
            // (geometry/element.rs, move_path_handle) and so preserves
            // every field structurally. Swift has no `..clone()`, so this
            // rebuild must restate all 17 non-`d` fields by hand; the
            // earlier version forwarded only eight and silently promoted
            // outline/invisible paths to `.preview` and erased name/id.
            // Pinned by Tests/Document/MovePathHandleFieldsTests.swift,
            // whose Mirror walk covers fields added to Path later.
            let newElem = Element.path(Path(d: newD, fill: v.fill, stroke: v.stroke,
                                               widthPoints: v.widthPoints,
                                               opacity: v.opacity, transform: v.transform,
                                               locked: v.locked,
                                               visibility: v.visibility,
                                               blendMode: v.blendMode,
                                               mask: v.mask,
                                               fillGradient: v.fillGradient,
                                               strokeGradient: v.strokeGradient,
                                               strokeBrush: v.strokeBrush,
                                               strokeBrushOverrides: v.strokeBrushOverrides,
                                               toolOrigin: v.toolOrigin,
                                               name: v.name,
                                               id: v.id,
                                               fillRule: v.fillRule))
            doc = doc.replaceElement(path, with: newElem)
            model.editDocument(doc)
        }
    }

    public func moveSelection(dx: Double, dy: Double) {
        var doc = model.document
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            let newElem = elem.moveControlPoints(es.kind, dx: dx, dy: dy)
            doc = doc.replaceElement(es.path, with: newElem)
        }
        model.editDocument(doc)
    }

    /// Simplify the geometry of each selected Polygon / Path element in
    /// place by running the Schneider curve fit (`simplifyPolyline`) on
    /// its vertices. Other element kinds are left alone. Used by
    /// Object → Simplify and (in future) other refit entry points.
    /// `precision` is the Schneider max-error tolerance in points.
    ///
    /// Polygons are replaced with Paths carrying the refitted CurveTo /
    /// LineTo commands; existing Paths are re-issued with refitted
    /// geometry. Selection is preserved.
    ///
    /// Faithful port of jas_dioxus controller.rs `simplify_selection`.
    /// Like `moveSelection`, this mutates `model.document` directly and
    /// does not push its own undo snapshot — the caller/harness brackets.
    public func simplifySelection(precision: Double) {
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        var newDoc = doc
        for es in doc.selection {
            let elem = newDoc.getElement(es.path)
            switch elem {
            case .polygon(let p):
                let cmds = simplifyPolyline(p.points, precision: precision, closed: true)
                if cmds.isEmpty { continue }
                let newPath = Element.path(Path(
                    d: cmds,
                    fill: p.fill,
                    stroke: p.stroke,
                    widthPoints: [],
                    opacity: p.opacity,
                    transform: p.transform,
                    locked: p.locked,
                    visibility: p.visibility,
                    blendMode: p.blendMode,
                    mask: p.mask,
                    fillGradient: p.fillGradient,
                    strokeGradient: p.strokeGradient,
                    name: p.name,
                    id: p.id,
                    // A Polygon carries no fill rule, so the refit Path is
                    // a fresh nonzero one. Matches Rust's Polygon arm.
                    fillRule: .nonzero
                ))
                newDoc = newDoc.replaceElement(es.path, with: newPath)
            case .path(let p):
                // Walk the path command list, splitting at every moveTo /
                // closePath into subpaths of 2D points. Each subpath is
                // refit independently; other command kinds (curveTo,
                // arcTo, ...) are passed through as-is.
                var newCmds: [PathCommand] = []
                var buf: [(Double, Double)] = []
                var closed = false
                func flush() {
                    if buf.count >= 2 {
                        let sub = simplifyPolyline(buf, precision: precision, closed: closed)
                        newCmds.append(contentsOf: sub)
                    }
                    buf.removeAll(keepingCapacity: true)
                    closed = false
                }
                for c in p.d {
                    switch c {
                    case .moveTo(let x, let y):
                        flush()
                        buf.append((x, y))
                    case .lineTo(let x, let y):
                        buf.append((x, y))
                    case .closePath:
                        closed = true
                        flush()
                    default:
                        // Already-curved commands stay verbatim; splice
                        // the buffered run before emitting them so refit
                        // and pre-existing curves sit in order.
                        flush()
                        newCmds.append(c)
                    }
                }
                flush()
                if newCmds.isEmpty { continue }
                let newPath = Element.path(Path(
                    d: newCmds,
                    fill: p.fill,
                    stroke: p.stroke,
                    widthPoints: p.widthPoints,
                    opacity: p.opacity,
                    transform: p.transform,
                    locked: p.locked,
                    visibility: p.visibility,
                    blendMode: p.blendMode,
                    mask: p.mask,
                    fillGradient: p.fillGradient,
                    strokeGradient: p.strokeGradient,
                    strokeBrush: p.strokeBrush,
                    strokeBrushOverrides: p.strokeBrushOverrides,
                    toolOrigin: p.toolOrigin,
                    name: p.name,
                    id: p.id,
                    fillRule: p.fillRule
                ))
                newDoc = newDoc.replaceElement(es.path, with: newPath)
            default:
                break
            }
        }
        model.editDocument(newDoc)
    }

    /// `Object > Lock` (Ctrl+2, `workspace/actions.yaml` §lock): set the
    /// `locked` flag on each selected element and clear the selection.
    ///
    /// **ON EACH SELECTED ELEMENT, AND ON NOTHING ELSE.** A Group or Layer's
    /// lock reaches its contents by INHERITANCE (``Document/effectiveLocked(_:)``),
    /// never by being written onto them — this is step 1 of
    /// ``Document/togglingElementLock(at:)``, the Layers-panel lock button,
    /// applied once per selected path, and it uses the very same
    /// ``Element/withLocked(_:)`` helper. It is deliberately the same shape
    /// rather than a second one: until LOCKMAT this function kept its own
    /// recursive `lockRecursive` whose `case .group` arm stamped
    /// `locked = true` onto every descendant, which is the MATERIALIZATION
    /// transcripts/LAYER_STRUCTURE.md §13 repealed (RULED by JYH 2026-07-28).
    /// §13 repaired the panel path and left this one, and the two then said
    /// different things about the same artist action.
    ///
    /// Why the residue could not simply be left: §13.1 landed `jas:locked`, so
    /// stamped flags SURVIVE SAVE AND RELOAD, and under inheritance nothing
    /// clears a single one of them — opening the parent leaves every child
    /// locked, and `Unlock All` is the whole document or nothing.
    ///
    /// The selection is cleared WHOLESALE, which is `togglingElementLock`'s
    /// step 2 in the case where every selected path was just locked: it is not
    /// cosmetic, because nothing downstream refuses to move or delete a locked
    /// element, so a lock that left the selection alone would leave locked
    /// content draggable.
    ///
    /// `withLocked` is clone-then-mutate on all twelve Element cases, so the
    /// copy-site omission class cannot reach this walk — the group arm it
    /// replaced needed a hand-written comment to stay honest about eleven
    /// fields, and this one has no rebuild to get wrong. `tryGetElement` rather
    /// than `getElement`, matching `togglingElementLock`'s guard: a selection
    /// entry naming no element is skipped, not trapped on.
    ///
    /// The twin is jas_dioxus `Controller::lock_selection`.
    public func lockSelection() {
        var doc = model.document
        for es in doc.selection {
            guard let elem = doc.tryGetElement(es.path) else { continue }
            doc = doc.replaceElement(es.path, with: elem.withLocked(true))
        }
        model.editDocument(doc.replacing(selection: []))
    }

    public func unlockAll() {
        let doc = model.document
        var lockedPaths: [ElementPath] = []

        func collectLocked(_ path: ElementPath, _ elem: Element) {
            switch elem {
            case .group(let g):
                if g.locked { lockedPaths.append(path) }
                for (i, child) in g.children.enumerated() {
                    collectLocked(path + [i], child)
                }
            case .layer(let l):
                for (i, child) in l.children.enumerated() {
                    collectLocked(path + [i], child)
                }
            default:
                if elem.isLocked { lockedPaths.append(path) }
            }
        }
        for (li, layer) in doc.layers.enumerated() {
            for (ci, child) in layer.children.enumerated() {
                collectLocked([li, ci], child)
            }
        }

        func unlockChildren(_ elements: [Element]) -> [Element] {
            elements.map { elem in
                switch elem {
                // T4: unlocking speaks to `locked`; every other field of every
                // container this walk rebuilds comes back untouched. The three
                // inline literals this replaced kept five or six of eleven
                // fields, so unlock-all destroyed the `id` of EVERY layer and
                // group in the document (and a Group's `name` besides). Rust's
                // `unlock_element` is clone-then-mutate and never had the hole.
                case .group(let g):
                    var v = g.withChildren(unlockChildren(g.children))
                    v.locked = false
                    return Element.group(v)
                case .layer(let l):
                    var v = l.withChildren(unlockChildren(l.children))
                    v.locked = false
                    return Element.layer(v)
                default:
                    return elem.isLocked ? elem.withLocked(false) : elem
                }
            }
        }
        let newLayers = doc.layers.map { layer -> Layer in
            var v = layer.withChildren(unlockChildren(layer.children))
            v.locked = false
            return v
        }
        let newDoc = doc.replacing(layers: newLayers, selection: [])
        var newSelection: Selection = []
        for path in lockedPaths {
            let _ = newDoc.getElement(path)
            newSelection.append(ElementSelection.all(path))
        }
        model.editDocument(doc.replacing(layers: newLayers, selection: newSelection))
    }

    /// Set every element in the current selection to
    /// `Visibility.invisible` and clear the selection.
    ///
    /// If an element is a Group or Layer, only the container's own
    /// flag is set — a parent's `.invisible` caps every descendant,
    /// so the effect reaches the whole subtree without rewriting
    /// every node.
    public func hideSelection() {
        var doc = model.document
        if doc.selection.isEmpty { return }
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            doc = doc.replaceElement(es.path, with: elem.withVisibility(.invisible))
        }
        model.editDocument(doc.replacing(selection: []))
    }

    /// Traverse the document, set every element whose own visibility
    /// is `Visibility.invisible` back to `Visibility.preview`, and
    /// replace the current selection with exactly the paths that were
    /// shown. Elements that are effectively invisible only because an
    /// ancestor is invisible are *not* individually modified — it is
    /// the ancestor whose own flag is unset, and that cascades.
    public func showAll() {
        let doc = model.document
        var shownPaths: [ElementPath] = []

        func showIn(_ elem: Element, _ path: ElementPath) -> Element {
            var newElem = elem
            if elem.visibility == .invisible {
                newElem = elem.withVisibility(.preview)
                shownPaths.append(path)
            }
            // T4: show-all speaks to `visibility`, already written onto
            // `newElem` above. Rebuilding the container to carry the rewritten
            // children must change NOTHING else — the two inline literals this
            // replaced kept five or six of eleven fields, so showing all
            // destroyed the `id` of every layer and group in the document (and
            // a Group's `name`). Rust's `show_all_in` is clone-then-mutate.
            switch newElem {
            case .group(let g):
                return .group(g.withChildren(g.children.enumerated().map { (i, c) in
                    showIn(c, path + [i])
                }))
            case .layer(let l):
                return .layer(l.withChildren(l.children.enumerated().map { (i, c) in
                    showIn(c, path + [i])
                }))
            default:
                return newElem
            }
        }

        let newLayers: [Layer] = doc.layers.enumerated().map { (li, layer) in
            let shown = showIn(.layer(layer), [li])
            // showIn preserves the Element variant: a .layer input always produces a .layer output.
            guard case .layer(let l) = shown else { fatalError("unreachable") }
            return l
        }
        var newSelection: Selection = []
        for path in shownPaths {
            newSelection.append(ElementSelection.all(path))
        }
        model.editDocument(doc.replacing(layers: newLayers, selection: newSelection))
    }

    /// Group the selected elements into a new Group. **R1 — group ALWAYS
    /// flattens** (transcripts/LAYER_STRUCTURE.md §3, ratified 2026-07-28).
    ///
    /// Every selected element becomes a child of the new Group regardless of
    /// where it came from — across layers, across sibling groups, at any
    /// depth. There is no refusal and no silent no-op. This replaced a guard
    /// that required all selected paths to share one parent prefix; with it,
    /// Cmd+G on a selection spanning two layers did nothing and said nothing
    /// (defect D2). The guard was about PARENTS, not layers: a selection
    /// spanning two different Groups failed identically.
    ///
    /// **Why flattening rather than preservation.** A Group is an element and
    /// its children are its children; there is no representation in which one
    /// Group's children live in two different parents. Unlike paste there is
    /// no structure-preserving option to choose between, so this is the
    /// Preservation Law's *what it cannot preserve it must not guess* clause
    /// resolved by T3's documented default.
    ///
    /// **Placement: the FRONTMOST selected element's parent, at the z-slot
    /// that element vacates.** Frontmost is the GREATEST path — paths sort
    /// ascending and the canvas paints layers forward, so a higher index
    /// paints later and therefore on top. Same rule BOOLEAN.md fixes and
    /// `makeCompoundShape` already implements with the last operand. Placing
    /// the group frontmost minimises visual change: it renders roughly where
    /// the frontmost member already rendered, instead of hurling the selection
    /// backward past unrelated content.
    ///
    /// Note this half of R1 also corrects the SAME-PARENT case. `actions.yaml`
    /// §group has always said the group "inherits the z-order position of the
    /// frontmost selected object"; both ports inserted at `paths[0]`, the
    /// BACKMOST. The two agree only when the selection is contiguous, which is
    /// why the existing corpus golden never saw it.
    ///
    /// **On electing a winner from geometry.** The Preservation Law forbids
    /// electing an IDENTITY winner from geometry, z-order included, and this
    /// is deliberately NOT that. Identity here is a FRESH group — a 0 -> 1
    /// creation under the cardinality law, wearing default properties and
    /// never a member's id — while z-order is being used for PLACEMENT, which
    /// is inherently an ordering concern. The surface resemblance will
    /// otherwise read as a contradiction.
    ///
    /// **Emptied source containers are KEPT — both layers and groups.** A
    /// container the selection drained was never what the edit spoke to; it is
    /// a bystander (T4), and it carries a name, an id and blend flags that
    /// deleting would destroy on an unrequested 1 -> 0. This is NOT the orphan
    /// D3 was fixed for: there a container was emptied by a WRONG insert that
    /// should have landed inside it, whereas here the emptying is the correct
    /// consequence of a move the artist asked for.
    ///
    /// Twin probes: `Tests/Document/GroupFlattenTests.swift` and the Rust
    /// `r1_*` tests in `jas_dioxus/src/document/controller.rs`, case for case,
    /// plus the shared corpus family `test_fixtures/actions/group_flatten.json`.
    public func groupSelection() {
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        // `Selection` is a Set here and a Vec in Rust, so this sort is what
        // makes the two ports agree on document order at all.
        let sorted = doc.selection.map(\.path).sorted { $0.lexicographicallyPrecedes($1) }
        var paths: [ElementPath] = []
        for p in sorted where paths.last != p { paths.append(p) }
        // An ancestor carries its own children, so a selected path that sits
        // UNDER another selected path is dropped from the move. Without this,
        // selecting a Group and one of its children would clone the child into
        // the new group AND leave it inside the cloned subtree: the same
        // element twice, one live id duplicated.
        //
        // UNRULED, and taken as the conservative reading rather than as law:
        // brief §6 open question 3 (mixed DEPTHS) is not settled, and this is
        // the sub-case where the naive reading is not merely debatable but
        // unsafe. Banked for JYH.
        let roots = paths.filter { p in
            !paths.contains { q in
                q != p && p.count > q.count && Array(p.prefix(q.count)) == q
            }
        }
        guard roots.count >= 2 else { return }
        // Rust resolves each path with `get_element`, which returns None for a
        // stale path and makes the whole operation a silent no-op. Swift's
        // `getElement` INDEXES and would trap, so the same staleness that is
        // quiet in Rust would be a crash here. Check resolvability first.
        guard roots.allSatisfy({ pathResolves(doc, $0) }) else { return }
        let elements = roots.map { doc.getElement($0) }
        // The destination: the FRONTMOST root's own path, with each component
        // shifted down by the deletions that land EARLIER in that same
        // container. A deleted path shifts `front[k]` exactly when it is a
        // direct child of `front[..k]` with a smaller index — deleting a whole
        // subtree removes one entry from its parent, so every later sibling
        // (including an ANCESTOR of the frontmost element) slides back one.
        let front = roots[roots.count - 1]
        var insertPath = front
        for k in 0..<front.count {
            let shift = roots.filter { d in
                d != front && d.count == k + 1
                    && Array(d.prefix(k)) == Array(front.prefix(k)) && d[k] < front[k]
            }.count
            insertPath[k] -= shift
        }
        // Delete the sources in reverse document order (descending paths keep
        // the remaining indices valid). `deleteElement` recurses.
        var newDoc = doc
        for path in roots.reversed() {
            newDoc = newDoc.deleteElement(path)
        }
        // The new Group is a fresh 0 -> 1 container: it never wears a member's
        // identity.
        let group = Element.group(Group(children: elements))
        // Insert at the destination's TRUE depth. This previously read only
        // `insertPath[1]` and inserted into `layers[insertPath[0]].children`,
        // discarding every deeper component -- so grouping a selection that
        // already lived inside a Group placed the new group one level too high
        // AND left the emptied container behind as an orphan (D3).
        // `deleteElement` recurses correctly, so the delete and the insert
        // disagreed about depth inside a single operation. Mirrors Rust's
        // `insert_element_at`, which recurses on `&path[1..]`.
        // Gate: Tests/Document/NestedGroupProbeTests.swift, and its Rust twin
        // `grouping_inside_a_group_stays_inside_that_group`.
        let parentPath = Array(insertPath.dropLast())
        let childIdx = insertPath.last ?? 0
        let inserted = insertElementAtPath(newDoc, parentPath, childIdx, group)
        let newSelection: Selection = [ElementSelection.all(insertPath)]
        model.editDocument(inserted.replacing(selection: newSelection))
    }

    /// True when every component of `path` addresses a real child, so
    /// `Document.getElement` will not trap. Rust's `get_element` returns an
    /// Option and its callers no-op on None; this is the Swift equivalent of
    /// that check, kept local to the one caller that needs it.
    private func pathResolves(_ doc: Document, _ path: ElementPath) -> Bool {
        guard let first = path.first, first >= 0, first < doc.layers.count else { return false }
        var node: Element = .layer(doc.layers[first])
        for idx in path.dropFirst() {
            let kids = groupChildContainer(node)
            guard idx >= 0, idx < kids.count else { return false }
            node = kids[idx]
        }
        return true
    }

    /// The children of `elem` if it is a container, else []. Mirrors the same
    /// container set `Document.getElement` walks.
    private func groupChildContainer(_ elem: Element) -> [Element] {
        switch elem {
        case .group(let g): return g.children
        case .layer(let l): return l.children
        case .live(.compoundShape(let c)): return c.operands
        default: return []
        }
    }

    /// Ungroup all selected Group elements, replacing each with its children.
    /// After ungrouping, the selection contains the formerly-grouped children.
    public func ungroupSelection() {
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        // Collect selected paths that are Groups
        var groupPaths: [ElementPath] = []
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            if case .group = elem {
                groupPaths.append(es.path)
            }
        }
        guard !groupPaths.isEmpty else { return }
        groupPaths.sort { $0.lexicographicallyPrecedes($1) }
        // Process in reverse order to preserve indices
        var newDoc = doc
        for gpath in groupPaths.reversed() {
            let groupElem = newDoc.getElement(gpath)
            guard case .group(let g) = groupElem else { continue }
            let children = g.children
            // Delete the group
            newDoc = newDoc.deleteElement(gpath)
            let layerIdx = gpath[0]
            let childIdx = gpath.count > 1 ? gpath[1] : 0
            let layer = newDoc.layers[layerIdx]
            var newChildren = layer.children
            newChildren.insert(contentsOf: children, at: childIdx)
            // T4 bystander clause: see `addElement`. Same four-of-eleven
            // literal, same seven fields lost, once per iteration.
            let newLayer = layer.withChildren(newChildren)
            var newLayers = newDoc.layers
            newLayers[layerIdx] = newLayer
            newDoc = newDoc.replacing(layers: newLayers, selection: [])
        }
        // Build selection for all unpacked children
        var newSelection: Selection = []
        var offset = 0
        for gpath in groupPaths {
            let groupElem = doc.getElement(gpath)
            guard case .group(let g) = groupElem else { continue }
            let nChildren = g.children.count
            let layerIdx = gpath[0]
            let childIdx = (gpath.count > 1 ? gpath[1] : 0) + offset
            for j in 0..<nChildren {
                let path: ElementPath = [layerIdx, childIdx + j]
                newSelection.append(ElementSelection.all(path))
            }
            offset += nChildren - 1
        }
        model.editDocument(newDoc.replacing(selection: newSelection))
    }

    /// Make a compound shape from the current selection using UNION.
    /// Thin wrapper around makeCompoundShape(operation:).
    public func makeCompoundShape() {
        makeCompoundShape(operation: .union)
    }

    /// Make a compound shape from the current selection using the
    /// given [operation]. All selected elements must be siblings;
    /// at least 2 required. Paint inherits from the frontmost
    /// (last-in-path-order) operand. The new compound replaces its
    /// operands in place and becomes the selection. See BOOLEAN.md
    /// §Compound shapes.
    public func makeCompoundShape(operation: CompoundOperation) {
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        let paths = doc.selection.map(\.path).sorted { $0.lexicographicallyPrecedes($1) }
        guard paths.count >= 2 else { return }
        let parent = Array(paths[0].dropLast())
        guard paths.allSatisfy({ Array($0.dropLast()) == parent }) else { return }
        let elements = paths.map { doc.getElement($0) }
        let frontmost = elements.last!
        let cs = CompoundShape(
            operation: operation,
            operands: elements,
            // A compound is a WRAP: 0 -> 1, and a container never wears a
            // member's identity (EDIT_SEMANTICS_FREEZE.md §3.4). Only the
            // frontmost operand's PAINT is inherited, which is exactly what
            // Rust's `make_compound_shape_with_op` copies. So: unnamed.
            name: nil,
            fill: frontmost.fill,
            stroke: frontmost.stroke,
            opacity: 1.0,
            transform: frontmost.transform,
            locked: false,
            visibility: frontmost.visibility
        )
        let compound = Element.live(.compoundShape(cs))
        var newDoc = doc
        for path in paths.reversed() {
            newDoc = newDoc.deleteElement(path)
        }
        let insertPath = paths[0]
        let layerIdx = insertPath[0]
        let childIdx = insertPath.count > 1 ? insertPath[1] : 0
        let layer = newDoc.layers[layerIdx]
        var newChildren = layer.children
        newChildren.insert(compound, at: childIdx)
        // T4 bystander clause: the layer is rebuilt only to reach its children.
        // See `addElement` — the same four-of-eleven literal, same seven fields
        // lost, and the containing layer is the artist's, not this op's.
        let newLayer = layer.withChildren(newChildren)
        var newLayers = newDoc.layers
        newLayers[layerIdx] = newLayer
        let newSelection: Selection = [ElementSelection.all(insertPath)]
        model.editDocument(newDoc.replacing(layers: newLayers, selection: newSelection))
    }

    /// Alt/Option+click on the four Shape Mode buttons. Creates a
    /// live compound shape with the chosen [opName] (union,
    /// subtract_front, intersection, exclude) instead of applying
    /// the destructive variant. Unknown op names are no-ops.
    public func applyCompoundCreation(_ opName: String) {
        let op: CompoundOperation
        switch opName {
        case "union": op = .union
        case "subtract_front": op = .subtractFront
        case "intersection": op = .intersection
        case "exclude": op = .exclude
        default: return
        }
        makeCompoundShape(operation: op)
    }

    /// Release every selected compound shape. Each is replaced with
    /// its operand children; operands keep their own paint. Released
    /// operands become the new selection.
    public func releaseCompoundShape() {
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        var csPaths: [ElementPath] = []
        for es in doc.selection {
            if case .live = doc.getElement(es.path) {
                csPaths.append(es.path)
            }
        }
        guard !csPaths.isEmpty else { return }
        csPaths.sort { $0.lexicographicallyPrecedes($1) }
        var newDoc = doc
        for csPath in csPaths.reversed() {
            guard case .live(.compoundShape(let cs)) = newDoc.getElement(csPath) else { continue }
            newDoc = newDoc.deleteElement(csPath)
            let layerIdx = csPath[0]
            let childIdx = csPath.count > 1 ? csPath[1] : 0
            let layer = newDoc.layers[layerIdx]
            var newChildren = layer.children
            newChildren.insert(contentsOf: cs.operands, at: childIdx)
            // T4 bystander clause: see `addElement`. Same four-of-eleven
            // literal, same seven fields lost, once per iteration.
            let newLayer = layer.withChildren(newChildren)
            var newLayers = newDoc.layers
            newLayers[layerIdx] = newLayer
            newDoc = newDoc.replacing(layers: newLayers, selection: [])
        }
        var newSelection: Selection = []
        var offset = 0
        for csPath in csPaths {
            guard case .live(.compoundShape(let cs)) = doc.getElement(csPath) else { continue }
            let n = cs.operands.count
            let layerIdx = csPath[0]
            let childIdx = (csPath.count > 1 ? csPath[1] : 0) + offset
            for j in 0..<n {
                newSelection.append(ElementSelection.all([layerIdx, childIdx + j]))
            }
            offset += n - 1
        }
        model.editDocument(newDoc.replacing(selection: newSelection))
    }

    /// Expand every selected compound shape into static Polygon
    /// elements derived from its evaluated geometry. Expanded
    /// polygons become the new selection.
    public func expandCompoundShape() {
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        var csPaths: [ElementPath] = []
        for es in doc.selection {
            if case .live = doc.getElement(es.path) {
                csPaths.append(es.path)
            }
        }
        guard !csPaths.isEmpty else { return }
        csPaths.sort { $0.lexicographicallyPrecedes($1) }
        var expandedCounts: [Int] = []
        var newDoc = doc
        for csPath in csPaths.reversed() {
            guard case .live(.compoundShape(let cs)) = newDoc.getElement(csPath) else {
                expandedCounts.append(0)
                continue
            }
            let expanded = cs.expand(precision: DEFAULT_PRECISION)
            expandedCounts.append(expanded.count)
            newDoc = newDoc.deleteElement(csPath)
            let layerIdx = csPath[0]
            let childIdx = csPath.count > 1 ? csPath[1] : 0
            let layer = newDoc.layers[layerIdx]
            var newChildren = layer.children
            newChildren.insert(contentsOf: expanded, at: childIdx)
            // T4 bystander clause: see `addElement`. Same four-of-eleven
            // literal, same seven fields lost, once per iteration.
            let newLayer = layer.withChildren(newChildren)
            var newLayers = newDoc.layers
            newLayers[layerIdx] = newLayer
            newDoc = newDoc.replacing(layers: newLayers, selection: [])
        }
        expandedCounts.reverse()
        var newSelection: Selection = []
        var offset = 0
        for (csPath, n) in zip(csPaths, expandedCounts) {
            let layerIdx = csPath[0]
            let childIdx = (csPath.count > 1 ? csPath[1] : 0) + offset
            for j in 0..<n {
                newSelection.append(ElementSelection.all([layerIdx, childIdx + j]))
            }
            offset += n - 1
        }
        model.editDocument(newDoc.replacing(selection: newSelection))
    }

    /// Destructively apply one of the nine boolean ops to the
    /// current selection. Supported: "union", "intersection",
    /// "exclude", "subtract_front", "subtract_back", "crop",
    /// "divide", "trim", "merge".
    ///
    /// [options] carries the document-scoped Boolean Options
    /// settings (precision / remove_redundant_points /
    /// divide_remove_unpainted) per BOOLEAN.md §Boolean Options
    /// dialog. Defaults are applied when not provided.
    ///
    /// Semantics per BOOLEAN.md §Operand and paint rules:
    /// - UNION / INTERSECTION / EXCLUDE: all operands consumed;
    ///   result carries the frontmost operand's paint.
    /// - SUBTRACT_FRONT: frontmost is consumed as cutter; each
    ///   survivor keeps its own paint.
    /// - SUBTRACT_BACK: backmost is consumed as cutter.
    /// - CROP: frontmost is consumed as mask; survivors clipped to
    ///   its interior.
    /// - DIVIDE: cut the union apart so no two fragments overlap;
    ///   each fragment inherits the frontmost covering operand's
    ///   paint.
    /// - TRIM: each operand minus the union of all later operands;
    ///   frontmost is untouched.
    /// - MERGE: TRIM, then union touching survivors whose solid-
    ///   color fills are exactly equal.
    public func applyDestructiveBoolean(
        _ opName: String, options: BooleanOptions = BooleanOptions()
    ) {
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        let paths = doc.selection.map(\.path).sorted { $0.lexicographicallyPrecedes($1) }
        guard paths.count >= 2 else { return }
        let parent = Array(paths[0].dropLast())
        guard paths.allSatisfy({ Array($0.dropLast()) == parent }) else { return }
        let elements = paths.map { doc.getElement($0) }
        let precision = options.precision

        // outputs: one (polygonSet, fill, stroke, common) tuple per fragment —
        // the same shape Rust's `apply_destructive_boolean_minting` builds.
        var outputs: [(BoolPolygonSet, Fill?, Stroke?, BooleanCommon)] = []
        switch opName {
        case "union", "intersection", "exclude":
            let sets = elements.map { elementToPolygonSet($0, precision: precision) }
            let op: CompoundOperation = opName == "union" ? .union
                : opName == "intersection" ? .intersection : .exclude
            let front = elements.last!
            // N → 1. THE REJECTED RULE IN DISGUISE lived on the other side of
            // this line in Rust (`front.common().clone()` — "the frontmost
            // source keeps the id", elected by z-order) and as a total DROP
            // here: this port passed no `id` at all, so a merge of identified
            // operands produced an identity-less product. Both are failures of
            // the same clause; identity is preservable exactly when the edit is
            // one-to-one (the cardinality law), so the product wears a MINTED
            // id, its paint from the frontmost, and everything else by
            // unanimity (EDIT_SEMANTICS_FREEZE.md §3.3, §3.6).
            var common = booleanMergedCommon(elements, front: front)
            // Identity is minted only when an identity is actually AT STAKE —
            // i.e. when some operand carried one. Identity in this app is LAZY
            // (VISION.md §6.2), so a merge of id-less operands kills nothing and
            // the product takes the fresh element's documented default, `nil`.
            // Rust's arm is guarded identically.
            if elements.contains(where: { $0.id != nil }) {
                var existing = doc.elementIds
                guard let minted = mintUniqueIds(1, existing: &existing,
                                                 mint: { generateElementId() })
                else {
                    // A failed mint aborts the whole edit — never a
                    // half-identified merge.
                    return
                }
                common.id = minted[0]
            }
            outputs.append((applyOperation(op, sets), front.fill, front.stroke,
                            common))
        case "subtract_front", "crop":
            let cutter = elementToPolygonSet(elements.last!, precision: precision)
            for survivor in elements.dropLast() {
                let sSet = elementToPolygonSet(survivor, precision: precision)
                let res = opName == "crop"
                    ? booleanIntersect(sSet, cutter)
                    : booleanSubtract(sSet, cutter)
                // 1 → 1: the survivor's identity LIVES (§3.6's survivor row).
                outputs.append((res, survivor.fill, survivor.stroke,
                                BooleanCommon(preserving: survivor)))
            }
        case "subtract_back":
            let cutter = elementToPolygonSet(elements.first!, precision: precision)
            for survivor in elements.dropFirst() {
                let sSet = elementToPolygonSet(survivor, precision: precision)
                outputs.append((booleanSubtract(sSet, cutter),
                                survivor.fill, survivor.stroke,
                                BooleanCommon(preserving: survivor)))
            }
        case "divide":
            // Walk operands back-to-front, maintaining a partition
            // of the union-so-far as (region, frontmost-covering
            // operand index) pairs. Each incoming operand splits
            // every existing region into overlap / non-overlap;
            // overlap relabels to the incoming index (now frontmost).
            let operandSets = elements.map { elementToPolygonSet($0, precision: precision) }
            var accumulator: [(BoolPolygonSet, Int)] = []
            for (i, opSet) in operandSets.enumerated() {
                var newAcc: [(BoolPolygonSet, Int)] = []
                var remaining = opSet
                for (existingRegion, existingIdx) in accumulator {
                    let overlap = booleanIntersect(existingRegion, opSet)
                    if !overlap.isEmpty { newAcc.append((overlap, i)) }
                    let nonOverlap = booleanSubtract(existingRegion, opSet)
                    if !nonOverlap.isEmpty { newAcc.append((nonOverlap, existingIdx)) }
                    remaining = booleanSubtract(remaining, existingRegion)
                }
                if !remaining.isEmpty { newAcc.append((remaining, i)) }
                accumulator = newAcc
            }
            for (region, paintIdx) in accumulator {
                // KNOWN OPEN, and identical in Rust
                // (`src.common().clone()` at the same arm): DIVIDE is 1 → N
                // per designated operand, so §3.6's DIVIDE row calls for a
                // FRESH mint per fragment. Both ports instead copy the
                // operand's whole common, which repeats its id across every
                // fragment it was cut into. Deliberately left port-identical
                // rather than fixed one-sidedly — the repair must land in both
                // ports in one commit, exactly as the transform-blind class is
                // scheduled to.
                let src = elements[paintIdx]
                outputs.append((region, src.fill, src.stroke,
                                BooleanCommon(preserving: src)))
            }
        case "trim", "merge":
            let operandSets = elements.map { elementToPolygonSet($0, precision: precision) }
            var trimmed: [(BoolPolygonSet, Fill?, Stroke?, BooleanCommon)] = []
            for i in 0..<elements.count {
                var region = operandSets[i]
                for later in operandSets[(i + 1)...] {
                    region = booleanSubtract(region, later)
                }
                if !region.isEmpty {
                    // TRIM is 1 → 1 per operand: full preservation.
                    trimmed.append((region, elements[i].fill, elements[i].stroke,
                                    BooleanCommon(preserving: elements[i])))
                }
            }
            if opName == "trim" {
                outputs.append(contentsOf: trimmed)
            } else {
                // MERGE: unify touching same-fill survivors. O(N^2)
                // pass; acceptable for panel-sized selections. The
                // frontmost contributor wins stroke / common props
                // on the merged output — KNOWN OPEN and identical in Rust:
                // a multi-contributor merge is N → 1, where §3.6 calls for a
                // fresh mint and unanimity, not a z-order winner. Same
                // both-ports-at-once repair as the DIVIDE row above.
                var consumed = [Bool](repeating: false, count: trimmed.count)
                for i in 0..<trimmed.count {
                    if consumed[i] { continue }
                    consumed[i] = true
                    var merged = trimmed[i].0
                    let fillI = trimmed[i].1
                    var strokeWinner = trimmed[i].2
                    var commonWinner = trimmed[i].3
                    if let fillI = fillI {
                        for j in (i + 1)..<trimmed.count {
                            if consumed[j] { continue }
                            if let fillJ = trimmed[j].1,
                               fillI.color == fillJ.color {
                                merged = booleanUnion(merged, trimmed[j].0)
                                // j > i in operand z-order, so j is frontmost.
                                strokeWinner = trimmed[j].2
                                commonWinner = trimmed[j].3
                                consumed[j] = true
                            }
                        }
                    }
                    outputs.append((merged, fillI, strokeWinner, commonWinner))
                }
            }
        default:
            return
        }

        // Flatten (rings, paint) outputs into elements; drop rings with
        // < 3 points. Optional per BooleanOptions:
        // - divide_remove_unpainted: drop unpainted DIVIDE fragments
        // - remove_redundant_points: collapse near-collinear points
        //
        // The sweep emits CANONICAL rings, which are read under the
        // even-odd rule (see Boolean.swift's carried-rule law). A result
        // like XOR of two overlapping rects is one outer ring plus an
        // inner ring cutting out the overlap — emitting each ring as its
        // own Polygon (which fills its own area independently) FILLS THE
        // HOLE. That was a live user-facing bug: Rust drew the donut and
        // Swift drew the disc. Single-ring results stay Polygons;
        // multi-ring results emit ONE Path with all rings as subpaths,
        // declaring boolResultFillRule, matching Rust's
        // apply_destructive_boolean ring for ring.
        //
        // PAINT. BOOLEAN.md §Operand and paint rules names four
        // properties as the paint the result carries — "fill, stroke,
        // opacity, blend mode" — from whichever operand that op's rule
        // designates (`paintSrc`). All four are passed below. `opacity`
        // used to be written as a literal 1.0 and `blendMode` was left
        // at its `.normal` default, so a half-transparent multiply
        // operand came out opaque and normal; Rust never had that gap
        // (its rebuild clones the paint source's CommonProps).
        //
        // NOT paint: `locked`, `mask` and the identity pair `name`/`id`, plus
        // the `toolOrigin` capability marker. These used to be written as a
        // literal `false` / dropped outright here while Rust cloned them, which
        // was the §3.5 row "Swift boolean rebuild, non-paint fields". They now
        // ride in `BooleanCommon`, whose value the ARM computed under the
        // cardinality law: full preservation on a 1→1 survivor (§3.1), fresh
        // mint + unanimity on an N→1 merge (§3.3).
        //
        // `fillGradient`/`strokeGradient` are still dropped by BOTH ports.
        // §3.6 flags carrying them as an AMENDMENT (it widens BOOLEAN.md's
        // ratified four-property paint list), so it waits on a ruling and is
        // not guessed here.
        var newElements: [Element] = []
        for (ps, fill, stroke, common) in outputs {
            if opName == "divide" && options.divideRemoveUnpainted
               && fill == nil && stroke == nil {
                continue
            }
            let kept: [BoolRing] = ps.map { ring in
                options.removeRedundantPoints
                    ? collapseCollinearPoints(ring, tolerance: options.precision)
                    : ring
            }.filter { $0.count >= 3 }
            if kept.isEmpty { continue }
            if kept.count == 1 {
                // A Polygon has no `toolOrigin` slot in this port; see
                // `BooleanCommon`'s note.
                newElements.append(.polygon(Polygon(
                    points: kept[0],
                    fill: fill,
                    stroke: stroke,
                    opacity: common.opacity,
                    transform: common.transform,
                    locked: common.locked,
                    visibility: common.visibility,
                    blendMode: common.blendMode,
                    mask: common.mask,
                    name: common.name,
                    id: common.id
                )))
            } else {
                var d: [PathCommand] = []
                for ring in kept {
                    d.append(.moveTo(ring[0].0, ring[0].1))
                    for p in ring[1...] { d.append(.lineTo(p.0, p.1)) }
                    d.append(.closePath)
                }
                newElements.append(.path(Path(
                    d: d,
                    fill: fill,
                    stroke: stroke,
                    opacity: common.opacity,
                    transform: common.transform,
                    locked: common.locked,
                    visibility: common.visibility,
                    blendMode: common.blendMode,
                    mask: common.mask,
                    toolOrigin: common.toolOrigin,
                    name: common.name,
                    id: common.id,
                    fillRule: FillRule(boolResultFillRule)
                )))
            }
        }

        var newDoc = doc
        for path in paths.reversed() {
            newDoc = newDoc.deleteElement(path)
        }
        let insertPath = paths[0]
        let layerIdx = insertPath[0]
        let childIdx = insertPath.count > 1 ? insertPath[1] : 0
        let layer = newDoc.layers[layerIdx]
        var newChildren = layer.children
        newChildren.insert(contentsOf: newElements, at: childIdx)
        // T4, THE BYSTANDER CLAUSE: the layer names no part of this edit; the
        // op only rebuilds it to reach its target, so every one of ITS fields
        // comes back unchanged. The inline
        // `Layer(name:children:opacity:transform:)` this replaced kept four of
        // eleven, silently erasing the layer's `id`, `locked`, `visibility`,
        // `blendMode`, `isolatedBlending`, `knockoutGroup` and `mask` on EVERY
        // boolean op — and an inline container rebuild is not a copy API, so no
        // per-copy-API battery would ever have been written for it (§4.1). Rust
        // never had the hole: `layers[i].children_mut()` mutates in place.
        let newLayer = layer.withChildren(newChildren)
        var newLayers = newDoc.layers
        newLayers[layerIdx] = newLayer
        var newSelection: Selection = []
        for i in 0..<newElements.count {
            newSelection.append(ElementSelection.all([layerIdx, childIdx + i]))
        }
        model.editDocument(newDoc.replacing(layers: newLayers, selection: newSelection))
    }

    /// Re-apply the last destructive or compound-creating boolean op
    /// to the current selection. [lastOp] is the 13-value enum from
    /// BOOLEAN.md §Repeat state: op names ending in _compound route
    /// to applyCompoundCreation; all others route to
    /// applyDestructiveBoolean. No-op when [lastOp] is nil or empty.
    public func applyRepeatBooleanOperation(
        _ lastOp: String?, options: BooleanOptions = BooleanOptions()
    ) {
        guard let op = lastOp, !op.isEmpty else { return }
        let suffix = "_compound"
        if op.hasSuffix(suffix) {
            let base = String(op.dropLast(suffix.count))
            applyCompoundCreation(base)
        } else {
            applyDestructiveBoolean(op, options: options)
        }
    }

    /// Build the document with `fill` applied to every selected element,
    /// WITHOUT committing it. Used by the undoable ``setSelectionFill(_:)``.
    /// Mirrors the Rust `Controller::fill_applied`.
    private func fillApplied(_ fill: Fill?) -> Document {
        var doc = model.document
        if doc.selection.isEmpty { return doc }
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            let newElem = withFill(elem, fill: fill)
            doc = doc.replaceElement(es.path, with: newElem)
        }
        return doc
    }

    /// Set the fill of every element in the current selection (undoable,
    /// self-bracketing via ``Model/editDocument(_:)``).
    public func setSelectionFill(_ fill: Fill?) {
        if model.document.selection.isEmpty { return }
        model.editDocument(fillApplied(fill))
    }

    /// Build the document with `stroke` applied to every selected element,
    /// WITHOUT committing it. Mirrors the Rust `Controller::stroke_applied`.
    private func strokeApplied(_ stroke: Stroke?) -> Document {
        var doc = model.document
        if doc.selection.isEmpty { return doc }
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            let newElem = withStroke(elem, stroke: stroke)
            doc = doc.replaceElement(es.path, with: newElem)
        }
        return doc
    }

    /// Set the stroke of every element in the current selection (undoable,
    /// self-bracketing).
    public func setSelectionStroke(_ stroke: Stroke?) {
        if model.document.selection.isEmpty { return }
        model.editDocument(strokeApplied(stroke))
    }

    /// Rewrite each selected element's stroke through `f`, which receives
    /// that element's OWN current stroke (`nil` when it has none).
    ///
    /// Unlike ``setSelectionStroke(_:)`` — which stamps one identical
    /// Stroke across the whole selection — this preserves the per-element
    /// fields `f` leaves alone, so a Stroke-panel edit to one attribute
    /// cannot carry the first element's width / colour onto its siblings.
    /// Used by `applyStrokePanelToSelection`. Mirrors the Rust
    /// `Controller::map_selection_stroke`.
    public func mapSelectionStroke(_ f: (Stroke?) -> Stroke?) {
        guard let doc = strokeMapped(f) else { return }
        model.editDocument(doc)
    }

    /// Live, NON-undoable ``mapSelectionStroke(_:)`` for per-tick
    /// colour-slider drag: undo is captured once on pointer-up by
    /// `setActiveColor`, so the drag must not push checkpoints.
    public func mapSelectionStrokeLive(_ f: (Stroke?) -> Stroke?) {
        guard let doc = strokeMapped(f) else { return }
        model.setDocumentUnbracketed(doc, intent: .liveDrag)
    }

    private func strokeMapped(_ f: (Stroke?) -> Stroke?) -> Document? {
        var doc = model.document
        if doc.selection.isEmpty { return nil }
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            let newElem = withStroke(elem, stroke: f(elem.stroke))
            doc = doc.replaceElement(es.path, with: newElem)
        }
        return doc
    }

    /// Rewrite each selected element's fill through `f`, which receives
    /// that element's OWN current fill (`nil` when it has none). The
    /// per-element counterpart of ``setSelectionFill(_:)``: preserves the
    /// fields `f` leaves alone (e.g. a colour pick must not reset each
    /// element's fill opacity). Mirrors Rust `map_selection_fill`.
    public func mapSelectionFill(_ f: (Fill?) -> Fill?) {
        guard let doc = fillMapped(f) else { return }
        model.editDocument(doc)
    }

    /// Live, NON-undoable ``mapSelectionFill(_:)`` for per-tick drag.
    public func mapSelectionFillLive(_ f: (Fill?) -> Fill?) {
        guard let doc = fillMapped(f) else { return }
        model.setDocumentUnbracketed(doc, intent: .liveDrag)
    }

    private func fillMapped(_ f: (Fill?) -> Fill?) -> Document? {
        var doc = model.document
        if doc.selection.isEmpty { return nil }
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            let newElem = withFill(elem, fill: f(elem.fill))
            doc = doc.replaceElement(es.path, with: newElem)
        }
        return doc
    }

    /// Swap the fill and stroke COLOURS — `workspace/actions.yaml`
    /// `swap_fill_stroke` (Shift+X, the fill/stroke widget arrow, the
    /// Color-panel button).
    ///
    /// Colour-only: each side keeps every one of its own non-colour
    /// attributes (width / cap / join / dash / arrowheads / align / miter,
    /// and each opacity) and takes only the other's colour. It used to build
    /// a bare `Stroke(color:)` / `Fill(color:)` and stamp it over the
    /// selection, so the arrow reset a 5pt dashed arrowheaded line.
    ///
    /// The two colours are sourced from the tab DEFAULTS, which is also what
    /// decides `nil` (no fill / no stroke swaps too). Sourcing them from the
    /// selection instead — which one of the two Swift call sites did — is
    /// wrong per element: a Line holds no fill, so a per-element swap would
    /// hand its stroke a nil colour and swap the stroke away to nothing.
    /// Mirrors the Rust `AppState::swap_fill_stroke` (app_state.rs), which
    /// this is the single Swift statement of: both view call sites route
    /// here rather than each holding a copy of the law.
    public func swapFillStrokeColors() {
        let oldFill = model.defaultFill
        let oldStroke = model.defaultStroke
        let fillColor = oldFill?.color
        let strokeColor = oldStroke?.color
        model.defaultFill = strokeColor.map { ColorPanel.recolorFill(oldFill, $0) }
        model.defaultStroke = fillColor.map { ColorPanel.recolorStroke(oldStroke, $0) }
        guard !model.document.selection.isEmpty else { return }
        // Fill + stroke swap as ONE undo step: withTxn opens the bracket,
        // each mapSelection* (editDocument) joins it. Each mapper hands the
        // element its OWN fill / stroke, so recolouring preserves the rest.
        model.withTxn {
            self.mapSelectionFill { f in strokeColor.map { ColorPanel.recolorFill(f, $0) } }
            self.mapSelectionStroke { s in fillColor.map { ColorPanel.recolorStroke(s, $0) } }
        }
    }

    /// Set strokeBrush on every selected element (paths only). Used
    /// by apply_brush_to_selection / remove_brush_from_selection.
    public func setSelectionStrokeBrush(_ slug: String?) {
        var doc = model.document
        if doc.selection.isEmpty { return }
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            let newElem = withStrokeBrush(elem, strokeBrush: slug)
            doc = doc.replaceElement(es.path, with: newElem)
        }
        model.editDocument(doc)
    }

    /// Set strokeBrushOverrides on every selected element (paths only).
    public func setSelectionStrokeBrushOverrides(_ overrides: String?) {
        var doc = model.document
        if doc.selection.isEmpty { return }
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            let newElem = withStrokeBrushOverrides(elem, overrides: overrides)
            doc = doc.replaceElement(es.path, with: newElem)
        }
        model.editDocument(doc)
    }

    /// Set the fillGradient of every element in the current selection.
    /// Phase 5 — pass `nil` to demote (clear gradient; existing solid
    /// fill remains).
    public func setSelectionFillGradient(_ gradient: Gradient?) {
        var doc = model.document
        if doc.selection.isEmpty { return }
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            let newElem = withFillGradient(elem, fillGradient: gradient)
            doc = doc.replaceElement(es.path, with: newElem)
        }
        model.editDocument(doc)
    }

    /// Set the strokeGradient of every element in the current selection.
    public func setSelectionStrokeGradient(_ gradient: Gradient?) {
        var doc = model.document
        if doc.selection.isEmpty { return }
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            let newElem = withStrokeGradient(elem, strokeGradient: gradient)
            doc = doc.replaceElement(es.path, with: newElem)
        }
        model.editDocument(doc)
    }

    // ── Opacity mask lifecycle (OPACITY.md § States) ───────────

    /// Create an opacity mask on every selected element that does not
    /// already have one. The subtree starts as an empty ``Group``;
    /// users populate it via the MASK_PREVIEW click (Phase 4).
    /// ``clip`` and ``invert`` come from the document preferences
    /// ``new_masks_clipping`` / ``new_masks_inverted``.
    public func makeMaskOnSelection(clip: Bool, invert: Bool) {
        var doc = model.document
        if doc.selection.isEmpty { return }
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            if elem.mask != nil { continue }
            let m = Mask(
                subtreeElement: .group(Group(children: [])),
                clip: clip,
                invert: invert,
                disabled: false,
                linked: true,
                unlinkTransform: nil
            )
            doc = doc.replaceElement(es.path, with: withMask(elem, mask: m))
        }
        model.editDocument(doc)
    }

    /// Remove the opacity mask from every selected element.
    public func releaseMaskOnSelection() {
        var doc = model.document
        if doc.selection.isEmpty { return }
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            if elem.mask == nil { continue }
            doc = doc.replaceElement(es.path, with: withMask(elem, mask: nil))
        }
        model.editDocument(doc)
    }

    /// Set `mask.clip` on every selected element that has a mask.
    public func setMaskClipOnSelection(_ clip: Bool) {
        updateMaskOnSelection { old in
            Mask(subtreeElement: old.subtreeElement,
                 clip: clip, invert: old.invert,
                 disabled: old.disabled, linked: old.linked,
                 unlinkTransform: old.unlinkTransform)
        }
    }

    /// Set `mask.invert` on every selected element that has a mask.
    public func setMaskInvertOnSelection(_ invert: Bool) {
        updateMaskOnSelection { old in
            Mask(subtreeElement: old.subtreeElement,
                 clip: old.clip, invert: invert,
                 disabled: old.disabled, linked: old.linked,
                 unlinkTransform: old.unlinkTransform)
        }
    }

    /// Toggle `mask.disabled` on every selected mask, driven by the
    /// first selected element's current state.
    public func toggleMaskDisabledOnSelection() {
        guard let current = firstMask(model.document)?.disabled else { return }
        let newState = !current
        updateMaskOnSelection { old in
            Mask(subtreeElement: old.subtreeElement,
                 clip: old.clip, invert: old.invert,
                 disabled: newState, linked: old.linked,
                 unlinkTransform: old.unlinkTransform)
        }
    }

    /// Toggle `mask.linked` on every selected mask. On unlink, captures
    /// each element's current transform into `unlink_transform`. On
    /// relink, clears `unlink_transform`.
    public func toggleMaskLinkedOnSelection() {
        guard let currentLinked = firstMask(model.document)?.linked else { return }
        let newLinked = !currentLinked
        var doc = model.document
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            guard let old = elem.mask else { continue }
            let newMask = Mask(
                subtreeElement: old.subtreeElement,
                clip: old.clip, invert: old.invert,
                disabled: old.disabled,
                linked: newLinked,
                unlinkTransform: newLinked ? nil : elem.transform
            )
            doc = doc.replaceElement(es.path, with: withMask(elem, mask: newMask))
        }
        model.editDocument(doc)
    }

    /// Internal helper: apply `transform` to every selected element's
    /// mask. Elements without a mask are skipped.
    private func updateMaskOnSelection(_ transform: (Mask) -> Mask) {
        var doc = model.document
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            guard let old = elem.mask else { continue }
            doc = doc.replaceElement(es.path, with: withMask(elem, mask: transform(old)))
        }
        model.editDocument(doc)
    }

    /// Write Character-panel text attributes to every `Text` /
    /// `TextPath` element in the current selection. Non-text elements
    /// in the selection are left alone. Fields not present in `attrs`
    /// preserve their current value on each element. Mirrors the Rust
    /// `apply_character_panel_to_selection` pipeline.
    ///
    /// Recognised keys (mostly string): `font_family`, `font_size`
    /// (number), `font_weight`, `font_style`, `text_decoration`,
    /// `text_transform`, `font_variant`, `baseline_shift`,
    /// `line_height`, `letter_spacing`, `xml_lang`, `aa_mode`,
    /// `rotate`, `horizontal_scale`, `vertical_scale`, `kerning`.
    /// Unknown keys are silently ignored.
    public func setSelectionTextAttributes(_ attrs: [String: Any]) {
        setSelectionTextAttributes(perElement: { _ in attrs })
    }

    /// Apply a PER-ELEMENT character-attribute dict to every selected Text /
    /// TextPath. `build` receives each element, so a field-scoped
    /// Character-panel apply can derive its values from THAT element — the
    /// Leading group's Auto test reads the element's own font size, which one
    /// shared dict cannot express across a mixed selection. Keys the dict
    /// omits are left untouched on the element.
    public func setSelectionTextAttributes(
        perElement build: (Element) -> [String: Any]
    ) {
        var doc = model.document
        if doc.selection.isEmpty { return }
        var changed = false
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            let attrs = build(elem)
            let newElem: Element
            switch elem {
            case .text(let t):
                newElem = .text(Self.applyTextAttrs(t, attrs: attrs))
            case .textPath(let tp):
                newElem = .textPath(Self.applyTextPathAttrs(tp, attrs: attrs))
            default:
                continue
            }
            doc = doc.replaceElement(es.path, with: newElem)
            changed = true
        }
        // Nothing in the selection was text, so there is no edit — and an
        // edit that changes nothing must not become an undo step. Matches
        // the Rust apply's `if changed` guard.
        if changed { model.editDocument(doc) }
    }

    /// Apply a character-attribute dict onto a single `Text`, returning
    /// a new value with only the overlapping keys replaced.
    ///
    /// CLONE-THEN-MUTATE, and it must stay that way. This was an open-coded
    /// rebuild naming 27 of `Text`'s 31 stored properties, so every
    /// Character-panel apply silently destroyed the element's `name`, `id`,
    /// `blendMode` and `mask` — the Swift copy-site omission class
    /// (EDIT_SEMANTICS_FREEZE.md §3.1). The `id` loss is a direct violation of
    /// the Preservation Law: setting a font does not speak to a text element's
    /// identity. Rust's twin
    /// (`app_state.rs::apply_character_panel_to_selection`) is
    /// `let mut new_t = t.clone(); set_character_attrs!(new_t, attrs);` and
    /// always conformed, so the rebuild was also a live port divergence.
    ///
    /// Do NOT repair this shape by adding the four missing arguments — that
    /// is the repair that has failed twice in this class, because the next new
    /// field lands right back in the same place. With `var out = t` there is
    /// no field list left to fall behind. Gated by
    /// `CopySiteOmissionTests.characterApplyKeepsTextIdentityAndPaint` and
    /// structurally by `scripts/check_swift_copy_sites.py`.
    private static func applyTextAttrs(_ t: Text, attrs: [String: Any]) -> Text {
        var out = t
        out.fontFamily = (attrs["font_family"] as? String) ?? t.fontFamily
        out.fontSize = (attrs["font_size"] as? NSNumber)?.doubleValue ?? t.fontSize
        out.fontWeight = (attrs["font_weight"] as? String) ?? t.fontWeight
        out.fontStyle = (attrs["font_style"] as? String) ?? t.fontStyle
        out.textDecoration = (attrs["text_decoration"] as? String) ?? t.textDecoration
        out.textTransform = (attrs["text_transform"] as? String) ?? t.textTransform
        out.fontVariant = (attrs["font_variant"] as? String) ?? t.fontVariant
        out.baselineShift = (attrs["baseline_shift"] as? String) ?? t.baselineShift
        out.lineHeight = (attrs["line_height"] as? String) ?? t.lineHeight
        out.letterSpacing = (attrs["letter_spacing"] as? String) ?? t.letterSpacing
        out.xmlLang = (attrs["xml_lang"] as? String) ?? t.xmlLang
        out.aaMode = (attrs["aa_mode"] as? String) ?? t.aaMode
        out.rotate = (attrs["rotate"] as? String) ?? t.rotate
        out.horizontalScale = (attrs["horizontal_scale"] as? String) ?? t.horizontalScale
        out.verticalScale = (attrs["vertical_scale"] as? String) ?? t.verticalScale
        out.kerning = (attrs["kerning"] as? String) ?? t.kerning
        return out
    }

    /// Apply a character-attribute dict onto a single `TextPath`,
    /// returning a new value with overlapping keys replaced.
    ///
    /// Same clause and same repair as ``applyTextAttrs(_:attrs:)`` — see its
    /// note. The rebuild this replaced named 25 of `TextPath`'s 29 stored
    /// properties and lost the identical four.
    private static func applyTextPathAttrs(_ tp: TextPath, attrs: [String: Any]) -> TextPath {
        var out = tp
        out.fontFamily = (attrs["font_family"] as? String) ?? tp.fontFamily
        out.fontSize = (attrs["font_size"] as? NSNumber)?.doubleValue ?? tp.fontSize
        out.fontWeight = (attrs["font_weight"] as? String) ?? tp.fontWeight
        out.fontStyle = (attrs["font_style"] as? String) ?? tp.fontStyle
        out.textDecoration = (attrs["text_decoration"] as? String) ?? tp.textDecoration
        out.textTransform = (attrs["text_transform"] as? String) ?? tp.textTransform
        out.fontVariant = (attrs["font_variant"] as? String) ?? tp.fontVariant
        out.baselineShift = (attrs["baseline_shift"] as? String) ?? tp.baselineShift
        out.lineHeight = (attrs["line_height"] as? String) ?? tp.lineHeight
        out.letterSpacing = (attrs["letter_spacing"] as? String) ?? tp.letterSpacing
        out.xmlLang = (attrs["xml_lang"] as? String) ?? tp.xmlLang
        out.aaMode = (attrs["aa_mode"] as? String) ?? tp.aaMode
        out.rotate = (attrs["rotate"] as? String) ?? tp.rotate
        out.horizontalScale = (attrs["horizontal_scale"] as? String) ?? tp.horizontalScale
        out.verticalScale = (attrs["vertical_scale"] as? String) ?? tp.verticalScale
        out.kerning = (attrs["kerning"] as? String) ?? tp.kerning
        return out
    }

    public func setSelectionWidthProfile(_ widthPoints: [StrokeWidthPoint]) {
        var doc = model.document
        if doc.selection.isEmpty { return }
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            let newElem = withWidthPoints(elem, widthPoints: widthPoints)
            doc = doc.replaceElement(es.path, with: newElem)
        }
        model.editDocument(doc)
    }

    public func copySelection(dx: Double, dy: Double) {
        var doc = model.document
        var newSelection: Selection = []
        // Sort paths in reverse so insertions don't shift earlier paths
        let sortedSels = doc.selection.sorted { $0.path.lexicographicallyPrecedes($1.path) }.reversed()
        for es in sortedSels {
            let elem = doc.getElement(es.path)
            // A copy must not inherit the source's stable id (no two
            // elements may share an identity); it is born id-less.
            let copied = elem.moveControlPoints(es.kind, dx: dx, dy: dy).clearingIds()
            doc = doc.insertElementAfter(es.path, element: copied)
            var copyPath = es.path
            copyPath[copyPath.count - 1] += 1
            // Copying always selects the new element as a whole.
            newSelection.append(ElementSelection.all(copyPath))
        }
        model.editDocument(doc.replacing(selection: newSelection))
    }
}

/// Resolve the current selection to the stable `common.id`s of the selected
/// elements, in document order (OP_LOG.md §9 / Fork 4: the `targets` of a
/// journaled op). Id-less selected elements are silently dropped (`id` is
/// optional; a recorded source must carry an id — a documented prerequisite,
/// not a bug). Sorting by path makes the order deterministic and cross-language
/// stable even though Swift's `Selection` is a `Set`. One definition reused by
/// the production `OpApply` path and the `#if DEBUG` harness so both populate
/// `targets` identically. Mirrors Rust `controller::selection_to_ids`.
public func selectionToIds(_ doc: Document) -> [String] {
    doc.selection
        .sorted { $0.path.lexicographicallyPrecedes($1.path) }
        .compactMap { doc.tryGetElement($0.path)?.id }
}

// MARK: - Fill / Stroke summary

public enum FillSummary: Equatable {
    case noSelection
    case uniform(Fill?)
    case mixed
}

public enum StrokeSummary: Equatable {
    case noSelection
    case uniform(Stroke?)
    case mixed
}

/// Summarize the fill of all selected elements.
public func selectionFillSummary(_ doc: Document) -> FillSummary {
    let sel = doc.selection
    guard !sel.isEmpty else { return .noSelection }
    var first = true
    var value: Fill? = nil
    for es in sel {
        let elem = doc.getElement(es.path)
        // Skip groups/layers -- they have no fill.
        if case .group = elem { continue }
        if case .layer = elem { continue }
        let f = elem.fill
        if first {
            value = f
            first = false
        } else if f != value {
            return .mixed
        }
    }
    if first { return .noSelection }
    return .uniform(value)
}

/// Summarize the stroke of all selected elements.
public func selectionStrokeSummary(_ doc: Document) -> StrokeSummary {
    let sel = doc.selection
    guard !sel.isEmpty else { return .noSelection }
    var first = true
    var value: Stroke? = nil
    for es in sel {
        let elem = doc.getElement(es.path)
        if case .group = elem { continue }
        if case .layer = elem { continue }
        let s = elem.stroke
        if first {
            value = s
            first = false
        } else if s != value {
            return .mixed
        }
    }
    if first { return .noSelection }
    return .uniform(value)
}

/// Find the first id-bearing element named `id`, searching `doc.symbols`
/// (sorted-by-id for determinism, matching every order-dependent symbols site)
/// then `doc.layers` in pre-order. A pure lookup — no entropy — used by
/// ``Controller/detach(_:)`` to resolve an instance's target across both the
/// off-canvas master store and the canvas tree (SYMBOLS.md §7). Returns an
/// owned copy so callers can mutate it independently. Mirrors Rust
/// `find_element_by_id`.
private func findElementById(_ doc: Document, _ id: String) -> Element? {
    func walk(_ elem: Element) -> Element? {
        if elem.id == id { return elem }
        // Recurse into Group / Layer children only, mirroring the reference's
        // `Element::children` (None for every leaf and Live kind).
        switch elem {
        case .group(let g):
            for child in g.children {
                if let found = walk(child) { return found }
            }
        case .layer(let l):
            for child in l.children {
                if let found = walk(child) { return found }
            }
        default:
            break
        }
        return nil
    }
    // Symbols first, in sorted-by-id order (the §2 deterministic-order rule).
    let sortedMasters = doc.symbols.sorted { ($0.id ?? "") < ($1.id ?? "") }
    for master in sortedMasters {
        if let found = walk(master) { return found }
    }
    // Then the layer tree.
    for layer in doc.layers {
        if let found = walk(.layer(layer)) { return found }
    }
    return nil
}
