#!/usr/bin/env python3
"""The pure half of the Mac level-2 script driver (docs/TESTING.md section 6).

`jas_gui_harness.py script <file>` drives an input script through the LIVE Mac
app: real Quartz pointer and key events, panel widgets and menu items through
Accessibility, and the read-back from `jas://document`. Everything that needs no
window lives here, so it runs (and self-tests) on any machine:

  plan(script, menubar)       the script as a list of acts, or a refusal by name
  doc_to_screen(...)          a document point as a screen point, from the view
                              the canvas reports and the canvas's screen frame
  parse_view_report(text)     the canvas's accessibility value, `view z x y`
  menu_paths(menubar)         menu item id -> its title path in the Mac menubar
  set_aside_the_opens_artboard(got, want)
                              the Windows oracle's rule, and the Rust engine
                              replay's (`ffi_script_replay.rs`), here in Python

The refusals mirror the Windows hand's (`send_hand.ps1`): `meta`; a pointer or
key step after a panel or menu step; a script with no `read`; and, for this
channel, a `read` other than `document` (the tree and pixel reads are not built
here). A menu id with no unique path in the menubar is refused by name, never
guessed. A panel is shown the way a person shows it on the Mac, by its dock tab,
whose accessibility identifier is `<panel content id>_tab`.

Usage:  python3 scripts/mac_l2_plan.py --self-test
        python3 scripts/mac_l2_plan.py --plan test_fixtures/input_scripts/X.json
"""
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class Refused(Exception):
    """A script this channel will not drive, with the reason."""


def _title(label):
    # The Mac menubar shows a spec label without its mnemonic `&`.
    return label.replace("&", "")


def menu_paths(menubar):
    """Menu item id -> [top title, (submenu title, ...) item title].

    An id that occurs twice has no unique path and maps to None, so a script
    naming it is refused rather than driven at the first one found."""
    paths = {}

    def walk(items, prefix):
        for it in items or []:
            if not isinstance(it, dict):
                continue  # a separator
            p = prefix + [_title(it.get("label", ""))]
            iid = it.get("id")
            if iid:
                paths[iid] = None if iid in paths else p
            walk(it.get("items"), p)

    for top in menubar.get("menubar", []):
        walk(top.get("items"), [_title(top.get("label", ""))])
    return paths


def live_title(text):
    """A live Mac menu title as the spec writes it. The Mac menubar draws a
    checkable item's state INTO its title (`✓ Stroke`, `    Paragraph`), so
    the mark and the indent are stripped before comparing."""
    t = text or ""
    if t.startswith("\u2713"):
        t = t[1:]
    return t.strip()


TAB_SUFFIX = "_tab"


def panel_menu_paths(menubar):
    """Panel name -> the title path of the Window item that toggles it. A
    panel in no dock group has no tab; a person opens it from this item."""
    out = {}

    def walk(items, prefix):
        for it in items or []:
            if not isinstance(it, dict):
                continue
            p = prefix + [_title(it.get("label", ""))]
            if it.get("action") == "toggle_panel":
                name = (it.get("params") or {}).get("panel")
                if name:
                    out[name] = None if name in out else p
            walk(it.get("items"), p)

    for top in menubar.get("menubar", []):
        walk(top.get("items"), [_title(top.get("label", ""))])
    return out


PANEL_SUFFIX = "_panel_content"
POINTER_KINDS = ("press", "move", "release")
MODS = ("shift", "alt", "ctrl")


def _even(v):
    return isinstance(v, (int, float)) and float(v).is_integer() and int(v) % 2 == 0


def find_widget(spec, wid):
    """The element with `id: wid` anywhere in a panel spec, or None."""
    if isinstance(spec, dict):
        if spec.get("id") == wid:
            return spec
        for v in spec.values():
            hit = find_widget(v, wid)
            if hit is not None:
                return hit
    elif isinstance(spec, list):
        for v in spec:
            hit = find_widget(v, wid)
            if hit is not None:
                return hit
    return None


def select_label(widget, value):
    """A select's option label for `value`: the title its popup shows."""
    for o in widget.get("options") or []:
        if isinstance(o, dict) and str(o.get("value")) == str(value):
            return o.get("label")
    return None


