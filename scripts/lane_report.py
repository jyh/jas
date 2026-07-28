#!/usr/bin/env python3
"""Lane accounting for the cross-language runners: ORACLE vs COMPARISON.

WHY THIS EXISTS. A cloud referee replayed this repository on a clean, isolated
Linux box on 2026-07-27. Swift does not exist on Linux, so it ran the corpus
driver with `--lang rust`. With one lane there is nothing to compare against,
and the driver printed exactly this and nothing else:

    Cross-language algorithms: 410 passed, 0 failed, 0 errors (20 algorithms x 0 comparisons)

All 410 of those came from ORACLE checks -- does the reference lane still
reproduce the pinned goldens. **Zero cross-language comparisons happened.** The
one thing the driver exists to do -- cross-check independent implementations --
did not occur, yet the summary line reads like a pass. The referee flagged it
itself: "a reader skimming '410 passed' could easily mistake it for a
cross-language pass."

That is this project's most serious defect class (a claim wider than its
evidence) sitting inside the instrument the whole method rests on. This module
is the fix, shared by every cross-language runner so they cannot drift apart:

  1. TWO NUMBERS, ALWAYS. An ORACLE count and a COMPARISON count, in every run,
     single-lane or not. Neither may absorb the other, and the total is printed
     as their sum so it cannot be read as either one alone.
  2. A LOUD BANNER when the comparison count is zero, naming the lanes that were
     requested, the ones that took part, and the ones that are therefore
     UNCHECKED. It is printed AFTER the counts and BEFORE a one-line VERDICT, so
     the last line of the run states what was and was not established.
  3. EXIT CODES. Zero comparisons is NOT a default failure: a single-lane
     oracle run is a real, valuable thing (it is what proved the pinned goldens
     reproduce on hardware that had never seen this repo). Making it exit 1
     would delete that use. Instead:
       * default          -- exit 0 when nothing failed, with the banner;
       * --require-comparisons -- exit 3 when the run performed no comparison,
         or when a requested comparison lane performed none. CI passes this, so
         the blocking lane can never silently degrade into an oracle-only run;
       * VACUOUS (no oracle checks AND no comparisons) -- exit 3 ALWAYS. A run
         that established nothing must not exit 0 even without the flag.

WHAT THIS MODULE CANNOT SEE -- stated because a gate whose blind spots are
unknown invites exactly the over-claim it was built to stop:

  * IT COUNTS WHAT IT IS TOLD. If a runner forgets to increment a counter, the
     report is honestly rendering a wrong number. Only that runner's own tests
     can catch that; `--self-test` here proves the rendering and the lane
     arithmetic, not the runners' bookkeeping.
  * IT DOES NOT KNOW THE LANES ARE INDEPENDENT. Two lanes that both shell out to
     the same binary would report a comparison count that means nothing. Lane
     independence is a structural property of the ports, not of this file.
  * THE TOOLCHAIN PROBE IS PATH-ONLY. `which(cargo)` says "found", never
     "works": a lane whose binary fails to build still shows as found, and shows
     up instead as the runner's ERROR count.
  * PAIRS COUNTED THROUGH A SHARED GOLDEN are transitive only because the
     anchor is EXACT string equality (see `pairs_via_golden`). A runner that
     ever anchors with a tolerance may not claim pairs that way.
  * COVERAGE IS SOMEONE ELSE'S JOB. Nothing here knows whether the corpus
     covers the behaviour that matters; that is `check_corpus_manifest.py`.

Usage:
    python3 scripts/lane_report.py --self-test
"""
from __future__ import annotations

import re
import shutil
import sys
from dataclasses import dataclass, field

# The ACTIVE ports (POLICY.md section 1, tag `five-port-parity`). The
# cross-language claim this project makes is about these two; a run that leaves
# one out is named in the report for that reason.
ACTIVE_PORTS = ("rust", "swift")

