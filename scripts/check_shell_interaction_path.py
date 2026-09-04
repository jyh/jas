#!/usr/bin/env python3
"""O2b: the benchmark loop and the surface clamp stay OFF the interaction path.

WHY THIS EXISTS
---------------
The WinUI shell in `prototypes/sb_winui/` had two defects that were invisible
because they were structural rather than wrong:

  * F-5 -- A 60-FRAME BENCHMARK ON THE RESIZE PATH. `SB_FRAMES` was read inside
    `RenderFrame` (`SwapChainHost.cs:444`), and `RenderFrame` is what the
    `Canvas.SizeChanged` handler calls (`MainWindow.xaml.cs:169`). So every
    resize event repainted the probe SIXTY TIMES. Measured on kenai, at the
    reported 984x526 surface: 2.75 ms of real resize work followed by
    60 x 6.01 ms of repaint -- about 363 ms per `SizeChanged` event, for a
    frame the user was going to replace on the next event anyway.

  * F-6 -- 0x0 ACCEPTED SILENTLY. `Math.Max(1, ...)` at
    `MainWindow.xaml.cs:83-84` and `Math.Max(width, 1)` at
    `SwapChainHost.cs:180-181` and `:329-330`. A window squeezed to zero height
    was resized to 1 px and reported as a success. The clamp turned a REFUSAL
    into a silent lie about what surface was measured.

Neither is a bug in a line. Both are a SHAPE, and a shape comes back. The repair
(the FREEZE's coats 2 and 3) splits `Repaint()` from `Benchmark(frames)` and
routes every width and height through a three-valued `SurfacePolicy.Decide`;
this gate is what stops the split from being quietly re-joined, and what stops
the next clamp from being spelled `Math.Clamp` instead.

WHAT IT ASSERTS
---------------
Over `prototypes/sb_winui/*.cs`, with `//` and `/* */` comments blanked and
string-literal CONTENTS blanked (`scripts/csharp_source.py`), so that neither a
comment explaining a deleted clamp nor a diagnostic string quoting one can red
or green this gate:

(a) EXACTLY ONE `GetEnvironmentVariable("SB_FRAMES")` outside a whitelisted
    method, and that one read is inside a method named `Benchmark`. The
    whitelist is NAMED, one entry, with its reason in this file: `Report`
    writes the knob's value into the `sb-runs.log` receipt row, which is a LOG
    field and not an interaction-path read. A whitelist entry naming a method
    that no longer holds such a read is reported STALE -- an exemption that
    outlives its subject is how a hole becomes permanent.

(b) EVERY `Benchmark(` CALL SITE sits in the `SB_SCENE` dispatch's benchmark
    arm. The arm is recognised BY ITS OWN GUARD naming the scene literal
    `"benchmark"` -- an enclosing `if`/`else if` condition, or a preceding
    `case "benchmark":` label. There must be at least ONE call site: a
    `Benchmark` nobody calls is a dead measurement wearing a live one's name.
    (An empty `SB_SCENE` resolves to `benchmark` per the freeze's §1.2, so it
    reaches the same guarded arm and needs no separate clause here.)

(c) ZERO clamps, banned as WHOLE IDENTIFIERS in four spellings: `Math.Max`,
    `Math.Clamp`, `System.Math.Max`, and the ternary `w < 1 ? 1 : w`. Whole
    identifiers because a substring ban would also hit `MathMaxima`, and a gate
    that reds on an unrelated name is a gate someone weakens. `Math.Abs` and
    `Math.Round` are NOT banned -- the ban is on the clamp, not on arithmetic.

(d) THE POSITIVE HALF, which is the one a blacklist cannot give: every width and
    height entering `Attach`, `Resize` and the `SizeChanged` handler passes
    through `SurfacePolicy.Decide`. All three entry kinds must be FOUND -- a
    scan that located no `Attach`, no `Resize` or no `SizeChanged` subscription
    reds, because a ban over an empty population is green for the wrong reason.

WHAT IT DOES NOT COVER
----------------------
* THE DRAIN SHAPE. The freeze's §1.3 makes the render thread's drain a
  correctness clause (one blocking `Take()`, then `TryTake()` to exhaustion,
  applied in enqueue order). A one-item-per-pass drain is F-5's shape at a new
  scale and this text gate CANNOT see it. O2's measured `events_total` row is
  the instrument for that; this gate is not.
* It asserts that `Decide` is CALLED in each entry region, not that its answer
  is obeyed. A handler that calls `Decide` and then ignores a `Refuse` passes
  here and reds in O6, which drives a real 0-height `SizeChanged` through the
  window manager.
* Only `prototypes/sb_winui/*.cs`. The PowerShell harness (`sitting.ps1`,
  `verify_window.ps1`) reads knobs too; O7 censuses those knobs, and no gate
  asserts anything about the harness's own control flow.
* Interpolated-string holes are opaque payload (see `csharp_source.py`). A
  clamp written inside `$"{Math.Max(w, 1)}"` would not be seen.

RED ON `main` BY CONSTRUCTION, and that is the point. At 3c8fddce this gate
reports the three clamps, the un-split `SB_FRAMES` read, the absent `Benchmark`
and the absent `SurfacePolicy`. Its LIVE arm is wired into CI by N5b, in the
same pull request as the shell that satisfies it; only `--self-test` runs today.
"""

