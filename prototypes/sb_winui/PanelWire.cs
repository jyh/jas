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
    /// jas item 40: a `keydown` also carries `key`, the key's W3C name
    /// (<see cref="KeyName"/>); every other event carries none.
    internal static byte[] EventJson(string widget, string eventName, string? value,
                                     bool alt, bool shift, bool ctrl, bool meta,
                                     string? path = null, string? key = null)
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
        if (key is not null) { ev["key"] = key; }
        if (PlanPath(path) is { } p) { ev["path"] = p; }
        return System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(ev);
    }

    /// <summary>
    /// jas item 40: the W3C name a text field's key crosses as, from WinUI's
    /// `VirtualKey` name, or null for a key the box keeps (it types, moves the
    /// caret, or has no behaviour in any template yet). Only Enter and Escape
    /// have behaviours today (`layers.yaml`, `artboards.yaml`); sending every
    /// keystroke would cross the boundary once per character to be refused
    /// `EmptyBehavior`.
    /// </summary>
    internal static string? KeyName(string virtualKey) => virtualKey switch
    {
        "Enter" => "Enter",
        "Escape" => "Escape",
        _ => null,
    };

    /// <summary>
    /// Whether the plan says a node answers <paramref name="eventName"/>
    /// (<see cref="ReadEvents"/>). No channel answers nothing.
    /// </summary>
    internal static bool Answers(IReadOnlyList<string>? events, string eventName) =>
        events is not null && events.Contains(eventName);

    /// <summary>
    /// The plan paths of the text fields a draw shows (`text_input`,
    /// `number_input`, `length_input`), in plan order.
    /// </summary>
    internal static List<string> ShownInputs(IEnumerable<(string Path, string Type, bool Shown)> leaves) =>
        leaves.Where(l => l.Shown && l.Type is "text_input" or "number_input" or "length_input")
              .Select(l => l.Path).ToList();

    /// <summary>
    /// jas §647/#757: the field to give the keyboard after a draw: the first one
    /// shown now that the last draw of the same panel did not show (F2's rename
    /// field), as the web's and the Mac's rename inputs take focus when they
    /// appear. Null when none is new, and on a panel's first draw
    /// (<paramref name="before"/> null), so opening a panel never takes focus.
    /// </summary>
    internal static string? InputToFocus(IReadOnlySet<string>? before, IReadOnlyList<string> now) =>
        before is null ? null : now.FirstOrDefault(p => !before.Contains(p));

    /// <summary>
    /// flask §656: the row a press on <paramref name="leafPath"/> belongs to when
    /// the leaf does not answer `click` itself: the innermost surface whose path
    /// strictly encloses the leaf's and which routes `click`
    /// (<see cref="RoutesPress"/>), as a click bubbles to its row on the web. A
    /// Layers name answers only `double_click`, and a surface is a SIBLING drawn
    /// beneath its leaves, so without this the name took the press and sent
    /// nothing. Null when no surface around the leaf answers.
    /// </summary>
    internal static HitBox? PressTarget(IReadOnlyList<HitBox> hits, string leafPath)
    {
        HitBox? best = null;
        foreach (var hit in hits)
        {
            // "[3,5" + "," so that [3,5] encloses [3,5,7] and not [3,50,7].
            var prefix = hit.Path.TrimEnd(']') + ",";
            if (!leafPath.StartsWith(prefix, StringComparison.Ordinal)) { continue; }
            if (!RoutesPress(hit.Events, hit.Id, hit.Path)) { continue; }
            if (best is null || hit.Path.Length > best.Path.Length) { best = hit; }
        }
        return best;
    }

    /// <summary>
    /// The event JSON for a gesture on a stops kind (`WIDGET_EVENTS.md` §The
    /// stops kind): `value` is an OBJECT of the gesture's RAW parameters (an
    /// `index`, a `pair`, a `location` in percent, a `dy` in DIPs), never a
    /// string, because the engine reads them as numbers. Everything else is
    /// <see cref="EventJson"/>'s envelope. The shell computes no step of the
    /// slider law; the engine does.
    /// </summary>
    internal static byte[] GestureJson(string widget, string gesture, IReadOnlyDictionary<string, object> parameters,
                                       bool alt, bool shift, bool ctrl, bool meta, string? path = null)
    {
        var ev = new Dictionary<string, object>
        {
            ["widget"] = widget,
            ["event"] = gesture,
            ["alt"] = alt,
            ["shift"] = shift,
            ["ctrl"] = ctrl,
            ["meta"] = meta,
            ["value"] = parameters,
        };
        if (PlanPath(path) is { } p) { ev["path"] = p; }
        return System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(ev);
    }

    /// <summary>A gesture's parameters as one whitespace-free row token: the
    /// compact JSON object, with a space escaped as <see cref="RowValue"/> does.</summary>
    internal static string GestureRowValue(IReadOnlyDictionary<string, object> parameters) =>
        System.Text.Json.JsonSerializer.Serialize(parameters).Replace(" ", "\\u0020");

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
    /// A leaf's resolved `bind.z_index` as a draw order, or null. The core
    /// resolves the binding (the toolbar swatches: `if state.fill_on_top then 2
    /// else 1`); the shell only applies it. A fraction or a word names no order
    /// and is refused, never rounded.
    /// </summary>
    internal static int? ZIndex(string? resolved) =>
        double.TryParse(resolved, System.Globalization.NumberStyles.Float,
                        System.Globalization.CultureInfo.InvariantCulture, out var d)
        && d == Math.Floor(d) && d is >= int.MinValue and <= int.MaxValue
            ? (int)d
            : null;

    /// <summary>
    /// The events a plan entry says its node ANSWERS (`"events"`, #464), in
    /// the order the core sent them. Null when there is no channel (an older
    /// core) or it is not an array; a non-string entry is skipped. `[]` is an
    /// answer: the node answers nothing.
    /// </summary>
    internal static IReadOnlyList<string>? ReadEvents(string? eventsJson)
    {
        if (string.IsNullOrEmpty(eventsJson)) { return null; }
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(eventsJson);
            var root = doc.RootElement;
            if (root.ValueKind != System.Text.Json.JsonValueKind.Array) { return null; }
            var events = new List<string>();
            foreach (var v in root.EnumerateArray())
            {
                if (v.ValueKind == System.Text.Json.JsonValueKind.String) { events.Add(v.GetString()!); }
            }
            return events;
        }
        catch (System.Text.Json.JsonException) { return null; }
    }

    /// <summary>
    /// Whether a press on a leaf is sent as `click`: the plan says the node
    /// answers `click`, and the leaf has an address (<see cref="Addressable"/>).
    /// The shell does not decide by kind (jas §316): an Artboards row's `text`
    /// answers `click`, a heading's does not. No list routes nothing.
    /// </summary>
    internal static bool RoutesPress(IReadOnlyList<string>? events, string id, string? path) =>
        events is not null && events.Contains("click") && Addressable(id, path);

    /// <summary>
    /// S1: a `button`'s face. A `bind: label:` expression arrives in the
    /// leaf's `values` as `bind.label` and replaces the label, as the web's
    /// `render_button` does (a Concepts operation button's "Add Side", the
    /// Opacity panel's Make Mask / Release); until 2026-10-26 the shell never
    /// read it and drew those buttons blank (flask STATUS § 568, finding K).
    /// Next, the core resolves a `{{`-bearing label into `values` as `label`
    /// (Save Changes' "Save {{param.filename}}") and sends a literal one in
    /// `static`; the resolved one wins over the literal. With no label, the
    /// summary, then the id, as `icon_button`'s text face falls back. Never null.
    /// </summary>
    internal static string ButtonLabel(string? bindLabel, string? resolvedLabel, string? literalLabel, string? summary, string id) =>
        bindLabel ?? resolvedLabel ?? literalLabel ?? summary ?? id;

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
    /// S3: which rule a `separator` draws in its rect. A declared
    /// `orientation` (a STATIC_KEY since #439) wins; an unknown one draws
    /// nothing rather than a guess. A separator that declares none follows
    /// the plan's own geometry: wider than tall (or square) is horizontal,
    /// taller is vertical. An empty rect draws nothing (null).
    /// </summary>
    internal static string? SeparatorRule(string? declared, double w, double h) =>
        w <= 0 || h <= 0 ? null
        : declared is null ? (w >= h ? "horizontal" : "vertical")
        : declared is "horizontal" or "vertical" ? declared
        : null;

    /// <summary>
    /// S3 (#429, WIDGET_EVENTS.md): what a press on a radio sends. `radio` is a
    /// check kind: `click`, no value. `radio_group` is an option kind: `toggle`
    /// carrying the pressed option's id. A press on the checked one is the
    /// engine's to refuse (`AlreadyChecked`), never filtered here.
    /// </summary>
    internal static (string Event, string? Value) RadioEvent(string type, string optionValue) =>
        type == "radio_group" ? ("toggle", optionValue) : ("click", null);

    /// <summary>
    /// #434: a `reference_point_widget`'s rows are its kind's nine anchors, row
    /// by row. The face lays any perfect-square count out as a square grid and
    /// refuses (null) any other, so it never assumes nine.
    /// </summary>
    internal static int? GridColumns(int count)
    {
        for (var n = 1; n * n <= count; n++)
        {
            if (n * n == count) { return n; }
        }
        return null;
    }

    /// <summary>
    /// #431: an `icon_button_group`'s buttons sit side by side in the plan's
    /// rect, each square: the rect's height, or an equal share of its width
    /// when that is narrower. No options is no cell.
    /// </summary>
    internal static double GroupCellSide(double w, double h, int count) =>
        count <= 0 ? 0 : (w / count < h ? w / count : h);

    /// <summary>Row-by-row placement: the <paramref name="index"/>th row's cell.</summary>
    internal static (int Row, int Column) GridCell(int index, int columns) => (index / columns, index % columns);

    /// <summary>A `radio_group` option's face: its label as the core sent it,
    /// empty included (the picker's channel radios carry none), never its id.</summary>
    internal static string RadioFace(PaneOption row) => row.Label;

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
                rows.Add(new PaneOption(false, value, label, Str(row, "glyph"), selected, Str(row, "icon")));
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
    /// What an editable combo sends when a person LEAVES it (flask § 451,
    /// § 457): the typed text, as a text box's blur commits it, or null. Null
    /// when focus stayed inside the combo (into its own dropdown), when there
    /// is no readable text or it is empty or whitespace (flask § 459: putting
    /// the box back after a commit can leave it empty, and the next blur sent
    /// "" to the engine), when the text is what the core showed (its value
    /// or its label: <c>CommitOnBlur</c>'s rule), and when it names an item,
    /// which is a pick and goes by the selection path as Enter's does.
    /// </summary>
    internal static string? ComboBlurCommit(string? typed, string shownValue, string shownText,
        IEnumerable<string> itemTexts, bool focusStaysInCombo)
    {
        if (focusStaysInCombo || string.IsNullOrWhiteSpace(typed)) { return null; }
        if (!CommitOnBlur(typed, shownValue) || !CommitOnBlur(typed, shownText)) { return null; }
        return itemTexts.Any(t => string.Equals(t, typed, StringComparison.Ordinal)) ? null : typed;
    }

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
    /// Whether an EDITABLE combo's selection change is a person's pick: one made
    /// in its list, open now or closed by that same pick. Any other move is the
    /// platform COMPLETING typed text to an option (`13` to `135`), and it is not
    /// sent; the typed text goes by Enter or blur. flask § 499: after a
    /// re-entry completed `13`, Enter committed the selected `135` over a typed
    /// `31`.
    ///
    /// ⛔ NOT "the box shows the item's text": a completion WRITES that text, so
    /// that test passed it (§ 500). And there is no pick with the list closed:
    /// Down there changes nothing (§ 500, measured), so the list is the only door.
    /// </summary>
    internal static bool EditablePickIsReal(bool dropDownOpen, bool listJustClosed) =>
        dropDownOpen || listJustClosed;

    /// <summary>
    /// The item Up or Down picks in an editable combo with its list SHUT: the
    /// one after (or before) the core's own, staying put at either end; from a free
    /// value (no item, -1), Down picks the first and Up the last. -1 when the
    /// list is empty. flask § 505: the platform's own Down stepped the box
    /// `90` to `135` and sent nothing, so the shell takes the key and picks.
    /// </summary>
    internal static int ArrowPick(int coreIndex, int count, bool down)
    {
        if (count <= 0) { return -1; }
        if (coreIndex < 0 || coreIndex >= count) { return down ? 0 : count - 1; }
        if (down) { return coreIndex == count - 1 ? coreIndex : coreIndex + 1; }
        return coreIndex == 0 ? 0 : coreIndex - 1;
    }

    /// <summary>
    /// The text an editable combo's blur commits: the editor's, unless the
    /// platform has BLANKED it, when it is what the person last typed. flask
    /// § 504: putting the selection back to -1 blanked the editor after the
    /// undo had written the typed `13`, so the blur read `''` and the entry was
    /// lost. A box the person emptied themselves types `''`, which stays blank.
    /// </summary>
    internal static string? BlurText(string? box, string? typed) =>
        string.IsNullOrEmpty(box) ? typed : box;

    /// <summary>
    /// What Enter in an editable combo sends, from the EDITOR's text: the value
    /// of the item it names, or the text itself when it names none; nothing
    /// when it is the core's own value or text, or blank. The shell takes Enter
    /// itself (flask § 503: the platform's Enter resolved its own stale text,
    /// `135`, over the editor's `31`, and raised no TextSubmitted).
    /// </summary>
    internal static string? EnterCommit(string? typed, string shownValue, string shownText, List<PaneOption> items)
    {
        if (string.IsNullOrWhiteSpace(typed)) { return null; }
        var named = items.FindIndex(r => string.Equals(ChoiceText(r), typed, StringComparison.Ordinal));
        if (named >= 0) { return ChoiceCommit(named, items, shownValue); }
        return CommitOnBlur(typed, shownValue) && CommitOnBlur(typed, shownText) ? typed : null;
    }

    /// <summary>
    /// W-b: the text an item shows in the list. An `icon_select` row carries a
    /// `glyph` (a single mark, "•") beside its label, and both are shown; any
    /// other row shows its label.
    /// </summary>
    internal static string ChoiceText(PaneOption row) =>
        row.Glyph is { Length: > 0 } g ? $"{g}  {row.Label}" : row.Label;

    /// <summary>One part of a leaf (row 56), relative to the leaf's own origin, in DIPs.</summary>
    internal readonly record struct PartRect(double X, double Y, double W, double H);

    /// <summary>
    /// #803's LOW (jas, 10-31), measured on the box: the border a pane button
    /// wears, applied on every refresh. A labelled face (row 56's parts) wears
    /// none in either state: its parts are in the leaf's own coordinates and the
    /// web's face draws no border, so the style's 1-DIP border put both parts
    /// 1.33 DIP right and down of the plan. Any other button keeps its checked
    /// edge (1); unchecked it takes the style's (null: clear the local value).
    /// </summary>
    internal static double? ButtonEdge(bool on, bool labelledFace) => labelledFace ? 0 : on ? 1 : null;

    /// <summary>A labelled icon_button's parts (row 56): its icon, and its label when the engine planned room for one.</summary>
    internal sealed record LeafParts(PartRect Icon, PartRect? Label);

    /// <summary>
    /// ROW 56 (#796): a labelled `icon_button`'s `parts`, the icon's and the
    /// label's rects, which the engine plans in plan coordinates. Read relative to
    /// the leaf's own origin (`leafX`, `leafY`), the shell's one subtraction; the
    /// shell does no layout of its own. Null (an icon-only button) when there is no
    /// `parts`, no usable icon (four numbers, a positive size), or the text is not
    /// JSON. A label of no width is dropped and the icon kept.
    /// </summary>
    internal static LeafParts? ReadParts(string? partsJson, long leafX, long leafY)
    {
        if (string.IsNullOrEmpty(partsJson)) { return null; }
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(partsJson);
            PartRect? Read(string key)
            {
                if (doc.RootElement.ValueKind != System.Text.Json.JsonValueKind.Object
                    || !doc.RootElement.TryGetProperty(key, out var r)
                    || r.ValueKind != System.Text.Json.JsonValueKind.Object) { return null; }
                double? N(string k) => r.TryGetProperty(k, out var v) && v.ValueKind == System.Text.Json.JsonValueKind.Number
                    ? v.GetDouble() : null;
                return N("x") is { } x && N("y") is { } y && N("w") is { } w && N("h") is { } h && w > 0 && h > 0
                    ? new PartRect(x - leafX, y - leafY, w, h)
                    : null;
            }
            return Read("icon") is { } icon ? new LeafParts(icon, Read("label")) : null;
        }
        catch (System.Text.Json.JsonException)
        {
            return null;
        }
    }

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
    /// How a WinUI Slider fits a planned height (the 10-30 sitting, finding 15):
    /// the thumb, its inner dot, and the equal margins that centre it, or null
    /// when the plan's height already holds the template. WinAppSDK 1.8's
    /// template stacks `SliderPreContentMargin` (14), an 18-DIP thumb and
    /// `SliderPostContentMargin` (14): 46 DIP. In Swatch Options' 12-DIP rows
    /// the track was clipped and only the thumb's top showed. The shell sets
    /// these as the control's own theme resources.
    ///
    /// ⛔ NO FLOOR, NO CLAMP (check_shell_interaction_path, F-6). The template's
    /// own 18-DIP thumb when the row holds it between 1-DIP edges; otherwise
    /// the thumb the row has room for. A row with no room for any thumb is
    /// REFUSED (null), never drawn with one it cannot hold. A first version
    /// floored the thumb at 6 DIP, which gave a 2-DIP row a NEGATIVE margin.
    /// </summary>
    internal static (double Thumb, double Inner, double Margin)? SliderFit(double planHeight)
    {
        const double natural = 14 + 18 + 14, templateThumb = 18, edges = 2;
        if (!(planHeight > edges) || planHeight >= natural) { return null; }
        var thumb = planHeight >= templateThumb + edges ? templateThumb : planHeight - edges;
        return (thumb, Math.Round(thumb * 2 / 3, 2), (planHeight - thumb) / 2);
    }

    /// <summary>
    /// The scale that fits a WinUI RadioButton into a planned height (finding
    /// 14), or null when it fits as it is. Its template draws a 20-DIP circle
    /// centred in a FIXED 32-DIP row, and no theme resource sizes either, so
    /// the color picker's shorter rows showed part of a circle.
    /// </summary>
    internal static double? RadioScale(double planHeight) =>
        planHeight > 0 && planHeight < RadioNaturalHeight ? planHeight / RadioNaturalHeight : null;

    /// <summary>The row height WinUI's RadioButton template draws in.</summary>
    internal const double RadioNaturalHeight = 32;

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
    /// Finding 13, step 4: the point a picker surface sends. The Color Picker's
    /// strip (`color_hue_bar`) sends ONE number, `v`, since its pick never reads
    /// a `u` (WIDGET_EVENTS.md); the field (`color_gradient`) and the colour bar
    /// send `u,v` (<see cref="ColorBarPoint"/>). Null when the surface or the
    /// pointer names no point.
    /// </summary>
    internal static string? PickerPoint(string kind, double x, double y, double width, double height) =>
        kind == "color_hue_bar"
            ? double.IsFinite(y) && double.IsFinite(height) && height > 0 ? ContractNumber(y / height) : null
            : ColorBarPoint(x, y, width, height);

    /// <summary>
    /// A held move sends `change` only when it names a new point, so a pointer
    /// that reports the same spot twice costs the engine nothing.
    /// </summary>
    internal static string? ColorBarChange(string? point, string? lastSent) =>
        point is not null && point != lastSent ? point : null;

    /// <summary>
    /// jas §612: a layout container that answers events (a Layers or Artboards
    /// row, the Layers select square), by path; drawn as a transparent surface
    /// beneath its children, so a child's own control wins the press.
    /// </summary>
    internal sealed record HitBox(string Path, string Id, double X, double Y, double W, double H, IReadOnlyList<string> Events,
                                  string? Background = null, string? Border = null);

    /// <summary>
    /// jas §630: a surface's paint, from its `bind.background`: a `#rrggbb`
    /// paints (a panel-selected row's highlight); `transparent`, an absent key
    /// or anything else paints nothing. Never a guess: an unresolved template
    /// is withheld by the plan and would not arrive, and if it did it is not a
    /// colour.
    /// </summary>
    internal static (byte R, byte G, byte B)? SurfaceFill(string? background) => SwatchColor(background);

    /// <summary>
    /// The 10-30 sitting, finding 6: a surface's border, from its `bind.border`
    /// (#769 binds the Layers select square's, e.g. `1px solid #555555`; the
    /// colour follows the appearance). Exactly `&lt;w&gt;px solid #rrggbb` with a
    /// positive width draws; any other spelling (another style, no colour, a
    /// template) is refused, never guessed.
    /// </summary>
    internal static (double Width, byte R, byte G, byte B)? SurfaceBorder(string? border)
    {
        if (border is null) { return null; }
        var m = System.Text.RegularExpressions.Regex.Match(border,
            @"^\s*(\d+(?:\.\d+)?)px\s+solid\s+(#[0-9a-fA-F]{6})\s*$");
        if (!m.Success
            || !double.TryParse(m.Groups[1].Value, System.Globalization.NumberStyles.Float,
                                System.Globalization.CultureInfo.InvariantCulture, out var width)
            || !(width > 0)
            || SwatchColor(m.Groups[2].Value) is not { } c) { return null; }
        return (width, c.R, c.G, c.B);
    }

    /// <summary>
    /// jas §612: the plan's layout containers (`chrome` and `containers`, in plan
    /// order) whose `events` is non-empty, with any under a `hidden` path
    /// skipped. Leaves are their own controls and never surfaces. Null when the
    /// plan does not parse: never read as "no surfaces".
    /// </summary>
    internal static List<HitBox>? HitBoxes(string planJson)
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
            var boxes = new List<HitBox>();
            foreach (var list in new[] { "chrome", "containers" })
            {
                if (!root.TryGetProperty(list, out var entries)) { continue; }
                foreach (var e in entries.EnumerateArray())
                {
                    if (ReadEvents(e.TryGetProperty("events", out var evs) ? evs.GetRawText() : null) is not { Count: > 0 } events) { continue; }
                    var p = e.GetProperty("path").EnumerateArray().Select(x => x.GetInt64()).ToArray();
                    if (hidden.Any(h => h.Length <= p.Length && h.SequenceEqual(p.Take(h.Length)))) { continue; }
                    var r = e.GetProperty("rect");
                    boxes.Add(new HitBox(
                        e.GetProperty("path").GetRawText(),
                        e.TryGetProperty("id", out var id) ? id.GetString() ?? "" : "",
                        r.GetProperty("x").GetDouble(), r.GetProperty("y").GetDouble(),
                        r.GetProperty("w").GetDouble(), r.GetProperty("h").GetDouble(),
                        events,
                        e.TryGetProperty("values", out var vs) && vs.ValueKind == System.Text.Json.JsonValueKind.Object
                            && vs.TryGetProperty("bind.background", out var bg) && bg.ValueKind == System.Text.Json.JsonValueKind.String
                            ? bg.GetString() : null,
                        e.TryGetProperty("values", out var vb) && vb.ValueKind == System.Text.Json.JsonValueKind.Object
                            && vb.TryGetProperty("bind.border", out var bd) && bd.ValueKind == System.Text.Json.JsonValueKind.String
                            ? bd.GetString() : null));
                }
            }
            return boxes;
        }
        catch (Exception ex) when (ex is System.Text.Json.JsonException or InvalidOperationException or KeyNotFoundException)
        {
            return null;
        }
    }

    /// <summary>
    /// Whether a gesture on a node is sent as <paramref name="eventName"/>: the
    /// plan says the node answers it, and the node has an address
    /// (<see cref="Addressable"/>). <see cref="RoutesPress"/> is this for `click`.
    /// </summary>
    internal static bool RoutesEvent(IReadOnlyList<string>? events, string id, string? path, string eventName) =>
        Answers(events, eventName) && Addressable(id, path);

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

    /// <summary>
    /// §252 (#399): the bytes of a `display.picture`, a `data:image/bmp;base64,`
    /// URI. Null for no picture, another media type, malformed base64, or bytes
    /// that do not open with the BMP signature `BM`. Decoding is all the shell
    /// does: every pixel is already the engine's colour.
    /// </summary>
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
internal sealed record PaneOption(bool Separator, string Value, string Label, string? Glyph, bool Selected, string? Icon = null);

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
/// A menu `shortcut:` ("Ctrl+Shift+S") as a Windows virtual-key code and its
/// modifiers, or null. Pure, so `sb_winui_tests` drives it; MainWindow makes
/// the KeyboardAccelerator from it.
///
/// ⛔ NULL, NEVER A GUESS: a wrong accelerator silently steals a keystroke. The
/// 10-30 sitting (finding 2) found the old parse wrong both ways: `=` and `-`
/// named no key, so Zoom In and Zoom Out had none; and a DIGIT went through
/// `Enum.TryParse&lt;VirtualKey&gt;` as a NUMBER, so "Ctrl+1" bound VirtualKey 1,
/// the left mouse button, and never the 1 key.
/// </summary>
internal static class ShortcutWire
{
    internal readonly record struct Chord(int Key, bool Ctrl, bool Shift, bool Alt);

