#!/usr/bin/env python3
"""A suite that quietly stopped running still exits 0. Prove the main Rust suite RAN.

WHY THIS EXISTS
---------------
Two lanes in this repo already carry an execution gate, and both were built after
the same discovery: a green lane is not evidence that anything ran.
`check_wasm_canvas_count.py` guards the browser canvas lane by DERIVING both
sides of a count. `check_native_backend_lane.py` guards the `d2d`/`ffi` lanes by
asserting NAMED tests appear in the runner's stdout, because "a feature lane that
compiled nothing still exits 0".

The suite those two do not cover is the largest one in the repo. `cd jas_dioxus
&& cargo test` runs ~3,000 tests and is invoked by TWO jobs, and nothing reads
its output. Measured 2026-09-06, not argued: `cargo test` on a crate containing
zero tests exits **0**. (`pytest` exits 5 on an empty collection, which is why
the Python steps in this workflow need no equivalent gate -- the tool defends
itself and `cargo` does not.)

⛔ THE FAILURE MODE IS A GREEN LANE, NOT A RED ONE, and this repo has already met
it once at the authoring end: `check_unregistered_tests.py` exists because a test
function without `#[test]` had never run while sitting between neighbours that
had. That gate answers "was this test REGISTERED". It cannot answer "did the
registered suite still RUN", which is what a `#[cfg(test)]` module dropping out
of the build looks like: the total falls, every remaining test passes, and the
step exits 0.

WHY NAMED ANCHORS AND NOT A DERIVED COUNT
-----------------------------------------
`check_wasm_canvas_count.py` derives EXPECTED from the source and is right to:
every wasm test in that crate lives under a module-level `#[cfg(all(test,
target_arch = "wasm32"))]`, so a wasm build compiles all of them or none. **That
invariant does not hold here.** The native total moves with the feature set --
measured on kenai 2026-09-06, `--features web` ran 3,066 and
`--no-default-features --features d2d,ffi` ran 2,686 -- so a single derived
EXPECTED cannot cover both invocations, and a per-invocation table of totals
would be exactly the remembered number this repo's doctrine rejects.

So this gate takes the OTHER pattern already blessed here, from
`check_native_backend_lane.py`: **a named test is immune**. An anchor either
appears in the runner's stdout as executed and passing, or it does not.

⭐ AND THE DECLARATION ITSELF IS DERIVED, which is the half that does not rot.
The anchors are chosen one per AREA -- a top-level subdirectory of
`jas_dioxus/src/` holding a plain `#[cfg(test)]` module -- and
`declaration_findings()` recomputes that set of areas FROM THE SOURCE TREE on
every run. A new area with tests, or an area that grows one, reds this gate until
it is given a witness. The coverage rule is therefore not a list someone
remembered to update; it is a question asked of the tree.

A DISAGREEMENT IN EITHER DIRECTION IS A REFUSAL. An anchor that no longer exists
in the source reds here rather than silently never matching the log -- an anchor
that cannot be found is not a satisfied anchor, and a gate that tolerates being
wrong about its own subject is worth nothing.

THE ANCHOR'S SCOPE LIMIT, AND THE COUNT THAT CLOSES IT (#128 -> this)
--------------------------------------------------------------------
An anchor proves an area RAN. It cannot see an area that loses half its tests
and keeps its anchor: the total falls, the anchor still passes, the step exits
0. That limit was DEFERRED at #128 with a ripens-when -- "the gate has survived
a handful of real merges without a spurious red" -- and measured met on
2026-09-10: 27 merges since, zero maintenance commits, no spurious red.

⛔ THE REASON IT WAS DEFERRED RATHER THAN GUESSED AT: a count needs an EXPECTED
side, and every cheap expected side is unsound here. A single total is wrong
because the total moves with the feature set. A per-invocation TABLE of totals
is the remembered number this repo rejects -- and this seat has twice measured a
floor sitting 40-odd files below reality with a green self-test, because a
floor's arm drives the constant against ITSELF and so tests the comparison and
never the value.

⭐ SO THE EXPECTED SIDE IS DERIVED FROM THE SOURCE, ONCE PER INVOCATION, AND
THERE IS NO CONSTANT ANYWHERE IN IT. For each area, count the `#[test]` fns the
source declares, evaluate each one's `#[cfg]` against THIS invocation's features
and target, and require the runner to have registered EXACTLY that many. The
expected value is recomputed from the tree on every run, so it cannot go stale,
and a disagreement in EITHER direction is a finding: fewer means tests stopped
running, more means this gate has misread its own subject.

⛔ THREE THINGS THE REAL ARTIFACT TAUGHT THIS COUNT, NONE OF THEM VISIBLE FROM
`cargo test -- --list`, and each of which would have made a wrong number look
exactly like a measurement:

  1. `cargo test` RUNS THE LIBRARY SUITE TWICE -- once as `unittests src/lib.rs`
     and once as `unittests src/main.rs`, because the bin target compiles the
     same modules. A count taken over the whole log is therefore EXACTLY DOUBLE
     the truth, and doubling is the error shape least likely to look wrong. The
     count is scoped to the `src/lib.rs` block alone, and the absence of that
     block is a REFUSAL, never a skip.
  2. A `#[should_panic]` test reports as `test <path> - should panic ... ok`.
     Three of them sit in this suite. A matcher without that suffix silently
     drops them and lands 3 short of the banner -- which is also why
     `executed_ok` below carries the suffix: an anchor that were ever marked
     `#[should_panic]` would otherwise read as a suite that did not run.
  3. AN IGNORED TEST IS STILL REGISTERED. `ok`, `ignored` and `FAILED` all count
     toward the banner, so all three count here. ⛔ WHAT THIS COUNT THEREFORE
     CANNOT SEE, stated rather than left to be discovered: a test that gains
     `#[ignore]` stops running and the count does not move. The anchors cover
     that for eleven tests; nothing covers it for the rest.

⛔ AND THE CFG EVALUATOR REFUSES WHAT IT DOES NOT UNDERSTAND. A resolver that
cannot refuse reports the answer its filter allows, and the number still looks
like a measurement -- this seat shipped exactly that defect in a census three
days ago. `evaluate_cfg` raises on any predicate outside the small grammar
measured in this tree (`all`, `any`, `not`, `feature = "..."`, `target_os`,
`target_arch`, `windows`, `unix`, `test`), and the raise becomes a FINDING.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "jas_dioxus" / "src"

# THE AREAS THIS GATE ADJUDICATES, one anchor each. An area is a top-level
# SUBDIRECTORY of `jas_dioxus/src/`; the anchor is a test inside it that the
# runner must report as executed and passing.
#
# `prefix` is what ties an anchor to its area, in the same posture as
# `check_native_backend_lane.py`'s feature->prefix map: an anchor swapped for a
# test somewhere else no longer matches its prefix and the DECLARATION reds,
# before any log is read. Without that, "one anchor per area" degrades into
# "eleven anchors, possibly all from one module", which asserts what a single
# anchor asserts and looks eleven times stronger.
AREAS: dict[str, dict[str, str]] = {
    "algorithms": {
        "prefix": "algorithms::",
        "anchor": "algorithms::hit_test::tests::"
                  "unfilled_ellipse_marquee_inside_outline_misses_under_identity_and_none",
        "reason": "Hit testing is reached by every selection gesture in the app; "
                  "an unfilled-ellipse marquee exercises the winding path rather "
                  "than a bounding box, so it cannot pass off a stub.",
    },
    "canvas": {
        "prefix": "canvas::",
        "anchor": "canvas::render::tests::"
                  "effective_mask_transform_unlinked_returns_captured_unlink_transform",
        "reason": "The web walk's mask transform, the half no native backend "
                  "reaches. `canvas::render` is also the module the Painter port "
                  "is drawing features OUT of, so it is the one most likely to "
                  "lose a test module to an edit rather than to a deletion.",
    },
    "document": {
        "prefix": "document::",
        "anchor": "document::model::tests::"
                  "id_index_matches_rebuild_after_controller_edits_and_undo_and_resolves",
        "reason": "The id index is the structure `emit_document` rebuilds per "
                  "paint and the web walk borrows; a divergence here is invisible "
                  "in every rendered pixel until a lookup misses.",
    },
    "geometry": {
        "prefix": "geometry::",
        "anchor": "geometry::live::tests::"
                  "expand_of_a_split_compound_copies_every_other_field_to_every_ring",
        "reason": "Live geometry's field-copying law across rings -- the shape of "
                  "defect this repo has met repeatedly, where one field is "
                  "forgotten and every other field agrees.",
    },
    "interpreter": {
        "prefix": "interpreter::",
        "anchor": "interpreter::effects::tests::"
                  "artboard_duplicate_copies_every_other_field_and_leaves_the_source_alone",
        "reason": "The interpreter is the executable meaning of the spec (POLICY "
                  "§1); duplicate-and-leave-the-source-alone is a two-sided "
                  "assertion, so a half-built effect fails it.",
    },
    "painter": {
        "prefix": "painter::",
        "anchor": "painter::element_render::tests::"
                  "the_subtract_rings_are_co_oriented_and_are_read_under_the_declared_even_odd_rule",
        "reason": "`emit_element` is the renderer of record for native (A6, "
                  "ratified), and the even-odd rule is a VALUE inside a call "
                  "rather than a call -- the class a whole-op witness pass "
                  "cannot see.",
    },
    "panels": {
        "prefix": "panels::",
        "anchor": "panels::tests::every_panel_menu_predicate_read_is_published_to_the_menu_context",
        "reason": "The panel/menu contract that #119 made generic across both "
                  "ports; it asserts over EVERY predicate read, so a predicate "
                  "added without publication reds it.",
    },
    "recorder": {
        "prefix": "recorder::",
        "anchor": "recorder::core::tests::pointer_events_convert_per_event_under_pan_zoom",
        "reason": "Per-event conversion under pan/zoom -- the smallest area with "
                  "tests, and therefore the one whose disappearance moves a total "
                  "by the least and hides best.",
    },
    "surface": {
        "prefix": "surface::",
        "anchor": "surface::tests::luminance_promotion_on_a_surface_applies_the_bytes_law",
        "reason": "The bytes law behind luminance promotion, whose ClipIn "
                  "fallback repair is a STANDING NEGATIVE in this seat's bank: "
                  "an area with known open work must not go quiet.",
    },
    "tools": {
        "prefix": "tools::",
        "anchor": "tools::yaml_tool::tests::"
                  "eyedropper_parity_click_source_with_selection_copies_fill_to_target",
        "reason": "`yaml_tool` is where the generic-YAML doctrine (CLAUDE.md: "
                  "native code is discouraged) actually executes; a parity test "
                  "here covers the interpreter-driven tool path, not a native one.",
    },
    "workspace": {
        "prefix": "workspace::",
        "anchor": "workspace::app_state::character_panel_apply_tests::"
                  "a_range_tracking_edit_writes_only_the_tracking_onto_the_range",
        "reason": "`writes ONLY the tracking` is a negative assertion over the "
                  "other fields, which is what makes it a witness rather than a "
                  "smoke test.",
    },
}

# ⚠️ A NARROW SECOND GUARD, AND ITS ROLE IS NAMED SO IT DOES NOT READ AS THE
# PRIMARY ONE. The real floor on this declaration is DERIVED, in
# `declaration_findings`: an area on disk with no entry here reds, so the
# declaration cannot silently shrink while the tree stays the same. This
# constant only covers the case that rule cannot see -- a TREE that has itself
# fallen below eight areas, which would be a restructuring worth a human
# looking at rather than a gate quietly adjusting. Kept deliberately slack for
# that reason: an exact floor here would red on every ordinary refactor while
# buying nothing the derived rule does not already buy.
MIN_AREAS = 8

# A test binary prints these and no source file does. Requiring the PAIR is what
# makes "this is a runner stream" a checked premise: one `test result:` line
# alone is satisfied by a three-line hand-written file.
RESULT_SUMMARY = re.compile(r"^test result: (?:ok|FAILED)\.", re.MULTILINE)
HARNESS_BANNER = re.compile(r"^running \d+ tests?[ \t\r]*$", re.MULTILINE)

# ── THE PER-AREA COUNT ──────────────────────────────────────────────────────
# Everything below derives its expected side from the source tree and this
# invocation's cfg. Deliberately NO constant: see the docstring's scope section.

CARGO_TOML = ROOT / "jas_dioxus" / "Cargo.toml"

# `#[test]` is never on the same line as its `fn` in this tree (measured: 3,273
# occurrences, zero inline), so the attribute and the declaration are found
# separately. `#[wasm_bindgen_test]` is deliberately NOT matched -- those belong
# to the lane `check_wasm_canvas_count.py` guards and no native run registers
# one.
TEST_ATTR = re.compile(r"^\s*#\[test\]\s*$")
CFG_ATTR = re.compile(r"^\s*#\[cfg\((?P<cond>.*)\)\]\s*$")
# What may sit BETWEEN a `#[test]` and its `fn`: further attributes, doc
# comments, ordinary comments, blank lines. Anything else ends the run, which is
# what stops a nested helper `fn` in a PREVIOUS test's body from being read as
# the test's name.
ATTR_OR_DOC = re.compile(r"^\s*(#\[|#!\[|///|//!|//|$)")
# ⛔ `[A-Za-z0-9_]`, not `[a-z0-9_]`. A test name in this tree carries uppercase
# (`a_blended_layer_requires_the_layer_AND_the_blend`), and a lowercase-only
# pattern TRUNCATES it rather than missing it -- so the name still looks like a
# name and the diff blames the wrong test.
FN_DECL = re.compile(
    r"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?fn\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)"
)
MOD_DECL = re.compile(
    r"^\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*;"
)

# ⛔ THE BLOCK, NOT THE LOG. `cargo test` runs the library suite TWICE -- as
# `unittests src/lib.rs` and again as `unittests src/main.rs`, the bin target
# compiling the same modules -- so a whole-log count is exactly double.
RUNNING_LIB = re.compile(r"^\s*Running unittests src[/\\]lib\.rs\b")
BANNER_N = re.compile(r"^running (?P<n>\d+) tests?[ \t\r]*$")
# ` - should panic` is not decoration: three tests in this suite report with it.
OUTCOME = re.compile(
    r"^test (?P<path>[A-Za-z0-9_:]+)(?: - should panic)? \.\.\. "
    r"(?P<verdict>ok|ignored|FAILED)"
)


class CfgUnknown(Exception):
    """A cfg predicate outside the measured grammar. Raised, never defaulted."""


_CFG_TOKEN = re.compile(
    r'\s*(?:(?P<fn>all|any|not)\s*\(|'
    r'(?P<key>[a-z_]+)\s*=\s*"(?P<val>[^"]*)"|'
    r'(?P<ident>[a-z_][a-z0-9_]*)|(?P<close>\))|(?P<comma>,))'
)


def evaluate_cfg(cond: str, cfg: dict) -> bool:
    """Is `cond` true under `cfg`? ⛔ RAISES on anything it does not understand.

    A backward-compatible default here -- "assume false", or "assume true", or
    "skip it" -- is the resolver-that-cannot-refuse defect: every unparsed
    predicate would silently move the expected count and the result would still
    look like a measurement. The grammar covers every form measured in this tree
    and the raise is how a new one announces itself.
    """
    pos = 0

    def parse() -> bool:
        nonlocal pos
        m = _CFG_TOKEN.match(cond, pos)
        if not m:
            raise CfgUnknown(cond)
        pos = m.end()
        if m.group("fn"):
            fn = m.group("fn")
            args: list[bool] = []
            while True:
                args.append(parse())
                nxt = _CFG_TOKEN.match(cond, pos)
                if not nxt:
                    raise CfgUnknown(cond)
                pos = nxt.end()
                if nxt.group("close"):
                    break
                if not nxt.group("comma"):
                    raise CfgUnknown(cond)
            if fn == "all":
                return all(args)
            if fn == "any":
                return any(args)
            if len(args) != 1:
                raise CfgUnknown(cond)
            return not args[0]
        if m.group("key"):
            key, val = m.group("key"), m.group("val")
            if key == "feature":
                return val in cfg["features"]
            if key == "target_os":
                return val == cfg["target_os"]
            if key == "target_arch":
                return val == cfg["target_arch"]
            raise CfgUnknown(cond)
        if m.group("ident"):
            ident = m.group("ident")
            if ident == "test":
                return True
            if ident == "windows":
                return cfg["target_os"] == "windows"
            if ident == "unix":
                return cfg["target_os"] != "windows"
            raise CfgUnknown(cond)
        raise CfgUnknown(cond)

    value = parse()
    if cond[pos:].strip():
        raise CfgUnknown(cond)
    return value


def _cfg_above(lines: list[str], index: int) -> str | None:
    """The nearest non-`test` `#[cfg(...)]` in the attribute block above `index`."""
    j = index - 1
    while j >= 0 and ATTR_OR_DOC.match(lines[j]):
        m = CFG_ATTR.match(lines[j])
        if m and m.group("cond").strip() != "test":
            return m.group("cond").strip()
        j -= 1
    return None


def conditional_module_paths() -> dict[str, str]:
    """Source paths reachable only under a non-`test` cfg, and the cfg reaching them.

    A whole backend is gated at its `mod` declaration, not at its tests:
    `painter/mod.rs` carries `#[cfg(all(feature = "d2d", windows))] pub mod
    direct2d;`, which gates 97 `#[test]` fns none of which carries an attribute
    of its own. A scan that read only the attributes beside each test would call
    all 97 unconditional and demand they run on a lane that cannot build them.
    """
    gated: dict[str, str] = {}
    if not SRC.is_dir():
        return gated
    for path in SRC.rglob("*.rs"):
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        for i, line in enumerate(lines):
            decl = MOD_DECL.match(line)
            if not decl:
                continue
            cond = _cfg_above(lines, i)
            if cond is None:
                continue
            base = (
                path.parent
                if path.name in ("mod.rs", "lib.rs", "main.rs")
                else path.with_suffix("")
            )
            name = decl.group("name")
            for cand in (base / f"{name}.rs", base / name):
                try:
                    gated[cand.relative_to(SRC).as_posix()] = cond
                except ValueError:
                    pass
    return gated


def _gate_on_path(rel: str, gated: dict[str, str]) -> str | None:
    parts = rel.split("/")
    for k in range(1, len(parts) + 1):
        hit = gated.get("/".join(parts[:k]))
        if hit is not None:
            return hit
    return None


def declared_tests(area: str, gated: dict[str, str]) -> list[tuple[str, str, str | None]]:
    """Every `#[test]` fn under `src/<area>/`, as (name, "file:line", cfg or None).

    The cfg attached to a test is the nearest non-`test` `#[cfg]` beside it, or
    failing that the one gating the module its file lives in.
    """
    out: list[tuple[str, str, str | None]] = []
    area_dir = SRC / area
    if not area_dir.is_dir():
        return out
    for path in sorted(area_dir.rglob("*.rs")):
        rel = path.relative_to(SRC).as_posix()
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        out.extend(scan_tests(lines, rel, _gate_on_path(rel, gated)))
    return out


def scan_tests(
    lines: list[str], rel: str, file_gate: str | None
) -> list[tuple[str | None, str, str | None]]:
    """The per-file half of `declared_tests`, taking LINES so it can be driven directly.

    ⛔ BOTH OF THIS SCANNER'S RULES ARE REPAIRS OF A DEFECT MEASURED IN A
    THROWAWAY VERSION OF IT, and both produced a plausible wrong name rather
    than an error:

      * a lowercase-only name pattern TRUNCATED
        `a_blended_layer_requires_the_layer_AND_the_blend` at the uppercase, so
        the source and the log disagreed about a test that was running fine;
      * a fixed two-line window after `#[test]` picked up a helper `fn` nested
        INSIDE the previous test's body (`arc_of`, `json_of`), inventing two
        tests that never existed.

    Only the second of those was visible at all, and only because the diff had
    an impossible direction in it -- a name the runner reported that the source
    did not declare. ⇒ A SCAN THAT CAN ONLY UNDER-REPORT HAS NO SUCH TELL.
    """
    out: list[tuple[str | None, str, str | None]] = []
    for i, line in enumerate(lines):
        if not TEST_ATTR.match(line):
            continue
        gate = _cfg_above(lines, i) or file_gate
        name = None
        k = i + 1
        while k < len(lines):
            decl = FN_DECL.match(lines[k])
            if decl:
                name = decl.group("name")
            # ⛔ ONE GUARD, NOT TWO. A `break` beside the assignment above reads
            # as the thing that stops the walk and is unobservable behind this
            # line -- an `fn` is not an attribute or a doc comment, so this
            # breaks on the same iteration. With both present, a mutant that
            # took the LAST `fn` in the block instead of the FIRST survived the
            # nested-helper arm, which is a fixture that then looks like
            # coverage and is not. This is the line that owns stopping.
            if not ATTR_OR_DOC.match(lines[k]):
                break
            below = CFG_ATTR.match(lines[k])
            if below and below.group("cond").strip() != "test":
                gate = below.group("cond").strip()
            k += 1
        # ⛔ AN UNRESOLVED `#[test]` IS CARRIED WITH A None NAME, NOT DROPPED, so
        # the caller reds rather than quietly counting one test fewer and still
        # reporting an exact match.
        out.append((name, f"{rel}:{i + 1}", gate))
    return out


def crate_features() -> tuple[set[str], str | None]:
    """The default feature set, resolved transitively from `Cargo.toml`.

    Derived, not typed: the CI steps this gate guards run a bare `cargo test`,
    so the invocation's features ARE the crate's defaults, and a default list
    copied into this file would be one more number nobody re-reads. Returns
    (features, error); a parse that cannot find `[features]` returns an error
    rather than an empty set, because an empty set silently makes every
    `feature = "..."` predicate false.
    """
    if not CARGO_TOML.is_file():
        return set(), f"{CARGO_TOML.as_posix()} does not exist"
    text = CARGO_TOML.read_text(encoding="utf-8", errors="replace")
    section = re.search(r"^\[features\]\s*$(.*?)(?=^\[|\Z)", text, re.M | re.S)
    if not section:
        return set(), f"no [features] table in {CARGO_TOML.as_posix()}"
    table: dict[str, list[str]] = {}
    for key, body in re.findall(
        r"^([A-Za-z0-9_-]+)\s*=\s*\[(.*?)\]", section.group(1), re.M | re.S
    ):
        table[key] = re.findall(r'"([^"]*)"', body)
    if "default" not in table:
        return set(), f"no `default` key in the [features] table of {CARGO_TOML.name}"
    resolved: set[str] = set()
    pending = ["default"]
    while pending:
        feat = pending.pop()
        if feat in resolved or feat.startswith("dep:"):
            continue
        resolved.add(feat)
        pending.extend(table.get(feat, []))
    return resolved, None


def _host_target_os() -> str:
    """The cfg-relevant OS name for THIS machine, in Rust's vocabulary."""
    if sys.platform.startswith("win"):
        return "windows"
    if sys.platform == "darwin":
        return "macos"
    return "linux"


