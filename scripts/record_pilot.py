#!/usr/bin/env python3
"""CDP driver for the S2 recorder pilots (RECORDER.md §Pilots).

Launches the served wasm app in a fresh headless Chrome profile with
--remote-debugging-port, drives REAL input through the DevTools
protocol (Input.dispatchMouseEvent / dispatchKeyEvent — the same
trusted-event path a user's mouse takes), arms the recorder via the
window.jas_record_* API, and saves the returned recording envelope.

Scenarios:
  rect           press/drag/release rect draw under the stock view
  rect_panzoom   the SAME draw after alt-wheel zoom + wheel pan
                 (the screen-vs-doc trap: recorded events must be doc
                 coords, not screen coords)
  blob_dot       Blob Brush zero-length click commits a dot (BB-015)
  blob_merge     two overlapping Blob strokes merge into one path
                 (BB-070/BB-073)
  blob_separate  two non-overlapping Blob strokes stay two paths
                 (BB-071)

Usage:
  .venv/bin/python scripts/record_pilot.py <scenario> --out DIR
      [--serve-port 8080] [--cdp-port 9222] [--family NAME] [--windowed]

The dev server must already be running (run_dioxus_desktop.sh starts
one). Requires websocket-client (installed in .venv).
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

import websocket

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# CDP modifier bitmask.
ALT, CTRL, META, SHIFT = 1, 2, 4, 8


class Cdp:
    """Minimal DevTools-protocol client over one page websocket."""

    def __init__(self, ws_url: str):
        self.ws = websocket.create_connection(ws_url, timeout=30)
        self.next_id = 1

    def call(self, method: str, **params):
        mid = self.next_id
        self.next_id += 1
        self.ws.send(json.dumps({"id": mid, "method": method, "params": params}))
        while True:
            msg = json.loads(self.ws.recv())
            if msg.get("id") == mid:
                if "error" in msg:
                    raise RuntimeError(f"{method}: {msg['error']}")
                return msg.get("result", {})
            # Interleaved events are ignored.

    def evaluate(self, expr: str):
        res = self.call("Runtime.evaluate", expression=expr, returnByValue=True)
        if res.get("exceptionDetails"):
            raise RuntimeError(f"evaluate({expr!r}): {res['exceptionDetails']}")
        return res.get("result", {}).get("value")

    # --- input primitives -------------------------------------------------

    def mouse(self, mtype: str, x: float, y: float, *, buttons: int = 0,
              modifiers: int = 0, delta_y: float = 0.0):
        params = dict(type=mtype, x=x, y=y, modifiers=modifiers, buttons=buttons)
        if mtype in ("mousePressed", "mouseReleased"):
            params.update(button="left", clickCount=1)
        if mtype == "mouseWheel":
            params.update(deltaX=0.0, deltaY=delta_y)
        self.call("Input.dispatchMouseEvent", **params)
        time.sleep(0.05)

    def drag(self, points: list[tuple[float, float]], *, modifiers: int = 0):
        """press at points[0], move through the rest, release at the last."""
        x0, y0 = points[0]
        self.mouse("mousePressed", x0, y0, buttons=1, modifiers=modifiers)
        for x, y in points[1:]:
            self.mouse("mouseMoved", x, y, buttons=1, modifiers=modifiers)
        xn, yn = points[-1]
        self.mouse("mouseReleased", xn, yn, buttons=0, modifiers=modifiers)

    def key(self, ch: str, *, shift: bool = False):
        """Dispatch a character key down/up to the focused element."""
        mods = SHIFT if shift else 0
        code = f"Key{ch.upper()}" if ch.isalpha() else ch
        self.call("Input.dispatchKeyEvent", type="keyDown", key=ch, code=code,
                  text=ch, unmodifiedText=ch.lower(), modifiers=mods)
        self.call("Input.dispatchKeyEvent", type="keyUp", key=ch, code=code,
                  modifiers=mods)
        time.sleep(0.1)


def launch_chrome(url: str, cdp_port: int, windowed: bool) -> tuple[subprocess.Popen, str]:
    profile = tempfile.mkdtemp(prefix="jas-pilot-chrome-")
    args = [
        CHROME,
        f"--remote-debugging-port={cdp_port}",
        "--remote-allow-origins=*",  # Chrome rejects CDP websockets without it
        f"--user-data-dir={profile}",
        "--window-size=1400,950",
        "--no-first-run",
        "--no-default-browser-check",
    ]
    if not windowed:
        args.append("--headless=new")
    args.append(f"--app={url}" if windowed else url)
    proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return proc, profile


def attach(cdp_port: int, serve_url: str) -> Cdp:
    deadline = time.time() + 30
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(f"http://localhost:{cdp_port}/json") as r:
                targets = json.load(r)
            for t in targets:
                if t.get("type") == "page" and t.get("url", "").startswith(serve_url):
                    return Cdp(t["webSocketDebuggerUrl"])
        except OSError:
            pass
        time.sleep(0.5)
    raise RuntimeError("could not attach to the app page over CDP")


def wait_for(cdp: Cdp, expr: str, what: str, timeout: float = 60.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if cdp.evaluate(expr):
                return
        except RuntimeError:
            pass
        time.sleep(0.5)
    raise RuntimeError(f"app did not become ready ({what})")


def wait_app_ready(cdp: Cdp) -> None:
    wait_for(cdp, "typeof window.jas_record_start === 'function'", "jas_record_start")
    # A fresh profile starts with NO document (no saved session); the
    # canvas mounts once one exists. Create it the way a user would:
    # Ctrl+N (the web app maps menu chords to Ctrl).
    if not cdp.evaluate("!!document.getElementById('jas-canvas')"):
        focus_app(cdp)
        cdp.call("Input.dispatchKeyEvent", type="keyDown", key="n", code="KeyN",
                 text="n", unmodifiedText="n", modifiers=CTRL)
        cdp.call("Input.dispatchKeyEvent", type="keyUp", key="n", code="KeyN",
                 modifiers=CTRL)
        wait_for(cdp, "!!document.getElementById('jas-canvas')", "#jas-canvas after Ctrl+N")


def canvas_origin(cdp: Cdp) -> tuple[float, float, float, float]:
    r = cdp.evaluate(
        "(() => { const r = document.getElementById('jas-canvas')"
        ".getBoundingClientRect(); return [r.x, r.y, r.width, r.height]; })()")
    return tuple(r)


def focus_app(cdp: Cdp) -> None:
    """Give the root keyboard div focus (keys route to its onkeydown)."""
    cdp.evaluate("document.querySelector('div[tabindex]').focus()")


# ---------------------------------------------------------------------------
# Scenarios. All coordinates below are CANVAS-LOCAL; the driver adds the
# canvas origin to produce viewport coords.
# ---------------------------------------------------------------------------

def scenario_rect(cdp: Cdp, cx: float, cy: float, family: str) -> str:
    focus_app(cdp)
    cdp.key("m")  # rect tool (production shortcut resolution)
    assert cdp.evaluate(f"window.jas_record_start('gesture', '{family}')"), "arm failed"
    cdp.drag([(cx + 300, cy + 300), (cx + 400, cy + 350), (cx + 400, cy + 350)])
    return cdp.evaluate("window.jas_record_stop()")


def scenario_rect_panzoom(cdp: Cdp, cx: float, cy: float, family: str) -> str:
    focus_app(cdp)
    cdp.key("m")
    # Zoom in twice, anchored near canvas center (alt-wheel up), then
    # pan down (plain wheel) — BEFORE arming, so the case setup is the
    # unchanged stock document but the VIEW is panned + zoomed.
    cdp.mouse("mouseWheel", cx + 400, cy + 300, delta_y=-120, modifiers=ALT)
    cdp.mouse("mouseWheel", cx + 400, cy + 300, delta_y=-120, modifiers=ALT)
    cdp.mouse("mouseWheel", cx + 400, cy + 300, delta_y=100)
    assert cdp.evaluate(f"window.jas_record_start('gesture', '{family}')"), "arm failed"
    cdp.drag([(cx + 300, cy + 300), (cx + 400, cy + 350), (cx + 400, cy + 350)])
    return cdp.evaluate("window.jas_record_stop()")


def select_blob_brush(cdp: Cdp) -> None:
    focus_app(cdp)
    cdp.key("B", shift=True)  # Shift+B = Blob Brush


def scenario_blob_dot(cdp: Cdp, cx: float, cy: float, family: str) -> str:
    # BB-015: a zero-length click (no drag) commits a filled dot.
    select_blob_brush(cdp)
    assert cdp.evaluate(f"window.jas_record_start('gesture', '{family}')"), "arm failed"
    cdp.mouse("mousePressed", cx + 350, cy + 300, buttons=1)
    cdp.mouse("mouseReleased", cx + 350, cy + 300, buttons=0)
    return cdp.evaluate("window.jas_record_stop()")


def scenario_blob_merge(cdp: Cdp, cx: float, cy: float, family: str) -> str:
    # BB-070/BB-073: an overlapping second stroke with the same fill
    # merges into ONE path.
    select_blob_brush(cdp)
    assert cdp.evaluate(f"window.jas_record_start('gesture', '{family}')"), "arm failed"
    cdp.drag([(cx + 300, cy + 300), (cx + 340, cy + 300), (cx + 380, cy + 300)])
    cdp.drag([(cx + 340, cy + 280), (cx + 340, cy + 310), (cx + 340, cy + 340)])
    return cdp.evaluate("window.jas_record_stop()")


def scenario_blob_separate(cdp: Cdp, cx: float, cy: float, family: str) -> str:
    # BB-071: a NON-overlapping second stroke stays a separate path.
    select_blob_brush(cdp)
    assert cdp.evaluate(f"window.jas_record_start('gesture', '{family}')"), "arm failed"
    cdp.drag([(cx + 250, cy + 300), (cx + 280, cy + 300), (cx + 310, cy + 300)])
    cdp.drag([(cx + 450, cy + 300), (cx + 480, cy + 300), (cx + 510, cy + 300)])
    return cdp.evaluate("window.jas_record_stop()")


SCENARIOS = {
    "rect": scenario_rect,
    "rect_panzoom": scenario_rect_panzoom,
    "blob_dot": scenario_blob_dot,
    "blob_merge": scenario_blob_merge,
    "blob_separate": scenario_blob_separate,
}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("scenario", choices=sorted(SCENARIOS))
    ap.add_argument("--out", required=True, help="directory for the recording JSON")
    ap.add_argument("--serve-port", type=int, default=8080)
    ap.add_argument("--cdp-port", type=int, default=9222)
    ap.add_argument("--family", default=None,
                    help="fixture family name (default: recorded_<scenario>)")
    ap.add_argument("--windowed", action="store_true",
                    help="run a visible chromeless window instead of headless")
    args = ap.parse_args()
    family = args.family or f"recorded_{args.scenario}"

    serve_url = f"http://localhost:{args.serve_port}"
    proc, profile = launch_chrome(serve_url, args.cdp_port, args.windowed)
    try:
        cdp = attach(args.cdp_port, serve_url)
        wait_app_ready(cdp)
        time.sleep(1.0)  # first paint / viewport sync
        cx, cy, cw, ch = canvas_origin(cdp)
        print(f"pilot: canvas at ({cx},{cy}) size {cw}x{ch}")
        envelope_json = SCENARIOS[args.scenario](cdp, cx, cy, family)
        if not envelope_json:
            raise RuntimeError("jas_record_stop returned nothing (was recording armed?)")
        env = json.loads(envelope_json)
        os.makedirs(args.out, exist_ok=True)
        out_path = os.path.join(args.out, f"{family}.recording.json")
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(envelope_json)
        print(f"pilot: fidelity={env.get('fidelity')} cases={len(env.get('cases', []))}")
        for c in env.get("cases", []):
            print(f"pilot:   case {c['name']}: tool={c.get('tool')} "
                  f"events={len(c.get('events', []))} fidelity={c.get('fidelity')} "
                  f"violations={c.get('precondition_violations')}")
        print(f"pilot: wrote {out_path}")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        shutil.rmtree(profile, ignore_errors=True)


if __name__ == "__main__":
    main()
