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


# ══════════════════════════════════════════════════════════════════
# StateStore artboard helpers (find / delete / set / duplicate)
# ══════════════════════════════════════════════════════════════════


class TestStoreArtboardHelpers:
    def _store(self, ids: list[str]) -> StateStore:
        doc = {"artboards": [_default_artboard(i, f"Artboard {n}") for n, i in enumerate(ids, 1)]}
        return StateStore(document=doc, artboard_id_generator=_seeded_rng(77))

    def test_find_by_id_returns_live_reference(self):
        s = self._store(["aaa", "bbb"])
        ab = s.find_artboard_by_id("bbb")
        assert ab is not None
        assert ab["id"] == "bbb"
        ab["name"] = "Mutated"
        assert s.find_artboard_by_id("bbb")["name"] == "Mutated"

    def test_find_by_id_missing_returns_none(self):
        s = self._store(["aaa"])
        assert s.find_artboard_by_id("does-not-exist") is None

    def test_delete_by_id_removes_and_returns(self):
        s = self._store(["aaa", "bbb", "ccc"])
        deleted = s.delete_artboard_by_id("bbb")
        assert deleted is not None
        assert deleted["id"] == "bbb"
        ids = [a["id"] for a in s.document()["artboards"]]
        assert ids == ["aaa", "ccc"]

    def test_delete_by_id_missing_returns_none(self):
        s = self._store(["aaa"])
        assert s.delete_artboard_by_id("zzz") is None
        assert len(s.document()["artboards"]) == 1

    def test_set_field_writes_and_returns_true(self):
        s = self._store(["aaa"])
        ok = s.set_artboard_field("aaa", "name", "Cover")
        assert ok is True
        assert s.find_artboard_by_id("aaa")["name"] == "Cover"

    def test_set_field_missing_returns_false(self):
        s = self._store(["aaa"])
        ok = s.set_artboard_field("zzz", "name", "Cover")
        assert ok is False

    def test_duplicate_offsets_and_renames(self):
        s = self._store(["aaa"])
        s.find_artboard_by_id("aaa")["x"] = 100
        s.find_artboard_by_id("aaa")["y"] = 200
        dup = s.duplicate_artboard("aaa")
        assert dup is not None
        assert dup["id"] != "aaa"
        # name is not "Artboard 1 copy"; it's the next unused default
        assert dup["name"] == "Artboard 2"
        assert dup["x"] == 120
        assert dup["y"] == 220
        assert len(s.document()["artboards"]) == 2

    def test_duplicate_missing_returns_none(self):
        s = self._store(["aaa"])
        assert s.duplicate_artboard("zzz") is None


# ══════════════════════════════════════════════════════════════════
# doc.* effects
# ══════════════════════════════════════════════════════════════════


class TestDocArtboardEffects:
    def test_delete_by_id_effect(self):
        store = StateStore(
            document={"artboards": [
                _default_artboard("aaa00001", "Artboard 1"),
                _default_artboard("bbb00002", "Artboard 2"),
            ]},
        )
        run_effects(
            [{"doc.delete_artboard_by_id": "'bbb00002'"}],
            {}, store,
        )
        assert [a["id"] for a in store.document()["artboards"]] == ["aaa00001"]

    def test_delete_by_id_binds_via_as(self):
        store = StateStore(
            document={"artboards": [_default_artboard("aaa00001", "Cover")]},
        )
        # Create an extra artboard so we can delete one without tripping invariant.
        run_effects([{"doc.create_artboard": {}}], {}, store, schema=None)
        run_effects(
            [
                {"doc.delete_artboard_by_id": "'aaa00001'", "as": "deleted"},
                {"set": {"deleted_name": "deleted.name"}},
            ],
            {}, store,
        )
        assert store.get("deleted_name") == "Cover"

    def test_duplicate_effect(self):
        store = StateStore(
            document={"artboards": [_default_artboard("aaa00001", "Artboard 1")]},
            artboard_id_generator=_seeded_rng(5),
        )
        run_effects(
            [{"doc.duplicate_artboard": "'aaa00001'"}],
            {}, store,
        )
        assert len(store.document()["artboards"]) == 2
        new_ab = store.document()["artboards"][-1]
        assert new_ab["name"] == "Artboard 2"

    def test_set_field_effect(self):
        store = StateStore(
            document={"artboards": [_default_artboard("aaa00001", "Artboard 1")]},
        )
        run_effects(
            [{"doc.set_artboard_field": {
                "id": "'aaa00001'",
                "field": "name",
                "value": "'Cover'",
            }}],
            {}, store,
        )
        assert store.find_artboard_by_id("aaa00001")["name"] == "Cover"


