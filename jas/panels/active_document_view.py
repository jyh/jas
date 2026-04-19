"""Centralised construction of the ``active_document`` context
namespace for native-Python (jas) consumers.

Used by:
- Panel body rendering (dock_panel._create_panel_body) — drives
  bind.disabled / bind.visible expressions that read
  ``active_document.*``.
- Layers-panel action dispatch (panel_menu.dispatch_yaml_action) —
  evaluated against the same surface so action predicates and
  render-time predicates see the same values.

``panel_selection`` carries the layers-panel tree-selection so
computed fields like ``new_layer_insert_index`` and
``layers_panel_selection_count`` see live panel state. Pass ``None``
or ``[]`` from callers that don't have layers-panel context.
"""

from __future__ import annotations

from typing import Sequence


def build_active_document_view(
    model,
    panel_selection: Sequence[tuple[int, ...]] | None = None,
) -> dict:
    from geometry.element import Layer
    from workspace_interpreter.expr_types import Value

    panel_selection = list(panel_selection or [])
    panel_count = len(panel_selection)

    if model is None:
        return {
            "top_level_layers": [],
            "top_level_layer_paths": [],
            "next_layer_name": "Layer 1",
            "new_layer_insert_index": 0,
            "layers_panel_selection_count": panel_count,
            "has_selection": False,
            "selection_count": 0,
            "element_selection": [],
        }

    doc = model.document
    layers = doc.layers

    top_level_layers = []
    top_level_layer_paths = []
    used_names: set[str] = set()
    for i, elem in enumerate(layers):
        if isinstance(elem, Layer):
            vis_str = elem.visibility.name.lower()
            path_val = Value.path((i,))
            top_level_layers.append({
                "kind": "Layer",
                "name": elem.name,
                "common": {"visibility": vis_str, "locked": elem.locked},
                "path": path_val,
            })
            top_level_layer_paths.append(path_val)
            used_names.add(elem.name)

    n = 1
    while f"Layer {n}" in used_names:
        n += 1
    next_layer_name = f"Layer {n}"

    top_level_selected_indices = [p[0] for p in panel_selection if len(p) == 1]
    new_layer_insert_index = (
        min(top_level_selected_indices) + 1
        if top_level_selected_indices
        else len(layers)
    )

    # Canvas selection: ordered list of paths. Native Python
    # Selection is a frozenset[ElementSelection]; sort by path for
    # deterministic output across runs.
    selection_paths = sorted(es.path for es in doc.selection)
    element_selection = [Value.path(tuple(p)) for p in selection_paths]

    return {
        "top_level_layers": top_level_layers,
        "top_level_layer_paths": top_level_layer_paths,
        "next_layer_name": next_layer_name,
        "new_layer_insert_index": new_layer_insert_index,
        "layers_panel_selection_count": panel_count,
        "has_selection": len(selection_paths) > 0,
        "selection_count": len(selection_paths),
        "element_selection": element_selection,
    }
