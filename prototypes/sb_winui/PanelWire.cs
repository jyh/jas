namespace SbWinUi;

/// <summary>
/// W2b-2: what a panel control SENDS the core, what a row SAYS it sent, and
/// the list of panels the pane offers, read from the core's own bytes.
///
/// ⛔ PURE ON PURPOSE: no WinUI, no device, no engine. `sb_winui_tests` links
/// this file, so the desktop-less runner in `windows-shell-compile` drives it.
/// Everything here that a person's input reaches would otherwise first run on
/// kenai.
///
/// ⛔ AND IT DECIDES NOTHING ABOUT A VALUE. The text a person typed crosses as
/// TEXT; the core parses it by the widget's kind (`WIDGET_EVENTS.md`), and a
/// refusal is the core's. The one choice made here is WHEN a focus loss
/// commits, and that is about the shell's own control, not the value.
/// </summary>
internal static class PanelWire
{
    /// <summary>
    /// The reply's changed rows for <paramref name="panelId"/> checked against the
    /// plan read AFTER the click. `Mismatch` is how many disagree, as text ("0"
    /// when all agree; `UNREADABLE(..)` when either side does not parse). A row
    /// whose value the plan withheld (a template) agrees when `withheld` names it.
    /// A row under one of the plan's `hidden` paths (#360: the plan prunes a
    /// hidden node's rows) is not drawn and cannot disagree: it is counted in
    /// `Hidden`, never as a mismatch. The test is by PATH PREFIX, element-wise.
    /// Measured live 2026-10-12: Color's hex commit read 12 "mismatches", every
    /// one a slider of a mode group the plan had hidden.
    /// </summary>
    internal static (string Mismatch, int Hidden) CheckDelta(string reply, string plan, string panelId)
    {
        try
        {
            using var answer = System.Text.Json.JsonDocument.Parse(reply);
            using var doc = System.Text.Json.JsonDocument.Parse(plan);
            var values = new Dictionary<string, string>();
            foreach (var list in new[] { "chrome", "leaves", "containers" })
            {
                foreach (var e in doc.RootElement.GetProperty(list).EnumerateArray())
                {
                    var path = e.GetProperty("path").GetRawText();
                    foreach (var kv in e.GetProperty("values").EnumerateObject())
                    {
                        values[path + "|" + kv.Name] = kv.Value.GetString() ?? "";
                    }
                }
            }
            var withheld = new HashSet<string>();
            foreach (var w in doc.RootElement.GetProperty("withheld").EnumerateArray())
            {
                withheld.Add(w.GetProperty("path").GetRawText() + "|" + w.GetProperty("key").GetString());
            }
            var hidden = new List<long[]>();
            if (doc.RootElement.TryGetProperty("hidden", out var hs))
            {
                foreach (var h in hs.EnumerateArray()) { hidden.Add(h.EnumerateArray().Select(x => x.GetInt64()).ToArray()); }
            }

            int bad = 0, under = 0;
            foreach (var row in answer.RootElement.GetProperty("changed").EnumerateArray())
            {
                if (row.GetProperty("panel").GetString() != panelId) { continue; }
                var p = row.GetProperty("path").EnumerateArray().Select(x => x.GetInt64()).ToArray();
                if (hidden.Any(h => h.Length <= p.Length && h.SequenceEqual(p.Take(h.Length)))) { under++; continue; }
                var k = row.GetProperty("path").GetRawText() + "|" + row.GetProperty("key").GetString();
                var v = row.GetProperty("value").GetString() ?? "";
                var agrees = values.TryGetValue(k, out var inPlan) ? inPlan == v : withheld.Contains(k);
                if (!agrees) { bad++; }
            }
            return (bad.ToString(), under);
        }
        catch (Exception ex)
        {
            return ($"UNREADABLE({ex.GetType().Name})", 0);
        }
    }

    /// <summary>The row form of "this event carried no value" (a press).</summary>
    internal const string NoValue = "-";

    /// <summary>
    /// The event JSON for `jas_panel_behavior`, written by a serializer.
    ///
    /// A press (`click`) carries NO `value` key. A commit carries the TEXT the
    /// control holds as a JSON STRING, always: the header refuses a `value`
    /// that is not a string as `BadValue`, so a shell that sent `40` as a
    /// number would have every commit refused.
    /// </summary>
    /// W2b-19: `path` is the leaf's PLAN path as the plan printed it (`[0,1,2]`).
    /// The core resolves a path to the row it names, which is the only way a row
    /// a `foreach` stamped out can be addressed (its id names a template). A
    /// path that is not a JSON array of non-negative integers is left out, so
    /// the event falls back to the widget id rather than carrying garbage.
    internal static byte[] EventJson(string widget, string eventName, string? value,
                                     bool alt, bool shift, bool ctrl, bool meta,
                                     string? path = null)
    {
        var ev = new Dictionary<string, object>
        {
            ["widget"] = widget,
            ["event"] = eventName,
            ["alt"] = alt,
            ["shift"] = shift,
            ["ctrl"] = ctrl,
            ["meta"] = meta,
        };
        if (value is not null) { ev["value"] = value; }
        if (PlanPath(path) is { } p) { ev["path"] = p; }
        return System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(ev);
    }

