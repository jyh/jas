using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace ScPanel;

/// <summary>
/// Turn the Rust core's panel description into NATIVE WinUI controls.
///
/// This is the arm S-C actually builds: native-materialized panels. The
/// painter-drawn arm is deliberately NOT built (sequencer's ruling), which is
/// why this spike can show the materializer LOSES and cannot show it WINS.
///
/// # Two calls, because the core describes a panel in two passes
///
/// <c>jas_widget_tree</c> gives STRUCTURE and is value-blind BY DESIGN — it
/// records the sorted KEY NAMES of each node's bindings, not what they resolve
/// to, which is what keeps it stable across ports. <c>jas_bind_values</c> gives
/// the resolved values. A materializer needs both, and that is why the surface
/// grew a ninth function rather than this file growing an expression evaluator.
///
/// ⛔ NOTHING HERE INTERPRETS. No expression is evaluated, no binding is
/// resolved, no jas-specific rule is encoded. Every value displayed arrives
/// already resolved from the core. That is the dumb-shell doctrine, and it is
/// the property that makes this a materializer rather than a third interpreter.
/// </summary>
internal static class Materializer
{
    /// <summary>
    /// The widget kinds S-C.1 materializes. Measured against the Colour panel's
    /// 106 widgets: these cover 71. The remaining 35 (color_swatch 14, slider
    /// 14, icon_button 6, color_bar 1) are S-C.2's and are rendered as a labelled
    /// placeholder so the count of what is NOT built stays visible in the window
    /// instead of quietly reading as an empty area.
    /// </summary>
    internal static readonly HashSet<string> EasyKinds = new()
    {
        "container", "row", "col", "grid", "text", "separator", "spacer",
        "number_input", "text_input", "button", "select", "dropdown",
        "combo_box", "checkbox", "toggle", "label",
    };

    internal sealed class Result
    {
        public string PanelId = "";
        public FrameworkElement Root = new Grid();
        public int Materialized;
        public int Placeholders;
        public int ValuesApplied;
        public int Nodes;

        /// <summary>
        /// The controls this panel put on screen, by widget id — the other half
        /// of the tick. A protocol that delivers a delta the shell cannot APPLY
        /// has measured half an interaction: the pinned tick runs "from the
        /// shell receiving the input to every dependent control showing the new
        /// value", and without this map the second clause never happens.
        /// </summary>
        public readonly Dictionary<string, FrameworkElement> Controls = new(StringComparer.Ordinal);

        /// <summary>What each widget currently displays. The shell's own map.</summary>
        public readonly Dictionary<string, string> Values = new(StringComparer.Ordinal);
    }

    /// <summary>
    /// C1: build the panel from cold. Two reads and two frees — four crossings
    /// before a single control exists.
    /// </summary>
    /// <remarks>
    /// The ctx span is NULL, which is the production call: the engine assembles
    /// the panel's data scope. A shell that supplied one would be holding app
    /// state in C# (BL1), and for a data-driven panel it would also be deciding
    /// how many rows the panel has.
    /// </remarks>
    internal static Result Build(IntPtr engine, string panelId)
    {
        var idBytes = JasCore.Utf8(panelId);
        var treeJson = JasCore.Take(
            JasCore.jas_widget_tree(engine, idBytes, (nuint)idBytes.Length, null, 0));
        var valuesJson = JasCore.Take(
            JasCore.jas_bind_values(engine, idBytes, (nuint)idBytes.Length));

        var result = new Result { PanelId = panelId };
        if (string.IsNullOrEmpty(treeJson))
        {
            return result;
        }

        var nodes = JsonDocument.Parse(treeJson).RootElement;
        var values = BuildValueMap(valuesJson, result);
        foreach (var kv in values)
        {
            result.Values[kv.Key] = kv.Value;
        }

        var panel = new StackPanel { Orientation = Orientation.Vertical, Spacing = 2 };
        foreach (var node in nodes.EnumerateArray())
        {
            result.Nodes++;
            var kind = node.TryGetProperty("kind", out var k) ? k.GetString() ?? "" : "";
            var id = node.TryGetProperty("id", out var i) ? i.GetString() ?? "" : "";

            // `visible` is a plain bool on the record; a DYNAMIC visible was
            // already collapsed to `dyn_visible` by the core and its resolved
            // value arrives in the bind map. Neither is evaluated here.
            var visible = !node.TryGetProperty("visible", out var v) || v.ValueKind != JsonValueKind.False;
            if (!visible)
            {
                continue;
            }

            var element = Materialize(kind, id, values, result);
            if (element is not null)
            {
                panel.Children.Add(element);
                // LAST ONE WINS, deliberately: a compiled panel can carry the
                // same id twice (the H slider and its number box are cp_h and
                // cp_h_val, but a template that repeats one really would), and
                // both bind the same expression by construction, so either is a
                // correct target. Stated rather than left to a reader who finds
                // one control updating and assumes the other is broken.
                if (id.Length > 0)
                {
                    result.Controls[id] = element;
                }
            }
        }

        result.Root = panel;
        return result;
    }

