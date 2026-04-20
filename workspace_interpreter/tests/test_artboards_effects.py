"""Tests for artboard data model, invariants, and effects.

Covers ARTBOARDS.md phase-1 sub-phase 1: data-model additions to the
StateStore, the at-least-one-artboard invariant with load-time repair,
the ``color_or_transparent`` schema type, the ``doc.create_artboard``
effect, the ``next_artboard_name`` rule, and the artboard fields in the
active-document view.
"""

from __future__ import annotations

import json
import logging
import os
import random
import re

import pytest

from workspace_interpreter.effects import run_effects
from workspace_interpreter.schema import SchemaEntry, coerce_value
from workspace_interpreter.state_store import (
    StateStore,
    _ARTBOARD_ID_ALPHABET,
    _ARTBOARD_ID_LENGTH,
    _default_artboard,
    _generate_artboard_id,
    ensure_artboards_invariant,
    next_artboard_name,
)


FIXTURE_PATH = os.path.join(
    os.path.dirname(__file__), "..", "..", "test_fixtures", "artboards",
    "default_seeded.json",
)


def _seeded_rng(seed: int = 42) -> random.Random:
    return random.Random(seed)


# ══════════════════════════════════════════════════════════════════
# color_or_transparent schema type
# ══════════════════════════════════════════════════════════════════


class TestColorOrTransparentSchemaType:
    def test_accepts_hex_color(self):
        entry = SchemaEntry(type="color_or_transparent", default="transparent")
        out, err = coerce_value("#FFCC00", entry)
        assert err is None
        assert out == "#FFCC00"

    def test_accepts_transparent_literal(self):
        entry = SchemaEntry(type="color_or_transparent", default="transparent")
        out, err = coerce_value("transparent", entry)
        assert err is None
        assert out == "transparent"

    def test_rejects_other_strings(self):
        entry = SchemaEntry(type="color_or_transparent", default="transparent")
        out, err = coerce_value("red", entry)
        assert err == "type_mismatch"
        out, err = coerce_value("Transparent", entry)  # case-sensitive
        assert err == "type_mismatch"

    def test_rejects_numbers(self):
        entry = SchemaEntry(type="color_or_transparent", default="transparent")
        _, err = coerce_value(42, entry)
        assert err == "type_mismatch"

    def test_rejects_short_hex(self):
        entry = SchemaEntry(type="color_or_transparent", default="transparent")
        _, err = coerce_value("#FFF", entry)
        assert err == "type_mismatch"


# ══════════════════════════════════════════════════════════════════
# At-least-one-artboard invariant & load-time repair
# ══════════════════════════════════════════════════════════════════


class TestInvariantAndRepair:
    def test_empty_document_gets_default_artboard(self):
        doc: dict = {}
        repaired = ensure_artboards_invariant(doc, id_generator=lambda: "seedfeed")
        assert repaired is True
        assert len(doc["artboards"]) == 1
        ab = doc["artboards"][0]
        assert ab["name"] == "Artboard 1"
        assert ab["width"] == 612
        assert ab["height"] == 792
        assert ab["x"] == 0
        assert ab["y"] == 0
        assert ab["fill"] == "transparent"
        assert ab["show_center_mark"] is False
        assert ab["show_cross_hairs"] is False
        assert ab["show_video_safe_areas"] is False
        assert ab["video_ruler_pixel_aspect_ratio"] == 1.0
        assert ab["id"] == "seedfeed"

    def test_empty_list_gets_default_artboard(self):
        doc = {"artboards": []}
        repaired = ensure_artboards_invariant(doc, id_generator=lambda: "xxxxxxxx")
        assert repaired is True
        assert len(doc["artboards"]) == 1

    def test_existing_artboard_preserved(self):
        existing = _default_artboard("abc12345", "Cover")
        doc = {"artboards": [existing]}
        repaired = ensure_artboards_invariant(doc)
        assert repaired is False
        assert len(doc["artboards"]) == 1
        assert doc["artboards"][0] is existing

    def test_options_defaults_inserted(self):
        doc = {"artboards": [_default_artboard("id00000a")]}
        ensure_artboards_invariant(doc)
        assert doc["artboard_options"]["fade_region_outside_artboard"] is True
        assert doc["artboard_options"]["update_while_dragging"] is True

    def test_partial_options_filled_in(self):
        doc = {
            "artboards": [_default_artboard("id00000b")],
            "artboard_options": {"fade_region_outside_artboard": False},
        }
        ensure_artboards_invariant(doc)
        assert doc["artboard_options"]["fade_region_outside_artboard"] is False
        assert doc["artboard_options"]["update_while_dragging"] is True