# What a lane needs on PATH to run at all. Used only to explain an absent lane
# ("not found on this machine" vs "present but not requested") -- never to skip
# a lane, because a silent skip is the hazard this module exists to remove.
TOOLCHAIN = {
    "rust": "cargo",
    "swift": "swift",
    "ocaml": "dune",
    "python": "python3",
}

# The banner's headline. The self-test spells this string LITERALLY rather than
# importing it: a fixture built from the constant under test cancels the
# mutation out and detects nothing. (Measured -- that exact flaw was found in
# check_naming_rule.py's self-test on 2026-07-27.)
WARN_HEADLINE = "ZERO CROSS-LANGUAGE COMPARISONS WERE PERFORMED"
SILENT_LANE_HEADLINE = "requested but performed ZERO comparisons"

RULE = "!!! " + "=" * 66

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_NO_COMPARISONS = 3


@dataclass(frozen=True)
class Lanes:
    """Which lanes a run asked for, and which of them compare against which."""

    requested: tuple
    reference: str | None
    comparison: tuple

    @staticmethod
    def resolve(requested) -> "Lanes":
        """Deduplicate (order preserved); lane 0 is the reference.

        Dedup is load-bearing: `--lang rust,swift,swift` must count ONE
        comparison lane, not two, and `--lang rust,rust` must count ZERO --
        i.e. it is an oracle-only run wearing a two-lane costume.
        """
        seen: list[str] = []
        for lang in requested:
            lang = (lang or "").strip()
            if lang and lang not in seen:
                seen.append(lang)
        if not seen:
            return Lanes(requested=(), reference=None, comparison=())
        return Lanes(requested=tuple(seen), reference=seen[0],
                     comparison=tuple(seen[1:]))


def toolchain_available(lang: str, which=shutil.which) -> bool:
    tool = TOOLCHAIN.get(lang)
    return bool(tool and which(tool))


def unexercised_active_ports(lanes: Lanes, which=shutil.which):
    """[(port, why)] for ACTIVE_PORTS that this run did not ask for."""
    out = []
    for port in ACTIVE_PORTS:
        if port in lanes.requested:
            continue
        if toolchain_available(port, which):
            out.append((port, "toolchain present but not requested"))
        else:
            out.append((port, "toolchain not found on this machine"))
    return out


def pairs_via_golden(matched_lane_count: int) -> int:
    """Lane pairs a shared-golden anchor establishes transitively.

    When every lane is compared to the SAME golden by EXACT equality, k lanes
    matching it implies all k*(k-1)/2 lane pairs agree. Sound only for exact
    equality -- a tolerance is not transitive, and a runner that anchors with
    one may not count pairs this way.
    """
    k = max(0, matched_lane_count)
    return k * (k - 1) // 2


