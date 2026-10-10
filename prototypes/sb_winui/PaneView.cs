// One PaneView per pane, added 2026-10-10.
//
// Moved out of MainWindow.xaml.cs unchanged except for the instance it now
// belongs to: every control, receipt and icon load below was written for ONE
// pane, and is now a pane's own, so a toolbar pane and a dock pane can each
// hold their plan, their drawn controls and their pending icon loads without
// reading each other's. What the window owns (the report line, the canvas,
// the selector) is reached through `_w`.

using System;
using System.Collections.Generic;
using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;

namespace SbWinUi;

public sealed partial class MainWindow
{
    private sealed class PaneView
    {
        private readonly MainWindow _w;
        private readonly Border _host;
        private readonly ScrollViewer _scroll;
        private readonly long _availW;
        private readonly bool _topAligned;

        internal PaneView(MainWindow w, Border host, ScrollViewer scroll, long availW, string firstPanel,
                          bool topAligned = false)
        {
            _topAligned = topAligned;
            _w = w;
            _host = host;
            _scroll = scroll;
            _availW = availW;
            _paneDrawnPanel = firstPanel;
        }

        /// <summary>
        /// The panel whose plan the drawn controls were built from. A control
        /// addresses THIS panel, so a click is always sent to the panel whose
        /// control it is, even while a switch is still queued.
        /// </summary>
        internal string _paneDrawnPanel;

        /// <summary>The `Seq` of the plan currently drawn (see `_menuDrawnSeq`).</summary>
        private long _paneDrawnSeq;

        /// <summary>
        /// What the drawn controls were BUILT from: every leaf's path, type, id,
        /// rect, static strings and icon. A new plan with the same signature only
        /// moves values, so the controls are kept and updated in place; a
        /// different one is rebuilt.
        /// </summary>
        private string? _paneSignature;

        /// <summary>§1.2: the newest plan's `items` per leaf path, read by a
        /// dropdown's flyout when it opens.</summary>
        private readonly Dictionary<string, PaneItems> _paneItems = new(StringComparer.Ordinal);

        /// <summary>The drawn controls, by plan path.</summary>
        private readonly Dictionary<string, FrameworkElement> _paneControls = new();

        /// <summary>Icon loads still outstanding for the build numbered `_paneBuild`.</summary>
        private int _paneIconsPending;
        private int _paneIconsSvg;
        private int _paneIconsText;
        private int _paneIconsFailed;
        /// <summary>`brush_preview` loads, tallied apart from icons: they share the
        /// loader and its pending count, so the PANEL ICONS row still waits for
        /// them, but a failed preview must not read as a failed icon face.</summary>
        private int _panePreviewsSvg;
        private int _panePreviewsFailed;
        private int _paneBuild;

        /// <summary>One plan leaf, as this shell reads it. Values and static strings are the core's.</summary>
        private sealed record PaneLeaf(
            string Path, string Type, string Id, double X, double Y, double W, double H,
            Dictionary<string, string> Values, Dictionary<string, string> Static,
            Dictionary<string, string> Display, PaneOptions? Options, PaneItems? Items)
        {
            internal string? Value(string key) => Values.TryGetValue(key, out var v) ? v : null;
            internal string? Literal(string key) => Static.TryGetValue(key, out var v) ? v : null;

            /// <summary>
            /// W2b-9: the core's own formatted display string for a bind key, or
            /// null when it sent none. NULL AND EMPTY ARE DIFFERENT ANSWERS here:
            /// see `PanelWire.DisplayText`.
            /// </summary>
            internal string? Shown(string key) => Display.TryGetValue(key, out var v) ? v : null;

            /// <summary>
            /// The name this leaf's glyph is looked up under. The RULE lives in
            /// `PanelWire.IconName` so the desktop-less runner drives it; an
            /// `icon` node names its glyph under `name`, not `icon`.
            /// </summary>
            internal string? IconName => PanelWire.IconName(
                Value("bind.icon"), Literal("icon"), Literal("name"), Type);
        }

        // INSTANCE fields, not static: a brush is a XAML object, and an instance
        // initializer runs on the UI thread that builds this window, where a type
        // initializer runs wherever the type is first touched.
        private readonly Microsoft.UI.Xaml.Media.SolidColorBrush _paneInkBrush =
            new(Microsoft.UI.ColorHelper.FromArgb(0xFF, 0x1A, 0x1A, 0x1A));
        private readonly Microsoft.UI.Xaml.Media.SolidColorBrush _paneMutedBrush =
            new(Microsoft.UI.ColorHelper.FromArgb(0xFF, 0x80, 0x80, 0x80));
        private readonly Microsoft.UI.Xaml.Media.SolidColorBrush _paneCheckedFill =
            new(Microsoft.UI.ColorHelper.FromArgb(0xFF, 0xCD, 0xE3, 0xF7));
        private readonly Microsoft.UI.Xaml.Media.SolidColorBrush _paneCheckedEdge =
            new(Microsoft.UI.ColorHelper.FromArgb(0xFF, 0x2F, 0x6F, 0xB0));

