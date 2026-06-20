"""Document controller (MVC pattern).

The Controller provides mutation operations on the Model's document.
Since the Document is immutable, mutations produce a new Document
that replaces the old one in the Model.
"""

from collections.abc import Callable
import dataclasses
from dataclasses import dataclass, replace

from document.document import (
    Document, ElementPath, ElementSelection, Selection,
    SelectionKind, _SelectionAll, _SelectionPartial,
    selection_all, selection_partial,
)
from geometry.element import (
    ClosePath, Element, Fill, Gradient, Group, Layer, LineTo, Mask, MoveTo,
    Path, PathCommand, Polygon, Stroke, StrokeWidthPoint, Transform, Visibility,
    clear_ids, control_point_count, control_points, move_control_points,
    move_path_handle as _move_path_handle,
    with_fill as _with_fill, with_stroke as _with_stroke,
    with_fill_gradient as _with_fill_gradient,
    with_stroke_gradient as _with_stroke_gradient,
    with_stroke_brush as _with_stroke_brush,
    with_stroke_brush_overrides as _with_stroke_brush_overrides,
    with_width_points as _with_width_points,
    with_mask as _with_mask,
    element_fill as _element_fill, element_stroke as _element_stroke,
)
from algorithms.hit_test import (
    element_intersects_rect, point_in_rect,
)
from document.model import Model


# ── Opacity-mask helpers (OPACITY.md § States) ───────────────

def first_mask(document) -> Mask | None:
    """Return the mask on the first selected element, if any. Drives
    the first-element-wins toggles in the Opacity panel (disable,
    unlink, and the MAKE_MASK_BUTTON label flip).
    """
    if not document.selection:
        return None
    # Selection is a frozenset; pick a deterministic "first" by path.
    first = min(document.selection, key=lambda es: es.path)
    try:
        return document.get_element(first.path).mask
    except Exception:
        return None


def selection_has_mask(document) -> bool:
    """True when every selected element has an opacity mask attached.
    Mixed selections (some masked, some not) count as "no mask" per
    OPACITY.md § States.
    """
    if not document.selection:
        return False
    for es in document.selection:
        try:
            if document.get_element(es.path).mask is None:
                return False
        except Exception:
            return False
    return True


# ── Symbols helpers (SYMBOLS.md §7) ──────────────────────────

def _find_element_by_id(document, id: str) -> Element | None:
    """Find the first id-bearing element named ``id``, searching
    ``document.symbols`` (sorted-by-id for determinism, matching every
    order-dependent symbols site) then ``document.layers`` in pre-order. A
    pure lookup — no entropy — used by ``Controller.detach`` to resolve an
    instance's target across both the off-canvas master store and the canvas
    tree (SYMBOLS.md §7). Returns the element it finds (frozen dataclasses are
    immutable, so callers copy via ``dataclasses.replace``). Mirrors the Rust
    ``find_element_by_id``.
    """
    def walk(elem: Element) -> Element | None:
        if getattr(elem, "id", None) == id:
            return elem
        if isinstance(elem, Group):  # Group/Layer carry children
            for child in elem.children:
                found = walk(child)
                if found is not None:
                    return found
        return None

    # Symbols first, in sorted-by-id order (the §2 deterministic-order rule).
    sorted_masters = sorted(
        document.symbols, key=lambda m: getattr(m, "id", None) or "")
    for master in sorted_masters:
        found = walk(master)
        if found is not None:
            return found
    # Then the layer tree.
    for layer in document.layers:
        found = walk(layer)
        if found is not None:
            return found
    return None


def selection_to_ids(doc: Document) -> list[str]:
    """Resolve the current selection to the stable ``id``s of the selected
    elements, in document order (OP_LOG.md §9 / Fork 4: the ``targets`` of a
    journaled op). Id-less selected elements are silently dropped (a recorded
    source must carry an id — a documented prerequisite, not a bug).

    The selection is a path-keyed ``frozenset`` here, so paths are sorted to
    give a deterministic document order (matching the Rust selection-order
    iteration, which for any real recorded source is single-element). One
    definition reused by the production ``op_apply`` path and the harness so
    both populate ``targets`` identically. Mirrors the Rust
    ``controller::selection_to_ids``.
    """
    out: list[str] = []
    for es in sorted(doc.selection, key=lambda e: e.path):
        try:
            elem = doc.get_element(es.path)
        except Exception:
            continue
        eid = getattr(elem, "id", None)
        if eid is not None:
            out.append(eid)
    return out


