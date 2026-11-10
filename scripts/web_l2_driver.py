#!/usr/bin/env python3
"""The web app's level-2 driver (docs/TESTING.md section 6).

It drives every input script in test_fixtures/input_scripts/ through the LIVE
web app in a headless browser. Pointer and key steps go in as trusted input
(Playwright's mouse and keyboard, which use CDP Input.dispatch*). Panel steps
act on the DOM element whose id is the widget id, inside the element whose id
is the panel content id. Menu steps open the menubar's menus by their titles.
The read-back is `window.__jasTest.read()`, which is `document_to_test_json`.

The PLAN is the Mac driver's (scripts/mac_l2_plan.py: the act list, its
refusals, the document-to-screen mapping and the open's artboard), so the two
channels refuse the same shapes for the same reasons. This file adds only what
a browser needs. Two choices differ from the Mac driver, both on purpose:
  * a select's commit chooses its option by VALUE (the DOM <option> value),
    never by its label;
  * each script runs in a FRESH browser context, so no stored session leaks
    from one script into the next.

The app installs `window.__jasTest` only when the page's query carries
`jas_test=1` (jas_dioxus/src/workspace/test_hook.rs). The run checks both
directions before any script: the hook is ABSENT without the flag and PRESENT
with it.

The first line of its output, and of --receipt FILE, is the board's receipt:
  UI-NIGHTLY v1 suite=web.live verdict=GREEN|RED(...) items=P/N panels=- head=<sha8> scope=full date=<iso>

Two more checks guard against a read-back that cannot move. jas, 2026-11-06:
on the Mac, a route that dropped doc.op silently read every document back as
its setup.
  * For --witness (default align.left), the run REFUSES unless that script's
    read-back is byte-equal to its .expected.json, which is the Rust engine's
    read-back, AND differs from the read taken right after the open.
  * Every PASS whose read equals its own opening read is counted and printed
    as `unmoved=K`. That is a vacuity tell, never a failure: a script may
    expect no change.

Usage:
  python3 scripts/web_l2_driver.py --self-test         (no browser; CI)
  python3 scripts/web_l2_driver.py --url URL [--receipt FILE] [--head SHA]
                                   [--only NAME ...] [--artifacts DIR] [--dock]
"""
import argparse
import datetime
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mac_l2_plan as _plan  # noqa: E402

REPO = _plan.REPO
SCRIPTS = os.path.join(REPO, "test_fixtures", "input_scripts")
SVGS = os.path.join(REPO, "test_fixtures", "svg")
SUITE = "web.live"
WITNESS = "align.left"
VIEWPORT = {"width": 1400, "height": 900}
HOOK_TIMEOUT_MS = 30000
# The key corpus's named tokens (test_fixtures/keys/) that Playwright names the same.
KEYNAME = {k: k for k in ("Delete", "Backspace", "Escape", "Enter", "Tab",
                          "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown")}
MODKEY = {"shift": "Shift", "alt": "Alt", "ctrl": "Control"}


def script_paths(only=None):
    paths = sorted(p for p in glob.glob(os.path.join(SCRIPTS, "*.json"))
                   if not p.endswith(".expected.json"))
    if only:
        names = {os.path.basename(p)[:-5]: p for p in paths}
        missing = [n for n in only if n not in names]
        if missing:
            raise SystemExit(f"--only names no script: {missing}")
        paths = [names[n] for n in only]
    return paths


def menu_ids_by_path(menubar):
    """Title path -> menu id, the inverse of the planner's menu_paths, so a
    menu act (a title path) clicks the DOM element whose id is the menu id."""
    return {tuple(p): mid for mid, p in _plan.menu_paths(menubar).items() if p}


def key_chord(key, mods):
    """A script key step -> Playwright's chord. `ctrl` is Control: the web app
    takes Ctrl, not Cmd. Raises Refused for a key this driver has no name for."""
    name = KEYNAME.get(key)
    if name is None:
        if len(key) == 1 and key.isalnum():
            name = key.lower() if not mods else key.upper()
        else:
            raise _plan.Refused(f"key {key!r} has no name in this driver")
    return "+".join([MODKEY[m] for m in mods] + [name])


def receipt(results, head, date, not_run=None):
    """The receipt line, in the ONE grammar every channel writes: mac_l2_plan.receipt_line with suite=web.live.
    `results` is [(name, status, detail)]; items count passes over the scripts RUN, and scope is full only
    when every corpus script ran."""
    corpus = [os.path.basename(p) for p in script_paths()]
    outcomes = {n + ".json": s for n, s, _ in results}
    return _plan.receipt_line(outcomes, corpus, (head or "unknown")[:8], date, not_run=not_run, suite=SUITE)


# ---------------------------------------------------------------------------
# The browser half (imports Playwright only when it runs).

class Browser:
    def __init__(self, url):
        from playwright.sync_api import sync_playwright
        self.url = url
        self._pw = sync_playwright().start()
        self._b = self._pw.chromium.launch(headless=True)

    def close(self):
        self._b.close()
        self._pw.stop()

    def page(self, with_flag=True):
        ctx = self._b.new_context(viewport=VIEWPORT, device_scale_factor=1)
        page = ctx.new_page()
        sep = "&" if "?" in self.url else "?"
        page.goto(self.url + (sep + "jas_test=1" if with_flag else ""))
        return ctx, page

    def hook_present(self, with_flag):
        """True if window.__jasTest exists once the app has mounted. The app is
        mounted when its menubar has rendered."""
        ctx, page = self.page(with_flag)
        try:
            page.wait_for_selector(".jas-menu-title", timeout=HOOK_TIMEOUT_MS)
            return page.evaluate("typeof window.__jasTest !== 'undefined'")
        finally:
            ctx.close()


