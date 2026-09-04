#!/usr/bin/env python3
"""Every action whose DECLARED effects do nothing must say which port implements
it natively -- and the two ports must agree.

WHY THIS EXISTS
---------------
64 of the 237 actions in `workspace/actions.yaml` are LOG-ONLY: their entire
effect list is `- log: "name"`. That is not a defect by itself. `undo`, `copy`,
`paste`, `save`, `group` are all log-only, and they all work, because the effect
vocabulary cannot express "run the undo stack" and each port implements them
natively. That is legitimate and permanent.

THE PROBLEM IS THAT NOTHING DISTINGUISHES THEM. In the spec,
`toggle_artboard_orientation` -- implemented in NEITHER active port, and rendered
ALWAYS ENABLED in `artboard_options.yaml` -- has exactly the same shape as
`undo`. 83 enabled controls point into this undifferentiated pile, and no one can
tell from the spec which of them do anything.

A convention exists and it is WRONG. Nine of the 64 carry the literal string
`(native)` inside their log message. At least two of those nine --
`toggle_artboard_orientation` and `toggle_artboard_chain_link` -- are implemented
in neither port. A marker that is false on 22% of its own uses is worse than no
marker, and it is the house's recurring shape: a human-readable claim in a
machine-read file that nobody rechecks.

The mechanism to say it properly ALREADY EXISTS and holds exactly one entry:
`native_intercepts` at the top of `actions.yaml` lists `export_to_pdf` and
nothing else.

WHAT THIS GATE DOES
-------------------
It reads both ports' native dispatch tables and classifies every log-only action
four ways:

  native_both     both ports handle it natively -- legitimate, belongs in
                  `native_intercepts`
  DIVERGENT       exactly one port handles it -- a PRIME DIRECTIVE VIOLATION,
                  and an artist-visible one: the control works in one app and
                  does nothing in the other
  unclassified    NO DISPATCH ENTRY FOUND IN EITHER PORT. This is a MIXED
                  bucket and must not be read as "dead". It contains genuinely
                  unbuilt actions AND actions whose feature works natively
                  behind a different entry point -- the Layers row controls
                  (eye / lock / twirl / rename / select) live in
                  `lp_tree.row_template`, which NO port reads, because both
                  draw tree rows natively; the action id is unreferenced while
                  the feature works. Separating the two needs per-action
                  tracing, which is what the ledger is for. Guessing function
                  names does not do it -- this gate's author tried and got one
                  of three.
  bypassed        declared, dispatched by name in neither port, but the FEATURE
                  exists natively behind a different entry point. Judgement, so
                  it must be DECLARED in `action_implementation_ledger.json`
                  with machine-checked claims -- see `verify_asserts` in
                  check_widget_kind_dispatch.py for the mechanism and the reason
                  it exists.

THE EXTRACTION RULE, which is the whole trick
---------------------------------------------
A dispatch arm whose body merely ROUTES BACK to the generic action pipeline is
NOT native handling. This is not a detail -- it is the exact misread this gate
was predicted to make. In jas_dioxus:

    "save_as" | "revert" | "quit" | ... => {
        let _ = dispatch_action(&action, ...);      // <- back to the log stub
    }

`save_as` LOOKS like a handled arm. It is a pass-through, and Save As does
nothing in that port. JasSwift has the same shape with `runYamlActionByName`,
and additionally uses `break` for declared placeholders. So an arm counts as
native only when its body does real work.

WHAT IT DOES NOT COVER
----------------------
* It reads dispatch TABLES, not behaviour. An arm that is present and wrong is
  native here.
* Reachability is not checked: an action no control invokes is still classified.
* The frozen ports are out of scope by POLICY.md section 1.
"""

import json
import pathlib
import re
import sys

import yaml

REPO = pathlib.Path(__file__).resolve().parent.parent
ACTIONS = REPO / "workspace" / "actions.yaml"
LEDGER = REPO / "scripts" / "action_implementation_ledger.json"

RUST_DISPATCH = [
    REPO / "jas_dioxus" / "src" / "workspace" / "menu_bar.rs",
] + sorted((REPO / "jas_dioxus" / "src" / "panels").glob("*.rs"))

SWIFT_DISPATCH = [
    REPO / "JasSwift" / "Sources" / "Menu" / "JasCommands.swift",
    REPO / "JasSwift" / "Sources" / "Interpreter" / "YamlPanelBodyView.swift",
] + sorted((REPO / "JasSwift" / "Sources" / "Panels").glob("*.swift"))

