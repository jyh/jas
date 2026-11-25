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
  accept_minted_ids(got, want)
                              the minted-id law (Rust `accept_minted_ids`,
                              Swift `acceptMintedIds`, Windows
                              `Compare-SbReadBack`), here in Python
  read_back(got, want)        both laws, artboard first: THE comparator of
                              the Mac and web channels (one law, never two)
  receipt_line(...)           the run's `UI-NIGHTLY v1` receipt line (O100)
  launch_env_problem(env)     why the launch environment cannot run, or None

The refusals mirror the Windows hand's (`send_hand.ps1`): `meta`; a script
with no `read`; and, for this channel, a `read` other than `document` (the tree
and pixel reads are not built here). ONE DELIBERATE DIFFERENCE: this channel
plans a pointer or key step AFTER a panel or menu step, in script order (the
Align key-object scripts press the canvas after clicking "align to key
object"); the driver acts in order and re-checks that Jas is frontmost before
every pointer and key act. The Windows hand sends its gesture first and its
panel steps last, so it still refuses that shape (since 2026-10-18). A menu id with no unique path in the menubar is refused by name, never
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
# The keys each step kind DELIVERS on this channel. Any other key is refused by
# name: a form this driver does not build (`hold_ms`, `row`, `at`, a panel
# step's modifiers, a tree read's `window`) would otherwise be dropped, and the
# run would drive a different gesture and read as measured (docs/TESTING.md
# lists those forms; the Mac driver has not built them).
DELIVERED_KEYS = {
    "read": {"read"},
    "pointer": {"kind", "x", "y", "dragging", "shift", "alt", "ctrl", "meta"},
    "key": {"key", "shift", "alt", "ctrl", "meta"},
    "panel": {"panel", "widget", "event", "value"},
    "menu": {"menu"},
    "toolbar": {"panel", "widget", "event", "hold_ms"},
    "read state": {"read", "keys"},
}
TOOLBAR_PANE = "toolbar_pane"  # a toolbar step's panel: the slots live in workspace/layout.yaml


def _refuse_undelivered(item, i, st, kind):
    extra = sorted(set(st) - DELIVERED_KEYS[kind])
    if extra:
        raise Refused(f"{item}: step {i} carries {', '.join(extra)}; a {kind} step on this "
                      f"channel delivers only {', '.join(sorted(DELIVERED_KEYS[kind]))}")
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


def icon_option_matches(description, label):
    """Whether an icon_select popover button's AXDescription names `label`.
    JasSwift describes each option as "<glyph>, <label>" with no identifier
    (the AX dump of pg_bullets on the Mac test box, 2026-11-23, row 83), so the label is
    matched as the WHOLE text after ", ": "Circle" never picks "Open Circle"."""
    if not isinstance(description, str) or not isinstance(label, str):
        return False
    return description.endswith(", " + label) and len(description) > len(label) + 2


def canonical_state(text):
    """A state read as the comparison reads it: JSON, keys sorted, no whitespace."""
    return json.dumps(json.loads(text), sort_keys=True, separators=(",", ":"))


def load_state_keys():
    """The keys `workspace/state.yaml` declares: the only keys a state read may name."""
    import yaml
    with open(os.path.join(REPO, "workspace", "state.yaml"), encoding="utf-8") as f:
        return set((yaml.safe_load(f) or {}).get("state") or {})


def _plan_read(item, i, st, script, state_keys):
    kind = st["read"]
    if kind == "state":
        keys = st.get("keys")
        if not (isinstance(keys, list) and keys and all(isinstance(k, str) for k in keys)
                and len(set(keys)) == len(keys)):
            raise Refused(f"{item}: step {i}: a state read's keys must be a non-empty list of distinct names, "
                          f"not {keys!r}")
        _refuse_undelivered(item, i, st, "read state")
        undeclared = sorted(set(keys) - state_keys)
        if undeclared:
            raise Refused(f"{item}: step {i} reads {', '.join(undeclared)}, which workspace/state.yaml does not declare")
        want = script.get("expected_state_json")
        if not isinstance(want, dict):
            raise Refused(f"{item}: step {i} reads state; the script carries no expected_state_json object")
        if set(want) != set(keys):
            raise Refused(f"{item}: step {i} reads {sorted(keys)}; expected_state_json names {sorted(want)}")
        return ("read", "state", tuple(keys), canonical_state(json.dumps(want)))
    _refuse_undelivered(item, i, st, "read")
    if kind == "dialog":
        if "expected_dialog" not in script:
            raise Refused(f"{item}: step {i} reads the dialog; the script carries no expected_dialog")
        want = script["expected_dialog"]
        if want is not None and not isinstance(want, str):
            raise Refused(f"{item}: step {i}: expected_dialog is {want!r}, not a dialog id or null")
        return ("read", "dialog", want)
    if kind != "document":
        raise Refused(f"{item}: step {i} reads {kind!r}; this channel reads the document, state or dialog")
    return ("read", "document")


def _plan_toolbar(item, i, st, spec):
    _refuse_undelivered(item, i, st, "toolbar")
    if st.get("event") != "press":
        raise Refused(f"{item}: step {i}: a toolbar step's event is press, not {st.get('event')!r}")
    hold = st.get("hold_ms", 0)
    if "hold_ms" in st and not (type(hold) is int and hold > 0):
        raise Refused(f"{item}: step {i}: hold_ms is {hold!r}; it is a positive whole number of milliseconds")
    if spec is None:
        raise Refused(f"{item}: step {i} is a toolbar step; its script's spec must be workspace/layout.yaml")
    if find_widget(spec, st.get("widget")) is None:
        raise Refused(f"{item}: step {i}: slot {st.get('widget')!r} is not declared in workspace/layout.yaml")
    return ("toolbar", st["widget"], hold)


def plan(script, menubar, spec=None, state_keys=None):
    """The script as acts: ("open", svg, reset_workspace) ("tool", id) ("pointer", kind, x, y,
    dragging, mods) ("key", key, mods) ("panel", panel_id, tab_id,
    window_path, widget, event, value, option_label, widget_type) ("menu", path)
    ("read", "document") ("toolbar", slot, hold_ms) ("read", "state", keys,
    canonical expected) ("read", "dialog", expected id or None). `spec` is the
    script's panel spec, parsed (workspace/layout.yaml for a toolbar step); a
    select commit needs it for the option's label. `state_keys` is the set
    workspace/state.yaml declares (loaded when None). Raises Refused."""
    item = script.get("item", "?")
    steps = script.get("steps") or []
    if not any(isinstance(s, dict) and "read" in s for s in steps):
        raise Refused(f"{item}: a script without a read step asserts nothing")
    menus, panels = menu_paths(menubar), panel_menu_paths(menubar)
    # The open act asks for a reset workspace: the app persists its dock layout,
    # so a fresh process alone starts where the last script left it (row 254).
    acts = [("open", script["setup_svg"], True), ("tool", script["tool"])]
    for i, st in enumerate(steps):
        if "read" in st:
            if st["read"] == "state" and state_keys is None:
                state_keys = load_state_keys()
            acts.append(_plan_read(item, i, st, script, state_keys))
            continue
        if st.get("panel") == TOOLBAR_PANE:
            acts.append(_plan_toolbar(item, i, st, spec))
            continue
        if st.get("meta"):
            raise Refused(f"{item}: step {i} carries meta, which the engine's key route does not take")
        if "kind" in st or "key" in st:
            _refuse_undelivered(item, i, st, "pointer" if "kind" in st else "key")
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
            _refuse_undelivered(item, i, st, "panel")
            pid = st["panel"]
            if not pid.endswith(PANEL_SUFFIX):
                raise Refused(f"{item}: step {i} names panel {pid!r}, not a panel content id")
            if st.get("event") not in ("click", "commit"):
                raise Refused(f"{item}: step {i} has panel event {st.get('event')!r}")
            # The Window item may be None (no unique item); the driver refuses
            # only if it needs it, when the panel has no dock tab either.
            label = None
            w = find_widget(spec, st["widget"]) if spec is not None else None
            wtype = w.get("type") if w is not None else None
            # A select's option is a menu item; an icon_select's is a popover
            # button (row 83). Both carry the option's label; the type says which.
            if wtype in ("select", "icon_select") and st["event"] == "commit":
                label = select_label(w, st.get("value"))
                if label is None:
                    raise Refused(f"{item}: step {i}: {st.get('value')!r} is not an option of {wtype} {st['widget']!r}")
            acts.append(("panel", pid, pid + TAB_SUFFIX, panels.get(pid[: -len(PANEL_SUFFIX)]),
                         st["widget"], st["event"], st.get("value"), label, wtype))
            continue
        if "menu" in st:
            _refuse_undelivered(item, i, st, "menu")
            path = menus.get(st["menu"])
            if not path:
                raise Refused(f"{item}: step {i}: menu id {st['menu']!r} has no unique path in the menubar")
            acts.append(("menu", path))
            continue
        raise Refused(f"{item}: step {i} is not a step this channel knows: {sorted(st)}")
    return acts


# ── the locked-console route (STATUS-jas row 250) ─────────────────────────
# With the console locked the app is never active, so a Quartz event lands
# nowhere and a posted click never reaches the canvas (row 249). The FIFO's
# `gesture <json>` (FifoGesture.swift) delivers a pointer run to the canvas
# view's own handlers instead, in document units, and `read` reads back. So a
# locked run folds each run of pointer acts into ONE gesture act, and refuses
# BY NAME what that route cannot deliver: a key needs a key window, a menu and
# a toolbar hold are pressed through a window server a locked console does
# not give. A panel act is left for the driver, whose accessibility walk
# either finds the widget or refuses by name. NOT witnessed on this route:
# the window's first-mouse and key routing.
GESTURE_FIELDS = ("kind", "x", "y", "dragging", "shift", "alt")  # FifoGesture.parse's fields


def locked_acts(acts, item="?"):
    """`plan()`'s acts for the locked route: ("gesture", steps) in place of
    each run of pointer acts, everything else unchanged. Raises Refused."""
    out, run = [], None
    for a in acts:
        if a[0] != "pointer":
            run = None
            if a[0] == "key":
                raise Refused(f"{item}: a key step ({a[1]}) needs a key window, which a locked console never gives")
            if a[0] in ("menu", "toolbar"):
                raise Refused(f"{item}: a {a[0]} step is pressed through the window server, "
                              f"which a locked console does not give")
            out.append(a)
            continue
        _, kind, x, y, dragging, mods = a
        if "ctrl" in mods:
            raise Refused(f"{item}: a pointer step carries ctrl, which the canvas reads no form of")
        if kind == "move" and not dragging and "shift" in mods:
            raise Refused(f"{item}: a shift on a move that does not drag, which the canvas's mouseMoved drops")
        st = {"kind": kind, "x": x, "y": y}
        if dragging:
            st["dragging"] = True
        for m in ("shift", "alt"):
            if m in mods:
                st[m] = True
        if run is None:
            run = []
            out.append(("gesture", run))
        run.append(st)
    return out


# The locked suite (row 252, desk AHJ option A): the board token a locked run's
# receipt carries. Its members are the corpus scripts this route delivers
# WHOLE: every act a gesture, an open, a tool or a read. A script with a key,
# menu or toolbar step is refused by the route's own reason, and one with a
# panel step is refused too, because a panel act needs the accessibility walk
# and the locked route does not measure that. A member's receipt is always
# scope=partial while any corpus script is not a member, so a locked GREEN
# can never read like mac.live's full one.
LOCKED_SUITE = "mac.locked"


def locked_suite_refusal(script, menubar, spec=None):
    """None when `script` is a member of the locked suite, else the reason it
    is not, by name."""
    item = script.get("item", "?")
    try:
        acts = locked_acts(plan(script, menubar, spec), item)
    except Refused as e:
        return str(e)
    if any(a[0] == "panel" for a in acts):
        return f"{item}: a panel step needs the accessibility walk, which the locked suite does not measure"
    return None


def locked_suite_split(scripts, menubar):
    """`scripts` maps a file name to its script. Returns (the member names,
    sorted; {name: reason} for every script refused)."""
    members, refused = [], {}
    for name in sorted(scripts):
        scr = scripts[name]
        spec = load_spec(scr) if scr.get("spec") else None
        why = locked_suite_refusal(scr, menubar, spec)
        if why is None:
            members.append(name)
        else:
            refused[name] = why
    return members, refused


def gesture_log_verdict(text):
    """The app's own receipt for a gesture, from its log since the command was
    sent: "delivered", the refusal's text, or None while nothing is there yet.
    The FIFO is one-way, so this is the only way a refused or unknown gesture
    is not read as a FAIL of the script (row 250)."""
    for line in text.splitlines():
        if "test-fifo: gesture delivered" in line:
            return "delivered"
        for tell in ("gesture REFUSED", "unknown command gesture"):
            if tell in line:
                return line[line.index(tell):].strip()
    return None


def gesture_command(act):
    """The FIFO line for a ("gesture", steps) act."""
    return "gesture " + json.dumps(act[1], separators=(",", ":"))

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


# THE OWNER'S CLAIM (council 2026-11-24): the test box is free for the fleet at
# any time unless its owner says it is his. The fleet records that word on the
# coordinating host, and a relay there mirrors it onto this box: the claim file
# while he holds the box, and a heartbeat (`<claim>.relay`, touched on every
# pass) either way. The driver reads both before EVERY console act and stops
# while the claim exists. It FAILS CLOSED: a heartbeat that is missing or older
# than the bound means the claim cannot be read, and an unread claim is never
# read as "free". `JAS_CLAIM_FILE=none` turns the check off, and the driver says
# so on every run (a dev box with no relay).
CLAIM_RELAY_MAX_AGE_S = 120  # the relay writes every 30 s; four missed passes is a dead relay
CLAIM_DEFAULT = os.path.join("~", ".fleet", "watch", "CONSOLE-CLAIM")


def claim_refusal(claim_text, relay_age_s, max_age_s=CLAIM_RELAY_MAX_AGE_S):
    """None to go on, or the reason to stop. `claim_text` is the claim file's
    text (None when there is no claim); `relay_age_s` is the heartbeat's age in
    seconds (None when there is no heartbeat). A claim wins over everything."""
    if claim_text is not None:
        return "the owner has claimed this box"
    if relay_age_s is None:
        return "the owner's claim cannot be read: no relay heartbeat"
    if relay_age_s > max_age_s:
        return (f"the owner's claim cannot be read: the relay last wrote {relay_age_s:.0f} s ago "
                f"(bound {max_age_s} s)")
    return None


def claim_check_off(env):
    return env.get("JAS_CLAIM_FILE", "").strip().lower() == "none"


def claim_path(env):
    return os.path.expanduser(env.get("JAS_CLAIM_FILE") or CLAIM_DEFAULT)


def claim_check(env, now):
    """`claim_refusal` over the files on this box (`JAS_CLAIM_FILE`, default
    CLAIM_DEFAULT, and its `.relay` heartbeat), at time `now`."""
    if claim_check_off(env):
        return None
    path = claim_path(env)
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            claim = f.read()
    except FileNotFoundError:
        claim = None
    except OSError as e:
        return f"the owner's claim cannot be read: {type(e).__name__}"
    try:
        age = now - os.stat(path + ".relay").st_mtime
    except OSError:
        age = None
    return claim_refusal(claim, age)


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



MINTED = "<minted>"


def accept_minted_ids(got, want):
    """The minted-id law, Rust's `accept_minted_ids` (`ffi_script_replay.rs`)
    line for line. At each `"id":"<minted>"` in the expected, the read-back
    must carry an 8-character base-36 id, and those ids must be pairwise
    distinct (fresh, not one id stamped twice). Every other id is left for the
    byte comparison, and the counts of `"id":` must agree, so a dropped or an
    extra id is refused. Each accepted id is replaced by the token."""
    key = '"id":"'
    if key + MINTED + '"' not in want:
        return got

    def ids(s):
        out, frm = [], 0
        while True:
            i = s.find(key, frm)
            if i < 0:
                return out
            start = i + len(key)
            end = s.find('"', start)
            end = start if end < 0 else end
            out.append((start, end))
            frm = end

    g, w = ids(got), ids(want)
    if len(g) != len(w):
        raise Refused(f"the read-back carries {len(g)} ids where the expected names {len(w)}")
    out, seen, at = [], set(), 0
    for (gs, ge), (ws, we) in zip(g, w):
        if want[ws:we] != MINTED:
            continue
        mid = got[gs:ge]
        if not _AB_ID.match(mid):
            raise Refused(f'a minted id is not an 8-character base-36 id: "{mid}"')
        if mid in seen:
            raise Refused(f'the minted id "{mid}" is carried twice; a mint is fresh')
        seen.add(mid)
        out.append(got[at:gs])
        out.append(MINTED)
        at = ge
    out.append(got[at:])
    return "".join(out)



def read_back(got, want):
    """The app's read as the expected is written: the open's artboard set
    aside, then each fresh id where the expected names `<minted>` accepted as
    the token. The Mac harness (`jas_gui_harness.py`) and the web driver
    (`scripts/web_l2_driver.py`) both compare through this one function."""
    return accept_minted_ids(set_aside_the_opens_artboard(got, want), want)


def fifo_read_command(act, out):
    """The test-FIFO command that writes `act`'s read to the file `out`."""
    if act[1] == "document":
        return "read " + out
    if act[1] == "state":
        return "state " + out + " " + " ".join(act[2])
    if act[1] == "dialog":
        return "dialog " + out
    raise Refused(f"no FIFO command reads {act[1]!r}")


def compare_read(act, got, want_doc):
    """(ok, got, want) for one read act over the app's written text. A document
    read compares through read_back with the script's expected_json; a state
    read compares canonical JSON with the planned expected; a dialog read
    compares the written id (or null) with the planned one."""
    if act[1] == "document":
        g = read_back(got, want_doc)
        return g == want_doc, g, want_doc
    if act[1] == "state":
        g = canonical_state(got)
        return g == act[3], g, act[3]
    if act[1] == "dialog":
        d = json.loads(got)
        if not (isinstance(d, dict) and set(d) == {"dialog"}):
            raise Refused(f"the app's dialog read is {got!r}, not {{\"dialog\": <id or null>}}")
        return d["dialog"] == act[2], json.dumps(d["dialog"]), json.dumps(act[2])
    raise Refused(f"no comparison for a {act[1]!r} read")


def launch_env_problem(env):
    """Why `jas_gui_harness.py script` cannot start under `env`, or None. The
    driver talks to the app through `JAS_FIFO`, and finds its window by
    `JAS_TITLE`, which `JAS_APP` launches it with (`--title`). Without the title
    the launch crashed in `Popen` on a Mac run box (2026-11-06) instead of refusing."""
    if not env.get("JAS_FIFO"):
        return "JAS_FIFO is not set: the driver reaches the app's --test-fifo through it"
    if env.get("JAS_APP") and not env.get("JAS_TITLE"):
        return "JAS_APP is set without JAS_TITLE: the app is launched with --title JAS_TITLE and found by it"
    return None


RECEIPT_OUTCOMES = ("PASS", "FAIL", "REFUSED")


def receipt_line(outcomes, corpus, head, date, not_run=None, suite="mac.live"):
    """The run's receipt, one `UI-NIGHTLY v1` line (O100's board grammar).

    `outcomes` maps a script's file name to PASS, FAIL or REFUSED; `corpus` is
    every script name in `test_fixtures/input_scripts`. `items` counts passes
    over the scripts RUN; `scope` is `full` only when every corpus script ran.
    `not_run` is the reason a run was refused before any script (a locked
    screen, a person at the console): the line says NOT RUN over the whole
    corpus, so a refused night is a row, never a missing one. `panels=-` until
    this channel reads the tree. A call with no outcome and no reason is
    refused: it would read as a 0/0 run. `suite` names the channel (the web
    driver passes `web.live`), so every channel writes ONE grammar."""
    unknown = sorted(set(outcomes) - set(corpus))
    if unknown:
        raise ValueError("not in the corpus: " + ", ".join(unknown))
    bad = sorted(n for n, o in outcomes.items() if o not in RECEIPT_OUTCOMES)
    if bad:
        raise ValueError("an outcome is not PASS, FAIL or REFUSED: " + ", ".join(bad))
    if not_run is not None:
        verdict, items = "NOT RUN(%s)" % str(not_run).replace(")", "]"), "0/%d" % len(corpus)
        # A refused night is over the whole corpus, except for the locked
        # suite, which never covers it whole, so its NOT RUN is partial too.
        scope = "partial" if suite == LOCKED_SUITE else "full"
    else:
        if not outcomes:
            raise ValueError("no script ran and no refusal was given")
        n = {o: sum(1 for v in outcomes.values() if v == o) for o in RECEIPT_OUTCOMES}
        verdict = ("GREEN" if n["PASS"] == len(outcomes)
                   else "RED(fail=%d refused=%d)" % (n["FAIL"], n["REFUSED"]))
        items = "%d/%d" % (n["PASS"], len(outcomes))
        scope = "full" if set(outcomes) == set(corpus) else "partial"
    return ("UI-NIGHTLY v1 suite=%s verdict=%s items=%s panels=- head=%s scope=%s date=%s"
            % (suite, verdict, items, head, scope, date))


def load_spec(script):
    import yaml
    path = os.path.join(REPO, script.get("spec", ""))
    if script.get("spec") != "workspace/layout.yaml" and not script.get("spec", "").startswith("workspace/panels/"):
        return None
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f)