# ══════════════════════════════════════════════════════════════════
# current_artboard field in active_document view
# ══════════════════════════════════════════════════════════════════


class TestCurrentArtboardView:
    def test_current_is_first_when_no_selection(self):
        store = StateStore(document={"artboards": [
            _default_artboard("aaa", "Artboard 1"),
            _default_artboard("bbb", "Artboard 2"),
        ]})
        view = store._active_document_view()
        assert view["current_artboard"]["id"] == "aaa"
        assert view["current_artboard"]["width"] == 612

    def test_current_follows_panel_selection(self):
        store = StateStore(document={"artboards": [
            _default_artboard("aaa", "Artboard 1"),
            _default_artboard("bbb", "Artboard 2"),
            _default_artboard("ccc", "Artboard 3"),
        ]})
        store.init_panel("artboards", {
            "artboards_panel_selection": ["bbb", "ccc"],
        })
        view = store._active_document_view()
        # Topmost panel-selected in list order is bbb.
        assert view["current_artboard"]["id"] == "bbb"

    def test_current_empty_dict_when_no_document(self):
        store = StateStore()
        view = store._active_document_view()
        assert view["current_artboard"] == {}


# ══════════════════════════════════════════════════════════════════
# CRUD action dispatch (loads real workspace/actions.yaml)
# ══════════════════════════════════════════════════════════════════


import yaml


_ACTIONS_PATH = os.path.join(
    os.path.dirname(__file__), "..", "..", "workspace", "actions.yaml",
)


def _load_actions() -> dict:
    with open(_ACTIONS_PATH) as f:
        data = yaml.safe_load(f)
    return data.get("actions", {})


ACTIONS = _load_actions()


def _run_action(store: StateStore, name: str, params: dict | None = None):
    action = ACTIONS[name]
    effects = action.get("effects", [])
    ctx = {"param": params} if params else {}
    run_effects(effects, ctx, store, actions=ACTIONS)


class TestNewArtboardAction:
    def test_silent_create_offset_when_selection_empty(self):
        store = StateStore(
            document={},  # repaired to 1 default
            artboard_id_generator=_seeded_rng(100),
        )
        store.init_panel("artboards", {"artboards_panel_selection": []})
        store.set_active_panel("artboards")
        _run_action(store, "new_artboard")
        abs_list = store.document()["artboards"]
        assert len(abs_list) == 2
        new_ab = abs_list[-1]
        # No selection → position (0, 0), inherited size from current (first).
        assert new_ab["x"] == 0
        assert new_ab["y"] == 0
        assert new_ab["width"] == 612
        assert new_ab["height"] == 792
        assert new_ab["name"] == "Artboard 2"

    def test_silent_create_inherits_size_from_selected(self):
        store = StateStore(
            document={"artboards": [_default_artboard("aaa", "Artboard 1")]},
            artboard_id_generator=_seeded_rng(101),
        )
        # Resize the existing artboard, then New with it panel-selected.
        store.set_artboard_field("aaa", "width", 400)
        store.set_artboard_field("aaa", "height", 300)
        store.init_panel("artboards", {"artboards_panel_selection": ["aaa"]})
        store.set_active_panel("artboards")
        _run_action(store, "new_artboard")
        abs_list = store.document()["artboards"]
        new_ab = abs_list[-1]
        assert new_ab["width"] == 400
        assert new_ab["height"] == 300
        # Selection non-empty → offset (20, 20) from current.x/y.
        assert new_ab["x"] == 20
        assert new_ab["y"] == 20

    def test_takes_one_snapshot(self):
        store = StateStore(document={}, artboard_id_generator=_seeded_rng(102))
        store.init_panel("artboards", {"artboards_panel_selection": []})
        store.set_active_panel("artboards")
        _run_action(store, "new_artboard")
        assert len(store.snapshots()) == 1

    def test_sets_rearrange_dirty(self):
        store = StateStore(document={}, artboard_id_generator=_seeded_rng(103))
        store.init_panel("artboards", {
            "artboards_panel_selection": [],
            "rearrange_dirty": False,
        })
        store.set_active_panel("artboards")
        _run_action(store, "new_artboard")
        assert store.get_panel("artboards", "rearrange_dirty") is True


