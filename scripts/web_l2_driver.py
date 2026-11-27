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
        why = undelivered(act)
        if why:
            raise _plan.Refused(why)
        k = act[0]
        if k == "open":
            # act[2], the reset workspace (row 254), holds by construction here:
            # every case runs in a new browser context, so its storage is fresh.
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
            pid, tab, wpath, widget, event, value, iterations = panel_fields(act)
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
            root, where = scoped_root(panels, iterations, pid)
            ws = root.locator(f"#{widget}")
            if ws.count() != 1:
                raise _plan.Refused(f"{ws.count()} widgets carry id {widget!r} in {where!r}")
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
# The cases, the band, the layout reader, the verdict and the DOCK line are
# mac_l2_plan's, so the web and Mac channels read a dock by one law.
DOCK_EDGES, DOCK_CASES = _plan.DOCK_EDGES, _plan.DOCK_CASES
snap_distance, dock_point, dock_line = _plan.snap_distance, _plan.dock_point, _plan.dock_line

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


# --fit: row 66's live arm. WORKSPACE.md "A Group's Tab Bar", and a dock that
# never scrolls sideways, read under BOTH scrollbar conditions: overlay bars
# (macOS, and Chromium's headless default) and classic 16-px bars (Windows and
# Linux browsers), injected before the first paint because the app measures
# its scrollbar once. Row 66 was closed once on overlay-only reads, which
# cannot see a 228-px body beside a 16-px bar.
FIT_CONDITIONS = ("overlay", "classic")
CLASSIC_BARS_JS = """(() => { const css = '*{scrollbar-width:auto !important} *::-webkit-scrollbar{width:16px !important;height:16px !important;background:#888}';
  const add = () => { const st = document.createElement('style'); st.textContent = css; (document.head || document.documentElement).appendChild(st); };
  if (document.documentElement) add(); else document.addEventListener('DOMContentLoaded', add); })()"""
# Row 193: every input/select/textarea in a dock cell, on the dock tab now
# shown, that draws past its Path B cell (the cell's overflow:hidden cuts it).
CUT_READ_JS = r"""() => { const out = [];
  for (const e of document.querySelectorAll('input,select,textarea')) {
    const r = e.getBoundingClientRect(); if (r.width === 0) continue;
    let p = e.parentElement; while (p && getComputedStyle(p).position !== 'absolute') p = p.parentElement;
    if (!p || !p.closest('[id^="dock_group_"]')) continue;
    const pr = p.getBoundingClientRect();
    if (r.right > pr.right + 0.5) out.push(`${e.tagName.toLowerCase()}#${e.id} ${r.width.toFixed(0)}/${pr.width.toFixed(0)}`);
  } return out; }"""
FIT_READ_JS = r"""() => {
  const bars = [...document.querySelectorAll('[id^="dock_group_"] > div')].filter(b => b.querySelector('[id$="_tab"]'));
  let bad = 0, n = 0;
  for (const b of bars) {
    if (b.getBoundingClientRect().width === 0) continue;
    n += 1;
    let a = b.parentElement, box = null;
    while (a) { if (getComputedStyle(a).overflowX !== 'visible') { box = a; break; } a = a.parentElement; }
    const lim = box ? box.getBoundingClientRect().left + box.clientWidth : window.innerWidth;
    const over = [...b.children].slice(-2).some(k => k.getBoundingClientRect().right > lim + 0.5);
    if (over || b.scrollWidth > b.clientWidth + 1) bad += 1;
  }
  let hscroll = 0, vbar = 0; const who = [];
  for (const e of document.querySelectorAll('*')) {
    const c = getComputedStyle(e);
    if ((c.overflowX === 'auto' || c.overflowX === 'scroll') && e.scrollWidth > e.clientWidth + 1) {
      hscroll += 1;
      if (who.length < 3) {
        // name the scroller and its widest overrunning child, so a RED names its subject
        const lim = e.getBoundingClientRect().left + e.clientWidth; let wide = null, wr = lim;
        for (const k of e.querySelectorAll('*')) { const r = k.getBoundingClientRect(); if (r.width > 0 && r.right > wr + 0.5) { wr = r.right; wide = k; } }
        const nm = el => el ? `${el.tagName.toLowerCase()}${el.id ? '#' + el.id : ''}` : '-';
        who.push(`${nm(e)}[${e.scrollWidth}/${e.clientWidth}] by ${nm(wide)}+${(wr - lim).toFixed(0)}`);
      }
    }
    if ((c.overflowY === 'auto' || c.overflowY === 'scroll') && e.querySelector('[id^="dock_group_"]')) vbar = Math.max(vbar, e.offsetWidth - e.clientWidth);
  }
  return {bars: n, bad, hscroll, vbar, who};
}"""