def load_menubar():
    import yaml
    with open(os.path.join(REPO, "workspace", "menubar.yaml"), encoding="utf-8") as f:
        return yaml.safe_load(f)


# ---------------------------------------------------------------------------
# The dock check: one reader and one verdict, shared by the web channel
# (scripts/web_l2_driver.py --dock) and the Mac channel (jas_gui_harness.py
# dock). It runs OUTSIDE the input-script corpus on purpose: every channel
# replays that corpus, and a dock script would break the engine replays and
# move every channel's item count. A case passes only if BOTH halves hold:
# the engine's layout puts the panel in the dock anchored at the edge, and
# the drawn dock for that edge holds the panel's tab. Either half alone could
# agree with itself.
DOCK_EDGES = ("left", "bottom")
# (panel, the edge it must end anchored at or None to float, a band to pass
# through first or None). All three start in the right dock. The third is
# WORKSPACE.md's "a floating dock DROPPED within SNAP_DISTANCE of a window
# edge snaps": a drag that crosses the left band and drops mid-viewport must
# float, not snap.
DOCK_CASES = (("stroke", "left", None), ("layers", "bottom", None), ("align", None, "left"))
WORKSPACE_RS = os.path.join(REPO, "jas_dioxus", "src", "workspace", "workspace.rs")


