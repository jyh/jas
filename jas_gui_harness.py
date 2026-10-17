"""Quartz synthetic-input harness for GUI-testing the native Jas (Swift) app.

Drives the running app with synthetic mouse + keyboard events (Quartz CGEvent)
and reads results back with `screencapture -l<windowid>`. Used to automate the
manual-floor tests the cross-language corpora cannot see (live canvas, overlays,
gesture cancel, ...). See transcripts/COORD_RECONCILE_TESTS.md.

USAGE
  1. Launch ONE instance with a unique title so the window is findable:
         (cd JasSwift && swift run Jas --title JasHarness)
  2. Point the harness at it and drive verbs:
         export JAS_TITLE=JasHarness
         python3 jas_gui_harness.py activate
         python3 jas_gui_harness.py key v                 # select tool
         python3 jas_gui_harness.py key b shift            # Shift+B (blob brush)
         python3 jas_gui_harness.py drag 0.4 0.3 0.5 0.4   # drag in WINDOW FRACTIONS
         python3 jas_gui_harness.py dragpath 0.3 0.4 0.4 0.3 0.5 0.4   # curved drag
         python3 jas_gui_harness.py shot /tmp/out.png      # screenshot the window

Coordinates are WINDOW FRACTIONS (0..1) mapped to logical screen points
(window_origin + frac*size), so they are resolution / Retina independent and
work wherever the window sits (including a second display).

RUST/DIOXUS app (chromeless desktop window — see run_dioxus_desktop.sh): it is
wasm-only, so it runs in a chromeless Chrome window. Drive it with:
    export JAS_TITLE=Jas JAS_PROC="Google Chrome"
    python3 jas_gui_harness.py click 0.5 0.5   # FOCUS-CLICK first to raise this
    python3 jas_gui_harness.py key m            # window, then drive normally.
JAS_PROC sets the `activate` process; JAS_TITLE matches the window title by
SUBSTRING ("Jas — Vector Drawing"). The web app uses Ctrl, not Cmd, for menu
shortcuts. With another Chrome already open, prefer a focus-click over
`activate` (the AppleScript target is ambiguous across Chrome instances).

Verbs:
  script FILE...   (level 2: an input script through the live app; see below)
  geom | activate | clearmods | shot PATH | click FX FY | key CHAR [MODS]
  drag FX1 FY1 FX2 FY2 [MODS] | dragbegin FX1 FY1 FX2 FY2 | dragend FX FY
  dragpath FX1 FY1 FX2 FY2 ...        (continuous drag through N waypoints)
  MODS = comma-list of shift,cmd,alt,ctrl,space.

HARD-WON GOTCHAS (do not regress):
  - Run exactly ONE instance; multiple windows / the 33px menu-bar strips make
    the owner name ambiguous. find_window() prefers a kCGWindowName == JAS_TITLE
    match, else the largest owner='Jas' window with height>100.
  - Focus via AppleScript `activate` (verb), NEVER by clicking the title bar —
    repeated title-bar clicks double-click-minimize the window.
  - Modifier keys: post REAL modifier key-down/up AND let the state SETTLE
    (~0.08s) before the main key, else (a) a flag-only press leaks (a stuck Cmd
    turned a later 'm' into Cmd+M=minimize) and (b) the modifier doesn't reach
    the shortcut matcher in time (Shift+B silently fell back to bare focus).
  - Screenshot px -> screen pt = window_origin + px/scale (Retina scale = 2).
  - The HID left-button stays held across processes, so dragbegin ... shot ...
    dragend lets you capture / send keys mid-gesture (e.g. Escape-cancel).
"""
import subprocess, sys, time, os
import Quartz

