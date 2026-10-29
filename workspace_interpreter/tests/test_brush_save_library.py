"""`brush.save_library: { library, name }` -- Save Brush Library's confirm.

Design: the 2026-10-28 jas brush-library design, B.2. Both operands are
EXPRESSIONS. In order: (1) a slug from the name (lower-case ASCII letters and
digits kept, every other run becomes one `_`, ends trimmed, `library` if
nothing is left); (2) the source's own slug saves IN PLACE, another existing
slug takes the first free `_2`, `_3`, ...; (3) data.brush_libraries[slug] is a
deep copy of the source with `name` set, and a NEW library opens (expanded)
and becomes the selected library, its brush selection kept; (4) one
`{kind, slug, manifest}` request is appended to the store's `pending_writes`,
which the host drains: the interpreter itself writes no file. An empty name,
or a missing source, is a no-op in every part. Each arm has its own store.
"""

import copy

import pytest

from workspace_interpreter.effects import run_effects
from workspace_interpreter.state_store import StateStore

_LIBS = {
    "default_brushes": {"name": "Default Brushes", "brushes": [{"slug": "basic", "name": "Basic"}]},
    "my_brushes": {"name": "My Brushes", "brushes": []},
    "my_brushes_2": {"name": "My Brushes 2", "brushes": []},
}


def _save(name, library="default_brushes", libs=None):
    store = StateStore()
    store.set_data({"brush_libraries": copy.deepcopy(_LIBS if libs is None else libs)})
    store.init_panel("brushes", {
        "selected_library": library, "selected_brushes": ["basic"],
        "open_libraries": [{"id": "default_brushes", "collapsed": True}],
    })
    store.set_active_panel("brushes")
    run_effects([{"brush.save_library": {"library": "param.lib", "name": "param.name"}}],
                {"param": {"lib": library, "name": name}}, store)
    return store


def _libs(store):
    return store.get_data_path("brush_libraries")


def _panel(store, key):
    return store.get_panel("brushes", key)


# (name typed, slug expected). Each row's slug is distinct from every other's.
SLUG_ROWS = [
    ("Calligraphy Set", "calligraphy_set"),
    ("  Ink -- & Wash!  ", "ink_wash"),
    ("Über 7", "ber_7"),
    ("--- !!! ---", "library"),
    # ASCII-only lower-casing: the Kelvin sign is NOT a "k" here, though
    # Python's str.lower() would make it one.
    ("\u212aelvin", "elvin"),
]


@pytest.mark.parametrize("name,slug", SLUG_ROWS)
def test_the_slug_is_derived_from_the_name(name, slug):
    store = _save(name)
    assert slug in _libs(store)
    assert _libs(store)[slug]["name"] == name


def test_the_slug_rows_are_pairwise_distinct():
    slugs = [s for _, s in SLUG_ROWS]
    assert len(set(slugs)) == len(slugs)


def test_a_new_library_is_a_deep_copy_with_the_new_name():
    store = _save("Calligraphy Set")
    new = _libs(store)["calligraphy_set"]
    assert new == {"name": "Calligraphy Set", "brushes": [{"slug": "basic", "name": "Basic"}]}
    new["brushes"][0]["name"] = "changed"
    assert _libs(store)["default_brushes"]["brushes"][0]["name"] == "Basic"
    assert _libs(store)["default_brushes"]["name"] == "Default Brushes"


def test_a_new_library_opens_expanded_and_becomes_the_selection():
    store = _save("Calligraphy Set")
    assert _panel(store, "open_libraries") == [
        {"id": "default_brushes", "collapsed": True}, {"id": "calligraphy_set", "collapsed": False}]
    assert _panel(store, "selected_library") == "calligraphy_set"
    assert _panel(store, "selected_brushes") == ["basic"]


def test_the_sources_own_slug_saves_in_place():
    store = _save("Default Brushes!")
    assert set(_libs(store)) == set(_LIBS)
    assert _libs(store)["default_brushes"]["name"] == "Default Brushes!"
    assert _panel(store, "open_libraries") == [{"id": "default_brushes", "collapsed": True}]
    assert _panel(store, "selected_library") == "default_brushes"


def test_another_librarys_slug_takes_the_first_free_suffix():
    # my_brushes and my_brushes_2 both exist, so the first free one is _3.
    store = _save("My Brushes")
    assert "my_brushes_3" in _libs(store)
    assert _libs(store)["my_brushes"] == _LIBS["my_brushes"]


def test_the_suffix_starts_at_2():
    libs = {k: v for k, v in _LIBS.items() if k != "my_brushes_2"}
    store = _save("My Brushes", libs=libs)
    assert "my_brushes_2" in _libs(store)


def test_one_write_request_is_queued_for_the_host():
    store = _save("Calligraphy Set")
    assert store.pending_writes == [{
        "kind": "brush_library", "slug": "calligraphy_set",
        "manifest": {"name": "Calligraphy Set", "brushes": [{"slug": "basic", "name": "Basic"}]},
    }]


def test_an_in_place_save_queues_the_sources_slug():
    store = _save("Default Brushes")
    assert [w["slug"] for w in store.pending_writes] == ["default_brushes"]


def test_the_queued_manifest_is_not_the_live_library():
    store = _save("Calligraphy Set")
    _libs(store)["calligraphy_set"]["name"] = "edited later"
    assert store.pending_writes[0]["manifest"]["name"] == "Calligraphy Set"


@pytest.mark.parametrize("name,library", [("", "default_brushes"), (None, "default_brushes"),
                                          ("X", "nowhere"), ("X", None)])
def test_an_empty_name_or_a_missing_source_is_a_no_op(name, library):
    store = _save(name, library=library)
    assert _libs(store) == _LIBS
    assert store.pending_writes == []
    assert _panel(store, "open_libraries") == [{"id": "default_brushes", "collapsed": True}]


def test_a_fresh_store_has_no_pending_writes():
    assert StateStore().pending_writes == []