    // The named keys a shortcut may spell out, as virtual-key codes.
    private static readonly Dictionary<string, int> Named = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Backspace"] = 0x08, ["Tab"] = 0x09, ["Enter"] = 0x0D, ["Escape"] = 0x1B, ["Space"] = 0x20,
        ["PageUp"] = 0x21, ["PageDown"] = 0x22, ["End"] = 0x23, ["Home"] = 0x24,
        ["Left"] = 0x25, ["Up"] = 0x26, ["Right"] = 0x27, ["Down"] = 0x28,
        ["Insert"] = 0x2D, ["Delete"] = 0x2E,
    };

    internal static Chord? Parse(string? spec)
    {
        if (string.IsNullOrWhiteSpace(spec)) { return null; }
        bool ctrl = false, shift = false, alt = false;
        int? key = null;
        foreach (var raw in spec.Split('+', StringSplitOptions.RemoveEmptyEntries))
        {
            var part = raw.Trim();
            switch (part)
            {
                case "Ctrl": ctrl = true; continue;
                case "Shift": shift = true; continue;
                case "Alt": alt = true; continue;
            }
            // A second key is not a chord; keeping the last one would be a guess.
            if (key is not null) { return null; }
            key = KeyOf(part);
            if (key is null) { return null; }
        }
        return key is { } k ? new Chord(k, ctrl, shift, alt) : null;
    }

    /// <summary>
    /// The character OnKeyDown sends the engine for a key the KEY HANDLER owns,
    /// or null. Only `=` and `-`: a KeyboardAccelerator on VK_OEM_PLUS or
    /// VK_OEM_MINUS left the View menu opening with ZERO items (measured 10-30,
    /// both ways), so Ctrl+= and Ctrl+- go the Ctrl+letter route instead.
    /// </summary>
    internal static int? ChordChar(int virtualKey) => virtualKey switch
    {
        0xBB => '=',
        0xBD => '-',
        _ => null,
    };

    private static int? KeyOf(string part)
    {
        if (part.Length == 1)
        {
            var c = char.ToUpperInvariant(part[0]);
            if (c is >= 'A' and <= 'Z') { return c; }   // VK_A..VK_Z
            if (c is >= '0' and <= '9') { return c; }   // VK_0..VK_9, the top row
            if (c == '=') { return 0xBB; }              // VK_OEM_PLUS, the =/+ key
            if (c == '-') { return 0xBD; }              // VK_OEM_MINUS
            return null;
        }
        if (Named.TryGetValue(part, out var named)) { return named; }
        if (part.Length is 2 or 3 && part[0] is 'F' or 'f'
            && int.TryParse(part[1..], out var f) && f is >= 1 and <= 24)
        {
            return 0x6F + f;                             // VK_F1 = 0x70
        }
        return null;
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
    /// <summary>
    /// Whether an act reply's `dialog` opens a dialog. `dialog` is STATE (the
    /// dialog open after the act), so a reply that names the dialog already
    /// shown, such as a `mouse_up` after the tool flyout opened, shows nothing
    /// new. The comparison is with what the shell SHOWS, never the last reply,
    /// so a dialog closed by another door opens again when named.
    /// </summary>
    internal static bool Reopens(string? replyDialog, bool shownOpen, string? shownId) =>
        !string.IsNullOrEmpty(replyDialog) && !(shownOpen && shownId == replyDialog);

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

    /// <summary>
    /// jas §284 (a): a tool's pointer gesture has no reply to name a dialog, so
    /// the plan is read after every release. Publish when the reading differs
    /// from the dialog shown (null: none), or cannot be read at all; an
    /// unchanged reading publishes nothing, so a plain click adds no row.
    /// </summary>
    internal static bool AfterRelease(string? shown, DialogReading? read) =>
        read is null || (read.Open ? read.Id : null) != shown;

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

    /// <summary>How the open dialog is drawn: dimmed or clear smoke, with or
    /// without its title bar, centred (null Left/Top) or at a point in the
    /// dialog layer (DIPs).</summary>
    internal readonly record struct DialogLook(bool Dim, bool TitleBar, double? Left, double? Top);

    /// <summary>
    /// #783: a `modal: false` dialog is a POPOVER beside the control that
    /// opened it, with no backdrop and no title bar; its top-left is the
    /// opener's right edge and top. A modal dialog is dimmed, titled and
    /// centred whatever opened it. A non-modal one with no opener the shell can
    /// place is centred, as the web centres one with no anchor. No fit rule:
    /// the web has none, and every shipped flyout fits beside its slot.
    /// </summary>
    internal static DialogLook Look(bool modal, (double X, double Y, double W, double H)? anchor) =>
        modal ? new DialogLook(Dim: true, TitleBar: true, null, null)
        : anchor is { } a ? new DialogLook(Dim: false, TitleBar: false, a.X + a.W, a.Y)
        : new DialogLook(Dim: false, TitleBar: false, null, null);
}

