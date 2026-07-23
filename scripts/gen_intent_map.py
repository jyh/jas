#!/usr/bin/env python3
"""Generate the reachable-intent map for the ACTION seam (dispatch_action).

Reads workspace/workspace.json (as committed -- never regenerates it), walks
every action's full effect tree, and classifies each action by whether it can
reach a `doc.*` effect verb that journals through `op_apply`. Emits two
committed artifacts:

  intent_map.json   -- the machine enumeration
  INTENT_MAP.md     -- the human summary (scope note, per-class lists,
                       verb -> journaling evidence table)

This generator is the authoritative enumeration behind OP_LOG.md's prose
claim of the actions.yaml <-> op_apply unification ("26 journaling verbs");
no hand-maintained list exists anywhere else.

Usage:
  python scripts/gen_intent_map.py                 # write both repo-root artifacts
  python scripts/gen_intent_map.py --json X --md Y # write to explicit paths
  python scripts/gen_intent_map.py --self-test     # assertions only, no writes

The verb -> journaling table below is AUTHORED, with file:line evidence read
from the Rust reference implementation (jas_dioxus). The walk itself is
generic: dicts/lists are recursed exhaustively (effects arrays, if/then/else
branches, foreach bodies, created-element subtrees, unknown node shapes),
and `dispatch` effects are followed transitively across actions (cycle-safe).
"""

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
WORKSPACE_JSON = REPO_ROOT / "workspace" / "workspace.json"

EXPECTED_TOTAL_ACTIONS = 236

