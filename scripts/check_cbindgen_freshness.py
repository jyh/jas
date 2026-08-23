#!/usr/bin/env python3
"""The C header a native shell compiles against must match the Rust it describes.

WHY THIS EXISTS
---------------
Every other generated artifact in this repository has a freshness referee. The
five corpus goldens are regenerated and byte-compared on every run
(`check_expr_corpus.sh` and its four siblings); `workspace.json` has
`check_workspace_json.sh`; the panel goldens have `check_panel_goldens.sh`.

`jas_dioxus/include/jas_ffi.h` had none. Measured before this gate was written:

    grep -rln 'cbindgen|jas_ffi.h' scripts/ .github/workflows/   ->   nothing

with a positive control on the same expression -- 28 `check_*.py` under
`scripts/` -- so the emptiness was the subject's, not the query's.

And it had drifted. The committed header was last touched 2026-07-29 (805f0ec2);
regenerating it from source with the pinned cbindgen produced **325 lines against
309 committed, 16 added and 0 removed**. Purely additive, and the addition is two
constants the Rust side had gained -- `CAP_ARC_STEPS` and `PINNED_DPI` -- with
their doc comments.

PIN THE UNIT: 16, not 17. The survey that first found this drift reported 17
added; re-measuring gave 16, and the arithmetic closes on 16 (309 + 16 = 325).
The smaller number is the right one.

WHAT A STALE HEADER COSTS. Nothing that any test in this repository can see,
which is exactly the problem. The Rust builds, every port's suite passes, and the
divergence lives entirely in the artifact a *consumer outside this repo* compiles
against -- `prototypes/ffi_spike/Program.cs` is the one in tree. A C caller that
included this header could not see two constants the library exports. There is no
red anywhere until someone outside the repo tries to use it.

WHAT IT ASSERTS
---------------
1. `cbindgen` is present. If it is not, this FAILS -- it does not skip. A
   freshness gate that quietly passes when its oracle is missing is the vacuity
   this repo has found four times in a week.
2. `cbindgen` is EXACTLY the pinned version. A different version silently emits
   different formatting, which would red this gate for a reason that has nothing
   to do with the source. That is not hypothetical caution: the drift above was
   measured only after checking the tool version first, precisely so tool drift
   could not be mistaken for source drift.
3. The committed header equals what cbindgen generates from `src/ffi.rs`.
4. The generated output is non-trivial -- it carries the include guard and at
   least a floor of declarations. A cbindgen that emitted nothing would otherwise
   compare equal to a header someone had emptied.

WHAT IT DOES NOT COVER
----------------------
* It compares LINES, not bytes. cbindgen's line endings follow the platform it
  runs on, and this gate must pass on both families; `.gitattributes` ("LF is law
  in this repository") already governs what lands in the tree, and
  `check_encoding_hygiene.py` governs how this repo writes text. So a CRLF-only
  difference is invisible HERE, deliberately, and covered THERE.
* It does not check that the header is CORRECT, only that it is CURRENT. If
  cbindgen mis-translates a signature, this gate is satisfied by the
  mis-translation.
* **cbindgen emits 174 RAW warning lines / 153 DISTINCT on this config, and they are
  not all alike.** (Both units, because this gate deduplicates and a reader counting
  raw lines gets a different and equally correct number -- see the note beside the
  classifier. This line first read "~170", which pinned neither the figure nor its
  unit, in a file whose whole argument is that a count without its unit is half a
  claim.)
  The overwhelming majority are `Skip <name> - (not pub)`, which is cbindgen
  narrating every private constant it correctly ignored -- pure noise. This gate
  COUNTS those and prints the count. The handful that are not skips it prints in
  full, because two of them are real:
    - `Missing [defines] entry` for **four** cfgs -- `d2d`, `ffi`, `web`,
      `windows` -- so items behind those `#[cfg]`s are resolved by cbindgen's
      default rather than by a rule this repo wrote down;
    - `Cannot find a mangling for generic path RedBlackTreeMap<String, Rc<Element>>`,
      a type cbindgen could not translate at all.
  Neither FAILS this gate. Fixing the config is a separate change with its own
  blast radius on the generated output, and doing it inside a freshness gate
  would mean the gate's first act was to invalidate the golden it exists to
  protect. **This distinction was itself an instrument lesson:** the first
  measurement of these warnings read `tail -3` of the stream and reported "three
  warnings, all about `ffi`". The stream was 170 lines and the summary was drawn
  from its last three.
* It says nothing about the OTHER direction of staleness: a symbol deleted from
  Rust and still referenced by an outside consumer. That is the consumer's
  compile error, not something this tree can see.
"""