def edge_dock_id(edge):
    """The drawn edge dock's id: the web DOM id, which the Swift app also
    carries as the container's AXIdentifier (edgeDockAccessibilityId)."""
    return f"jas-edge-dock-{edge}"


def snap_distance():
    """SNAP_DISTANCE as the app declares it, read from the Rust source."""
    with open(WORKSPACE_RS, encoding="utf-8") as f:
        hits = re.findall(r"^pub const SNAP_DISTANCE: f64 = ([0-9.]+);", f.read(), re.M)
    if len(hits) != 1:
        raise Refused(f"workspace.rs declares SNAP_DISTANCE {len(hits)} times; the dock check needs exactly one")
    return float(hits[0])


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
    raise Refused(f"the app snaps to left, right or bottom; {edge!r} is none of them")


def dock_edge_of(layout_text, kind):
    """The edge of the anchored dock holding panel `kind`, or None if no
    anchored dock holds it (floating or hidden). Refuses rather than guess."""
    lay = json.loads(layout_text)
    if "anchored" not in lay:
        raise Refused("the layout read carries no anchored member")
    edges = [a["edge"] for a in lay["anchored"]
             for g in a["dock"]["groups"] for p in g["panels"] if p == kind]
    if len(edges) > 1:
        raise Refused(f"panel {kind!r} is in {len(edges)} anchored places; a panel is in one")
    return edges[0] if edges else None


def floats(layout_text, kind):
    """True when a floating dock holds panel `kind`."""
    lay = json.loads(layout_text)
    return any(p == kind for f in lay.get("floating", [])
               for g in f["dock"]["groups"] for p in g["panels"])


def dock_start_refusal(before, kind):
    """None when `kind` starts in the right dock, as every case assumes;
    else the reason the case cannot run."""
    at = dock_edge_of(before, kind)
    return None if at == "right" else f"{kind} does not start in the right dock (reads {at!r})"


def dock_verdict(before, after, kind, edge, drawn):
    """-> (status, detail) for one case. `before`/`after` are the engine's
    layout reads; `drawn` maps each of DOCK_EDGES to how many copies of the
    panel's tab that edge's drawn dock holds (0 when the dock is absent)."""
    if after == before:
        return "FAIL", "the layout did not change (did the drag reach its drop?)"
    got = dock_edge_of(after, kind)
    if got != edge:
        return "FAIL", f"the engine anchors {kind} at {got!r}"
    if edge is None:
        if not floats(after, kind):
            return "FAIL", f"{kind} is in no anchored dock and no floating dock"
        if sum(drawn.get(e, 0) for e in DOCK_EDGES):
            return "FAIL", f"an edge dock still draws the {kind} tab"
        return "PASS", ""
    n = drawn.get(edge, 0)
    if n != 1:
        return "FAIL", f"{edge_dock_id(edge)} holds {n} copies of the tab"
    return "PASS", ""


def dock_line(cases):
    """cases: [(kind, edge, status, detail)] -> one line beside the receipt."""
    if not cases:
        return "DOCK NOT RUN"
    ok = sum(1 for c in cases if c[2] == "PASS")
    if ok == len(cases):
        return f"DOCK {ok}/{len(cases)}"
    bad = "; ".join(f"{s} {k}->{e or 'float'}: {d}" for k, e, s, d in cases if s != "PASS")
    return f"DOCK RED {ok}/{len(cases)} ({bad})"


# ── sheet 2's dock drops (rows 129/132/133, row 255) ─────────────────────
# Three drops inside the right dock, each read by the engine layout before and
# after. The targets come from the dock TAB frames only: a panel body's content
# id is not reachable from outside the app (measured 11-23), so a group's body
# is the band between its tab bar and the next group's.
GROUP_CASES = ("tab_before", "body_new_group", "grip_move")
GRIP_OFFSET = 10.0   # points left of a group's first tab: its grip (the dotted handle)
BODY_DEPTH = 0.85    # how far down the band a "lower body" drop lands


def _tab(frames, kind):
    f = frames.get(kind + PANEL_SUFFIX + TAB_SUFFIX)
    if f is None:
        raise Refused(f"no frame for the {kind} tab")
    return f


def _below(top, nxt):
    """A point BODY_DEPTH of the way down the band from `top`'s tab bar to `nxt`'s."""
    bottom = top[1] + top[3]
    return top[0] + 60, bottom + (nxt[1] - bottom) * BODY_DEPTH


def group_case_targets(case, frames):
    """(press, release) screen points for a case, from the dock tabs' AX frames
    {tab id: (x, y, w, h)}. Refuses by name when a frame it needs is missing."""
    if case == "tab_before":
        a, sw = _tab(frames, "align"), _tab(frames, "swatches")
        return (a[0] + a[2] / 2, a[1] + a[3] / 2), (sw[0] + sw[2] * 0.25, sw[1] + sw[3] / 2)
    if case == "body_new_group":
        a, c = _tab(frames, "align"), _tab(frames, "color")
        return (a[0] + a[2] / 2, a[1] + a[3] / 2), _below(c, a)
    if case == "grip_move":
        c, ch, st = _tab(frames, "color"), _tab(frames, "character"), _tab(frames, "stroke")
        return (c[0] - GRIP_OFFSET, c[1] + c[3] / 2), _below(ch, st)
    raise Refused(f"no sheet-2 case {case!r}")


def group_case_verdict(case, before, after):
    """-> (status, detail). `before`/`after` are the right dock's groups as
    panel-name lists. The expected layout is derived from `before`."""
    if case == "tab_before":
        top = before[0]
        if "swatches" not in top or "align" in top:
            raise Refused(f"the tab case needs a top group with swatches and without align; it reads {top}")
        rest = [[p for p in g if p != "align"] for g in before[1:]]
        i = top.index("swatches")
        want = [top[:i] + ["align"] + top[i:]] + [g for g in rest if g]
    elif case == "body_new_group":
        rest = [[p for p in g if p != "align"] for g in before[1:]]
        want = [before[0], ["align"]] + [g for g in rest if g]
    elif case == "grip_move":
        want = before[1:3] + [before[0]] + before[3:]
    else:
        raise Refused(f"no sheet-2 case {case!r}")
    if after == before:
        return "FAIL", "the layout did not change (did the drag reach its drop?)"
    return ("PASS", "") if after == want else ("FAIL", f"want {want}, read {after}")


def group_line(cases):
    """cases: [(case, status, detail)] -> one line, the dock line's form."""
    if not cases:
        return "DOCKGROUPS NOT RUN"
    ok = sum(1 for c in cases if c[1] == "PASS")
    if ok == len(cases):
        return f"DOCKGROUPS {ok}/{len(cases)}"
    bad = "; ".join(f"{st} {c}: {d}" for c, st, d in cases if st != "PASS")
    return f"DOCKGROUPS RED {ok}/{len(cases)} ({bad})"