class TestDeleteArtboardsAction:
    def test_deletes_selected(self):
        store = StateStore(document={"artboards": [
            _default_artboard("aaa", "Artboard 1"),
            _default_artboard("bbb", "Artboard 2"),
            _default_artboard("ccc", "Artboard 3"),
        ]})
        store.init_panel("artboards", {
            "artboards_panel_selection": ["bbb"],
        })
        store.set_active_panel("artboards")
        _run_action(store, "delete_artboards")
        ids = [a["id"] for a in store.document()["artboards"]]
        assert ids == ["aaa", "ccc"]

    def test_clears_panel_selection_after_delete(self):
        store = StateStore(document={"artboards": [
            _default_artboard("aaa", "Artboard 1"),
            _default_artboard("bbb", "Artboard 2"),
        ]})
        store.init_panel("artboards", {
            "artboards_panel_selection": ["bbb"],
        })
        store.set_active_panel("artboards")
        _run_action(store, "delete_artboards")
        assert store.get_panel("artboards", "artboards_panel_selection") == []

    def test_deletes_multiple(self):
        store = StateStore(document={"artboards": [
            _default_artboard("aaa", "Artboard 1"),
            _default_artboard("bbb", "Artboard 2"),
            _default_artboard("ccc", "Artboard 3"),
            _default_artboard("ddd", "Artboard 4"),
        ]})
        store.init_panel("artboards", {
            "artboards_panel_selection": ["bbb", "ddd"],
        })
        store.set_active_panel("artboards")
        _run_action(store, "delete_artboards")
        ids = [a["id"] for a in store.document()["artboards"]]
        assert ids == ["aaa", "ccc"]

    def test_snapshot_captured_for_undo(self):
        store = StateStore(document={"artboards": [
            _default_artboard("aaa", "Artboard 1"),
            _default_artboard("bbb", "Artboard 2"),
        ]})
        store.init_panel("artboards", {
            "artboards_panel_selection": ["bbb"],
        })
        store.set_active_panel("artboards")
        _run_action(store, "delete_artboards")
        snap = store.snapshots()[-1]
        assert [a["id"] for a in snap["artboards"]] == ["aaa", "bbb"]


class TestDuplicateArtboardsAction:
    def test_duplicates_selected(self):
        store = StateStore(
            document={"artboards": [_default_artboard("aaa", "Artboard 1")]},
            artboard_id_generator=_seeded_rng(200),
        )
        store.init_panel("artboards", {
            "artboards_panel_selection": ["aaa"],
        })
        store.set_active_panel("artboards")
        _run_action(store, "duplicate_artboards")
        abs_list = store.document()["artboards"]
        assert len(abs_list) == 2
        dup = abs_list[-1]
        assert dup["id"] != "aaa"
        assert dup["name"] == "Artboard 2"
        assert dup["x"] == 20
        assert dup["y"] == 20


class TestRenameActions:
    def test_rename_artboard_sets_renaming_panel_key(self):
        store = StateStore(document={"artboards": [
            _default_artboard("aaa", "Artboard 1"),
        ]})
        store.init_panel("artboards", {
            "artboards_panel_selection": ["aaa"],
            "renaming_artboard": None,
        })
        store.set_active_panel("artboards")
        _run_action(store, "rename_artboard", {"artboard_id": "aaa"})
        assert store.get_panel("artboards", "renaming_artboard") == "aaa"

    def test_confirm_writes_new_name_and_clears_renaming(self):
        store = StateStore(document={"artboards": [
            _default_artboard("aaa", "Artboard 1"),
        ]})
        store.init_panel("artboards", {
            "renaming_artboard": "aaa",
        })
        store.set_active_panel("artboards")
        _run_action(store, "confirm_artboard_rename", {
            "artboard_id": "aaa",
            "new_name": "Cover",
        })
        assert store.find_artboard_by_id("aaa")["name"] == "Cover"
        assert store.get_panel("artboards", "renaming_artboard") is None

    def test_confirm_takes_one_snapshot(self):
        store = StateStore(document={"artboards": [
            _default_artboard("aaa", "Artboard 1"),
        ]})
        store.init_panel("artboards", {"renaming_artboard": "aaa"})
        store.set_active_panel("artboards")
        _run_action(store, "confirm_artboard_rename", {
            "artboard_id": "aaa",
            "new_name": "Cover",
        })
        assert len(store.snapshots()) == 1

    def test_cancel_clears_renaming_without_mutating_name(self):
        store = StateStore(document={"artboards": [
            _default_artboard("aaa", "Artboard 1"),
        ]})
        store.init_panel("artboards", {"renaming_artboard": "aaa"})
        store.set_active_panel("artboards")
        _run_action(store, "cancel_artboard_rename")
        assert store.get_panel("artboards", "renaming_artboard") is None
        assert store.find_artboard_by_id("aaa")["name"] == "Artboard 1"