def lib_block(log: str) -> tuple[int, list[str]] | None:
    """The `unittests src/lib.rs` region: its banner count and its outcome lines.

    ⛔ SCOPED ON PURPOSE, AND THE WHOLE-LOG FORM IS THE TRAP: the bin target
    compiles the same modules, so `cargo test` reports the library suite twice
    and a log-wide count is exactly double the truth.
    """
    lines = log.splitlines()
    for i, line in enumerate(lines):
        if not RUNNING_LIB.match(line):
            continue
        j = i + 1
        while j < len(lines) and not BANNER_N.match(lines[j]):
            if RESULT_SUMMARY.match(lines[j]):
                return None
            j += 1
        if j >= len(lines):
            return None
        total = int(BANNER_N.match(lines[j]).group("n"))
        body: list[str] = []
        k = j + 1
        while k < len(lines) and not RESULT_SUMMARY.match(lines[k]):
            body.append(lines[k])
            k += 1
        if k >= len(lines):
            return None
        return total, body
    return None


def registered_counts(body: list[str]) -> tuple[dict[str, int], int]:
    """Tests the runner REGISTERED, by area, plus the total it registered.

    `ok`, `ignored` and `FAILED` all count: each one is a test the harness knew
    about, which is what the banner counts and therefore what the expected side
    must be compared against.
    """
    per: dict[str, int] = {}
    total = 0
    for line in body:
        m = OUTCOME.match(line)
        if not m:
            continue
        total += 1
        area = m.group("path").split("::")[0]
        per[area] = per.get(area, 0) + 1
    return per, total



