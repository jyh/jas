using System;
using System.Collections.Generic;
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
        public FrameworkElement Root = new Grid();
        public int Materialized;
        public int Placeholders;
        public int ValuesApplied;
        public int Nodes;
    }

    /// <summary>
    /// C1: build the panel from cold. Two reads and two frees — four crossings
    /// before a single control exists.
    /// </summary>
    internal static Result Build(IntPtr engine, string panelId)
    {
        var idBytes = JasCore.Utf8(panelId);
        var treeJson = JasCore.Take(
            JasCore.jas_widget_tree(engine, idBytes, (nuint)idBytes.Length, null, 0));
        var valuesJson = JasCore.Take(
            JasCore.jas_bind_values(engine, idBytes, (nuint)idBytes.Length));

        var result = new Result();
        if (string.IsNullOrEmpty(treeJson))
        {
            return result;
        }

        var nodes = JsonDocument.Parse(treeJson).RootElement;
        var values = BuildValueMap(valuesJson, result);

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
            }
        }

        result.Root = panel;
        return result;
    }

    /// <summary>
    /// C2: one colour-drag tick. Dispatch the change, then re-read.
    ///
    /// ⚠️ THE RE-READ IS WHOLE-PANEL, AND THAT IS THE CHATTER FINDING RATHER
    /// THAN A SHORTCUT TAKEN HERE. The surface offers no per-widget and no
    /// per-binding read: <c>jas_bind_values</c> takes a PANEL identifier and
    /// returns every row the panel has. So a tick that moves one channel must
    /// re-fetch all of them. This was NOT engineered around, on the sequencer's
    /// explicit instruction — if a tick forces a whole-panel re-fetch, that is
    /// the finding and it gets reported as one.
    /// </summary>
    internal static int Tick(IntPtr engine, string panelId, string opJson, Result into)
    {
        var op = JasCore.Utf8(opJson);
        var status = JasCore.jas_dispatch_event(engine, op, (nuint)op.Length);

        var idBytes = JasCore.Utf8(panelId);
        var valuesJson = JasCore.Take(
            JasCore.jas_bind_values(engine, idBytes, (nuint)idBytes.Length));
        BuildValueMap(valuesJson, into);
        return status;
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
