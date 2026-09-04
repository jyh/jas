using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.Graphics;

namespace SbWinUi;

/// <summary>
/// The window. It OWNS NOTHING THE CORE TOUCHES.
///
/// ⛔ THE DIVISION OF LABOUR IS THE POINT, AND IT IS BL2's (`ffi.rs:16-17`): the
/// engine is `Rc`-based and not `Send`, so every call for it must happen on the
/// thread that created it. This class therefore decides, enqueues and reports.
/// It never calls the core -- not for a paint, not for a pointer, and not for
/// the harness's own `jas_document_json` dumps, which are queue commands like
/// everything else. The one file in this prototype that calls `JasCore` for the
/// retained engine is <c>Canvas.cs</c>, on one thread, and that thread's id is
/// printed on every receipt row so a reader can check it.
/// </summary>
public sealed partial class MainWindow : Window
{
    /// <summary>
    /// The title the verifier asserts on. Deliberately long and specific: the
    /// oracle must assert a value ONLY THIS APP CAN PRODUCE, the same law
    /// <c>scripts/check_native_backend_lane.py</c> is built on. A title like
    /// "MainWindow" would match half the windows ever opened on this desktop and
    /// would pass over a run in which nothing of ours appeared.
    /// </summary>
    public const string VerifyTitle = "JAS S-B MATERIALIZER CHECKPOINT 3";

    /// <summary>
    /// ONE LOCK FOR THE RECEIPT FILE, and it is a correctness fix rather than a
    /// precaution (FREEZE §1.3 / A9). <see cref="Report"/> is now called from the
    /// RENDER thread (every scene, resize and pointer row) and from the UI thread
    /// (the refusals), and two threads appending one file inside a bare `catch`
    /// LOSE ROWS -- silently, because the catch was written to stop diagnostics
    /// becoming the failure. The receipt IS the oracle for O1, O2, O3, O5 and O6,
    /// so a lost row is a lost measurement wearing a green tick.
    /// </summary>
    private static readonly object LogLock = new();

    /// <summary>
    /// The retained canvas. `global::` qualified because `x:Name="Canvas"` also
    /// puts a `SwapChainPanel` field called `Canvas` on this class: the two names
    /// are legal together (one is a type, one is a member) and the qualification
    /// is here so nobody has to work that out from the compiler's answer.
    /// </summary>
    private readonly global::SbWinUi.Canvas _canvas;

    /// <summary>Captured on the XAML thread in the constructor, BEFORE anything else
    /// exists that might want to post to it. Reading `Window.DispatcherQueue` from
    /// the render thread would be a XAML-object touch off the XAML thread.</summary>
    private readonly DispatcherQueue _ui;

    private bool _started;
    private bool _afterSceneDriven;

    /// <summary>`hit=PANEL` or `hit=SIBLING`, printed on every pointer row.</summary>
    private string _hit = "PANEL";

    /// <summary>The `AppWindow` size at first layout -- what `SB_RESIZE`'s `original`
    /// sentinel resolves to. Recorded, never assumed.</summary>
    private SizeInt32 _originalSize;

    private List<string> _resizeSteps = new();
    private int _resizeStep;

    // ---- the open gesture, owned by the XAML thread -----------------------
    private bool _gestureOpen;
    private int _pressCount;
    private int _moveCount;
    private int _releaseCount;
    private double _pressX;
    private double _pressY;
    private double _lastX;
    private double _lastY;
    private uint _pointerId;
    private string _device = "Unknown";

