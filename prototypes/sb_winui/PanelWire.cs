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