def source_areas() -> set[str]:
    """Top-level `src/` subdirectories holding a PLAIN `#[cfg(test)]` module.

    ⛔ SUBDIRECTORIES ONLY, AND THE BOUNDARY IS DELIBERATE -- there is nothing
    missing from this function. Top-level `.rs` modules are excluded because the
    set of them that COMPILES depends on the feature set: `ffi.rs` carries tests
    that exist only under `--features ffi`, so "every top-level module with
    tests" is not a well-defined obligation without evaluating cfgs, and a rule
    that demands an anchor for a module the default lane never builds reds a
    working lane. Every `src/` SUBDIRECTORY holding a plain `#[cfg(test)]`
    module IS present in the default lane -- verified 2026-09-06 against
    `cargo test --lib -- --list`, 11 of 11 areas found, 3,085 tests listed.

    Plain, not `#[cfg(all(test, ...))]`: the wasm-gated modules belong to the
    lane `check_wasm_canvas_count.py` already guards, and counting them here
    would demand an anchor no native run can satisfy.
    """
    found: set[str] = set()
    if not SRC.is_dir():
        return found
    for path in SRC.rglob("*.rs"):
        rel = path.relative_to(SRC)
        if len(rel.parts) < 2:
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for line in text.splitlines():
            if line.strip() == "#[cfg(test)]":
                found.add(rel.parts[0])
                break
    return found