    /// <summary>
    /// §1.2: a dropdown entry's `items` from its raw JSON
    /// (`panel_plan.rs::items_of`). Null when the core sent `null` (no `items`
    /// list), when the key is absent, or when the bytes are not an array.
    ///
    /// ⛔ THE SHELL DECIDES NOTHING ABOUT A ROW. A divider is `kind: separator`;
    /// an `action` or `toggle` row carries a `value` string (what a pick sends
    /// back) and a `label` string; its `checked` is `true`, `false`, or null
    /// (unknown), as the core sent it: a toggle's membership in
    /// `bind.checked_in`, or whether an action is already in force. Any other `kind`, a row missing a
    /// string, or a `checked` that is not a boolean or null is COUNTED in
    /// `Refused` and not offered.
    /// </summary>
    internal static PaneItems? ReadItems(string? json)
    {
        if (json is null) { return null; }
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.ValueKind != System.Text.Json.JsonValueKind.Array) { return null; }
            var rows = new List<PaneItem>();
            var refused = 0;
            foreach (var row in root.EnumerateArray())
            {
                var kind = Str(row, "kind");
                if (kind == "separator")
                {
                    rows.Add(new PaneItem(true, "separator", "", "", null));
                    continue;
                }
                if ((kind != "action" && kind != "toggle")
                    || Str(row, "value") is not { } value || Str(row, "label") is not { } label)
                {
                    refused++;
                    continue;
                }
                bool? isChecked = null;
                if (row.TryGetProperty("checked", out var c))
                {
                    switch (c.ValueKind)
                    {
                        case System.Text.Json.JsonValueKind.True: isChecked = true; break;
                        case System.Text.Json.JsonValueKind.False: isChecked = false; break;
                        case System.Text.Json.JsonValueKind.Null: break;
                        default: refused++; continue;
                    }
                }
                rows.Add(new PaneItem(false, kind, value, label, isChecked));
            }
            return new PaneItems(rows, refused);
        }
        catch (System.Text.Json.JsonException)
        {
            return null;
        }
    }

    /// <summary>§1.2: the event a pick sends (WIDGET_EVENTS.md): `toggle`, or
    /// `alt_toggle` with Alt held. They are not synonyms; each runs only its
    /// own behaviors.</summary>
    internal static string PickEvent(bool alt) => alt ? "alt_toggle" : "toggle";

    /// <summary>
    /// Whether a tap on a control can reach the core: by its id, or by its
    /// plan path (<see cref="PlanPath"/>), which is how a row a `foreach`
    /// stamped out is addressed (a library swatch has no id at all;
    /// STATUS-flask §114). The swatch's gate and its `unaddressable` count
    /// both read this, so the two cannot disagree.
    /// </summary>
    internal static bool Addressable(string id, string? path) =>
        id.Length > 0 || PlanPath(path) is not null;

    /// <summary>
    /// S1: a `button`'s face. The core resolves a `{{`-bearing label into the
    /// leaf's `values` (Save Changes' "Save {{param.filename}}") and sends a
    /// literal one in `static`; the resolved one wins. With no label, the
    /// summary, then the id, as `icon_button`'s text face falls back. Never null.
    /// </summary>
    internal static string ButtonLabel(string? boundLabel, string? literalLabel, string? summary, string id) =>
        boundLabel ?? literalLabel ?? summary ?? id;

    /// <summary>
    /// S1: whether a press on a button can reach the core, so whether it is
    /// enabled. A `button` or `icon_button` is addressed like a swatch
    /// (<see cref="Addressable"/>): a dialog's OK and Cancel, the canvas
    /// strip's close box and the 23 tool-alternates buttons carry NO id, only
    /// a plan path (#420). Any other kind drawn as a button (a dropdown, whose
    /// button sends nothing itself) keeps the id rule.
    /// </summary>
    internal static bool Clickable(string type, string id, string? path) =>
        type is "button" or "icon_button" ? Addressable(id, path) : id.Length > 0;

    /// <summary>
    /// S3: which rule a `separator` draws in its rect. The plan carries no
    /// `orientation` (it is not a STATIC_KEY), so the rule follows the
    /// plan's own geometry: wider than tall (or square) is horizontal, taller
    /// is vertical. An empty rect draws nothing (null).
    /// </summary>
    internal static string? SeparatorRule(double w, double h) =>
        w <= 0 || h <= 0 ? null : (w >= h ? "horizontal" : "vertical");

    /// <summary>A plan path's text as integers, or null when it is not one.</summary>
    internal static int[]? PlanPath(string? path)
    {
        if (string.IsNullOrEmpty(path)) { return null; }
        try
        {
            var p = System.Text.Json.JsonSerializer.Deserialize<int[]>(path);
            return p is { Length: > 0 } && p.All(i => i >= 0) ? p : null;
        }
        catch (System.Text.Json.JsonException)
        {
            return null;
        }
    }

    /// <summary>
    /// A value as a row prints it: one whitespace-free token, so a reader's
    /// `key=\S+` takes all of it. The text is JSON-encoded (quoted), with a
    /// space written as `\u0020`; a press prints <see cref="NoValue"/>, which
    /// no encoded string can equal because an encoded string is quoted.
    /// </summary>
    internal static string RowValue(string? value)
    {
        if (value is null) { return NoValue; }
        // The default encoder already writes every control character and every
        // non-ASCII character as an escape, so an ASCII space is the only
        // whitespace left to encode.
        return System.Text.Json.JsonSerializer.Serialize(value).Replace(" ", "\\u0020");
    }

    /// <summary>
    /// Does losing focus commit this text? Only when it differs from what the
    /// core last showed, compared ORDINALLY. Enter always commits; a focus
    /// change that edited nothing must not run a panel's behaviors.
    /// </summary>
    internal static bool CommitOnBlur(string text, string shown)
    {
        return !string.Equals(text, shown, StringComparison.Ordinal);
    }

    /// <summary>
    /// The pane's panel list from `jas_panel_list`'s bytes: each row's `id`,
    /// and the label to show (its `summary`, or the id when the core sent
    /// none). A row with no string id cannot be opened, so it is COUNTED in
    /// `Skipped` and never shown.
    ///
    /// ⛔ NULL MEANS UNREADABLE, and it is not an empty list: bytes that do not
    /// parse, or parse to anything but an array, return null so the caller
    /// reports a refusal instead of drawing an empty selector.
    /// </summary>
    internal static PanelChoices? ReadPanelList(string json)
    {
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != System.Text.Json.JsonValueKind.Array) { return null; }
            var rows = new List<(string Id, string Label)>();
            var skipped = 0;
            foreach (var row in doc.RootElement.EnumerateArray())
            {
                if (row.ValueKind != System.Text.Json.JsonValueKind.Object
                    || !row.TryGetProperty("id", out var id)
                    || id.ValueKind != System.Text.Json.JsonValueKind.String
                    || id.GetString() is not { Length: > 0 } idText)
                {
                    skipped++;
                    continue;
                }
                var label = row.TryGetProperty("summary", out var summary)
                            && summary.ValueKind == System.Text.Json.JsonValueKind.String
                            && summary.GetString() is { Length: > 0 } summaryText
                    ? summaryText
                    : idText;
                rows.Add((idText, label));
            }
            return new PanelChoices(rows, skipped);
        }
        catch (System.Text.Json.JsonException)
        {
            return null;
        }
    }

    /// <summary>
    /// W2b-9: the string a control SHOWS — the core's formatted `display`
    /// when it sent one, else the resolved value.
    ///
    /// ⛔ PRESENCE, NEVER TRUTHINESS. An EMPTY display is a real answer and
    /// must win over a non-empty value: a `length_input` whose bind resolves
    /// to anything but a number displays empty in every port
    /// (`length::format(None, ..)`), while its raw value may still be a
    /// string. A `?? ` on the display would show that string and no port does.
    ///
    /// ⛔ AND THE SHELL STILL COMPUTES NOTHING. `display` arrives already
    /// formatted — unit appended, converted out of pt, rounded to the widget's
    /// precision — because that is interpretation and the core owns it. The
    /// one choice here is WHICH of two strings the core sent to show.
    /// </summary>
    internal static string DisplayText(string? display, string? value) => display ?? value ?? "";

    /// <summary>
    /// A `color_swatch` leaf's fill, from the `bind.color` string the core
    /// sends: `#rrggbb` (either case) and nothing else, or null. A null is
    /// drawn as an EMPTY swatch (a recent-colour slot with no colour yet),
    /// never as black, because black is a colour a swatch can hold.
    ///
    /// ⛔ `AllowHexSpecifier` ALONE, never `NumberStyles.HexNumber`: that one
    /// also allows leading and trailing white space, so "# 12345" would read
    /// its first channel as 0x01 and pass as a colour.
    /// </summary>
    internal static (byte R, byte G, byte B)? SwatchColor(string? hex)
    {
        if (hex is null || hex.Length != 7 || hex[0] != '#') { return null; }
        const System.Globalization.NumberStyles Hex = System.Globalization.NumberStyles.AllowHexSpecifier;
        var inv = System.Globalization.CultureInfo.InvariantCulture;
        if (byte.TryParse(hex.AsSpan(1, 2), Hex, inv, out var r)
            && byte.TryParse(hex.AsSpan(3, 2), Hex, inv, out var g)
            && byte.TryParse(hex.AsSpan(5, 2), Hex, inv, out var b))
        {
            return (r, g, b);
        }
        return null;
    }

    /// <summary>
    /// A `brush_preview` leaf's drawing: the core's `preview.viewbox` and
    /// `preview.svg` (the elements, painted in `currentColor`), the same pair an
    /// icon is drawn from, or null. BOTH OR NEITHER: a drawing with no box, or a
    /// box with nothing in it, is drawn as the empty tile the core means by
    /// sending no preview (a brush type with no preview), never half-drawn.
    /// </summary>
    internal static (string Viewbox, string Svg)? Preview(string? viewbox, string? svg) =>
        string.IsNullOrWhiteSpace(viewbox) || string.IsNullOrWhiteSpace(svg) ? null : (viewbox, svg);

    /// <summary>
    /// W2b-9: which name a leaf's glyph is looked up under.
    ///
    /// ⛔ AN `icon` NODE NAMES ITS GLYPH UNDER `name`, NOT `icon`, AND NOTHING
    /// ELSE DOES. This mirrors the PRODUCER exactly --
    /// `panel_plan.rs::icon_names` carries the same special case:
    ///
    ///     push(&amp;st["icon"]);
    ///     if entry["type"] == "icon" { push(&amp;st["name"]); }
    ///     push(&amp;entry["values"]["bind.icon"]);
    ///
    /// which is how the plan's `icons` map acquires the definition at all. A
    /// shell that looked only under `icon` would resolve EVERY bare `icon` to
    /// null: it draws an empty face, counts an `icon-text`, and never asks for
    /// the SVG -- a complete, silent failure that passes every gate, because
    /// nothing downstream knows a glyph was expected.
    ///
    /// ⛔ AND THE `name` BRANCH IS TYPE-GATED DELIBERATELY. `name` is a
    /// STATIC_KEYS display string that other kinds also carry, so reading it
    /// unconditionally would make some other widget's label into an icon
    /// lookup. The producer gates it on the type; so does this.
    ///
    /// A resolved `bind.icon` wins over either literal, as in every port.
    /// </summary>
    internal static string? IconName(string? boundIcon, string? literalIcon, string? literalName, string type)
        => boundIcon ?? literalIcon ?? (type == "icon" ? literalName : null);

    /// <summary>
    /// W-b: a plan entry's `options` from its raw JSON (`panel_plan.rs::options_of`).
    ///
    /// Null when the core sent `null` (the node declares no list), when the key
    /// is absent, or when the bytes are not an array: a list control built from
    /// no list is the degenerate control this channel exists to prevent, so the
    /// caller must be able to tell "no list" from "an empty one".
    ///
    /// ⛔ THE SHELL DECIDES NOTHING ABOUT A ROW. A divider is a row whose `kind`
    /// is `separator`, and the core says so; an option's `value` is the text to
    /// commit, and `selected` is the core's answer to which row is the bound
    /// value. Any other `kind`, or an option missing its `value` or `label`
    /// string, is COUNTED in `Refused` and not offered.
    /// </summary>
    internal static PaneOptions? ReadOptions(string? json)
    {
        if (json is null) { return null; }
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.ValueKind != System.Text.Json.JsonValueKind.Array) { return null; }
            var rows = new List<PaneOption>();
            var refused = 0;
            foreach (var row in root.EnumerateArray())
            {
                var kind = Str(row, "kind");
                if (kind == "separator")
                {
                    rows.Add(new PaneOption(true, "", "", null, false));
                    continue;
                }
                if (kind != "option" || Str(row, "value") is not { } value || Str(row, "label") is not { } label)
                {
                    refused++;
                    continue;
                }
                var selected = row.TryGetProperty("selected", out var sel)
                               && sel.ValueKind == System.Text.Json.JsonValueKind.True;
                rows.Add(new PaneOption(false, value, label, Str(row, "glyph"), selected));
            }
            return new PaneOptions(rows, refused);
        }
        catch (System.Text.Json.JsonException)
        {
            return null;
        }
    }

    private static string? Str(System.Text.Json.JsonElement row, string key) =>
        row.ValueKind == System.Text.Json.JsonValueKind.Object
        && row.TryGetProperty(key, out var v)
        && v.ValueKind == System.Text.Json.JsonValueKind.String
            ? v.GetString()
            : null;

    /// <summary>
    /// W-b: what picking item <paramref name="picked"/> sends: its `value` text,
    /// or null when nothing is to be sent -- no item (-1, or out of range), or
    /// the item whose value the core already shows (<paramref name="shown"/>).
    ///
    /// ⛔ THE SECOND NULL IS THE ONE THAT MATTERS. Putting a list control back
    /// to the core's value raises the same selection-changed event a person's
    /// pick does, so without it every plan the core publishes would commit its
    /// own value back and run the widget's behaviors -- `CommitOnBlur`'s rule,
    /// for a list.
    ///
    /// ⛔ AND IT SENDS THE VALUE, NEVER THE LABEL: `stk_start_arrowhead_scale`
    /// labels 100 as "100%", and the core's commit parse accepts `100`.
    /// </summary>
    internal static string? ChoiceCommit(int picked, List<PaneOption> items, string? shown)
    {
        if (picked < 0 || picked >= items.Count) { return null; }
        var value = items[picked].Value;
        return string.Equals(value, shown, StringComparison.Ordinal) ? null : value;
    }

    /// <summary>
    /// W-b: the text an item shows in the list. An `icon_select` row carries a
    /// `glyph` (a single mark, "•") beside its label, and both are shown; any
    /// other row shows its label.
    /// </summary>
    internal static string ChoiceText(PaneOption row) =>
        row.Glyph is { Length: > 0 } g ? $"{g}  {row.Label}" : row.Label;

    /// <summary>
    /// FORK A (#384): a `slider`'s track, from the plan's `numbers` channel (the
    /// node's LITERAL min/max/step). Null -- a counted placeholder, never a guessed
    /// range -- when the core sent no `numbers` (an older core), a bound is missing
    /// or not a number, or min is not below max. A non-positive step is dropped.
    /// ⛔ THE TRACK ONLY DRAWS: the engine parses, clamps and snaps every commit
    /// (`widget_commit::parse_commit`), so nothing here enforces these numbers.
    /// </summary>
    internal static SliderTrack? ReadSliderTrack(string? numbersJson)
    {
        if (string.IsNullOrEmpty(numbersJson)) { return null; }
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(numbersJson);
            var root = doc.RootElement;
            if (root.ValueKind != System.Text.Json.JsonValueKind.Object) { return null; }
            double? Num(string key) =>
                root.TryGetProperty(key, out var v) && v.ValueKind == System.Text.Json.JsonValueKind.Number
                    ? v.GetDouble() : null;
            if (Num("min") is not { } min || Num("max") is not { } max || min >= max) { return null; }
            var step = Num("step") is { } st && st > 0 ? st : (double?)null;
            return new SliderTrack(min, max, step);
        }
        catch (System.Text.Json.JsonException) { return null; }
    }

    /// <summary>
    /// FORK A: where the core's value puts the thumb, read invariantly. Null when
    /// the core sent no number; the thumb is then left where it is.
    /// </summary>
    internal static double? SliderPosition(string? coreValue) =>
        double.TryParse(coreValue, System.Globalization.NumberStyles.Float,
                        System.Globalization.CultureInfo.InvariantCulture, out var d) ? d : null;

    /// <summary>
    /// FORK A: the text a slider's RELEASE commits -- the dragged number as the
    /// contract writes it (<see cref="ContractNumber"/>) -- or null when it is numerically the value
    /// the core already shows (a release that moved nothing sends nothing, as
    /// <see cref="ChoiceCommit"/> does). ⛔ NO SNAP, NO CLAMP: the engine's.
    /// </summary>
    internal static string? SliderCommit(double dragged, string? shown) =>
        SliderPosition(shown) is { } at && at == dragged
            ? null
            : ContractNumber(dragged);

    /// <summary>
    /// A number as the contract's grammar writes it (`WIDGET_EVENTS.md`):
    /// invariant, fixed-point, to 15 significant digits. ⛔ NEVER `"R"`: .NET's
    /// round-trip text writes an EXPONENT below 1e-5 (`1.6666666666666667E-06`),
    /// which the grammar refuses, so a value a hair from 0 was a `BadValue`.
    /// </summary>
    internal static string ContractNumber(double d) =>
        d.ToString("0.#################", System.Globalization.CultureInfo.InvariantCulture);

    /// <summary>
    /// FORK B2 (#394): the colour bar's POINT under the pointer, `u,v`, with
    /// u = x / width and v = y / height from the bar's own top-left, as invariant
    /// fixed-point text (<see cref="ContractNumber"/>) and no space. ⛔ NOT CLAMPED: a captured pointer past the
    /// edge is sent as given, and the engine clamps and maps it
    /// (`color_util::color_bar_rgb`). An unsized bar or a non-finite pointer
    /// names no point.
    /// </summary>
    internal static string? ColorBarPoint(double x, double y, double width, double height) =>
        double.IsFinite(x) && double.IsFinite(y) && double.IsFinite(width) && double.IsFinite(height)
        && width > 0 && height > 0
            ? ContractNumber(x / width) + "," + ContractNumber(y / height)
            : null;

    /// <summary>
    /// A held move sends `change` only when it names a new point, so a pointer
    /// that reports the same spot twice costs the engine nothing.
    /// </summary>
    internal static string? ColorBarChange(string? point, string? lastSent) =>
        point is not null && point != lastSent ? point : null;

    /// <summary>
    /// §252 (#399): the bytes of a `display.picture`, a `data:image/bmp;base64,`
    /// URI. Null for no picture, another media type, malformed base64, or bytes
    /// that do not open with the BMP signature `BM`. Decoding is all the shell
    /// does: every pixel is already the engine's colour.
    /// </summary>
    /// <summary>§255: a chrome row carrying `bind.active` (a document tab), by path; drawn behind its leaves.</summary>
    internal sealed record ActiveBox(string Path, double X, double Y, double W, double H, bool Active);

    /// <summary>
    /// §255 (#403): the plan's chrome rows that carry `bind.active`, in plan
    /// order, with any row under one of the plan's `hidden` paths skipped. A
    /// `foreach` row's id is withheld, so a row is named by its PATH (the same
    /// raw text a leaf's path is). Null when the plan does not parse. The shell
    /// only reads `"true"`: which tab is active is the engine's answer.
    /// </summary>
    internal static List<ActiveBox>? ActiveBoxes(string planJson)
    {
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(planJson);
            var root = doc.RootElement;
            var hidden = new List<long[]>();
            if (root.TryGetProperty("hidden", out var hs))
            {
                foreach (var h in hs.EnumerateArray()) { hidden.Add(h.EnumerateArray().Select(x => x.GetInt64()).ToArray()); }
            }
            var boxes = new List<ActiveBox>();
            foreach (var e in root.GetProperty("chrome").EnumerateArray())
            {
                if (!e.GetProperty("values").TryGetProperty("bind.active", out var active)) { continue; }
                var p = e.GetProperty("path").EnumerateArray().Select(x => x.GetInt64()).ToArray();
                if (hidden.Any(h => h.Length <= p.Length && h.SequenceEqual(p.Take(h.Length)))) { continue; }
                var r = e.GetProperty("rect");
                boxes.Add(new ActiveBox(
                    e.GetProperty("path").GetRawText(),
                    r.GetProperty("x").GetDouble(), r.GetProperty("y").GetDouble(),
                    r.GetProperty("w").GetDouble(), r.GetProperty("h").GetDouble(),
                    active.GetString() == "true"));
            }
            return boxes;
        }
        catch (Exception ex) when (ex is System.Text.Json.JsonException or InvalidOperationException or KeyNotFoundException)
        {
            return null;
        }
    }

    /// <summary>
    /// §265: the probe's reading of the canvas strip, naming WHY there is none.
    /// `NONE` when the strip is not open; `UNREADABLE` when it is open and its
    /// plan does not parse (a parse failure must never read as "no strip", or it
    /// would match a baseline frozen without one); otherwise <see cref="TabReading"/>.
    /// Neither sentinel can collide with a reading, which is empty or opens with `[`.
    /// </summary>
    internal static string TabProbeReading(bool open, string? planJson) =>
        !open ? "NONE" : (planJson is null ? null : TabReading(planJson)) ?? "UNREADABLE";

    /// <summary>
    /// §260: the canvas strip as a certificate reads it -- each tab (a row
    /// <see cref="ActiveBoxes"/> finds) as `path=on|off:"label"`, space-joined in
    /// plan order, where the label is the first text leaf under the tab's path
    /// (its resolved `content`, else the literal). Only the engine's answers are
    /// read, never a rect, so the reading moves when a tab's NAME or ACTIVE STATE
    /// does and not when the strip is laid out differently. Empty for a plan with
    /// no tabs; null when the plan does not parse.
    /// </summary>
    internal static string? TabReading(string planJson)
    {
        var boxes = ActiveBoxes(planJson);
        if (boxes is null) { return null; }
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(planJson);
            var leaves = doc.RootElement.TryGetProperty("leaves", out var ls)
                ? ls.EnumerateArray().ToList() : new List<System.Text.Json.JsonElement>();
            var parts = new List<string>();
            foreach (var b in boxes)
            {
                var p = System.Text.Json.JsonDocument.Parse(b.Path).RootElement.EnumerateArray().Select(x => x.GetInt64()).ToArray();
                var label = "";
                foreach (var l in leaves)
                {
                    if (l.GetProperty("type").GetString() != "text") { continue; }
                    var lp = l.GetProperty("path").EnumerateArray().Select(x => x.GetInt64()).ToArray();
                    if (lp.Length <= p.Length || !lp.Take(p.Length).SequenceEqual(p)) { continue; }
                    label = (l.GetProperty("values").TryGetProperty("content", out var v) ? v.GetString() : null)
                        ?? (l.GetProperty("static").TryGetProperty("content", out var s) ? s.GetString() : null)
                        ?? "";
                    break;
                }
                var quoted = label.Replace("\\", "\\\\").Replace("\"", "\\\"");
                parts.Add($"{b.Path}={(b.Active ? "on" : "off")}:\"{quoted}\"");
            }
            return string.Join(" ", parts);
        }
        catch (Exception ex) when (ex is System.Text.Json.JsonException or InvalidOperationException or KeyNotFoundException)
        {
            return null;
        }
    }


    /// <summary>
    /// §255: the y at which the chrome container <paramref name="surfaceId"/>
    /// starts, so the shell's own drawing surface sits where the plan puts it and
    /// the strip above it is the plan's. Null when the plan does not parse or
    /// does not place it.
    /// </summary>
    internal static long? SurfaceTop(string planJson, string surfaceId)
    {
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(planJson);
            foreach (var e in doc.RootElement.GetProperty("chrome").EnumerateArray())
            {
                if (e.GetProperty("id").GetString() == surfaceId) { return e.GetProperty("rect").GetProperty("y").GetInt64(); }
            }
            return null;
        }
        catch (Exception ex) when (ex is System.Text.Json.JsonException or InvalidOperationException or KeyNotFoundException)
        {
            return null;
        }
    }

    /// <summary>
    /// §257 (#406): the name the canvas tab shows for a document opened from or
    /// saved to <paramref name="path"/> -- its FILE NAME, never the path, as the
    /// UTF-8 bytes <c>jas_document_set_filename</c> takes (BL5: a string would
    /// cross as ANSI and mangle a non-ASCII name). Null when there is no file
    /// name to send, which the engine would refuse anyway.
    /// </summary>
    internal static byte[]? DocumentNameBytes(string? path)
    {
        var name = System.IO.Path.GetFileName(path);
        return string.IsNullOrEmpty(name) ? null : System.Text.Encoding.UTF8.GetBytes(name);
    }

    /// <summary>
    /// §257 (#406): does a save to <paramref name="path"/> give the document a
    /// new name? True for the first save of an untitled document and for a
    /// save to another file; false for a save back to the file it came from.
    /// Windows paths compare without case.
    /// </summary>
    internal static bool IsNewDocumentPath(string? current, string path) =>
        current is null
        || !string.Equals(System.IO.Path.GetFullPath(current), System.IO.Path.GetFullPath(path),
                          StringComparison.OrdinalIgnoreCase);

    internal static byte[]? PictureBytes(string? uri)
    {
        const string prefix = "data:image/bmp;base64,";
        if (uri is null || !uri.StartsWith(prefix, StringComparison.Ordinal)) { return null; }
        try
        {
            var bytes = Convert.FromBase64String(uri.Substring(prefix.Length));
            return bytes.Length >= 2 && bytes[0] == (byte)'B' && bytes[1] == (byte)'M' ? bytes : null;
        }
        catch (FormatException) { return null; }
    }

    /// <summary>A reading of a leaf the plan does not hold, or of a key the leaf does not carry.</summary>
    internal const string Absent = "ABSENT";

    /// <summary>A reading from bytes that are not a plan, or of a value that is not a string.</summary>
    internal const string Unreadable = "UNREADABLE";

    /// <summary>
    /// W2b-3: one resolved value of one plan leaf, exactly as the plan carries
    /// it -- the reading the value replay's row reports at each step.
    ///
    /// Returns the value string of `values[key]` on the FIRST leaf whose `id`
    /// is <paramref name="widgetId"/>; <see cref="Absent"/> when no leaf has
    /// that id (an empty id is never matched, so an id-less text leaf is never
    /// read) or the leaf carries no such key; <see cref="Unreadable"/> when the
    /// bytes are not a plan (no parse, not an object, no `leaves` array) or
    /// the value is not a string.
    ///
    /// ⛔ AN EMPTY STRING IS A VALUE, NOT ABSENT. A reader that folded the two
    /// would hand the harness a missing reading that looks like a real one.
    /// </summary>
    internal static string LeafValue(string planJson, string widgetId, string key)
    {
        if (widgetId.Length == 0) { return Absent; }
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(planJson);
            var root = doc.RootElement;
            if (root.ValueKind != System.Text.Json.JsonValueKind.Object
                || !root.TryGetProperty("leaves", out var leaves)
                || leaves.ValueKind != System.Text.Json.JsonValueKind.Array)
            {
                return Unreadable;
            }
            foreach (var leaf in leaves.EnumerateArray())
            {
                if (leaf.ValueKind != System.Text.Json.JsonValueKind.Object
                    || !leaf.TryGetProperty("id", out var id)
                    || id.ValueKind != System.Text.Json.JsonValueKind.String
                    || !string.Equals(id.GetString(), widgetId, StringComparison.Ordinal))
                {
                    continue;
                }
                if (!leaf.TryGetProperty("values", out var values)
                    || values.ValueKind != System.Text.Json.JsonValueKind.Object
                    || !values.TryGetProperty(key, out var value))
                {
                    return Absent;
                }
                return value.ValueKind == System.Text.Json.JsonValueKind.String
                    ? value.GetString() ?? Unreadable
                    : Unreadable;
            }
            return Absent;
        }
        catch (System.Text.Json.JsonException)
        {
            return Unreadable;
        }
    }

    /// <summary>
    /// W2b-3: `SB_PANEL_COMMIT=&lt;widget&gt;:&lt;text&gt;` as (widget, text),
    /// split at the FIRST `:`, ordinal. The text is kept verbatim -- spaces,
    /// later colons, or nothing at all: the core decides what it means.
    ///
    /// Null when there is no `:`, or when the widget is empty or whitespace
    /// (the predicate every pane knob uses for unset), so the caller refuses
    /// the knob by name instead of replaying on a widget nobody named. The
    /// harness splits with the same rule (`Split-SbCommitKnob`).
    /// </summary>
    internal static (string Widget, string Text)? SplitCommitKnob(string knob)
    {
        var colon = knob.IndexOf(':', StringComparison.Ordinal);
        if (colon < 0) { return null; }
        var widget = knob[..colon];
        if (string.IsNullOrWhiteSpace(widget)) { return null; }
        return (widget, knob[(colon + 1)..]);
    }
}