/// <summary>
/// #783's second door, a press OUTSIDE a flyout: it closes the flyout and does
/// NOTHING else, so neither the press nor its release reaches what lies
/// beneath (a dismissing click never draws or selects). The dialog layer's
/// smoke takes the press and asks the engine to dismiss; when the engine's
/// close arrives first, the smoke stays up, clear, until that press's release,
/// and goes with it. A modal dialog's smoke only swallows, as it always has.
/// Pure, so `sb_winui_tests` drives it.
/// </summary>
internal sealed class OutsidePress
{
    private bool _held;
    private bool _closed;

    /// <summary>A press on the smoke; true when it should dismiss the dialog.</summary>
    internal bool Pressed(bool modal)
    {
        if (modal) { return false; }
        _held = true;
        _closed = false;
        return true;
    }

    /// <summary>The engine closed the dialog; true when the layer goes now,
    /// false when a dismissing press still holds the smoke.</summary>
    internal bool HideOnClose()
    {
        if (!_held) { return true; }
        _closed = true;
        return false;
    }

    /// <summary>A dialog was drawn open. After the held press's close it is a
    /// NEW dialog (a key shortcut with the button down), so that press's
    /// release must not hide it and the gate forgets the press (#786's review).
    /// Before the close it is the same dialog redrawn, and the press holds.</summary>
    internal void Opened()
    {
        if (!_closed) { return; }
        _held = false;
        _closed = false;
    }