def source_has_test(anchor: str) -> bool:
    """Is `anchor` still a registered test in the source?

    The last path segment is the function name; it must appear as a `fn` with a
    `#[test]` attribute somewhere under the area's directory. Deliberately not a
    full module-path resolution: this asks "does this witness still exist",
    which is the question whose wrong answer makes an anchor silently
    unmatchable in the log.
    """
    parts = anchor.split("::")
    if len(parts) < 2:
        return False
    area, fn = parts[0], parts[-1]
    area_dir = SRC / area
    if not area_dir.is_dir():
        return False
    pattern = re.compile(r"#\[test\]\s*\n\s*(?:async\s+)?fn\s+" + re.escape(fn) + r"\b")
    for path in area_dir.rglob("*.rs"):
        if pattern.search(path.read_text(encoding="utf-8", errors="replace")):
            return True
    return False


def executed_ok(log: str, anchor: str) -> bool:
    """Did the runner report `anchor` as executed and PASSING?

    `\\r` in the trailing class, not decoration: a Windows lane tees this log and
    the line arrives CRLF-terminated. ` - should panic` likewise: a
    `#[should_panic]` test reports as `test <path> - should panic ... ok`, so
    without the suffix an anchor that were ever marked `#[should_panic]` could
    never match, and this gate would report a suite that did not run.
    """
    pattern = re.compile(
        r"^test " + re.escape(anchor) + r"(?: - should panic)? \.\.\. ok[ \t\r]*$",
        re.MULTILINE,
    )
    return bool(pattern.search(log))