class TestStateStoreLoadRepair:
    def test_statestore_repairs_empty_document(self, caplog):
        caplog.set_level(logging.INFO, logger="workspace_interpreter")
        store = StateStore(
            document={},
            artboard_id_generator=_seeded_rng(42),
        )
        doc = store.document()
        assert doc is not None
        assert len(doc["artboards"]) == 1
        assert doc["artboards"][0]["name"] == "Artboard 1"
        assert any(
            "Document had no artboards; inserted default." in r.message
            for r in caplog.records
        ), "Expected repair log line missing from caplog"

    def test_statestore_repairs_missing_artboards_key(self, caplog):
        caplog.set_level(logging.INFO, logger="workspace_interpreter")
        store = StateStore(document={"layers": []})
        doc = store.document()
        assert doc is not None
        assert "artboards" in doc
        assert len(doc["artboards"]) == 1
        assert any(
            "Document had no artboards; inserted default." in r.message
            for r in caplog.records
        )

    def test_statestore_does_not_repair_non_empty(self, caplog):
        caplog.set_level(logging.INFO, logger="workspace_interpreter")
        existing = _default_artboard("deadbeef", "Existing")
        store = StateStore(document={"artboards": [existing]})
        doc = store.document()
        assert len(doc["artboards"]) == 1
        assert doc["artboards"][0]["id"] == "deadbeef"
        # No log line emitted
        assert not any(
            "Document had no artboards" in r.message
            for r in caplog.records
        )


# ══════════════════════════════════════════════════════════════════
# Id generation
# ══════════════════════════════════════════════════════════════════


class TestArtboardIdGeneration:
    def test_id_is_8_chars_base36(self):
        aid = _generate_artboard_id(_seeded_rng(1))
        assert len(aid) == _ARTBOARD_ID_LENGTH == 8
        assert all(c in _ARTBOARD_ID_ALPHABET for c in aid)

    def test_id_deterministic_with_seed(self):
        rng_a = _seeded_rng(1234)
        rng_b = _seeded_rng(1234)
        assert _generate_artboard_id(rng_a) == _generate_artboard_id(rng_b)

    def test_id_varies_across_seeds(self):
        a = _generate_artboard_id(_seeded_rng(1))
        b = _generate_artboard_id(_seeded_rng(2))
        assert a != b

    def test_id_format_matches_regex(self):
        aid = _generate_artboard_id(_seeded_rng(99))
        assert re.match(r'^[0-9a-z]{8}$', aid) is not None


# ══════════════════════════════════════════════════════════════════
# next_artboard_name rule
# ══════════════════════════════════════════════════════════════════


class TestNextArtboardName:
    def test_empty_list_picks_artboard_1(self):
        assert next_artboard_name([]) == "Artboard 1"

    def test_skips_used_numbers(self):
        artboards = [
            _default_artboard("a", "Artboard 1"),
            _default_artboard("b", "Artboard 2"),
        ]
        assert next_artboard_name(artboards) == "Artboard 3"

    def test_fills_gaps(self):
        artboards = [
            _default_artboard("a", "Artboard 1"),
            _default_artboard("b", "Artboard 3"),
        ]
        assert next_artboard_name(artboards) == "Artboard 2"

    def test_ignores_custom_names(self):
        artboards = [
            _default_artboard("a", "Cover"),
            _default_artboard("b", "Interior"),
        ]
        assert next_artboard_name(artboards) == "Artboard 1"

    def test_case_sensitive_pattern(self):
        """Lowercase "artboard 1" and double-space "Artboard  1" are
        treated as custom names and don't block the default pattern."""
        artboards = [
            _default_artboard("a", "artboard 1"),    # lowercase custom
            _default_artboard("b", "Artboard  1"),   # double-space custom
        ]
        assert next_artboard_name(artboards) == "Artboard 1"

    def test_ignores_non_dict_entries(self):
        artboards = [None, "junk", _default_artboard("a", "Artboard 1")]
        assert next_artboard_name(artboards) == "Artboard 2"


# ══════════════════════════════════════════════════════════════════
# StateStore.create_artboard method
# ══════════════════════════════════════════════════════════════════


