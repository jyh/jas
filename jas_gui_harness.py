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
  script --locked FILE...  (the same with the console locked: pointer runs through
                   the FIFO's `gesture`, keys and menus refused by name; row 250)
  script --locked --receipt FILE...  (the board's mac.locked suite: non-members
                   refused by name and left out; the line is scope=partial; row 252)
  dock             (the dock check: three tab drags, one DOCK line; needs JAS_APP)
  dock --groups    (sheet 2's three drops inside the right dock, one DOCKGROUPS line; row 255)
  layers           (row 208 through the Layers tree: R1 R4 R5-R7, one LAYERS line; rows 256, 264)
  geom | activate | clearmods | shot PATH | click FX FY | key CHAR [MODS]
  drag FX1 FY1 FX2 FY2 [MODS] | dragbegin FX1 FY1 FX2 FY2 | dragend FX FY
  dragpath FX1 FY1 FX2 FY2 ...        (continuous drag through N waypoints)
  MODS = comma-list of shift,cmd,alt,ctrl,space.

THE OWNER'S CLAIM (council 2026-11-24): before EVERY console step on every
verb above (a launch, an act, a reset, a drag) the driver reads the claim file
on this box (JAS_CLAIM_FILE, default ~/.fleet/watch/CONSOLE-CLAIM) and its
`.relay` heartbeat, and stops while the claim exists. It fails closed: no
heartbeat, or one older than 120 s, refuses by name. The law and its arms are
mac_l2_plan.claim_check; JAS_CLAIM_FILE=none turns it off and says so.

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
 'left':123,'right':124,'down':125,'up':126,
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

_LAST_MINE = [None]  # when this driver last posted an event (time.time())

def mouse(etype, x, y, f=0):
    _LAST_MINE[0] = time.time()
    e=Quartz.CGEventCreateMouseEvent(None, etype, (x,y), Quartz.kCGMouseButtonLeft)
    if f: Quartz.CGEventSetFlags(e, f)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, e); time.sleep(0.02)

def keyev(code, down, f=0):
    _LAST_MINE[0] = time.time()
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

def _launch(locked=False):
    """With JAS_APP set, each script gets a FRESH app, as each port's level-1
    runner starts each script from a fresh store. Returns the process. LOCKED
    (`script --locked`): waits for the FIFO only, since a locked console lists
    no window and gives no frontmost app."""
    fifo = os.environ["JAS_FIFO"]
    log = fifo + ".log"
    if os.path.exists(fifo):
        os.remove(fifo)
    proc = subprocess.Popen([os.environ["JAS_APP"], "--title", TITLE, "--test-fifo", fifo],
                            stdout=open(log, "w", encoding="utf-8", newline=""), stderr=subprocess.STDOUT)
    for _ in range(100):
        if os.path.exists(fifo) and (locked or find_window()):
            break
        time.sleep(0.1)
    else:
        proc.terminate()
        raise _plan.Refused("the app did not open its FIFO and window within 10 s")
    if locked:
        time.sleep(2.0)  # the FIFO opens before the window's first document can
        return proc
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
KEYNAME = {"Delete": "delete", "Backspace": "delete", "Escape": "escape", "Enter": "return",
           "ArrowLeft": "left", "ArrowRight": "right", "ArrowDown": "down", "ArrowUp": "up"}

def _locked_app(pid):
    """The app's accessibility element by pid (no window lookup), for a panel
    act on the locked route. Refused by name when this process is not trusted
    for accessibility, where every walk reads one element and finds nothing."""
    AX = _ax()
    if not AX.AXIsProcessTrusted():
        raise _plan.Refused("this process is not trusted for accessibility, so a panel step cannot be pressed")
    return AX.AXUIElementCreateApplication(pid)

def _drive_widget(app, container, where, widget, event, value, label, wtype):
    """Drive one widget inside `container` (a panel, or an open dialog's body)
    as a person does: a click presses it, a select or icon_select commit picks
    the option a person reads, a text commit types the text. One body for the
    panel step and the dialog step, so the two routes cannot drift."""
    ws = _by_id(container, widget)
    if len(ws) != 1:
        raise _plan.Refused(f"{len(ws)} widgets carry AXIdentifier {widget!r} in {where!r}")
    w = ws[0]
    if _attr(w, "AXEnabled") is False:
        raise _plan.Refused(f"widget {widget!r} is disabled")
    if event == "click":
        _press(w)
    elif wtype == "icon_select":
        # An icon_select opens a POPOVER of buttons described "<glyph>,
        # <label>", none with an identifier (row 83, the AX dump on the Mac test box):
        # press the widget, then the one option whose description names
        # the label. A popover with no match is cancelled, never picked.
        _press(w); time.sleep(0.5)
        pops = _find_all(app, lambda e: _attr(e, "AXRole") == "AXPopover")
        if len(pops) != 1:
            raise _plan.Refused(f"icon_select {widget!r}: {len(pops)} popovers open after its press")
        items = [b for b in _find_all(pops[0], lambda e: _attr(e, "AXRole") == "AXButton")
                 if _plan.icon_option_matches(_attr(b, "AXDescription"), label)]
        if len(items) != 1:
            _ax().AXUIElementPerformAction(pops[0], "AXCancel")
            raise _plan.Refused(f"icon_select {widget!r}: {len(items)} options named {label!r}")
        _press(items[0])
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


def _run_script(path, menubar, locked=False, pid=None):
    with open(path, encoding="utf-8") as f:
        script = _json.load(f)
    acts = _plan.plan(script, menubar, _plan.load_spec(script))
    if locked:
        # Row 250: pointer runs go through the FIFO's `gesture`; keys, menus and
        # toolbar holds are refused by name (mac_l2_plan.locked_acts).
        acts = _plan.locked_acts(acts, script.get("item", os.path.basename(path)))
    repo = os.path.dirname(os.path.abspath(__file__))
    # Only a document read compares with expected_json; a toolbar script
    # reads state and the dialog, and carries the expected values itself.
    want = None
    if any(a[0] == "read" and a[1] == "document" for a in acts):
        want = open(os.path.join(os.path.dirname(path), script["expected_json"]), encoding="utf-8").read().strip()
    app = None if locked else _app_element()
    pid_of_app = pid  # the panel act unpacks its own `pid` (a panel id)
    st = {"view": None, "origin": None, "reads": []}

    def blocked():
        why = _claimed()  # the owner's claim binds the box, so both routes
        if why:
            return why
        if locked:
            return None  # nothing on this route reaches the window server
        # Before EVERY act: a locked screen, or input after this driver's own
        # last event (a person's), aborts the run (the helm's hardening,
        # 2026-10-17). On a locked screen a key event types into the login
        # window.
        if _screen_locked():
            return "the screen is locked"
        idle = Quartz.CGEventSourceSecondsSinceLastEventType(
            Quartz.kCGEventSourceStateHIDSystemState, Quartz.kCGAnyInputEventType)
        mine = None if _LAST_MINE[0] is None else time.time() - _LAST_MINE[0]
        return "a person used the console" if _plan.a_person_acted(idle, mine) else None

    def do_act(act):
        nonlocal app
        view, origin = st["view"], st["origin"]
        k = act[0]
        if k == "open" and act[2]:
            # The app persists its dock layout, so a fresh process starts where
            # the last script left it; level 1 starts from a fresh store (row 254).
            _fifo("action reset_workspace"); time.sleep(0.8)
        if k == "open" and locked:
            # Document units go straight to the canvas view: no screen mapping.
            _fifo("open " + os.path.join(repo, "test_fixtures", "svg", act[1])); time.sleep(1.2)
        elif k == "gesture":
            # The FIFO is one-way, so a gesture the app did not deliver (an app
            # built without the verb, a refused step) would read as a FAIL of
            # the script. The app logs its own receipt; wait for it, and refuse
            # by name on anything else (row 250).
            log = os.environ["JAS_FIFO"] + ".log"
            start = os.path.getsize(log) if os.path.exists(log) else 0
            _fifo(_plan.gesture_command(act))
            for _ in range(30):
                time.sleep(0.1)
                with open(log, encoding="utf-8", errors="replace") as f:
                    f.seek(start)
                    verdict = _plan.gesture_log_verdict(f.read())
                if verdict is not None:
                    break
            if verdict != "delivered":
                raise _plan.Refused(f"the app did not deliver the gesture: {verdict or 'no receipt in its log within 3 s'}")
            time.sleep(0.2)
        elif k == "seed":
            # Row 275 (b): the script's app_state, seeded by the app's FIFO
            # `seed` verb (ScriptPanelSeeds, the level-1 runner's own parse and
            # apply). Its receipt is waited for, as a gesture's is; an app that
            # refused it, or one built without the verb, refuses the script.
            log = os.environ["JAS_FIFO"] + ".log"
            start = os.path.getsize(log) if os.path.exists(log) else 0
            _fifo(_plan.seed_command(act))
            verdict = None
            for _ in range(30):
                time.sleep(0.1)
                with open(log, encoding="utf-8", errors="replace") as f:
                    f.seek(start)
                    verdict = _plan.fifo_log_verdict("seed", f.read())
                if verdict is not None:
                    break
            if verdict != "delivered":
                raise _plan.Refused(f"the app did not seed the app_state: {verdict or 'no receipt in its log within 3 s'}")
            time.sleep(0.2)
        elif k == "open":
            _fifo("open " + os.path.join(repo, "test_fixtures", "svg", act[1])); time.sleep(1.2)
            _fifo("view 1 0 0"); time.sleep(0.4)
            view, origin = _canvas(app)
            st["view"], st["origin"] = view, origin
            if view != (1.0, 0.0, 0.0):
                raise _plan.Refused(f"the canvas reports view {view} after `view 1 0 0`")
        elif k == "tool":
            _fifo("tool " + act[1]); time.sleep(0.3)
        elif k in ("pointer", "key", "toolbar", "panel_menu") and not _front_is_jas():
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
            if app is None:
                app = _locked_app(pid_of_app)
            _, pid, tab, wpath, widget, event, value, label, wtype = act
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
            _drive_widget(app, panels[0], pid, widget, event, value, label, wtype)
            time.sleep(0.3)
        elif k == "menu":
            _press(_menu_item(app, act[1])); time.sleep(0.4)
        elif k == "dialog":
            # Row 275 (c): a widget of the OPEN dialog. The open dialog is read
            # first, by the FIFO's `dialog` (the same read a script's
            # `read: dialog` takes), and a step naming another dialog, or none
            # open, is refused by name; never driven into whatever is open. The
            # widget is found inside the dialog's body, `<dialog id>_dialog`.
            if app is None:
                app = _locked_app(pid_of_app)
            _, did, body_id, widget, event, value, label, wtype = act
            out = os.path.join(os.environ.get("TMPDIR", "/tmp"), "jas-l2-dialog-check.json")
            if os.path.exists(out): os.remove(out)
            _fifo("dialog " + out)
            for _ in range(30):
                if os.path.exists(out): break
                time.sleep(0.1)
            else:
                raise _plan.Refused("the app wrote no dialog read before a dialog step")
            got = _json.load(open(out, encoding="utf-8")).get("dialog")
            if got != did:
                raise _plan.Refused(f"dialog step for {did!r}: the open dialog is {got!r}")
            bodies = _by_id(app, body_id)
            if len(bodies) != 1:
                raise _plan.Refused(f"{len(bodies)} elements carry AXIdentifier {body_id!r}")
            _drive_widget(app, bodies[0], did, widget, event, value, label, wtype)
            time.sleep(0.4)
        elif k == "panel_menu":
            # Row 275 (a): the person's route. Show the panel (its dock tab, or
            # its Window item), press its group's hamburger, `<pid>_menu`, by a
            # REAL click at its AX frame (it pops an NSMenu from the current
            # event, so an AXPress opens nothing), then press the one item
            # titled as the YAML labels it. A disabled item is refused by name.
            if app is None:
                app = _locked_app(pid_of_app)
            _, pid, tab, wpath, menu_id, label = act
            buttons = _by_id(app, menu_id)
            if not buttons:
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
                buttons = _by_id(app, menu_id)
            if len(buttons) != 1:
                raise _plan.Refused(f"{len(buttons)} menu buttons carry AXIdentifier {menu_id!r}")
            import ApplicationServices as AX
            pos, size = _attr(buttons[0], "AXPosition"), _attr(buttons[0], "AXSize")
            if pos is None or size is None:
                raise _plan.Refused(f"menu button {menu_id!r} reports no AX frame")
            _, p = AX.AXValueGetValue(pos, AX.kAXValueCGPointType, None)
            _, z = AX.AXValueGetValue(size, AX.kAXValueCGSizeType, None)
            sx, sy = p.x + z.width / 2, p.y + z.height / 2
            mouse(Quartz.kCGEventMouseMoved, sx, sy); mouse(Quartz.kCGEventLeftMouseDown, sx, sy)
            time.sleep(0.05); mouse(Quartz.kCGEventLeftMouseUp, sx, sy)
            time.sleep(0.5)
            # The popped menu, never the menubar: its items are in the AX tree
            # even while closed, and a panel item can share a menubar title.
            items = [m for root in _children(app) if _attr(root, "AXRole") != "AXMenuBar"
                     for m in _find_all(root, lambda e: _attr(e, "AXRole") == "AXMenuItem")
                     if _plan.live_title(_attr(m, "AXTitle")) == label]
            if len(items) != 1:
                do_key("escape", [])
                raise _plan.Refused(f"panel menu {menu_id!r}: {len(items)} items titled {label!r} "
                                    f"outside the menubar")
            if _attr(items[0], "AXEnabled") is False:
                do_key("escape", [])
                raise _plan.Refused(f"panel menu {menu_id!r}: {label!r} is disabled")
            _press(items[0]); time.sleep(0.5)
        elif k == "toolbar":
            # A real press at the slot's AX frame, held hold_ms, then released:
            # an AXPress has no duration, so it cannot drive a hold (TESTING.md,
            # the toolbar step). hold_ms 0 is a press released at once.
            _, slot, hold_ms = act
            hits = _by_id(app, slot)
            if len(hits) != 1:
                raise _plan.Refused(f"{len(hits)} elements carry AXIdentifier {slot!r}; a toolbar press needs one")
            import ApplicationServices as AX
            pos, size = _attr(hits[0], "AXPosition"), _attr(hits[0], "AXSize")
            if pos is None or size is None:
                raise _plan.Refused(f"slot {slot!r} reports no AX frame")
            _, p = AX.AXValueGetValue(pos, AX.kAXValueCGPointType, None)
            _, z = AX.AXValueGetValue(size, AX.kAXValueCGSizeType, None)
            sx, sy = p.x + z.width / 2, p.y + z.height / 2
            mouse(Quartz.kCGEventMouseMoved, sx, sy); mouse(Quartz.kCGEventLeftMouseDown, sx, sy)
            time.sleep(hold_ms / 1000.0 if hold_ms else 0.05)
            mouse(Quartz.kCGEventLeftMouseUp, sx, sy)
            time.sleep(0.5)
        elif k == "read":
            out = os.path.join(os.environ.get("TMPDIR", "/tmp"), "jas-l2-read.json")
            if os.path.exists(out): os.remove(out)
            _fifo(_plan.fifo_read_command(act, out))
            for _ in range(30):
                if os.path.exists(out): break
                time.sleep(0.1)
            else:
                raise _plan.Refused(f"the app wrote no {act[1]} read (is --test-fifo the same path as JAS_FIFO? "
                                    "a refused state read is in the app's log)")
            st["reads"].append(_plan.compare_read(act, open(out, encoding="utf-8").read().strip(), want))

    _plan.run_guarded(acts, blocked, do_act)
    # Every read must pass; a FAIL shows each read's got and want.
    reads = st["reads"]
    return (all(r[0] for r in reads), " | ".join(r[1] for r in reads), " | ".join(r[2] for r in reads))

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

def _claimed():
    """The owner's claim on this box (mac_l2_plan.claim_check), or None. Read
    before EVERY console step on every route: a launch, an act, a reset, a drag."""
    return _plan.claim_check(os.environ, time.time())

def _claim_gate():
    why = _claimed()
    if why:
        raise _plan.Refused(why)

def _claim_banner():
    if _plan.claim_check_off(os.environ):
        print("CLAIM CHECK OFF (JAS_CLAIM_FILE=none): the owner's claim on this box is NOT read")

def _screen_locked():
    d = Quartz.CGSessionCopyCurrentDictionary()
    return bool(d and d.get("CGSSessionScreenIsLocked"))

def _front_is_jas():
    from AppKit import NSWorkspace
    app = NSWorkspace.sharedWorkspace().frontmostApplication()
    return app is not None and app.localizedName() == PROC

def _write_receipt(path, outcomes, not_run=None, suite="mac.live"):
    """`--receipt FILE`: the run's UI-NIGHTLY v1 line (O100), written whole or
    not at all. The corpus is `test_fixtures/input_scripts`; `head` is this
    tree's HEAD (JAS_HEAD overrides it, for an app built from another sha)."""
    import datetime
    repo = os.path.dirname(os.path.abspath(__file__))
    d = os.path.join(repo, "test_fixtures", "input_scripts")
    corpus = sorted(f for f in os.listdir(d) if f.endswith(".json") and not f.endswith(".expected.json"))
    head = os.environ.get("JAS_HEAD") or subprocess.run(
        ["git", "-C", repo, "rev-parse", "--short=8", "HEAD"], capture_output=True, text=True,
        encoding="utf-8").stdout.strip()
    date = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    try:
        line = _plan.receipt_line(outcomes, corpus, head or "unknown", date, not_run=not_run, suite=suite)
    except ValueError as e:
        print(f"RECEIPT NOT WRITTEN: {e}")
        return False
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        f.write(line + "\n")
    os.replace(tmp, path)
    print("RECEIPT " + line)
    return True

def do_script(paths, receipt=None, locked=False):
    global _plan
    import mac_l2_plan as _plan
    if locked:
        return _do_script_locked(paths, receipt)
    problem = _plan.launch_env_problem(os.environ)
    if problem:
        print("REFUSED: " + problem)
        if receipt:
            _write_receipt(receipt, {}, not_run=problem)
        return 3
    _claim_banner()
    why = _claimed()
    if why:
        print("REFUSED: " + why)
        if receipt:
            _write_receipt(receipt, {}, not_run=why)
        return 3
    if _screen_locked():
        print("REFUSED: the screen is locked; a key event would type into the login window")
        if receipt:
            _write_receipt(receipt, {}, not_run="the screen is locked")
        return 3
    busy, idle = _console_in_use()
    if busy:
        print(f"REFUSED: the console saw input {idle:.0f} s ago (floor {IDLE_FLOOR_S} s); a person may be using it")
        if receipt:
            _write_receipt(receipt, {}, not_run=f"console input {idle:.0f} s ago")
        return 3
    menubar = _plan.load_menubar()
    bad = 0
    outcomes = {}
    for p in paths:
        name = os.path.basename(p)
        proc = None
        try:
            _claim_gate()
            if _screen_locked():
                raise _plan.Refused("the screen is locked")
            clear_mods()  # a flag-carrying event leaks its modifier into the next script
            if os.environ.get("JAS_APP"):
                proc = _launch()
            ok, got, want = _run_script(p, menubar)
            print(("PASS " if ok else "FAIL ") + name)
            outcomes[name] = "PASS" if ok else "FAIL"
            if not ok:
                bad += 1
                print("  got  ", got); print("  want ", want)
        except _plan.Refused as e:
            bad += 1
            outcomes[name] = "REFUSED"
            print("REFUSED " + name + ": " + str(e))
        finally:
            if not _screen_locked():
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
    if receipt and not _write_receipt(receipt, outcomes):
        return 4
    return 1 if bad else 0

def _do_script_locked(paths, receipt):
    """`script --locked` (row 250): each script in a FRESH app (JAS_APP), its
    pointer runs through the FIFO's `gesture`, its reads through `read`. Runs
    whether or not the console is locked, because nothing on this route
    reaches the window server; so there is no person check and no modifier
    reset. NOT witnessed: the window's first-mouse and key routing.

    With `--receipt FILE` (row 252) the run is the board's `mac.locked` suite:
    a given script that is not a member (a key, menu, toolbar or panel step;
    mac_l2_plan.locked_suite_split) is REFUSED by name before any app launch
    and left out of the receipt, and the line counts the members only, with
    scope=partial while any corpus script is not a member. A run refused
    before any script writes NOT RUN, so a refused night is a row."""
    suite = _plan.LOCKED_SUITE
    if not os.environ.get("JAS_APP") or not os.environ.get("JAS_FIFO"):
        why = "--locked needs JAS_APP, a fresh app per script by pid, and JAS_FIFO"
        print("REFUSED: " + why)
        if receipt:
            _write_receipt(receipt, {}, not_run=why, suite=suite)
        return 3
    _claim_banner()
    why = _claimed()
    if why:
        print("REFUSED: " + why)
        if receipt:
            _write_receipt(receipt, {}, not_run=why, suite=suite)
        return 3
    menubar = _plan.load_menubar()
    if receipt:
        scripts = {}
        for p in paths:
            with open(p, encoding="utf-8") as f:
                scripts[os.path.basename(p)] = _json.load(f)
        members, refused = _plan.locked_suite_split(scripts, menubar)
        for name in sorted(refused):
            print(f"REFUSED {name}: not in {suite}: {refused[name]}")
        paths = [p for p in paths if os.path.basename(p) in members]
    bad = 0
    outcomes = {}
    for p in paths:
        name = os.path.basename(p)
        proc = None
        try:
            _claim_gate()
            proc = _launch(locked=True)
            ok, got, want = _run_script(p, menubar, locked=True, pid=proc.pid)
            print(("PASS " if ok else "FAIL ") + name)
            outcomes[name] = "PASS" if ok else "FAIL"
            if not ok:
                bad += 1
                print("  got  ", got); print("  want ", want)
        except _plan.Refused as e:
            bad += 1
            outcomes[name] = "REFUSED"
            print("REFUSED " + name + ": " + str(e))
        finally:
            if proc is not None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                time.sleep(0.3)
    print(f"{len(paths) - bad} of {len(paths)} scripts passed (locked route: first-mouse and key routing not witnessed)")
    if receipt and not _write_receipt(receipt, outcomes, suite=suite):
        return 4
    return 1 if bad else 0

# ── `dock`: the dock check on the Mac (row 89; the web channel's is
# scripts/web_l2_driver.py --dock). The cases, the band, the layout reader and
# the verdict are mac_l2_plan's, so both channels read a dock by one law. Each
# case drags a dock tab with an AppKit drag session (`.onDrag` on the tab, the
# pane container's `.onDrop`) and passes only when the engine layout (the FIFO
# `layout` verb) AND the drawn edge dock (AXIdentifier jas-edge-dock-<edge>)
# agree. NOT MEASURED until the Mac lane runs it: whether posted HID events complete
# an `.onDrag` session at all. A session that never starts leaves the layout
# unchanged, which the verdict reports as a FAIL by name, never a PASS.
def _layout_read():
    out = os.path.join(os.environ.get("TMPDIR", "/tmp"), "jas-l2-layout.json")
    if os.path.exists(out): os.remove(out)
    _fifo("layout " + out)
    for _ in range(30):
        if os.path.exists(out): break
        time.sleep(0.1)
    else:
        raise _plan.Refused("the app wrote no layout (is this app built with the test-fifo `layout` verb?)")
    return open(out, encoding="utf-8").read().strip()

def _frame(el):
    AX = _ax()
    pos, size = _attr(el, "AXPosition"), _attr(el, "AXSize")
    if pos is None or size is None:
        raise _plan.Refused(f"{_attr(el, 'AXIdentifier')!r} reports no frame")
    _, p = AX.AXValueGetValue(pos, AX.kAXValueCGPointType, None)
    _, s = AX.AXValueGetValue(size, AX.kAXValueCGSizeType, None)
    return p.x, p.y, s.width, s.height

def _session_drag(x1, y1, waypoints):
    # An AppKit drag session starts only after the button has been held and the
    # pointer has moved past the drag threshold, so: settle after the press,
    # nudge a few points, then walk each leg in small steps and hold before
    # the release so the drop target sees the final position.
    mouse(Quartz.kCGEventMouseMoved, x1, y1); time.sleep(0.05)
    mouse(Quartz.kCGEventLeftMouseDown, x1, y1); time.sleep(0.25)
    for i in range(1, 5):
        mouse(Quartz.kCGEventLeftMouseDragged, x1 + 2 * i, y1); time.sleep(0.03)
    a = (x1 + 8, y1)
    for b in waypoints:
        for i in range(1, 17):
            mouse(Quartz.kCGEventLeftMouseDragged, a[0] + (b[0] - a[0]) * i / 16, a[1] + (b[1] - a[1]) * i / 16)
            time.sleep(0.02)
        a = b
    time.sleep(0.3)
    mouse(Quartz.kCGEventLeftMouseUp, *a); time.sleep(0.5)

def _drawn_counts(app, tab_id):
    out = {}
    for e in _plan.DOCK_EDGES:
        docks = _by_id(app, _plan.edge_dock_id(e))
        if len(docks) > 1:
            raise _plan.Refused(f"{len(docks)} elements carry {_plan.edge_dock_id(e)!r}")
        out[e] = len(_by_id(docks[0], tab_id)) if docks else 0
    return out

def _dock_case(kind, edge, via):
    global WIN
    before = _layout_read()
    why = _plan.dock_start_refusal(before, kind)
    if why:
        return "REFUSED", why
    WIN = find_window()
    if not WIN:
        raise _plan.Refused(f"no window titled {TITLE!r}")
    vw, vh = _plan.viewport_size(before)
    ox, oy = _plan.viewport_origin(WIN, vw, vh)
    app = _app_element()
    tab_id = kind + _plan.PANEL_SUFFIX + _plan.TAB_SUFFIX
    tabs = _by_id(app, tab_id)
    if len(tabs) != 1:
        return "REFUSED", f"{len(tabs)} elements carry AXIdentifier {tab_id!r}"
    tx, ty, tw, th = _frame(tabs[0])
    band = _plan.snap_distance()
    legs = [_plan.dock_point(via, vw, vh, band)] if via else []
    legs.append(_plan.dock_point(edge, vw, vh, band) if edge else (vw / 2, vh / 2))
    _claim_gate()
    pts = [(ox + px, oy + py) for px, py in legs]
    why = _plan.outside_window(WIN, ("press", tx + tw / 2, ty + th / 2),
                               *[(f"drop {i}", x, y) for i, (x, y) in enumerate(pts)])
    if why:
        return "REFUSED", why
    _session_drag(tx + tw / 2, ty + th / 2, pts)
    after = _layout_read()
    return _plan.dock_verdict(before, after, kind, edge, _drawn_counts(app, tab_id))

def do_dock():
    """One DOCK line (the web channel's form). Each case gets a fresh app, as
    each web case gets a fresh page: a case's start is the default layout."""
    global _plan
    import mac_l2_plan as _plan
    problem = _plan.launch_env_problem(os.environ)
    if problem or not os.environ.get("JAS_APP"):
        print("REFUSED: " + (problem or "the dock check needs JAS_APP: each case starts from a fresh app"))
        print("DOCK NOT RUN")
        return 3
    _claim_banner()
    why = _claimed()
    if why:
        print("REFUSED: " + why); print("DOCK NOT RUN"); return 3
    if _screen_locked():
        print("REFUSED: the screen is locked"); print("DOCK NOT RUN"); return 3
    busy, idle = _console_in_use()
    if busy:
        print(f"REFUSED: the console saw input {idle:.0f} s ago (floor {IDLE_FLOOR_S} s)"); print("DOCK NOT RUN")
        return 3
    cases = []
    for kind, edge, via in _plan.DOCK_CASES:
        proc = None
        try:
            _claim_gate()
            clear_mods()
            proc = _launch()
            status, detail = _dock_case(kind, edge, via)
        except _plan.Refused as e:
            status, detail = "REFUSED", str(e)
        except Exception as e:
            status, detail = "REFUSED", f"driver error: {type(e).__name__}: {str(e).splitlines()[0] if str(e) else ''}"
        finally:
            if proc is not None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                time.sleep(0.3)
        cases.append((kind, edge, status, detail))
        print(f"{status} {kind}->{edge or 'float'}" + (f" -- {detail}" if detail else ""))
    with open(_lastpost_file(), "w", encoding="utf-8", newline="") as f:
        f.write(str(time.time()))
    line = _plan.dock_line(cases)
    print(line)
    return 0 if line.startswith("DOCK ") and not line.startswith(("DOCK RED", "DOCK NOT")) else 1

# ── `dock --groups`: sheet 2's three drops inside the right dock (row 255). The
# targets and verdicts are mac_l2_plan's (group_case_targets/_verdict), measured
# on the Mac test box 11-23 (all three read A). Each case gets a fresh app AND a
# reset workspace: the app persists its dock layout, so a fresh process alone
# starts where the last case left it (row 254).
GROUP_TABS = ("align", "swatches", "color", "character", "stroke")

def _right_groups(layout_text):
    lay = _json.loads(layout_text)
    right = [a for a in lay.get("anchored", []) if a.get("edge") == "right"]
    if len(right) != 1:
        raise _plan.Refused(f"{len(right)} right docks in the layout; the group cases need one")
    return [list(p if isinstance(p, str) else next(iter(p)) for p in g["panels"]) for g in right[0]["dock"]["groups"]]

def _group_case(case):
    global WIN
    _claim_gate()
    _fifo("action reset_workspace"); time.sleep(1.0)
    WIN = find_window()
    if not WIN:
        raise _plan.Refused(f"no window titled {TITLE!r}")
    before = _right_groups(_layout_read())
    app = _app_element()
    frames = {}
    for kind in GROUP_TABS:
        tid = kind + _plan.PANEL_SUFFIX + _plan.TAB_SUFFIX
        hits = _by_id(app, tid)
        if len(hits) == 1:
            frames[tid] = _frame(hits[0])
    (x1, y1), (x2, y2) = _plan.group_case_targets(case, frames)
    why = _plan.outside_window(WIN, ("press", x1, y1), ("drop", x2, y2))
    if why:
        raise _plan.Refused(f"{case}: {why}")
    _claim_gate()
    _session_drag(x1, y1, [(x2, y2)])
    return _plan.group_case_verdict(case, before, _right_groups(_layout_read()))

def do_dock_groups():
    """One DOCKGROUPS line. Refuses, as `dock` does, on a locked or busy console."""
    global _plan
    import mac_l2_plan as _plan
    problem = _plan.launch_env_problem(os.environ)
    if problem or not os.environ.get("JAS_APP"):
        print("REFUSED: " + (problem or "the group cases need JAS_APP: each starts from a fresh app"))
        print("DOCKGROUPS NOT RUN"); return 3
    _claim_banner()
    why = _claimed()
    if why:
        print("REFUSED: " + why); print("DOCKGROUPS NOT RUN"); return 3
    if _screen_locked():
        print("REFUSED: the screen is locked"); print("DOCKGROUPS NOT RUN"); return 3
    busy, idle = _console_in_use()
    if busy:
        print(f"REFUSED: the console saw input {idle:.0f} s ago (floor {IDLE_FLOOR_S} s)"); print("DOCKGROUPS NOT RUN")
        return 3
    cases = []
    for case in _plan.GROUP_CASES:
        proc = None
        try:
            _claim_gate()
            clear_mods()
            proc = _launch()
            status, detail = _group_case(case)
        except _plan.Refused as e:
            status, detail = "REFUSED", str(e)
        except Exception as e:
            status, detail = "REFUSED", f"driver error: {type(e).__name__}: {str(e).splitlines()[0] if str(e) else ''}"
        finally:
            if proc is not None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                time.sleep(0.3)
        cases.append((case, status, detail))
        print(f"{status} {case}" + (f" -- {detail}" if detail else ""))
    with open(_lastpost_file(), "w", encoding="utf-8", newline="") as f:
        f.write(str(time.time()))
    line = _plan.group_line(cases)
    print(line)
    return 0 if line.startswith("DOCKGROUPS ") and not line.startswith(("DOCKGROUPS RED", "DOCKGROUPS NOT")) else 1

# ── `layers`: row 208's R1 and R4 through the Layers tree, one LAYERS line
# (row 256). The method is the 11-24 slot's (slot-1124g/v4b on the Mac test
# box, both A), and the verdicts, the cases and the fixture are mac_l2_plan's
# (layers_*), which derive what they expect from the document read before
# each act. Each case gets a fresh app and a reset workspace, as `dock
# --groups` does. Between acts the driver stops at once on a person's input
# (an HID event later than its own last one) as well as on the owner's claim.
def _person_gate():
    _claim_gate()
    idle = Quartz.CGEventSourceSecondsSinceLastEventType(
        Quartz.kCGEventSourceStateHIDSystemState, Quartz.kCGAnyInputEventType)
    mine = _LAST_MINE[0]
    if mine is not None and idle < (time.time() - mine) - 1.0:
        raise _plan.Refused(f"a person's input {idle:.1f} s ago, after the driver's last event")

def _fifo_json(cmd, tag):
    """Send `cmd` with {out} replaced by a fresh file and return the JSON the
    app writes there; a missing or unparseable reply refuses by name."""
    out = os.path.join(os.environ.get("TMPDIR", "/tmp"), f"jas-l2-layers-{tag}.json")
    if os.path.exists(out):
        os.remove(out)
    _fifo(cmd.format(out=out))
    for _ in range(40):
        if os.path.exists(out):
            try:
                return _json.load(open(out, encoding="utf-8"))
            except ValueError:
                pass  # still being written
        time.sleep(0.1)
    raise _plan.Refused(f"the app wrote no reply to FIFO `{cmd.split()[0]}` within 4 s")

def _layers_state(tag):
    return _plan.layers_reduce(_fifo_json("read {out}", tag + "-doc"),
                               _fifo_json("state {out} panel.layers.layers_panel_selection", tag + "-psel"))

def _layers_rows(app):
    """Every AX element under the Layers panel that carries text, with its
    frame, top to bottom (the panel lists the TOP layer first)."""
    roots = _by_id(app, "layers_panel_content")
    if len(roots) != 1:
        raise _plan.Refused(f"{len(roots)} elements carry 'layers_panel_content'")
    out = []
    for el in _find_all(roots[0], lambda e: True, limit=5000):
        txt = " ".join(str(_attr(el, a)) for a in ("AXTitle", "AXValue", "AXDescription") if _attr(el, a) is not None)
        if not txt:
            continue
        try:
            f = _frame(el)
        except _plan.Refused:
            continue
        out.append((txt, f))
    return sorted(out, key=lambda r: r[1][1])

def _row_point(f):
    x, y, w, h = f
    return x + min(w / 2, 40), y + h / 2

def _layer_row(rows, name):
    hits = [f for t, f in rows if name.lower() in t.lower()]
    if not hits:
        raise _plan.Refused(f"no Layers row reads {name!r}")
    return hits[0]

def _shape_row(rows, layer_name, child_type):
    """The first row below `layer_name`'s row that names a shape of `child_type`."""
    top = _layer_row(rows, layer_name)[1]
    for t, f in rows:
        if f[1] > top + 2 and (child_type.lower() in t.lower() or t.startswith("<")):
            return f
    raise _plan.Refused(f"no {child_type} row under {layer_name!r} in the Layers tree")

def _hover(x, y):
    mouse(Quartz.kCGEventMouseMoved, x - 6, y); time.sleep(0.1)
    mouse(Quartz.kCGEventMouseMoved, x, y); time.sleep(0.4)

def _row_click(f, cmd=False):
    _person_gate()
    x, y = _row_point(f)
    _hover(x, y)
    fl = Quartz.kCGEventFlagMaskCommand if cmd else 0
    if cmd:
        keyev(MODKEY["cmd"], True, fl); time.sleep(0.08)
    mouse(Quartz.kCGEventLeftMouseDown, x, y, fl); time.sleep(0.05)
    mouse(Quartz.kCGEventLeftMouseUp, x, y, fl); time.sleep(0.4)
    if cmd:
        keyev(MODKEY["cmd"], False); time.sleep(0.08)

def _row_right_click(f):
    _person_gate()
    x, y = _row_point(f)
    _hover(x, y)
    for t in (Quartz.kCGEventRightMouseDown, Quartz.kCGEventRightMouseUp):
        _LAST_MINE[0] = time.time()
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, Quartz.CGEventCreateMouseEvent(None, t, (x, y), Quartz.kCGMouseButtonRight))
        time.sleep(0.05)
    time.sleep(0.8)

