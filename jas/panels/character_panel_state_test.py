"""Tests for the Character panel apply-to-selection pipeline."""

from __future__ import annotations

import pytest

from panels.character_panel_state import (
    _attrs_from_panel,
    _fmt_num,
    apply_character_panel_to_selection,
    subscribe,
)


# ── _fmt_num ─────────────────────────────────────────────────

class TestFmtNum:
    def test_integer_no_decimal(self):
        assert _fmt_num(12.0) == "12"

    def test_fraction_trimmed(self):
        assert _fmt_num(14.4) == "14.4"

    def test_trailing_zeros_trimmed(self):
        assert _fmt_num(14.5000) == "14.5"

    def test_negative(self):
        assert _fmt_num(-3.0) == "-3"


# ── _attrs_from_panel — text_decoration ──────────────────────

class TestTextDecoration:
    def test_neither(self):
        attrs = _attrs_from_panel({"underline": False, "strikethrough": False})
        assert attrs["text_decoration"] == ""

    def test_underline_only(self):
        attrs = _attrs_from_panel({"underline": True})
        assert attrs["text_decoration"] == "underline"

    def test_strikethrough_only(self):
        attrs = _attrs_from_panel({"strikethrough": True})
        assert attrs["text_decoration"] == "line-through"

    def test_both_alphabetical(self):
        attrs = _attrs_from_panel({"underline": True, "strikethrough": True})
        assert attrs["text_decoration"] == "line-through underline"


# ── _attrs_from_panel — caps / sub / super ───────────────────

class TestCapsAndBaseline:
    def test_all_caps_wins_over_small_caps(self):
        attrs = _attrs_from_panel({"all_caps": True, "small_caps": True})
        assert attrs["text_transform"] == "uppercase"
        assert attrs["font_variant"] == ""

    def test_small_caps_when_all_caps_off(self):
        attrs = _attrs_from_panel({"small_caps": True})
        assert attrs["text_transform"] == ""
        assert attrs["font_variant"] == "small-caps"

    def test_super_wins_over_numeric(self):
        attrs = _attrs_from_panel({"superscript": True, "baseline_shift": 5})
        assert attrs["baseline_shift"] == "super"

    def test_sub_when_super_off(self):
        attrs = _attrs_from_panel({"subscript": True})
        assert attrs["baseline_shift"] == "sub"

    def test_numeric_baseline_shift(self):
        attrs = _attrs_from_panel({"baseline_shift": 3})
        assert attrs["baseline_shift"] == "3pt"

    def test_zero_baseline_shift_empty(self):
        attrs = _attrs_from_panel({"baseline_shift": 0})
        assert attrs["baseline_shift"] == ""


# ── _attrs_from_panel — style_name parsing ───────────────────

class TestStyleName:
    def test_regular(self):
        attrs = _attrs_from_panel({"style_name": "Regular"})
        assert attrs["font_weight"] == "normal"
        assert attrs["font_style"] == "normal"

    def test_italic(self):
        attrs = _attrs_from_panel({"style_name": "Italic"})
        assert attrs["font_weight"] == "normal"
        assert attrs["font_style"] == "italic"

    def test_bold(self):
        attrs = _attrs_from_panel({"style_name": "Bold"})
        assert attrs["font_weight"] == "bold"
        assert attrs["font_style"] == "normal"

    def test_bold_italic(self):
        attrs = _attrs_from_panel({"style_name": "Bold Italic"})
        assert attrs["font_weight"] == "bold"
        assert attrs["font_style"] == "italic"

    def test_unknown_style_no_font_keys(self):
        """Unknown style names leave weight/style untouched."""
        attrs = _attrs_from_panel({"style_name": "Something Weird"})
        assert "font_weight" not in attrs
        assert "font_style" not in attrs


# ── _attrs_from_panel — leading / tracking ───────────────────

