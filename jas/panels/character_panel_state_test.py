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