# THE THIRD RUST DISPATCH TABLE, and the one that made this gate report four
# false divergences on its first production run. `dispatch_action` in the
# renderer carries NATIVE INTERCEPTS -- `if action == "new_symbol" || ...` --
# which is why symbols_panel.rs's arm is a deliberate pass-through: its own
# docstring says "the shared dispatch_action pipeline, where the native
# intercept mints ids and calls the Controller ops". A panel arm that routes
# is not always an unimplemented action; sometimes the implementation is one
# layer down.
RUST_INTERCEPTS = REPO / "jas_dioxus" / "src" / "interpreter" / "renderer.rs"
RUST_INTERCEPT_RE = re.compile(r'action == "([a-z_0-9]+)"')

# Guard arms: `c if c.starts_with("toggle_panel_") => {...}`. A pattern guard,
# invisible to a string-literal scan, and jas_dioxus routes every panel toggle
# through one.
RUST_GUARD_PREFIX_RE = re.compile(r'starts_with\("([a-z_0-9]+)_"\)')

# Calls that mean "hand this back to the generic pipeline". An arm whose body
# contains one of these and nothing else is a pass-through, not a handler.
ROUTING_CALLS = ("dispatch_action", "runYamlActionByName", "run_yaml_action")

# jas_dioxus's menu keys on a legacy cmd string, not the action name. From
# `cmd_for` in menu_bar.rs. Actions absent here pass through unchanged.
RUST_CMD_ALIAS = {
    "new_document": "new",
    "open_file": "open",
    "open_document_setup": "document_setup",
    "open_print_dialog": "print",
    "hide_selection": "hide",
    # toggle_pane / toggle_panel fold a param into the cmd; handled by prefix.
}
RUST_CMD_PREFIX = ("toggle_pane", "toggle_panel")

# Anti-vacuity floors, EXACT rather than slack (Flask's law). An extraction that
# silently stopped matching would report every action dead and read as a
# catastrophe rather than as a broken parse -- but one that matched everything
# would read as a clean tree, which is the dangerous direction.
MIN_LOG_ONLY = 63
MIN_RUST_ARMS = 60
MIN_SWIFT_ARMS = 60


class ParseFailure(Exception):
    """The source did not have the shape this gate reads."""


def log_only_actions(doc: dict) -> set[str]:
    """Actions whose entire effect list is `- log:`."""
    out = set()
    for name, spec in (doc.get("actions") or {}).items():
        if not isinstance(spec, dict):
            continue
        eff = spec.get("effects")
        if not isinstance(eff, list) or not eff:
            continue
        kinds = [next(iter(e)) if isinstance(e, dict) else str(e) for e in eff]
        if set(kinds) == {"log"}:
            out.add(name)
    return out


def native_intercepts(doc: dict) -> set[str]:
    ni = doc.get("native_intercepts") or []
    out = set()
    for e in ni:
        out.add(e if isinstance(e, str) else str(
            e.get("action") or e.get("name") or next(iter(e))))
    return out


def _rust_arm_body(src: str, at: int) -> str:
    """The body of a Rust match arm whose `=>` ends at `at`.

    BRACE-MATCHED, not "up to the next label". The first draft of this gate read
    to the next label or 4000 characters, which meant the LAST arm of a match
    swallowed whatever functions followed it -- and the last arm of
    menu_bar.rs's match is the pass-through, so `save_as` read as native. The
    anchor self-test caught it, which is the entire reason the anchors are
    hand-verified against the live tree rather than against a fixture I wrote.
    """
    i = at
    while i < len(src) and src[i].isspace():
        i += 1
    if i < len(src) and src[i] == "{":
        depth = 0
        for j in range(i, len(src)):
            if src[j] == "{":
                depth += 1
            elif src[j] == "}":
                depth -= 1
                if depth == 0:
                    return src[i:j + 1]
        return src[i:]
    # Expression arm: read to the comma that ends it, at depth zero.
    depth = 0
    for j in range(i, len(src)):
        c = src[j]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                return src[i:j]
            depth -= 1
        elif c == "," and depth == 0:
            return src[i:j]
    return src[i:]


SWIFT_TERMINATOR = re.compile(r'^[ \t]*(?:case[ \t]+|default[ \t]*:)', re.M)