def declaration_findings() -> list[str]:
    """Findings about the DECLARATION, before any log is read."""
    findings: list[str] = []

    if len(AREAS) < MIN_AREAS:
        findings.append(
            f"this gate declares {len(AREAS)} area(s), floor is {MIN_AREAS} -- a "
            f"declaration this thin asserts almost nothing and would report "
            f"success on a suite that had mostly stopped running"
        )

    for area, spec in AREAS.items():
        prefix = spec.get("prefix")
        anchor = spec.get("anchor")
        reason = spec.get("reason")
        if not isinstance(prefix, str) or not prefix.endswith("::"):
            findings.append(
                f"area {area!r} maps to prefix {prefix!r}, which is not a module "
                f"path ending in '::' -- a prefix that is not a module path is "
                f"matched by tests the area does not own"
            )
            continue
        if not isinstance(anchor, str) or not anchor.startswith(prefix):
            findings.append(
                f"area {area!r} declares anchor {anchor!r}, which does not start "
                f"with {prefix!r} -- an anchor outside its own area proves that "
                f"OTHER area ran, and eleven anchors from one module look eleven "
                f"times stronger than the one assertion they make"
            )
        if not isinstance(reason, str) or not reason.strip():
            findings.append(
                f"area {area!r}: anchor carries no reason -- an anchor without an "
                f"argument is how a lane's coverage becomes folklore"
            )

    # ⭐ THE DERIVED HALF, and the half that does not rot. The obligation is
    # recomputed FROM THE TREE on every run, so a new area with tests reds this
    # gate until it is given a witness. A list someone must remember to update is
    # the defect this repo has met at `swift:dropdown` and at a stale floor of 4.
    on_disk = source_areas()
    if not on_disk:
        findings.append(
            f"no `#[cfg(test)]` module found under {SRC.as_posix()} -- this "
            f"gate examined nothing, which is a refusal and not a pass"
        )
    for area in sorted(on_disk - set(AREAS)):
        findings.append(
            f"src/{area}/ holds a #[cfg(test)] module but no area is declared for "
            f"it -- it would run, or stop running, entirely unwatched"
        )
    for area in sorted(set(AREAS) - on_disk):
        findings.append(
            f"area {area!r} is declared but src/{area}/ holds no #[cfg(test)] "
            f"module -- a stale declaration is an excuse that outlived its "
            f"subject, and it would keep this gate green while covering nothing"
        )

    # An anchor that no longer exists cannot be matched in any log. Caught HERE,
    # against the source, so the message names a renamed test rather than
    # reporting a lane that did not run.
    for area, spec in sorted(AREAS.items()):
        anchor = spec.get("anchor")
        if isinstance(anchor, str) and area in on_disk and not source_has_test(anchor):
            findings.append(
                f"area {area!r}: anchor {anchor!r} is not a #[test] fn anywhere "
                f"under src/{area}/ -- it was renamed or deleted. Pick a new "
                f"witness and say why; an anchor that cannot be found is not a "
                f"satisfied anchor"
            )
    return findings


def log_findings(log: str, label: str) -> list[str]:
    """Findings about the RUN, given a declaration that is sound."""
    if not log.strip():
        return [
            f"{label} is empty -- a lane that produced no output produced no "
            f"evidence, and absent evidence is RED, never a skip"
        ]
    if not RESULT_SUMMARY.search(log) or not HARNESS_BANNER.search(log):
        return [
            f"{label} lacks the `running N tests` banner and `test result:` "
            f"summary a real harness run prints, so it is not a cargo-test "
            f"stream. This gate reads the RUNNER'S STDOUT by design; pointed at "
            f"a build log or a truncated capture it refuses rather than passing"
        ]
    findings: list[str] = []
    for area, spec in sorted(AREAS.items()):
        anchor = spec["anchor"]
        if not executed_ok(log, anchor):
            findings.append(
                f"area {area!r}: {anchor} is not reported as executed and passing "
                f"in {label} -- either the suite did not run it, or its "
                f"#[cfg(test)] module stopped being compiled. The total would "
                f"fall and every remaining test would still pass"
            )
    return findings


def count_findings(log: str, label: str, cfg: dict) -> list[str]:
    """Findings about HOW MUCH of each area ran, against a per-invocation expectation.

    This is the half an anchor cannot reach. The expected side is recomputed
    from the source tree here, under `cfg`, so there is no number to go stale
    and no arm that could test a constant against itself.
    """
    block = lib_block(log)
    if block is None:
        return [
            f"{label} carries no complete `Running unittests src/lib.rs` region "
            f"(banner and `test result:` summary). The per-area counts are taken "
            f"from that block ALONE, because `cargo test` reports the library "
            f"suite twice -- the bin target compiles the same modules -- so a "
            f"whole-log count is exactly double. A missing block is a REFUSAL, "
            f"never a skip"
        ]
    banner_total, body = block
    per_area, registered_total = registered_counts(body)

    findings: list[str] = []
    # ⛔ THE ANTI-VACUITY ARM, AND IT LEADS. If the outcome matcher has stopped
    # matching, every per-area count falls together and the comparison below
    # would report a tidy set of shortfalls that are all this gate's own fault.
    if registered_total != banner_total:
        findings.append(
            f"{label}: the lib.rs block announces {banner_total} test(s) and this "
            f"gate matched {registered_total} outcome line(s). Until those agree "
            f"the per-area counts are unsafe to read -- a matcher that has "
            f"stopped matching reports every area as short"
        )
        return findings

    gated = conditional_module_paths()
    for area in sorted(AREAS):
        declared = declared_tests(area, gated)
        unresolved = [where for name, where, _ in declared if name is None]
        if unresolved:
            findings.append(
                f"area {area!r}: {len(unresolved)} `#[test]` attribute(s) with no "
                f"resolvable `fn` ({', '.join(unresolved[:3])}) -- this gate could "
                f"not read its own subject, which is a refusal and not a count"
            )
            continue
        expected = 0
        for _name, where, cond in declared:
            if cond is None:
                expected += 1
                continue
            try:
                if evaluate_cfg(cond, cfg):
                    expected += 1
            except CfgUnknown:
                findings.append(
                    f"area {area!r}: the cfg `{cond}` at {where} is outside this "
                    f"gate's measured grammar. It is REFUSED rather than assumed "
                    f"true or false -- either assumption would move the expected "
                    f"count silently and the result would still look like a "
                    f"measurement"
                )
                expected = None
                break
        if expected is None:
            continue
        actual = per_area.get(area, 0)
        if actual == expected:
            continue
        if actual < expected:
            findings.append(
                f"area {area!r}: the source declares {expected} test(s) that this "
                f"invocation should build (features "
                f"{', '.join(sorted(cfg['features'])) or 'none'}; target_os "
                f"{cfg['target_os']}) and the runner registered {actual} -- "
                f"{expected - actual} test(s) stopped running while the area's "
                f"anchor still passed, which is exactly what an anchor cannot see"
            )
        else:
            findings.append(
                f"area {area!r}: the runner registered {actual} test(s) and the "
                f"source declares only {expected} for this invocation. MORE than "
                f"expected is this gate misreading its own subject, not a healthy "
                f"suite -- a disagreement in either direction is a refusal"
            )
    return findings