    /// <summary>The press was released (or its capture lost); true when the
    /// layer the close left up goes now.</summary>
    internal bool Released()
    {
        var go = _held && _closed;
        _held = false;
        _closed = false;
        return go;
    }
}

/// <summary>
/// jas §314: a key reaches the engine as `jas_dispatch_action({"key": <name>,
/// "mods": {"shift", "alt", "ctrl"}})`. The ENGINE resolves it (the active
/// tool's claim, then `shortcuts.yaml`) and answers with the act reply, so the
/// shell holds no binding and reads a dialog or a close from a key as from any
/// act.
/// </summary>
internal static class KeyWire
{
    /// <summary>The request for a key named <paramref name="name"/> (`Delete`,
    /// `Backspace`, `Enter`, `Escape`, or one character), or null for no name.
    /// Every flag is written; `ctrl` is the command modifier. jas §644/#753: a
    /// key pressed in a focused panel also names that panel's content id, and
    /// the engine resolves it against the panel's own `keyboard:` rows.</summary>
    internal static string? Request(string name, bool shift, bool alt, bool ctrl, string? panel = null)
    {
        if (name.Length == 0) { return null; }
        using var buffer = new System.IO.MemoryStream();
        using (var w = new System.Text.Json.Utf8JsonWriter(buffer, new System.Text.Json.JsonWriterOptions
               { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }))
        {
            w.WriteStartObject();
            if (panel is not null) { w.WriteString("panel", panel); }
            w.WriteString("key", name);
            w.WriteStartObject("mods");
            w.WriteBoolean("shift", shift);
            w.WriteBoolean("alt", alt);
            w.WriteBoolean("ctrl", ctrl);
            w.WriteEndObject();
            w.WriteEndObject();
        }
        return System.Text.Encoding.UTF8.GetString(buffer.ToArray());
    }