def run_script(br, path, menubar, menu_ids, artifacts=None):
    """-> (status, detail, moved). status is PASS, FAIL or REFUSED."""
    with open(path, encoding="utf-8") as f:
        script = json.load(f)
    name = os.path.basename(path)[:-5]
    try:
        acts = _plan.plan(script, menubar, _plan.load_spec(script))
    except _plan.Refused as e:
        return "REFUSED", str(e), None
    with open(os.path.join(SCRIPTS, script["expected_json"]), encoding="utf-8") as f:
        want = f.read().strip()
    ctx, page = br.page(True)
    try:
        # The wasm app mounts after the page loads; the hook exists only then.
        page.wait_for_function("() => window.__jasTest !== undefined", timeout=HOOK_TIMEOUT_MS)
    except Exception:
        ctx.close()
        return "REFUSED", f"window.__jasTest did not appear within {HOOK_TIMEOUT_MS} ms", None
    held = set()
    st = {"origin": None, "view": None, "opened": None}

    def sync_mods(mods):
        for m in sorted(held - set(mods)):
            page.keyboard.up(MODKEY[m]); held.discard(m)
        for m in sorted(set(mods) - held):
            page.keyboard.down(MODKEY[m]); held.add(m)

    def release_mods():
        sync_mods(())

    def menu_click(path):
        """Open the top menu titled path[0], then click the item whose DOM id
        is the menubar.yaml id of that title path."""
        mid = menu_ids.get(tuple(path))
        if mid is None:
            raise _plan.Refused(f"menu path {list(path)} has no id")
        tops = page.locator(".jas-menu-title")
        exact = [i for i in range(tops.count()) if tops.nth(i).inner_text().strip() == path[0]]
        if len(exact) != 1:
            raise _plan.Refused(f"{len(exact)} menubar titles read {path[0]!r}")
        tops.nth(exact[0]).dispatch_event("mousedown")
        item = page.locator(f"#{mid}")
        item.wait_for(timeout=5000)
        item.click()
        page.wait_for_timeout(200)

    def canvas_origin():
        loc = page.locator("#jas-canvas")
        if loc.count() != 1:
            raise _plan.Refused(f"{loc.count()} elements carry id jas-canvas; the run needs exactly one")
        box = loc.bounding_box()
        return (box["x"], box["y"])

    def do_act(act):
        k = act[0]
        if k == "open":
            with open(os.path.join(SVGS, act[1]), encoding="utf-8") as f:
                svg = f.read()
            if not page.evaluate("([t, n]) => window.__jasTest.open(t, n)", [svg, act[1]]):
                raise _plan.Refused("window.__jasTest.open returned false")
            page.wait_for_selector("#jas-canvas", timeout=HOOK_TIMEOUT_MS)
            page.evaluate("() => window.__jasTest.view(1, 0, 0)")
            page.wait_for_timeout(300)
            view = _plan.parse_view_report(page.evaluate("() => window.__jasTest.view()"))
            if view != (1.0, 0.0, 0.0):
                raise _plan.Refused(f"the app reports view {view} after view(1, 0, 0)")
            st["view"], st["origin"] = view, canvas_origin()
            st["opened"] = page.evaluate("() => window.__jasTest.read()").strip()
        elif k == "tool":
            got = page.evaluate("(id) => window.__jasTest.tool(id)", act[1])
            if got != act[1]:
                raise _plan.Refused(f"tool {act[1]!r} selected {got!r}")
        elif k == "pointer":
            _, kind, x, y, dragging, mods = act
            sx, sy = _plan.doc_to_screen(st["view"], st["origin"], x, y)
            sync_mods(mods)
            if kind == "press":
                page.mouse.move(sx, sy); page.mouse.down()
            elif kind == "move":
                page.mouse.move(sx, sy)
            else:
                page.mouse.move(sx, sy); page.mouse.up()
        elif k == "key":
            _, key, mods = act
            release_mods()
            page.keyboard.press(key_chord(key, mods))
            page.wait_for_timeout(100)
        elif k == "panel":
            release_mods()
            _, pid, tab, wpath, widget, event, value, _label = act
            if page.locator(f"#{pid}").count() == 0:
                # Show it as a person does: its dock tab, or, for a panel in no
                # dock group, its Window menu item.
                tabs = page.locator(f"#{tab}")
                if tabs.count() > 1:
                    raise _plan.Refused(f"{tabs.count()} dock tabs carry id {tab!r}")
                if tabs.count() == 1:
                    tabs.click()
                elif wpath:
                    menu_click(wpath)
                else:
                    raise _plan.Refused(f"panel {pid!r} has no dock tab and no unique Window item")
                page.wait_for_timeout(300)
            panels = page.locator(f"#{pid}")
            if panels.count() != 1:
                raise _plan.Refused(f"{panels.count()} panels carry id {pid!r}")
            ws = panels.locator(f"#{widget}")
            if ws.count() != 1:
                raise _plan.Refused(f"{ws.count()} widgets carry id {widget!r} in {pid!r}")
            w = ws.first
            if w.is_disabled() or w.get_attribute("aria-disabled") == "true":
                raise _plan.Refused(f"widget {widget!r} is disabled")
            tag = w.evaluate("e => e.tagName.toLowerCase()")
            if event == "click":
                w.click()
            elif tag == "select" or w.locator("select").count() == 1:
                sel = w if tag == "select" else w.locator("select")
                sel.select_option(value=str(value))
            else:
                fields = w if tag in ("input", "textarea") else w.locator("input, textarea")
                if fields.count() != 1:
                    raise _plan.Refused(f"widget {widget!r} holds {fields.count()} text fields; a commit needs one")
                fields.first.fill(str(value))
                fields.first.press("Enter")
            page.wait_for_timeout(200)
        elif k == "menu":
            release_mods()
            menu_click(act[1])
        elif k == "read":
            release_mods()
            page.wait_for_timeout(150)
            return _plan.read_back(page.evaluate("() => window.__jasTest.read()").strip(), want)
        return None

    try:
        got = None
        for act in acts:
            r = do_act(act)
            if r is not None:
                got = r
        opened = _plan.set_aside_the_opens_artboard(st["opened"], want) if st["opened"] else None
        moved = got != opened
        if got == want:
            return "PASS", "", moved
        if artifacts:
            os.makedirs(artifacts, exist_ok=True)
            page.screenshot(path=os.path.join(artifacts, name + ".png"))
            with open(os.path.join(artifacts, name + ".got.json"), "w", encoding="utf-8", newline="\n") as f:
                f.write(got or "")
        return "FAIL", "read-back differs from the expected", moved
    except _plan.Refused as e:
        return "REFUSED", str(e), None
    except Exception as e:  # a driver crash is this script's result, never the run's end
        return "REFUSED", f"driver error: {type(e).__name__}: {str(e).splitlines()[0] if str(e) else ''}", None
    finally:
        try:
            release_mods()
        except Exception:
            pass
        ctx.close()