APP = "Jas"
# When set (export JAS_TITLE=...), find the window whose TITLE (kCGWindowName)
# CONTAINS it — deterministic across instances / menu-bar strips. Substring so
# the Chrome-app desktop window (title = page title "Jas — Vector Drawing")
# matches JAS_TITLE=Jas. Launch the native apps with `--title <JAS_TITLE>`.
TITLE = os.environ.get("JAS_TITLE")
# Process name used by `activate` (AppleScript). "Jas" for the native Swift app;
# set JAS_PROC="Google Chrome" for the chromeless-Chrome Dioxus desktop window.
PROC = os.environ.get("JAS_PROC", "Jas")
KEYCODE = {  # ANSI virtual keycodes
 'a':0,'s':1,'d':2,'f':3,'h':4,'g':5,'z':6,'x':7,'c':8,'v':9,'b':11,'q':12,'w':13,
 'e':14,'r':15,'y':16,'t':17,'o':31,'u':32,'i':34,'p':35,'l':37,'j':38,'k':40,'n':45,'m':46,
 '=':24,'-':27,'space':49,'delete':51,'escape':53,'return':36,'tab':48,
 '\\':42,'/':44,';':41,',':43,'.':47,'[':33,']':30,
 '1':18,'2':19,'3':20,'4':21,'5':23,'6':22,'7':26,'8':28,'9':25,'0':29,
}
FLAG = {
 'shift':Quartz.kCGEventFlagMaskShift, 'cmd':Quartz.kCGEventFlagMaskCommand,
 'alt':Quartz.kCGEventFlagMaskAlternate, 'ctrl':Quartz.kCGEventFlagMaskControl,
}

def find_window():
    # Prefer a window whose TITLE matches JAS_TITLE; else the largest-area Jas
    # layer-0 window with height>100 (excludes the 33px menu-bar strips that
    # also report owner 'Jas'). Retry for the occasionally-flaky on-screen list.
    for _ in range(6):
        wl = Quartz.CGWindowListCopyWindowInfo(
            Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
            Quartz.kCGNullWindowID)
        best=None
        for w in wl:
            if w.get(Quartz.kCGWindowLayer) != 0: continue
            b=w["kCGWindowBounds"]
            if b["Height"] <= 100: continue
            name = w.get(Quartz.kCGWindowName) or ""
            owner = w.get(Quartz.kCGWindowOwnerName, "")
            match = (TITLE in name) if TITLE else (APP.lower() in owner.lower())
            if match:
                cand={"id":w.get(Quartz.kCGWindowNumber),"x":b["X"],"y":b["Y"],"w":b["Width"],"h":b["Height"]}
                if best is None or b["Width"]*b["Height"]>best["w"]*best["h"]:
                    best=cand
        if best: return best
        time.sleep(0.2)
    return None

WIN = find_window()
def pt(fx, fy): return (WIN["x"]+fx*WIN["w"], WIN["y"]+fy*WIN["h"])

def flags(mods):
    f=0
    for m in mods:
        if m in FLAG: f|=FLAG[m]
    return f

def mouse(etype, x, y, f=0):
    e=Quartz.CGEventCreateMouseEvent(None, etype, (x,y), Quartz.kCGMouseButtonLeft)
    if f: Quartz.CGEventSetFlags(e, f)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, e); time.sleep(0.02)

def keyev(code, down, f=0):
    e=Quartz.CGEventCreateKeyboardEvent(None, code, down)
    if f: Quartz.CGEventSetFlags(e, f)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, e); time.sleep(0.02)

MODKEY = {'cmd':55, 'shift':56, 'alt':58, 'ctrl':59}  # left-modifier virtual keycodes

def do_key(ch, mods):
    # Post REAL modifier key-down/up around the main key AND let the modifier
    # state settle before the main key. Flag-only (no modifier key events)
    # desyncs the global state and sticks into the next keystroke; no settle
    # delay and the modifier does not reach the shortcut matcher in time.
    code=KEYCODE[ch]; f=0
    for m in mods:
        f |= FLAG.get(m, 0)
        if m in MODKEY: keyev(MODKEY[m], True, f)
    if mods: time.sleep(0.08)        # let the modifier state settle before the main key
    keyev(code, True, f); time.sleep(0.05); keyev(code, False, f)
    if mods: time.sleep(0.03)
    for m in reversed(mods):
        if m in MODKEY:
            f &= ~FLAG.get(m, 0)
            keyev(MODKEY[m], False, f)

def clear_mods():
    for kc in (55,56,58,59):
        keyev(kc, False, 0)