    /// <summary>jas §644/#753: the panel door's refusal for a key the focused
    /// panel does not bind. The shell then sends the same key to the document
    /// door, so a panel with focus keeps every key it does not claim.</summary>
    internal static bool UnboundPanelKey(string channel) =>
        channel.Contains("\"UnboundPanelKey\"", StringComparison.Ordinal);

    /// <summary>The key name for a code `OnKeyDown` or `OnCharacterReceived`
    /// sent (`JasCore.Key*`): a named key by its table, else the character.
    /// Tab (0x09) is a control character, so only the table names it.</summary>
    internal static string? Name(uint code) => code switch
    {
        0x08 => "Backspace",
        0x09 => "Tab",
        0x0D => "Enter",
        0x1B => "Escape",
        0x7F => "Delete",
        0xF700 => "ArrowUp",
        0xF701 => "ArrowDown",
        0xF702 => "ArrowLeft",
        0xF703 => "ArrowRight",
        0xF705 => "F2",
        0xF729 => "Home",
        0xF72B => "End",
        _ => CharName(code),
    };

    /// <summary>Whether the shell sends Tab to the engine and keeps it from
    /// the platform's focus traversal: only from the canvas's own focus, as on
    /// the web, where Tab on a widget walks the widgets (`keyboard.rs`). From
    /// the canvas the engine's tool takes it, so a text session keeps focus.</summary>
    internal static bool TakesTab(bool fromCanvas) => fromCanvas;

    /// <summary>flask §556 finding H: the menu action a refused COMMAND chord
    /// names (`{"panel_event":"KeyUnhandled",...,"menu_action":<action>}`), or
    /// null when the refusal names none, is another class, or is unreadable.
    /// `OnKeyDown` kept that chord from the menu's accelerator, so the shell
    /// runs the item itself.</summary>
    internal static string? MenuAction(string channel)
    {
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(channel);
            var root = doc.RootElement;
            if (root.ValueKind != System.Text.Json.JsonValueKind.Object) { return null; }
            if (!root.TryGetProperty("panel_event", out var cls)
                || cls.ValueKind != System.Text.Json.JsonValueKind.String
                || cls.GetString() != "KeyUnhandled") { return null; }
            if (!root.TryGetProperty("menu_action", out var action)
                || action.ValueKind != System.Text.Json.JsonValueKind.String) { return null; }
            var name = action.GetString();
            return string.IsNullOrEmpty(name) ? null : name;
        }
        catch (System.Text.Json.JsonException) { return null; }
    }

    /// <summary>A typed character's key name: the character itself, or null
    /// for a control character (the named keys arrive by their own codes).</summary>
    internal static string? CharName(uint c) =>
        c < 0x20 || c == 0x7F || c > 0x10FFFF || (c >= 0xD800 && c <= 0xDFFF) ? null : char.ConvertFromUtf32((int)c);
}

/// <summary>
/// Press-and-hold (the 10-30 sitting, finding 1; the engine half is #771). A
/// `mouse_down` / `mouse_up` reply carries `"timers"`: `{"start": id,
/// "delay_ms": n}` (start, or restart, that timer) or `{"cancel": id}`, and no
/// key at all when no timer act happened. The shell only runs the clock: the
/// engine keeps the effects and, on the tick `{"event": "timer", "value": id}`,
/// runs them only if that id is still pending. Pure, so `sb_winui_tests`
/// drives it. A start with no delay, or a negative one, is refused, never
/// defaulted. A malformed act (no id, no whole delay, both `start` and
/// `cancel`, not an object) is REFUSED BY NAME: its own JSON text goes in
/// `Refused` for the caller to report, never dropped silently (#778's review).
/// </summary>
internal static class TimerWire
{
    internal readonly record struct Act(string Id, int DelayMs, bool Cancel);

    internal readonly record struct Reading(IReadOnlyList<Act> Acts, IReadOnlyList<string> Refused);

    internal static Reading Parse(string? reply)
    {
        var acts = new List<Act>();
        var refused = new List<string>();
        if (string.IsNullOrEmpty(reply)) { return new Reading(acts, refused); }
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(reply);
            if (doc.RootElement.ValueKind != System.Text.Json.JsonValueKind.Object
                || !doc.RootElement.TryGetProperty("timers", out var list)) { return new Reading(acts, refused); }
            if (list.ValueKind != System.Text.Json.JsonValueKind.Array)
            {
                refused.Add(list.GetRawText());
                return new Reading(acts, refused);
            }
            foreach (var e in list.EnumerateArray())
            {
                if (ReadAct(e) is { } act) { acts.Add(act); }
                else { refused.Add(e.GetRawText()); }
            }
        }
        catch (System.Text.Json.JsonException) { }
        return new Reading(acts, refused);
    }

    /// <summary>One act, or null when it is malformed.</summary>
    private static Act? ReadAct(System.Text.Json.JsonElement e)
    {
        if (e.ValueKind != System.Text.Json.JsonValueKind.Object) { return null; }
        var hasCancel = e.TryGetProperty("cancel", out var c);
        var hasStart = e.TryGetProperty("start", out var s);
        if (hasCancel == hasStart) { return null; }
        if (hasCancel)
        {
            return c.ValueKind == System.Text.Json.JsonValueKind.String && c.GetString() is { Length: > 0 } cancelId
                ? new Act(cancelId, 0, Cancel: true)
                : null;
        }
        return s.ValueKind == System.Text.Json.JsonValueKind.String && s.GetString() is { Length: > 0 } startId
            && e.TryGetProperty("delay_ms", out var d) && d.ValueKind == System.Text.Json.JsonValueKind.Number
            && d.TryGetInt32(out var ms) && ms >= 0
            ? new Act(startId, ms, Cancel: false)
            : null;
    }
}

/// <summary>
/// The clocks the shell runs for the engine's timers, keyed as the engine
/// keys its pending set: by (panel, timer id) (#778's review). Two panels may
/// pend the same id, and a cancel or a restart on one never stops the other's
/// clock. Generic so `sb_winui_tests` drives it with no dispatcher.
/// </summary>
internal sealed class PendingTimers<T> where T : class
{
    private readonly Dictionary<(string Panel, string Id), T> _clocks = new();

    internal int Count => _clocks.Count;

    /// <summary>Takes out the clock pending for (panel, id), or null.</summary>
    internal T? Take(string panel, string id) => _clocks.Remove((panel, id), out var clock) ? clock : null;

    /// <summary>Records the clock now pending for (panel, id).</summary>
    internal void Put(string panel, string id, T clock) => _clocks[(panel, id)] = clock;
}

/// <summary>
/// Whether a press-and-hold slot's CLICK goes (jas's ruling on finding 1,
/// point 4). The web, the port of record, fires no click once the flyout has
/// opened. So a press whose tick got a NON-EMPTY reply drops its click; a tick
/// answered `StaleTimer` (cancelled, or raced by the release) leaves it; and a
/// click that arrives before the tick's answer waits for it, then goes or drops
/// once. The ENGINE's reply decides, never the shell's clock. One per button.
/// </summary>
internal sealed class LongPressGate
{
    internal enum Fate { Sent, Dropped, Held }

