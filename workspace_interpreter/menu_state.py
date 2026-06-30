"""Menu enabled/checked evaluation (TESTING_STRATEGY.md chrome seam).

Pure, headless evaluation of every menubar item's ``enabled_when`` /
``checked_when`` predicate against a supplied context, producing a
language-neutral per-item ``{enabled, checked}`` record. This is the cross-app
byte-gate behind the menu's DYNAMIC state: all apps must build the same
context and evaluate the same bundle expressions to the same booleans, so a
menu item that grays out (or shows a check mark) in one app does so in every
app.

Mirrors :mod:`workspace_interpreter.widget_tree`: every field is read straight
from the compiled bundle ``menubar``, and the ONLY thing evaluated is each
item's ``enabled_when`` / ``checked_when`` expression (no live widgets). The
native ports bake an identical pre-order walk.

The context namespaces (the live renderers build these from real app state;
the corpus seeds them directly):
  * ``state.tab_count``           — open-document count
  * ``active_document.{has_selection, selection_count, can_undo, can_redo,
      is_modified, has_filename}``
  * ``workspace.has_saved_layout``
  * ``panels.<panel_id>``         — bool, the panel's current visibility
  * ``panes.<pane_id>``           — bool, the pane's current visibility
"""

from __future__ import annotations

from .expr import evaluate


def _eval_bool(expr: str, ctx: dict) -> bool:
    """Evaluate ``expr`` against ``ctx`` and coerce to bool via the shared
    expression evaluator's truthiness (``evaluate`` never raises — it returns
    ``Value.null()`` on error, which ``to_bool`` reports as False)."""
    return evaluate(expr, ctx).to_bool()


def menu_state(menubar: list, ctx: dict) -> list[dict]:
    """Walk the compiled ``menubar`` and evaluate each action item's
    ``enabled_when`` / ``checked_when`` against ``ctx``.

    Returns a flat pre-order list of ``{path, action, enabled, checked}`` for
    every action item. Separators (bare ``"separator"`` strings) and the
    submenu nodes themselves are skipped; submenu CHILDREN are walked with an
    extended path so their predicates (e.g. ``workspace.has_saved_layout`` on
    Revert to Saved) are covered. ``enabled`` defaults to True when there is no
    ``enabled_when``; ``checked`` is the evaluated bool when ``checked_when`` is
    present, else ``None``.
    """
    out: list[dict] = []

    def _walk(items: list, prefix: list[int]) -> None:
        for i, item in enumerate(items):
            path = prefix + [i]
            if not isinstance(item, dict):
                continue  # bare "separator"
            if "items" in item:
                _walk(item["items"], path)  # submenu: recurse into children
                continue
            ew = item.get("enabled_when")
            cw = item.get("checked_when")
            out.append({
                "path": path,
                "action": item.get("action", ""),
                "enabled": _eval_bool(ew, ctx) if ew else True,
                "checked": _eval_bool(cw, ctx) if cw else None,
            })

    for m, menu in enumerate(menubar):
        _walk(menu.get("items", []), [m])
    return out