# ---------------------------------------------------------------------------
# --dock: R1-2's live arm (seat design brief 2026-11-10, option A-prime).
# The edge-dock LAW is pinned by the shared corpus in
# test_fixtures/workspace_operations/. This check witnesses what that corpus
# cannot see: a dock tab dragged in the browser reaches that law, AND the
# snapped dock is drawn. It runs OUTSIDE the input-script corpus on purpose:
# every channel replays that corpus, and a dock script would break the
# engine replays and move every channel's item count.
# Each case passes only if BOTH halves hold: the engine's layout puts the
# panel in the dock anchored at the edge, and the DOM node for that edge's
# dock holds the panel's tab. Either half alone could agree with itself.
DOCK_EDGES = ("left", "bottom")
# (panel, the edge it must end anchored at or None to float, a band to pass
# through first or None). All three start in the right dock. The third is
# WORKSPACE.md's "a floating dock DROPPED within SNAP_DISTANCE of a window
# edge snaps": a drag that crosses the left band and drops mid-viewport must
# float, not snap.
DOCK_CASES = (("stroke", "left", None), ("layers", "bottom", None), ("align", None, "left"))
WORKSPACE_RS = os.path.join(REPO, "jas_dioxus", "src", "workspace", "workspace.rs")


def snap_distance():
    """SNAP_DISTANCE as the app declares it, read from the Rust source."""
    import re
    with open(WORKSPACE_RS, encoding="utf-8") as f:
        hits = re.findall(r"^pub const SNAP_DISTANCE: f64 = ([0-9.]+);", f.read(), re.M)
    if len(hits) != 1:
        raise _plan.Refused(f"workspace.rs declares SNAP_DISTANCE {len(hits)} times; the dock check needs exactly one")
    return float(hits[0])


APP_RS = os.path.join(REPO, "jas_dioxus", "src", "workspace", "app.rs")


def snap_preview_style(text=None):
    """(width px, computed colour) of the root's snap preview, read from the
    three `let snap_<edge> = if snap_edge == ...` lines in app.rs. The preview
    is drawn exactly while the drop target is an Edge, so reading it mid-drag
    tells the drop target the dragend handler will read (R1-2h, flask's 775)."""
    import re
    if text is None:
        with open(APP_RS, encoding="utf-8") as f:
            text = f.read()
    hits = re.findall(r'let snap_(left|right|bottom) = if snap_edge == Some\(DockEdge::\w+\) '
                      r'\{ "([0-9]+)px solid (#[0-9a-fA-F]{6})" \}', text)
    if sorted(h[0] for h in hits) != ["bottom", "left", "right"] or len({h[1:] for h in hits}) != 1:
        raise _plan.Refused(f"app.rs's snap preview lets read {hits!r}; the preview probe needs three alike")
    return int(hits[0][1]), hex_to_rgb(hits[0][2])


def hex_to_rgb(h):
    return "rgb({}, {}, {})".format(int(h[1:3], 16), int(h[3:5], 16), int(h[5:7], 16))


# Which root edges draw the snap preview right now. Any element may carry it,
# so every element is read; the side names are getComputedStyle's.
PREVIEW_JS = """([w, rgb]) => {
  const out = [];
  for (const el of document.querySelectorAll('*')) {
    const cs = getComputedStyle(el);
    for (const side of ['left', 'right', 'bottom'])
      if (cs['border-' + side + '-width'] === w + 'px' && cs['border-' + side + '-style'] === 'solid'
          && cs['border-' + side + '-color'] === rgb) out.push(side);
  }
  return out;
}"""


def preview_label(sides):
    return "+".join(sorted(set(sides))) or "none"