def _layers_open():
    """Reset the workspace, open the fixture, show the Layers tab and scroll
    the dock until the layer rows sit inside the window (AX reports frames for
    rows the window clips; slot 2, 11-23)."""
    global WIN
    _person_gate()
    _fifo("action reset_workspace"); time.sleep(1.2)
    _fifo("open " + os.path.join(os.path.dirname(os.path.abspath(__file__)), _plan.LAYERS_FIXTURE)); time.sleep(1.5)
    app = _app_element()
    tabs = _by_id(app, "layers_panel_content_tab")
    if len(tabs) != 1:
        raise _plan.Refused(f"{len(tabs)} elements carry 'layers_panel_content_tab'")
    _person_gate()
    _press(tabs[0]); time.sleep(1.0)
    WIN = find_window()
    if not WIN:
        raise _plan.Refused(f"no window titled {TITLE!r}")
    before = _layers_state("before")
    names = [n for n, _ in before["layers"]]
    limit = min(Quartz.CGDisplayBounds(Quartz.CGMainDisplayID()).size.height, WIN["y"] + WIN["h"]) - 8
    anchor = _by_id(app, "align_panel_content_tab")
    if len(anchor) != 1:
        raise _plan.Refused(f"{len(anchor)} elements carry 'align_panel_content_tab' (the scroll point)")
    ax, ay, _, _ = _frame(anchor[0])
    sx, sy = ax + 40, min(ay + 200, limit / 2)

    def bottom():
        ys = [f[1] + f[3] for t, f in _layers_rows(app) if any(n in t for n in names) or t.startswith("<")]
        return max(ys) if ys else None
    b, step = bottom(), -5
    for _ in range(14):
        if b is not None and b < limit:
            break
        _person_gate()
        _hover(sx, sy)
        _LAST_MINE[0] = time.time()
        Quartz.CGEventPost(Quartz.kCGHIDEventTap,
                           Quartz.CGEventCreateScrollWheelEvent(None, Quartz.kCGScrollEventUnitLine, 1, step))
        time.sleep(0.5)
        nb = bottom()
        if nb is not None and b is not None and nb >= b:
            step = -step  # the wheel moved the wrong way (or not at all): flip once measured
        b = nb
    if b is None or b >= limit:
        raise _plan.Refused(f"the Layers rows stay below the window ({b} >= {limit}) after scrolling")
    return app, before