from __future__ import annotations

import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CRATE = ROOT / "jas_dioxus"
CONFIG = CRATE / "cbindgen.toml"
HEADER = CRATE / "include" / "jas_ffi.h"

# The version the header is generated with. Documented at
# prototypes/ffi_spike/README.md:50 and enforced here rather than trusted.
# REFUSE on any other version -- see assertion (2) in the docstring.
PINNED_VERSION = "0.29.4"

# Anti-vacuity floor on the GENERATED side. A tool that produced an empty or
# truncated header would otherwise satisfy a comparison against a header someone
# had emptied in the same commit. Hand-typed because it guards a PARSE and has no
# independent oracle -- the O3.3 DERIVEDFLOOR ruling's second category.
MIN_GENERATED_LINES = 100
GUARD = "JAS_FFI_H"


class Unavailable(Exception):
    """The oracle cannot be reached. FAIL; never skip."""


def _run(argv: list, cwd: pathlib.Path) -> subprocess.CompletedProcess:
    # encoding= is NOT decoration here, and check_encoding_hygiene.py caught its
    # absence in this very file. `text=True` alone decodes with the LOCALE codec
    # -- cp1252 on the Windows runner -- while cbindgen emits UTF-8, including
    # the em-dashes and back-ticks in the doc comments it copies out of the Rust
    # into the header. On Windows that would corrupt the generated text and this
    # gate would report drift that exists only in its own decoder.
    return subprocess.run(
        argv, cwd=cwd, capture_output=True, text=True, encoding="utf-8"
    )


def cbindgen_path() -> str | pathlib.Path:
    """Locate cbindgen, including the cargo bin dir that may not be on PATH.

    Returns the Path UNCONVERTED. `subprocess` accepts PathLike and renders it
    with the platform's own rules, so there is no reason to flatten it to text
    first -- and check_path_keying.py caught exactly that here: `str(Path)`
    yields backslashes on Windows, which is the defect class this repo's Windows
    lane exists to find. It was harmless at this site (argv, not a comparison
    key) and it is still not worth an exemption when not converting is simpler.
    """
    found = shutil.which("cbindgen")
    if found:
        return found
    cargo_bin = pathlib.Path.home() / ".cargo" / "bin" / "cbindgen"
    if cargo_bin.exists():
        return cargo_bin
    raise Unavailable(
        "cbindgen is not installed. This gate FAILS rather than skipping: a "
        "freshness check that passes when its generator is missing reports "
        f"'header is current' having compared nothing. Install {PINNED_VERSION} "
        "(`cargo binstall cbindgen@" + PINNED_VERSION + "`)."
    )


def check_version(exe: str | pathlib.Path) -> str:
    proc = _run([exe, "--version"], ROOT)
    if proc.returncode != 0:
        raise Unavailable(f"`cbindgen --version` exited {proc.returncode}")
    text = proc.stdout.strip()
    version = text.split()[-1] if text else ""
    if version != PINNED_VERSION:
        raise Unavailable(
            f"cbindgen is {version!r}, pinned is {PINNED_VERSION!r}. REFUSING: a "
            f"version difference changes generated formatting, and this gate "
            f"would then red for a reason unrelated to the source."
        )
    return version


def generate(exe: str | pathlib.Path) -> tuple[str, str]:
    """Return (generated header text, cbindgen stderr)."""
    proc = _run([exe, "--config", CONFIG, "--lang", "c"], CRATE)
    if proc.returncode != 0:
        raise Unavailable(
            f"cbindgen exited {proc.returncode}: {proc.stderr.strip()[:400]}"
        )
    return proc.stdout, proc.stderr


