using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.Graphics;
// ⛔ NO `using Windows.System;` HERE. It would make `DispatcherQueue` ambiguous
// between `Microsoft.UI.Dispatching.DispatcherQueue` (the field `_ui`) and
// `Windows.System.DispatcherQueue`. `VirtualKey`/`VirtualKeyModifiers` are
// therefore fully qualified below, which is what line ~560 already did.
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.HiDpi;

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
    /// How long the squeeze waits for the window manager's `SizeChanged` before
    /// writing `delivered NONE`. Bounded, because the row must be written
    /// whether the event comes or not; generous, because a slow answer and no
    /// answer are different findings and the deadline must not turn the first
    /// into the second.
    /// </summary>
    private const int SqueezeDeadlineMs = 2000;

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
    /// THE RUN'S VERDICT, FOLDED OVER EVERY ROW — the value the session-1 title
    /// oracle actually reads. Guarded by <see cref="LogLock"/> for exactly the
    /// reason the log append is: <see cref="Report"/> runs on the render thread
    /// and on the UI thread, and an unsynchronised read-modify-write here would
    /// lose a verdict the same way an unsynchronised append lost a row.
    ///
    /// ⛔ IT IS NOT A COPY OF THE LAST ROW. See <see cref="TitleVerdict"/> for
    /// why the title's verdict is a property of the RUN: three successful runs
    /// were failed by the last-row rule on kenai 2026-09-04, and the class of
    /// rows that can do it has twenty-odd members, not the three #118 named.
    /// </summary>
    private static TitleVerdict _titleVerdict = TitleVerdict.Empty;

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

    // ---- the squeeze, and what it was answered with -----------------------

    /// <summary>
    /// A squeeze has been REQUESTED and the window manager's answer has not been
    /// seen yet. The next `SizeChanged` writes the `SQUEEZE delivered` row
    /// whatever it carries, and a bounded timer writes one if no `SizeChanged`
    /// arrives at all.
    ///
    /// ⛔ WHY THE FLAG EXISTS AT ALL. `SB_SQUEEZE=1` produced NO row of any kind
    /// on the box: O6.1 failed twice while the PROBE arm passed, and from the
    /// log alone it was impossible to tell whether the window manager never
    /// delivered a zero-height `SizeChanged` or delivered one the policy
    /// accepted. Those are opposite findings and they looked identical, so the
    /// shell now writes a row in EVERY outcome and names the height it was
    /// actually given.
    /// </summary>
    private bool _squeezePending;

    /// <summary>The client height the squeeze asked the window down to.</summary>
    private int _squeezeRequestedHeight;

    /// <summary>What the presenter reports for its own minimum after the request
    /// (`PreferredMinimumHeight`), rendered as text because the interesting case
    /// is the one where the window manager IGNORES it.</summary>
    private string _squeezeMinHeight = "unset";

    /// <summary>Held in a field so the one-shot deadline is not collected before
    /// it fires. A timer nobody references is a receipt that may or may not be
    /// written, which is the shape this whole repair exists to end.</summary>
    private DispatcherQueueTimer? _squeezeTimer;

    /// <summary>
    /// True under `SB_SCENE=retained`: every settled surface in the `SB_RESIZE`
    /// walk is HASHED before the next step is asked for. O1's whole subject is
    /// the pixels at each stop, so a walk that stepped without hashing would
    /// arrive back at `original` having proven that a window can be resized.
    /// </summary>
    private bool _hashEveryStep;

    /// <summary>
    /// A step's hash is outstanding, so the NEXT step is owed to
    /// <c>HashTaken</c> and to nothing else.
    ///
    /// ⛔ THE GATE IS NOT DECORATION. `HashTaken` fires for EVERY hash row,
    /// including the two the `retained` scene takes for itself before the walk
    /// begins (`A` and `A-MUT`). Without this flag those would each advance the
    /// walk, and the surface would go away before the mutation's own frame had
    /// been hashed.
    /// </summary>
    private bool _awaitingStepHash;

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

    /// The last pointer FRAME this shell applied — id, timestamp and position
    /// together. See <see cref="OnPointerMoved"/> for what they are for and for
    /// the measurement that made them necessary.
    private uint? _lastFrameId;
    private ulong _lastTimestamp;
    private double _lastPosX;
    private double _lastPosY;
    /// How many re-delivered frames were suppressed in THIS gesture. Zeroed at
    /// the press and carried onto the `POINTER` row.
    private int _dupFrames;

    /// <summary>
    /// ⭐ EVERY `PointerMoved` THIS GESTURE WAS RAISED, COUNTED BEFORE ANY
    /// DECISION IS TAKEN ABOUT IT — and it exists to close a hole jas named on
    /// O4.4x's own PASS line rather than hiding: that arm asserts `dup-frames=`
    /// is REPORTED and well-formed, not that it is CORRECT. A shell that kept
    /// suppressing but stopped INCREMENTING would read `dup-frames=0` with
    /// `move == k` and pass both arms.
    ///
    /// ⛔ THE OBVIOUS CLOSURE DOES NOT WORK, and it was read before it was
    /// built. Counting `SB_TRACE_POINTER`'s `MOVE-DUP` rows against
    /// `dup-frames=` is THE SAME NUMBER TWICE: `_dupFrames++` and
    /// `TracePointer("MOVE-DUP", …)` are adjacent statements in one block, so a
    /// shell that stopped incrementing would stop tracing in the same breath.
    ///
    /// What closes it is an IDENTITY over three counters incremented at THREE
    /// DIFFERENT SITES:
    ///
    ///     raised == move + dup-frames
    ///
    /// `_movesRaised` here (before the branch), `_moveCount` in the applied
    /// branch, `_dupFrames` in the suppressed branch. Drop or freeze any ONE of
    /// the three and the identity breaks; no single edit can keep it true while
    /// making a count wrong. That is what `MOVE-DUP` could not give.
    /// </summary>
    private int _movesRaised;

    /// Read ONCE, at construction: a gesture must not change instrumentation
    /// halfway through. See <see cref="TracePointer"/>.
    private static readonly bool _tracePointer =
        !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("SB_TRACE_POINTER"));
    private string _device = "Unknown";

    public MainWindow()
    {
        InitializeComponent();
        // `RUSTPENDING`, not a bare name: a window that has reported nothing yet
        // must SAY so. The bare title used to be indistinguishable from a run
        // whose verdict had been blanked by a verdict-less last row.
        Title = TitleVerdict.Compose(VerifyTitle, TitleVerdict.Empty);
        _ui = DispatcherQueue;
        _canvas = new global::SbWinUi.Canvas(Report);
        _canvas.SurfaceSettled = OnSurfaceSettled;
        _canvas.SceneCompleted = AfterScene;
        _canvas.MenuChanged = OnMenuChanged;
        _canvas.DocumentDirtyChanged = OnDocumentDirtyChanged;
        _canvas.HashTaken = OnHashTaken;

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

    /// <summary>
    /// ⭐ ONE ROW PER POINTER EVENT, WITH THE FIELDS THAT SAY WHERE IT CAME
    /// FROM. Off unless `SB_TRACE_POINTER` is set, because a drag writes one row
    /// per event and the receipt is also the oracle for every other assertion.
    ///
    /// ⛔ WHY IT EXISTS. `move != k` -- the shell counting more `PointerMoved`
    /// than the injector sent -- has now survived two waves. #115 named a
    /// candidate mechanism and #117 refuted it by measurement; #117 characterised
    /// the extras as periodic in the drag's DURATION and said, in its own words,
    /// "characterised, not identified"; #118 priced them rather than explaining
    /// them. `probe_hold.ps1` then excluded everything below this class: a bare
    /// Win32 window driven by the SAME injector at the SAME configurations reads
    /// arrivals == k exactly, in both the legacy mouse stack and the pointer
    /// stack, repainting or not. So the extras are raised ABOVE the message
    /// queue, and these are the fields that say which:
    ///
    ///   `frame` and `ts`  -- a duplicate of either means one input frame was
    ///                        raised twice; distinct values on every row mean
    ///                        genuinely new frames arrived at this app and not
    ///                        at the probe.
    ///   `pos`             -- an extra that repeats the previous position is a
    ///                        re-delivery; one that moves is real motion.
    ///   `intermediates`   -- WinUI coalesces into a frame and offers the parts
    ///                        here; a count above 1 is the platform saying it
    ///                        merged, which is the OPPOSITE of an extra.
    ///   `update`          -- `PointerUpdateKind`; `Other` on a synthesized
    ///                        update, a button kind on a real transition.
    ///
    /// The row carries no verdict prefix ON PURPOSE: it is a note, not an
    /// outcome, and since the title carries the RUN's verdict rather than the
    /// last row's (see <see cref="TitleVerdict"/>) a diagnostic row can no
    /// longer blank the oracle -- which is what would have made this trace
    /// unusable during a real sitting.
    /// </summary>
    private void TracePointer(string kind, PointerRoutedEventArgs e)
    {
        if (!_tracePointer) { return; }
        try
        {
            var p = e.GetCurrentPoint(Canvas);
            var inter = e.GetIntermediatePoints(Canvas);
            Report($"POINTER-TRACE kind={kind} id={e.Pointer.PointerId} "
                 + $"ts={p.Timestamp} frame={p.FrameId} "
                 + $"pos=({p.Position.X:F2},{p.Position.Y:F2}) "
                 + $"contact={p.IsInContact} update={p.Properties.PointerUpdateKind} "
                 + $"intermediates={(inter is null ? -1 : inter.Count)} "
                 + $"move-count={_moveCount} gesture-open={_gestureOpen}");
        }
        catch (Exception ex)
        {
            // A trace that throws must not take the gesture with it -- the run
            // is still a measurement of everything else.
            Report($"POINTER-TRACE unavailable: {ex.GetType().Name}: {ex.Message}");
        }
    }

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (sender is UIElement el) { el.CapturePointer(e.Pointer); }
        TracePointer("PRESS", e);
        _gestureOpen = true;
        // ⛔ THE PRESS'S OWN FRAME IS SEEDED HERE, because XAML re-raises IT as
        // a `PointerMoved` too: the k=2 trace carries a MOVE at the press's
        // frame with `update=LeftButtonPressed` on it. Without this seed the
        // press's frame would be counted as the drag's first move.
        {
            var pressed = e.GetCurrentPoint(Canvas);
            _lastFrameId = pressed.FrameId;
            _lastTimestamp = pressed.Timestamp;
            _lastPosX = pressed.Position.X;
            _lastPosY = pressed.Position.Y;
        }
        _dupFrames = 0;
        _movesRaised = 0;
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
        if (!_gestureOpen) { TracePointer("MOVE-IGNORED", e); return; }

        // ⭐⭐ ONE INPUT FRAME IS ONE MOVE. THIS IS THE `move != k` DEFECT, AND
        // IT IS A RE-DELIVERY, NOT AN ARRIVAL.
        //
        // MEASURED on kenai 2026-09-06 with `SB_TRACE_POINTER=1`. k=2 at settle
        // 800 ms: `frame=4` was raised THREE times and `frame=5` TWICE, every
        // repeat carrying the SAME `FrameId` AND the SAME `Timestamp` AND the
        // same position. k=7 at settle 10 ms: seven moves, frames 4..10, each
        // raised exactly ONCE. So the repeats are XAML re-raising a frame the
        // shell has already applied, and they multiply with the IDLE GAP after
        // a frame -- which is precisely #117's "one extra per few hundred ms
        // while the button is held", seen from the other side.
        //
        // ⛔ AND IT IS NOT MERELY A COUNT. Every repeat also called
        // `_canvas.Pointer(PointerMove, ...)`, so the CORE was driven with a
        // point it had already been given, several times per stationary
        // moment. The counter was the visible half of a real defect.
        //
        // ⛔ EXCLUDED FIRST, BY MEASUREMENT, NOT BY ARGUMENT: `probe_hold.ps1`
        // drives a bare Win32 window with this harness's own injector at these
        // same configurations and reads arrivals == k EXACTLY -- in the legacy
        // mouse stack and in the pointer stack, repainting at 5 ms or not at
        // all. The injector, `SendInput`, the mouse stack, the pointer stack
        // and the message queue are therefore all innocent. #115's candidate
        // (positioned button events) was already refuted by #117.
        //
        // THE TEST IS THE WHOLE TRIPLE, not the frame id alone: a genuinely new
        // sample cannot share a predecessor's frame id, timestamp AND position,
        // so nothing real is dropped. Coalesced samples inside one frame are
        // offered through `GetIntermediatePoints`, which this shell does not
        // read -- so they were never separate events here to lose.
        // BEFORE THE DECISION. This is the third site of the identity described
        // on `_movesRaised`; counting it after the branch would make it a copy
        // of one of the other two rather than a witness over both.
        _movesRaised++;

        var pp = e.GetCurrentPoint(Canvas);
        if (_lastFrameId.HasValue
            && pp.FrameId == _lastFrameId.Value
            && pp.Timestamp == _lastTimestamp
            && pp.Position.X == _lastPosX
            && pp.Position.Y == _lastPosY)
        {
            // ⛔ COUNTED AND REPORTED, NEVER SILENTLY DROPPED. A shell that
            // quietly swallowed these would be indistinguishable from one where
            // they had stopped happening, and the next wave would have to
            // rediscover the whole finding.
            _dupFrames++;
            TracePointer("MOVE-DUP", e);
            e.Handled = true;
            return;
        }
        _lastFrameId = pp.FrameId;
        _lastTimestamp = pp.Timestamp;
        _lastPosX = pp.Position.X;
        _lastPosY = pp.Position.Y;

        TracePointer("MOVE", e);
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
            DupFrames = _dupFrames,
            MovesRaised = _movesRaised,
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

    /// <summary>
    /// The scale moved (a DPI change, or the window dragged to another panel),
    /// so BOTH halves of the scale chain move with it: the core is told the new
    /// scale, and the surface is re-derived in physical pixels from the SAME
    /// DIP size the panel still has.
    ///
    /// ⚠️ THE SECOND HALF IS THE ONE THAT WAS MISSING. `SizeChanged` does not
    /// fire when only the scale changes -- the panel's DIP size is unchanged --
    /// so a shell that only forwarded the scale would keep a surface sized for
    /// the old rasterisation and report it as current. It is routed through
    /// <c>Canvas.Resize</c>, which decides again, so a zero cannot enter here by
    /// a door `SizeChanged` does not open.
    /// </summary>
    private void OnCompositionScaleChanged(SwapChainPanel sender, object args)
    {
        _canvas.SetDpiScale(sender.CompositionScaleX);
        if (!_started || !_canvas.HasSurface) { return; }

        var scaleX = sender.CompositionScaleX <= 0 ? 1f : sender.CompositionScaleX;
        var scaleY = sender.CompositionScaleY <= 0 ? 1f : sender.CompositionScaleY;
        var w = (uint)(sender.ActualWidth * scaleX);
        var h = (uint)(sender.ActualHeight * scaleY);
        if (w == _canvas.Width && h == _canvas.Height) { return; }

        // SB_SIZE pins the surface; the same mutual exclusion the resize path
        // states applies here, and for the same reason.
        if (!string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("SB_SIZE"))) { return; }

        Report($"SCALE CHANGED composition-scale={scaleX:0.###}x{scaleY:0.###} "
             + $"client-dips={sender.ActualWidth:F0}x{sender.ActualHeight:F0} "
             + $"surface-request={w}x{h} {_canvas.Tids()}");
        _canvas.Resize(w, h, "SCALE");
    }

    /// <summary>
    /// ⭐ THE STARTUP RECEIPT, AND ITS POINT IS THAT THE HARNESS CAN ASSERT THE
    /// MANIFEST RATHER THAN INFER IT.
    ///
    /// The first run on the box diagnosed DPI-unawareness from a RATIO --
    /// `client-width / surface-width = 2856/1904 = 1.5` across two receipts
    /// written by two different programs. That reading was right, and it is the
    /// wrong kind of evidence to have to reconstruct: the app's own `scale=1`
    /// was TRUE from inside its virtualised view, so nothing in its log could
    /// contradict it. This row asks the OS what awareness it actually gave this
    /// window and what DPI it actually reports for it, so a manifest that failed
    /// to take effect says so in one field instead of being deduced from two
    /// numbers a page apart.
    ///
    /// ⚠️ `GetAwarenessFromDpiAwarenessContext` CANNOT DISTINGUISH PerMonitorV2
    /// FROM PerMonitor(v1): both answer `DPI_AWARENESS_PER_MONITOR_AWARE`. The
    /// pair to assert is therefore that field TOGETHER WITH
    /// `dpi-for-window`, which reads 96 for a virtualised window and the panel's
    /// real DPI (144 at 150%) for an aware one.
    /// </summary>
    private void ReportStartup(uint surfaceW, uint surfaceH)
    {
        var awareness = "UNKNOWN";
        var dpi = "n/a";
        try
        {
            var hwnd = (HWND)Microsoft.UI.Win32Interop.GetWindowFromWindowId(AppWindow.Id);
            awareness = PInvoke.GetAwarenessFromDpiAwarenessContext(
                PInvoke.GetWindowDpiAwarenessContext(hwnd)).ToString();
            dpi = PInvoke.GetDpiForWindow(hwnd).ToString();
        }
        catch (Exception ex)
        {
            // NAMED, never silent: a row that omitted the field would read
            // exactly like a build whose manifest was never applied.
            awareness = $"UNREADABLE({ex.GetType().Name})";
        }

        Report($"STARTUP dpi-awareness={awareness} dpi-for-window={dpi} "
             + $"composition-scale={this.Canvas.CompositionScaleX:0.###}x"
             + $"{this.Canvas.CompositionScaleY:0.###} "
             + $"client-dips={this.Canvas.ActualWidth:F0}x{this.Canvas.ActualHeight:F0} "
             + $"surface-request={surfaceW}x{surfaceH} {_canvas.Tids()}");
    }

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
        // ⭐ DIPs IN, PHYSICAL PIXELS OUT, AND THE MULTIPLY IS THE OTHER HALF OF
        // THE MANIFEST. `e.NewSize` is XAML's, so it is DIPs whatever the
        // display does; `CompositionScaleX/Y` is what the compositor will
        // rasterise those DIPs at. Sized in DIPs the swapchain would be 1904 px
        // wide behind a panel occupying 2856 device pixels and the compositor
        // would upscale it -- and the pointer path, which multiplies by the same
        // scale (see `Physical`), would then address a surface 1.5x larger than
        // the one that exists.
        //
        // Before the manifest this multiply was an identity (an unaware process
        // is told its scale is 1) and the defect was invisible for that reason;
        // it is the manifest that makes the scale real, so the two land in one
        // change and not in two.
        var scaleX = this.Canvas.CompositionScaleX <= 0 ? 1f : this.Canvas.CompositionScaleX;
        var scaleY = this.Canvas.CompositionScaleY <= 0 ? 1f : this.Canvas.CompositionScaleY;
        var w = (uint)(e.NewSize.Width * scaleX);
        var h = (uint)(e.NewSize.Height * scaleY);
        var decision = SurfacePolicy.Decide(w, h, _canvas.HasSurface);

        // The squeeze's answer, WHATEVER IT IS, before any early return below
        // can swallow it. A refusal, a deferral and an accept are three
        // different findings about the window manager and all three used to
        // leave the same silence.
        if (_squeezePending) { ReportSqueezeDelivered($"{w}x{h}", decision.ToString()); }

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

            // The startup receipt, written BEFORE the surface exists because
            // what it carries is a property of the process and the window, not
            // of the swapchain.
            ReportStartup(w, h);

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

            // O1's walk hashes at every stop. Decided HERE, from the scene name,
            // rather than inside the walk: the walk is generic and the hashing
            // is one scene's requirement, and a walk that hashed for everybody
            // would put a hash row into every benchmark receipt on record.
            _hashEveryStep = string.Equals(scene, "retained", StringComparison.OrdinalIgnoreCase);

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

        // READ BACK, NOT ASSUMED. `PreferredMinimumHeight` is a PREFERENCE: the
        // window manager enforces its own floor for a window with a caption, and
        // whether it honours 1 is precisely the question O6.1 could not answer
        // from the log. So the value the presenter reports after the write goes
        // on the receipt beside the height that was actually delivered.
        _squeezeMinHeight = $"{op.PreferredMinimumHeight}";
        _squeezeRequestedHeight = target;
        _squeezePending = true;

        Report($"SQUEEZE requesting window height {target} (status row) from {AppWindow.Size.Height} "
             + $"min-height policy={_squeezeMinHeight} {_canvas.Tids()}");
        _ui.TryEnqueue(() =>
        {
            try
            {
                AppWindow.Resize(new SizeInt32(AppWindow.Size.Width, target));
            }
            catch (Exception ex)
            {
                Report($"RUSTFAIL squeeze request {ex.GetType().Name}: {ex.Message}");
                ReportSqueezeDelivered("THREW", "NONE");
                return;
            }
            ArmSqueezeDeadline();
        });
    }

    /// <summary>
    /// ⛔ A ROW IN EVERY OUTCOME, INCLUDING SILENCE. If the window manager never
    /// delivers a `SizeChanged` at all, the absence is the finding -- and an
    /// absence cannot be read out of a log. So the request arms a bounded
    /// deadline, and the row it writes is DISTINCT from every row a delivered
    /// `SizeChanged` can write (`delivered NONE`).
    ///
    /// One shot, and it is held in a field so it cannot be collected before it
    /// fires.
    /// </summary>
    private void ArmSqueezeDeadline()
    {
        var timer = _ui.CreateTimer();
        _squeezeTimer = timer;
        timer.Interval = TimeSpan.FromMilliseconds(SqueezeDeadlineMs);
        timer.IsRepeating = false;
        timer.Tick += (s, e) =>
        {
            timer.Stop();
            if (!_squeezePending) { return; }
            ReportSqueezeDelivered("NONE", "NONE");
        };
        timer.Start();
    }

    /// <summary>
    /// The squeeze's answer, written ONCE. `delivered` is the client size the
    /// panel was actually given in PHYSICAL pixels (or `NONE` when nothing
    /// arrived); `policy` is what <see cref="SurfacePolicy.Decide"/> answered
    /// about it.
    ///
    /// ⚠️ IT IS A RECEIPT, NOT A VERDICT. If a zero client height turns out to
    /// be unreachable through an `OverlappedPresenter` -- the window manager's
    /// own minimum for a captioned window standing above
    /// `PreferredMinimumHeight` -- then O6.1's REFUSED row is unproducible by
    /// this route and the delivered height is what says so. The policy is NOT
    /// relaxed to make the assertion pass; a `Decide` that refused a height the
    /// window manager never sent would be an oracle agreeing with itself.
    /// </summary>
    private void ReportSqueezeDelivered(string delivered, string policy)
    {
        if (!_squeezePending) { return; }
        _squeezePending = false;
        // The deadline has done its job either way; a timer left running would
        // fire into a flag that is already false and read as a second answer.
        _squeezeTimer?.Stop();
        // The verdict prefix: on an `o6` squeeze run this receipt is the LAST
        // row of the run, so it is what the window title carries and what the
        // session-1 oracle reads (see Canvas.PaintAndHash). RUSTOK is about the
        // RECEIPT having been written, not about the squeeze having landed --
        // `delivered NONE` is a legitimate outcome and O6.1 is what prices it.
        Report($"RUSTOK SQUEEZE delivered {delivered} (requested height {_squeezeRequestedHeight}; "
             + $"min-height policy={_squeezeMinHeight}) policy={policy} {_canvas.Tids()}");
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

    /// <summary>
    /// A surface settled. Under `SB_SCENE=retained` that is not the end of a
    /// step -- the hash is.
    ///
    /// ⛔ THE STEP IS NOT ADVANCED FROM HERE UNDER `retained`, AND THAT IS A
    /// RACE THIS DESIGN HAD TO ANSWER. Posting the next `AppWindow.Resize` the
    /// moment the previous one settles lets the hash command and the next
    /// resize be drained in ONE batch -- and a batch paints once. The row would
    /// then carry the OLD step's label over the NEW step's pixels: a hash that
    /// looks perfectly well-formed and describes the wrong surface, which is the
    /// one failure O1 could not detect from its own rows.
    /// </summary>
    private void OnSurfaceSettled()
    {
        if (!_hashEveryStep || _resizeStep == 0)
        {
            DriveNextResize();
            return;
        }

        // The LABEL names the stop, not the ordinal, because the harness asserts
        // by name: `A'` is the return to `original` (O1's H2) and `H<i>` is the
        // i-th away size (H1). A list with more stops keeps numbering.
        var token = _resizeSteps[_resizeStep - 1];
        var label = string.Equals(token, "original", StringComparison.OrdinalIgnoreCase)
            ? "A'"
            : $"H{_resizeStep}";
        _awaitingStepHash = true;
        _canvas.Hash(label);
    }

    /// <summary>A hash row landed. Only a STEP's hash owes the next step.</summary>
    private void OnHashTaken()
    {
        if (!_awaitingStepHash) { return; }
        _awaitingStepHash = false;
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
    /// ⛔ AND THE TITLE CARRIES THE RUN'S VERDICT, NOT THIS ROW'S. It used to
    /// carry the row, which meant any caller that wrote no `RUSTOK `/`RUSTFAIL `
    /// blanked the oracle's verdict — three successful runs failed that way on
    /// kenai 2026-09-04, and there are twenty-odd such callers, not the three
    /// PR #118 prefixed by name. <see cref="TitleVerdict"/> holds the rule and
    /// `../sb_winui_tests/` drives it with no desktop; the STATUS LINE still
    /// shows this row alone, because a human at the window wants the row.
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

        // THE FOLD, NOT THE LAST ROW. `text` is what a human reads; the verdict
        // that reaches the title is the RUN's, so a row with no verdict on it
        // (`A'`, `UI-STALL DONE`, `SQUEEZE requesting …`, `DUMP`, `SCALE
        // CHANGED`, …) updates the text and leaves the verdict standing. The
        // fold is taken here, on the reporting thread and under the same lock as
        // the append, so the title cannot be composed from a half-updated value.
        //
        // ⛔ THE FOLD AND THE ENQUEUE ARE ONE CRITICAL SECTION. Composing under
        // the lock and enqueuing outside it would let two reporting threads
        // interleave — B composes and posts its title, then A posts the older
        // one it composed first — and the title the oracle reads would be a
        // STALE verdict. `TryEnqueue` neither blocks nor runs the callback
        // inline, so there is nothing here to deadlock against.
        lock (LogLock)
        {
            _titleVerdict = TitleVerdict.Fold(_titleVerdict, text);
            var title = TitleVerdict.Compose(VerifyTitle, _titleVerdict);
            _ui.TryEnqueue(() =>
            {
                Title = title;
                StatusLine.Text = text;
            });
        }
    }

    // =======================================================================
    // W4 — THE MENUBAR, MATERIALIZED
    //
    // ⛔ NOT ONE MENU ITEM IS AUTHORED HERE. The labels, shortcuts, dividers and
    // submenu titles come from `jas_menu_structure`; `enabled` and `checked`
    // come from `jas_menu_state`; the two are joined on `path`. This class
    // still calls no core function — it reads the JSON `Canvas` published and
    // turns it into WinUI controls, which is what "materializer" means.
    // =======================================================================

    /// <summary>
    /// The `Seq` of the snapshot currently drawn.
    ///
    /// ⭐ IT IS NOT A SOUVENIR — IT DETECTS A LOST NOTIFICATION. `Canvas.PostToUi`
    /// drops `TryEnqueue`'s bool and returns silently when the queue is null, so
    /// a menu announcement CAN vanish. The failure mode is a stale menubar with
    /// no diagnostic at all — an item enabled that should not be, which §7 stop 3
    /// is written about. A jump in `Seq` is the only evidence that would ever
    /// exist, so the row carries `missed=`.
    /// </summary>
    private long _menuDrawnSeq = 0;

    /// <summary>
    /// Shortcut specs this rebuild could not turn into an accelerator.
    ///
    /// ⛔ IT EXISTS BECAUSE THE REFUSAL HAD NO READER. Measured on kenai
    /// 2026-09-09: `MENU SHORTCUT UNPARSED 'Ctrl+='` and `'Ctrl+-'` are written
    /// TWICE PER REBUILD -- zoom-in and zoom-out have no keyboard accelerator
    /// on Windows. The refusal is the RIGHT behaviour (a wrong accelerator
    /// steals a keystroke silently) and it was announced only in a log line
    /// that nothing reads and no oracle looks at. ⇒ A producer needs a consumer
    /// that can red: the count goes on the MENU row, where P4 reads it, so the
    /// number CHANGING is visible instead of merely being printed.
    /// ⚠️ It is REPORTED, not asserted to be zero. Two are expected today and
    /// pinning that number would red the day a menubar gains an item.
    /// </summary>
    private int _shortcutsUnparsed = 0;

    /// <summary>
    /// A new menu reading arrived. Rebuild, on the UI thread, from the snapshot.
    ///
    /// ⛔ PUSHED, NOT POLLED, AND NEVER PER FRAME. This fires when the CORE's
    /// answer changes — startup, an open, a mutation — and `menu-rebuilds` on
    /// the row is what makes a regression to per-frame visible rather than
    /// merely slow (§7 stop 4).
    /// </summary>
    private void OnMenuChanged()
    {
        var snap = _canvas.Menu;
        if (snap is null) { return; }
        try
        {
            var (items, enabled) = BuildMenu(snap);

            // ⭐ P4's RECEIPT. `disabled` is on the row and not derived by a
            // reader, because the transition across an open is what catches a
            // shell that hard-codes `Save` as always-enabled — the one defect
            // the text gate explicitly cannot see.
            //
            // ⛔ `state-age=0` IS A CONSTANT HERE AND SAYS SO. The design block
            // budgeted a one-open staleness for an `Opening`-pull; this shell
            // is PUSHED, so the drawn snapshot is always the newest published
            // one. The field stays on the row rather than being dropped: a
            // reader comparing runs across the change needs to see that the
            // number went to zero, not that the column vanished.
            // A gap means a publication was announced and never arrived. Zero
            // is the expected reading and it is on every row, so the field can
            // be seen to be working rather than merely absent.
            var missed = snap.Seq - _menuDrawnSeq - 1;
            Report($"MENU rebuilds={snap.Seq} items={items} enabled={enabled} "
                 + $"disabled={items - enabled} seq={snap.Seq} state-age=0 "
                 + $"missed={(missed > 0 ? missed : 0)} "
                 + $"shortcuts-unparsed={_shortcutsUnparsed}");
            _menuDrawnSeq = snap.Seq;
        }
        catch (Exception ex)
        {
            // A menubar that failed to build must SAY so. A silently empty
            // MenuBar over a healthy status line is the ambiguous failure this
            // shell keeps refusing.
            Report($"RUSTFAIL MENU BUILD threw {ex.GetType().Name}: {ex.Message}");
        }
    }

    /// <summary>
    /// Join the two passes on `path` and materialize the result.
    ///
    /// The structure is a flat pre-order list of `{path, kind, id, label,
    /// action, shortcut, dynamic}`; the state is `{path, action, enabled,
    /// checked}`. A `path` of length 1 is a top-level menu, length 2 an entry in
    /// it, length 3 an entry in a submenu.
    /// </summary>
    private (int Items, int Enabled) BuildMenu(MenuSnapshot snap)
    {
        // PER REBUILD, not cumulative: the row reports what THIS menubar could
        // not attach, so two runs are comparable.
        _shortcutsUnparsed = 0;
        using var structure = System.Text.Json.JsonDocument.Parse(snap.StructureJson);
        // ⛔ NOT `state` — see the note in `Canvas.ApplyMenuRefresh`: that token
        // is the workspace context's own spelling and the materializer gate bans
        // it in shell code. The gate is right to be unable to tell a local from
        // the real thing.
        using var menuState = System.Text.Json.JsonDocument.Parse(snap.StateJson);

        // path -> enabled, from the DYNAMIC half. Absent means "the core did not
        // evaluate this node", which is true of menus, submenus and separators.
        var enabled = new Dictionary<string, bool>();
        foreach (var row in menuState.RootElement.EnumerateArray())
        {
            enabled[PathKey(row)] = row.TryGetProperty("enabled", out var e)
                                    && e.ValueKind == System.Text.Json.JsonValueKind.True;
        }

        Menu.Items.Clear();
        var items = 0;
        var onCount = 0;
        MenuBarItem? top = null;
        MenuFlyoutSubItem? sub = null;
        var subPath = "";

        foreach (var node in structure.RootElement.EnumerateArray())
        {
            var kind = node.GetProperty("kind").GetString();
            var path = node.GetProperty("path");
            var label = Str(node, "label");

            if (kind == "menu")
            {
                top = new MenuBarItem { Title = label ?? "" };
                Menu.Items.Add(top);
                sub = null;
                continue;
            }
            if (top is null) { continue; }

            // A node outside the open submenu closes it.
            //
            // ⛔ THE TRAILING COMMA IS LOAD-BEARING. Without it `"0,20"` starts
            // with `"0,2"`, so the 21st entry of a menu would be adopted as a
            // child of a submenu at index 2 — a prefix collision, which is the
            // shape this seat lost a sitting to once (`scale` matching inside
            // `composition-scale=`). Comparing depth-aware prefixes is what
            // makes this a path test rather than a string test.
            if (sub is not null && !PathKey(path).StartsWith(subPath + ",", StringComparison.Ordinal))
            {
                sub = null;
            }

            switch (kind)
            {
                case "separator":
                    AddTo(top, sub, new MenuFlyoutSeparator());
                    break;

                case "submenu":
                    var node_sub = new MenuFlyoutSubItem { Text = label ?? "" };
                    AddTo(top, sub, node_sub);
                    sub = node_sub;
                    subPath = PathKey(path);
                    break;

                case "item":
                    var action = Str(node, "action") ?? "";
                    var isOn = enabled.TryGetValue(PathKey(path), out var on) && on;
                    items++;
                    if (isOn) { onCount++; }
                    var item = new MenuFlyoutItem
                    {
                        Text = label ?? "",
                        // ⛔ THE BOOLEAN IS THE CORE'S. This shell evaluates no
                        // `enabled_when`; it reads the answer.
                        IsEnabled = isOn,
                    };
                    var accel = Accelerator(Str(node, "shortcut"));
                    if (accel is not null) { item.KeyboardAccelerators.Add(accel); }
                    item.Click += (_, _) => Invoke(action);
                    AddTo(top, sub, item);
                    break;

                default:
                    // `unknown` — the core refused to categorise a bundle node.
                    // Drawn as nothing and REPORTED, never as a divider.
                    Report($"MENU UNKNOWN NODE path={PathKey(path)} — the core would "
                         + "not categorise it; nothing was drawn for it");
                    break;
            }
        }
        return (items, onCount);
    }

    private static void AddTo(MenuBarItem top, MenuFlyoutSubItem? sub, MenuFlyoutItemBase item)
    {
        if (sub is not null) { sub.Items.Add(item); } else { top.Items.Add(item); }
    }

    private static string PathKey(System.Text.Json.JsonElement node)
    {
        var p = node.ValueKind == System.Text.Json.JsonValueKind.Array
            ? node
            : node.GetProperty("path");
        return string.Join(",", p.EnumerateArray().Select(x => x.GetInt32()));
    }

    private static string? Str(System.Text.Json.JsonElement node, string name) =>
        node.TryGetProperty(name, out var v)
        && v.ValueKind == System.Text.Json.JsonValueKind.String
            ? v.GetString()
            : null;

    /// <summary>
    /// `"Ctrl+Shift+S"` -> a `KeyboardAccelerator`, or null.
    ///
    /// ⛔ AN UNPARSEABLE SHORTCUT RETURNS NULL AND IS REPORTED, never guessed.
    /// A wrong accelerator is worse than none: it silently steals a keystroke
    /// from another control and the menu still looks right.
    /// </summary>
    private KeyboardAccelerator? Accelerator(string? spec)
    {
        if (string.IsNullOrWhiteSpace(spec)) { return null; }
        var mods = Windows.System.VirtualKeyModifiers.None;
        Windows.System.VirtualKey? key = null;
        foreach (var part in spec.Split('+', StringSplitOptions.RemoveEmptyEntries))
        {
            switch (part.Trim())
            {
                case "Ctrl": mods |= Windows.System.VirtualKeyModifiers.Control; break;
                case "Shift": mods |= Windows.System.VirtualKeyModifiers.Shift; break;
                case "Alt": mods |= Windows.System.VirtualKeyModifiers.Menu; break;
                default:
                    if (Enum.TryParse<Windows.System.VirtualKey>(part.Trim(), true, out var k)) { key = k; }
                    else if (part.Trim().Length == 1
                             && Enum.TryParse<Windows.System.VirtualKey>("Number" + part.Trim(), true, out var n))
                    {
                        key = n;
                    }
                    break;
            }
        }
        if (key is null)
        {
            _shortcutsUnparsed++;
            Report($"MENU SHORTCUT UNPARSED '{spec}' — no accelerator was attached, "
                 + "which is deliberate: a wrong one steals a keystroke silently");
            return null;
        }
        return new KeyboardAccelerator { Key = key.Value, Modifiers = mods };
    }

    // =======================================================================
    // W4 — WHAT A CLICK DOES (§3.1, re-cut at v1.2)
    // =======================================================================

    /// <summary>
    /// Dispatch by action id into a SMALL, EXPLICIT table.
    ///
    /// ⛔ EVERYTHING NOT IN IT IS REFUSED BY NAME. 64 of the 239 workspace
    /// actions have log-only effect lists, so a generic "run the action" path
    /// would report success and change nothing — the exact false success stop 1
    /// fired on. A menu item that looks live and does nothing is the defect
    /// `SB_SCENE_FINAL` was gated for.
    ///
    /// ⛔ AND THIS IS NOT AN EXPRESSION EVALUATOR. Dispatching a known id is not
    /// evaluating an `enabled_when`; the core decided what is enabled before
    /// this item was ever drawn.
    /// </summary>
    private void Invoke(string action)
    {
        switch (action)
        {
            case "undo":
                _canvas.Op("{\"op\":\"undo\"}", "undo");
                break;
            case "redo":
                _canvas.Op("{\"op\":\"redo\"}", "redo");
                break;
            case "open_file":
                OpenViaPicker();
                break;
            case "save":
            case "save_as":
                SaveDocument(action == "save_as");
                break;
            case "quit":
                _canvas.Quit();
                Close();
                break;
            default:
                Report($"ACTION UNIMPLEMENTED {action}");
                break;
        }
    }

    /// <summary>
    /// File ▸ Open… ⛔ §7 STOP 2 IS LIVE HERE AND IS NAMED ON THE ROW.
    ///
    /// WinAppSDK pickers need a window handle and, unpackaged, an
    /// initialisation call — UNMEASURED on the box. If the picker throws, the
    /// row says `open=PICKER-FAILED` and the fallback is `SB_OPEN_PATH` through
    /// the SAME code path. ⛔ Never a synthetic receipt wearing `PICKER`.
    /// </summary>
    private async void OpenViaPicker()
    {
        try
        {
            var picker = new Windows.Storage.Pickers.FileOpenPicker();
            WinRT.Interop.InitializeWithWindow.Initialize(
                picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
            picker.FileTypeFilter.Add(".svg");
            var file = await picker.PickSingleFileAsync();
            if (file is null)
            {
                Report("OPEN CANCELLED open=PICKER");
                return;
            }
            Report($"OPEN REQUESTED open=PICKER path={file.Path}");
            _canvas.Open(file.Path);
        }
        catch (Exception ex)
        {
            Report($"RUSTFAIL OPEN open=PICKER-FAILED {ex.GetType().Name}: {ex.Message} "
                 + "— set SB_OPEN_PATH to drive the same path without the picker");
        }
    }

    /// <summary>File ▸ Save / Save As. The path is the UI thread's; the bytes are the core's.</summary>
    private async void SaveDocument(bool forceAsk)
    {
        try
        {
            var path = forceAsk ? null : _savePath;
            if (path is null)
            {
                var picker = new Windows.Storage.Pickers.FileSavePicker();
                WinRT.Interop.InitializeWithWindow.Initialize(
                    picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
                picker.FileTypeChoices.Add("SVG", new List<string> { ".svg" });
                picker.SuggestedFileName = "drawing";
                var file = await picker.PickSaveFileAsync();
                if (file is null) { Report("SAVE CANCELLED save=PICKER"); return; }
                path = file.Path;
            }
            _savePath = path;
            _canvas.Save(path);
        }
        catch (Exception ex)
        {
            Report($"RUSTFAIL SAVE save=PICKER-FAILED {ex.GetType().Name}: {ex.Message} "
                 + "— set SB_SAVE_PATH to drive the same path without the picker");
        }
    }

    private string? _savePath = Environment.GetEnvironmentVariable("SB_SAVE_PATH");

    /// <summary>
    /// The document's dirty mark, folded into the TITLE VERDICT rather than
    /// written to <c>Title</c>.
    ///
    /// ⛔ A DIRECT WRITE HERE WOULD BE ERASED BY THE NEXT ROW. `Report`
    /// recomposes the whole title from `_titleVerdict` under `LogLock` and is
    /// called constantly, so a mark set outside that fold appears, flickers and
    /// vanishes — which reads as "implemented". The mark is appended by
    /// `TitleVerdict.Compose` AFTER the verdict, so the session-1 oracle's
    /// required `"&lt;name&gt; | RUSTOK"` substring is untouched. Both facts have
    /// arms in `sb_winui_tests`.
    /// </summary>
    private void OnDocumentDirtyChanged(bool dirty)
    {
        lock (LogLock)
        {
            _titleVerdict = TitleVerdict.WithDirty(_titleVerdict, dirty);
            var title = TitleVerdict.Compose(VerifyTitle, _titleVerdict);
            _ui.TryEnqueue(() => Title = title);
        }
    }
}