        internal void DrawPane(PanelSnapshot snap)
        {
            using var doc = System.Text.Json.JsonDocument.Parse(snap.PlanJson);
            var root = doc.RootElement;
            var leaves = new List<PaneLeaf>();
            foreach (var e in root.GetProperty("leaves").EnumerateArray())
            {
                var rect = e.GetProperty("rect");
                leaves.Add(new PaneLeaf(
                    e.GetProperty("path").GetRawText(),
                    e.GetProperty("type").GetString() ?? "",
                    e.GetProperty("id").GetString() ?? "",
                    rect.GetProperty("x").GetInt64(),
                    rect.GetProperty("y").GetInt64(),
                    rect.GetProperty("w").GetInt64(),
                    rect.GetProperty("h").GetInt64(),
                    Strings(e.GetProperty("values")),
                    Strings(e.GetProperty("static")),
                    Strings(e.GetProperty("display")),
                    // W-b: null when the core sent `null` (no declared list) or an
                    // older core sent no key at all. The two read the same here:
                    // either way there is no list to offer.
                    PanelWire.ReadOptions(e.TryGetProperty("options", out var opts) ? opts.GetRawText() : null),
                    // §1.2: a dropdown's items, read the same way: null is no list.
                    PanelWire.ReadItems(e.TryGetProperty("items", out var its) ? its.GetRawText() : null)));
            }
            var icons = new Dictionary<string, (string Viewbox, string Svg)>();
            foreach (var ic in root.GetProperty("icons").EnumerateObject())
            {
                icons[ic.Name] = (ic.Value.GetProperty("viewbox").GetString() ?? "",
                                  ic.Value.GetProperty("svg").GetString() ?? "");
            }
            var height = root.GetProperty("height").GetInt64();

            // The panel id is part of the signature: two panels with the same
            // leaves would otherwise keep controls that address the wrong panel.
            var signature = snap.PanelId + "\n" + string.Join("\n", leaves.Select(l =>
                $"{l.Path}|{l.Type}|{l.Id}|{l.X},{l.Y},{l.W},{l.H}|{l.IconName}|"
                + string.Join(";", l.Static.OrderBy(kv => kv.Key, StringComparer.Ordinal)
                                           .Select(kv => $"{kv.Key}={kv.Value}"))
                // W-b: a list control's ITEMS are built once, so a changed list
                // must rebuild. The selection is not in it: it moves every tick
                // and is applied in place.
                + "|" + (l.Options?.Signature ?? "")));
            var rebuilt = signature != _paneSignature;
            _paneDrawnPanel = snap.PanelId;
            if (rebuilt) { BuildPane(leaves, icons, height); }
            _paneSignature = signature;

            // §1.2: a dropdown's flyout is built at every OPEN from the newest
            // plan's items, so a check the core moved is never shown stale and a
            // moved check need not rebuild the pane.
            _paneItems.Clear();
            foreach (var leaf in leaves)
            {
                if (leaf.Items is not null) { _paneItems[leaf.Path] = leaf.Items; }
            }

            var (disabled, @checked, hidden, editing) = (0, 0, 0, 0);
            foreach (var leaf in leaves)
            {
                if (!_paneControls.TryGetValue(leaf.Path, out var el)) { continue; }
                var (d, c, h, ed) = ApplyLeafValues(el, leaf);
                disabled += d;
                @checked += c;
                hidden += h;
                editing += ed;
            }

            // ⚠️ THE MENU ROW's ARITHMETIC, AND ITS LIMIT: this handler also reads the
            // CURRENT snapshot, so a gap is a coalesce OR a loss. Nothing asserts on
            // it; see `_menuDelivered` for the form that can tell them apart.
            var missed = snap.Seq - _paneDrawnSeq - 1;
            _paneDrawnSeq = snap.Seq;
            _w.Report($"PANEL DRAWN panel={snap.PanelId} seq={snap.Seq} cause={snap.Cause} "
                 + $"missed={(missed > 0 ? missed : 0)} rebuilt={(rebuilt ? "true" : "false")} "
                 + $"controls={_paneControls.Count} disabled={disabled} checked={@checked} hidden={hidden} "
                 + $"editing={editing} "
                 + $"pane-dips={_host.ActualWidth:0}x{_host.ActualHeight:0} "
                 + $"canvas-dips={_w.Canvas.ActualWidth:0}x{_w.Canvas.ActualHeight:0}");
        }

        private static Dictionary<string, string> Strings(System.Text.Json.JsonElement map)
        {
            var d = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var kv in map.EnumerateObject())
            {
                d[kv.Name] = kv.Value.ValueKind == System.Text.Json.JsonValueKind.String
                    ? kv.Value.GetString() ?? ""
                    : kv.Value.GetRawText();
            }
            return d;
        }

