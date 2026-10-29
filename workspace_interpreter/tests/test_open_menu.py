"""`open_menu: { id }`, the request to pop up a declared menu item's submenu
(the 2026-10-28 jas brush-library design, A.3). The interpreter records the
request as the store's `pending_menu`; the host pops it up. Row for row with
JasSwift's OpenMenuEffectTests."""

import pytest

from workspace_interpreter.effects import run_effects
from workspace_interpreter.state_store import StateStore


def _run(*effects):
    store = StateStore()
    run_effects(list(effects), {}, store)
    return store


def test_a_new_store_has_no_pending_menu():
    assert StateStore().pending_menu is None


def test_the_mapping_form_records_its_id():
    assert _run({"open_menu": {"id": "bp_menu_open_library"}}).pending_menu == "bp_menu_open_library"


def test_the_bare_form_records_its_id():
    assert _run({"open_menu": "bp_menu_open_library"}).pending_menu == "bp_menu_open_library"


def test_the_id_is_a_literal_not_an_expression():
    # `param.x` would evaluate to something else; it is recorded as written.
    assert _run({"open_menu": {"id": "param.x"}}).pending_menu == "param.x"


@pytest.mark.parametrize("spec", [{"id": ""}, {}, {"id": 3}, "", None, 7])
def test_an_empty_or_non_string_id_records_nothing(spec):
    assert _run({"open_menu": spec}).pending_menu is None


def test_a_later_request_replaces_an_earlier_one():
    store = _run({"open_menu": {"id": "first"}}, {"open_menu": {"id": "second"}})
    assert store.pending_menu == "second"


def test_an_empty_request_leaves_an_earlier_one():
    store = _run({"open_menu": {"id": "first"}}, {"open_menu": {"id": ""}})
    assert store.pending_menu == "first"