# ── THE `layers` CHECK (row 256): row 208's R1 and R4, read through the Layers
# tree with real input on the Mac test box (first read by hand in the 11-24
# slot, both A). The driver opens test_fixtures/svg/multi_layer.svg (two
# top-level layers, one shape each) in a fresh app and reads the document by
# the FIFO `read` verb and the panel selection by `state`; the verdicts below
# take those reads REDUCED by layers_reduce, and derive what they expect from
# the read taken before the act, never from a typed layout.
#   R1  a right-click on a row selects that row: right-click Background's
#       shape row after selecting Foreground, choose Duplicate; Background
#       gains one shape and no layer is added (layers.yaml row context_menu).
#   R4  "a document always has at least one layer": with every top-level
#       layer selected, Delete removes nothing (layers.yaml keyboard Delete,
#       enabled_when). Its CONTROL, run first: Delete on a selected shape row
#       removes the shape, so a refusal is not a dead key (11-24: R4 read NO
#       KEY before #1107).
LAYERS_CASES = ("R1", "R4")
LAYERS_FIXTURE = os.path.join("test_fixtures", "svg", "multi_layer.svg")


def layers_reduce(doc, psel):
    """The FIFO `read` document and `state … panel.layers.layers_panel_selection`
    reply -> {"layers": [(name, [child types])], "psel": [path, ...]}."""
    if not isinstance(psel, dict) or "panel.layers.layers_panel_selection" not in psel:
        raise Refused(f"the panel selection was not read (state reply {psel!r})")
    paths = [list(p["__path__"]) for p in psel["panel.layers.layers_panel_selection"]]
    return {"layers": [(l.get("name"), [c.get("type") for c in l.get("children", [])]) for l in doc["layers"]],
            "psel": paths}


def layers_r1_verdict(before, menu, after, target):
    """-> (status, detail). `target` is the shape row's path (Background's
    first child); `menu` is the FIFO `menu` reply read with the menu open."""
    items = {m.get("title"): m.get("enabled") for m in (menu or {}).get("menu", [])}
    if not (menu or {}).get("open") or not items:
        return "REFUSED", "no row menu was read open after the right-click"
    if "Duplicate" not in items:
        return "FAIL", f"the row menu has no Duplicate (it reads {sorted(items)})"
    if not items["Duplicate"]:
        return "FAIL", "the row menu's Duplicate is disabled"
    li = target[0]
    want = [(n, kids + [kids[target[1]]] if i == li else kids) for i, (n, kids) in enumerate(before["layers"])]
    got = after["layers"]
    if got == before["layers"]:
        return "FAIL", "the document did not change (did Duplicate run?)"
    if len(got) == len(before["layers"]) + 1:
        return "FAIL", f"a LAYER was duplicated, so the right-click did not select the row (read {got})"
    if got != want:
        return "FAIL", f"want {want}, read {got}"
    if after["psel"] != [list(target)]:
        return "FAIL", f"the panel selection after is {after['psel']}, not the right-clicked row {list(target)}"
    return "PASS", ""


def layers_r4_verdict(before, control, selected, after):
    """-> (status, detail). `control` is read after Delete on the LAST layer's
    first shape row; `selected` just before the Delete with every top-level
    layer selected (after the control was undone); `after` after that Delete."""
    n = len(before["layers"])
    if n < 2:
        return "REFUSED", f"the fixture has {n} top-level layer(s); the refusal needs two or more to mean anything"
    last, kids = before["layers"][-1]
    if control["layers"][-1] != (last, kids[1:]):
        return "FAIL", "NO KEY: Delete on a selected shape row removed nothing"
    tops = sorted(p for p in selected["psel"] if len(p) == 1)
    if tops != [[i] for i in range(n)] or selected["layers"] != before["layers"]:
        return "REFUSED", (f"the selection before Delete is {selected['psel']}, not every top-level layer "
                           "of the undone document; an empty one would pass vacuously")
    if len(after["layers"]) != n:
        return "FAIL", f"Delete removed a layer: {n} -> {len(after['layers'])}"
    if after["layers"] != before["layers"]:
        return "FAIL", f"Delete changed the document: want {before['layers']}, read {after['layers']}"
    return "PASS", ""


def layers_line(cases):
    """cases: [(case, status, detail)] -> one line, the dock line's form."""
    if not cases:
        return "LAYERS NOT RUN"
    ok = sum(1 for c in cases if c[1] == "PASS")
    if ok == len(cases):
        return f"LAYERS {ok}/{len(cases)}"
    bad = "; ".join(f"{st} {c}: {d}" for c, st, d in cases if st != "PASS")
    return f"LAYERS RED {ok}/{len(cases)} ({bad})"


TITLE_BAR_MAX = 64.0  # points; a Mac title bar (with or without a toolbar strip) is under this


def viewport_size(layout_text):
    """(width, height) of the pane viewport the app snaps against."""
    pl = json.loads(layout_text).get("pane_layout")
    if not isinstance(pl, dict):
        raise Refused("the layout read has no pane_layout, so there is no viewport to snap against")
    return float(pl["viewport_width"]), float(pl["viewport_height"])


def outside_window(win, *points):
    """None when every named screen point lies inside the window (half-open:
    the far edges are outside), or the refusal naming the first that does not
    (row 263). AX reports frames the window clips and posted events at such a
    point reach another window or nothing, so a drag there is the
    instrument's failure, never the app's: refuse before posting."""
    for name, x, y in points:
        if not (win["x"] <= x < win["x"] + win["w"] and win["y"] <= y < win["y"] + win["h"]):
            return (f"the {name} ({x:.0f}, {y:.0f}) lies outside the window "
                    f"({win['x']:.0f}, {win['y']:.0f}, {win['w']:.0f}x{win['h']:.0f}); AX reports clipped frames")
    return None