def arms(src: str, case_re: re.Pattern, lang: str) -> dict[str, str]:
    """Map every string-literal dispatch label to the body that follows it.

    Rust bodies are brace-matched. Swift `case` bodies have no braces, so they
    run to the next `case`/`default` -- `default` included deliberately, since
    the last real case before it would otherwise absorb the pass-through
    default and read as native.
    """
    hits = list(case_re.finditer(src))
    out: dict[str, str] = {}
    for i, m in enumerate(hits):
        if lang == "rust":
            body = _rust_arm_body(src, m.end())
        else:
            nxt = SWIFT_TERMINATOR.search(src, m.end())
            body = src[m.end():nxt.start() if nxt else min(len(src), m.end() + 2000)]
        for label in re.findall(r'"([a-z_0-9]+)"', m.group(0)):
            out.setdefault(label, "")
            out[label] += body
    return out


RUST_CASE = re.compile(
    r'^[ \t]*"[a-z_0-9]+"(?:[ \t]*\|[ \t]*(?:\n[ \t]*\|[ \t]*)?"[a-z_0-9]+")*[ \t]*(?:\n[ \t]*\|[^=]*)?=>',
    re.M)
SWIFT_CASE = re.compile(
    r'^[ \t]*case[ \t]+"[a-z_0-9]+"(?:[ \t]*,[ \t]*"[a-z_0-9]+")*[ \t]*:', re.M)


# Calls that are PLUMBING, not work: allocation, cloning, borrowing, option
# handling. A body whose only calls are these plus a routing call is delivering
# the routing call, not handling the action.
CALL_NOISE = {
    "to_string", "clone", "borrow", "borrow_mut", "new", "unwrap", "unwrap_or",
    "unwrap_or_else", "unwrap_or_default", "Some", "None", "into", "as_str",
    "as_ref", "format", "String", "default", "from", "map", "and_then", "get",
    "expect", "to_owned", "iter", "collect", "Box", "Ok", "Err",
}


def body_is_native(body: str) -> bool:
    """True when an arm's body does real work.

    THE TEST IS WHAT IT CALLS, not how long it is. A first draft measured the
    residue in characters after deleting the routing call, and the deferred-
    effect closure that jas_dioxus wraps its pass-through in
    (`(act.0.borrow_mut())(Box::new(move |st| ...))`) is far more than any
    character threshold -- so the pass-through read as a handler and `save_as`
    came back native. Boilerplate is bulky; that is the point of boilerplate.

    A handler calls something that is not plumbing. A pass-through's only
    non-plumbing call is the routing call itself.
    """
    stripped = re.sub(r'//[^\n]*', '', body)      # prose must not count as code
    code = stripped.strip().strip("{}").strip()
    if not code:
        return False
    if all(line.strip() in ("break", "", "{", "}", "()", ";")
           for line in code.splitlines()):
        return False
    calls = set(re.findall(r'([A-Za-z_][A-Za-z_0-9]*)\s*\(', stripped))
    meaningful = calls - CALL_NOISE - set(ROUTING_CALLS)
    return bool(meaningful)


def rust_cmds(action: str) -> list[str]:
    """The cmd string(s) jas_dioxus's menu would key on for an action."""
    if action in RUST_CMD_ALIAS:
        return [RUST_CMD_ALIAS[action]]
    if action in RUST_CMD_PREFIX:
        return [action]          # folded per-target; prefix-matched below
    return [action]


def rust_extra_handlers() -> dict[str, bool]:
    """Native intercepts in `dispatch_action`, plus guard-arm prefixes."""
    out: dict[str, bool] = {}
    try:
        src = RUST_INTERCEPTS.read_text(encoding="utf-8")
    except OSError:
        return out
    for name in RUST_INTERCEPT_RE.findall(src):
        out[name] = True
    try:
        menu = (REPO / "jas_dioxus" / "src" / "workspace" / "menu_bar.rs").read_text(
            encoding="utf-8")
        for prefix in RUST_GUARD_PREFIX_RE.findall(menu):
            out[prefix] = True
    except OSError:
        pass
    return out


def port_handlers(files, case_re, lang) -> dict[str, bool]:
    """label -> is_native, unioned across a port's dispatch files."""
    out: dict[str, bool] = {}
    for f in files:
        try:
            src = f.read_text(encoding="utf-8")
        except OSError:
            continue
        for label, body in arms(src, case_re, lang).items():
            out[label] = out.get(label, False) or body_is_native(body)
    return out