def do_click(fx, fy, mods=()):
    # Modifier-aware click: hold REAL modifier keys (down/up) AND set the
    # CGEvent flags, so shift/alt-click reach the app's mousedown handler
    # (flag-only modifiers proved flaky — mirror do_key's real-keydown path).
    f=flags(mods); x,y=pt(fx,fy)
    for m in mods:
        if m in MODKEY: keyev(MODKEY[m], True, f)
    if mods: time.sleep(0.06)
    mouse(Quartz.kCGEventMouseMoved,x,y,f)
    mouse(Quartz.kCGEventLeftMouseDown,x,y,f); time.sleep(0.06); mouse(Quartz.kCGEventLeftMouseUp,x,y,f)
    for m in reversed(mods):
        if m in MODKEY: keyev(MODKEY[m], False)

def do_drag(fx1,fy1,fx2,fy2,mods):
    f=flags(mods); x1,y1=pt(fx1,fy1); x2,y2=pt(fx2,fy2)
    space_held = 'space' in mods
    if space_held: keyev(KEYCODE['space'], True)
    mouse(Quartz.kCGEventMouseMoved,x1,y1,f)
    mouse(Quartz.kCGEventLeftMouseDown,x1,y1,f); time.sleep(0.05)
    N=12
    for i in range(1,N+1):
        x=x1+(x2-x1)*i/N; y=y1+(y2-y1)*i/N
        mouse(Quartz.kCGEventLeftMouseDragged,x,y,f); time.sleep(0.015)
    time.sleep(0.05); mouse(Quartz.kCGEventLeftMouseUp,x2,y2,f)
    if space_held: keyev(KEYCODE['space'], False)

def do_dragbegin(fx1,fy1,fx2,fy2,mods=()):
    # Mouse down at start, drag to end, but LEAVE the button held (the HID
    # button state persists across processes). Use dragend to release.
    # `mods` (e.g. alt/shift) are carried as CGEvent flags on every event AND
    # held as real modifier keys (released by dragend) — this is the modifier
    # path for drags (Alt-copy etc.). Prefer this over the single-shot `drag`
    # when the test sends a key/click AFTER the drag: the single-shot `drag`
    # leaves the canvas unable to receive the next synthetic input, but the
    # button-held begin/end path does not.
    # FLAG-ONLY modifiers (no real key held): the modifier rides on the CGEvent
    # flags of every mouse event, which is what the app reads for a drag
    # modifier (event.modifiers.alt). Holding a REAL modifier key across the
    # begin/end process boundary disrupted subsequent synthetic input
    # (a later Ctrl-Z / drag didn't register); flag-only avoids that.
    f=flags(mods); x1,y1=pt(fx1,fy1); x2,y2=pt(fx2,fy2)
    mouse(Quartz.kCGEventMouseMoved,x1,y1,f)
    mouse(Quartz.kCGEventLeftMouseDown,x1,y1,f); time.sleep(0.05)
    N=12
    for i in range(1,N+1):
        x=x1+(x2-x1)*i/N; y=y1+(y2-y1)*i/N
        mouse(Quartz.kCGEventLeftMouseDragged,x,y,f); time.sleep(0.015)

def do_dragend(fx,fy,mods=()):
    f=flags(mods); x,y=pt(fx,fy)
    mouse(Quartz.kCGEventLeftMouseUp,x,y,f)

def do_dragpath(points):
    # Continuous drag through N waypoints (a curve). Down at first, interpolated
    # dragged events between each pair (so on_mousemove fires along the path),
    # up at the last.
    pts=[pt(fx,fy) for (fx,fy) in points]
    mouse(Quartz.kCGEventMouseMoved,*pts[0])
    mouse(Quartz.kCGEventLeftMouseDown,*pts[0]); time.sleep(0.05)
    for a,b in zip(pts,pts[1:]):
        for i in range(1,9):
            x=a[0]+(b[0]-a[0])*i/8; y=a[1]+(b[1]-a[1])*i/8
            mouse(Quartz.kCGEventLeftMouseDragged,x,y); time.sleep(0.012)
    time.sleep(0.05); mouse(Quartz.kCGEventLeftMouseUp,*pts[-1])