    public MainWindow()
    {
        InitializeComponent();
        Title = VerifyTitle;
        _ui = DispatcherQueue;
        _canvas = new global::SbWinUi.Canvas(Report);
        _canvas.SurfaceSettled = DriveNextResize;
        _canvas.SceneCompleted = AfterScene;

        // SB_FULLSCREEN: THE COPY COST IS FIXED BY SURFACE AREA, so pricing it
        // needs a run at the display's full resolution and not at whatever size
        // WinUI happens to give a new window. The default 1904x941 is 1.79 Mpx
        // against this display's 8.29 Mpx -- 22% -- so a copy priced only there
        // understates the full-screen cost by ~4.6x.
        //
        // Set BEFORE the panel is laid out, so the FIRST SizeChanged (the one
        // that starts the run) is already the fullscreen size. If this ran after
        // layout the run would report 4K in its label while measuring a small
        // window -- and the numbers would look entirely plausible.
        if (Environment.GetEnvironmentVariable("SB_FULLSCREEN") == "1")
        {
            AppWindow.SetPresenter(Microsoft.UI.Windowing.AppWindowPresenterKind.FullScreen);
        }

        // ⛔ SB_TOPMOST=1 -- BECAUSE THE HARNESS KEPT PHOTOGRAPHING ITS OWN
        // CONSOLE INSTEAD OF THIS WINDOW. On Windows 11 the console host is
        // Windows Terminal, whose window `-WindowStyle Hidden` DOES NOT
        // suppress, so a black console lands on the desktop AFTER this window and
        // covers the canvas. Measured 2026-09-01 across three consecutive runs.
        // Hiding consoles is whack-a-mole; owning the top of the z-order is not.
        //
        // OPT-IN, so every S-B and S-C timing already on record keeps meaning
        // what it meant: a run is only comparable to another run it shares its
        // flags with.
        if (Environment.GetEnvironmentVariable("SB_TOPMOST") == "1"
            && AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter op)
        {
            op.IsAlwaysOnTop = true;
        }

        // SizeChanged rather than Loaded: a SwapChainPanel has no useful size
        // until it has been laid out. A NAMED handler rather than a lambda, so
        // the width and height it decides on have a method a reader (and O2b's
        // text gate) can name.
        this.Canvas.SizeChanged += OnCanvasSizeChanged;
        this.Canvas.CompositionScaleChanged += OnCompositionScaleChanged;
        WirePointer();

        // ONE `jas_engine_free`, at Quit, on the thread that made the engine.
        Closed += OnWindowClosed;
    }

    // =======================================================================
    // COAT 4 — REAL POINTER INPUT
    // =======================================================================