def compare(committed: str, generated: str) -> list[str]:
    """Findings for a committed header against a freshly generated one.

    Compares LINES, so a platform's line endings cannot decide the verdict --
    see WHAT IT DOES NOT COVER.
    """
    findings: list[str] = []
    gen_lines = generated.splitlines()
    com_lines = committed.splitlines()

    # ANTI-VACUITY on the generated side, checked BEFORE the comparison so an
    # empty-vs-empty match can never read as agreement.
    if len(gen_lines) < MIN_GENERATED_LINES:
        findings.append(
            f"cbindgen produced only {len(gen_lines)} line(s), floor is "
            f"{MIN_GENERATED_LINES} -- the generator is broken, and comparing "
            f"against its output would be meaningless, not reassuring"
        )
        return findings
    if not any(GUARD in line for line in gen_lines):
        findings.append(
            f"generated header carries no {GUARD} include guard -- the "
            f"generator did not produce this project's header"
        )
        return findings

    if gen_lines == com_lines:
        return findings

    added = [l for l in gen_lines if l not in com_lines]
    removed = [l for l in com_lines if l not in gen_lines]
    findings.append(
        f"{HEADER.relative_to(ROOT).as_posix()} is STALE: committed "
        f"{len(com_lines)} line(s), generated {len(gen_lines)}"
    )
    for line in added[:12]:
        findings.append(f"  only in GENERATED (missing from the header): {line.strip()[:88]}")
    if len(added) > 12:
        findings.append(f"  ... and {len(added) - 12} more generated-only line(s)")
    for line in removed[:12]:
        findings.append(f"  only in COMMITTED (gone from the source): {line.strip()[:88]}")
    if len(removed) > 12:
        findings.append(f"  ... and {len(removed) - 12} more committed-only line(s)")
    return findings


def self_test() -> int:
    """Prove this checker FAILS before trusting any green it reports."""
    failures: list[str] = []
    body = "\n".join([f"/* line {i} */" for i in range(MIN_GENERATED_LINES + 20)])
    good = f"#ifndef {GUARD}\n#define {GUARD}\n{body}\n#endif\n"

    # (a) THE EMPTY GENERATOR, FIRST. Empty vs empty must never read as fresh.
    if not compare("", ""):
        failures.append("an empty generated header must be FATAL, not green")

    # (b) A tool that emitted a stub must red even against a matching stub.
    if not any("floor is" in f for f in compare("short\n", "short\n")):
        failures.append("a below-floor generated header must hit the floor")

    # (c) Identical, non-trivial headers pass.
    if compare(good, good):
        failures.append(f"identical headers must pass, got {compare(good, good)}")

    # (d) THE HISTORICAL DEFECT, planted in its real shape: purely additive
    #     drift, the committed header missing constants the source gained.
    stale = good.replace(f"#define {GUARD}\n", f"#define {GUARD}\n")
    fresh = good.replace("/* line 0 */", "/* line 0 */\n#define CAP_ARC_STEPS 32")
    found = compare(stale, fresh)
    if not found or not any("is STALE" in f for f in found):
        failures.append(f"purely additive drift must be caught, got {found}")
    if not any("CAP_ARC_STEPS" in f for f in found):
        failures.append("the finding must NAME the drifted line, not just count it")

    # (e) The other direction: a symbol gone from source but still in the header.
    gone = compare(good.replace("/* line 5 */", "/* line 5 */\nvoid removed(void);"), good)
    if not any("only in COMMITTED" in f for f in gone):
        failures.append(f"a committed-only line must be reported, got {gone}")

    # (f) A generated header with no include guard is not this project's header.
    noguard = "\n".join(f"/* x {i} */" for i in range(MIN_GENERATED_LINES + 5))
    if not any("include guard" in f for f in compare(good, noguard)):
        failures.append("a guardless generated header must red")

    # (g) LINE ENDINGS MUST NOT DECIDE THE VERDICT -- the stated blindness,
    #     asserted so a future edit cannot remove it silently.
    if compare(good, good.replace("\n", "\r\n")):
        failures.append("a CRLF-only difference must NOT red this gate")

    # (h) The version guard must REFUSE, not pass, on a mismatch. Exercised
    #     through a stub so the self-test needs no cbindgen installed.
    class _Stub:
        def __init__(self, out): self.out = out
        def __call__(self, argv, cwd):
            return subprocess.CompletedProcess(argv, 0, self.out, "")

    global _run
    saved = _run
    try:
        _run = _Stub("cbindgen 9.9.9")
        try:
            check_version("cbindgen")
            failures.append("a version mismatch must raise, not pass")
        except Unavailable as exc:
            if PINNED_VERSION not in str(exc):
                failures.append("the refusal must name the pinned version")
        _run = _Stub(f"cbindgen {PINNED_VERSION}")
        if check_version("cbindgen") != PINNED_VERSION:
            failures.append("the pinned version must be accepted")
    finally:
        _run = saved

    for f in failures:
        print(f"SELF-TEST FAIL: {f}")
    if failures:
        return 1
    print(
        "check_cbindgen_freshness SELF-TEST: OK (empty generator fatal proven "
        "FIRST, below-floor stub caught, additive drift caught AND named, "
        "committed-only lines reported, guardless output refused, CRLF-only "
        "difference proven not to decide the verdict, version mismatch refused)"
    )
    return 0


