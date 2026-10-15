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
                          bool topAligned = false, double pad = PanePad, bool dialog = false)
        {
            _dialog = dialog;
            _topAligned = topAligned;
            _pad = pad;
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

        /// <summary>
        /// S2: this view draws the OPEN DIALOG's plan. Its acts go to
        /// `jas_dialog_event` instead of a panel, and it writes no `SB_PLAN_OUT`
        /// (that file is the dock panel's, which the harness compares).
        /// </summary>
        private readonly bool _dialog;

        /// <summary>The margin round the plan's own coordinates: the panes' 4, the canvas strip's 0.</summary>
        private readonly double _pad;

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
            Dictionary<string, string> Display, PaneOptions? Options, PaneItems? Items,
            SliderTrack? Track = null)
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
        // An unselected option cell's fill: CLEAR, never null. A null
        // background is not hit-testable, so a press would fall through to
        // the pane beneath and send nothing (measured live on #434's grid).
        private readonly Microsoft.UI.Xaml.Media.SolidColorBrush _paneClearFill =
            new(Microsoft.UI.Colors.Transparent);

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
                    PanelWire.ReadItems(e.TryGetProperty("items", out var its) ? its.GetRawText() : null),
                    // Fork A: a slider's track from the `numbers` channel; null
                    // (no channel, an older core) leaves it a counted placeholder.
                    PanelWire.ReadSliderTrack(e.TryGetProperty("numbers", out var nums) ? nums.GetRawText() : null)));
            }
            var icons = new Dictionary<string, (string Viewbox, string Svg)>();
            foreach (var ic in root.GetProperty("icons").EnumerateObject())
            {
                icons[ic.Name] = (ic.Value.GetProperty("viewbox").GetString() ?? "",
                                  ic.Value.GetProperty("svg").GetString() ?? "");
            }
            var height = root.GetProperty("height").GetInt64();
            // §255: chrome rows carrying `bind.active` (the canvas pane's document
            // tabs) are drawn as boxes behind the leaves. Which one is active is a
            // build input, so a moved active tab rebuilds the pane.
            var boxes = PanelWire.ActiveBoxes(snap.PlanJson) ?? new List<PanelWire.ActiveBox>();

            // The panel id is part of the signature: two panels with the same
            // leaves would otherwise keep controls that address the wrong panel.
            var signature = snap.PanelId + "\n" + string.Join("\n", leaves.Select(l =>
                $"{l.Path}|{l.Type}|{l.Id}|{l.X},{l.Y},{l.W},{l.H}|{l.IconName}|"
                + string.Join(";", l.Static.OrderBy(kv => kv.Key, StringComparer.Ordinal)
                                           .Select(kv => $"{kv.Key}={kv.Value}"))
                // W-b: a list control's ITEMS are built once, so a changed list
                // must rebuild. The selection is not in it: it moves every tick
                // and is applied in place.
                + "|" + (l.Options?.Signature ?? "")
                + "|" + (l.Track?.ToString() ?? "")))
                + "\n" + string.Join("\n", boxes);
            var rebuilt = signature != _paneSignature;
            _paneDrawnPanel = snap.PanelId;
            if (rebuilt) { BuildPane(leaves, icons, height, boxes); }
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

            // #323: the plan bytes this tree was DRAWN from, so a UIA read of the
            // same window is compared against the same selection (the harness's
            // `Compare-SbRenderedTree`). Overwritten at every draw: the newest wins.
            if (!_dialog && PlanOutPath is { } planOut)
            {
                try
                {
                    System.IO.File.WriteAllText(planOut, snap.PlanJson);
                    _w.Report($"PLAN OUT panel={snap.PanelId} seq={snap.Seq} bytes={snap.PlanJson.Length}");
                }
                catch (Exception ex)
                {
                    _w.Report($"RUSTFAIL PLAN OUT panel={snap.PanelId} seq={snap.Seq} -- {ex.GetType().Name}: {ex.Message}");
                }
            }
        }

        /// <summary>`SB_PLAN_OUT`, resolved beside the exe when relative; null when unset.</summary>
        private static readonly string? PlanOutPath =
            Environment.GetEnvironmentVariable("SB_PLAN_OUT") is { Length: > 0 } v
                ? System.IO.Path.Combine(AppContext.BaseDirectory, v)
                : null;

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
        private void BuildPane(List<PaneLeaf> leaves, Dictionary<string, (string Viewbox, string Svg)> icons, long height,
                               List<PanelWire.ActiveBox> boxes)
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
                Margin = new Thickness(_pad),
            };
            // §255: a row's box goes in first, so its leaves draw over it. The
            // active one takes the checked look a toggle has; another is outlined.
            foreach (var box in boxes)
            {
                var face = new Border
                {
                    Width = box.W,
                    Height = box.H,
                    Background = box.Active ? _paneCheckedFill : null,
                    BorderBrush = box.Active ? _paneCheckedEdge : _paneMutedBrush,
                    BorderThickness = box.Active ? new Thickness(1, 1, 1, 0) : new Thickness(0, 0, 1, 0),
                    IsHitTestVisible = false,
                };
                Microsoft.UI.Xaml.Controls.Canvas.SetLeft(face, box.X);
                Microsoft.UI.Xaml.Controls.Canvas.SetTop(face, box.Y);
                host.Children.Add(face);
            }
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
            var spacers = 0;
            var separators = 0;
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
                        if (!PanelWire.Clickable(leaf.Type, leaf.Id, leaf.Path)) { unaddressable++; }
                        el = BuildIconButton(leaf, icons);
                        break;

                    // S1 (the dialog door, design §3): a text `button`. Every
                    // dialog's OK/Cancel/Save/Discard is one, and two panels
                    // (opacity, concepts) use it. Its event is `click`; a
                    // dialog's buttons carry no id, so the plan path is the
                    // address (#420), and the count reads the same predicate.
                    case "button":
                        buttons++;
                        if (!PanelWire.Clickable(leaf.Type, leaf.Id, leaf.Path)) { unaddressable++; }
                        el = BuildTextButton(leaf);
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
                    // A `text_input` is the same box: the core's `parse_commit`
                    // keeps its text verbatim (Color's hex, Layers' search, the
                    // artboard rename), and it was a `[text_input]` placeholder
                    // until 2026-10-12 (measured live: `cp_hex` a TextBlock).
                    case "number_input":
                    case "length_input":
                    case "text_input":
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

                    // FORK A (#384): a `slider` is an input kind. The track is the
                    // plan's `numbers`; with none it stays a counted placeholder,
                    // never a guessed 0..100. A RELEASE commits the dragged number
                    // as text; the engine parses, clamps and snaps it.
                    case "slider":
                        if (leaf.Track is null)
                        {
                            unmaterialized++;
                            el = Placeholder(leaf.Type);
                            break;
                        }
                        inputs++;
                        if (leaf.Id.Length == 0) { unaddressable++; }
                        el = BuildSlider(leaf, leaf.Track);
                        break;

                    // FORK B2 (#394): the colour bar is an input kind. Held, it sends
                    // `change` with the POINT under the pointer; the release sends
                    // `commit` with the release point. The engine maps the point to a
                    // colour (`color_util::color_bar_rgb`) and clamps it; the shell
                    // does neither, so it draws no picture of its own.
                    case "color_bar":
                        inputs++;
                        if (leaf.Id.Length == 0) { unaddressable++; }
                        el = BuildColorBar(leaf);
                        break;

                    // S3 (jas §282, #429): a `radio` is a check kind -- its own
                    // `bind.checked`, a `click` that runs its `on_check`. The
                    // exclusivity is the YAML's (each radio binds its own
                    // condition), so no two shell radios share a group.
                    case "radio":
                        toggles++;
                        if (leaf.Id.Length == 0) { unaddressable++; }
                        el = BuildRadio(leaf);
                        break;

                    // A `radio_group` is an option kind: one radio per planned
                    // option row, checked by the row's `selected`, a press
                    // sending `toggle` with the option's id. With no rows it is
                    // a counted placeholder, as a `select` with no list is.
                    case "radio_group":
                        if (leaf.Options is not { Items.Count: > 0 })
                        {
                            unmaterialized++;
                            el = Placeholder(leaf.Type);
                            break;
                        }
                        inputs++;
                        if (leaf.Id.Length == 0) { unaddressable++; }
                        optionsRefused += leaf.Options.Refused;
                        el = BuildRadioGroup(leaf, leaf.Options);
                        break;

                    // #431: an `icon_button_group` is an input kind: one icon
                    // button per option row, the `selected` one filled, a press
                    // sending `commit` with the option's value. With no rows it
                    // is a counted placeholder, as a `select` with no list is.
                    case "icon_button_group":
                        if (leaf.Options is not { Items.Count: > 0 })
                        {
                            unmaterialized++;
                            el = Placeholder(leaf.Type);
                            break;
                        }
                        inputs++;
                        if (leaf.Id.Length == 0) { unaddressable++; }
                        optionsRefused += leaf.Options.Refused;
                        el = BuildIconGroup(leaf, leaf.Options, icons);
                        break;

                    // #434: a `reference_point_widget` is an input kind whose
                    // rows are its kind's anchors; a square grid of cells, the
                    // `selected` one filled, a press sending `commit` with the
                    // anchor. A row count that is not a square is a placeholder.
                    case "reference_point_widget":
                        if (leaf.Options is not { Items.Count: > 0 } || PanelWire.GridColumns(leaf.Options.Items.Count) is not { } columns)
                        {
                            unmaterialized++;
                            el = Placeholder(leaf.Type);
                            break;
                        }
                        inputs++;
                        if (leaf.Id.Length == 0) { unaddressable++; }
                        optionsRefused += leaf.Options.Refused;
                        el = BuildAnchorGrid(leaf, leaf.Options, columns);
                        break;

                    // S3 (jas §279): a `separator` is a 1-DIP rule across the
                    // middle of its rect, in the direction the rect runs. No
                    // event, no value; an empty rect is counted and drawn empty.
                    case "separator":
                        separators++;
                        el = BuildSeparator(leaf);
                        break;

                    // A `spacer` is layout-only flex: the plan already gave it
                    // its room, and it draws nothing in any port. Counted, never
                    // drawn as a `[spacer]` placeholder.
                    case "spacer":
                        spacers++;
                        el = new Border();
                        break;

                    default:
                        unmaterialized++;
                        el = Placeholder(leaf.Type);
                        break;
                }
                // The RENDERED tree's identity (docs/TESTING.md section 5 item 2): the
                // widget id, exactly the string the Mac app gives the same widget
                // (`.accessibilityIdentifier(element["id"])`); none when it has none.
                if (leaf.Id.Length > 0)
                {
                    Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(el, leaf.Id);
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
                 + $"buttons={buttons} inputs={inputs} toggles={toggles} glyphs={glyphs} swatches={swatches} spacers={spacers} separators={separators} previews={previews} preview-empty={previewEmpty} "
                 + $"unmaterialized={unmaterialized} boxes={boxes.Count} boxes-active={boxes.Count(b => b.Active)} "
                 + $"unaddressable={unaddressable} icon-loads={_paneIconsPending} icon-text={_paneIconsText} "
                 + $"options-refused={optionsRefused} menus={menus} items-refused={itemsRefused}");
            if (_paneIconsPending == 0) { ReportPaneIcons(); }
        }

        /// <summary>
        /// S3: a `radio`. A press puts the face back to the core's last answer
        /// and sends `click` (<see cref="PanelWire.RadioEvent"/>); the next plan
        /// shows what the core decided. ⛔ ITS OWN GroupName: WinUI groups
        /// radios that share a parent and unchecks the others itself, which
        /// would be the shell deciding the YAML's exclusivity.
        /// </summary>
        private RadioButton BuildRadio(PaneLeaf leaf)
        {
            var radio = new RadioButton
            {
                Content = leaf.Literal("label") ?? leaf.Id,
                FontSize = 12,
                MinWidth = 0,
                MinHeight = 0,
                GroupName = "radio:" + leaf.Path,
            };
            var (id, path) = (leaf.Id, leaf.Path);
            radio.Click += (_, _) =>
            {
                radio.IsChecked = radio.Tag is true;
                var (ev, value) = PanelWire.RadioEvent("radio", "");
                SendPane(id, ev, value, path);
            };
            return radio;
        }

        /// <summary>S3: a `radio_group`'s option radios, side by side, each in
        /// its own GroupName for the reason <see cref="BuildRadio"/> gives.</summary>
        private RadioGroupRow BuildRadioGroup(PaneLeaf leaf, PaneOptions options)
        {
            var row = new RadioGroupRow { Orientation = Orientation.Horizontal, Spacing = 6 };
            var (id, path) = (leaf.Id, leaf.Path);
            foreach (var option in options.Items)
            {
                var radio = new RadioButton
                {
                    Content = PanelWire.RadioFace(option),
                    FontSize = 12,
                    MinWidth = 0,
                    MinHeight = 0,
                    GroupName = "radio:" + path + ":" + option.Value,
                    Tag = option.Selected,
                };
                var value = option.Value;
                radio.Click += (_, _) =>
                {
                    radio.IsChecked = radio.Tag is true;
                    var (ev, v) = PanelWire.RadioEvent("radio_group", value);
                    SendPane(id, ev, v, path);
                };
                row.Children.Add(radio);
            }
            return row;
        }

        /// <summary>
        /// #431: an `icon_button_group`'s buttons, side by side and square
        /// (<see cref="PanelWire.GroupCellSide"/>). Each face is its row's icon
        /// from the plan's `icons` map, or the row's label when it names none
        /// the map holds (counted as `icon-text`). A press sends `commit` with
        /// the row's value; the next plan's `selected` fills the chosen button.
        /// </summary>
        private IconGroupRow BuildIconGroup(PaneLeaf leaf, PaneOptions options,
                                            Dictionary<string, (string Viewbox, string Svg)> icons)
        {
            var row = new IconGroupRow { Orientation = Orientation.Horizontal };
            var side = PanelWire.GroupCellSide(leaf.W, leaf.H, options.Items.Count);
            var (id, path) = (leaf.Id, leaf.Path);
            foreach (var option in options.Items)
            {
                var btn = new Button
                {
                    Width = side,
                    Height = side,
                    MinWidth = 0,
                    MinHeight = 0,
                    Padding = new Thickness(0),
                    BorderThickness = new Thickness(1),
                    BorderBrush = _paneCheckedEdge,
                    Background = option.Selected ? _paneCheckedFill : _paneClearFill,
                    HorizontalContentAlignment = HorizontalAlignment.Center,
                    VerticalContentAlignment = VerticalAlignment.Center,
                    Content = new TextBlock { Text = option.Label, FontSize = 8, TextTrimming = TextTrimming.CharacterEllipsis },
                };
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(btn, option.Label);
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetItemStatus(btn, option.Selected ? "selected" : "");
                ToolTipService.SetToolTip(btn, option.Label);
                var value = option.Value;
                btn.Click += (_, _) => SendPane(id, "commit", value, path);
                if (option.Icon is { } name && icons.TryGetValue(name, out var def))
                {
                    _paneIconsPending++;
                    LoadIcon(btn, def.Viewbox, def.Svg, side, _paneBuild);
                }
                else
                {
                    _paneIconsText++;
                }
                row.Children.Add(btn);
            }
            return row;
        }

        /// <summary>
        /// #434: a `reference_point_widget`'s cells, one per anchor row, placed
        /// row by row (<see cref="PanelWire.GridCell"/>). Each cell is named by
        /// its row's label; a press sends `commit` with the row's value, and the
        /// next plan's `selected` fills the cell the core chose and gives it the
        /// automation status `selected`, so a screen reader hears the choice.
        /// </summary>
        private AnchorGrid BuildAnchorGrid(PaneLeaf leaf, PaneOptions options, int columns)
        {
            var grid = new AnchorGrid();
            for (var i = 0; i < columns; i++)
            {
                grid.RowDefinitions.Add(new RowDefinition());
                grid.ColumnDefinitions.Add(new ColumnDefinition());
            }
            var (id, path) = (leaf.Id, leaf.Path);
            for (var i = 0; i < options.Items.Count; i++)
            {
                var option = options.Items[i];
                var cell = new Button
                {
                    MinWidth = 0,
                    MinHeight = 0,
                    Padding = new Thickness(0),
                    Margin = new Thickness(1),
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    VerticalAlignment = VerticalAlignment.Stretch,
                    BorderThickness = new Thickness(1),
                    BorderBrush = _paneCheckedEdge,
                    Background = option.Selected ? _paneCheckedFill : _paneClearFill,
                };
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(cell, option.Label);
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetItemStatus(cell, option.Selected ? "selected" : "");
                var (row, column) = PanelWire.GridCell(i, columns);
                Grid.SetRow(cell, row);
                Grid.SetColumn(cell, column);
                var value = option.Value;
                cell.Click += (_, _) => SendPane(id, "commit", value, path);
                grid.Children.Add(cell);
            }
            return grid;
        }

        /// <summary>S3: a `separator`'s rule, centred in its rect (<see cref="PanelWire.SeparatorRule"/>).</summary>
        private Grid BuildSeparator(PaneLeaf leaf)
        {
            var host = new Grid { IsHitTestVisible = false };
            var rule = PanelWire.SeparatorRule(leaf.W, leaf.H);
            if (rule is null) { return host; }
            host.Children.Add(new Border
            {
                Background = _paneMutedBrush,
                Width = rule == "horizontal" ? double.NaN : 1,
                Height = rule == "horizontal" ? 1 : double.NaN,
                HorizontalAlignment = rule == "horizontal" ? HorizontalAlignment.Stretch : HorizontalAlignment.Center,
                VerticalAlignment = rule == "horizontal" ? VerticalAlignment.Center : VerticalAlignment.Stretch,
            });
            return host;
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
        private SwatchTile BuildSwatch(PaneLeaf leaf)
        {
            var swatch = new SwatchTile { BorderBrush = _paneMutedBrush, BorderThickness = new Thickness(1) };
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

        /// <summary>
        /// S1: a text `button`. Its face is <see cref="PanelWire.ButtonLabel"/>,
        /// re-read at every draw (a label can be a template the core resolves),
        /// and a press sends `click` by id or plan path. What the press DOES is
        /// the node's action or behaviors, run by the core.
        /// </summary>
        private Button BuildTextButton(PaneLeaf leaf)
        {
            var btn = new Button
            {
                Padding = new Thickness(6, 0, 6, 0),
                MinWidth = 0,
                MinHeight = 0,
                HorizontalContentAlignment = HorizontalAlignment.Center,
                VerticalContentAlignment = VerticalAlignment.Center,
                Content = new TextBlock
                {
                    FontSize = 12,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                },
            };
            var summary = leaf.Literal("summary");
            if (!string.IsNullOrEmpty(summary)) { ToolTipService.SetToolTip(btn, summary); }
            var (id, path) = (leaf.Id, leaf.Path);
            if (PanelWire.Clickable(leaf.Type, id, path)) { btn.Click += (_, _) => OnPaneClick(id, path); }
            return btn;
        }

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
            if (!string.IsNullOrEmpty(summary))
            {
                ToolTipService.SetToolTip(btn, summary);
                // Its face is a picture, so without this an assistive reader
                // (and the harness's UIA hand) finds a button with no name.
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(btn, summary);
            }

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
        /// button is never enabled, since a click could not name it: no id, or
        /// for a `button` neither id nor plan path (<see cref="PanelWire.Clickable"/>).
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
                case SwatchTile swatch when leaf.Type == "color_swatch":
                    swatch.Background = SwatchBrush(leaf.Value("bind.color"));
                    break;

                case TextBlock tb when leaf.Type == "text":
                    tb.Text = leaf.Value("content") ?? leaf.Literal("content") ?? "";
                    break;

                case Button btn:
                    off = off || !PanelWire.Clickable(leaf.Type, leaf.Id, leaf.Path);
                    if (leaf.Type == "button" && btn.Content is TextBlock face)
                    {
                        face.Text = PanelWire.ButtonLabel(
                            leaf.Value("label"), leaf.Literal("label"), leaf.Literal("summary"), leaf.Id);
                    }
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

                // Fork A: the thumb sits where the CORE's value is, except while a
                // person holds it -- a held thumb is theirs until the release
                // commits, and the re-read after that commit places it.
                case Slider slider when slider.Tag is SliderState st:
                    st.Shown = leaf.Value("bind.value");
                    typing = st.Held;
                    if (!st.Held && PanelWire.SliderPosition(st.Shown) is { } at) { slider.Value = at; }
                    off = off || leaf.Id.Length == 0;
                    slider.IsEnabled = !off;
                    break;

                // Fork B2: a disabled bar (the active colour is none) takes no
                // pointer; a held one is the person's until the release.
                case ColorBarSurface bar when bar.Tag is ColorBarState cb:
                    typing = cb.Held;
                    off = off || leaf.Id.Length == 0;
                    bar.IsHitTestVisible = !off;
                    bar.Opacity = off ? 0.4 : 1.0;
                    break;

                case RadioButton radio when leaf.Type == "radio":
                    off = off || leaf.Id.Length == 0;
                    radio.Tag = on;
                    radio.IsChecked = on;
                    radio.IsEnabled = !off;
                    break;

                case IconGroupRow iconGroup:
                {
                    off = off || leaf.Id.Length == 0;
                    var items = leaf.Options?.Items;
                    for (var i = 0; i < iconGroup.Children.Count; i++)
                    {
                        if (iconGroup.Children[i] is not Button btn) { continue; }
                        var sel = items is not null && i < items.Count && items[i].Selected;
                        btn.Background = sel ? _paneCheckedFill : _paneClearFill;
                        Microsoft.UI.Xaml.Automation.AutomationProperties.SetItemStatus(btn, sel ? "selected" : "");
                        btn.IsEnabled = !off;
                        on |= sel;
                    }
                    break;
                }

                case AnchorGrid anchors:
                {
                    off = off || leaf.Id.Length == 0;
                    var items = leaf.Options?.Items;
                    for (var i = 0; i < anchors.Children.Count; i++)
                    {
                        if (anchors.Children[i] is not Button cell) { continue; }
                        var sel = items is not null && i < items.Count && items[i].Selected;
                        cell.Background = sel ? _paneCheckedFill : _paneClearFill;
                        Microsoft.UI.Xaml.Automation.AutomationProperties.SetItemStatus(cell, sel ? "selected" : "");
                        cell.IsEnabled = !off;
                        on |= sel;
                    }
                    break;
                }

                case RadioGroupRow group:
                {
                    off = off || leaf.Id.Length == 0;
                    var items = leaf.Options?.Items;
                    for (var i = 0; i < group.Children.Count; i++)
                    {
                        if (group.Children[i] is not RadioButton r) { continue; }
                        var sel = items is not null && i < items.Count && items[i].Selected;
                        r.Tag = sel;
                        r.IsChecked = sel;
                        r.IsEnabled = !off;
                        on |= sel;
                    }
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
            var act = new PanelClickCmd
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
            };
            if (_dialog) { _w._canvas.DialogEvent(act); }
            else { _w._canvas.PanelClick(act); }
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
            // The spec's literal hint for an empty box (`cp_hex`'s "000000",
            // Layers' "Search All"); the plan sends it in `static`.
            if (leaf.Literal("placeholder") is { Length: > 0 } hint) { box.PlaceholderText = hint; }
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
        /// Fork A: what a slider last showed (the core's value text) and whether a
        /// person is holding it.
        /// </summary>
        private sealed class SliderState
        {
            internal string? Shown;
            internal bool Held;
        }

        /// <summary>
        /// FORK A (#384): a `slider`, drawn over the plan's track. A pointer
        /// RELEASE (or a key that moved it) commits the dragged number as text
        /// through the behaviour door, as the hex box does; nothing is sent while
        /// it is held. ⛔ THE SHELL DOES NOT SNAP: `StepFrequency` is a
        /// ten-thousandth of the range, so the number sent is the one dragged and
        /// the engine's `parse_commit` alone clamps and snaps it. The declared step
        /// is the KEYBOARD increment only.
        /// </summary>
        private Slider BuildSlider(PaneLeaf leaf, SliderTrack track)
        {
            var range = track.Max - track.Min;
            var grip = new SliderState();
            var slider = new Slider
            {
                Minimum = track.Min,
                Maximum = track.Max,
                StepFrequency = range / 10000.0,
                SmallChange = track.Step ?? range / 100.0,
                LargeChange = (track.Step ?? range / 100.0) * 10,
                MinHeight = 0,
                Padding = new Thickness(0),
                IsThumbToolTipEnabled = false,
                Tag = grip,
            };
            if (leaf.Id.Length == 0) { slider.IsEnabled = false; return slider; }

            var id = leaf.Id;
            void Release()
            {
                if (!grip.Held) { return; }
                grip.Held = false;
                if (PanelWire.SliderCommit(slider.Value, grip.Shown) is { } text)
                {
                    SendPane(id, "commit", text, leaf.Path);
                }
            }
            // handledEventsToo: the Thumb handles its own pointer events.
            slider.AddHandler(UIElement.PointerPressedEvent,
                new PointerEventHandler((_, _) => grip.Held = true), true);
            slider.AddHandler(UIElement.PointerReleasedEvent,
                new PointerEventHandler((_, _) => Release()), true);
            slider.AddHandler(UIElement.PointerCaptureLostEvent,
                new PointerEventHandler((_, _) => Release()), true);
            // A key that MOVES the thumb commits on its release; Tab and the rest
            // never do.
            slider.KeyUp += (_, e) =>
            {
                if (e.Key is not (Windows.System.VirtualKey.Left or Windows.System.VirtualKey.Right
                    or Windows.System.VirtualKey.Up or Windows.System.VirtualKey.Down
                    or Windows.System.VirtualKey.Home or Windows.System.VirtualKey.End
                    or Windows.System.VirtualKey.PageUp or Windows.System.VirtualKey.PageDown)) { return; }
                if (PanelWire.SliderCommit(slider.Value, grip.Shown) is { } text) { SendPane(id, "commit", text, leaf.Path); }
            };
            return slider;
        }

        /// <summary>
        /// Fork B2: whether a person holds the colour bar, the last point a
        /// `change` sent, and the last point the pointer named.
        /// </summary>
        private sealed class ColorBarState
        {
            internal bool Held;
            internal string? LastSent;
            internal string? LastPoint;
        }

        /// <summary>
        /// FORK B2 (#394): a `color_bar`. A press captures the pointer; each held
        /// move to a new point sends `change` with `u,v`
        /// (<see cref="PanelWire.ColorBarPoint"/>), and the release sends `commit`
        /// with the release point. A lost capture commits the last point named.
        /// ⛔ NO COLOUR IS COMPUTED HERE: the engine maps and clamps the point,
        /// and the engine's picture of the bar (`display.picture`, §252) is
        /// decoded and stretched to the bar's rect, so the colour under a point
        /// is the colour that point picks. With no picture, an outline.
        /// </summary>
        private ColorBarSurface BuildColorBar(PaneLeaf leaf)
        {
            var grip = new ColorBarState();
            var bar = new ColorBarSurface
            {
                BorderThickness = new Thickness(1),
                BorderBrush = _paneMutedBrush,
                // A transparent fill, not none, so the whole bar takes the pointer.
                Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(0x00, 0x00, 0x00, 0x00)),
                Tag = grip,
            };
            if (leaf.Literal("summary") is { Length: > 0 } tip) { ToolTipService.SetToolTip(bar, tip); }
            if (PanelWire.PictureBytes(leaf.Shown("picture")) is { } picture) { LoadColorBarPicture(bar, picture, leaf, _paneBuild); }
            else { _w.Report($"PANEL PICTURE NONE {leaf.Id} -- the bar stays an outline"); }
            if (leaf.Id.Length == 0) { bar.IsHitTestVisible = false; return bar; }

            var id = leaf.Id;
            string? Point(PointerRoutedEventArgs e)
            {
                var at = e.GetCurrentPoint(bar).Position;
                return PanelWire.ColorBarPoint(at.X, at.Y, bar.ActualWidth, bar.ActualHeight);
            }
            void Move(string? point)
            {
                grip.LastPoint = point ?? grip.LastPoint;
                if (PanelWire.ColorBarChange(point, grip.LastSent) is { } text)
                {
                    grip.LastSent = text;
                    SendPane(id, "change", text, leaf.Path);
                }
            }
            void Release(string? point)
            {
                if (!grip.Held) { return; }
                grip.Held = false;
                if ((point ?? grip.LastPoint) is { } text) { SendPane(id, "commit", text, leaf.Path); }
            }
            bar.PointerPressed += (_, e) =>
            {
                grip.Held = true;
                grip.LastSent = null;
                grip.LastPoint = null;
                bar.CapturePointer(e.Pointer);
                Move(Point(e));
                e.Handled = true;
            };
            bar.PointerMoved += (_, e) =>
            {
                if (grip.Held) { Move(Point(e)); }
            };
            bar.PointerReleased += (_, e) =>
            {
                var point = Point(e);
                Release(point);
                bar.ReleasePointerCapture(e.Pointer);
                e.Handled = true;
            };
            bar.PointerCaptureLost += (_, _) => Release(null);
            return bar;
        }

        /// <summary>
        /// §252: draw the engine's BMP of the colour bar under the bar's pointer
        /// surface, stretched over the whole bar (the core's 120×32 to the leaf's
        /// rect), with no outline.
        /// The image takes no pointer, so every press still reaches the bar. A
        /// load for a replaced build is dropped; a failed load leaves the outline.
        /// </summary>
        private async void LoadColorBarPicture(ColorBarSurface bar, byte[] picture, PaneLeaf leaf, int build)
        {
            try
            {
                using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
                using (var writer = new Windows.Storage.Streams.DataWriter(stream))
                {
                    writer.WriteBytes(picture);
                    await writer.StoreAsync();
                    writer.DetachStream();
                }
                stream.Seek(0);
                var source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage();
                await source.SetSourceAsync(stream);
                if (build != _paneBuild) { return; }
                // The outline goes: a Grid's border insets its children, and the
                // pointer's u,v are measured over the whole bar, so an inset
                // picture would put a different colour under the point it picks.
                bar.BorderThickness = new Thickness(0);
                bar.Children.Insert(0, new Image
                {
                    Source = source,
                    Stretch = Microsoft.UI.Xaml.Media.Stretch.Fill,
                    IsHitTestVisible = false,
                });
                _w.Report($"PANEL PICTURE drawn {leaf.Id} {source.PixelWidth}x{source.PixelHeight} into {leaf.W}x{leaf.H}");
            }
            catch (Exception ex)
            {
                _w.Report($"PANEL PICTURE FAILED {ex.GetType().Name}: {ex.Message} -- the bar stays an outline");
            }
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

/// <summary>
/// A `color_swatch` tile: a bordered, filled square that UI Automation can SEE.
/// A `Border` has no automation peer, so its AutomationId reached no reader:
/// measured on the Windows box (#323), 14 of color_panel_content's and 12 of
/// swatches_panel_content's ids were absent from the rendered tree while the
/// Mac gives the same widget its identifier. A `Grid` draws the same fill and
/// edge and takes the same tap; the peer is the only addition.
/// </summary>
internal sealed partial class SwatchTile : Grid
{
    protected override Microsoft.UI.Xaml.Automation.Peers.AutomationPeer OnCreateAutomationPeer() =>
        new Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer(this);
}

/// <summary>
/// Fork B2: the colour bar's surface. A panel has no automation peer, so this
/// one is given the plain element peer, as <see cref="SwatchTile"/> is, and the
/// bar's AutomationId reaches the rendered tree.
/// </summary>
internal sealed partial class ColorBarSurface : Grid
{
    protected override Microsoft.UI.Xaml.Automation.Peers.AutomationPeer OnCreateAutomationPeer() =>
        new Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer(this);
}

/// <summary>#431: an `icon_button_group`'s row of option buttons, a type of its own
/// so the value applier can tell it from any other StackPanel.</summary>
internal sealed partial class IconGroupRow : StackPanel
{
}

/// <summary>#434: a `reference_point_widget`'s grid of anchor cells, a type of its
/// own so the value applier can tell it from any other Grid; its peer makes the
/// widget id visible to UI Automation.</summary>
internal sealed partial class AnchorGrid : Grid
{
    protected override Microsoft.UI.Xaml.Automation.Peers.AutomationPeer OnCreateAutomationPeer() =>
        new Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer(this);
}

/// <summary>S3: a `radio_group`'s row of option radios, a type of its own so the
/// value applier can tell it from any other StackPanel.</summary>
internal sealed partial class RadioGroupRow : StackPanel
{
}