def fit_line(readings):
    """readings: {condition: {bars, bad, hscroll, vbar}} -> one receipt line.
    NOT RUN when a condition found no tab bar (the needle missed), or when the
    classic condition's dock shows no scrollbar width (the bars did not take,
    so it would be an overlay read wearing the classic label)."""
    if not readings:
        return "FIT NOT RUN (no condition read)"
    for c in FIT_CONDITIONS:
        r = readings.get(c)
        if r is None:
            return f"FIT NOT RUN ({c}: not read)"
        if "error" in r:
            return f"FIT NOT RUN ({c}: {r['error']})"
        if r["bars"] == 0:
            return f"FIT NOT RUN ({c}: no tab bar found, so the tab-bar law was not read)"
        if c == "classic" and r["vbar"] <= 0:
            return f"FIT NOT RUN (classic: the dock shows no scrollbar width, so the classic bars did not take)"
    ok = [c for c in FIT_CONDITIONS
          if readings[c]["bad"] == 0 and readings[c]["hscroll"] == 0 and not readings[c].get("cut")]
    if len(ok) == len(FIT_CONDITIONS):
        return f"FIT {len(ok)}/{len(FIT_CONDITIONS)}"
    bad = "; ".join(f"FAIL {c}: bad={readings[c]['bad']} hscroll={readings[c]['hscroll']}"
                    + (f" cut={len(readings[c]['cut'])}" if readings[c].get("cut") else "")
                    + (f" [{', '.join(readings[c]['who'])}]" if readings[c].get("who") else "")
                    + (f" [{', '.join(readings[c]['cut'][:4])}]" if readings[c].get("cut") else "")
                    for c in FIT_CONDITIONS if c not in ok)
    return f"FIT RED {len(ok)}/{len(FIT_CONDITIONS)} ({bad})"


def run_fit(br):
    """-> {condition: reading}. Each condition is its own browser launch: the
    classic one without Chromium's --hide-scrollbars, with 16-px bars injected
    before the app's first paint."""
    out = {}
    for c in FIT_CONDITIONS:
        b = None
        try:
            b = br._pw.chromium.launch(headless=True, **({"ignore_default_args": ["--hide-scrollbars"]} if c == "classic" else {}))
            page = b.new_context(viewport=VIEWPORT, device_scale_factor=1).new_page()
            if c == "classic":
                page.add_init_script(CLASSIC_BARS_JS)
            page.goto(br.url)
            page.wait_for_selector(".jas-menu-title", timeout=HOOK_TIMEOUT_MS)
            page.wait_for_timeout(1500)
            out[c] = page.evaluate(FIT_READ_JS)
            if c == "overlay":
                # Show every dock tab in turn: a panel's controls exist only
                # while its tab is the active one (row 193 sat on a tab the
                # default layout does not show).
                cut = []
                for t in page.evaluate("() => [...document.querySelectorAll('[id$=\"_tab\"]')].map(t => t.id)"):
                    page.locator(f"#{t}").scroll_into_view_if_needed()
                    page.locator(f"#{t}").click()
                    page.wait_for_timeout(300)
                    cut += [w for w in page.evaluate(CUT_READ_JS) if w not in cut]
                out[c]["cut"] = cut
        except Exception as e:
            out[c] = {"error": f"driver error: {type(e).__name__}: {str(e).splitlines()[0] if str(e) else ''}"}
        finally:
            if b is not None:
                b.close()
    return out


def dock_summary(cases):
    """The DOCK line for cases that carry a preview dict after the four
    fields _plan.dock_line reads (kind, edge, status, detail)."""
    return dock_line([c[:4] for c in cases])


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
        why = _plan.dock_start_refusal(before, kind)
        if why:
            return "REFUSED", why
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
        drawn = {e: page.locator(f"#{_plan.edge_dock_id(e)} #{tab_id}").count() for e in DOCK_EDGES}
        return _plan.dock_verdict(before, after, kind, edge, drawn)
    except _plan.Refused as e:
        return "REFUSED", str(e)
    except Exception as e:
        return "REFUSED", f"driver error: {type(e).__name__}: {str(e).splitlines()[0] if str(e) else ''}"


# ── --layers: the Mac harness's `layers` check (rows 256/264) on the web
# channel (row 266), by the SAME verdicts (mac_l2_plan.layers_*). The app is
# read by window.__jasTest.read() and .state(), whose reply is the Mac FIFO
# `state` verb's form; the open row menu by #lp_row_menu and each item's
# data-enabled; rows by renderer.rs's `lp_row_<path joined by _>`. Each case
# gets a fresh page, as each dock case does.
def menu_reply(items):
    """[(text, data-enabled)] read from #lp_row_menu's children -> the Mac
    FIFO `menu` reply's form. A child with no text and no data-enabled is a
    separator and is dropped."""
    menu = [{"title": t, "enabled": e == "true"} for t, e in items if t or e is not None]
    return {"open": bool(menu), "menu": menu}


def row_dom_id(path):
    return "lp_row_" + "_".join(str(i) for i in path)


def _web_state(page, name):
    return json.loads(page.evaluate("n => window.__jasTest.state(n)", name) or "null")


def _web_layers(page):
    return _plan.layers_reduce(json.loads(page.evaluate("() => window.__jasTest.read()")),
                               _web_state(page, "panel.layers.layers_panel_selection"))


def _web_row(page, path):
    loc = page.locator("#" + row_dom_id(path))
    if loc.count() != 1:
        raise _plan.Refused(f"{loc.count()} elements carry id {row_dom_id(path)!r}")
    loc.scroll_into_view_if_needed()
    return loc