@dataclass
class LaneReport:
    """The end-of-run summary. Build it, then `print_report()` and exit with
    `exit_code()`."""

    title: str
    scope: str                       # e.g. "24 algorithms", "14 fixtures"
    lanes: Lanes
    oracle_passed: int = 0
    oracle_failed: int = 0
    comparison_passed: int = 0
    comparison_failed: int = 0
    harness_failed: int = 0          # preflight faults: neither kind of check
    errors: int = 0
    oracle_what: str = "vs pinned goldens"
    comparison_what: str = "lane-vs-lane agreement"
    # Which lanes the oracle checks cover. Usually just the reference lane;
    # the commutativity runner's diagonal cells cover EVERY lane, and a report
    # that named only the reference there would understate its own evidence.
    oracle_lanes: tuple | None = None
    # {lane: comparisons performed}; None when a runner does not track it, in
    # which case the silent-lane check is skipped rather than guessed.
    per_lane_comparisons: dict | None = None
    require_comparisons: bool = False
    unexercised: list = field(default_factory=list)

    # -- derived ---------------------------------------------------------
    @property
    def oracle_checks(self) -> int:
        return self.oracle_passed + self.oracle_failed

    @property
    def comparison_checks(self) -> int:
        return self.comparison_passed + self.comparison_failed

    @property
    def total_passed(self) -> int:
        return self.oracle_passed + self.comparison_passed

    @property
    def total_failed(self) -> int:
        return self.oracle_failed + self.comparison_failed + self.harness_failed

    @property
    def silent_lanes(self) -> list:
        if self.per_lane_comparisons is None:
            return []
        return [l for l in self.lanes.comparison
                if self.per_lane_comparisons.get(l, 0) == 0]

    @property
    def oracle_lane_label(self) -> str:
        lanes = self.oracle_lanes
        if lanes is None:
            lanes = (self.lanes.reference,) if self.lanes.reference else ()
        if not lanes:
            return "no lane"
        word = "lane" if len(lanes) == 1 else "lanes"
        return f"{word} " + ", ".join(f"`{l}`" for l in lanes)

    @property
    def contradiction(self) -> str | None:
        """A count that cannot be true given the lanes.

        The self-test proves the RENDERING; it cannot see a runner miscounting
        (see the docstring's blind spots). This is the one runner-level lie it
        can catch from here: comparisons cannot happen without a lane to
        compare against. It fires, for instance, if a runner ever classifies
        its own diagonal (a port checked against itself) as cross-language.
        """
        if self.comparison_checks and not self.lanes.comparison:
            return (f"{self.comparison_checks} comparison check(s) counted, but "
                    f"this run has NO comparison lane -- the runner is counting "
                    f"something that cannot be a cross-language comparison")
        return None

    @property
    def verdict(self) -> str:
        if self.contradiction:
            # Measured: without this, a runner that counted its own diagonal as
            # cross-language printed "FAIL: IMPOSSIBLE COUNT" and then a last
            # line reading "VERDICT: CROSS-LANGUAGE -- 14 comparison(s)
            # performed (rust vs )". The last line must never out-claim the
            # failure above it.
            return "IMPOSSIBLE"
        if self.comparison_checks:
            return "CROSS-LANGUAGE"
        if self.oracle_checks:
            return "ORACLE-ONLY"
        return "VACUOUS"

    # -- output ----------------------------------------------------------
    def render(self) -> list:
        ref = self.lanes.reference or "(none)"
        comp = ", ".join(self.lanes.comparison) or "(none)"
        req = ", ".join(self.lanes.requested) or "(none)"

        # The headline keeps the familiar total -- but only ever as the SUM of
        # the two kinds, written out. It cannot be skimmed as either one alone.
        lines = [
            f"{self.title}: {self.total_passed} checks passed, "
            f"{self.total_failed} failed, {self.errors} errors "
            f"= ORACLE {self.oracle_passed} + COMPARISON "
            f"{self.comparison_passed}  ({self.scope})",
            f"  ORACLE     {self.oracle_passed} passed, {self.oracle_failed} "
            f"failed   ({self.oracle_lane_label} {self.oracle_what})",
            f"  COMPARISON {self.comparison_passed} passed, "
            f"{self.comparison_failed} failed   ({self.comparison_what}: "
            + (f"{ref} vs {comp})" if self.lanes.comparison
               else "NONE PERFORMED -- only one lane in this run)"),
            f"  lanes requested: {req} | reference: {ref} | "
            f"comparison lanes: {comp}",
        ]
        if self.harness_failed:
            lines.append(f"  harness preflight: {self.harness_failed} failed "
                         f"(neither an oracle nor a comparison result)")
        if self.per_lane_comparisons is not None and self.lanes.comparison:
            per = ", ".join(
                f"{l}={self.per_lane_comparisons.get(l, 0)}"
                for l in self.lanes.comparison)
            lines.append(f"  comparisons performed per lane: {per}")
        if self.unexercised:
            lines.append("  active ports that did not take part: " + "; ".join(
                f"{p} ({why})" for p, why in self.unexercised))

        if self.contradiction:
            lines.extend(["", RULE,
                          f"!!! FAIL: IMPOSSIBLE COUNT -- {self.contradiction}",
                          RULE])
        if self.comparison_checks == 0:
            lines.extend(self._zero_comparison_banner())
        elif self.silent_lanes:
            lines.extend(self._silent_lane_banner())

        lines.append(f"VERDICT: {self.verdict} -- {self._verdict_tail()}")
        return lines

    def _zero_comparison_banner(self) -> list:
        unchecked = [p for p, _ in self.unexercised] + list(self.silent_lanes)
        for lane in self.lanes.comparison:
            if lane not in unchecked:
                unchecked.append(lane)
        detail = []
        for p, why in self.unexercised:
            detail.append(f"{p} ({why})")
        for lane in self.silent_lanes:
            detail.append(f"{lane} ({SILENT_LANE_HEADLINE})")
        out = [
            "",
            RULE,
            f"!!! WARNING: {WARN_HEADLINE}",
            "!!! Nothing in this run shows that two independent "
            "implementations agree.",
        ]
        if self.oracle_checks:
            out.append(
                f"!!! What DID run: {self.oracle_checks} ORACLE check(s) -- "
                f"{self.oracle_lane_label} {self.oracle_what}.")
            out.append("!!! That is a real result, and a DIFFERENT one. Do not "
                       "report it as parity.")
        else:
            out.append("!!! And no oracle check ran either: this run "
                       "established NOTHING.")
        out.append("!!! Unchecked: " + ("; ".join(detail) if detail
                                        else ", ".join(unchecked) or "(none)"))
        out.append("!!! For the cross-language gate, run two lanes on a machine "
                   "that has both")
        out.append("!!! toolchains, e.g. --lang rust,swift; pass "
                   "--require-comparisons to make")
        out.append("!!! a zero-comparison run exit non-zero.")
        out.append(RULE)
        return out

    def _silent_lane_banner(self) -> list:
        return [
            "",
            RULE,
            f"!!! WARNING: lane(s) {SILENT_LANE_HEADLINE}: "
            f"{', '.join(self.silent_lanes)}",
            "!!! Their agreement with the reference is UNCHECKED; every "
            "comparison counted in",
            "!!! this report came from the other lane(s).",
            RULE,
        ]

    def _verdict_tail(self) -> str:
        if self.verdict == "IMPOSSIBLE":
            return (f"{self.contradiction}. No claim can be read off this run "
                    f"until the runner's bookkeeping is fixed.")
        if self.verdict == "CROSS-LANGUAGE":
            tail = (f"{self.comparison_checks} cross-language comparison(s) "
                    f"performed ({self.lanes.reference} vs "
                    f"{', '.join(self.lanes.comparison)}), "
                    f"{self.comparison_passed} passed; plus "
                    f"{self.oracle_checks} oracle check(s).")
            if self.silent_lanes:
                tail += (f" BUT lane(s) {', '.join(self.silent_lanes)} "
                         f"performed none.")
            return tail
        if self.verdict == "ORACLE-ONLY":
            return (f"0 cross-language comparisons performed; "
                    f"{self.oracle_checks} oracle check(s), "
                    f"{self.oracle_passed} passed. This run did NOT check that "
                    f"any two implementations agree.")
        return ("0 cross-language comparisons AND 0 oracle checks: this run "
                "established nothing.")

    def print_report(self) -> None:
        print("")
        for line in self.render():
            print(line)

    def exit_code(self) -> int:
        if self.total_failed or self.errors or self.contradiction:
            return EXIT_FAILED
        if self.verdict == "VACUOUS":
            # A run that checked nothing must never exit 0, flag or no flag.
            return EXIT_NO_COMPARISONS
        if self.require_comparisons and (self.comparison_checks == 0
                                         or self.silent_lanes):
            return EXIT_NO_COMPARISONS
        return EXIT_OK


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