class TestLeadingTracking:
    def test_leading_at_auto_default_empties(self):
        attrs = _attrs_from_panel({"font_size": 12, "leading": 14.4})
        assert attrs["line_height"] == ""

    def test_leading_off_auto(self):
        attrs = _attrs_from_panel({"font_size": 12, "leading": 20})
        assert attrs["line_height"] == "20pt"

    def test_tracking_zero_empties(self):
        attrs = _attrs_from_panel({"tracking": 0})
        assert attrs["letter_spacing"] == ""

    def test_tracking_positive(self):
        attrs = _attrs_from_panel({"tracking": 25})  # 25/1000 em
        assert attrs["letter_spacing"] == "0.025em"

    def test_kerning_zero_empties(self):
        attrs = _attrs_from_panel({"kerning": 0})
        assert attrs["kerning"] == ""

    def test_kerning_positive(self):
        attrs = _attrs_from_panel({"kerning": 50})
        assert attrs["kerning"] == "0.05em"

    def test_kerning_numeric_string(self):
        # combo_box commits values as strings — numeric form still
        # converts to "{N}em".
        attrs = _attrs_from_panel({"kerning": "25"})
        assert attrs["kerning"] == "0.025em"

    def test_kerning_named_modes_pass_through(self):
        assert _attrs_from_panel({"kerning": "Optical"})["kerning"] == "Optical"
        assert _attrs_from_panel({"kerning": "Metrics"})["kerning"] == "Metrics"

    def test_kerning_auto_empties(self):
        # Auto / "" / "0" all round-trip to an empty element attribute.
        assert _attrs_from_panel({"kerning": "Auto"})["kerning"] == ""
        assert _attrs_from_panel({"kerning": "0"})["kerning"] == ""
        assert _attrs_from_panel({"kerning": ""})["kerning"] == ""


# ── _attrs_from_panel — rotation / scale ─────────────────────

class TestRotationScale:
    def test_rotation_zero_empties(self):
        attrs = _attrs_from_panel({"character_rotation": 0})
        assert attrs["rotate"] == ""

    def test_rotation_numeric(self):
        attrs = _attrs_from_panel({"character_rotation": 15})
        assert attrs["rotate"] == "15"

    def test_scale_identity_empties(self):
        attrs = _attrs_from_panel({"horizontal_scale": 100, "vertical_scale": 100})
        assert attrs["horizontal_scale"] == ""
        assert attrs["vertical_scale"] == ""

    def test_scale_off_identity(self):
        attrs = _attrs_from_panel({"horizontal_scale": 120, "vertical_scale": 90})
        assert attrs["horizontal_scale"] == "120"
        assert attrs["vertical_scale"] == "90"


# ── _attrs_from_panel — language / aa_mode ───────────────────

class TestLanguageAA:
    def test_language_passes_through(self):
        attrs = _attrs_from_panel({"language": "fr"})
        assert attrs["xml_lang"] == "fr"

    def test_sharp_aa_empties(self):
        attrs = _attrs_from_panel({"anti_aliasing": "Sharp"})
        assert attrs["aa_mode"] == ""

    def test_non_default_aa(self):
        attrs = _attrs_from_panel({"anti_aliasing": "Crisp"})
        assert attrs["aa_mode"] == "Crisp"


# ── apply_character_panel_to_selection — end-to-end ──────────