# R1-2h positive control (flask's 779). A passing stroke->left read up=none,
# so a single read before the release cannot tell "never drawn" from "drawn
# late" or "drawn only by the release's own dragover". This instrument is
# installed before the press and logs, by phase, every change in which root
# edges draw the preview (a MutationObserver on style attributes), and counts
# the dragover events the window saw. In the release phase it also logs the
# release's own first dragover, its drop and its dragend into the same
# sequence, so the order names the event that drew (or cleared) the preview. `ctl` plants an element carrying the
# preview's exact style and reads it back: the reader's own positive control.
INSTRUMENT_JS = """([w, rgb]) => {
  const sides = () => {
    const out = [];
    for (const el of document.querySelectorAll('*')) {
      const cs = getComputedStyle(el);
      for (const side of ['left', 'right', 'bottom'])
        if (cs['border-' + side + '-width'] === w + 'px' && cs['border-' + side + '-style'] === 'solid'
            && cs['border-' + side + '-color'] === rgb) out.push(side);
    }
    return [...new Set(out)].sort().join('+') || 'none';
  };
  const p = {phase: 'drag', over: 0, start: 0, muts: [], last: sides()};
  window.addEventListener('dragstart', () => { p.start++; }, true);
  window.addEventListener('dragover', () => {
    p.over++;
    if (p.phase === 'release' && !p.relOver) { p.relOver = true; p.muts.push([p.phase, 'over']); }
  }, true);
  for (const ev of ['drop', 'dragend'])
    window.addEventListener(ev, () => { p.muts.push([p.phase, ev]); }, true);
  new MutationObserver(() => {
    const now = sides();
    if (now !== p.last) { p.muts.push([p.phase, now]); p.last = now; }
  }).observe(document.documentElement, {subtree: true, attributes: true, attributeFilter: ['style']});
  window.__jasPreviewProbe = p;
  const el = document.createElement('div');
  el.style.cssText = 'position:absolute;left:-99px;width:9px;height:9px;border-left:' + w + 'px solid ' + rgb;
  document.body.appendChild(el);
  const ctl = getComputedStyle(el)['border-left-width'] === w + 'px'
    && getComputedStyle(el)['border-left-color'] === rgb ? 'left' : 'none';
  el.remove();
  return ctl;
}"""


def seen_label(muts):
    """The phase-tagged preview transitions, in order, repeats dropped."""
    out = []
    for ph, lab in muts:
        t = f"{ph}:{lab}"
        if not out or out[-1] != t:
            out.append(t)
    return ",".join(out) or "none"


PREVIEW_FIELDS = ("hit", "start", "via", "viaw", "up", "upw", "over", "seen", "ctl", "src")

# How long after a move the preview is read a second time (viaw, upw), before
# the release: long enough for a render a frame or two late to land.
SETTLE_MS = 150


# R1-2h press reading (flask's 781). layers->bottom saw no dragover at all, so
# the question moves to the press: what element is under the point the mouse
# goes down on, and did a dragstart follow. The point is the tab's bounding-box
# centre, which Playwright does not scroll into view, so a tab below the fold
# is pressed at a point outside the viewport.
PRESS_JS = """([id, x, y]) => {
  const tab = document.getElementById(id);
  if (x < 0 || y < 0 || x >= innerWidth || y >= innerHeight)
    return {where: 'offscreen', y: y, vh: innerHeight};
  const el = document.elementFromPoint(x, y);
  if (el === tab) return {where: 'tab'};
  if (el && tab && tab.contains(el)) return {where: 'child', tag: el.tagName};
  return {where: 'other', tag: el ? el.tagName : null, id: el && el.id ? el.id : ''};
}"""


def press_label(d):
    """One whitespace-free token for what the press point hit."""
    import re
    w = d.get("where")
    if w == "tab":
        return "tab"
    if w == "child":
        return "child:" + str(d.get("tag")).lower()
    if w == "offscreen":
        return f"offscreen:y{round(d['y'])}/vh{round(d['vh'])}"
    if w == "other":
        tag = (d.get("tag") or "null").lower()
        el_id = re.sub(r"\s+", "_", d.get("id") or "")
        return f"other:{tag}#{el_id}" if el_id else f"other:{tag}"
    raise _plan.Refused(f"the press reading {d!r} names no known place")


def preview_line(cases):
    """Every case's preview readings, PASS included: a PASS that floated with
    the preview still lit is itself a finding."""
    if not cases:
        return "DOCK PREVIEW NOT RUN"
    parts = []
    for k, e, _s, _d, *rest in cases:
        pv = rest[0] if rest else {}
        parts.append(f"{k}->{e or 'float'}[" + " ".join(f"{p}={pv[p]}" for p in PREVIEW_FIELDS if p in pv) + "]")
    return "DOCK PREVIEW " + " ".join(parts)


DRAG_STEPS = 12


def drag_to(page, x, y):
    """Move a held mouse to (x, y) in DRAG_STEPS steps, then once more to the
    same point. Chromium delivers a drag's dragover for the LAST mouse move
    only when the next input event arrives (flask's 787, then driven on this
    bundle: the dragovers stop at the second-to-last step, and the target's
    own arrives with the release). Without the extra move the app never sees
    the target mid-drag, so a preview read there measures the driver."""
    page.mouse.move(x, y, steps=DRAG_STEPS)
    page.mouse.move(x, y)


def dock_point(edge, vw, vh, band):
    """A viewport point a fifth of the way into the edge's snap band.
    Bottom is mid-width, so neither side band claims it first."""
    inset = band / 5
    if edge == "left":
        return (inset, vh / 2)
    if edge == "right":
        return (vw - inset, vh / 2)
    if edge == "bottom":
        return (vw / 2, vh - inset)
    raise _plan.Refused(f"the app snaps to left, right or bottom; {edge!r} is none of them")


def dock_edge_of(layout_text, kind):
    """The edge of the anchored dock holding panel `kind`, or None if no
    anchored dock holds it (floating or hidden). Refuses rather than guess."""
    lay = json.loads(layout_text)
    if "anchored" not in lay:
        raise _plan.Refused("the layout read carries no anchored member")
    edges = [a["edge"] for a in lay["anchored"]
             for g in a["dock"]["groups"] for p in g["panels"] if p == kind]
    if len(edges) > 1:
        raise _plan.Refused(f"panel {kind!r} is in {len(edges)} anchored places; a panel is in one")
    return edges[0] if edges else None