        /// <summary>
        /// Build every control, each at its canonical rect, and report what was
        /// built. A leaf type this shell has no control for is drawn as a muted
        /// `[type]` placeholder and COUNTED, never dropped.
        /// </summary>
        private void BuildPane(List<PaneLeaf> leaves, Dictionary<string, (string Viewbox, string Svg)> icons, long height)
        {
            _paneBuild++;
            _paneControls.Clear();
            _paneIconsPending = 0;
            _paneIconsSvg = 0;
            _paneIconsText = 0;
            _paneIconsFailed = 0;
            _panePreviewsSvg = 0;
            _panePreviewsFailed = 0;

            var host = new Microsoft.UI.Xaml.Controls.Canvas
            {
                Width = _availW,
                Height = height,
                Margin = new Thickness(PanePad),
            };
            // The toolbar's buttons sit at the TOP of its column, as every port
            // draws a toolbar. The dock keeps its placement (unchanged here).
            if (_topAligned) { host.VerticalAlignment = VerticalAlignment.Top; }
            // ⚠️ `toggles` COUNTS BOTH BOOLEAN KINDS since W2b-9, so its name now
            // understates its population -- ask what a count is a count OF before
            // quoting this row. It is NOT renamed: nothing parses these fields (only
            // a synthetic fixture string in `harness_selftest.ps1` carries them), the
            // vocabulary is read by eye on the Windows box, and `BOOLEAN_KINDS` is COMPLETE at
            // {toggle, checkbox} -- so the field can never drift further from its name.
            // `inputs` is in the same position: since W-b it counts the text inputs
            // {number_input, length_input} AND the list kinds {select, combo_box,
            // icon_select}, which are INPUT_KINDS in the same contract (a `commit`
            // carrying text). `optionsRefused` counts option rows this shell could
            // not read, so a list shown short is never shown silently.
            var (texts, buttons, inputs, toggles, glyphs, unmaterialized, unaddressable) = (0, 0, 0, 0, 0, 0, 0);
            var optionsRefused = 0;
            var (menus, itemsRefused) = (0, 0);
            var swatches = 0;
            var (previews, previewEmpty) = (0, 0);
            foreach (var leaf in leaves)
            {
                FrameworkElement el;
                switch (leaf.Type)
                {
                    case "text":
                        texts++;
                        el = new TextBlock
                        {
                            FontSize = 12,
                            Foreground = _paneInkBrush,
                            TextTrimming = TextTrimming.CharacterEllipsis,
                            TextWrapping = TextWrapping.NoWrap,
                            VerticalAlignment = VerticalAlignment.Center,
                        };
                        break;

                    // A bare `icon` is decoration: no id, no bind, no click. It
                    // is NOT counted in `unaddressable` -- see BuildIcon.
                    case "icon":
                        glyphs++;
                        el = BuildIcon(leaf, icons);
                        break;

                    case "icon_button":
                        buttons++;
                        if (leaf.Id.Length == 0) { unaddressable++; }
                        el = BuildIconButton(leaf, icons);
                        break;

                    // A swatch is a filled square whose colour the core sends as
                    // `bind.color` (STATUS-flask §110: 228 of Swatches' 234 leaves
                    // were placeholders). NOT a Button: ApplyLeafValues' Button arm
                    // clears Background on every draw, which would wipe the colour.
                    // A library tile has NO id (the template repeats per colour);
                    // its plan path addresses it, so the count reads the same
                    // predicate as the tap (STATUS-flask §114: 216 of 228 drew
                    // and sent nothing while this read the id alone).
                    case "color_swatch":
                        swatches++;
                        if (!PanelWire.Addressable(leaf.Id, leaf.Path)) { unaddressable++; }
                        el = BuildSwatch(leaf);
                        break;

                    // A brush tile's preview: the drawing the core sends in
                    // `display` (preview.svg + preview.viewbox), loaded as an icon
                    // is. A brush type with no preview is an EMPTY tile, counted
                    // as `preview-empty`, which is what the web port shows too.
                    case "brush_preview":
                        previews++;
                        el = BuildBrushPreview(leaf, ref previewEmpty);
                        break;

                    // A `length_input` is this control too: the person types TEXT
                    // and the core parses it by the widget's kind. What differs is
                    // the DISPLAY, and the core now sends that ready-made.
                    case "number_input":
                    case "length_input":
                        inputs++;
                        if (leaf.Id.Length == 0) { unaddressable++; }
                        el = BuildNumberInput(leaf);
                        break;

                    // A `checkbox` is this control too. The spec's own table puts
                    // both in ONE contract -- `BOOLEAN_KINDS = {toggle, checkbox}`,
                    // reached by PRESS_EVENTS -- and the plan carries the same keys
                    // for each (`bind.checked`, `label`, `summary`), so the builder
                    // and the applier below are already right for it.
                    case "toggle":
                    case "checkbox":
                        toggles++;
                        if (leaf.Id.Length == 0) { unaddressable++; }
                        el = BuildToggle(leaf);
                        break;

                    // §1.2: a `dropdown` is a MENU BUTTON (`items` + a `behavior`),
                    // not a selector: it binds no value. The core sends its items
                    // as kinds with each toggle's check; with no `items` channel it
                    // stays a counted placeholder.
                    case "dropdown":
                        if (leaf.Items is null)
                        {
                            unmaterialized++;
                            el = Placeholder(leaf.Type);
                            break;
                        }
                        menus++;
                        if (leaf.Id.Length == 0) { unaddressable++; }
                        itemsRefused += leaf.Items.Refused;
                        el = BuildDropdown(leaf, icons);
                        break;

                    // W-b: the three list kinds, from the plan's `options` channel.
                    // ⛔ ONLY WHEN THE CORE SENT A LIST, or `combo_box`'s free entry
                    // (`grad_stop_location_combo` declares no options and is typed
                    // into). A `select` with no list is a counted placeholder: a
                    // ComboBox built from the resolved value alone draws, counts
                    // as built, and cannot select anything.
                    // ⛔ PLAIN LABELS, NOT `case "select" when …`: the kind-label
                    // gate reads a bare quoted case label, and a guarded one is invisible
                    // to it (measured: 8 labels read of 10).
                    case "select":
                    case "icon_select":
                    case "combo_box":
                        if (leaf.Options is null && leaf.Type != "combo_box")
                        {
                            unmaterialized++;
                            el = Placeholder(leaf.Type);
                            break;
                        }
                        inputs++;
                        if (leaf.Id.Length == 0) { unaddressable++; }
                        optionsRefused += leaf.Options?.Refused ?? 0;
                        el = BuildChoice(leaf);
                        break;

                    default:
                        unmaterialized++;
                        el = Placeholder(leaf.Type);
                        break;
                }
                el.Width = leaf.W;
                el.Height = leaf.H;
                Microsoft.UI.Xaml.Controls.Canvas.SetLeft(el, leaf.X);
                Microsoft.UI.Xaml.Controls.Canvas.SetTop(el, leaf.Y);
                host.Children.Add(el);
                _paneControls[leaf.Path] = el;
            }
            _scroll.Content = host;

            // `glyphs=` is a NEW field, and adding one is safe MEASURED rather than
            // assumed: `harness_common.ps1` reads this row BY NAME (`Get-SbField`)
            // and asserts only `leaves` and `controls`; nothing sums the category
            // counters, and the self-test's row is an INPUT to that parser.
            _w.Report($"PANEL BUILT panel={_paneDrawnPanel} build={_paneBuild} leaves={leaves.Count} texts={texts} "
                 + $"buttons={buttons} inputs={inputs} toggles={toggles} glyphs={glyphs} swatches={swatches} previews={previews} preview-empty={previewEmpty} "
                 + $"unmaterialized={unmaterialized} "
                 + $"unaddressable={unaddressable} icon-loads={_paneIconsPending} icon-text={_paneIconsText} "
                 + $"options-refused={optionsRefused} menus={menus} items-refused={itemsRefused}");
            if (_paneIconsPending == 0) { ReportPaneIcons(); }
        }

