using SbWinUi;

// ===========================================================================
// THE TITLE ORACLE'S RULE, DRIVEN
// ===========================================================================
//
// ⛔ WHAT THIS FILE IS ABOUT. On kenai 2026-09-04 the session-1 title oracle
// read FAIL on THREE RUNS THAT SUCCEEDED -- `retained`, `stall` and the o6
// squeeze. `Report` wrote the LAST row into the window title, and each of those
// scenes ended on a row that carried no verdict, so the title the oracle read
// said nothing and the rule `| RUSTOK` correctly refused it.
//
// PR #118 repaired that by putting `RUSTOK `/`RUSTFAIL ` in front of the three
// completion rows BY NAME. That is the same repair shape as #115's, one row on,
// and #117 already recorded what it costs: a later wave adds a row, the row is
// last, and the oracle goes dark again. `Report` still has 20-odd callers with
// no verdict on them (`SCALE CHANGED`, `DUMP`, `FIRST-PRESENT`, `RESIZE STEP`,
// `UI-STALL DONE`, `NOT RUN: no gesture`, `POINTER CAPTURE-LOST`, ...), and any
// of them landing last blanks the verdict again.
//
// ⇒ THE DEFECT IS NOT WHICH ROWS CARRY A VERDICT. IT IS THAT THE TITLE CARRIES
//   THE LAST ROW'S VERDICT AT ALL. The title's verdict is a property of the RUN.
//   `TitleVerdict.Fold` makes it one: a verdict-bearing row SETS it, and a
//   verdict-less row leaves it exactly as it was while still updating the text.
//
// ⛔ AND THE FOLD IS DELIBERATELY NOT STICKY-ON-FAIL. O5's refusals are CORRECT
// behaviour reported as `RUSTFAIL` (`SB_TOOL` refused, `SB_SIZE` pinned): a
// sticky fail would turn every O5 run red by design. Masking is answered by
// COUNTING instead -- the composed title carries `fails=N` whenever any fail row
// has been seen, so an OK that follows a failure cannot hide it.

static class Program
{
    static int _passed;
    static int _failed;

    // The oracle's required substring, BYTE-IDENTICAL to `sitting.ps1:96`
    // (`$title = 'JAS S-B MATERIALIZER CHECKPOINT 3 | RUSTOK'`). Written out
    // rather than composed from `TitleVerdict`'s own pieces: a constant built
    // from the subject cannot disagree with the subject, which is the whole
    // thing this constant exists to check.
    const string OracleRequires = "JAS S-B MATERIALIZER CHECKPOINT 3 | RUSTOK";
    const string VerifyTitle = "JAS S-B MATERIALIZER CHECKPOINT 3";

    static void Check(string name, bool ok, string detail)
    {
        if (ok) { _passed++; Console.WriteLine($"  pass  {name}"); }
        else { _failed++; Console.WriteLine($"  FAIL  {name}  --  {detail}"); }
    }

    static void Eq(string name, string expected, string actual) =>
        Check(name, expected == actual, $"expected '{expected}', got '{actual}'");

    // Fold a whole run's rows, which is what `Report` does one call at a time.
    static TitleVerdict Run(params string[] rows)
    {
        var v = TitleVerdict.Empty;
        foreach (var r in rows) { v = TitleVerdict.Fold(v, r); }
        return v;
    }