class TestPanelSelectActions:
    def test_select_none_replaces(self):
        store = StateStore(document={"artboards": [
            _default_artboard("aaa"), _default_artboard("bbb"),
        ]})
        store.init_panel("artboards", {
            "artboards_panel_selection": ["aaa"],
            "panel_selection_anchor": "aaa",
        })
        store.set_active_panel("artboards")
        _run_action(store, "artboards_panel_select", {
            "artboard_id": "bbb",
            "modifier": "none",
        })
        assert store.get_panel("artboards", "artboards_panel_selection") == ["bbb"]
        assert store.get_panel("artboards", "panel_selection_anchor") == "bbb"

    def test_select_all(self):
        store = StateStore(document={"artboards": [
            _default_artboard("aaa"),
            _default_artboard("bbb"),
            _default_artboard("ccc"),
        ]})
        store.init_panel("artboards", {"artboards_panel_selection": []})
        store.set_active_panel("artboards")
        _run_action(store, "artboards_select_all")
        assert sorted(store.get_panel("artboards", "artboards_panel_selection")) == [
            "aaa", "bbb", "ccc"
        ]


# ══════════════════════════════════════════════════════════════════
# Reorder: swap-with-neighbor-skipping-selected rule
# ══════════════════════════════════════════════════════════════════


class TestReorderSwapRule:
    def _store(self, count: int) -> StateStore:
        doc = {"artboards": [
            _default_artboard(f"id{i:06d}", f"Artboard {i}")
            for i in range(1, count + 1)
        ]}
        return StateStore(document=doc, artboard_id_generator=_seeded_rng(9000))

    def _ids(self, store: StateStore) -> list[str]:
        return [a["id"] for a in store.document()["artboards"]]

    def test_move_up_single_middle_row(self):
        s = self._store(3)
        changed = s.move_artboards_up(["id000002"])
        assert changed is True
        assert self._ids(s) == ["id000002", "id000001", "id000003"]

    def test_move_up_row_at_top_is_noop(self):
        s = self._store(3)
        changed = s.move_artboards_up(["id000001"])
        assert changed is False
        assert self._ids(s) == ["id000001", "id000002", "id000003"]

    def test_move_up_contiguous_block_moves_together(self):
        """Rows 3 and 4 both selected → each swaps with its upper
        non-selected neighbor. The pair slides up as a unit."""
        s = self._store(5)
        changed = s.move_artboards_up(["id000003", "id000004"])
        assert changed is True
        assert self._ids(s) == [
            "id000001", "id000003", "id000004", "id000002", "id000005",
        ]

    def test_move_up_discontiguous_1_3_5(self):
        """The canonical spec example. Selection {1, 3, 5} + Move Up
        → row 1 stays (top), row 3 swaps with 2, row 5 swaps with 4.
        Result: [1, 3, 2, 5, 4]."""
        s = self._store(5)
        changed = s.move_artboards_up(["id000001", "id000003", "id000005"])
        assert changed is True
        assert self._ids(s) == [
            "id000001", "id000003", "id000002", "id000005", "id000004",
        ]

    def test_move_up_all_selected_is_noop(self):
        """If every row is selected, every upper neighbor is also
        selected, so every swap is skipped."""
        s = self._store(4)
        all_ids = self._ids(s)
        changed = s.move_artboards_up(all_ids)
        assert changed is False
        assert self._ids(s) == all_ids

    def test_move_down_symmetric_middle_row(self):
        s = self._store(3)
        changed = s.move_artboards_down(["id000002"])
        assert changed is True
        assert self._ids(s) == ["id000001", "id000003", "id000002"]

    def test_move_down_row_at_bottom_is_noop(self):
        s = self._store(3)
        changed = s.move_artboards_down(["id000003"])
        assert changed is False
        assert self._ids(s) == ["id000001", "id000002", "id000003"]

    def test_move_down_discontiguous_1_3(self):
        """Selection {1, 3} + Move Down → row 3 swaps with 4 first,
        then row 1 swaps with 2. Result: [2, 1, 4, 3, 5]."""
        s = self._store(5)
        changed = s.move_artboards_down(["id000001", "id000003"])
        assert changed is True
        assert self._ids(s) == [
            "id000002", "id000001", "id000004", "id000003", "id000005",
        ]

    def test_empty_selection_is_noop(self):
        s = self._store(3)
        ids_before = self._ids(s)
        assert s.move_artboards_up([]) is False
        assert s.move_artboards_down([]) is False
        assert self._ids(s) == ids_before

    def test_non_existent_id_is_ignored(self):
        s = self._store(3)
        ids_before = self._ids(s)
        assert s.move_artboards_up(["does-not-exist"]) is False
        assert self._ids(s) == ids_before