# ---------------------------------------------------------------------------
# The AUTHORED verb -> journaling table.
#
# "journals" values:
#   "always"      -- routing through op_apply records a real op whenever the
#                    effect runs (subject only to the arm's own malformed-
#                    payload / no-op-edit skips, which record nothing).
#   "param-gated" -- routes through op_apply ONLY when the CALL SITE carries a
#                    literal `journal: true` param (OP_LOG.md par.9 Phase P7:
#                    the CONFIRM/PREVIEW boundary). Classified per call site,
#                    statically -- every bundle value is a literal.
#   "never"       -- the effect never records an op through op_apply (view
#                    state, preview channel, transaction management, direct
#                    field writes, or pure ctx binders).
#
# Evidence is file:line into the Rust reference implementation at the time of
# authoring (2026-07-22, post `five-port-parity`):
#   effects.rs  = jas_dioxus/src/interpreter/effects.rs   (run_doc_effect)
#   renderer.rs = jas_dioxus/src/interpreter/renderer.rs  (run_yaml_effect +
#                 the effects.rs delegation fallback at renderer.rs:3893-3921)
#   op_apply.rs = jas_dioxus/src/document/op_apply.rs     (op_apply dispatch;
#                 record_op at op_apply.rs:1908)
VERB_TABLE = {
    # -- unconditional journaling: renderer.rs run_yaml_effect arms ---------
    "doc.create_artboard": {
        "journals": "always", "op": "create_artboard",
        "evidence": ["renderer.rs:3100-3136", "op_apply.rs:1863"],
    },
    "doc.delete_artboard_by_id": {
        "journals": "always", "op": "delete_artboard_by_id",
        "evidence": ["renderer.rs:3150-3159", "op_apply.rs:1832"],
    },
    "doc.duplicate_artboard": {
        "journals": "always", "op": "duplicate_artboard",
        "evidence": ["renderer.rs:3176-3229", "op_apply.rs:1876"],
    },
    "doc.set_artboard_field": {
        "journals": "always", "op": "set_artboard_field",
        "evidence": ["renderer.rs:3241-3265", "op_apply.rs:1802"],
    },
    "doc.set_artboard_options_field": {
        "journals": "always", "op": "set_artboard_options_field",
        "evidence": ["renderer.rs:3273-3290", "op_apply.rs:1817"],
    },
    "doc.set_print_preferences_field": {
        "journals": "always", "op": "set_print_preferences_field",
        "evidence": ["renderer.rs:3326-3367", "op_apply.rs:1775 (PRINT_CONFIG_VERBS)"],
    },
    "doc.set_marks_and_bleed_field": {
        "journals": "always", "op": "set_marks_and_bleed_field",
        "evidence": ["renderer.rs:3326-3367", "op_apply.rs:1775 (PRINT_CONFIG_VERBS)"],
    },
    "doc.set_output_field": {
        "journals": "always", "op": "set_output_field",
        "evidence": ["renderer.rs:3326-3367", "op_apply.rs:1775 (PRINT_CONFIG_VERBS)"],
    },
    "doc.set_output_ink_field": {
        "journals": "always", "op": "set_output_ink_field",
        "evidence": ["renderer.rs:3326-3367", "op_apply.rs:1775 (PRINT_CONFIG_VERBS)"],
    },
    "doc.set_graphics_field": {
        "journals": "always", "op": "set_graphics_field",
        "evidence": ["renderer.rs:3326-3367", "op_apply.rs:1775 (PRINT_CONFIG_VERBS)"],
    },
    "doc.set_color_management_field": {
        "journals": "always", "op": "set_color_management_field",
        "evidence": ["renderer.rs:3326-3367", "op_apply.rs:1775 (PRINT_CONFIG_VERBS)"],
    },
    "doc.set_document_setup_field": {
        "journals": "always", "op": "set_document_setup_field",
        "evidence": ["renderer.rs:3326-3367", "op_apply.rs:1775 (PRINT_CONFIG_VERBS)"],
    },
    "doc.set_advanced_field": {
        "journals": "always", "op": "set_advanced_field",
        "evidence": ["renderer.rs:3326-3367", "op_apply.rs:1775 (PRINT_CONFIG_VERBS)"],
    },
    "doc.move_artboards_up": {
        "journals": "always", "op": "move_artboards_up",
        "evidence": ["renderer.rs:3378-3384", "op_apply.rs:1842"],
    },
    "doc.move_artboards_down": {
        "journals": "always", "op": "move_artboards_down",
        "evidence": ["renderer.rs:3390-3396", "op_apply.rs:1849"],
    },
    "doc.delete_at": {
        "journals": "always", "op": "delete_at",
        "evidence": ["renderer.rs:3440-3463", "op_apply.rs:1554"],
    },
    "doc.delete_selection": {
        "journals": "always", "op": "delete_selection",
        "evidence": ["renderer.rs:3508-3513", "op_apply.rs:1564"],
    },
    "doc.insert_after": {
        "journals": "always", "op": "insert_after",
        "evidence": ["renderer.rs:3545-3564", "op_apply.rs:1571"],
    },
    "doc.insert_at": {
        "journals": "always", "op": "insert_at",
        "evidence": ["renderer.rs:3675-3706", "op_apply.rs:1578"],
    },
    "doc.wrap_in_group": {
        "journals": "always", "op": "wrap_in_group",
        "evidence": ["renderer.rs:3642-3664", "op_apply.rs:1601"],
    },
    "doc.wrap_in_layer": {
        "journals": "always", "op": "wrap_in_layer",
        "evidence": ["renderer.rs:3599-3631", "op_apply.rs:1615"],
    },
    "doc.unpack_group_at": {
        "journals": "always", "op": "unpack_group_at",
        "evidence": ["renderer.rs:3576-3587", "op_apply.rs:1632"],
    },
    # -- unconditional journaling: effects.rs run_doc_effect arms -----------
    "doc.set_attr_on_selection": {
        "journals": "always", "op": "set_attr_on_selection",
        "evidence": ["effects.rs:901-946", "op_apply.rs:1676"],
    },
    "doc.translate_selection": {
        "journals": "always", "op": "move_selection",
        "evidence": ["effects.rs:767-785", "op_apply.rs:1394"],
    },
    "doc.copy_selection": {
        "journals": "always", "op": "copy_selection",
        "evidence": ["effects.rs:948-961", "op_apply.rs:1397"],
    },
    "doc.select_in_rect": {
        "journals": "always", "op": "select_rect",
        "note": ("selection-only / non-undoable: op_apply records it only "
                 "into an ALREADY-OPEN transaction and never opens one "
                 "(op_apply.rs:1329-1336), so a bare marquee stays "
                 "journal-neutral"),
        "evidence": ["effects.rs:987-1013", "op_apply.rs:1380"],
    },
    # -- param-gated journaling (OP_LOG.md par.9 Phase P7) ------------------
    "doc.scale.apply": {
        "journals": "param-gated", "op": "scale_transform",
        "evidence": ["effects.rs:1619-1656 (gate at :1651)", "op_apply.rs:1710"],
    },
    "doc.rotate.apply": {
        "journals": "param-gated", "op": "rotate_transform",
        "evidence": ["effects.rs:1658-1683 (gate at :1678)", "op_apply.rs:1725"],
    },
    "doc.shear.apply": {
        "journals": "param-gated", "op": "shear_transform",
        "evidence": ["effects.rs:1685-1717 (gate at :1711)", "op_apply.rs:1735"],
    },
    # -- never journals ------------------------------------------------------
    "doc.snapshot": {
        "journals": "never",
        "note": ("transaction management: begin_txn only; snapshot/undo/redo "
                 "manage the journal cursor and are never journaled as ops"),
        "evidence": ["effects.rs:682-684", "op_apply.rs:1300-1314"],
    },
    "doc.preview.restore": {
        "journals": "never",
        "note": "out-of-band preview-snapshot channel (OP_LOG.md par.8)",
        "evidence": ["effects.rs:703-708"],
    },
    "doc.preview.clear": {
        "journals": "never",
        "note": "out-of-band preview-snapshot channel (OP_LOG.md par.8)",
        "evidence": ["effects.rs:709-714"],
    },
    "doc.zoom.apply": {
        "journals": "never", "note": "view state only (zoom/pan)",
        "evidence": ["effects.rs:1719-1768"],
    },
    "doc.zoom.set": {
        "journals": "never", "note": "view state only (zoom/pan)",
        "evidence": ["effects.rs:1770-1795"],
    },
    "doc.zoom.fit_rect": {
        "journals": "never", "note": "view state only (zoom/pan)",
        "evidence": ["effects.rs:1869-1881"],
    },
    "doc.zoom.fit_elements": {
        "journals": "never", "note": "view state only (zoom/pan)",
        "evidence": ["effects.rs:1914-1933"],
    },
    "doc.zoom.fit_all_artboards": {
        "journals": "never", "note": "view state only (zoom/pan)",
        "evidence": ["effects.rs:1935-1956"],
    },
    "doc.set": {
        "journals": "never",
        "note": ("direct per-field document write via apply_doc_set_field; "
                 "not routed through op_apply, so it records no op"),
        "evidence": ["renderer.rs:3709-3728"],
    },
    "doc.clone_at": {
        "journals": "never",
        "note": "pure ctx binder: clones an element into scope, no mutation",
        "evidence": ["renderer.rs:3516-3534"],
    },
    "doc.create_layer": {
        "journals": "never",
        "note": ("pure ctx binder: deterministic Layer factory bound via "
                 "`as:`; the subsequent doc.insert_at journals"),
        "evidence": ["renderer.rs:3401-3430"],
    },
}