from __future__ import annotations

import os
import pathlib
import re
import subprocess
import sys

# os.path, not str(Path): check_path_keying.py forbids rendering a Path to text
# because str(Path) yields backslashes on Windows.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from csharp_source import blocks, enclosing_blocks, enclosing_method, lex  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
SHELL_GLOB = "prototypes/sb_winui/*.cs"

# The ONE method allowed to read SB_FRAMES besides `Benchmark`, with its reason.
# A whitelist without an argument is a hole with a name; this one is checked for
# staleness below, so it cannot outlive the read it excuses.
SB_FRAMES_WHITELIST: dict[str, str] = {
    "Report": "writes the knob's value into the sb-runs.log receipt row -- a LOG "
              "field describing the run, not a read on the interaction path "
              "(FREEZE §1.2; MainWindow.xaml.cs:219 at 3c8fddce)",
}

# The method the one non-whitelisted read must live in.
BENCHMARK_METHOD = "Benchmark"

# The scene literal that marks the dispatch's benchmark arm.
BENCHMARK_SCENE = '"benchmark"'

# The three entry kinds every surface dimension must pass through Decide.
ENTRY_METHODS = ("Attach", "Resize")

DECIDE = re.compile(r"(?<![A-Za-z0-9_])SurfacePolicy\s*\.\s*Decide\s*\(")

# ---- the four clamp spellings, WHOLE IDENTIFIER --------------------------
# `(?<![A-Za-z0-9_.])` on the left keeps `Foo.Math.Max` matched (it is the same
# clamp) while `(?![A-Za-z0-9_])` on the right refuses `Math.Maxima`.
CLAMPS = {
    "Math.Max / Math.Clamp":
        re.compile(r"(?<![A-Za-z0-9_])(?:System\s*\.\s*)?Math\s*\.\s*(?:Max|Clamp)(?![A-Za-z0-9_])"),
    "ternary clamp-to-one (x < 1 ? 1 : x)":
        re.compile(r"(?<![A-Za-z0-9_.])([A-Za-z_][\w.]*)\s*<\s*1\s*\?\s*1\s*:\s*\1(?![A-Za-z0-9_])"),
    "ternary clamp-to-one (x > 1 ? x : 1)":
        re.compile(r"(?<![A-Za-z0-9_.])([A-Za-z_][\w.]*)\s*>=?\s*1\s*\?\s*\1\s*:\s*1(?![A-Za-z0-9_])"),
}

ENV_READ = re.compile(r"(?<![A-Za-z0-9_])Environment\s*\.\s*GetEnvironmentVariable\s*\(\s*\"([A-Za-z_][A-Za-z0-9_]*)\"\s*\)")
# NO `.` IN THE LOOKBEHIND, AND THAT IS THE FIX. The first cut matched an
# optional single-receiver prefix (`_canvas.`) and excluded `.` on the left,
# which made `host.canvas.Benchmark(` unmatchable from either start position
# -- a two-level member call was invisible to the clause. Excluding word
# characters only catches every receiver depth, and still refuses
# `MyBenchmark(`. The declaration is excluded by _sig_regions, not by this.
BENCH_CALL = re.compile(r"(?<![A-Za-z0-9_])Benchmark\s*\(")
SIZECHANGED = re.compile(r"(?<![A-Za-z0-9_])SizeChanged\s*\+=")
NAMED_HANDLER = re.compile(r"(?<![A-Za-z0-9_])SizeChanged\s*\+=\s*([A-Za-z_]\w*)\s*;")
CASE_BENCH = re.compile(r"(?<![A-Za-z0-9_])case\s+\"benchmark\"\s*:", re.IGNORECASE)
ANY_CASE = re.compile(r"(?<![A-Za-z0-9_])(?:case\s+[^:;{}]+:|default\s*:)")


class Refuse(Exception):
    """The source cannot be decided statically. Refuse; never guess."""


