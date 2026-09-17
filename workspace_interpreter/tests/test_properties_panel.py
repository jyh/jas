"""The Properties panel's display sync and its edit subscription (reference arm).

``sync_properties_panel_from_selection`` pushes the selection's values into
the panel's ``prop_*`` keys, and ``subscribe_properties_panel`` applies a
``prop_*`` write back to the selection. The sync's own pushes are not edits:
the sync raises ``_PROPS_SYNCING`` so the subscription skips them.

Until 2026-09-17 the flag covered four of the eight pushes (rotation,
opacity, blend, shear). The x / y / w / h pushes reached the subscription as
edits, so a sync MOVED the selection to its own 2-decimal display value:
x = 10.004 became 10.0. The frozen OCaml port guards all eight; Swift and the
Rust web app read the display on demand and have no loop.
"""

from __future__ import annotations

import os
import sys

_JAS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "jas"))
if _JAS_DIR not in sys.path:
    sys.path.insert(0, _JAS_DIR)

import pytest

from workspace_interpreter import effects
from workspace_interpreter.effects import (
    selection_evaluated_bounds,
    subscribe_properties_panel,
    sync_properties_panel_from_selection,
)
from workspace_interpreter.state_store import StateStore

PID = "properties_panel_content"
FIELDS = ("x", "y", "w", "h", "rotation", "shear", "opacity", "blend")
INIT = {"prop_x": 0, "prop_y": 0, "prop_w": 0, "prop_h": 0, "prop_rotation": 0,
        "prop_shear": 0, "prop_opacity": 100, "prop_blend": "normal",
        "prop_constrain": False}


def _model(**rect):
    from document.document import Document, ElementSelection
    from document.model import Model
    from geometry.element import Layer, Rect
    layer = Layer(children=(Rect(**rect),))
    sel = frozenset({ElementSelection.all((0, 0))})
    return Model(document=Document(layers=(layer,), selection=sel))


def _loaded():
    """A selection whose eight display values all differ from the panel's
    initial values, and whose x / y / w / h are not 2-decimal numbers. A key
    whose display value equals the stored one is never written (the store
    skips an equal write), so an arm over it would pass by construction."""
    from geometry.element import BlendMode, Transform
    t = Transform.rotate(30.0).multiply(Transform.shear(0.25, 0.0))
    return _model(x=10.004, y=20.004, width=30.004, height=40.004,
                  transform=t, opacity=0.5, blend_mode=BlendMode.SCREEN)


def _wired(model):
    store = StateStore()
    store.init_panel(PID, dict(INIT))
    subscribe_properties_panel(store, lambda: model)
    return store


def test_the_fixture_moves_every_display_key():
    model = _loaded()
    store = StateStore()
    store.init_panel(PID, dict(INIT))
    sync_properties_panel_from_selection(store, model)
    moved = [f for f in FIELDS if store.get_panel(PID, f"prop_{f}") != INIT[f"prop_{f}"]]
    assert moved == list(FIELDS), store.get_panel_state(PID)


def test_a_display_sync_applies_nothing(monkeypatch):
    calls = []
    monkeypatch.setattr(effects, "apply_properties_field",
                        lambda ctrl, field, value, constrain=False: calls.append(field))
    model = _loaded()
    store = _wired(model)
    sync_properties_panel_from_selection(store, model)
    assert calls == []


def test_a_display_sync_leaves_the_document_alone():
    model = _loaded()
    store = _wired(model)
    before = model.document
    bounds = selection_evaluated_bounds(before)
    sync_properties_panel_from_selection(store, model)
    assert model.document is before
    assert selection_evaluated_bounds(model.document) == bounds


@pytest.mark.parametrize("field,value", [
    ("x", 100.0), ("y", 50.0), ("w", 60.0), ("h", 80.0),
    ("rotation", 45.0), ("shear", 10.0), ("opacity", 40.0), ("blend", "multiply"),
])
def test_an_edit_outside_the_sync_still_applies(monkeypatch, field, value):
    """The control: the spy records a genuine edit of each key, so an empty
    record above is the guard's doing, not a dead instrument."""
    calls = []
    monkeypatch.setattr(effects, "apply_properties_field",
                        lambda ctrl, f, v, constrain=False: calls.append((f, v)))
    model = _loaded()
    store = _wired(model)
    store.set_panel(PID, f"prop_{field}", value)
    assert calls == [(field, value)]


def test_an_edit_after_a_sync_moves_the_selection():
    """X lands exactly where it was typed, after a sync that would have
    snapped it. The rect carries no transform: see the arm below."""
    model = _model(x=10.004, y=20.004, width=30.004, height=40.004)
    store = _wired(model)
    sync_properties_panel_from_selection(store, model)
    assert selection_evaluated_bounds(model.document)[0] == pytest.approx(10.004, abs=1e-12)
    store.set_panel(PID, "prop_x", 100.0)
    assert selection_evaluated_bounds(model.document)[0] == pytest.approx(100.0, abs=1e-9)