class TestApplyEndToEnd:
    """Exercises the store -> attrs -> selection -> document path.
    Uses a stub Model + StateStore to keep the test hermetic."""

    def _make_model_and_store(self, text_elem):
        """Tiny Model stub with a single Text in the selection."""
        from workspace_interpreter.state_store import StateStore

        class _Sel:
            def __init__(self, path):
                self.path = path

        class _Doc:
            def __init__(self, elem):
                self._elem = elem
                self.selection = [_Sel((0, 0))]

            def get_element(self, path):
                return self._elem

            def replace_element(self, path, new_elem):
                new = _Doc(new_elem)
                new.selection = self.selection
                return new

        class _Model:
            def __init__(self, elem):
                self.document = _Doc(elem)
                self.snapshots = 0

            def snapshot(self):
                self.snapshots += 1

        return _Model(text_elem), StateStore()

    def test_font_family_written_to_selected_text(self):
        from geometry.element import Text
        t = Text(x=0, y=0, content="hello", font_family="sans-serif", font_size=12)
        model, store = self._make_model_and_store(t)
        store.init_panel("character_panel", {"font_family": "Arial", "font_size": 12})
        apply_character_panel_to_selection(store, model)
        assert model.document.get_element((0, 0)).font_family == "Arial"
        assert model.snapshots == 1

    def test_no_op_when_no_model(self):
        from workspace_interpreter.state_store import StateStore
        store = StateStore()
        store.init_panel("character_panel", {"font_family": "Arial"})
        apply_character_panel_to_selection(store, None)  # doesn't raise

    def test_no_op_when_selection_empty(self):
        from geometry.element import Text
        from workspace_interpreter.state_store import StateStore

        class _Doc:
            def __init__(self):
                self.selection = []

            def get_element(self, path):
                raise AssertionError("should not be called")

            def replace_element(self, path, new_elem):
                raise AssertionError("should not be called")

        class _Model:
            def __init__(self):
                self.document = _Doc()
                self.snapshots = 0

            def snapshot(self):
                self.snapshots += 1

        model = _Model()
        store = StateStore()
        apply_character_panel_to_selection(store, model)
        assert model.snapshots == 0

    def test_underline_flows_to_text_decoration(self):
        from geometry.element import Text
        t = Text(x=0, y=0, content="hi", font_family="serif", font_size=12)
        model, store = self._make_model_and_store(t)
        store.init_panel("character_panel", {"underline": True, "font_size": 12})
        apply_character_panel_to_selection(store, model)
        assert model.document.get_element((0, 0)).text_decoration == "underline"

    def test_subscribe_fires_on_panel_write(self):
        from geometry.element import Text
        t = Text(x=0, y=0, content="hi", font_family="serif", font_size=12)
        model, store = self._make_model_and_store(t)
        store.init_panel("character_panel", {"font_family": "sans-serif", "font_size": 12})
        subscribe(store, lambda: model)
        # The subscribe firing after every set_panel is what wires the
        # panel's write-back to the selected element.
        store.set_panel("character_panel", "font_family", "Courier New")
        assert model.document.get_element((0, 0)).font_family == "Courier New"


# ── Phase 3: Character panel → pending override routing ──────────────

def _default_text():
    from geometry.element import Text
    return Text(x=0, y=0, content="",
                font_family="sans-serif", font_size=16,
                font_weight="normal", font_style="normal",
                text_decoration="", text_transform="", font_variant="",
                xml_lang="", rotate="")


def _aligned_panel():
    return {
        "font_family": "sans-serif",
        "font_size": 16.0,
        "style_name": "Regular",
        "all_caps": False, "small_caps": False,
        "superscript": False, "subscript": False,
        "underline": False, "strikethrough": False,
        "language": "",
        "character_rotation": 0.0,
    }


class TestBuildPanelPendingTemplate:
    def test_template_empty_when_panel_matches_element(self):
        from panels.character_panel_state import build_panel_pending_template
        assert build_panel_pending_template(_aligned_panel(), _default_text()) is None

    def test_template_bold_sets_font_weight_only(self):
        from panels.character_panel_state import build_panel_pending_template
        panel = {**_aligned_panel(), "style_name": "Bold"}
        tpl = build_panel_pending_template(panel, _default_text())
        assert tpl is not None
        assert tpl.font_weight == "bold"
        # Bold parses to ("bold", "normal"); element is "normal" — no font_style diff.
        assert tpl.font_style is None
        assert tpl.font_family is None
        assert tpl.font_size is None

    def test_template_text_decoration_normalizes_none_to_empty(self):
        from geometry.element import Text
        from panels.character_panel_state import build_panel_pending_template
        # Element stores "none" (CSS default); panel has both flags off.
        t = Text(x=0, y=0, content="", font_family="sans-serif", font_size=16,
                 font_weight="normal", font_style="normal",
                 text_decoration="none", text_transform="", font_variant="",
                 xml_lang="", rotate="")
        assert build_panel_pending_template(_aligned_panel(), t) is None

    def test_template_font_size_differs(self):
        from panels.character_panel_state import build_panel_pending_template
        panel = {**_aligned_panel(), "font_size": 24.0}
        tpl = build_panel_pending_template(panel, _default_text())
        assert tpl is not None
        assert tpl.font_size == 24.0

    def test_template_underline_flag(self):
        from panels.character_panel_state import build_panel_pending_template
        panel = {**_aligned_panel(), "underline": True}
        tpl = build_panel_pending_template(panel, _default_text())
        assert tpl is not None
        assert tpl.text_decoration == ("underline",)

    def test_template_all_caps_sets_text_transform(self):
        from panels.character_panel_state import build_panel_pending_template
        panel = {**_aligned_panel(), "all_caps": True}
        tpl = build_panel_pending_template(panel, _default_text())
        assert tpl is not None
        assert tpl.text_transform == "uppercase"