class Controller:
    """Mediates between user actions and the document model."""

    def __init__(self, model: Model = None):
        self._model = model or Model()

    @property
    def model(self) -> Model:
        return self._model

    @property
    def document(self) -> Document:
        return self._model.document

    def set_document(self, document: Document) -> None:
        """Replace the entire document — the general undoable mutator used by
        tool/effect handlers (they wrap an action in begin_txn/with_txn, so this
        joins that transaction; standalone it self-brackets). Routes through
        ``edit_document`` (OP_LOG.md Increment 1). Selection-only writes use the
        ``select_*`` / ``set_selection`` methods (non-undoable)."""
        self._model.edit_document(document)

    def set_filename(self, filename: str) -> None:
        """Update the filename."""
        self._model.filename = filename

    def add_layer(self, layer: Layer) -> None:
        """Append a layer to the document."""
        self._model.edit_document(replace(
            self._model.document,
            layers=self._model.document.layers + (layer,),
        ))

    def remove_layer(self, index: int) -> None:
        """Remove the layer at the given index."""
        layers = list(self._model.document.layers)
        del layers[index]
        self._model.edit_document(replace(
            self._model.document, layers=tuple(layers),
        ))

    def add_element(self, element: Element) -> None:
        """Append ``element`` to the current editing target and
        select the new element. In content-mode (the default), the
        element is appended to the selected layer. In mask-editing
        mode (OPACITY.md §Preview interactions) the element is
        appended to the masked element's mask subtree instead —
        mask-mode falls back to the layer path when the mask
        subtree isn't a Group (shouldn't happen with masks created
        via ``make_mask_on_selection``, but protects against
        externally-built masks).
        """
        # Mask-mode: append to the mask subtree and bail on success.
        # On any "can't route here" failure we fall through to the
        # content path so the user's stroke isn't lost.
        target = getattr(self._model, "editing_target", None)
        if target is not None and target.is_mask:
            if self._add_element_to_mask(element, target.mask_path):
                return
        doc = self._model.document
        idx = doc.selected_layer
        layer = doc.layers[idx]
        child_idx = len(layer.children)
        new_layer = replace(layer, children=layer.children + (element,))
        new_layers = doc.layers[:idx] + (new_layer,) + doc.layers[idx + 1:]
        es = ElementSelection.all((idx, child_idx))
        self._model.edit_document(replace(doc, layers=new_layers,
                                       selection=frozenset({es})))

    def assign_id(self, path: ElementPath, id: str) -> None:
        """Stamp a stable ``id`` onto the element at ``path`` — the lazy
        assign-on-create primitive (REFERENCE_GRAPH.md §4). The id is
        minted by the initiator and carried in the operation payload,
        never minted here, so every app applies the identical value. A
        no-op when the path is invalid. The caller owns identity: this
        overwrites any existing id (re-identification is the initiator's
        responsibility; reference remapping arrives with the graph).

        Mirrors ``add_element``: produces a new document and sets it
        directly, with no internal snapshot.
        """
        doc = self._model.document
        try:
            elem = doc.get_element(path)
        except (ValueError, IndexError, KeyError):
            return
        new_elem = replace(elem, id=id)
        self._model.edit_document(doc.replace_element(path, new_elem))

    def create_reference(self, target_path: ElementPath, target_id: str,
                         ref_id: str) -> None:
        """Create a by-id reference to the element at ``target_path``
        (REFERENCE_GRAPH.md §4). Assign-on-create: stamp ``target_id``
        onto the target *iff* it has no id yet (the lazy-mint trigger);
        if it already has one, that id names the edge and ``target_id``
        is ignored. A new ``ReferenceElem`` (its own id = ``ref_id``) is
        then appended via the regular ``add_element`` path. Both ids are
        minted by the initiator and carried in the op payload — never
        minted here — so every app applies identical values. No-op on an
        invalid path. Mirrors the Rust ``Controller::create_reference``.
        """
        from geometry.element import ReferenceElem
        doc = self._model.document
        try:
            target = doc.get_element(target_path)
        except (ValueError, IndexError, KeyError):
            return
        if target.id is not None:
            resolved_id = target.id
        else:
            resolved_id = target_id
            self._model.edit_document(doc.replace_element(
                target_path, replace(target, id=target_id)))
        reference = ReferenceElem(target=resolved_id, id=ref_id)
        self.add_element(reference)

    # ── Symbols P2 — operations (SYMBOLS.md §7) ──────────────────
    # Value-in-op: every id is minted by the initiator/UI and carried in the
    # op payload, never minted inside the Controller (same rule as
    # create_reference / assign_id), so all apps apply identical values. Each
    # produces a new document and sets it directly — no internal snapshot;
    # the caller owns undo.

    def make_symbol(self, path: ElementPath, master_id: str,
                    ref_id: str) -> None:
        """Make Symbol (promote): move the element at ``path`` into
        ``doc.symbols`` as a master and leave a ``ReferenceElem`` instance in
        its place (SYMBOLS.md §7, Fork S6 — the dual of Detach).
        Assign-on-create: if the element already has an ``id``, that id is KEPT
        as the master key and ``master_id`` is ignored (mirrors
        create_reference's target rule); otherwise ``master_id`` is stamped.
        The instance carries ``id = ref_id`` and targets the master id. Net:
        the master lives off-canvas in ``symbols``, an instance sits where the
        element was, so the canvas looks unchanged (the instance resolves to
        the master geometry). No-op on an invalid path. Mirrors the Rust
        ``Controller::make_symbol``.
        """
        from geometry.element import ReferenceElem
        doc = self._model.document
        try:
            target = doc.get_element(path)
        except (ValueError, IndexError, KeyError):
            return
        # Resolve the master id: keep the element's own id if it has one,
        # else stamp the carried master_id (assign-on-create).
        resolved_id = target.id if target.id is not None else master_id
        # The master carries the resolved id.
        master = replace(target, id=resolved_id)
        # The in-place instance targets the master id, with its own ref_id.
        reference = ReferenceElem(target=resolved_id, id=ref_id)
        # Replace the element in place with the instance, then push the master
        # into the off-canvas store.
        new_doc = doc.replace_element(path, reference)
        self._model.edit_document(replace(
            new_doc, symbols=new_doc.symbols + (master,)))

    def place_instance(self, master_id: str, ref_id: str) -> None:
        """Place Instance: append a ``ReferenceElem`` targeting an existing
        master (``master_id``) to the active layer via ``add_element`` (which
        auto-selects it) — exactly like create_reference's final step
        (SYMBOLS.md §7). No offset: placement offset is a UI concern. It is
        fine if ``master_id`` does not currently exist; the instance simply
        renders empty until the master appears (dangling is already handled by
        the resolver). The instance carries ``id = ref_id``, minted by the
        initiator. Mirrors the Rust ``Controller::place_instance``.
        """
        from geometry.element import ReferenceElem
        self.add_element(ReferenceElem(target=master_id, id=ref_id))

    def place_concept_instance(
        self, concept_id: str, params: dict, elem_id: str
    ) -> None:
        """Place a generated instance of ``concept_id`` (with the given default
        ``params``) on the active layer via ``add_element`` (auto-selects). The
        element carries ``id = elem_id``, minted by the initiator. Mirrors the
        Rust ``Controller::place_concept_instance``.
        """
        from geometry.element import GeneratedElem
        self.add_element(
            GeneratedElem(concept_id=concept_id, params=params, id=elem_id)
        )

    def detach(self, path: ElementPath) -> None:
        """Detach (break the link / expand): replace the ``ReferenceElem``
        instance at ``path`` with an INDEPENDENT copy of its resolved target
        (SYMBOLS.md §7, Fork S6 — the inverse of Make Symbol). The target id is
        resolved by a pure lookup over ALL id-bearing elements
        (``doc.symbols`` AND ``layers``; deterministic, no entropy). The copy
        is born id-less (``clear_ids``, per the duplication rule) and the
        instance's own overrides are applied onto it: its ``transform`` (set,
        or compose if the copy already has one) and its paint (``fill`` /
        ``stroke`` applied only when not None). The master and every other
        instance are untouched, and nothing is minted. No-op when the path is
        invalid, not a reference, or the target is unresolvable. Mirrors the
        Rust ``Controller::detach``.
        """
        from geometry.element import ReferenceElem
        doc = self._model.document
        try:
            elem = doc.get_element(path)
        except (ValueError, IndexError, KeyError):
            return
        # Must be a reference instance.
        if not isinstance(elem, ReferenceElem):
            return
        # Resolve the target id over symbols + layers (a pure id->element map).
        target = _find_element_by_id(doc, elem.target)
        if target is None:
            return

        # Independent copy of the resolved target, born id-less.
        copy = clear_ids(target)

        # Apply the instance's transform overrides. The render composition is
        # transform (CTM) ∘ instance_transform (Symbols P4 / Fork F2); detach
        # must fold BOTH onto the copy so neither is dropped. Build the
        # instance-side transform first (CTM ∘ instance field), then compose
        # onto any transform the copy already carries.
        if elem.transform is not None and elem.instance_transform is not None:
            inst_combined = elem.transform.multiply(elem.instance_transform)
        elif elem.transform is not None:
            inst_combined = elem.transform
        else:
            inst_combined = elem.instance_transform
        if inst_combined is not None:
            copy_t = getattr(copy, "transform", None)
            composed = inst_combined.multiply(copy_t) \
                if copy_t is not None else inst_combined
            copy = replace(copy, transform=composed)
        # Apply the instance's paint overrides (only when not None).
        if elem.fill is not None:
            copy = _with_fill(copy, elem.fill)
        if elem.stroke is not None:
            copy = _with_stroke(copy, elem.stroke)

        self._model.edit_document(doc.replace_element(path, copy))

    def set_instance_transform(self, path: ElementPath,
                               transform: Transform) -> None:
        """Set the instance transform of the ``ReferenceElem`` at ``path``
        (Symbols P4, SYMBOLS.md §4 / Fork F2). Value-in-op: the ``transform``
        is carried in the payload (not minted), letting an instance be mirrored
        / scaled relative to its master. This is the instance transform,
        distinct from the render CTM (``transform`` / common.transform); the
        render composition is CTM ∘ instance transform. No-op when ``path`` is
        invalid or the element there is not a reference. Mirrors the Rust
        ``Controller::set_instance_transform``.
        """
        from geometry.element import ReferenceElem
        doc = self._model.document
        try:
            elem = doc.get_element(path)
        except (ValueError, IndexError, KeyError):
            return
        if not isinstance(elem, ReferenceElem):
            return
        # Rebuild the reference with the instance transform set, preserving the
        # target, paint overrides, and the render CTM.
        new_elem = replace(elem, instance_transform=transform)
        self._model.edit_document(doc.replace_element(path, new_elem))

    def redefine(self, master_id: str, path: ElementPath,
                 ref_id: str) -> None:
        """Redefine: replace the master with id ``master_id`` in
        ``doc.symbols`` with a clone of the element at ``path`` (re-id the
        clone to ``master_id``), then replace the element at ``path`` in place
        with a ``ReferenceElem`` instance (``id = ref_id``, targeting
        ``master_id``) — the selection becomes an instance of the redefined
        master (SYMBOLS.md §7, Fork S2). All other instances of ``master_id``
        re-resolve to the new definition on the next paint. No-op when
        ``master_id`` is not in ``symbols`` or ``path`` is invalid. Mirrors the
        Rust ``Controller::redefine``.
        """
        from geometry.element import ReferenceElem
        doc = self._model.document
        # The master must already exist.
        master_idx = next(
            (i for i, m in enumerate(doc.symbols)
             if getattr(m, "id", None) == master_id),
            None)
        if master_idx is None:
            return
        try:
            source = doc.get_element(path)
        except (ValueError, IndexError, KeyError):
            return

        # New master = clone of the selection, re-id'd to master_id.
        new_master = replace(source, id=master_id)
        # The selection becomes an instance of the redefined master.
        reference = ReferenceElem(target=master_id, id=ref_id)
        new_doc = doc.replace_element(path, reference)
        new_symbols = (new_doc.symbols[:master_idx] + (new_master,)
                       + new_doc.symbols[master_idx + 1:])
        self._model.edit_document(replace(new_doc, symbols=new_symbols))

    def delete_symbol(self, master_id: str) -> None:
        """Delete Symbol: remove the master whose ``id == master_id`` from
        ``doc.symbols`` (SYMBOLS.md §7). No-op when no master carries that id.
        The instances (``ReferenceElem``s targeting ``master_id``) are left
        untouched — they simply become dangling and resolve to empty until the
        master returns (recoverable via undo, since the caller owns the
        snapshot). The Symbols-panel confirm-before-delete warning is a UI
        concern, not part of this op. Mirrors the Rust
        ``Controller::delete_symbol``.
        """
        doc = self._model.document
        idx = next(
            (i for i, m in enumerate(doc.symbols)
             if getattr(m, "id", None) == master_id),
            None)
        if idx is None:
            return
        new_symbols = doc.symbols[:idx] + doc.symbols[idx + 1:]
        self._model.edit_document(replace(doc, symbols=new_symbols))

    def _add_element_to_mask(self, element: Element,
                              path: tuple[int, ...]) -> bool:
        """Append ``element`` to the mask subtree of the element at
        ``path``. Returns ``True`` on success, ``False`` when the
        target has no mask or the subtree root isn't a ``Group``.
        """
        from geometry.element import Group, with_mask
        doc = self._model.document
        try:
            target = doc.get_element(path)
        except (IndexError, KeyError):
            return False
        mask = getattr(target, "mask", None)
        if mask is None:
            return False
        if not isinstance(mask.subtree, Group):
            return False
        new_group = replace(
            mask.subtree,
            children=mask.subtree.children + (element,),
        )
        new_mask = replace(mask, subtree=new_group)
        new_target = with_mask(target, new_mask)
        new_doc = doc.replace_element(path, new_target)
        # No canonical "inside a mask" path — select the mask-target
        # element itself after the add.
        es = ElementSelection.all(path)
        self._model.edit_document(replace(new_doc, selection=frozenset({es})))
        return True

    @staticmethod
    def _toggle_selection(current: Selection, new: Selection) -> Selection:
        """XOR two selections per element.

        - Elements appearing in only one input pass through unchanged.
        - Two ``.all`` selections cancel out — this is the
          element-level deselect gesture (shift-click an already-fully-
          selected element).
        - Two ``.partial`` selections XOR their CP sets. If the result
          is empty the element stays selected as ``.partial(empty)`` —
          "element selected, no individual CPs highlighted" — rather
          than being dropped.
        - Mixed ``.all``/``.partial`` collapses to ``.all`` (preserving
          the pre-refactor behavior for this rare case).
        """
        current_by_path = {es.path: es for es in current}
        new_by_path = {es.path: es for es in new}
        result: set[ElementSelection] = set()
        # Elements only in current
        for path, es in current_by_path.items():
            if path not in new_by_path:
                result.add(es)
        # Elements only in new
        for path, es in new_by_path.items():
            if path not in current_by_path:
                result.add(es)
        # Elements in both: XOR.
        for path in current_by_path.keys() & new_by_path.keys():
            cur = current_by_path[path].kind
            nw = new_by_path[path].kind
            if isinstance(cur, _SelectionAll) and isinstance(nw, _SelectionAll):
                # Cancel out — element drops out of selection.
                continue
            if isinstance(cur, _SelectionPartial) and isinstance(nw, _SelectionPartial):
                # Keep the element even when the XOR is empty.
                xor = cur.cps.symmetric_difference(nw.cps)
                result.add(ElementSelection(
                    path=path, kind=_SelectionPartial(xor)))
            else:
                # Mixed All/Partial — keep `.all`.
                result.add(ElementSelection.all(path))
        return frozenset(result)

    # ------------------------------------------------------------------
    # Private helpers for selection
    # ------------------------------------------------------------------

    def _select_flat(self, predicate: Callable[[Element], bool],
                     *, extend: bool = False) -> None:
        """Flat 2-level selection with group expansion.

        Iterates layers and their direct children.  Groups that contain
        at least one hit are expanded (the group itself *and* every child
        are selected).  Parameterized by *predicate* which receives an
        element and returns whether it is hit.
        """
        doc = self._model.document
        entries: list[ElementSelection] = []
        for li, layer in enumerate(doc.layers):
            if layer.visibility == Visibility.INVISIBLE:
                continue
            for ci, child in enumerate(layer.children):
                if child.locked:
                    continue
                child_vis = min(layer.visibility, child.visibility,
                                key=lambda v: v.value)
                if child_vis == Visibility.INVISIBLE:
                    continue
                if isinstance(child, Group) and not isinstance(child, Layer):
                    if any(predicate(gc) for gc in child.children):
                        entries.append(ElementSelection.all((li, ci)))
                        for gi in range(len(child.children)):
                            entries.append(
                                ElementSelection.all((li, ci, gi)))
                elif predicate(child):
                    entries.append(ElementSelection.all((li, ci)))
        new_sel = frozenset(entries)
        if extend:
            new_sel = self._toggle_selection(doc.selection, new_sel)
        # Selection-only: a non-undoable write (OP_LOG.md §7/§8).
        self._model.set_document_unbracketed(replace(doc, selection=new_sel))

    def _select_recursive(
        self,
        leaf_handler: Callable[
            [ElementPath, Element], ElementSelection | None],
        *, extend: bool = False,
    ) -> None:
        """Recursive selection traversal.

        Walks every layer/group tree.  When a leaf element (non-group,
        non-layer) is reached, *leaf_handler* is called with ``(path,
        element)`` and may return an :class:`ElementSelection` or
        ``None``.
        """
        doc = self._model.document
        entries: list[ElementSelection] = []

        def _walk(path: ElementPath, elem: Element,
                  ancestor_vis: Visibility) -> None:
            if elem.locked:
                return
            effective = min(ancestor_vis, elem.visibility,
                            key=lambda v: v.value)
            if effective == Visibility.INVISIBLE:
                return
            if isinstance(elem, (Group, Layer)):
                for i, child in enumerate(elem.children):
                    _walk(path + (i,), child, effective)
                return
            result = leaf_handler(path, elem)
            if result is not None:
                entries.append(result)

        for li, layer in enumerate(doc.layers):
            _walk((li,), layer, Visibility.PREVIEW)

        new_sel = frozenset(entries)
        if extend:
            new_sel = self._toggle_selection(doc.selection, new_sel)
        # Selection-only: a non-undoable write (OP_LOG.md §7/§8).
        self._model.set_document_unbracketed(replace(doc, selection=new_sel))

    # ------------------------------------------------------------------
    # Public selection methods (thin wrappers)
    # ------------------------------------------------------------------

    def select_rect(self, x: float, y: float, width: float, height: float,
                    *, extend: bool = False) -> None:
        """Select all elements whose bounds intersect the given rectangle.

        Group expansion: if any child of a Group intersects, all children
        of that Group are selected.
        """
        self._select_flat(
            lambda elem: element_intersects_rect(elem, x, y, width, height),
            extend=extend,
        )

    def select_polygon(self, polygon: list[tuple[float, float]], *,
                       extend: bool = False) -> None:
        """Select all elements intersecting the given polygon."""
        from algorithms.hit_test import element_intersects_polygon
        self._select_flat(
            lambda elem: element_intersects_polygon(elem, polygon),
            extend=extend,
        )

    def interior_select_rect(self, x: float, y: float, width: float, height: float,
                          *, extend: bool = False) -> None:
        """Group selection marquee: selects individual elements with all
        control points.  Groups are traversed (not expanded) so elements
        inside groups can be individually selected.
        """
        def _leaf(path: ElementPath, elem: Element) -> ElementSelection | None:
            if element_intersects_rect(elem, x, y, width, height):
                return ElementSelection.all(path)
            return None
        self._select_recursive(_leaf, extend=extend)

    def partial_select_rect(self, x: float, y: float, width: float, height: float,
                           *, extend: bool = False) -> None:
        """Direct selection marquee: select individual elements and only the
        control points that fall within the rectangle.  Groups are not
        expanded — elements inside groups can be individually selected.
        """
        def _leaf(path: ElementPath, elem: Element) -> ElementSelection | None:
            cps = control_points(elem)
            hit_cps = [
                i for i, (px, py) in enumerate(cps)
                if point_in_rect(px, py, x, y, width, height)
            ]
            if hit_cps:
                return ElementSelection.partial(path, hit_cps)
            if element_intersects_rect(elem, x, y, width, height):
                # Marquee crosses the body but no CPs. Select the
                # element with an empty CP set -- the Partial Selection
                # tool must not promote "body intersects" to "every CP
                # selected" (which is what `.all` would mean).
                return ElementSelection.partial(path, ())
            return None
        self._select_recursive(_leaf, extend=extend)

    def select_all(self) -> None:
        """Select all unlocked, visible elements."""
        self._select_flat(lambda _: True)

    def set_selection(self, selection: Selection) -> None:
        """Set the document selection directly. Selection-only: a non-undoable
        write (OP_LOG.md §7/§8)."""
        self._model.set_document_unbracketed(
            replace(self._model.document, selection=selection))

    def select_element(self, path: ElementPath) -> None:
        """Select an element by path.

        If the element's immediate parent is a Group (not a Layer), all
        children of that Group are selected.  Otherwise just the single
        element is selected.  Locked elements cannot be selected.
        """

        if not path:
            raise ValueError("Path must be non-empty")
        doc = self._model.document
        elem = doc.get_element(path)
        if elem.locked:
            return
        if doc.effective_visibility(path) == Visibility.INVISIBLE:
            return
        if len(path) >= 2:
            parent_path = path[:-1]
            parent = doc.get_element(parent_path)
            if isinstance(parent, Group) and not isinstance(parent, Layer):
                entries = [ElementSelection.all(parent_path)]
                entries.extend(
                    ElementSelection.all(parent_path + (i,))
                    for i in range(len(parent.children))
                )
                # Selection-only: non-undoable (OP_LOG.md §7/§8).
                self._model.set_document_unbracketed(
                    replace(doc, selection=frozenset(entries)))
                return
        # Selection-only: non-undoable (OP_LOG.md §7/§8).
        self._model.set_document_unbracketed(
            replace(doc, selection=frozenset({ElementSelection.all(path)}))
        )

    def select_control_point(self, path: ElementPath, index: int) -> None:
        """Select a single control point on an element.

        The given control-point index is marked as selected.
        """
        if not path:
            raise ValueError("Path must be non-empty")
        # Selection-only: non-undoable (OP_LOG.md §7/§8).
        self._model.set_document_unbracketed(replace(
            self._model.document,
            selection=frozenset({ElementSelection.partial(path, [index])}),
        ))

    def move_selection(self, dx: float, dy: float) -> None:
        """Move all selected control points by (dx, dy)."""
        doc = self._model.document
        new_doc = doc
        for es in doc.selection:
            elem = doc.get_element(es.path)
            new_elem = move_control_points(elem, es.kind, dx, dy)
            new_doc = new_doc.replace_element(es.path, new_elem)
        self._model.edit_document(new_doc)

    def simplify_selection(self, precision: float) -> None:
        """Simplify the geometry of each selected Polygon / Path element
        by running the Schneider curve fit
        (:func:`algorithms.simplify.simplify_polyline`) on its vertices.
        Other element kinds are left alone. Used by Object -> Simplify
        and (in future) other refit entry points. ``precision`` is the
        Schneider max-error tolerance in points.

        Polygons are replaced with Paths that carry the refitted CurveTo
        / LineTo commands; existing Paths are re-issued with refitted
        geometry. Selection is preserved.

        Like the other controller mutators (e.g. :meth:`move_selection`)
        this does NOT snapshot internally -- the caller/harness owns the
        undo bracket. It only mutates ``self._model.document``.
        Mirrors ``Controller::simplify_selection`` in
        ``jas_dioxus/src/document/controller.rs``.
        """
        from algorithms.simplify import simplify_polyline

        doc = self._model.document
        if not doc.selection:
            return
        new_doc = doc
        for es in doc.selection:
            elem = new_doc.get_element(es.path)
            if isinstance(elem, Polygon):
                pts = [(p[0], p[1]) for p in elem.points]
                cmds = simplify_polyline(pts, precision, True)
                if not cmds:
                    continue
                new_path = Path(
                    d=tuple(cmds),
                    fill=elem.fill,
                    stroke=elem.stroke,
                    opacity=elem.opacity,
                    transform=elem.transform,
                    locked=elem.locked,
                    visibility=elem.visibility,
                    blend_mode=elem.blend_mode,
                    mask=elem.mask,
                    fill_gradient=elem.fill_gradient,
                    stroke_gradient=elem.stroke_gradient,
                    name=elem.name,
                )
                new_doc = new_doc.replace_element(es.path, new_path)
            elif isinstance(elem, Path):
                # Walk the path command list, splitting at every MoveTo /
                # ClosePath into subpaths of 2D points. Each subpath is
                # refit independently; other command kinds (CurveTo,
                # ArcTo, ...) are passed through as-is.
                new_cmds: list[PathCommand] = []
                buf: list[tuple[float, float]] = []
                state = {"closed": False}

                def flush() -> None:
                    if len(buf) >= 2:
                        new_cmds.extend(
                            simplify_polyline(buf, precision, state["closed"]))
                    buf.clear()
                    state["closed"] = False

                for c in elem.d:
                    if isinstance(c, MoveTo):
                        flush()
                        buf.append((c.x, c.y))
                    elif isinstance(c, LineTo):
                        buf.append((c.x, c.y))
                    elif isinstance(c, ClosePath):
                        state["closed"] = True
                        flush()
                    else:
                        # Already-curved commands stay verbatim; splice
                        # the buffered run before emitting them so refit
                        # and pre-existing curves sit in order.
                        flush()
                        new_cmds.append(c)
                flush()
                if not new_cmds:
                    continue
                new_path = replace(elem, d=tuple(new_cmds))
                new_doc = new_doc.replace_element(es.path, new_path)
        self._model.edit_document(new_doc)

    def copy_selection(self, dx: float, dy: float) -> None:
        """Duplicate selected elements, offset by (dx, dy), leaving originals unchanged."""
        doc = self._model.document
        new_doc = doc
        new_selection: set[ElementSelection] = set()
        # Sort paths in reverse so insertions don't shift earlier paths
        sorted_sels = sorted(doc.selection, key=lambda es: es.path, reverse=True)
        for es in sorted_sels:
            elem = doc.get_element(es.path)
            copied = move_control_points(elem, es.kind, dx, dy)
            # A copy must not inherit the source's stable id (no two elements
            # may share an identity); it is born id-less.
            copied = clear_ids(copied)
            new_doc = new_doc.insert_element_after(es.path, copied)
            # The copy is at path with last index incremented by 1
            copy_path = es.path[:-1] + (es.path[-1] + 1,)
            # Copying always selects the new element as a whole.
            new_selection.add(ElementSelection.all(copy_path))
        self._model.edit_document(replace(
            new_doc, selection=frozenset(new_selection)))

    def lock_selection(self) -> None:
        """Lock all selected elements and clear the selection.

        When a Group is locked, all its children are locked recursively.
        """
        doc = self._model.document
        if not doc.selection:
            return

        def _lock(elem: Element) -> Element:
            if isinstance(elem, Group) and not isinstance(elem, Layer):
                new_children = tuple(_lock(c) for c in elem.children)
                return replace(elem, children=new_children, locked=True)
            return replace(elem, locked=True)

        new_doc = doc
        for es in doc.selection:
            elem = new_doc.get_element(es.path)
            new_doc = new_doc.replace_element(es.path, _lock(elem))
        self._model.edit_document(replace(new_doc, selection=frozenset()))

    def unlock_all(self) -> None:
        """Unlock all locked elements and select them."""
        from geometry.element import control_point_count
        doc = self._model.document
        unlocked_paths: list[tuple[ElementPath, Element]] = []

        def _collect_locked(path: ElementPath, elem: Element) -> None:
            if isinstance(elem, Group) and not isinstance(elem, Layer):
                if elem.locked:
                    unlocked_paths.append((path, elem))
                for i, child in enumerate(elem.children):
                    _collect_locked(path + (i,), child)
            elif elem.locked:
                unlocked_paths.append((path, elem))

        for li, layer in enumerate(doc.layers):
            for ci, child in enumerate(layer.children):
                _collect_locked((li, ci), child)

        def _unlock(elem: Element) -> Element:
            if isinstance(elem, Group):
                new_children = tuple(_unlock(c) for c in elem.children)
                return replace(elem, children=new_children, locked=False)
            return replace(elem, locked=False)

        new_layers = tuple(
            replace(layer, children=tuple(_unlock(c) for c in layer.children))
            for layer in doc.layers
        )
        # Select all newly unlocked elements
        new_selection: set[ElementSelection] = set()
        new_doc = replace(doc, layers=new_layers)
        for path, _ in unlocked_paths:
            new_selection.add(ElementSelection.all(path))
        self._model.edit_document(replace(new_doc, selection=frozenset(new_selection)))

    def move_path_handle(self, path: ElementPath, anchor_idx: int,
                         handle_type: str, dx: float, dy: float) -> None:
        """Move a Bezier handle of a path element."""
        doc = self._model.document
        elem = doc.get_element(path)
        if isinstance(elem, Path):
            new_elem = _move_path_handle(elem, anchor_idx, handle_type, dx, dy)
            self._model.edit_document(doc.replace_element(path, new_elem))

    def hide_selection(self) -> None:
        """Set every element in the current selection to
        :class:`Visibility.INVISIBLE` and clear the selection.

        If an element is a Group or Layer, only the container's own
        flag is set — a parent's ``INVISIBLE`` caps every descendant,
        so the effect reaches the whole subtree without rewriting
        every node.
        """

        doc = self._model.document
        if not doc.selection:
            return
        new_doc = doc
        for es in doc.selection:
            elem = new_doc.get_element(es.path)
            hidden = replace(elem, visibility=Visibility.INVISIBLE)
            new_doc = new_doc.replace_element(es.path, hidden)
        self._model.edit_document(replace(new_doc, selection=frozenset()))

    def show_all(self) -> None:
        """Traverse the document, set every element whose own
        visibility is :class:`Visibility.INVISIBLE` back to
        :class:`Visibility.PREVIEW`, and replace the current
        selection with exactly the paths that were shown.

        Elements that are effectively invisible only because an
        ancestor is invisible are *not* individually modified — it
        is the ancestor whose own flag is unset, and that cascades.
        """

        doc = self._model.document
        shown_paths: list[ElementPath] = []

        def _show(elem: Element, path: ElementPath) -> Element:
            new_elem = elem
            if elem.visibility == Visibility.INVISIBLE:
                new_elem = replace(new_elem, visibility=Visibility.PREVIEW)
                shown_paths.append(path)
            if isinstance(new_elem, (Group, Layer)):
                new_children = tuple(
                    _show(c, path + (i,))
                    for i, c in enumerate(new_elem.children)
                )
                new_elem = replace(new_elem, children=new_children)
            return new_elem

        new_layers = tuple(
            _show(layer, (li,)) for li, layer in enumerate(doc.layers)
        )
        new_selection = frozenset(
            ElementSelection.all(p) for p in shown_paths
        )
        self._model.edit_document(replace(
            doc, layers=new_layers, selection=new_selection))

    def _fill_applied(self, fill: Fill | None) -> Document:
        """Pure: return the document with ``fill`` applied to every selected
        element (no write). Mirrors the Rust ``fill_applied``."""
        doc = self._model.document
        new_doc = doc
        for es in doc.selection:
            elem = new_doc.get_element(es.path)
            new_elem = _with_fill(elem, fill)
            if new_elem is not elem:
                new_doc = new_doc.replace_element(es.path, new_elem)
        return new_doc

    def _stroke_applied(self, stroke: Stroke | None) -> Document:
        """Pure: return the document with ``stroke`` applied to every selected
        element (no write). Mirrors the Rust ``stroke_applied``."""
        doc = self._model.document
        new_doc = doc
        for es in doc.selection:
            elem = new_doc.get_element(es.path)
            new_elem = _with_stroke(elem, stroke)
            if new_elem is not elem:
                new_doc = new_doc.replace_element(es.path, new_elem)
        return new_doc

    def set_selection_fill(self, fill: Fill | None) -> None:
        """Set the fill of all selected elements (undoable, self-bracketing)."""
        self._model.edit_document(self._fill_applied(fill))

    def set_selection_fill_live(self, fill: Fill | None) -> None:
        """Live, NON-undoable fill set for per-tick color-slider drag
        (``set_active_color_live``). Undo is captured once on pointer-up by
        ``set_active_color``, so the drag must NOT push checkpoints. Mirrors the
        Rust ``set_selection_fill_live`` (OP_LOG.md §7/§8 live-drag)."""
        self._model.set_document_unbracketed(self._fill_applied(fill))

    def set_selection_stroke(self, stroke: Stroke | None) -> None:
        """Set the stroke of all selected elements (undoable, self-bracketing)."""
        self._model.edit_document(self._stroke_applied(stroke))

    def set_selection_stroke_live(self, stroke: Stroke | None) -> None:
        """Live, NON-undoable stroke set for per-tick color drag (see
        ``set_selection_fill_live``). Mirrors the Rust
        ``set_selection_stroke_live``."""
        self._model.set_document_unbracketed(self._stroke_applied(stroke))

    def set_selection_stroke_brush(self, slug: str | None) -> None:
        """Set stroke_brush on every selected element (paths only).
        Used by apply_brush_to_selection / remove_brush_from_selection."""
        doc = self._model.document
        new_doc = doc
        for es in doc.selection:
            elem = new_doc.get_element(es.path)
            new_elem = _with_stroke_brush(elem, slug)
            if new_elem is not elem:
                new_doc = new_doc.replace_element(es.path, new_elem)
        self._model.edit_document(new_doc)

    def set_selection_stroke_brush_overrides(self, overrides: str | None) -> None:
        """Set stroke_brush_overrides on every selected element (paths only)."""
        doc = self._model.document
        new_doc = doc
        for es in doc.selection:
            elem = new_doc.get_element(es.path)
            new_elem = _with_stroke_brush_overrides(elem, overrides)
            if new_elem is not elem:
                new_doc = new_doc.replace_element(es.path, new_elem)
        self._model.edit_document(new_doc)

    def set_selection_fill_gradient(self, gradient: Gradient | None) -> None:
        """Phase 5: set the fill_gradient of all selected elements.

        Pass None to clear (demote to solid; the underlying solid Fill
        is left untouched as the demote-target color).
        """
        doc = self._model.document
        new_doc = doc
        for es in doc.selection:
            elem = new_doc.get_element(es.path)
            new_elem = _with_fill_gradient(elem, gradient)
            if new_elem is not elem:
                new_doc = new_doc.replace_element(es.path, new_elem)
        self._model.edit_document(new_doc)

    def set_selection_stroke_gradient(self, gradient: Gradient | None) -> None:
        """Phase 5: set the stroke_gradient of all selected elements."""
        doc = self._model.document
        new_doc = doc
        for es in doc.selection:
            elem = new_doc.get_element(es.path)
            new_elem = _with_stroke_gradient(elem, gradient)
            if new_elem is not elem:
                new_doc = new_doc.replace_element(es.path, new_elem)
        self._model.edit_document(new_doc)

    def set_selection_width_profile(self, width_points: tuple[StrokeWidthPoint, ...]) -> None:
        """Set the variable-width stroke profile for all selected elements."""
        doc = self._model.document
        if not doc.selection:
            return
        new_doc = doc
        for es in doc.selection:
            elem = new_doc.get_element(es.path)
            new_elem = _with_width_points(elem, width_points)
            if new_elem is not elem:
                new_doc = new_doc.replace_element(es.path, new_elem)
        self._model.edit_document(new_doc)

    # ── Opacity mask lifecycle (OPACITY.md § States) ─────────────

    def make_mask_on_selection(self, clip: bool, invert: bool) -> None:
        """Create an opacity mask on every selected element that does
        not already have one. The subtree starts as an empty ``Group``;
        users populate it via the MASK_PREVIEW click (Phase 4). ``clip``
        and ``invert`` come from the document preferences
        ``new_masks_clipping`` / ``new_masks_inverted``.
        """
        doc = self._model.document
        if not doc.selection:
            return
        new_doc = doc
        for es in doc.selection:
            elem = new_doc.get_element(es.path)
            if elem.mask is not None:
                continue
            m = Mask(
                subtree=Group(),
                clip=clip,
                invert=invert,
                disabled=False,
                linked=True,
                unlink_transform=None,
            )
            new_doc = new_doc.replace_element(es.path, _with_mask(elem, m))
        self._model.edit_document(new_doc)

    def release_mask_on_selection(self) -> None:
        """Remove the opacity mask from every selected element."""
        doc = self._model.document
        if not doc.selection:
            return
        new_doc = doc
        for es in doc.selection:
            elem = new_doc.get_element(es.path)
            if elem.mask is None:
                continue
            new_doc = new_doc.replace_element(es.path, _with_mask(elem, None))
        self._model.edit_document(new_doc)

    def _update_mask_on_selection(self, transform) -> None:
        """Apply ``transform`` (Mask -> Mask) to every selected element's
        mask. Elements without a mask are skipped.
        """
        doc = self._model.document
        new_doc = doc
        for es in doc.selection:
            elem = new_doc.get_element(es.path)
            if elem.mask is None:
                continue
            new_doc = new_doc.replace_element(es.path, _with_mask(elem, transform(elem.mask)))
        self._model.edit_document(new_doc)

    def set_mask_clip_on_selection(self, clip: bool) -> None:
        """Set ``mask.clip`` on every selected element that has a mask."""
        self._update_mask_on_selection(lambda m: dataclasses.replace(m, clip=clip))

    def set_mask_invert_on_selection(self, invert: bool) -> None:
        """Set ``mask.invert`` on every selected element that has a mask."""
        self._update_mask_on_selection(lambda m: dataclasses.replace(m, invert=invert))

    def toggle_mask_disabled_on_selection(self) -> None:
        """Toggle ``mask.disabled`` on every selected mask, driven by
        the first selected element's current state.
        """
        fm = first_mask(self._model.document)
        if fm is None:
            return
        new_state = not fm.disabled
        self._update_mask_on_selection(
            lambda m: dataclasses.replace(m, disabled=new_state))

    def toggle_mask_linked_on_selection(self) -> None:
        """Toggle ``mask.linked`` on every selected mask. On unlink,
        captures each element's current transform into
        ``unlink_transform``. On relink, clears ``unlink_transform``.
        """
        fm = first_mask(self._model.document)
        if fm is None:
            return
        new_linked = not fm.linked
        doc = self._model.document
        new_doc = doc
        for es in doc.selection:
            elem = new_doc.get_element(es.path)
            if elem.mask is None:
                continue
            capture = None if new_linked else getattr(elem, 'transform', None)
            new_mask = dataclasses.replace(
                elem.mask, linked=new_linked, unlink_transform=capture)
            new_doc = new_doc.replace_element(es.path, _with_mask(elem, new_mask))
        self._model.edit_document(new_doc)