def _parse(files: dict[str, str]):
    """{name: text} -> {name: (Lexed, [Block])}."""
    return {name: (lex(text), blocks(lex(text).code)) for name, text in sorted(files.items())}


def _sig_regions(bs):
    """Byte ranges that are METHOD SIGNATURES, so a declaration is not a call."""
    return [(b.sig_start, b.body_start) for b in bs if b.method and b.sig_start is not None]


def _guarded_by_benchmark(lx, bs, off) -> bool:
    """True iff `off` sits in an arm whose own guard names the benchmark scene."""
    for b in enclosing_blocks(bs, off):
        head = lx.decommented[b.head_start:b.body_start]
        if BENCHMARK_SCENE in head.lower():
            return True
    inner = enclosing_blocks(bs, off)
    limit = inner[0].body_start if inner else 0
    labels = [(m.start(), m.group(0)) for m in ANY_CASE.finditer(lx.decommented)
              if limit <= m.start() < off]
    if labels:
        _, last = max(labels)
        if CASE_BENCH.match(last):
            return True
    return False


def _sizechanged_regions(name, lx, bs, findings):
    """[(kind, label, start, end)] for every `SizeChanged +=` in one file.

    The KIND travels beside the label rather than being read back out of it: an
    earlier cut derived the kind by splitting the label on its backticks, which
    yielded the HANDLER's name for the named-handler spelling and silently made
    the SizeChanged floor unsatisfiable.
    """
    out = []
    for m in SIZECHANGED.finditer(lx.code):
        line = lx.line_of(m.start())
        named = NAMED_HANDLER.match(lx.code, m.start())
        if named:
            handler = named.group(1)
            hits = [b for b in bs if b.method == handler]
            if not hits:
                findings.append(
                    f"{name}:{line}: REFUSING to guess -- `SizeChanged += {handler};` "
                    f"names a handler this file does not declare, so the gate cannot "
                    f"tell whether its width/height reach SurfacePolicy.Decide")
                continue
            b = hits[0]
            out.append(("SizeChanged", f"the SizeChanged handler `{handler}`",
                        b.body_start, b.body_end))
            continue
        cands = [b for b in bs if b.body_start > m.end() and b.head_start <= m.start()]
        if not cands:
            findings.append(
                f"{name}:{line}: REFUSING to guess -- `SizeChanged +=` is followed by "
                f"neither a named handler nor a braced lambda body")
            continue
        b = min(cands, key=lambda b: b.body_start)
        out.append(("SizeChanged", "the SizeChanged handler (lambda)",
                    b.body_start, b.body_end))
    return out