def classify(log_only, rust, swift, declared_bypassed):
    rows = {}
    for a in sorted(log_only):
        r = any(rust.get(c, False) for c in rust_cmds(a)) or any(
            k.startswith(a) and v for k, v in rust.items()
            if a in RUST_CMD_PREFIX)
        s = swift.get(a, False) or any(
            k.startswith(a) and v for k, v in swift.items()
            if a in RUST_CMD_PREFIX)
        if a in declared_bypassed:
            rows[a] = "bypassed"
        elif r and s:
            rows[a] = "native_both"
        elif r or s:
            rows[a] = "DIVERGENT:rust" if r else "DIVERGENT:swift"
        else:
            rows[a] = "dead_both"
    return rows


def load_ledger():
    if not LEDGER.exists():
        return {}
    return json.loads(LEDGER.read_text(encoding="utf-8")).get("bypassed", {})


def load_known_divergences():
    if not LEDGER.exists():
        return {}
    raw = json.loads(LEDGER.read_text(encoding="utf-8")).get("known_divergences", {})
    return {k: _sib().normalise_row(v) for k, v in raw.items()}


def _sib():
    """check_widget_kind_dispatch, imported for its claim verifier.

    IMPORTED RATHER THAN COPIED, deliberately. The law those functions enforce
    is that a claim nobody rechecks goes stale; a second copy of the enforcer
    is the same hazard one level up.
    """
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "_wkd", pathlib.Path(__file__).with_name("check_widget_kind_dispatch.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


# --------------------------------------------------------------------------
# self-test
# --------------------------------------------------------------------------

def self_test() -> int:
    """Prove the gate reads the real tree correctly, against KNOWN ANCHORS.

    Anchors rather than synthetic fixtures, because the predicted failure mode
    of this gate is not a logic bug -- it is misreading two hand-written
    switches. A synthetic switch I wrote would be one I already understood.
    """
    failures = []

    # (a) The pass-through rule, which is the whole trick.
    if body_is_native('{ let _ = dispatch_action(&action, &m, st); }'):
        failures.append("  a: a bare dispatch_action pass-through must NOT be native")
    if body_is_native('\n    runYamlActionByName(cmd, params: [:], model: model)\n'):
        failures.append("  a: a bare runYamlActionByName pass-through must NOT be native")
    if body_is_native('\n    // placeholder until the plumbing lands\n    break\n'):
        failures.append("  a: a `break` placeholder must NOT be native")
    if body_is_native('   '):
        failures.append("  a: an empty body must NOT be native")
    if not body_is_native('{ st.tab_mut().map(|t| t.model.undo()); redraw(st); }'):
        failures.append("  a: a real body MUST be native")
    # A handler that does real work AND delegates is still a handler.
    if not body_is_native('''{
            let svg = document_to_svg(tab.model.document());
            let filename = format!("{}.svg", tab.model.filename);
            download_file(&filename, &svg);
            tab.model.mark_saved();
            let _ = dispatch_action(&action, &m, st);
        }'''):
        failures.append("  a: work-plus-delegate MUST be native")

    # (b) THE ANCHORS, against the live tree. Each was verified by hand at
    #     council on 2026-07-30; if the extraction drifts, these move first.
    try:
        doc = yaml.safe_load(ACTIONS.read_text(encoding="utf-8"))
        lo = log_only_actions(doc)
        rust = port_handlers(RUST_DISPATCH, RUST_CASE, "rust")
        rust.update(rust_extra_handlers())
        swift = port_handlers(SWIFT_DISPATCH, SWIFT_CASE, "swift")
        rows = classify(lo, rust, swift, load_ledger())
    except (OSError, ParseFailure, yaml.YAMLError) as e:
        print(f"SELF-TEST FAILED -- cannot read the tree: {e}")
        return 1

    anchors = {
        # verified by hand: menu_bar.rs:67 real body / JasCommands "undo"
        "undo": "native_both",
        # verified: neither port contains the string at all
        "toggle_artboard_orientation": "dead_both",
        # save_as was DIVERGENT:swift when this gate was written and is
        # native_both since council O1.1 wired jas_dioxus's picker. The anchor
        # MOVED WITH THE FIX -- an anchor is a claim about the tree like any
        # other, and this one expired the moment the defect did. Keeping it
        # here, now asserting the repaired state, is what stops the repair
        # silently regressing.
        "save_as": "native_both",
        # revert followed save_as out of the divergence list once JYH ruled
        # how a browser should name "the saved version": the tab retains the
        # bytes it was opened from or last saved as, and revert re-parses them.
        "revert": "native_both",
        # sort_swatches_by_name was DIVERGENT:rust until council O1.3 built
        # JasSwift's five verbs (2026-07-30). The anchor moves with the fix, and
        # now asserts the REPAIRED state so it cannot silently regress.
        "sort_swatches_by_name": "native_both",
        # THE TWO CLASSES THAT PRODUCED FALSE DIVERGENCES on the first
        # production run, anchored so they cannot regress:
        #   guard arm -- jas_dioxus routes panel toggles through
        #   `c if c.starts_with("toggle_panel_")`, invisible to a
        #   string-literal scan
        "toggle_panel": "native_both",
        #   native intercept -- symbols_panel.rs's arm deliberately routes to
        #   `dispatch_action`, where `if action == "new_symbol"` does the work
        "new_symbol": "native_both",
        "place_instance": "native_both",
    }
    for a, want in anchors.items():
        got = rows.get(a, "<not in the log-only set>")
        if got != want:
            failures.append(f"  b: {a}: expected {want}, read {got}")

    if len(lo) != MIN_LOG_ONLY:
        failures.append(f"  c: {len(lo)} log-only actions, floor is exactly {MIN_LOG_ONLY}")
    # 64 when this gate was written; 63 once `toggle_layers_type_filter` gained
    # real effects (council Q3.2); 62 once `delete_empty_artboards` gained real
    # effects (EMPTYARTBOARDS) -- it had been a log-only stub whose menu command
    # did nothing in either port. The floor is EXACT so a stub leaving the set
    # -- or a new one joining it -- has to be noticed and accounted for, which
    # is the friction working rather than an obstacle to it. It worked twice:
    # this gate is how each change announced itself.
    #
    # 63 again as of the state-read repair, and this is the FIRST time the count
    # went UP. `sort_brushes_by_name` JOINED the log-only set. It is not a new
    # stub -- it was always a no-op; it declared
    # `data.list_sort` with a `${panel.selected_library}` in its path, and
    # `${...}` is `loader.substitute_params`, which never runs on an effect
    # payload. So it read as implemented to this gate (a non-log effect) while
    # doing nothing at all, which is precisely the undifferentiated pile this
    # gate's docstring was written about -- one rung worse, because a broken
    # effect declaration hides in the classified bucket rather than the
    # unclassified one. Declaring it log-only moves it into the bucket that
    # says "no port does this", which is true. See VISION.md section 11.
    if len(rust) < MIN_RUST_ARMS:
        failures.append(f"  c: only {len(rust)} rust dispatch labels parsed "
                        f"(floor {MIN_RUST_ARMS}) -- the extraction is broken")
    if len(swift) < MIN_SWIFT_ARMS:
        failures.append(f"  c: only {len(swift)} swift dispatch labels parsed "
                        f"(floor {MIN_SWIFT_ARMS}) -- the extraction is broken")

    if failures:
        print("SELF-TEST FAILED -- the gate does not read what it claims:")
        print("\n".join(failures))
        return 1
    # The summary is DERIVED from `anchors`, never restated. The hand-written
    # version of this line survived three anchors moving (save_as, revert and
    # sort_swatches_by_name all became native_both as their divergences were
    # fixed) and went on reporting them as divergent -- stale prose in a
    # machine-read file, in the summary of the gate whose whole subject is
    # stale prose in machine-read files.
    summary = ", ".join(f"{a}={v}" for a, v in sorted(anchors.items()))
    print(f"self-test: pass-through / placeholder / empty / real / "
          f"work-plus-delegate bodies all classified correctly, and "
          f"{len(anchors)} HAND-VERIFIED anchors read as expected against the "
          f"live tree ({summary}); {len(lo)} log-only actions, {len(rust)} "
          f"rust and {len(swift)} swift dispatch labels parsed.")
    return 0


def _read_repo(rel):
    try:
        return (REPO / rel).read_text(encoding="utf-8")
    except OSError:
        return None


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()

    try:
        doc = yaml.safe_load(ACTIONS.read_text(encoding="utf-8"))
        lo = log_only_actions(doc)
        ni = native_intercepts(doc)
        rust = port_handlers(RUST_DISPATCH, RUST_CASE, "rust")
        rust.update(rust_extra_handlers())
        swift = port_handlers(SWIFT_DISPATCH, SWIFT_CASE, "swift")
        rows = classify(lo, rust, swift, load_ledger())
    except (OSError, yaml.YAMLError, json.JSONDecodeError) as e:
        print(f"ERROR: cannot read the dispatch tables: {e}", file=sys.stderr)
        return 1

    if len(lo) != MIN_LOG_ONLY or len(rust) < MIN_RUST_ARMS or len(swift) < MIN_SWIFT_ARMS:
        print(f"ERROR: below the anti-vacuity floor -- {len(lo)} log-only "
              f"actions (exactly {MIN_LOG_ONLY} expected), {len(rust)}/{len(swift)} "
              f"dispatch labels parsed.", file=sys.stderr)
        print("A parse that stopped matching classifies everything as dead, and "
              "a parse that over-matches classifies everything as fine. Neither "
              "is a result.", file=sys.stderr)
        return 1

    divergent = {a: v for a, v in rows.items() if v.startswith("DIVERGENT")}

    # A declared divergence is RULED AND SCHEDULED, not accepted -- and its
    # claim is verified before it is honoured, written to red WHEN THE
    # DIVERGENCE IS FIXED so the row cannot outlive the defect.
    known = load_known_divergences()
    stale = _sib().verify_asserts(known, lambda rel: _read_repo(rel))
    if stale:
        print(f"ERROR: {len(stale)} declared-divergence claim(s) no longer hold.",
              file=sys.stderr)
        for key, why in stale:
            print(f"  {key}: {why}", file=sys.stderr)
        print(file=sys.stderr)
        print("Most likely the divergence was FIXED -- delete the row. That is "
              "the mechanism working, not an obstacle to it.", file=sys.stderr)
        return 1
    undeclared = {a: v for a, v in divergent.items() if a not in known}
    retired = sorted(set(known) - set(divergent))
    if retired:
        print(f"ERROR: {len(retired)} row(s) declare a divergence that no longer "
              f"exists: {', '.join(retired)}. Delete them.", file=sys.stderr)
        return 1
    divergent = undeclared
    dead = [a for a, v in rows.items() if v == "dead_both"]   # = unclassified
    both = [a for a, v in rows.items() if v == "native_both"]
    byp = [a for a, v in rows.items() if v == "bypassed"]

    print(f"action implementations: {len(lo)} log-only action(s) -- "
          f"{len(both)} native in both ports, {len(byp)} declared bypassed, "
          f"{len(dead)} with no dispatch entry (MIXED -- see below), "
          f"{len(known)} DECLARED divergence(s) awaiting their queued fix, "
          f"{len(divergent)} UNDECLARED.")
    print()
    if both:
        missing_ni = sorted(set(both) - ni)
        print(f"  native in both ({len(both)}): {', '.join(sorted(both))}")
        if missing_ni:
            print(f"    -> {len(missing_ni)} not yet in `native_intercepts`, which is "
                  f"where a permanent native action belongs.")
    if dead:
        print()
        print(f"  NO DISPATCH ENTRY IN EITHER PORT ({len(dead)}) -- a MIXED "
              f"bucket, NOT a list of dead controls. Some of these work "
              f"natively behind another entry point (the Layers row controls "
              f"are the known family). Tracing each is what moves it into the "
              f"ledger as `bypassed` or into a fix:")
        for a in dead:
            print(f"    {a}")
    if byp:
        print()
        print(f"  declared bypassed ({len(byp)}): {', '.join(sorted(byp))}")

    if not divergent:
        return 0

    print(file=sys.stderr)
    print(f"ERROR: {len(divergent)} action(s) are implemented in ONE active "
          f"port only. Each is a prime-directive violation and an "
          f"artist-visible one -- the control works in one app and does "
          f"nothing in the other.", file=sys.stderr)
    print(file=sys.stderr)
    for a, v in sorted(divergent.items()):
        who = v.split(":")[1]
        other = "JasSwift" if who == "rust" else "jas_dioxus"
        print(f"  {a}: implemented in {who}, DEAD in {other}", file=sys.stderr)
    print(file=sys.stderr)
    print("Fix the port that lacks it, or -- if the divergence is intended and "
          "scheduled -- declare it in "
          f"{LEDGER.relative_to(REPO).as_posix()} with machine-checked claims, "
          "never with prose alone.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