    private bool _tickSent;
    private bool? _opened;
    private Action? _held;

    internal void Pressed() { _tickSent = false; _opened = null; _held = null; }

    internal void TickSent() => _tickSent = true;

    /// <summary>The tick's answer; returns whether a held click was sent.</summary>
    internal bool Answered(bool nonEmpty)
    {
        _opened = nonEmpty;
        var held = _held;
        _held = null;
        if (held is null || nonEmpty) { return false; }
        held();
        return true;
    }

    internal Fate Click(Action send)
    {
        if (!_tickSent || _opened == false) { send(); return Fate.Sent; }
        if (_opened == true) { return Fate.Dropped; }
        _held = send;
        return Fate.Held;
    }
}

/// <summary>
/// The engine's dock layout (`jas_layout_state`, floating panels FP-3): the
/// shell draws the dock from it and sends `layout_apply` verbs back, holding
/// no dock state of its own. Read strictly: a reply the engine would never
/// send (an `active` outside its group, an empty group, a missing flag) is
/// refused whole, never repaired, so the shell is never handed a value to clamp.
/// </summary>
internal static class LayoutWire
{
    /// <summary>
    /// jas §642 (#738): the pane state a layout carries, `"panes": {"toolbar",
    /// "canvas", "dock"}` (bools) and `"canvas_maximized"` (bool). Null when a
    /// key is missing (an older engine), a member is not a bool, or the bytes
    /// are unreadable: never read as "every pane hidden".
    /// </summary>
    internal static PaneState? Panes(string layout)
    {
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(layout);
            var root = doc.RootElement;
            if (root.ValueKind != System.Text.Json.JsonValueKind.Object
                || !root.TryGetProperty("panes", out var p) || p.ValueKind != System.Text.Json.JsonValueKind.Object
                || !root.TryGetProperty("canvas_maximized", out var m))
            {
                return null;
            }
            static bool? B(System.Text.Json.JsonElement e) => e.ValueKind switch
            {
                System.Text.Json.JsonValueKind.True => true,
                System.Text.Json.JsonValueKind.False => false,
                _ => null,
            };
            bool? Member(string k) => p.TryGetProperty(k, out var v) ? B(v) : null;
            return (Member("toolbar"), Member("canvas"), Member("dock"), B(m)) is ({ } t, { } c, { } d, { } x)
                ? new PaneState(t, c, d, x)
                : null;
        }
        catch (System.Text.Json.JsonException)
        {
            return null;
        }
    }

    internal sealed record Group(IReadOnlyList<string> Panels, int Active, bool Collapsed);
    internal sealed record Anchored(int DockId, IReadOnlyList<Group> Groups);
    internal sealed record Floated(int DockId, double X, double Y, double Width, int Z, IReadOnlyList<Group> Groups);

    /// <summary>A dock's groups, or null for any group the engine would never send.</summary>
    private static List<Group>? Groups(System.Text.Json.JsonElement dock)
    {
        var groups = new List<Group>();
        foreach (var g in dock.GetProperty("groups").EnumerateArray())
        {
            var panels = g.GetProperty("panels").EnumerateArray().Select(p => p.GetString() ?? "").ToList();
            var active = g.GetProperty("active").GetInt32();
            var collapsed = g.GetProperty("collapsed").GetBoolean();
            if (panels.Count == 0 || panels.Any(p => p.Length == 0) || active < 0 || active >= panels.Count) { return null; }
            groups.Add(new Group(panels, active, collapsed));
        }
        return groups;
    }

    private static T? Read<T>(string stateJson, Func<System.Text.Json.JsonElement, T?> read) where T : class
    {
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(stateJson);
            return read(doc.RootElement);
        }
        catch (Exception ex) when (ex is System.Text.Json.JsonException or KeyNotFoundException
                                     or InvalidOperationException or FormatException or IndexOutOfRangeException)
        {
            return null;
        }
    }

    /// <summary>The first anchored dock of a layout state, or null.</summary>
    internal static Anchored? Dock(string stateJson) => Read(stateJson, root =>
    {
        var anchored = root.GetProperty("anchored");
        if (anchored.GetArrayLength() == 0) { return null; }
        var d = anchored[0];
        var groups = Groups(d);
        return groups is null ? null : new Anchored(d.GetProperty("id").GetInt32(), groups);
    });

    /// <summary>
    /// The floating docks, back to front: ascending `z` (the engine's
    /// `z_index_for`), ties in the engine's list order. Empty when there are
    /// none; null when any dock is one the engine would never send.
    /// </summary>
    internal static IReadOnlyList<Floated>? Floating(string stateJson) => Read(stateJson, root =>
    {
        var docks = new List<Floated>();
        foreach (var f in root.GetProperty("floating").EnumerateArray())
        {
            var groups = Groups(f);
            if (groups is null) { return null; }
            docks.Add(new Floated(f.GetProperty("id").GetInt32(), f.GetProperty("x").GetDouble(),
                                  f.GetProperty("y").GetDouble(), f.GetProperty("width").GetDouble(),
                                  f.GetProperty("z").GetInt32(), groups));
        }
        return (IReadOnlyList<Floated>)docks.OrderBy(d => d.Z).ToList();
    });

    /// <summary>A floating group's pane key. Never `dock…`: four sites parse a
    /// `dock{i}` key back to an anchored group's index.</summary>
    internal static string FloatKey(int dockId, int groupIdx) =>
        string.Create(System.Globalization.CultureInfo.InvariantCulture, $"float{dockId}g{groupIdx}");

    private static string Op(Dictionary<string, object> op) => System.Text.Json.JsonSerializer.Serialize(op);

    /// <summary>The chevron's verb: toggle a group's collapse in the engine.</summary>
    internal static string ToggleCollapsed(int dockId, int groupIdx) =>
        Op(new() { ["op"] = "toggle_group_collapsed", ["dock_id"] = dockId, ["group_idx"] = groupIdx });

    internal static string BringToFront(int dockId) => Op(new() { ["op"] = "bring_to_front", ["dock_id"] = dockId });

    internal static string SetFloatingPosition(int dockId, double x, double y) =>
        Op(new() { ["op"] = "set_floating_position", ["dock_id"] = dockId, ["x"] = x, ["y"] = y });

    internal static string Redock(int dockId) => Op(new() { ["op"] = "redock", ["dock_id"] = dockId });

    internal static string DetachPanel(int dockId, int groupIdx, int panelIdx, double x, double y) =>
        Op(new() { ["op"] = "detach_panel", ["dock_id"] = dockId, ["group_idx"] = groupIdx, ["panel_idx"] = panelIdx, ["x"] = x, ["y"] = y });

    /// <summary>The distance in DIPs a press must travel before it is a drag, not a click.</summary>
    internal const double TearOutThreshold = 8;

    /// <summary>
    /// Whether a drag out of the dock tears its tab or group out (FP-5): it moved
    /// past <see cref="TearOutThreshold"/> and was released INSIDE the canvas cell
    /// (`x`, `y` relative to it, `w` by `h`). A release back over the dock, or
    /// anywhere outside the cell, is no drop.
    /// </summary>
    internal static bool TearsOut(double dx, double dy, double x, double y, double w, double h) =>
        Math.Sqrt(dx * dx + dy * dy) >= TearOutThreshold && x >= 0 && y >= 0 && x <= w && y <= h;

    /// <summary>The engine keeps every floating dock reachable in a resized canvas cell (FP-6).</summary>
    internal static string ClampFloatingDocks(double w, double h) =>
        Op(new() { ["op"] = "clamp_floating_docks", ["viewport_w"] = w, ["viewport_h"] = h });

    internal static string DetachGroup(int dockId, int groupIdx, double x, double y) =>
        Op(new() { ["op"] = "detach_group", ["dock_id"] = dockId, ["group_idx"] = groupIdx, ["x"] = x, ["y"] = y });
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
    /// jas §300: `"close_window": <bool>`, in every act reply. True for `quit`
    /// with nothing edited and for Save Changes' Don't Save. Only a named
    /// `true` closes. An older engine with no key, a non-boolean, a refusal's
    /// empty reply, or unreadable bytes all keep the window.
    /// </summary>
    internal static bool CloseWindow(string reply) => NamedTrue(reply, "close_window");

    /// <summary>
    /// jas §305: `"save_all_then_close": <bool>`, in every act reply. True when
    /// Save Changes' Save All runs, and never with `close_window`: the engine
    /// cannot save, so the SHELL saves every modified document and closes only
    /// if every save succeeded. Only a named `true` acts.
    /// </summary>
    internal static bool SaveAllThenClose(string reply) => NamedTrue(reply, "save_all_then_close");

    /// <summary>
    /// Save All's first step in this shell, which holds ONE document. `close`:
    /// there is nothing to save (no document open, or it is unmodified).
    /// `save`: save it first, then <see cref="AfterSaveAll"/>.
    /// </summary>
    internal static string SaveAllStep(bool documentOpen, bool modified) =>
        documentOpen && modified ? "save" : "close";

    /// <summary>After Save All's save: `close` only if it wrote the file, else `keep`.</summary>
    internal static string AfterSaveAll(bool saved) => saved ? "close" : "keep";

    /// <summary>
    /// jas §364 (plan § 5 slice 8): `"clipboard_write": <text> | null`, in every
    /// act reply. Copy and Cut carry it; the shell puts the string on the system
    /// clipboard as plain text, UNCHANGED, and never parses it. Null when the
    /// reply names none, an older engine sent no key, the value is not a
    /// string, or the bytes are unreadable. An empty string is a string.
    /// </summary>
    internal static string? ClipboardWrite(string reply)
    {
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(reply);
            return doc.RootElement.ValueKind == System.Text.Json.JsonValueKind.Object
                   && doc.RootElement.TryGetProperty("clipboard_write", out var t)
                   && t.ValueKind == System.Text.Json.JsonValueKind.String
                ? t.GetString()
                : null;
        }
        catch (System.Text.Json.JsonException)
        {
            return null;
        }
    }

    /// <summary>
    /// jas §637 (#733): `"export_pdf": <file name> | null`, in every act reply.
    /// Print > Print names one: the shell saves the document's PDF
    /// (`jas_document_pdf`) under that SUGGESTED name. Null when the reply names
    /// none, an older engine sent no key, the value is not a string, or the
    /// bytes are unreadable.
    /// </summary>
    internal static string? ExportPdf(string reply)
    {
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(reply);
            return doc.RootElement.ValueKind == System.Text.Json.JsonValueKind.Object
                   && doc.RootElement.TryGetProperty("export_pdf", out var t)
                   && t.ValueKind == System.Text.Json.JsonValueKind.String
                ? t.GetString()
                : null;
        }
        catch (System.Text.Json.JsonException)
        {
            return null;
        }
    }

    /// <summary>
    /// jas §637: whether bytes from `jas_document_pdf` are a PDF (they open
    /// `%PDF-`). Anything else is never written to disk as one.
    /// </summary>
    internal static bool IsPdf(byte[] bytes) =>
        bytes.Length >= 5 && bytes[0] == (byte)'%' && bytes[1] == (byte)'P' && bytes[2] == (byte)'D'
        && bytes[3] == (byte)'F' && bytes[4] == (byte)'-';

    /// <summary>
    /// jas §637: the engine's suggested name, usable as a FILE NAME only, or
    /// null. A name carrying any directory part (a separator, a drive, `..`) is
    /// refused rather than trimmed: the suggestion must never steer a write
    /// out of the folder a person (or `SB_EXPORT_PDF_DIR`) chose.
    /// </summary>
    internal static string? PdfFileName(string? name)
    {
        if (string.IsNullOrWhiteSpace(name)) { return null; }
        if (name.IndexOfAny(new[] { '/', '\\', ':' }) >= 0 || name == "." || name == "..") { return null; }
        if (name.IndexOfAny(System.IO.Path.GetInvalidFileNameChars()) >= 0) { return null; }
        return name;
    }
    /// <summary>
    /// jas §642 (#738): `"layout": <the whole layout> | null`, in every act
    /// reply. A layout effect ran (Window ▸ Toolbar / Panels, the canvas
    /// maximize) when it is an object; the shell publishes it as it publishes
    /// `jas_layout_apply`'s answer. Null for null, a missing key, a non-object
    /// or unreadable bytes. Returned as the object's raw text, unchanged.
    /// </summary>
    internal static string? Layout(string reply)
    {
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(reply);
            return doc.RootElement.ValueKind == System.Text.Json.JsonValueKind.Object
                   && doc.RootElement.TryGetProperty("layout", out var l)
                   && l.ValueKind == System.Text.Json.JsonValueKind.Object
                ? l.GetRawText()
                : null;
        }
        catch (System.Text.Json.JsonException)
        {
            return null;
        }
    }

    /// <summary>
    /// A paste sent with no `clipboard` field is refused with nothing run, and
    /// the error channel reads `{"panel_event":"NeedsClipboard","detail":
    /// "<action>"}`. The action it names (empty when it names none), or null
    /// for any other channel, a clear one, or unreadable bytes.
    /// </summary>
    internal static string? NeedsClipboard(string channel)
    {
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(channel);
            var root = doc.RootElement;
            if (root.ValueKind != System.Text.Json.JsonValueKind.Object
                || !root.TryGetProperty("panel_event", out var e)
                || e.ValueKind != System.Text.Json.JsonValueKind.String
                || e.GetString() != "NeedsClipboard")
            {
                return null;
            }
            return root.TryGetProperty("detail", out var d) && d.ValueKind == System.Text.Json.JsonValueKind.String
                ? d.GetString()
                : "";
        }
        catch (System.Text.Json.JsonException)
        {
            return null;
        }
    }

    /// <summary>
    /// The resend: THE SAME request object, with `"clipboard"` set to the
    /// clipboard's text, or a JSON null when it holds no text or the read
    /// threw. A `clipboard` already there is replaced, never written twice.
    /// </summary>
    internal static string WithClipboard(string request, string? text)
    {
        using var doc = System.Text.Json.JsonDocument.Parse(request);
        using var buffer = new System.IO.MemoryStream();
        using (var w = new System.Text.Json.Utf8JsonWriter(buffer, new System.Text.Json.JsonWriterOptions
               { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }))
        {
            w.WriteStartObject();
            foreach (var p in doc.RootElement.EnumerateObject())
            {
                if (p.NameEquals("clipboard")) { continue; }
                p.WriteTo(w);
            }
            if (text is null) { w.WriteNull("clipboard"); }
            else { w.WriteString("clipboard", text); }
            w.WriteEndObject();
        }
        return System.Text.Encoding.UTF8.GetString(buffer.ToArray());
    }

    /// <summary>
    /// What a refusal asks of the shell. `read`: it was refused for the
    /// clipboard, so read it and resend. `refused-again`: the request already
    /// carried it and was refused for it again, a failure, never a second
    /// retry. `none`: any other refusal.
    /// </summary>
    internal static string ClipboardStep(string? needs, bool carried) =>
        needs is null ? "none" : carried ? "refused-again" : "read";

    /// <summary>Whether a reply names <paramref name="key"/> as a JSON `true`.</summary>
    private static bool NamedTrue(string reply, string key)
    {
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(reply);
            return doc.RootElement.ValueKind == System.Text.Json.JsonValueKind.Object
                   && doc.RootElement.TryGetProperty(key, out var v)
                   && v.ValueKind == System.Text.Json.JsonValueKind.True;
        }
        catch (System.Text.Json.JsonException)
        {
            return false;
        }
    }

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

