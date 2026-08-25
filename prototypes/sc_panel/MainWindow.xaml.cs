using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text.Json;
using Microsoft.UI.Xaml;

namespace ScPanel;

/// <summary>
/// The S-C materializer window, and the C1 + C2 measurement harness.
///
/// C1 is "open the panel cold": from an engine with no panel materialized to a
/// window of native controls. C2 is one colour-drag tick, measured at TWO
/// document sizes because one measurement cannot distinguish O(1) from O(n).
///
/// The crossings are counted BY THE RUST SIDE, not by counting call sites here —
/// a static count of the P/Invoke sites in this project would read identically
/// on a run that never happened.
/// </summary>
public sealed partial class MainWindow : Window
{
    /// <summary>
    /// The title a session-1 observer asserts on. Deliberately specific: a value
    /// only this app can produce. `MainWindowHandle` is NOT an oracle from the
    /// agent shell — it reads 0 for a rendering app and a blank one alike,
    /// because a session-0 process enumerates zero visible windows.
    /// </summary>
    public const string VerifyTitle = "JAS S-C.2 MATERIALIZER C1+C2";

    private const string PanelId = "color_panel_content";
    private const string SecondPanelId = "artboards_panel_content";

    /// <summary>
    /// The two document sizes, as TOTAL artboards. Pinned in the S-C.2 premise
    /// flags BEFORE anything was measured and accepted as pinned — the free
    /// parameter closed by the party being measured, before measuring.
    ///
    /// ⚠️ Named by role rather than by document path: the working record is
    /// private and a public source file should not carry a handle into it.
    /// </summary>
    private const int SmallDocument = 8;
    private const int LargeDocument = 200;

    /// <summary>The hue the tick drags to. Any value that is not the seed's.</summary>
    private const double TickHue = 210.0;

    public MainWindow()
    {
        InitializeComponent();
        Title = VerifyTitle;
        try
        {
            Run();
        }
        catch (Exception ex)
        {
            // Swallowing would leave an empty panel and a cheerful status, which
            // is the vacuous-success shape this whole spike exists to refuse.
            StatusLine.Text = $"FAILED - {ex.GetType().Name}: {ex.Message}";
            Title = $"{VerifyTitle} | SCFAIL {ex.GetType().Name}";
            TryWrite("sc-error.txt", ex.ToString());
        }
    }

    private void Run()
    {
        JasCore.Bind();

        var c1 = MeasureC1();
        var small = MeasureC2(SmallDocument, showInWindow: true);
        var large = MeasureC2(LargeDocument, showInWindow: false);

        // AMENDMENT 5: every check asserts a NON-ZERO amount of work examined. A
        // count has no natural failure mode — a harness that measured nothing
        // reports 0, which is a well-formed number that reads like a cheap
        // interaction. So zero is RED here, never "the tick is cheap".
        var vacuous =
            c1.Crossings <= 0 || c1.Nodes <= 0 || c1.Materialized <= 0 ||
            small.Crossings <= 0 || small.RowsChanged <= 0 ||
            large.Crossings <= 0 || large.RowsChanged <= 0 ||
            // ⛔ AND THE CLAUSE THE `layers` PANEL WOULD HAVE FAILED SILENTLY:
            // the two arms must actually DIFFER in widget count, or gate ② was
            // measured with its independent variable held constant.
            large.Widgets <= small.Widgets;

        var verdict = vacuous
            ? $"RED-VACUOUS c1={c1.Crossings} nodes={c1.Nodes} " +
              $"small={small.Crossings}/{small.RowsChanged}/{small.Widgets} " +
              $"large={large.Crossings}/{large.RowsChanged}/{large.Widgets}"
            : $"C1 {c1.Crossings}x/{c1.BytesTotal}b | " +
              $"C2@{SmallDocument} {small.Crossings}x/{small.BytesTotal}b/{small.Widgets}w | " +
              $"C2@{LargeDocument} {large.Crossings}x/{large.BytesTotal}b/{large.Widgets}w";

        StatusLine.Text = verdict;
        Title = $"{VerifyTitle} | {verdict}";

        // Written beside the exe so the session-0 agent shell can read what a
        // session-1 process saw: the two sessions share a filesystem and nothing
        // else. The window title carries the headline; this carries the rows.
        //
        // ⛔ `IncludeFields` IS LOAD-BEARING, AND ITS ABSENCE COST A RUN.
        // System.Text.Json serializes PROPERTIES only by default, and every
        // reading below is a public FIELD — so the first receipt came back as
        // `"c1": {}, "arms": [{}, {}]` beside a cheerful `"vacuous": false`.
        // The measurement was real and the file that carried it was empty:
        // a receipt that EXISTS is not a receipt that says anything, which is
        // this campaign's own class arriving in the output format. `WriteReceipt`
        // now refuses to write a receipt that lost its numbers.
        WriteReceipt("sc-c2.json", JsonSerializer.Serialize(new
        {
            vacuous,
            c1,
            arms = new[] { small, large },
            growth = new
            {
                widgets = Ratio(large.Widgets, small.Widgets),
                crossings_delta = large.Crossings - small.Crossings,
                // UNGATED and reported at both sizes, per Amendment 8 ③: there
                // is no basis for a constant, and a figure that is reported but
                // not gated still gives whoever sets one later two points to set
                // it from instead of none.
                bytes = Ratio(large.BytesTotal, small.BytesTotal),
                engine_rows = Ratio(large.RowsEvaluated, small.RowsEvaluated),
            },
        }, new JsonSerializerOptions { WriteIndented = true, IncludeFields = true }));
    }

