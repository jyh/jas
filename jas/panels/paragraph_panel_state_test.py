"""Tests for the Paragraph panel selection-driven state — Phase 3a."""

from __future__ import annotations

from panels.paragraph_panel_state import sync_paragraph_panel_from_selection


# ── Tiny stub Model + Doc for hermetic tests (mirrors the
#    pattern in character_panel_state_test.py). ──────────────

class _Sel:
    def __init__(self, path):
        self.path = path


class _Doc:
    def __init__(self, elements_with_paths):
        # elements_with_paths: list[(path, element)]
        self._elements = dict(elements_with_paths)
        self.selection = [_Sel(p) for p, _ in elements_with_paths]

    def get_element(self, path):
        return self._elements[tuple(path) if isinstance(path, tuple) else path]


class _Model:
    def __init__(self, elements_with_paths):
        self.document = _Doc(elements_with_paths)


def _store_with_paragraph_panel():
    from workspace_interpreter.state_store import StateStore
    s = StateStore()
    # Per the OCaml port, set_panel is a no-op when the panel scope
    # has not been initialised; init with the YAML defaults of true
    # so failing-to-set bugs show up as "stayed true".
    s.init_panel("paragraph_panel_content", {
        "text_selected": True,
        "area_text_selected": True,
    })
    return s


class TestSyncParagraphPanelFromSelection:
    def test_no_op_when_model_is_none(self):
        store = _store_with_paragraph_panel()
        sync_paragraph_panel_from_selection(store, None)  # doesn't raise
        # Defaults stay (the YAML keeps the panel enabled in the absence of a model).
        assert store.get_panel("paragraph_panel_content", "text_selected") is True
        assert store.get_panel("paragraph_panel_content", "area_text_selected") is True

    def test_empty_selection_disables_panel(self):
        model = _Model([])
        store = _store_with_paragraph_panel()
        sync_paragraph_panel_from_selection(store, model)
        assert store.get_panel("paragraph_panel_content", "text_selected") is False
        assert store.get_panel("paragraph_panel_content", "area_text_selected") is False

    def test_non_text_selection_disables_panel(self):
        from geometry.element import Rect
        model = _Model([((0, 0), Rect(x=0, y=0, width=10, height=10))])
        store = _store_with_paragraph_panel()
        sync_paragraph_panel_from_selection(store, model)
        assert store.get_panel("paragraph_panel_content", "text_selected") is False
        assert store.get_panel("paragraph_panel_content", "area_text_selected") is False

    def test_point_text_enables_universal_only(self):
        # width=0, height=0 → point text → text_selected true,
        # area_text_selected false (JUSTIFY/indent/hyphenate disabled).
        from geometry.element import Text
        t = Text(x=0, y=0, content="hi", font_family="sans-serif",
                 font_size=12, width=0, height=0)
        model = _Model([((0, 0), t)])
        store = _store_with_paragraph_panel()
        sync_paragraph_panel_from_selection(store, model)
        assert store.get_panel("paragraph_panel_content", "text_selected") is True
        assert store.get_panel("paragraph_panel_content", "area_text_selected") is False

    def test_area_text_enables_all(self):
        # width>0 and height>0 → area text → both flags true.
        from geometry.element import Text
        t = Text(x=0, y=0, content="hello", font_family="sans-serif",
                 font_size=12, width=200, height=100)
        model = _Model([((0, 0), t)])
        store = _store_with_paragraph_panel()
        sync_paragraph_panel_from_selection(store, model)
        assert store.get_panel("paragraph_panel_content", "text_selected") is True
        assert store.get_panel("paragraph_panel_content", "area_text_selected") is True

    def test_text_path_enables_universal_only(self):
        from geometry.element import TextPath
        tp = TextPath(d=(), content="path", font_family="sans-serif",
                      font_size=14)
        model = _Model([((0, 0), tp)])
        store = _store_with_paragraph_panel()
        sync_paragraph_panel_from_selection(store, model)
        assert store.get_panel("paragraph_panel_content", "text_selected") is True
        assert store.get_panel("paragraph_panel_content", "area_text_selected") is False

    def test_mixed_area_and_point(self):
        # Multi-element selection: area + point.
        # PARAGRAPH.md: "a control is enabled iff every selected text
        # element supports it" → area_text_selected stays false.
        from geometry.element import Text
        area = Text(x=0, y=0, content="area", font_family="sans-serif",
                    font_size=12, width=200, height=100)
        point = Text(x=0, y=0, content="pt", font_family="sans-serif",
                     font_size=12, width=0, height=0)
        model = _Model([
            ((0, 0), area),
            ((0, 1), point),
        ])
        store = _store_with_paragraph_panel()
        sync_paragraph_panel_from_selection(store, model)
        assert store.get_panel("paragraph_panel_content", "text_selected") is True
        assert store.get_panel("paragraph_panel_content", "area_text_selected") is False