# Classes for actions that reach doc.* verbs but never journal.
VIEW_PREFIXES = ("doc.zoom.", "doc.pan.")
PREVIEW_CHANNEL_VERBS = {
    "doc.preview.capture", "doc.preview.restore", "doc.preview.clear",
}
PARAM_GATED_VERBS = {
    v for v, row in VERB_TABLE.items() if row["journals"] == "param-gated"
}

CLASS_DEFINITIONS = {
    "journaling": (
        "reaches at least one doc.* verb that journals through op_apply "
        "(unconditional, or param-gated with a literal `journal: true` at "
        "the call site)"),
    "tool-lifecycle": (
        "select_tool ONLY: the action itself is a bare "
        "`set: {active_tool}`, but tool activation runs the outgoing "
        "tool's on_leave, which MAY journal (pen.yaml conditionally emits "
        "doc.snapshot + doc.add_path_from_anchor_buffer to commit an "
        "in-progress path). Annotation class -- classified statically, "
        "never executed"),
    "native-intercept": (
        "declared in the bundle's native_intercepts list; the native app "
        "handles it before/instead of YAML effects (no actions-map effect "
        "tree to classify)"),
    "view": (
        "reaches doc.* verbs, all of them zoom/pan view-state writes; "
        "never touches the document or the journal"),
    "preview": (
        "the dialog preview channel: reaches only the out-of-band "
        "preview-snapshot verbs (doc.preview.*) plus a param-gated "
        "transform apply WITHOUT `journal: true`; document changes ride "
        "the preview snapshot, never the journal"),
    "doc-direct": (
        "reaches doc.* verbs that write the document (or bind document "
        "values) WITHOUT journaling through op_apply -- e.g. doc.set "
        "direct field writes"),
    "ui-state": (
        "no doc.* verb reachable: state/panel/layout/dialog/log-only "
        "effect trees"),
}