/// <summary>
/// The `gradient_slider`'s picture (gradient.yaml `grad_slider`), as the web
/// draws it (`renderer.rs` `render_gradient_slider`): a bar previewing the
/// stops, a circle per stop at its `location`, and a diamond per pair at its
/// `midpoint_to_next`. Its gestures (council 10-21 ⑤, node 3b) cross as raw
/// parameters through <see cref="PanelWire.GestureJson"/>: this class turns a
/// pointer's DIPs into a `location` and a `dy` (<see cref="Point"/>) and
/// nothing more; the slider law is the engine's.
/// </summary>
internal static class GradientSliderWire
{
    /// <summary>One stop: `#rrggbb`, opacity and location in 0..100, and the
    /// midpoint to the next stop in 0..100 (50 when the stop names none).</summary>
    internal readonly record struct Stop(string Color, double Opacity, double Location, double Midpoint);

    /// <summary>`bind.stops` (the plan's JSON text) as stops, or null when it
    /// is not an array of objects that each name a `color` and a `location`, or
    /// when any percentage lies outside 0..100: refused, never clamped, as the
    /// shell refuses every value it was not given (check_shell_interaction_path).</summary>
    internal static IReadOnlyList<Stop>? Stops(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) { return null; }
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != System.Text.Json.JsonValueKind.Array) { return null; }
            var stops = new List<Stop>();
            foreach (var s in doc.RootElement.EnumerateArray())
            {
                if (s.ValueKind != System.Text.Json.JsonValueKind.Object) { return null; }
                if (!s.TryGetProperty("color", out var c) || c.ValueKind != System.Text.Json.JsonValueKind.String) { return null; }
                if (!s.TryGetProperty("location", out var l) || !l.TryGetDouble(out var loc)) { return null; }
                double Num(string key, double fallback) =>
                    s.TryGetProperty(key, out var v) && v.TryGetDouble(out var d) ? d : fallback;
                var (opacity, midpoint) = (Num("opacity", 100), Num("midpoint_to_next", 50));
                if (new[] { loc, opacity, midpoint }.Any(p => p < 0 || p > 100)) { return null; }
                stops.Add(new Stop(c.GetString()!, opacity, loc, midpoint));
            }
            return stops;
        }
        catch (System.Text.Json.JsonException) { return null; }
    }

    /// <summary>Where the diamond between `a` and the next stop `b` sits, in 0..100.</summary>
    internal static double MidpointLocation(Stop a, Stop b) => a.Location + (b.Location - a.Location) * a.Midpoint / 100;

    /// <summary>A bound index (`bind.selected_stop_index`, `…midpoint_index`): -1, none, unless an integer.</summary>
    internal static int Index(string? shown) => int.TryParse(shown, out var i) ? i : -1;

    /// <summary>
    /// The slider's geometry in the plan's rect, in DIPs: a stop's radius `R`
    /// (also the inset that keeps an end stop inside), a diamond's side `D`, and
    /// the bar's top, width and height. Null when the rect is too small to hold
    /// a bar, which then draws nothing and takes no gesture. The ONE layout the
    /// drawing and the pointer share, so a press lands where its marker is drawn.
    /// </summary>
    internal readonly record struct Layout(double R, double D, double BarTop, double BarW, double BarH);

    internal static Layout? LayoutOf(double w, double h)
    {
        var (r, d) = (h * 0.2, h * 0.25);
        var barTop = d + 1;
        var (barW, barH) = (w - 2 * r, h - barTop - 2 * r);
        return barW <= 0 || barH <= 0 ? null : new Layout(r, d, barTop, barW, barH);
    }

    /// <summary>Where a `location` (0..100) is drawn along the bar, in DIPs from the surface's left.</summary>
    internal static double At(Layout l, double location) => l.R + l.BarW * location / 100;

    /// <summary>
    /// A point on the surface (DIPs) as a gesture's raw parameters: its
    /// `location` in percent along the bar (the inverse of <see cref="At"/>)
    /// and `dy`, its distance from the bar's centre line. Neither is clamped: a
    /// drag past an end or off the bar is the law's to read (`drag_stop`), and
    /// the shell decides nothing about it.
    /// </summary>
    internal static (double Location, double Dy) Point(Layout l, double x, double y) =>
        ((x - l.R) / l.BarW * 100, y - (l.BarTop + l.BarH / 2));

    /// <summary>
    /// A diamond's press target's width, in DIPs: a slider thumb's, not the
    /// diamond's drawn 6 (desk AED, flask §520: a press 3 DIP right of a
    /// diamond's centre missed it). 18 is WinUI's horizontal slider thumb
    /// width, measured on the box (flask §527: `SliderHorizontalThumbWidth`).
    /// </summary>
    internal const double MidpointTarget = 18;

    /// <summary>
    /// How far the drawn diamond's top corner reaches above the slider's rect:
    /// a <see cref="Layout.D"/>-wide square rotated 45° about its centre at
    /// y = D/2 spans D·√2, so its corner sits D(√2 − 1)/2 above y 0 (flask
    /// §527). The target reaches up with it, so every drawn pixel takes a press.
    /// </summary>
    internal static double DiamondOverhang(Layout l) => l.D * (Math.Sqrt(2) - 1) / 2;

    /// <summary>
    /// The pair whose diamond a press at (x, y) takes, or null. The target is
    /// the band above the bar (y in −<see cref="DiamondOverhang"/>..BarTop, from
    /// the drawn corner down to the bar, so the bar's own rows stay the bar's
    /// `add`), <see cref="MidpointTarget"/> wide and centred on the
    /// diamond; where two targets overlap the nearer diamond takes it, the
    /// lower pair on a tie. Only the shell's hit test: the press it starts
    /// carries the pointer's own location, as a press on the drawn diamond did.
    /// </summary>
    internal static int? MidpointAt(Layout l, IReadOnlyList<Stop> stops, double x, double y)
    {
        if (y < -DiamondOverhang(l) || y >= l.BarTop) { return null; }
        int? best = null;
        var bestDistance = MidpointTarget / 2;
        for (var i = 0; i + 1 < stops.Count; i++)
        {
            var distance = Math.Abs(x - At(l, MidpointLocation(stops[i], stops[i + 1])));
            if (distance < bestDistance || (best is null && distance == bestDistance)) { (best, bestDistance) = (i, distance); }
        }
        return best;
    }

    /// <summary>
    /// A key on the focused slider in GRADIENT.md's keyboard table's names, from
    /// the `VirtualKey`'s name (`Left`, `Back`, ...); null for a key the table
    /// does not name, which the slider leaves to the window. Mirrors the web's
    /// `slider_key`: Back is Backspace.
    /// </summary>
    internal static string? KeyName(string virtualKey) => virtualKey switch
    {
        "Left" or "Right" or "Home" or "End" or "Delete" => virtualKey,
        "Back" => "Backspace",
        _ => null,
    };
}

