"""Tests for the Symbols-panel native action arms (SYMBOLS.md §7, §8).

The mutating symbol ops (new_symbol / place_instance / delete_symbol) mint
ids by the value-in-op rule and call the shared symbol Controller ops, so the
shared YAML actions are ``log`` stubs and the real work lives in these native
arms (like ``menu._link_to_selection`` / Make Instance). Each takes one
snapshot so the op is a single undo step. Mirrors the Rust
``dispatch_action`` symbols intercept.
"""

from __future__ import annotations

from document.document import Document, ElementSelection
from document.model import Model
from geometry.element import Layer, Rect, ReferenceElem, Visibility
from panels.symbols_apply import (
    apply_new_symbol,
    apply_place_instance,
    apply_delete_symbol,
    symbol_usage_count,
)


def _rect(name=None, eid=None):
    return Rect(x=0.0, y=0.0, width=10.0, height=10.0, name=name, id=eid)


def _model(layers, selection_paths=(), symbols=()):
    selection = frozenset(ElementSelection.all(path=p) for p in selection_paths)
    doc = Document(layers=layers, selected_layer=0, selection=selection,
                   symbols=tuple(symbols))
    return Model(document=doc)


class TestNewSymbol:
    def test_promotes_single_selection_to_master(self):
        layer = Layer(name="L", children=(_rect(),))
        model = _model((layer,), selection_paths=[(0, 0)])
        new_id = apply_new_symbol(model)
        # A master was added to the off-canvas store.
        assert len(model.document.symbols) == 1
        # An instance (ReferenceElem) replaced the element in place.
        inst = model.document.layers[0].children[0]
        assert isinstance(inst, ReferenceElem)
        # The new master id is returned so the panel can select it.
        assert new_id == model.document.symbols[0].id
        assert inst.target == new_id

    def test_no_selection_is_noop(self):
        layer = Layer(name="L", children=(_rect(),))
        model = _model((layer,), selection_paths=[])
        assert apply_new_symbol(model) is None
        assert len(model.document.symbols) == 0

    def test_multi_selection_is_noop(self):
        layer = Layer(name="L", children=(_rect(), _rect()))
        model = _model((layer,), selection_paths=[(0, 0), (0, 1)])
        assert apply_new_symbol(model) is None
        assert len(model.document.symbols) == 0

    def test_takes_one_snapshot(self):
        layer = Layer(name="L", children=(_rect(),))
        model = _model((layer,), selection_paths=[(0, 0)])
        before = len(model._undo_stack) if hasattr(model, "_undo_stack") else None
        apply_new_symbol(model)
        # Undo restores the pre-promotion document (single undo step).
        model.undo()
        assert len(model.document.symbols) == 0
        assert isinstance(model.document.layers[0].children[0], Rect)
        _ = before


class TestPlaceInstance:
    def test_appends_instance_of_master(self):
        master = _rect(eid="m1")
        layer = Layer(name="L", children=())
        model = _model((layer,), symbols=[master])
        apply_place_instance(model, "m1")
        children = model.document.layers[0].children
        assert len(children) == 1
        assert isinstance(children[0], ReferenceElem)
        assert children[0].target == "m1"

    def test_none_master_is_noop(self):
        layer = Layer(name="L", children=())
        model = _model((layer,))
        apply_place_instance(model, None)
        assert len(model.document.layers[0].children) == 0


class TestDeleteSymbol:
    def test_removes_master(self):
        master = _rect(eid="m1")
        layer = Layer(name="L", children=())
        model = _model((layer,), symbols=[master])
        apply_delete_symbol(model, "m1")
        assert len(model.document.symbols) == 0

    def test_instances_left_untouched(self):
        master = _rect(eid="m1")
        layer = Layer(name="L", children=(ReferenceElem(target="m1", id="r1"),))
        model = _model((layer,), symbols=[master])
        apply_delete_symbol(model, "m1")
        assert len(model.document.symbols) == 0
        # The instance remains (dangling, recoverable via undo).
        inst = model.document.layers[0].children[0]
        assert isinstance(inst, ReferenceElem)
        assert inst.target == "m1"

    def test_none_master_is_noop(self):
        master = _rect(eid="m1")
        model = _model((Layer(name="L", children=()),), symbols=[master])
        apply_delete_symbol(model, None)
        assert len(model.document.symbols) == 1


class TestUsageCount:
    def test_counts_instances_via_rdeps(self):
        master = _rect(eid="m1")
        layer = Layer(name="L", children=(
            ReferenceElem(target="m1", id="r1"),
            ReferenceElem(target="m1", id="r2"),
        ))
        model = _model((layer,), symbols=[master])
        assert symbol_usage_count(model, "m1") == 2

    def test_zero_when_no_instances(self):
        master = _rect(eid="m1")
        model = _model((Layer(name="L", children=()),), symbols=[master])
        assert symbol_usage_count(model, "m1") == 0
