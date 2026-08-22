// S-A — the boundary spike's C# half.
//
// A console harness, deliberately NOT WinUI: gate (i) is "builds headless from
// the CLI on kenai, cargo + dotnet, no Visual Studio", and a GUI would make that
// unanswerable. The surface and the boundary laws BL1-BL6 this file obeys are
// documented in jas_dioxus/src/ffi.rs.
//
// BL5 is why there is not one `string` in any DllImport signature below. The
// default P/Invoke CharSet is Ansi -- the active code page, cp1252 on this box --
// so a `string` parameter would silently mangle non-Latin-1 content in exactly
// the way a bare open() did in shared Python on this seat's first day.

using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

internal static class Jas
{
    private const string Lib = "jas_dioxus";

    [StructLayout(LayoutKind.Sequential)]
    internal struct Bytes
    {
        public IntPtr Ptr;
        public UIntPtr Len;
    }

    // 1-5 are the five frozen OpError classes, by position. >= 100 are transport
    // faults that never reached the core.
    internal enum Status
    {
        Ok = 0,
        MalformedEnvelope = 1,
        UnknownVerb = 2,
        MissingParam = 3,
        BadParamType = 4,
        MissingTarget = 5,
        BadUtf8 = 100,
        BadJson = 101,
        NullHandle = 102,
    }

    [DllImport(Lib)] internal static extern IntPtr jas_engine_new();
    [DllImport(Lib)] internal static extern void jas_engine_free(IntPtr e);
    [DllImport(Lib)] internal static extern void jas_free(Bytes b);
    [DllImport(Lib)] internal static extern Bytes jas_version();
    [DllImport(Lib)] internal static extern Bytes jas_document_json(IntPtr e);
    [DllImport(Lib)] internal static extern Bytes jas_last_error_json(IntPtr e);

    [DllImport(Lib)]
    internal static extern Status jas_dispatch_event(IntPtr e, byte[] opJson, UIntPtr len);

    [DllImport(Lib)]
    internal static extern Bytes jas_widget_tree(
        IntPtr e, byte[] panelId, UIntPtr panelLen, byte[] ctxJson, UIntPtr ctxLen);

    /// BL4: Rust owns the allocation. Copy immediately, then free. Never let a
    /// finalizer or Marshal.FreeHGlobal near it.
    internal static string Take(Bytes b)
    {
        if (b.Ptr == IntPtr.Zero || b.Len == UIntPtr.Zero) return string.Empty;
        int n = checked((int)b.Len);
        var buf = new byte[n];
        Marshal.Copy(b.Ptr, buf, 0, n);
        jas_free(b);
        return Encoding.UTF8.GetString(buf);
    }

    internal static Status Dispatch(IntPtr e, string opJson)
    {
        var b = Encoding.UTF8.GetBytes(opJson);
        return jas_dispatch_event(e, b, (UIntPtr)b.Length);
    }

    internal static string WidgetTree(IntPtr e, string panel, string ctxJson)
    {
        var p = Encoding.UTF8.GetBytes(panel);
        var c = Encoding.UTF8.GetBytes(ctxJson);
        return Take(jas_widget_tree(e, p, (UIntPtr)p.Length, c, (UIntPtr)c.Length));
    }
}

internal static class Program
{
    private static int _pass, _fail;

    private static void Check(bool ok, string what, string? detail = null)
    {
        if (ok) { _pass++; Console.WriteLine($"  PASS  {what}"); }
        else { _fail++; Console.WriteLine($"  FAIL  {what}{(detail is null ? "" : $"\n        {detail}")}"); }
    }

    /// Canonical form: object keys sorted, arrays in order. Both sides go through
    /// this, so the comparison is of CONTENT, not of serializer key order.
    private static string Canon(JsonNode? n)
    {
        var sb = new StringBuilder();
        Write(n, sb);
        return sb.ToString();

        static void Write(JsonNode? node, StringBuilder sb)
        {
            switch (node)
            {
                case null: sb.Append("null"); break;
                case JsonObject o:
                    sb.Append('{');
                    bool first = true;
                    foreach (var kv in o.OrderBy(k => k.Key, StringComparer.Ordinal))
                    {
                        if (!first) sb.Append(',');
                        first = false;
                        sb.Append(JsonSerializer.Serialize(kv.Key)).Append(':');
                        Write(kv.Value, sb);
                    }
                    sb.Append('}');
                    break;
                case JsonArray a:
                    sb.Append('[');
                    for (int i = 0; i < a.Count; i++)
                    {
                        if (i > 0) sb.Append(',');
                        Write(a[i], sb);
                    }
                    sb.Append(']');
                    break;
                default: sb.Append(node.ToJsonString()); break;
            }
        }
    }

