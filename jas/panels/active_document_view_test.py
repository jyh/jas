"""Tests for panels.active_document_view.build_active_document_view."""

from __future__ import annotations

import pytest

from document.document import Document, ElementSelection
from document.model import Model
from geometry.element import Layer, Visibility
from panels.active_document_view import build_active_document_view
from workspace_interpreter.expr_types import Value, ValueType


def _make_model(layer_names, selection_paths=()):
    layers = tuple(
        Layer(name=name, children=(), visibility=Visibility.PREVIEW, locked=False)
        for name in layer_names
    )
    selection = frozenset(ElementSelection.all(path=p) for p in selection_paths)
    doc = Document(layers=layers, selected_layer=0, selection=selection)
    return Model(document=doc)


class TestBuildActiveDocumentView:
    def test_no_model_yields_no_selection(self):
        view = build_active_document_view(None)
        assert view["has_selection"] is False
        assert view["selection_count"] == 0
        assert view["element_selection"] == []
        assert view["top_level_layers"] == []
        assert view["next_layer_name"] == "Layer 1"

    def test_empty_selection_yields_no_selection(self):
        model = _make_model(["A"])
        view = build_active_document_view(model)
        assert view["has_selection"] is False
        assert view["selection_count"] == 0
        assert view["element_selection"] == []

    def test_selection_count_matches_selection_length(self):
        model = _make_model(
            ["A"],
            selection_paths=[(0,), (0, 1), (0, 2)],
        )
        view = build_active_document_view(model)
        assert view["has_selection"] is True
        assert view["selection_count"] == 3

    def test_element_selection_contains_path_values_in_sorted_order(self):
        model = _make_model(
            ["A"],
            selection_paths=[(0, 2), (0,)],
        )
        view = build_active_document_view(model)
        entries = view["element_selection"]
        assert len(entries) == 2
        for entry in entries:
            assert isinstance(entry, Value)
            assert entry.type == ValueType.PATH
        assert entries[0].value == (0,)
        assert entries[1].value == (0, 2)

    def test_layers_rollups_populated_from_model(self):
        model = _make_model(["A", "B"])
        view = build_active_document_view(model)
        assert len(view["top_level_layers"]) == 2
        assert view["top_level_layers"][0]["name"] == "A"
        assert view["top_level_layers"][1]["name"] == "B"

    def test_next_layer_name_skips_existing(self):
        model = _make_model(["Layer 1", "Layer 2"])
        view = build_active_document_view(model)
        assert view["next_layer_name"] == "Layer 3"

    def test_layers_panel_selection_count_reflects_argument(self):
        model = _make_model(["A"])
        view = build_active_document_view(
            model, panel_selection=[(0,), (0, 2)]
        )
        assert view["layers_panel_selection_count"] == 2

    def test_new_layer_insert_index_above_selected_top_level(self):
        model = _make_model(["A", "B", "C"])
        view = build_active_document_view(
            model, panel_selection=[(1,)]
        )
        assert view["new_layer_insert_index"] == 2


class TestSyncDocumentToStore:
    """Phase F — sync_document_to_store mirrors jas model.document
    onto the store's ``_document`` dict so dialog cross-scope
    bindings in state_store.get_dialog / set_dialog see live state."""

    def test_sync_populates_artboards(self):
        import dataclasses
        from document.artboard import Artboard
        from document.document import Document
        from panels.active_document_view import sync_document_to_store
        from workspace_interpreter.state_store import StateStore

        a = dataclasses.replace(Artboard.default_with_id("aaaa0001"),
                                 name="Cover", x=10, y=20,
                                 width=300, height=400)
        model = Model(document=Document(artboards=(a,)))
        store = StateStore()
        sync_document_to_store(model, store)
        assert store._document is not None
        abs_ = store._document.get("artboards")
        assert isinstance(abs_, list) and len(abs_) == 1
        assert abs_[0]["id"] == "aaaa0001"
        assert abs_[0]["name"] == "Cover"
        assert abs_[0]["x"] == 10
        assert abs_[0]["width"] == 300

    def test_sync_populates_artboard_options(self):
        import dataclasses
        from document.artboard import ArtboardOptions
        from document.document import Document
        from panels.active_document_view import sync_document_to_store
        from workspace_interpreter.state_store import StateStore

        model = Model(document=Document(
            artboard_options=ArtboardOptions(
                fade_region_outside_artboard=False,
                update_while_dragging=True,
            ),
        ))
        store = StateStore()
        sync_document_to_store(model, store)
        opts = store._document.get("artboard_options")
        assert opts["fade_region_outside_artboard"] is False
        assert opts["update_while_dragging"] is True

    def test_sync_roundtrip_via_active_document_view(self):
        """After sync, store._active_document_view() reports the
        jas model's artboards — that's what get_dialog / set_dialog
        surface to cross-scope expressions."""
        import dataclasses
        from document.artboard import Artboard
        from document.document import Document
        from panels.active_document_view import sync_document_to_store
        from workspace_interpreter.state_store import StateStore

        a = dataclasses.replace(Artboard.default_with_id("aaaa0001"),
                                 name="Cover")
        model = Model(document=Document(artboards=(a,)))
        store = StateStore()
        sync_document_to_store(model, store)
        view = store._active_document_view()
        assert view["artboards_count"] == 1
        assert view["artboards"][0]["id"] == "aaaa0001"
        assert view["artboards"][0]["name"] == "Cover"

    def test_sync_none_model_noop(self):
        from panels.active_document_view import sync_document_to_store
        from workspace_interpreter.state_store import StateStore
        store = StateStore()
        sync_document_to_store(None, store)
        # No crash, no document mutation
        assert store._document is None