def do_move(fx,fy):
    # Bare cursor move, NO button — for hover-dependent overlays (e.g. the
    # Pen tool's live preview curve and the close-hit ring near the first
    # anchor) that track the cursor via on_mousemove. After a click the cursor
    # sits on the last anchor, so the preview is zero-length; this repositions
    # it without placing an anchor. A couple of moves + settle so on_mousemove
    # fires and the overlay repaints before the next `shot`.
    x,y=pt(fx,fy)
    mouse(Quartz.kCGEventMouseMoved,x,y); time.sleep(0.03)
    mouse(Quartz.kCGEventMouseMoved,x,y); time.sleep(0.06)

def do_presshold(fx, fy, ms=400):
    # Clean press-and-HOLD-in-place then release — for long-press flyouts
    # (e.g. the toolbar tool-slot alternates). Unlike `drag`/`dragbegin`,
    # it sends NO dragged events, so a tool that distinguishes hold from
    # drag sees a genuine long-press. The hold duration (default 400ms)
    # exceeds the 250ms flyout threshold.
    x,y=pt(fx,fy)
    mouse(Quartz.kCGEventMouseMoved,x,y); time.sleep(0.03)
    mouse(Quartz.kCGEventLeftMouseDown,x,y)
    time.sleep(ms/1000.0)
    mouse(Quartz.kCGEventLeftMouseUp,x,y); time.sleep(0.05)

def do_shot(path):
    subprocess.run(f"screencapture -o -l{WIN['id']} {path}", shell=True)

# ── `script FILE...`: level 2 on the Mac (docs/TESTING.md section 6) ──────
# Drives an input script through the LIVE app and compares the read-back with
# the script's level-1 expected file, byte for byte. Every decision (the act
# list, the refusals, the document -> screen mapping, the open's artboard) is
# made by scripts/mac_l2_plan.py, which self-tests without a window; this part
# only posts events and walks the accessibility tree.
#   Launch:  (cd JasSwift && swift run Jas --title JasHarness --test-fifo /tmp/jas.fifo)
#   Run:     JAS_TITLE=JasHarness JAS_FIFO=/tmp/jas.fifo python3 jas_gui_harness.py script test_fixtures/input_scripts/*.json
#   Or set JAS_APP=<path to the built Jas binary> and skip the launch: the
#   driver then starts a FRESH app per script, as level 1 starts each script
#   from a fresh store. Without it, scripts run in ONE app, and opening a file
#   that is already open FOCUSES its tab, edits and all (File > Open's rule,
#   `WorkspaceState.addCanvas`), so scripts sharing a setup file share a document.
# A script's `ctrl` is the engine's command modifier, which a person presses
# as Cmd on the Mac, so it is posted as Cmd.
import json as _json
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "scripts"))

def _ax():
    import ApplicationServices as AX
    return AX

def _attr(el, name):
    AX = _ax()
    err, v = AX.AXUIElementCopyAttributeValue(el, name, None)
    return v if err == 0 else None

def _children(el):
    return list(_attr(el, "AXChildren") or [])

def _find_all(root, pred, limit=40000):
    out, stack, seen = [], [root], 0
    while stack and seen < limit:
        el = stack.pop(); seen += 1
        if pred(el): out.append(el)
        stack.extend(_children(el))
    return out

def _by_id(root, ident):
    return _find_all(root, lambda e: _attr(e, "AXIdentifier") == ident)

def _app_element():
    win = find_window()
    if not win:
        raise _plan.Refused(f"no window titled {TITLE!r}")
    wl = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID)
    for w in wl:
        if w.get(Quartz.kCGWindowNumber) == win["id"]:
            return _ax().AXUIElementCreateApplication(w[Quartz.kCGWindowOwnerPID])
    raise _plan.Refused("the harness window has no owning process")

def _launch():
    """With JAS_APP set, each script gets a FRESH app, as each port's level-1
    runner starts each script from a fresh store. Returns the process."""
    fifo = os.environ["JAS_FIFO"]
    log = fifo + ".log"
    if os.path.exists(fifo):
        os.remove(fifo)
    proc = subprocess.Popen([os.environ["JAS_APP"], "--title", TITLE, "--test-fifo", fifo],
                            stdout=open(log, "w", encoding="utf-8", newline=""), stderr=subprocess.STDOUT)
    for _ in range(100):
        if os.path.exists(fifo) and find_window():
            break
        time.sleep(0.1)
    else:
        proc.terminate()
        raise _plan.Refused("the app did not open its FIFO and window within 10 s")
    subprocess.run(["osascript", "-e", f'tell application "System Events" to set frontmost of (first process whose unix id is {proc.pid}) to true'])
    time.sleep(0.5)
    return proc