def main() -> int:
    if "--self-test" in sys.argv[1:]:
        return self_test()

    try:
        exe = cbindgen_path()
        version = check_version(exe)
        generated, stderr = generate(exe)
    except Unavailable as exc:
        print("FAIL: the header's freshness could not be established.")
        print(f"  {exc}")
        return 1

    if not HEADER.exists():
        print("FAIL: the header's freshness could not be established.")
        print(f"  {HEADER.relative_to(ROOT).as_posix()} does not exist, but "
              f"cbindgen generates one from src/ffi.rs")
        return 1

    findings = compare(HEADER.read_text(encoding="utf-8"), generated)

    # Reported, never fatal -- see WHAT IT DOES NOT COVER. CLASSIFIED, because
    # ~170 undifferentiated warnings would bury the finding this gate exists to
    # report: the `Skip ... (not `pub`)` majority is cbindgen narrating private
    # constants it correctly ignored, and only the remainder carries signal.
    raw = [l.strip() for l in stderr.splitlines() if l.startswith("WARN")]
    warns = sorted(set(raw))
    skips = [w for w in warns if w.startswith("WARN: Skip ")]
    raw_skips = [w for w in raw if w.startswith("WARN: Skip ")]
    signal = [w for w in warns if not w.startswith("WARN: Skip ")]
    raw_signal = [w for w in raw if not w.startswith("WARN: Skip ")]

    # BOTH UNITS, ALWAYS. This gate deduplicates, so its counts are DISTINCT
    # warnings; a reader counting raw lines gets a different and equally correct
    # number. Two seats compared 148 against 149 and 5 against 24 before noticing
    # they were counting two populations -- the difference is `feature = "ffi"`
    # alone, which cbindgen emits 21 times. A count without its unit is half a
    # claim, so neither number is printed without the other.
    for w in signal:
        print(f"  note: cbindgen {w[:180]}")
    if signal:
        print(f"  note: {len(signal)} distinct signal warning(s) "
              f"over {len(raw_signal)} raw line(s)")
    if skips:
        print(f"  note: cbindgen also skipped {len(skips)} distinct non-exported "
              f"item(s) over {len(raw_skips)} raw line(s) (`not pub` / unsupported "
              f"literal) -- expected, not reported individually")

    if findings:
        print("FAIL: the committed C header does not match the Rust it describes.")
        for f in findings:
            print(f"  {f}")
        print()
        print("Regenerate it and commit the result:")
        print(f"  cd jas_dioxus && cbindgen --config cbindgen.toml --lang c \\")
        print(f"      --output include/jas_ffi.h")
        print("Nothing in this tree fails when this header is stale -- the cost")
        print("lands on a C consumer OUTSIDE the repo, which is why it needs a")
        print("referee rather than a test.")
        return 1

    print(f"check_cbindgen_freshness: OK (cbindgen {version}, "
          f"{len(generated.splitlines())} generated line(s) match "
          f"{HEADER.relative_to(ROOT).as_posix()})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