        /// <summary>A kind this shell does not draw: a muted `[type]`, COUNTED by the caller, never dropped.</summary>
        private TextBlock Placeholder(string type) => new()
        {
            Text = $"[{type}]",
            FontSize = 10,
            Foreground = _paneMutedBrush,
        };

        /// <summary>
        /// An `icon_button`: its tooltip is the core's `summary`, its click is the
        /// widget id, and its face is the named icon -- or, stop 4's fallback, the
        /// button's own label or summary text, COUNTED as `icon-text`. Never blank:
        /// the text face is shown first and replaced only by an icon that loaded.
        /// </summary>
        /// <summary>
        /// A `brush_preview`: no id, no bind, no click (the tile around it carries
        /// the click). Its face is the core's drawing, through the icon loader; a
        /// leaf the core sent no drawing for stays empty and is counted.
        /// </summary>
        private ContentControl BuildBrushPreview(PaneLeaf leaf, ref int empty)
        {
            var host = new ContentControl
            {
                HorizontalContentAlignment = HorizontalAlignment.Center,
                VerticalContentAlignment = VerticalAlignment.Center,
                IsHitTestVisible = false,
            };
            if (PanelWire.Preview(leaf.Shown("preview.viewbox"), leaf.Shown("preview.svg")) is { } p)
            {
                _paneIconsPending++;
                LoadIcon(host, p.Viewbox, p.Svg, leaf.W < leaf.H ? leaf.W : leaf.H, _paneBuild, preview: true);
            }
            else
            {
                empty++;
            }
            return host;
        }

        /// <summary>
        /// A `color_swatch`: a bordered square, filled on every draw by
        /// ApplyLeafValues from `bind.color`. A tap sends the leaf's `click` by its
        /// plan path, like every other control; a leaf with neither an id nor a
        /// plan path is counted unaddressable and sends nothing
        /// (<see cref="PanelWire.Addressable"/>). Double-click is not routed here.
        /// </summary>
        private Border BuildSwatch(PaneLeaf leaf)
        {
            var swatch = new Border { BorderBrush = _paneMutedBrush, BorderThickness = new Thickness(1) };
            var summary = leaf.Literal("summary");
            if (!string.IsNullOrEmpty(summary)) { ToolTipService.SetToolTip(swatch, summary); }
            var id = leaf.Id;
            var path = leaf.Path;
            if (PanelWire.Addressable(id, path)) { swatch.Tapped += (_, _) => OnPaneClick(id, path); }
            return swatch;
        }