    static int Main()
    {
        // -- the three kenai rows, by name --------------------------------
        //
        // These are the runs that FAILED while succeeding. Each is the real
        // shape: a verdict-bearing row, then the scene's own last row with no
        // verdict on it. Under the old rule the title ended verdict-less.

        Eq("retained: a verdict-less A' row does not blank the RUSTOK before it",
            "RUSTOK",
            Run("RUSTOK REPAINT events_total=3 frames=1 surface=2858x1429",
                "A' scene=retained surface=2858x1429 ui-tid=1 render-tid=2").Verdict);

        Eq("stall: UI-STALL DONE does not blank the verdict before it",
            "RUSTOK",
            Run("RUSTOK STALL render-stall=20000ms stall-tid=2",
                "UI-STALL DONE ui-stall=20000ms stall-tid=1").Verdict);

        Eq("o6: the squeeze's request row does not blank the verdict before it",
            "RUSTOK",
            Run("RUSTOK SQUEEZE delivered NONE (requested height 35)",
                "SQUEEZE requesting window height 35 (status row) from 953").Verdict);

        // -- the class, not the three instances ---------------------------
        //
        // Every verdict-less caller `Report` has. If the rule is right these
        // cannot matter, and that is the assertion: the NEXT wave's new row is
        // covered before it is written.

        foreach (var row in new[] {
            "SCALE CHANGED composition-scale=1.5x1.5 dpi-for-window=144",
            "DUMP sb-doc-after.json bytes=8123 ui-tid=1",
            "FIRST-PRESENT surface=2858x1429 present-tid=2",
            "RESIZE STEP 2/3 '1000x600' -> window 1000x600",
            "RESIZE DEFERRED 1000x600 — no surface yet policy=DEFER",
            "RESIZE REFUSED 0x600 — surface stays 2858x1429",
            "STALL ARMED render-stall=20000ms ui-stall=0ms",
            "SYNTH-DRAG scene=pointer spec='7' k=7 press@=(37.0,23.0)",
            "POINTER CAPTURE-LOST reason=Canceled id=1 device=Mouse",
            "NOT RUN: no gesture (no -Hand) scene=retained mutation=NONE",
            "STARTUP dpi-awareness=PER_MONITOR_AWARE dpi-for-window=144",
        })
        {
            Eq($"verdict-less row carries the verdict: '{row.Split(' ')[0]}'",
                "RUSTOK", Run("RUSTOK BENCHMARK frames=60", row).Verdict);
        }

        // -- the other half of the rule: no false OK ----------------------

        Eq("a run with no verdict-bearing row at all is PENDING, never OK",
            "RUSTPENDING",
            Run("STARTUP dpi-for-window=144", "FIRST-PRESENT surface=2858x1429").Verdict);

        Eq("the empty fold is PENDING",
            "RUSTPENDING", TitleVerdict.Empty.Verdict);

        Eq("a fail row sets the verdict to RUSTFAIL",
            "RUSTFAIL",
            Run("RUSTOK BENCHMARK frames=60", "RUSTFAIL SetSwapChain threw").Verdict);

        Eq("RECEIPT-LOST is a failure of the measurement, so it reads RUSTFAIL",
            "RUSTFAIL",
            Run("RUSTOK BENCHMARK frames=60",
                "RECEIPT-LOST IOException | RUSTOK GOLDENS 21/21").Verdict);

        Eq("SBFAIL is a fail spelling too (MainWindow's bad SB_SIZE refusal)",
            "RUSTFAIL", Run("SBFAIL bad SB_SIZE '4k' (want WxH)").Verdict);

        // A near-miss must not be read as a verdict. The prefix is a WORD.
        Eq("'RUSTOKAY' is not RUSTOK -- the prefix ends at a space",
            "RUSTPENDING", Run("RUSTOKAY whatever=1").Verdict);
        Eq("'RUSTFAILURE' is not RUSTFAIL",
            "RUSTPENDING", Run("RUSTFAILURE whatever=1").Verdict);
        Eq("a bare 'RUSTOK' with nothing after it still counts",
            "RUSTOK", Run("RUSTOK").Verdict);

        // -- O5: a refusal must not poison the rest of the run ------------

        Eq("O5: a refusal followed by a real OK reads RUSTOK (NOT sticky)",
            "RUSTOK",
            Run("RUSTFAIL SB_TOOL='3' is refused: only tool 0 (selection) is bound",
                "RUSTOK STAY pid=4812").Verdict);

        Check("O5: ...and the refusal is still COUNTED, so it cannot hide",
            Run("RUSTFAIL SB_TOOL='3' is refused", "RUSTOK STAY pid=4812").Fails == 1,
            "fails should be 1");

        Check("the ok rows are counted too",
            Run("RUSTOK A", "RUSTOK B", "RUSTFAIL C").Oks == 2, "oks should be 2");

        // -- the text half: the last row is still the last row -------------

        Eq("the last row's TEXT is always the last row, verdict or not",
            "UI-STALL DONE ui-stall=20000ms",
            Run("RUSTOK STALL render-stall=20000ms", "UI-STALL DONE ui-stall=20000ms").LastRow);

        // -- composition, against the LIVE oracle string -------------------

        var okTitle = TitleVerdict.Compose(VerifyTitle,
            Run("RUSTOK REPAINT frames=1", "A' scene=retained surface=2858x1429"));
        Check("the composed title matches the oracle's required substring",
            okTitle.Contains(OracleRequires),
            $"'{okTitle}' does not contain '{OracleRequires}'");
        Check("...and it still carries the last row's text for a human",
            okTitle.Contains("A' scene=retained"), okTitle);

        var maskedTitle = TitleVerdict.Compose(VerifyTitle,
            Run("RUSTFAIL SB_TOOL='3' is refused", "RUSTOK STAY pid=4812"));
        Check("a run with an earlier failure still matches (O5 must not go red)",
            maskedTitle.Contains(OracleRequires), maskedTitle);
        Check("...and the title SAYS there was a failure -- masking made visible",
            maskedTitle.Contains("fails=1"), maskedTitle);

        // ⭐ THE POSITIVE CONTROL FOR THE ORACLE ITSELF. If this passes while
        // the rule is dead, every assertion above is measuring nothing.
        var failTitle = TitleVerdict.Compose(VerifyTitle,
            Run("RUSTOK BENCHMARK frames=60", "RUSTFAIL render thread died"));
        Check("CONTROL: a failed run's title does NOT match the oracle",
            !failTitle.Contains(OracleRequires), failTitle);

        var pendingTitle = TitleVerdict.Compose(VerifyTitle, TitleVerdict.Empty);
        Check("CONTROL: a run that reported nothing does NOT match the oracle",
            !pendingTitle.Contains(OracleRequires), pendingTitle);
        Check("...and the pending title has no dangling separator",
            !pendingTitle.EndsWith("| "), $"'{pendingTitle}'");

        Console.WriteLine();
        Console.WriteLine($"--- {_passed} passed, {_failed} failed, of {_passed + _failed} case(s) ---");
        return _failed == 0 ? 0 : 1;
    }
}
