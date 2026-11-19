#!/usr/bin/env python3
"""Generate test_fixtures/algorithms/tile_selected_in.json from the RULE.

The expected value of each case is computed here by `rule`, a statement of
the law independent of either port (the corpus's `_doc` states it in prose).
Rust (`algorithm_tile_selected_in_vectors`) and Swift
(`testAlgorithmTileSelectedIn`) run the file. Re-run after editing a case:

    python3 scripts/gen_tile_selected_in_fixture.py
"""
import json
from pathlib import Path

FIXTURE = Path(__file__).resolve().parent.parent / "test_fixtures" / "algorithms" / "tile_selected_in.json"

def swatch(scoped=True):
    sel = {"target": "swatch._index", "list": "selected_swatches", "mode": "auto"}
    if scoped:
        sel.update({"scope": "selected_library", "scope_value": "lib.id"})
    return {"id": "sp_swatch_tile", "type": "color_swatch",
            "bind": {"color": "swatch.color", "selected_in": "panel.selected_swatches"},
            "behavior": [{"event": "click", "effects": [{"select": sel}], "action": "set_active_color"},
                         {"event": "double_click", "action": "open_swatch_options"}]}
def brush():
    return {"type": "container", "bind": {"selected_in": "panel.selected_brushes"},
            "behavior": [{"event": "click", "effects": [{"select": {"target": "brush.slug", "list": "selected_brushes",
                          "scope": "selected_library", "scope_value": "lib.id", "mode": "auto"}}]}]}
def sctx(lib, sel_lib, sel, idx):
    return {"panel": {"selected_library": sel_lib, "selected_swatches": sel},
            "lib": {"id": lib}, "swatch": {"_index": idx, "color": "#ff0000"}}
def bctx(lib, sel_lib, sel, slug):
    return {"panel": {"selected_library": sel_lib, "selected_brushes": sel},
            "lib": {"id": lib}, "brush": {"slug": slug}}
# The rule, applied independently of either port:
def rule(el, ctx):
    lst_expr = el.get("bind", {}).get("selected_in")
    if not lst_expr: return False
    sel = None
    for b in el.get("behavior", []):
        for e in b.get("effects", []):
            if "select" in e and "target" in e["select"]:
                sel = e["select"]; break
        if sel: break
    if not sel: return False
    def ev(path):
        v = ctx
        for k in path.split("."):
            if not isinstance(v, dict) or k not in v: return None
            v = v[k]
        return v
    ident = ev(sel["target"]); lst = ev(lst_expr) or []
    if ident not in lst: return False
    if sel.get("scope"):
        cur = ev("panel." + sel["scope"])
        return cur is not None and cur == ev(sel["scope_value"])
    return True

def main():
    doc = json.loads(FIXTURE.read_text(encoding="utf-8"))
    cases = [
     ("swatch_in_list_in_its_library", swatch(), sctx("web_colors", "web_colors", [3], 3)),
     ("swatch_not_in_list", swatch(), sctx("web_colors", "web_colors", [3], 4)),
     ("swatch_same_index_in_another_library_is_not_selected", swatch(), sctx("pastels", "web_colors", [3], 3)),
     ("swatch_second_of_a_multi_selection", swatch(), sctx("web_colors", "web_colors", [1, 3, 5], 5)),
     ("swatch_multi_selection_other_library_none_selected", swatch(), sctx("pastels", "web_colors", [1, 3, 5], 1)),
     ("swatch_scope_never_set_is_not_selected", swatch(), sctx("web_colors", None, [0], 0)),
     ("swatch_empty_list", swatch(), sctx("web_colors", "web_colors", [], 0)),
     ("unscoped_select_reads_membership_alone", swatch(scoped=False), sctx("pastels", "web_colors", [3], 3)),
     ("brush_in_list_in_its_library", brush(), bctx("acme", "acme", ["round"], "round")),
     ("brush_same_slug_in_another_library_is_not_selected", brush(), bctx("other", "acme", ["round"], "round")),
     ("brush_not_in_list", brush(), bctx("acme", "acme", ["round"], "flat")),
    ]
    cases.append(("scope_unresolvable_on_both_sides_is_not_selected", swatch(), {"panel": {"selected_swatches": [3]}, "swatch": {"_index": 3}}))
    no_bind = swatch(); del no_bind["bind"]["selected_in"]
    cases.append(("no_selected_in_bind", no_bind, sctx("web_colors", "web_colors", [3], 3)))
    no_sel = swatch(); no_sel["behavior"] = [{"event": "click", "action": "set_active_color"}]
    cases.append(("no_select_target", no_sel, sctx("web_colors", "web_colors", [3], 3)))
    doc["cases"] = [{"name": n, "element": el, "context": c, "expected": rule(el, c)} for n, el, c in cases]
    FIXTURE.write_text(json.dumps(doc, indent=1) + "\n", encoding="utf-8", newline="")
    print(sum(c["expected"] for c in doc["cases"]), "true of", len(doc["cases"]))


if __name__ == "__main__":
    main()
