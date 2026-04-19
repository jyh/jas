"""Paragraph panel selection-driven state — Phase 3a.

Computes ``panel.text_selected`` and ``panel.area_text_selected``
from the current document selection so PARAGRAPH.md §Text-kind
gating ``bind.disabled`` expressions resolve to the live values
rather than the YAML defaults of true.

Mirrors the paragraph-panel block in the Rust dock_panel.rs
``build_live_panel_overrides``, the Swift
``paragraphPanelLiveOverrides``, and the OCaml
``Effects.sync_paragraph_panel_from_selection``.

Like the OCaml port, this function is currently unwired in the
Python app (no selection-change observer pumps it) — Phase 4
hooks it in alongside the panel→selection write pipeline.
"""

from __future__ import annotations

from geometry.element import Text, TextPath


def sync_paragraph_panel_from_selection(store, model) -> None:
    """Push ``text_selected`` and ``area_text_selected`` to the
    ``paragraph_panel_content`` panel scope.

    - ``text_selected`` — true when any selected element is a Text
      or TextPath.
    - ``area_text_selected`` — true when at least one text element
      is selected and every selected text element is area Text
      (Text with width > 0 and height > 0). Text-on-path counts as
      non-area; any non-area text in the selection makes this false.

    No-op when the model is None or when the panel scope has not
    been initialised — matches the OCaml ``set_panel`` semantics.
    """
    if model is None:
        return
    doc = getattr(model, "document", None)
    if doc is None:
        return

    any_text = False
    all_area = True
    wrappers = []
    for es in doc.selection:
        path = getattr(es, "path", None)
        if path is None:
            continue
        elem = doc.get_element(path)
        if isinstance(elem, Text):
            any_text = True
            if not (elem.width > 0 and elem.height > 0):
                all_area = False
            for t in elem.tspans:
                if t.jas_role == "paragraph":
                    wrappers.append(t)
        elif isinstance(elem, TextPath):
            any_text = True
            all_area = False

    text_selected = any_text
    area_text_selected = any_text and all_area
    store.set_panel("paragraph_panel_content", "text_selected", text_selected)
    store.set_panel("paragraph_panel_content", "area_text_selected", area_text_selected)

    # Phase 3c mixed-state aggregation. For each panel-surface
    # paragraph attribute we collect every wrapper's effective value
    # (the field value if set, else the type's default). If all
    # wrappers agree the agreed value flows to the matching panel
    # key; if they disagree the override is omitted so the panel
    # keeps its prior / YAML-default value.
    if not wrappers:
        return

    def _agree(values):
        """Return the single shared value when all entries are equal,
        else None. Empty list also returns None."""
        if not values:
            return None
        first = values[0]
        return first if all(v == first for v in values) else None

    li = _agree([w.jas_left_indent if w.jas_left_indent is not None else 0
                 for w in wrappers])
    if li is not None:
        store.set_panel("paragraph_panel_content", "left_indent", li)
    ri = _agree([w.jas_right_indent if w.jas_right_indent is not None else 0
                 for w in wrappers])
    if ri is not None:
        store.set_panel("paragraph_panel_content", "right_indent", ri)
    hyph = _agree([w.jas_hyphenate if w.jas_hyphenate is not None else False
                   for w in wrappers])
    if hyph is not None:
        store.set_panel("paragraph_panel_content", "hyphenate", hyph)
    hp = _agree([w.jas_hanging_punctuation if w.jas_hanging_punctuation is not None else False
                 for w in wrappers])
    if hp is not None:
        store.set_panel("paragraph_panel_content", "hanging_punctuation", hp)
    # Single backing attr split into two panel dropdowns. Aggregate
    # first, then route by prefix.
    ls = _agree([w.jas_list_style if w.jas_list_style is not None else ""
                 for w in wrappers])
    if ls is not None:
        if ls.startswith("bullet-"):
            store.set_panel("paragraph_panel_content", "bullets", ls)
            store.set_panel("paragraph_panel_content", "numbered_list", "")
        elif ls.startswith("num-"):
            store.set_panel("paragraph_panel_content", "numbered_list", ls)
            store.set_panel("paragraph_panel_content", "bullets", "")
        else:
            # Empty agreement (no marker) clears both dropdowns.
            store.set_panel("paragraph_panel_content", "bullets", "")
            store.set_panel("paragraph_panel_content", "numbered_list", "")