def scan(files: dict[str, str]) -> list[str]:
    """Findings for a mapping of C#-file-name -> source text. Empty == green."""
    findings: list[str] = []

    # ---- ANTI-VACUITY, FIRST. A scan that examined nothing is not a pass. ----
    if not files:
        findings.append(
            "NO C# source was scanned. Every assertion below is a ban or a count "
            "over an empty population, and an empty population satisfies a ban. "
            "This is not a pass.")
        return findings
    parsed = _parse(files)
    if not any(lx.code.strip() for lx, _ in parsed.values()):
        findings.append(
            f"{len(files)} file(s) scanned and NOT ONE CODE CHARACTER survived "
            f"comment/string blanking -- the reader is broken or the shell is "
            f"prose. This is not a pass.")
        return findings

    # ---- (c) the clamp ban ------------------------------------------------
    for name, (lx, _) in parsed.items():
        for label, rx in CLAMPS.items():
            for m in rx.finditer(lx.code):
                findings.append(
                    f"{name}:{lx.line_of(m.start())}: CLAMP `{m.group(0).strip()}` "
                    f"({label}) -- F-6's silent 0x0 acceptance. The shell has no "
                    f"use for a clamp: SurfacePolicy.Decide answers Refuse, Defer "
                    f"or Accept, and a surface the user did not have is refused, "
                    f"never rounded up to 1 px")

    # ---- (a) SB_FRAMES: one read, in Benchmark, one named whitelist entry ----
    reads = []
    for name, (lx, bs) in parsed.items():
        for m in ENV_READ.finditer(lx.decommented):
            if m.group(1) != "SB_FRAMES" or lx.in_string(m.start()):
                continue
            meth = enclosing_method(bs, m.start())
            reads.append((name, lx.line_of(m.start()), meth.method if meth else None))

    outside = [r for r in reads if r[2] not in SB_FRAMES_WHITELIST]
    if len(outside) != 1:
        where = ", ".join(f"{n}:{ln} (in {mn or '<no enclosing method>'})"
                          for n, ln, mn in outside) or "nowhere"
        findings.append(
            f"SB_FRAMES is read {len(outside)} time(s) outside the whitelist "
            f"[{', '.join(sorted(SB_FRAMES_WHITELIST))}], want exactly 1 -- at "
            f"{where}. F-5 was a second read on the interaction path; a zero "
            f"count means the benchmark loop lost its knob")
    else:
        name, line, meth = outside[0]
        if meth != BENCHMARK_METHOD:
            findings.append(
                f"{name}:{line}: SB_FRAMES is read in "
                f"`{meth or '<no enclosing method>'}`, not in `{BENCHMARK_METHOD}` "
                f"-- that is F-5 exactly: the frame-count knob reachable from the "
                f"path a resize takes")

    live_whitelist = {r[2] for r in reads if r[2] in SB_FRAMES_WHITELIST}
    for entry in sorted(set(SB_FRAMES_WHITELIST) - live_whitelist):
        findings.append(
            f"STALE whitelist entry `{entry}`: it excuses an SB_FRAMES read that "
            f"no method of that name performs any more. Delete the row in the "
            f"commit that deleted the read -- an exemption nobody visits is how a "
            f"hole becomes permanent")

    # ---- (b) Benchmark call sites ------------------------------------------
    call_sites = 0
    for name, (lx, bs) in parsed.items():
        sigs = _sig_regions(bs)
        for m in BENCH_CALL.finditer(lx.code):
            if any(a <= m.start() < b for a, b in sigs):
                continue                        # a declaration, not a call
            call_sites += 1
            if not _guarded_by_benchmark(lx, bs, m.start()):
                findings.append(
                    f"{name}:{lx.line_of(m.start())}: `Benchmark(` is called from an "
                    f"arm whose guard does not name the scene {BENCHMARK_SCENE}. The "
                    f"benchmark loop belongs to the SB_SCENE dispatch's benchmark arm "
                    f"and to nothing else; a call from the resize path is F-5")
    if call_sites == 0:
        findings.append(
            "NO `Benchmark(` call site exists. Either the benchmark arm is gone -- "
            "and every S-B/S-C number on record loses the loop that produced it -- "
            "or this gate's call-site clause is asserting nothing. This is not a "
            "pass.")

    # ---- (d) every entry passes through SurfacePolicy.Decide ----------------
    regions = []
    for name, (lx, bs) in parsed.items():
        for b in bs:
            if b.method in ENTRY_METHODS:
                regions.append((name, lx, b.method, f"the method `{b.method}`",
                                b.body_start, b.body_end))
        for kind, label, start, end in _sizechanged_regions(name, lx, bs, findings):
            regions.append((name, lx, kind, label, start, end))

    kinds_found = {kind for _, _, kind, _, _, _ in regions}
    for want in ENTRY_METHODS:
        if want not in kinds_found:
            findings.append(
                f"NO method named `{want}` was found in the shell. The positive "
                f"half of this gate -- every surface dimension passes through "
                f"SurfacePolicy.Decide -- would be vacuously satisfied over the "
                f"entry points it cannot find. This is not a pass.")
    if "SizeChanged" not in kinds_found:
        findings.append(
            "NO `SizeChanged +=` subscription was found in the shell. The window's "
            "own resize event is the entry F-6 came in through; a gate that cannot "
            "find it is asserting nothing about it. This is not a pass.")

    for name, lx, _kind, label, start, end in regions:
        if not DECIDE.search(lx.code[start:end]):
            findings.append(
                f"{name}:{lx.line_of(start)}: {label} takes a width/height and never "
                f"calls SurfacePolicy.Decide. Every dimension entering Attach, Resize "
                f"or the SizeChanged handler is decided there -- Refuse for a zero "
                f"once a surface exists, Defer for a zero before Attach, Accept "
                f"otherwise -- and no other code decides it")

    return findings


# --------------------------------------------------------------------------
# live mode
# --------------------------------------------------------------------------

def _tracked_shell_files() -> int:
    """How many shell `.cs` files GIT knows about.

    DERIVED, and from a DIFFERENT ORACLE than the pathlib glob this gate scans
    with -- the floor exists to catch that glob silently matching less, and a
    floor computed from the same glob would agree with any breakage. It FAILS
    CLOSED: an unreachable oracle is an error, never a zero, because a floor of
    zero passes every possible tree including an empty one.
    (The shape is check_lane_coverage.py's `_tracked_check_scripts`.)
    """
    try:
        out = subprocess.run(["git", "ls-files", SHELL_GLOB], cwd=ROOT,
                             capture_output=True, text=True, encoding="utf-8",
                             check=True).stdout
    except (OSError, subprocess.CalledProcessError) as e:
        raise Refuse(
            f"cannot derive the file floor: `git ls-files {SHELL_GLOB}` is "
            f"unavailable ({e}). Refusing to scan rather than guarding nothing."
        ) from e
    return len([l for l in out.splitlines() if l.strip()])


