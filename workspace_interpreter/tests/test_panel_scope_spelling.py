"""One panel scope per panel, whatever the spelling.

WHY THIS FILE EXISTS
--------------------
The workspace YAML names a panel's state scope by its SHORT kind at every
effect site — ``set_panel_state: { panel: brushes, … }`` (36 sites across
nine panels) — while every panel map in the compiled bundle, and therefore
``panel_state_defaults`` and the ``panel.<key>`` reads a panel's own widgets
make, is keyed by the CONTENT id (``brushes_panel_content``). jas_dioxus keys
its generic table by the content id and normalises the short form at the
write (``panel_menu::panel_content_id``); JasSwift normalised inside its
``set_panel_state`` effect and nowhere else, so its native artboard verbs
wrote ``"artboards"`` while the YAML's writes landed in
``artboards_panel_content`` — two buckets for one selection. This reference
normalised NOWHERE: ``set_panel_state`` wrote the short name verbatim, and
``set_panel`` on a scope nobody had initialised returned silently, so every
short-spelled YAML write was a no-op here — invisible, because the reference's
own tests seeded the scopes by the same short names the actions used
(``init_panel("artboards", …)``, ``set_active_panel("layers")``), and the
active-document view read ``_panels["layers"]`` back by that spelling.

THE RULE, applied at the STORE BOUNDARY in all three interpreters: a panel id
without the ``_panel_content`` suffix gains it; one that carries it passes
through. Both spellings address ONE scope for init, read, write, subscribe,
the active panel, and the active-document view. The rule is not new — it is
the one jas_dioxus applied at its write — it is now the store's, so no caller
can spell its way into a second bucket.
"""
from __future__ import annotations

import os

from workspace_interpreter.effects import run_effects
from workspace_interpreter.state_store import StateStore, panel_content_id

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def test_panel_content_id_normalises_both_spellings():
    """The rule itself, with the identity half as the control: a full id
    must pass through unchanged, or the rule would double the suffix."""
    assert panel_content_id("brushes") == "brushes_panel_content"
    assert panel_content_id("brushes_panel_content") == "brushes_panel_content"
    assert panel_content_id("magic_wand") == "magic_wand_panel_content"


def test_short_and_full_spellings_address_one_scope():
    store = StateStore()
    store.init_panel("swatches_panel_content", {"thumbnail_size": "small", "selected_swatches": []})
    store.set_panel("swatches", "thumbnail_size", "large")
    assert store.get_panel("swatches_panel_content", "thumbnail_size") == "large"
    assert store.get_panel("swatches", "thumbnail_size") == "large"
    assert store.get_panel_state("swatches") == store.get_panel_state("swatches_panel_content")
    # …and initialising by the SHORT name seeds the content scope.
    store.init_panel("color", {"mode": "hsb"})
    assert store.get_panel("color_panel_content", "mode") == "hsb"


def test_set_panel_state_effect_spelled_short_lands_in_the_content_scope():
    """The YAML's own spelling, through the generic effect: before the store
    normalised, this write went to a scope nothing had initialised and
    ``set_panel`` dropped it on the floor."""
    store = StateStore()
    store.init_panel("brushes_panel_content", {"view_mode": "thumbnail"})
    run_effects(
        [{"set_panel_state": {"panel": "brushes", "key": "view_mode", "value": '"list"'}}],
        {}, store,
    )
    assert store.get_panel("brushes_panel_content", "view_mode") == "list"


def test_active_panel_spelled_short_reads_the_content_scope():
    """``set_active_panel("layers")`` and the scope initialised as
    ``layers_panel_content`` are the same panel: the expression context's
    ``panel`` namespace and the active-document view's layers-panel rollups
    both read it."""
    store = StateStore(document={"layers": [{"kind": "Layer", "name": "L0", "children": []}]})
    store.init_panel("layers_panel_content", {
        "layers_panel_selection": [{"__path__": [0]}],
        "isolation_stack": [],
    })
    store.set_active_panel("layers")
    ctx = store.eval_context()
    assert ctx["panel"]["isolation_stack"] == []
    assert ctx["active_document"]["layers_panel_selection_count"] == 1
    assert ctx["active_document"]["layers_panel_selection_is_container"] is True
    assert store.get_active_panel_id() == "layers_panel_content"
    # The other way round too: initialised short, activated by the content id.
    store2 = StateStore(document={"layers": [{"kind": "Layer", "name": "L0", "children": []}]})
    store2.init_panel("layers", {"layers_panel_selection": [{"__path__": [0]}]})
    store2.set_active_panel("layers_panel_content")
    assert store2.eval_context()["active_document"]["layers_panel_selection_count"] == 1


def test_subscribers_follow_the_one_scope():
    seen = []
    store = StateStore()
    store.init_panel("stroke", {"cap": "butt"})
    store.subscribe_panel("stroke_panel_content", lambda k, v: seen.append((k, v)))
    store.set_panel("stroke", "cap", "round")
    assert seen == [("cap", "round")]
    store.destroy_panel("stroke")
    assert store.get_panel_state("stroke_panel_content") == {}
