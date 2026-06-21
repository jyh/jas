"""Concepts-panel native action arms (CONCEPTS.md §6).

The Concepts panel's mutating ops are ``log`` stubs in the shared
``actions.yaml`` (like the Symbols panel's); the real work lives here and is
intercepted natively by the dock panel, exactly as ``symbols_apply`` does:

- ``place_concept_instance`` mints a fresh element id (value-in-op) and appends
  a default-param ``GeneratedElem`` of the panel-selected concept.
- ``set_concept_param`` writes one parameter on the single selected generated
  instance so it re-generates live (the §6.4 "tune the same parameters" promise).

Each op goes through a :class:`Controller` mutator that self-brackets one undo
step via ``edit_document``. Id minting is a UI-layer concern (``generate_element_id``
with a collision-retry loop), never minted inside the Controller, so every app
applies identical values. Mirrors the Rust ``place_concept_instance`` /
``set_concept_param`` dispatch arms and the Swift ``ConceptsPanel``.
"""

from __future__ import annotations


def _gather_existing_ids(doc) -> set[str]:
    """Every element id currently in the document (layers + master store), so a
    freshly minted id avoids collisions. Mirrors ``symbols_apply``."""
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


def default_params(concept_id: str) -> dict:
    """The concept's declared default parameters as a params dict, read from the
    compiled concept registry. Mirrors the Rust / Swift default-params helpers."""
    from panels.yaml_menu import get_workspace_data
    ws = get_workspace_data()
    concept = (ws or {}).get("concepts", {}).get(concept_id)
    if not isinstance(concept, dict):
        return {}
    out: dict = {}
    for p in concept.get("params", []) or []:
        if isinstance(p, dict) and "name" in p and "default" in p:
            out[p["name"]] = p["default"]
    return out


def apply_place_concept_instance(model, concept_id: str | None) -> None:
    """Place Instance: append a new default-param generated instance of
    ``concept_id`` to the active layer and select it (CONCEPTS.md §6). Mints
    ``elem_id``, then ``Controller.place_concept_instance`` (one undo step).
    No-op when no concept is panel-selected. Mirrors the Rust
    ``place_concept_instance`` arm."""
    if model is None or not concept_id:
        return
    from document.controller import Controller
    existing = _gather_existing_ids(model.document)
    elem_id = _mint(existing)
    if elem_id is None:
        return
    # The Controller mutator self-brackets via edit_document (one undo step).
    Controller(model=model).place_concept_instance(
        concept_id, default_params(concept_id), elem_id)


def apply_set_concept_param(model, name: str, value: float) -> None:
    """Set one parameter on the single selected generated instance to ``value``
    so it re-generates live (CONCEPTS.md §6.4). No-op unless exactly one
    ``GeneratedElem`` is selected. Mirrors the Rust ``set_concept_param`` arm."""
    if model is None or not name:
        return
    from document.controller import Controller
    from geometry.element import GeneratedElem
    doc = model.document
    if len(doc.selection) != 1:
        return
    es = next(iter(doc.selection))
    try:
        elem = doc.get_element(es.path)
    except (ValueError, IndexError, KeyError):
        return
    if not isinstance(elem, GeneratedElem):
        return
    # The Controller mutator self-brackets via edit_document (one undo step).
    Controller(model=model).set_concept_param(es.path, name, value)
