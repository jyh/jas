#!/usr/bin/env python3
"""GUIEYES — the Swift lane: window capture + measurable pixel assertions.

STATUS: PARTIAL, and honestly so. See §Swift in GUI_EYES.md.

WHAT WORKS HERE
---------------
The PIXEL half of the Swift lane, reusing the same measurement vocabulary the
Rust lane asserts with (`region_stats`, `stats_distance`, `decode_png` from
`gui_probe.py`), so a Swift claim and a Rust claim are comparable numbers
rather than two dialects:

  * `find_window(title)`  — locate a window by exact `kCGWindowName`, no
                            raising and no focus stealing;
  * `capture(win)`        — `screencapture -x -o -l<id>` of that ONE window,
                            which works even when the window is occluded or
                            in the background;
  * `region_stats(png)`   — mean RGB / distinct colours / digest of a crop, in
                            window-relative points (Retina scale handled);
  * `ink_span(png, ...)`  — thickness of a rendered stroke along a scanline,
                            the same metric that catches a 5pt stroke coming
                            back 1pt.

Launch a drivable instance with:
    ./swift.sh --title JasHarness --test-fifo /tmp/jas-harness.fifo
(`swift.sh` forwards arguments as of this wave; it previously swallowed them.)
Input injection is `jas_gui_harness.py` (pyobjc Quartz `CGEventPost`) plus the
`--test-fifo` verbs `tool <id>` / `action <name> [json]`.

WHAT IS BLOCKED (the Zeno line)
-------------------------------
READ-BACK. Swift has no equivalent of the Rust lane's `Runtime.evaluate`, so
the DECLARED half of every pair assertion is unavailable: nothing can ask the
running app "is this widget checked?". Two consequences:

  * `chain_visible` cannot be ported. Its whole power is comparing declared
    state against rendered pixels; with pixels only it degrades to an
    image-diff, which is what we set out to avoid.
  * The declared-behavior liveness sweep cannot be ported: there is no way to
    resolve a YAML widget id to a screen rect.

The unblock is one line per widget site — `.accessibilityIdentifier(widget.id)`
in `JasSwift/Sources/Interpreter/YamlPanelBodyView.swift` — after which the
already-granted Accessibility API gives Swift the same id-addressed reflection
CDP gives Rust (`osascript` System Events can already read another app's
UI-element roles and names; that was verified). That file is owned by a
parallel wave, so it is deliberately untouched here. The alternative
unblock is a `dump <what> <path>` fifo verb; the OCaml fifo's third verb
(`open_dialog`) is the precedent that this vocabulary is meant to grow.

PERMISSIONS: Screen Recording + Accessibility, both ALREADY GRANTED to iTerm
on this machine. They follow the terminal that launches Claude Code — from
Terminal.app / VS Code / the desktop app, that host needs the same two
toggles. Never call `CGRequestScreenCaptureAccess()`; it prompts.

BUT PERMISSION IS NOT ENOUGH: the lane also needs an UNLOCKED, AWAKE display on
the console. `screencapture` returns exit 0 but writes a blank frame under
`CGSSessionScreenIsLocked` or display sleep (verified on this host — permission
True, capture blank). `require_capturable_display()` preflights this and stops
with a NAMED message (exit 3) rather than measuring a black rectangle; run
`gui_probe_swift.py session` to see the current state.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gui_probe import ProbeFailure, decode_png  # noqa: E402

SCREENCAPTURE = "/usr/sbin/screencapture"


def list_windows() -> list[dict]:
    """Every on-screen window with a readable name, via CGWindowList."""
    try:
        import Quartz
    except ImportError:
        raise ProbeFailure(
            "pyobjc (Quartz) is required for the Swift lane; it is present in "
            "the repo .venv — run this with .venv/bin/python") from None
    out = []
    for w in Quartz.CGWindowListCopyWindowInfo(
            Quartz.kCGWindowListOptionOnScreenOnly
            | Quartz.kCGWindowListExcludeDesktopElements,
            Quartz.kCGNullWindowID) or []:
        name = w.get("kCGWindowName") or ""
        b = w.get("kCGWindowBounds") or {}
        out.append({"id": int(w.get("kCGWindowNumber", 0)),
                    "name": name,
                    "owner": w.get("kCGWindowOwnerName") or "",
                    "layer": int(w.get("kCGWindowLayer", 0)),
                    "x": b.get("X", 0), "y": b.get("Y", 0),
                    "w": b.get("Width", 0), "h": b.get("Height", 0)})
    return out


def capturable_windows() -> list[dict]:
    """Real, capturable APP windows only.

    A normal application window sits on window layer 0. Everything the harness
    must NOT target — the lock-screen `Display N Shield` pseudo-windows the
    Window Server puts up (verified on this host while locked), the menu bar,
    the Dock, Control Center items, the login window — is owned by the Window
    Server or lives on a non-zero layer. Capturing a shield "succeeds" and
    proves nothing, so selftest and any auto-pick must draw only from here.
    """
    return [w for w in list_windows()
            if w["layer"] == 0 and w["owner"] != "Window Server" and w["name"]]


class DisplayUnavailable(ProbeFailure):
    """The login session cannot be screen-captured right now (screen locked,
    display asleep, or fast-user-switched off the console)."""


def display_session_state() -> dict:
    """Whether this login session can actually be screen-captured right now."""
    try:
        import Quartz
    except ImportError:
        raise ProbeFailure(
            "pyobjc (Quartz) is required for the Swift lane; it is present in "
            "the repo .venv — run this with .venv/bin/python") from None
    d = Quartz.CGSessionCopyCurrentDictionary() or {}
    return {
        "locked": bool(d.get("CGSSessionScreenIsLocked", 0)),
        "on_console": bool(d.get("kCGSSessionOnConsoleKey", 0)),
        "asleep": bool(Quartz.CGDisplayIsAsleep(Quartz.CGMainDisplayID())),
    }


def require_capturable_display() -> dict:
    """Fail with a NAMED message if the display cannot be captured.

    `screencapture -l<id>` returns exit 0 but writes an unusable/black frame
    when the screen is LOCKED or the display is ASLEEP. Verified on this host:
    Screen-Recording permission preflights True, yet the capture is blank under
    `CGSSessionScreenIsLocked`. So the Swift lane needs more than the two
    permission toggles — it needs an unlocked, awake display on the console.
    Read that up front and say so, instead of measuring a black rectangle.
    """
    st = display_session_state()
    problems = []
    if st["locked"]:
        problems.append("the screen is LOCKED (CGSSessionScreenIsLocked)")
    if st["asleep"]:
        problems.append("the main display is ASLEEP (CGDisplayIsAsleep)")
    if not st["on_console"]:
        problems.append("this session is not on the console "
                        "(fast-user-switched away)")
    if problems:
        raise DisplayUnavailable(
            "the Swift lane needs an UNLOCKED, AWAKE display on the console: "
            + "; ".join(problems)
            + ". `screencapture` returns success but an unusable frame "
              "otherwise, so this is a named stop rather than a false green. "
              "Unlock the machine and keep the display awake, then retry.")
    return st


def find_window(title: str, exact: bool = True) -> dict:
    """Locate a window by name. Exact match by default.

    Exact because substring matching is how a harness ends up driving the
    wrong window (a browser tab whose title contains the app name). Launch
    the app with `--title JasHarness` and match that.
    """
    cands = [w for w in list_windows()
             if (w["name"] == title if exact else title in w["name"])]
    if not cands:
        names = sorted({w["name"] for w in list_windows() if w["name"]})
        raise ProbeFailure(
            f"no on-screen window named {title!r}. Launch one with "
            f"`./swift.sh --title {title}`. Visible window names: {names[:12]}")
    if len(cands) > 1:
        raise ProbeFailure(f"{len(cands)} windows named {title!r} "
                           f"(ids {[c['id'] for c in cands]}) — ambiguous")
    return cands[0]


def capture(window: dict, path: str) -> tuple[str, float]:
    """Capture ONE window to `path`. Returns (path, retina scale).

    `-x` no sound, `-o` no window shadow (a shadow would offset every
    subsequent crop coordinate), `-l<id>` that window only — which succeeds
    for background and occluded windows, so the app never has to be raised
    and JYH's focus is never stolen.
    """
    require_capturable_display()   # named stop if locked/asleep, never a blank
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    r = subprocess.run([SCREENCAPTURE, "-x", "-o", f"-l{window['id']}", path],
                       capture_output=True, text=True, encoding="utf-8")
    if r.returncode != 0 or not os.path.exists(path):
        raise ProbeFailure(f"screencapture -l{window['id']} failed: "
                           f"{r.stderr.strip() or 'no output file'}")
    w, _h, _rgba = decode_png(open(path, "rb").read())
    scale = round(w / window["w"], 4) if window["w"] else 1.0
    return path, scale


# ---------------------------------------------------------------------------
# Measurements over a captured PNG. Coordinates are WINDOW-RELATIVE POINTS;
# the Retina scale is applied here so a check reads the same on any display.
# ---------------------------------------------------------------------------

def _load(path: str) -> tuple[int, int, bytes]:
    with open(path, "rb") as f:
        return decode_png(f.read())


def region_stats(path: str, x: float, y: float, w: float, h: float,
                 scale: float = 1.0) -> dict:
    """Mean RGB / distinct colours / digest of one crop — the Rust lane's
    `GuiProbe.region_stats` contract, so the numbers are comparable."""
    iw, ih, rgba = _load(path)
    x0, y0 = int(x * scale), int(y * scale)
    x1, y1 = min(int((x + w) * scale), iw), min(int((y + h) * scale), ih)
    if x0 >= x1 or y0 >= y1:
        raise ProbeFailure(f"crop ({x},{y},{w},{h}) at scale {scale} is empty "
                           f"or outside the {iw}x{ih}px capture")
    sums, colors, n, crop = [0, 0, 0], set(), 0, bytearray()
    for py in range(y0, y1):
        row = (py * iw + x0) * 4
        chunk = rgba[row:row + (x1 - x0) * 4]
        crop += chunk
        for i in range(0, len(chunk), 4):
            sums[0] += chunk[i]
            sums[1] += chunk[i + 1]
            sums[2] += chunk[i + 2]
            colors.add(bytes(chunk[i:i + 3]))
            n += 1
    return {"px": n, "mean": [round(s / n, 2) for s in sums],
            "colors": len(colors),
            "digest": hashlib.sha1(bytes(crop)).hexdigest()[:12]}


def stats_distance(a: dict, b: dict) -> float:
    return round(sum(abs(x - y) for x, y in zip(a["mean"], b["mean"])), 2)


def ink_span(path: str, x: float, y: float, length: float, scale: float = 1.0,
             axis: str = "v", paper_min: int = 246) -> dict:
    """Thickness / presence of ink along a 1-px scanline of the capture.

    Same metric and same `paper_min` threshold as the Rust lane, so "the
    stroke is 6px thick" means the same thing in both apps.
    """
    iw, ih, rgba = _load(path)
    bits = []
    for i in range(int(length * scale)):
        px, py = (int(x * scale), int(y * scale) + i) if axis == "v" \
            else (int(x * scale) + i, int(y * scale))
        if not (0 <= px < iw and 0 <= py < ih):
            break
        o = (py * iw + px) * 4
        bits.append("1" if (rgba[o] < paper_min or rgba[o + 1] < paper_min
                            or rgba[o + 2] < paper_min) else "0")
    s = "".join(bits)
    longest = off = run = 0
    for i, c in enumerate(s):
        if c == "1":
            run += 1
            if run > longest:
                longest, off = run, i - run + 1
        else:
            run = 0
    return {"ink": round(s.count("1") / scale, 2),
            "longest": round(longest / scale, 2),
            "offset": round(off / scale, 2), "pattern": s}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("windows", help="list on-screen window names + ids")
    sub.add_parser("session", help="report display capturability (lock/sleep)")
    g = sub.add_parser("geom", help="print one window's id and bounds")
    g.add_argument("title")
    s = sub.add_parser("shot", help="capture one window to a PNG")
    s.add_argument("title")
    s.add_argument("path")
    st = sub.add_parser("stats", help="crop statistics of a captured PNG")
    st.add_argument("path")
    for a in ("x", "y", "w", "h"):
        st.add_argument(a, type=float)
    st.add_argument("--scale", type=float, default=1.0)
    ik = sub.add_parser("ink", help="scanline ink measurement of a PNG")
    ik.add_argument("path")
    for a in ("x", "y", "length"):
        ik.add_argument(a, type=float)
    ik.add_argument("--scale", type=float, default=1.0)
    ik.add_argument("--axis", default="v", choices=("v", "h"))
    sc = sub.add_parser("selftest",
                        help="prove the capture+measure chain on ANY window")
    sc.add_argument("--title", default=None)
    args = ap.parse_args()

    try:
        if args.cmd == "windows":
            for w in list_windows():
                if w["name"]:
                    cap = "cap " if (w["layer"] == 0
                                     and w["owner"] != "Window Server") else "    "
                    print(f"{cap}{w['id']:>7}  L{w['layer']:<3} "
                          f"{w['owner'][:18]:18s} "
                          f"{int(w['w'])}x{int(w['h'])}  {w['name'][:60]}")
        elif args.cmd == "session":
            st = display_session_state()
            ok = not (st["locked"] or st["asleep"]) and st["on_console"]
            print(f"locked={st['locked']} asleep={st['asleep']} "
                  f"on_console={st['on_console']} -> "
                  f"{'CAPTURABLE' if ok else 'NOT capturable'}")
            return 0 if ok else 3
        elif args.cmd == "geom":
            print(find_window(args.title))
        elif args.cmd == "shot":
            path, scale = capture(find_window(args.title), args.path)
            print(f"wrote {path} (retina scale {scale})")
        elif args.cmd == "stats":
            print(region_stats(args.path, args.x, args.y, args.w, args.h,
                               args.scale))
        elif args.cmd == "ink":
            print(ink_span(args.path, args.x, args.y, args.length, args.scale,
                           args.axis))
        elif args.cmd == "selftest":
            return selftest(args.title)
    except DisplayUnavailable as e:
        # Distinct from a measurement failure: the host cannot be captured at
        # all right now, so no verdict is possible (mirrors the Rust lane's
        # exit-3 "harness error, teeth unproven").
        print(f"UNAVAILABLE: {e}", file=sys.stderr)
        return 3
    except ProbeFailure as e:
        print(f"FAIL: {e}", file=sys.stderr)
        return 1
    return 0


def selftest(title: str | None) -> int:
    """Prove capture + decode + measure end to end WITHOUT launching the app.

    Uses whatever CAPTURABLE app window is available (the app when `--title` is
    given), so the Swift lane's measurement chain is verifiable on a host where
    the Swift build is not present — which is exactly the situation this wave
    was in.
    """
    require_capturable_display()   # named stop if the display is locked/asleep
    if title:
        wins = [find_window(title)]
    else:
        wins = [w for w in capturable_windows() if w["w"] > 200 and w["h"] > 200]
    if not wins:
        print("FAIL: no capturable app window (layer 0, not the Window Server) "
              "to self-test against — open any normal app window, or pass "
              "--title", file=sys.stderr)
        return 1
    win = wins[0]
    print(f"target: id={win['id']} {win['owner']!r} {win['name'][:40]!r} "
          f"{int(win['w'])}x{int(win['h'])}pt")
    tmp = os.path.join(tempfile.gettempdir(), "guieyes-swift-selftest.png")
    path, scale = capture(win, tmp)
    size = os.path.getsize(path)
    iw, ih, _ = _load(path)
    print(f"captured {size} bytes, {iw}x{ih}px, retina scale {scale}")
    if size < 1000:
        print("FAIL: capture is suspiciously small (blank?)", file=sys.stderr)
        return 1
    a = region_stats(path, 0, 0, 40, 40, scale)
    b = region_stats(path, win["w"] - 40, win["h"] - 40, 40, 40, scale)
    print(f"crop A (top-left)     {a}")
    print(f"crop B (bottom-right) {b}")
    print(f"stats_distance(A,B) = {stats_distance(a, b)}")
    ink = ink_span(path, win["w"] / 2, 0, min(80, win["h"]), scale)
    print(f"ink scanline at mid-x: ink={ink['ink']} longest={ink['longest']}")
    path2, _ = capture(win, tmp + "2")
    r2 = region_stats(path2, 0, 0, 40, 40, scale)
    print(f"repeat capture crop A digest {r2['digest']} "
          f"({'STABLE' if r2['digest'] == a['digest'] else 'changed (live window)'})")
    os.unlink(path)
    os.unlink(path2)
    print("PASS: window lookup, single-window capture, PNG decode, crop "
          "statistics and scanline ink all work.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