class TestCreateArtboardMethod:
    def test_appends_with_fresh_id_and_next_name(self):
        store = StateStore(
            document={"artboards": [_default_artboard("firstone", "Artboard 1")]},
            artboard_id_generator=_seeded_rng(7),
        )
        ab = store.create_artboard()
        assert ab is not None
        assert ab["name"] == "Artboard 2"
        assert ab["id"] != "firstone"
        assert store.document()["artboards"][-1] is ab

    def test_returns_none_without_document(self):
        store = StateStore()
        assert store.create_artboard() is None

    def test_applies_overrides(self):
        store = StateStore(
            document={},
            artboard_id_generator=_seeded_rng(10),
        )
        ab = store.create_artboard({"x": 100, "y": 200, "width": 400})
        assert ab["x"] == 100
        assert ab["y"] == 200
        assert ab["width"] == 400
        # Non-overridden fields stay at defaults
        assert ab["height"] == 792
        assert ab["fill"] == "transparent"

    def test_name_override_wins_over_next_rule(self):
        store = StateStore(document={}, artboard_id_generator=_seeded_rng(11))
        ab = store.create_artboard({"name": "Cover"})
        assert ab["name"] == "Cover"

    def test_empty_name_falls_back_to_next_rule(self):
        store = StateStore(document={}, artboard_id_generator=_seeded_rng(12))
        ab = store.create_artboard({"name": "   "})
        # Blank name falls back to default pattern. Store was repaired with
        # one "Artboard 1" default, so next unused is 2.
        assert ab["name"] == "Artboard 2"

    def test_fresh_id_avoids_collision_with_existing(self):
        # Inject a generator that returns a used id once then a fresh one.
        used = "duplicate"

        class StubGen:
            def __init__(self):
                self.calls = 0

            def choices(self, alphabet, k):
                self.calls += 1
                if self.calls == 1:
                    return list(used)
                return list("unique00")

        doc = {"artboards": [_default_artboard(used, "Artboard 1")]}
        store = StateStore(document=doc, artboard_id_generator=StubGen())
        ab = store.create_artboard()
        assert ab["id"] != used


# ══════════════════════════════════════════════════════════════════
# doc.create_artboard effect
# ══════════════════════════════════════════════════════════════════


class TestDocCreateArtboardEffect:
    def test_effect_appends_artboard(self):
        store = StateStore(document={}, artboard_id_generator=_seeded_rng(20))
        run_effects(
            [{"doc.create_artboard": {}}],
            {}, store,
        )
        # Started with one default (from load repair), now has two.
        assert len(store.document()["artboards"]) == 2

    def test_effect_binds_via_as(self):
        store = StateStore(document={}, artboard_id_generator=_seeded_rng(21))
        # Create an artboard, bind via `as:`, then set a state key from it.
        run_effects(
            [
                {"doc.create_artboard": {}, "as": "new_ab"},
                {"set": {"captured_name": "new_ab.name"}},
            ],
            {}, store,
        )
        assert store.get("captured_name") == "Artboard 2"

    def test_effect_accepts_overrides(self):
        store = StateStore(document={}, artboard_id_generator=_seeded_rng(22))
        run_effects(
            [{"doc.create_artboard": {"width": "300", "height": "400"}}],
            {}, store,
        )
        ab = store.document()["artboards"][-1]
        assert ab["width"] == 300
        assert ab["height"] == 400


# ══════════════════════════════════════════════════════════════════
# Snapshot / undo preserves id
# ══════════════════════════════════════════════════════════════════


class TestSnapshotPreservesId:
    def test_snapshot_captures_ids(self):
        doc = {
            "artboards": [
                _default_artboard("idaaaaaa", "Artboard 1"),
                _default_artboard("idbbbbbb", "Artboard 2"),
            ],
        }
        store = StateStore(document=doc)
        store.snapshot()
        snaps = store.snapshots()
        assert len(snaps) == 1
        assert [a["id"] for a in snaps[0]["artboards"]] == ["idaaaaaa", "idbbbbbb"]

    def test_snapshot_restore_roundtrips_id(self):
        doc = {"artboards": [_default_artboard("idaaaaaa", "Artboard 1")]}
        store = StateStore(document=doc)
        store.snapshot()
        # Mutate: clear artboards, then simulate undo by restoring.
        del store.document()["artboards"][0]
        saved = store.snapshots()[-1]
        store._document.update(saved)  # test-only direct restore
        assert store.document()["artboards"][0]["id"] == "idaaaaaa"