def _fifo(cmd):
    with open(os.environ["JAS_FIFO"], "w", encoding="utf-8", newline="") as f:
        f.write(cmd + "\n")

def _press(el):
    if _ax().AXUIElementPerformAction(el, "AXPress") != 0:
        raise _plan.Refused(f"AXPress failed on {_attr(el, 'AXRole')} {_attr(el, 'AXIdentifier')!r}")

def _menu_item(app, path):
    bar = _attr(app, "AXMenuBar")
    level = [c for c in _children(bar)] if bar else []
    el = None
    for depth, title in enumerate(path):
        hits = [c for c in level if _plan.live_title(_attr(c, "AXTitle")) == title]
        if len(hits) != 1:
            raise _plan.Refused(f"menu path {path}: {len(hits)} items titled {title!r} at depth {depth}")
        el = hits[0]
        kids = _children(el)
        level = _children(kids[0]) if kids and _attr(kids[0], "AXRole") == "AXMenu" else kids
    return el

def _canvas(app):
    hits = _by_id(app, "jas_canvas")
    if len(hits) != 1:
        raise _plan.Refused(f"{len(hits)} canvases carry AXIdentifier jas_canvas; the run needs exactly one")
    c = hits[0]
    view = _plan.parse_view_report(_attr(c, "AXValue"))
    pos, size = _attr(c, "AXPosition"), _attr(c, "AXSize")
    if view is None or pos is None:
        raise _plan.Refused(f"the canvas does not report its view ({_attr(c, 'AXValue')!r}); was the app launched with --test-fifo?")
    import ApplicationServices as AX
    ok, p = AX.AXValueGetValue(pos, AX.kAXValueCGPointType, None)
    return view, (p.x, p.y)

TEXT_ROLES = ("AXTextField", "AXComboBox", "AXTextArea")
TYPE_DELAY_S = float(os.environ.get("JAS_TYPE_DELAY", "0.25"))  # between typed characters
KEYNAME = {"Delete": "delete", "Backspace": "delete", "Escape": "escape", "Enter": "return"}