def load_workspace(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def collect_direct(node, out):
    """Generic exhaustive walk of one action's effect tree.

    Collects (verb, spec) pairs for every key starting with "doc." and the
    action names referenced by `dispatch` effects. Unknown node shapes are
    walked generically by recursing into dicts/lists, so if/then/else
    branches, foreach bodies, and created-element subtrees are all covered.
    """
    if isinstance(node, dict):
        for k, v in node.items():
            if k.startswith("doc."):
                out["verbs"].append((k, v))
            if k == "dispatch":
                if isinstance(v, str):
                    out["dispatch"].append(v)
                elif isinstance(v, dict) and isinstance(v.get("action"), str):
                    out["dispatch"].append(v["action"])
            collect_direct(v, out)
    elif isinstance(node, list):
        for v in node:
            collect_direct(v, out)


def build_reachability(actions):
    """Per action: doc.* (verb, spec) sites and dispatched action names."""
    direct = {}
    for name, action in actions.items():
        out = {"verbs": [], "dispatch": []}
        collect_direct(action.get("effects", []), out)
        direct[name] = out
    return direct


def reachable_sites(name, direct, _seen=None):
    """(verb, spec) call sites reachable from `name`, following dispatch
    chains transitively (cycle-safe). Dispatches to unknown action names
    contribute nothing."""
    if _seen is None:
        _seen = set()
    if name in _seen or name not in direct:
        return []
    _seen.add(name)
    sites = list(direct[name]["verbs"])
    for target in direct[name]["dispatch"]:
        sites.extend(reachable_sites(target, direct, _seen))
    return sites


def journal_param_of(spec):
    """The literal `journal` param at a param-gated call site (bundle values
    are always literals, so static classification suffices)."""
    if isinstance(spec, dict):
        return spec.get("journal") is True
    return False


def classify_action(name, direct):
    """Return (class, sorted doc_verbs, journal_param_sites or None)."""
    if name == "select_tool":
        return "tool-lifecycle", [], None

    sites = reachable_sites(name, direct)
    verbs = sorted({v for v, _ in sites})

    for v, _spec in sites:
        if v not in VERB_TABLE:
            raise SystemExit(
                f"ERROR: action '{name}' reaches doc.* verb '{v}' which has "
                f"no entry in the authored VERB_TABLE. Read the Rust "
                f"dispatchers (run_doc_effect / run_yaml_effect / op_apply) "
                f"and add the verb with evidence.")

    gated_sites = {}
    journaling = False
    for v, spec in sites:
        row = VERB_TABLE[v]
        if row["journals"] == "always":
            journaling = True
        elif row["journals"] == "param-gated":
            gated_sites.setdefault(v, []).append(journal_param_of(spec))

    if any(any(flags) for flags in gated_sites.values()):
        journaling = True

    if journaling:
        return "journaling", verbs, gated_sites or None
    if not verbs:
        return "ui-state", [], None
    if all(v.startswith(VIEW_PREFIXES) for v in verbs):
        return "view", verbs, None
    if all(v in PREVIEW_CHANNEL_VERBS or v in PARAM_GATED_VERBS for v in verbs):
        return "preview", verbs, gated_sites or None
    return "doc-direct", verbs, gated_sites or None


def build_map(ws):
    actions = ws["actions"]
    native_intercepts = ws.get("native_intercepts", [])
    direct = build_reachability(actions)

    entries = {}
    for name in actions:
        cls, verbs, gated = classify_action(name, direct)
        entry = {"class": cls, "doc_verbs": verbs}
        if gated is not None:
            entry["journal_param_sites"] = {
                v: flags for v, flags in sorted(gated.items())
            }
        dispatches = sorted(set(direct[name]["dispatch"]))
        if dispatches:
            entry["dispatches"] = dispatches
        entries[name] = entry

    for name in native_intercepts:
        entry = {"class": "native-intercept", "doc_verbs": []}
        if name not in actions:
            entry["note"] = ("declared in native_intercepts; no actions-map "
                            "entry -- handled natively")
        entries[name] = entry

    # Journaling verbs reachable from the action seam vs. the whole bundle.
    action_seam_verbs = set()
    for name in actions:
        action_seam_verbs.update(v for v, _ in reachable_sites(name, direct))
    bundle_verbs = set()
    _collect_all_doc_keys(ws, bundle_verbs)
    outside_verbs = sorted(bundle_verbs - action_seam_verbs)

    by_class = Counter(e["class"] for e in entries.values())
    summary = {
        "total_actions": len(actions),
        "native_intercepts": sorted(native_intercepts),
        "by_class": dict(sorted(by_class.items())),
        "journaling_actions": by_class.get("journaling", 0),
        "verb_table": {
            "always": sorted(v for v, r in VERB_TABLE.items()
                             if r["journals"] == "always"),
            "param_gated": sorted(PARAM_GATED_VERBS),
            "never": sorted(v for v, r in VERB_TABLE.items()
                            if r["journals"] == "never"),
        },
        "action_seam_doc_verbs": sorted(action_seam_verbs),
        "doc_verbs_outside_action_seam": outside_verbs,
    }
    return entries, summary


def _collect_all_doc_keys(node, out):
    if isinstance(node, dict):
        for k, v in node.items():
            if k.startswith("doc."):
                out.add(k)
            _collect_all_doc_keys(v, out)
    elif isinstance(node, list):
        for v in node:
            _collect_all_doc_keys(v, out)


def render_json(entries, summary):
    obj = {
        "generated_from": "workspace/workspace.json",
        "generator": "scripts/gen_intent_map.py",
        "scope_note": (
            "ACTION seam (dispatch_action) ONLY. "
            f"{len(summary['doc_verbs_outside_action_seam'])} doc.* effect "
            "verbs -- including every DRAWING verb -- are reachable only "
            "from tool/panel/dialog YAML and are NOT in this map. An AI "
            "tool schema derived from this map alone would omit drawing "
            "entirely. See INTENT_MAP.md."),
        "actions": {k: entries[k] for k in sorted(entries)},
        "summary": summary,
    }
    return json.dumps(obj, indent=2, sort_keys=True) + "\n"


def _md_action_row(name, entry):
    verbs = ", ".join(f"`{v}`" for v in entry["doc_verbs"]) or "--"
    gated = entry.get("journal_param_sites")
    extra = ""
    if gated:
        marks = "; ".join(
            f"`{v}` journal:{'true' if any(flags) else 'absent/false'}"
            for v, flags in sorted(gated.items()))
        extra = f" ({marks})"
    disp = entry.get("dispatches")
    if disp:
        extra += " -> dispatches " + ", ".join(f"`{d}`" for d in disp)
    return f"| `{name}` | {verbs}{extra} |"


def render_md(entries, summary):
    lines = []
    a = lines.append
    a("# INTENT_MAP -- the reachable-intent map (action seam)")
    a("")
    a("> **GENERATED FILE -- do not edit by hand.** Regenerate with")
    a("> `python scripts/gen_intent_map.py`; drift is gated in CI by")
    a("> `scripts/check_intent_map.sh`. Machine form: `intent_map.json`.")
    a("")
    a("## Scope -- read this first")
    a("")
    a("**This map covers the ACTION seam (`dispatch_action`) ONLY**: the")
    a(f"{summary['total_actions']} actions in the workspace bundle's `actions` map, plus the")
    a("bundle's declared `native_intercepts`. It is the machine enumeration")
    a("of which actions journal through `op_apply` (the enumeration")
    a("OP_LOG.md's actions.yaml<->op_apply unification prose refers to).")
    a("")
    n_outside = len(summary["doc_verbs_outside_action_seam"])
    a(f"**{n_outside} `doc.*` effect verbs -- including every DRAWING verb**")
    a("(`doc.add_element`, `doc.add_path_from_buffer`,")
    a("`doc.add_path_from_anchor_buffer`, the blob-brush / paintbrush")
    a("commit verbs, ...) -- **are reachable only from tool/panel/dialog")
    a("YAML and are NOT in this map. An AI tool schema derived from this")
    a("map alone would omit drawing entirely.** The full outside-the-seam")
    a("verb list is in `intent_map.json` under")
    a("`summary.doc_verbs_outside_action_seam`.")
    a("")
    a("## Classes")
    a("")
    a("| class | definition |")
    a("|---|---|")
    for cls in ("journaling", "tool-lifecycle", "native-intercept", "view",
                "preview", "doc-direct", "ui-state"):
        a(f"| `{cls}` | {CLASS_DEFINITIONS[cls]} |")
    a("")
    a("## Summary")
    a("")
    a("| class | actions |")
    a("|---|---|")
    for cls, n in sorted(summary["by_class"].items()):
        a(f"| `{cls}` | {n} |")
    a(f"| **total** | **{sum(summary['by_class'].values())}** |")
    a("")
    a(f"(The bundle's `actions` map has {summary['total_actions']} entries; "
      "`native-intercept` entries")
    a("come additively from `native_intercepts`.)")
    a("")

    def actions_of(cls):
        return sorted(n for n, e in entries.items() if e["class"] == cls)

    a(f"## Journaling actions ({len(actions_of('journaling'))})")
    a("")
    a("| action | doc.* verbs reached |")
    a("|---|---|")
    for name in actions_of("journaling"):
        a(_md_action_row(name, entries[name]))
    a("")
    a(f"## Preview actions ({len(actions_of('preview'))})")
    a("")
    a("| action | doc.* verbs reached |")
    a("|---|---|")
    for name in actions_of("preview"):
        a(_md_action_row(name, entries[name]))
    a("")
    a(f"## View actions ({len(actions_of('view'))})")
    a("")
    a("| action | doc.* verbs reached |")
    a("|---|---|")
    for name in actions_of("view"):
        a(_md_action_row(name, entries[name]))
    a("")
    a(f"## Doc-direct actions ({len(actions_of('doc-direct'))})")
    a("")
    a("| action | doc.* verbs reached |")
    a("|---|---|")
    for name in actions_of("doc-direct"):
        a(_md_action_row(name, entries[name]))
    a("")
    a(f"## Tool-lifecycle ({len(actions_of('tool-lifecycle'))})")
    a("")
    for name in actions_of("tool-lifecycle"):
        a(f"- `{name}` -- {CLASS_DEFINITIONS['tool-lifecycle']}.")
    a("")
    a(f"## Native-intercept ({len(actions_of('native-intercept'))})")
    a("")
    for name in actions_of("native-intercept"):
        note = entries[name].get("note", "")
        a(f"- `{name}`" + (f" -- {note}." if note else ""))
    a("")
    ui = actions_of("ui-state")
    a(f"## UI-state actions ({len(ui)})")
    a("")
    a("No `doc.*` verb reachable (state/panel/layout/dialog/log-only trees):")
    a("")
    for i in range(0, len(ui), 4):
        a(", ".join(f"`{n}`" for n in ui[i:i + 4]) +
          ("," if i + 4 < len(ui) else ""))
    a("")
    a("## Verb -> journaling evidence table")
    a("")
    a("Derived by reading the Rust reference dispatchers. File aliases:")
    a("`effects.rs` = `jas_dioxus/src/interpreter/effects.rs`,")
    a("`renderer.rs` = `jas_dioxus/src/interpreter/renderer.rs`,")
    a("`op_apply.rs` = `jas_dioxus/src/document/op_apply.rs`. Line numbers")
    a("are as of authoring (2026-07-22, post `five-port-parity`).")
    a("")
    a("| doc.* verb | journals | op | reachable from actions | evidence |")
    a("|---|---|---|---|---|")
    seam = set(summary["action_seam_doc_verbs"])
    order = {"always": 0, "param-gated": 1, "never": 2}
    for verb in sorted(VERB_TABLE, key=lambda v: (order[VERB_TABLE[v]["journals"]], v)):
        row = VERB_TABLE[verb]
        op = f"`{row['op']}`" if "op" in row else "--"
        reach = "yes" if verb in seam else "no (tool YAML only)"
        ev = "; ".join(row["evidence"])
        note = row.get("note")
        j = row["journals"]
        if note:
            j = f"{j} ({note})"
        a(f"| `{verb}` | {j} | {op} | {reach} | {ev} |")
    a("")
    a("## Caveats")
    a("")
    a("- **Static classification of the YAML bundle.** Several actions are")
    a("  `log`-stubs in YAML whose real behavior lives in native code:")
    a("  `dispatch_action` natively intercepts the symbol/concept actions")
    a("  (`new_symbol`, `place_instance`, `delete_symbol_action`,")
    a("  `delete_symbol_orphan_confirm_ok`, `place_concept_instance`,")
    a("  `set_concept_param`, `apply_concept_operation`,")
    a("  `promote_to_concept` -- renderer.rs:549-1010), several of which")
    a("  journal real ops through `op_apply` natively; and the menu/keyboard")
    a("  fast paths handle `cut`/`copy`/`paste`/`delete_selection` natively")
    a("  (journaling `delete_selection` via `journal_delete_selection`,")
    a("  op_apply.rs:1276). Those actions classify as `ui-state` here")
    a("  because their YAML effect trees reach no `doc.*` verb; the class")
    a("  describes the YAML seam, not the native behavior behind it.")
    a("- **`doc.select_in_rect`** routes through `op_apply` but records only")
    a("  into an already-open transaction and never opens one")
    a("  (op_apply.rs:1329-1336): selection is non-undoable serialized")
    a("  state, so a bare marquee stays journal-neutral.")
    a("- **`doc.snapshot`** is transaction management (`begin_txn`), not an")
    a("  op; history-navigation verbs are never journaled")
    a("  (op_apply.rs:1294-1314).")
    a("- **Dispatch chains are followed** (`cut` -> `copy` +")
    a("  `delete_selection`, `save` -> `save_as`, ...), transitively and")
    a("  cycle-safe; `action:` keys inside created-element `behavior` blocks")
    a("  are event bindings, not dispatch-time effects, and are not")
    a("  followed.")
    a("")
    return "\n".join(lines)


def self_test(ws):
    entries, summary = build_map(ws)

    assert summary["total_actions"] == EXPECTED_TOTAL_ACTIONS, (
        f"expected {EXPECTED_TOTAL_ACTIONS} actions in the bundle, found "
        f"{summary['total_actions']}")
    assert entries["export_to_pdf"]["class"] == "native-intercept", (
        "export_to_pdf must classify native-intercept")
    assert entries["select_tool"]["class"] == "tool-lifecycle", (
        "select_tool must classify tool-lifecycle")
    assert entries["scale_options_confirm"]["class"] == "journaling", (
        "scale_options_confirm must classify journaling (journal: true)")
    assert entries["scale_options_preview"]["class"] != "journaling", (
        "scale_options_preview must NOT classify journaling (no journal "
        "param)")

    # Structural invariants.
    for name, e in entries.items():
        assert e["class"] in CLASS_DEFINITIONS, (name, e["class"])
    # Determinism: rendering twice yields identical bytes.
    e2, s2 = build_map(ws)
    assert render_json(entries, summary) == render_json(e2, s2)
    assert render_md(entries, summary) == render_md(e2, s2)

    n_j = summary["journaling_actions"]
    n_always = len(summary["verb_table"]["always"])
    n_gated = len(summary["verb_table"]["param_gated"])
    print(f"self-test PASS: {summary['total_actions']} actions; "
          f"{n_j} journaling actions; verb table: {n_always} always + "
          f"{n_gated} param-gated + "
          f"{len(summary['verb_table']['never'])} never; "
          f"{len(summary['action_seam_doc_verbs'])} doc.* verbs on the "
          f"action seam, "
          f"{len(summary['doc_verbs_outside_action_seam'])} outside it.")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--workspace", type=Path, default=WORKSPACE_JSON,
                    help="path to workspace.json (read-only)")
    ap.add_argument("--json", type=Path, default=REPO_ROOT / "intent_map.json",
                    help="output path for the machine map")
    ap.add_argument("--md", type=Path, default=REPO_ROOT / "INTENT_MAP.md",
                    help="output path for the human map")
    ap.add_argument("--self-test", action="store_true",
                    help="run assertions only; write nothing")
    args = ap.parse_args()

    ws = load_workspace(args.workspace)
    if args.self_test:
        return self_test(ws)

    entries, summary = build_map(ws)
    args.json.write_text(render_json(entries, summary), encoding="utf-8")
    args.md.write_text(render_md(entries, summary), encoding="utf-8")
    print(f"wrote {args.json} and {args.md} "
          f"({summary['total_actions']} actions, "
          f"{summary['journaling_actions']} journaling).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