ORACLE_LINE = re.compile(r"^\s*ORACLE\s+(\d+) passed, (\d+) failed")
COMPARISON_LINE = re.compile(r"^\s*COMPARISON\s+(\d+) passed, (\d+) failed")
TOTAL_LINE = re.compile(r"(\d+) checks passed")


def _read_like_a_skimmer(lines):
    """Parse a rendered report the way a hurried human reads it.

    Deliberately NOT a peek at the object's fields: the whole defect was a
    report whose TEXT said less than its state knew. Everything asserted below
    is read back out of the printed lines.
    """
    text = "\n".join(lines)
    oracle = comparison = None
    total = None
    for line in lines:
        m = ORACLE_LINE.match(line)
        if m:
            oracle = (int(m.group(1)), int(m.group(2)))
        m = COMPARISON_LINE.match(line)
        if m:
            comparison = (int(m.group(1)), int(m.group(2)))
        m = TOTAL_LINE.search(line)
        if m and total is None:
            total = int(m.group(1))
    return {
        "oracle": oracle,
        "comparison": comparison,
        "total": total,
        # Literal phrases, never module constants -- see WARN_HEADLINE.
        "banner": "ZERO CROSS-LANGUAGE COMPARISONS WERE PERFORMED" in text,
        "silent_warning": "requested but performed ZERO comparisons" in text,
        "last": lines[-1] if lines else "",
        "text": text,
    }