    /// <summary>
    /// Write the receipt, but only if it still carries the numbers it exists to
    /// carry. A serializer that silently drops every field produces a
    /// well-formed file, and a well-formed file is what the run script reports
    /// as success — so the check is on the CONTENT, not on the write.
    /// </summary>
    private static void WriteReceipt(string name, string body)
    {
        if (!body.Contains("\"BytesTotal\"") || !body.Contains("\"RowsEvaluated\""))
        {
            TryWrite("sc-error.txt",
                "RECEIPT REFUSED: the serialized readings carry no fields.\n" +
                "JsonSerializer emits properties only unless IncludeFields is set,\n" +
                "and every reading here is a public field.\n\n" + body);
            throw new InvalidOperationException(
                "receipt lost its readings - see sc-error.txt");
        }
        TryWrite(name, body);
    }

    private sealed class C1Reading
    {
        public int Crossings;
        public int BytesTotal;
        public int Nodes;
        public int Materialized;
        public int Placeholders;
        public int ValuesApplied;
        public string Counters = "";
    }

    /// <summary>
    /// C1 — open the colour panel cold, on a document with no artboards added.
    ///
    /// ⚖️ RE-RUN UNDER A RULING, not for completeness. Route (a) grew the
    /// engine-assembled scope with an `active_document` namespace, which changes
    /// what the engine assembles for EVERY panel — so C1's published figure
    /// (4 crossings / 23,050 bytes) had to be re-measured rather than assumed
    /// still true, or a number in a report would quietly stop describing what it
    /// names.
    /// </summary>
    private C1Reading MeasureC1()
    {
        var engine = NewEngine();
        try
        {
            // Reset AFTER the engine exists. C1 is the cost of opening a PANEL,
            // and engine creation is app startup, not panel construction. Stated
            // because the boundary between the two is a choice and a reader
            // should not have to infer which side it fell on.
            JasCore.jas_instr_reset();
            var built = Materializer.Build(engine, PanelId);
            // DUMP LAST. A dump taken mid-interaction has to be freed, and that
            // free is itself a counted crossing that would land in this reading.
            var counters = JasCore.Take(JasCore.jas_instr_counters_json());

            return new C1Reading
            {
                Crossings = ReadInt(counters, "crossings"),
                BytesTotal = ReadInt(counters, "bytes_total"),
                Nodes = built.Nodes,
                Materialized = built.Materialized,
                Placeholders = built.Placeholders,
                ValuesApplied = built.ValuesApplied,
                Counters = counters,
            };
        }
        finally
        {
            JasCore.jas_engine_free(engine);
        }
    }

    private sealed class C2Reading
    {
        public int Artboards;
        public int Widgets;
        public int ColourWidgets;
        public int SecondPanelWidgets;
        public int Materialized;
        public int Placeholders;
        public int Crossings;
        public int BytesTotal;
        public int RowsChanged;
        public int RowsValueKeyed;
        public int ControlsUpdated;
        public int RowsToPlaceholder;
        public int RowsUnplaced;
        public int ReplyBytes;
        public int RowsEvaluated;
        public int PanelsEvaluated;
        public int NaiveWholePanelBytes;
        public string Counters = "";
    }

