#!/usr/bin/env python3
"""W2b-9 — the C# shell states its widget-kind list TWICE, and nothing joins them.

`prototypes/sc_panel/Materializer.cs` holds the same fact in two places:

  * `EasyKinds`, a `HashSet<string>` — the GATE. A kind outside it is drawn as
    a `[kind]` placeholder and counted in `Result.Placeholders`.
  * the `switch (kind)` in `Materialize` — the MATERIALISER, one arm per kind.

The switch's own `default:` arm says what happens when they drift:

    // Reachable only if EasyKinds and this switch disagree. Counted
    // as a placeholder rather than silently dropped, because a widget

⇒ Adding a kind to ONE of them is a complete, compiling, reviewable change, and
its failure mode is a silent placeholder rather than an error. That is the
`one-fact-in-three-places-with-no-join` shape, and this is the join.

⛔ THIS GATE IS GREEN THE DAY IT LANDS — the two sets agree (16 each) at the
commit that introduced it. Its value is preventing the class, not fixing an
instance, so it was validated by MUTATION in both directions rather than by
passing: remove a kind from either side and the live arm reds naming it.

The C# does not compile on the seat that wrote this. It does not need to: the
claim is about two literal lists in one file, which is a reading.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "prototypes" / "sc_panel" / "Materializer.cs"
WORKFLOW = ROOT / ".github" / "workflows" / "test.yml"
SELF = "scripts/check_shell_widget_kinds.py"


def easy_kinds(src: str) -> set[str]:
    """The `EasyKinds` initialiser's string literals."""
    m = re.search(r"EasyKinds\s*=\s*new\(\)\s*\{(.*?)\}\s*;", src, re.S)
    if m is None:
        raise LookupError("EasyKinds initialiser not found — the shape changed")
    return set(re.findall(r'"([a-z_]+)"', m.group(1)))


def switch_labels(src: str) -> set[str]:
    """The `case "..."` labels of the `switch (kind)` in `Materialize`, up to
    its `default:`. Bounded at `default:` deliberately: a `case` after it would
    belong to a different switch, and silently absorbing one would make this
    gate agree with a file it had misread."""
    i = src.find("switch (kind)")
    if i < 0:
        raise LookupError("`switch (kind)` not found — the shape changed")
    j = src.find("default:", i)
    if j < 0:
        raise LookupError("the switch has no `default:` — the shape changed")
    return set(re.findall(r'case\s+"([a-z_]+)"\s*:', src[i:j]))


def compare(src: str) -> list[str]:
    """Failures, naming the kind and the side it is missing from."""
    easy, labels = easy_kinds(src), switch_labels(src)
    out: list[str] = []
    # ANTI-VACUITY: a regex that matched nothing would otherwise report two
    # empty sets as agreeing, which is the exact failure this gate exists to
    # catch one level up.
    if len(easy) < 8 or len(labels) < 8:
        out.append(
            f"read only {len(easy)} EasyKinds and {len(labels)} switch labels; "
            "the file's shape changed and this gate is no longer measuring"
        )
        return out
    for k in sorted(easy - labels):
        out.append(f"`{k}` is in EasyKinds and has no switch arm "
                   "— it passes the gate and draws a placeholder")
    for k in sorted(labels - easy):
        out.append(f"`{k}` has a switch arm and is not in EasyKinds "
                   "— the arm is dead, the gate rejects it first")
    return out