HIT_JS = """el => { const b = el.getBoundingClientRect(); const x = b.x + b.width / 2, y = b.y + b.height / 2;
  const h = document.elementFromPoint(x, y);
  return `box=${Math.round(b.x)},${Math.round(b.y)},${Math.round(b.width)}x${Math.round(b.height)} vh=${innerHeight} `
    + `under=${h ? h.tagName.toLowerCase() + (h.id ? '#' + h.id : '') + (el.contains(h) ? '(inside)' : '(OTHER)') : 'none'}`; }"""


def _act(label, loc, how="click", **kw):
    """One labelled pointer act with a short timeout; a failure names the act
    and what lies under its point, so a red says which step and why."""
    try:
        getattr(loc, how)(timeout=5000, **kw)
    except Exception as e:
        try:
            where = loc.evaluate(HIT_JS)
        except Exception:
            where = "unreadable"
        raise _plan.Refused(f"{label}: {type(e).__name__} ({where})")


def _web_layers_open(page):
    page.wait_for_function("() => window.__jasTest !== undefined", timeout=HOOK_TIMEOUT_MS)
    if not page.evaluate("() => typeof window.__jasTest.state === 'function'"):
        raise _plan.Refused("window.__jasTest has no state()")
    svg = open(os.path.join(REPO, _plan.LAYERS_FIXTURE), encoding="utf-8").read()
    if not page.evaluate("([s, n]) => window.__jasTest.open(s, n)", [svg, os.path.basename(_plan.LAYERS_FIXTURE)]):
        raise _plan.Refused("window.__jasTest.open returned false")
    page.wait_for_timeout(300)
    tab = page.locator("#layers_panel_content_tab")
    if tab.count() != 1:
        raise _plan.Refused(f"{tab.count()} elements carry id 'layers_panel_content_tab'")
    tab.scroll_into_view_if_needed()
    _act("show the Layers tab", tab)
    page.wait_for_timeout(300)
    return _web_layers(page)


def _web_key(page, key):
    page.keyboard.press(key)
    page.wait_for_timeout(300)


def _web_r1(page, before):
    _act("R1 click the top layer", _web_row(page, [len(before["layers"]) - 1]))
    _act("R1 right-click the bottom layer's shape", _web_row(page, [0, 0]), button="right")
    page.wait_for_timeout(300)
    items = page.locator("#lp_row_menu > div")
    reply = menu_reply([(items.nth(i).inner_text().strip(), items.nth(i).get_attribute("data-enabled"))
                        for i in range(items.count())])
    dup = page.locator("#lp_row_menu > div[data-enabled='true']", has_text="Duplicate")
    if dup.count() == 1:
        _act("R1 choose Duplicate", dup)
    else:
        _web_key(page, "Escape")
    page.wait_for_timeout(300)
    return _plan.layers_r1_verdict(before, reply, _web_layers(page), (0, 0))


def _web_r4(page, before):
    n = len(before["layers"])
    _act("R4 click the top layer's shape", _web_row(page, [n - 1, 0]))
    _web_key(page, "Delete")
    control = _web_layers(page)
    if control["layers"][-1] != (before["layers"][-1][0], before["layers"][-1][1][1:]):
        return _plan.layers_r4_verdict(before, control, control, control)
    _web_key(page, "ControlOrMeta+z")
    _act("R4 click the top layer", _web_row(page, [n - 1]))
    for i in reversed(range(n - 1)):
        _act(f"R4 add layer {i}", _web_row(page, [i]), modifiers=["ControlOrMeta"])
    selected = _web_layers(page)
    _web_key(page, "Delete")
    return _plan.layers_r4_verdict(before, control, selected, _web_layers(page))


def _web_r5(page, before):
    _act("R5 click the top layer", _web_row(page, [len(before["layers"]) - 1]))
    clicked = _web_layers(page)
    _web_key(page, "ArrowDown")
    down = _web_layers(page)
    _web_key(page, "ArrowUp")
    return _plan.layers_r5_verdict(before, clicked, down, _web_layers(page))


def _web_r6(page, before):
    _act("R6 click the top layer", _web_row(page, [len(before["layers"]) - 1]))
    clicked = _web_layers(page)
    _web_key(page, "ControlOrMeta+a")
    return _plan.layers_r6_verdict(before, clicked, _web_layers(page))


def _web_r7(page, before):
    typed = "x"
    ren = lambda: _web_state(page, "panel.layers.renaming_element")
    names = lambda: [n for n, _ in _web_layers(page)["layers"]]
    _act("R7 double-click the top layer", _web_row(page, [len(before["layers"]) - 1]), how="dblclick")
    page.wait_for_timeout(300)
    dbl = ren()
    _web_key(page, typed)
    _web_key(page, "Escape")
    dbl_esc, dbl_names = ren(), names()
    _act("R7 click the bottom layer", _web_row(page, [0]))
    _web_key(page, "Enter")
    enter = ren()
    _web_key(page, typed)
    _web_key(page, "Enter")
    return _plan.layers_r7_verdict(before, typed, dbl, dbl_esc, dbl_names, enter, ren(), names())


