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
                                   [--only NAME ...] [--artifacts DIR]
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


def read_back(got, want):
    """The app's read as the expected is written: the open's artboard set
    aside, then each fresh id where the expected names `<minted>` accepted as
    the token. Both laws are mac_l2_plan's, shared with the Mac channel."""
    return _plan.accept_minted_ids(_plan.set_aside_the_opens_artboard(got, want), want)


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
            return read_back(page.evaluate("() => window.__jasTest.read()").strip(), want)
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


def run(args):
    menubar = _plan.load_menubar()
    menu_ids = menu_ids_by_path(menubar)
    paths = script_paths(args.only)
    br = Browser(args.url)
    lines = []
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
    finally:
        br.close()
    date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    first = receipt(results, args.head, date, not_run=not_run)
    body = [first, f"unmoved={unmoved} (PASSes whose read equals their opening read; a vacuity tell, not a failure)"] + lines
    print("\n".join(body))
    if args.receipt:
        with open(args.receipt, "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(body) + "\n")
    if args.advisory and args.receipt:
        return 0   # the verdict rides in the receipt; only a run that wrote none fails the step (jas, #836 review)
    return 0 if " verdict=GREEN " in first else 1


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
    minted_files = sorted(p for p in glob.glob(os.path.join(SCRIPTS, "*.expected.json"))
                          if '"id":"<minted>"' in open(p, encoding="utf-8").read())
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
            check(read_back(app_read, mwant) == mwant, f"{os.path.basename(mf)}: fresh ids read back as the expected")
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