def _load() -> dict[str, str]:
    found = {}
    for p in sorted(ROOT.glob(SHELL_GLOB)):
        found[p.relative_to(ROOT).as_posix()] = p.read_text(encoding="utf-8")
    tracked = _tracked_shell_files()
    if tracked == 0:
        raise Refuse(
            f"`git ls-files {SHELL_GLOB}` matched nothing. Either the shell moved "
            f"or this is not the repo -- both make every assertion vacuous.")
    if len(found) != tracked:
        raise Refuse(
            f"the filesystem glob found {len(found)} shell file(s) and git tracks "
            f"{tracked}. The two oracles disagree; refusing to report coverage "
            f"over a population this gate cannot pin down.")
    return found


# --------------------------------------------------------------------------
# self-test
# --------------------------------------------------------------------------

CLEAN = {
    "Canvas.cs": '''
using System;

internal enum Decision { Accept, Refuse, Defer }

internal static class SurfacePolicy
{
    // Three-valued, and the shell's ONLY answer to a zero. The clamp this
    // replaced was Math.Max(width, 1) -- named here so the ban is explained
    // where it bites, and so this gate proves comments are blanked.
    internal static Decision Decide(uint w, uint h, bool hasSurface)
    {
        if (w == 0 || h == 0) { return hasSurface ? Decision.Refuse : Decision.Defer; }
        return Decision.Accept;
    }
}

internal sealed class Canvas
{
    public void Attach(uint width, uint height)
    {
        var d = SurfacePolicy.Decide(width, height, false);
        if (d == Decision.Accept) { CreateDeviceAndSwapChain(width, height); }
    }

    public bool Resize(uint width, uint height)
    {
        var d = SurfacePolicy.Decide(width, height, true);
        if (d != Decision.Accept) { return false; }
        return ResizeBuffers(width, height);
    }

    public bool Repaint()
    {
        // Draws ONCE. No frame count, no knob.
        return PaintFrame();
    }

    public bool Benchmark()
    {
        var frames = int.TryParse(Environment.GetEnvironmentVariable("SB_FRAMES"), out var f) ? f : 60;
        for (var i = 0; i < frames; i++) { PaintFrame(); }
        return true;
    }

    private double Scale(double v)
    {
        // Arithmetic that is NOT a clamp stays legal, and the decoy identifiers
        // prove the ban is whole-identifier rather than substring.
        var a = Math.Abs(v);
        var r = Math.Round(a * MathMaxima.Factor);
        return Mathematics.Maxwell(r);
    }
}
''',
    "MainWindow.xaml.cs": '''
using System;

internal sealed class MainWindow
{
    public MainWindow()
    {
        Canvas.SizeChanged += (_, e) =>
        {
            var w = (uint)e.NewSize.Width;
            var h = (uint)e.NewSize.Height;
            var d = SurfacePolicy.Decide(w, h, _started);
            if (d == Decision.Accept) { _canvas.Enqueue(new Resize(w, h)); }
        };
    }

    private void Dispatch()
    {
        var scene = Environment.GetEnvironmentVariable("SB_SCENE");
        if (string.IsNullOrWhiteSpace(scene)) { scene = "benchmark"; }
        if (string.Equals(scene, "benchmark", StringComparison.OrdinalIgnoreCase))
        {
            _canvas.Benchmark();
        }
        else
        {
            _canvas.Repaint();
        }
    }

    private void Report(string status)
    {
        var frames = Environment.GetEnvironmentVariable("SB_FRAMES") ?? "(default:60)";
        Log("the clamp Math.Max(w, 1) and the read Environment.GetEnvironmentVariable(\\"SB_FRAMES\\") are quoted here as PAYLOAD");
        Append($"SB_FRAMES={frames} {status}");
    }
}
''',
}


def _mutate(where: str, old: str, new: str) -> dict[str, str]:
    """A fixture COPY with exactly one planted violation.

    `count == 1` is asserted: an ambiguous anchor that matched a byte-identical
    sibling would plant the violation somewhere other than the arm's name says,
    and the arm would still go red -- for the wrong reason, forever.
    """
    files = dict(CLEAN)
    assert files[where].count(old) == 1, f"ambiguous anchor {old!r} in {where}"
    files[where] = files[where].replace(old, new)
    return files