/// <summary>
/// §1.2: one row of a dropdown's `items` channel. `Kind` is `action` or
/// `toggle` (a separator carries neither value nor label). `Checked` is the
/// core's answer (a toggle's membership, an action's being in force), and null
/// when the core does not know it: never read as false by the reader. See <see cref="PanelWire.ReadItems"/>.
/// </summary>
internal sealed record PaneItem(bool Separator, string Kind, string Value, string Label, bool? Checked);

/// <summary>§1.2: a dropdown's items as the core sent them, and how many rows
/// this shell could not read (COUNTED, never guessed at).</summary>
internal sealed record PaneItems(List<PaneItem> Rows, int Refused);

/// <summary>FORK A: a slider's drawn range, from the plan's `numbers`.</summary>
internal sealed record SliderTrack(double Min, double Max, double? Step);

/// <summary>
/// W-b: one row of a plan entry's `options` channel. A separator carries no
/// value and is never offered; see <see cref="PanelWire.ReadOptions"/>.
/// </summary>
internal sealed record PaneOption(bool Separator, string Value, string Label, string? Glyph, bool Selected);

/// <summary>
/// W-b: a leaf's options as the core sent them, and how many rows this shell
/// could not read (an unknown `kind`, or an option row missing a string). A
/// refused row is COUNTED, never guessed at.
/// </summary>
internal sealed record PaneOptions(List<PaneOption> Rows, int Refused)
{
    /// <summary>
    /// The rows a list control holds: the VALUES, in order, separators dropped.
    /// ⛔ A ComboBox item is selectable, so a divider placed among the items
    /// would be a value a person can pick. The grouping is lost, knowingly;
    /// what is never lost is the difference between a divider and a value.
    /// </summary>
    internal List<PaneOption> Items => Rows.Where(r => !r.Separator).ToList();