class TestMoveActions:
    def test_move_up_action_takes_one_snapshot(self):
        store = StateStore(document={"artboards": [
            _default_artboard("aaa", "Artboard 1"),
            _default_artboard("bbb", "Artboard 2"),
            _default_artboard("ccc", "Artboard 3"),
        ]})
        store.init_panel("artboards", {
            "artboards_panel_selection": ["bbb"],
        })
        store.set_active_panel("artboards")
        _run_action(store, "move_artboard_up")
        assert [a["id"] for a in store.document()["artboards"]] == ["bbb", "aaa", "ccc"]
        assert len(store.snapshots()) == 1

    def test_move_down_action_symmetric(self):
        store = StateStore(document={"artboards": [
            _default_artboard("aaa", "Artboard 1"),
            _default_artboard("bbb", "Artboard 2"),
            _default_artboard("ccc", "Artboard 3"),
        ]})
        store.init_panel("artboards", {
            "artboards_panel_selection": ["bbb"],
        })
        store.set_active_panel("artboards")
        _run_action(store, "move_artboard_down")
        assert [a["id"] for a in store.document()["artboards"]] == ["aaa", "ccc", "bbb"]

    def test_move_action_sets_rearrange_dirty(self):
        store = StateStore(document={"artboards": [
            _default_artboard("aaa", "Artboard 1"),
            _default_artboard("bbb", "Artboard 2"),
        ]})
        store.init_panel("artboards", {
            "artboards_panel_selection": ["bbb"],
            "rearrange_dirty": False,
        })
        store.set_active_panel("artboards")
        _run_action(store, "move_artboard_up")
        assert store.get_panel("artboards", "rearrange_dirty") is True


class TestPanelSelectionTracksIdAcrossReorder:
    def test_selection_follows_artboard_across_move(self):
        """ART-107: panel-selection is by id, so it follows the
        artboard across a reorder, not a fixed position."""
        store = StateStore(document={"artboards": [
            _default_artboard("aaa", "Artboard 1"),
            _default_artboard("bbb", "Artboard 2"),
            _default_artboard("ccc", "Artboard 3"),
        ]})
        store.init_panel("artboards", {
            "artboards_panel_selection": ["ccc"],
        })
        store.set_active_panel("artboards")
        # Move ccc up twice: ccc → position 2, then position 1.
        _run_action(store, "move_artboard_up")
        _run_action(store, "move_artboard_up")
        assert [a["id"] for a in store.document()["artboards"]] == ["ccc", "aaa", "bbb"]
        assert store.get_panel("artboards", "artboards_panel_selection") == ["ccc"]
        # current_artboard still ccc (topmost panel-selected).
        assert store._active_document_view()["current_artboard_id"] == "ccc"


class TestResetPanelAction:
    def test_reset_clears_selection_and_restores_reference_point(self):
        store = StateStore(document={"artboards": [_default_artboard("aaa")]})
        store.init_panel("artboards", {
            "artboards_panel_selection": ["aaa"],
            "panel_selection_anchor": "aaa",
            "reference_point": "top_left",
        })
        store.set_active_panel("artboards")
        _run_action(store, "reset_artboards_panel")
        assert store.get_panel("artboards", "artboards_panel_selection") == []
        assert store.get_panel("artboards", "panel_selection_anchor") is None
        assert store.get_panel("artboards", "reference_point") == "center"


# ══════════════════════════════════════════════════════════════════
# Anchor-offset builtins (reference-point display transform)
# ══════════════════════════════════════════════════════════════════