def run_self_test() -> int:
    """The READER is verified before the subject, in BOTH directions."""
    src = SOURCE.read_text(encoding="utf-8")
    failures: list[str] = []

    def probe(label: str, text: str) -> list[str] | None:
        """Every self-test read goes through here. ⚠️ A reader that reports a
        defect by RAISING dumps a traceback instead of naming it, and wrapping
        ONE call site only moves the crash to the next one — driven twice while
        writing this."""
        try:
            return compare(text)
        except LookupError as exc:
            failures.append(f"self-test: reading {label} raised — {exc}")
            return None

    if probe("the real file", src):
        failures.append("the real file must be clean at the moment this gate lands")

    # (a) a kind in EasyKinds with no arm
    planted = src.replace('"number_input", "text_input", "button"',
                          '"number_input", "text_input", "button", "planted_kind"', 1)
    if planted == src:
        failures.append("self-test (a) anchor did not apply — the mutation was a no-op")
    elif not any("planted_kind" in f and "no switch arm" in f
                 for f in (probe("self-test (a)", planted) or [])):
        failures.append("self-test (a): a kind in EasyKinds with no arm was NOT caught")

    # (b) an arm with no kind — the other direction, which a one-way
    #     subset check would pass
    planted_b = src.replace('            case "spacer":',
                            '            case "orphan_kind":\n            case "spacer":', 1)
    if planted_b == src:
        failures.append("self-test (b) anchor did not apply — the mutation was a no-op")
    elif not any("orphan_kind" in f and "not in EasyKinds" in f
                 for f in (probe("self-test (b)", planted_b) or [])):
        failures.append("self-test (b): an arm with no EasyKinds entry was NOT caught")

    # (c) the anti-vacuity floor fires when the reader reads nothing
    if not probe("self-test (c)", 'EasyKinds = new() {\n "a" };\nswitch (kind)\n default:'):
        failures.append("self-test (c): the anti-vacuity floor did not fire on an empty read")

    # (e) THE WINDOWS LANE'S CLAIM, TESTED ON EVERY PLATFORM. This gate is
    #     wired on windows-latest because `Materializer.cs` ships there, and a
    #     checkout on that lane has CRLF line endings. A regex that silently
    #     matched NOTHING under CRLF would report two empty sets as AGREEING —
    #     which is the failure this gate exists to catch, one level up. So the
    #     arm is not "does it parse CRLF" but "does it still CATCH under CRLF".
    #     ⚠️ Each read is wrapped: an LF-only assumption in either regex raises
    #     `LookupError` here, and an arm that reports a defect by RAISING dumps
    #     a traceback instead of naming it. Driven: a mutant requiring a bare
    #     `\n` after the EasyKinds brace is caught by name because of this.
    def _safe(label: str, text: str, expect_clean: bool, needle: str = "") -> None:
        found = probe(f"self-test (e) {label}", text)
        if found is None:
            return
        if expect_clean and found:
            failures.append(f"self-test (e): the clean file reds when read as {label}")
        if needle and not any(needle in f for f in found):
            failures.append(
                f"self-test (e): a planted divergence was MISSED under {label} "
                "— that lane would report agreement on two empty reads")

    crlf = src.replace("\n", "\r\n")
    _safe("CRLF", crlf, expect_clean=True)
    crlf_mutant = crlf.replace('"combo_box", "checkbox", "toggle", "label",',
                               '"checkbox", "toggle", "label",', 1)
    if crlf_mutant == crlf:
        failures.append("self-test (e) anchor did not apply under CRLF")
    else:
        _safe("CRLF", crlf_mutant, expect_clean=False, needle="combo_box")
    # And a BOM, which the sibling scene gate documents as real in this tree.
    _safe("a UTF-8 BOM", "\ufeff" + src, expect_clean=True)

    # (d) CI must run the LIVE arm, not `--self-test` alone. A gate that only
    #     ever self-tests is a gate that has never looked at the subject.
    if WORKFLOW.exists():
        live = [
            ln for ln in WORKFLOW.read_text(encoding="utf-8").splitlines()
            if SELF in ln and "--self-test" not in ln
        ]
        if not live:
            failures.append(
                f"(d) {WORKFLOW.name} — add a `{SELF}` step WITHOUT `--self-test`")

    for f in failures:
        print(f"SELF-TEST FAIL: {f}")
    if failures:
        return 1
    print("check_shell_widget_kinds SELF-TEST: OK (the reader is verified first — "
          "both directions of divergence planted and caught, the anti-vacuity floor "
          "driven on an empty read, and CI's live arm confirmed wired)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--self-test", action="store_true",
                    help="verify the reader against planted divergences")
    args = ap.parse_args()
    if args.self_test:
        return run_self_test()

    src = SOURCE.read_text(encoding="utf-8")
    failures = compare(src)
    if failures:
        print(f"check_shell_widget_kinds: FAIL ({len(failures)} finding(s)) — "
              f"{SOURCE.relative_to(ROOT)} states its widget-kind list twice and "
              "the two disagree:")
        for f in failures:
            print(f"  {f}")
        return 1
    n = len(easy_kinds(src))
    print(f"check_shell_widget_kinds: OK ({n} kinds, EasyKinds == the switch's "
          "case labels). LIMIT: this compares two LISTS in one file — it says "
          "nothing about whether an arm draws the right control, and nothing "
          "about kinds the YAML uses that neither list names.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