def _layers_r1():
    app, before = _layers_open()
    first, last = before["layers"][0][0], before["layers"][-1][0]
    kids = before["layers"][0][1]
    if not kids:
        raise _plan.Refused(f"the fixture's bottom layer {first!r} has no shape to right-click")
    _row_click(_layer_row(_layers_rows(app), last))       # the selection the right-click must replace
    rows = _layers_rows(app)
    _row_right_click(_shape_row(rows, first, kids[0]))
    menu = _fifo_json("menu {out}", "r1-menu")
    items = _find_all(app, lambda e: _attr(e, "AXRole") == "AXMenuItem" and str(_attr(e, "AXTitle")) == "Duplicate",
                      limit=20000)
    _person_gate()
    if items:
        _press(items[0])
    else:
        do_key("escape", [])
    time.sleep(0.8)
    return _plan.layers_r1_verdict(before, menu, _layers_state("r1-after"), (0, 0))

def _layers_r4():
    app, before = _layers_open()
    last, kids = before["layers"][-1]
    first = before["layers"][0][0]
    if not kids:
        raise _plan.Refused(f"the fixture's top layer {last!r} has no shape for the control")
    _row_click(_shape_row(_layers_rows(app), last, kids[0]))
    _person_gate(); do_key("delete", []); time.sleep(0.6)
    control = _layers_state("r4-control")
    if control["layers"][-1] == (last, kids[1:]):
        _person_gate(); do_key("z", ["cmd"]); time.sleep(0.6)
        rows = _layers_rows(app)
        for i, (name, _) in enumerate(reversed(before["layers"])):
            _row_click(_layer_row(rows, name), cmd=i > 0)
        selected = _layers_state("r4-selected")
        _person_gate(); do_key("delete", []); time.sleep(0.8)
        after = _layers_state("r4-after")
    else:
        selected = after = control  # the verdict reads NO KEY from the control alone
    return _plan.layers_r4_verdict(before, control, selected, after)