def floats(layout_text, kind):
    """True when a floating dock holds panel `kind`."""
    lay = json.loads(layout_text)
    return any(p == kind for f in lay.get("floating", [])
               for g in f["dock"]["groups"] for p in g["panels"])


def dock_line(cases):
    """cases: [(kind, edge, status, detail)] -> one line beside the receipt."""
    if not cases:
        return "DOCK NOT RUN"
    ok = sum(1 for c in cases if c[2] == "PASS")
    if ok == len(cases):
        return f"DOCK {ok}/{len(cases)}"
    bad = "; ".join(f"{s} {k}->{e or 'float'}: {d}" for k, e, s, d, *_ in cases if s != "PASS")
    return f"DOCK RED {ok}/{len(cases)} ({bad})"


def run_dock_case(br, kind, edge, via=None):
    """-> (status, detail, preview). preview maps "via"/"up" to the snap
    preview read just after the band pass and just before the release, and
    "src" to whether the pressed tab node is still in the DOM then. Drags `kind`'s dock tab into `edge`'s snap band,
    or, with edge None, through `via`'s band and then to the viewport's
    centre, where it must float."""
    ctx, page = br.page(True)
    pv = {}
    try:
        return run_dock_drag(page, kind, edge, via, pv) + (pv,)
    finally:
        ctx.close()


def run_dock_drag(page, kind, edge, via, pv):
    try:
        page.wait_for_function("() => window.__jasTest !== undefined", timeout=HOOK_TIMEOUT_MS)
        if not page.evaluate("() => typeof window.__jasTest.layout === 'function'"):
            return "REFUSED", "window.__jasTest has no layout()"
        before = page.evaluate("() => window.__jasTest.layout()")
        if dock_edge_of(before, kind) != "right":
            return "REFUSED", f"{kind} does not start in the right dock (reads {dock_edge_of(before, kind)!r})"
        tab_id = kind + _plan.PANEL_SUFFIX + _plan.TAB_SUFFIX
        tab = page.locator(f"#{tab_id}")
        if tab.count() != 1:
            return "REFUSED", f"{tab.count()} elements carry id {tab_id!r}"
        vw, vh = page.evaluate("() => [window.innerWidth, window.innerHeight]")
        band = snap_distance()
        px, py = dock_point(edge, vw, vh, band) if edge else (vw / 2, vh / 2)
        # The dock scrolls: a tab in its lowest group can sit below the fold
        # (flask's 784: layers at y 1087 of 900), and the mouse cannot press it there.
        tab.scroll_into_view_if_needed()
        box = tab.bounding_box()
        src = tab.element_handle()
        bx, by = box["x"] + box["width"] / 2, box["y"] + box["height"] / 2
        style = list(snap_preview_style())
        # Installed before the press, so the press's own dragstart is counted.
        pv["ctl"] = page.evaluate(INSTRUMENT_JS, style)
        pv["hit"] = press_label(page.evaluate(PRESS_JS, [tab_id, bx, by]))
        page.mouse.move(bx, by)
        page.mouse.down()
        if via:
            drag_to(page, *dock_point(via, vw, vh, band))
            pv["via"] = preview_label(page.evaluate(PREVIEW_JS, style))
            page.wait_for_timeout(SETTLE_MS)
            pv["viaw"] = preview_label(page.evaluate(PREVIEW_JS, style))
        drag_to(page, px, py)
        pv["up"] = preview_label(page.evaluate(PREVIEW_JS, style))
        page.wait_for_timeout(SETTLE_MS)
        pv["upw"] = preview_label(page.evaluate(PREVIEW_JS, style))
        # A source node replaced mid-drag fires its dragend detached, so the
        # event never bubbles to the root's ondragend (app.rs's comment).
        pv["src"] = "kept" if src.evaluate("el => el.isConnected") else "gone"
        pv["over"], pv["start"] = page.evaluate(
            "() => { const p = window.__jasPreviewProbe; p.phase = 'release'; return [p.over, p.start]; }")
        page.mouse.up()
        page.wait_for_timeout(300)
        pv["seen"] = seen_label(page.evaluate("() => window.__jasPreviewProbe.muts"))
        after = page.evaluate("() => window.__jasTest.layout()")
        if after == before:
            return "FAIL", "the layout did not change (did the drag reach ondragend?)"
        got = dock_edge_of(after, kind)
        if got != edge:
            return "FAIL", f"the engine anchors {kind} at {got!r}"
        if edge is None:
            if not floats(after, kind):
                return "FAIL", f"{kind} is in no anchored dock and no floating dock"
            in_edges = sum(page.locator(f"#jas-edge-dock-{e} #{tab_id}").count() for e in DOCK_EDGES)
            if in_edges:
                return "FAIL", f"an edge dock still draws the {kind} tab"
            return "PASS", ""
        drawn = page.locator(f"#jas-edge-dock-{edge} #{tab_id}").count()
        if drawn != 1:
            return "FAIL", f"#jas-edge-dock-{edge} holds {drawn} copies of the tab"
        return "PASS", ""
    except _plan.Refused as e:
        return "REFUSED", str(e)
    except Exception as e:
        return "REFUSED", f"driver error: {type(e).__name__}: {str(e).splitlines()[0] if str(e) else ''}"