def viewport_origin(win, vw, vh, slack=2.0):
    """The Mac viewport's top-left in screen points. The pane container
    fills the window below its title bar, so it shares the window's left and
    bottom edges. Refuses when the sizes say otherwise, rather than drop at a
    point the app reads differently."""
    if abs(win["w"] - vw) > slack:
        raise Refused(f"the viewport is {vw} wide in a {win['w']} wide window; it should fill the width")
    bar = win["h"] - vh
    if bar < -slack or bar > TITLE_BAR_MAX:
        raise Refused(f"the viewport is {vh} tall in a {win['h']} tall window; that is no title bar")
    return (win["x"], win["y"] + bar)


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

    # ── sheet 2's dock drops (rows 129/132/133; row 255): the expectation is
    # DERIVED from each case's own before-read, so a non-default start still
    # reads. The PASS fixtures are the layouts read on the Mac test box 11-23.
    m129b = [["color", "swatches"], ["align", "boolean"], ["character", "paragraph"]]
    m129a = [["color", "align", "swatches"], ["boolean"], ["character", "paragraph"]]
    m132b = [["color", "swatches", "brushes"], ["align", "boolean"], ["character", "paragraph"]]
    m132a = [["color", "swatches", "brushes"], ["align"], ["boolean"], ["character", "paragraph"]]
    m133b = [["color", "align", "swatches"], ["boolean"], ["character", "paragraph"], ["stroke", "properties"]]
    m133a = [["boolean"], ["character", "paragraph"], ["color", "align", "swatches"], ["stroke", "properties"]]
    check("sheet 2: the 11-23 tab drop reads PASS", group_case_verdict("tab_before", m129b, m129a)[0] == "PASS")
    check("sheet 2: the 11-23 body drop reads PASS", group_case_verdict("body_new_group", m132b, m132a)[0] == "PASS")
    check("sheet 2: the 11-23 grip move reads PASS", group_case_verdict("grip_move", m133b, m133a)[0] == "PASS")
    check("sheet 2: a tab appended at the end (the sheet's B) is a FAIL",
          group_case_verdict("tab_before", m129b, [["color", "swatches", "align"], ["boolean"], ["character", "paragraph"]])[0] == "FAIL")
    check("sheet 2: a body drop that joins the group (B) is a FAIL",
          group_case_verdict("body_new_group", m132b, [["color", "swatches", "brushes", "align"], ["boolean"], ["character", "paragraph"]])[0] == "FAIL")
    check("sheet 2: a group moved one place short is a FAIL",
          group_case_verdict("grip_move", m133b, [["boolean"], ["color", "align", "swatches"], ["character", "paragraph"], ["stroke", "properties"]])[0] == "FAIL")
    for case, b in (("tab_before", m129b), ("body_new_group", m132b), ("grip_move", m133b)):
        st, why = group_case_verdict(case, b, b)
        check(f"sheet 2: an unchanged layout is a FAIL that says so ({case})", st == "FAIL" and "did not change" in why)
    check("sheet 2: a start without Align beside Swatches refuses the tab case",
          refused(lambda: group_case_verdict("tab_before", [["color"], ["align"]], [["align", "color"]]), "swatches"))
    check("sheet 2: an unknown case refuses", refused(lambda: group_case_verdict("wiggle", m129b, m129a), "wiggle"))
    fr = {"align_panel_content_tab": (1300, 390, 44, 20), "swatches_panel_content_tab": (1340, 157, 60, 20),
          "color_panel_content_tab": (1280, 157, 50, 20), "character_panel_content_tab": (1280, 470, 70, 20),
          "stroke_panel_content_tab": (1280, 780, 50, 20)}
    (px, py), (rx, ry) = group_case_targets("tab_before", fr)
    check("sheet 2: the tab drop presses Align's centre", (px, py) == (1322, 400))
    check("sheet 2: the tab drop releases on the LEFT half of Swatches", 1340 < rx < 1370 and 157 < ry < 177)
    (px, py), (rx, ry) = group_case_targets("body_new_group", fr)
    check("sheet 2: the body drop releases below the top tab bar and above Align's", 177 < ry < 390 and ry > (177 + 390) / 2)
    (px, py), (rx, ry) = group_case_targets("grip_move", fr)
    check("sheet 2: the grip press is LEFT of the first tab, on its row", px < 1280 and 157 < py < 177)
    check("sheet 2: the grip move releases in the third group's lower body", 490 < ry < 780 and ry > (490 + 780) / 2)
    check("sheet 2: the line counts PASSes", group_line([("tab_before", "PASS", ""), ("grip_move", "PASS", "")]) == "DOCKGROUPS 2/2")
    check("sheet 2: a FAIL reddens the line and names the case",
          group_line([("tab_before", "PASS", ""), ("grip_move", "FAIL", "x")]) == "DOCKGROUPS RED 1/2 (FAIL grip_move: x)")
    check("sheet 2: no cases is NOT RUN, never a pass", group_line([]) == "DOCKGROUPS NOT RUN")
    check("sheet 2: a missing tab frame refuses by name",
          refused(lambda: group_case_targets("grip_move", {k: v for k, v in fr.items() if not k.startswith("stroke")}), "stroke"))

    # ── the `layers` check (row 256). Every fixture is a line the 11-24 slot
    # read on the Mac test box (slot-1124g/v4b/slot.json, 208-R1 A, 208-R4 A),
    # reduced by layers_reduce exactly as the driver reduces a live read.
    def doc(layers, psel=()):
        return layers_reduce({"layers": [{"name": n, "children": [{"type": t} for t in kids]} for n, kids in layers]},
                             {"panel.layers.layers_panel_selection": [{"__path__": list(p)} for p in psel]})
    L0 = [("Background", ["rect"]), ("Foreground", ["ellipse"])]
    d0 = doc(L0)
    check("layers: the reduction keeps names, child types and panel paths",
          d0 == {"layers": [("Background", ["rect"]), ("Foreground", ["ellipse"])], "psel": []}
          and doc(L0, [(0, 0)])["psel"] == [[0, 0]])
    check("layers: an unread panel selection refuses by name",
          refused(lambda: layers_reduce({"layers": []}, None), "panel selection"))
    menu = {"menu": [{"enabled": False, "title": "Options for Layer..."}, {"enabled": True, "title": "Duplicate"},
                     {"enabled": True, "title": "Delete Selection"}], "open": True}
    r1_after = doc([("Background", ["rect", "rect"]), ("Foreground", ["ellipse"])], [(0, 0)])
    check("layers R1: the slot's A reading PASSES", layers_r1_verdict(d0, menu, r1_after, (0, 0)) == ("PASS", ""))
    st, why = layers_r1_verdict(d0, menu, doc([("Background", ["rect"]), ("Foreground", ["ellipse"]), ("Foreground", ["ellipse"])], [(1,)]), (0, 0))
    check("layers R1: a duplicated LAYER (the right-click left the old selection) FAILS and says so",
          st == "FAIL" and "did not select the row" in why)
    check("layers R1: an unchanged document FAILS by name",
          layers_r1_verdict(d0, menu, doc(L0, [(0, 0)]), (0, 0))[0] == "FAIL")
    check("layers R1: no menu read is REFUSED, never a pass",
          layers_r1_verdict(d0, {"menu": [], "open": False}, r1_after, (0, 0))[0] == "REFUSED")
    check("layers R1: a disabled Duplicate is a FAIL naming it",
          layers_r1_verdict(d0, {"menu": [{"enabled": False, "title": "Duplicate"}], "open": True}, r1_after, (0, 0))
          == ("FAIL", "the row menu's Duplicate is disabled"))
    check("layers R1: the selection after must be the right-clicked row",
          layers_r1_verdict(d0, menu, doc([("Background", ["rect", "rect"]), ("Foreground", ["ellipse"])], [(1,)]), (0, 0))[0] == "FAIL")
    # R4: the control (a shape row + Delete removes the shape) proves the key
    # reaches the tree; only then does "every layer selected + Delete leaves the
    # layers" mean the refusal, not a dead key (11-24: R4 read NO KEY first).
    ctl = doc([("Background", ["rect"]), ("Foreground", [])])
    both = doc(L0, [(0,), (1,)])
    check("layers R4: the slot's A reading PASSES", layers_r4_verdict(d0, ctl, both, doc(L0, [(0,), (1,)])) == ("PASS", ""))
    check("layers R4: a control that removed nothing is NO KEY, a FAIL",
          layers_r4_verdict(d0, d0, both, doc(L0, [(0,), (1,)])) == ("FAIL", "NO KEY: Delete on a selected shape row removed nothing"))
    check("layers R4: a selection that is not every top-level layer is REFUSED (an empty one would pass vacuously)",
          layers_r4_verdict(d0, ctl, doc(L0, [(0,)]), doc(L0, [(0,)]))[0] == "REFUSED"
          and layers_r4_verdict(d0, ctl, doc(L0), doc(L0))[0] == "REFUSED")
    st, why = layers_r4_verdict(d0, ctl, both, doc([("Background", ["rect"])]))
    check("layers R4: a deleted layer FAILS and names the count", st == "FAIL" and "2 -> 1" in why)
    check("layers R4: the case needs two layers or more, else it cannot test the refusal",
          layers_r4_verdict(doc([("Only", ["rect"])]), ctl, both, both)[0] == "REFUSED")
    check("layers: the line counts PASSes", layers_line([("R1", "PASS", ""), ("R4", "PASS", "")]) == "LAYERS 2/2")
    check("layers: a FAIL reddens the line and names the case",
          layers_line([("R1", "PASS", ""), ("R4", "FAIL", "x")]) == "LAYERS RED 1/2 (FAIL R4: x)")
    check("layers: a REFUSED is not a pass", layers_line([("R1", "PASS", ""), ("R4", "REFUSED", "y")]).startswith("LAYERS RED 1/2"))
    check("layers: no cases is NOT RUN, never a pass", layers_line([]) == "LAYERS NOT RUN")
    check("layers: the cases are R1 then R4", LAYERS_CASES == ("R1", "R4"))
    # The app persists its dock layout (UserDefaults `jas_layout:Workspace`), so a
    # fresh PROCESS is not a fresh STATE: the 11-23 nightly left gradient and
    # opacity appended to the dock, and the next script started from that.
    # Level 1 starts every script from a fresh store, so the open act (always
    # the first, built unconditionally) asks the driver to reset the workspace.
    check("the open act asks for a reset workspace", acts[0] == ("open", "s.svg", True))
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
    # A combo_box in JasSwift is a text field beside the menu of its options
    # (YamlPanelBodyView.renderComboBox, since 2026-11-09), as the Rust web
    # combo is an input with a datalist: a person can type any value, so a
    # commit is TYPED, option or not, and carries no menu label.
    combo = {"content": [{"id": "angle", "type": "combo_box",
                          "options": [-45, 0, 45, 0.5, {"value": 150, "label": "150%"}]}]}
    cstep = {"panel": "gradient_panel_content", "widget": "angle", "event": "commit", "value": "45"}
    for v in ("45", "-45", "0.5", "150", "30"):
        a = plan(dict(base, steps=[dict(cstep, value=v), read]), mb, combo)[2]
        check(f"a combo commit of {v!r} is typed (no label), option or not",
              a[7] is None and a[6] == v)
    check("a click carries no label", acts[4][7] is None)
    # An icon_select (paragraph.yaml pg_bullets) opens a POPOVER, not a menu:
    # its options are AXButtons described "<glyph>, <label>" with no
    # AXIdentifier (row 83, read on the Mac test box 11-23). So its commit carries the
    # option label AND the widget type, and the driver matches the label as a
    # description SUFFIX after ", " (so "Circle" never picks "Open Circle").
    icon = {"content": [{"id": "pg_bullets", "type": "icon_select",
                         "options": [{"value": "", "glyph": "\u2014", "label": "None"},
                                     {"value": "bullet-disc", "glyph": "\u2022", "label": "Disc"},
                                     {"value": "bullet-open-circle", "glyph": "\u25cb", "label": "Open Circle"}]}]}
    istep = {"panel": "paragraph_panel_content", "widget": "pg_bullets", "event": "commit", "value": "bullet-disc"}
    ia = plan(dict(base, steps=[istep, read]), mb, icon)[2]
    check("an icon_select commit carries its option label", ia[7] == "Disc")
    check("an icon_select commit carries its widget type", ia[8] == "icon_select")
    check("an icon_select's empty value is its None option",
          plan(dict(base, steps=[dict(istep, value=""), read]), mb, icon)[2][7] == "None")
    check("an icon_select value that is not an option is refused",
          refused(lambda: plan(dict(base, steps=[dict(istep, value="nope"), read]), mb, icon), "not an option"))
    check("a select commit carries its widget type", plan(dict(base, steps=[sstep, read]), mb, sel)[2][8] == "select")
    check("a panel act with no spec carries no widget type", acts[4][8] is None)
    for desc, label, want in (("\u2022, Disc", "Disc", True), ("\u2014, None", "None", True),
                              ("\u25cb, Open Circle", "Open Circle", True), ("\u25cb, Open Circle", "Circle", False),
                              ("\u2022, Disc", "disc", False), ("Disc", "Disc", False), ("", "Disc", False),
                              (None, "Disc", False)):
        check(f"icon option {desc!r} matches {label!r}: {want}", icon_option_matches(desc, label) is want)
    check("modifiers are carried", plan(dict(base, steps=[dict(press, shift=True), read]), mb)[2][5] == ("shift",))
    check("no read is refused", refused(lambda: plan(dict(base, steps=[press]), mb), "without a read"))
    check("a tree read is refused", refused(lambda: plan(dict(base, steps=[{"read": "tree"}]), mb), "reads 'tree'"))
    check("meta is refused", refused(lambda: plan(dict(base, steps=[{"key": "Z", "meta": True}, read]), mb), "meta"))
    check("a gesture after a panel step is planned in script order",
          [a[0] for a in plan(dict(base, steps=[pan, press, rel, read]), mb)]
          == ["open", "tool", "panel", "pointer", "pointer", "read"])
    check("a key after a menu step is planned in script order",
          [a[0] for a in plan(dict(base, steps=[{"menu": "menu_group"}, {"key": "Z"}, read]), mb)]
          == ["open", "tool", "menu", "key", "read"])
    check("an odd unit is refused", refused(lambda: plan(dict(base, steps=[dict(press, x=37), read]), mb), "even"))
    # A key this channel does not deliver is refused BY NAME, never dropped: a
    # dropped `hold_ms` runs a hold as a click, and a dropped `alt` on a panel
    # step runs an Alt-click as a click, and either reads as measured.
    for name, st, needle in (
        ("a press's hold_ms", dict(press, hold_ms=400), "hold_ms"),
        ("an unknown pointer key", dict(press, bogus=1), "bogus"),
        ("an unknown key-step key", {"key": "Z", "repeat": 2}, "repeat"),
        ("a panel step's alt", dict(pan, alt=True), "alt"),
        ("a panel step's row", dict(pan, row=[0]), "row"),
        ("a panel step's at", dict(pan, at=[0, 1]), "at"),
        ("a panel step's hold_ms", dict(pan, hold_ms=400), "hold_ms"),
        ("a menu step's extra key", {"menu": "menu_group", "shift": True}, "shift"),
        ("a read step's extra key", {"read": "document", "window": {"w": 1, "h": 1}}, "window"),
    ):
        check(f"{name} is refused by name", refused(lambda st=st: plan(dict(base, steps=[st, read]), mb), needle))
    check("a refusal names the step kind's delivered keys",
          refused(lambda: plan(dict(base, steps=[dict(press, hold_ms=400), read]), mb), "delivers only"))
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
    # THE OWNER'S CLAIM (council 2026-11-24): the test box is free unless its
    # owner claims it, and a relay mirrors that claim onto the box with a
    # heartbeat. Each arm differs from its neighbour in ONE input.
    check("no claim and a fresh relay: go", claim_refusal(None, 10.0) is None)
    check("a claim stops the driver",
          "the owner has claimed this box" in (claim_refusal("", 10.0) or ""))
    check("a claim stops it even with a stale relay",
          "the owner has claimed this box" in (claim_refusal("", 10_000.0) or ""))
    check("no heartbeat is unreadable, never free",
          "no relay heartbeat" in (claim_refusal(None, None) or ""))
    check("a stale heartbeat is unreadable, never free",
          "relay last wrote 121 s ago" in (claim_refusal(None, 121.0) or ""))
    check("the heartbeat at the bound is fresh", claim_refusal(None, CLAIM_RELAY_MAX_AGE_S) is None)
    check("a heartbeat a little in the future is fresh", claim_refusal(None, -2.0) is None)
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        cf = os.path.join(td, "CLAIM")
        env = {"JAS_CLAIM_FILE": cf}
        check("the reader: no files at all is refused (no heartbeat)",
              "no relay heartbeat" in (claim_check(env, 1000.0) or ""))
        with open(cf + ".relay", "w", encoding="utf-8", newline="") as f:
            f.write("")
        os.utime(cf + ".relay", (1.0, 990.0))  # atime differs, so the age must come from the mtime
        check("the reader: a fresh heartbeat and no claim goes", claim_check(env, 1000.0) is None)
        check("the reader: the heartbeat's AGE is read from its mtime",
              "relay last wrote 210 s ago" in (claim_check(env, 1200.0) or ""))
        with open(cf, "w", encoding="utf-8", newline="") as f:
            f.write("his\n")
        check("the reader: a claim file present stops it", "claimed" in (claim_check(env, 1000.0) or ""))
        check("the reader: the check off is named, never silent",
              claim_check({"JAS_CLAIM_FILE": "none"}, 1000.0) is None
              and claim_check_off({"JAS_CLAIM_FILE": "none"}))
        check("the reader: the default is ON", not claim_check_off({}))
        check("the reader: the default path is the box's watch dir",
              claim_path({}) == os.path.expanduser(os.path.join("~", ".fleet", "watch", "CONSOLE-CLAIM")))
    # The guard consults the claim before EVERY act: a claim landing mid-run
    # aborts at the next act (run_guarded's contract, driven with the claim's words).
    done2 = []
    readings2 = iter([None, claim_refusal("", 5.0)])
    check("a claim landing mid-run aborts at the next act",
          refused(lambda: run_guarded(acts5, lambda: next(readings2), done2.append), "claimed this box before act 1 (tool)")
          and [a[0] for a in done2] == ["open"])
    # Row 263: a drag's press and drop must lie inside the window, or the
    # reading is the instrument's, never the app's (AX reports frames the
    # window clips). Each arm moves ONE point across ONE edge.
    W = {"x": 100.0, "y": 50.0, "w": 800.0, "h": 600.0}
    check("both points inside the window: go", outside_window(W, ("press", 150, 100), ("drop", 850, 640)) is None)
    check("a press below the window is refused by name",
          "press (150, 651) lies outside the window" in (outside_window(W, ("press", 150, 651), ("drop", 400, 300)) or ""))
    check("a drop past the right edge is refused by name",
          "drop (901, 300)" in (outside_window(W, ("press", 150, 100), ("drop", 901, 300)) or ""))
    check("a point above the window is refused", outside_window(W, ("press", 150, 49), ("drop", 400, 300)) is not None)
    check("a point left of the window is refused", outside_window(W, ("press", 99, 100), ("drop", 400, 300)) is not None)
    check("the far edge itself is outside (half-open)", outside_window(W, ("press", 900, 100)) is not None)
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

    # The minted-id law, Rust's arms (ffi_script_replay.rs) one for one:
    # boolean.divide gives each fragment a FRESH id, so its expected writes
    # "<minted>" there; the read-back must carry a fresh 8-character base-36 id.
    el = lambda i: '{"id":"%s","type":"polygon"}' % i
    mdoc = lambda a, b: '{"layers":[%s,%s]}' % (el(a), el(b))
    mwant = mdoc(MINTED, MINTED)
    check("minted: two fresh ids are accepted as the token", accept_minted_ids(mdoc("l006y7om", "7xkxpudp"), mwant) == mwant)
    check("minted: no token, the read-back is untouched",
          accept_minted_ids(mdoc("l006y7om", "7xkxpudp"), mdoc("aaaaaaaa", "bbbbbbbb")) == mdoc("l006y7om", "7xkxpudp"))
    mixed_ids = mdoc("keepthis", MINTED)
    check("minted: a literal id beside a token is left for the byte comparison",
          accept_minted_ids(mdoc("keepthis", "7xkxpudp"), mixed_ids) == mixed_ids
          and accept_minted_ids(mdoc("changed1", "7xkxpudp"), mixed_ids) != mixed_ids)
    check("minted: one id stamped twice is refused", refused(lambda: accept_minted_ids(mdoc("l006y7om", "l006y7om"), mwant), "carried twice"))
    check("minted: an upper-case id is refused", refused(lambda: accept_minted_ids(mdoc("L006Y7OM", "7xkxpudp"), mwant), "not an 8-character"))
    check("minted: a 7-character id is refused", refused(lambda: accept_minted_ids(mdoc("l006y7o", "7xkxpudp"), mwant), "not an 8-character"))
    check("minted: a missing id is refused by count",
          refused(lambda: accept_minted_ids('{"layers":[%s,{"type":"polygon"}]}' % el("l006y7om"), mwant),
                  "carries 1 ids where the expected names 2"))

    # read_back: both laws in one read, the artboard first (its id would
    # otherwise be counted among the minted ids and the counts would differ).
    rb_want = '{"layers":[%s,%s]}' % (el(MINTED), el("keepthis"))
    rb_got = '{"artboards":[%s],"layers":[%s,%s]}' % (ab("pfj2j82z", "Artboard 1"), el("l006y7om"), el("keepthis"))
    check("read_back: the open's artboard AND a fresh id, read as the expected", read_back(rb_got, rb_want) == rb_want)

    # The launch environment is refused BY NAME before anything drives the
    # console (a Mac run box, 2026-11-06: JAS_APP without JAS_TITLE crashed in Popen).
    ok = {"JAS_FIFO": "/tmp/f", "JAS_TITLE": "JasHarness", "JAS_APP": "/x/Jas"}
    check("env: a full launch environment passes", launch_env_problem(ok) is None)
    check("env: no JAS_APP (an app already open) passes with a FIFO and title",
          launch_env_problem({"JAS_FIFO": "/tmp/f", "JAS_TITLE": "T"}) is None)
    check("env: JAS_APP without JAS_TITLE is refused by name",
          "JAS_TITLE" in (launch_env_problem({"JAS_FIFO": "/tmp/f", "JAS_APP": "/x/Jas"}) or ""))
    check("env: no JAS_FIFO is refused by name",
          "JAS_FIFO" in (launch_env_problem({"JAS_TITLE": "T", "JAS_APP": "/x/Jas"}) or ""))
    check("env: an EMPTY JAS_TITLE is refused like a missing one",
          "JAS_TITLE" in (launch_env_problem(dict(ok, JAS_TITLE="")) or ""))

    # The receipt (O100): one UI-NIGHTLY v1 line, the form the board parses.
    corpus = ["a.json", "b.json", "c.json"]
    D, H = "2026-11-06T12:00:00-08:00", "0123abcd"
    check("receipt: all pass over the corpus is GREEN, scope=full",
          receipt_line({"a.json": "PASS", "b.json": "PASS", "c.json": "PASS"}, corpus, H, D)
          == "UI-NIGHTLY v1 suite=mac.live verdict=GREEN items=3/3 panels=- head=0123abcd scope=full date=" + D)
    # Distinct counts (2 FAIL, 1 REFUSED), so a swap of the two cannot pass.
    check("receipt: FAILs and REFUSEDs are RED, counted apart, items counts passes",
          receipt_line({"a.json": "FAIL", "b.json": "FAIL", "c.json": "REFUSED", "d.json": "PASS"},
                       corpus + ["d.json"], H, D)
          == "UI-NIGHTLY v1 suite=mac.live verdict=RED(fail=2 refused=1) items=1/4 panels=- head=0123abcd scope=full date=" + D)
    check("receipt: a run refused before any script is NOT RUN, over the whole corpus",
          receipt_line({}, corpus, H, D, not_run="the screen is locked")
          == "UI-NIGHTLY v1 suite=mac.live verdict=NOT RUN(the screen is locked) items=0/3 panels=- head=0123abcd scope=full date=" + D)
    check("receipt: a subset of the corpus is scope=partial, never full",
          " scope=partial " in receipt_line({"a.json": "PASS"}, corpus, H, D))
    check("the suite token is the caller's (default mac.live)",
          " suite=web.live " in receipt_line({"a.json": "PASS"}, corpus, H, D, suite="web.live")
          and " suite=mac.live " in receipt_line({"a.json": "PASS"}, corpus, H, D))
    check("receipt: a reason cannot close the parenthesis early",
          "verdict=NOT RUN(x] y) items" in receipt_line({}, corpus, H, D, not_run="x) y"))
    try:
        receipt_line({}, corpus, H, D)
        check("receipt: no outcome and no refusal is refused, never GREEN 0/0", False)
    except ValueError:
        check("receipt: no outcome and no refusal is refused, never GREEN 0/0", True)
    try:
        receipt_line({"zzz.json": "PASS"}, corpus, H, D)
        check("receipt: a script outside the corpus is refused by name", False)
    except ValueError as e:
        check("receipt: a script outside the corpus is refused by name", "zzz.json" in str(e))
    try:
        receipt_line({"a.json": "OK"}, corpus, H, D)
        check("receipt: an unknown outcome is refused", False)
    except ValueError:
        check("receipt: an unknown outcome is refused", True)

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

    # The dock check (R1-2 web, row 89 Mac): one reader and one verdict for
    # both channels. The band comes from the Rust source; each drop point
    # must classify to its own edge under the app's rule (left, then right,
    # then bottom), checked against a mirror of is_near_edge.
    band = snap_distance()
    check(f"SNAP_DISTANCE derives from workspace.rs as 20 (read {band})", band == 20.0)

    def near_edge(x, y, vw, vh):
        return "left" if x <= band else "right" if x >= vw - band else "bottom" if y >= vh - band else None
    for vw, vh in ((1400, 900), (1200, 800)):
        for e in DOCK_EDGES:
            px, py = dock_point(e, vw, vh, band)
            check(f"the {e} drop point classifies to {e} in {vw}x{vh}", near_edge(px, py, vw, vh) == e)
            check(f"the {e} drop point is inside {vw}x{vh}", 0 < px < vw and 0 < py < vh)
    check("a top drop is refused: the app has no top edge", refused(lambda: dock_point("top", 1400, 900, band), "top"))
    # The layout reader, over the corpus's own layout (bytes, never typed).
    wo = os.path.join(REPO, "test_fixtures", "workspace_operations")
    lay = open(os.path.join(wo, "panel_detach_panel_snap_bottom.json"), encoding="utf-8").read().strip()
    check("swatches reads as anchored at bottom in the snap fixture", dock_edge_of(lay, "swatches") == "bottom")
    check("stroke reads as anchored at right in the snap fixture", dock_edge_of(lay, "stroke") == "right")
    check("a panel in no anchored dock reads None", dock_edge_of(lay, "gradient") is None)
    # The two-docks mutant puts swatches into the right dock's Color group too.
    # It anchors on the group's OPENING, never its whole list: the list is the
    # spec's default group, which grew (row 160 added brushes) and left a
    # whole-list anchor matching nothing.
    check("the two-docks anchor occurs exactly once", lay.count('"panels":["color"') == 1)
    for bad, why in ((lay.replace('"anchored":', '"anchoredX":', 1), "no anchored member"),
                     (lay.replace('"panels":["color"', '"panels":["color","swatches"', 1), "two docks")):
        check(f"the {why} mutant changed the layout", bad != lay)
        check(f"a layout with {why} is refused", refused(lambda: dock_edge_of(bad, "swatches"), "anchored"))
    fl = open(os.path.join(wo, "panel_detach_panel.json"), encoding="utf-8").read().strip()
    check("floats() reads the detach fixture: swatches floats, stroke does not",
          floats(fl, "swatches") and not floats(fl, "stroke"))
    check("floats() reads a snapped panel as not floating", not floats(lay, "swatches"))
    check("two passing dock cases read DOCK 2/2",
          dock_line([("stroke", "left", "PASS", ""), ("layers", "bottom", "PASS", "")]) == "DOCK 2/2")
    check("a failing dock case names itself",
          dock_line([("stroke", "left", "PASS", ""), ("layers", "bottom", "FAIL", "x")]) == "DOCK RED 1/2 (FAIL layers->bottom: x)")
    check("no dock case is NOT RUN, never 0/0", dock_line([]) == "DOCK NOT RUN")
    check("a float case names itself as ->float", dock_line([("align", None, "FAIL", "x")]) == "DOCK RED 0/1 (FAIL align->float: x)")
    check("the dock cases cover left, bottom and a float, with distinct panels",
          len({c[0] for c in DOCK_CASES}) == len(DOCK_CASES) and {c[1] for c in DOCK_CASES} == {"left", "bottom", None})
    check("a case passes through a snap band and drops outside it (WORKSPACE.md: a DROP near an edge snaps)",
          any(c[1] is None and c[2] in DOCK_EDGES for c in DOCK_CASES))
    check("the edge-dock ids are the web DOM ids the Swift app also carries",
          [edge_dock_id(e) for e in DOCK_EDGES] == ["jas-edge-dock-left", "jas-edge-dock-bottom"])
    # The start condition: every case starts with its panel in the right dock.
    check("stroke starts in the right dock of the snap fixture", dock_start_refusal(lay, "stroke") is None)
    check("swatches at bottom is refused as a start", "swatches" in (dock_start_refusal(lay, "swatches") or ""))
    # The verdict, over the two fixtures: lay has swatches snapped bottom and
    # fl has it floating, so each direction of each case is a real layout.
    none = {e: 0 for e in DOCK_EDGES}
    bottom_drawn = dict(none, bottom=1)
    check("an unchanged layout FAILS by name", dock_verdict(lay, lay, "swatches", "bottom", bottom_drawn)[0] == "FAIL"
          and "did not change" in dock_verdict(lay, lay, "swatches", "bottom", bottom_drawn)[1])
    check("swatches snapped bottom and drawn there PASSES", dock_verdict(fl, lay, "swatches", "bottom", bottom_drawn) == ("PASS", ""))
    v = dock_verdict(fl, lay, "swatches", "bottom", none)
    check("the engine half alone is not a PASS (the bottom dock draws no tab)", v[0] == "FAIL" and "jas-edge-dock-bottom" in v[1])
    v = dock_verdict(fl, lay, "swatches", "bottom", dict(none, bottom=2))
    check("two drawn copies FAIL", v[0] == "FAIL" and "2 copies" in v[1])
    v = dock_verdict(fl, lay, "swatches", "left", dict(none, left=1))
    check("anchored at the wrong edge FAILS and names the edge read", v[0] == "FAIL" and "'bottom'" in v[1])
    check("a float case PASSES on a floating panel no edge dock draws", dock_verdict(lay, fl, "swatches", None, none) == ("PASS", ""))
    v = dock_verdict(lay, fl, "swatches", None, dict(none, left=1))
    check("a float case FAILS while an edge dock still draws the tab", v[0] == "FAIL" and "still draws" in v[1])
    v = dock_verdict(fl, lay, "swatches", None, none)
    check("a float case FAILS on a snapped panel", v[0] == "FAIL" and "'bottom'" in v[1])
    hidden = lay.replace('"panels":["swatches"]', '"panels":[]', 1)
    check("the hidden mutant changed the layout", hidden != lay)
    v = dock_verdict(fl, hidden, "swatches", None, none)
    check("a float case FAILS on a panel in no dock at all", v[0] == "FAIL" and "no floating dock" in v[1])
    # The Mac viewport: the pane container fills the window below its title
    # bar, so its origin is the window's bottom-left minus the viewport height.
    sized = lay.replace('"pane_layout":null', '"pane_layout":{"viewport_height":772.0,"viewport_width":1200.0}', 1)
    check("the sized mutant changed the layout", sized != lay)
    check("the viewport size reads from pane_layout", viewport_size(sized) == (1200.0, 772.0))
    check("a null pane_layout is refused", refused(lambda: viewport_size(lay), "pane_layout"))
    win = {"x": 100.0, "y": 50.0, "w": 1200.0, "h": 800.0}
    check("the viewport sits under a 28 pt title bar", viewport_origin(win, 1200.0, 772.0) == (100.0, 78.0))
    check("a viewport narrower than its window is refused", refused(lambda: viewport_origin(win, 1000.0, 772.0), "wide"))
    check("a viewport taller than its window is refused", refused(lambda: viewport_origin(win, 1200.0, 900.0), "tall"))
    check("a viewport far shorter than its window is refused (not under a title bar)",
          refused(lambda: viewport_origin(win, 1200.0, 500.0), "tall"))

    # The toolbar forms (TESTING.md, row 50): a toolbar step, a state read,
    # a dialog read. Each refusal arm names the field it refuses.
    SK = {"active_tool", "fill_on_top"}
    tb = dict(base, spec="workspace/layout.yaml", expected_state_json={"active_tool": "selection"},
              expected_dialog="arrow_alternates")
    hold = {"panel": "toolbar_pane", "widget": "btn_arrow_slot", "event": "press", "hold_ms": 400}
    click = {"panel": "toolbar_pane", "widget": "btn_arrow_slot", "event": "press"}
    rst = {"read": "state", "keys": ["active_tool"]}
    rdl = {"read": "dialog"}
    lay = {"tool_grid": [{"id": "btn_arrow_slot"}]}
    ta = plan(dict(tb, steps=[hold, rst, rdl]), mb, lay, state_keys=SK)
    check("a held toolbar press plans as a toolbar act carrying its hold",
          ta[2] == ("toolbar", "btn_arrow_slot", 400))
    check("a state read carries its keys and its expected, canonical",
          ta[3] == ("read", "state", ("active_tool",), '{"active_tool":"selection"}'))
    check("a dialog read carries its expected id", ta[4] == ("read", "dialog", "arrow_alternates"))
    tc = plan(dict(tb, expected_dialog=None, steps=[click, rst, rdl]), mb, lay, state_keys=SK)
    check("a press with no hold_ms plans as a hold of 0 (a click)", tc[2] == ("toolbar", "btn_arrow_slot", 0))
    check("a dialog read can expect none open", tc[4] == ("read", "dialog", None))
    check("a toolbar step's event is press",
          refused(lambda: plan(dict(tb, steps=[dict(click, event="click"), rst]), mb, lay, state_keys=SK), "press"))
    for bad in (0, -5, 2.5, "400", True):
        check(f"hold_ms {bad!r} is refused",
              refused(lambda: plan(dict(tb, steps=[dict(hold, hold_ms=bad), rst]), mb, lay, state_keys=SK), "hold_ms"))
    check("a slot the layout does not declare is refused",
          refused(lambda: plan(dict(tb, steps=[dict(hold, widget="btn_nope"), rst]), mb, lay, state_keys=SK), "btn_nope"))
    check("a toolbar step carrying a key it does not deliver is refused",
          refused(lambda: plan(dict(tb, steps=[dict(hold, value=1), rst]), mb, lay, state_keys=SK), "value"))
    check("a state key state.yaml does not declare is refused by name",
          refused(lambda: plan(dict(tb, expected_state_json={"no_such": 1}, steps=[{"read": "state", "keys": ["no_such"]}]),
                               mb, lay, state_keys=SK), "no_such, which workspace/state.yaml does not declare"))
    for ks in ([], ["active_tool", "active_tool"], "active_tool", None):
        check(f"state keys {ks!r} are refused",
              refused(lambda: plan(dict(tb, steps=[{"read": "state", "keys": ks}]), mb, lay, state_keys=SK), "keys"))
    nost = {k: v for k, v in tb.items() if k != "expected_state_json"}
    check("a state read with no expected_state_json is refused",
          refused(lambda: plan(dict(nost, steps=[rst]), mb, lay, state_keys=SK), "expected_state_json"))
    check("an expected_state_json naming a key the read does not is refused",
          refused(lambda: plan(dict(tb, expected_state_json={"active_tool": "x", "fill_on_top": True}, steps=[rst]),
                               mb, lay, state_keys=SK), "expected_state_json"))
    nodl = {k: v for k, v in tb.items() if k != "expected_dialog"}
    check("a dialog read with no expected_dialog is refused",
          refused(lambda: plan(dict(nodl, steps=[rdl]), mb, lay, state_keys=SK), "expected_dialog"))
    check("a dialog read carrying keys is refused",
          refused(lambda: plan(dict(tb, steps=[dict(rdl, keys=["a"])]), mb, lay, state_keys=SK), "keys"))
    check("canonical state sorts keys and drops whitespace",
          canonical_state('{ "b": 1, "a": "x" }') == '{"a":"x","b":1}')
    check("the shipped state.yaml declares active_tool", "active_tool" in load_state_keys())
    check("a state read's FIFO command names its keys",
          fifo_read_command(("read", "state", ("active_tool", "fill_on_top"), "{}"), "/o")
          == "state /o active_tool fill_on_top")
    check("a dialog read's FIFO command", fifo_read_command(("read", "dialog", None), "/o") == "dialog /o")
    check("a document read's FIFO command is unchanged", fifo_read_command(("read", "document"), "/o") == "read /o")
    sact = ("read", "state", ("active_tool",), '{"active_tool":"selection"}')
    check("a state read passes on the expected, whatever its spacing",
          compare_read(sact, '{ "active_tool" : "selection" }', None)[0])
    check("a state read fails on another tool", not compare_read(sact, '{"active_tool":"partial_selection"}', None)[0])
    dact = ("read", "dialog", "arrow_alternates")
    check("a dialog read passes on the expected id", compare_read(dact, '{"dialog":"arrow_alternates"}', None)[0])
    check("a dialog read fails on none open", not compare_read(dact, '{"dialog":null}', None)[0])
    check("a dialog read expecting none passes on null", compare_read(("read", "dialog", None), '{"dialog":null}', None)[0])
    check("a dialog read expecting none fails on an open flyout",
          not compare_read(("read", "dialog", None), '{"dialog":"arrow_alternates"}', None)[0])
    check("a dialog read of the wrong shape is refused",
          refused(lambda: compare_read(dact, '"arrow_alternates"', None), "dialog read"))

    # ── the locked route (row 250) ──
    mv = {"kind": "move", "x": 48, "y": 24, "dragging": True}
    def locked(steps):
        return locked_acts(plan(dict(base, steps=steps), mb), "t")
    def lk(steps):
        try:
            return locked(steps)
        except Refused:
            return None
    la = lk([press, mv, rel, read])
    check("a locked run folds a pointer run into ONE gesture",
          la is not None and [a[0] for a in la] == ["open", "tool", "gesture", "read"])
    check("the gesture carries the steps in document units, dragging only on the move",
          la is not None and la[2][1] == [{"kind": "press", "x": 36, "y": 18},
                                          {"kind": "move", "x": 48, "y": 24, "dragging": True},
                                          {"kind": "release", "x": 36, "y": 18}])
    lb = lk([press, rel, read, press, rel, read])
    check("a read between two runs makes two gestures",
          lb is not None and [a[0] for a in lb] == ["open", "tool", "gesture", "read", "gesture", "read"])
    ls = lk([dict(press, shift=True), dict(mv, alt=True), rel, read])
    check("shift and alt ride on their own steps",
          ls is not None and ls[2][1][0].get("shift") is True and ls[2][1][1].get("alt") is True
          and "alt" not in ls[2][1][0] and "shift" not in ls[2][1][1])
    check("every gesture step carries only FifoGesture's fields",
          ls is not None and all(set(st) <= set(GESTURE_FIELDS) for st in ls[2][1]))
    check("a locked ctrl pointer step is refused by name",
          refused(lambda: locked([dict(press, ctrl=True), rel, read]), "ctrl"))
    check("a locked shift on a move that does not drag is refused by name",
          refused(lambda: locked([dict(mv, dragging=False, shift=True), read]), "does not drag"))
    check("a locked key step is refused by name",
          refused(lambda: locked([{"key": "Z", "ctrl": True}, read]), "key window"))
    check("a locked menu step is refused by name",
          refused(lambda: locked([{"menu": "menu_group"}, read]), "menu"))
    lp = lk([pan, read])
    check("a locked panel step is left for the driver", lp is not None and lp[2][0] == "panel")
    check("the gesture's FIFO line is the verb and compact JSON",
          la is not None and gesture_command(la[2]) ==
          'gesture [{"kind":"press","x":36,"y":18},{"kind":"move","x":48,"y":24,"dragging":true},'
          '{"kind":"release","x":36,"y":18}]')
    check("a delivered gesture reads delivered",
          gesture_log_verdict("x Jas[1:2] test-fifo: gesture [..]\ny test-fifo: gesture delivered 3: press@(1,2)")
          == "delivered")
    check("an app without the verb reads as its refusal",
          (gesture_log_verdict("t test-fifo: unknown command gesture [{}]") or "").startswith("unknown command gesture"))
    check("a refused gesture reads as its refusal",
          (gesture_log_verdict("t test-fifo: gesture REFUSED (step 0: unknown kind 'x')") or "")
          .startswith("gesture REFUSED (step 0"))
    check("an empty log is not yet a verdict", gesture_log_verdict("") is None
          and gesture_log_verdict("t test-fifo: gesture [{}]") is None)
    # ── the locked suite's receipt (row 252, desk AHJ option A) ──
    whole = dict(base, steps=[press, mv, rel, read])
    check("locked suite: a script whose every act the route delivers is a member",
          locked_suite_refusal(whole, mb) is None)
    check("locked suite: a script with a panel step is refused by name",
          "panel" in (locked_suite_refusal(dict(base, steps=[pan, read]), mb) or ""))
    check("locked suite: a script with a key step is refused by the route's own reason",
          "key window" in (locked_suite_refusal(dict(base, steps=[{"key": "Z", "ctrl": True}, read]), mb) or ""))
    check("locked suite: a script with a menu step is refused by the route's own reason",
          "menu" in (locked_suite_refusal(dict(base, steps=[{"menu": "menu_group"}, read]), mb) or ""))
    mem, out = locked_suite_split({"w.json": whole, "p.json": dict(base, steps=[pan, read])}, mb)
    check("locked suite: the split keeps members and names every refusal",
          mem == ["w.json"] and sorted(out) == ["p.json"] and "panel" in out["p.json"])
    check("locked suite: the token is the board's declared one", LOCKED_SUITE == "mac.locked")
    check("locked receipt: a run refused before any script is NOT RUN, and still scope=partial",
          receipt_line({}, corpus, H, D, not_run="x", suite=LOCKED_SUITE)
          == "UI-NIGHTLY v1 suite=mac.locked verdict=NOT RUN(x) items=0/3 panels=- head=0123abcd scope=partial date=" + D)
    lr = receipt_line({"a.json": "PASS", "b.json": "PASS"}, corpus, H, D, suite=LOCKED_SUITE)
    check("locked receipt: a GREEN over the members reads scope=partial, never full",
          lr == "UI-NIGHTLY v1 suite=mac.locked verdict=GREEN items=2/2 panels=- head=0123abcd scope=partial date=" + D)

    # The shipped corpus: which scripts the locked route drives whole (no
    # panel act left for the accessibility walk). Counted and printed, not pinned.
    shipped = {}
    for f in sorted(os.listdir(os.path.join(REPO, "test_fixtures", "input_scripts"))):
        if not f.endswith(".json") or f.endswith(".expected.json"):
            continue
        shipped[f] = json.load(open(os.path.join(REPO, "test_fixtures", "input_scripts", f), encoding="utf-8"))
    members, refusals = locked_suite_split(shipped, load_menubar())
    locked_whole = len(members)
    check("some shipped script is drivable whole on the locked route", locked_whole > 0)
    check("the locked suite is a STRICT subset of the shipped corpus, so its receipt is scope=partial",
          0 < locked_whole < len(shipped) and len(members) + len(refusals) == len(shipped))

    total = ran[0]
    print(f"mac_l2_plan self-test: {total - len(fails)} of {total} checks passed, {planned} shipped scripts planned, {locked_whole} drivable whole with the console locked")
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