def test_x_on_a_rotated_element_lands_where_it_was_typed():
    """S-3's founding arm, carried here as a strict xfail until 2026-09-17.

    It named the defect exactly — `move_selection` adding the document-space
    delta to LOCAL geometry, so a 30-degree rect typed to x=100 landed at
    83.74 — and instructed its reader to drop the mark once the move became
    transform-aware. `Controller.move_selection` now maps the delta through
    the inverse of the accumulated transform, and the mark is dropped.
    The Rust and Swift moves still read the old way (S-3 step 3).
    """
    from geometry.element import Transform
    model = _model(x=10.0, y=20.0, width=30.0, height=40.0,
                   transform=Transform.rotate(30.0))
    store = _wired(model)
    store.set_panel(PID, "prop_x", 100.0)
    assert selection_evaluated_bounds(model.document)[0] == pytest.approx(100.0, abs=1e-9)


def _model_in_layer(layer_transform, **rect):
    """A single Rect inside a Layer that carries its own transform. The X/Y
    oracle is computed against the EVALUATED bbox, which walks the element's
    transform AND every ancestor's (`_element_evaluated_bbox`), so an ancestor
    transform is part of the same law — and a fix that consults only
    `elem.transform` passes the two arms above and fails this one."""
    from document.document import Document, ElementSelection
    from document.model import Model
    from geometry.element import Layer, Rect
    layer = Layer(children=(Rect(**rect),), transform=layer_transform)
    sel = frozenset({ElementSelection.all((0, 0))})
    return Model(document=Document(layers=(layer,), selection=sel))


def test_y_on_a_rotated_element_lands_where_it_was_typed():
    """S-3, the Y arm. Same cause as the X arm: `move_selection` hands a
    document-space delta to a LOCAL-space mover, so under a rotation the
    bbox travels along the rotated axis and Y lands short."""
    from geometry.element import Transform
    model = _model(x=10.0, y=20.0, width=30.0, height=40.0,
                   transform=Transform.rotate(30.0))
    store = _wired(model)
    store.set_panel(PID, "prop_y", 50.0)
    assert selection_evaluated_bounds(model.document)[1] == pytest.approx(50.0, abs=1e-9)


def test_x_on_a_scaled_element_lands_where_it_was_typed():
    """S-3, the SCALE mechanism, isolated from rotation: a non-unit scale
    changes the delta's MAGNITUDE rather than its direction, so a fix that
    only rotates the delta passes the two rotation arms and fails here."""
    from geometry.element import Transform
    model = _model(x=10.0, y=20.0, width=30.0, height=40.0,
                   transform=Transform.scale(2.0, 3.0))
    store = _wired(model)
    store.set_panel(PID, "prop_x", 100.0)
    assert selection_evaluated_bounds(model.document)[0] == pytest.approx(100.0, abs=1e-9)


def test_x_under_an_ancestor_transform_lands_where_it_was_typed():
    """S-3, the CHAIN mechanism: the ELEMENT is untransformed and its LAYER
    is rotated. A fix reading only `elem.transform` sees an identity here and
    leaves the delta unconverted."""
    from geometry.element import Transform
    model = _model_in_layer(Transform.rotate(30.0),
                            x=10.0, y=20.0, width=30.0, height=40.0)
    store = _wired(model)
    store.set_panel(PID, "prop_x", 100.0)
    assert selection_evaluated_bounds(model.document)[0] == pytest.approx(100.0, abs=1e-9)


def test_an_x_edit_moves_the_selection_and_changes_nothing_else():
    """A translate is a translate: the edit may move the bbox and must not
    resize it or touch the element's transform. Without this, a 'fix' that
    reached the right X by scaling or rotating the element would pass every
    arm above."""
    from geometry.element import Transform
    model = _model(x=10.0, y=20.0, width=30.0, height=40.0,
                   transform=Transform.rotate(30.0))
    store = _wired(model)
    before_t = model.document.get_element((0, 0)).transform
    before_w, before_h = selection_evaluated_bounds(model.document)[2:]
    store.set_panel(PID, "prop_x", 100.0)
    after = selection_evaluated_bounds(model.document)
    assert model.document.get_element((0, 0)).transform == before_t
    assert after[2] == pytest.approx(before_w, abs=1e-9)
    assert after[3] == pytest.approx(before_h, abs=1e-9)


def test_x_on_an_identity_transform_lands_where_it_was_typed():
    """CONTROL, green before and after the S-3 repair: an explicit identity
    transform is the boundary between the transformed and untransformed
    paths, and the conversion must be a no-op on it."""
    from geometry.element import Transform
    model = _model(x=10.0, y=20.0, width=30.0, height=40.0,
                   transform=Transform())
    store = _wired(model)
    store.set_panel(PID, "prop_x", 100.0)
    assert selection_evaluated_bounds(model.document)[0] == pytest.approx(100.0, abs=1e-9)
