"""The four orphan-confirm dialogs say how many live instances an act leaves
empty, with the noun agreeing with the count.

Until 2026-10-14 the noun was `{{ param.count == 1 ? "instance" : "instances" }}`.
No port's parser accepts `a ? b : c`, so it evaluated to null and the
message read "...leave 2 live  empty." `check_state_reads` did not see it,
because the string names no state head; it now refuses an unparseable
expression of any head."""

import os

import pytest
import yaml

from workspace_interpreter.expr import evaluate_text

DIALOGS = os.path.join(os.path.dirname(__file__), "..", "..", "workspace", "dialogs")
ORPHAN_DIALOGS = ["cut_orphan_confirm", "delete_layer_orphan_confirm",
                  "delete_orphan_confirm", "delete_symbol_orphan_confirm"]


def _message(dialog_id):
    with open(os.path.join(DIALOGS, dialog_id + ".yaml"), encoding="utf-8") as f:
        spec = yaml.safe_load(f)[dialog_id]
    texts = [c["content"] for c in spec["content"]["children"]
             if isinstance(c, dict) and "{{" in str(c.get("content", ""))
             and "param.count" in str(c.get("content", ""))]
    assert len(texts) == 1, f"{dialog_id}: expected one count message, found {len(texts)}"
    return texts[0]


@pytest.mark.parametrize("dialog_id", ORPHAN_DIALOGS)
@pytest.mark.parametrize("count,noun", [(1, "instance"), (2, "instances")])
def test_the_noun_agrees_with_the_count(dialog_id, count, noun):
    text = evaluate_text(_message(dialog_id), {"param": {"count": count}})
    assert f"{count} live {noun} empty." in text, text