class TestBuildPanelFullOverrides:
    def test_sets_every_scope_field(self):
        from panels.character_panel_state import build_panel_full_overrides
        panel = {**_aligned_panel(),
                 "style_name": "Bold",
                 "all_caps": True,
                 "underline": True}
        t = build_panel_full_overrides(panel)
        assert t.font_family == "sans-serif"
        assert t.font_size == 16.0
        assert t.font_weight == "bold"
        assert t.font_style == "normal"
        assert t.text_transform == "uppercase"
        assert t.text_decoration == ("underline",)

    def test_regular_style_forces_normal(self):
        from panels.character_panel_state import build_panel_full_overrides
        t = build_panel_full_overrides({**_aligned_panel(),
                                         "style_name": "Regular"})
        assert t.font_weight == "normal"
        assert t.font_style == "normal"


class TestPendingTemplateComplexAttrs:
    """Phase 3 complex attributes: leading, tracking, baseline-shift
    numeric, anti-aliasing."""

    def _elem(self):
        from geometry.element import Text
        return Text(x=0, y=0, content="",
                    font_family="sans-serif", font_size=16,
                    font_weight="normal", font_style="normal",
                    text_decoration="", text_transform="", font_variant="",
                    baseline_shift="", line_height="", letter_spacing="",
                    xml_lang="", aa_mode="", rotate="")

    def _aligned(self, **overrides):
        base = {
            **_aligned_panel(),
            "leading": 16.0 * 1.2,
            "tracking": 0.0,
            "baseline_shift": 0.0,
            "anti_aliasing": "Sharp",
        }
        base.update(overrides)
        return base

    def test_leading_differs_from_auto(self):
        from panels.character_panel_state import build_panel_pending_template
        tpl = build_panel_pending_template(self._aligned(leading=32.0), self._elem())
        assert tpl is not None
        assert tpl.line_height == 32.0

    def test_tracking_differs_from_zero(self):
        from panels.character_panel_state import build_panel_pending_template
        tpl = build_panel_pending_template(self._aligned(tracking=50.0), self._elem())
        assert tpl is not None
        assert abs(tpl.letter_spacing - 0.05) < 1e-9

    def test_baseline_shift_numeric(self):
        from panels.character_panel_state import build_panel_pending_template
        tpl = build_panel_pending_template(self._aligned(baseline_shift=3.0), self._elem())
        assert tpl is not None
        assert tpl.baseline_shift == 3.0

    def test_baseline_shift_skipped_when_super(self):
        from panels.character_panel_state import build_panel_pending_template
        tpl = build_panel_pending_template(
            self._aligned(superscript=True, baseline_shift=3.0),
            self._elem())
        if tpl is not None:
            assert tpl.baseline_shift is None

    def test_anti_aliasing_differs_from_sharp(self):
        from panels.character_panel_state import build_panel_pending_template
        tpl = build_panel_pending_template(self._aligned(anti_aliasing="Smooth"),
                                            self._elem())
        assert tpl is not None
        assert tpl.jas_aa_mode == "Smooth"


class TestFullOverridesComplexAttrs:
    def test_includes_all_complex_attrs(self):
        from panels.character_panel_state import build_panel_full_overrides
        t = build_panel_full_overrides({**_aligned_panel(),
                                          "leading": 16.0 * 1.2,
                                          "tracking": 0.0,
                                          "baseline_shift": 0.0,
                                          "anti_aliasing": "Sharp"})
        # Full builder always emits these fields.
        assert t.line_height is not None
        assert t.letter_spacing is not None
        assert t.baseline_shift is not None
        assert t.jas_aa_mode is not None