def _fake_log(anchors: list[str], banner: bool = True, summary: bool = True) -> str:
    lines = []
    if banner:
        lines.append(f"running {len(anchors)} tests")
    lines += [f"test {a} ... ok" for a in anchors]
    if summary:
        lines.append("test result: ok. %d passed; 0 failed; 0 ignored" % len(anchors))
    return "\n".join(lines) + "\n"


def self_test() -> int:
    """Drive every failure arm, and the empty-scan fatal FIRST.

    ⛔ THE EMPTY ARM LEADS BECAUSE IT IS THE ONE THAT PROVES THE INSTRUMENT CAN
    FAIL AT ALL. A self-test whose arms all pass through the same "no findings"
    path would report success for a gate whose checks had been deleted.
    """
    arms = 0
    failures: list[str] = []

    def arm(label: str, ok: bool) -> None:
        nonlocal arms
        arms += 1
        if not ok:
            failures.append(label)

    # 1. EMPTY LOG IS FATAL -- proven before anything else.
    arm("an empty log is a finding", bool(log_findings("", "the log")))
    arm("a whitespace-only log is a finding", bool(log_findings("   \n\n", "the log")))

    all_anchors = [spec["anchor"] for spec in AREAS.values()]

    # 2. POSITIVE CONTROL: a well-formed log naming every anchor is clean. If
    #    this arm ever fails, the arms below prove nothing -- they would all be
    #    passing for the wrong reason.
    arm("a complete runner log yields no findings",
        log_findings(_fake_log(all_anchors), "the log") == [])

    # 3. A log that is not a runner stream is refused, not passed.
    arm("a log with no banner is refused",
        bool(log_findings(_fake_log(all_anchors, banner=False), "the log")))
    arm("a log with no result summary is refused",
        bool(log_findings(_fake_log(all_anchors, summary=False), "the log")))

    # 4. THE ARM THIS GATE EXISTS FOR: one area stops running, everything else
    #    still passes, and the run still exits 0.
    for drop in sorted(AREAS):
        kept = [spec["anchor"] for a, spec in AREAS.items() if a != drop]
        found = log_findings(_fake_log(kept), "the log")
        arm(f"a log missing {drop!r}'s anchor is a finding",
            any(drop in f for f in found))

    # 5. A test reported as FAILING is not a test reported as passing.
    one = all_anchors[0]
    bad = _fake_log(all_anchors).replace(f"test {one} ... ok", f"test {one} ... FAILED")
    arm("an anchor reported FAILED does not satisfy its area",
        bool(log_findings(bad, "the log")))

    # 6. THE DECLARATION ARMS. The live declaration must be clean first --
    #    otherwise a mutation below could be "caught" by a pre-existing finding.
    live = declaration_findings()
    arm("the live declaration is clean", live == [])

    saved = {a: dict(spec) for a, spec in AREAS.items()}
    victim = sorted(AREAS)[0]
    try:
        AREAS[victim]["prefix"] = "algorithms"          # no trailing '::'
        arm("a prefix that is not a module path is a finding",
            any("module path" in f for f in declaration_findings()))
        AREAS[victim].update(saved[victim])

        AREAS[victim]["anchor"] = "workspace::app_state::tests::somewhere_else"
        arm("an anchor outside its own area's prefix is a finding",
            any("does not start with" in f for f in declaration_findings()))
        AREAS[victim].update(saved[victim])

        AREAS[victim]["reason"] = "   "
        arm("an anchor with no reason is a finding",
            any("no reason" in f for f in declaration_findings()))
        AREAS[victim].update(saved[victim])

        AREAS[victim]["anchor"] = f"{victim}::tests::a_test_that_does_not_exist_anywhere"
        arm("an anchor that is not a #[test] fn in the source is a finding",
            any("renamed or deleted" in f for f in declaration_findings()))
        AREAS[victim].update(saved[victim])

        removed = AREAS.pop(victim)
        arm("an on-disk area with no declaration is a finding",
            any("no area is declared" in f for f in declaration_findings()))
        AREAS[victim] = removed

        AREAS["a_directory_that_does_not_exist"] = {
            "prefix": "a_directory_that_does_not_exist::",
            "anchor": "a_directory_that_does_not_exist::tests::x",
            "reason": "self-test only",
        }
        arm("a declared area absent from the tree is a finding",
            any("stale declaration" in f for f in declaration_findings()))
        del AREAS["a_directory_that_does_not_exist"]

        kept_areas = dict(AREAS)
        AREAS.clear()
        AREAS.update({k: kept_areas[k] for k in sorted(kept_areas)[:1]})
        arm("a declaration below the area floor is a finding",
            any("floor is" in f for f in declaration_findings()))
        AREAS.clear()
        AREAS.update(kept_areas)
    finally:
        AREAS.clear()
        AREAS.update(saved)

    arm("the declaration is restored after the mutations", declaration_findings() == [])

    # ── 7. THE COUNT'S ARMS. ⛔ THE REFUSAL ARM LEADS, for the same reason the
    #    empty-log arm leads above: `evaluate_cfg` deciding an unknown predicate
    #    instead of raising is the one failure that would leave every number
    #    below looking exactly like a measurement.
    unknown_forms = [
        'target_family = "wasm"',        # a key the grammar does not carry
        "some_future_cfg",               # a bare ident it does not carry
        'not(feature = "a", feature = "b")',   # `not` is unary
        'all(feature = "a"',             # unbalanced
        'feature = "a" garbage',         # trailing junk
    ]
    for form in unknown_forms:
        raised = False
        try:
            evaluate_cfg(form, {"features": {"a"}, "target_os": "macos",
                                "target_arch": "x86_64"})
        except CfgUnknown:
            raised = True
        arm(f"the cfg {form!r} is REFUSED, not decided", raised)

    cfg_web = {"features": {"default", "web"}, "target_os": "macos",
               "target_arch": "x86_64"}
    cfg_win = {"features": {"default", "web", "d2d"}, "target_os": "windows",
               "target_arch": "x86_64"}
    for cond, under, want, why in [
        ("test", cfg_web, True, "a plain `test` cfg is always true here"),
        ('feature = "web"', cfg_web, True, "a feature that is on"),
        ('feature = "d2d"', cfg_web, False, "a feature that is off"),
        ('all(feature = "d2d", windows)', cfg_web, False, "`all` with a false arm"),
        ('all(feature = "d2d", windows)', cfg_win, True, "`all` with both arms true"),
        ('not(all(feature = "d2d", windows))', cfg_web, True, "`not` of a false `all`"),
        ('any(feature = "d2d", feature = "web")', cfg_web, True, "`any` with one true"),
        ("windows", cfg_web, False, "the bare `windows` ident off Windows"),
        ("windows", cfg_win, True, "the bare `windows` ident on Windows"),
        ("unix", cfg_web, True, "the bare `unix` ident off Windows"),
        ('target_os = "macos"', cfg_web, True, "an explicit target_os"),
    ]:
        arm(f"cfg {cond!r}: {why}", evaluate_cfg(cond, under) is want)

    # ── THE SCANNER, driven on source text rather than on a path. Each arm is a
    #    defect this scanner actually had, written from the tree's own lines.
    upper = ["#[test]", "fn a_blended_layer_requires_the_layer_AND_the_blend() {", "}"]
    arm("an uppercase run in a test name survives the scan",
        scan_tests(upper, "f.rs", None)
        == [("a_blended_layer_requires_the_layer_AND_the_blend", "f.rs:1", None)])

    nested = [
        "#[test]",
        "fn a_non_centre_ellipse_stroke_describes_the_same_conic() {",
        "    fn arc_of(align: StrokeAlign) -> EllipseArc {",
        "        todo!()",
        "    }",
        "}",
    ]
    arm("a helper fn nested in a test's body is not read as a second test",
        [n for n, _, _ in scan_tests(nested, "f.rs", None)]
        == ["a_non_centre_ellipse_stroke_describes_the_same_conic"])

    gated_above = ['#[cfg(all(feature = "d2d", windows))]', "#[test]", "fn t() {", "}"]
    arm("a cfg ABOVE the #[test] gates it",
        scan_tests(gated_above, "f.rs", None)
        == [("t", "f.rs:2", 'all(feature = "d2d", windows)')])

    gated_below = ["#[test]", '#[cfg(feature = "web")]', "fn t() {", "}"]
    arm("a cfg BELOW the #[test] gates it too",
        scan_tests(gated_below, "f.rs", None) == [("t", "f.rs:1", 'feature = "web"')])

    arm("a plain #[cfg(test)] beside a test does NOT gate it",
        scan_tests(["#[cfg(test)]", "#[test]", "fn t() {", "}"], "f.rs", None)
        == [("t", "f.rs:2", None)])

    arm("a test in a module-gated file inherits the module's cfg",
        scan_tests(["#[test]", "fn t() {", "}"], "f.rs", 'feature = "ffi"')
        == [("t", "f.rs:1", 'feature = "ffi"')])

    arm("a #[test] with no reachable fn is carried as UNRESOLVED, not dropped",
        scan_tests(["#[test]", "let x = 1;"], "f.rs", None) == [(None, "f.rs:1", None)])

    arm("#[wasm_bindgen_test] is not counted as a #[test]",
        scan_tests(["#[wasm_bindgen_test]", "fn t() {", "}"], "f.rs", None) == [])

    # ── THE BLOCK. ⛔ THE DOUBLE-COUNT ARM IS THE ONE THAT MATTERS: this is the
    #    trap the real log sprang, and the only one whose wrong answer is a tidy
    #    round multiple of the right one.
    twice = (
        "     Running unittests src/lib.rs (target/debug/deps/x-1)\n"
        "\nrunning 2 tests\n"
        "test canvas::a::tests::one ... ok\n"
        "test canvas::a::tests::two ... ok\n"
        "test result: ok. 2 passed; 0 failed; 0 ignored\n"
        "     Running unittests src/main.rs (target/debug/deps/x-2)\n"
        "\nrunning 2 tests\n"
        "test canvas::a::tests::one ... ok\n"
        "test canvas::a::tests::two ... ok\n"
        "test result: ok. 2 passed; 0 failed; 0 ignored\n"
    )
    block = lib_block(twice)
    arm("the lib.rs block is found and the main.rs block is NOT added to it",
        block is not None and block[0] == 2
        and registered_counts(block[1])[1] == 2)
    arm("a log with no lib.rs unittests block yields no block at all",
        lib_block(_fake_log(all_anchors)) is None)
    arm("a lib.rs Running line with no banner before its summary yields no block",
        lib_block("     Running unittests src/lib.rs (x)\n"
                  "test result: ok. 0 passed; 0 failed; 0 ignored\n") is None)

    outcomes = [
        "test document::model::tests::plain ... ok",
        "test document::model::tests::panics - should panic ... ok",
        "test document::model::tests::skipped ... ignored, not yet supported",
        "test document::model::tests::broke ... FAILED",
        "test result: ok. 1 passed",
    ]
    per, total = registered_counts(outcomes)
    arm("ok, should-panic, ignored and FAILED all count as REGISTERED",
        total == 4 and per == {"document": 4})

    # ── count_findings END TO END, against THE REAL SOURCE TREE. The expected
    #    side is built by the gate itself, so this arm is a live check that the
    #    scanner and the comparison agree about the tree as it stands today.
    gated_now = conditional_module_paths()

    def _expected_now(area: str) -> int:
        n = 0
        for name, _where, cond in declared_tests(area, gated_now):
            if name is None:
                return -1
            if cond is None or evaluate_cfg(cond, cfg_web):
                n += 1
        return n

    expected_now = {a: _expected_now(a) for a in AREAS}
    arm("every declared area resolves a non-negative expected count",
        all(v >= 0 for v in expected_now.values()))

    # ⛔ THE ARM BELOW EXISTS BECAUSE THE END-TO-END ARMS CANNOT HOLD THIS.
    #    They build their log FROM the expected counts, so a systematic error in
    #    the expected side agrees with itself and every arm stays green --
    #    measured: a mutant that stopped module-level cfgs from gating their
    #    files moved `painter` by 97 tests and survived every other arm here.
    #    This one asks a question the counting cannot answer: is a test whose
    #    FILE is gated reported as conditional at all?
    ungated_under_a_gate: list[str] = []
    for area in sorted(AREAS):
        for _name, where, cond in declared_tests(area, gated_now):
            if cond is None and _gate_on_path(where.split(":")[0], gated_now):
                ungated_under_a_gate.append(where)
    arm("a test inside a module-gated file is reported as CONDITIONAL -- the "
        "expected side cannot check this, because it is built from it",
        not ungated_under_a_gate)
    arm("some test in this tree IS gated, so the arm above is not vacuous",
        any(cond is not None
            for area in AREAS
            for _n, _w, cond in declared_tests(area, gated_now)))
    arm("the expected counts are not all zero -- an all-zero expectation is "
        "satisfied by a log with no tests in it at all",
        sum(expected_now.values()) > 0)

    def _synthetic(counts: dict[str, int]) -> str:
        rows = []
        for area, n in sorted(counts.items()):
            rows += [f"test {area}::m::tests::t{i} ... ok" for i in range(n)]
        return (
            "     Running unittests src/lib.rs (target/debug/deps/x-1)\n"
            f"\nrunning {len(rows)} tests\n" + "\n".join(rows) +
            "\ntest result: ok. %d passed; 0 failed; 0 ignored\n" % len(rows)
        )

    arm("a log matching the tree's own per-area counts yields NO count findings",
        count_findings(_synthetic(expected_now), "the log", cfg_web) == [])

    short = dict(expected_now)
    victim_area = max(expected_now, key=lambda a: expected_now[a])
    short[victim_area] = expected_now[victim_area] // 2
    found = count_findings(_synthetic(short), "the log", cfg_web)
    arm("an area that loses half its tests IS a finding -- the case an anchor "
        "cannot see, and the whole reason this count exists",
        any(victim_area in f and "stopped running" in f for f in found))

    over = dict(expected_now)
    over[victim_area] = expected_now[victim_area] + 1
    arm("an area with MORE tests than the source declares is also a finding",
        any(victim_area in f and "misreading its own subject" in f
            for f in count_findings(_synthetic(over), "the log", cfg_web)))

    # ⛔ THIS FIXTURE IS SHORT IN EVERY AREA *AND* MIS-BANNERED, and both halves
    #    are load-bearing. With correct per-area counts, "suppressed" and "not
    #    suppressed" both yield exactly one finding, so the arm could not see
    #    the behaviour it names -- measured: a mutant removing the suppression
    #    survived it.
    starved = {a: max(0, n - 1) for a, n in expected_now.items()}
    mismatched = _synthetic(starved).replace(
        f"running {sum(starved.values())} tests",
        f"running {sum(starved.values()) + 7} tests")
    suppressed = count_findings(mismatched, "the log", cfg_web)
    arm("a banner that disagrees with the matched outcome lines is a finding, "
        "and it SUPPRESSES the per-area counts rather than reporting a "
        "shortfall in every area that is this gate's own fault",
        len(suppressed) == 1 and "announces" in suppressed[0])

    arm("a log with no lib.rs block is a count REFUSAL, not a skip",
        bool(count_findings(_fake_log(all_anchors), "the log", cfg_web)))

    feats, feats_err = crate_features()
    arm("the crate's default features are derived from Cargo.toml, not typed",
        feats_err is None and "web" in feats and "d2d" not in feats)

    if failures:
        print(f"check_rust_suite_ran SELF-TEST: FAILED {len(failures)} of {arms} arm(s)")
        for f in failures:
            print(f"  ARM FAILED: {f}")
        return 1
    print(
        f"check_rust_suite_ran SELF-TEST: OK ({arms} arms driven; empty-log fatal "
        f"proven FIRST; {len(AREAS)} declared area(s) each driven as a "
        f"stopped-running mutant; every declaration failure path NAMES findings)"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Prove the main Rust suite RAN, area by area, and how much of it."
    )
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--log", help="the cargo-test stdout to adjudicate")
    parser.add_argument(
        "--features",
        help="comma-separated features this invocation built with. DEFAULT: the "
             "crate's own `default` list, resolved from Cargo.toml -- which is "
             "what a bare `cargo test` uses, and both CI steps run a bare one.",
    )
    parser.add_argument(
        "--target-os",
        help="the target OS the suite ran on, for cfgs like `windows`. DEFAULT: "
             "this machine, which both CI steps make true by running the suite "
             "and this gate in the same job. A wrong value is LOUD, not silent: "
             "it moves the expected counts and reds.",
    )
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    findings = declaration_findings()
    if findings:
        print("check_rust_suite_ran: REFUSED -- the declaration is unsound:")
        for f in findings:
            print(f"  {f}")
        return 1

    if not args.log:
        print("check_rust_suite_ran: REFUSED -- --log is required (or --self-test). "
              "A run with no subject is not a pass.")
        return 2

    path = pathlib.Path(args.log)
    if not path.is_file():
        print(f"check_rust_suite_ran: REFUSED -- {args.log} does not exist. "
              f"A missing log is absent evidence, which is RED, never a skip.")
        return 2

    if args.features is not None:
        features = {f.strip() for f in args.features.split(",") if f.strip()}
    else:
        features, err = crate_features()
        if err:
            print(
                f"check_rust_suite_ran: REFUSED -- the default feature set could "
                f"not be derived ({err}). An empty feature set would make every "
                f"`feature = \"...\"` predicate false and silently lower every "
                f"expected count, so it is refused rather than assumed."
            )
            return 2
    cfg = {
        "features": features,
        "target_os": args.target_os or _host_target_os(),
        "target_arch": "unknown",
    }

    log = path.read_text(encoding="utf-8", errors="replace")
    findings = log_findings(log, args.log) + count_findings(log, args.log, cfg)
    if findings:
        print(f"check_rust_suite_ran: FAIL -- {len(findings)} finding(s):")
        for f in findings:
            print(f"  {f}")
        return 1

    block = lib_block(log)
    print(
        f"check_rust_suite_ran: OK ({len(AREAS)} area(s), each proved to have RUN "
        f"by a named test passing in {args.log}, and each proved to have run IN "
        f"FULL against a count derived from the source under features "
        f"{','.join(sorted(cfg['features'])) or 'none'} / target_os "
        f"{cfg['target_os']}; {block[0]} test(s) registered in the lib.rs block). "
        f"⛔ THE LIMIT, NAMED: the count compares REGISTERED tests, and `ignored` "
        f"counts as registered -- a test that gains #[ignore] stops running "
        f"without moving any number here. The eleven anchors cover that for "
        f"eleven tests; nothing covers it for the rest."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