    /// <summary>
    /// ⚠️ HIT-TESTABILITY IS A BRANCH, NOT A DISCOVERY (FREEZE §1.4 / A4, stop 8).
    ///
    /// A `SwapChainPanel` with no `Background` may not be hit-testable, and
    /// `Background` cannot be set on it (its own Remarks page says so). The docs
    /// do not settle it and NEITHER DOES THIS MACHINE -- the shell does not
    /// compile on the Mac this was written on, so the question is decided at the
    /// box and not here.
    ///
    /// So BOTH ARMS ARE BUILT and one switch chooses: `SB_HIT=panel` (the
    /// default) puts the handlers on the panel; `SB_HIT=sibling` reveals a
    /// transparent `Border` in the SAME grid cell (`MainWindow.xaml`,
    /// `Grid.Row="0"`) and puts the SAME handlers on that. A `Transparent`
    /// background is hit-testable where a null one is not, which is the whole
    /// mechanism. Either way the receipt says which arm ran (`hit=PANEL` /
    /// `hit=SIBLING`), so a row can never be read as evidence about the arm it
    /// did not take.
    ///
    /// An unrecognised value is REFUSED BY NAME rather than falling back to the
    /// default: a run asked for the sibling that quietly used the panel would
    /// report the wrong arm in the one field the branch exists to answer.
    /// </summary>
    private void WirePointer()
    {
        var hit = Environment.GetEnvironmentVariable("SB_HIT");
        UIElement target;
        if (string.IsNullOrWhiteSpace(hit) || string.Equals(hit, "panel", StringComparison.OrdinalIgnoreCase))
        {
            _hit = "PANEL";
            target = this.Canvas;
        }
        else if (string.Equals(hit, "sibling", StringComparison.OrdinalIgnoreCase))
        {
            _hit = "SIBLING";
            HitShield.Visibility = Visibility.Visible;
            target = HitShield;
        }
        else
        {
            _hit = "REFUSED";
            StatusLine.Text = $"FAILED - SB_HIT='{hit}' is not recognised";
            Report($"RUSTFAIL SB_HIT='{hit}' is not recognised; use 'panel' or 'sibling'");
            return;
        }

        target.PointerPressed += OnPointerPressed;
        target.PointerMoved += OnPointerMoved;
        target.PointerReleased += OnPointerReleased;
        target.PointerCaptureLost += OnPointerCaptureLost;
        target.PointerCanceled += OnPointerCanceled;
    }

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (sender is UIElement el) { el.CapturePointer(e.Pointer); }
        _gestureOpen = true;
        _pointerId = e.Pointer.PointerId;
        _device = e.Pointer.PointerDeviceType.ToString();
        _pressCount++;
        _moveCount = 0;
        _releaseCount = 0;
        var (x, y) = Physical(e);
        _pressX = x;
        _pressY = y;
        _lastX = x;
        _lastY = y;
        _canvas.Pointer(JasCore.PointerPress, x, y, Mods(e));
        e.Handled = true;
    }

    /// <summary>
    /// ⛔ ONLY WHILE CAPTURED, AND A HOVER IS NOT A DRAG. `MOD_DRAGGING`
    /// (`ffi_pointer.rs:35`) exists because the canvas has no such concept and
    /// the tool trait does -- `on_move`'s `dragging` -- so the shell is the only
    /// thing that knows. Forwarding idle motion would drive the selection tool's
    /// `on_move` with a button that is not down.
    ///
    /// ⚠️ TRUE OF TOOL 0 ONLY, which is why `SB_TOOL != 0` is refused by name
    /// this wave: `pen.yaml:83-85` sets `mouse_x/y` on every `on_mousemove`,
    /// captured or not, so captured-only forwarding would starve it.
    /// </summary>
    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_gestureOpen) { return; }
        var (x, y) = Physical(e);
        _lastX = x;
        _lastY = y;
        _moveCount++;
        _canvas.Pointer(JasCore.PointerMove, x, y, Mods(e) | JasCore.ModDragging);
        e.Handled = true;
    }

    private void OnPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        var (x, y) = Physical(e);
        EndGesture(x, y, Mods(e), "REAL");
        if (sender is UIElement el) { el.ReleasePointerCapture(e.Pointer); }
        e.Handled = true;
    }

    private void OnPointerCaptureLost(object sender, PointerRoutedEventArgs e) =>
        EndGesture(_lastX, _lastY, 0, "CAPTURE-LOST");

    private void OnPointerCanceled(object sender, PointerRoutedEventArgs e) =>
        EndGesture(_lastX, _lastY, 0, "CANCELED");

    /// <summary>
    /// Close the gesture ONCE, whoever closes it.
    ///
    /// ⛔ IDEMPOTENT, AND THAT IS NOT DEFENSIVE CODING. `PointerCaptureLost`
    /// fires on EVERY normal release too -- `ReleasePointerCapture` raises it --
    /// so without the latch a clean drag would send two Releases to the core and
    /// the second would arrive with no gesture open. A closed gesture is a no-op
    /// here, and the row is written by whichever path actually closed it.
    /// </summary>
    private void EndGesture(double x, double y, uint mods, string kind)
    {
        if (!_gestureOpen) { return; }
        _gestureOpen = false;
        _releaseCount++;
        _canvas.Pointer(JasCore.PointerRelease, x, y, mods);
        if (kind != "REAL")
        {
            Report($"POINTER CAPTURE-LOST reason={kind} id={_pointerId} device={_device} "
                 + $"hit={_hit} synthetic-release@=({x:F1},{y:F1}) {_canvas.Tids()}");
        }
        _canvas.PointerReport(new PointerReportCmd
        {
            Kind = kind == "REAL" ? "REAL" : "CAPTURE-LOST",
            PointerId = _pointerId,
            Device = _device,
            Hit = _hit,
            Press = _pressCount,
            Move = _moveCount,
            Release = _releaseCount,
            PressX = _pressX,
            PressY = _pressY,
            ReleaseX = x,
            ReleaseY = y,
        });
    }

    /// <summary>
    /// DIPs in, PHYSICAL PIXELS out, and the multiply never gets a matching
    /// divide on this side.
    ///
    /// `GetCurrentPoint(Canvas).Position` is in DIPs relative to the panel. The
    /// core takes PHYSICAL pixels (`ffi_pointer.rs:127`) and divides by the scale
    /// it was told (`:143`), so the shell multiplies and reports the scale with
    /// `jas_set_dpi_scale`. Under jas#16 -- the buffer is sized in DIPs and the
    /// compositor upscales -- the multiply-then-divide is an identity on the
    /// document coordinates, WHICH IS THE POINT: the same code is right before
    /// and after #16 lands, and the divide never lives in C#.
    /// </summary>
    private (double X, double Y) Physical(PointerRoutedEventArgs e)
    {
        var p = e.GetCurrentPoint(this.Canvas).Position;
        return (p.X * this.Canvas.CompositionScaleX, p.Y * this.Canvas.CompositionScaleY);
    }

    /// <summary>
    /// Shift -> MOD_SHIFT, Menu -> MOD_ALT. The bit values are ABI
    /// (`ffi_pointer.rs:30-35`); this MIRRORS them and never renumbers.
    /// </summary>
    private static uint Mods(PointerRoutedEventArgs e)
    {
        uint m = 0;
        var k = e.KeyModifiers;
        if ((k & Windows.System.VirtualKeyModifiers.Shift) != 0) { m |= JasCore.ModShift; }
        if ((k & Windows.System.VirtualKeyModifiers.Menu) != 0) { m |= JasCore.ModAlt; }
        return m;
    }

    private void OnCompositionScaleChanged(SwapChainPanel sender, object args) =>
        _canvas.SetDpiScale(sender.CompositionScaleX);

    private void OnWindowClosed(object sender, WindowEventArgs args)
    {
        _canvas.Quit();
        _canvas.Dispose();
    }

    // =======================================================================
    // THE SURFACE — every dimension through SurfacePolicy.Decide
    // =======================================================================

    /// <summary>
    /// ⭐ F-6's REPAIR AT THE REAL LINK. Three `Math.Max(..., 1)` sites became one
    /// pure decision with three answers, and the answer is on the receipt.
    ///
    /// The handler decides FIRST so it can name the policy SOURCE
    /// (`policy=EVENT` -- this came through the window manager, not through a
    /// probe). `Canvas.Resize` decides again because it is the only door to
    /// `ResizeBuffers`; `Decide` is pure, so the second reading cannot disagree
    /// with the first.
    /// </summary>
    private void OnCanvasSizeChanged(object sender, SizeChangedEventArgs e)
    {
        var w = (uint)e.NewSize.Width;
        var h = (uint)e.NewSize.Height;
        var decision = SurfacePolicy.Decide(w, h, _canvas.HasSurface);

        if (decision == Decision.Refuse)
        {
            // THE SWAPCHAIN IS NOT TOUCHED AND THE LAST GOOD SURFACE STANDS. The
            // clamp this replaced said `resized to 1184x1` and reported success.
            StatusLine.Text = $"REFUSED {w}x{h} - surface stays {_canvas.Width}x{_canvas.Height}";
            Report($"RESIZE REFUSED {w}x{h} — surface stays {_canvas.Width}x{_canvas.Height} "
                 + $"policy=EVENT {_canvas.Tids()}");
            return;
        }
        if (decision == Decision.Defer)
        {
            // Before Attach a zero is normal and refusing would brick startup.
            Report($"RESIZE DEFERRED {w}x{h} — no surface yet policy=DEFER {_canvas.Tids()}");
            return;
        }

        if (!_started)
        {
            StartFirstLayout(w, h);
            return;
        }

        // ⚠️ SB_SIZE AND A RESIZE ARE MUTUALLY EXCLUSIVE, and this is the one
        // decision the merge had to make rather than inherit. SB_SIZE exists to
        // pin the swapchain at a stated physical size so a number can be
        // attributed to it; a later resize moves the surface out from under that
        // pin. Honouring both would produce a run LABELLED with the forced size
        // and MEASURED at another. So the pin wins and the resize is REFUSED BY
        // NAME rather than silently ignored.
        if (!string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("SB_SIZE")))
        {
            Report($"RUSTFAIL SB_SIZE pins the surface; a resize to {w}x{h} would "
                 + "measure a size the run is not labelled with. Use one or the other.");
            StatusLine.Text = "FAILED - SB_SIZE and SB_RESIZE are mutually exclusive";
            return;
        }

        _canvas.Resize(w, h, "EVENT");
    }

    /// <summary>
    /// First layout: bind the core, build the surface on the render thread, and
    /// enqueue the scene. NOTHING here paints, and nothing here waits.
    /// </summary>
    private void StartFirstLayout(uint w, uint h)
    {
        _started = true;
        try
        {
            // ⛔ SB_TOOL != 0 IS REFUSED BY NAME. Captured-only forwarding is
            // answered for the SELECTION tool only (the freeze's R5, narrowed by
            // the verdict at `selection.yaml:153-160`), and `pen` reads idle
            // motion. A run that asked for the pen and silently got selection
            // would report a gesture the tool never saw.
            var tool = Environment.GetEnvironmentVariable("SB_TOOL");
            if (!string.IsNullOrWhiteSpace(tool) && tool.Trim() != "0")
            {
                StatusLine.Text = $"FAILED - SB_TOOL='{tool}' is refused this wave";
                Report($"RUSTFAIL SB_TOOL='{tool}' is refused: only tool 0 (selection) is "
                     + "answered this wave; captured-only pointer forwarding is not correct "
                     + "for tools that read idle motion");
                return;
            }

            // SB_SIZE=WxH -- A MEASUREMENT INPUT, AND DELIBERATELY NOT THE FIX
            // for jas#16. `e.NewSize` is in DIPs; at 150% scaling a 3840x2160
            // display reports 2560x1440, so every surface this harness measured
            // was 3.60 Mpx. The real fix is the inverse matrix transform and it
            // is booked work. This is the narrower thing: an explicit size input
            // that sizes the SWAPCHAIN in physical pixels.
            var forced = Environment.GetEnvironmentVariable("SB_SIZE");
            if (!string.IsNullOrWhiteSpace(forced))
            {
                if (TryParseSize(forced, out var fw, out var fh) && fw > 0 && fh > 0)
                {
                    w = fw;
                    h = fh;
                }
                else
                {
                    // REFUSE LOUDLY. A malformed SB_SIZE that silently fell back
                    // to the DIP size would produce a run labelled 4K and
                    // measured at 3.6 Mpx -- the exact confusion this input
                    // exists to end, wearing the label of its own cure.
                    Report($"SBFAIL bad SB_SIZE '{forced}' (want WxH)");
                    StatusLine.Text = $"FAILED - bad SB_SIZE '{forced}'";
                    return;
                }
            }

            JasCore.Bind();

            // `original`'s referent, RECORDED rather than recomputed later. It is
            // an AppWindow size (what SB_RESIZE sets), not a surface size (what
            // the hash is of) -- the two differ by the chrome and the status row,
            // which is why O1 compares at the OBSERVED surface and refuses a
            // mismatch instead of asserting the requested one.
            _originalSize = AppWindow.Size;

            if (!_canvas.Attach(_ui, this.Canvas, w, h,
                                this.Canvas.CompositionScaleX, this.Canvas.CompositionScaleY))
            {
                _started = false;   // a DEFERRED first layout tries again next pass
                return;
            }

            // ⭐ AN EMPTY SB_SCENE RESOLVES TO `benchmark` (FREEZE §1.2 / A8).
            // `RenderFrame` was what ran when the knob was unset, and the
            // committed 4K sweep never set it -- so every historical invocation
            // keeps its meaning, and the sweep now names the scene explicitly so
            // its receipts say what they ran. An unrecognised value is refused by
            // name on the render thread.
            var scene = Environment.GetEnvironmentVariable("SB_SCENE");
            if (string.IsNullOrWhiteSpace(scene)) { scene = "benchmark"; }
            _canvas.Scene(scene);
        }
        catch (Exception ex)
        {
            // Swallowing would leave a blank canvas and a cheerful status, which
            // is the vacuous-success shape this whole branch exists to refuse.
            StatusLine.Text = $"FAILED — {ex.GetType().Name}: {ex.Message}";
            Report($"RUSTFAIL {ex.GetType().Name}: {ex.Message}");
            // A window title holds one line; an interop failure needs the FRAME.
            try
            {
                File.WriteAllText(
                    Path.Combine(AppContext.BaseDirectory, "sb-error.txt"),
                    ex.ToString());
            }
            catch { /* diagnostics must never become the failure */ }
        }
    }

    /// <summary>
    /// Runs ONCE, on the UI thread, after the scene has finished on the render
    /// thread.
    ///
    /// ⛔ NOT AT THE END OF `StartFirstLayout`, AND THAT IS A RACE THIS DESIGN
    /// HAD TO ANSWER. `Attach` is now asynchronous: it starts a thread and
    /// enqueues. A probe fired straight after it would ask
    /// `SurfacePolicy.Decide(0, 0, hasSurface)` while `hasSurface` was still
    /// false and get DEFER -- the answer for a startup that has not happened yet,
    /// printed on a row about a surface that exists. O6's `policy=PROBE` control
    /// would then be measuring the race and not the policy.
    /// </summary>
    private void AfterScene()
    {
        if (_afterSceneDriven) { return; }
        _afterSceneDriven = true;
        MaybeProbeSurface();
        MaybeSqueeze();
        MaybeDriveResize();
    }

    /// <summary>
    /// `SB_SURFACE_PROBE=WxH` drives <c>SurfacePolicy.Decide</c> DIRECTLY.
    ///
    /// The POLICY FUNCTION's own control, and it is deliberately not a substitute
    /// for the real link: `SB_SQUEEZE` drives a genuine zero-height
    /// `SizeChanged` through the window manager (`policy=EVENT`), and this drives
    /// the same decision procedure with a value nobody had to squeeze a window to
    /// obtain (`policy=PROBE`). Two routes, one function. The ACCEPT arm is here
    /// too -- `SB_SURFACE_PROBE=1000x600` resizes -- because a refusal arm alone
    /// is satisfied by a function that refuses everything.
    /// </summary>
    private void MaybeProbeSurface()
    {
        var probe = Environment.GetEnvironmentVariable("SB_SURFACE_PROBE");
        if (string.IsNullOrWhiteSpace(probe)) { return; }
        if (!TryParseSize(probe, out var pw, out var ph))
        {
            Report($"RUSTFAIL SB_SURFACE_PROBE malformed: '{probe}' (want WxH)");
            return;
        }

        var decision = SurfacePolicy.Decide(pw, ph, _canvas.HasSurface);
        if (decision == Decision.Refuse)
        {
            Report($"RESIZE REFUSED {pw}x{ph} — surface stays {_canvas.Width}x{_canvas.Height} "
                 + $"policy=PROBE {_canvas.Tids()}");
            return;
        }
        if (decision == Decision.Defer)
        {
            Report($"RESIZE DEFERRED {pw}x{ph} — no surface yet policy=PROBE {_canvas.Tids()}");
            return;
        }
        Report($"RESIZE ACCEPTED {pw}x{ph} policy=PROBE {_canvas.Tids()}");
        _canvas.Resize(pw, ph, "PROBE");
    }

    /// <summary>
    /// `SB_SQUEEZE=1` -- 0x0 THROUGH THE REAL LINK (FREEZE O6 / A6, R6).
    ///
    /// The panel is the STAR ROW of a two-row grid, so squeezing the window to
    /// the status line's own height leaves the panel with nothing: `SizeChanged`
    /// then fires with height 0 through the window manager, which is the event
    /// the clamp used to swallow. `PreferredMinimumHeight = 1` is what lets the
    /// window get that small at all -- without it the manager stops at its own
    /// minimum and the experiment silently measures a window that never shrank.
    ///
    /// The presenter is grabbed by name and REFUSED by name if it is the wrong
    /// kind, rather than skipped: a squeeze that did not happen must not read as
    /// a squeeze that was accepted.
    /// </summary>
    private void MaybeSqueeze()
    {
        if (Environment.GetEnvironmentVariable("SB_SQUEEZE") != "1") { return; }
        if (AppWindow.Presenter is not Microsoft.UI.Windowing.OverlappedPresenter op)
        {
            Report("RUSTFAIL SB_SQUEEZE needs an OverlappedPresenter; this window has "
                 + $"{AppWindow.Presenter.Kind}");
            return;
        }
        op.PreferredMinimumHeight = 1;
        var target = (int)Math.Ceiling(
            StatusLine.ActualHeight + StatusLine.Margin.Top + StatusLine.Margin.Bottom);
        Report($"SQUEEZE requesting window height {target} (status row) from {AppWindow.Size.Height} "
             + $"{_canvas.Tids()}");
        _ui.TryEnqueue(() =>
        {
            try
            {
                AppWindow.Resize(new SizeInt32(AppWindow.Size.Width, target));
            }
            catch (Exception ex)
            {
                Report($"RUSTFAIL squeeze request {ex.GetType().Name}: {ex.Message}");
            }
        });
    }

    /// <summary>
    /// `SB_RESIZE=1000x600,original` -- A LIST, and `original` is a SENTINEL.
    ///
    /// ⛔ WHY A LIST AT ALL (FREEZE O1 / A12). O1 needs the surface to go AWAY and
    /// COME BACK so the retained document can be proven identical across the
    /// round trip. One size cannot express that. And `original` cannot be written
    /// as a literal by the harness, because `SB_RESIZE` sets a WINDOW size
    /// (`AppWindow.Resize`) while the hash is of the SURFACE (client DIPs): a
    /// window size fed back returns a SMALLER surface, so `H0 == H2` could not be
    /// produced as v1 wrote it. The sentinel resolves to the AppWindow size
    /// RECORDED at first layout.
    ///
    /// STEPPED BY RECEIPT, NOT BY SLEEP: each step is posted when the previous
    /// one has actually landed on the render thread (`SurfaceSettled`). A sleep
    /// would measure the sleep, and a sleep that was too short would compare two
    /// surfaces while one of them was mid-flight.
    ///
    /// Posted through the dispatcher rather than called inline: the first
    /// SizeChanged may still be on the stack, and resizing from inside a layout
    /// pass is how a reentrancy fault gets blamed on the graphics code. A
    /// malformed value REFUSES LOUDLY instead of falling back to no resize.
    /// </summary>
    private void MaybeDriveResize()
    {
        if (_resizeSteps.Count > 0) { DriveNextResize(); return; }

        var spec = Environment.GetEnvironmentVariable("SB_RESIZE");
        if (string.IsNullOrWhiteSpace(spec)) { return; }

        var steps = new List<string>();
        foreach (var raw in spec.Split(','))
        {
            var token = raw.Trim();
            if (token.Length == 0) { continue; }
            if (string.Equals(token, "original", StringComparison.OrdinalIgnoreCase))
            {
                steps.Add("original");
                continue;
            }
            if (!TryParseSize(token, out var rw, out var rh) || rw < 1 || rh < 1)
            {
                StatusLine.Text = $"FAILED — SB_RESIZE malformed: '{spec}' (want WxH[,WxH|original]...)";
                Report($"RUSTFAIL SB_RESIZE malformed at '{token}' in '{spec}' "
                     + "(want WxH, or the sentinel 'original', comma-separated)");
                return;
            }
            steps.Add(token);
        }
        if (steps.Count == 0)
        {
            Report($"RUSTFAIL SB_RESIZE '{spec}' names no steps");
            return;
        }

        _resizeSteps = steps;
        _resizeStep = 0;
        DriveNextResize();
    }

    private void DriveNextResize()
    {
        if (_resizeStep >= _resizeSteps.Count) { return; }
        var token = _resizeSteps[_resizeStep];
        _resizeStep++;

        SizeInt32 target;
        if (string.Equals(token, "original", StringComparison.OrdinalIgnoreCase))
        {
            target = _originalSize;
        }
        else if (TryParseSize(token, out var rw, out var rh))
        {
            target = new SizeInt32((int)rw, (int)rh);
        }
        else
        {
            Report($"RUSTFAIL SB_RESIZE step '{token}' did not parse on its second reading");
            return;
        }

        Report($"RESIZE STEP {_resizeStep}/{_resizeSteps.Count} '{token}' -> window "
             + $"{target.Width}x{target.Height} {_canvas.Tids()}");
        _ui.TryEnqueue(() =>
        {
            try
            {
                AppWindow.Resize(target);
            }
            catch (Exception ex)
            {
                StatusLine.Text = $"FAILED — resize request threw {ex.GetType().Name}";
                Report($"RUSTFAIL resize request {ex.GetType().Name}: {ex.Message}");
            }
        });
    }

    /// <summary>
    /// `WxH` -> two unsigned numbers. ZERO IS A LEGAL PARSE and that is the
    /// point: `SB_SURFACE_PROBE=0x0` must reach <c>SurfacePolicy.Decide</c> to be
    /// refused BY THE POLICY, not rejected by the parser and reported as a typo.
    /// Callers that need a positive size say so themselves.
    /// </summary>
    private static bool TryParseSize(string spec, out uint w, out uint h)
    {
        w = 0;
        h = 0;
        var parts = spec.Split('x', 'X');
        return parts.Length == 2
            && uint.TryParse(parts[0], out w)
            && uint.TryParse(parts[1], out h);
    }

    // =======================================================================
    // THE RECEIPT
    // =======================================================================

    /// <summary>
    /// Publish the outcome INTO THE LOG AND THE WINDOW TITLE -- split, serialised,
    /// and never silent (FREEZE §1.3 / A9).
    ///
    /// THE LOG APPEND HAPPENS ON THE CALLING THREAD UNDER ONE STATIC LOCK. Most
    /// callers are the render thread; the refusals are the UI thread. Two threads
    /// appending one file inside the bare `catch` this method used to have would
    /// LOSE ROWS, and the receipt is the oracle.
    ///
    /// THE TITLE AND STATUS WRITE IS POSTED TO THE UI THREAD, FIRE-AND-FORGET.
    /// `Title` and `StatusLine.Text` are XAML and must be touched there; a
    /// blocking hand-over from the render thread would be stop 2's deadlock by a
    /// third door.
    ///
    /// AND A CAUGHT EXCEPTION PUTS `RECEIPT-LOST` IN THE TITLE. The old bare
    /// `catch { }` said "diagnostics must never become the failure", which is
    /// right, but it made a lost receipt indistinguishable from a run that had
    /// nothing to say -- and the session-1 oracle reads titles.
    ///
    /// The title is a channel that is known to work, carrying a value only a real
    /// paint attempt can produce; the file is how a measurement reaches session 0,
    /// which cannot see session 1's titles. Both, because they answer different
    /// questions.
    /// </summary>
    private void Report(string status)
    {
        string? lost = null;
        try
        {
            var path = System.IO.Path.Combine(AppContext.BaseDirectory, "sb-runs.log");
            var mode = Environment.GetEnvironmentVariable("SB_MODE") ?? "(default:offscreen)";
            var size = Environment.GetEnvironmentVariable("SB_SIZE") ?? "(window)";
            var frames = Environment.GetEnvironmentVariable("SB_FRAMES") ?? "(default:60)";
            var line = $"{DateTime.Now:HH:mm:ss}\tSB_MODE={mode}\tSB_SIZE={size}\t"
                     + $"SB_FRAMES={frames}\t{status}\n";
            lock (LogLock)
            {
                System.IO.File.AppendAllText(path, line);
            }
        }
        catch (Exception ex)
        {
            lost = $"RECEIPT-LOST {ex.GetType().Name}";
        }

        var text = lost is null ? status : $"{lost} | {status}";
        _ui.TryEnqueue(() =>
        {
            Title = $"{VerifyTitle} | {text}";
            StatusLine.Text = text;
        });
    }
}
