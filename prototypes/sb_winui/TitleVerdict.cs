namespace SbWinUi;

/// <summary>
/// THE WINDOW TITLE'S VERDICT, AS A PROPERTY OF THE RUN RATHER THAN OF THE LAST
/// ROW.
///
/// ⛔ WHY THIS TYPE EXISTS. The session-1 oracle reads the window title and
/// requires <c>| RUSTOK</c> in it (`sitting.ps1:96`, `verify_window.ps1`'s
/// `-Title`), because a bare title passes a window that says RUSTFAIL. `Report`
/// wrote the LAST ROW into the title, so a scene ending on a row that carried no
/// verdict left the title saying nothing: on kenai 2026-09-04 that FAILED THREE
/// RUNS THAT SUCCEEDED — `retained` (last row `A'`), `stall` (`UI-STALL DONE`)
/// and the o6 squeeze (`SQUEEZE requesting …`).
///
/// ⛔ AND THE REPAIR THAT PR #118 MADE IS NOT THE ONE THIS TYPE MAKES. #118 put
/// the prefix on those three rows BY NAME. That is the same shape as #115's
/// repair one row earlier, and #117 §F-A recorded what the shape costs: the next
/// wave adds a row, the row lands last, and the oracle goes dark again. `Report`
/// has twenty-odd verdict-less callers — `SCALE CHANGED`, `DUMP`,
/// `FIRST-PRESENT`, `RESIZE STEP/DEFERRED/REFUSED`, `STALL ARMED`, `SYNTH-DRAG`,
/// `POINTER CAPTURE-LOST`, `NOT RUN: no gesture`, `STARTUP` — every one of them
/// a live way for the title to go blank between the verdict and the capture.
///
/// ⇒ A VERDICT-LESS ROW NOW CARRIES THE VERDICT FORWARD UNCHANGED and updates
///   only the text. Which rows carry a prefix stops being load-bearing.
///
/// ⛔ IT IS DELIBERATELY NOT STICKY ON FAILURE, and that is a ruling, not an
/// oversight. `RUSTFAIL` is overloaded in this shell: O5's refusals are CORRECT
/// behaviour reported with it (`SB_TOOL='3' is refused`, `SB_SIZE pins the
/// surface`). A sticky fail would turn every O5 run red by construction. So the
/// verdict is the LAST verdict-bearing row's, and masking is answered by
/// COUNTING: <see cref="Compose"/> writes <c>fails=N</c> into the title whenever
/// any fail row has been seen, so an OK that follows a failure cannot hide it
/// from a reader while still matching the oracle.
///
/// 📌 THE ROW-LEVEL VERDICTS ARE STILL THE LOG'S. `sb-runs.log` keeps every row
/// with its own prefix and `verify_assertions.ps1` reads them there. This type
/// answers only the narrower question the title exists for: did this run, in
/// session 1, reach a verdict-bearing outcome at all.
///
/// Pure: no WinUI, no device, no window, no clock. That is what lets
/// <c>../sb_winui_tests/</c> drive it on a runner with no desktop — the same
/// argument that built `harness_selftest.ps1` for the shell's row readers.
/// </summary>
public readonly struct TitleVerdict
{
    /// <summary>`RUSTPENDING` until a verdict-bearing row arrives, then that row's.</summary>
    public string Verdict { get; init; }

    /// <summary>The last row `Report` was given, verdict-bearing or not.</summary>
    public string LastRow { get; init; }

    /// <summary>How many rows read as OK. Counted so the title can say so.</summary>
    public int Oks { get; init; }

    /// <summary>
    /// How many rows read as a failure — INCLUDING the deliberate refusals,
    /// because this type cannot tell them apart and must not pretend to. The
    /// count is reported, never used to decide the verdict.
    /// </summary>
    public int Fails { get; init; }

    /// <summary>
    /// The verdict of a window that has reported nothing. It is NOT `RUSTOK`:
    /// the oracle must refuse a capture taken before the app drew anything, and
    /// this is the value that makes it refuse.
    /// </summary>
    public const string Pending = "RUSTPENDING";

    public const string Ok = "RUSTOK";
    public const string Fail = "RUSTFAIL";

    /// <summary>
    /// The document has unsaved changes.
    ///
    /// ⛔ IT LIVES IN THIS TYPE RATHER THAN BESIDE `Title`, AND THAT IS NOT
    /// TIDINESS. `Report` recomposes the ENTIRE title from this struct, under a
    /// lock, on every row — and it is called constantly. A mark written straight
    /// to `Title` would be erased by the next row: it would appear, flicker and
    /// vanish, which reads as "implemented" to anyone not watching for seconds.
    /// Carried by <see cref="Fold"/> exactly as the verdict is, because an
    /// ordinary report is not a save.
    /// </summary>
    public bool Dirty { get; init; }

    /// <summary>
    /// The mark itself, as a named constant so the test can assert on the thing
    /// rather than on a copy of it. A bullet, not an asterisk: `*` is a glob in
    /// every shell that reads these titles.
    /// </summary>
    public const string DirtyMark = " \u25cf";

    public static TitleVerdict Empty => new()
    {
        Verdict = Pending,
        LastRow = "",
        Oks = 0,
        Fails = 0,
        Dirty = false,
    };

    /// <summary>Set or clear the dirty mark, leaving the run's verdict alone.</summary>
    public static TitleVerdict WithDirty(TitleVerdict prev, bool dirty) =>
        new()
        {
            Verdict = prev.Verdict,
            LastRow = prev.LastRow,
            Oks = prev.Oks,
            Fails = prev.Fails,
            Dirty = dirty,
        };

    /// <summary>
    /// Read one row's verdict, or <c>null</c> when it carries none.
    ///
    /// ⛔ THE PREFIX IS A WORD, NOT A SUBSTRING. `RUSTOKAY` is not `RUSTOK`.
    /// This seat lost a whole sitting to a short field name matching inside a
    /// longer one (`scale` inside `composition-scale=`), so the match is
    /// anchored at both ends: the row is the token, or the token and a space.
    /// </summary>
    public static string? RowVerdict(string? row)
    {
        if (string.IsNullOrEmpty(row)) { return null; }
        if (Word(row, Ok)) { return Ok; }
        if (Word(row, Fail)) { return Fail; }

        // The two other fail spellings this shell actually writes. `SBFAIL` is
        // `MainWindow`'s malformed-`SB_SIZE` refusal; `RECEIPT-LOST` is
        // `Report`'s own catch, and a lost receipt is a failure OF THE
        // MEASUREMENT — the title is the only channel left to say so.
        if (Word(row, "SBFAIL")) { return Fail; }
        if (Word(row, "RECEIPT-LOST")) { return Fail; }

        return null;
    }

    private static bool Word(string row, string token) =>
        row.Length == token.Length
            ? row == token
            : row.StartsWith(token, StringComparison.Ordinal)
              && row.Length > token.Length
              && row[token.Length] == ' ';

    /// <summary>
    /// Fold one row into the run's verdict. A verdict-bearing row SETS the
    /// verdict and bumps its counter; every other row updates only the text.
    /// </summary>
    public static TitleVerdict Fold(TitleVerdict prev, string row)
    {
        var v = RowVerdict(row);
        return new TitleVerdict
        {
            Verdict = v ?? prev.Verdict,
            LastRow = row ?? "",
            Oks = prev.Oks + (v == Ok ? 1 : 0),
            Fails = prev.Fails + (v == Fail ? 1 : 0),
            // CARRIED, NOT RECOMPUTED. A row says nothing about whether the
            // document is saved, and only a save clears the mark.
            Dirty = prev.Dirty,
        };
    }

    /// <summary>
    /// The title the oracle reads: the app's own name, then the RUN's verdict
    /// (with the fail tally when there is one), then the last row for a human at
    /// the window. The verdict sits immediately after the name because the
    /// oracle's required substring is `"<name> | RUSTOK"` and nothing may come
    /// between them.
    /// </summary>
    /// <remarks>
    /// ⛔ THE DIRTY MARK GOES AT THE END, AND THE PLACEMENT IS THE WHOLE POINT.
    /// The oracle's required substring is `"&lt;name&gt; | RUSTOK"` and nothing may
    /// come between them (see the summary above). A mark placed after the name
    /// would blank the session-1 oracle in exactly the way the 2026-09-04 kenai
    /// regression did — three runs that succeeded, read as failures. Appending
    /// leaves every existing match intact, which the test asserts rather than
    /// assumes.
    /// </remarks>
    public static string Compose(string verifyTitle, TitleVerdict v)
    {
        var verdict = v.Fails > 0 ? $"{v.Verdict} fails={v.Fails}" : v.Verdict;
        var mark = v.Dirty ? DirtyMark : "";
        return string.IsNullOrEmpty(v.LastRow)
            ? $"{verifyTitle} | {verdict}{mark}"
            : $"{verifyTitle} | {verdict} | {v.LastRow}{mark}";
    }
}