    /// <summary>
    /// The index into <see cref="Items"/> of the row the core marked
    /// `selected`, or -1 when it marked none (a free combo entry, a dialog's
    /// display-only "Custom"). The shell compares no values to find it.
    /// </summary>
    internal int SelectedIndex => Items.FindIndex(r => r.Selected);

    /// <summary>What a rebuild keys on: the list, never the selection, which moves.</summary>
    internal string Signature => string.Join(";", Rows.Select(r =>
        r.Separator ? "-" : $"{RowToken(r.Value)}={RowToken(r.Label)}={RowToken(r.Glyph ?? "")}"));

    private static string RowToken(string s) => System.Text.Json.JsonSerializer.Serialize(s);
}

/// <summary>The panels the pane can show, in the core's order, and how many rows could not be offered.</summary>
internal sealed record PanelChoices(List<(string Id, string Label)> Rows, int Skipped);

/// <summary>
/// Step 3 (2026-10-11): which panes a run opens, from its knobs. Pure, so
/// `sb_winui_tests` drives it.
/// </summary>
internal static class PaneKnobs
{
    /// <summary>The toolbar is ON BY DEFAULT under `app`: `SB_TOOLBAR=0` is the
    /// one way off, and any other value, or none, is on. Off `app` a value that
    /// asks for it is "refused" (refused by name, never ignored), and `0`, which
    /// asks for nothing, is "off". Blank is unset, the same predicate as every
    /// other pane knob.</summary>
    internal static string Toolbar(string? knob, bool appScene)
    {
        var v = string.IsNullOrWhiteSpace(knob) ? null : knob.Trim();
        if (v == "0") return "off";
        if (appScene) return "on";
        return v is null ? "off" : "refused";
    }
}