def plan(script, menubar, spec=None):
    """The script as acts: ("open", svg) ("tool", id) ("pointer", kind, x, y,
    dragging, mods) ("key", key, mods) ("panel", panel_id, tab_id,
    window_path, widget, event, value, option_label) ("menu", path)
    ("read", "document"). `spec` is the script's panel spec, parsed; a select
    commit needs it for the option's label. Raises Refused."""
    item = script.get("item", "?")
    steps = script.get("steps") or []
    if not any(isinstance(s, dict) and "read" in s for s in steps):
        raise Refused(f"{item}: a script without a read step asserts nothing")
    menus, panels = menu_paths(menubar), panel_menu_paths(menubar)
    acts = [("open", script["setup_svg"]), ("tool", script["tool"])]
    late = None  # the first panel or menu step, after which no gesture may come
    for i, st in enumerate(steps):
        if "read" in st:
            if st["read"] != "document":
                raise Refused(f"{item}: step {i} reads {st['read']!r}; this channel reads the document only")
            acts.append(("read", "document"))
            continue
        if st.get("meta"):
            raise Refused(f"{item}: step {i} carries meta, which the engine's key route does not take")
        if "kind" in st or "key" in st:
            if late is not None:
                raise Refused(f"{item}: step {i} is a pointer or key step after the {late} step")
            mods = tuple(m for m in MODS if st.get(m))
            if "kind" in st:
                if st["kind"] not in POINTER_KINDS:
                    raise Refused(f"{item}: step {i} has pointer kind {st['kind']!r}")
                if not (_even(st.get("x")) and _even(st.get("y"))):
                    raise Refused(f"{item}: step {i} is at ({st.get('x')}, {st.get('y')}); a script's units are even")
                acts.append(("pointer", st["kind"], int(st["x"]), int(st["y"]), bool(st.get("dragging")), mods))
            else:
                acts.append(("key", st["key"], mods))
            continue
        if "panel" in st:
            pid = st["panel"]
            if not pid.endswith(PANEL_SUFFIX):
                raise Refused(f"{item}: step {i} names panel {pid!r}, not a panel content id")
            if st.get("event") not in ("click", "commit"):
                raise Refused(f"{item}: step {i} has panel event {st.get('event')!r}")
            # The Window item may be None (no unique item); the driver refuses
            # only if it needs it, when the panel has no dock tab either.
            label = None
            w = find_widget(spec, st["widget"]) if spec is not None else None
            if w is not None and w.get("type") == "select" and st["event"] == "commit":
                label = select_label(w, st.get("value"))
                if label is None:
                    raise Refused(f"{item}: step {i}: {st.get('value')!r} is not an option of select {st['widget']!r}")
            acts.append(("panel", pid, pid + TAB_SUFFIX, panels.get(pid[: -len(PANEL_SUFFIX)]),
                         st["widget"], st["event"], st.get("value"), label))
            late = late or "panel"
            continue
        if "menu" in st:
            path = menus.get(st["menu"])
            if not path:
                raise Refused(f"{item}: step {i}: menu id {st['menu']!r} has no unique path in the menubar")
            acts.append(("menu", path))
            late = late or "menu"
            continue
        raise Refused(f"{item}: step {i} is not a step this channel knows: {sorted(st)}")
    return acts


PERSON_TOLERANCE_S = 0.5  # HID idle clock and the driver's clock may differ by this


def a_person_acted(idle_s, since_mine_s, tolerance=PERSON_TOLERANCE_S):
    """True when the console saw input AFTER the driver's own last event.

    `idle_s` is the HID system's seconds since ANY input; `since_mine_s` is
    the seconds since the driver last posted one (None before its first). The
    driver's own events reset the idle clock too, so input is a person's only
    when the idle time is clearly shorter than the time since the driver's
    last event. Checked before EVERY act: a person returning mid-run aborts
    the run, never pauses it, because resuming would post into their work."""
    if since_mine_s is None:
        return False
    return idle_s < since_mine_s - tolerance


