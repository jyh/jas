#!/usr/bin/env python3
"""GUIEYES check suite — visual facts CI could not previously see.

Run through `scripts/gui_drive.sh` (which brings the dev server up first):

    ./scripts/gui_drive.sh                       # every check
    ./scripts/gui_drive.sh --check chain_visible
    ./scripts/gui_drive.sh --list
    ./scripts/gui_drive.sh --regress dead_sweep  # prove a check has teeth
                                                 # (auto-selects its owning check)

Exit status is 0 only when every selected check passed, so a conductor can
gate on it. Under `--regress` the exit code carries the teeth verdict: 0 the
fault was caught, 1 the gate is blind to it, 3 the harness itself broke.

EACH CHECK IS A DEFECT CLASS, NOT A WIDGET
------------------------------------------
  stroke_width_invariance  a rendered property must survive an unrelated
                           panel edit               (JYH's 5pt → 1pt)
  chain_visible            declared-checked must be VISIBLY checked
                           (the pair assertion)     (invisible highlight)
  tile_click_responds      a declared-clickable tile must actually respond
                                                    (dead brush tile)
  behavior_liveness        the generic sweep: every declared-clickable
                           widget live in the DOM must move something

FAULT INJECTION (`--regress MODE`)
----------------------------------
A green check proves nothing unless it can go red. Each mode reproduces a
real defect at the layer it escaped from, and EACH MODE OWNS EXACTLY ONE
CHECK — the one it must make fail. `--regress MODE` with no `--check`
auto-selects that owning check; pairing a mode with a different `--check`
is a usage error (exit 2), never a fake red.

  MODE                 OWNING CHECK             what it breaks
  invisible_highlight  chain_visible            neutralise the checked
                                                highlight in CSS — the state
                                                still flips, nothing paints
  dead_tile            tile_click_responds      strip the swatch's
                                                `data-dioxus-id` so the
                                                delegated handler cannot
                                                resolve it (declared,
                                                rendered, unwired)
  dead_sweep           behavior_liveness        strip `data-dioxus-id` from
                                                ONE in-scope swept widget, in
                                                the SAME pristine probe that
                                                clicks it, so the sweep must
                                                report that widget DEAD
  width_reset          stroke_width_invariance  a second Stroke-panel weight
                                                commit while selected — on this
                                                build a livelock (see
                                                GUI_EYES.md §Findings)
  thin_stroke          stroke_width_invariance  draw the probe stroke at 1pt
                                                when the check asked for 5pt

SCORING (`--regress`). The verdict is INVERTED, but not blindly — a red for
the wrong reason proves nothing:

  * the check fails AND the failure carries the mode's expected marker
    (`FAULTS[mode].marker`, a substring of the check's own `ctx.want`
    message) -> `TEETH ok`, exit 0;
  * the check PASSES with the fault injected -> `TEETH MISSING`, exit 1
    (the gate is blind to the defect it claims to catch);
  * the check fails WITHOUT the expected marker, or the harness itself
    errors (no Chrome, dev server down, a CDP timeout, a launch failure)
    -> `HARNESS ERROR`, exit 3 ("teeth unproven") — never scored as a pass,
    because a caught fault and a broken host must not look alike.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time

from gui_probe import CTRL, SHIFT, GuiProbe, ProbeFailure

WORKSPACE_JSON = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "workspace", "workspace.json")

CHECKS: dict = {}


def check(name: str, about: str):
    def deco(fn):
        fn.about = about
        CHECKS[name] = fn
        return fn
    return deco


class Ctx:
    """Per-check services: logging, evidence collection, fault injection."""

    def __init__(self, probe: GuiProbe, shot_dir: str | None, regress: str | None,
                 new_probe=None, opts=None):
        self.p = probe
        self.shot_dir = shot_dir
        self.regress = regress
        # A factory for ADDITIONAL pristine app instances. The liveness sweep
        # needs one per widget: clicking widgets serially in a single instance
        # accumulates document/panel state, and that accumulation — not any one
        # widget — is what produced a 200-record mutation storm and then a
        # wedge during development. Isolation makes every verdict attributable.
        self.new_probe = new_probe
        self.opts = opts or {}
        self.notes: list[str] = []

    def note(self, msg: str):
        self.notes.append(msg)
        print(f"    | {msg}", flush=True)

    def shot(self, name: str, target: str | None = None):
        if not self.shot_dir:
            return None
        path = os.path.join(self.shot_dir, f"{name}.png")
        self.p.shot(path, target)
        self.note(f"shot {path}")
        return path

    def want(self, cond: bool, msg: str):
        if not cond:
            raise ProbeFailure(msg)
        self.note(f"OK {msg}")

    # --- fault injection ------------------------------------------------

    def inject(self, mode: str, probe: GuiProbe | None = None) -> bool:
        """Apply fault `mode` if it is the one requested. Returns True if applied.

        The fault lands in `probe` (default: this check's primary probe). The
        liveness sweep passes its per-widget PRISTINE probe here, so the fault
        is stripped in the SAME browser that performs the swept click — an
        earlier version applied it to the primary probe while the sweep clicked
        in a throwaway one, so it never bit anything.
        """
        if self.regress != mode:
            return False
        FAULTS[mode].apply(probe or self.p)
        self.note(f"INJECTED FAULT {mode!r}")
        return True


def _strip_dioxus_id(p: GuiProbe, ids: list[str]):
    """Sever the delegated handler binding on each of `ids`, in probe `p`.

    Dioxus delegates DOM events from the document root and resolves the
    handler by `data-dioxus-id`; removing that attribute cuts the binding
    without touching layout or styling — a widget that looks perfectly
    clickable and does nothing.
    """
    p.cdp.evaluate(
        f"(()=>{{for(const id of {json.dumps(ids)}){{"
        "const e=document.getElementById(id);"
        "if(e){e.removeAttribute('data-dioxus-id');"
        "e.style.pointerEvents='auto';}}return true;})()")


def _fault_invisible_highlight(p: GuiProbe):
    """Kill the rendered side of the checked state, keep the declared side.

    Exactly the shape of the escape: `data-checked` flips as designed, so a
    DOM-only check stays green while the user sees nothing.
    """
    p.cdp.evaluate(
        "(()=>{const s=document.createElement('style');"
        "s.textContent='.jas-icon-button[data-checked=\"true\"]"
        "{background:transparent !important;box-shadow:none !important;}';"
        "document.head.appendChild(s);return true;})()")


def _fault_dead_tile(p: GuiProbe):
    """Unwire the colour-panel swatch that `tile_click_responds` clicks."""
    _strip_dioxus_id(p, ["cp_black_swatch", "cp_white_swatch"])


def _fault_dead_sweep(p: GuiProbe):
    """Unwire ONE in-default-scope widget the liveness sweep will click.

    The sweep clicks each widget in its own pristine probe; this must run in
    THAT probe (the sweep passes it explicitly), so the widget the sweep is
    about to click is the one that goes dead — and the sweep reports it DEAD.
    """
    _strip_dioxus_id(p, [DEAD_SWEEP_TARGET])


def _fault_width_reset(p: GuiProbe):
    """Reproduce the 5pt → 1pt reset as a side effect of an unrelated edit.

    NOTE (finding, 2026-07-24): on this build the injected user action — a
    SECOND Stroke-panel weight commit made while an object is selected — does
    not merely change the width, it WEDGES the app (see
    GUI_EYES.md §Findings). The check still goes red, via `heartbeat`, whose
    message ("the main thread is wedged") is the mode's marker. Use
    `thin_stroke` for a wedge-free teeth demonstration of the same measurement.
    """
    p.set_field("stk_weight", "1")


def _fault_thin_stroke(p: GuiProbe):
    """No browser-side mutation: `draw_probe_line` draws the stroke at 1pt when
    this mode is armed, so the 5pt-thickness assertion fails at 2.0px vs the
    4.0px floor — the wedge-free proof the canvas measurement tells fat from
    thin, exactly the observation JYH made by eye."""


# The single widget `dead_sweep` unwires. It must be inside SWEEP_DEFAULT_SCOPES
# (so the default sweep actually reaches it) and reliably LIVE in the stock scene
# (so a healthy sweep passes and only the injection turns it DEAD). This chain
# toggle sits in the Stroke panel, starts unchecked, and flips its own
# `data-checked` on click — a clean, self-contained meaningful mutation to sever.
DEAD_SWEEP_TARGET = "stk_link_arrowhead_scale"


class Fault:
    """A fault mode: how to inject it, which check it must break, and the
    substring the intended failure carries so a red can be attributed to it
    (not to a broken host or an unrelated defect)."""

    def __init__(self, apply, check: str, marker: str):
        self.apply = apply
        self.check = check
        self.marker = marker


# Every mode owns exactly ONE check. `marker` is a stable fragment of that
# check's own failing `ctx.want` message; the regress scorer requires it in the
# failure before reporting TEETH ok (see module doc + main()).
FAULTS = {
    "invisible_highlight": Fault(_fault_invisible_highlight, "chain_visible",
                                 "RENDERED style moved"),
    "dead_tile": Fault(_fault_dead_tile, "tile_click_responds",
                       "moved the DOM meaningfully"),
    "dead_sweep": Fault(_fault_dead_sweep, "behavior_liveness",
                        DEAD_SWEEP_TARGET),
    "width_reset": Fault(_fault_width_reset, "stroke_width_invariance",
                         "the main thread is wedged"),
    "thin_stroke": Fault(_fault_thin_stroke, "stroke_width_invariance",
                         "5pt stroke renders thick"),
}


# ---------------------------------------------------------------------------
# Shared scene setup
# ---------------------------------------------------------------------------

# Canvas-local geometry of the probe stroke. Horizontal so a single vertical
# scanline crosses it perpendicularly and `longest` IS the rendered thickness.
LINE_Y = 300
LINE_X0, LINE_X1 = 300, 500
SCAN_X = 400
SCAN_Y0, SCAN_SPAN = LINE_Y - 25, 50


def deselect(p: GuiProbe):
    """Select > Deselect, so the selection overlay never pollutes a pixel read."""
    p.focus_app()
    p.key("a", "KeyA", mods=CTRL | SHIFT)
    time.sleep(0.3)


def select_all(p: GuiProbe):
    p.focus_app()
    p.key("a", "KeyA", mods=CTRL)
    time.sleep(0.3)


def draw_probe_line(ctx: Ctx, weight: str) -> float:
    """Set the stroke weight, draw one horizontal line, return its thickness."""
    p = ctx.p
    if ctx.inject("thin_stroke"):
        weight = "1"
        ctx.note("fault: the probe stroke will be drawn at 1pt, not 5pt")
    got = p.set_field("stk_weight", weight)
    ctx.want(got.strip().startswith(weight),
             f"stroke weight field committed {got!r} for input {weight!r}")
    p.click("btn_line")
    ctx.want(p.checked("btn_line"), "line tool is the active tool")
    p.drag([(LINE_X0, LINE_Y), (LINE_X1, LINE_Y), (LINE_X1, LINE_Y)])
    deselect(p)
    span = p.ink_span(SCAN_X, SCAN_Y0, SCAN_SPAN)
    ctx.note(f"scanline x={SCAN_X}: thickness={span['longest']}px "
             f"ink={span['ink']}px pattern={span['pattern']}")
    return span["longest"]


# ---------------------------------------------------------------------------
# The checks
# ---------------------------------------------------------------------------

@check("stroke_width_invariance",
       "a fat stroke stays fat after an unrelated Stroke-panel edit")
def stroke_width_invariance(ctx: Ctx):
    """JYH's bug: a 5pt stroke came back 1pt after touching the panel.

    Asserts a RENDERED property (ink thickness on the canvas), never the
    widget's own value — so it catches the reset no matter which layer caused
    it. Invariance, not an absolute: anti-aliasing shifts the number by a
    pixel, but T-before and T-after are the same measurement.
    """
    p = ctx.p
    t_before = draw_probe_line(ctx, "5")
    ctx.want(t_before >= 4.0,
             f"a 5pt stroke renders thick: {t_before}px (a 1pt stroke measures ~2px)")
    ctx.shot("stroke_before")

    # Reselect: the bug shows up while the object is selected and the user
    # fiddles with the panel.
    select_all(p)
    # The UNRELATED edit. Linking arrowhead scales cannot change the width of
    # a plain line by any legitimate reading of the spec.
    p.click("stk_link_arrowhead_scale")
    ctx.note("unrelated edit: clicked stk_link_arrowhead_scale (arrowhead-scale link)")
    ctx.inject("width_reset")
    # Before trusting any pixel read, confirm the app is still servicing work:
    # a wedged main thread would otherwise surface as a socket timeout inside
    # the scanline probe and read like a harness bug.
    ctx.note(f"app responsive after the unrelated edit "
             f"({p.heartbeat(6.0, 'the app')}s round trip)")
    deselect(p)

    span = p.ink_span(SCAN_X, SCAN_Y0, SCAN_SPAN)
    t_after = span["longest"]
    ctx.note(f"after unrelated edit: thickness={t_after}px pattern={span['pattern']}")
    ctx.shot("stroke_after")
    ctx.want(t_after == t_before,
             f"stroke thickness is INVARIANT across the unrelated edit "
             f"({t_before}px -> {t_after}px)")


@check("chain_visible",
       "a checked icon-button is VISUALLY distinguishable from unchecked")
def chain_visible(ctx: Ctx):
    """The invisible-highlight class, caught by asserting the PAIR.

    Declared state (`data-checked`, what the interpreter believes) is compared
    against rendered state (computed style + the actual pixel crop). Either
    side alone is green during the bug; only their DIVERGENCE names it.
    """
    p = ctx.p
    target = "stk_link_arrowhead_scale"
    ctx.want(p.hit_target(target) == target,
             f"{target} is the topmost element at its own centre "
             f"(nothing is intercepting the click)")
    ctx.inject("invisible_highlight")

    off_declared = p.checked(target)
    off_bg = p.css(target, "background-color")
    off_shadow = p.css(target, "box-shadow")
    off_px = p.region_stats(target)
    ctx.want(off_declared is False, "starts unchecked (declared)")
    ctx.note(f"unchecked: bg={off_bg} shadow={off_shadow} "
             f"mean={off_px['mean']} digest={off_px['digest']}")
    ctx.shot("chain_unchecked", target)

    p.click(target)

    on_declared = p.checked(target)
    on_bg = p.css(target, "background-color")
    on_shadow = p.css(target, "box-shadow")
    on_px = p.region_stats(target)
    ctx.note(f"checked:   bg={on_bg} shadow={on_shadow} "
             f"mean={on_px['mean']} digest={on_px['digest']}")
    ctx.shot("chain_checked", target)

    ctx.want(on_declared is True,
             "the click flipped the DECLARED state (data-checked true)")
    style_moved = (on_bg != off_bg) or (on_shadow != off_shadow)
    ctx.want(style_moved,
             f"the RENDERED style moved too: background {off_bg} -> {on_bg}, "
             f"box-shadow {off_shadow!r} -> {on_shadow!r}")
    dist = p.stats_distance(off_px, on_px)
    ctx.want(dist >= 10.0,
             f"the pixel crop is measurably different: mean distance {dist} "
             f"(>=10 required; 0 would mean the highlight is invisible)")
    ctx.want(on_px["digest"] != off_px["digest"],
             f"crop digests differ ({off_px['digest']} -> {on_px['digest']})")


@check("tile_click_responds",
       "a declared-clickable tile responds to a click at all")
def tile_click_responds(ctx: Ctx):
    """The dead-brush-tile class.

    Two independent observations, because either alone can lie: the DOM must
    move at all (generic liveness), and the tile's own DECLARED effect must
    land (here `set_active_color #000000`, observable as the fill swatch
    turning black).
    """
    p = ctx.p
    tile = "cp_black_swatch"
    ctx.want(p.exists(tile), f"{tile} is present in the live DOM")
    ctx.want(p.hit_target(tile) == tile, f"{tile} is clickable at its own centre")
    ctx.inject("dead_tile")

    before = p.attr("cp_fill_swatch", "style")
    ctx.note(f"fill swatch before: ...{before[-60:]}")
    p.watch_start()
    p.click(tile)
    meaningful = p.watch_meaningful(tile)
    incidental = p.watch_incidental()
    p.watch_stop()
    after = p.attr("cp_fill_swatch", "style")
    ctx.note(f"fill swatch after:  ...{after[-60:]}")
    ctx.note(f"DOM mutations: {len(meaningful)} meaningful, {incidental} "
             f"decoration-only [{p.describe_records(meaningful)}]")
    ctx.shot("tile_clicked")

    ctx.want(len(meaningful) > 0,
             f"the click moved the DOM meaningfully ({len(meaningful)} "
             f"mutations beyond focus/hover decoration); 0 means the widget "
             f"declares a click behavior that is not wired")
    ctx.want("rgb(0, 0, 0)" in after or "#000000" in after,
             "the tile's DECLARED effect landed: the fill swatch is now black")


@check("behavior_liveness",
       "generic sweep: every declared-clickable widget live in the DOM responds")
def behavior_liveness(ctx: Ctx):
    """The gate that would have caught the dead tile without anyone naming it.

    Spec-derived: the clickable set comes from `workspace/workspace.json`
    (214 behavior blocks / 198 `event: click`), so it grows with the YAML
    instead of needing a hand-written check per widget. For each such widget
    that is present, enabled and on-screen, a trusted click must move the DOM.

    This can never be a headless gate — `widget_tree.rs` is a projection of
    the same bundle and cannot observe wiring.
    """
    ids, templated = declared_clickable_ids()
    scope = ctx.opts.get("sweep_scope")
    if scope == "all":
        scopes, label = None, "ALL prefixes (triage run — expect untriaged DEADs)"
    elif scope:
        scopes, label = (scope,), f"scope {scope!r}"
    else:
        scopes, label = SWEEP_DEFAULT_SCOPES, \
            f"triaged prefixes {list(SWEEP_DEFAULT_SCOPES)}"
    if scopes:
        ids = [i for i in ids if i.startswith(scopes)]
    ctx.note(f"{len(ids)} of the declared-clickable widget ids match {label}; "
             f"{len(templated)} more are templated (NOT sweepable — the id is "
             f"resolved per instance at render time)")

    # Which of them the default scene actually renders. Read once, from a
    # throwaway instance, so the per-widget runs below stay pristine.
    present = [w for w in ids if w not in SWEEP_SKIP and ctx.p.exists(w)]
    ctx.note(f"{len(present)} of them are present in the default scene "
             f"({len(ids) - len(present)} live in panels this scene does not open, "
             f"or are skipped by SWEEP_SKIP)")

    live, dead, skipped, wedged = [], [], [], []
    for wid in present:
        # ONE PRISTINE APP PER WIDGET. Serial clicking in a shared instance
        # accumulates state; a verdict reached that way names the wrong widget.
        p = ctx.new_probe()
        try:
            if p.disabled(wid):
                skipped.append((wid, "disabled (correctly inert)"))
                continue
            try:
                hit = p.hit_target(wid)
            except ProbeFailure as e:
                skipped.append((wid, f"unreachable: {str(e)[:60]}"))
                continue
            if hit != wid:
                skipped.append((wid, f"occluded by {hit}"))
                continue
            # `--regress dead_sweep`: unwire the ONE in-scope target IN THIS
            # widget's own probe, right before it is clicked, so the sweep must
            # report exactly this widget DEAD. The teeth assertion below names
            # it, so the red is attributable — not "some widget failed".
            if wid == DEAD_SWEEP_TARGET:
                ctx.inject("dead_sweep", probe=p)
            pre = SWEEP_PRECONDITION.get(wid, [])
            for pre_wid in pre:
                p.click(pre_wid)
            was_checked = p.checked(wid)
            p.watch_start()
            p.click(wid)
            meaningful = p.watch_meaningful(wid)
            raw = p.watch_incidental()
            p.watch_stop()
            try:
                p.heartbeat(6.0, f"the app after clicking {wid}")
            except ProbeFailure as e:
                wedged.append((wid, str(e)))
                continue
            rec = (wid, len(meaningful), raw,
                   p.describe_records(meaningful, 3)
                   + (f" [after precondition {pre}]" if pre else ""))
            if meaningful:
                live.append(rec)
            elif was_checked:
                # An already-checked radio (`align_to_selection_button` is the
                # default target) is asked to enter the state it is already in.
                # Changing nothing is CORRECT, not dead. Coverage limit, stated
                # in the recipes doc: this sweep cannot prove the wiring of a
                # control that starts active.
                skipped.append((wid, "already checked — an idempotent re-click "
                                     "has nothing to change (wiring unproven)"))
            else:
                dead.append(rec)
        finally:
            p.shutdown()

    ctx.note(f"LIVE {len(live)} | DEAD {len(dead)} | WEDGED {len(wedged)} "
             f"| skipped {len(skipped)}")
    for wid, why in skipped:
        ctx.note(f"  skip {wid}: {why}")
    for wid, n, raw, desc in live:
        ctx.note(f"  live {wid}: {n} meaningful (+{raw} decoration) [{desc}]")
    for wid, n, raw, desc in dead:
        ctx.note(f"  DEAD {wid}: 0 meaningful mutations ({raw} decoration-only) "
                 f"— declared clickable, not wired")
    for wid, why in wedged:
        ctx.note(f"  WEDGED {wid}: {why}")
    ctx.want(len(live) > 0, f"the sweep actually exercised widgets ({len(live)} live)")
    ctx.want(not dead,
             f"no declared-clickable widget is click-dead "
             f"(dead: {[w for w, _, _, _ in dead] or 'none'})")
    ctx.want(not wedged,
             f"no declared-clickable widget wedges the app on a single click "
             f"(wedged: {[w for w, _ in wedged] or 'none'})")


# Widgets the sweep must not click blind, each with its reason. Keep this list
# SHORT and justified: every entry is a hole in the gate.
SWEEP_SKIP = {
    "ap_delete": "destructive — removes an appearance row",
    "ap_new": "mutates the appearance stack, shifting every later target",
    "ap_options": "opens a menu that swallows the next click",
    "ap_rearrange": "enters a modal drag mode",
    "cp_hex": "text field, not a button",
    # A state-dependent identity operation in the stock scene: it swaps the
    # start and end arrowheads, and the stock document has None at both ends
    # with equal scales, so a correct implementation changes nothing. Unlike
    # stk_reset_profile below it cannot be un-no-op'd by clicking another
    # button — it needs a combo-box selection first, which the sweep has no
    # generic way to drive. Documented hole; a Stroke-panel scenario check
    # is the right home for it.
    "stk_swap_arrowheads": "identity op in the stock scene (both arrowheads "
                           "None, equal scales); needs a combo-box precondition",
}

# Widgets whose declared effect is an identity operation in the stock scene, and
# which the sweep can make non-trivial by clicking something else FIRST. This
# turns an untestable skip into real coverage, so prefer a precondition over a
# SWEEP_SKIP entry whenever one exists.
SWEEP_PRECONDITION = {
    # Reset-to-uniform does nothing when the profile is already uniform, so
    # flip it first; the reset must then be observable.
    "stk_reset_profile": ["stk_flip_profile"],
}

# Which id prefixes the sweep gates BY DEFAULT.
#
# Deliberately incremental. A `DEAD` verdict is not self-interpreting: it can
# mean "declared clickable and never wired" (the bug we want) or "a correct
# identity operation in the stock scene" (clicking `cp_recent_3` when the
# recent-colour list is empty). Separating those needs a human once per widget,
# after which the widget earns either a precondition (preferred), a SWEEP_SKIP
# reason, or a bug report. Only TRIAGED prefixes belong here, so the gate stays
# trustworthy; run `--sweep-scope all` to triage the rest.
#
# TRIAGED:   align_ (9), stk_ (18)
# UNTRIAGED: cp_ (21 — 16 report DEAD, mostly empty recent-colour slots and
#            already-active modes, but cp_gradient_btn / cp_none_btn /
#            cp_none_swatch look like genuine suspects), btn_, ap_,
#            distribute_, and the single-widget prefixes.
SWEEP_DEFAULT_SCOPES = ("align_", "stk_")


#  A YAML id may be a TEMPLATE (`${id_prefix}fill_swatch`, `bp_tile_{{lib}}_...`)
#  resolved per instance at render time. Those are not addressable as literal
#  selectors, so the sweep cannot target them; `declared_clickable_ids` reports
#  how many it dropped so the coverage hole stays visible instead of silent.
LITERAL_ID = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]*$")


def declared_clickable_ids() -> tuple[list[str], list[str]]:
    """Widget ids declaring `event: click`, split into (literal, templated)."""
    with open(WORKSPACE_JSON, encoding="utf-8") as f:
        bundle = json.load(f)
    found: list[str] = []

    def walk(node):
        if isinstance(node, dict):
            beh = node.get("behavior")
            wid = node.get("id")
            if isinstance(beh, list) and isinstance(wid, str):
                if any(isinstance(h, dict) and h.get("event") == "click"
                       for h in beh):
                    found.append(wid)
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    walk(bundle)
    uniq = sorted(set(found))
    literal = [i for i in uniq if LITERAL_ID.match(i)]
    templated = [i for i in uniq if not LITERAL_ID.match(i)]
    return literal, templated


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="append", default=None,
                    help="run only this check (repeatable); default = all")
    ap.add_argument("--list", action="store_true", help="list checks and exit")
    ap.add_argument("--serve-port", type=int, default=8097)
    ap.add_argument("--cdp-port", type=int, default=9333)
    ap.add_argument("--headed", action="store_true",
                    help="show the browser window (debugging)")
    ap.add_argument("--shot-dir", default=None,
                    help="write evidence screenshots here")
    ap.add_argument("--regress", choices=sorted(FAULTS), default=None,
                    help="inject a known fault; verdicts INVERT (see module doc)")
    ap.add_argument("--sweep-scope", default=None, metavar="PREFIX",
                    help="behavior_liveness: only widgets whose id starts with "
                         "PREFIX (e.g. stk_), or 'all' for every prefix (a "
                         "triage run — untriaged prefixes report DEADs that "
                         "still need a human). Default: the triaged prefixes.")
    args = ap.parse_args()

    if args.list:
        for name, fn in sorted(CHECKS.items()):
            print(f"{name:26s} {fn.about}")
        return 0

    # A fault mode owns exactly ONE check. `--regress MODE` with no `--check`
    # auto-selects that check; pairing MODE with any other `--check` is a usage
    # error (exit 2), so a non-matching combination can never masquerade as a
    # red. Without `--regress`, `--check` selects normally (default: all).
    if args.regress:
        owner = FAULTS[args.regress].check
        if args.check is None or args.check == [owner]:
            names = [owner]
        else:
            print(f"usage: --regress {args.regress} exercises only its owning "
                  f"check {owner!r}, but --check {args.check} was given. Omit "
                  f"--check to auto-select it, or pass exactly "
                  f"--check {owner}.", file=sys.stderr)
            return 2
    else:
        names = args.check or sorted(CHECKS)

    unknown = [n for n in names if n not in CHECKS]
    if unknown:
        print(f"unknown check(s): {unknown}; try --list", file=sys.stderr)
        return 2
    if args.shot_dir:
        os.makedirs(args.shot_dir, exist_ok=True)

    if args.regress:
        fault = FAULTS[args.regress]
        print(f"FAULT INJECTION {args.regress!r} -> check {fault.check!r}: it "
              f"must fail carrying the marker {fault.marker!r}.\n")

    results = []
    for name in names:
        fn = CHECKS[name]
        print(f"[{name}] {fn.about}", flush=True)
        # A fresh app instance per check: no check may inherit another's
        # document, tool, panel state or injected fault.
        def make_probe(_n=[0]):
            """A pristine app instance on its own DevTools port.

            Distinct ports so a previous instance still shutting down can never
            be attached to by mistake.
            """
            _n[0] += 1
            pr = GuiProbe(serve_port=args.serve_port,
                          cdp_port=args.cdp_port + _n[0],
                          headless=not args.headed, verbose=False)
            pr.launch()
            return pr

        probe = GuiProbe(serve_port=args.serve_port, cdp_port=args.cdp_port,
                         headless=not args.headed)
        ctx = Ctx(probe, args.shot_dir, args.regress, new_probe=make_probe,
                  opts={"sweep_scope": args.sweep_scope})
        try:
            probe.launch()
            fn(ctx)
            failure = None
        except Exception as e:
            # Broad on purpose: a wedged app surfaces as a DevTools socket
            # timeout, not a ProbeFailure, and "the app stopped answering"
            # is a check result, not a harness crash.
            failure = f"{type(e).__name__}: {e}"
        finally:
            probe.shutdown()

        if args.regress:
            marker = FAULTS[args.regress].marker
            if failure is None:
                status = "teeth_missing"
                detail = (" — the check PASSED with the fault injected, so it "
                          "is blind to the defect it claims to catch")
            elif marker in failure:
                status = "teeth_ok"
                detail = f" (failed as intended, carrying {marker!r}: {failure})"
            else:
                # A red for the wrong reason, or the harness itself broke (no
                # Chrome, dev server down, a CDP timeout, a launch failure). A
                # caught fault and a broken host MUST NOT look alike.
                status = "harness_error"
                detail = (f" — teeth UNPROVEN: failed WITHOUT the expected "
                          f"marker {marker!r} (broken host, or a red for the "
                          f"wrong reason): {failure}")
        else:
            status = "pass" if failure is None else "fail"
            detail = "" if failure is None else f": {failure}"
        print(f"  => {TAGS[status]}{detail}\n", flush=True)
        results.append((name, status))

    print("=" * 68)
    for name, status in results:
        print(f"  {TAGS[status]:14s} {name}")
    good = sum(1 for _, s in results if s in ("pass", "teeth_ok"))
    print(f"{good}/{len(results)} ok")

    # Exit codes: 3 (harness error / teeth unproven) dominates 1 (a real
    # failure, or a gate blind to its own fault); 0 only when every selected
    # check is good. A caught fault (0) is never confused with a broken host (3).
    statuses = {s for _, s in results}
    if "harness_error" in statuses:
        return 3
    if "fail" in statuses or "teeth_missing" in statuses:
        return 1
    return 0


TAGS = {"pass": "PASS", "fail": "FAIL", "teeth_ok": "TEETH ok",
        "teeth_missing": "TEETH MISSING", "harness_error": "HARNESS ERROR"}


if __name__ == "__main__":
    sys.exit(main())