/// <summary>
/// A menu label as `menubar.yaml` writes it, as WinUI must show it. Pure, so
/// `sb_winui_tests` drives it.
/// </summary>
internal static class MenuWire
{
    /// <summary>`&File` is "File" with access key "F". `&&` is a literal `&`;
    /// the FIRST single `&` before a character marks the key; a trailing `&`
    /// marks nothing and is kept. WinUI parses none of this itself, so without
    /// it the in-window MenuBar showed `&File` (his note 4a, 2026-10-11).</summary>
    internal static (string Text, string Key) Label(string? raw)
    {
        if (string.IsNullOrEmpty(raw)) return ("", "");
        var text = new System.Text.StringBuilder(raw.Length);
        var key = "";
        for (var i = 0; i < raw.Length; i++)
        {
            if (raw[i] == '&' && i + 1 < raw.Length)
            {
                if (raw[i + 1] == '&') { text.Append('&'); i++; continue; }
                if (key == "") key = raw[i + 1].ToString().ToUpperInvariant();
                continue;
            }
            text.Append(raw[i]);
        }
        return (text.ToString(), key);
    }
}

/// <summary>
/// SB_TOOL, read against the core's own tool list. Pure, so `sb_winui_tests`
/// drives it.
/// </summary>
internal static class ToolKnob
{
    /// <summary>The index `knob` names in `names` (the core's `jas_tool_name`
    /// list): a decimal index below the count, or a tool name compared
    /// ordinally. -1 refuses it, and the caller refuses the run by name; a run
    /// that asked for a tool must never silently get selection.</summary>
    internal static int Resolve(string? knob, IReadOnlyList<string> names)
    {
        var v = knob?.Trim() ?? "";
        if (v.Length == 0) return -1;
        if (v.All(char.IsAsciiDigit))
        {
            return int.TryParse(v, out var i) && i < names.Count ? i : -1;
        }
        for (var i = 0; i < names.Count; i++)
        {
            if (string.Equals(names[i], v, StringComparison.Ordinal)) return i;
        }
        return -1;
    }
}