def run_guarded(acts, blocked, do_act):
    """Run each act, asking `blocked()` BEFORE every one. It returns None to
    go on, or the reason to stop (a person used the console, the screen is
    locked). The first reason aborts with Refused naming the act; no later act
    runs. Returns the last act's result (the read-back)."""
    result = None
    for i, act in enumerate(acts):
        why = blocked()
        if why:
            raise Refused(f"{why} before act {i} ({act[0]}); the run is aborted, not paused")
        result = do_act(act)
    return result


_VIEW = re.compile(r"^view (\S+) (\S+) (\S+)$")


def parse_view_report(text):
    """`view z x y` (the canvas's accessibility value) -> (z, x, y), or None."""
    m = _VIEW.match((text or "").strip())
    if not m:
        return None
    try:
        z, x, y = (float(g) for g in m.groups())
    except ValueError:
        return None
    return (z, x, y) if z > 0 else None


def doc_to_screen(view, frame_origin, x, y):
    """A document point -> the screen point a CGEvent takes.

    The canvas is flipped (origin top left, y down, as AX and CGEvent are) and
    a tool reads `(local - offset) / zoom`, so local = offset + doc * zoom."""
    z, ox, oy = view
    fx, fy = frame_origin
    return (fx + ox + x * z, fy + oy + y * z)


_AB_ID = re.compile(r"^[0-9a-z]{8}$")


def set_aside_the_opens_artboard(got, want):
    """The Windows oracle's rule (`Compare-SbReadBack`): when the expected names
    no artboards, set aside exactly the one the open adds (`Artboard 1`, an
    8-character base-36 id); anything else in its place is refused by name."""
    head = '{"artboards":['
    if '"artboards":' in want or not got.startswith(head):
        return got
    end = got.find("],")
    if end < 0:
        raise Refused("the read-back opens with an artboards member this reader cannot delimit")
    try:
        abs_ = json.loads(got[len(head) - 1: end + 1])
    except ValueError:
        raise Refused("the read-back opens with an artboards member this reader cannot delimit")
    if len(abs_) != 1:
        raise Refused(f"the read-back carries {len(abs_)} artboards where the expected names none; the open adds exactly one")
    aid, name = abs_[0].get("id", ""), abs_[0].get("name", "")
    if not _AB_ID.match(aid) or name != "Artboard 1":
        raise Refused(f'an artboard the expected does not name, and not the one the open adds: id "{aid}" name "{name}"')
    return "{" + got[end + 2:]


def load_spec(script):
    import yaml
    path = os.path.join(REPO, script.get("spec", ""))
    if not script.get("spec", "").startswith("workspace/panels/") or not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f)


def load_menubar():
    import yaml
    with open(os.path.join(REPO, "workspace", "menubar.yaml"), encoding="utf-8") as f:
        return yaml.safe_load(f)