WEB_LAYERS_RUN = {"R1": _web_r1, "R4": _web_r4, "R5": _web_r5, "R6": _web_r6, "R7": _web_r7}


def run_layers_case(br, case):
    ctx, page = br.page(True)
    try:
        return WEB_LAYERS_RUN[case](page, _web_layers_open(page))
    except _plan.Refused as e:
        return "REFUSED", str(e)
    except Exception as e:
        return "REFUSED", f"driver error: {type(e).__name__}: {str(e).splitlines()[0] if str(e) else ''}"
    finally:
        ctx.close()


# ── --artboard-fill (row 270): Artboard Options' Fill dropdown (`ao_fill_dropdown`,
# a `select` whose bind is a computed expression) by the person's route: the
# Artboards tab, the row's Options button, White in the dropdown, OK; then the
# document's artboard fill by __jasTest.read().
ARTBOARD_FILL_WANT = "#ffffff"


def artboard_fill_verdict(before, after, want=ARTBOARD_FILL_WANT, what="fill", widget="the Fill dropdown's pick"):
    if before == want:
        return "REFUSED", f"the artboard's {what} is already {want!r}; the pick cannot be read"
    if after == before:
        return "FAIL", f"{widget} wrote nothing (the {what} stayed {before!r})"
    if after != want:
        return "FAIL", f"the {what} reads {after!r}, want {want!r}"
    return "PASS", ""


def artboard_fill_line(verdict, cases=None):
    """The fill case's verdict first; `cases` [(name, (status, detail))] add
    the control (a typed width, a `dialog.` bind) and the Size preset. The
    fill and the preset prove nothing about their selects unless the control
    passed: the line says CONTROL FAILED instead of FAIL then."""
    st, why = verdict
    line = f"ARTBOARDFILL {st}" + (f" ({why})" if why else "")
    for name, (cst, cwhy) in cases or []:
        line += f"; {name} {cst}" + (f" ({cwhy})" if cwhy else "")
    if cases and dict(cases).get("control", ("PASS", ""))[0] != "PASS":
        line = "ARTBOARDFILL CONTROL FAILED: " + line[len("ARTBOARDFILL "):]
    return line


def _artboard_fill(page, case="fill"):
    key = {"fill": "fill", "control": "width", "preset": "width"}[case]
    ab = lambda: (json.loads(page.evaluate("() => window.__jasTest.read()")).get("artboards") or [{}])[0].get(key)
    page.wait_for_function("() => window.__jasTest !== undefined", timeout=HOOK_TIMEOUT_MS)
    svg = open(os.path.join(REPO, _plan.LAYERS_FIXTURE), encoding="utf-8").read()
    if not page.evaluate("([s, n]) => window.__jasTest.open(s, n)", [svg, "artboard_fill.svg"]):
        raise _plan.Refused("window.__jasTest.open returned false")
    page.wait_for_timeout(300)
    before = ab()
    tab = page.locator("#artboards_panel_content_tab")
    if tab.count() != 1:
        raise _plan.Refused(f"{tab.count()} elements carry id 'artboards_panel_content_tab'")
    tab.scroll_into_view_if_needed()
    _act("show the Artboards tab", tab)
    page.wait_for_timeout(300)
    opt = page.locator("#ap_options")
    if opt.count() < 1:
        raise _plan.Refused("no artboard row has an Options button (#ap_options)")
    _act("open Artboard Options", opt.first)
    page.wait_for_timeout(400)
    if case == "control":
        w = page.locator("#ao_width input, input#ao_width").first
        try:
            w.fill("300", timeout=5000); w.press("Enter", timeout=5000)
        except Exception as e:
            raise _plan.Refused(f"type 300 into Width: {type(e).__name__}")
        want, what, widget = 300.0, "width", "the typed Width"
    else:
        wid, val = ("ao_fill_dropdown", "white") if case == "fill" else ("ao_preset", "letter")
        dd = page.locator("#" + wid)
        if dd.count() != 1:
            raise _plan.Refused(f"{dd.count()} elements carry id {wid!r}")
        try:
            dd.select_option(val, timeout=5000)
        except Exception as e:
            raise _plan.Refused(f"choose {val} in {wid}: {type(e).__name__}")
        want, what, widget = ((ARTBOARD_FILL_WANT, "fill", "the Fill dropdown's pick") if case == "fill"
                              else (612.0, "width", "the Size preset's pick (Letter)"))
    page.wait_for_timeout(300)
    _act("press OK", page.get_by_role("button", name="OK", exact=True).last)
    page.wait_for_timeout(400)
    after = ab()
    if isinstance(want, float):
        before, after = (float(before) if before is not None else None), (float(after) if after is not None else None)
    return artboard_fill_verdict(before, after, want, what, widget)