class TestAnchorOffsetBuiltins:
    def _eval(self, expr: str) -> float:
        from workspace_interpreter.expr import evaluate
        r = evaluate(expr, {})
        return r.value

    def test_center_half_width(self):
        assert self._eval("anchor_offset_x('center', 612)") == 306
        assert self._eval("anchor_offset_y('center', 792)") == 396

    def test_top_left_zero(self):
        assert self._eval("anchor_offset_x('top_left', 612)") == 0
        assert self._eval("anchor_offset_y('top_left', 792)") == 0

    def test_bottom_right_full_size(self):
        assert self._eval("anchor_offset_x('bottom_right', 612)") == 612
        assert self._eval("anchor_offset_y('bottom_right', 792)") == 792

    def test_middle_left_half_y_zero_x(self):
        assert self._eval("anchor_offset_x('middle_left', 612)") == 0
        assert self._eval("anchor_offset_y('middle_left', 792)") == 396

    def test_top_center_half_x_zero_y(self):
        assert self._eval("anchor_offset_x('top_center', 612)") == 306
        assert self._eval("anchor_offset_y('top_center', 792)") == 0


# ══════════════════════════════════════════════════════════════════
# doc.set_artboard_options_field effect
# ══════════════════════════════════════════════════════════════════


class TestDocSetArtboardOptionsField:
    def test_writes_document_global_toggle(self):
        store = StateStore(
            document={"artboards": [_default_artboard("aaa")]},
        )
        run_effects(
            [{"doc.set_artboard_options_field": {
                "field": "fade_region_outside_artboard",
                "value": "false",
            }}],
            {}, store,
        )
        assert store.document()["artboard_options"]["fade_region_outside_artboard"] is False

    def test_writes_update_while_dragging(self):
        store = StateStore(
            document={"artboards": [_default_artboard("aaa")]},
        )
        run_effects(
            [{"doc.set_artboard_options_field": {
                "field": "update_while_dragging",
                "value": "false",
            }}],
            {}, store,
        )
        assert store.document()["artboard_options"]["update_while_dragging"] is False


# ══════════════════════════════════════════════════════════════════
# Artboard Options dialog open / confirm round-trip
# ══════════════════════════════════════════════════════════════════


_WORKSPACE_PATH = os.path.join(
    os.path.dirname(__file__), "..", "..", "workspace",
)


def _load_dialogs() -> dict:
    """Load dialogs from the workspace dir to support open_dialog."""
    path = os.path.join(_WORKSPACE_PATH, "dialogs")
    dialogs: dict = {}
    for fname in sorted(os.listdir(path)):
        if not fname.endswith(".yaml"):
            continue
        with open(os.path.join(path, fname)) as f:
            data = yaml.safe_load(f)
        if isinstance(data, dict):
            dialogs.update(data)
    return dialogs


DIALOGS = _load_dialogs()


def _run_dialog_action(store: StateStore, name: str, params: dict | None = None):
    action = ACTIONS[name]
    effects = action.get("effects", [])
    ctx = {"param": params} if params else {}
    run_effects(effects, ctx, store, actions=ACTIONS, dialogs=DIALOGS)


