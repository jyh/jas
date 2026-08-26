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
  arrowhead_reflects_scale a head's rendered size must match the panel's
                           Scale field                (JYH's half-size head)
  brush_promotes_line      applying a brush to a Line must thicken its ink
                                                    (Line→Path promotion)
  canvas_transform_balance a brushed repaint must leave the canvas transform
                           where it found it       (the receding artboard)
  button_enter_activates   a focused native button must still activate on
                           Enter — the app may not claim a key's default
                           action out from under the element that owns it
  none_indicator_visible   a no-paint swatch must LOOK like no paint — the
                           white face and the red diagonal, not a colour
                           (the unrendered-fact class)

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
  dead_brush_tile      brush_promotes_line      strip `data-dioxus-id` from
                                                every brush tile, so the click
                                                applies no brush and the Line
                                                is never promoted
  width_reset          stroke_width_invariance  commit 1pt through the panel's
                                                own production path during the
                                                unrelated edit: it injects the
                                                OBSERVABLE the escape produced,
                                                not the escape's cause — caught
                                                by the INVARIANCE assertion
  thin_stroke          stroke_width_invariance  draw the probe stroke at 1pt
                                                when the check asked for 5pt —
                                                the same check's ABSOLUTE
                                                assertion
  arrow_scale_lie      arrowhead_reflects_scale overwrite the end-scale field's
                                                DOM value to 200 while the head
                                                stays at its true 100% — the
                                                panel then claims a scale the
                                                canvas never rendered
  leaked_ctx_save      canvas_transform_balance push one un-restored save() +
                                                transform onto the live canvas
                                                context, the class the brushed
                                                early `return` used to leak
  none_indicator_flat  none_indicator_visible   strip the red diagonal from the
                                                fill swatch and keep stripping
                                                it, the way reverting the
                                                `explicit_none` plumbing renders
                                                a null colour
  enter_default_stolen button_enter_activates   prevent Enter's default from a
                                                capturing document listener,
                                                regardless of what has focus —
                                                the over-broad suppression that
                                                killed native button activation

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
        # widget — is what produced a 200-record mutation storm during
        # development (an unresponsive instance followed; that part was never
        # root-caused, and this driver has since been caught manufacturing
        # unresponsiveness of its own — see gui_probe.KEY_TEXT). The mutation
        # storm alone earns the isolation: it makes every verdict attributable.
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


def _fault_none_indicator_flat(p: GuiProbe):
    """Strip the red-diagonal no-paint indicator, and keep stripping it.

    The shape of the escape this check exists for: `explicit_none` is what tells
    `render_color_swatch` that a NULL colour means "no paint" rather than "empty
    slot", and with that plumbing reverted every no-colour swatch renders as a
    plain placeholder — no white face, no diagonal. Reverting it in the source
    left all 2386 Swift tests, the widget_tree goldens and 8/8 gui_drive checks
    green, which is why this check is here.

    A one-shot DOM edit would not survive the click's re-render, so the removal
    is re-applied by a MutationObserver: the indicator can never appear.
    """
    p.cdp.evaluate(
        "(()=>{const strip=()=>{const e=document.getElementById('cp_fill_swatch');"
        "if(!e)return;for(const c of [...e.children]){"
        "if(c.querySelector&&c.querySelector('svg'))c.remove();}};"
        "strip();const mo=new MutationObserver(strip);"
        "mo.observe(document.body,{childList:true,subtree:true});"
        "window.__jasNoneFlat=mo;return true;})()")


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


def _fault_dead_brush_tile(p: GuiProbe):
    """Sever the handler on every brush tile the promotion check might click.

    The tile ids are TEMPLATED (`bp_tile_<lib>_<slug>`), so target them by the
    `id^="bp_tile_"` prefix rather than a literal id. With the handler cut, the
    click lands on a live-looking tile that applies no brush — the Line is never
    promoted, the stroke stays thin, and `brush_promotes_line` sees no band.
    """
    p.cdp.evaluate(
        "(()=>{for(const e of document.querySelectorAll('[id^=\"bp_tile_\"]')){"
        "e.removeAttribute('data-dioxus-id');e.style.pointerEvents='auto';}"
        "return true;})()")


def _fault_dead_sweep(p: GuiProbe):
    """Unwire ONE in-default-scope widget the liveness sweep will click.

    The sweep clicks each widget in its own pristine probe; this must run in
    THAT probe (the sweep passes it explicitly), so the widget the sweep is
    about to click is the one that goes dead — and the sweep reports it DEAD.
    """
    _strip_dioxus_id(p, [DEAD_SWEEP_TARGET])


def _fault_width_reset(p: GuiProbe):
    """Reproduce the 5pt → 1pt reset as a side effect of an unrelated edit.

    We cannot make a healthy build reset the width by itself, so we inject the
    OBSERVABLE the escape produced — the rendered stroke is 1pt after an edit
    that had nothing to do with the weight — by committing 1pt through the
    panel's own production path at that exact moment. The check must then go
    red at its INVARIANCE assertion, the one that names the defect class.

    This is the mode that gives that assertion teeth: `thin_stroke` trips the
    check's ABSOLUTE assertion (a 5pt stroke measures thick) before the
    unrelated edit is ever made, so the two are complementary, not redundant.

    HISTORY (2026-07-25): this fault used to carry the marker "the main thread
    is wedged", because the injected commit really did stop the app answering.
    That wedge was the DRIVER's: `set_field`'s Enter was dispatched without its
    control-character text, and Chrome then re-queued it into thousands of
    trusted keydowns (gui_probe.KEY_TEXT — reproduced on a blank page with no
    app loaded). With that fixed the app rides the injection with a flat
    heartbeat, and the fault reds where it always should have.
    """
    p.set_field("stk_weight", "1")


def _fault_thin_stroke(p: GuiProbe):
    """No browser-side mutation: `draw_probe_line` draws the stroke at 1pt when
    this mode is armed, so the 5pt-thickness assertion fails at 2.0px vs the
    4.0px floor — the proof the canvas measurement tells fat from thin, exactly
    the observation JYH made by eye. Trips the check's ABSOLUTE assertion;
    `width_reset` trips its INVARIANCE assertion."""


def _fault_arrow_scale_lie(p: GuiProbe):
    """Make the Scale field CLAIM a scale the head does not have: overwrite the
    end-arrowhead-scale field's DOM value to 200 while the drawn head stays at
    its true 100%. Reproduces JYH's class — the panel reports a scale the
    canvas never rendered (here the head is HALF what the field claims).
    Browser-side; a re-render would revert it, but the check reads the field
    immediately, before it deselects."""
    p.cdp.evaluate(
        "(()=>{const e=document.getElementById('stk_end_arrowhead_scale');"
        "if(e){e.value='200';}return !!e;})()")


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
def _fault_menu_tick_lies(p: GuiProbe):
    """Put a check glyph on the Window ▸ Layers row while the Layers panel is
    absent from the DOM. This is MENULIES itself: the menu asserting a panel is
    on screen when the dock is drawing a different tab of its group. Browser
    side and read before the click, so no re-render can launder it."""
    p.cdp.evaluate(
        "(()=>{const e=document.getElementById('menu_layers');"
        "if(!e)return false;const s=e.querySelector('span');"
        "if(s)s.textContent='\u2713 Layers';return !!s;})()")


def _fault_chrome_drop(p: GuiProbe):
    """Delete the toolbar's first tool button and the dock's Color body from
    the DOM after the workspace switch -- the exact symptom JasSwift shows when
    the nil pane layout is saved (PANESNIL). DOM-level, like menu_tick_lies:
    the symptom is planted where the check READS, so a green under this fault
    means the check reads nothing."""
    p.cdp.evaluate(
        "(()=>{for(const id of ['btn_selection','cp_content']){"
        "const e=document.getElementById(id);if(e)e.remove();}return true;})()")


FAULTS = {
    "menu_tick_lies": Fault(_fault_menu_tick_lies, "menu_tick_matches_screen",
                            "agrees with what is on screen"),
    "chrome_drop": Fault(_fault_chrome_drop, "workspace_switch_keeps_chrome",
                         "still drawn after the switch"),
    "invisible_highlight": Fault(_fault_invisible_highlight, "chain_visible",
                                 "RENDERED style moved"),
    "dead_tile": Fault(_fault_dead_tile, "tile_click_responds",
                       "moved the DOM meaningfully"),
    "dead_sweep": Fault(_fault_dead_sweep, "behavior_liveness",
                        DEAD_SWEEP_TARGET),
    "width_reset": Fault(_fault_width_reset, "stroke_width_invariance",
                         "stroke thickness is INVARIANT"),
    "thin_stroke": Fault(_fault_thin_stroke, "stroke_width_invariance",
                         "5pt stroke renders thick"),
    "arrow_scale_lie": Fault(_fault_arrow_scale_lie, "arrowhead_reflects_scale",
                             "matches the panel's Scale field"),
    "dead_brush_tile": Fault(_fault_dead_brush_tile, "brush_promotes_line",
                             "THICKER band"),
    # WEDGESTORM: owns canvas_transform_balance. Re-injects the leaked-save
    # class the render fix removed; the at-rest transform then diverges and
    # the check reds with its own marker.
    "leaked_ctx_save": Fault(lambda p: _fault_leaked_ctx_save(p),
                             "canvas_transform_balance",
                             "the canvas transform is balanced"),
    # KEYCLEAN: owns button_enter_activates. Re-injects the over-broad
    # Enter suppression — a root handler claiming the key's default action
    # while a <button> has focus — so the dialog's OK button goes dead and
    # the check reds with its own marker.
    "enter_default_stolen": Fault(lambda p: _fault_enter_default_stolen(p),
                                  "button_enter_activates",
                                  "ACTIVATED on Enter"),
    # COLORTIERS: owns none_indicator_visible. Removes the red diagonal and
    # keeps removing it, which is what reverting the `explicit_none` plumbing
    # produces on screen — a no-paint swatch indistinguishable from a painted
    # one.
    "none_indicator_flat": Fault(_fault_none_indicator_flat,
                                 "none_indicator_visible",
                                 "carries the red DIAGONAL"),
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
# A calligraphic band is far taller than a plain stroke, so the brush-promotion
# check scans a generous vertical strip centred on the line.
BAND_SCAN_Y0, BAND_SCAN_SPAN = LINE_Y - 90, 180


def _click_by_text(p: GuiProbe, selector: str, text: str) -> bool:
    """Trusted-click the first element matching `selector` whose textContent
    contains `text`, and return True; False when none matches.

    The top-level menu TITLES render as text with no id, so a menu is opened by
    its title text. (Menu ITEMS do carry their spec id since MENUADDRESSED, so
    prefer `p.click("menu_layers")` for those.) `selector` is a raw CSS selector
    (a leading `css:` handle, as elsewhere in the harness, is stripped).
    """
    if selector.startswith("css:"):
        selector = selector[4:]
    center = p.cdp.evaluate(
        f"(()=>{{const els=[...document.querySelectorAll({json.dumps(selector)})];"
        f"const e=els.find(x=>x.textContent && x.textContent.includes({json.dumps(text)}));"
        "if(!e)return null;const r=e.getBoundingClientRect();"
        "return [r.x+r.width/2, r.y+r.height/2];})()")
    if not center:
        return False
    p.click_xy(center[0], center[1])
    return True


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


def _set_end_arrow(p, shape):
    """Pick the END arrowhead shape the way its onchange fires. The <select>'s
    change routes production set_stroke_field + apply, so a drawn line inherits
    the shape from the new-element default."""
    p.cdp.evaluate(
        "(()=>{const e=document.getElementById('stk_end_arrowhead');"
        f"e.value='{shape}';"
        "e.dispatchEvent(new Event('change',{bubbles:true}));return e.value;})()")
    time.sleep(0.4)


def _head_height(p):
    """Vertical ink extent of the END head, scanned a few px back from the tip
    at (LINE_X1, LINE_Y). The stroke body is trimmed by the arrow setback so
    these scanlines see only the head; the longest contiguous run rises toward
    the head's base, so its max over the sweep IS the head's rendered size."""
    best = 0.0
    for xoff in (7, 10, 13, 16, 19):
        span = p.ink_span(LINE_X1 - xoff, LINE_Y - 22, 44)
        if span["longest"] > best:
            best = span["longest"]
    return best


@check("arrowhead_reflects_scale",
       "an arrowhead's rendered size matches the scale the panel field shows")
def arrowhead_reflects_scale(ctx: Ctx):
    """JYH's bug (2026-07-25): a drawn line's arrowhead rendered a size the
    Stroke-panel Scale field never showed, and committing the shown value then
    JUMPED it. The Scale field did not reflect the selection (unlike
    weight/cap/join), so it could claim a scale the canvas did not have.

    Asserts a RENDERED property (head ink extent) against the panel's OWN
    reported scale: a simple_arrow head is 4 x weight x scale% / 100 px. The
    two agree only when the display tells the truth about the selection — so
    this catches both a stale display and a mis-scaled draw, whichever caused
    the divergence, exactly as JYH saw it by eye."""
    p = ctx.p
    weight = 5.0
    got = p.set_field("stk_weight", "5")
    ctx.want(got.strip().startswith("5"), f"weight committed {got!r}")
    deselect(p)
    _set_end_arrow(p, "simple_arrow")           # new-element default end shape
    p.click("btn_line")
    ctx.want(p.checked("btn_line"), "line tool active")
    p.drag([(LINE_X0, LINE_Y), (LINE_X1, LINE_Y), (LINE_X1, LINE_Y)])
    select_all(p)                               # the bug shows while selected
    ctx.inject("arrow_scale_lie")
    raw = (p.value("stk_end_arrowhead_scale") or "").strip()
    scale = float(raw) if raw else 0.0
    ctx.note(f"panel end-scale field reads {raw!r} -> {scale}%")
    deselect(p)                                 # keep handles out of the pixels
    h = _head_height(p)
    expected = round(4.0 * weight * scale / 100.0, 1)
    ctx.note(f"rendered head {h}px; field {scale}% expects ~{expected}px")
    ctx.shot("arrow_reflects")

    ctx.want(scale > 0, f"the end-scale field read a real number ({raw!r})")
    ctx.want(h >= 4.0, f"an arrowhead actually rendered ({h}px)")
    ctx.want(abs(h - expected) <= 4.0,
             f"the rendered head (~{h}px) matches the panel's Scale field "
             f"({scale}% -> ~{expected}px); a mismatch means the panel claims a "
             f"scale the canvas never rendered — JYH's half-size head")


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


def _none_diagonal(p: GuiProbe, target: str) -> dict | None:
    """The no-paint indicator inside `target`, as {stroke, x1, y1, x2, y2} —
    None when the swatch carries no indicator at all."""
    return p.cdp.evaluate(
        "(()=>{const e=document.getElementById(%s);if(!e)return null;"
        "const l=e.querySelector('svg line');if(!l)return null;"
        "return {stroke:l.getAttribute('stroke'),x1:l.getAttribute('x1'),"
        "y1:l.getAttribute('y1'),x2:l.getAttribute('x2'),"
        "y2:l.getAttribute('y2')};})()" % json.dumps(target))


@check("none_indicator_visible",
       "a no-paint swatch must LOOK like no paint, not like a colour")
def none_indicator_visible(ctx: Ctx):
    """The unrendered-fact class: a state the app KNOWS and never draws.

    `state.fill_color == null` has to become a white face with a red diagonal
    across it. Nothing else on the gate could see that: `color_panel_content` is
    Path-B-excluded so no widget_tree golden covers this widget, and until this
    check existed reverting the whole `explicit_none` plumbing left every unit
    test, every golden and 8/8 gui_drive checks GREEN (COLORTIERS).

    The fill is painted BLACK first, deliberately: the launch default is already
    white, so "no paint" and "unchanged" would otherwise look identical, and a
    check that cannot fail on a no-op is not a check.
    """
    p = ctx.p
    swatch = "cp_fill_swatch"
    ctx.want(p.exists(swatch), f"{swatch} is present in the live DOM")

    # Paint it black, so the no-paint face has somewhere to move FROM.
    p.click("cp_black_swatch")
    painted = p.attr(swatch, "style")
    ctx.note(f"painted style: ...{painted[-70:]}")
    ctx.want("rgb(0, 0, 0)" in painted or "#000000" in painted,
             "the swatch starts on a real colour (black)")
    ctx.want(_none_diagonal(p, swatch) is None,
             "a PAINTED swatch carries no indicator")
    painted_px = p.region_stats(swatch)
    ctx.shot("none_indicator_painted", swatch)

    ctx.inject("none_indicator_flat")

    p.click("cp_none_swatch")
    none_style = p.attr(swatch, "style")
    diag = _none_diagonal(p, swatch)
    none_px = p.region_stats(swatch)
    ctx.note(f"no-paint style: ...{none_style[-70:]}")
    ctx.note(f"indicator: {diag}")
    ctx.shot("none_indicator_none", swatch)

    ctx.want(diag is not None and diag.get("stroke") == "red",
             "the no-paint swatch carries the red DIAGONAL indicator; without "
             "it a None fill is indistinguishable from a painted one")
    ctx.want((diag["x1"], diag["y1"], diag["x2"], diag["y2"])
             == ("0", "100", "100", "0"),
             f"the diagonal runs corner to corner, bottom-left to top-right "
             f"(got {diag['x1']},{diag['y1']} -> {diag['x2']},{diag['y2']})")
    ctx.want("#fff" in none_style or "rgb(255, 255, 255)" in none_style,
             f"the no-paint FACE is white so the diagonal reads against it "
             f"(style tail: ...{none_style[-40:]})")
    dist = p.stats_distance(painted_px, none_px)
    ctx.want(dist >= 10.0,
             f"and the pixels actually moved: mean distance {dist} from the "
             f"painted state (>=10 required)")


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


@check("menu_tick_matches_screen",
       "a Window-menu tick means the panel is on screen, and ONE click reaches it")
def menu_tick_matches_screen(ctx: Ctx):
    """MENULIES (JYH's board, 2026-07-29): the Window menu ticked six panels at
    startup that the dock was not drawing. The dock renders ONE panel per group
    and the stock layout stacks panels in tabbed groups, so Layers was a group
    MEMBER sitting behind Artboards — and the tick was computed from membership.
    Worse, the toggle routed on the same predicate, so clicking the ticked row
    ran the CLOSE branch: the artist asked to see Layers and it silently left
    the workspace. A second click summoned it back, visible this time.

    Two properties, because either alone can be satisfied by a lie: the tick
    AGREES with the DOM, and one click flips both together.
    """
    p = ctx.p
    LAYERS_ROOT = "lp_root"   # the Layers panel's root; verified live
    COLOR_BODY = "cp_content"  # the Color panel's body; verified live

    def open_window_menu():
        _click_by_text(p, "css:.jas-menu-title", "Window")
        time.sleep(0.3)

    def ticked(row: str) -> bool:
        return "\u2713" in (p.cdp.evaluate(
            f"(document.getElementById({json.dumps(row)})||{{}}).textContent") or "")

    open_window_menu()
    ctx.want(p.exists("menu_layers"), "the Window menu lists a Layers row")
    ctx.inject("menu_tick_lies")

    # A background tab: a member of a group, drawn nowhere.
    layers_ticked, layers_drawn = ticked("menu_layers"), p.exists(LAYERS_ROOT)
    ctx.note(f"Layers: tick={layers_ticked} drawn={layers_drawn}")
    ctx.want(layers_ticked == layers_drawn,
             f"the Layers tick ({layers_ticked}) agrees with what is on screen "
             f"({layers_drawn}); a tick on an undrawn panel is the menu lying "
             f"about a tab it is not showing")

    # A front tab, for contrast — otherwise a menu that ticks NOTHING passes.
    color_ticked, color_drawn = ticked("menu_color"), p.exists(COLOR_BODY)
    ctx.note(f"Color: tick={color_ticked} drawn={color_drawn}")
    ctx.want(color_ticked == color_drawn,
             f"the Color tick ({color_ticked}) agrees with what is on screen "
             f"({color_drawn})")
    ctx.want(color_ticked and not layers_ticked,
             "the stock layout ticks its front tab (Color) and not its "
             "background tab (Layers) — if both read alike this check is blind")

    # ONE click must reach the panel. This is what the shipped build failed:
    # the first click deleted Layers instead of raising it.
    p.click("menu_layers")
    time.sleep(0.4)
    reached = p.exists(LAYERS_ROOT)
    ctx.shot("after_one_click_on_layers")
    ctx.note(f"after one click: Layers drawn={reached}")
    ctx.want(reached,
             "ONE click on Window ▸ Layers puts the Layers panel on screen; "
             "if it takes two, the first click ran the close branch on a panel "
             "the artist could not see")

    open_window_menu()
    ctx.want(ticked("menu_layers"),
             "and the tick followed the panel onto the screen")


@check("workspace_switch_keeps_chrome",
       "switching to the Default workspace keeps the toolbar and dock drawn")
def workspace_switch_keeps_chrome(ctx: Ctx):
    """PANESNIL (JYH at the canvas, 2026-08-25): in JasSwift, picking the
    Default workspace dropped the toolbar and every panel, the Window menu kept
    the panels ticked, and the pane toggles went silently dead -- one nil read
    three ways. Both ports construct the Default layout with pane_layout=None
    (workspace.rs:345 / WorkspaceLayout.swift:346) and NEITHER switch path
    repairs it (app_state.rs:1617 / ContentView.swift:250). Dioxus survives
    only because the app loop re-creates a missing pane layout on every pass
    (app.rs:847) -- immune by construction, where Swift repaired per call site
    and the switch site forgot.

    This check pins the RESCUE on the port that has it: remove or reorder the
    app-loop repair and the toolbar and dock vanish exactly as Swift's did.
    The Swift twin is unwritable until that lane grows read-back
    (GUI_EYES.md section Swift); when it does, port this check first.
    """
    p = ctx.p
    TOOL = "btn_selection"   # first toolbar tool button (workspace/layout.yaml)
    DOCK = "cp_content"      # Color panel body, stock front tab; verified live

    ctx.want(p.exists(TOOL), "baseline: the toolbar is drawn before the switch")
    ctx.want(p.exists(DOCK), "baseline: the dock is drawn before the switch")

    def open_workspace_submenu():
        _click_by_text(p, "css:.jas-menu-title", "Window")
        time.sleep(0.3)
        ok = _click_by_text(p, "css:.jas-menu-item", "Workspace")
        time.sleep(0.3)
        return ok

    ctx.want(open_workspace_submenu(), "the Window menu lists a Workspace submenu")

    # EXACT match, not contains: "Reset to Default" lives in the same submenu,
    # and a contains-match on "Default" reaches the right row only by document
    # order -- correctness by luck is the class this file exists to kill.
    clicked = p.cdp.evaluate(
        "(()=>{const els=[...document.querySelectorAll('.jas-menu-item')];"
        "const e=els.find(x=>{const t=(x.textContent||'').trim();"
        "return t==='Default'||t==='\u2713 Default';});"
        "if(!e)return null;const r=e.getBoundingClientRect();"
        "return [r.x+r.width/2, r.y+r.height/2];})()")
    ctx.want(bool(clicked),
             "the Workspace submenu lists the Default layout (exact match)")
    if clicked:
        p.click_xy(clicked[0], clicked[1])
    time.sleep(0.6)
    ctx.inject("chrome_drop")

    # The switch must have HAPPENED -- a check that examines nothing returns
    # green (the vacuity class). Re-open and require the tick on Default.
    open_workspace_submenu()
    ticked = p.cdp.evaluate(
        "(()=>{const els=[...document.querySelectorAll('.jas-menu-item')];"
        "return els.some(e=>(e.textContent||'').trim()==='\u2713 Default');})()")
    ctx.note(f"Default ticked after switch: {ticked}")
    ctx.want(bool(ticked),
             "the switch actually happened: Default carries the tick")
    _click_by_text(p, "css:.jas-menu-title", "Window")  # toggle the menu shut
    time.sleep(0.3)

    ctx.shot("after_switch_to_default")
    ctx.want(p.exists(TOOL),
             "the toolbar is still drawn after the switch -- in Swift this "
             "exact step dropped it (nil pane layout, saved)")
    ctx.want(p.exists(DOCK),
             "the dock is still drawn after the switch")


@check("brush_promotes_line",
       "applying a brush to a Line thickens its ink (Line→Path promotion)")
def brush_promotes_line(ctx: Ctx):
    """LINEPROMOTE (JYH 2026-07-25): a brush applied to a selected Line PROMOTES
    it to a Path that renders the calligraphic band — the "upgrade naturally"
    convention. The only end-to-end visible proof: a plain thin line stroke
    becomes a fat band. The pre-convention behavior silently no-op'd (a Line had
    no `stroke_brush` field to write), leaving the thin stroke unchanged; this
    check would go red on that build exactly as it does under the owned fault.
    """
    p = ctx.p
    tile = 'css:[id^="bp_tile_"]'

    # Open the Brushes panel via Window ▸ Brushes (the title is text-addressed;
    # the item could now use its id, left as-is deliberately). Opened BEFORE
    # drawing so the canvas layout — and the doc→screen mapping the ink reads
    # depend on — is stable across the before/after measurements. Skip if already
    # open.
    if not p.exists(tile):
        _click_by_text(p, "css:.jas-menu-title", "Window")
        time.sleep(0.3)
        ctx.want(_click_by_text(p, "css:.jas-menu-item", "Brushes"),
                 "Window ▸ Brushes toggles the Brushes panel open")
        time.sleep(0.3)
    ctx.want(p.exists(tile),
             "a brush tile is rendered in the open Brushes panel")

    # Draw a THIN horizontal line, then switch to the Selection tool and
    # select-all so the line is really in doc.selection (the line tool's
    # just-drawn highlight is NOT a document selection) —
    # apply_brush_to_selection acts on doc.selection.
    got = p.set_field("stk_weight", "1")
    ctx.want(got.strip().startswith("1"),
             f"stroke weight committed {got!r} for input '1'")
    p.click("btn_line")
    ctx.want(p.checked("btn_line"), "line tool is the active tool")
    p.drag([(LINE_X0, LINE_Y), (LINE_X1, LINE_Y), (LINE_X1, LINE_Y)])
    p.click("btn_selection")
    select_all(p)
    # A horizontal line's bounding box is degenerate (zero height), so its
    # selection handles sit at the two ENDPOINTS (x=LINE_X0 / LINE_X1), never at
    # the mid-span SCAN_X — the thickness read there is pure stroke ink whether
    # or not the line is selected.
    before = p.ink_span(SCAN_X, BAND_SCAN_Y0, BAND_SCAN_SPAN)["longest"]
    ctx.note(f"before brush: plain line thickness = {before}px")

    # Click a wide (10 pt round) brush tile. The tiles all share the LITERAL
    # templated id `bp_tile_{{lib.id}}_{{brush.slug}}` (the container id template
    # is not expanded), so a specific brush is reached by INDEX, not id. Index 5
    # is the 10 pt round calligraphic. In regress mode the tile handler is
    # severed here so the brush never applies.
    def _click_nth(sel, n):
        c = p.cdp.evaluate(
            f"(()=>{{const els=document.querySelectorAll({json.dumps(sel)});"
            f"const e=els[{n}];if(!e)return null;"
            "e.scrollIntoView({block:'center',inline:'center'});"
            "const r=e.getBoundingClientRect();"
            "return [r.x+r.width/2, r.y+r.height/2];})()")
        if not c:
            return False
        p.click_xy(c[0], c[1])
        return True
    ctx.inject("dead_brush_tile")
    ctx.want(_click_nth('[id^="bp_tile_"]', 5),
             "the 10 pt round brush tile is clickable")
    p.heartbeat(6.0, "the app after clicking the brush tile")
    after = p.ink_span(SCAN_X, BAND_SCAN_Y0, BAND_SCAN_SPAN)["longest"]
    ctx.note(f"after brush:  calligraphic band thickness = {after}px")
    ctx.shot("brush_promoted_line")

    ctx.want(after > before + 5,
             f"the brushed line renders a THICKER band ({after}px vs {before}px) "
             f"— the Line→Path promotion fired end-to-end; an unchanged thickness "
             f"means the brush apply was a silent no-op")


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
# WEDGESTORM (resolved 2026-07-25): the canvas transform must stay balanced
# ---------------------------------------------------------------------------

def _fault_leaked_ctx_save(p: GuiProbe):
    """Reintroduce the WEDGESTORM leak class: push one un-restored save()
    onto the live canvas context and apply a small transform, exactly what
    render.rs's brushed-path early `return` used to leak (the save/restore
    imbalance whose compounding produced the receding-artboard cascade).
    Subsequent repaints then run on the leaked state and the at-rest
    transform diverges from its baseline."""
    p.cdp.evaluate(
        "(()=>{const c=document.getElementById('jas-canvas');"
        "if(!c)return false;const x=c.getContext('2d');"
        "x.save();x.translate(30,25);x.scale(0.9,0.9);return true;})()")


@check("canvas_transform_balance",
       "a brushed repaint leaves the canvas transform exactly where it found it")
def canvas_transform_balance(ctx: Ctx):
    """WEDGESTORM's honest pin. The bug: draw_element_body's brushed-path
    branch `return`ed between the per-element ctx.save() and the epilogue
    ctx.restore(), leaking one save per brushed frame; every subsequent
    repaint compounded the view transform on the leaked state, re-drawing
    the whole scene smaller/offset each frame (JYH's receding-artboard
    cascade, which followed mouse movement because mousemoves trigger
    repaints). Heartbeats never died — earlier "livelock" verdicts were a
    separate headless-CDP keydown artifact — so the ONLY honest observable
    is the context's at-rest transform: it must be IDENTICAL before and
    after a brushed render plus further repaints. Reads the real 2D
    context's getTransform() (the same context the wasm draws through)."""
    p = ctx.p
    xform = ("(()=>{const c=document.getElementById('jas-canvas');"
             "if(!c)return 'NOCANVAS';const t=c.getContext('2d').getTransform();"
             "return JSON.stringify([t.a,t.b,t.c,t.d,t.e,t.f]);})()")

    # Scene: a line with a brush applied (the exact leaking render), via the
    # same steps brush_promotes_line uses.
    tile = 'css:[id^="bp_tile_"]'
    if not p.exists(tile):
        _click_by_text(p, "css:.jas-menu-title", "Window")
        time.sleep(0.3)
        ctx.want(_click_by_text(p, "css:.jas-menu-item", "Brushes"),
                 "Window ▸ Brushes toggles the Brushes panel open")
        time.sleep(0.3)
    p.click("btn_line")
    p.drag([(LINE_X0, LINE_Y), (LINE_X1, LINE_Y), (LINE_X1, LINE_Y)])
    p.click("btn_selection")
    select_all(p)

    before = p.cdp.evaluate(xform)
    ctx.want(before != "NOCANVAS", "the canvas context is readable")

    # The leaking render: apply a brush to the selected line...
    p.click(tile)
    time.sleep(0.4)
    ctx.inject("leaked_ctx_save")
    # ...then force several more repaints, the way mouse movement does live.
    # Each repaint on a leaked stack compounds the transform.
    cx0, cy0, cw, chh = p.canvas_rect()
    for i in range(4):
        p._mouse("mouseMoved", cx0 + 60 + 40 * i, cy0 + 80 + 10 * i)
        time.sleep(0.15)
    time.sleep(0.3)

    after = p.cdp.evaluate(xform)
    ctx.note(f"transform before={before} after={after}")
    ctx.want(after == before,
             "the canvas transform is balanced after a brushed render + "
             "repaints (an unbalanced save/restore would compound here — "
             "the receding-artboard cascade)")


# ---------------------------------------------------------------------------
# KEYCLEAN (2026-07-25): a focused native button keeps its Enter activation
# ---------------------------------------------------------------------------

def _fault_enter_default_stolen(p: GuiProbe):
    """Re-inject the over-broad Enter suppression this check exists to forbid.

    KEYCLEAN's first cut called preventDefault for Enter/Escape from the root
    keydown handler whenever a TEXT FIELD did not hold focus — and a focused
    <button> is not a text field, so Enter's NATIVE activation died with it
    (measured: Document Setup's OK button reported defaultPrevented=true and
    fired no click, and the dialog stayed open). A capturing document-level
    keydown listener that prevents Enter regardless of what holds focus is that
    same claim at the same layer — Dioxus delegates the app's keydown from the
    document root — so the check must go red on it.
    """
    p.cdp.evaluate(
        "(()=>{document.addEventListener('keydown',e=>{"
        "if(e.key==='Enter')e.preventDefault();},true);return true;})()")


@check("button_enter_activates",
       "a focused native button still activates on Enter (its default action "
       "is left to it)")
def button_enter_activates(ctx: Ctx):
    """KEYCLEAN (2026-07-25): the app may claim a key's DEFAULT ACTION only
    where the focused element has no default action of its own.

    Enter on a focused <button> is a browser-native activation — it is how the
    keyboard clicks a dialog's OK, a dialog's close X, the pane Restore button. A
    root keydown handler that calls preventDefault for Enter on the strength of
    "no text field is focused" takes that away from every button in the app
    subtree, and the only visible symptom is the one a user reports: the dialog
    will not close from the keyboard.

    Asserts the END-TO-END user-visible fact (the dialog commits and closes),
    not the mechanism, so it catches the loss whichever layer causes it — a
    root suppression, a swallowed keypress, a handler that stops propagation.
    The `defaultPrevented` reading below is evidence, asserted after the
    behavior so a red always names the behavior first.

    Coverage note: focus is placed with `el.focus()` rather than by walking Tab
    into the modal. Tab order inside a freshly opened dialog is its own
    question (and its own check, if it earns one); what this check pins is what
    happens to Enter ONCE a native button holds focus.
    """
    p = ctx.p

    # File ▸ Document Setup — a modal with a real <button> footer. Menu titles
    # and items render as TEXT (the menu bar emits no per-item DOM id), so both
    # are text-addressed; the mnemonic markers are stripped by the renderer, so
    # "Document Set&up..." reads as "Document Setup...".
    _click_by_text(p, "css:.jas-menu-title", "File")
    time.sleep(0.3)
    ctx.want(_click_by_text(p, "css:.jas-menu-item", "Document Setup"),
             "File ▸ Document Setup is present in the File menu")
    time.sleep(0.4)
    # The dialog's own fields carry spec ids; the footer buttons do not, so the
    # dialog's OPEN/CLOSED state is read from a field and OK is found by text.
    ctx.want(p.exists("ds_bleed_top"),
             "the Document Setup dialog is open (its Bleed Top field is live)")

    focused = p.cdp.evaluate(
        "(()=>{const b=[...document.querySelectorAll('button')]"
        ".find(e=>(e.textContent||'').trim()==='OK');if(!b)return null;"
        "b.focus();const a=document.activeElement;"
        "return [a.tagName,(a.textContent||'').trim(),a.id||''];})()")
    ctx.want(focused is not None, "the dialog renders an OK <button>")
    ctx.note(f"focused element: <{focused[0]}> text={focused[1]!r} "
             f"id={focused[2]!r}")
    ctx.want(focused[0] == "BUTTON" and focused[1] == "OK",
             "the dialog's OK <button> holds DOM focus")

    # Evidence instrument: a passive bubble-phase listener, so it reads
    # defaultPrevented AFTER the app's own handler has had the event. It also
    # counts the keydowns, which pins the KEY_TEXT storm class (a textless
    # Enter re-queued thousands of trusted keydowns) at the same time.
    p.cdp.evaluate(
        "(()=>{window.__jasEnter={n:0,prevented:null,trusted:null};"
        "document.addEventListener('keydown',e=>{if(e.key!=='Enter')return;"
        "window.__jasEnter.n++;if(window.__jasEnter.prevented===null){"
        "window.__jasEnter.prevented=e.defaultPrevented;"
        "window.__jasEnter.trusted=e.isTrusted;}});return true;})()")

    ctx.inject("enter_default_stolen")
    p.key("Enter")                      # trusted, and carrying its "\r" text
    time.sleep(0.5)
    ev = p.cdp.evaluate("window.__jasEnter") or {}
    ctx.note(f"Enter: {ev.get('n')} keydown(s) trusted={ev.get('trusted')} "
             f"defaultPrevented={ev.get('prevented')}")
    still_open = p.exists("ds_bleed_top")
    ctx.note(f"dialog after Enter: {'STILL OPEN' if still_open else 'closed'}")
    ctx.shot("button_enter_activates")

    ctx.want(ev.get("n") == 1 and ev.get("trusted") is True,
             f"exactly one TRUSTED Enter reached the page "
             f"({ev.get('n')} keydown(s) seen; thousands would mean the "
             f"KEY_TEXT re-queue storm would show here as key='Unidentified' — this\n"
             f"             counter watches key=='Enter' only, so it bounds THIS key, not\n"
             f"             that class; the activation assertion is what reds on a storm)")
    ctx.want(not still_open,
             "the focused OK button ACTIVATED on Enter — the dialog committed "
             "and closed; a handler that claims Enter's default action while a "
             "<button> has focus kills native activation and the dialog stays "
             "open with no click ever firing")
    ctx.want(ev.get("prevented") is False,
             f"Enter's default action was left to the element that owns it "
             f"(defaultPrevented={ev.get('prevented')})")

    # The OTHER half of the same law, so this check also pins the suppression
    # itself rather than only its limit: on the app's OWN surface — the root
    # wrapper, where focus lands from a canvas click — nothing else owns Enter,
    # and the app does claim it. Asserted last so a red always reports the
    # user-visible loss (above) before the mechanism.
    p.focus_app()
    surface = p.cdp.evaluate(
        "(()=>{window.__jasEnter={n:0,prevented:null,trusted:null};"
        "const a=document.activeElement;return [a.tagName,a.id||''];})()")
    ctx.note(f"app surface focused: <{surface[0]}> id={surface[1]!r}")
    ctx.want(surface[1] == "jas-app-root",
             "the root keyboard wrapper holds focus (its id is the surface "
             "the app matches on)")
    p.key("Enter")
    time.sleep(0.3)
    ev2 = p.cdp.evaluate("window.__jasEnter") or {}
    ctx.note(f"Enter on the app surface: defaultPrevented={ev2.get('prevented')}")
    ctx.want(ev2.get("prevented") is True,
             "with the app's own surface focused the app DOES claim Enter's "
             "default (nothing else owns it there) — the suppression is gated, "
             "not removed")


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
