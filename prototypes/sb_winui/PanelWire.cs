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
    internal static byte[] EventJson(string widget, string eventName, string? value,
                                     bool alt, bool shift, bool ctrl, bool meta)
    {
        return System.Array.Empty<byte>();
    }

    /// <summary>
    /// A value as a row prints it: one whitespace-free token, so a reader's
    /// `key=\S+` takes all of it. The text is JSON-encoded (quoted), with a
    /// space written as ` `; a press prints <see cref="NoValue"/>, which
    /// no encoded string can equal because an encoded string is quoted.
    /// </summary>
    internal static string RowValue(string? value)
    {
        return value ?? "";
    }

    /// <summary>
    /// Does losing focus commit this text? Only when it differs from what the
    /// core last showed, compared ORDINALLY. Enter always commits; a focus
    /// change that edited nothing must not run a panel's behaviors.
    /// </summary>
    internal static bool CommitOnBlur(string text, string shown)
    {
        return false;
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
        return new PanelChoices(new List<(string Id, string Label)>(), 0);
    }
}

/// <summary>The panels the pane can show, in the core's order, and how many rows could not be offered.</summary>
internal sealed record PanelChoices(List<(string Id, string Label)> Rows, int Skipped);