    /// <summary>
    /// C2 — one colour-drag tick with both panels open, on a document of
    /// `artboards` TOTAL artboards.
    /// </summary>
    /// <remarks>
    /// The document is grown through `create_artboard`, a live id-minting
    /// `op_apply` verb, so the second panel grows because THE DOCUMENT GREW —
    /// the second arm is not synthetic. ⚠️ A fresh document already holds ONE
    /// artboard, so this creates `artboards - 1` and the figure reported is the
    /// TOTAL. Creating `artboards` of them would make "8 and 200" quietly mean
    /// 9 and 201.
    /// </remarks>
    private C2Reading MeasureC2(int artboards, bool showInWindow)
    {
        var engine = NewEngine();
        try
        {
            for (var i = 1; i < artboards; i++)
            {
                var op = JasCore.Utf8(
                    $"{{\"op\":\"create_artboard\",\"id\":\"sc2ab{i.ToString("D3", CultureInfo.InvariantCulture)}\"}}");
                var st = JasCore.jas_dispatch_event(engine, op, (nuint)op.Length);
                if (st != 0)
                {
                    throw new InvalidOperationException($"create_artboard {i} refused with status {st}");
                }
            }

            var colour = Materializer.Build(engine, PanelId);
            var second = Materializer.Build(engine, SecondPanelId);
            var open = new List<Materializer.Result> { colour, second };

            // THE MEASURED WINDOW IS THE TICK ALONE. Everything above is setup
            // and would otherwise be in the reading.
            JasCore.jas_instr_reset();
            var tick = Materializer.Tick(engine, PanelId, "cp_h", TickHue, open);
            var counters = JasCore.Take(JasCore.jas_instr_counters_json());

            // Measured AFTER the dump, so it is not in the tick's figure: what
            // the trivial whole-panel re-read would have cost on this same
            // panel, at this same colour. Gate ③'s ceiling is quoted from C1's
            // 7,038, and this is the number that ceiling is supposed to be — so
            // a PASS can be reported as what it is, "no worse than re-reading
            // everything", rather than as validation of a delta protocol.
            var idBytes = JasCore.Utf8(PanelId);
            var naive = JasCore.Take(JasCore.jas_bind_values(engine, idBytes, (nuint)idBytes.Length));

            if (showInWindow)
            {
                PanelHost.Children.Add(colour.Root);
                SecondPanelHost.Children.Add(second.Root);
            }

            return new C2Reading
            {
                Artboards = artboards,
                Widgets = colour.Nodes + second.Nodes,
                ColourWidgets = colour.Nodes,
                SecondPanelWidgets = second.Nodes,
                Materialized = colour.Materialized + second.Materialized,
                Placeholders = colour.Placeholders + second.Placeholders,
                Crossings = ReadInt(counters, "crossings"),
                BytesTotal = ReadInt(counters, "bytes_total"),
                RowsChanged = tick.RowsChanged,
                RowsValueKeyed = tick.RowsValueKeyed,
                ControlsUpdated = tick.ControlsUpdated,
                RowsToPlaceholder = tick.RowsToPlaceholder,
                RowsUnplaced = tick.RowsUnplaced,
                ReplyBytes = tick.ReplyBytes,
                RowsEvaluated = ReadEngineInt(counters, "rows_evaluated"),
                PanelsEvaluated = ReadEngineInt(counters, "panels_evaluated"),
                NaiveWholePanelBytes = System.Text.Encoding.UTF8.GetByteCount(naive),
                Counters = counters,
            };
        }
        finally
        {
            JasCore.jas_engine_free(engine);
        }
    }

    private static IntPtr NewEngine()
    {
        var engine = JasCore.jas_engine_new();
        if (engine == IntPtr.Zero)
        {
            throw new InvalidOperationException("jas_engine_new returned NULL");
        }
        return engine;
    }

    private static double Ratio(int large, int small) =>
        small <= 0 ? 0 : Math.Round((double)large / small, 3);

    private static int ReadInt(string json, string field)
    {
        try
        {
            return JsonDocument.Parse(json).RootElement.GetProperty(field).GetInt32();
        }
        catch
        {
            return -1;
        }
    }

    private static int ReadEngineInt(string json, string field)
    {
        try
        {
            return JsonDocument.Parse(json).RootElement
                .GetProperty("engine").GetProperty(field).GetInt32();
        }
        catch
        {
            return -1;
        }
    }

    private static void TryWrite(string name, string body)
    {
        try
        {
            File.WriteAllText(Path.Combine(AppContext.BaseDirectory, name), body);
        }
        catch
        {
            // Diagnostics must never become the failure.
        }
    }
}