def _run_script(path, menubar):
    with open(path, encoding="utf-8") as f:
        script = _json.load(f)
    acts = _plan.plan(script, menubar, _plan.load_spec(script))
    repo = os.path.dirname(os.path.abspath(__file__))
    want = open(os.path.join(os.path.dirname(path), script["expected_json"]), encoding="utf-8").read().strip()
    app = _app_element()
    view = origin = None
    for act in acts:
        k = act[0]
        if k == "open":
            _fifo("open " + os.path.join(repo, "test_fixtures", "svg", act[1])); time.sleep(1.2)
            _fifo("view 1 0 0"); time.sleep(0.4)
            view, origin = _canvas(app)
            if view != (1.0, 0.0, 0.0):
                raise _plan.Refused(f"the canvas reports view {view} after `view 1 0 0`")
        elif k == "tool":
            _fifo("tool " + act[1]); time.sleep(0.3)
        elif k in ("pointer", "key") and not _front_is_jas():
            raise _plan.Refused("Jas is not the frontmost app; a real event would land elsewhere")
        elif k == "pointer":
            _, kind, x, y, dragging, mods = act
            sx, sy = _plan.doc_to_screen(view, origin, x, y)
            f = flags(mods)
            if kind == "press":
                mouse(Quartz.kCGEventMouseMoved, sx, sy, f); mouse(Quartz.kCGEventLeftMouseDown, sx, sy, f)
            elif kind == "move":
                mouse(Quartz.kCGEventLeftMouseDragged if dragging else Quartz.kCGEventMouseMoved, sx, sy, f)
            else:
                mouse(Quartz.kCGEventLeftMouseUp, sx, sy, f)
            time.sleep(0.05)
        elif k == "key":
            _, key, mods = act
            ch = KEYNAME.get(key, key.lower())
            if ch not in KEYCODE:
                raise _plan.Refused(f"key {key!r} has no keycode in this harness")
            do_key(ch, ["cmd" if m == "ctrl" else m for m in mods]); time.sleep(0.2)
        elif k == "panel":
            _, pid, tab, wpath, widget, event, value, label = act
            panels = _by_id(app, pid)
            if not panels:
                # Show it as a person does: its dock tab, or, for a panel in no
                # dock group, its Window menu item.
                tabs = _by_id(app, tab)
                if len(tabs) > 1:
                    raise _plan.Refused(f"{len(tabs)} dock tabs carry AXIdentifier {tab!r}")
                if tabs:
                    _press(tabs[0])
                elif wpath:
                    _press(_menu_item(app, wpath))
                else:
                    raise _plan.Refused(f"panel {pid!r} has no dock tab and no unique Window item")
                time.sleep(0.6)
                panels = _by_id(app, pid)
            if len(panels) != 1:
                raise _plan.Refused(f"{len(panels)} panels carry AXIdentifier {pid!r}")
            ws = _by_id(panels[0], widget)
            if len(ws) != 1:
                raise _plan.Refused(f"{len(ws)} widgets carry AXIdentifier {widget!r} in {pid!r}")
            w = ws[0]
            if _attr(w, "AXEnabled") is False:
                raise _plan.Refused(f"widget {widget!r} is disabled")
            if event == "click":
                _press(w)
            elif label is not None:
                # A select: open its popup and choose the item a person reads.
                _press(w); time.sleep(0.4)
                items = [m for m in _find_all(w, lambda e: _attr(e, "AXRole") == "AXMenuItem")
                         if _plan.live_title(_attr(m, "AXTitle")) == label]
                if len(items) != 1:
                    do_key("escape", [])
                    raise _plan.Refused(f"select {widget!r}: {len(items)} items titled {label!r}")
                _press(items[0])
            else:
                # Type the text as a person does. Setting AXValue on a SwiftUI
                # text field does not reach its binding, so Return committed
                # the old text. The field is the widget or its one text-field
                # descendant (a length input wraps one).
                fields = [w] if _attr(w, "AXRole") in TEXT_ROLES else \
                    _find_all(w, lambda e: _attr(e, "AXRole") in TEXT_ROLES)
                if len(fields) != 1:
                    raise _plan.Refused(f"widget {widget!r} holds {len(fields)} text fields; a commit needs one")
                text = str(value)
                bad = [c for c in text if c not in KEYCODE]
                if bad:
                    raise _plan.Refused(f"commit text {text!r} has characters this harness cannot type: {bad}")
                _ax().AXUIElementSetAttributeValue(fields[0], "AXFocused", True); time.sleep(0.2)
                do_key("a", ["cmd"]); time.sleep(0.1)
                for c in text:
                    do_key(c, []); time.sleep(TYPE_DELAY_S)
                do_key("return", [])
            time.sleep(0.3)
        elif k == "menu":
            _press(_menu_item(app, act[1])); time.sleep(0.4)
        elif k == "read":
            out = os.path.join(os.environ.get("TMPDIR", "/tmp"), "jas-l2-read.json")
            if os.path.exists(out): os.remove(out)
            _fifo("read " + out)
            for _ in range(30):
                if os.path.exists(out): break
                time.sleep(0.1)
            else:
                raise _plan.Refused("the app wrote no read-back (is --test-fifo the same path as JAS_FIFO?)")
            got = open(out, encoding="utf-8").read().strip()
            got = _plan.set_aside_the_opens_artboard(got, want)
            return got == want, got, want

IDLE_FLOOR_S = 120  # a person's input this recent means the console is in use

def _lastpost_file():
    return os.environ["JAS_FIFO"] + ".lastpost"

def _console_in_use():
    # Real Quartz events go to whatever is under the pointer, so the driver
    # never runs while a person is using the console. The HID idle clock also
    # counts this driver's own events, so input is a person's only if it came
    # after the driver's last post (recorded at the end of every run).
    idle = Quartz.CGEventSourceSecondsSinceLastEventType(
        Quartz.kCGEventSourceStateHIDSystemState, Quartz.kCGAnyInputEventType)
    try:
        since_mine = time.time() - float(open(_lastpost_file(), encoding="utf-8").read())
    except (OSError, ValueError):
        since_mine = None
    if since_mine is not None and idle >= since_mine - 1.0:
        return False, idle  # the last input was the driver's own
    return idle < IDLE_FLOOR_S, idle