# ══════════════════════════════════════════════════════════════════
# Active document view exposes artboards
# ══════════════════════════════════════════════════════════════════


class TestActiveDocumentView:
    def test_view_exposes_artboards_with_number(self):
        doc = {
            "artboards": [
                _default_artboard("idaaaaaa", "Artboard 1"),
                _default_artboard("idbbbbbb", "Cover"),
            ],
        }
        store = StateStore(document=doc)
        view = store._active_document_view()
        assert view["artboards_count"] == 2
        assert [a["number"] for a in view["artboards"]] == [1, 2]
        assert [a["id"] for a in view["artboards"]] == ["idaaaaaa", "idbbbbbb"]

    def test_view_exposes_options(self):
        doc = {"artboards": [_default_artboard("id00000c")]}
        store = StateStore(document=doc)
        view = store._active_document_view()
        assert view["artboard_options"] == {
            "fade_region_outside_artboard": True,
            "update_while_dragging": True,
        }

    def test_next_artboard_name_in_view(self):
        doc = {
            "artboards": [
                _default_artboard("idaaaaaa", "Artboard 1"),
                _default_artboard("idbbbbbb", "Artboard 3"),
            ],
        }
        store = StateStore(document=doc)
        view = store._active_document_view()
        assert view["next_artboard_name"] == "Artboard 2"

    def test_current_artboard_defaults_to_first(self):
        doc = {
            "artboards": [
                _default_artboard("idaaaaaa", "Artboard 1"),
                _default_artboard("idbbbbbb", "Artboard 2"),
            ],
        }
        store = StateStore(document=doc)
        view = store._active_document_view()
        assert view["current_artboard_id"] == "idaaaaaa"

    def test_current_artboard_respects_panel_selection(self):
        doc = {
            "artboards": [
                _default_artboard("idaaaaaa", "Artboard 1"),
                _default_artboard("idbbbbbb", "Artboard 2"),
                _default_artboard("idcccccc", "Artboard 3"),
            ],
        }
        store = StateStore(document=doc)
        store.init_panel("artboards", {
            "artboards_panel_selection": ["idbbbbbb", "idcccccc"],
        })
        view = store._active_document_view()
        # Topmost of {idbbbbbb, idcccccc} in list order is idbbbbbb.
        assert view["current_artboard_id"] == "idbbbbbb"

    def test_panel_selection_ids_passthrough(self):
        store = StateStore(document={})
        store.init_panel("artboards", {
            "artboards_panel_selection": ["xxx", "yyy"],
        })
        view = store._active_document_view()
        assert view["artboards_panel_selection_ids"] == ["xxx", "yyy"]

    def test_no_document_empty_artboards(self):
        store = StateStore()
        view = store._active_document_view()
        assert view["artboards"] == []
        assert view["artboards_count"] == 0
        assert view["next_artboard_name"] == "Artboard 1"
        assert view["current_artboard_id"] is None
        assert view["artboards_panel_selection_ids"] == []


# ══════════════════════════════════════════════════════════════════
# Default-seeded fixture contract
# ══════════════════════════════════════════════════════════════════


class TestDefaultSeededFixture:
    @pytest.fixture
    def fixture_data(self) -> dict:
        with open(FIXTURE_PATH) as f:
            return json.load(f)

    def _normalize(self, doc: dict) -> dict:
        """Strip ids so two freshly-seeded documents compare equal."""
        out = {k: v for k, v in doc.items() if not k.startswith("_")}
        for a in out.get("artboards", []):
            if isinstance(a, dict) and "id" in a:
                a["id"] = "<placeholder>"
        return out

    def test_fixture_matches_seeded_document(self, fixture_data):
        store = StateStore(
            document={},
            artboard_id_generator=_seeded_rng(1),
        )
        observed = self._normalize(dict(store.document()))
        expected = self._normalize(dict(fixture_data))
        assert observed == expected

    def test_fixture_is_stable(self, fixture_data):
        """Structural sanity: fixture must have exactly one artboard
        with transparent fill at 612x792."""
        assert len(fixture_data["artboards"]) == 1
        ab = fixture_data["artboards"][0]
        assert ab["width"] == 612
        assert ab["height"] == 792
        assert ab["fill"] == "transparent"
        assert fixture_data["artboard_options"]["fade_region_outside_artboard"] is True
        assert fixture_data["artboard_options"]["update_while_dragging"] is True