/// <summary>
/// jas §642 (#738): the engine's pane state, as a layout reply carries it.
/// Geometry is not in it; the columns are the shell's.
/// </summary>
internal sealed record PaneState(bool Toolbar, bool Canvas, bool Dock, bool CanvasMaximized);

/// <summary>
/// jas §642: which side columns show for a <see cref="PaneState"/>. A pane shows
/// when the engine says so and the canvas is not maximized (a maximized canvas
/// takes the window's whole width). The shell applies this and decides nothing
/// else.
/// </summary>
internal static class PaneRule
{
    internal static (bool Toolbar, bool Dock) Shown(PaneState p) =>
        (p.Toolbar && !p.CanvasMaximized, p.Dock && !p.CanvasMaximized);
}

/// <summary>
/// jas §644/#753: which keys pressed in a focused panel go to the panel door.
/// They are the keys a panel's `keyboard:` rows bind (the tree's arrows,
/// F2, Enter, Escape, Delete and Backspace, and Ctrl+A). Every other key,
/// Ctrl+Z and the plain letters among them, stays on the document's route
/// exactly as before. Which ACTION a forwarded key runs is the engine's.
/// </summary>
internal static class PanelKeys
{
    internal static bool Forwards(uint code, bool ctrl) => code switch
    {
        0xF700 or 0xF701 or 0xF702 or 0xF703 or 0xF705 => true,
        0x0D or 0x1B or 0x7F or 0x08 => true,
        'a' => ctrl,
        _ => false,
    };

    /// <summary>
    /// flask §656: the keys routed from a pane's focus BEFORE they bubble: the
    /// arrows, Home and End. A dock column that overflows is a ScrollViewer,
    /// which takes exactly these on their way up to scroll itself, so a row
    /// press that gave the panel the keyboard still lost Up and Down while F2
    /// and Ctrl+A arrived. Every other key bubbles as before.
    /// </summary>
    internal static bool BeforeScroller(uint code) => code is 0xF700 or 0xF701 or 0xF702 or 0xF703 or 0xF729 or 0xF72B;
}