class TestArtboardOptionsDialog:
    def _prepared_store(self, **ab_overrides) -> StateStore:
        ab = _default_artboard("aaa", "Artboard 1")
        ab.update(ab_overrides)
        store = StateStore(document={"artboards": [ab]})
        store.init_panel("artboards", {
            "artboards_panel_selection": ["aaa"],
            "reference_point": "center",
        })
        store.set_active_panel("artboards")
        return store

    def test_open_populates_dialog_state_from_artboard(self):
        store = self._prepared_store(width=400, height=300, name="Cover")
        _run_dialog_action(store, "open_artboard_options", {
            "artboard_id": "aaa",
        })
        assert store.get_dialog_id() == "artboard_options"
        assert store.get_dialog("name") == "Cover"
        assert store.get_dialog("width") == 400
        assert store.get_dialog("height") == 300

    def test_open_pulls_global_options(self):
        store = self._prepared_store()
        _run_dialog_action(store, "open_artboard_options", {
            "artboard_id": "aaa",
        })
        assert store.get_dialog("fade_region_outside_artboard") is True
        assert store.get_dialog("update_while_dragging") is True

    def test_confirm_writes_all_fields(self):
        store = self._prepared_store()
        _run_dialog_action(store, "open_artboard_options", {
            "artboard_id": "aaa",
        })
        _run_dialog_action(store, "artboard_options_confirm", {
            "artboard_id": "aaa",
            "name": "Cover",
            "x": 100,
            "y": 200,
            "width": 400,
            "height": 300,
            "fill": "#ffcc00",
            "show_center_mark": True,
            "show_cross_hairs": False,
            "show_video_safe_areas": True,
            "video_ruler_pixel_aspect_ratio": 1.5,
            "fade_region_outside_artboard": False,
            "update_while_dragging": False,
        })
        ab = store.find_artboard_by_id("aaa")
        assert ab["name"] == "Cover"
        assert ab["x"] == 100
        assert ab["y"] == 200
        assert ab["width"] == 400
        assert ab["height"] == 300
        assert ab["fill"] == "#ffcc00"
        assert ab["show_center_mark"] is True
        assert ab["show_video_safe_areas"] is True
        assert ab["video_ruler_pixel_aspect_ratio"] == 1.5
        assert store.document()["artboard_options"]["fade_region_outside_artboard"] is False
        assert store.document()["artboard_options"]["update_while_dragging"] is False

    def test_confirm_takes_one_snapshot(self):
        store = self._prepared_store()
        _run_dialog_action(store, "open_artboard_options", {
            "artboard_id": "aaa",
        })
        _run_dialog_action(store, "artboard_options_confirm", {
            "artboard_id": "aaa",
            "name": "X",
            "x": 0, "y": 0,
            "width": 612, "height": 792,
            "fill": "transparent",
            "show_center_mark": False,
            "show_cross_hairs": False,
            "show_video_safe_areas": False,
            "video_ruler_pixel_aspect_ratio": 1.0,
            "fade_region_outside_artboard": True,
            "update_while_dragging": True,
        })
        assert len(store.snapshots()) == 1

    def test_confirm_closes_dialog(self):
        store = self._prepared_store()
        _run_dialog_action(store, "open_artboard_options", {
            "artboard_id": "aaa",
        })
        assert store.get_dialog_id() == "artboard_options"
        _run_dialog_action(store, "artboard_options_confirm", {
            "artboard_id": "aaa",
            "name": "X",
            "x": 0, "y": 0,
            "width": 612, "height": 792,
            "fill": "transparent",
            "show_center_mark": False,
            "show_cross_hairs": False,
            "show_video_safe_areas": False,
            "video_ruler_pixel_aspect_ratio": 1.0,
            "fade_region_outside_artboard": True,
            "update_while_dragging": True,
        })
        assert store.get_dialog_id() is None

    def test_reference_point_widget_transforms_display(self):
        """ART-199: with anchor = center, X=306 Y=396 displays for
        an artboard at top-left (0, 0) size 612x792."""
        store = self._prepared_store()
        _run_dialog_action(store, "open_artboard_options", {
            "artboard_id": "aaa",
        })
        # dialog.x_rp is a computed prop. Reading evaluates the get
        # expression against dialog state + panel.reference_point.
        x_rp = store.get_dialog("x_rp")
        y_rp = store.get_dialog("y_rp")
        assert x_rp == 306   # 0 + 612/2
        assert y_rp == 396   # 0 + 792/2

    def test_reference_point_top_left_displays_raw(self):
        store = self._prepared_store()
        store.set_panel("artboards", "reference_point", "top_left")
        _run_dialog_action(store, "open_artboard_options", {
            "artboard_id": "aaa",
        })
        assert store.get_dialog("x_rp") == 0
        assert store.get_dialog("y_rp") == 0


# ══════════════════════════════════════════════════════════════════
# Phase-1 deferrals and blue-dot (rearrange_dirty) flag
# ══════════════════════════════════════════════════════════════════


class TestRearrangeDirtyBlueDot:
    """ART-334: the REARRANGE_BUTTON's accent dot fires on first list
    change and — in phase 1 — remains lit (the Rearrange Dialogue
    that would clear it is deferred)."""

    def _store(self, ids: list[str]) -> StateStore:
        doc = {"artboards": [_default_artboard(i, f"Artboard {n}") for n, i in enumerate(ids, 1)]}
        store = StateStore(document=doc, artboard_id_generator=_seeded_rng(333))
        store.init_panel("artboards", {
            "artboards_panel_selection": [],
            "rearrange_dirty": False,
        })
        store.set_active_panel("artboards")
        return store

    def test_fresh_panel_flag_starts_false(self):
        store = self._store(["aaa"])
        assert store.get_panel("artboards", "rearrange_dirty") is False

    def test_new_artboard_flips_flag(self):
        store = self._store(["aaa"])
        _run_action(store, "new_artboard")
        assert store.get_panel("artboards", "rearrange_dirty") is True

    def test_duplicate_flips_flag(self):
        store = self._store(["aaa"])
        store.set_panel("artboards", "artboards_panel_selection", ["aaa"])
        _run_action(store, "duplicate_artboards")
        assert store.get_panel("artboards", "rearrange_dirty") is True

    def test_delete_flips_flag(self):
        store = self._store(["aaa", "bbb"])
        store.set_panel("artboards", "artboards_panel_selection", ["bbb"])
        _run_action(store, "delete_artboards")
        assert store.get_panel("artboards", "rearrange_dirty") is True

    def test_move_up_flips_flag(self):
        store = self._store(["aaa", "bbb"])
        store.set_panel("artboards", "artboards_panel_selection", ["bbb"])
        _run_action(store, "move_artboard_up")
        assert store.get_panel("artboards", "rearrange_dirty") is True

    def test_move_down_flips_flag(self):
        store = self._store(["aaa", "bbb"])
        store.set_panel("artboards", "artboards_panel_selection", ["aaa"])
        _run_action(store, "move_artboard_down")
        assert store.get_panel("artboards", "rearrange_dirty") is True

    def test_flag_sticks_across_multiple_changes(self):
        """Phase-1: no Dialogue exists to clear the flag, so it stays
        lit after the first change."""
        store = self._store(["aaa"])
        _run_action(store, "new_artboard")
        assert store.get_panel("artboards", "rearrange_dirty") is True
        _run_action(store, "new_artboard")
        assert store.get_panel("artboards", "rearrange_dirty") is True


