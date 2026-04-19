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


def _store_with_phase3b_panel():
    """Init the panel scope with Phase 3a + 3b defaults so set_panel
    has somewhere to write."""
    from workspace_interpreter.state_store import StateStore
    s = StateStore()
    s.init_panel("paragraph_panel_content", {
        "text_selected": True,
        "area_text_selected": True,
        "left_indent": 0,
        "right_indent": 0,
        "hyphenate": False,
        "hanging_punctuation": False,
        "bullets": "",
        "numbered_list": "",
    })
    return s


class TestPhase3bParagraphAttrReads:
    """Phase 3b: read paragraph attrs from the first wrapper tspan
    in the first selected text element."""

    def test_reads_para_wrapper_attrs(self):
        from geometry.element import Text
        from geometry.tspan import Tspan
        wrapper = Tspan(id=0, content="", jas_role="paragraph",
                        jas_left_indent=18.0, jas_right_indent=9.0,
                        jas_hyphenate=True, jas_hanging_punctuation=True,
                        jas_list_style="bullet-disc")
        content = Tspan(id=1, content="hello")
        area = Text(x=0, y=0, content="hello",
                    tspans=(wrapper, content),
                    font_family="sans-serif", font_size=12,
                    width=200, height=100)
        model = _Model([((0, 0), area)])
        store = _store_with_phase3b_panel()
        sync_paragraph_panel_from_selection(store, model)
        assert store.get_panel("paragraph_panel_content", "left_indent") == 18.0
        assert store.get_panel("paragraph_panel_content", "right_indent") == 9.0
        assert store.get_panel("paragraph_panel_content", "hyphenate") is True
        assert store.get_panel("paragraph_panel_content", "hanging_punctuation") is True
        assert store.get_panel("paragraph_panel_content", "bullets") == "bullet-disc"
        assert store.get_panel("paragraph_panel_content", "numbered_list") == ""

    def test_num_list_style_routes_to_numbered_dropdown(self):
        from geometry.element import Text
        from geometry.tspan import Tspan
        wrapper = Tspan(id=0, content="", jas_role="paragraph",
                        jas_list_style="num-decimal")
        content = Tspan(id=1, content="1. item")
        area = Text(x=0, y=0, content="hello",
                    tspans=(wrapper, content),
                    font_family="sans-serif", font_size=12,
                    width=200, height=100)
        model = _Model([((0, 0), area)])
        store = _store_with_phase3b_panel()
        sync_paragraph_panel_from_selection(store, model)
        assert store.get_panel("paragraph_panel_content", "numbered_list") == "num-decimal"
        assert store.get_panel("paragraph_panel_content", "bullets") == ""

    def test_absent_wrapper_leaves_panel_defaults(self):
        # Area text without any wrapper tspan — text-kind flags fire
        # but no paragraph-attr writes happen.
        from geometry.element import Text
        area = Text(x=0, y=0, content="hi", font_family="sans-serif",
                    font_size=12, width=200, height=100)
        model = _Model([((0, 0), area)])
        store = _store_with_phase3b_panel()
        sync_paragraph_panel_from_selection(store, model)
        assert store.get_panel("paragraph_panel_content", "text_selected") is True
        assert store.get_panel("paragraph_panel_content", "area_text_selected") is True
        # Defaults from init_panel preserved.
        assert store.get_panel("paragraph_panel_content", "left_indent") == 0
        assert store.get_panel("paragraph_panel_content", "bullets") == ""
        assert store.get_panel("paragraph_panel_content", "hyphenate") is False


class TestPhase3cMixedStateAggregation:
    """Phase 3c: aggregate paragraph attrs across multiple wrappers
    in the selection. Agree → write; disagree → omit override
    (panel keeps its prior value)."""

    def test_agrees_across_wrappers(self):
        from geometry.element import Text
        from geometry.tspan import Tspan
        w1 = Tspan(id=0, content="", jas_role="paragraph",
                   jas_left_indent=12.0, jas_hyphenate=True,
                   jas_list_style="bullet-disc")
        c1 = Tspan(id=1, content="first ")
        w2 = Tspan(id=2, content="", jas_role="paragraph",
                   jas_left_indent=12.0, jas_hyphenate=True,
                   jas_list_style="bullet-disc")
        c2 = Tspan(id=3, content="second")
        area = Text(x=0, y=0, content="first second",
                    tspans=(w1, c1, w2, c2),
                    font_family="sans-serif", font_size=12,
                    width=200, height=100)
        model = _Model([((0, 0), area)])
        store = _store_with_phase3b_panel()
        sync_paragraph_panel_from_selection(store, model)
        assert store.get_panel("paragraph_panel_content", "left_indent") == 12.0
        assert store.get_panel("paragraph_panel_content", "hyphenate") is True
        assert store.get_panel("paragraph_panel_content", "bullets") == "bullet-disc"

    def test_mixed_numeric_omits_key(self):
        # Two wrappers disagreeing on left_indent → no write; panel
        # keeps the YAML default 0.
        from geometry.element import Text
        from geometry.tspan import Tspan
        w1 = Tspan(id=0, content="", jas_role="paragraph", jas_left_indent=12.0)
        c1 = Tspan(id=1, content="first ")
        w2 = Tspan(id=2, content="", jas_role="paragraph", jas_left_indent=24.0)
        c2 = Tspan(id=3, content="second")
        area = Text(x=0, y=0, content="first second",
                    tspans=(w1, c1, w2, c2),
                    font_family="sans-serif", font_size=12,
                    width=200, height=100)
        model = _Model([((0, 0), area)])
        store = _store_with_phase3b_panel()
        sync_paragraph_panel_from_selection(store, model)
        assert store.get_panel("paragraph_panel_content", "left_indent") == 0

    def test_mixed_list_style_clears_both_dropdowns(self):
        # Wrappers split bullet vs numbered → no write; both
        # dropdowns keep their YAML defaults of "".
        from geometry.element import Text
        from geometry.tspan import Tspan
        w1 = Tspan(id=0, content="", jas_role="paragraph",
                   jas_list_style="bullet-disc")
        c1 = Tspan(id=1, content="•")
        w2 = Tspan(id=2, content="", jas_role="paragraph",
                   jas_list_style="num-decimal")
        c2 = Tspan(id=3, content="1.")
        area = Text(x=0, y=0, content="•1.",
                    tspans=(w1, c1, w2, c2),
                    font_family="sans-serif", font_size=12,
                    width=200, height=100)
        model = _Model([((0, 0), area)])
        store = _store_with_phase3b_panel()
        sync_paragraph_panel_from_selection(store, model)
        assert store.get_panel("paragraph_panel_content", "bullets") == ""
        assert store.get_panel("paragraph_panel_content", "numbered_list") == ""
