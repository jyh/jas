"""Symbols-panel native action arms (SYMBOLS.md §7, §8).

The mutating symbol ops (new_symbol / place_instance / delete_symbol) mint
ids by the value-in-op rule and call the shared symbol :class:`Controller`
ops, so the shared YAML actions are ``log`` stubs and the real work lives
here — exactly like ``menu._link_to_selection`` (Make Instance) intercepts
the menu command natively. Each op takes ONE snapshot so it is a single
undo step. Mirrors the Rust ``interpreter::renderer::dispatch_action``
symbols intercept.

Id minting is a UI-layer concern: ``generate_element_id`` with a
collision-retry loop over every existing element id (layers + master
store), never minted inside a Controller, so every app applies identical
values.
"""

from __future__ import annotations


def _gather_existing_ids(doc) -> set[str]:
    """Every element id currently in the document (layers + master
    store), so freshly minted ids avoid collisions. Mirrors the Rust
    ``existing_ids`` walk in the symbols intercept."""
    existing: set[str] = set()

    def _walk(elem) -> None:
        eid = getattr(elem, "id", None)
        if eid is not None:
            existing.add(eid)
        children = getattr(elem, "children", None)
        if children is not None:
            for c in children:
                _walk(c)

    for layer in doc.layers:
        _walk(layer)
    for master in doc.symbols:
        _walk(master)
    return existing


def _mint(existing: set[str]) -> str | None:
    """Mint one collision-free element id (UI-layer minter)."""
    from document.artboard import generate_element_id
    for _ in range(100):
        candidate = generate_element_id()
        if candidate not in existing:
            return candidate
    return None


def symbol_usage_count(model, master_id: str | None) -> int:
    """Number of live instances of ``master_id`` — the length of its
    reverse-dependency list (rdeps) in the dependency index. The
    safe-delete signal that gates the reference-aware confirm."""
    if model is None or not master_id:
        return 0
    from document.dependency_index import dependency_index
    idx = dependency_index(model.document)
    return len(idx.rdeps.get(master_id, []))


def apply_new_symbol(model) -> str | None:
    """New Symbol: promote the single selected canvas element to a master
    (SYMBOLS.md §7 Make Symbol). Enabled only when exactly ONE whole
    element is selected (kind = all). Mints ``master_id`` + ``ref_id``,
    snapshots once, then ``Controller.make_symbol``. Returns the resolved
    master id (so the panel can keep the new master selected), or ``None``
    on a no-op. Mirrors the Rust ``new_symbol`` arm."""
    if model is None:
        return None
    from document.controller import Controller
    from document.document import _SelectionAll

    doc = model.document
    # Enabled only for a single whole-element selection.
    if len(doc.selection) != 1:
        return None
    es = next(iter(doc.selection))
    if not isinstance(es.kind, _SelectionAll):
        return None
    path = es.path

    existing = _gather_existing_ids(doc)
    master_id = _mint(existing)
    if master_id is None:
        return None
    existing.add(master_id)
    ref_id = _mint(existing)
    if ref_id is None:
        return None

    model.snapshot()
    Controller(model=model).make_symbol(path, master_id, ref_id)
    # make_symbol KEEPS an existing element id as the master key; resolve
    # which id actually became the master from the in-place instance's
    # target so the panel selects the real master.
    try:
        placed = model.document.get_element(path)
        from geometry.element import ReferenceElem
        if isinstance(placed, ReferenceElem):
            return placed.target
    except (ValueError, IndexError, KeyError):
        pass
    return master_id


def apply_place_instance(model, master_id: str | None) -> None:
    """Place Instance: append a new instance of ``master_id`` to the
    active layer (SYMBOLS.md §7 Place Instance). Mints ``ref_id``,
    snapshots once, then ``Controller.place_instance``. No-op when no
    master is panel-selected. Mirrors the Rust ``place_instance`` arm."""
    if model is None or not master_id:
        return
    from document.controller import Controller
    existing = _gather_existing_ids(model.document)
    ref_id = _mint(existing)
    if ref_id is None:
        return
    model.snapshot()
    Controller(model=model).place_instance(master_id, ref_id)


def apply_delete_symbol(model, master_id: str | None) -> None:
    """Delete Symbol: remove ``master_id`` from the master store
    (SYMBOLS.md §7 Delete Symbol). Snapshots once, then
    ``Controller.delete_symbol``. The instances are left untouched (they
    become dangling, recoverable via undo). The reference-aware confirm
    is a UI concern handled by the caller; this arm performs the actual
    deletion for both the inline (no-instance) and confirmed paths.
    No-op when no master is panel-selected. Mirrors the Rust
    ``delete_symbol`` arm."""
    if model is None or not master_id:
        return
    from document.controller import Controller
    model.snapshot()
    Controller(model=model).delete_symbol(master_id)