    private static int Main(string[] args)
    {
        // Resolve the cdylib explicitly rather than relying on PATH, so the
        // harness proves it loaded the library cargo just built.
        string repo = args.Length > 0
            ? args[0]
            : Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", ".."));
        string dll = Path.Combine(repo, "jas_dioxus", "target", "debug", "jas_dioxus.dll");
        string golden = Path.Combine(repo, "test_fixtures", "algorithms", "panel_widget_tree.json");

        NativeLibrary.SetDllImportResolver(Assembly.GetExecutingAssembly(), (name, asm, path) =>
            name == "jas_dioxus" ? NativeLibrary.Load(dll) : IntPtr.Zero);

        Console.WriteLine("S-A boundary spike — C# console harness");
        Console.WriteLine($"  cdylib : {dll}");
        Console.WriteLine($"  exists : {File.Exists(dll)}");
        if (!File.Exists(dll)) { Console.Error.WriteLine("cdylib not built; run cargo first"); return 2; }
        Console.WriteLine();

        var sw = Stopwatch.StartNew();
        IntPtr e = Jas.jas_engine_new();
        Check(e != IntPtr.Zero, "jas_engine_new returns a handle");

        // ---- lifecycle + BL4 ------------------------------------------------
        Console.WriteLine("\n[lifecycle]");
        string version = Jas.Take(Jas.jas_version());
        Check(version.Contains("\"crate\":\"jas_dioxus\""), "jas_version round-trips a UTF-8 span", version);
        for (int i = 0; i < 1000; i++) Jas.Take(Jas.jas_version());
        Check(true, "1000 alloc/copy/jas_free cycles without a crash (BL4)");

        // ---- GATE (iii): dispatch_event applies an op, canonical JSON reads back
        Console.WriteLine("\n[gate iii — dispatch_event / document_json]");
        string before = Jas.Take(Jas.jas_document_json(e));
        Check(before.Length > 0, "jas_document_json returns canonical JSON on a fresh engine");

        var st = Jas.Dispatch(e, "{\"op\":\"create_artboard\",\"id\":\"sa-ab-1\"}");
        Check(st == Jas.Status.Ok, $"create_artboard applies (status={st})");
        string after = Jas.Take(Jas.jas_document_json(e));
        Check(after != before, "the document changed after the op");
        Check(after.Contains("sa-ab-1"), "the new artboard id reads back in canonical JSON");

        // ---- the error channel: the frozen classes, by position ---------------
        Console.WriteLine("\n[error channel — the five frozen classes]");
        Check(Jas.Dispatch(e, "{\"not_an_op\":1}") == Jas.Status.MalformedEnvelope,
            "no verb                -> MalformedEnvelope (1)");
        Check(Jas.Dispatch(e, "{\"op\":\"no_such_verb\"}") == Jas.Status.UnknownVerb,
            "unknown verb           -> UnknownVerb (2)");
        Check(Jas.Dispatch(e, "{\"op\":\"create_artboard\"}") == Jas.Status.MissingParam,
            "create_artboard, no id -> MissingParam (3)");
        Check(Jas.Dispatch(e, "{\"op\":\"create_artboard\",\"id\":\"\"}") == Jas.Status.BadParamType,
            "create_artboard, id=\"\" -> BadParamType (4)");

        string detail = Jas.Take(Jas.jas_last_error_json(e));
        Check(detail.Contains("\"class\":\"BadParamType\""),
            "jas_last_error_json spells the class as the fixtures spell it", detail);

        Check(Jas.Dispatch(e, "{not json") == Jas.Status.BadJson,
            "malformed JSON         -> BadJson (101), a TRANSPORT fault");
        Check((int)Jas.Status.BadJson >= 100 && (int)Jas.Status.MissingTarget < 100,
            "transport codes never collide with the ratified 1-5 range");

        // ---- BL5: UTF-8 across the boundary, not the active code page ---------
        Console.WriteLine("\n[BL5 — UTF-8 byte spans]");
        var stU = Jas.Dispatch(e, "{\"op\":\"create_artboard\",\"id\":\"Ünïcodé-Ω-日本\"}");
        Check(stU == Jas.Status.Ok, $"an op carrying non-Latin-1 text applies (status={stU})");
        string afterU = Jas.Take(Jas.jas_document_json(e));
        Check(afterU.Contains("Ünïcodé-Ω-日本"),
            "non-Latin-1 survives the ABI intact — cp1252 marshaling would have mangled it");

        // ---- GATE (ii): widget_tree byte-identical to the shared golden -------
        Console.WriteLine("\n[gate ii — widget_tree against the shared golden]");
        if (!File.Exists(golden))
        {
            Check(false, "golden fixture present", golden);
        }
        else
        {
            var cases = JsonNode.Parse(File.ReadAllText(golden))!.AsArray();
            int checkedCases = 0, mismatches = 0;
            string firstBad = "";
            foreach (var tc in cases)
            {
                string name = tc!["name"]!.GetValue<string>();
                string panel = tc["args"]!["panel"]!.GetValue<string>();
                var ctxNode = tc["args"]!["ctx"];
                string ctx = ctxNode is null ? "{}" : ctxNode.ToJsonString();

                string got = Jas.WidgetTree(e, panel, ctx);
                if (got.Length == 0) { mismatches++; if (firstBad == "") firstBad = $"{name}: empty result"; continue; }
                string a = Canon(JsonNode.Parse(got));
                string b = Canon(tc["expected"]);
                if (a != b)
                {
                    mismatches++;
                    if (firstBad == "") firstBad = $"{name}: first divergence at char {FirstDiff(a, b)}";
                }
                checkedCases++;
            }
            Check(cases.Count >= 16, $"golden carries the full panel set ({cases.Count} cases)");
            Check(mismatches == 0,
                $"all {cases.Count} panel widget trees match through the ABI", firstBad);
        }

        Jas.jas_engine_free(e);
        Check(true, "jas_engine_free");

        sw.Stop();
        Console.WriteLine($"\n{_pass} passed, {_fail} failed in {sw.ElapsedMilliseconds} ms");
        return _fail == 0 ? 0 : 1;

        static int FirstDiff(string a, string b)
        {
            int n = Math.Min(a.Length, b.Length);
            for (int i = 0; i < n; i++) if (a[i] != b[i]) return i;
            return n;
        }
    }
}