def _top_row(app, before):
    return _layer_row(_layers_rows(app), before["layers"][-1][0])

def _layers_r5():
    app, before = _layers_open()
    _row_click(_top_row(app, before))
    clicked = _layers_state("r5-click")
    _person_gate(); do_key("down", []); time.sleep(0.6)
    down = _layers_state("r5-down")
    _person_gate(); do_key("up", []); time.sleep(0.6)
    return _plan.layers_r5_verdict(before, clicked, down, _layers_state("r5-up"))

def _layers_r6():
    app, before = _layers_open()
    _row_click(_top_row(app, before))
    clicked = _layers_state("r6-click")
    _person_gate(); do_key("a", ["cmd"]); time.sleep(0.6)
    return _plan.layers_r6_verdict(before, clicked, _layers_state("r6-after"))

def _renaming(tag):
    return _fifo_json("state {out} panel.layers.renaming_element", tag)

def _type_key(ch):
    _person_gate()
    keyev(KEYCODE[ch], True); time.sleep(0.05); keyev(KEYCODE[ch], False); time.sleep(0.8)

R7_TYPED = "x"

def _layers_r7():
    app, before = _layers_open()
    x, y = _row_point(_top_row(app, before))
    _person_gate(); _hover(x, y)
    for n in (1, 2):  # a real double-click: the second press carries click state 2
        for t in (Quartz.kCGEventLeftMouseDown, Quartz.kCGEventLeftMouseUp):
            ev = Quartz.CGEventCreateMouseEvent(None, t, (x, y), Quartz.kCGMouseButtonLeft)
            Quartz.CGEventSetIntegerValueField(ev, Quartz.kCGMouseEventClickState, n)
            _LAST_MINE[0] = time.time()
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev); time.sleep(0.04)
    time.sleep(0.8)
    dbl = _renaming("r7-dbl")
    _type_key(R7_TYPED)
    _type_key("escape")
    dbl_esc = _renaming("r7-dbl-esc")
    dbl_names = [n for n, _ in _layers_state("r7-dbl-names")["layers"]]
    _row_click(_layer_row(_layers_rows(app), before["layers"][0][0]))
    _type_key("return")
    enter = _renaming("r7-enter")
    _type_key(R7_TYPED)
    _type_key("return")
    enter_ret = _renaming("r7-enter-ret")
    enter_names = [n for n, _ in _layers_state("r7-enter-names")["layers"]]
    return _plan.layers_r7_verdict(before, R7_TYPED, dbl, dbl_esc, dbl_names, enter, enter_ret, enter_names)