def self_test() -> int:
    """Prove each property FAILS when broken. A gate is trusted for its red."""
    bad: list = []

    def check(cond, msg):
        if not cond:
            bad.append(msg)

    # --- lane arithmetic (the mis-count mutations) -----------------------
    one = Lanes.resolve(["rust"])
    check(one.reference == "rust", f"(a) reference of ['rust'] = {one.reference!r}")
    check(one.comparison == (),
          f"(a) ['rust'] must yield ZERO comparison lanes, got {one.comparison!r} "
          f"-- the reference must never compare against itself")
    two = Lanes.resolve(["rust", "swift"])
    check(two.comparison == ("swift",), f"(b) ['rust','swift'] -> {two.comparison!r}")
    dup = Lanes.resolve(["rust", "swift", "swift"])
    check(dup.comparison == ("swift",),
          f"(c) duplicate lane must count ONCE, got {dup.comparison!r}")
    selfdup = Lanes.resolve(["rust", "rust"])
    check(selfdup.comparison == (),
          f"(d) ['rust','rust'] is an oracle run in disguise, got {selfdup.comparison!r}")
    check(Lanes.resolve([]).reference is None, "(e) empty --lang must yield no reference")
    check(Lanes.resolve(["rust", " swift "]).comparison == ("swift",),
          "(f) lane names must be stripped")

    # --- toolchain honesty ----------------------------------------------
    absent = unexercised_active_ports(one, which=lambda tool: None)
    check([p for p, _ in absent] == ["swift"],
          f"(g) with only rust requested, swift must be named unexercised: {absent}")
    check(absent and "not found" in absent[0][1],
          f"(g) an absent toolchain must say so: {absent}")
    present = unexercised_active_ports(one, which=lambda tool: "/usr/bin/" + tool)
    check(present and "not requested" in present[0][1],
          f"(h) a present-but-unrequested lane must say so, not 'not found': {present}")
    check(unexercised_active_ports(two, which=lambda tool: None) == [],
          "(i) both active ports requested -> nothing unexercised")

    # --- transitive pair counting ---------------------------------------
    check(pairs_via_golden(1) == 0, "(j) one lane matching a golden proves no pair")
    check(pairs_via_golden(2) == 1, "(j) two lanes matching a golden prove one pair")
    check(pairs_via_golden(3) == 3, "(j) three lanes -> three pairs")
    check(pairs_via_golden(0) == 0, "(j) no lanes -> no pairs")

    # --- CASE A: the cloud referee's run (single lane, oracle only) ------
    # Numbers are the REAL measured ones for `--lang rust` at this commit.
    a = LaneReport(title="Cross-language algorithms", scope="24 algorithms",
                   lanes=one, oracle_passed=459,
                   unexercised=[("swift", "toolchain not found on this machine")])
    ra = _read_like_a_skimmer(a.render())
    check(ra["oracle"] == (459, 0),
          f"(A) oracle count unreadable/wrong in the text: {ra['oracle']}")
    check(ra["comparison"] == (0, 0),
          f"(A) comparison count unreadable/wrong in the text: {ra['comparison']} "
          f"-- a folded total is exactly the defect this gate exists for")
    check(ra["banner"], "(A) zero comparisons must raise the loud banner")
    check("swift" in ra["text"],
          "(A) the unchecked lane must be NAMED, not merely implied")
    check(ra["last"].startswith("VERDICT:"),
          f"(A) the last line must be the verdict, got {ra['last']!r}")
    check("ORACLE-ONLY" in ra["last"],
          f"(A) the last line must say ORACLE-ONLY, got {ra['last']!r}")
    check("0 cross-language comparison" in ra["last"],
          f"(A) the last line must state ZERO comparisons, got {ra['last']!r}")
    check(a.exit_code() == EXIT_OK,
          f"(A) a clean single-lane oracle run stays usable: exit {a.exit_code()}")
    a_strict = LaneReport(**{**a.__dict__, "require_comparisons": True})
    check(a_strict.exit_code() == EXIT_NO_COMPARISONS,
          f"(A) --require-comparisons must reject 0 comparisons: "
          f"exit {a_strict.exit_code()}")

    # --- CASE B: the real blocking run (two lanes, green) ----------------
    b = LaneReport(title="Cross-language algorithms", scope="24 algorithms",
                   lanes=two, oracle_passed=459, comparison_passed=390,
                   per_lane_comparisons={"swift": 390})
    rb = _read_like_a_skimmer(b.render())
    check(rb["oracle"] == (459, 0), f"(B) oracle: {rb['oracle']}")
    check(rb["comparison"] == (390, 0), f"(B) comparison: {rb['comparison']}")
    check(rb["total"] == 849, f"(B) total: {rb['total']}")
    check(rb["oracle"] and rb["comparison"] and
          rb["total"] == rb["oracle"][0] + rb["comparison"][0],
          "(B) the printed total must equal ORACLE + COMPARISON as printed")
    check(not rb["banner"],
          "(B) a genuine two-lane run must NOT print the banner -- a warning "
          "that always fires teaches readers to ignore it")
    check(not rb["silent_warning"], "(B) no lane was silent here")
    check("CROSS-LANGUAGE" in rb["last"] and "390" in rb["last"],
          f"(B) verdict must claim the comparisons it made: {rb['last']!r}")
    check(b.exit_code() == EXIT_OK, f"(B) exit {b.exit_code()}")
    check(LaneReport(**{**b.__dict__, "require_comparisons": True}).exit_code()
          == EXIT_OK, "(B) strict mode must pass a real two-lane run")
    # The ORACLE line must name the lanes its checks actually cover: the
    # commutativity runner's diagonal cells cover BOTH ports, and a line that
    # said `rust` alone would understate the run's own evidence.
    b_all = LaneReport(**{**b.__dict__, "oracle_lanes": ("rust", "swift")})
    check("lanes `rust`, `swift`" in _read_like_a_skimmer(b_all.render())["text"],
          "(B) oracle_lanes must widen the ORACLE line's lane label")
    check("lane `rust`" in rb["text"] and "swift`" not in
          rb["text"].split("ORACLE")[1].split("\n")[0],
          "(B) by default the ORACLE line names the reference lane only")

    # --- CASE C: lane requested, produced nothing (toolchain broke) ------
    c = LaneReport(title="Cross-language algorithms", scope="24 algorithms",
                   lanes=two, oracle_passed=459, errors=24,
                   per_lane_comparisons={"swift": 0})
    rc = _read_like_a_skimmer(c.render())
    check(rc["banner"], "(C) requested-but-errored lane still means 0 comparisons")
    check("swift" in rc["text"], "(C) the silent lane must be named")
    check(c.exit_code() == EXIT_FAILED,
          f"(C) errors must still exit 1, got {c.exit_code()}")

    # --- CASE D: three lanes, one silent (the banner must not hide it) ---
    three = Lanes.resolve(["rust", "swift", "ocaml"])
    d = LaneReport(title="Cross-language algorithms", scope="24 algorithms",
                   lanes=three, oracle_passed=459, comparison_passed=390,
                   per_lane_comparisons={"swift": 0, "ocaml": 390})
    rd = _read_like_a_skimmer(d.render())
    check(not rd["banner"], "(D) comparisons did happen, so no zero-banner")
    check(rd["silent_warning"],
          "(D) a lane that performed ZERO comparisons must be warned about even "
          "when other lanes compared -- otherwise one dead lane hides inside a "
          "healthy total")
    check("swift" in rd["text"], "(D) name the silent lane")
    check(d.exit_code() == EXIT_OK, f"(D) default exit stays 0: {d.exit_code()}")
    check(LaneReport(**{**d.__dict__, "require_comparisons": True}).exit_code()
          == EXIT_NO_COMPARISONS,
          "(D) strict mode must reject a requested lane that compared nothing")

    # --- CASE E: vacuous -- nothing was checked at all -------------------
    e = LaneReport(title="Cross-language algorithms", scope="1 algorithm",
                   lanes=one)
    re_ = _read_like_a_skimmer(e.render())
    check(re_["oracle"] == (0, 0) and re_["comparison"] == (0, 0),
          f"(E) both counts must print as zero: {re_['oracle']} {re_['comparison']}")
    check("VACUOUS" in re_["last"],
          f"(E) a run that checked nothing must say so: {re_['last']!r}")
    check(e.exit_code() == EXIT_NO_COMPARISONS,
          f"(E) a vacuous run must NOT exit 0, got {e.exit_code()}")

    # --- CASE F: failures are attributed, never pooled -------------------
    f_ = LaneReport(title="Cross-language algorithms", scope="24 algorithms",
                    lanes=two, oracle_passed=458, oracle_failed=1,
                    comparison_passed=388, comparison_failed=2,
                    harness_failed=1, per_lane_comparisons={"swift": 390})
    rf = _read_like_a_skimmer(f_.render())
    check(rf["oracle"] == (458, 1), f"(F) oracle failure not attributed: {rf['oracle']}")
    check(rf["comparison"] == (388, 2),
          f"(F) comparison failure not attributed: {rf['comparison']}")
    check("harness" in rf["text"],
          "(F) a preflight fault is neither an oracle nor a comparison result "
          "and must be reported as its own kind")
    check(f_.exit_code() == EXIT_FAILED, f"(F) exit {f_.exit_code()}")

    # --- CASE G: an impossible count (a runner classifying its own
    # diagonal as cross-language) must be caught, not printed as evidence ---
    g = LaneReport(title="Cross-language commutativity", scope="14 fixtures",
                   lanes=one, oracle_passed=0, comparison_passed=14)
    rg = _read_like_a_skimmer(g.render())
    check("IMPOSSIBLE COUNT" in rg["text"],
          "(G) comparisons without a comparison lane must be called impossible")
    check(g.exit_code() == EXIT_FAILED,
          f"(G) an impossible count must exit 1, got {g.exit_code()}")
    check("CROSS-LANGUAGE" not in rg["last"],
          f"(G) the last line must not out-claim the failure above it: "
          f"{rg['last']!r}")
    check("IMPOSSIBLE" in rg["last"], f"(G) verdict: {rg['last']!r}")
    check(LaneReport(title="t", scope="s", lanes=two,
                     comparison_passed=14).contradiction is None,
          "(G) a real comparison lane must not trip the invariant")

    if bad:
        print("lane-report SELF-TEST: FAILED")
        for msg in bad:
            print(f"  {msg}")
        return 1
    print("lane-report SELF-TEST: OK (7 report cases, 13 lane-arithmetic cases; "
          "oracle/comparison split, zero-comparison banner, silent-lane warning, "
          "impossible-count invariant, verdict line and all four exit paths "
          "proven)")
    return 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()
    print(__doc__)
    print("This module is imported by the cross_language_* runners; "
          "run it with --self-test.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