# ---------------------------------------------------------------------------
def self_test():
    fails = []
    ran = [0]

    def check(name, cond):
        ran[0] += 1
        if not cond:
            fails.append(name)

    def refused(fn, needle):
        try:
            fn()
        except Refused as e:
            return needle in str(e)
        return False

    mb = {"menubar": [
        {"id": "object_menu", "label": "&Object", "items": [
            {"id": "menu_group", "label": "&Group", "action": "group"}, "separator",
            {"id": "menu_sub", "label": "Ar&range", "items": [
                {"id": "menu_front", "label": "Bring to &Front", "action": "bring_to_front"}]}]},
        {"id": "window_menu", "label": "&Window", "items": [
            {"id": "menu_stroke", "label": "&Stroke", "action": "toggle_panel", "params": {"panel": "stroke"}},
            {"id": "menu_dup", "label": "A", "action": "a"}, {"id": "menu_dup", "label": "B", "action": "b"}]},
    ]}
    mp = menu_paths(mb)
    check("menu path strips the mnemonic", mp["menu_group"] == ["Object", "Group"])
    check("menu path walks a submenu", mp["menu_front"] == ["Object", "Arrange", "Bring to Front"])
    check("a twice-used id has no path", mp["menu_dup"] is None)
    check("a checked live title reads as its label", live_title("\u2713 Stroke") == "Stroke")
    check("an unchecked live title reads as its label", live_title("    Paragraph") == "Paragraph")
    check("a plain live title is unchanged", live_title("Group") == "Group")

    base = {"item": "t", "setup_svg": "s.svg", "tool": "selection"}
    press = {"kind": "press", "x": 36, "y": 18}
    rel = {"kind": "release", "x": 36, "y": 18}
    pan = {"panel": "stroke_panel_content", "widget": "stk_join_miter", "event": "click"}
    read = {"read": "document"}
    acts = plan(dict(base, steps=[press, rel, pan, {"menu": "menu_group"}, read]), mb)
    check("plan opens, picks the tool, then the steps in order",
          [a[0] for a in acts] == ["open", "tool", "pointer", "pointer", "panel", "menu", "read"])
    check("a panel act carries its dock tab's id", acts[4][2] == "stroke_panel_content_tab")
    check("a panel act carries its Window item", acts[4][3] == ["Window", "Stroke"])
    check("panel paths", panel_menu_paths(mb) == {"stroke": ["Window", "Stroke"]})
    sel = {"content": [{"id": "op_mode", "type": "select",
                        "options": [{"value": "normal", "label": "Normal"}, "separator",
                                    {"value": "multiply", "label": "Multiply"}]}]}
    sstep = {"panel": "opacity_panel_content", "widget": "op_mode", "event": "commit", "value": "multiply"}
    check("a select commit carries its option label",
          plan(dict(base, steps=[sstep, read]), mb, sel)[2][7] == "Multiply")
    check("a select value that is not an option is refused",
          refused(lambda: plan(dict(base, steps=[dict(sstep, value="nope"), read]), mb, sel), "not an option"))
    check("a click carries no label", acts[4][7] is None)
    check("modifiers are carried", plan(dict(base, steps=[dict(press, shift=True), read]), mb)[2][5] == ("shift",))
    check("no read is refused", refused(lambda: plan(dict(base, steps=[press]), mb), "without a read"))
    check("a tree read is refused", refused(lambda: plan(dict(base, steps=[{"read": "tree"}]), mb), "document only"))
    check("meta is refused", refused(lambda: plan(dict(base, steps=[{"key": "Z", "meta": True}, read]), mb), "meta"))
    check("a gesture after a panel step is refused",
          refused(lambda: plan(dict(base, steps=[pan, press, read]), mb), "after the panel step"))
    check("a key after a menu step is refused",
          refused(lambda: plan(dict(base, steps=[{"menu": "menu_group"}, {"key": "Z"}, read]), mb), "after the menu step"))
    check("an odd unit is refused", refused(lambda: plan(dict(base, steps=[dict(press, x=37), read]), mb), "even"))
    check("a fractional unit is refused", refused(lambda: plan(dict(base, steps=[dict(press, y=18.5), read]), mb), "even"))
    check("an unknown menu id is refused", refused(lambda: plan(dict(base, steps=[{"menu": "nope"}, read]), mb), "'nope'"))
    check("a duplicate menu id is refused", refused(lambda: plan(dict(base, steps=[{"menu": "menu_dup"}, read]), mb), "menu_dup"))
    check("a panel id that is not a content id is refused",
          refused(lambda: plan(dict(base, steps=[dict(pan, panel="stk_content"), read]), mb), "not a panel content id"))
    check("an unknown step is refused", refused(lambda: plan(dict(base, steps=[{"wave": 1}, read]), mb), "wave"))

    # A person returning mid-script: the driver posted at t=0, the person
    # touched the mouse at t=3, the next check is at t=5, so idle 2 < 5.
    check("a person's input after the driver's last event is seen", a_person_acted(2.0, 5.0))
    check("the driver's own last event is not a person's", not a_person_acted(5.0, 5.0))
    check("clock skew inside the tolerance is not a person", not a_person_acted(4.8, 5.0))
    check("before the driver's first event nothing is a person's here", not a_person_acted(0.1, None))
    # The fixture the helm ordered: idle drops mid-script, at the third check.
    done = []
    readings = iter([None, None, "a person used the console", None])
    acts5 = [("open", "s"), ("tool", "t"), ("pointer", "press"), ("pointer", "release"), ("read", "document")]
    check("a person mid-script aborts the run at that act",
          refused(lambda: run_guarded(acts5, lambda: next(readings), done.append), "a person used the console before act 2 (pointer)"))
    check("no act after the person runs", [a[0] for a in done] == ["open", "tool"])
    ran2 = []
    check("an unbroken run returns the last act's result",
          run_guarded(acts5, lambda: None, lambda a: ran2.append(a) or a[0]) == "read" and len(ran2) == 5)
    check("view report parses", parse_view_report("view 1.0 0.0 0.0") == (1.0, 0.0, 0.0))
    check("view report with other text is None", parse_view_report("zoom 1") is None)
    check("view report with zoom 0 is None", parse_view_report("view 0 0 0") is None)
    # The mapping is checked on asymmetric numbers so a swapped axis or a
    # dropped term gives a different answer for every one of them.
    check("doc to screen at the identity view", doc_to_screen((1, 0, 0), (100, 200), 36, 18) == (136, 218))
    check("doc to screen with zoom and pan", doc_to_screen((2, 5, -7), (100, 200), 36, 18) == (177, 229))

    ab = lambda i, n: '{"fill":"transparent","id":"%s","name":"%s","x":0.0}' % (i, n)
    rest = '"layers":[],"selection":[]}'
    want = "{" + rest
    one = '{"artboards":[%s],%s' % (ab("pfj2j82z", "Artboard 1"), rest)
    check("the open's artboard is set aside", set_aside_the_opens_artboard(one, want) == want)
    named = '{"artboards":[],' + rest
    check("nothing set aside when the expected names artboards", set_aside_the_opens_artboard(one, named) == one)
    two = '{"artboards":[%s,%s],%s' % (ab("pfj2j82z", "Artboard 1"), ab("abcdefgh", "Artboard 2"), rest)
    check("two artboards refused", refused(lambda: set_aside_the_opens_artboard(two, want), "carries 2 artboards"))
    check("a wrong name refused", refused(lambda: set_aside_the_opens_artboard(
        '{"artboards":[%s],%s' % (ab("pfj2j82z", "Artboard 9"), rest), want), "not the one the open adds"))
    check("an upper-case id refused", refused(lambda: set_aside_the_opens_artboard(
        '{"artboards":[%s],%s' % (ab("PFJ2J82Z", "Artboard 1"), rest), want), "not the one the open adds"))

    # The real artifacts: every shipped script plans, and every menu and panel
    # path it needs exists in the real menubar. This is the population check:
    # it counts the scripts it planned, so an empty directory cannot pass.
    real = load_menubar()
    d = os.path.join(REPO, "test_fixtures", "input_scripts")
    names = sorted(f for f in os.listdir(d) if f.endswith(".json") and not f.endswith(".expected.json"))
    planned = 0
    for f in names:
        with open(os.path.join(d, f), encoding="utf-8") as fh:
            try:
                sc = json.load(fh)
                plan(sc, real, load_spec(sc))
                planned += 1
            except Refused as e:
                fails.append(f"shipped script refused: {e}")
    check(f"every shipped script plans ({planned} of {len(names)})", planned == len(names))
    # Known members of each step family, so a wrong directory cannot pass.
    for member in ("align.left.json", "object.group.json", "shortcut.undo.json", "selection.drag.json"):
        check(f"the population holds {member}", member in names)
    check("the real menubar gives object.group its path", menu_paths(real).get("menu_group") == ["Object", "Group"])

    total = ran[0]
    print(f"mac_l2_plan self-test: {total - len(fails)} of {total} checks passed, {planned} shipped scripts planned")
    for f in fails:
        print("  FAIL:", f)
    return 1 if fails else 0


def main(argv):
    if argv[1:] == ["--self-test"]:
        return self_test()
    if len(argv) == 3 and argv[1] == "--plan":
        with open(argv[2], encoding="utf-8") as f:
            sc = json.load(f)
            for act in plan(sc, load_menubar(), load_spec(sc)):
                print(act)
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
