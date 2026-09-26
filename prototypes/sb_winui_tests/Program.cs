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

    /// <summary>A nullable reading as a printable token, so "(null)" is a CASE
    /// and not an empty string that an absent value would also produce.</summary>
    static string Show(string? v) => v ?? "(null)";

    static string ShowPreview((string Viewbox, string Svg)? p) =>
        p is { } v ? v.Viewbox + "|" + v.Svg : "(null)";

    static string ShowRgb((byte R, byte G, byte B)? c) => c is { } v ? $"{v.R},{v.G},{v.B}" : "(null)";

    static void Eq(string name, string expected, string actual) =>
        Check(name, expected == actual, $"expected '{expected}', got '{actual}'");

    // W2b-2's readers. Each returns a value that FAILS the case it feeds on
    // bytes that do not parse, rather than throwing: a throw would end the run
    // and hide every case after it.
    static System.Text.Json.JsonDocument? Parse(byte[] bytes)
    {
        try { return System.Text.Json.JsonDocument.Parse(bytes); }
        catch (System.Text.Json.JsonException) { return null; }
    }

    static string? Str(System.Text.Json.JsonDocument doc, string key) =>
        doc.RootElement.ValueKind == System.Text.Json.JsonValueKind.Object
        && doc.RootElement.TryGetProperty(key, out var v)
        && v.ValueKind == System.Text.Json.JsonValueKind.String
            ? v.GetString()
            : null;

    static bool? Bool(System.Text.Json.JsonDocument doc, string key) =>
        doc.RootElement.ValueKind == System.Text.Json.JsonValueKind.Object
        && doc.RootElement.TryGetProperty(key, out var v)
        && (v.ValueKind == System.Text.Json.JsonValueKind.True
            || v.ValueKind == System.Text.Json.JsonValueKind.False)
            ? v.GetBoolean()
            : null;

    static string Show(System.Text.Json.JsonDocument? doc) =>
        doc is null ? "(unparseable)" : doc.RootElement.GetRawText();

    static string Decode(string token)
    {
        try { return System.Text.Json.JsonSerializer.Deserialize<string>(token) ?? "(null)"; }
        catch (System.Text.Json.JsonException) { return $"(not a JSON string: {token})"; }
    }

    // W2b-3: a split knob as one comparable string; a refusal is `(null)`.
    static string ShowSplit((string Widget, string Text)? split) =>
        split is { } s ? $"{s.Widget}|{s.Text}" : "(null)";

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

        // ===================================================================
        // W4 — THE DOCUMENT'S DIRTY MARK, AND WHY IT IS IN THIS TYPE AT ALL
        // ===================================================================
        //
        // ⛔ THE DESIGN BLOCK SAYS "the title loses its dirty mark" ON SAVE, AND
        // THE OBVIOUS IMPLEMENTATION IS A SILENT NO-OP. `Report` recomposes the
        // whole title from `TitleVerdict` under a lock on EVERY row, and it is
        // called constantly. A mark written straight to `Title` would be erased
        // by the next row — appearing, flickering, and vanishing, which reads as
        // "implemented" to anyone who does not watch for seconds.
        //
        // ⛔ AND THE ORACLE IS THE HARDER CONSTRAINT. `Compose`'s own doc: "the
        // verdict sits immediately after the name because the oracle's required
        // substring is `<name> | RUSTOK` and NOTHING MAY COME BETWEEN THEM." A
        // dirty mark placed there would blank the title oracle exactly as the
        // 2026-09-04 kenai regression did — three runs that succeeded, read as
        // failures. So the mark goes at the END, and these arms are what say so.

        var dirty = TitleVerdict.WithDirty(
            Run("RUSTOK APP menu-items=55"), true);

        Check("W4: a dirty title STILL matches the session-1 oracle",
            TitleVerdict.Compose(VerifyTitle, dirty).Contains(OracleRequires),
            TitleVerdict.Compose(VerifyTitle, dirty));

        Check("W4: ...and the mark is actually there (or the arm above is vacuous)",
            TitleVerdict.Compose(VerifyTitle, dirty).EndsWith(TitleVerdict.DirtyMark),
            TitleVerdict.Compose(VerifyTitle, dirty));

        Check("W4: a clean document carries NO mark",
            !TitleVerdict.Compose(VerifyTitle, Run("RUSTOK APP menu-items=55"))
                .Contains(TitleVerdict.DirtyMark),
            TitleVerdict.Compose(VerifyTitle, Run("RUSTOK APP menu-items=55")));

        // ⭐ THE ARM THAT MATTERS MOST, because it is the one the obvious
        // implementation fails: the mark must SURVIVE the rows that keep
        // arriving after the edit. `Fold` carries it exactly as it carries the
        // verdict — a report is not a save.
        var stillDirty = TitleVerdict.Fold(
            TitleVerdict.Fold(dirty, "DUMP sb-doc-after.json bytes=812"),
            "RUSTOK REPAINT frames=1");
        Check("W4: an ordinary row does not clear the dirty mark",
            stillDirty.Dirty, TitleVerdict.Compose(VerifyTitle, stillDirty));

        Check("W4: ...and saving DOES clear it",
            !TitleVerdict.WithDirty(stillDirty, false).Dirty, "still dirty after a save");

        // A pending run can be dirty too (an edit before any verdict-bearing
        // row), and that must not manufacture a dangling separator.
        var pendingDirty = TitleVerdict.Compose(
            VerifyTitle, TitleVerdict.WithDirty(TitleVerdict.Empty, true));
        Check("W4: CONTROL — a pending dirty title still does not match the oracle",
            !pendingDirty.Contains(OracleRequires), pendingDirty);
        Check("W4: ...and has no dangling separator",
            !pendingDirty.Contains("|  "), $"'{pendingDirty}'");

        // ===================================================================
        // W2b-2 — WHAT A PANEL CONTROL SENDS, AND THE PANEL LIST
        // ===================================================================
        //
        // ⛔ THE SHELL CANNOT BE COMPILED WHERE IT IS WRITTEN, AND IT RUNS ONLY ON
        // kenai. These are the parts of a person's panel input that a desktop-less
        // runner CAN drive: the bytes that cross, the token a row prints, and
        // the one decision the shell makes about when a focus loss commits.

        var press = Parse(PanelWire.EventJson("mwp_fill_color", "click", null, false, false, false, false));
        Check("W2b-2: a press carries NO value key",
            press is not null && !press.RootElement.TryGetProperty("value", out _), Show(press));
        Check("W2b-2: a press names its widget and its event",
            press is not null
            && Str(press, "widget") == "mwp_fill_color" && Str(press, "event") == "click", Show(press));

        // W2b-19: a leaf's plan path crosses as an int array, and a path that is
        // not one is left out rather than sent.
        var rowed = Parse(PanelWire.EventJson("ap_number", "click", null, false, false, false, false, "[0,1,0]"));
        Check("W2b-19: a press carries its plan path as integers",
            rowed is not null && rowed.RootElement.TryGetProperty("path", out var rp)
            && rp.ValueKind == System.Text.Json.JsonValueKind.Array
            && string.Join(",", rp.EnumerateArray().Select(x => x.GetInt32())) == "0,1,0", Show(rowed));
        // One literal case per shape: check_title_oracle_ran reads case names
        // from the source, and a name built inside a loop is one it cannot size.
        bool NoPath(string bad)
        {
            var ev = Parse(PanelWire.EventJson("w", "click", null, false, false, false, false, bad));
            return ev is not null && !ev.RootElement.TryGetProperty("path", out _);
        }
        Check("W2b-19: an empty path is left out", NoPath(""), "");
        Check("W2b-19: an empty array is left out", NoPath("[]"), "[]");
        Check("W2b-19: a negative index is left out", NoPath("[0,-1]"), "[0,-1]");
        Check("W2b-19: an object is left out", NoPath("{\"a\":1}"), "{\"a\":1}");
        Check("W2b-19: unparseable text is left out", NoPath("[0,1"), "[0,1");
        Check("W2b-19: a bare number is left out", NoPath("0"), "0");
        Check("W2b-19: no path given means no path key",
            press is not null && !press.RootElement.TryGetProperty("path", out _), Show(press));

        var commit = Parse(PanelWire.EventJson("mwp_fill_tolerance", "commit", "40", false, false, false, false));
        Check("W2b-2: a commit carries its text as a JSON STRING, never a number",
            commit is not null
            && commit.RootElement.TryGetProperty("value", out var cv)
            && cv.ValueKind == System.Text.Json.JsonValueKind.String
            && cv.GetString() == "40", Show(commit));

        var spaced = Parse(PanelWire.EventJson("w", "commit", " 4 0 ", false, false, false, false));
        Eq("W2b-2: a commit sends the text verbatim, spaces and all",
            " 4 0 ", spaced is null ? "(unparseable)" : Str(spaced, "value") ?? "(absent)");
        var blank = Parse(PanelWire.EventJson("w", "commit", "", false, false, false, false));
        Eq("W2b-2: an empty commit sends the empty STRING, and the core decides",
            "", blank is null ? "(unparseable)" : Str(blank, "value") ?? "(absent)");

        var mods = Parse(PanelWire.EventJson("w", "click", null, true, false, true, false));
        Check("W2b-2: the modifiers cross as booleans, each its own",
            mods is not null
            && Bool(mods, "alt") == true && Bool(mods, "shift") == false
            && Bool(mods, "ctrl") == true && Bool(mods, "meta") == false, Show(mods));

        var token = PanelWire.RowValue("a b\tc");
        Check("W2b-2: a row value is one whitespace-free token",
            token.Length > 0 && !token.Any(char.IsWhiteSpace), $"'{token}'");
        Eq("W2b-2: ...and it decodes back to the text",
            "a b\tc", Decode(token));
        Eq("W2b-2: a press prints the no-value marker",
            PanelWire.NoValue, PanelWire.RowValue(null));
        Check("W2b-2: CONTROL: the text '-' does not print as the no-value marker",
            PanelWire.RowValue("-") != PanelWire.NoValue, PanelWire.RowValue("-"));

        Check("W2b-2: focus loss commits a changed text",
            PanelWire.CommitOnBlur("41", "40"), "41 over 40 did not commit");
        Check("W2b-2: CONTROL: focus loss does not commit the text the core showed",
            !PanelWire.CommitOnBlur("40", "40"), "40 over 40 committed");
        Check("W2b-2: the comparison is ordinal, so a case change commits",
            PanelWire.CommitOnBlur("Abc", "abc"), "Abc over abc did not commit");

        var list = PanelWire.ReadPanelList(
            "[{\"id\":\"align_panel_content\",\"summary\":\"Align\"},"
            + "{\"id\":\"magic_wand_panel_content\",\"summary\":null},"
            + "{\"summary\":\"No id\"},{\"id\":7,\"summary\":\"Number id\"}]");
        Eq("W2b-2: the panel list keeps the core's rows in the core's order",
            "align_panel_content=Align|magic_wand_panel_content=magic_wand_panel_content",
            list is null ? "(null)" : string.Join("|", list.Rows.Select(r => $"{r.Id}={r.Label}")));
        Check("W2b-2: a row with no string id is counted, never shown",
            list is not null && list.Skipped == 2, list is null ? "(null)" : $"skipped={list.Skipped}");
        Check("W2b-2: bytes that do not parse are UNREADABLE (null), not an empty list",
            PanelWire.ReadPanelList("not json") is null, "an unparseable list read as a list");
        Check("W2b-2: a JSON object is UNREADABLE too",
            PanelWire.ReadPanelList("{\"id\":\"a\"}") is null, "an object read as a list");
        var none = PanelWire.ReadPanelList("[]");
        Check("W2b-2: CONTROL: an empty array is an empty list, not a refusal",
            none is not null && none.Rows.Count == 0 && none.Skipped == 0,
            none is null ? "(null)" : $"rows={none.Rows.Count} skipped={none.Skipped}");

        // ===================================================================
        // W2b-3 — THE VALUE REPLAY'S READINGS AND ITS KNOB
        // ===================================================================
        //
        // ⛔ THE SHELL JUDGES NOTHING, SO WHAT IT WRITES MUST BE EXACTLY WHAT THE
        // PLAN SAID. `LeafValue` is the one reading the replay's row carries per
        // step, and the harness compares those readings with no tolerance: a
        // reader that returned a stale value, or an id-less text leaf's value, or
        // an empty string for a missing key, would hand the harness a wrong
        // number wearing the shape of a right one. The plan below has the real
        // Magic Wand leaves' shape (`jas_panel_plan`, 228) plus the leaves each
        // refusal needs.
        const string MwPlan =
            "{\"leaves\":["
            + "{\"path\":[0,0,0],\"type\":\"toggle\",\"id\":\"mwp_fill_color\",\"values\":{\"bind.checked\":\"true\"}},"
            + "{\"path\":[0,1,0],\"type\":\"text\",\"id\":\"\",\"values\":{\"bind.value\":\"9\"}},"
            + "{\"path\":[0,1,1],\"type\":\"number_input\",\"id\":\"mwp_fill_tolerance\","
            + "\"values\":{\"bind.disabled\":\"false\",\"bind.value\":\"32\"}},"
            + "{\"path\":[1,0,0],\"type\":\"text_input\",\"id\":\"blank_box\",\"values\":{\"bind.value\":\"\"}},"
            + "{\"path\":[2,0,0],\"type\":\"number_input\",\"id\":\"odd_box\",\"values\":{\"bind.value\":7}},"
            + "{\"path\":[3,0,0],\"type\":\"number_input\",\"id\":\"twice\",\"values\":{\"bind.value\":\"1\"}},"
            + "{\"path\":[3,0,1],\"type\":\"number_input\",\"id\":\"twice\",\"values\":{\"bind.value\":\"2\"}}"
            + "],\"chrome\":[],\"containers\":[],\"withheld\":[],\"unjoined\":[],\"icons\":{},\"height\":164}";

        Eq("W2b-3: a number leaf's value reads as the plan's own string",
            "32", PanelWire.LeafValue(MwPlan, "mwp_fill_tolerance", "bind.value"));
        Eq("W2b-3: a second key of the same leaf reads its own value",
            "false", PanelWire.LeafValue(MwPlan, "mwp_fill_tolerance", "bind.disabled"));
        Eq("W2b-3: a toggle's checked reads as the plan's canonical text",
            "true", PanelWire.LeafValue(MwPlan, "mwp_fill_color", "bind.checked"));
        Eq("W2b-3: a widget the plan does not hold is ABSENT",
            "ABSENT", PanelWire.LeafValue(MwPlan, "mwp_no_such_widget", "bind.value"));
        Eq("W2b-3: a key the leaf does not carry is ABSENT",
            "ABSENT", PanelWire.LeafValue(MwPlan, "mwp_fill_color", "bind.value"));
        Eq("W2b-3: an empty widget id is ABSENT, never an id-less text leaf's value",
            "ABSENT", PanelWire.LeafValue(MwPlan, "", "bind.value"));
        Eq("W2b-3: an empty string value is a value, not ABSENT",
            "", PanelWire.LeafValue(MwPlan, "blank_box", "bind.value"));
        Eq("W2b-3: a value that is not a string is UNREADABLE",
            "UNREADABLE", PanelWire.LeafValue(MwPlan, "odd_box", "bind.value"));
        Eq("W2b-3: a widget id the plan holds twice reads the first leaf",
            "1", PanelWire.LeafValue(MwPlan, "twice", "bind.value"));
        Eq("W2b-3: bytes that do not parse are UNREADABLE",
            "UNREADABLE", PanelWire.LeafValue("not json", "mwp_fill_tolerance", "bind.value"));
        Eq("W2b-3: the empty span a refused plan leaves is UNREADABLE",
            "UNREADABLE", PanelWire.LeafValue("", "mwp_fill_tolerance", "bind.value"));
        Eq("W2b-3: JSON with no leaves list is UNREADABLE, not ABSENT",
            "UNREADABLE", PanelWire.LeafValue("{\"height\":164}", "mwp_fill_tolerance", "bind.value"));
        Eq("W2b-3: a JSON array is UNREADABLE",
            "UNREADABLE", PanelWire.LeafValue("[]", "mwp_fill_tolerance", "bind.value"));
        Check("W2b-3: CONTROL: the two sentinels are distinct and neither is empty",
            PanelWire.Absent != PanelWire.Unreadable
            && PanelWire.Absent.Length > 0 && PanelWire.Unreadable.Length > 0,
            $"'{PanelWire.Absent}' '{PanelWire.Unreadable}'");

        Eq("W2b-3: the commit knob splits at the first colon",
            "mwp_fill_tolerance|40", ShowSplit(PanelWire.SplitCommitKnob("mwp_fill_tolerance:40")));
        Eq("W2b-3: a colon after the first stays in the text",
            "w|a:b", ShowSplit(PanelWire.SplitCommitKnob("w:a:b")));
        Eq("W2b-3: the text is kept verbatim, spaces and all",
            "w| 4 0 ", ShowSplit(PanelWire.SplitCommitKnob("w: 4 0 ")));
        Eq("W2b-3: an empty text is a text, and the core decides",
            "w|", ShowSplit(PanelWire.SplitCommitKnob("w:")));
        Eq("W2b-3: a knob with no colon is refused",
            "(null)", ShowSplit(PanelWire.SplitCommitKnob("mwp_fill_tolerance")));
        Eq("W2b-3: an empty widget is refused",
            "(null)", ShowSplit(PanelWire.SplitCommitKnob(":40")));
        Eq("W2b-3: a whitespace widget is refused, the knob's own unset predicate",
            "(null)", ShowSplit(PanelWire.SplitCommitKnob("  :40")));
        Eq("W2b-3: an empty knob is refused",
            "(null)", ShowSplit(PanelWire.SplitCommitKnob("")));

        // ─────────────────────────────────────────────────────────────
        // W2b-9: which of the core's two strings a control shows.
        //
        // The plan hands a `length_input` its raw value ("12") AND a
        // core-formatted display ("12 pt"). Every other port shows the
        // formatted one, because each formats at a view layer INSIDE the
        // interpreter; this shell is the first view that is outside one.
        // ─────────────────────────────────────────────────────────────
        Eq("W2b-9: the core's formatted display wins over the raw value",
            "12 pt", PanelWire.DisplayText("12 pt", "12"));
        // ⛔ THE ARM THAT MATTERS, AND THE ONE A `??` ON THE WRONG SIDE
        //    BREAKS: an EMPTY display is a real answer. A length whose bind
        //    resolves to anything but a number displays empty in every port,
        //    while its raw value may still be a string.
        Eq("W2b-9: an EMPTY display still wins -- presence, never truthiness",
            "", PanelWire.DisplayText("", "not-a-number"));
        Eq("W2b-9: no display sent, so the resolved value is shown",
            "12", PanelWire.DisplayText(null, "12"));
        Eq("W2b-9: neither sent is the empty string, never null",
            "", PanelWire.DisplayText(null, null));
        // The control: the two inputs are distinguishable, so the four cases
        // above are about the RULE and not about two strings that happen to
        // agree. Without this a reader cannot tell a working preference from
        // a function that returns its second argument.
        Check("W2b-9: CONTROL: display and value differ in the winning case",
            PanelWire.DisplayText("12 pt", "12") != "12",
            "the preference cannot be observed if the two agree");

        // ─────────────────────────────────────────────────────────────
        // A `color_swatch`'s fill (STATUS-flask §110: 228 of the Swatches
        // panel's 234 leaves were `[color_swatch]` placeholders). The core
        // sends `bind.color` as `#rrggbb`; the shell parses and computes
        // nothing else. A null is an EMPTY swatch, never black.
        // ─────────────────────────────────────────────────────────────
        Eq("swatch: #rrggbb is its three channels", "102,64,64", ShowRgb(PanelWire.SwatchColor("#664040")));
        Eq("swatch: either case", "255,255,255", ShowRgb(PanelWire.SwatchColor("#FFfFff")));
        Eq("swatch: black is a colour, not a failure", "0,0,0", ShowRgb(PanelWire.SwatchColor("#000000")));
        // One literal case per malformed string: check_title_oracle_ran sizes
        // cases by reading their names, and a name built in a loop cannot be
        // sized (#235 and this node both tripped it).
        Eq("swatch: no # is no colour", "(null)", ShowRgb(PanelWire.SwatchColor("664040")));
        Eq("swatch: five digits is no colour", "(null)", ShowRgb(PanelWire.SwatchColor("#66404")));
        Eq("swatch: seven digits is no colour", "(null)", ShowRgb(PanelWire.SwatchColor("#6640400")));
        Eq("swatch: a non-hex digit is no colour", "(null)", ShowRgb(PanelWire.SwatchColor("#gg0000")));
        Eq("swatch: empty is no colour", "(null)", ShowRgb(PanelWire.SwatchColor("")));
        Eq("swatch: the word null is no colour", "(null)", ShowRgb(PanelWire.SwatchColor("null")));
        Eq("swatch: a leading space is no colour", "(null)", ShowRgb(PanelWire.SwatchColor(" #664040")));
        Eq("swatch: a space inside, which HexNumber would accept is no colour", "(null)", ShowRgb(PanelWire.SwatchColor("# 12345")));

        // ─────────────────────────────────────────────────────────────
        // A `brush_preview`'s drawing (STATUS-flask §112: every preview was
        // an empty box, `values: {}`). The core sends `display["preview.svg"]`
        // and `display["preview.viewbox"]`, the pair an icon is drawn from;
        // the shell draws them or draws nothing. Both, or neither.
        // ─────────────────────────────────────────────────────────────
        Eq("preview: both halves draw", "0 0 40 40|<ellipse/>", ShowPreview(PanelWire.Preview("0 0 40 40", "<ellipse/>")));
        Eq("preview: no svg is no drawing", "(null)", ShowPreview(PanelWire.Preview("0 0 40 40", null)));
        Eq("preview: no viewbox is no drawing", "(null)", ShowPreview(PanelWire.Preview(null, "<ellipse/>")));
        Eq("preview: an empty svg is no drawing", "(null)", ShowPreview(PanelWire.Preview("0 0 40 40", "")));
        Eq("preview: a blank viewbox is no drawing", "(null)", ShowPreview(PanelWire.Preview("  ", "<ellipse/>")));
        Eq("swatch: null is no colour", "(null)", ShowRgb(PanelWire.SwatchColor(null)));
        // ─────────────────────────────────────────────────────────────
        // §1.2: a dropdown's `items` channel, read from the core's OWN bytes:
        // the Layers type filter's entry after one pick checked `path`,
        // printed by `the_layers_filter_plan_carries_its_items_and_their_checks`
        // -- copied, never typed from the shape.
        // ─────────────────────────────────────────────────────────────
        const string LayersFilter = """
            [{"kind":"action","label":"All","value":"__all__"},{"checked":false,"kind":"toggle","label":"Layer","value":"layer"},{"checked":false,"kind":"toggle","label":"Group","value":"group"},{"checked":true,"kind":"toggle","label":"Path","value":"path"},{"checked":false,"kind":"toggle","label":"Rectangle","value":"rectangle"},{"checked":false,"kind":"toggle","label":"Circle","value":"circle"},{"checked":false,"kind":"toggle","label":"Ellipse","value":"ellipse"},{"checked":false,"kind":"toggle","label":"Polyline","value":"polyline"},{"checked":false,"kind":"toggle","label":"Polygon","value":"polygon"},{"checked":false,"kind":"toggle","label":"Text","value":"text"},{"checked":false,"kind":"toggle","label":"Text Path","value":"text_path"},{"checked":false,"kind":"toggle","label":"Line","value":"line"},{"checked":false,"kind":"toggle","label":"Compound Shape","value":"live"}]
            """;
        var filter = PanelWire.ReadItems(LayersFilter);
        Check("items: the Layers filter's channel reads", filter is not null && filter.Refused == 0, $"refused={filter?.Refused}");
        // Counts DERIVED from the fixture by a route the reader does not use.
        var wantRows = LayersFilter.Split("\"kind\":").Length - 1;
        var wantToggles = LayersFilter.Split("\"kind\":\"toggle\"").Length - 1;
        Eq("items: one row per item", wantRows.ToString(), (filter?.Rows.Count ?? -1).ToString());
        Eq("items: every toggle is a toggle row", wantToggles.ToString(),
            (filter?.Rows.Count(r => r.Kind == "toggle") ?? -1).ToString());
        Eq("items: the core's one check is the one read", "path",
            filter is null ? "(null)" : string.Join(",", filter.Rows.Where(r => r.Checked == true).Select(r => r.Value)));
        Eq("items: an action row carries no check", "(null)",
            filter is null ? "(no list)" : filter.Rows.First(r => r.Kind == "action").Checked?.ToString() ?? "(null)");
        Check("items: CONTROL: an unchecked toggle reads false, not unknown",
            filter is not null && filter.Rows.Any(r => r.Kind == "toggle" && r.Checked == false),
            "the check arms above would pass on a reader that made every check null");
        // An unknown check is its own state, and it is not unchecked.
        var unknown = PanelWire.ReadItems("""[{"kind":"toggle","value":"a","label":"A","checked":null}]""");
        Eq("items: a null check is unknown, not false", "(null)", unknown?.Rows[0].Checked?.ToString() ?? "(null)");
        Eq("items: the core's null is no list", "(null)", PanelWire.ReadItems("null") is null ? "(null)" : "list");
        Eq("items: an absent key is no list", "(null)", PanelWire.ReadItems(null) is null ? "(null)" : "list");
        var oddItems = PanelWire.ReadItems("""
            [{"kind":"submenu","value":"s","label":"S"},{"kind":"toggle","label":"no value"},
             {"kind":"toggle","value":"x","label":"X","checked":"yes"},{"kind":"separator"},
             {"kind":"action","value":"ok","label":"OK"}]
            """);
        Eq("items: an unreadable row is refused and counted", "3", (oddItems?.Refused ?? -1).ToString());
        Eq("items: ...and the readable rows are still offered", "separator,action",
            oddItems is null ? "(null)" : string.Join(",", oddItems.Rows.Select(r => r.Kind)));
        Eq("items: a plain pick is toggle", "toggle", PanelWire.PickEvent(false));
        Eq("items: an Alt pick is alt_toggle", "alt_toggle", PanelWire.PickEvent(true));

        // A swatch's tap reaches the core by its id OR its plan path
        // (STATUS-flask §114: a library tile has no id, only a path).
        Eq("addressable: an id alone", "True", PanelWire.Addressable("sp_recent_0", null).ToString());
        Eq("addressable: a plan path alone, a library swatch", "True", PanelWire.Addressable("", "[3,0,0,3]").ToString());
        Eq("addressable: neither an id nor a path", "False", PanelWire.Addressable("", null).ToString());
        Eq("addressable: a negative index is no plan path", "False", PanelWire.Addressable("", "[3,-1]").ToString());
        Eq("addressable: an empty array is no plan path", "False", PanelWire.Addressable("", "[]").ToString());
        Eq("addressable: text that is not JSON is no plan path", "False", PanelWire.Addressable("", "row 3").ToString());
        Check("swatch: CONTROL: two colours read differently",
            ShowRgb(PanelWire.SwatchColor("#664040")) != ShowRgb(PanelWire.SwatchColor("#406640")),
            "a parser that ignores its input would pass every case above but the null ones");

        // ─────────────────────────────────────────────────────────────
        // W2b-9: which name a glyph is looked up under.
        //
        // The producer (`panel_plan.rs::icon_names`) special-cases the `icon`
        // TYPE and reads `name`; every other kind names its glyph under
        // `icon`. A shell that looked only under `icon` resolves every bare
        // `icon` to null and never asks for the SVG.
        // ─────────────────────────────────────────────────────────────
        Eq("W2b-9: an icon_button names its glyph under `icon`",
            "plus", Show(PanelWire.IconName(null, "plus", null, "icon_button")));
        // ⛔ THE ARM FOR THE BUG THIS FOUND: without the type-gated `name`
        //    branch this is null, and all 15 bare icons draw an empty face.
        Eq("W2b-9: a bare `icon` node names its glyph under `name`",
            "char_size", Show(PanelWire.IconName(null, null, "char_size", "icon")));
        // ⛔ AND THE BRANCH IS TYPE-GATED: `name` is a STATIC_KEYS display
        //    string other kinds carry, so reading it unconditionally would
        //    turn some other widget's label into an icon lookup.
        Eq("W2b-9: `name` on a NON-icon kind is not a glyph lookup",
            "(null)", Show(PanelWire.IconName(null, null, "char_size", "text")));
        Eq("W2b-9: a resolved bind.icon wins over both literals",
            "bound", Show(PanelWire.IconName("bound", "literal", "named", "icon")));
        Eq("W2b-9: nothing named is null, so the caller counts an icon-text",
            "(null)", Show(PanelWire.IconName(null, null, null, "icon")));
        // The control: the three inputs are pairwise distinct in the winning
        // case, so the precedence above is observable. Without it a reader
        // cannot tell a working precedence from a function returning its first
        // non-null argument in some other order.
        Check("W2b-9: CONTROL: the icon-name inputs differ in the winning case",
            PanelWire.IconName("bound", "literal", "named", "icon") == "bound"
            && PanelWire.IconName(null, "literal", "named", "icon") == "literal"
            && PanelWire.IconName(null, null, "named", "icon") == "named",
            "the three sources must be separable");

        // ─────────────────────────────────────────────────────────────
        // W-b: the options channel, read from the core's OWN bytes.
        //
        // Each fixture below is a `panel_plan` entry's `options`, printed by
        // the Rust core at `jas/panel-plan-options-channel` with op_mode bound
        // to "multiply", the arrowhead scale to 100.0 and the bullets to
        // "bullet-disc" -- copied, never typed from the shape.
        // ─────────────────────────────────────────────────────────────
        const string OpMode = """
            [{"kind":"option","label":"Normal","selected":false,"value":"normal"},{"kind":"separator"},{"kind":"option","label":"Darken","selected":false,"value":"darken"},{"kind":"option","label":"Multiply","selected":true,"value":"multiply"},{"kind":"option","label":"Color Burn","selected":false,"value":"color_burn"},{"kind":"separator"},{"kind":"option","label":"Lighten","selected":false,"value":"lighten"},{"kind":"option","label":"Screen","selected":false,"value":"screen"},{"kind":"option","label":"Color Dodge","selected":false,"value":"color_dodge"},{"kind":"separator"},{"kind":"option","label":"Overlay","selected":false,"value":"overlay"},{"kind":"option","label":"Soft Light","selected":false,"value":"soft_light"},{"kind":"option","label":"Hard Light","selected":false,"value":"hard_light"},{"kind":"separator"},{"kind":"option","label":"Difference","selected":false,"value":"difference"},{"kind":"option","label":"Exclusion","selected":false,"value":"exclusion"},{"kind":"separator"},{"kind":"option","label":"Hue","selected":false,"value":"hue"},{"kind":"option","label":"Saturation","selected":false,"value":"saturation"},{"kind":"option","label":"Color","selected":false,"value":"color"},{"kind":"option","label":"Luminosity","selected":false,"value":"luminosity"}]
            """;
        const string ArrowScale = """
            [{"kind":"option","label":"50%","selected":false,"value":"50"},{"kind":"option","label":"75%","selected":false,"value":"75"},{"kind":"option","label":"100%","selected":true,"value":"100"},{"kind":"option","label":"150%","selected":false,"value":"150"},{"kind":"option","label":"200%","selected":false,"value":"200"},{"kind":"option","label":"300%","selected":false,"value":"300"},{"kind":"option","label":"400%","selected":false,"value":"400"}]
            """;
        const string Bullets = """
            [{"glyph":"—","kind":"option","label":"None","selected":false,"value":""},{"glyph":"•","kind":"option","label":"Disc","selected":true,"value":"bullet-disc"},{"glyph":"○","kind":"option","label":"Open Circle","selected":false,"value":"bullet-open-circle"},{"glyph":"■","kind":"option","label":"Square","selected":false,"value":"bullet-square"},{"glyph":"□","kind":"option","label":"Open Square","selected":false,"value":"bullet-open-square"},{"glyph":"–","kind":"option","label":"Dash","selected":false,"value":"bullet-dash"},{"glyph":"✓","kind":"option","label":"Check","selected":false,"value":"bullet-check"}]
            """;
        var op = PanelWire.ReadOptions(OpMode);
        Check("W-b: op_mode's channel reads", op is not null && op.Refused == 0, $"refused={op?.Refused}");
        // The counts are DERIVED from the fixture's own rows, by a route the
        // reader does not use (a substring count), never typed.
        var wantValues = OpMode.Split("\"kind\":\"option\"").Length - 1;
        var wantDividers = OpMode.Split("\"kind\":\"separator\"").Length - 1;
        Eq("W-b: every value is an item", wantValues.ToString(), (op?.Items.Count ?? -1).ToString());
        Eq("W-b: every divider is a row and NOT an item",
            (wantValues + wantDividers).ToString(), (op?.Rows.Count ?? -1).ToString());
        // ⛔ THE TRAP: a shell that looped the raw list put "separator" on the
        //    blend-mode menu, where picking it commits that string.
        Check("W-b: no item is a divider, and no item's value is the divider token",
            op is not null && op.Items.All(r => !r.Separator && r.Value != "separator"),
            "a divider reached the list as a value");
        Check("W-b: CONTROL: the fixture really carries dividers",
            wantDividers > 0, "the arm above would pass on a list with none");
        // The CORE marked the row; the shell compares nothing to find it.
        Eq("W-b: the selected index is the row the core marked",
            "multiply", op is not null && op.SelectedIndex >= 0 ? op.Items[op.SelectedIndex].Value : "(none)");
        // Dropping the dividers SHIFTS indices, so an index read off the raw
        // rows would land one row early here: "multiply" follows a divider.
        Check("W-b: CONTROL: the selected row sits after a divider (the shift is exercised)",
            op is not null && op.Rows.FindIndex(r => r.Selected) != op.SelectedIndex,
            "the raw-row index and the item index agree, so the shift is untested");

        var scale = PanelWire.ReadOptions(ArrowScale);
        // ⛔ IT SENDS THE VALUE, NEVER THE LABEL: "150%" would be refused.
        Eq("W-b: a pick sends the row's value, not its label",
            "150", Show(scale is null ? null : PanelWire.ChoiceCommit(3, scale.Items, "100")));
        Check("W-b: CONTROL: label and value differ on that row",
            scale is not null && scale.Items[3].Label != scale.Items[3].Value, "the arm above cannot tell them apart");
        // ⛔ Putting the control back to the core's value fires the same
        //    selection event a person's pick does; it must send NOTHING.
        Eq("W-b: re-selecting the value the core shows sends nothing",
            "(null)", Show(scale is null ? null : PanelWire.ChoiceCommit(scale.SelectedIndex, scale.Items, "100")));
        Eq("W-b: no item picked sends nothing",
            "(null)", Show(scale is null ? null : PanelWire.ChoiceCommit(-1, scale.Items, "100")));
        Eq("W-b: an index past the list sends nothing",
            "(null)", Show(scale is null ? null : PanelWire.ChoiceCommit(scale.Items.Count, scale.Items, "100")));

        var bullets = PanelWire.ReadOptions(Bullets);
        Eq("W-b: an icon_select item shows its glyph beside its label",
            "\u2022  Disc", bullets is null ? "(null)" : PanelWire.ChoiceText(bullets.Items[1]));
        Eq("W-b: a row with no glyph shows its label alone",
            "150%", scale is null ? "(null)" : PanelWire.ChoiceText(scale.Items[3]));
        // An EMPTY value is a value ("None"), and it is sent as one.
        Eq("W-b: the empty value is committable",
            "", Show(bullets is null ? null : PanelWire.ChoiceCommit(0, bullets.Items, "bullet-disc")));

        // NULL MEANS NO LIST, AND IS NOT AN EMPTY ONE.
        Eq("W-b: the core's null is no list", "(null)", PanelWire.ReadOptions("null") is null ? "(null)" : "list");
        Eq("W-b: an absent key is no list", "(null)", PanelWire.ReadOptions(null) is null ? "(null)" : "list");
        Eq("W-b: unreadable bytes are no list", "(null)", PanelWire.ReadOptions("{not json") is null ? "(null)" : "list");
        Eq("W-b: CONTROL: an empty array IS a list, of nothing",
            "0", (PanelWire.ReadOptions("[]")?.Rows.Count ?? -1).ToString());
        // An unknown kind, or an option missing a string, is COUNTED.
        var odd = PanelWire.ReadOptions("""
            [{"kind":"heading","label":"x"},{"kind":"option","label":"no value","selected":false},
             {"kind":"option","value":"ok","label":"OK","selected":false}]
            """);
        Eq("W-b: an unreadable row is refused and counted", "2", (odd?.Refused ?? -1).ToString());
        Eq("W-b: ...and the readable one is still offered", "ok", odd is null || odd.Items.Count != 1 ? "(wrong)" : odd.Items[0].Value);
        Eq("W-b: nothing marked is index -1, never 0", "-1", (odd?.SelectedIndex ?? 99).ToString());

        // A rebuild keys on the LIST and not the selection, which moves every tick.
        var moved = PanelWire.ReadOptions(OpMode.Replace("\"selected\":true", "\"selected\":false"));
        Eq("W-b: a moved selection keeps the signature", op?.Signature ?? "a", moved?.Signature ?? "b");
        var relabeled = PanelWire.ReadOptions(OpMode.Replace("\"Darken\"", "\"Darker\""));
        Check("W-b: a changed label changes the signature",
            relabeled is not null && op is not null && relabeled.Signature != op.Signature, "a relabel would not rebuild");

        Console.WriteLine();
        Console.WriteLine($"--- {_passed} passed, {_failed} failed, of {_passed + _failed} case(s) ---");
        return _failed == 0 ? 0 : 1;
    }
}
