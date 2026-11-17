"""`swatch.save_library: { library, name }` -- Save Swatch Library's confirm.

Design: the 2026-10-28 jas brush-library design, §3.4 (Swatches onto the same
primitives). The rules are `brush.save_library`'s (test_brush_save_library.py),
over `data.swatch_libraries` and the Swatches panel: the same slug, in place on
the source's own slug, else the first free `_2`, `_3`, ...; a NEW library is a
deep copy named as typed, opened expanded and selected (the swatch selection,
indices into an identical copy, kept); one `{kind: swatch_library, slug,
manifest}` request on `pending_writes`. An empty name or a missing source is a
no-op. Each arm has its own store.
"""

import copy

import pytest

from workspace_interpreter.effects import run_effects
from workspace_interpreter.state_store import StateStore

_LIBS = {
    "web_colors": {"name": "Web Colors", "swatches": [{"name": "Red", "color": "#ff0000"}]},
    "my_swatches": {"name": "My Swatches", "swatches": []},
}


def _save(name, library="web_colors", libs=None):
    store = StateStore()
    store.set_data({"swatch_libraries": copy.deepcopy(_LIBS if libs is None else libs)})
    store.init_panel("swatches", {
        "selected_library": library, "selected_swatches": [0],
        "open_libraries": [{"id": "web_colors", "collapsed": True}],
    })
    store.set_active_panel("swatches")
    run_effects([{"swatch.save_library": {"library": "param.lib", "name": "param.name"}}],
                {"param": {"lib": library, "name": name}}, store)
    return store


def _libs(store):
    return store.get_data_path("swatch_libraries")


def _panel(store, key):
    return store.get_panel("swatches", key)


def test_a_new_library_is_a_deep_copy_named_as_typed_opened_and_selected():
    store = _save("Sunset Palette")
    new = _libs(store)["sunset_palette"]
    assert new == {"name": "Sunset Palette", "swatches": [{"name": "Red", "color": "#ff0000"}]}
    new["swatches"][0]["name"] = "changed"
    assert _libs(store)["web_colors"] == _LIBS["web_colors"]
    assert _panel(store, "open_libraries") == [
        {"id": "web_colors", "collapsed": True}, {"id": "sunset_palette", "collapsed": False}]
    assert _panel(store, "selected_library") == "sunset_palette"
    assert _panel(store, "selected_swatches") == [0]


def test_the_sources_own_slug_saves_in_place():
    store = _save("Web  Colors!")
    assert set(_libs(store)) == set(_LIBS)
    assert _libs(store)["web_colors"]["name"] == "Web  Colors!"
    assert _panel(store, "selected_library") == "web_colors"
    assert _panel(store, "open_libraries") == [{"id": "web_colors", "collapsed": True}]


def test_another_librarys_slug_takes_the_first_free_suffix():
    store = _save("My Swatches")
    assert "my_swatches_2" in _libs(store)
    assert _libs(store)["my_swatches"] == _LIBS["my_swatches"]


def test_one_write_request_of_kind_swatch_library_is_queued():
    store = _save("Sunset Palette")
    assert store.pending_writes == [{
        "kind": "swatch_library", "slug": "sunset_palette",
        "manifest": {"name": "Sunset Palette", "swatches": [{"name": "Red", "color": "#ff0000"}]},
    }]
    _libs(store)["sunset_palette"]["name"] = "edited later"
    assert store.pending_writes[0]["manifest"]["name"] == "Sunset Palette", "a snapshot"


def test_the_slug_is_brushes_slug():
    # One slug law for both library kinds: the Kelvin sign is not a "k".
    store = _save("Kelvin & Co")
    assert "elvin_co" in _libs(store)


@pytest.mark.parametrize("name,library", [("", "web_colors"), (None, "web_colors"),
                                          ("X", "nowhere"), ("X", None)])
def test_an_empty_name_or_a_missing_source_is_a_no_op(name, library):
    store = _save(name, library=library)
    assert _libs(store) == _LIBS
    assert store.pending_writes == []
    assert _panel(store, "open_libraries") == [{"id": "web_colors", "collapsed": True}]


def test_a_brush_save_does_not_touch_the_swatch_libraries():
    store = _save("Sunset Palette")
    store.set_data_path("brush_libraries", {"b": {"name": "B", "brushes": []}})
    run_effects([{"brush.save_library": {"library": "'b'", "name": "'Sunset Palette'"}}], {}, store)
    assert "sunset_palette" in store.get_data_path("brush_libraries")
    assert [w["kind"] for w in store.pending_writes] == ["swatch_library", "brush_library"]