# ── --at (row 290): a panel step scoped to one foreach iteration, live. Two
# artboards (the fixture's, then New Artboard), Options pressed INSIDE
# iteration k of `ap_list`, Fill ▸ White, OK. Iteration k's artboard must turn
# white and the other must not; k=0 is the control for k=1. A subject already
# white could not show the step at all, so it is refused, not passed.
def at_verdict(before, after, k, want=ARTBOARD_FILL_WANT):
    if not isinstance(before, list) or not isinstance(after, list) or len(before) != 2 or len(after) != 2:
        return "REFUSED", f"expected two artboards before and after, read {before!r} -> {after!r}"
    if before[k] == want:
        return "REFUSED", f"artboard {k} was already {want} before the step: the subject cannot show it"
    other = 1 - k
    if after[k] != want:
        return "FAIL", f"artboard {k} read {after[k]!r}, not {want}"
    if after[other] != before[other]:
        return "FAIL", f"artboard {other} moved too ({before[other]!r} -> {after[other]!r}): the step was not scoped"
    return "PASS", ""


def at_line(cases):
    """`AT PASS` only when iteration 1 and its control, iteration 0, both pass."""
    sts = dict((k, st) for k, st, _ in cases)
    why = "; ".join(f"k={k}: {st}" + (f" ({d})" if d else "") for k, st, d in cases)
    ok = sts.get(1) == "PASS" and sts.get(0) == "PASS"
    return ("AT PASS" if ok else "AT " + ("REFUSED" if "REFUSED" in sts.values() else "FAIL")) + f" -- {why}"


def _at_check(page, k):
    fills = lambda: [a.get("fill") for a in (json.loads(page.evaluate("() => window.__jasTest.read()")).get("artboards") or [])]
    page.wait_for_function("() => window.__jasTest !== undefined", timeout=HOOK_TIMEOUT_MS)
    svg = open(os.path.join(REPO, _plan.LAYERS_FIXTURE), encoding="utf-8").read()
    if not page.evaluate("([s, n]) => window.__jasTest.open(s, n)", [svg, "at_check.svg"]):
        raise _plan.Refused("window.__jasTest.open returned false")
    page.wait_for_timeout(300)
    tab = page.locator("#artboards_panel_content_tab")
    if tab.count() != 1:
        raise _plan.Refused(f"{tab.count()} elements carry id 'artboards_panel_content_tab'")
    tab.scroll_into_view_if_needed()
    _act("show the Artboards tab", tab)
    page.wait_for_timeout(300)
    new = page.locator("#artboards_panel_content #ap_new")
    if new.count() != 1:
        raise _plan.Refused(f"{new.count()} New Artboard buttons (#ap_new)")
    _act("press New Artboard", new)
    page.wait_for_timeout(400)
    before = fills()
    root, where = scoped_root(page.locator("#artboards_panel_content"), [("ap_list", k)], "artboards_panel_content")
    opt = root.locator("#ap_options")
    if opt.count() != 1:
        raise _plan.Refused(f"{opt.count()} Options buttons in {where!r}")
    _act(f"open Artboard Options in {where}", opt)
    page.wait_for_timeout(400)
    dd = page.locator("#ao_fill_dropdown")
    if dd.count() != 1:
        raise _plan.Refused(f"{dd.count()} elements carry id 'ao_fill_dropdown'")
    try:
        dd.select_option("white", timeout=5000)
    except Exception as e:
        raise _plan.Refused(f"choose white in ao_fill_dropdown: {type(e).__name__}")
    page.wait_for_timeout(300)
    _act("press OK", page.get_by_role("button", name="OK", exact=True).last)
    page.wait_for_timeout(400)
    return at_verdict(before, fills(), k)


def run_at_check(br, k):
    ctx, page = br.page(True)
    try:
        return _at_check(page, k)
    except _plan.Refused as e:
        return "REFUSED", str(e)
    except Exception as e:
        return "REFUSED", f"driver error: {type(e).__name__}: {str(e).splitlines()[0] if str(e) else ''}"
    finally:
        ctx.close()


def run_artboard_fill(br, case="fill"):
    ctx, page = br.page(True)
    try:
        return _artboard_fill(page, case)
    except _plan.Refused as e:
        return "REFUSED", str(e)
    except Exception as e:
        return "REFUSED", f"driver error: {type(e).__name__}: {str(e).splitlines()[0] if str(e) else ''}"
    finally:
        ctx.close()


