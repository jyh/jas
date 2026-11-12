namespace SbWinUi;

/// <summary>
/// (A) W1a: the agent session's wire on the C# side. The engine owns the
/// session (`jas_mcp_*`, A6 R2), and every reply it returns is zero or more
/// newline-terminated JSON-RPC lines, ready to write to the client as they
/// are, so the shell never parses a reply. It reads only what the accept bar
/// shows (<see cref="Pending"/>), and splits the client's byte stream into
/// the whole lines the engine takes (<see cref="LineSplitter"/>).
///
/// PURE ON PURPOSE, like `PanelWire`: `sb_winui_tests` links this file.
/// </summary>
internal static class McpWire
{
    /// <summary>
    /// What the bar shows: <c>Id</c> and <c>Name</c> of the pending proposal,
    /// both null when none is; or <c>Why</c>, when the engine's answer is not
    /// one it would send.
    /// </summary>
    internal sealed record PendingRead(string? Id, string? Name, string? Why);

    /// <summary>
    /// `jas_mcp_pending`'s answer: <c>{"id":"…","name":"…"}</c>, or <c>null</c>
    /// for none. The empty span (a null engine), bad JSON, or an object
    /// without a string id and name is REFUSED by name, never read as "no
    /// proposal": a bar that silently showed nothing would hide one.
    /// </summary>
    internal static PendingRead Pending(string json)
    {
        if (string.IsNullOrEmpty(json)) { return new PendingRead(null, null, "empty"); }
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.ValueKind == System.Text.Json.JsonValueKind.Null) { return new PendingRead(null, null, null); }
            if (root.ValueKind != System.Text.Json.JsonValueKind.Object) { return new PendingRead(null, null, "not an object"); }
            if (!root.TryGetProperty("id", out var id) || id.ValueKind != System.Text.Json.JsonValueKind.String)
            {
                return new PendingRead(null, null, "no id");
            }
            if (!root.TryGetProperty("name", out var name) || name.ValueKind != System.Text.Json.JsonValueKind.String)
            {
                return new PendingRead(null, null, "no name");
            }
            return new PendingRead(id.GetString(), name.GetString(), null);
        }
        catch (System.Text.Json.JsonException)
        {
            return new PendingRead(null, null, "not JSON");
        }
    }

    /// <summary>
    /// The client's byte stream as the whole lines the engine takes. A line
    /// ends at LF; a trailing CR is not part of it; an empty line is no line.
    /// The bytes are passed through untouched (`jas_mcp_handle` answers bad
    /// UTF-8 with a parse error itself). A line longer than the cap is
    /// REFUSED: its bytes are dropped up to its LF and one <c>null</c> stands
    /// in its place, so the next line still reads.
    /// </summary>
    internal sealed class LineSplitter
    {
        private readonly int _cap;
        private readonly List<byte> _held = new();
        private bool _overflowing;

        internal LineSplitter(int cap) { _cap = cap; }

        /// <summary>How many bytes of an unfinished line are held.</summary>
        internal int Held => _held.Count;

        /// <summary>How many lines have been refused for length.</summary>
        internal int Overflows { get; private set; }

        /// <summary>The whole lines these bytes finish, in order; <c>null</c> for a refused one.</summary>
        internal List<byte[]?> Feed(ReadOnlySpan<byte> bytes)
        {
            var lines = new List<byte[]?>();
            foreach (var b in bytes)
            {
                if (b == (byte)'\n')
                {
                    if (_overflowing)
                    {
                        _overflowing = false;
                        Overflows++;
                        lines.Add(null);
                    }
                    else
                    {
                        if (_held.Count > 0 && _held[^1] == (byte)'\r') { _held.RemoveAt(_held.Count - 1); }
                        if (_held.Count > 0) { lines.Add(_held.ToArray()); }
                    }
                    _held.Clear();
                    continue;
                }
                if (_overflowing) { continue; }
                _held.Add(b);
                if (_held.Count > _cap)
                {
                    _held.Clear();
                    _overflowing = true;
                }
            }
            return lines;
        }
    }

    /// <summary>
    /// The bar's row when what it shows changes, or null when it does not:
    /// `PROPOSAL SHOWN id= name=`, `PROPOSAL GONE id=`, or both when one
    /// proposal replaces another between two reads.
    /// </summary>
    internal static string? BarRow((string Id, string Name)? was, (string Id, string Name)? now)
    {
        if (was == now) { return null; }
        var rows = new List<string>();
        if (was is { } w) { rows.Add($"PROPOSAL GONE id={w.Id}"); }
        if (now is { } n) { rows.Add($"PROPOSAL SHOWN id={n.Id} name={n.Name}"); }
        return string.Join("; ", rows);
    }

    /// <summary>
    /// (A) W1c: the accept bar's label, as the Mac's `ProposalBarView` draws it,
    /// or null when no bar is shown: none pending, or a read refused (whose
    /// refusal is the shell's row, never a label).
    /// </summary>
    internal static string? BarText(PendingRead read) =>
        read.Why is null && read.Id is not null ? $"Proposed: {read.Name}" : null;

    /// <summary>
    /// (A) W1b: whether a drain that held this command must pull
    /// `jas_mcp_observe` for an attached client. EVERY drain does (jas 861):
    /// a list of the crossings that can edit missed three (a load, an open, a
    /// run panel-menu item), and a miss reports a withdrawal late, beside an
    /// unrelated act. A pull that owes nothing is quiet and cheap, so no kind
    /// is exempt: the rule fails safe. The parameter stays so the rule is
    /// asked per command, where a future exemption would have to be argued.
    /// </summary>
    internal static bool ObserveAfter(string commandKind) => true;

    /// <summary>The pipe the shell serves, named for its own process: `\\.\pipe\jas-mcp-&lt;pid&gt;` (A6 F2 (a)).</summary>
    internal static string PipeName(int pid) =>
        string.Create(System.Globalization.CultureInfo.InvariantCulture, $"jas-mcp-{pid}");
}
