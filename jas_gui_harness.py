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

Verbs:
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
# When set (export JAS_TITLE=...), find the window by its TITLE (kCGWindowName)
# instead of the shared owner name — deterministic across instances / menu-bar
# strips. Launch the app with `--title <JAS_TITLE>`.
TITLE = os.environ.get("JAS_TITLE")
KEYCODE = {  # ANSI virtual keycodes
 'a':0,'s':1,'d':2,'f':3,'h':4,'g':5,'z':6,'x':7,'c':8,'v':9,'b':11,'q':12,'w':13,
 'e':14,'r':15,'y':16,'t':17,'o':31,'u':32,'i':34,'p':35,'l':37,'j':38,'k':40,'n':45,'m':46,
 '=':24,'-':27,'space':49,'delete':51,'escape':53,'return':36,
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
            match = (name == TITLE) if TITLE else (APP.lower() in owner.lower())
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

def do_click(fx, fy):
    x,y=pt(fx,fy); mouse(Quartz.kCGEventMouseMoved,x,y)
    mouse(Quartz.kCGEventLeftMouseDown,x,y); time.sleep(0.06); mouse(Quartz.kCGEventLeftMouseUp,x,y)

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

def do_dragbegin(fx1,fy1,fx2,fy2):
    # Mouse down at start, drag to end, but LEAVE the button held (the HID
    # button state persists across processes). Use dragend to release.
    x1,y1=pt(fx1,fy1); x2,y2=pt(fx2,fy2)
    mouse(Quartz.kCGEventMouseMoved,x1,y1)
    mouse(Quartz.kCGEventLeftMouseDown,x1,y1); time.sleep(0.05)
    N=12
    for i in range(1,N+1):
        x=x1+(x2-x1)*i/N; y=y1+(y2-y1)*i/N
        mouse(Quartz.kCGEventLeftMouseDragged,x,y); time.sleep(0.015)

def do_dragend(fx,fy):
    x,y=pt(fx,fy); mouse(Quartz.kCGEventLeftMouseUp,x,y)

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

def do_shot(path):
    subprocess.run(f"screencapture -o -l{WIN['id']} {path}", shell=True)

if __name__=="__main__":
    v=sys.argv[1]
    if v=="activate":
        # Unminimize + frontmost WITHOUT clicking (title-bar clicks risk a
        # double-click-minimize). Does NOT require the window to be found.
        subprocess.run(["osascript",
            "-e",'tell application "System Events" to tell (first process whose name is "Jas") to set value of attribute "AXMinimized" of every window to false',
            "-e",'tell application "System Events" to set frontmost of (first process whose name is "Jas") to true'])
        time.sleep(0.3)
        print("activated"); sys.exit(0)
    if v=="clearmods":
        clear_mods(); print("mods cleared"); sys.exit(0)
    if not WIN: print("WINDOW NOT FOUND"); sys.exit(1)
    if v=="geom": print(WIN)
    elif v=="shot": do_shot(sys.argv[2]); print("shot",sys.argv[2])
    elif v=="click": do_click(float(sys.argv[2]),float(sys.argv[3])); print("click",sys.argv[2],sys.argv[3])
    elif v=="key":
        mods=sys.argv[3].split(",") if len(sys.argv)>3 else []
        do_key(sys.argv[2],mods); print("key",sys.argv[2],mods)
    elif v=="drag":
        mods=sys.argv[6].split(",") if len(sys.argv)>6 else []
        do_drag(*[float(a) for a in sys.argv[2:6]],mods); print("drag",sys.argv[2:6],mods)
    elif v=="dragbegin":
        do_dragbegin(*[float(a) for a in sys.argv[2:6]]); print("dragbegin",sys.argv[2:6])
    elif v=="dragend":
        do_dragend(float(sys.argv[2]),float(sys.argv[3])); print("dragend",sys.argv[2:4])
    elif v=="dragpath":
        nums=[float(a) for a in sys.argv[2:]]
        points=list(zip(nums[0::2],nums[1::2]))
        do_dragpath(points); print("dragpath",points)
    else:
        print("unknown verb:", v); sys.exit(2)