/// <summary>
/// One row of `jas_panel_menu`: a node of a panel's `menu:`, as the core
/// evaluated it. `Checked` is null for a row that is not checkable.
/// </summary>
internal sealed record PanelMenuRow(int Index, string Kind, string Label, string Action, bool Enabled, bool? Checked);

/// <summary>
/// The panel menu (the owner's note 3, 2026-10-12), read off the core's rows
/// and the synth knob. Pure, so `sb_winui_tests` drives it. The shell
/// evaluates nothing here: label, enabled and checked are the core's.
/// </summary>
internal static class PanelMenuWire
{
    /// <summary>`jas_panel_menu`'s array. Empty or unreadable is an empty menu,
    /// never a throw; the caller reports the count it drew.</summary>
    internal static List<PanelMenuRow> Parse(string? json)
    {
        var rows = new List<PanelMenuRow>();
        if (string.IsNullOrWhiteSpace(json)) return rows;
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != System.Text.Json.JsonValueKind.Array) return rows;
            foreach (var r in doc.RootElement.EnumerateArray())
            {
                static string Str(System.Text.Json.JsonElement e, string k) =>
                    e.TryGetProperty(k, out var v) && v.ValueKind == System.Text.Json.JsonValueKind.String ? v.GetString() ?? "" : "";
                bool? chk = r.TryGetProperty("checked", out var c) && (c.ValueKind == System.Text.Json.JsonValueKind.True || c.ValueKind == System.Text.Json.JsonValueKind.False)
                    ? c.GetBoolean() : null;
                var en = !r.TryGetProperty("enabled", out var en0) || en0.ValueKind != System.Text.Json.JsonValueKind.False;
                rows.Add(new PanelMenuRow(
                    r.TryGetProperty("index", out var i) && i.TryGetInt32(out var iv) ? iv : rows.Count,
                    Str(r, "kind"), Str(r, "label"), Str(r, "action"), en, chk));
            }
        }
        catch (System.Text.Json.JsonException) { rows.Clear(); }
        return rows;
    }

    /// <summary>`SB_PANEL_MENU_SYNTH=&lt;group key&gt;:&lt;index&gt;`, or null for
    /// anything else (the caller refuses a set knob it cannot read, by name).</summary>
    internal static (string Group, int Index)? SynthKnob(string? knob)
    {
        if (string.IsNullOrWhiteSpace(knob)) return null;
        var at = knob.IndexOf(':');
        if (at <= 0) return null;
        var group = knob[..at].Trim();
        var idx = knob[(at + 1)..].Trim();
        if (group.Length == 0 || idx.Length == 0 || !idx.All(char.IsAsciiDigit)) return null;
        return int.TryParse(idx, out var n) ? (group, n) : null;
    }
}