    /// <summary>
    /// Where every changed row went. **The breakdown is the point, not the
    /// total**: "22 rows changed, 11 controls updated" invites a reader to
    /// conclude half the delta was lost, and the truth is that the other half
    /// is rows this stage does not consume plus widgets this stage does not
    /// build. A number without its denominator is this campaign's most
    /// expensive habit.
    /// </summary>
    internal sealed class TickResult
    {
        /// Rows in the reply.
        public int RowsChanged;
        public int ReplyBytes;

        /// Of those, rows carrying `bind.value` — the only key a control's
        /// displayed value comes from. The rest are `bind.color`,
        /// `bind.disabled`, `bind.visible` and friends, which drive appearance
        /// this stage does not materialize.
        public int RowsValueKeyed;

        /// `bind.value` rows whose widget is a REAL typed control, and which
        /// were therefore shown. This is the tick's second clause.
        public int ControlsUpdated;

        /// `bind.value` rows whose widget is a labelled PLACEHOLDER — the
        /// sliders among them. Not a lost row: a widget the hard-widget stage
        /// has not built, and that stage is unfunded.
        public int RowsToPlaceholder;

        /// `bind.value` rows naming a widget this panel never put on screen
        /// (statically hidden, or in a panel the shell does not hold). ⚠️ THIS
        /// IS THE ONE THAT WOULD BE A DEFECT if it were large: a row the engine
        /// says moved and the shell has nowhere to put.
        public int RowsUnplaced;
    }

    /// <summary>
    /// C2: ONE COLOUR-DRAG TICK. The whole interaction, end to end.
    ///
    /// The pinned definition is "one pointer-move during a colour drag that
    /// CHANGES THE ACTIVE COLOUR, from the shell receiving the input to every
    /// dependent control showing the new value." Both clauses are here: the
    /// crossing, and the application of what came back to the controls.
    ///
    /// ⚠️ THE SHELL NAMES A WIDGET, NOT A CHANNEL. <c>cp_h</c> and the number
    /// the slider produced — nothing about hue, colour or mode crosses from this
    /// side. The engine resolves the widget to its binding and decides what the
    /// number means, which is the whole difference between a materializer and a
    /// third interpreter.
    ///
    /// ⭐ ONE CROSSING, NOT TWO. The reply carries the changed rows, so this is
    /// <c>jas_panel_event</c> plus the <c>jas_free</c> inside <c>Take</c>. The
    /// S-C.1 version of this method dispatched and then re-read the whole panel,
    /// which is three crossings and 7,038 bytes; the difference is the protocol
    /// S-C.2 exists to build, and both numbers are in the report.
    /// </summary>
    internal static TickResult Tick(
        IntPtr engine, string panelId, string widgetId, double value, IEnumerable<Result> open)
    {
        var ev = $"{{\"widget\":\"{widgetId}\",\"key\":\"bind.value\",\"value\":{value.ToString(CultureInfo.InvariantCulture)}}}";
        var evBytes = JasCore.Utf8(ev);
        var idBytes = JasCore.Utf8(panelId);
        var reply = JasCore.Take(JasCore.jas_panel_event(
            engine, idBytes, (nuint)idBytes.Length, evBytes, (nuint)evBytes.Length));

        var result = new TickResult { ReplyBytes = Encoding.UTF8.GetByteCount(reply) };
        if (string.IsNullOrEmpty(reply))
        {
            return result;
        }

        var byPanel = new Dictionary<string, Result>(StringComparer.Ordinal);
        foreach (var p in open)
        {
            byPanel[p.PanelId] = p;
        }

        foreach (var row in JsonDocument.Parse(reply).RootElement.EnumerateArray())
        {
            result.RowsChanged++;
            var panel = row.TryGetProperty("panel", out var pn) ? pn.GetString() ?? "" : "";
            var id = row.TryGetProperty("id", out var i) ? i.GetString() ?? "" : "";
            var key = row.TryGetProperty("key", out var k) ? k.GetString() ?? "" : "";
            var val = row.TryGetProperty("value", out var v) ? v.GetString() ?? "" : "";
            if (key != "bind.value" || id.Length == 0 || !byPanel.TryGetValue(panel, out var target))
            {
                continue;
            }
            result.RowsValueKeyed++;
            target.Values[id] = val;
            if (!target.Controls.TryGetValue(id, out var control))
            {
                result.RowsUnplaced++;
            }
            else if (ApplyValue(control, val))
            {
                result.ControlsUpdated++;
            }
            else
            {
                // A control that exists and cannot take a value is a
                // placeholder: the hard-widget stage's, not a lost row.
                result.RowsToPlaceholder++;
            }
        }
        return result;
    }

