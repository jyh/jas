using System;
using System.IO;
using System.Text.Json;
using Microsoft.UI.Xaml;

namespace ScPanel;

/// <summary>
/// The S-C.1 materializer window, and the C1 measurement harness.
///
/// C1 is "open the panel cold": from an engine with no panel materialized to a
/// window of native controls. The crossings are counted BY THE RUST SIDE, not by
/// counting call sites here — a static count of the P/Invoke sites in this
/// project would read identically on a run that never happened.
/// </summary>
public sealed partial class MainWindow : Window
{
    /// <summary>
    /// The title a session-1 observer asserts on. Deliberately specific: a value
    /// only this app can produce. `MainWindowHandle` is NOT an oracle from the
    /// agent shell — it reads 0 for a rendering app and a blank one alike,
    /// because a session-0 process enumerates zero visible windows.
    /// </summary>
    public const string VerifyTitle = "JAS S-C.1 MATERIALIZER C1";

    private const string PanelId = "color_panel_content";

    public MainWindow()
    {
        InitializeComponent();
        Title = VerifyTitle;
        try
        {
            RunC1();
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

    private void RunC1()
    {
        JasCore.Bind();
        var engine = JasCore.jas_engine_new();
        if (engine == IntPtr.Zero)
        {
            throw new InvalidOperationException("jas_engine_new returned NULL");
        }

        // Reset AFTER the engine exists. C1 is the cost of opening a PANEL, and
        // engine creation is app startup, not panel construction. Stated because
        // the boundary between the two is a choice and a reader should not have
        // to infer which side it fell on.
        JasCore.jas_instr_reset();

        var built = Materializer.Build(engine, PanelId);

        // DUMP LAST. A dump taken mid-interaction has to be freed, and that free
        // is itself a counted crossing that would land in this reading.
        var counters = JasCore.Take(JasCore.jas_instr_counters_json());

        PanelHost.Children.Add(built.Root);

        var crossings = ReadInt(counters, "crossings");
        var bytesTotal = ReadInt(counters, "bytes_total");

        // AMENDMENT 5: every check asserts a NON-ZERO amount of work examined.
        // A count has no natural failure mode — a harness that measured nothing
        // reports 0, which is a well-formed number that reads like a cheap
        // interaction. So zero is RED here, never "C1 is cheap".
        var vacuous = crossings <= 0 || built.Nodes <= 0 || built.Materialized <= 0;
        var verdict = vacuous
            ? $"RED-VACUOUS crossings={crossings} nodes={built.Nodes} materialized={built.Materialized}"
            : $"C1 crossings={crossings} bytes={bytesTotal} nodes={built.Nodes} " +
              $"materialized={built.Materialized} placeholders={built.Placeholders} " +
              $"values={built.ValuesApplied}";

        StatusLine.Text = verdict;
        Title = $"{VerifyTitle} | {verdict}";

        // Written beside the exe so the session-0 agent shell can read what a
        // session-1 process saw: the two sessions share a filesystem and nothing
        // else. The window title carries the headline; this carries the rows.
        TryWrite("sc-c1.json", JsonSerializer.Serialize(new
        {
            interaction = "C1_open_panel_cold",
            panel = PanelId,
            vacuous,
            nodes = built.Nodes,
            materialized = built.Materialized,
            placeholders = built.Placeholders,
            values_applied = built.ValuesApplied,
            counters = JsonDocument.Parse(counters).RootElement,
        }, new JsonSerializerOptions { WriteIndented = true }));

        JasCore.jas_engine_free(engine);
    }

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