class TestPhase1DeferralsPanelYaml:
    """Structural tests against workspace/panels/artboards.yaml that
    the deferred menu / footer / context-menu entries are present
    and grayed."""

    @pytest.fixture
    def panel(self) -> dict:
        path = os.path.join(
            _WORKSPACE_PATH, "panels", "artboards.yaml",
        )
        with open(path) as f:
            return yaml.safe_load(f)

    def test_menu_convert_grayed(self, panel):
        menu = panel.get("menu", [])
        entry = next(m for m in menu if isinstance(m, dict) and m.get("label") == "Convert to Artboards")
        assert entry.get("enabled_when") == "false"
        assert "Coming soon" in entry.get("description", "")

    def test_menu_rearrange_grayed(self, panel):
        menu = panel.get("menu", [])
        entry = next(m for m in menu if isinstance(m, dict) and m.get("label") == "Rearrange...")
        assert entry.get("enabled_when") == "false"
        assert "Coming soon" in entry.get("description", "")

    def test_footer_rearrange_grayed_with_badge(self, panel):
        content = panel.get("content", {})
        footer = next(c for c in content.get("children", []) if isinstance(c, dict) and c.get("id") == "ap_footer")
        rearrange = next(ch for ch in footer.get("children", []) if isinstance(ch, dict) and ch.get("id") == "ap_rearrange")
        assert rearrange.get("bind", {}).get("disabled") == "true"
        assert rearrange.get("bind", {}).get("badge") == "panel.rearrange_dirty"
        assert rearrange.get("description") == "Coming soon"

    def test_context_menu_exists_on_rows(self, panel):
        content = panel.get("content", {})
        list_container = next(c for c in content.get("children", []) if isinstance(c, dict) and c.get("id") == "ap_list")
        row = list_container.get("do", {})
        ctx_menu = row.get("context_menu")
        assert ctx_menu is not None
        labels = [m.get("label") for m in ctx_menu if isinstance(m, dict)]
        assert "Artboard Options..." in labels
        assert "Rename" in labels
        assert "Duplicate Artboards" in labels
        assert "Delete Artboards" in labels
        assert "Convert to Artboards" in labels

    def test_context_menu_convert_is_grayed(self, panel):
        content = panel.get("content", {})
        list_container = next(c for c in content.get("children", []) if isinstance(c, dict) and c.get("id") == "ap_list")
        row = list_container.get("do", {})
        ctx_menu = row.get("context_menu", [])
        convert = next(m for m in ctx_menu if isinstance(m, dict) and m.get("label") == "Convert to Artboards")
        assert convert.get("enabled_when") == "false"
        assert convert.get("tooltip") == "Coming soon"


class TestDeleteArtboardFromDialog:
    def test_deletes_and_closes(self):
        store = StateStore(document={"artboards": [
            _default_artboard("aaa", "Artboard 1"),
            _default_artboard("bbb", "Artboard 2"),
        ]})
        store.init_panel("artboards", {"artboards_panel_selection": ["aaa"]})
        store.set_active_panel("artboards")
        _run_dialog_action(store, "open_artboard_options", {
            "artboard_id": "aaa",
        })
        _run_dialog_action(store, "delete_artboard_from_dialog", {
            "artboard_id": "aaa",
        })
        assert [a["id"] for a in store.document()["artboards"]] == ["bbb"]
        assert store.get_dialog_id() is None