def run(args):
    menubar = _plan.load_menubar()
    menu_ids = menu_ids_by_path(menubar)
    paths = script_paths(args.only)
    br = Browser(args.url)
    lines = []
    dock = dock_cases = fit = layers = abfill = at = None
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
            dock = dock_summary(dock_cases)
        if args.fit:
            fit = fit_line(run_fit(br)) if not not_run else "FIT NOT RUN (" + not_run + ")"
        if args.layers:
            layer_cases = [] if not_run else [(c,) + run_layers_case(br, c) for c in _plan.LAYERS_CASES]
            for c, st, d in layer_cases:
                lines.append(f"{st} layers {c}" + (f" -- {d}" if d else ""))
            layers = _plan.layers_line(layer_cases)
        if args.at:
            at = ("AT NOT RUN (" + not_run + ")" if not_run else
                  at_line([(k,) + run_at_check(br, k) for k in (1, 0)]))
        if args.artboard_fill:
            abfill = ("ARTBOARDFILL NOT RUN (" + not_run + ")" if not_run else
                      artboard_fill_line(run_artboard_fill(br, "fill"),
                                         [(c, run_artboard_fill(br, c)) for c in ("control", "preset")]))
    finally:
        br.close()
    date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    first = receipt(results, args.head, date, not_run=not_run)
    body = [first, f"unmoved={unmoved} (PASSes whose read equals their opening read; a vacuity tell, not a failure)"]
    if dock is not None:
        body.append(dock + " (the --dock check: R1-2's live edge-dock arm; outside items=P/N on purpose)")
        body.append(preview_line(dock_cases) + " (the press and the snap preview the root draws mid-drag: hit = the element under the press point (tab, child:<tag>, other:<tag>#<id>, or offscreen:y<y>/vh<h>); start = dragstart events the window saw; via = after the band pass, up = just before the release, viaw/upw = the same read again after a settle wait; over = dragover events the window saw before the release; seen = each change in which edges draw it, by phase, with the release's own over/drop/dragend in order; ctl = a planted element with the preview style, read back (the reader's positive control); src = the pressed tab node still in the DOM at the release)")
    if abfill is not None:
        body.append(abfill + " (the --artboard-fill check: Artboard Options' Fill dropdown by the person's route, row 270)")
    if at is not None:
        body.append(at + " (the --at check: Options pressed inside iteration k of ap_list, Fill > White; k=0 is k=1's control, row 290)")
    if layers is not None:
        body.append(layers + " (the --layers check: the Mac harness's `layers` cases on the web, rows 256/264/266)")
    if fit is not None:
        body.append(fit + " (the --fit check: row 66's live arm; the dock's tab bars and sideways scroll under overlay and classic 16-px scrollbars)")
    body += lines
    print("\n".join(body))
    if args.receipt:
        with open(args.receipt, "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(body) + "\n")
    if args.advisory and args.receipt:
        return 0   # the verdict rides in the receipt; only a run that wrote none fails the step (jas, #836 review)
    dock_ok = dock_cases is None or (bool(dock_cases) and all(c[2] == "PASS" for c in dock_cases))
    fit_ok = fit is None or fit == f"FIT {len(FIT_CONDITIONS)}/{len(FIT_CONDITIONS)}"
    return 0 if " verdict=GREEN " in first and dock_ok and fit_ok else 1


# ---------------------------------------------------------------------------
# The acts this channel delivers. A toolbar press, a state read and a dialog
# read (TESTING.md, row 50) have no web hook yet; they are refused by name,
# because answering a state read with the document, or skipping a press, would
# read as measured.
WEB_ACTS = {"open", "tool", "pointer", "key", "panel", "menu"}
WEB_READS = {"document"}


def panel_fields(act):
    """A planned panel act as (pid, tab, wpath, widget, event, value), read
    by its plan's shape (mac_l2_plan.plan's docstring), or Refused by name.
    The one place this channel reads that shape, so the self-test drives it
    over every planned act of the corpus: on 11-26 the plan grew a field
    (row 281's `scope`) and an unpack inline in the run raised on all 116."""
    _, pid, tab, wpath, widget, event, value, _label, _wtype, scope = act
    return pid, tab, wpath, widget, event, value, parse_scope(scope)


def parse_scope(scope):
    """A panel act's `scope` (row 281: `["<foreach id>#<k>", ...]`, outermost
    first) as [(foreach id, k)], or Refused by name for any entry that is not
    exactly one id, one `#`, and a non-negative integer."""
    out = []
    for entry in scope or []:
        name, sep, k = str(entry).partition("#")
        if not sep or not name or "#" in k or not k.isdigit():
            raise _plan.Refused(f"scope entry {entry!r} is not '<foreach id>#<k>'")
        out.append((name, int(k)))
    return out


def iteration_selector(foreach_id, k):
    """Row 290: iteration k of an identified foreach on the web. The renderer
    draws the foreach as div#<id> and each iteration as that div's direct
    child (render_repeat), so the k-th iteration is its (k+1)-th child."""
    return f"#{foreach_id} > :nth-child({k + 1})"


def scoped_root(root, iterations, where):
    """Narrow `root` (a Playwright locator) to the iteration a step's `at`
    names, one level per enclosing foreach, refusing by name a container that
    is not exactly one or an iteration that is not drawn."""
    for name, k in iterations:
        if root.locator(f"#{name}").count() != 1:
            raise _plan.Refused(f"{root.locator(f'#{name}').count()} foreach containers carry id {name!r} in {where!r}")
        it = root.locator(iteration_selector(name, k))
        if it.count() != 1:
            raise _plan.Refused(f"iteration {k} of {name!r} in {where!r} is not drawn")
        root, where = it, f"{name}#{k}"
    return root, where


def undelivered(act):
    """None if this channel delivers `act`, else the refusal naming it."""
    if act[0] in WEB_ACTS or (act[0] == "read" and act[1] in WEB_READS):
        return None
    return f"the web channel does not deliver a {' '.join(map(str, act[:2]))} act yet"


def self_test():
    fails = []

    def check(cond, what):
        if not cond:
            fails.append(what)

    # The layers check (row 266): the web's open row menu, reduced to the Mac
    # FIFO `menu` reply's form, which mac_l2_plan.layers_r1_verdict reads.
    check(menu_reply([("Options for Layer...", "false"), ("Duplicate", "true")]) ==
          {"open": True, "menu": [{"title": "Options for Layer...", "enabled": False},
                                  {"title": "Duplicate", "enabled": True}]},
          "menu_reply keeps order, titles and enabled")
    check(menu_reply([]) == {"open": False, "menu": []}, "no items read is a closed menu, never an open empty one")
    check(menu_reply([("", None)])["menu"] == [], "a separator (no text, no data-enabled) is dropped")
    check(row_dom_id([1, 0]) == "lp_row_1_0" and row_dom_id([0]) == "lp_row_0",
          "the row id is renderer.rs's lp_row_<path joined by _>")
    # --artboard-fill (row 270): Artboard Options' Fill dropdown, by the person's route.
    check(artboard_fill_verdict("transparent", "#ffffff") == ("PASS", ""), "white written: PASS")
    check(artboard_fill_verdict("transparent", "transparent") ==
          ("FAIL", "the Fill dropdown's pick wrote nothing (the fill stayed 'transparent')"), "nothing written: FAIL by name")
    check(artboard_fill_verdict("#ffffff", "#ffffff")[0] == "REFUSED", "a start already white cannot test the pick")
    check(artboard_fill_verdict("transparent", "#000000")[0] == "FAIL", "the wrong preset: FAIL")
    check(artboard_fill_line(("FAIL", "x"), [("control", ("PASS", "")), ("preset", ("FAIL", "y"))])
          == "ARTBOARDFILL FAIL (x); control PASS; preset FAIL (y)", "the line carries the control and the preset")
    check(artboard_fill_line(("FAIL", "x"), [("control", ("FAIL", "z"))]).startswith("ARTBOARDFILL CONTROL FAILED: FAIL (x)"),
          "a failed control voids the reading, by name")
    check(artboard_fill_line(("PASS", "")) == "ARTBOARDFILL PASS"
          and artboard_fill_line(("FAIL", "x")) == "ARTBOARDFILL FAIL (x)", "the line names its verdict")

    menubar = _plan.load_menubar()
    paths = script_paths()
    check(len(paths) > 0, "the corpus is not empty")
    planned = refused = panel_acts = 0
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
                if a[0] == "panel":
                    panel_acts += 1
                    try:
                        panel_fields(a)
                    except Exception as e:  # noqa: BLE001 - any raise is the defect
                        fails.append(f"{p}: the panel act does not read: {type(e).__name__}: {e}")
            check(os.path.exists(os.path.join(SCRIPTS, s["expected_json"])), f"{p}: expected exists")
        except _plan.Refused:
            refused += 1
    check(WITNESS in [os.path.basename(p)[:-5] for p in paths], f"the witness {WITNESS} is in the corpus")
    # The floor: the corpus reaches the reader (a count of 0 would make the
    # arm above vacuous), and a scope the web cannot find is refused by name.
    check(panel_acts > 0, f"the corpus plans panel acts for panel_fields to read ({panel_acts})")
    pa = ("panel", "p_panel", "p_panel_tab", None, "w", "click", None, None, "button")
    try:
        check(panel_fields(pa + ([],)) == ("p_panel", "p_panel_tab", None, "w", "click", None, []),
              "a panel act with no scope reads as its six fields and no iterations")
        # Row 290: the web delivers `at`. A foreach renders as div#<foreach id>
        # with each iteration as its direct child, so iteration k is that
        # div's (k+1)-th child; nested foreaches chain, outermost first.
        check(panel_fields(pa + (["outer#1", "inner#2"],))[6] == [("outer", 1), ("inner", 2)],
              "a scoped panel act reads its iterations, outermost first")
        check(iteration_selector("ap_list", 0) == "#ap_list > :nth-child(1)"
              and iteration_selector("ap_list", 3) == "#ap_list > :nth-child(4)",
              "iteration k is the foreach container's (k+1)-th direct child")
    except Exception as e:  # noqa: BLE001
        fails.append(f"a panel act does not read: {type(e).__name__}: {e}")
    w, t = ARTBOARD_FILL_WANT, "transparent"
    check(at_verdict([t, t], [t, w], 1) == ("PASS", ""), "--at: iteration 1 turns white and iteration 0 does not")
    check(at_verdict([t, t], [w, t], 1)[0] == "FAIL", "--at: the WRONG iteration turning white fails")
    check(at_verdict([t, t], [w, w], 1)[0] == "FAIL", "--at: both turning white fails (the step was not scoped)")
    check(at_verdict([t, t], [t, t], 1)[0] == "FAIL", "--at: nothing turning white fails")
    check(at_verdict([t, w], [t, w], 1)[0] == "REFUSED", "--at: a subject already white is refused, never passed")
    check(at_verdict([t], [t, w], 1)[0] == "REFUSED", "--at: not two artboards is refused")
    check(at_line([(1, "PASS", ""), (0, "PASS", "")]).startswith("AT PASS")
          and at_line([(1, "PASS", ""), (0, "FAIL", "x")]).startswith("AT FAIL")
          and at_line([(1, "REFUSED", "y"), (0, "PASS", "")]).startswith("AT REFUSED"),
          "--at: the line passes only when both iterations pass, and names a refusal")
    for bad in (["ap_list"], ["ap_list#"], ["ap_list#x"], ["ap_list#-1"], ["#1"], ["a#1#2"]):
        try:
            parse_scope(bad)
            fails.append(f"a malformed scope {bad} is refused by name")
        except _plan.Refused as e:
            check(bad[0] in str(e), f"the refusal names the malformed scope {bad} ({e})")
        except Exception as e:  # noqa: BLE001
            fails.append(f"a malformed scope {bad} raises {type(e).__name__}, not a refusal: {e}")
    ids = menu_ids_by_path(menubar)
    check(ids.get(tuple(_plan.menu_paths(menubar)["menu_group"])) == "menu_group", "a menu path maps back to its id")
    for a in (("toolbar", "btn_arrow_slot", 400), ("read", "state", ("active_tool",), "{}"), ("read", "dialog", None)):
        check(undelivered(a) is not None and str(a[1]) in undelivered(a), f"{a[:2]} is refused by name")
    check(undelivered(("read", "document")) is None, "a document read is delivered")
    check(undelivered(("pointer", "press", 0, 0, False, ())) is None, "a pointer act is delivered")
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
    # --dock (R1-2's live arm): its reader, cases and verdict are mac_l2_plan's
    # and self-test there. Here, only that the drop points fit this viewport.
    band = snap_distance()
    for e in DOCK_EDGES:
        px, py = dock_point(e, VIEWPORT["width"], VIEWPORT["height"], band)
        check(0 < px < VIEWPORT["width"] and 0 < py < VIEWPORT["height"], f"the {e} drop point is inside the viewport")
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
    # R1-2h: the snap preview, read mid-drag from the DOM (flask's 775).
    w, rgb = snap_preview_style()
    check(w > 0 and rgb.startswith("rgb("), f"the preview style reads from app.rs ({w}px {rgb})")
    check(hex_to_rgb("#4a90d9") == "rgb(74, 144, 217)", "hex_to_rgb writes the computed-style form")
    check(preview_label([]) == "none" and preview_label(["left", "left"]) == "left"
          and preview_label(["bottom", "left"]) == "bottom+left", "preview_label: none, dedup, sorted")
    five = [("stroke", "left", "PASS", "", {"up": "left", "src": "kept"}),
            ("layers", "bottom", "FAIL", "x", {"up": "none", "src": "gone"}),
            ("align", None, "PASS", "", {"via": "left", "up": "left"})]
    check(dock_summary(five) == "DOCK RED 2/3 (FAIL layers->bottom: x)", "dock_summary reads cases that carry a preview")
    # --fit (row 66): the reader refuses a read that could not have failed.
    good = {"bars": 5, "bad": 0, "hscroll": 0, "vbar": 0}
    goodc = {"bars": 5, "bad": 0, "hscroll": 0, "vbar": 16}
    check(fit_line({"overlay": good, "classic": goodc}) == "FIT 2/2", "both conditions fitting is FIT 2/2")
    check(fit_line({"overlay": good, "classic": dict(goodc, hscroll=1)}) == "FIT RED 1/2 (FAIL classic: bad=0 hscroll=1)",
          "a classic-bar sideways scroll is RED and names its condition")
    check(fit_line({"overlay": dict(good, bad=2), "classic": goodc}) == "FIT RED 1/2 (FAIL overlay: bad=2 hscroll=0)",
          "a tab bar past the dock is RED")
    check(fit_line({"overlay": dict(good, bars=0), "classic": goodc}).startswith("FIT NOT RUN (overlay: no tab bar found"),
          "no tab bar found is NOT RUN, never a pass over nothing")
    check(fit_line({"overlay": good, "classic": dict(goodc, vbar=0)}).startswith("FIT NOT RUN (classic: the dock shows no scrollbar width"),
          "classic bars that did not take are NOT RUN, never an overlay read under the classic label")
    check(fit_line({}) == "FIT NOT RUN (no condition read)", "no readings is NOT RUN")
    check(fit_line({"overlay": dict(good, cut=["input#prop_x 131/90"]), "classic": goodc})
          == "FIT RED 1/2 (FAIL overlay: bad=0 hscroll=0 cut=1 [input#prop_x 131/90])",
          "a control drawn past its cell on ANY dock tab is RED and named (row 193)")
    check(fit_line({"overlay": dict(good, hscroll=1, who=["div#x[245/238] by input#y+7"]), "classic": goodc})
          == "FIT RED 1/2 (FAIL overlay: bad=0 hscroll=1 [div#x[245/238] by input#y+7])", "a RED names the scroller and what overruns it")
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
    ap.add_argument("--fit", action="store_true",
                    help="also read the dock's fit under overlay and classic scrollbars (row 66)")
    ap.add_argument("--at", action="store_true",
                    help="also drive a panel step scoped to one foreach iteration (Artboards Options in row k) and read it (row 290)")
    ap.add_argument("--artboard-fill", action="store_true",
                    help="also pick White in Artboard Options' Fill dropdown and read the artboard (row 270)")
    ap.add_argument("--layers", action="store_true",
                    help="also run the Layers tree cases R1 R4-R7 on the shared verdicts (row 266)")
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