def self_test() -> int:
    failures: list[str] = []

    def red(label, files, needle=None):
        found = scan(files)
        if not found:
            failures.append(f"{label}: must RED, got green")
        elif needle and not any(needle in f for f in found):
            failures.append(f"{label}: red, but no finding mentions {needle!r}: {found}")

    def green(label, files):
        found = scan(files)
        if found:
            failures.append(f"{label}: must be GREEN, got {found}")

    # (0) THE EMPTY SET, FIRST -- before any arm that could pass by being empty.
    if not scan({}):
        failures.append("0: an empty file set must be FATAL, not green")
    if not any("not a pass" in f for f in scan({"a.cs": "// only a comment\n"})):
        failures.append("0b: a file set with no code must hit the anti-vacuity floor")

    # (1) The clean post-N1 shape passes, decoys and all.
    green("1 clean fixture", CLEAN)

    # (2)-(5) ALL FOUR CLAMP SPELLINGS. A blacklist passes the tests you wrote,
    #         so each spelling is planted separately and named separately.
    red("2 Math.Max", _mutate("Canvas.cs", "return ResizeBuffers(width, height);",
                              "return ResizeBuffers(Math.Max(width, 1), height);"),
        "CLAMP")
    red("3 Math.Clamp", _mutate("Canvas.cs", "return ResizeBuffers(width, height);",
                                "return ResizeBuffers(Math.Clamp(width, 1, 8192), height);"),
        "CLAMP")
    red("4 System.Math.Max", _mutate("Canvas.cs", "return ResizeBuffers(width, height);",
                                     "return ResizeBuffers(System.Math.Max(width, 1), height);"),
        "CLAMP")
    red("5 ternary w < 1 ? 1 : w",
        _mutate("Canvas.cs", "return ResizeBuffers(width, height);",
                "return ResizeBuffers(width < 1 ? 1 : width, height);"), "CLAMP")
    red("5b ternary w > 1 ? w : 1",
        _mutate("Canvas.cs", "return ResizeBuffers(width, height);",
                "return ResizeBuffers(width > 1 ? width : 1, height);"), "CLAMP")

    # (6) THE DECOYS, ASSERTED AS DECOYS. Case (1) would pass if the ban never
    #     fired at all, so prove the ban is whole-identifier by DELETING the
    #     decoys and confirming (1) still passes -- and by driving a clamp that
    #     differs from a decoy in one character.
    without_decoys = _mutate(
        "Canvas.cs",
        "        var r = Math.Round(a * MathMaxima.Factor);\n"
        "        return Mathematics.Maxwell(r);\n",
        "        return a;\n")
    green("6 clean without the decoys", without_decoys)
    red("6b `Math.Max` one character from the decoy `MathMaxima`",
        _mutate("Canvas.cs", "var r = Math.Round(a * MathMaxima.Factor);",
                "var r = Math.Max(a, MathMaxima.Factor);"), "CLAMP")

    # (7) A clamp inside a COMMENT and inside a STRING must stay green -- the
    #     clean fixture already carries both (SurfacePolicy's comment and
    #     Report's payload line). Prove they are load-bearing by driving the
    #     same text as CODE.
    red("7 the same clamp text, as code",
        _mutate("Canvas.cs", "if (d == Decision.Accept) { CreateDeviceAndSwapChain(width, height); }",
                "CreateDeviceAndSwapChain(Math.Max(width, 1), height);"), "CLAMP")

    # (8) SB_FRAMES: a second read outside the whitelist.
    red("8 a second SB_FRAMES read",
        _mutate("Canvas.cs", "        // Draws ONCE. No frame count, no knob.\n",
                '        var f = Environment.GetEnvironmentVariable("SB_FRAMES");\n'),
        "SB_FRAMES is read 2 time(s)")

    # (9) SB_FRAMES read moved OUT of Benchmark -- F-5 exactly.
    red("9 the read outside Benchmark",
        _mutate("Canvas.cs",
                "    public bool Repaint()\n    {\n"
                "        // Draws ONCE. No frame count, no knob.\n"
                "        return PaintFrame();\n    }\n\n"
                "    public bool Benchmark()\n    {\n"
                '        var frames = int.TryParse(Environment.GetEnvironmentVariable("SB_FRAMES"), out var f) ? f : 60;\n',
                "    public bool Repaint()\n    {\n"
                '        var frames = int.TryParse(Environment.GetEnvironmentVariable("SB_FRAMES"), out var f) ? f : 60;\n'
                "        return PaintFrame();\n    }\n\n"
                "    public bool Benchmark()\n    {\n"
                "        var frames = 60;\n"),
        "not in `Benchmark`")

    # (10) ZERO reads is not a pass either -- the count is exact, not a ceiling.
    red("10 no SB_FRAMES read at all",
        _mutate("Canvas.cs",
                'var frames = int.TryParse(Environment.GetEnvironmentVariable("SB_FRAMES"), out var f) ? f : 60;',
                "var frames = 60;"),
        "want exactly 1")

    # (11) THE WHITELIST GOES STALE. Delete Report's read and the entry that
    #      excused it must be reported, not silently satisfied.
    red("11 stale whitelist entry",
        _mutate("MainWindow.xaml.cs",
                'var frames = Environment.GetEnvironmentVariable("SB_FRAMES") ?? "(default:60)";',
                'var frames = "(not recorded)";'),
        "STALE whitelist entry")

    # (12) A `Benchmark(` call outside the dispatch's benchmark arm.
    red("12 Benchmark called off the arm",
        _mutate("MainWindow.xaml.cs",
                "            if (d == Decision.Accept) { _canvas.Enqueue(new Resize(w, h)); }",
                "            if (d == Decision.Accept) { _canvas.Benchmark(); }"),
        "does not name the scene")

    # (12b) A TWO-LEVEL member call. The first cut of BENCH_CALL allowed one
    #       receiver and excluded `.` on the left, so `host.canvas.Benchmark(`
    #       matched from neither start position and was invisible to the clause.
    red("12b Benchmark called off the arm, two-level receiver",
        _mutate("MainWindow.xaml.cs",
                "            if (d == Decision.Accept) { _canvas.Enqueue(new Resize(w, h)); }",
                "            if (d == Decision.Accept) { _host.canvas.Benchmark(); }"),
        "does not name the scene")

    # (13) NO call site at all: a benchmark nobody calls.
    red("13 no Benchmark call site",
        _mutate("MainWindow.xaml.cs", "            _canvas.Benchmark();",
                "            _canvas.Repaint();"),
        "NO `Benchmark(` call site")

    # (14) A `case \"benchmark\":` label is the other legal arm shape.
    green("14 the switch-label arm", _mutate(
        "MainWindow.xaml.cs",
        '        if (string.Equals(scene, "benchmark", StringComparison.OrdinalIgnoreCase))\n'
        "        {\n            _canvas.Benchmark();\n        }\n"
        "        else\n        {\n            _canvas.Repaint();\n        }\n",
        "        switch (scene)\n        {\n"
        '            case "benchmark":\n                _canvas.Benchmark();\n                break;\n'
        "            default:\n                _canvas.Repaint();\n                break;\n"
        "        }\n"))

    # (15)-(17) THE POSITIVE HALF, one entry kind at a time.
    red("15 Attach bypasses Decide",
        _mutate("Canvas.cs",
                "        var d = SurfacePolicy.Decide(width, height, false);\n"
                "        if (d == Decision.Accept) { CreateDeviceAndSwapChain(width, height); }",
                "        CreateDeviceAndSwapChain(width, height);"),
        "never calls SurfacePolicy.Decide")
    red("16 Resize bypasses Decide",
        _mutate("Canvas.cs",
                "        var d = SurfacePolicy.Decide(width, height, true);\n"
                "        if (d != Decision.Accept) { return false; }\n",
                ""),
        "never calls SurfacePolicy.Decide")
    red("17 the SizeChanged handler bypasses Decide",
        _mutate("MainWindow.xaml.cs",
                "            var d = SurfacePolicy.Decide(w, h, _started);\n"
                "            if (d == Decision.Accept) { _canvas.Enqueue(new Resize(w, h)); }",
                "            _canvas.Enqueue(new Resize(w, h));"),
        "never calls SurfacePolicy.Decide")

    # (18) A COMMENTED-OUT Decide is not a Decide. Without this, deleting the
    #      call and leaving the comment behind reads identically to the repair.
    red("18 Decide only in a comment",
        _mutate("MainWindow.xaml.cs",
                "            var d = SurfacePolicy.Decide(w, h, _started);",
                "            // var d = SurfacePolicy.Decide(w, h, _started);\n"
                "            var d = Decision.Accept;"),
        "never calls SurfacePolicy.Decide")

    # (19)-(21) THE ENTRY-KIND FLOORS. A gate that cannot find the entry is not
    #           entitled to report that the entry is clean.
    red("19 no Attach method",
        _mutate("Canvas.cs", "    public void Attach(uint width, uint height)",
                "    public void Bind(uint width, uint height)"),
        "NO method named `Attach`")
    red("20 no Resize method",
        _mutate("Canvas.cs", "    public bool Resize(uint width, uint height)",
                "    public bool Rescale(uint width, uint height)"),
        "NO method named `Resize`")
    red("21 no SizeChanged subscription",
        _mutate("MainWindow.xaml.cs", "        Canvas.SizeChanged += (_, e) =>",
                "        Canvas.Loaded += (_, e) =>"),
        "NO `SizeChanged +=` subscription")

    # (22) The NAMED-HANDLER spelling resolves to its method...
    named = _mutate(
        "MainWindow.xaml.cs",
        "        Canvas.SizeChanged += (_, e) =>\n        {\n"
        "            var w = (uint)e.NewSize.Width;\n"
        "            var h = (uint)e.NewSize.Height;\n"
        "            var d = SurfacePolicy.Decide(w, h, _started);\n"
        "            if (d == Decision.Accept) { _canvas.Enqueue(new Resize(w, h)); }\n"
        "        };\n",
        "        Canvas.SizeChanged += OnCanvasSizeChanged;\n")
    named["MainWindow.xaml.cs"] = named["MainWindow.xaml.cs"].replace(
        "    private void Dispatch()",
        "    private void OnCanvasSizeChanged(object s, SizeChangedEventArgs e)\n"
        "    {\n"
        "        var w = (uint)e.NewSize.Width;\n"
        "        var h = (uint)e.NewSize.Height;\n"
        "        var d = SurfacePolicy.Decide(w, h, _started);\n"
        "        if (d == Decision.Accept) { _canvas.Enqueue(new Resize(w, h)); }\n"
        "    }\n\n    private void Dispatch()")
    green("22 named SizeChanged handler", named)

    # (23) ...and a named handler this gate cannot find is a REFUSAL, not a pass.
    orphan = dict(named)
    orphan["MainWindow.xaml.cs"] = orphan["MainWindow.xaml.cs"].replace(
        "OnCanvasSizeChanged(object s", "OnCanvasSizeChangedRenamed(object s")
    red("23 named handler that does not exist", orphan, "REFUSING to guess")

    # ⛔ NO LIVE-TREE ARM HERE, AND THAT IS A DECISION. This gate's live mode is
    #    RED on `main` by construction (three clamps, an un-split SB_FRAMES read,
    #    no SurfacePolicy) and GREEN once the shell lands. An arm asserting either
    #    would be an arm that must be edited by the very PR it is meant to judge,
    #    and the freeze (§3, N5a) says these self-tests are green on ANY tree.
    #    The live red is a RECEIPT, pasted into N5a's pull request; the live arm
    #    is wired into CI by N5b, in the same PR as the shell that satisfies it.

    for f in failures:
        print(f"SELF-TEST FAIL: {f}")
    if failures:
        return 1
    print(
        "check_shell_interaction_path SELF-TEST: OK (empty scan fatal proven "
        "FIRST; all FOUR clamp spellings planted separately and caught, plus the "
        "mirrored ternary; whole-identifier decoys MathMaxima/Mathematics.Maxwell "
        "and Math.Abs/Math.Round stay green and are proven load-bearing; a clamp "
        "in a comment and in a string stay green while the same text as code "
        "reds; SB_FRAMES second read / read outside Benchmark / zero reads all "
        "red; the named whitelist goes STALE when its read leaves; a Benchmark "
        "call off the arm reds and both arm spellings -- if-guard and case-label "
        "-- pass; each of the three Decide entries reds separately, a "
        "commented-out Decide does not count, and each missing entry kind hits "
        "its own floor; the named-handler spelling resolves and an orphan handler "
        "REFUSES. NO live-tree arm: the live mode is red on main by "
        "construction and green once the shell lands, so it is a RECEIPT in "
        "N5a's PR and a CI arm in N5b's, never an assertion in here)")
    return 0


def main() -> int:
    if "--self-test" in sys.argv[1:]:
        return self_test()
    try:
        files = _load()
    except Refuse as exc:
        print(f"REFUSING: {exc}")
        return 1
    findings = scan(files)
    if findings:
        print("FAIL: the benchmark loop or the surface clamp is on the interaction path.")
        for f in findings:
            print(f"  {f}")
        print()
        print("O2b (FREEZE §2). Repaint() draws once and reads no knob; Benchmark(")
        print("frames) owns SB_FRAMES and is called only from the SB_SCENE dispatch's")
        print("benchmark arm; every width and height is decided by SurfacePolicy.Decide,")
        print("never clamped to 1.")
        return 1
    print(f"check_shell_interaction_path: OK ({len(files)} shell file(s) scanned; "
          f"one SB_FRAMES read, in Benchmark; whitelist {sorted(SB_FRAMES_WHITELIST)}; "
          f"no clamp in any of {len(CLAMPS)} banned spellings; every Attach/Resize/"
          f"SizeChanged entry passes through SurfacePolicy.Decide)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