def do_layers():
    """One LAYERS line. Refuses, as `dock` does, on a claim, a locked or a busy console."""
    global _plan
    import mac_l2_plan as _plan
    problem = _plan.launch_env_problem(os.environ)
    if problem or not os.environ.get("JAS_APP"):
        print("REFUSED: " + (problem or "the layers cases need JAS_APP: each starts from a fresh app"))
        print("LAYERS NOT RUN"); return 3
    _claim_banner()
    why = _claimed()
    if why:
        print("REFUSED: " + why); print("LAYERS NOT RUN"); return 3
    if _screen_locked():
        print("REFUSED: the screen is locked"); print("LAYERS NOT RUN"); return 3
    busy, idle = _console_in_use()
    if busy:
        print(f"REFUSED: the console saw input {idle:.0f} s ago (floor {IDLE_FLOOR_S} s)"); print("LAYERS NOT RUN")
        return 3
    run = {"R1": _layers_r1, "R4": _layers_r4, "R5": _layers_r5, "R6": _layers_r6, "R7": _layers_r7}
    cases = []
    for case in _plan.LAYERS_CASES:
        proc = None
        try:
            _claim_gate()
            clear_mods()
            proc = _launch()
            status, detail = run[case]()
        except _plan.Refused as e:
            status, detail = "REFUSED", str(e)
        except Exception as e:
            status, detail = "REFUSED", f"driver error: {type(e).__name__}: {str(e).splitlines()[0] if str(e) else ''}"
        finally:
            if proc is not None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                time.sleep(0.3)
        cases.append((case, status, detail))
        print(f"{status} {case}" + (f" -- {detail}" if detail else ""))
        if status == "REFUSED" and detail.startswith(("a person's input", "the owner")):
            break  # a person or the owner is at the box: stop at once, the line reads RED
    clear_mods()
    with open(_lastpost_file(), "w", encoding="utf-8", newline="") as f:
        f.write(str(time.time()))
    line = _plan.layers_line(cases)
    print(line)
    return 0 if line.startswith("LAYERS ") and not line.startswith(("LAYERS RED", "LAYERS NOT")) else 1

if __name__=="__main__":
    v=sys.argv[1]
    if v=="dock" and sys.argv[2:3]==["--groups"]:
        sys.exit(do_dock_groups())
    if v=="dock":
        sys.exit(do_dock())
    if v=="layers":
        sys.exit(do_layers())
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
        args=sys.argv[2:]
        receipt=None
        locked=False
        if args[:1]==["--locked"]:
            locked, args = True, args[1:]
        if args[:1]==["--receipt"]:
            if len(args)<2: print("--receipt names a file"); sys.exit(2)
            receipt, args = args[1], args[2:]
        paths=[a for a in args if not a.endswith(".expected.json")]
        sys.exit(do_script(paths, receipt, locked))
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