        /// <summary>The fill for a swatch: its colour, or TRANSPARENT when the core
        /// sent none (an empty slot), never black -- see PanelWire.SwatchColor.</summary>
        private static Microsoft.UI.Xaml.Media.SolidColorBrush SwatchBrush(string? hex) =>
            PanelWire.SwatchColor(hex) is { } c
                ? new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(0xFF, c.R, c.G, c.B))
                : new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(0x00, 0x00, 0x00, 0x00));

        private Button BuildIconButton(PaneLeaf leaf, Dictionary<string, (string Viewbox, string Svg)> icons,
                                       bool sendsClick = true)
        {
            var label = leaf.Literal("label") ?? leaf.Literal("summary") ?? leaf.Id;
            var btn = new Button
            {
                Padding = new Thickness(0),
                MinWidth = 0,
                MinHeight = 0,
                HorizontalContentAlignment = HorizontalAlignment.Center,
                VerticalContentAlignment = VerticalAlignment.Center,
                Content = new TextBlock
                {
                    Text = label,
                    FontSize = 8,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                },
            };
            var summary = leaf.Literal("summary");
            if (!string.IsNullOrEmpty(summary)) { ToolTipService.SetToolTip(btn, summary); }

            var id = leaf.Id;
            var path = leaf.Path;
            if (sendsClick) { btn.Click += (_, _) => OnPaneClick(id, path); }

            var name = leaf.IconName;
            if (name is not null && icons.TryGetValue(name, out var def))
            {
                _paneIconsPending++;
                LoadIcon(btn, def.Viewbox, def.Svg, leaf.W < leaf.H ? leaf.W : leaf.H, _paneBuild);
            }
            else
            {
                // No icon named, or one the workspace does not define
                // (`icons_missing`): the text face stays, by design.
                _paneIconsText++;
            }
            return btn;
        }

        /// <summary>
        /// §1.2: a `dropdown`, drawn as its icon button with a menu flyout. The
        /// button sends NOTHING itself (a `click` on an item kind is refused
        /// `WrongEvent`); each menu row sends a pick of its own `value`, `toggle`
        /// or with Alt held `alt_toggle` (WIDGET_EVENTS.md, "Picking a dropdown
        /// item"). The rows are rebuilt at every open from the newest plan
        /// (`_paneItems`): a toggle row shows the core's check, and an unknown
        /// check (null) shows unchecked. An action row whose check the core knows
        /// (the Layers filter's "All", in force when nothing is checked) is drawn
        /// with a tick column too; one it does not know is a plain item. A row's own tick after a click is the
        /// control's guess and is discarded at the next open.
        /// </summary>
        private Button BuildDropdown(PaneLeaf leaf, Dictionary<string, (string Viewbox, string Svg)> icons)
        {
            var btn = BuildIconButton(leaf, icons, sendsClick: false);
            var (id, path) = (leaf.Id, leaf.Path);
            var menu = new MenuFlyout();
            menu.Opening += (_, _) =>
            {
                menu.Items.Clear();
                if (!_paneItems.TryGetValue(path, out var items)) { return; }
                foreach (var row in items.Rows)
                {
                    if (row.Separator)
                    {
                        menu.Items.Add(new MenuFlyoutSeparator());
                        continue;
                    }
                    MenuFlyoutItem item = row.Kind == "toggle" || row.Checked is not null
                        ? new ToggleMenuFlyoutItem { Text = row.Label, IsChecked = row.Checked == true }
                        : new MenuFlyoutItem { Text = row.Label };
                    var value = row.Value;
                    item.Click += (_, _) => SendPane(
                        id, PanelWire.PickEvent(IsKeyDown(Windows.System.VirtualKey.Menu)), value, path);
                    menu.Items.Add(item);
                }
            };
            btn.Flyout = menu;
            return btn;
        }

        /// <summary>
        /// A bare `icon`: decoration. The workspace's 15 `icon` nodes carry
        /// EXACTLY `{type, name, style}` -- no id, no bind, and NO TEXT KEY --
        /// measured, against `icon_button`'s 87 nodes carrying `summary` on 86.
        ///
        /// ⛔ SO ITS FAILURE FALLBACK IS A DECISION, NOT A PORT, AND IT IS RULED
        /// (jas, 2026-09-19, r.6e): fall back to the icon's own `name` as TEXT,
        /// counted as `icon-text`, exactly as `icon_button` already does.
        ///   (a) draw nothing        REFUSED -- this shell's README calls an empty
        ///                           pane over a healthy status line "the ambiguous
        ///                           failure this shell refuses"
        ///   (c) a "missing" glyph   REFUSED -- a new vocabulary for a case the
        ///                           shell already answers
        /// It is DELIBERATELY UGLY: a failed icon shows `char_size`. That is the
        /// point -- readable as a defect by anyone looking at the pane, where a
        /// blank space is not, and countable from the row without a screenshot.
        ///
        /// ⛔ NOT `unaddressable`: that counter is for widgets a CLICK could not
        /// name. An `icon` has no click and is never addressable BY DESIGN, so
        /// counting it there would be a standing false alarm.
        /// </summary>
        private ContentControl BuildIcon(PaneLeaf leaf, Dictionary<string, (string Viewbox, string Svg)> icons)
        {
            var name = leaf.IconName;
            var host = new ContentControl
            {
                HorizontalContentAlignment = HorizontalAlignment.Center,
                VerticalContentAlignment = VerticalAlignment.Center,
                Content = new TextBlock
                {
                    Text = name ?? string.Empty,
                    FontSize = 8,
                    Foreground = _paneMutedBrush,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                },
            };
            if (name is not null && icons.TryGetValue(name, out var def))
            {
                _paneIconsPending++;
                LoadIcon(host, def.Viewbox, def.Svg, leaf.W < leaf.H ? leaf.W : leaf.H, _paneBuild);
            }
            else
            {
                // Named nothing, or named an icon the workspace does not define
                // (`icons_missing`): the name stays on screen, by the ruling above.
                _paneIconsText++;
            }
            return host;
        }

        /// <summary>
        /// Draw a workspace icon through the platform's SVG reader.
        ///
        /// The document is the workspace's own `viewbox` and `svg`, wrapped, with
        /// `currentColor` given the pane's ink both ways -- as the root's `color`
        /// and by substitution, the Swift port's approach -- because whether this
        /// reader honours `currentColor` is read, not measured. A load that does
        /// not SUCCEED leaves the text face and is counted as failed.
        /// </summary>
        // ⛔ `ContentControl`, not `Button`: a bare `icon` widget needs this same
        // loader and is not a button. A Button IS a ContentControl, so the
        // icon_button call site is unchanged and this widens the type rather than
        // duplicating the loader -- the alternative was a second copy of the SVG
        // wrapping, the currentColor substitution and the staleness guard.
        private async void LoadIcon(ContentControl host, string viewbox, string svg, double box, int build, bool preview = false)
        {
            var ok = false;
            try
            {
                var markup = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"" + viewbox
                           + "\" color=\"" + PaneInk + "\">" + svg.Replace("currentColor", PaneInk)
                           + "</svg>";
                var bytes = System.Text.Encoding.UTF8.GetBytes(markup);
                using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
                using (var writer = new Windows.Storage.Streams.DataWriter(stream))
                {
                    writer.WriteBytes(bytes);
                    await writer.StoreAsync();
                    writer.DetachStream();
                }
                stream.Seek(0);
                var source = new Microsoft.UI.Xaml.Media.Imaging.SvgImageSource();
                var status = await source.SetSourceAsync(stream);
                ok = status == Microsoft.UI.Xaml.Media.Imaging.SvgImageSourceLoadStatus.Success;
                if (ok && build == _paneBuild)
                {
                    // The button's own padding is zero, so the icon is inset by
                    // 2 DIPs a side from the core's rect: a presentation choice of
                    // this shell, like the Swift port's icon size is of that one.
                    var side = box - 4;
                    if (side < 1) { side = box; }
                    host.Content = new Image
                    {
                        Source = source,
                        Width = side,
                        Height = side,
                        Stretch = Microsoft.UI.Xaml.Media.Stretch.Uniform,
                    };
                }
                else if (!ok)
                {
                    _w.Report($"PANEL ICON FAILED status={status} -- the text face stays");
                }
            }
            catch (Exception ex)
            {
                _w.Report($"PANEL ICON FAILED {ex.GetType().Name}: {ex.Message} -- the text face stays");
            }
            finally
            {
                // A load finishing for a build that has since been replaced says
                // nothing about the pane on screen, so it is not counted.
                if (build == _paneBuild)
                {
                    if (preview) { if (ok) { _panePreviewsSvg++; } else { _panePreviewsFailed++; } }
                    else if (ok) { _paneIconsSvg++; } else { _paneIconsFailed++; }
                    _paneIconsPending--;
                    if (_paneIconsPending == 0) { ReportPaneIcons(); }
                }
            }
        }

        /// <summary>Stop 4's receipt: how each icon_button's face was drawn, once every load settled.</summary>
        private void ReportPaneIcons() =>
            _w.Report($"PANEL ICONS panel={_paneDrawnPanel} build={_paneBuild} svg={_paneIconsSvg} "
                 + $"text={_paneIconsText} failed={_paneIconsFailed} "
                 + $"icon={(_paneIconsSvg > 0 && _paneIconsText + _paneIconsFailed == 0 ? "SVG" : "TEXT")} "
                 + $"preview-svg={_panePreviewsSvg} preview-failed={_panePreviewsFailed}");

        /// <summary>
        /// Show what the core says about one control. Returns `(disabled, checked,
        /// hidden, editing)` as 0/1 for the row. `editing` is a focused number box
        /// whose text a person has changed and not committed: its text is left
        /// alone, and the core's value is still recorded as the one it shows.
        ///
        /// ⛔ THESE ARE READINGS, NOT EVALUATIONS. Each value is the canonical
        /// string the core resolved; `"true"` is the only true. An unaddressable
        /// button (no id) is never enabled, since a click could not name it.
        /// </summary>
        private (int Disabled, int Checked, int Hidden, int Editing) ApplyLeafValues(FrameworkElement el, PaneLeaf leaf)
        {
            var shown = (leaf.Value("bind.visible") ?? leaf.Value("visible")) != "false";
            el.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
            var off = leaf.Value("bind.disabled") == "true";
            var on = leaf.Value("bind.checked") == "true";
            var typing = false;

            switch (el)
            {
                case Border swatch when leaf.Type == "color_swatch":
                    swatch.Background = SwatchBrush(leaf.Value("bind.color"));
                    break;

                case TextBlock tb when leaf.Type == "text":
                    tb.Text = leaf.Value("content") ?? leaf.Literal("content") ?? "";
                    break;

                case Button btn:
                    off = off || leaf.Id.Length == 0;
                    btn.IsEnabled = !off;
                    if (on)
                    {
                        btn.Background = _paneCheckedFill;
                        btn.BorderBrush = _paneCheckedEdge;
                        btn.BorderThickness = new Thickness(1);
                    }
                    else
                    {
                        btn.ClearValue(Control.BackgroundProperty);
                        btn.ClearValue(Control.BorderBrushProperty);
                        btn.ClearValue(Control.BorderThicknessProperty);
                    }
                    break;

                case TextBox box:
                    // ⛔ THE COMMENT HERE USED TO READ "the value ALONE, as both
                    // active ports show it ... and the core refuses `5 pt` for a
                    // number". BOTH CLAUSES ARE FALSE FOR `length_input` and both
                    // are quoted rather than deleted, because they were TRUE of
                    // `number_input` -- the only kind this arm had when they were
                    // written -- and a reader who meets only the new rule will
                    // restore the tidier one.
                    //   the ports show   `length::format(..)` = "12 pt", not "12"
                    //   the core ACCEPTS a unit suffix on this kind, by the
                    //                    widget's own description
                    // So the shown string is the core's `display` when it sent one
                    // and the resolved value otherwise. NULL AND EMPTY DIFFER:
                    // `PanelWire.DisplayText` holds that rule and is driven on the
                    // desktop-less runner.
                    var value = PanelWire.DisplayText(leaf.Shown("bind.value"), leaf.Value("bind.value"));
                    typing = box.FocusState != FocusState.Unfocused
                             && !string.Equals(box.Text, box.Tag as string ?? "", StringComparison.Ordinal);
                    // The Tag is the SHOWN text, not the raw value: `CommitOnBlur`
                    // compares against it, so a Tag holding "12" under a box
                    // showing "12 pt" would commit on every focus loss.
                    box.Tag = value;
                    if (!typing) { box.Text = value; }
                    off = off || leaf.Id.Length == 0;
                    box.IsEnabled = !off;
                    break;

                // W-b: the CORE says which item is the bound value (`selected`);
                // nothing here compares values to find it. The state records what
                // the core showed, so the selection event this raises is
                // recognised by `PanelWire.ChoiceCommit` and sends nothing.
                case ComboBox combo:
                {
                    var index = leaf.Options?.SelectedIndex ?? -1;
                    var items = leaf.Options?.Items;
                    var shownValue = index >= 0 && items is not null
                        ? items[index].Value
                        : PanelWire.DisplayText(leaf.Shown("bind.value"), leaf.Value("bind.value"));
                    var shownText = index >= 0 && items is not null ? PanelWire.ChoiceText(items[index]) : shownValue;
                    // An editable combo a person is TYPING into keeps its text: focused
                    // AND holding text other than what the core last showed. Focus
                    // alone is not typing -- a pick leaves the combo focused, and a
                    // focus-only rule would then never show the core's re-read.
                    var before = combo.Tag as ChoiceState;
                    typing = combo.IsEditable && combo.FocusState != FocusState.Unfocused
                             && !string.Equals(combo.Text, before?.Text ?? "", StringComparison.Ordinal);
                    combo.Tag = new ChoiceState(shownValue, index, shownText);
                    if (!typing)
                    {
                        combo.SelectedIndex = index;
                        // A value no item carries (a free entry) is shown as text.
                        if (combo.IsEditable && index < 0) { combo.Text = shownText; }
                    }
                    off = off || leaf.Id.Length == 0;
                    combo.IsEnabled = !off;
                    break;
                }

                case CheckBox toggle:
                    off = off || leaf.Id.Length == 0;
                    toggle.Tag = on;
                    toggle.IsChecked = on;
                    toggle.IsEnabled = !off;
                    break;
            }
            return (off ? 1 : 0, on ? 1 : 0, shown ? 0 : 1, typing ? 1 : 0);
        }

        /// <summary>
        /// A pane control was clicked: send its widget id and the modifier keys.
        /// What the click does is the core's (`jas_panel_behavior`); the row it
        /// writes is the receipt.
        /// </summary>
        private void OnPaneClick(string widget, string? path = null) => SendPane(widget, "click", null, path);

        /// <summary>
        /// Send one act on a pane control to the core, addressed to the panel the
        /// control was built from. A press is `click` with no value; a commit is
        /// `commit` with the control's text (<see cref="PanelWire.EventJson"/>).
        /// </summary>
        private void SendPane(string widget, string eventName, string? value, string? path = null)
        {
            _w._canvas.PanelClick(new PanelClickCmd
            {
                PanelId = _paneDrawnPanel,
                Widget = widget,
                Path = path,
                Via = "hand",
                Event = eventName,
                Value = value,
                Alt = IsKeyDown(Windows.System.VirtualKey.Menu),
                Shift = IsKeyDown(Windows.System.VirtualKey.Shift),
                Ctrl = IsKeyDown(Windows.System.VirtualKey.Control),
                Meta = IsKeyDown(Windows.System.VirtualKey.LeftWindows)
                       || IsKeyDown(Windows.System.VirtualKey.RightWindows),
            });
        }

        // =======================================================================
        // W2b-2 — THE SELECTOR, AND THE CONTROLS A PERSON CAN CHANGE
        //
        // ⛔ STILL NOT ONE VALUE IS DECIDED HERE. A number box sends the TEXT it
        // holds and a toggle sends a press; the core parses, writes and runs the
        // behaviors (`WIDGET_EVENTS.md`), and the plan it publishes afterwards is
        // what the controls show. So each control is put back to the core's last
        // value AS IT SENDS: a refused commit then leaves the core's value on
        // screen, and an accepted one is shown by the re-read, never by the
        // control's own guess.
        // =======================================================================

        /// <summary>
        /// A `number_input`. Enter commits; losing focus commits only a changed
        /// text (<see cref="PanelWire.CommitOnBlur"/>). A declared unit is the
        /// tooltip, since the box holds exactly what a commit sends. A box with no
        /// id cannot be addressed, so it is read-only.
        /// </summary>
        private TextBox BuildNumberInput(PaneLeaf leaf)
        {
            var box = new TextBox
            {
                FontSize = 12,
                MinWidth = 0,
                MinHeight = 0,
                Padding = new Thickness(4, 0, 4, 0),
                IsSpellCheckEnabled = false,
                IsReadOnly = leaf.Id.Length == 0,
            };
            var unit = leaf.Literal("unit") ?? leaf.Literal("suffix");
            if (!string.IsNullOrEmpty(unit)) { ToolTipService.SetToolTip(box, unit); }
            if (leaf.Id.Length == 0) { return box; }

            var id = leaf.Id;
            box.KeyDown += (_, e) =>
            {
                if (e.Key != Windows.System.VirtualKey.Enter) { return; }
                e.Handled = true;
                CommitBox(box, id, leaf.Path);
            };
            box.LostFocus += (_, _) =>
            {
                if (PanelWire.CommitOnBlur(box.Text, box.Tag as string ?? "")) { CommitBox(box, id, leaf.Path); }
            };
            return box;
        }

        private void CommitBox(TextBox box, string widget, string? path = null)
        {
            var text = box.Text;
            box.Text = box.Tag as string ?? "";
            SendPane(widget, "commit", text, path);
        }

        /// <summary>
        /// A `toggle`: a check box labelled with the plan's `label`. A press is a
        /// `click`; what it writes is the core's, which is why the box is put back
        /// to the core's value before the press is sent.
        /// </summary>
        private CheckBox BuildToggle(PaneLeaf leaf)
        {
            var box = new CheckBox
            {
                Content = leaf.Literal("label") ?? leaf.Id,
                FontSize = 12,
                MinWidth = 0,
                MinHeight = 0,
                IsThreeState = false,
            };
            var id = leaf.Id;
            box.Click += (_, _) =>
            {
                box.IsChecked = box.Tag is true;
                SendPane(id, "click", null, leaf.Path);
            };
            return box;
        }

        /// <summary>
        /// What a list control last showed: the core's value, its item index (-1:
        /// none), and the text on the control's face for it.
        /// </summary>
        private sealed record ChoiceState(string Shown, int Index, string Text);

        /// <summary>
        /// W-b: a `select`, `combo_box` or `icon_select`, as one ComboBox over the
        /// plan's `options` VALUES (dividers are never items: see
        /// `PaneOptions.Items`). A `combo_box` is editable, since its contract
        /// accepts free text; an `icon_select` item shows its glyph beside its
        /// label (`PanelWire.ChoiceText`).
        ///
        /// ⛔ A PICK SENDS THE ROW'S `value`, NEVER ITS LABEL, as a `commit` -- the
        /// INPUT_KINDS contract a number box already uses, and the text the core's
        /// commit parse matches. Then the control is put back to the core's value
        /// AS IT SENDS, exactly as a number box is, so a refused pick leaves the
        /// core's value on screen and an accepted one is shown by the re-read.
        /// </summary>
        private ComboBox BuildChoice(PaneLeaf leaf)
        {
            var items = leaf.Options?.Items ?? new List<PaneOption>();
            var combo = new ComboBox
            {
                FontSize = 12,
                MinWidth = 0,
                MinHeight = 0,
                Padding = new Thickness(4, 0, 4, 0),
                IsEditable = leaf.Type == "combo_box",
            };
            foreach (var row in items) { combo.Items.Add(PanelWire.ChoiceText(row)); }
            var summary = leaf.Literal("summary");
            if (!string.IsNullOrEmpty(summary)) { ToolTipService.SetToolTip(combo, summary); }
            if (leaf.Id.Length == 0) { return combo; }

            var id = leaf.Id;
            combo.SelectionChanged += (_, _) =>
            {
                var state = combo.Tag as ChoiceState;
                var send = PanelWire.ChoiceCommit(combo.SelectedIndex, items, state?.Shown);
                if (send is null) { return; }
                // Put back first: this raises SelectionChanged again, at the core's
                // own index, and `ChoiceCommit` sends nothing for that.
                combo.SelectedIndex = state?.Index ?? -1;
                if (combo.IsEditable && (state?.Index ?? -1) < 0) { combo.Text = state?.Text ?? ""; }
                SendPane(id, "commit", send, leaf.Path);
            };
            if (combo.IsEditable)
            {
                // Typed text crosses as TEXT; the core parses it by the kind. Text
                // that names an item is left to SelectionChanged above.
                combo.TextSubmitted += (_, e) =>
                {
                    var state = combo.Tag as ChoiceState;
                    if (items.Any(r => string.Equals(PanelWire.ChoiceText(r), e.Text, StringComparison.Ordinal))) { return; }
                    e.Handled = true;
                    if (PanelWire.CommitOnBlur(e.Text, state?.Shown ?? "")) { SendPane(id, "commit", e.Text, leaf.Path); }
                    combo.Text = state?.Text ?? "";
                };
            }
            return combo;
        }
    }
}