/// <summary>
/// S2: one reading of `jas_dialog_plan` (#419). `Depth` is how many dialogs
/// the engine holds (2 when the Color Picker sits over Layer Options); the
/// shell draws only the TOP one, whose plan this is.
/// </summary>
internal sealed record DialogReading(bool Open, string Id, string Summary, bool Modal, int Depth, string? PlanJson,
                                     long? Width = null);

/// <summary>
/// S2, the dialog door's shell half: the two replies the overlay host reads.
/// ⛔ A REPLY THIS CANNOT READ IS NULL, NEVER "CLOSED": reading it as closed
/// would hide a dialog the engine still holds, and every later click would go
/// to panels under a modal the person cannot see.
/// </summary>
internal static class DialogWire
{
    /// <summary>`{"open": false}`, or `{"open": true, "id", "summary", "modal",
    /// "depth", "plan"}`; null when the bytes are not that.</summary>
    internal static DialogReading? Read(string json)
    {
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (!root.TryGetProperty("open", out var open)
                || open.ValueKind is not (System.Text.Json.JsonValueKind.True or System.Text.Json.JsonValueKind.False))
            {
                return null;
            }
            if (!open.GetBoolean()) { return new DialogReading(false, "", "", false, 0, null); }
            if (!root.TryGetProperty("id", out var id) || id.ValueKind != System.Text.Json.JsonValueKind.String
                || !root.TryGetProperty("plan", out var plan) || plan.ValueKind != System.Text.Json.JsonValueKind.Object)
            {
                return null;
            }
            var name = id.GetString() ?? "";
            var summary = root.TryGetProperty("summary", out var s) && s.ValueKind == System.Text.Json.JsonValueKind.String
                ? s.GetString() ?? name
                : name;
            var modal = root.TryGetProperty("modal", out var m) && m.ValueKind == System.Text.Json.JsonValueKind.True;
            var depth = root.TryGetProperty("depth", out var d) && d.TryGetInt32(out var n) ? n : 1;
            // §271: the declared width, or null. Null, a missing key (an older
            // engine), or anything but a positive integer is "none declared".
            long? width = root.TryGetProperty("width", out var w) && w.ValueKind == System.Text.Json.JsonValueKind.Number
                          && w.TryGetInt64(out var wv) && wv > 0 ? wv : null;
            return new DialogReading(true, name, summary, modal, depth, plan.GetRawText(), width);
        }
        catch (System.Text.Json.JsonException)
        {
            return null;
        }
    }

    /// <summary>The width a dialog is planned at: its declared one, else the
    /// shell's default (jas §271: the engine invents none).</summary>
    internal static long PlanWidth(long? declared, long fallback) => declared ?? fallback;

    /// <summary>The dialog an act's reply names as open after it (#414's
    /// `"dialog": <id> | null`); null when it names none or cannot be read.</summary>
    internal static string? Named(string reply)
    {
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(reply);
            return doc.RootElement.ValueKind == System.Text.Json.JsonValueKind.Object
                   && doc.RootElement.TryGetProperty("dialog", out var d)
                   && d.ValueKind == System.Text.Json.JsonValueKind.String
                ? d.GetString()
                : null;
        }
        catch (System.Text.Json.JsonException)
        {
            return null;
        }
    }
}

