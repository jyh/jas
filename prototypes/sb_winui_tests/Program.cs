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
            Run("RUSTFAIL SB_TOOL='pen' is refused: not an index below the core's 27 tool(s)",
                "RUSTOK STAY pid=4812").Verdict);

        Check("O5: ...and the refusal is still COUNTED, so it cannot hide",
            Run("RUSTFAIL SB_TOOL='pen' is refused", "RUSTOK STAY pid=4812").Fails == 1,
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
            Run("RUSTFAIL SB_TOOL='pen' is refused", "RUSTOK STAY pid=4812"));
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
        // STATUS-jas item 23 (flask §563 finding I): a field a `foreach` stamps
        // out has NO id, so its commit crosses with an EMPTY widget, its typed
        // text and its plan path -- the shape the engine's
        // `a_template_param_field_commits_by_its_plan_path` arm sends.
        var templated = Parse(PanelWire.EventJson("", "commit", "8", false, false, false, false, "[0,1,2,0,1]"));
        Check("item 23: an id-less field's commit carries its value and its plan path",
            templated is not null && Str(templated, "widget") == "" && Str(templated, "event") == "commit"
            && Str(templated, "value") == "8"
            && templated.RootElement.TryGetProperty("path", out var tp)
            && string.Join(",", tp.EnumerateArray().Select(x => x.GetInt32())) == "0,1,2,0,1", Show(templated));
        Check("item 23: an id-less field is addressable by its plan path",
            PanelWire.Addressable("", "[0,1,2,0,1]"), "");
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

        // jas item 40 (#715): a text field whose node answers `keydown` sends the
        // key's W3C name and the text BEFORE the key acts, at its plan path; one
        // that answers `blur` sends its text on losing focus. The plan's `events`
        // channel says which; the shell does not decide by kind.
        var keyed = Parse(PanelWire.EventJson("lp_name_edit", "keydown", "Bob", false, false, false, false, "[3,0,6]", "Enter"));
        Check("item 40: a keydown carries its key name, its text and its plan path",
            keyed is not null && Str(keyed, "event") == "keydown" && Str(keyed, "key") == "Enter"
            && Str(keyed, "value") == "Bob" && keyed.RootElement.TryGetProperty("path", out _), Show(keyed));
        Check("item 40: an event with no key sends no key field",
            press is not null && !press.RootElement.TryGetProperty("key", out _), Show(press));
        Eq("item 40: Enter crosses as Enter", "Enter", PanelWire.KeyName("Enter") ?? "(none)");
        Eq("item 40: Escape crosses as Escape", "Escape", PanelWire.KeyName("Escape") ?? "(none)");
        Eq("item 40: a letter is the box's own, not sent", "(none)", PanelWire.KeyName("A") ?? "(none)");
        Eq("item 40: Tab is not sent", "(none)", PanelWire.KeyName("Tab") ?? "(none)");
        Check("item 40: a node that answers keydown takes its keys",
            PanelWire.Answers(new[] { "keydown", "blur" }, "keydown"), "");
        Check("item 40: a node that answers only commit does not",
            !PanelWire.Answers(new[] { "commit" }, "keydown"), "");
        Check("item 40: no events channel answers nothing",
            !PanelWire.Answers(null, "blur"), "");

        // jas §612: every layout container the plan lists (`chrome` or
        // `containers`) whose `events` is non-empty gets a hit surface beneath
        // its children, addressed by its plan path. One with `events: []`, no
        // `events`, or under a `hidden` path gets none.
        const string HitPlan = """
            {"height": 60,
             "chrome": [
               {"path": [3, 0], "rect": {"x": 0, "y": 0, "w": 200, "h": 24}, "type": "container", "id": "", "values": {"bind.background": "#cde3f7"}, "events": ["click", "double_click"]},
               {"path": [3, 1], "rect": {"x": 0, "y": 24, "w": 200, "h": 24}, "type": "container", "id": "", "values": {}, "events": []}],
             "leaves": [
               {"path": [3, 0, 2], "rect": {"x": 40, "y": 0, "w": 60, "h": 24}, "type": "text", "id": "lp_name", "values": {}, "events": ["double_click"]}],
             "containers": [
               {"path": [3, 0, 5], "rect": {"x": 180, "y": 0, "w": 20, "h": 24}, "type": "container", "id": "lp_select", "values": {"bind.visible": "true"}, "events": ["click"]},
               {"path": [4, 0], "rect": {"x": 0, "y": 48, "w": 200, "h": 12}, "type": "container", "id": "", "values": {"bind.visible": "false"}, "events": ["click"]},
               {"path": [5], "rect": {"x": 0, "y": 0, "w": 1, "h": 1}, "type": "container", "id": "", "values": {"bind.x": "1"}}],
             "hidden": [[4]]}
            """;
        var hits = PanelWire.HitBoxes(HitPlan);
        Eq("§612: the containers with events get surfaces, in plan order",
            "[3,0]|[3,0,5]", hits is null ? "(null)" : string.Join("|", hits.Select(h => h.Path.Replace(" ", ""))));
        Eq("§612: a surface keeps its rect",
            "180,0,20x24", hits is { Count: 2 } ? $"{hits[1].X},{hits[1].Y},{hits[1].W}x{hits[1].H}" : "(none)");
        Eq("§612: a surface keeps its id and events",
            "lp_select:click", hits is { Count: 2 } ? $"{hits[1].Id}:{string.Join(",", hits[1].Events)}" : "(none)");
        // jas §630/(B): a surface carries the plan's `bind.background` (a
        // panel-selected row's highlight), and only a `#rrggbb` paints;
        // `transparent`, a missing key, or anything else paints nothing.
        Eq("§630: a surface carries its bind.background",
            "#cde3f7", hits is { Count: 2 } ? hits[0].Background ?? "(null)" : "(none)");
        Eq("§630: a surface with no bind.background carries none",
            "(null)", hits is { Count: 2 } ? hits[1].Background ?? "(null)" : "(none)");
        Check("§630: a selected row's colour paints",
            PanelWire.SurfaceFill("#cde3f7") is (0xCD, 0xE3, 0xF7), "");
        Check("§630: 'transparent' paints nothing",
            PanelWire.SurfaceFill("transparent") is null, "");
        Check("§630: an unresolved template paints nothing, never a guess",
            PanelWire.SurfaceFill("{{theme.colors.selection}}") is null, "");
        Check("§612: a leaf is never a surface (it is its own control)",
            hits is not null && hits.All(h => h.Id != "lp_name"), "");
        Check("§612: an unparseable plan reads null, never 'no surfaces'",
            PanelWire.HitBoxes("{not json") is null, "");
        // A text that answers `double_click` (the Layers name starts a rename).
        Check("§612: a text answering double_click routes it",
            PanelWire.RoutesEvent(new[] { "double_click" }, "lp_name", null, "double_click"), "");
        Check("§612: ...an id-less one by its plan path",
            PanelWire.RoutesEvent(new[] { "double_click" }, "", "[3,0,2]", "double_click"), "");
        Check("§612: a text that answers only click does not route a double_click",
            !PanelWire.RoutesEvent(new[] { "click" }, "ap_name", null, "double_click"), "");

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

        // flask § 451 / § 457: an editable combo's typed text commits when a
        // person LEAVES it, as a text box's does; Enter was the only commit.
        var comboItems = new[] { "0°", "45°", "90°" };
        Eq("combo blur: typed text no item names commits as typed",
            "13", PanelWire.ComboBlurCommit("13", "0", "0°", comboItems, false) ?? "(null)");
        Eq("combo blur: CONTROL: the text the core showed does not commit",
            "(null)", PanelWire.ComboBlurCommit("0°", "0", "0°", comboItems, false) ?? "(null)");
        Eq("combo blur: CONTROL: the core's value typed back does not commit",
            "(null)", PanelWire.ComboBlurCommit("0", "0", "0°", comboItems, false) ?? "(null)");
        // flask § 499 / § 500: a selection the platform moved by COMPLETING typed
        // text (13 to 135) is not a pick. Only the list picks, open or closed by
        // the pick itself; a completion writes the item's text into the box, so
        // the box text cannot tell them apart.
        Check("editable pick: a pick in the open dropdown is real",
            PanelWire.EditablePickIsReal(true, false), "an open-list pick was refused");
        Check("editable pick: a pick that has just closed the list is real",
            PanelWire.EditablePickIsReal(false, true), "a closing pick was refused");
        Check("editable pick: a selection moved with the list shut is NOT a pick",
            !PanelWire.EditablePickIsReal(false, false), "a completion read as a pick");
        // flask § 503: the shell takes Enter, from the EDITOR's text.
        var angleItems = new List<PaneOption> {
            new(false, "0", "0", null, true), new(false, "45", "45", null, false), new(false, "135", "135", null, false) };
        Eq("enter: typed text that names no item sends as typed (31, not the completed 135)",
            "31", PanelWire.EnterCommit("31", "13", "13", angleItems) ?? "(null)");
        Eq("enter: an item's text sends that item's VALUE",
            "45", PanelWire.EnterCommit("45", "13", "13", angleItems) ?? "(null)");
        Eq("enter: CONTROL: the core's own value sends nothing",
            "(null)", PanelWire.EnterCommit("13", "13", "13", angleItems) ?? "(null)");
        Eq("enter: CONTROL: the item the core shows sends nothing",
            "(null)", PanelWire.EnterCommit("0", "0", "0", angleItems) ?? "(null)");
        Eq("enter: a blank editor sends nothing",
            "(null)", PanelWire.EnterCommit(" ", "13", "13", angleItems) ?? "(null)");
        // flask § 505: Up/Down with the list shut step from the CORE's item.
        Eq("arrow: Down from 90 (index 5 of 8) picks 135 (6)", "6", PanelWire.ArrowPick(5, 8, true).ToString());
        Eq("arrow: Up from 90 picks 45 (4)", "4", PanelWire.ArrowPick(5, 8, false).ToString());
        Eq("arrow: Down at the last item stays there", "7", PanelWire.ArrowPick(7, 8, true).ToString());
        Eq("arrow: Up at the first item stays there", "0", PanelWire.ArrowPick(0, 8, false).ToString());
        Eq("arrow: Down from a free value picks the first", "0", PanelWire.ArrowPick(-1, 8, true).ToString());
        Eq("arrow: Up from a free value picks the last", "7", PanelWire.ArrowPick(-1, 8, false).ToString());
        Eq("arrow: an empty list picks nothing", "-1", PanelWire.ArrowPick(-1, 0, true).ToString());
        // flask § 504: the platform blanks the editor after the undo restored it.
        Eq("blur text: a blanked editor gives back what was typed",
            "13", PanelWire.BlurText("", "13") ?? "(null)");
        Eq("blur text: CONTROL: an editor with text is read as it is",
            "31", PanelWire.BlurText("31", "13") ?? "(null)");
        Eq("blur text: a box the person emptied stays empty",
            "", PanelWire.BlurText("", "") ?? "(null)");
        Eq("blur text: nothing typed and a blank box is nothing",
            "(null)", PanelWire.BlurText(null, null) ?? "(null)");
        Eq("combo blur: an item's text is a pick, left to the selection path",
            "(null)", PanelWire.ComboBlurCommit("45°", "0", "0°", comboItems, false) ?? "(null)");
        Eq("combo blur: focus moving into the combo's own dropdown is not leaving",
            "(null)", PanelWire.ComboBlurCommit("13", "0", "0°", comboItems, true) ?? "(null)");
        Eq("combo blur: no readable text (the template part missing) sends nothing",
            "(null)", PanelWire.ComboBlurCommit(null, "0", "0°", comboItems, false) ?? "(null)");
        // flask § 459, measured on the box: putting the box back after a
        // commit can leave it EMPTY, and the next blur sent "" (BadValue).
        Eq("combo blur: an empty box is not a value and sends nothing",
            "(null)", PanelWire.ComboBlurCommit("", "0", "0°", comboItems, false) ?? "(null)");
        Eq("combo blur: nor does a whitespace-only box",
            "(null)", PanelWire.ComboBlurCommit("  ", "0", "0°", comboItems, false) ?? "(null)");
        Eq("combo blur: CONTROL: an empty SHOWN text does not stop a typed value",
            "27", PanelWire.ComboBlurCommit("27", "", "", comboItems, false) ?? "(null)");

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
        // the Layers type filter's entry after one pick checked `path` (so
        // "All" is no longer in force),
        // printed by `the_layers_filter_plan_carries_its_items_and_their_checks`
        // -- copied, never typed from the shape.
        // ─────────────────────────────────────────────────────────────
        const string LayersFilter = """
            [{"checked":false,"kind":"action","label":"All","value":"__all__"},{"checked":false,"kind":"toggle","label":"Layer","value":"layer"},{"checked":false,"kind":"toggle","label":"Group","value":"group"},{"checked":true,"kind":"toggle","label":"Path","value":"path"},{"checked":false,"kind":"toggle","label":"Rectangle","value":"rectangle"},{"checked":false,"kind":"toggle","label":"Circle","value":"circle"},{"checked":false,"kind":"toggle","label":"Ellipse","value":"ellipse"},{"checked":false,"kind":"toggle","label":"Polyline","value":"polyline"},{"checked":false,"kind":"toggle","label":"Polygon","value":"polygon"},{"checked":false,"kind":"toggle","label":"Text","value":"text"},{"checked":false,"kind":"toggle","label":"Text Path","value":"text_path"},{"checked":false,"kind":"toggle","label":"Line","value":"line"},{"checked":false,"kind":"toggle","label":"Compound Shape","value":"live"}]
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
        Eq("items: an action row carries the core's in-force check", "False",
            filter is null ? "(no list)" : filter.Rows.First(r => r.Kind == "action").Checked?.ToString() ?? "(null)");
        var inForce = PanelWire.ReadItems("""[{"kind":"action","value":"__all__","label":"All","checked":true}]""");
        Eq("items: an action in force reads true", "True", inForce?.Rows[0].Checked?.ToString() ?? "(null)");
        var badAction = PanelWire.ReadItems("""[{"kind":"action","value":"a","label":"A","checked":1}]""");
        Eq("items: an action's unreadable check is refused", "1", (badAction?.Refused ?? -1).ToString());
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
        // jas §316 (#464): a plan entry names the events its node answers. A
        // press is routed on a leaf whose events hold `click`, whatever its kind
        // (an Artboards row's `text` was drawn deaf, STATUS-flask §315).
        static string Ev(string? json) => PanelWire.ReadEvents(json) is { } ev ? string.Join(",", ev) : "(null)";
        Eq("events: the declared order, read as sent", "click,click_and_wait", Ev("""["click","click_and_wait"]"""));
        Eq("events: a node that answers nothing", "", Ev("[]"));
        Eq("events: no channel, an older core, is no list", "(null)", Ev(null));
        Eq("events: a channel that is not an array is no list", "(null)", Ev("""{"click":true}"""));
        Eq("events: text that is not JSON is no list", "(null)", Ev("click"));
        Eq("events: a non-string entry is skipped, the rest read", "click", Ev("""[3,"click",null]"""));
        Eq("routes press: click with an id", "True", PanelWire.RoutesPress(new[] { "click" }, "ap_number", null).ToString());
        Eq("routes press: click with only a plan path", "True", PanelWire.RoutesPress(new[] { "click" }, "", "[0,2,1]").ToString());
        Eq("routes press: click with no address sends nothing", "False", PanelWire.RoutesPress(new[] { "click" }, "", null).ToString());
        Eq("routes press: events without click", "False", PanelWire.RoutesPress(new[] { "click_and_wait" }, "ap_name", null).ToString());
        Eq("routes press: an empty list", "False", PanelWire.RoutesPress(System.Array.Empty<string>(), "t", null).ToString());
        Eq("routes press: no list, an older core, routes nothing", "False", PanelWire.RoutesPress(null, "t", null).ToString());
        Eq("routes press: the name is exact, not a prefix", "False", PanelWire.RoutesPress(new[] { "click_and_wait", "clicks" }, "t", null).ToString());
        // S1 (the dialog door, design §3): a `button`'s face and whether a press
        // can reach the core. A dialog's OK/Cancel carry NO id; the plan path is
        // their address, as a library swatch's is. `icon_button` keeps its rule.
        // Finding K (flask § 568): a `bind: label:` arrives as `bind.label` and
        // replaces every other label, as the web's render_button does.
        Eq("button: a bound label (bind.label) wins over everything", "Add Side",
            PanelWire.ButtonLabel("Add Side", "Save “doc.svg”", "OK", "tip", "b"));
        Eq("button: a bound label with no other label at all", "Add Side",
            PanelWire.ButtonLabel("Add Side", null, null, null, ""));
        Eq("button: an engine-resolved label wins over the literal", "Save “doc.svg”",
            PanelWire.ButtonLabel(null, "Save “doc.svg”", "OK", "tip", "b"));
        Eq("button: the literal label", "OK", PanelWire.ButtonLabel(null, null, "OK", "tip", "b"));
        Eq("button: no label falls back to the summary", "tip", PanelWire.ButtonLabel(null, null, null, "tip", "b"));
        Eq("button: then to the id", "b", PanelWire.ButtonLabel(null, null, null, null, "b"));
        Eq("button: nothing at all is an empty face, never null", "", PanelWire.ButtonLabel(null, null, null, null, ""));
        Eq("clickable: a button by plan path alone, a dialog's OK", "True",
            PanelWire.Clickable("button", "", "[1,0]").ToString());
        Eq("clickable: a button with neither id nor path", "False",
            PanelWire.Clickable("button", "", null).ToString());
        // ⛔ REVERSED on purpose (flask §272): 26 workspace icon_buttons carry no
        // id -- the canvas strip's close box and 23 tool-alternates buttons --
        // and the id rule left every one disabled. A plan path addresses them.
        Eq("clickable: an icon_button by plan path alone, the strip's close box", "True",
            PanelWire.Clickable("icon_button", "", "[1,0,0,1]").ToString());
        Eq("clickable: an icon_button with neither id nor path", "False",
            PanelWire.Clickable("icon_button", "", null).ToString());
        Eq("clickable: a dropdown keeps the id rule (its button sends nothing)", "False",
            PanelWire.Clickable("dropdown", "", "[2]").ToString());
        // #422: every action reply names a tab the SHELL must remove, or null.
        Eq("remove_tab: a reply naming tab 0", "0",
            ActWire.RemoveTab("""{"changed":[],"dialog":null,"doc_changed":false,"remove_tab":0}""")?.ToString() ?? "(null)");
        Eq("remove_tab: a reply naming tab 2", "2",
            ActWire.RemoveTab("""{"changed":[],"dialog":null,"doc_changed":false,"remove_tab":2}""")?.ToString() ?? "(null)");
        Eq("remove_tab: null names none", "(null)",
            ActWire.RemoveTab("""{"changed":[],"dialog":null,"doc_changed":false,"remove_tab":null}""")?.ToString() ?? "(null)");
        Eq("remove_tab: an older engine with no key names none", "(null)",
            ActWire.RemoveTab("""{"changed":[],"doc_changed":false}""")?.ToString() ?? "(null)");
        Eq("remove_tab: a negative or non-integer index names none", "(null)|(null)",
            (ActWire.RemoveTab("""{"remove_tab":-1}""")?.ToString() ?? "(null)") + "|"
            + (ActWire.RemoveTab("""{"remove_tab":"0"}""")?.ToString() ?? "(null)"));
        Eq("remove_tab: unreadable bytes name none", "(null)", ActWire.RemoveTab("{")?.ToString() ?? "(null)");
        // jas §274: this shell holds ONE document (tab 0). A named tab 0 closes it
        // (`jas_document_close`); any other index names a tab this shell does
        // not have, refused by name, never mapped onto tab 0.
        Eq("remove_tab: tab 0 closes the one document", "close", ActWire.Removal(0));
        Eq("remove_tab: another index is no tab this shell holds", "no-such-tab", ActWire.Removal(1));
        Eq("close: 1 closed the document", "closed", ActWire.CloseReading(1));
        Eq("close: 0 found none open", "none-open", ActWire.CloseReading(0));
        Eq("close: 255 had no engine", "no-engine", ActWire.CloseReading(255));
        // jas §300: every act reply names a window close (`"close_window":
        // <bool>`): `quit` with nothing edited, and Save Changes' Don't Save.
        // The shell closes ONLY on a named true, never on a refusal or a guess.
        Eq("close_window: quit with nothing edited closes", "True",
            ActWire.CloseWindow("""{"changed":[],"close_window":true,"dialog":null,"doc_changed":false,"remove_tab":null}""").ToString());
        Eq("close_window: quit with an edit asks first and keeps the window", "False",
            ActWire.CloseWindow("""{"changed":[],"close_window":false,"dialog":"save_changes_window","doc_changed":false,"remove_tab":null}""").ToString());
        Eq("close_window: an older engine with no key keeps the window", "False",
            ActWire.CloseWindow("""{"changed":[],"dialog":null,"doc_changed":false}""").ToString());
        Eq("close_window: a non-boolean keeps the window", "False|False",
            ActWire.CloseWindow("""{"close_window":"true"}""").ToString() + "|"
            + ActWire.CloseWindow("""{"close_window":1}""").ToString());
        Eq("close_window: a refusal's empty reply keeps the window", "False", ActWire.CloseWindow("").ToString());
        Eq("close_window: unreadable bytes keep the window", "False", ActWire.CloseWindow("{").ToString());
        // jas §637 (#733): every act reply carries `"export_pdf": <file name> | null`.
        // A string asks the shell to save the document's PDF (`jas_document_pdf`)
        // under that suggested name; anything else saves nothing.
        Eq("export_pdf: Print's suggested name is read", "Untitled-1.pdf",
            ActWire.ExportPdf("""{"changed":[],"export_pdf":"Untitled-1.pdf","doc_changed":false}""") ?? "(null)");
        Eq("export_pdf: a null saves nothing", "(null)",
            ActWire.ExportPdf("""{"changed":[],"export_pdf":null}""") ?? "(null)");
        Eq("export_pdf: an older engine with no key saves nothing", "(null)",
            ActWire.ExportPdf("""{"changed":[],"doc_changed":false}""") ?? "(null)");
        Eq("export_pdf: a non-string or unreadable reply saves nothing", "(null)|(null)",
            (ActWire.ExportPdf("""{"export_pdf":1}""") ?? "(null)") + "|" + (ActWire.ExportPdf("{not json") ?? "(null)"));
        Check("export_pdf: bytes that open %PDF- are a PDF",
            ActWire.IsPdf(System.Text.Encoding.ASCII.GetBytes("%PDF-1.4 %...")), "");
        Check("export_pdf: empty or non-PDF bytes are not saved",
            !ActWire.IsPdf(Array.Empty<byte>()) && !ActWire.IsPdf(System.Text.Encoding.ASCII.GetBytes("<svg/>")), "");
        // The name is the ENGINE's suggestion, used as a FILE NAME only: a
        // path in it must never steer the write out of the chosen folder.
        Eq("export_pdf: a plain name is kept", "Untitled-1.pdf", ActWire.PdfFileName("Untitled-1.pdf") ?? "(null)");
        Eq("export_pdf: a name with a directory part is refused", "(null)|(null)|(null)",
            (ActWire.PdfFileName("../x.pdf") ?? "(null)") + "|" + (ActWire.PdfFileName(@"C:\t\x.pdf") ?? "(null)")
            + "|" + (ActWire.PdfFileName("a/b.pdf") ?? "(null)"));
        Eq("export_pdf: an empty name is refused", "(null)", ActWire.PdfFileName("") ?? "(null)");

        // jas §642 (#738): every layout reply carries `panes` and
        // `canvas_maximized`; an act reply carries `layout` (the whole layout) or
        // null. The shell SHOWS what they say and decides nothing.
        const string PanesLayout = """{"dock":{"groups":[]},"panes":{"toolbar":false,"canvas":true,"dock":true},"canvas_maximized":false}""";
        var panes = LayoutWire.Panes(PanesLayout);
        Eq("panes: read from a layout", "toolbar=False canvas=True dock=True max=False",
            panes is { } p0 ? $"toolbar={p0.Toolbar} canvas={p0.Canvas} dock={p0.Dock} max={p0.CanvasMaximized}" : "(null)");
        Check("panes: an older layout with no `panes` reads null, never 'all hidden'",
            LayoutWire.Panes("""{"dock":{"groups":[]}}""") is null, "");
        Check("panes: a non-bool member reads null",
            LayoutWire.Panes("""{"panes":{"toolbar":"no","canvas":true,"dock":true},"canvas_maximized":false}""") is null, "");
        Check("panes: unreadable bytes read null", LayoutWire.Panes("{nope") is null, "");
        Eq("layout: an act reply's layout is passed on whole", PanesLayout,
            ActWire.Layout("{\"changed\":[],\"layout\":" + PanesLayout + "}") ?? "(null)");
        Eq("layout: a null layout (no layout effect ran) is none", "(null)",
            ActWire.Layout("""{"changed":[],"layout":null}""") ?? "(null)");
        Eq("layout: an older engine with no key is none", "(null)",
            ActWire.Layout("""{"changed":[]}""") ?? "(null)");

        // jas §644/#753: a key pressed in a focused PANEL goes to the panel door,
        // `{"panel": <content id>, "key", "mods"}`, which resolves the panel's
        // own `keyboard:` rows. Only the keys those rows bind are forwarded; an
        // unbound one comes back `UnboundPanelKey` and goes on to the document.
        var pk = System.Text.Json.JsonDocument.Parse(KeyWire.Request("ArrowDown", false, false, false, "layers_panel_content")!);
        Eq("panel key: the request names its panel", "layers_panel_content",
            pk.RootElement.TryGetProperty("panel", out var pkp) ? pkp.GetString() ?? "(null)" : "(absent)");
        Eq("panel key: ...and its key", "ArrowDown", pk.RootElement.GetProperty("key").GetString() ?? "");
        var dk = System.Text.Json.JsonDocument.Parse(KeyWire.Request("Delete", false, false, false)!);
        Check("panel key: a document key names no panel", !dk.RootElement.TryGetProperty("panel", out _), "");
        Eq("panel key: F2 is named", "F2", KeyWire.Name(0xF705) ?? "(null)");
        Check("panel key: the arrows, F2, Enter, Escape, Delete and Backspace are forwarded",
            new uint[] { 0xF700, 0xF701, 0xF702, 0xF703, 0xF705, 0x0D, 0x1B, 0x7F, 0x08 }.All(c => PanelKeys.Forwards(c, ctrl: false)), "");
        Check("panel key: Ctrl+A is forwarded (the tree's select-all)", PanelKeys.Forwards('a', ctrl: true), "");
        Check("panel key: a plain letter is not (it is the document's shortcut)", !PanelKeys.Forwards('a', ctrl: false), "");
        Check("panel key: Ctrl+Z is not (undo stays the document's)", !PanelKeys.Forwards('z', ctrl: true), "");
        Check("panel key: Home and Tab are not", !PanelKeys.Forwards(0xF729, false) && !PanelKeys.Forwards(0x09, false), "");
        Check("panel key: an UnboundPanelKey refusal is read",
            KeyWire.UnboundPanelKey("""{"panel_event":"UnboundPanelKey","detail":"Delete"}"""), "");
        Check("panel key: any other refusal is not",
            !KeyWire.UnboundPanelKey("""{"panel_event":"KeyUnhandled","detail":"x"}""") && !KeyWire.UnboundPanelKey(""), "");
        // Which columns show: a pane is shown when the engine says so and the
        // canvas is not maximized (maximized gives the canvas the whole width).
        Eq("panes: the toolbar hidden, the dock shown", "toolbar=False dock=True",
            PaneRule.Shown(new PaneState(false, true, true, false)) is var s1 ? $"toolbar={s1.Toolbar} dock={s1.Dock}" : "");
        Eq("panes: maximized hides both side columns", "toolbar=False dock=False",
            PaneRule.Shown(new PaneState(true, true, true, true)) is var s2 ? $"toolbar={s2.Toolbar} dock={s2.Dock}" : "");
        Eq("panes: all shown", "toolbar=True dock=True",
            PaneRule.Shown(new PaneState(true, true, true, false)) is var s3 ? $"toolbar={s3.Toolbar} dock={s3.Dock}" : "");

        // jas §364 (plan § 5 slice 8): every act reply carries
        // `"clipboard_write": <text> | null`. A string goes on the system
        // clipboard UNCHANGED; anything else writes nothing.
        Eq("clipboard_write: Copy's text is read unchanged", "{\"a\":1}\n\u00e9",
            ActWire.ClipboardWrite("{\"changed\":[],\"clipboard_write\":\"{\\\"a\\\":1}\\n\u00e9\",\"doc_changed\":false}") ?? "(null)");
        Eq("clipboard_write: a null writes nothing", "(null)",
            ActWire.ClipboardWrite("""{"changed":[],"clipboard_write":null,"doc_changed":false}""") ?? "(null)");
        Eq("clipboard_write: an older engine with no key writes nothing", "(null)",
            ActWire.ClipboardWrite("""{"changed":[],"doc_changed":false}""") ?? "(null)");
        Eq("clipboard_write: a non-string writes nothing", "(null)|(null)",
            (ActWire.ClipboardWrite("""{"clipboard_write":1}""") ?? "(null)") + "|"
            + (ActWire.ClipboardWrite("""{"clipboard_write":{"text":"x"}}""") ?? "(null)"));
        Eq("clipboard_write: an empty reply or unreadable bytes write nothing", "(null)|(null)",
            (ActWire.ClipboardWrite("") ?? "(null)") + "|" + (ActWire.ClipboardWrite("{") ?? "(null)"));
        Eq("clipboard_write: an empty string is a string, written as it is", "",
            ActWire.ClipboardWrite("""{"clipboard_write":""}""") ?? "(null)");
        // A paste with no `clipboard` field is refused, nothing run, with
        // `{"panel_event":"NeedsClipboard","detail":"<action>"}` on the error
        // channel. The reader names the action, or null for any other channel.
        Eq("needs clipboard: the refusal names its action", "menu_paste",
            ActWire.NeedsClipboard("""{"panel_event":"NeedsClipboard","detail":"menu_paste"}""") ?? "(null)");
        Eq("needs clipboard: another refusal is not it", "(null)|(null)",
            (ActWire.NeedsClipboard("""{"panel_event":"KeyUnhandled","detail":"v"}""") ?? "(null)") + "|"
            + (ActWire.NeedsClipboard("""{"panel_event":"Unchanged","detail":"NeedsClipboard"}""") ?? "(null)"));
        Eq("needs clipboard: a clear or unreadable channel is not it", "(null)|(null)",
            (ActWire.NeedsClipboard("") ?? "(null)") + "|" + (ActWire.NeedsClipboard("{") ?? "(null)"));
        Eq("needs clipboard: a refusal with no detail still asks, unnamed", "",
            ActWire.NeedsClipboard("""{"panel_event":"NeedsClipboard"}""") ?? "(null)");
        // The resend is THE SAME request with `clipboard` added: the text, or
        // a JSON null when the clipboard holds none or the read threw.
        Eq("with clipboard: the text is added to the same request",
            """{"menu_item":"paste","clipboard":"a\"b\n"}""",
            ActWire.WithClipboard("""{"menu_item":"paste"}""", "a\"b\n"));
        Eq("with clipboard: no text is a JSON null",
            """{"key":"v","mods":{"shift":false,"alt":false,"ctrl":true},"clipboard":null}""",
            ActWire.WithClipboard("""{"key":"v","mods":{"shift":false,"alt":false,"ctrl":true}}""", null));
        Eq("with clipboard: a second read replaces the first, never two keys",
            """{"menu_item":"paste","clipboard":"new"}""",
            ActWire.WithClipboard("""{"menu_item":"paste","clipboard":"old"}""", "new"));
        // Never retry silently, and never twice: a request that already
        // carried the clipboard and is refused for it again is a failure.
        Eq("clipboard step: a refusal for the clipboard reads it", "read",
            ActWire.ClipboardStep("menu_paste", carried: false));
        Eq("clipboard step: refused again after carrying it is a failure", "refused-again",
            ActWire.ClipboardStep("menu_paste", carried: true));
        Eq("clipboard step: any other refusal reads nothing", "none|none",
            ActWire.ClipboardStep(null, carried: false) + "|" + ActWire.ClipboardStep(null, carried: true));
        // jas §314: a key goes to the engine as `{"key": <name>, "mods": {...}}`
        // through `jas_dispatch_action`; the engine resolves it, the shell holds
        // no binding. Every flag is written, true or false.
        Eq("key: Delete with no modifier", """{"key":"Delete","mods":{"shift":false,"alt":false,"ctrl":false}}""",
            KeyWire.Request("Delete", shift: false, alt: false, ctrl: false));
        Eq("key: Ctrl+Shift+z", """{"key":"z","mods":{"shift":true,"alt":false,"ctrl":true}}""",
            KeyWire.Request("z", shift: true, alt: false, ctrl: true));
        Eq("key: a quote is escaped as JSON", """{"key":"\"","mods":{"shift":false,"alt":true,"ctrl":false}}""",
            KeyWire.Request("\"", shift: false, alt: true, ctrl: false));
        Eq("key: an empty name is no request", "(null)", KeyWire.Request("", false, false, false) ?? "(null)");
        // flask §556 finding H: a refused command chord names its menu action,
        // which the shell runs; nothing else is read as one.
        Eq("key: a refused chord names its menu action", "save",
            KeyWire.MenuAction("""{"panel_event":"KeyUnhandled","detail":"s","menu_action":"save","params":{}}""") ?? "(null)");
        Eq("key: an unhandled key with no action names none", "(null)",
            KeyWire.MenuAction("""{"panel_event":"KeyUnhandled","detail":"k"}""") ?? "(null)");
        Eq("key: another refusal class is never a menu action", "(null)",
            KeyWire.MenuAction("""{"panel_event":"BadKey","detail":"s","menu_action":"save"}""") ?? "(null)");
        Eq("key: an empty or unreadable channel names none", "(null)|(null)|(null)",
            (KeyWire.MenuAction("") ?? "(null)") + "|" + (KeyWire.MenuAction("not json") ?? "(null)")
            + "|" + (KeyWire.MenuAction("""{"panel_event":"KeyUnhandled","menu_action":7}""") ?? "(null)"));
        // The gradient slider's picture (gradient.yaml grad_slider), DISPLAY ONLY
        // as in every port: `bind.stops` is the plan's JSON text, each stop
        // {color, location, midpoint_to_next?, opacity}, keys in any order.
        const string twoStops = """[{"color":"#000000","location":0,"midpoint_to_next":50,"opacity":100},{"color":"#ffffff","location":100,"opacity":100}]""";
        Eq("gradient: two stops parse with their fields", "#000000@0/50/100|#ffffff@100/50/100",
            string.Join("|", GradientSliderWire.Stops(twoStops)!.Select(st => $"{st.Color}@{st.Location}/{st.Midpoint}/{st.Opacity}")));
        Eq("gradient: a midpoint sits between its pair, at midpoint_to_next %", "0|25|80",
            string.Join("|", new[] { (0.0, 100.0, 0.0), (0.0, 50.0, 50.0), (60.0, 100.0, 50.0) }
                .Select(t => GradientSliderWire.MidpointLocation(new GradientSliderWire.Stop("#000000", 100, t.Item1, t.Item3),
                                                                 new GradientSliderWire.Stop("#000000", 100, t.Item2, 50)).ToString())));
        Eq("gradient: a percentage outside 0..100 is REFUSED, never clamped, and so is an unparsable list", "(null)|(null)|(null)|(null)|(null)",
            (GradientSliderWire.Stops("""[{"color":"#000000","location":-5},{"color":"#000000","location":40}]""")?.Count.ToString() ?? "(null)")
            + "|" + (GradientSliderWire.Stops("""[{"color":"#000000","location":0,"opacity":140},{"color":"#000000","location":40}]""")?.Count.ToString() ?? "(null)")
            + "|" + (GradientSliderWire.Stops("not json")?.Count.ToString() ?? "(null)")
            + "|" + (GradientSliderWire.Stops("""{"color":"#000000"}""")?.Count.ToString() ?? "(null)")
            + "|" + (GradientSliderWire.Stops("""[{"location":5}]""")?.Count.ToString() ?? "(null)"));
        Eq("gradient: the selected index reads -1 when absent or not a number", "0|-1|-1|2",
            $"{GradientSliderWire.Index("0")}|{GradientSliderWire.Index("-1")}|{GradientSliderWire.Index(null)}|{GradientSliderWire.Index("2")}");
        // Node 3b (council 10-21 ⑤): the pointer's DIPs as the gesture's RAW
        // parameters. The plan's slider is 24 DIP tall; at 200 wide the stop
        // radius is 4.8, the diamond 6, the bar's top 7, its width 190.4 and its
        // height 7.4, so its centre line is at 10.7. Expected values are from a
        // Python mirror of LayoutOf/Point, rounded to 6 places for the print.
        static string R6(double v) => Math.Round(v, 6).ToString(System.Globalization.CultureInfo.InvariantCulture);
        var slider = GradientSliderWire.LayoutOf(200, 24);
        Eq("gradient pointer: the layout at 200 x 24", "4.8|6|7|190.4|7.4",
            slider is { } sl ? $"{R6(sl.R)}|{R6(sl.D)}|{R6(sl.BarTop)}|{R6(sl.BarW)}|{R6(sl.BarH)}" : "(null)");
        string PointAt(double x, double y) =>
            slider is { } sl2 && GradientSliderWire.Point(sl2, x, y) is var (loc, dy) ? $"{R6(loc)}|{R6(dy)}" : "(null)";
        string RoundTrip(double loc) => slider is { } sl3 ? PointAt(GradientSliderWire.At(sl3, loc), 10.7) : "(null)";
        Eq("gradient pointer: a stop drawn at 0, 30 and 100 reads back its location, on the centre line",
            "0|0 30|0 100|0", $"{RoundTrip(0)} {RoundTrip(30)} {RoundTrip(100)}");
        Eq("gradient pointer: the surface's top-left corner is past the bar's start and above it, NOT clamped",
            "-2.521008|-10.7", PointAt(0, 0));
        Eq("gradient pointer: past the bar's end and below it, NOT clamped", "102.521008|20", PointAt(200, 30.7));
        Eq("gradient pointer: a rect with no room for a bar takes no gesture", "(null)|(null)",
            (GradientSliderWire.LayoutOf(9.6, 24) is null ? "(null)" : "layout") + "|"
            + (GradientSliderWire.LayoutOf(200, 2) is null ? "(null)" : "layout"));
        // Desk AED (flask §520): the diamond is drawn 6 DIP and was its own hit
        // area, so a press 3 DIP right of its centre on its middle row missed.
        // The target is the band above the bar, MidpointTarget wide, centred on
        // the diamond; the nearer diamond takes a press where two overlap. At
        // 200 x 24 the band is y 0..7 and a [0 100] pair's diamond is at x 100.
        var gStops = GradientSliderWire.Stops("""[{"color":"#000000","location":0},{"color":"#ffffff","location":100}]""")!;
        string MidAt(IReadOnlyList<GradientSliderWire.Stop> st, double x, double y) =>
            slider is { } sl4 ? GradientSliderWire.MidpointAt(sl4, st, x, y)?.ToString() ?? "(null)" : "(no layout)";
        // flask §527/§533: the drawn diamond is 6 DIP rotated 45°, so its top
        // corner reaches DiamondOverhang = 6 (√2 − 1) / 2 ≈ 1.242641 DIP above
        // the rect; the target reaches up with it, and no further.
        Eq("gradient target: the diamond's corner overhang above the rect",
            "1.242641", slider is { } sl5 ? GradientSliderWire.DiamondOverhang(sl5).ToString("0.######", System.Globalization.CultureInfo.InvariantCulture) : "(no layout)");
        Eq("gradient target: the rows above the rect where the corner is drawn hit, and above the corner nothing does",
            "0|0|(null)|(null)", $"{MidAt(gStops, 100, -1.2)}|{MidAt(gStops, 100, -1.24)}|{MidAt(gStops, 100, -1.25)}|{MidAt(gStops, 100, -2)}");
        Eq("gradient target: §520's misses now hit (+3,+3 middle row; +2,+0 top row) and the centre still does",
            "0|0|0", $"{MidAt(gStops, 103, 3)}|{MidAt(gStops, 102, 0)}|{MidAt(gStops, 100, 3)}");
        Eq("gradient target: half the target either side, and no further", "0|0|(null)|(null)",
            $"{MidAt(gStops, 100 - GradientSliderWire.MidpointTarget / 2, 3)}|{MidAt(gStops, 100 + GradientSliderWire.MidpointTarget / 2, 3)}"
            + $"|{MidAt(gStops, 100 - GradientSliderWire.MidpointTarget / 2 - 0.5, 3)}|{MidAt(gStops, 100 + GradientSliderWire.MidpointTarget / 2 + 0.5, 3)}");
        Eq("gradient target: the bar's top row is the bar's (add), never a diamond's", "(null)|(null)",
            $"{MidAt(gStops, 100, 7)}|{MidAt(gStops, 100, 12)}");
        // Stops 0, 5, 10: diamonds at x 9.56 and 19.08, 9.52 apart, so the targets overlap.
        var close = GradientSliderWire.Stops("""[{"color":"#000000","location":0},{"color":"#808080","location":5},{"color":"#ffffff","location":10}]""")!;
        Eq("gradient target: overlapping targets go to the NEARER diamond, both ways", "0|1|0|1",
            $"{MidAt(close, 14, 3)}|{MidAt(close, 15, 3)}|{MidAt(close, 9.56, 3)}|{MidAt(close, 19.08, 3)}");
        var drag =Parse(PanelWire.GestureJson("grad_slider", "drag",
            new Dictionary<string, object> { ["location"] = 30.5, ["dy"] = -2.0 }, false, true, false, false, "[0,3]"));
        Check("gradient gesture: value is an OBJECT of numbers, beside the widget, event, modifiers and path",
            drag is not null
            && Str(drag, "widget") == "grad_slider" && Str(drag, "event") == "drag" && Bool(drag, "shift") == true
            && drag.RootElement.TryGetProperty("value", out var dv) && dv.ValueKind == System.Text.Json.JsonValueKind.Object
            && dv.TryGetProperty("location", out var dl) && dl.ValueKind == System.Text.Json.JsonValueKind.Number && dl.GetDouble() == 30.5
            && dv.TryGetProperty("dy", out var ddy) && ddy.GetDouble() == -2.0
            && drag.RootElement.TryGetProperty("path", out var dp) && dp.GetArrayLength() == 2, Show(drag));
        var pressStop = Parse(PanelWire.GestureJson("grad_slider", "press",
            new Dictionary<string, object> { ["index"] = 1 }, false, false, false, false));
        Check("gradient gesture: a press's index crosses as an INTEGER (the engine reads it with as_i64)",
            pressStop is not null && pressStop.RootElement.TryGetProperty("value", out var pv)
            && pv.TryGetProperty("index", out var pi) && pi.TryGetInt64(out var piv) && piv == 1
            && pi.GetRawText() == "1", Show(pressStop));
        // The slider's keys (GRADIENT.md's keyboard table), by the VirtualKey's
        // NAME, as the web's `slider_key` names them: the arrows, Home and End,
        // and both deletes. Any other key names nothing and is left to the window.
        Eq("gradient keys: the table's keys by name", "Left|Right|Home|End|Delete|Backspace",
            string.Join("|", new[] { "Left", "Right", "Home", "End", "Delete", "Back" }
                .Select(k => GradientSliderWire.KeyName(k) ?? "(null)")));
        Eq("gradient keys: anything else names nothing", "(null)|(null)|(null)",
            string.Join("|", new[] { "Up", "A", "" }.Select(k => GradientSliderWire.KeyName(k) ?? "(null)")));
        Eq("gradient gesture: the row token is the compact object", "{\"location\":30.5,\"dy\":-2}",
            PanelWire.GestureRowValue(new Dictionary<string, object> { ["location"] = 30.5, ["dy"] = -2.0 }));
        // The shell's named keys, by the code `OnKeyDown` sends (`JasCore.Key*`).
        // Tab is 0x09, a CONTROL character, so the character fallback names it
        // nothing: before Tab was in this table it reached `ApplyKey` as
        // `RUSTFAIL KEY UNNAMED` and the engine never saw it.
        var named = new (uint Code, string Name)[]
        {
            (0x08, "Backspace"), (0x09, "Tab"), (0x0D, "Enter"), (0x1B, "Escape"), (0x7F, "Delete"),
            (0xF700, "ArrowUp"), (0xF701, "ArrowDown"), (0xF702, "ArrowLeft"), (0xF703, "ArrowRight"),
            (0xF729, "Home"), (0xF72B, "End"),
        };
        Eq("key name: each named code is its engine key name",
            string.Join("|", named.Select(n => n.Name)),
            string.Join("|", named.Select(n => KeyWire.Name(n.Code) ?? "(null)")));
        Eq("key name: the eleven names are pairwise distinct", "11",
            named.Select(n => KeyWire.Name(n.Code)).Distinct().Count().ToString());
        Eq("key name: Tab is not a character, so only the table names it", "(null)|Tab",
            (KeyWire.CharName(0x09) ?? "(null)") + "|" + (KeyWire.Name(0x09) ?? "(null)"));
        Eq("key name: any other code is the character it produced, or none", "O|(null)",
            (KeyWire.Name('O') ?? "(null)") + "|" + (KeyWire.Name(0x07) ?? "(null)"));
        // Tab goes to the engine only from the CANVAS's focus, as on the web
        // (`keyboard.rs`: Tab on a widget is the platform's focus traversal).
        Eq("tab: sent and kept from the canvas, left to the platform elsewhere", "True|False",
            KeyWire.TakesTab(fromCanvas: true) + "|" + KeyWire.TakesTab(fromCanvas: false));
        // FP-3: the dock is drawn from the ENGINE's layout (`jas_layout_state`),
        // its first anchored dock read strictly: a group is its panels (content
        // ids), its active index and its collapsed flag, all the engine's.
        const string state = """{"name":"Default","anchored":[{"id":0,"edge":"right","collapsed":false,"width":240.0,"groups":[{"panels":["color_panel_content","swatches_panel_content"],"active":1,"collapsed":false},{"panels":["layers_panel_content"],"active":0,"collapsed":true}]}],"floating":[],"z_order":[]}""";
        var dock = LayoutWire.Dock(state);
        Eq("layout: the anchored dock's id and groups read back", "0|color_panel_content,swatches_panel_content@1/False|layers_panel_content@0/True",
            dock is null ? "(null)" : dock.DockId + "|" + string.Join("|", dock.Groups.Select(g => $"{string.Join(",", g.Panels)}@{g.Active}/{g.Collapsed}")));
        // Each refusal is the control with ONE defect, so a reader that refused
        // everything could not pass (the control above reads).
        var defects = new[]
        {
            state.Replace("\"active\":1", "\"active\":2"),
            state.Replace("[\"layers_panel_content\"]", "[]"),
            state.Replace(",\"collapsed\":true}", "}"),
            state.Replace("\"anchored\":[{", "\"anchored\":[],\"x\":[{"),
            "not json",
            "",
        };
        Eq("layout: an out-of-range active, an empty group, a missing flag, no dock, bad JSON are each refused",
            string.Join("|", defects.Select(_ => "(null)")),
            string.Join("|", defects.Select(d => LayoutWire.Dock(d) is null ? "(null)" : "read")));
        // FP-4a: floating docks, drawn in the engine's stacking order (`z`
        // ascending, ties in the engine's list order); the shell holds no law.
        const string floats = """{"name":"Default","anchored":[{"id":0,"edge":"right","collapsed":false,"width":240.0,"groups":[{"panels":["color_panel_content"],"active":0,"collapsed":false}]}],"floating":[{"id":2,"collapsed":false,"width":240.0,"groups":[{"panels":["align_panel_content","boolean_panel_content"],"active":1,"collapsed":false}],"x":100.0,"y":50.5,"z":1},{"id":3,"collapsed":false,"width":200.0,"groups":[{"panels":["layers_panel_content"],"active":0,"collapsed":false}],"x":-20.0,"y":0.0,"z":0}],"z_order":[3,2]}""";
        var fl = LayoutWire.Floating(floats);
        Eq("floating: back to front by z, each with its position, width and groups", "3@-20,0w200:layers_panel_content|2@100,50.5w240:align_panel_content,boolean_panel_content",
            fl is null ? "(null)" : string.Join("|", fl.Select(f => FormattableString.Invariant($"{f.DockId}@{f.X},{f.Y}w{f.Width}:{string.Join(",", f.Groups.SelectMany(g => g.Panels))}"))));
        Eq("floating: no floating docks is an empty list, not a refusal", "0",
            LayoutWire.Floating(state)?.Count.ToString() ?? "(null)");
        var floatDefects = new[]
        {
            floats.Replace(",\"x\":100.0", ""),
            floats.Replace(",\"z\":0}", "}"),
            floats.Replace("\"active\":1", "\"active\":5"),
            floats.Replace("\"floating\":[{", "\"floating\":{\"a\":[{").Replace("],\"z_order\"", "]},\"z_order\""),
        };
        Eq("floating: a missing x, a missing z, an active outside its group, a floating that is not a list are each refused",
            string.Join("|", floatDefects.Select(_ => "(null)")),
            string.Join("|", floatDefects.Select(d => LayoutWire.Floating(d) is null ? "(null)" : "read")));
        Eq("floating: the four ops are the engine's verbs, addressed by dock id",
            """{"op":"bring_to_front","dock_id":2}|{"op":"set_floating_position","dock_id":2,"x":12.5,"y":-3}|{"op":"redock","dock_id":2}|{"op":"detach_group","dock_id":0,"group_idx":1,"x":300,"y":40}""",
            string.Join("|", LayoutWire.BringToFront(2), LayoutWire.SetFloatingPosition(2, 12.5, -3), LayoutWire.Redock(2), LayoutWire.DetachGroup(0, 1, 300, 40)));
        // FP-5: a tab or a group strip dragged out of the dock and released over
        // the canvas tears out. A press that barely moved is a click, and a release
        // outside the canvas cell (back over the dock) is no drop.
        Eq("tear-out: past the threshold and inside the canvas, and not otherwise",
            "True|False|False|False|False|True",
            string.Join("|", new[]
            {
                LayoutWire.TearsOut(dx: 30, dy: 0, x: 400, y: 300, w: 800, h: 600),
                LayoutWire.TearsOut(dx: 3, dy: 4, x: 400, y: 300, w: 800, h: 600),
                LayoutWire.TearsOut(dx: 30, dy: 0, x: 801, y: 300, w: 800, h: 600),
                LayoutWire.TearsOut(dx: 30, dy: 0, x: -1, y: 300, w: 800, h: 600),
                LayoutWire.TearsOut(dx: 30, dy: 0, x: 400, y: 601, w: 800, h: 600),
                LayoutWire.TearsOut(dx: 0, dy: -9, x: 0, y: 0, w: 800, h: 600),
            }));
        Eq("tear-out: a tab's op is detach_panel, with no viewport (the shell draws one anchored dock, so it never snaps)",
            """{"op":"detach_panel","dock_id":0,"group_idx":2,"panel_idx":1,"x":350.5,"y":40}""",
            LayoutWire.DetachPanel(0, 2, 1, 350.5, 40));
        Eq("clamp: the window's resize sends the engine's clamp with the canvas cell's size",
            """{"op":"clamp_floating_docks","viewport_w":1024.5,"viewport_h":600}""", LayoutWire.ClampFloatingDocks(1024.5, 600));
        Eq("floating: a floating group's pane key never starts with `dock`", "float2g0|float13g4",
            LayoutWire.FloatKey(2, 0) + "|" + LayoutWire.FloatKey(13, 4));
        Eq("layout: the chevron's op is the engine's toggle verb, addressed by dock and group",
            """{"op":"toggle_group_collapsed","dock_id":3,"group_idx":1}""", LayoutWire.ToggleCollapsed(3, 1));
        Eq("key: a character name is that one character, a control character none", "O|=|(null)|(null)",
            (KeyWire.CharName('O') ?? "(null)") + "|" + (KeyWire.CharName('=') ?? "(null)") + "|"
            + (KeyWire.CharName(0x07) ?? "(null)") + "|" + (KeyWire.CharName(0x7F) ?? "(null)"));
        // jas §305: Save All names `"save_all_then_close": <bool>`, never with
        // `close_window`. The SHELL saves every modified document, then closes
        // only if every save succeeded. Only a named true acts.
        Eq("save_all_then_close: Save All names it", "True",
            ActWire.SaveAllThenClose("""{"changed":[],"close_window":false,"dialog":null,"doc_changed":false,"remove_tab":null,"save_all_then_close":true}""").ToString());
        Eq("save_all_then_close: a false, a missing key or a non-boolean names none", "False|False|False",
            ActWire.SaveAllThenClose("""{"save_all_then_close":false}""").ToString() + "|"
            + ActWire.SaveAllThenClose("""{"close_window":true}""").ToString() + "|"
            + ActWire.SaveAllThenClose("""{"save_all_then_close":"true"}""").ToString());
        Eq("save_all_then_close: a refusal or unreadable bytes name none", "False|False",
            ActWire.SaveAllThenClose("").ToString() + "|" + ActWire.SaveAllThenClose("{").ToString());
        Eq("save_all_then_close: close_window alone is not a save", "False",
            ActWire.SaveAllThenClose("""{"close_window":true,"save_all_then_close":null}""").ToString());
        // What Save All does with this shell's ONE document.
        Eq("save all: no document open closes at once", "close", ActWire.SaveAllStep(documentOpen: false, modified: true));
        Eq("save all: an unmodified document closes at once", "close", ActWire.SaveAllStep(documentOpen: true, modified: false));
        Eq("save all: a modified document is saved first", "save", ActWire.SaveAllStep(documentOpen: true, modified: true));
        // After the save: close only if it wrote the file.
        Eq("save all: a written save closes", "close", ActWire.AfterSaveAll(saved: true));
        Eq("save all: a failed save keeps the window", "keep", ActWire.AfterSaveAll(saved: false));
        Eq("close: any other byte is no answer, never a guess", "unknown(7)", ActWire.CloseReading(7));
        Eq("clickable: an icon_button with an id", "True",
            PanelWire.Clickable("icon_button", "tb_rect", null).ToString());
        // S3 (jas §282, #429): the two radio kinds' events. `radio` is a check
        // kind (`click`); `radio_group` an option kind (`toggle` carrying the
        // option's id). The engine refuses a press on the checked one
        // (`AlreadyChecked`); the shell never decides that itself.
        // jas §287 (#434): a `reference_point_widget` plans its kind's nine
        // anchors as option rows; the face lays any perfect-square count out as
        // a square grid, row by row, and refuses any other count.
        // #431: an `icon_button_group`'s option rows name an `icon`, which the
        // plan's `icons` map carries; the reader keeps the name, or null.
        var iconRows = PanelWire.ReadOptions("""[{"kind":"option","value":"portrait","label":"portrait","icon":"orientation_portrait","selected":false},{"kind":"option","value":"x","label":"x","selected":true}]""");
        Eq("options: a row's icon is read", "orientation_portrait", iconRows?.Items[0].Icon ?? "(null)");
        Eq("options: a row with no icon reads none", "(null)", iconRows?.Items[1].Icon ?? "(null)");
        Eq("icon group: two buttons in a 56x28 rect are 28 square", "28", PanelWire.GroupCellSide(56, 28, 2).ToString());
        Eq("icon group: a narrow rect shares its width", "20", PanelWire.GroupCellSide(40, 28, 2).ToString());
        Eq("icon group: no options is no cell", "0", PanelWire.GroupCellSide(56, 28, 0).ToString());
        Eq("grid: nine rows are three columns", "3", PanelWire.GridColumns(9)?.ToString() ?? "(null)");
        Eq("grid: four rows are two columns", "2", PanelWire.GridColumns(4)?.ToString() ?? "(null)");
        Eq("grid: one row is one column", "1", PanelWire.GridColumns(1)?.ToString() ?? "(null)");
        Eq("grid: no rows is no grid", "(null)", PanelWire.GridColumns(0)?.ToString() ?? "(null)");
        Eq("grid: eight rows are no square, refused", "(null)", PanelWire.GridColumns(8)?.ToString() ?? "(null)");
        Eq("grid: the sixth row (middle_right) sits at row 1, column 2", "1|2",
            PanelWire.GridCell(5, 3) is var (gr, gc) ? $"{gr}|{gc}" : "");
        Eq("grid: the last row (bottom_right) sits at row 2, column 2", "2|2",
            PanelWire.GridCell(8, 3) is var (lr, lc) ? $"{lr}|{lc}" : "");
        Eq("radio: a radio sends click, no value", "click|(null)",
            PanelWire.RadioEvent("radio", "x") is var (re, rv) ? $"{re}|{rv ?? "(null)"}" : "");
        Eq("radio: a radio_group sends toggle with the option's id", "toggle|s",
            PanelWire.RadioEvent("radio_group", "s") is var (ge, gv) ? $"{ge}|{gv ?? "(null)"}" : "");
        var radioRows = PanelWire.ReadOptions("""[{"kind":"option","value":"h","label":"","selected":true}]""");
        Eq("radio_group: a one-option row with an empty label is read, not refused", "1|0|True",
            radioRows is null ? "(null)" : $"{radioRows.Items.Count}|{radioRows.Refused}|{radioRows.Items[0].Selected}");
        Eq("radio_group: an empty label is shown empty, never the option's id", "",
            radioRows is null ? "(null)" : PanelWire.RadioFace(radioRows.Items[0]));
        Eq("radio_group: a label is shown as sent", "Fit",
            PanelWire.ReadOptions("""[{"kind":"option","value":"fit","label":"Fit","selected":false}]""") is { } fr ? PanelWire.RadioFace(fr.Items[0]) : "(null)");
        // S3 (jas §279): a `separator`'s rule. The plan carries no orientation
        // (not a STATIC_KEY), so the rule follows the rect the plan placed:
        // wider than tall is horizontal, else vertical; an empty rect is none.
        // jas §293 (#439): a declared `orientation` wins over the rect's shape;
        // the shape rule is only for a separator that declares none.
        Eq("separator: a declared vertical rule in a wide rect is vertical", "vertical", PanelWire.SeparatorRule("vertical", 300, 9) ?? "(null)");
        Eq("separator: a declared horizontal rule in a tall rect is horizontal", "horizontal", PanelWire.SeparatorRule("horizontal", 1, 16) ?? "(null)");
        Eq("separator: an unknown orientation draws nothing, never a guess", "(null)", PanelWire.SeparatorRule("diagonal", 300, 9) ?? "(null)");
        Eq("separator: a declared rule in an empty rect draws nothing", "(null)", PanelWire.SeparatorRule("vertical", 0, 16) ?? "(null)");
        Eq("separator: a wide rect is a horizontal rule", "horizontal", PanelWire.SeparatorRule(null, 300, 9) ?? "(null)");
        Eq("separator: a tall rect is a vertical rule (the picker's swatch rule)", "vertical", PanelWire.SeparatorRule(null, 1, 16) ?? "(null)");
        Eq("separator: a square rect is horizontal", "horizontal", PanelWire.SeparatorRule(null, 8, 8) ?? "(null)");
        Eq("separator: an empty rect draws nothing", "(null)|(null)",
            (PanelWire.SeparatorRule(null, 0, 9) ?? "(null)") + "|" + (PanelWire.SeparatorRule(null, 300, 0) ?? "(null)"));
        // S2 (the dialog door): `jas_dialog_plan`'s reply (#419) and the `dialog`
        // an act's reply names (#414). A reply the shell cannot read is NULL,
        // never a closed dialog: "closed" would hide a dialog the engine holds.
        var shut = DialogWire.Read("""{"open":false}""");
        Eq("dialog: closed reads closed", "False", shut is null ? "(null)" : shut.Open.ToString());
        var open = DialogWire.Read("""
            {"open":true,"id":"save_changes_tab","summary":"Save changes?","modal":true,"depth":2,
             "plan":{"height":66,"leaves":[],"icons":{}}}
            """);
        Eq("dialog: open reads its id, summary, modal and depth", "True|save_changes_tab|Save changes?|True|2",
            open is null ? "(null)" : $"{open.Open}|{open.Id}|{open.Summary}|{open.Modal}|{open.Depth}");
        Eq("dialog: the plan is passed on as the planner wrote it", "66",
            open?.PlanJson is { } pj ? System.Text.Json.JsonDocument.Parse(pj).RootElement.GetProperty("height").GetRawText() : "(null)");
        Eq("dialog: a summary the engine sent as null is the id", "save_changes_tab",
            DialogWire.Read("""{"open":true,"id":"save_changes_tab","summary":null,"modal":true,"depth":1,"plan":{}}""")?.Summary ?? "(null)");
        Eq("dialog: open with no plan is unreadable, never closed", "(null)",
            DialogWire.Read("""{"open":true,"id":"x","depth":1}""")?.Open.ToString() ?? "(null)");
        Eq("dialog: open with no id is unreadable", "(null)",
            DialogWire.Read("""{"open":true,"depth":1,"plan":{}}""")?.Open.ToString() ?? "(null)");
        Eq("dialog: the empty span is unreadable", "(null)", DialogWire.Read("")?.Open.ToString() ?? "(null)");
        Eq("dialog: bytes that are not JSON are unreadable", "(null)", DialogWire.Read("{open")?.Open.ToString() ?? "(null)");
        // jas §271: the reply carries the dialog's DECLARED width, or null (18 of
        // 33 declare none, and the web sizes those to content). The shell plans
        // at the declared width, else at its own default.
        Eq("dialog width: a declared width is read", "460",
            DialogWire.Read("""{"open":true,"id":"document_setup","depth":1,"width":460,"plan":{}}""")?.Width?.ToString() ?? "(null)");
        Eq("dialog width: null is no declared width", "(null)",
            DialogWire.Read("""{"open":true,"id":"x","depth":1,"width":null,"plan":{}}""")?.Width?.ToString() ?? "(null)");
        Eq("dialog width: an older engine with no key is no declared width, and the dialog still reads", "True|(null)",
            DialogWire.Read("""{"open":true,"id":"x","depth":1,"plan":{}}""") is { } nw ? $"{nw.Open}|{nw.Width?.ToString() ?? "(null)"}" : "(null)");
        Eq("dialog width: zero or negative is no width", "(null)|(null)",
            (DialogWire.Read("""{"open":true,"id":"x","depth":1,"width":0,"plan":{}}""")?.Width?.ToString() ?? "(null)") + "|"
            + (DialogWire.Read("""{"open":true,"id":"x","depth":1,"width":-5,"plan":{}}""")?.Width?.ToString() ?? "(null)"));
        Eq("dialog width: a string is no width", "(null)",
            DialogWire.Read("""{"open":true,"id":"x","depth":1,"width":"460","plan":{}}""")?.Width?.ToString() ?? "(null)");
        Eq("dialog width: plan at the declared width", "720", DialogWire.PlanWidth(720, 420).ToString());
        Eq("dialog width: plan at the default when none is declared", "420", DialogWire.PlanWidth(null, 420).ToString());
        Eq("dialog: an act's reply naming a dialog", "layer_options",
            DialogWire.Named("""{"changed":[],"doc_changed":false,"dialog":"layer_options"}""") ?? "(null)");
        Eq("dialog: an act's reply with dialog null names none", "(null)",
            DialogWire.Named("""{"changed":[],"doc_changed":false,"dialog":null}""") ?? "(null)");
        Eq("dialog: an act's reply with no dialog key names none", "(null)",
            DialogWire.Named("""{"changed":[],"doc_changed":false}""") ?? "(null)");
        Eq("dialog: an unreadable act reply names none", "(null)", DialogWire.Named("nope") ?? "(null)");
        // jas §284 (a): after every pointer release the shell reads the plan and
        // publishes only a reading that differs from what is shown.
        var relShut = DialogWire.Read("""{"open":false}""");
        var relScale = DialogWire.Read("""{"open":true,"id":"scale_options","depth":1,"plan":{}}""");
        Eq("release: nothing shown, a tool opened a dialog -> publish", "True",
            DialogWire.AfterRelease(null, relScale).ToString());
        Eq("release: nothing shown, none open -> publish nothing", "False",
            DialogWire.AfterRelease(null, relShut).ToString());
        Eq("release: the shown dialog is still open -> publish nothing", "False",
            DialogWire.AfterRelease("scale_options", relScale).ToString());
        Eq("release: another dialog than the shown one -> publish", "True",
            DialogWire.AfterRelease("shear_options", relScale).ToString());
        Eq("release: the shown dialog closed -> publish", "True",
            DialogWire.AfterRelease("scale_options", relShut).ToString());
        Eq("release: an unreadable plan is published, never swallowed", "True",
            DialogWire.AfterRelease(null, null).ToString());
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

        // -- A POINTER POSITION IS FLOAT32 NOISE AROUND A WHOLE PIXEL (2026-10-11) --
        // WinRT's `Point` is two floats. With the canvas at a layout-rounded
        // physical origin that is not a whole DIP (122 px = 81.333... DIPs, the
        // toolbar column), `GetCurrentPoint(Canvas)` subtracts two inexact
        // floats, and a mouse on a whole pixel came back a hair off it: the E2E
        // drag landed x1=5.999992 for the spec's 6.0. The mechanism, rebuilt
        // on that drag's own release (canvas x 108 px, origin 122 px):
        float winDip = 230f / 1.5f, originDip = 122f / 1.5f;
        double raw = (double)(winDip - originDip) * 1.5;
        Check("snap: CONTROL -- the float32 route really is off the whole pixel", raw != 108.0, $"raw={raw:R}");
        Eq("snap: ...and the snap returns the whole pixel", "108", PointerWire.Snap(raw).ToString("R"));
        Eq("snap: just above a whole pixel snaps down", "54", PointerWire.Snap(54.00001).ToString("R"));
        Eq("snap: just below a whole pixel snaps up", "54", PointerWire.Snap(53.99999).ToString("R"));
        Eq("snap: a half pixel is a real position, kept", "54.5", PointerWire.Snap(54.5).ToString("R"));
        Eq("snap: a pen's sub-pixel position is kept", "54.25", PointerWire.Snap(54.25).ToString("R"));
        Eq("snap: just outside the window is kept", "54.002", PointerWire.Snap(54.002).ToString("R"));
        Eq("snap: a negative position (a drag off the canvas) snaps too", "-3", PointerWire.Snap(-3.000004).ToString("R"));
        // -- STEP 3: THE TOOLBAR IS ON BY DEFAULT under `app` (2026-10-11) -----
        // `SB_TOOLBAR=0` is the one way off; any other value, or none, is on.
        // Off `app` the old refusal stands for a value that ASKS for it, and
        // `0` (asking for nothing) is never refused.
        Eq("toolbar: unset under app is ON (the default)", "on", PaneKnobs.Toolbar(null, true));
        Eq("toolbar: blank under app is unset, so ON", "on", PaneKnobs.Toolbar("  ", true));
        Eq("toolbar: 0 under app is OFF", "off", PaneKnobs.Toolbar("0", true));
        Eq("toolbar: 0 with whitespace under app is OFF", "off", PaneKnobs.Toolbar(" 0 ", true));
        Eq("toolbar: 1 under app is ON", "on", PaneKnobs.Toolbar("1", true));
        Eq("toolbar: unset off app is OFF, never refused", "off", PaneKnobs.Toolbar(null, false));
        Eq("toolbar: 0 off app is OFF, never refused", "off", PaneKnobs.Toolbar("0", false));
        Eq("toolbar: 1 off app is REFUSED by name, as before", "refused", PaneKnobs.Toolbar("1", false));
        // -- HIS NOTE 4a (2026-10-11, over VNC): "I can't see the menus" ----------
        // `menubar.yaml` writes mnemonics as `&File`; WinUI does not parse `&`, so
        // the in-window MenuBar showed `&File` literally. `MenuWire.Label` gives
        // the text to show and the access key, `&&` being a literal ampersand.
        static string ML(string? raw) { var (t, k) = MenuWire.Label(raw); return t + "|" + k; }
        Eq("menu: &File is File, key F", "File|F", ML("&File"));
        Eq("menu: &Open... is Open..., key O", "Open...|O", ML("&Open..."));
        Eq("menu: a mid-word marker, Save &As...", "Save As...|A", ML("Save &As..."));
        Eq("menu: && is a literal ampersand, and no key", "Fish & Chips|", ML("Fish && Chips"));
        Eq("menu: no marker, no key", "Plain|", ML("Plain"));
        Eq("menu: null is empty, never a throw", "|", ML(null));
        Eq("menu: a trailing & marks nothing and is kept", "Trail&|", ML("Trail&"));
        Eq("menu: only the FIRST marker is the key", "AB|A", ML("&A&B"));
        // Over the REAL spec: every `label:` in menubar.yaml, shown, carries no
        // `&` marker -- and the read found labels at all (an empty read passes
        // nothing, so it is counted).
        var mbDir = new DirectoryInfo(AppContext.BaseDirectory);
        while (mbDir is not null && !File.Exists(Path.Combine(mbDir.FullName, "workspace", "menubar.yaml"))) { mbDir = mbDir.Parent; }
        var mbLabels = mbDir is null ? new List<string>() : System.Text.RegularExpressions.Regex
            .Matches(File.ReadAllText(Path.Combine(mbDir.FullName, "workspace", "menubar.yaml")), "label:\\s*\"([^\"]*)\"")
            .Select(m => m.Groups[1].Value).ToList();
        Check("menu: the spec's menubar.yaml was read, with its labels", mbLabels.Count >= 40, $"read {mbLabels.Count} label(s)");
        var mbMarked = mbLabels.Where(l => System.Text.RegularExpressions.Regex.IsMatch(MenuWire.Label(l).Text, "&[^&\\s]")).ToList();
        Eq("menu: no shown menubar.yaml label keeps an & marker", "", string.Join(",", mbMarked));
        // -- SB_TOOL BY NAME (2026-10-11): an input script names its tool
        // (`"tool": "rect"`); the shell resolves it against the CORE's own list
        // (`jas_tool_name`), so no list is copied here. An index still works.
        var tools = new[] { "selection", "partial_selection", "rect", "ellipse" };
        Eq("tool: a name is its index in the core's list", "2", ToolKnob.Resolve("rect", tools).ToString());
        Eq("tool: an index below the count is itself", "1", ToolKnob.Resolve("1", tools).ToString());
        Eq("tool: whitespace around a name is trimmed", "3", ToolKnob.Resolve(" ellipse ", tools).ToString());
        Eq("tool: an unknown name is refused (-1), never selection", "-1", ToolKnob.Resolve("rectangle", tools).ToString());
        Eq("tool: an index past the count is refused", "-1", ToolKnob.Resolve("4", tools).ToString());
        Eq("tool: names compare ordinally, so Rect is not rect", "-1", ToolKnob.Resolve("Rect", tools).ToString());
        Eq("tool: a negative number is refused", "-1", ToolKnob.Resolve("-1", tools).ToString());

        // -- THE PANEL MENU (the owner's note 3, 2026-10-12) ----------------------
        // `jas_panel_menu` rows, read as the shell draws them. The shell evaluates
        // nothing: label, enabled and checked are the core's.
        var pmJson = "[{\"index\":0,\"kind\":\"item\",\"label\":\"Grayscale\",\"action\":\"set_color_panel_mode\",\"enabled\":true,\"checked\":false},"
                   + "{\"index\":1,\"kind\":\"item\",\"label\":\"HSB\",\"action\":\"set_color_panel_mode\",\"enabled\":true,\"checked\":true},"
                   + "{\"index\":2,\"kind\":\"separator\"},"
                   + "{\"index\":3,\"kind\":\"item\",\"label\":\"Create New Swatch...\",\"action\":null,\"enabled\":false,\"checked\":null},"
                   + "{\"index\":4,\"kind\":\"unknown\"}]";
        var pm = PanelMenuWire.Parse(pmJson);
        Eq("panel menu: one row per node, in order", "0,1,2,3,4", string.Join(",", pm.Select(r => r.Index)));
        Eq("panel menu: kinds are read, an unknown one kept as unknown", "item,item,separator,item,unknown", string.Join(",", pm.Select(r => r.Kind)));
        Eq("panel menu: a checkable row carries its state", "False,True", $"{pm[0].Checked},{pm[1].Checked}");
        Check("panel menu: a non-checkable row has no check state (null, not false)", pm[3].Checked is null, $"{pm[3].Checked}");
        Check("panel menu: enabled is the core's", pm[1].Enabled && !pm[3].Enabled, $"{pm[1].Enabled},{pm[3].Enabled}");
        Eq("panel menu: a null action reads empty", "", pm[3].Action);
        Check("panel menu: empty or unreadable is an empty menu, never a throw", PanelMenuWire.Parse("").Count == 0 && PanelMenuWire.Parse("{x").Count == 0, "threw or read rows");
        // SB_PANEL_MENU_SYNTH=<group key>:<index>.
        static string PK(string? k) { var r = PanelMenuWire.SynthKnob(k); return r is null ? "refused" : $"{r.Value.Group}|{r.Value.Index}"; }
        Eq("panel menu knob: group and index", "dock1|0", PK("dock1:0"));
        Eq("panel menu knob: whitespace trimmed", "dock3|12", PK(" dock3 : 12 "));
        Eq("panel menu knob: no index is refused", "refused", PK("dock1"));
        Eq("panel menu knob: a negative or non-number index is refused", "refused,refused", PK("dock1:-1") + "," + PK("dock1:x"));
        Eq("panel menu knob: unset is refused (the caller reads it as not asked)", "refused", PK(null));

        // The reply's changed rows against the plan read after the click. #360's
        // plan PRUNES a hidden node's rows and lists the node in `hidden`, so a
        // changed row under a hidden path is not drawn and cannot disagree: it is
        // counted as hidden, never as a mismatch. Measured live 2026-10-12: Color's
        // hex commit read delta-mismatch=12, all 12 under the hidden mode groups.
        static string DH(string reply, string plan) { var d = PanelWire.CheckDelta(reply, plan, "p"); return $"{d.Mismatch}|{d.Hidden}"; }
        const string dhRow = "{\"panel\":\"p\",\"path\":[1,1,2,1,1],\"key\":\"bind.value\",\"value\":\"0\"}";
        static string DhPlan(string hidden) => "{\"chrome\":[],\"containers\":[],\"withheld\":[],\"hidden\":" + hidden
            + ",\"leaves\":[{\"path\":[2,1],\"values\":{\"bind.value\":\"ff0000\"}}]}";
        Eq("delta: a changed row under a HIDDEN path is hidden, not a mismatch",
            "0|1", DH("{\"changed\":[" + dhRow + "]}", DhPlan("[[1,1,2]]")));
        Eq("delta: CONTROL -- the same row with nothing hidden is a mismatch",
            "1|0", DH("{\"changed\":[" + dhRow + "]}", DhPlan("[]")));
        Eq("delta: CONTROL -- the hidden test is by PATH PREFIX, not text: [1,1,20] does not hide [1,1,2,...]",
            "1|0", DH("{\"changed\":[" + dhRow + "]}", DhPlan("[[1,1,20]]")));
        Eq("delta: a drawn row that agrees is 0; one that disagrees is a mismatch",
            "0|0,1|0",
            DH("{\"changed\":[{\"panel\":\"p\",\"path\":[2,1],\"key\":\"bind.value\",\"value\":\"ff0000\"}]}", DhPlan("[]")) + ","
            + DH("{\"changed\":[{\"panel\":\"p\",\"path\":[2,1],\"key\":\"bind.value\",\"value\":\"00ff00\"}]}", DhPlan("[]")));
        Eq("delta: another panel's row is not this plan's to check",
            "0|0", DH("{\"changed\":[{\"panel\":\"q\",\"path\":[9],\"key\":\"k\",\"value\":\"v\"}]}", DhPlan("[]")));
        Eq("delta: a plan with no `hidden` key (older core) hides nothing",
            "1|0", DH("{\"changed\":[" + dhRow + "]}", "{\"chrome\":[],\"containers\":[],\"withheld\":[],\"leaves\":[]}"));
        Check("delta: unreadable is named, never 0",
            PanelWire.CheckDelta("{x", "{}", "p").Mismatch.StartsWith("UNREADABLE("), PanelWire.CheckDelta("{x", "{}", "p").Mismatch);

        // FORK A (#384): a `slider` is an input kind. The plan's `numbers` channel
        // carries the node's literal min/max/step; the shell draws a track from
        // them and commits the dragged number as TEXT at release. ⛔ THE ENGINE
        // PARSES, CLAMPS AND SNAPS (`widget_commit::parse_commit`); the shell
        // must not, so nothing here rounds, clamps or snaps a dragged value.
        static string Track(string? json) => PanelWire.ReadSliderTrack(json) is { } t
            ? $"{t.Min.ToString(System.Globalization.CultureInfo.InvariantCulture)}..{t.Max.ToString(System.Globalization.CultureInfo.InvariantCulture)}"
              + $"/{(t.Step is { } st ? st.ToString(System.Globalization.CultureInfo.InvariantCulture) : "-")}"
            : "(null)";
        Eq("slider: a track is the plan's min..max/step", "0..359/1", Track("{\"min\":0,\"max\":359,\"step\":1}"));
        Eq("slider: a step is optional (the engine snaps, the track only draws)", "0..100/-", Track("{\"min\":0,\"max\":100}"));
        Eq("slider: fractional numbers survive", "-1.5..2.25/0.25", Track("{\"min\":-1.5,\"max\":2.25,\"step\":0.25}"));
        Eq("slider: no `numbers` (an older core) is no track -- a counted placeholder, never a guessed 0..100",
            "(null)", Track(null));
        Eq("slider: a missing max is no track", "(null)", Track("{\"min\":0}"));
        Eq("slider: min >= max is no track", "(null)", Track("{\"min\":5,\"max\":5}"));
        Eq("slider: a non-number bound is no track", "(null)", Track("{\"min\":\"0\",\"max\":100}"));
        Eq("slider: a non-positive step is dropped, not used", "0..100/-", Track("{\"min\":0,\"max\":100,\"step\":0}"));
        Eq("slider: unreadable numbers are no track, never a throw", "(null)", Track("{x"));

        static string Pos(string? v) => PanelWire.SliderPosition(v) is { } d
            ? d.ToString(System.Globalization.CultureInfo.InvariantCulture) : "(null)";
        Eq("slider: the core's value places the thumb", "212", Pos("212"));
        Eq("slider: the value is read invariantly (a '.' decimal on any culture)", "33.5", Pos("33.5"));
        Eq("slider: an empty or absent value places nothing", "(null)|(null)", Pos("") + "|" + Pos(null));
        Eq("slider: a non-number value places nothing", "(null)", Pos("abc"));

        Eq("slider: a release commits the dragged number as invariant text", "212.4", Show(PanelWire.SliderCommit(212.4, "100")));
        Eq("slider: a whole number commits without a decimal", "50", Show(PanelWire.SliderCommit(50.0, "40")));
        Eq("slider: the shell does NOT snap or clamp -- 359.7 on a 0..359 step-1 track is sent as dragged",
            "359.7", Show(PanelWire.SliderCommit(359.7, "359")));
        Eq("slider: a release where the core's value already is sends nothing", "(null)", Show(PanelWire.SliderCommit(50.0, "50")));
        Eq("slider: CONTROL -- equality is numeric, not textual (\"50.0\" is 50)", "(null)", Show(PanelWire.SliderCommit(50.0, "50.0")));
        Eq("slider: a release over no readable core value commits", "7", Show(PanelWire.SliderCommit(7.0, null)));
        Eq("slider: a value within 1e-5 of 0 commits fixed-point, never an exponent", "0.0000025", Show(PanelWire.SliderCommit(0.0000025, "0")));
        Eq("slider: a value below the 17th decimal commits as 0, still in the grammar", "0", Show(PanelWire.SliderCommit(1e-20, "1")));

        // FORK B2 (#394): the colour bar sends its POINT, u = x / width and
        // v = y / height from its own top-left, as invariant text with no space.
        // The engine maps and clamps; the shell does neither.
        Eq("color_bar: a point is u,v over the bar's own size", "0.25,0.5", Show(PanelWire.ColorBarPoint(30, 12, 120, 24)));
        Eq("color_bar: the corners are 0 and 1", "0,0|1,1", Show(PanelWire.ColorBarPoint(0, 0, 120, 24)) + "|" + Show(PanelWire.ColorBarPoint(120, 24, 120, 24)));
        Eq("color_bar: the shell does NOT clamp -- a captured pointer past the edge is sent as given",
            "-0.1,1.5", Show(PanelWire.ColorBarPoint(-12, 36, 120, 24)));
        Eq("color_bar: fractions are sent fixed-point, to 15 significant digits", "0.333333333333333,0.125", Show(PanelWire.ColorBarPoint(40, 3, 120, 24)));
        // The contract's number grammar has no exponent, and .NET's round-trip
        // text writes one below 1e-5: a press a hair from an edge must not be refused.
        Eq("color_bar: a tiny u is fixed-point, never an exponent", "0.00000166666666667,0.5", Show(PanelWire.ColorBarPoint(0.0005, 150, 300, 300)));
        Eq("color_bar: a tiny v is fixed-point, never an exponent", "0.5,0.00000166666666667", Show(PanelWire.ColorBarPoint(150, 0.0005, 300, 300)));
        Eq("color_bar: an unsized bar names no point", "(null)|(null)", Show(PanelWire.ColorBarPoint(1, 1, 0, 24)) + "|" + Show(PanelWire.ColorBarPoint(1, 1, 120, double.NaN)));
        Eq("color_bar: a non-finite pointer names no point", "(null)", Show(PanelWire.ColorBarPoint(double.PositiveInfinity, 1, 120, 24)));
        Eq("color_bar: a held move to a new point sends a change", "0.5,0.5", Show(PanelWire.ColorBarChange("0.5,0.5", "0.25,0.5")));
        Eq("color_bar: the first change after the press sends", "0.5,0.5", Show(PanelWire.ColorBarChange("0.5,0.5", null)));
        Eq("color_bar: a move that names the same point sends nothing", "(null)", Show(PanelWire.ColorBarChange("0.5,0.5", "0.5,0.5")));
        Eq("color_bar: no point, no change", "(null)", Show(PanelWire.ColorBarChange(null, "0.5,0.5")));
        // §252 (#399): the bar's picture is `display.picture`, a BMP data URI. The
        // shell decodes it and draws it; anything else draws no picture.
        static string Hex(byte[]? b) => b is null ? "(null)" : Convert.ToHexString(b);
        Eq("color_bar picture: a BMP data URI decodes to its bytes", "424D0102", Hex(PanelWire.PictureBytes("data:image/bmp;base64,Qk0BAg==")));
        Eq("color_bar picture: no picture, no bytes", "(null)|(null)", Hex(PanelWire.PictureBytes(null)) + "|" + Hex(PanelWire.PictureBytes("")));
        Eq("color_bar picture: another media type is refused", "(null)", Hex(PanelWire.PictureBytes("data:image/png;base64,Qk0BAg==")));
        Eq("color_bar picture: a URI that is not base64 is refused", "(null)", Hex(PanelWire.PictureBytes("data:image/bmp,Qk0BAg==")));
        Eq("color_bar picture: malformed base64 is refused", "(null)", Hex(PanelWire.PictureBytes("data:image/bmp;base64,Qk0*Ag==")));
        // §255 (#403): the canvas pane's document tabs. A tab row is a CHROME
        // container carrying `bind.active`; its id is withheld, so it is read by
        // path. The D2D surface starts where the plan puts `drawing_surface`.
        const string canvasPlan = """
            {"chrome":[
              {"path":[0],"type":"container","id":"canvas_tab_bar","rect":{"x":0,"y":0,"w":1600,"h":24},"values":{"bind.visible":"true"},"static":{},"display":{}},
              {"path":[0,0],"type":"container","id":"","rect":{"x":0,"y":0,"w":128,"h":24},"values":{"bind.active":"true"},"static":{},"display":{}},
              {"path":[0,1],"type":"container","id":"","rect":{"x":128,"y":0,"w":128,"h":24},"values":{"bind.active":"false"},"static":{},"display":{}},
              {"path":[1],"type":"container","id":"drawing_surface","rect":{"x":0,"y":24,"w":1600,"h":876},"values":{},"static":{},"display":{}},
              {"path":[1,0],"type":"container","id":"","rect":{"x":0,"y":30,"w":50,"h":20},"values":{"bind.active":"true"},"static":{},"display":{}}],
             "leaves":[],"containers":[],"hidden":[[1,0]]}
            """;
        static string Boxes(List<PanelWire.ActiveBox>? bs) => bs is null ? "(null)"
            : string.Join(" ", bs.Select(b => $"{b.Path}@{b.X},{b.Y},{b.W}x{b.H}:{(b.Active ? "on" : "off")}"));
        Eq("canvas tabs: each chrome row carrying bind.active is a box, in plan order, a hidden one skipped",
            "[0,0]@0,0,128x24:on [0,1]@128,0,128x24:off", Boxes(PanelWire.ActiveBoxes(canvasPlan)));
        Eq("canvas tabs: a plan with no active rows has no boxes", "",
            Boxes(PanelWire.ActiveBoxes("""{"chrome":[{"path":[0],"type":"container","id":"x","rect":{"x":0,"y":0,"w":9,"h":9},"values":{},"static":{},"display":{}}],"hidden":[]}""")));
        Eq("canvas tabs: an unparseable plan has no boxes", "(null)", Boxes(PanelWire.ActiveBoxes("{")));
        // §260: the certificate's reading of the tab strip -- each tab's path,
        // whether it is active, and its label (the text leaf under it) -- so a
        // regression in the tab's name or its active state fails `tree`.
        const string tabPlan = """
            {"chrome":[
              {"path":[0],"type":"container","id":"canvas_tab_bar","rect":{"x":0,"y":0,"w":1600,"h":24},"values":{"bind.visible":"true"},"static":{},"display":{}},
              {"path":[0,0],"type":"container","id":"","rect":{"x":0,"y":0,"w":128,"h":24},"values":{"bind.active":"true"},"static":{},"display":{}},
              {"path":[0,1],"type":"container","id":"","rect":{"x":128,"y":0,"w":128,"h":24},"values":{"bind.active":"false"},"static":{},"display":{}},
              {"path":[1,0],"type":"container","id":"","rect":{"x":0,"y":30,"w":50,"h":20},"values":{"bind.active":"true"},"static":{},"display":{}}],
             "leaves":[
              {"path":[0,0,0],"type":"text","id":"","rect":{"x":8,"y":2,"w":80,"h":20},"values":{"content":"tabréct.svg"},"static":{},"display":{}},
              {"path":[0,0,1],"type":"icon_button","id":"","rect":{"x":100,"y":4,"w":12,"h":12},"values":{},"static":{"icon":"close"},"display":{}},
              {"path":[0,1,0],"type":"text","id":"","rect":{"x":136,"y":2,"w":80,"h":20},"values":{},"static":{"content":"Untitled-2"},"display":{}},
              {"path":[1,0,0],"type":"text","id":"","rect":{"x":0,"y":30,"w":50,"h":20},"values":{"content":"hidden"},"static":{},"display":{}}],
             "containers":[],"hidden":[[1,0]]}
            """;
        Eq("canvas tab reading: each tab's path, active state and label, in plan order, a hidden one skipped",
            "[0,0]=on:\"tabréct.svg\" [0,1]=off:\"Untitled-2\"", Show(PanelWire.TabReading(tabPlan)));
        Eq("canvas tab reading: a mutant label reads differently",
            "False", (PanelWire.TabReading(tabPlan) == PanelWire.TabReading(tabPlan.Replace("tabréct.svg", "tabrect.svg"))).ToString());
        Eq("canvas tab reading: a mutant active state reads differently",
            "False", (PanelWire.TabReading(tabPlan) == PanelWire.TabReading(tabPlan.Replace("\"bind.active\":\"false\"", "\"bind.active\":\"true\""))).ToString());
        Eq("canvas tab reading: a tab without a text leaf reads an empty label", "[0,0]=on:\"\" [0,1]=off:\"\"",
            Show(PanelWire.TabReading(canvasPlan)));
        Eq("canvas tab reading: a plan with no tabs reads empty, an unparseable one null", "|(null)",
            Show(PanelWire.TabReading("""{"chrome":[],"leaves":[],"hidden":[]}""")) + "|" + Show(PanelWire.TabReading("{")));
        // §265: the probe's tab reading names WHY there is no reading. A strip that
        // is not open is NONE; a plan that does not parse is UNREADABLE, never NONE,
        // so a parse failure cannot match a baseline frozen with no strip.
        Eq("canvas tab probe: no strip open reads NONE", "NONE", PanelWire.TabProbeReading(false, null));
        Eq("canvas tab probe: an open strip whose plan does not parse reads UNREADABLE", "UNREADABLE", PanelWire.TabProbeReading(true, "{"));
        Eq("canvas tab probe: an open strip reads its tabs", "[0,0]=on:\"\" [0,1]=off:\"\"", PanelWire.TabProbeReading(true, canvasPlan));
        Eq("canvas tab probe: an open strip with no tabs reads empty, not NONE", "", PanelWire.TabProbeReading(true, """{"chrome":[],"leaves":[],"hidden":[]}"""));
        Eq("canvas tabs: the surface starts where the plan places it", "24", Show(PanelWire.SurfaceTop(canvasPlan, "drawing_surface")?.ToString()));
        Eq("canvas tabs: a plan without the surface names no top", "(null)|(null)",
            Show(PanelWire.SurfaceTop(canvasPlan, "no_such")?.ToString()) + "|" + Show(PanelWire.SurfaceTop("{", "drawing_surface")?.ToString()));
        Eq("color_bar picture: bytes that are not a BMP are refused", "(null)|(null)", Hex(PanelWire.PictureBytes("data:image/bmp;base64,iVBORw==")) + "|" + Hex(PanelWire.PictureBytes("data:image/bmp;base64,")));

        // §257 (#406): the tab names the document by its FILE NAME, sent as
        // UTF-8 bytes (BL5); a path with no file name sends nothing.
        static string Utf8(byte[]? b) => b is null ? "(null)" : System.Text.Encoding.UTF8.GetString(b);
        Eq("document name: the file name of the path, not the path", "tab_rect.svg", Utf8(PanelWire.DocumentNameBytes(@"C:\work\docs\tab_rect.svg")));
        Eq("document name: a non-ASCII name is UTF-8, never ANSI", "74616272C3A963742E737667", Hex(PanelWire.DocumentNameBytes(@"C:\d\tabr" + "\u00e9" + "ct.svg")));
        Eq("document name: no path, an empty path, or a directory sends nothing", "(null)|(null)|(null)", Utf8(PanelWire.DocumentNameBytes(null)) + "|" + Utf8(PanelWire.DocumentNameBytes("")) + "|" + Utf8(PanelWire.DocumentNameBytes(@"C:\d\")));
        Eq("document name: a save to the opened path is not a new path", "False", PanelWire.IsNewDocumentPath(@"C:\d\a.svg", @"C:\d\a.svg").ToString());
        Eq("document name: Windows paths compare without case", "False", PanelWire.IsNewDocumentPath(@"C:\D\A.svg", @"c:\d\a.SVG").ToString());
        Eq("document name: a save to another path is new", "True", PanelWire.IsNewDocumentPath(@"C:\d\a.svg", @"C:\d\b.svg").ToString());
        Eq("document name: the first save of an untitled document is new", "True", PanelWire.IsNewDocumentPath(null, @"C:\d\b.svg").ToString());

        // #397: the dirty flag is the MODEL's answer (`jas_document_modified`),
        // never a reply's `doc_changed` (a selection repaints and is not an edit).
        static string Dirty(byte b) => TitleVerdict.DirtyFromModel(b) is { } d ? (d ? "dirty" : "clean") : "(no answer)";
        Eq("dirty: the model's 1 is modified", "dirty", Dirty(1));
        Eq("dirty: the model's 0 is saved", "clean", Dirty(0));
        Eq("dirty: 255 (no engine) is no answer -- never read as saved", "(no answer)", Dirty(255));
        Eq("dirty: any other byte is no answer, never a guess", "(no answer)", Dirty(2));

        Console.WriteLine();
        Console.WriteLine($"--- {_passed} passed, {_failed} failed, of {_passed + _failed} case(s) ---");
        return _failed == 0 ? 0 : 1;
    }
}