# -- Fill/Stroke summary types --

@dataclass(frozen=True)
class FillSummaryNoSelection:
    """No elements are selected."""
    pass


@dataclass(frozen=True)
class FillSummaryUniform:
    """All selected elements have the same fill."""
    fill: Fill | None


@dataclass(frozen=True)
class FillSummaryMixed:
    """Selected elements have different fills."""
    pass


FillSummary = FillSummaryNoSelection | FillSummaryUniform | FillSummaryMixed


@dataclass(frozen=True)
class StrokeSummaryNoSelection:
    """No elements are selected."""
    pass


@dataclass(frozen=True)
class StrokeSummaryUniform:
    """All selected elements have the same stroke."""
    stroke: Stroke | None


@dataclass(frozen=True)
class StrokeSummaryMixed:
    """Selected elements have different strokes."""
    pass


StrokeSummary = StrokeSummaryNoSelection | StrokeSummaryUniform | StrokeSummaryMixed


def selection_fill_summary(doc: Document) -> FillSummary:
    """Compute the fill summary for the current selection."""
    if not doc.selection:
        return FillSummaryNoSelection()
    first = None
    first_set = False
    for es in doc.selection:
        fill = _element_fill(doc.get_element(es.path))
        if not first_set:
            first = fill
            first_set = True
        elif first != fill:
            return FillSummaryMixed()
    return FillSummaryUniform(fill=first)


def selection_stroke_summary(doc: Document) -> StrokeSummary:
    """Compute the stroke summary for the current selection."""
    if not doc.selection:
        return StrokeSummaryNoSelection()
    first = None
    first_set = False
    for es in doc.selection:
        stroke = _element_stroke(doc.get_element(es.path))
        if not first_set:
            first = stroke
            first_set = True
        elif first != stroke:
            return StrokeSummaryMixed()
    return StrokeSummaryUniform(stroke=first)