def run(args):
    menubar = _plan.load_menubar()
    menu_ids = menu_ids_by_path(menubar)
    paths = script_paths(args.only)
    br = Browser(args.url)
    lines = []
    dock = dock_cases = None
    try:
        absent, present = br.hook_present(False), br.hook_present(True)
        lines.append(f"HOOK without-flag={'PRESENT' if absent else 'absent'} with-flag={'present' if present else 'ABSENT'}")
        not_run = None
        if absent or not present:
            results, unmoved = [], 0
            not_run = "the hook check failed: " + lines[-1]
        else:
            results, unmoved, moved_by = [], 0, {}
            for p in paths:
                name = os.path.basename(p)[:-5]
                status, detail, moved = run_script(br, p, menubar, menu_ids, args.artifacts)
                results.append((name, status, detail))
                moved_by[name] = moved
                if status == "PASS" and moved is False:
                    unmoved += 1
                lines.append(f"{status} {name}" + (f" -- {detail}" if detail else ""))
            if WITNESS in [r[0] for r in results]:
                ws = dict((n, (s, d)) for n, s, d in results)[WITNESS]
                ok = ws[0] == "PASS" and moved_by.get(WITNESS) is True
                lines.append(f"WITNESS {WITNESS} {ws[0]} moved={moved_by.get(WITNESS)}")
                if not ok:
                    results = [(n, "REFUSED" if s == "PASS" else s, d) for n, s, d in results]
                    lines.append(f"WITNESS REFUSED: {WITNESS} did not pass with a moved read-back, so no PASS in this run is counted")
        if args.dock:
            dock_cases = [(k, e) + run_dock_case(br, k, e, v) for k, e, v in DOCK_CASES] if not not_run else []
            dock = dock_line(dock_cases)
    finally:
        br.close()
    date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    first = receipt(results, args.head, date, not_run=not_run)
    body = [first, f"unmoved={unmoved} (PASSes whose read equals their opening read; a vacuity tell, not a failure)"]
    if dock is not None:
        body.append(dock + " (the --dock check: R1-2's live edge-dock arm; outside items=P/N on purpose)")
        body.append(preview_line(dock_cases) + " (the press and the snap preview the root draws mid-drag: hit = the element under the press point (tab, child:<tag>, other:<tag>#<id>, or offscreen:y<y>/vh<h>); start = dragstart events the window saw; via = after the band pass, up = just before the release, viaw/upw = the same read again after a settle wait; over = dragover events the window saw before the release; seen = each change in which edges draw it, by phase, with the release's own over/drop/dragend in order; ctl = a planted element with the preview style, read back (the reader's positive control); src = the pressed tab node still in the DOM at the release)")
    body += lines
    print("\n".join(body))
    if args.receipt:
        with open(args.receipt, "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(body) + "\n")
    if args.advisory and args.receipt:
        return 0   # the verdict rides in the receipt; only a run that wrote none fails the step (jas, #836 review)
    dock_ok = dock_cases is None or (bool(dock_cases) and all(c[2] == "PASS" for c in dock_cases))
    return 0 if " verdict=GREEN " in first and dock_ok else 1


# ---------------------------------------------------------------------------
def self_test():
    fails = []

    def check(cond, what):
        if not cond:
            fails.append(what)

    menubar = _plan.load_menubar()
    paths = script_paths()
    check(len(paths) > 0, "the corpus is not empty")
    planned = refused = 0
    for p in paths:
        with open(p, encoding="utf-8") as f:
            s = json.load(f)
        try:
            acts = _plan.plan(s, menubar, _plan.load_spec(s))
            planned += 1
            for a in acts:
                if a[0] == "open":
                    check(os.path.exists(os.path.join(SVGS, a[1])), f"{p}: setup {a[1]} exists")
                if a[0] == "key":
                    try:
                        key_chord(a[1], a[2])
                    except _plan.Refused as e:
                        fails.append(f"{p}: {e}")
            check(os.path.exists(os.path.join(SCRIPTS, s["expected_json"])), f"{p}: expected exists")
        except _plan.Refused:
            refused += 1
    check(WITNESS in [os.path.basename(p)[:-5] for p in paths], f"the witness {WITNESS} is in the corpus")
    ids = menu_ids_by_path(menubar)
    check(ids.get(tuple(_plan.menu_paths(menubar)["menu_group"])) == "menu_group", "a menu path maps back to its id")
    check(key_chord("Z", ("ctrl",)) == "Control+Z", "ctrl is Control")
    check(key_chord("Delete", ()) == "Delete", "named keys pass through")
    check(key_chord("v", ()) == "v", "a bare letter is lower case")
    try:
        key_chord("F13", ())
        fails.append("an unnamed key is refused")
    except _plan.Refused:
        pass
    # The read-back over a REAL expected that names minted ids (boolean.divide):
    # the app's read is that file with a fresh id at each token and the open's
    # artboard in front, built from the file's bytes, never typed.
    import re as _re
    minted_files = sorted(ef for ef in glob.glob(os.path.join(SCRIPTS, "*.expected.json"))
                          if '"id":"<minted>"' in open(ef, encoding="utf-8").read())
    check(len(minted_files) >= 1, "the corpus has an expected that names a minted id (boolean.divide)")
    for mf in minted_files:
        mwant = open(mf, encoding="utf-8").read().strip()
        k = [0]

        def fresh(_m):
            k[0] += 1
            return '"id":"%s"' % ("m%07d" % k[0])
        app_read = '{"artboards":[{"fill":"transparent","id":"pfj2j82z","name":"Artboard 1","x":0.0}],' \
            + _re.sub(r'"id":"<minted>"', fresh, mwant)[1:]
        check(k[0] >= 2 and app_read != mwant, f"{os.path.basename(mf)}: the synthetic read differs from the expected")
        try:
            check(_plan.read_back(app_read, mwant) == mwant, f"{os.path.basename(mf)}: fresh ids read back as the expected")
        except _plan.Refused as e:
            fails.append(f"{os.path.basename(mf)}: fresh ids refused: {e}")
    D = "2026-11-06T00:00:00Z"
    names = [os.path.basename(p)[:-5] for p in paths]
    allpass = [(n, "PASS", "") for n in names]
    check(receipt(allpass, "7f78b29c0000", D) == f"UI-NIGHTLY v1 suite=web.live verdict=GREEN items={len(names)}/{len(names)} panels=- "
          f"head=7f78b29c scope=full date={D}", "every script passing is GREEN over the full corpus, in the shared grammar")
    mixed = [(names[0], "PASS", ""), (names[1], "FAIL", ""), (names[2], "REFUSED", "")]
    check(" verdict=RED(fail=1 refused=1) items=1/3 " in receipt(mixed, "7f78b29c", D) and " scope=partial " in receipt(mixed, "7f78b29c", D),
          "a partial run is RED with its counts and scope=partial")
    check(" verdict=NOT RUN(the hook check failed] x) " in receipt([], "7f78b29c", D, not_run="the hook check failed) x")
          and f" items=0/{len(names)} " in receipt([], "7f78b29c", D, not_run="x"), "a refused run is NOT RUN over the corpus, never 0/0")
    try:
        receipt([], "7f78b29c", D)
        fails.append("an empty run with no reason is refused")
    except ValueError:
        pass
    # --dock (R1-2's live arm). The band comes from the Rust source; the point
    # must classify to its own edge under the app's rule (left, then right,
    # then bottom), checked here against a mirror of is_near_edge.
    band = snap_distance()
    check(band == 20.0, f"SNAP_DISTANCE derives from workspace.rs as 20 (read {band})")

    def near_edge(x, y, vw, vh):
        return "left" if x <= band else "right" if x >= vw - band else "bottom" if y >= vh - band else None
    for e in DOCK_EDGES:
        px, py = dock_point(e, VIEWPORT["width"], VIEWPORT["height"], band)
        check(near_edge(px, py, VIEWPORT["width"], VIEWPORT["height"]) == e, f"the {e} drop point classifies to {e}")
        check(0 < px < VIEWPORT["width"] and 0 < py < VIEWPORT["height"], f"the {e} drop point is inside the viewport")
    try:
        dock_point("top", 1400, 900, band)
        fails.append("a top drop is refused: the app has no top edge")
    except _plan.Refused:
        pass
    # R1-2h (flask's 787): Chromium holds back the dragover for a drag's LAST
    # mouse move until the next input event, so a stepped move must end with
    # one more move to the same point, or the app never sees the target mid-drag.
    class _Mouse:
        def __init__(self):
            self.calls = []

        def move(self, x, y, steps=1):
            self.calls.append((x, y, steps))

    class _Page:
        def __init__(self):
            self.mouse = _Mouse()
    fake = _Page()
    drag_to(fake, 4, 450)
    check(fake.mouse.calls == [(4, 450, DRAG_STEPS), (4, 450, 1)],
          f"drag_to steps to the point, then moves to it once more (calls {fake.mouse.calls})")
    # The layout reader, over the corpus's own layout (bytes, never typed).
    lay_path = os.path.join(REPO, "test_fixtures", "workspace_operations", "panel_detach_panel_snap_bottom.json")
    lay = open(lay_path, encoding="utf-8").read().strip()
    check(dock_edge_of(lay, "swatches") == "bottom", "swatches reads as anchored at bottom in the snap fixture")
    check(dock_edge_of(lay, "stroke") == "right", "stroke reads as anchored at right in the snap fixture")
    check(dock_edge_of(lay, "gradient") is None, "a panel in no anchored dock reads None")
    for bad, why in ((lay.replace('"anchored":', '"anchoredX":', 1), "no anchored member"),
                     (lay.replace('"panels":["color"]', '"panels":["color","swatches"]', 1), "a panel in two docks")):
        check(bad != lay, f"the {why} mutant changed the layout")
        try:
            dock_edge_of(bad, "swatches")
            fails.append(f"{why} is refused")
        except _plan.Refused:
            pass
    fl = open(os.path.join(REPO, "test_fixtures", "workspace_operations", "panel_detach_panel.json"),
              encoding="utf-8").read().strip()
    check(floats(fl, "swatches") and not floats(fl, "stroke"), "floats() reads the detach fixture: swatches floats, stroke does not")
    check(not floats(lay, "swatches"), "floats() reads a snapped panel as not floating")
    check(dock_line([("stroke", "left", "PASS", ""), ("layers", "bottom", "PASS", "")]) == "DOCK 2/2",
          "two passing dock cases read DOCK 2/2")
    check(dock_line([("stroke", "left", "PASS", ""), ("layers", "bottom", "FAIL", "x")]) == "DOCK RED 1/2 (FAIL layers->bottom: x)",
          "a failing dock case names itself")
    check(dock_line([]) == "DOCK NOT RUN", "no dock case is NOT RUN, never 0/0")
    check(len({c[0] for c in DOCK_CASES}) == len(DOCK_CASES) and {c[1] for c in DOCK_CASES} == {"left", "bottom", None},
          "the dock cases cover left, bottom and a float, with distinct panels")
    check(any(c[1] is None and c[2] in DOCK_EDGES for c in DOCK_CASES),
          "a case passes through a snap band and drops outside it (WORKSPACE.md: a DROP near an edge snaps)")
    check(dock_line([("align", None, "FAIL", "x")]) == "DOCK RED 0/1 (FAIL align->float: x)",
          "a float case names itself as ->float")
    # R1-2h: the snap preview, read mid-drag from the DOM (flask's 775).
    w, rgb = snap_preview_style()
    check(w > 0 and rgb.startswith("rgb("), f"the preview style reads from app.rs ({w}px {rgb})")
    check(hex_to_rgb("#4a90d9") == "rgb(74, 144, 217)", "hex_to_rgb writes the computed-style form")
    check(preview_label([]) == "none" and preview_label(["left", "left"]) == "left"
          and preview_label(["bottom", "left"]) == "bottom+left", "preview_label: none, dedup, sorted")
    five = [("stroke", "left", "PASS", "", {"up": "left", "src": "kept"}),
            ("layers", "bottom", "FAIL", "x", {"up": "none", "src": "gone"}),
            ("align", None, "PASS", "", {"via": "left", "up": "left"})]
    check(dock_line(five) == "DOCK RED 2/3 (FAIL layers->bottom: x)", "dock_line reads cases that carry a preview")
    check(preview_line(five) == "DOCK PREVIEW stroke->left[up=left src=kept] layers->bottom[up=none src=gone] align->float[via=left up=left]",
          "preview_line names every case, PASS included, in the order via, up, src")
    check(preview_line([]) == "DOCK PREVIEW NOT RUN", "no case is NOT RUN")
    # R1-2h positive control (flask's 779: a PASSING snap read up=none). The
    # instrument fields ride in a fixed order after via/up, before src.
    six = [("stroke", "left", "PASS", "", {"src": "kept", "seen": "release:left", "ctl": "left", "over": 11, "up": "none"})]
    check(preview_line(six) == "DOCK PREVIEW stroke->left[up=none over=11 seen=release:left ctl=left src=kept]",
          "preview_line orders up, over, seen, ctl, src whatever the dict order")
    check(seen_label([]) == "none", "seen_label: no preview mutation at all is none")
    check(seen_label([["drag", "left"], ["release", "none"]]) == "drag:left,release:none",
          "seen_label keeps every transition, phase first, in order")
    check(seen_label([["drag", "left"], ["drag", "left"]]) == "drag:left",
          "seen_label drops a repeat of the same phase and label")
    # R1-2h press reading (flask's 781: layers->bottom saw over=0, no drag
    # session at all). hit names what the press point lands on; start counts
    # dragstart. Both lead the case, because nothing after them counts when
    # the press missed the tab.
    seven = [("layers", "bottom", "FAIL", "x", {"src": "kept", "start": 0, "hit": "offscreen:y1012/vh900", "over": 0})]
    check(preview_line(seven) == "DOCK PREVIEW layers->bottom[hit=offscreen:y1012/vh900 start=0 over=0 src=kept]",
          "preview_line leads with hit and start, then the drag fields")
    # flask's 784: layers' press point was 187 px below the viewport. The tab
    # is scrolled into view BEFORE its box is read, so the press lands on it.
    import inspect
    drag_src = inspect.getsource(run_dock_drag)
    si, bi = drag_src.find("tab.scroll_into_view_if_needed()"), drag_src.find("tab.bounding_box()")
    check(0 <= si < bi, "run_dock_drag scrolls the tab into view before it reads the tab's box")
    # flask's 784: stroke's preview drew only on the release's own dragover.
    # viaw/upw re-read the preview SETTLE_MS after the move, before the release,
    # so "drawn late" and "not drawn by a drag-phase dragover" read apart.
    eight = [("align", None, "PASS", "", {"upw": "none", "viaw": "left", "up": "none", "via": "none", "hit": "tab"})]
    check(preview_line(eight) == "DOCK PREVIEW align->float[hit=tab via=none viaw=left up=none upw=none]",
          "preview_line puts each settled read right after its immediate one")
    check(0 < SETTLE_MS <= 500, "the settle wait is a fraction of a second")
    check(press_label({"where": "tab"}) == "tab", "press_label: the tab itself")
    check(press_label({"where": "child", "tag": "SPAN"}) == "child:span", "press_label: a descendant, by tag")
    check(press_label({"where": "other", "tag": "DIV", "id": "pane-3"}) == "other:div#pane-3",
          "press_label: another element, by tag and id")
    check(press_label({"where": "other", "tag": "DIV", "id": ""}) == "other:div", "press_label: another element with no id")
    check(press_label({"where": "offscreen", "y": 1012.4, "vh": 900}) == "offscreen:y1012/vh900",
          "press_label: a press point outside the viewport names its y and the height")
    check(press_label({"where": "other", "tag": None, "id": ""}) == "other:null", "press_label: no element at the point")
    for bad in ({}, {"where": "nowhere"}):
        try:
            press_label(bad)
            check(False, f"press_label refuses {bad!r}")
        except _plan.Refused:
            pass
    check(" " not in press_label({"where": "other", "tag": "DIV", "id": "a b"}),
          "press_label keeps the token whitespace-free (the line is split on spaces)")
    try:
        snap_preview_style("let snap_left = 1;")
        check(False, "a source with no preview lets refuses")
    except _plan.Refused:
        pass
    print(f"web_l2_driver self-test: {len(paths)} scripts, {planned} planned, {refused} refused by the plan; "
          f"{len(fails)} failure(s)")
    for f in fails:
        print("  FAIL", f)
    return 1 if fails else 0


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--url")
    ap.add_argument("--receipt")
    ap.add_argument("--head")
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--artifacts")
    ap.add_argument("--dock", action="store_true",
                    help="also drag two dock tabs into the left and bottom snap bands (R1-2)")
    ap.add_argument("--advisory", action="store_true",
                    help="exit 0 once the receipt is written; the verdict rides in the receipt")
    args = ap.parse_args(argv)
    if args.self_test:
        return self_test()
    if not args.url:
        ap.error("--url is required unless --self-test")
    return run(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
