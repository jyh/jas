"""`gradient.save_library: { library, name }` -- Save Gradient Library's confirm.

Design: 2026-11-17 jas gradient-library tier, §2. The law is
`brush.save_library`'s / `swatch.save_library`'s over `data.gradient_libraries`,
with ONE difference: the Gradient panel shows one library at a time, so a NEW
library becomes the ACTIVE one (`panel.active_library_id`) instead of being
appended to an open list. The write it queues is `{kind: gradient_library,
slug, manifest}`. An empty name or a missing source is a no-op.
"""

import copy

import pytest

from workspace_interpreter.effects import run_effects
from workspace_interpreter.state_store import StateStore

_LIBS = {
    "neutrals": {"name": "Neutrals", "description": "d", "gradients": [{"name": "Black to White", "type": "linear"}]},
    "spectrums": {"name": "Spectrums", "gradients": []},
}


def _save(name, library="neutrals"):
    store = StateStore()
    store.set_data({"gradient_libraries": copy.deepcopy(_LIBS)})
    store.init_panel("gradient", {"active_library_id": library})
    store.set_active_panel("gradient")
    run_effects([{"gradient.save_library": {"library": "param.lib", "name": "param.name"}}],
                {"param": {"lib": library, "name": name}}, store)
    return store


def _libs(store):
    return store.get_data_path("gradient_libraries")


def test_a_new_library_is_a_copy_named_as_typed_and_becomes_active():
    store = _save("Warm Tones")
    assert _libs(store)["warm_tones"] == {
        "name": "Warm Tones", "description": "d", "gradients": [{"name": "Black to White", "type": "linear"}]}
    assert _libs(store)["neutrals"] == _LIBS["neutrals"]
    assert store.get_panel("gradient", "active_library_id") == "warm_tones"
    assert store.get_panel("gradient", "open_libraries") is None, "no open list on this panel"


def test_the_sources_own_slug_saves_in_place_and_stays_active():
    store = _save("Neutrals!")
    assert set(_libs(store)) == set(_LIBS)
    assert _libs(store)["neutrals"]["name"] == "Neutrals!"
    assert store.get_panel("gradient", "active_library_id") == "neutrals"


def test_another_librarys_slug_takes_the_first_free_suffix():
    store = _save("Spectrums")
    assert "spectrums_2" in _libs(store)
    assert store.get_panel("gradient", "active_library_id") == "spectrums_2"


def test_one_write_of_kind_gradient_library_is_queued():
    store = _save("Warm Tones")
    assert [(w["kind"], w["slug"]) for w in store.pending_writes] == [("gradient_library", "warm_tones")]
    assert store.pending_writes[0]["manifest"]["name"] == "Warm Tones"


@pytest.mark.parametrize("name,library", [("", "neutrals"), (None, "neutrals"), ("X", "nowhere"), ("X", None)])
def test_an_empty_name_or_a_missing_source_is_a_no_op(name, library):
    store = _save(name, library=library)
    assert _libs(store) == _LIBS
    assert store.pending_writes == []
