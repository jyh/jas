#!/usr/bin/env python3
"""GUIEYES — a live-window GUI probe for the Rust/Dioxus app.

WHY THIS EXISTS
---------------
The headless corpora (`test_fixtures/gestures|actions|keys`) replay at the
`CanvasTool` / `dispatch_action` seam and the widget-tree golden
(`interpreter/widget_tree.rs`) is a projection of the compiled bundle. Neither
ever observes a RENDERER, so a whole class of defect is invisible to CI by
construction:

  1. a widget that declares a click behavior but is not wired (click-dead);
  2. a state that flips correctly but paints no visible difference
     (invisible highlight);
  3. a rendered property that silently resets when an unrelated control is
     touched (the 5pt stroke that came back 1pt).

This module drives the REAL app in a real browser over the DevTools protocol
(the same trusted-event path a user's mouse takes) and asserts *facts read back
out of the live DOM and the live canvas*. It needs no macOS Screen-Recording or
Accessibility grant, so it runs unattended on an unprivileged host (and is
CI-ready — it gates on exit code and needs no display; no CI lane is wired yet).

WHAT IT ASSERTS
---------------
Measurable properties, not whole-image equality:
  * `ink_span()`     — thickness / presence of ink along a canvas scanline;
  * `probe_pixel()`  — exact canvas RGBA at a named point;
  * `attr()`/`css()` — the DECLARED state (e.g. `data-checked`) paired with the
                       RENDERED state (`getComputedStyle`), because the
                       divergence between the two IS bug class 2;
  * `region_stats()` — compact statistics of an element's pixel crop
                       (mean RGB, distinct colours, digest) so "checked looks
                       different from unchecked" is a numeric claim;
  * `watch_mutations()` — did clicking this thing change the DOM AT ALL, which
                       is the generic detector for bug class 1.

LIMITS (honest)
---------------
It checks CORRECTNESS, not FEEL. Layout taste, animation smoothness, cursor
glyphs, native chrome, focus comfort and "does this read as clickable" stay
JYH's manual floor. It also runs at devicePixelRatio 1 in headless Chrome, so
it is not a retina-fidelity oracle.

See `GUI_EYES.md` for how to add a check.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import struct
import subprocess
import tempfile
import time
import urllib.request
import zlib

import websocket

# Overridable so a non-default Chrome (a Beta/Canary channel, a pinned build, a
# CI image path) can drive the harness without editing this source. Preflighted
# in `launch`, which fails loudly and names $JAS_CHROME if the path is wrong —
# far better than a bare FileNotFoundError from subprocess deep in a check.
CHROME = os.environ.get(
    "JAS_CHROME",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")

# CDP modifier bitmask.
ALT, CTRL, META, SHIFT = 1, 2, 4, 8

# Non-text keys need explicit virtual key codes or Chrome will not treat them
# as editing commands inside a focused <input>.
VK = {"Enter": 13, "Backspace": 8, "Tab": 9, "Escape": 27, "Delete": 46}

# THE KEYS THAT STORM. Enter and Escape carry a legacy control character as
# their text ("\r", "\x1b"). Dispatched through `Input.dispatchKeyEvent` with a
# virtual key code but WITHOUT that text, Chrome (150.0.7871) never completes
# the key and re-queues it forever: ONE dispatched Enter became 8757 further
# trusted `key="Unidentified"` keydowns, and one Escape 10589 — enough to
# saturate the renderer and make a perfectly healthy app miss its heartbeat.
#
# It is the DRIVER's artifact, not the app's: measured at 11543 keydowns on a
# blank `data:text/html,<input>` page with no app loaded at all (and with the
# text supplied, exactly 1 keydown + 1 keypress, app or no app). Backspace,
# Tab and Delete do not storm — only these two.
#
# That storm is what two WEDGESTORM diagnosis attempts mistook for an app
# livelock. Supplying the text is the whole fix: the key arrives once, and its
# keypress reaches the browser's default action, which is what makes Enter
# COMMIT a focused field (an input's `change` event).
KEY_TEXT = {"Enter": "\r", "Escape": "\x1b"}


class ProbeFailure(AssertionError):
    """A visual/DOM fact did not hold. Carries the numbers that disproved it."""


# ---------------------------------------------------------------------------
# PNG decode — stdlib only (zlib), so the harness has no imaging dependency.
# ---------------------------------------------------------------------------

def decode_png(data: bytes) -> tuple[int, int, bytes]:
    """Return (width, height, RGBA bytes) for an 8-bit RGB/RGBA PNG.

    Chrome's `Page.captureScreenshot` emits exactly that, so the narrow
    support is deliberate rather than a shortcut we might regret.
    """
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, width, height, channels, idat = 8, 0, 0, 0, bytearray()
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        ctype = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if ctype == b"IHDR":
            width, height, depth, color = struct.unpack(">IIBB", body[:10])
            if depth != 8 or color not in (2, 6):
                raise ValueError(f"unsupported PNG depth/color {depth}/{color}")
            channels = 3 if color == 2 else 4
        elif ctype == b"IDAT":
            idat += body
        elif ctype == b"IEND":
            break
        pos += 12 + length
    raw = zlib.decompress(bytes(idat))
    stride = width * channels
    out = bytearray(width * height * 4)
    prev = bytearray(stride)
    rp = 0
    for y in range(height):
        filt = raw[rp]
        rp += 1
        line = bytearray(raw[rp:rp + stride])
        rp += stride
        # PNG per-scanline filters (spec 9.2). Applied in place, left to right.
        for i in range(stride):
            a = line[i - channels] if i >= channels else 0
            b = prev[i]
            c = prev[i - channels] if i >= channels else 0
            if filt == 1:
                line[i] = (line[i] + a) & 0xFF
            elif filt == 2:
                line[i] = (line[i] + b) & 0xFF
            elif filt == 3:
                line[i] = (line[i] + ((a + b) >> 1)) & 0xFF
            elif filt == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        for x in range(width):
            s, d = x * channels, (y * width + x) * 4
            out[d:d + 3] = line[s:s + 3]
            out[d + 3] = line[s + 3] if channels == 4 else 255
        prev = line
    return width, height, bytes(out)


# ---------------------------------------------------------------------------
# DevTools transport
# ---------------------------------------------------------------------------

class Cdp:
    """Minimal DevTools-protocol client over one page websocket.

    Promoted from `scripts/record_pilot.py`, which proved this exact transport
    across five landed recorder pilots.
    """

    def __init__(self, ws_url: str, timeout: float = 30.0):
        self.ws = websocket.create_connection(ws_url, timeout=timeout)
        self.next_id = 1

    def set_timeout(self, seconds: float):
        """Shorten/lengthen the reply deadline (used by `heartbeat`)."""
        self.ws.settimeout(seconds)

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
            # Interleaved protocol events are not consumed by this driver.

    def evaluate(self, expr: str):
        res = self.call("Runtime.evaluate", expression=expr, returnByValue=True,
                        awaitPromise=True)
        if res.get("exceptionDetails"):
            raise RuntimeError(f"evaluate({expr[:120]!r}): "
                               f"{res['exceptionDetails'].get('text')}")
        return res.get("result", {}).get("value")

    def close(self):
        try:
            self.ws.close()
        except Exception:
            pass


# ---------------------------------------------------------------------------
# The probe
# ---------------------------------------------------------------------------

class GuiProbe:
    """Drive + interrogate a live instance of the Rust/Dioxus app.

    Determinism knobs, all fixed by default so a check reruns identically:
    a FRESH Chrome profile (stock defaults, no restored session), a fixed
    window size, and a document created through the app's own Ctrl+N.
    """

    # Fixed so element rects — and therefore click coordinates — repeat.
    # Tall on purpose: the Stroke panel alone runs past y=1100, and a target
    # below the fold cannot be clicked (see `ensure_visible`). Sizing the
    # window to fit the docks keeps rects scroll-free, hence stable.
    WINDOW = (1400, 1300)
    SETTLE = 0.25   # seconds to let Dioxus flush after an input event
    SLOW = 0.05     # inter-event pause inside a drag

    def __init__(self, serve_port: int = 8097, cdp_port: int = 9333,
                 headless: bool = True, verbose: bool = True):
        self.serve_url = f"http://localhost:{serve_port}"
        self.cdp_port = cdp_port
        self.headless = headless
        self.verbose = verbose
        self.proc = None
        self.profile = None
        self.cdp: Cdp | None = None

    # --- lifecycle --------------------------------------------------------

    def __enter__(self) -> "GuiProbe":
        self.launch()
        return self

    def __exit__(self, *exc):
        self.shutdown()
        return False

    def log(self, msg: str):
        if self.verbose:
            print(f"  probe: {msg}", flush=True)

    def launch(self):
        if not (os.path.isfile(CHROME) and os.access(CHROME, os.X_OK)):
            raise ProbeFailure(
                f"Chrome is not an executable at {CHROME!r}. Set $JAS_CHROME to "
                f"the Chrome/Chromium binary you want to drive, e.g. "
                f"'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'.")
        self.profile = tempfile.mkdtemp(prefix="jas-guieyes-")
        args = [
            CHROME,
            f"--remote-debugging-port={self.cdp_port}",
            "--remote-allow-origins=*",   # Chrome rejects CDP sockets without it
            f"--user-data-dir={self.profile}",
            f"--window-size={self.WINDOW[0]},{self.WINDOW[1]}",
            "--no-first-run", "--no-default-browser-check",
            "--hide-scrollbars",          # scrollbars perturb element rects
            "--force-device-scale-factor=1",
        ]
        if self.headless:
            args.append("--headless=new")
        args.append(self.serve_url if self.headless else f"--app={self.serve_url}")
        self.proc = subprocess.Popen(args, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)
        self.cdp = self._attach()
        self.wait_ready()

    def _attach(self) -> Cdp:
        deadline = time.time() + 40
        while time.time() < deadline:
            try:
                with urllib.request.urlopen(
                        f"http://localhost:{self.cdp_port}/json") as r:
                    for t in json.load(r):
                        if (t.get("type") == "page"
                                and t.get("url", "").startswith(self.serve_url)):
                            return Cdp(t["webSocketDebuggerUrl"])
            # A Chrome that is still coming up answers /json with an empty or
            # truncated body as readily as it refuses the connection, and
            # `json.load` raises ValueError for that, not OSError. Both are the
            # same "not ready yet" and both must be RETRIED: the liveness sweep
            # launches one instance per widget, and an unretried decode error
            # there surfaced as a bare `JSONDecodeError` scored as a check
            # FAILURE — a launch race wearing a defect's clothes.
            except (OSError, ValueError):
                pass
            time.sleep(0.4)
        raise ProbeFailure(f"could not attach to {self.serve_url} over CDP "
                           f"(is the dev server up? try scripts/gui_drive.sh)")

    def wait_for(self, expr: str, what: str, timeout: float = 60.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                if self.cdp.evaluate(expr):
                    return
            except RuntimeError:
                pass
            time.sleep(0.4)
        raise ProbeFailure(f"timed out waiting for {what}")

    def wait_ready(self):
        """Block until the app is mounted AND a document exists.

        A fresh profile has no saved session, so the canvas has nothing to
        mount against; we create a document the way a user does (Ctrl+N — the
        web build maps menu chords to Ctrl) rather than reaching into state.
        """
        self.wait_for("typeof window.jas_record_start === 'function'",
                      "the wasm app to mount")
        if not self.cdp.evaluate("!!document.getElementById('jas-canvas')"):
            self.focus_app()
            self.key("n", "KeyN", mods=CTRL)
            self.wait_for("!!document.getElementById('jas-canvas')",
                          "#jas-canvas after Ctrl+N")
        time.sleep(1.0)   # first paint + viewport sync
        self.log(f"ready; canvas {self.canvas_rect()}")

    def heartbeat(self, timeout: float = 5.0, what: str = "the app") -> float:
        """Fail fast and legibly if the app has stopped answering.

        A wasm livelock (runaway re-render / recompute) does not raise a JS
        error and does not blank the window — it just makes the main thread
        stop servicing work, which a naive driver experiences as a 30-second
        socket timeout deep inside an unrelated probe. Calling this after a
        risky step turns "mystery hang" into a named result, and returns the
        round-trip latency so a check can also assert the app is not merely
        *crawling*.

        It says the main thread stopped, and NOT whose fault that is: an input
        this driver dispatched can saturate the renderer all by itself (see
        `KEY_TEXT`, which cost two diagnosis waves). Treat a red here as "the
        page stopped answering", and pin the cause before naming the app.
        """
        start = time.time()
        try:
            self.cdp.set_timeout(timeout)
            self.cdp.evaluate("1+1")
        except Exception as e:
            raise ProbeFailure(
                f"{what} stopped answering within {timeout}s "
                f"({type(e).__name__}): the page stopped answering. This does "
                f"NOT name a cause — an input THIS DRIVER dispatched can "
                f"saturate the renderer by itself (see KEY_TEXT, which cost "
                f"two diagnosis waves), so rule the driver out before calling "
                f"it an app livelock or panic") from None
        finally:
            try:
                self.cdp.set_timeout(30.0)
            except Exception:
                pass
        return round(time.time() - start, 3)

    def shutdown(self):
        if self.cdp:
            self.cdp.close()
        if self.proc:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        if self.profile:
            shutil.rmtree(self.profile, ignore_errors=True)

    # --- target resolution ------------------------------------------------
    #
    # A "target" is a YAML widget id ("stk_weight") or an explicit CSS
    # selector ("css:.jas-icon-button"). Widget ids are the primary handle
    # because the renderer emits every YAML id as the DOM element id, which
    # makes checks spec-addressed and immune to layout/theme churn.

    @staticmethod
    def _sel(target: str) -> str:
        if target.startswith("css:"):
            return target[4:]
        return f"#{target}"

    def exists(self, target: str) -> bool:
        return bool(self.cdp.evaluate(
            f"!!document.querySelector({json.dumps(self._sel(target))})"))

    def rect(self, target: str) -> tuple[float, float, float, float]:
        r = self.cdp.evaluate(
            f"(()=>{{const e=document.querySelector({json.dumps(self._sel(target))});"
            "if(!e)return null;const r=e.getBoundingClientRect();"
            "return [r.x,r.y,r.width,r.height];})()")
        if not r:
            raise ProbeFailure(f"target {target!r} is not in the live DOM")
        return tuple(r)

    def viewport(self) -> tuple[int, int]:
        return tuple(self.cdp.evaluate("[innerWidth,innerHeight]"))

    def ensure_visible(self, target: str) -> tuple[float, float, float, float]:
        """Scroll `target` into view if it is off-screen, and return its rect.

        A mouse event dispatched outside the viewport is silently dropped by
        Chrome, which would make an unclickable widget look merely inert — the
        exact confusion this harness exists to remove. So we scroll first and
        then let `center` fail loudly if the point is still unreachable.
        """
        x, y, w, h = self.rect(target)
        vw, vh = self.viewport()
        if not (0 <= y and y + h <= vh and 0 <= x and x + w <= vw):
            self.cdp.evaluate(
                f"(()=>{{document.querySelector({json.dumps(self._sel(target))})"
                ".scrollIntoView({block:'center',inline:'center'});return true;})()")
            time.sleep(0.2)
            x, y, w, h = self.rect(target)
        return x, y, w, h

    def center(self, target: str) -> tuple[float, float]:
        x, y, w, h = self.ensure_visible(target)
        if w <= 0 or h <= 0:
            raise ProbeFailure(f"target {target!r} has zero size ({w}x{h}) — "
                               f"it is present but not laid out")
        cx, cy = x + w / 2, y + h / 2
        vw, vh = self.viewport()
        if not (0 <= cx <= vw and 0 <= cy <= vh):
            raise ProbeFailure(
                f"target {target!r} centre ({cx:.0f},{cy:.0f}) is outside the "
                f"{vw}x{vh} viewport even after scrolling — a click here would "
                f"be silently dropped, so the check cannot be trusted")
        return cx, cy

    def hit_target(self, target: str) -> str | None:
        """Which element id actually sits under `target`'s centre point.

        Guards against a check that "clicks a widget" while an overlay, a
        flyout or a sibling is really receiving the event.
        """
        cx, cy = self.center(target)
        return self.cdp.evaluate(
            f"(()=>{{const e=document.elementFromPoint({cx},{cy});"
            "if(!e)return null;let n=e;while(n){if(n.id)return n.id;"
            "n=n.parentElement;}return e.tagName;})()")

    # --- input ------------------------------------------------------------

    def _mouse(self, mtype: str, x: float, y: float, *, buttons: int = 0,
               modifiers: int = 0, clicks: int = 1, delta_y: float = 0.0):
        p = dict(type=mtype, x=x, y=y, modifiers=modifiers, buttons=buttons)
        if mtype in ("mousePressed", "mouseReleased"):
            p.update(button="left", clickCount=clicks)
        if mtype == "mouseWheel":
            p.update(deltaX=0.0, deltaY=delta_y)
        self.cdp.call("Input.dispatchMouseEvent", **p)
        time.sleep(self.SLOW)

    def click_xy(self, x: float, y: float, *, clicks: int = 1, modifiers: int = 0):
        for i in range(1, clicks + 1):
            self._mouse("mousePressed", x, y, buttons=1, modifiers=modifiers,
                        clicks=i)
            self._mouse("mouseReleased", x, y, modifiers=modifiers, clicks=i)
        time.sleep(self.SETTLE)

    def click(self, target: str, *, clicks: int = 1, modifiers: int = 0):
        """Dispatch a TRUSTED click at the centre of a widget.

        Trusted (not `element.click()`) so the event travels the production
        hit-test + handler path; a widget whose behavior is declared but never
        bound stays silent here exactly as it does under a real mouse.
        """
        x, y = self.center(target)
        self.click_xy(x, y, clicks=clicks, modifiers=modifiers)

    def key(self, key: str, code: str | None = None, *, mods: int = 0,
            text: str | None = None):
        """Press and release one key, the way a keyboard delivers it.

        Enter and Escape default to their control-character `text` (see
        `KEY_TEXT`): without it Chrome re-queues them forever, and that storm —
        not the app — is what made the driver see wedges.
        """
        code = code or (f"Key{key.upper()}" if key.isalpha() and len(key) == 1
                        else key)
        text = text if text is not None else KEY_TEXT.get(key)
        p = dict(key=key, code=code, modifiers=mods)
        if text:
            p.update(text=text, unmodifiedText=text.lower())
        if key in VK:
            p.update(windowsVirtualKeyCode=VK[key], nativeVirtualKeyCode=VK[key])
        self.cdp.call("Input.dispatchKeyEvent", type="keyDown", **p)
        self.cdp.call("Input.dispatchKeyEvent", type="keyUp", key=key, code=code,
                      modifiers=mods)
        time.sleep(0.1)

    def type_text(self, text: str):
        for ch in text:
            code = (f"Digit{ch}" if ch.isdigit()
                    else f"Key{ch.upper()}" if ch.isalpha() else ch)
            self.key(ch, code, text=ch)

    def set_field(self, target: str, text: str) -> str:
        """Replace a text/length input's content the way a user does.

        Triple-click selects the whole value INSIDE the input; typing then
        replaces the selection and Enter commits. Deliberately not Ctrl+A or
        Backspace: the app claims both as Select-All / Delete at the document
        level, so those never reach the field (verified — they append instead
        of replacing, yielding values like "1 pt5").

        The Enter really does commit (it did not before `KEY_TEXT`: a textless
        Enter produced no keypress, so no `change` event, and the value sat raw
        in the DOM until some later click blurred the field). The returned
        value is therefore the app's — a length input reads back normalized,
        `"5 pt"` for an entered `"5"`, which is only possible if the write went
        through app state and re-rendered.
        """
        self.click(target, clicks=3)
        self.type_text(text)
        self.key("Enter")
        time.sleep(self.SETTLE)
        return self.value(target)

    def focus_app(self):
        """Give the root keyboard div focus so keys reach its onkeydown.

        Prefers the wrapper's own id (`keyboard::APP_ROOT_ID`) over "the first
        div with a tabindex", which was only ever true by layout accident; the
        selector remains as a fallback so the probe still drives a build that
        predates the id.
        """
        self.cdp.evaluate(
            "(document.getElementById('jas-app-root')"
            "||document.querySelector('div[tabindex]')).focus()")

    # --- canvas -----------------------------------------------------------

    def canvas_rect(self) -> tuple[float, float, float, float]:
        return self.rect("jas-canvas")

    def canvas_scale(self) -> float:
        """Backing-store pixels per CSS pixel for #jas-canvas."""
        return float(self.cdp.evaluate(
            "(()=>{const c=document.getElementById('jas-canvas');"
            "return c.width/c.getBoundingClientRect().width;})()"))

    def drag(self, points: list[tuple[float, float]], *, modifiers: int = 0,
             canvas_local: bool = True):
        """press → move… → release. Points default to CANVAS-LOCAL coords."""
        if canvas_local:
            cx, cy, _, _ = self.canvas_rect()
            points = [(cx + px, cy + py) for px, py in points]
        x0, y0 = points[0]
        self._mouse("mousePressed", x0, y0, buttons=1, modifiers=modifiers)
        for x, y in points[1:]:
            self._mouse("mouseMoved", x, y, buttons=1, modifiers=modifiers)
        self._mouse("mouseReleased", *points[-1], modifiers=modifiers)
        time.sleep(self.SETTLE)

    # `ink` = "this canvas pixel is not the paper". Paper is near-white in
    # every appearance the canvas ships, and the threshold sits well clear of
    # anti-aliasing fringe, so the metric survives theme tweaks.
    _INK_JS = "(d[i]<246||d[i+1]<246||d[i+2]<246)"

    def ink_span(self, x: float, y: float, length: int,
                 axis: str = "v") -> dict:
        """Scan a 1-px canvas line and report the ink on it.

        Returns `{ink, longest, pattern, offset}` in CANVAS-LOCAL px:
        `ink` = total inked pixels, `longest` = the longest contiguous inked
        run (the *thickness* of a stroke crossed perpendicularly), `offset` =
        where that run starts, `pattern` = the raw 0/1 string, which makes a
        failure message self-diagnosing (dashes, gaps and doubled edges are
        all legible in it).
        """
        w, h = (1, length) if axis == "v" else (length, 1)
        res = self.cdp.evaluate(
            "(()=>{const c=document.getElementById('jas-canvas');"
            "const g=c.getContext('2d');"
            "const s=c.width/c.getBoundingClientRect().width;"
            f"const d=g.getImageData(Math.round({x}*s),Math.round({y}*s),"
            f"Math.round({w}*s),Math.round({h}*s)).data;"
            "const b=[];for(let i=0;i<d.length;i+=4)"
            f"b.push({self._INK_JS}?1:0);"
            "return {bits:b.join(''),scale:s};})()")
        bits, scale = res["bits"], res["scale"]
        longest = best_off = run = 0
        for i, ch in enumerate(bits):
            if ch == "1":
                run += 1
                if run > longest:
                    longest, best_off = run, i - run + 1
            else:
                run = 0
        return {"ink": round(bits.count("1") / scale, 2),
                "longest": round(longest / scale, 2),
                "offset": round(best_off / scale, 2),
                "pattern": bits}

    def probe_pixel(self, x: float, y: float) -> tuple[int, int, int, int]:
        """Exact canvas RGBA at one CANVAS-LOCAL point."""
        return tuple(self.cdp.evaluate(
            "(()=>{const c=document.getElementById('jas-canvas');"
            "const g=c.getContext('2d');"
            "const s=c.width/c.getBoundingClientRect().width;"
            f"const d=g.getImageData(Math.round({x}*s),Math.round({y}*s),1,1).data;"
            "return [d[0],d[1],d[2],d[3]];})()"))

    # --- DOM reads --------------------------------------------------------

    def attr(self, target: str, name: str):
        return self.cdp.evaluate(
            f"(()=>{{const e=document.querySelector({json.dumps(self._sel(target))});"
            f"return e?e.getAttribute({json.dumps(name)}):null;}})()")

    def checked(self, target: str) -> bool:
        """The DECLARED checked state as the renderer published it."""
        return self.attr(target, "data-checked") == "true"

    def disabled(self, target: str) -> bool:
        """Is this widget non-interactive right now?

        A disabled control is legitimately click-inert (an Align button with
        nothing selected), so the liveness sweep must not read it as dead.
        The renderer drops disabled icon-buttons out of the tab cycle
        (`tabindex="-1"`), which is the signal used here alongside the native
        `:disabled` state and a `pointer-events:none` opt-out.
        """
        return bool(self.cdp.evaluate(
            f"(()=>{{const e=document.querySelector({json.dumps(self._sel(target))});"
            "if(!e)return true;"
            "if(e.matches(':disabled'))return true;"
            "if(e.getAttribute('tabindex')==='-1')return true;"
            "if(getComputedStyle(e).pointerEvents==='none')return true;"
            "return false;})()"))

    def css(self, target: str, prop: str) -> str:
        return self.cdp.evaluate(
            f"(()=>{{const e=document.querySelector({json.dumps(self._sel(target))});"
            f"return e?getComputedStyle(e).getPropertyValue({json.dumps(prop)}):null;}})()")

    def value(self, target: str):
        return self.cdp.evaluate(
            f"(()=>{{const e=document.querySelector({json.dumps(self._sel(target))});"
            "return e?(e.value!==undefined?e.value:e.textContent):null;})()")

    # --- liveness ---------------------------------------------------------

    # Mutations that a click produces whether or not the widget is wired, so
    # counting them would make a DEAD widget look alive. Measured, not guessed:
    # an unwired click produces EXACTLY one record, `data-input-modality` on
    # <html> (the root focus-modality stamp behind the keyboard-only focus
    # ring). The filter is kept this narrow deliberately — widening it to
    # `style` on the clicked node would swallow real signal, since inline
    # `style` is where a swatch's selection outline actually lands.
    INCIDENTAL_ATTRS = ("data-input-modality",)

    def watch_start(self):
        """Arm a document-wide MutationObserver that RECORDS what moved.

        The generic detector for a click-DEAD widget: a wired control always
        moves something meaningful in the DOM (an attribute, a text node, a
        subtree). A control whose declared behavior was never bound moves only
        interaction decoration. Spec-derived and per-widget-knowledge-free,
        which is why it scales with the YAML instead of needing a hand-written
        check per widget. Descriptions (not just a count) are kept so a
        failure names the change it did or did not see.
        """
        # The filter runs IN THE PAGE, before the cap, and incidental records
        # are counted rather than stored. An earlier version capped the raw
        # array at 200 and filtered in Python; a `data-input-modality` storm
        # then filled the cap with decoration and CROWDED OUT the meaningful
        # records that arrived after it, so a perfectly live widget reported
        # "201 raw, 0 meaningful" and the check failed intermittently. Never
        # let noise evict signal.
        incidental = json.dumps(list(self.INCIDENTAL_ATTRS))
        self.cdp.evaluate(
            "(()=>{window.__jasMut=[];window.__jasIncidental=0;"
            f"const IGN={incidental};"
            "if(window.__jasObs)window.__jasObs.disconnect();"
            "window.__jasObs=new MutationObserver(rs=>{for(const r of rs){"
            "if(r.type==='attributes'&&IGN.indexOf(r.attributeName)>=0){"
            "window.__jasIncidental++;continue;}"
            "if(window.__jasMut.length>=500)continue;"
            "const t=r.target, el=(t.nodeType===1?t:t.parentElement);"
            "window.__jasMut.push({type:r.type,"
            "attr:r.attributeName||'',"
            "id:(el&&el.id)||'',"
            "tag:(el&&el.tagName)||'#text',"
            "root:(el===document.documentElement||el===document.body)});}});"
            "window.__jasObs.observe(document.documentElement,"
            "{subtree:true,childList:true,attributes:true,characterData:true});"
            "return true;})()")

    def watch_records(self) -> list[dict]:
        """The MEANINGFUL records — decoration was already dropped in-page."""
        return self.cdp.evaluate("window.__jasMut||[]") or []

    def watch_meaningful(self, clicked_id: str | None = None) -> list[dict]:
        return self.watch_records()

    def watch_incidental(self) -> int:
        """How many decoration-only records were seen and discarded."""
        return int(self.cdp.evaluate("window.__jasIncidental||0"))

    def watch_count(self) -> int:
        """Total records observed, decoration included."""
        return len(self.watch_records()) + self.watch_incidental()

    def watch_stop(self):
        self.cdp.evaluate(
            "(()=>{if(window.__jasObs)window.__jasObs.disconnect();return true;})()")

    @staticmethod
    def describe_records(records: list[dict], limit: int = 6) -> str:
        seen = []
        for r in records[:limit]:
            what = f"{r['id'] or r['tag']}"
            seen.append(f"{r['type']}"
                        + (f"[{r['attr']}]" if r["attr"] else "")
                        + f"@{what}")
        more = "" if len(records) <= limit else f" (+{len(records) - limit} more)"
        return ", ".join(seen) + more if seen else "none"

    # --- pixels -----------------------------------------------------------

    def shot(self, path: str, target: str | None = None) -> str:
        """Screenshot the page, or an element's exact rect when `target` is set.

        Element crops are the committable kind: a chain button is ~1 KB, so a
        baseline stays small, regenerable and reviewable in a diff.
        """
        params = {"format": "png"}
        if target:
            x, y, w, h = self.ensure_visible(target)
            params["clip"] = {"x": x, "y": y, "width": w, "height": h,
                              "scale": 1}
            # Deliberately NOT captureBeyondViewport: it installs a temporary
            # viewport override that leaves subsequent Input.dispatchMouseEvent
            # coordinates mis-mapped, so a screenshot taken before a click
            # silently breaks the click (observed: a chain toggle stopped
            # flipping). `ensure_visible` already guarantees the clip is
            # on-screen, so the flag buys nothing.
        data = self.cdp.call("Page.captureScreenshot", **params)["data"]
        raw = __import__("base64").b64decode(data)
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        with open(path, "wb") as f:
            f.write(raw)
        return path

    def region_stats(self, target: str) -> dict:
        """Compact, comparable statistics of an element's pixel crop.

        Prefers numbers over image equality: `mean` (per-channel average),
        `colors` (distinct colour count), `digest` (sha1 of the RGBA bytes).
        Two states of the same widget are then compared by how far apart
        their means are — a claim that survives a theme tweak, unlike an
        exact-image baseline.
        """
        tmp = os.path.join(tempfile.gettempdir(),
                           f"guieyes-{target.replace('#', '')}.png")
        self.shot(tmp, target)
        with open(tmp, "rb") as f:
            data = f.read()
        os.unlink(tmp)
        w, h, rgba = decode_png(data)
        n = w * h
        sums, colors = [0, 0, 0], set()
        for i in range(0, len(rgba), 4):
            sums[0] += rgba[i]
            sums[1] += rgba[i + 1]
            sums[2] += rgba[i + 2]
            colors.add(rgba[i:i + 3])
        return {"w": w, "h": h,
                "mean": [round(s / n, 2) for s in sums],
                "colors": len(colors),
                "digest": hashlib.sha1(rgba).hexdigest()[:12]}

    @staticmethod
    def stats_distance(a: dict, b: dict) -> float:
        """Manhattan distance between two region means (0 = indistinguishable)."""
        return round(sum(abs(x - y) for x, y in zip(a["mean"], b["mean"])), 2)