def _front_is_jas():
    from AppKit import NSWorkspace
    app = NSWorkspace.sharedWorkspace().frontmostApplication()
    return app is not None and app.localizedName() == PROC

def do_script(paths):
    global _plan
    import mac_l2_plan as _plan
    busy, idle = _console_in_use()
    if busy:
        print(f"REFUSED: the console saw input {idle:.0f} s ago (floor {IDLE_FLOOR_S} s); a person may be using it")
        return 3
    menubar = _plan.load_menubar()
    bad = 0
    for p in paths:
        name = os.path.basename(p)
        proc = None
        clear_mods()  # a flag-carrying event leaks its modifier into the next script
        try:
            if os.environ.get("JAS_APP"):
                proc = _launch()
            ok, got, want = _run_script(p, menubar)
            print(("PASS " if ok else "FAIL ") + name)
            if not ok:
                bad += 1
                print("  got  ", got); print("  want ", want)
        except _plan.Refused as e:
            bad += 1
            print("REFUSED " + name + ": " + str(e))
        finally:
            clear_mods()
            if proc is not None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                time.sleep(0.3)
    with open(_lastpost_file(), "w", encoding="utf-8", newline="") as f:
        f.write(str(time.time()))
    print(f"{len(paths) - bad} of {len(paths)} scripts passed")
    return 1 if bad else 0

if __name__=="__main__":
    v=sys.argv[1]
    if v=="activate":
        # Unminimize + frontmost WITHOUT clicking (title-bar clicks risk a
        # double-click-minimize). Does NOT require the window to be found.
        subprocess.run(["osascript",
            "-e",f'tell application "System Events" to tell (first process whose name is "{PROC}") to set value of attribute "AXMinimized" of every window to false',
            "-e",f'tell application "System Events" to set frontmost of (first process whose name is "{PROC}") to true'])
        time.sleep(0.3)
        print("activated"); sys.exit(0)
    if v=="clearmods":
        clear_mods(); print("mods cleared"); sys.exit(0)
    if v=="script":
        paths=[a for a in sys.argv[2:] if not a.endswith(".expected.json")]
        sys.exit(do_script(paths))
    if not WIN: print("WINDOW NOT FOUND"); sys.exit(1)
    if v=="geom": print(WIN)
    elif v=="shot": do_shot(sys.argv[2]); print("shot",sys.argv[2])
    elif v=="click":
        cmods=sys.argv[4].split(",") if len(sys.argv)>4 else []
        do_click(float(sys.argv[2]),float(sys.argv[3]),cmods); print("click",sys.argv[2],sys.argv[3],cmods)
    elif v=="key":
        mods=sys.argv[3].split(",") if len(sys.argv)>3 else []
        do_key(sys.argv[2],mods); print("key",sys.argv[2],mods)
    elif v=="drag":
        mods=sys.argv[6].split(",") if len(sys.argv)>6 else []
        do_drag(*[float(a) for a in sys.argv[2:6]],mods); print("drag",sys.argv[2:6],mods)
    elif v=="dragbegin":
        bmods=sys.argv[6].split(",") if len(sys.argv)>6 else []
        do_dragbegin(*[float(a) for a in sys.argv[2:6]],bmods); print("dragbegin",sys.argv[2:6],bmods)
    elif v=="dragend":
        emods=sys.argv[4].split(",") if len(sys.argv)>4 else []
        do_dragend(float(sys.argv[2]),float(sys.argv[3]),emods); print("dragend",sys.argv[2:4],emods)
    elif v=="dragpath":
        nums=[float(a) for a in sys.argv[2:]]
        points=list(zip(nums[0::2],nums[1::2]))
        do_dragpath(points); print("dragpath",points)
    elif v=="move":
        do_move(float(sys.argv[2]),float(sys.argv[3])); print("move",sys.argv[2],sys.argv[3])
    elif v=="presshold":
        ms=int(sys.argv[4]) if len(sys.argv)>4 else 400
        do_presshold(float(sys.argv[2]),float(sys.argv[3]),ms); print("presshold",sys.argv[2:4],ms)
    else:
        print("unknown verb:", v); sys.exit(2)