class TestApplyOverridesToTspanRange:
    def test_bolds_partial_word(self):
        from geometry.tspan import Tspan
        from panels.character_panel_state import apply_overrides_to_tspan_range
        base = (Tspan(id=0, content="hello"),)
        overrides = Tspan(font_weight="bold")
        out = apply_overrides_to_tspan_range(base, 1, 4, overrides)
        assert len(out) == 3
        assert out[0].content == "h"
        assert out[1].content == "ell"
        assert out[1].font_weight == "bold"
        assert out[2].content == "o"
        assert out[2].font_weight != "bold"

    def test_empty_range_is_passthrough(self):
        from geometry.tspan import Tspan
        from panels.character_panel_state import apply_overrides_to_tspan_range
        base = [Tspan(id=0, content="hello")]
        overrides = Tspan(font_weight="bold")
        out = apply_overrides_to_tspan_range(base, 2, 2, overrides)
        assert list(out) == base

    def test_merges_adjacent_equal(self):
        from geometry.tspan import Tspan
        from panels.character_panel_state import apply_overrides_to_tspan_range
        base = [Tspan(id=0, content="foo"), Tspan(id=1, content="bar")]
        overrides = Tspan(font_weight="bold")
        out = apply_overrides_to_tspan_range(base, 0, 6, overrides)
        assert len(out) == 1
        assert out[0].content == "foobar"
        assert out[0].font_weight == "bold"


class TestPendingRouting:
    def _make_model_with_session(self, text_elem, caret: int,
                                   has_range: bool = False):
        """Minimal scaffolding: model with a single Text element and
        an active session at the given caret (optionally with a
        range)."""
        from tools.text_edit import EditTarget, TextEditSession

        class _Doc:
            def __init__(self, elem):
                self.layers = []
                self.selection = []
                self._elem = elem

            def get_element(self, path):
                if tuple(path) == (0, 0):
                    return self._elem
                raise KeyError(path)

            def replace_element(self, path, new_elem):
                if tuple(path) == (0, 0):
                    return _Doc(new_elem)
                return self

        class _Model:
            def __init__(self):
                self.document = _Doc(text_elem)
                self.current_edit_session = None
                self.snapshots = 0

            def snapshot(self):
                self.snapshots += 1

        model = _Model()
        session = TextEditSession(
            path=(0, 0), target=EditTarget.TEXT,
            content=text_elem.content, insertion=caret,
        )
        if has_range:
            session.set_insertion(caret + 2, extend=True)
        model.current_edit_session = session
        return model, session

    def test_panel_write_with_bare_caret_sets_pending(self):
        from geometry.element import Text
        from panels.character_panel_state import apply_character_panel_to_selection
        class _Store:
            def __init__(self, state):
                self._state = state
            def get_panel_state(self, _pid):
                return self._state

        text = Text(x=0, y=0, content="hello",
                    font_family="sans-serif", font_size=16,
                    font_weight="normal", font_style="normal",
                    text_decoration="", text_transform="", font_variant="",
                    xml_lang="", rotate="")
        model, session = self._make_model_with_session(text, caret=3)
        assert not session.has_selection()  # sanity
        store = _Store({**_aligned_panel(), "style_name": "Bold"})
        apply_character_panel_to_selection(store, model)
        assert session.has_pending_override()
        assert session.pending_char_start == 3
        assert session.pending_override.font_weight == "bold"

    def test_panel_write_with_range_selection_writes_to_range(self):
        # Range-selected session → per-range tspan write.
        from geometry.element import Text
        from panels.character_panel_state import apply_character_panel_to_selection
        class _Store:
            def __init__(self, state):
                self._state = state
            def get_panel_state(self, _pid):
                return self._state
        text = Text(x=0, y=0, content="hello",
                    font_family="sans-serif", font_size=16,
                    font_weight="normal", font_style="normal",
                    text_decoration="", text_transform="", font_variant="",
                    xml_lang="", rotate="")
        model, session = self._make_model_with_session(text, caret=1)
        session.set_insertion(4, extend=True)  # select [1, 4) → "ell"
        assert session.has_selection()
        store = _Store({**_aligned_panel(), "style_name": "Bold"})
        apply_character_panel_to_selection(store, model)
        # Pending stays unset; the write went to the range's tspans.
        assert not session.has_pending_override()
        elem = model.document.get_element((0, 0))
        # Element-level weight unchanged.
        assert elem.font_weight == "normal"
        # Three tspans: "h" plain, "ell" bold, "o" plain.
        assert len(elem.tspans) == 3
        assert elem.tspans[0].content == "h"
        assert elem.tspans[0].font_weight != "bold"
        assert elem.tspans[1].content == "ell"
        assert elem.tspans[1].font_weight == "bold"
        assert elem.tspans[2].content == "o"
        assert elem.tspans[2].font_weight != "bold"