    /// <summary>
    /// Show a resolved value in a native control. Returns whether anything was
    /// shown — a `false` here is a control the delta reached and could not
    /// update, which is a stale display and NOT a cheap tick.
    ///
    /// ⛔ Still no interpretation: the value arrives already resolved and this
    /// only chooses which property of which control type carries it.
    /// </summary>
    private static bool ApplyValue(FrameworkElement control, string value)
    {
        switch (control)
        {
            case TextBlock t: t.Text = value; return true;
            case TextBox tb: tb.Text = value; return true;
            case NumberBox nb:
                nb.Value = double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var d)
                    ? d : nb.Value;
                return true;
            case CheckBox cb: cb.IsChecked = value == "true"; return true;
            case ComboBox combo:
                combo.Items.Clear();
                combo.Items.Add(value);
                combo.SelectedIndex = 0;
                return true;
            case Button b: b.Content = value; return true;
            default: return false;
        }
    }

    /// <summary>
    /// Map one widget-tree record to a native control.
    ///
    /// Every branch returns a REAL WinUI control, not a stand-in: that is what
    /// makes the line count in this file comparable to the painter-drawn
    /// reference's, which draws its own chrome.
    /// </summary>
    private static FrameworkElement? Materialize(
        string kind, string id, IReadOnlyDictionary<string, string> values, Result result)
    {
        if (!EasyKinds.Contains(kind))
        {
            result.Placeholders++;
            return new Border
            {
                Height = 18,
                Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                Child = new TextBlock
                {
                    Text = $"[{kind}]",
                    Opacity = 0.45,
                    FontSize = 10,
                },
            };
        }

        result.Materialized++;
        var value = id.Length > 0 && values.TryGetValue(id, out var v) ? v : null;
        if (value is not null)
        {
            result.ValuesApplied++;
        }

        switch (kind)
        {
            case "container":
            case "row":
                return new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            case "col":
            case "grid":
                return new StackPanel { Orientation = Orientation.Vertical, Spacing = 2 };
            case "text":
            case "label":
                return new TextBlock { Text = value ?? string.Empty, FontSize = 12 };
            case "separator":
                return new Border { Height = 1, Background = new SolidColorBrush(Microsoft.UI.Colors.Gray) };
            case "spacer":
                return new Border { Height = 6 };
            case "number_input":
                return new NumberBox
                {
                    Value = double.TryParse(value, out var d) ? d : 0,
                    SmallChange = 1,
                    SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact,
                    Width = 64,
                };
            case "text_input":
                return new TextBox { Text = value ?? string.Empty, Width = 96 };
            case "button":
                return new Button { Content = value ?? id };
            case "checkbox":
            case "toggle":
                return new CheckBox { IsChecked = value == "true", Content = value ?? string.Empty };
            case "select":
            case "dropdown":
            case "combo_box":
                var combo = new ComboBox { Width = 96 };
                if (value is not null)
                {
                    combo.Items.Add(value);
                    combo.SelectedIndex = 0;
                }
                return combo;
            default:
                // Reachable only if EasyKinds and this switch disagree. Counted
                // as a placeholder rather than silently dropped, because a widget
                // that vanishes leaves a panel that looks merely sparse.
                result.Materialized--;
                result.Placeholders++;
                return new TextBlock { Text = $"[unmapped {kind}]", Opacity = 0.45, FontSize = 10 };
        }
    }

    /// <summary>
    /// Index the resolved bind rows by widget id.
    ///
    /// Rows are <c>{path,id,key,type,value}</c> and are keyed by widget PROPERTY
    /// (<c>bind.value</c>, <c>bind.color</c>, ...) — NOT by channel name. That
    /// cost a vacuous test to learn: a check that looked for <c>bind.r</c> found
    /// nothing and passed, having asserted nothing at all.
    /// </summary>
    private static Dictionary<string, string> BuildValueMap(string json, Result result)
    {
        var map = new Dictionary<string, string>(StringComparer.Ordinal);
        if (string.IsNullOrEmpty(json))
        {
            return map;
        }
        foreach (var row in JsonDocument.Parse(json).RootElement.EnumerateArray())
        {
            var id = row.TryGetProperty("id", out var i) ? i.GetString() ?? "" : "";
            var key = row.TryGetProperty("key", out var k) ? k.GetString() ?? "" : "";
            var val = row.TryGetProperty("value", out var v) ? v.GetString() ?? "" : "";
            if (id.Length > 0 && key == "bind.value")
            {
                map[id] = val;
            }
        }
        return map;
    }
}