/// <summary>The keys an action reply carries for the shell to act on.</summary>
internal static class ActWire
{
    /// <summary>
    /// jas §274: what a named tab removal means in THIS shell, which holds one
    /// document at index 0. `close`: call `jas_document_close`. `no-such-tab`:
    /// any other index, refused by name, never mapped onto tab 0.
    /// </summary>
    internal static string Removal(int index) => index == 0 ? "close" : "no-such-tab";

    /// <summary>`jas_document_close`'s byte, read: 1 closed, 0 none was open,
    /// 255 no engine; any other byte is no answer, never a guess.</summary>
    internal static string CloseReading(byte rc) => rc switch
    {
        1 => "closed",
        0 => "none-open",
        255 => "no-engine",
        _ => $"unknown({rc})",
    };

    /// <summary>
    /// #422: `"remove_tab": <index> | null`. The engine owns no tabs, so an
    /// unedited `close_tab`, or Save Changes' Discard, NAMES the tab and the
    /// shell removes it. Null when the reply names none, an older engine sent
    /// no key, or the value is not a non-negative integer.
    /// </summary>
    internal static int? RemoveTab(string reply)
    {
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(reply);
            return doc.RootElement.ValueKind == System.Text.Json.JsonValueKind.Object
                   && doc.RootElement.TryGetProperty("remove_tab", out var t)
                   && t.ValueKind == System.Text.Json.JsonValueKind.Number
                   && t.TryGetInt32(out var i) && i >= 0
                ? i
                : null;
        }
        catch (System.Text.Json.JsonException)
        {
            return null;
        }
    }
}
