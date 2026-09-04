using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Controls;
using Windows.Win32;
using Windows.Win32.Graphics.Direct3D;
using Windows.Win32.Graphics.Direct3D11;
using Windows.Win32.Graphics.Dxgi;
using Windows.Win32.Graphics.Dxgi.Common;
using WinRT;

namespace SbWinUi;

/// <summary>
/// <c>ISwapChainPanelNative</c>, hand-declared. MOVED HERE VERBATIM from
/// <c>SwapChainHost.cs</c>, which this file replaces.
///
/// The ONE interop type here that is not generated: it lives in Windows App SDK
/// metadata rather than Win32 metadata, so CsWin32 does not see it and
/// windows-rs has no binding for it either. One method, no inheritance beyond
/// IUnknown, so transcribing it carries none of the vtable-order risk that made
/// hand-writing IDXGIFactory2 a bad idea.
/// </summary>
[ComImport]
[Guid("63aad0b8-7c24-40ff-85a8-640d944cc325")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface ISwapChainPanelNative
{
    void SetSwapChain(IntPtr swapChain);
}

/// <summary>What <see cref="SurfacePolicy"/> answers about one proposed surface.</summary>
internal enum Decision
{
    /// <summary>A usable surface. Resize to it.</summary>
    Accept,

    /// <summary>A zero dimension AFTER a surface exists. Keep the last good one and SAY SO.</summary>
    Refuse,

    /// <summary>A zero dimension BEFORE a surface exists. Wait for the next layout pass.</summary>
    Defer,
}

/// <summary>
/// F-6's repair: THREE-VALUED, and the shell's only answer to a zero.
///
/// ⛔ WHAT IT REPLACES. `Math.Max(1, e.NewSize.Width)` sat at three sites in two
/// KINDS: the first-layout guard (`MainWindow.xaml.cs:83-84` at 3c8fddce, kept
/// because "creating a swapchain at 0x0 fails in a way that reads as a device
/// fault") and the two later-resize guards (`SwapChainHost.cs:180-181`, `:329-330`).
/// One spelling, two meanings, and the later one was a LIE: a window squeezed to
/// zero height was resized to 1 px and reported as a success, so the receipt
/// named a surface the user never had.
///
/// The two kinds are now two answers. Before a surface exists a zero is a
/// DEFERRAL -- refusing there bricks startup, because the panel genuinely has no
/// size until it is laid out. After one exists a zero is a REFUSAL: the last
/// good surface is kept, the swapchain is not touched, and the row says
/// `RESIZE REFUSED 1184x0 -- surface stays 1184x726`.
///
/// PURE, and that is what makes it testable without a window: `SB_SURFACE_PROBE`
/// drives this function directly (receipt `policy=PROBE`) while a real squeezed
/// window drives it through the window manager (receipt `policy=EVENT`). Two
/// routes, one decision procedure, and the probe is the control for the link
/// rather than a substitute for it.
/// </summary>
internal static class SurfacePolicy
{
    /// <summary>Decide one proposed surface. No side effects, no logging, no clamp.</summary>
    internal static Decision Decide(uint w, uint h, bool hasSurface)
    {
        if (w == 0 || h == 0)
        {
            return hasSurface ? Decision.Refuse : Decision.Defer;
        }
        return Decision.Accept;
    }
}

// ---------------------------------------------------------------------------
// THE COMMAND QUEUE'S VOCABULARY
// ---------------------------------------------------------------------------
//
// One class per verb rather than one class with a `kind` field: the drain has to
// treat Resize, Repaint and Pointer DIFFERENTLY (latch, collapse, never
// coalesce), and a switch over a tag would put that distinction in a comment.

internal abstract class Cmd
{
}

internal sealed class AttachCmd : Cmd
{
    internal uint Width;
    internal uint Height;
    internal float ScaleX;
    internal float ScaleY;
}

internal sealed class ResizeCmd : Cmd
{
    internal uint Width;
    internal uint Height;
    internal long ArrivedMs;
    internal string Source = "EVENT";
}

internal sealed class RepaintCmd : Cmd
{
    internal string Cause = "repaint";
}

internal sealed class PointerCmd : Cmd
{
    internal uint Kind;
    internal double X;
    internal double Y;
    internal uint Mods;
}

/// <summary>The counters a gesture accumulated on the UI thread, reported once the
/// core has seen its Release. `selected` can only be read where the engine lives.</summary>
internal sealed class PointerReportCmd : Cmd
{
    internal string Kind = "REAL";
    internal uint PointerId;
    internal string Device = "Unknown";
    internal string Hit = "PANEL";
    internal int Press;
    internal int Move;
    internal int Release;
    internal double PressX;
    internal double PressY;
    internal double ReleaseX;
    internal double ReleaseY;
}

internal sealed class LoadCmd : Cmd
{
    internal byte[] Svg = Array.Empty<byte>();
    internal string Label = "";
}

internal sealed class SceneCmd : Cmd
{
    internal string Scene = "";
}

internal sealed class DumpCmd : Cmd
{
    internal string Path = "";
}

internal sealed class HashCmd : Cmd
{
    internal string Label = "RETAINED";
}

internal sealed class DpiCmd : Cmd
{
    internal double Scale = 1.0;
}

internal sealed class QuitCmd : Cmd
{
}

/// <summary>
/// ⭐ THE RETAINED CANVAS. One object, one render thread, one engine.
///
/// WHAT IT REPLACES, AND WHY THE ONE-SHOT METHODS HAD TO GO. `SwapChainHost`
/// exposed `RenderFrame`, `RenderGoldens`, `RenderDocument` and
/// `RenderSelection`: four methods that each opened a workload, drew it and
/// returned, called SYNCHRONOUSLY FROM THE XAML THREAD -- `RenderFrame` from the
/// `Canvas.SizeChanged` handler. Three consequences, all measured:
///
///   * F-4 -- nothing was RETAINED. `RenderDocument` created an engine at entry
///     and freed it at exit, so after a resize there was no document to repaint;
///     the resize path repainted the PROBE.
///   * F-5 -- the resize path ran a 60-FRAME BENCHMARK. `SB_FRAMES` was read
///     inside `RenderFrame`, which the resize handler called: about 363 ms per
///     `SizeChanged` event at 984x526 (flask, kenai, N0b) for a frame the next
///     event would replace.
///   * F-3 -- every frame was painted and presented on the UI thread, so the
///     window could not pump messages while the core drew.
///
/// ⛔ AND BL2 IS WHY THIS IS A THREAD AND NOT A TASK. `ffi.rs:16-17`: "all calls
/// for a given engine must occur on the thread that created it. The core is
/// `Rc`-based and therefore not `Send`." A thread-pool continuation is a
/// DIFFERENT thread each time, so the engine would be called from many threads
/// and the ABI's one documented precondition would be violated on the happy
/// path. A dedicated `Thread` has a stable identity for the engine's whole life,
/// and that identity is printed on every receipt row (`render-tid=`), which is
/// how a reader checks the claim instead of believing it.
///
/// SO THE OWNERSHIP IS: the render thread owns the engine, the device, the
/// swapchain and the back buffer. The UI thread owns the panel and the window,
/// and its ONLY swapchain touch is `SetSwapChain` -- at handoff and again after
/// each successful `ResizeBuffers` -- posted FIRE-AND-FORGET. Nothing on either
/// side ever blocks on the other, because a wait in the resize path is the
/// deadlock the freeze names as stop 2.
/// </summary>
internal sealed unsafe class Canvas : IDisposable
{
    /// <summary>
    /// <c>D3D11_SDK_VERSION</c>, as a literal.
    ///
    /// CsWin32 does not generate it: the Win32 metadata carries it only as prose
    /// in the <c>D3D11CreateDevice</c> documentation, not as a constant. Written
    /// out with this note rather than silently, because a bare <c>7</c> in an
    /// interop call is exactly the kind of number a later reader cannot check.
    /// </summary>
    private const uint SdkVersion = 7;

    /// <summary>
    /// <c>DXGI_STATUS_OCCLUDED</c>, as a literal, for the same reason
    /// <c>SdkVersion</c> is one.
    ///
    /// FROM THE SDK ON THIS BOX -- winerror.h (10.0.22621.0, line 58184), under
    /// the heading "DXGI status (success) codes":
    ///
    ///   MessageText: The Present operation was invisible to the user.
    ///   #define DXGI_STATUS_OCCLUDED  _HRESULT_TYPEDEF_(0x087A0001L)
    ///
    /// A code whose documented meaning is "nobody saw this frame", filed by the
    /// platform as a SUCCESS. Its sign bit is clear, so <c>hr.Failed</c> is false
    /// and it must be tested for BY NAME or not at all.
    /// </summary>
    private const int StatusOccluded = unchecked((int)0x087A0001);

    /// <summary>How many resize arrival stamps one run's rows carry. See the use site.</summary>
    private const int ArrivalWindow = 200;

    /// <summary>
    /// How long the drain waits for the post-stall backlog before writing the
    /// STALL row with `resize-during-stall=none`.
    ///
    /// O3's resize is posted DURING the stall, so by the time the sleep ends the
    /// `ResizeCmd` is already queued and this timeout never fires. It exists so
    /// that a run where NOBODY resized still emits its STALL row instead of the
    /// render thread blocking in `Take()` with the row un-written -- a missing
    /// row and a `resize-during-stall=none` row look nothing alike, and only one
    /// of them can be read.
    /// </summary>
    private const int StallDrainGraceMs = 2000;

    /// <summary>
    /// How long <c>SB_PAINT_ON_UI</c>'s marshalled paint step waits for the
    /// UI thread before refusing BY NAME.
    ///
    /// ⚠️ THIS IS THE ONE PLACE THE RENDER THREAD WAITS ON THE DISPATCHER, and it
    /// exists only under the DESIGN-RED control knob. It is bounded because
    /// `SB_PAINT_ON_UI=1` and `SB_UI_STALL_MS=20000` together would otherwise
    /// hang: the thread that must run the paint is the thread that is asleep.
    /// The two controls answer different questions and are meant to be run
    /// separately; the bound is what makes running them together a REFUSAL
    /// instead of a hang somebody has to diagnose.
    /// </summary>
    private const int PaintOnUiWaitMs = 5000;

    /// <summary>
    /// ⚖️ O3's SECOND CONTROL, AND IT IS DESIGNED TO GO RED (FREEZE §2 O3(a)).
    ///
    /// `SB_PAINT_ON_UI=1` marshals the paint AND the present through the
    /// `DispatcherQueue`, so `paint-tid == present-tid == ui-tid` on every row
    /// and O3's residency assertion FAILS BY CONSTRUCTION. That is the whole
    /// point: it is §5 stop 1's named fallback made visible, so a reader can see
    /// what the tid assertion looks like when it is not satisfied, rather than
    /// trusting that a green one was ever capable of red.
    ///
    /// ⛔ A SWITCH INSIDE THE PAINT STEP, NEVER A SECOND PAINT PATH. Two code
    /// paths would drift, and the day they differed the control would be
    /// measuring the drift rather than the thread. Read ONCE into a static so a
    /// run cannot change its answer half way through.
    /// </summary>
    private static readonly bool PaintOnUi =
        Environment.GetEnvironmentVariable("SB_PAINT_ON_UI") == "1";

    // ---- the pump ---------------------------------------------------------

    private readonly BlockingCollection<Cmd> _queue = new();
    private readonly Action<string> _report;
    private Thread? _thread;
    private DispatcherQueue? _ui;

    /// <summary>
    /// The panel. Held so the post-resize re-bind can reach it, and TOUCHED ONLY
    /// INSIDE A <c>_ui.TryEnqueue</c> CALLBACK -- that is what makes holding it
    /// legal. `panel.As&lt;ISwapChainPanelNative&gt;()` is a XAML interop call and
    /// `SwapChainHost.cs:257` at 3c8fddce already said so ("Must happen on the UI
    /// thread"). The half of that sentence this design supersedes is the second
    /// one, "so must every later Present" -- decided at the machine, never
    /// assumed (FREEZE §5 stop 1).
    /// </summary>
    private SwapChainPanel? _panel;

    // ---- the device, the swapchain, the surface ----------------------------

    private ID3D11Device? _device;
    private ID3D11DeviceContext? _immediate;
    private ID3D11Texture2D? _offscreen;
    private ID3D11Resource? _offscreenRes;
    private IDXGISwapChain1? _swapChain;

    // NO Marshal.ReleaseComObject ANYWHERE IN THE FRAME PATH, and that is a fix
    // rather than a style choice. Over sixty frames it corrupted the heap: the
    // host died with 0xC0000374 in ntdll. ReleaseComObject decrements a
    // reference the runtime is also tracking, so pairing it with an explicit
    // Marshal.Release double-releases. The RCW's own reference belongs to the
    // runtime; only the pointer taken by GetIUnknownForObject belongs to us.

    /// <summary>
    /// The swapchain's raw IUnknown, taken ONCE on the render thread and handed
    /// to the UI thread as a bare pointer.
    ///
    /// ⭐ A POINTER, NOT THE RCW, AND THAT IS THE CROSS-THREAD DECISION. Passing
    /// the managed RCW to the UI thread would put a COM object's lifetime in the
    /// hands of two threads' marshalling rules; passing the interface pointer
    /// does not, because DXGI objects are free-threaded and `SetSwapChain`
    /// addrefs whatever it keeps. Released once, in <see cref="Dispose"/>.
    /// </summary>
    private IntPtr _swapChainUnknown;

    private uint _width;
    private uint _height;
    private float _scaleX = 1f;
    private float _scaleY = 1f;

    /// <summary>
    /// Written on the render thread, read on the UI thread by
    /// <c>SurfacePolicy.Decide</c>'s `hasSurface` argument. `volatile` rather
    /// than locked: it is one bit that only ever goes false -> true, and the
    /// worst a stale read can do is DEFER one event that could have been
    /// refused -- which the next `SizeChanged` corrects, and which the receipt
    /// names (`policy=DEFER`) rather than hiding.
    /// </summary>
    private volatile bool _hasSurface;

    // ---- the retained document (coat 1) -----------------------------------

    /// <summary>
    /// THE ENGINE, CREATED ONCE AND HELD. `jas_engine_new` at Attach,
    /// `jas_engine_free` at Quit, both on the render thread (BL2).
    ///
    /// ⚖️ THE FORK, AS THE FREEZE DECIDED IT (§1.1): what the shell retains is the
    /// ENGINE HANDLE, not a display list. `jas_paint_document` exists precisely
    /// to REMOVE the display-list round trip (`ffi_paint.rs:648`), and BL1 says
    /// the shell holds a handle and never a document. So coat 1 is "the engine
    /// held once across resize, paint and input", and O1 proves IDENTITY from the
    /// core's own `EngineNew`/`EngineFree` crossings rather than from appearance.
    /// </summary>
    private IntPtr _engine;

    /// <summary>
    /// How many times THIS SHELL called <c>jas_load_svg</c>.
    ///
    /// ⚠️ LABELLED `loads(shell)` ON EVERY ROW BECAUSE IT IS NOT THE ORACLE.
    /// There is no `LoadSvg` crossing in the core (`ffi_instr.rs:56-73` carries
    /// eleven variants and none of them is a load; `ffi_paint.rs:506` records
    /// nothing), so this is the shell counting itself -- exactly the shape a
    /// reload-per-resize shell could lie about. O1's identity clause reads the
    /// CORE's `engines-created`/`engines-freed` instead, and its mutation clause
    /// catches the reload-on-a-held-engine shape that no counter here can see.
    /// </summary>
    private int _loadsShell;

    // ---- thread identity, on every row ------------------------------------

    private int _uiTid;
    private int _renderTid;
    private int _paintTid;
    private int _presentTid;
    private bool _renderHasDispatcher = true;

    // ---- the resize census (O2) -------------------------------------------

    private long _eventsTotal;
    private readonly HashSet<string> _distinctSizes = new();
    private readonly List<long> _arrivals = new();
    private long _firstArrivalMs = -1;

    /// <summary>Set by a <see cref="HashCmd"/>; consumed by the next paint.</summary>
    private string? _hashLabel;

    // ---- N3's scenes: the latches the drain has to know about --------------
    //
    // ⛔ EVERY ONE OF THESE IS TOUCHED ONLY ON THE RENDER THREAD. They are the
    // state that makes `stall` and `pointer` observable WITHOUT blocking the
    // pump: a scene that waited for a hand by sleeping inside `ApplyScene`
    // would be waiting on a queue only it can drain, so the hand's own events
    // would never arrive. Both waits are therefore LATCHES plus a bounded
    // `TryTake` at the head of the loop.

    /// <summary>True once a present has succeeded. O3's DXGI eye is timed against
    /// the FIRST worker-thread present, so that present is named in the log.</summary>
    private bool _firstPresentSeen;

    /// <summary>ms the NEXT <see cref="RepaintOnce"/> sleeps for, then zeroed.</summary>
    private int _stallMs;

    /// <summary>The stall that actually happened, and the thread that slept.</summary>
    private int _stallSlept;
    private int _stallTid;
    private int _uiStallMs;

    /// <summary>Set when a render stall ENDS; cleared when the STALL row is written
    /// by the drain that applied the post-stall resize (or by the grace timeout).</summary>
    private bool _stallArmed;

    /// <summary>The LATEST size requested by a Resize in the drain being applied.</summary>
    private string _lastResizeRequested = "none";

    /// <summary>`TickCount64` after which a waited-for hand is `NOT RUN`. -1 = not waiting.</summary>
    private long _handDeadlineMs = -1;

    /// <summary>Which scene is waiting for the hand (`retained` or `pointer`).</summary>
    private string _handScene = "";

    /// <summary>How long the wait was asked to be, for the refusal's own text.</summary>
    private int _handWaitMs;

    /// <summary>A press arrived while waiting, so a timeout is a DIFFERENT refusal.</summary>
    private bool _handPressSeen;

    /// <summary>The scene posted <see cref="SceneCompleted"/> itself -- EARLY (`stall`,
    /// so the harness can resize DURING the stall) or LATE (`pointer`/`retained`
    /// waiting for a hand). <see cref="ApplyScene"/>'s `finally` must then not post
    /// a second one.</summary>
    private bool _scenePostsItsOwnCompletion;

    public string LastStatus { get; private set; } = "not started";

    public string Adapter { get; private set; } = "unknown";

    public string DebugLayer { get; private set; } = "off";

    /// <summary>The last resize, split into its three parts. "not resized" until one happens.</summary>
    public string ResizeCost { get; private set; } = "not resized";

    public uint Width => _width;

    public uint Height => _height;

    public bool HasSurface => _hasSurface;

    /// <summary>
    /// Raised ON THE UI THREAD after a drain that applied a resize, so a caller
    /// driving a LIST of sizes (`SB_RESIZE=1000x600,original`) can post the next
    /// step when the previous one has actually landed -- rather than sleeping,
    /// which measures the sleep.
    /// </summary>
    internal Action? SurfaceSettled { get; set; }

    /// <summary>
    /// Raised ON THE UI THREAD once a scene has run to completion on the render
    /// thread -- including the paths that refuse. The window uses it to drive the
    /// probe, the squeeze and the `SB_RESIZE` list, none of which may fire before
    /// the surface exists: `Attach` is asynchronous now, so a probe posted
    /// straight after it would read `hasSurface == false` and print DEFER on a
    /// row about a surface that exists.
    /// </summary>
    internal Action? SceneCompleted { get; set; }

    /// <summary>
    /// Raised ON THE UI THREAD after a hash row has been written. O1's
    /// `SB_RESIZE` walk steps on THIS and not on <see cref="SurfaceSettled"/>:
    /// the previous stop is not finished when its surface settles, it is
    /// finished when its hash has been taken.
    /// </summary>
    internal Action? HashTaken { get; set; }

    /// <summary>
    /// OFFSCREEN mode: Rust paints a texture WE own, and we copy it into the back
    /// buffer. DIRECT mode: Rust paints the back buffer itself.
    ///
    /// Both are legitimate designs, not a workaround and a real one. Direct is
    /// zero-copy and is what the variant wants; offscreen costs one full-surface
    /// GPU copy per frame and is what every compositor-hosted renderer that
    /// cannot touch the swapchain does.
    /// </summary>
    public static bool OffscreenMode =>
        Environment.GetEnvironmentVariable("SB_MODE") != "direct";

    internal Canvas(Action<string> report)
    {
        _report = report;
    }

    // =======================================================================
    // THE UI-THREAD SURFACE. Everything below this line ENQUEUES and returns.
    // =======================================================================

    /// <summary>
    /// Start the render thread and hand it a surface to build.
    ///
    /// ⛔ THE SPLIT IS THE POINT (FREEZE §1.3 / A7). `panel.CompositionScaleX/Y`
    /// and `panel.As&lt;ISwapChainPanelNative&gt;()` are XAML-object touches and
    /// belong to the UI thread; `D3D11CreateDevice` and
    /// `CreateSwapChainForComposition` do not. So the scale is read HERE, on the
    /// XAML thread, and crosses as two SCALARS; the render thread never receives
    /// a `panel` parameter it could dereference. The `DispatcherQueue` is
    /// captured HERE too, BEFORE the thread starts -- `GetForCurrentThread()` on
    /// the render thread returns null by design, and that null is asserted on
    /// every receipt row as `render-has-dispatcher=false`.
    /// </summary>
    internal bool Attach(DispatcherQueue ui, SwapChainPanel panel, uint width, uint height,
                         float scaleX, float scaleY)
    {
        var decision = SurfacePolicy.Decide(width, height, _hasSurface);
        if (decision != Decision.Accept)
        {
            // A zero at first layout is a DEFERRAL, not a refusal: the panel has
            // no size until it is laid out, and refusing here bricks startup.
            LastStatus = $"attach {width}x{height}: {decision}";
            _report($"RESIZE DEFERRED {width}x{height} — no surface yet policy=DEFER {Tids()}");
            return false;
        }

        _ui = ui;
        _panel = panel;
        _uiTid = Environment.CurrentManagedThreadId;
        _scaleX = scaleX <= 0 ? 1f : scaleX;
        _scaleY = scaleY <= 0 ? 1f : scaleY;

        _thread = new Thread(RenderLoop)
        {
            IsBackground = true,
            Name = "jas-render",
        };
        _thread.Start();
        _queue.Add(new AttachCmd { Width = width, Height = height, ScaleX = _scaleX, ScaleY = _scaleY });
        return true;
    }

    /// <summary>
    /// Ask for a new surface size. Decided, then ENQUEUED -- never applied here.
    ///
    /// The second door, and it decides again on purpose. The `SizeChanged`
    /// handler decides so it can name the POLICY SOURCE on the receipt
    /// (`policy=EVENT` vs `policy=PROBE`); this decides because it is the only
    /// path to `ResizeBuffers` and a gate that trusts its caller is not a gate.
    /// `Decide` is pure, so deciding twice cannot disagree with itself.
    /// </summary>
    internal bool Resize(uint width, uint height, string source)
    {
        var decision = SurfacePolicy.Decide(width, height, _hasSurface);
        if (decision != Decision.Accept)
        {
            _report($"RESIZE REFUSED {width}x{height} — surface stays {_width}x{_height} "
                  + $"policy=CANVAS source={source} {Tids()}");
            return false;
        }
        _queue.Add(new ResizeCmd
        {
            Width = width,
            Height = height,
            ArrivedMs = Environment.TickCount64,
            Source = source,
        });
        return true;
    }

    internal void Repaint(string cause) => _queue.Add(new RepaintCmd { Cause = cause });

    internal void Scene(string scene) => _queue.Add(new SceneCmd { Scene = scene });

    internal void Load(byte[] svg, string label) => _queue.Add(new LoadCmd { Svg = svg, Label = label });

    internal void Pointer(uint kind, double x, double y, uint mods) =>
        _queue.Add(new PointerCmd { Kind = kind, X = x, Y = y, Mods = mods });

    internal void PointerReport(PointerReportCmd report) => _queue.Add(report);

    internal void SetDpiScale(double scale) => _queue.Add(new DpiCmd { Scale = scale });

    /// <summary>
    /// Dump the retained document as canonical test JSON. A QUEUE COMMAND, and
    /// that is BL2 rather than tidiness: `jas_document_json` is a call for this
    /// engine and must happen on the thread that created it, whichever thread is
    /// convenient for the harness.
    /// </summary>
    internal void Dump(string path) => _queue.Add(new DumpCmd { Path = path });

    /// <summary>Paint once and hash the back buffer BEFORE presenting it (O1).</summary>
    internal void Hash(string label) => _queue.Add(new HashCmd { Label = label });

    internal void Quit() => _queue.Add(new QuitCmd());

    /// <summary>
    /// THREAD IDENTITY, ON EVERY ROW (FREEZE §1.3 / A3).
    ///
    /// ⛔ `Responding=True` IS NOT RESIDENCY. Any non-UI thread satisfies it --
    /// including §5 stop 1's own fallback, where the render thread paints and the
    /// UI thread presents. So residency is proven by IDS, each captured AT ITS
    /// OWN SITE, and O3 asserts `paint-tid == present-tid == render-tid != ui-tid`
    /// on every row. `render-has-dispatcher=false` is the same claim from the
    /// other side: a thread WinUI knows nothing about has no dispatcher queue.
    /// </summary>
    internal string Tids() =>
        $"ui-tid={_uiTid} render-tid={_renderTid} paint-tid={_paintTid} present-tid={_presentTid} "
        + $"render-has-dispatcher={(_renderHasDispatcher ? "true" : "false")}";

    public void Dispose()
    {
        try { _queue.CompleteAdding(); } catch (ObjectDisposedException) { }
    }

    // =======================================================================
    // THE RENDER THREAD. Nothing below this line runs on the XAML thread.
    // =======================================================================

    /// <summary>
    /// ⭐ THE DRAIN, AND ITS SHAPE IS A CORRECTNESS CLAUSE (FREEZE §1.3 / A5).
    ///
    /// ONE blocking <c>Take()</c>, then <c>TryTake()</c> TO EXHAUSTION. The
    /// obvious spelling -- `foreach (var c in _queue.GetConsumingEnumerable())` --
    /// takes ONE item per pass, which is a repaint per pointer event: F-5's shape
    /// at a new scale, and no text gate can see it. With this shape a drag's
    /// whole backlog is applied in ONE pass and costs ONE frame, so latency is
    /// bounded by a drain period.
    ///
    /// THE BATCH IS APPLIED IN ENQUEUE ORDER, and only CONSECUTIVE resizes latch.
    /// Sorting resizes to the front would let a Move be applied after its
    /// Release -- a gesture reordered into nonsense -- so the order is the
    /// contract and the coalescing is what fits inside it.
    /// </summary>
    private void RenderLoop()
    {
        _renderTid = Environment.CurrentManagedThreadId;

        // The claim `render-has-dispatcher=false`, MEASURED at the site rather
        // than asserted in a comment. A render thread that somehow had a
        // dispatcher would be a thread WinUI is pumping, and every residency
        // reading below would be about a different thread than the one named.
        _renderHasDispatcher = DispatcherQueue.GetForCurrentThread() is not null;

        try
        {
            while (true)
            {
                Cmd first = null!;
                bool got;

                // ⛔ THE HEAD OF THE LOOP IS BOUNDED ONLY WHEN A LATCH IS ARMED,
                // and never otherwise. A poll would burn a core and, worse,
                // would make "the pump is alive" unfalsifiable: an idle render
                // thread MUST block, so that a run in which nothing arrives is
                // visibly a run in which nothing arrived. The two armed waits --
                // the post-stall backlog and a scene waiting for a real hand --
                // are the only cases where the ABSENCE of a command is itself
                // the measurement, and each writes its own row when it fires.
                var timeout = PendingTimeoutMs();
                try
                {
                    if (timeout < 0)
                    {
                        first = _queue.Take();
                        got = true;
                    }
                    else
                    {
                        got = _queue.TryTake(out first, timeout);
                    }
                }
                catch (Exception)
                {
                    // CompleteAdding + empty, or disposed. Either way there is
                    // nothing left to drain and the loop is done.
                    break;
                }

                if (!got)
                {
                    FlushArmedTimeouts();
                    continue;
                }

                var batch = new List<Cmd> { first };
                while (_queue.TryTake(out var more))
                {
                    batch.Add(more);
                }

                if (!ApplyBatch(batch))
                {
                    break;
                }
            }
        }
        catch (Exception ex)
        {
            _report($"RUSTFAIL render thread died: {ex.GetType().Name}: {ex.Message} {Tids()}");
        }
        finally
        {
            // ONE free, at the end of the thread that made it (BL2). A process
            // exiting would release the memory anyway; the point is that the
            // COUNT is right, because O1 reads `engines-freed` from the core.
            if (_engine != IntPtr.Zero)
            {
                JasCore.jas_engine_free(_engine);
                _engine = IntPtr.Zero;
            }
            // Our own reference on the swapchain, released on the thread that
            // took it. `SetSwapChain` addrefs whatever it keeps, so the panel's
            // reference is not this one and the panel does not go dark first.
            if (_swapChainUnknown != IntPtr.Zero)
            {
                Marshal.Release(_swapChainUnknown);
                _swapChainUnknown = IntPtr.Zero;
            }
        }
    }

    /// <summary>Apply one drained batch. Returns false when a Quit was seen.</summary>
    private bool ApplyBatch(List<Cmd> batch)
    {
        var dirty = false;
        var cause = "repaint";
        var resizes = 0;
        var applied = false;

        for (var i = 0; i < batch.Count; i++)
        {
            switch (batch[i])
            {
                case QuitCmd _:
                    return false;

                case AttachCmd a:
                    ApplyAttach(a);
                    break;

                case ResizeCmd r:
                    _eventsTotal++;
                    _distinctSizes.Add($"{r.Width}x{r.Height}");
                    // The LATEST requested size in this drain, for O3's
                    // `resize-during-stall` field. It is what was ASKED FOR;
                    // `painted-after-stall` is what the surface became, and the
                    // two are different questions (a window size is not a
                    // surface size -- the whole reason `original` is a sentinel).
                    _lastResizeRequested = $"{r.Width}x{r.Height}";
                    if (_firstArrivalMs < 0) { _firstArrivalMs = r.ArrivedMs; }
                    // BOUNDED, and the bound is named on the row. `arrivals` is
                    // an inter-arrival SERIES for O2 to read a drag's cadence
                    // from; an unbounded one would make one log line grow past
                    // what a receipt can carry on a long drag. The count is
                    // `events_total`, which is never truncated -- so a reader can
                    // always tell a truncated series from a short one.
                    if (_arrivals.Count < ArrivalWindow) { _arrivals.Add(r.ArrivedMs - _firstArrivalMs); }
                    resizes++;
                    // ⭐ THE LATCH, AND IT IS DELIBERATELY LOCAL. Only a run of
                    // CONSECUTIVE resizes collapses: if the next command is
                    // another Resize, this one is superseded and never reaches
                    // the swapchain. A Resize with a Pointer behind it is
                    // applied, because the pointer's coordinates are in the
                    // surface this resize creates.
                    if (i + 1 < batch.Count && batch[i + 1] is ResizeCmd)
                    {
                        break;
                    }
                    if (ApplyResize(r))
                    {
                        dirty = true;
                        cause = "resize";
                        applied = true;
                    }
                    break;

                case RepaintCmd rp:
                    // MANY COLLAPSE TO ONE. A repaint is idempotent, so a
                    // backlog of them describes one frame.
                    dirty = true;
                    if (cause == "repaint") { cause = rp.Cause; }
                    break;

                case PointerCmd p:
                    // IN ORDER, NEVER COALESCED. A tool's `on_move` is a state
                    // machine; dropping intermediate moves changes what the
                    // gesture MEANS, which is not the shell's to decide (BL1).
                    ApplyPointer(p);
                    dirty = true;
                    cause = "pointer";
                    break;

                case PointerReportCmd pr:
                    ApplyPointerReport(pr);
                    break;

                case LoadCmd l:
                    _report(ApplyLoad(l)
                        ? $"RUSTOK {LastStatus} {Tids()}"
                        : $"RUSTFAIL {LastStatus} {Tids()}");
                    dirty = true;
                    cause = "load";
                    break;

                case SceneCmd s:
                    ApplyScene(s.Scene);
                    break;

                case DumpCmd d:
                    ApplyDump(d.Path);
                    break;

                case HashCmd h:
                    _hashLabel = h.Label;
                    dirty = true;
                    break;

                case DpiCmd dp:
                    if (_engine != IntPtr.Zero) { JasCore.jas_set_dpi_scale(_engine, dp.Scale); }
                    break;
            }
        }

        if (dirty && _swapChain is not null)
        {
            // ONE frame per drain. That is what removes F-5: sixty frames per
            // event becomes one frame per BATCH of events.
            RepaintOnce(cause, resizes);
        }

        // O3's row, written HERE and not at the end of the sleep, because the
        // two facts it has to carry -- what was requested during the stall and
        // what was actually painted after it -- are not both known until the
        // post-stall drain has run. A row written earlier would have to say
        // `pending` in the field the oracle reads.
        if (_stallArmed && resizes > 0)
        {
            FlushStallRow(resizes, _lastResizeRequested);
        }

        if (applied)
        {
            PostToUi(() => SurfaceSettled?.Invoke());
        }
        return true;
    }

    /// <summary>
    /// How long the head of the loop may wait, or -1 to block forever.
    ///
    /// ⛔ NO CLAMP HELPER, DELIBERATELY (FREEZE §1.5 / O2b). A past deadline
    /// yields 0 -- "take whatever is already there, then fire" -- written as an
    /// `if`, because `Math.Max` is banned in this shell as a whole identifier
    /// and the ban is on the SHAPE, not on the three sites F-6 found.
    /// </summary>
    private int PendingTimeoutMs()
    {
        if (_stallArmed) { return StallDrainGraceMs; }
        if (_handDeadlineMs >= 0)
        {
            var left = _handDeadlineMs - Environment.TickCount64;
            if (left < 0) { return 0; }
            if (left > int.MaxValue) { return int.MaxValue; }
            return (int)left;
        }
        return -1;
    }

    /// <summary>
    /// A bounded wait expired with nothing in the queue. Each armed latch writes
    /// its OWN row -- silence is never the answer.
    /// </summary>
    private void FlushArmedTimeouts()
    {
        if (_stallArmed)
        {
            FlushStallRow(0, "none");
            return;
        }
        if (_handDeadlineMs < 0) { return; }

        // ⛔ NEVER A SYNTHETIC RECEIPT WEARING `REAL` (FREEZE §5 stop 4). The
        // hand did not arrive, so the scene is NOT RUN and says why. The two
        // refusals are DIFFERENT facts and are not merged: "no press at all"
        // means the injector never reached the window (UIPI is undetectable at
        // the injector, per the SendInput page); "pressed and never released"
        // means it did reach it and the gesture was left open.
        var scene = _handScene;
        var waited = _handWaitMs;
        var pressed = _handPressSeen;
        _handDeadlineMs = -1;
        _handScene = "";
        _handPressSeen = false;

        LastStatus = pressed
            ? $"NOT RUN: hand refused (pressed but never released within {waited}ms)"
            : $"NOT RUN: hand refused (no press within {waited}ms)";
        _report($"{LastStatus} scene={scene} surface={_width}x{_height} {Tids()}");
        PostToUi(() => SceneCompleted?.Invoke());
    }

    /// <summary>O3's one row, written once. A second call is a no-op.</summary>
    private void FlushStallRow(int resizes, string requested)
    {
        if (!_stallArmed) { return; }
        _stallArmed = false;
        _report($"STALL render-stall={_stallSlept}ms stall-tid={_stallTid} "
              + $"ui-stall={_uiStallMs}ms resize-during-stall={requested} "
              + $"resizes-in-drain={resizes} painted-after-stall={_width}x{_height} "
              + $"{Tids()}");
    }

    /// <summary>
    /// Name the FIRST present in the log, once (FREEZE §2 O3's DXGI-eye clause).
    ///
    /// The camera is a GATE for exactly one row -- the first worker-thread
    /// present in the `retained` scene -- because the realistic failure there is
    /// S-OK-SHAPED: every call succeeds and the panel shows a stale or blank
    /// surface. A capture is only evidence if the harness knows WHICH present it
    /// is a photograph of, so the present announces itself with the surface it
    /// put up and the thread that put it there.
    ///
    /// ⚠️ EMITTED FROM <see cref="RepaintOnce"/> ONLY, which is the only present
    /// path the `retained` scene takes. The one-shot scenes (`goldens`,
    /// `document`, `selection-marquee`) present through their own loops and do
    /// NOT emit this row -- said here so its absence from those runs is not read
    /// as a present that did not happen.
    /// </summary>
    private void MarkFirstPresent()
    {
        if (_firstPresentSeen) { return; }
        _firstPresentSeen = true;
        _report($"FIRST-PRESENT surface={_width}x{_height} "
              + $"paint-on-ui={(PaintOnUi ? "1" : "0")} {Tids()}");
    }

    /// <summary>
    /// Run one paint step ON THE UI THREAD and wait for it. Returns null on
    /// success, or the refusal text.
    ///
    /// ⚠️ THE ONE RENDER-SIDE WAIT IN THIS SHELL, AND IT IS THE CONTROL'S OWN
    /// MECHANISM. Everywhere else the render thread posts fire-and-forget,
    /// because a wait in the resize path is the freeze's stop 2 by a second
    /// door. Here the wait IS the design being demonstrated -- the paint has to
    /// have finished before the row that names its thread is written -- so it is
    /// bounded, and a UI thread that does not run the step within
    /// <see cref="PaintOnUiWaitMs"/> is a REFUSAL with a name rather than a hang.
    ///
    /// The event is deliberately NOT disposed: on the timeout path the UI thread
    /// may still be about to `Set()` it, and disposing under that race turns a
    /// clean refusal into an `ObjectDisposedException` on the wrong thread.
    /// </summary>
    private string? RunPaintStepOnUi(Action step)
    {
        var ui = _ui;
        if (ui is null) { return "SB_PAINT_ON_UI: there is no dispatcher to marshal to"; }

        var done = new ManualResetEventSlim(false);
        string? threw = null;
        var queued = ui.TryEnqueue(() =>
        {
            try { step(); }
            catch (Exception ex) { threw = $"{ex.GetType().Name}: {ex.Message}"; }
            finally { done.Set(); }
        });
        if (!queued) { return "SB_PAINT_ON_UI: the dispatcher refused the paint step"; }
        if (!done.Wait(PaintOnUiWaitMs))
        {
            return $"SB_PAINT_ON_UI: the UI thread did not run the paint step within "
                 + $"{PaintOnUiWaitMs}ms (is SB_UI_STALL_MS set on the same run?)";
        }
        return threw;
    }

    /// <summary>
    /// Create the device and the composition swapchain, then create the engine.
    ///
    /// SCALARS ONLY: no `panel` crosses to this thread. The bind that DOES need
    /// the panel is posted back to the UI thread, fire-and-forget.
    /// </summary>
    private void ApplyAttach(AttachCmd a)
    {
        _width = a.Width;
        _height = a.Height;
        _scaleX = a.ScaleX;
        _scaleY = a.ScaleY;

        // BGRA_SUPPORT is REQUIRED for Direct2D interop, and omitting it fails
        // later and elsewhere: the device creates fine and D2D refuses the
        // surface, which reads as a D2D fault rather than a device flag.
        // DEBUG LAYER FIRST, falling back if it is not installed. The layer is an
        // optional Windows feature, so its absence must not become the failure --
        // but with it, D3D states the REASON a call was rejected instead of
        // leaving an HRESULT to be guessed at.
        const D3D11_CREATE_DEVICE_FLAG bgra = D3D11_CREATE_DEVICE_FLAG.D3D11_CREATE_DEVICE_BGRA_SUPPORT;
        var flags = bgra | D3D11_CREATE_DEVICE_FLAG.D3D11_CREATE_DEVICE_DEBUG;
        DebugLayer = "on";

        // WARP fallback so a box with no usable GPU produces a slow frame rather
        // than an unexplained device failure. The Rust-side tests use WARP for
        // the same reason.
        var hr = PInvoke.D3D11CreateDevice(
            null, D3D_DRIVER_TYPE.D3D_DRIVER_TYPE_HARDWARE, default, flags, default,
            SdkVersion, out var device, out var immediate);
        if (hr.Failed)
        {
            // Almost certainly the debug layer missing; retry without it.
            flags = bgra;
            DebugLayer = "unavailable";
            hr = PInvoke.D3D11CreateDevice(
                null, D3D_DRIVER_TYPE.D3D_DRIVER_TYPE_HARDWARE, default, flags, default,
                SdkVersion, out device, out immediate);
        }
        Adapter = "hardware";
        if (hr.Failed)
        {
            PInvoke.D3D11CreateDevice(
                null, D3D_DRIVER_TYPE.D3D_DRIVER_TYPE_WARP, default, flags, default,
                SdkVersion, out device, out immediate).ThrowOnFailure();
            Adapter = "warp";
        }
        _device = device;
        _immediate = immediate;

        // The factory comes FROM the device rather than from CreateDXGIFactory2,
        // so the swapchain is guaranteed to be on the same adapter as the device
        // that draws into it. A mismatch there produces a black panel and no
        // error, which is the failure shape this whole branch exists to refuse.
        ((IDXGIDevice)_device).GetAdapter(out var adapter);
        adapter.GetParent<IDXGIFactory2>(out var factory);

        var desc = new DXGI_SWAP_CHAIN_DESC1
        {
            Width = _width,
            Height = _height,
            Format = DXGI_FORMAT.DXGI_FORMAT_B8G8R8A8_UNORM,
            Stereo = false,
            SampleDesc = new DXGI_SAMPLE_DESC { Count = 1, Quality = 0 },
            BufferUsage = DXGI_USAGE.DXGI_USAGE_RENDER_TARGET_OUTPUT,
            // Two buffers and a FLIP model: composition swapchains REQUIRE flip,
            // and MSAA is not permitted, which is why SampleDesc is 1/0. It is
            // also why O1's hash needs NO TOLERANCE: there is no multisample
            // resolve to introduce a machine-dependent bit.
            BufferCount = 2,
            Scaling = DXGI_SCALING.DXGI_SCALING_STRETCH,
            SwapEffect = DXGI_SWAP_EFFECT.DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL,
            AlphaMode = DXGI_ALPHA_MODE.DXGI_ALPHA_MODE_PREMULTIPLIED,
            Flags = 0,
        };

        factory.CreateSwapChainForComposition(_device, in desc, null, out var swapChain);
        _swapChain = swapChain;

        // Same rule as Resize: the direct route never touches this surface.
        if (OffscreenMode) { CreateOffscreenTarget(); }

        _swapChainUnknown = Marshal.GetIUnknownForObject(_swapChain);
        _hasSurface = true;

        // ⛔ THE ENGINE IS CREATED HERE, ON THIS THREAD, AND EXACTLY ONCE. Coat 1.
        _engine = JasCore.jas_engine_new();
        if (_engine == IntPtr.Zero)
        {
            LastStatus = "ATTACH FAILED: the core would not create a session";
            _report($"RUSTFAIL {LastStatus} {Tids()}");
            return;
        }
        JasCore.jas_set_dpi_scale(_engine, _scaleX);
        // TOOL 0 (selection) IS THE ONLY TOOL THIS WAVE. `SB_TOOL != 0` is
        // refused by name in the window, not silently ignored here.
        JasCore.jas_set_tool(_engine, 0);

        BindPanelFromRenderThread();
        LastStatus = $"attached {SurfaceLabel()} on {Adapter}";
    }

    /// <summary>
    /// Post the `SetSwapChain` to the UI thread and RETURN IMMEDIATELY.
    ///
    /// ⛔ FIRE-AND-FORGET, AND A BLOCKING WAIT HERE IS §5 STOP 2's DEADLOCK BY A
    /// SECOND DOOR. If this thread waited for the dispatcher while the dispatcher
    /// was waiting for a frame, neither would move and the window would look
    /// exactly like a hung app -- which is what the pump exists to prevent.
    /// </summary>
    private void BindPanelFromRenderThread()
    {
        var unk = _swapChainUnknown;
        PostToUi(() =>
        {
            try
            {
                var panel = _panel;
                if (panel is null || unk == IntPtr.Zero) { return; }
                var native = panel.As<ISwapChainPanelNative>();
                native.SetSwapChain(unk);
            }
            catch (Exception ex)
            {
                _report($"RUSTFAIL SetSwapChain threw {ex.GetType().Name}: {ex.Message} {Tids()}");
            }
        });
    }

    private void PostToUi(Action action)
    {
        var ui = _ui;
        if (ui is null) { return; }
        ui.TryEnqueue(() => action());
    }

    /// <summary>
    /// (Re)create the offscreen target at the CURRENT `_width`/`_height`.
    ///
    /// SPLIT OUT FOR THE RESIZE PATH, and the split is the fix rather than
    /// tidying: while this lived inline it ran exactly once, so the target kept
    /// its initial size for the life of the window.
    /// </summary>
    private void CreateOffscreenTarget()
    {
        var texDesc = new D3D11_TEXTURE2D_DESC
        {
            Width = _width,
            Height = _height,
            MipLevels = 1,
            ArraySize = 1,
            Format = DXGI_FORMAT.DXGI_FORMAT_B8G8R8A8_UNORM,
            SampleDesc = new DXGI_SAMPLE_DESC { Count = 1, Quality = 0 },
            Usage = D3D11_USAGE.D3D11_USAGE_DEFAULT,
            BindFlags = D3D11_BIND_FLAG.D3D11_BIND_RENDER_TARGET,
            CPUAccessFlags = 0,
            MiscFlags = 0,
        };
        _device!.CreateTexture2D(in texDesc, null, out var off);
        _offscreen = off;
        // Resolve the base interface ONCE, here, where a failure is legible and
        // happens before any frame. Doing it at the call site made the marshaller
        // convert on every copy and it threw from InterfaceMarshaler.
        _offscreenRes = (ID3D11Resource)off;
    }

    /// <summary>
    /// Resize the swapchain AND the offscreen target. Both, or neither.
    ///
    /// ⛔ THE PAIRING IS THE WHOLE POINT. `ResizeBuffers` alone leaves the back
    /// buffer bigger than the target, and `CopyResource` is `void` -- D3D11 DROPS
    /// a mismatched copy instead of faulting.
    ///
    /// THE OLD BUFFER REFERENCES MUST BE GONE FIRST. `ResizeBuffers` fails with
    /// DXGI_ERROR_INVALID_CALL while any back-buffer reference is outstanding,
    /// and the RCW `GetBuffer` hands back is only released when the GC finalizes
    /// it. The collect below is what makes the call legal; it runs ON THIS
    /// THREAD, once per drain rather than once per frame, and never touches the
    /// hot path that the README records corrupting the heap.
    /// </summary>
    private bool ApplyResize(ResizeCmd r)
    {
        if (_swapChain is null || _device is null)
        {
            LastStatus = "resize: not started";
            return false;
        }
        var w = r.Width;
        var h = r.Height;
        if (w == _width && h == _height) { return false; }

        // Drop our reference to the old target BEFORE resizing, so the only
        // outstanding references are the swapchain's own.
        _offscreenRes = null;
        _offscreen = null;

        var swGc = System.Diagnostics.Stopwatch.StartNew();
        GC.Collect();
        GC.WaitForPendingFinalizers();
        swGc.Stop();

        // ⚠️ `ResizeBuffers` IS PROJECTED AS `void`, NOT AS AN HRESULT, unlike
        // `Present` which returns one. CsWin32 generates it PreserveSig(false),
        // so failure arrives as a thrown COMException. Two neighbouring calls on
        // the SAME interface with two different error conventions is exactly the
        // kind of thing that gets "tidied" into a silent hole later.
        var swBuf = new System.Diagnostics.Stopwatch();
        try
        {
            swBuf.Start();
            _swapChain.ResizeBuffers(0, w, h, DXGI_FORMAT.DXGI_FORMAT_UNKNOWN, 0);
            swBuf.Stop();
        }
        catch (Exception ex)
        {
            LastStatus = $"resize {w}x{h}: ResizeBuffers threw {ex.GetType().Name}: {ex.Message}";
            _report($"RUSTFAIL {LastStatus} {Tids()}");
            _width = 0;
            _height = 0;
            _hasSurface = false;
            return false;
        }

        _width = w;
        _height = h;
        var swTgt = System.Diagnostics.Stopwatch.StartNew();
        if (OffscreenMode) { CreateOffscreenTarget(); }
        swTgt.Stop();

        // ⭐ THE RE-BIND, AFTER EVERY SUCCESSFUL ResizeBuffers. The UWP
        // DirectX-interop page's own note says the panel must be handed the
        // swapchain again; the tree at 3c8fddce never did (`SwapChainHost.cs:
        // 329-372`) and F-4's resize still repainted, which is counter-evidence
        // and not a refutation -- that resize repainted the PROBE, and nothing
        // asserted the composed output. So it is done, fire-and-forget, and its
        // omission would have been a named negative rather than a silent
        // invariant.
        BindPanelFromRenderThread();

        ResizeCost = $"rcw-release={swGc.Elapsed.TotalMilliseconds:F2}ms "
                   + $"resizebuffers={swBuf.Elapsed.TotalMilliseconds:F2}ms "
                   + $"target-recreate={swTgt.Elapsed.TotalMilliseconds:F2}ms";
        LastStatus = $"resized to {SurfaceLabel()} :: {ResizeCost}";
        return true;
    }

    private void ApplyPointer(PointerCmd p)
    {
        if (_engine == IntPtr.Zero) { return; }
        // A scene WAITING for a hand stops asking "did anyone press?" the moment
        // one does, so its timeout can distinguish an injector that never
        // reached the window from a gesture left open.
        if (_handDeadlineMs >= 0 && p.Kind == JasCore.PointerPress) { _handPressSeen = true; }
        JasCore.jas_pointer_event(_engine, p.Kind, p.X, p.Y, p.Mods);
    }

    /// <summary>
    /// The gesture's receipt, written where `jas_selection_len` can be read (BL2).
    ///
    /// ⛔ THE COUNTERS COME FROM THE WinUI HANDLERS AND NOWHERE ELSE. A synthetic
    /// gesture cannot increment them, which is what makes `POINTER REAL` mean
    /// something -- the marquee at `SwapChainHost.cs:858-893` emitted
    /// `press=1 move=2 release=1` for its whole life without a pointer ever
    /// existing.
    /// </summary>
    private void ApplyPointerReport(PointerReportCmd r)
    {
        // ⛔ AN UNLOADED ENGINE IS `NOT RUN`, NEVER A `selected=0` -- a repair
        // folded in from flask's rows on the merged shell (R7/R8). A real hand
        // on the `document` scene reported `selected=0` while the synthesised
        // gesture reported 1, and the cause was that the control paints through
        // its OWN engine and never loads the HELD one, so the pointer drove an
        // EMPTY document. The tell was `loads(shell)=0`, on a row that did not
        // carry it.
        //
        // The scenes N3 adds (`pointer`, `retained`) load the held engine, so
        // that cause is gone -- but THE HAZARD IS NOT, because an empty-held-
        // engine `selected=0` is BYTE-IDENTICAL to O4's empty-canvas negative
        // control, which is a row that must read `selected=0` and mean the
        // opposite thing. Two states that produce the same row cannot both be
        // measured by it. So every gesture row now carries `doc=HELD|NONE` and
        // `loads(shell)=`, and a row about an engine that has never been loaded
        // REFUSES to print a selection figure at all.
        var loaded = _engine != IntPtr.Zero && _loadsShell > 0;
        var doc = loaded ? "HELD" : "NONE";
        string selField;
        if (loaded)
        {
            var selected = JasCore.jas_selection_len(_engine);
            selField = selected == nuint.MaxValue
                ? "selected=n/a"
                : $"selected={selected}";
        }
        else
        {
            selField = "NOT RUN: held engine has no document";
        }

        // ⛔ THE PROVENANCE IS A FIELD, DERIVED FROM THE KIND AND FROM NOTHING
        // ELSE. `SYNTHETIC` is set only by the replay of `SB_SYNTH_DRAG`;
        // `REAL` is reachable only from the WinUI handlers, which are the only
        // things that can increment the counters. A row can therefore never
        // claim a provenance its counters did not come from.
        var provenance = string.Equals(r.Kind, "SYNTHETIC", StringComparison.Ordinal)
            ? "SYNTHETIC"
            : "REAL";
        _report(
            $"POINTER {r.Kind} press={r.Press} move={r.Move} release={r.Release} "
          + $"id={r.PointerId} device={r.Device} hit={r.Hit} tool=0 pointer={provenance} "
          + $"doc={doc} loads(shell)={_loadsShell} "
          + $"press@=({r.PressX:F1},{r.PressY:F1}) release@=({r.ReleaseX:F1},{r.ReleaseY:F1}) "
          + $"{selField} surface={_width}x{_height} scale={_scaleX:0.##} {Tids()}");

        // A SCENE THAT WAS WAITING FOR THIS GESTURE IS NOW FINISHED, and only a
        // gesture that came through the handlers closes it: the synthetic replay
        // is applied inline by the scene that asked for it and never arrives
        // here as the thing being waited for.
        if (_handDeadlineMs < 0 || provenance != "REAL") { return; }
        var scene = _handScene;
        _handDeadlineMs = -1;
        _handScene = "";
        _handPressSeen = false;
        ApplyDump("sb-doc-after.json");
        if (string.Equals(scene, "retained", StringComparison.Ordinal))
        {
            // The mutation's own frame, hashed at the surface `A` was hashed at,
            // BEFORE the resize walk starts. `A-MUT` is the round trip's H0.
            PaintAndHash("A-MUT");
        }
        _report($"HAND CLOSED scene={scene} pointer=REAL doc={doc} loads(shell)={_loadsShell} "
              + $"{selField} the scene's completion is posted now "
              + $"surface={_width}x{_height} {Tids()}");
        PostToUi(() => SceneCompleted?.Invoke());
    }

    /// <summary>
    /// COAT 1's `Load`: <c>jas_load_svg</c> ON THE HELD ENGINE, replacing whatever
    /// it held. It does not create an engine and it does not free one.
    ///
    /// Returns success and sets <see cref="LastStatus"/>; it does NOT report,
    /// because it has two callers with different receipts -- the queue (which
    /// writes a `LOADED`/`LOAD FAILED` row) and the `selection` scene (which
    /// folds the failure into its own). A method that reported for itself would
    /// give the scene two rows for one event.
    /// </summary>
    private bool ApplyLoad(LoadCmd l)
    {
        if (_engine == IntPtr.Zero)
        {
            LastStatus = "LOAD FAILED: no engine";
            return false;
        }
        var rc = JasCore.jas_load_svg(_engine, l.Svg, (nuint)l.Svg.Length);
        _loadsShell++;
        if (rc != JasCore.PaintOk)
        {
            LastStatus = $"LOAD FAILED '{l.Label}': {JasCore.Explain(rc)}";
            return false;
        }
        LastStatus = $"LOADED '{l.Label}' ({l.Svg.Length} bytes) into the RETAINED engine "
                   + $"loads(shell)={_loadsShell}";
        return true;
    }

    /// <summary>
    /// Write the retained document's canonical test JSON beside the exe.
    ///
    /// BL4 held at the one place it is easiest to break: the span is Rust-owned,
    /// so it is COPIED and then freed, and the free happens even when the write
    /// throws.
    /// </summary>
    private void ApplyDump(string path)
    {
        if (_engine == IntPtr.Zero) { return; }
        try
        {
            var json = JasCore.TakeString(JasCore.jas_document_json(_engine));
            var full = System.IO.Path.Combine(AppContext.BaseDirectory, path);
            System.IO.File.WriteAllText(full, json);
            _report($"DUMP {path} bytes={json.Length} {Tids()}");
        }
        catch (Exception ex)
        {
            _report($"RUSTFAIL dump '{path}' threw {ex.GetType().Name}: {ex.Message} {Tids()}");
        }
    }

    /// <summary>
    /// The core's own crossing counters, as (created, freed) for `jas_engine_new`
    /// and `jas_engine_free`.
    ///
    /// ⭐ READ FROM THE CORE, NOT FROM THIS SHELL, AND THAT IS O1's IDENTITY
    /// CLAUSE. A shell counting its own calls is a witness to its own good
    /// behaviour. `ffi.rs:274/:284` record the crossings; this reads the dump.
    /// Read LAST in an interaction: its own `jas_free` is a counted crossing
    /// (`ffi.rs:551-556`).
    /// </summary>
    private (long Created, long Freed) EngineCounters()
    {
        try
        {
            var json = JasCore.TakeString(JasCore.jas_instr_counters_json());
            if (json.Length == 0) { return (-1, -1); }
            using var doc = System.Text.Json.JsonDocument.Parse(json);
            long created = -1, freed = -1;
            foreach (var row in doc.RootElement.GetProperty("per_fn").EnumerateArray())
            {
                var fn = row.GetProperty("fn").GetString();
                var calls = row.GetProperty("calls").GetInt64();
                if (fn == "jas_engine_new") { created = calls; }
                else if (fn == "jas_engine_free") { freed = calls; }
            }
            return (created, freed);
        }
        catch (Exception)
        {
            return (-1, -1);
        }
    }

    // =======================================================================
    // COAT 2 — Repaint() SPLIT FROM Benchmark()
    // =======================================================================

    /// <summary>
    /// ONE frame. No frame count, NO KNOB, no loop.
    ///
    /// ⛔ THIS IS THE SPLIT F-5 NEEDED. The method the resize path reaches now
    /// draws exactly one frame, and there is no value it could report other than
    /// `frames=1`. The 60-frame loop still exists -- verbatim, in
    /// <see cref="Benchmark"/> -- so every S-B and S-C number on record keeps the
    /// loop that produced it; it is simply no longer reachable from a resize.
    /// </summary>
    private void RepaintOnce(string cause, int resizes)
    {
        if (_swapChain is null || _engine == IntPtr.Zero) { return; }

        var swPaint = new System.Diagnostics.Stopwatch();
        var swPresent = new System.Diagnostics.Stopwatch();
        string? failure = null;
        var occluded = 0;
        string? hash = null;

        // ⭐ O3's STALL, AND IT IS INSIDE ONE REPAINT ON THE RENDER THREAD
        // (FREEZE §2 O3). Not inside the marshalled paint step below: under
        // `SB_PAINT_ON_UI=1` that step runs on the XAML thread, and a stall that
        // moved with it would silently turn the RENDER-stall arm into the
        // UI-stall arm -- two controls answering different questions, collapsed
        // into one by an implementation detail. The sleep is latched to ONE
        // repaint: `_stallMs` is zeroed before it starts, so a stalled scene
        // does not stall every later frame.
        if (_stallMs > 0)
        {
            var ms = _stallMs;
            _stallMs = 0;
            _stallSlept = ms;
            _stallTid = Environment.CurrentManagedThreadId;
            Thread.Sleep(ms);
            _stallArmed = true;
        }

        // ⛔ ONE PAINT STEP, TWO THREADS TO RUN IT ON -- and it is deliberately
        // ONE body. `SB_PAINT_ON_UI` is O3's design-red control (see the field's
        // note); implementing it as a second paint path would let the two drift,
        // and the control would then be measuring the drift.
        void PaintStep()
        {
            _swapChain!.GetBuffer<IDXGISurface>(0, out var back);
            // GetComInterfaceForObject, NOT GetIUnknownForObject: for a COM
            // object exposing several interfaces those are DIFFERENT pointers,
            // and calling through the wrong vtable manifested as 0xC0000374 in
            // ntdll rather than as a clean failure.
            var backPtr = Marshal.GetComInterfaceForObject(back, typeof(IDXGISurface));
            try
            {
                _paintTid = Environment.CurrentManagedThreadId;
                swPaint.Restart();
                var rc = JasCore.jas_paint_frame(_engine, backPtr, _width, _height);
                swPaint.Stop();
                if (rc != JasCore.PaintOk) { failure = JasCore.Explain(rc); }
            }
            finally
            {
                Marshal.Release(backPtr);
            }

            if (failure is null && _hashLabel is not null)
            {
                // ⛔ BEFORE Present, NOT AFTER. Under the flip model Present
                // rotates the buffers, so a read-back after presenting samples a
                // DIFFERENT buffer than the one just painted -- a hash that
                // looks stable and describes the wrong frame.
                hash = BackBufferSha256(out var hashNote);
                if (hash is null) { failure = hashNote; }
            }

            if (failure is null)
            {
                _presentTid = Environment.CurrentManagedThreadId;
                swPresent.Restart();
                var hr = _swapChain!.Present(1, default);
                swPresent.Stop();
                if (hr.Failed) { failure = $"Present 0x{hr.Value:X8}"; }
                else if (hr.Value == StatusOccluded) { occluded++; }
                if (failure is null) { MarkFirstPresent(); }
            }
        }

        if (PaintOnUi)
        {
            var refused = RunPaintStepOnUi(PaintStep);
            if (refused is not null && failure is null) { failure = refused; }
        }
        else
        {
            PaintStep();
        }

        var head = failure is null ? "REPAINT" : "REPAINT-FAILED";
        var arrivals = _arrivals.Count == 0 ? "none" : string.Join(",", _arrivals);
        var row = $"{head} events_total={_eventsTotal} distinct_sizes={_distinctSizes.Count} "
                + $"arrivals={arrivals} frames=1 cause={cause} resizes-in-drain={resizes} "
                + $"surface={_width}x{_height} "
                + $"paint={swPaint.Elapsed.TotalMilliseconds:F2}ms "
                + $"present={swPresent.Elapsed.TotalMilliseconds:F2}ms occluded={occluded} "
                + $"loads(shell)={_loadsShell} {Tids()}";
        if (failure is not null) { row += $" failure={failure}"; }
        LastStatus = row;
        _report(failure is null ? $"RUSTOK {row}" : $"RUSTFAIL {row}");

        if (_hashLabel is not null)
        {
            var label = _hashLabel;
            _hashLabel = null;

            // ⛔ THE COUNTERS ARE THE LAST CORE CALL BEFORE THE ROW (FREEZE
            // O1(i)), AND THE ORDER IS THE MEASUREMENT. `jas_instr_counters_json`
            // counts its own `jas_free`, and `jas_engine_free` is a recorded
            // crossing -- so a row composed before a free that is about to
            // happen reports the state one call ago. That is exactly the defect
            // flask measured on the `document` control (`2 / 0`), repaired at
            // its site by freeing before counting. Here nothing is freed at all,
            // which is the whole claim: the `retained` scene holds ONE engine
            // for the life of the window, so these rows must read
            // `engines-created=1 engines-freed=0` at every stop of the walk.
            var (created, freed) = EngineCounters();
            _report(
                $"{label} surface={_width}x{_height} hash={hash ?? "n/a"} "
              + $"engines-created={created} engines-freed={freed} loads(shell)={_loadsShell} "
              + $"{Tids()}");
            // ⛔ THE NEXT RESIZE STEP IS POSTED FROM HERE, NOT FROM THE SETTLE.
            // O1's list walks the surface AWAY and BACK, hashing at each stop.
            // If the next `AppWindow.Resize` were posted the moment the previous
            // one settled, the hash command and the next resize could land in
            // ONE drain -- one paint, at the NEW size, wearing the OLD step's
            // label. The hash row is the only point at which the previous stop
            // is finished, so it is the only safe place to ask for the next.
            PostToUi(() => HashTaken?.Invoke());
        }
    }

    /// <summary>
    /// Paint one frame and hash it, RIGHT HERE on the render thread.
    ///
    /// The scenes use this instead of <see cref="Hash"/> because they are ALREADY
    /// on the render thread: enqueuing from here would put two hash commands in
    /// one batch, and a batch paints once -- the second label would overwrite the
    /// first and one of the two hashes would silently never be taken. Same code
    /// path as the queued one, so the two cannot drift.
    /// </summary>
    private void PaintAndHash(string label)
    {
        _hashLabel = label;
        RepaintOnce("hash", 0);
    }

    /// <summary>
    /// ⭐ THE BENCHMARK LOOP, MOVED HERE VERBATIM IN BEHAVIOUR from
    /// <c>SwapChainHost.RenderFrame</c>.
    ///
    /// ⛔ AND THIS IS THE ONLY PLACE OUTSIDE `Report` THAT READS `SB_FRAMES`.
    /// That is O2b's clause, and the reason it is a gate rather than a habit: at
    /// 3c8fddce the knob was read inside `RenderFrame`, and `RenderFrame` was
    /// what `Canvas.SizeChanged` called. First frame excluded from the mean,
    /// occlusion counted and fatal, both routes preserved -- so every S-B/S-C
    /// number on record still means what it meant.
    /// </summary>
    private bool Benchmark()
    {
        if (_swapChain is null) { LastStatus = "no swapchain"; return false; }

        var frames = int.TryParse(Environment.GetEnvironmentVariable("SB_FRAMES"), out var f) ? f : 60;
        var offscreen = OffscreenMode && _offscreen is not null;
        var paint = new List<double>();
        var copy = new List<double>();
        var present = new List<double>();
        var sw = new System.Diagnostics.Stopwatch();
        string? failure = null;
        var occluded = 0;

        for (var i = 0; i < frames && failure is null; i++)
        {
            // WHICH SURFACE RUST PAINTS is the whole difference between the two
            // routes. Everything else below is identical, deliberately, so the
            // measured delta is the copy and not the scaffolding.
            if (offscreen)
            {
                _swapChain.GetBuffer<IDXGISurface>(0, out var back);
                var backPtr = Marshal.GetComInterfaceForObject(back, typeof(IDXGISurface));
                var offPtr = Marshal.GetComInterfaceForObject(_offscreen!, typeof(IDXGISurface));
                try
                {
                    _paintTid = Environment.CurrentManagedThreadId;
                    sw.Restart();
                    var rc = JasCore.jas_paint_probe_offscreen(backPtr, offPtr, _width, _height);
                    sw.Stop();
                    copy.Add(sw.Elapsed.TotalMilliseconds);
                    if (rc != JasCore.PaintOk) { failure = $"paint+copy {JasCore.Explain(rc)}"; break; }
                }
                finally
                {
                    Marshal.Release(backPtr);
                    Marshal.Release(offPtr);
                }
            }
            else
            {
                _swapChain.GetBuffer<IDXGISurface>(0, out var target);
                var ptr = Marshal.GetComInterfaceForObject(target, typeof(IDXGISurface));
                try
                {
                    _paintTid = Environment.CurrentManagedThreadId;
                    sw.Restart();
                    var rc = JasCore.jas_paint_probe_surface(ptr, _width, _height);
                    sw.Stop();
                    paint.Add(sw.Elapsed.TotalMilliseconds);
                    if (rc != JasCore.PaintOk) { failure = $"paint {JasCore.Explain(rc)}"; break; }
                }
                finally
                {
                    Marshal.Release(ptr);
                }
            }

            _presentTid = Environment.CurrentManagedThreadId;
            sw.Restart();
            var hr = _swapChain.Present(1, default);
            sw.Stop();
            present.Add(sw.Elapsed.TotalMilliseconds);
            if (hr.Failed) { failure = $"Present 0x{hr.Value:X8}"; break; }

            // ⛔ OCCLUSION IS A SUCCESS CODE. `hr.Failed` tests the sign bit, and
            // DXGI_STATUS_OCCLUDED has it clear, so an occluded present passed
            // straight through and was counted as an ordinary frame -- while its
            // documented meaning is that THE PRESENT WAS INVISIBLE TO THE USER.
            if (hr.Value == StatusOccluded) { occluded++; }
        }

        // ⛔ AN OCCLUDED RUN IS RED, NOT A SLOW ONE. Reporting timings from
        // frames nobody saw would be reporting a measurement that did not
        // happen -- and it would look entirely plausible.
        if (failure is null && occluded > 0)
        {
            failure = $"OCCLUDED {occluded}/{present.Count} presents were INVISIBLE TO THE USER "
                    + "(DXGI_STATUS_OCCLUDED, a success code) -- these timings do not describe "
                    + "frames anyone saw; re-run with the window unobscured";
        }

        var route = offscreen ? "OFFSCREEN+copy" : "DIRECT";
        if (failure is not null)
        {
            LastStatus = $"{route} FAILED at frame {paint.Count}: {failure} [{Stat("paint", paint)}]";
            return false;
        }

        LastStatus = $"BENCHMARK frames={frames} {route} {SurfaceLabel()} on {Adapter} :: "
                   + $"{Stat("paint", paint)} | {Stat("paint+copy", copy)} | {Stat("present", present)} "
                   + $"{Tids()}";
        return true;
    }

    /// <summary>
    /// THE FIRST FRAME IS EXCLUDED FROM THE MEAN, not merely printed beside it.
    /// It carries device warm-up, shader compilation and one-time allocation:
    /// measured at 1092 ms on the offscreen route against a 0.71 ms minimum.
    /// Averaging that in produced a "mean" of 19.20 ms that described nothing.
    /// </summary>
    private static string Stat(string name, List<double> xs)
    {
        if (xs.Count == 0) { return $"{name} n/a"; }
        if (xs.Count == 1) { return $"{name} first={xs[0]:F2}ms (one frame only)"; }
        var rest = xs.Skip(1).ToList();
        return $"{name} first={xs[0]:F2}ms steady-mean={rest.Average():F2}ms " +
               $"min={rest.Min():F2}ms max={rest.Max():F2}ms n={rest.Count}+1";
    }

    // =======================================================================
    // THE SCENES — dispatched HERE, on the render thread, because every one of
    // them calls the core (BL2).
    // =======================================================================

    private void ApplyScene(string scene)
    {
        // THE COMPLETION IS POSTED ON EVERY PATH, INCLUDING THE REFUSALS. A
        // notification that only fires on success is a notification the window
        // waits for forever after a bad SB_SVG -- and the run would look hung
        // rather than refused.
        //
        // ⚠️ TWO SCENES POST IT THEMSELVES, in opposite directions, and both say
        // so by setting `_scenePostsItsOwnCompletion`:
        //   * `stall` posts it EARLY, BEFORE the render thread sleeps -- O3's
        //     resize has to be posted DURING the stall, and the window cannot
        //     post it until it has been told the scene is up.
        //   * `pointer` and `retained` waiting for a real hand post it LATE,
        //     when the gesture closes or the wait is refused by name -- the
        //     resize round trip must not start before the mutation it is
        //     supposed to carry across.
        // Every one of those paths ends in exactly one post, and the hand's is
        // bounded by SB_POINTER_WAIT_MS, so no path can leave the window
        // waiting forever.
        _scenePostsItsOwnCompletion = false;
        try { ApplySceneInner(scene); }
        finally
        {
            if (!_scenePostsItsOwnCompletion)
            {
                PostToUi(() => SceneCompleted?.Invoke());
            }
        }
    }

    private void ApplySceneInner(string scene)
    {
        bool ok;
        try
        {
            // ⭐ AN EMPTY SB_SCENE RESOLVES TO `benchmark` BEFORE IT ARRIVES
            // HERE (MainWindow), so every historical invocation -- including the
            // committed 4K sweep, which never set the knob -- keeps meaning what
            // it meant. The sweep now sets it explicitly so its receipts say
            // what they ran.
            if (string.Equals(scene, "benchmark", StringComparison.OrdinalIgnoreCase))
            {
                ok = Benchmark();
            }
            else if (string.Equals(scene, "goldens", StringComparison.OrdinalIgnoreCase))
            {
                ok = RenderGoldens();
            }
            else if (string.Equals(scene, "document", StringComparison.OrdinalIgnoreCase))
            {
                ok = RenderDocumentControl();
            }
            else if (string.Equals(scene, "selection-marquee", StringComparison.OrdinalIgnoreCase))
            {
                ok = RenderSelection();
            }
            else if (string.Equals(scene, "retained", StringComparison.OrdinalIgnoreCase))
            {
                ok = RenderRetained();
            }
            else if (string.Equals(scene, "stall", StringComparison.OrdinalIgnoreCase))
            {
                ok = RenderStall();
            }
            else if (string.Equals(scene, "pointer", StringComparison.OrdinalIgnoreCase))
            {
                ok = RenderPointer();
            }
            else if (string.Equals(scene, "stay", StringComparison.OrdinalIgnoreCase))
            {
                ok = RenderStay();
            }
            else if (string.Equals(scene, "selection", StringComparison.OrdinalIgnoreCase))
            {
                // ⛔ THE OLD NAME IS REFUSED, POINTING AT THE NEW ONE, AND THAT
                // IS THE WHOLE VALUE OF THE RENAME. `selection` drives a MARQUEE
                // that moves nothing and selects N (FREEZE §1.4 / A4); it is a
                // control, not O4's positive arm. If the old spelling silently
                // ran the new scene, every invocation written before the rename
                // would keep working and nobody would ever find out which arm
                // their receipt came from.
                LastStatus = "SB_SCENE='selection' is RENAMED 'selection-marquee'. It is a "
                           + "CONTROL: its gesture is synthetic (pointer=SYNTHETIC), it moves "
                           + "nothing, and it proves nothing about the pointer seam. For a "
                           + "real gesture use SB_SCENE=pointer; for the seam's positive "
                           + "control use SB_SYNTH_DRAG on 'pointer' or 'retained'";
                _report($"RUSTFAIL {LastStatus} {Tids()}");
                return;
            }
            else
            {
                // An UNRECOGNISED value is refused BY NAME rather than falling
                // back to the probe. A run asked for goldens that quietly drew a
                // square would report RUSTOK over the wrong workload.
                LastStatus = $"SB_SCENE='{scene}' is not recognised; use 'benchmark', "
                           + "'goldens', 'document', 'retained', 'stall', 'pointer', "
                           + "'stay' or 'selection-marquee'";
                _report($"RUSTFAIL {LastStatus} {Tids()}");
                return;
            }
        }
        catch (Exception ex)
        {
            LastStatus = $"{ex.GetType().Name}: {ex.Message}";
            _report($"RUSTFAIL scene '{scene}' threw {LastStatus} {Tids()}");
            return;
        }

        _report(ok ? $"RUSTOK {LastStatus}" : $"RUSTFAIL {LastStatus}");
    }

    /// <summary>
    /// ⭐ PAINT THE GOLDENS, not the probe. The recorded corpus, walked through
    /// the real <c>Direct2DPainter</c> onto the back buffer this window presents.
    ///
    /// ⛔ A REFUSAL IS NOT A FAILURE HERE. The core REFUSES a scene it cannot
    /// fully draw (<c>PaintSceneIncomplete</c>) rather than presenting
    /// artwork-missing pixels; two goldens land there by design. So an incomplete
    /// is TALLIED and anything else is a hard stop -- and the EXPECTED TALLY is
    /// not written down on this side, because that would make the shell a second
    /// source of truth about the corpus.
    /// </summary>
    private bool RenderGoldens()
    {
        if (_swapChain is null) { LastStatus = "no swapchain"; return false; }

        var n = (nuint)JasCore.jas_corpus_len();
        if (n == 0)
        {
            LastStatus = "GOLDENS FAILED: the core reports an EMPTY corpus";
            return false;
        }

        var hold = SceneHold();

        // THE FINAL FRAME IS CHOSEN, NOT INHERITED FROM THE LOOP ORDER. A
        // screenshot is only evidence if it is deterministic.
        var finalName = Environment.GetEnvironmentVariable("SB_SCENE_FINAL") ?? "ref_shapes.json";

        var painted = new List<string>();
        var refused = new List<string>();
        string? failure = null;
        nuint finalIndex = 0;
        var haveFinal = false;

        for (nuint i = 0; i < n && failure is null; i++)
        {
            var (name, sceneBytes, len) = JasCore.Golden(i);
            if (name == finalName) { finalIndex = i; haveFinal = true; }

            var rc = PaintOnce(sceneBytes, len, hold, ref failure);
            if (failure is not null) { break; }

            if (rc == JasCore.PaintOk) { painted.Add(name); }
            else if (rc == JasCore.PaintSceneIncomplete) { refused.Add(name); }
            else
            {
                failure = $"{name}: {JasCore.Explain(rc)}";
            }
        }

        if (failure is null && !haveFinal)
        {
            failure = $"SB_SCENE_FINAL='{finalName}' is not in the corpus; the "
                    + $"corpus holds: {string.Join(", ", painted.Concat(refused))}";
        }

        if (failure is null)
        {
            var (name, sceneBytes, len) = JasCore.Golden(finalIndex);
            var rc = PaintOnce(sceneBytes, len, hold, ref failure);
            if (failure is null && rc != JasCore.PaintOk)
            {
                failure = $"final frame {name}: {JasCore.Explain(rc)}";
            }
        }

        if (failure is not null)
        {
            LastStatus = $"GOLDENS FAILED after {painted.Count} painted: {failure}";
            return false;
        }

        LastStatus =
            $"GOLDENS {painted.Count}/{n} painted through {SurfaceLabel()} on {Adapter}; " +
            $"{refused.Count} refused as INCOMPLETE (declared gap): " +
            $"{(refused.Count == 0 ? "none" : string.Join(", ", refused))}; " +
            $"final={finalName} {Tids()}";
        return true;
    }

    /// <summary>
    /// ⭐ O1's GOLDEN CONTROL, AND IT KEEPS ITS OWN ENGINE ON PURPOSE.
    ///
    /// This is the one-shot path as it stood at 3c8fddce (`SwapChainHost.cs:731`
    /// created an engine and `:793` freed it), moved onto the render thread and
    /// kept BY NAME as a control. O1(iii) asks whether the retained canvas paints
    /// the same pixels as a fresh engine painting the same SVG at the same
    /// observed surface: that comparison needs an arm that really does create and
    /// free an engine per call, so this arm is not a leftover -- deleting it
    /// would delete the control and leave O1 carrying self-equality, which is
    /// exactly what §4 records v1 doing.
    ///
    /// ⛔ SO ITS `engines-created` READS 2, NOT 1, and that is correct for THIS
    /// scene: the retained engine from Attach plus this one. O1's identity clause
    /// is asserted on the `retained` scene, not here.
    ///
    /// ⭐ AND `engines-freed` READS 1 BECAUSE THE FREE IS ORDERED BEFORE THE
    /// COUNTERS READ -- a repair folded in from flask's measurement of the
    /// merged shell on kenai, where the row read `2 / 0`. Nothing leaked: the
    /// free lived in the `finally`, so it ran AFTER the row was composed, and
    /// the row was a true statement about a moment that was one call too early.
    /// The count is therefore read AFTER this control's own `jas_engine_free`,
    /// and the `finally` stays as a GUARD that frees only a handle still held
    /// (the refusal paths above never reach the explicit free). An ordering
    /// fact reported as a count is exactly the shape a reader cannot tell from
    /// a leak, which is why it is fixed rather than annotated.
    /// </summary>
    private bool RenderDocumentControl()
    {
        if (_swapChain is null) { LastStatus = "no swapchain"; return false; }

        var svgPath = Environment.GetEnvironmentVariable("SB_SVG");
        if (string.IsNullOrWhiteSpace(svgPath))
        {
            LastStatus = "SB_SCENE=document requires SB_SVG=<path to an .svg>";
            return false;
        }

        byte[] bytes;
        try
        {
            // ⛔ BYTES, UNDECODED. `ReadAllText` would substitute U+FFFD for any
            // byte the active code page cannot map, and the core would parse the
            // SUBSTITUTION and report success on a document that is not the file.
            bytes = System.IO.File.ReadAllBytes(svgPath);
        }
        catch (Exception ex)
        {
            LastStatus = $"DOCUMENT FAILED: cannot read '{svgPath}': {ex.GetType().Name}";
            return false;
        }

        var engine = JasCore.jas_engine_new();
        if (engine == IntPtr.Zero)
        {
            LastStatus = "DOCUMENT FAILED: the core would not create a session";
            return false;
        }
        try
        {
            var lrc = JasCore.jas_load_svg(engine, bytes, (nuint)bytes.Length);
            if (lrc != JasCore.PaintOk)
            {
                LastStatus = $"DOCUMENT FAILED to open '{System.IO.Path.GetFileName(svgPath)}': "
                           + JasCore.Explain(lrc);
                return false;
            }

            var hold = SceneHold();
            string? failure = null;
            var rc = JasCore.PaintOk;
            string? hash = null;
            for (var f = 0; f < hold; f++)
            {
                _swapChain.GetBuffer<IDXGISurface>(0, out var back);
                var ptr = Marshal.GetComInterfaceForObject(back, typeof(IDXGISurface));
                try
                {
                    _paintTid = Environment.CurrentManagedThreadId;
                    rc = JasCore.jas_paint_document(engine, ptr, _width, _height);
                }
                finally
                {
                    Marshal.Release(ptr);
                }
                if (rc != JasCore.PaintOk) { break; }

                // The hash of the LAST painted frame, taken BEFORE its Present.
                if (f == hold - 1) { hash = BackBufferSha256(out _); }

                _presentTid = Environment.CurrentManagedThreadId;
                var hr = _swapChain.Present(1, default);
                if (hr.Failed) { failure = $"Present 0x{hr.Value:X8}"; break; }
            }

            if (rc != JasCore.PaintOk)
            {
                LastStatus = $"DOCUMENT REFUSED '{System.IO.Path.GetFileName(svgPath)}': "
                           + JasCore.Explain(rc);
                return false;
            }
            if (failure is not null)
            {
                LastStatus = $"DOCUMENT FAILED presenting: {failure}";
                return false;
            }

            // ⛔ FREE FIRST, THEN COUNT. `jas_engine_free` is a recorded
            // crossing, so a row composed before it reports the state one call
            // ago -- `engines-freed=0` about an engine this scene is about to
            // free. The handle is nulled so the `finally` below frees nothing
            // twice.
            JasCore.jas_engine_free(engine);
            engine = IntPtr.Zero;

            var (created, freed) = EngineCounters();
            LastStatus = $"DOCUMENT '{System.IO.Path.GetFileName(svgPath)}' "
                       + $"({bytes.Length} bytes) painted LIVE through {SurfaceLabel()} on {Adapter} "
                       + $"surface={_width}x{_height} hash={hash ?? "n/a"} "
                       + $"engines-created={created} engines-freed={freed} "
                       + $"loads(shell)={_loadsShell} pointer=NONE {Tids()}";
            return true;
        }
        finally
        {
            // A GUARD, not the primary free. The success path frees above, in
            // order, and nulls the handle; this catches every refusal and throw
            // between the create and that point -- a session leaked per frame is
            // a leak nobody notices until a long run.
            if (engine != IntPtr.Zero)
            {
                JasCore.jas_engine_free(engine);
                engine = IntPtr.Zero;
            }
        }
    }

    /// <summary>
    /// The RETAINED selection scene: load into the HELD engine, drive the
    /// synthesised marquee through the C ABI, present the frame WITH THE OVERLAY.
    ///
    /// ⚠️ ITS GESTURE IS SYNTHETIC AND IT SAYS SO (`pointer=SYNTHETIC`). The
    /// marquee at `SwapChainHost.cs:858-893` moved nothing and selected N; it
    /// cannot be O4's positive control and is not offered as one. What is new
    /// here is only that the engine it drives is the RETAINED one, so the
    /// document survives the scene.
    /// </summary>
    private bool RenderSelection()
    {
        if (_swapChain is null || _engine == IntPtr.Zero) { LastStatus = "no swapchain"; return false; }

        var svgPath = Environment.GetEnvironmentVariable("SB_SVG");
        if (string.IsNullOrWhiteSpace(svgPath))
        {
            LastStatus = "SB_SCENE=selection-marquee requires SB_SVG=<path to an .svg>";
            return false;
        }

        byte[] bytes;
        try { bytes = System.IO.File.ReadAllBytes(svgPath); }
        catch (Exception ex)
        {
            LastStatus = $"SELECTION FAILED: cannot read '{svgPath}': {ex.GetType().Name}";
            return false;
        }

        // THROUGH COAT 1's OWN LOAD PATH, not a second copy of it. The scene and
        // the queue command reach `jas_load_svg` by the same route, so
        // `loads(shell)` counts every load once and there is no second place for
        // the held engine's document to be replaced.
        if (!ApplyLoad(new LoadCmd { Svg = bytes, Label = System.IO.Path.GetFileName(svgPath) }))
        {
            return false;
        }
        ApplyDump("sb-doc-before.json");

        double x0 = _width * 0.06, y0 = _height * 0.06;
        double x1 = _width * 0.94, y1 = _height * 0.94;
        JasCore.jas_pointer_event(_engine, JasCore.PointerPress, x0, y0, 0);
        JasCore.jas_pointer_event(_engine, JasCore.PointerMove,
            (x0 + x1) / 2, (y0 + y1) / 2, JasCore.ModDragging);
        JasCore.jas_pointer_event(_engine, JasCore.PointerMove, x1, y1, JasCore.ModDragging);

        var hold = SceneHold();
        string? failure = null;
        var rc = JasCore.PaintOk;
        for (var f = 0; f < hold; f++)
        {
            _swapChain.GetBuffer<IDXGISurface>(0, out var back);
            var ptr = Marshal.GetComInterfaceForObject(back, typeof(IDXGISurface));
            try
            {
                _paintTid = Environment.CurrentManagedThreadId;
                rc = JasCore.jas_paint_frame(_engine, ptr, _width, _height);
            }
            finally { Marshal.Release(ptr); }
            if (rc != JasCore.PaintOk) { break; }
            _presentTid = Environment.CurrentManagedThreadId;
            var hr = _swapChain.Present(1, default);
            if (hr.Failed) { failure = $"Present 0x{hr.Value:X8}"; break; }
        }

        if (rc != JasCore.PaintOk)
        {
            LastStatus = $"SELECTION REFUSED '{System.IO.Path.GetFileName(svgPath)}': "
                       + JasCore.Explain(rc);
            return false;
        }
        if (failure is not null)
        {
            LastStatus = $"SELECTION FAILED presenting: {failure}";
            return false;
        }

        JasCore.jas_pointer_event(_engine, JasCore.PointerRelease, x1, y1, 0);
        ApplyDump("sb-doc-after.json");
        var n = JasCore.jas_selection_len(_engine);
        if (n == nuint.MaxValue)
        {
            LastStatus = "SELECTION FAILED: the core reported no session";
            return false;
        }
        // ⛔ SELECTING NOTHING IS A FAILURE HERE, not a quiet success. A marquee
        // over the whole document that selects zero elements means the pointer
        // never reached the tool, and the picture would look identical either way.
        if (n == 0)
        {
            LastStatus = "SELECTION FAILED: the gesture crossed but selected 0 elements";
            return false;
        }

        LastStatus = $"SELECTION '{System.IO.Path.GetFileName(svgPath)}' -- pointer=SYNTHETIC drove "
                   + $"tool 0 through the C ABI at scale {_scaleX:0.##}: {n} element(s) selected, "
                   + $"marquee overlay presented through {SurfaceLabel()} on {Adapter} "
                   + $"loads(shell)={_loadsShell} {Tids()}";
        return true;
    }

    // =======================================================================
    // N3 — THE SCENES THE FREEZE'S OBSERVABLES ARE MEASURED THROUGH
    //
    // ⚠️ NOTHING IN THIS SECTION IS A MEASUREMENT. Every method here EMITS the
    // rows an oracle reads; not one of them asserts, and not one of them has
    // been run -- the shell does not compile on the machine this was written on.
    // The assertions are the harness's (N4) and the numbers are flask's.
    // =======================================================================

    /// <summary>
    /// The SVGs whose hashes are CALIBRATED, by name.
    ///
    /// ⛔ AN UNCALIBRATED SVG IS REFUSED, NOT TOLERATED (FREEZE O1's negative
    /// control). O1 compares hashes with NO TOLERANCE, and it can do that only
    /// because the frame is deterministic for the scene that runs: `Clear` runs
    /// every frame, nothing in the paint path reads a clock or a random source,
    /// MSAA is impossible under the flip model. "Deterministic" is a property of
    /// a PARTICULAR document at a PARTICULAR surface, though, and nobody has
    /// checked it for an arbitrary one -- so the scene refuses by name rather
    /// than producing a hash whose stability is an assumption. The refusal reads
    /// `NOT RUN`, because a run that did not happen is not a run that failed.
    ///
    /// One name, and it is the one the reference renderer has been using:
    /// `complex_document.svg` (819 bytes; two layers, a rounded rect, a circle,
    /// a line in a half-opaque group, and one text element).
    /// </summary>
    private static readonly string[] CalibratedSvgs = { "complex_document.svg" };

    /// <summary>
    /// ⭐ O1's SUBJECT: the RETAINED document, across a resize round trip.
    ///
    /// Load into the HELD engine (never a new one), hash it, MUTATE it with an
    /// operation that is not on disk, hash it again, and then let
    /// `SB_RESIZE=1000x600,original` walk the surface away and back with a hash
    /// at each stop. What the harness asserts on those rows is O1's, not this
    /// method's; what this method owes is that each row is of the frame its
    /// label names.
    ///
    /// ⚖️ FOUR HASH ROWS, NOT THREE, AND THAT IS A DECISION TAKEN WITHOUT AN
    /// OPERATOR. The freeze asks O1 for both `hash(A) == hash(D)` -- the same
    /// SVG through the fresh-engine `document` control -- and `H0 == H2`, the
    /// round trip. Those cannot be the same hash: the mutation lands between
    /// them, so a hash that survives the round trip is a hash of a document the
    /// control never painted. So the pre-mutation frame and the post-mutation
    /// frame are BOTH hashed and BOTH labelled:
    ///
    ///   `A`      after Load, before the mutation  -> the arm `hash(A) == hash(D)` reads
    ///   `A-MUT`  after the mutation, same surface -> the round trip's H0
    ///   `H1`     at the away size                 -> H1 != H0
    ///   `A'`     back at `original`               -> H2, and H2 == A-MUT is retention
    ///
    /// `A != A-MUT` is the mutation's own pixel witness, which the freeze's
    /// three-hash spelling could not carry either.
    /// </summary>
    private bool RenderRetained()
    {
        if (_swapChain is null || _engine == IntPtr.Zero)
        {
            LastStatus = "no swapchain";
            return false;
        }

        var svgPath = Environment.GetEnvironmentVariable("SB_SVG");
        if (string.IsNullOrWhiteSpace(svgPath))
        {
            LastStatus = "SB_SCENE=retained requires SB_SVG=<path to an .svg>";
            return false;
        }

        var name = System.IO.Path.GetFileName(svgPath);
        var calibrated = false;
        foreach (var known in CalibratedSvgs)
        {
            if (string.Equals(name, known, StringComparison.OrdinalIgnoreCase)) { calibrated = true; }
        }
        if (!calibrated)
        {
            LastStatus = $"NOT RUN: uncalibrated SVG '{name}' -- O1 compares hashes with no "
                       + $"tolerance and only these are calibrated: {string.Join(", ", CalibratedSvgs)}";
            return false;
        }

        byte[] bytes;
        try { bytes = System.IO.File.ReadAllBytes(svgPath); }
        catch (Exception ex)
        {
            LastStatus = $"RETAINED FAILED: cannot read '{svgPath}': {ex.GetType().Name}";
            return false;
        }

        // THROUGH COAT 1's OWN LOAD PATH. `jas_load_svg` on the engine `Attach`
        // created; no engine is made here and none is freed, which is what
        // `engines-created=1 engines-freed=0` on the rows below is a witness to.
        if (!ApplyLoad(new LoadCmd { Svg = bytes, Label = name })) { return false; }
        ApplyDump("sb-doc-before.json");
        PaintAndHash("A");

        var synth = Environment.GetEnvironmentVariable("SB_SYNTH_DRAG");
        if (string.IsNullOrWhiteSpace(synth))
        {
            // NO SYNTH: WAIT FOR THE REAL HAND, and hold the resize walk until
            // it lands. Starting the round trip now would carry an unmutated
            // document across it and the receipt would still say `retained`.
            if (!ArmHandWait("retained")) { return false; }
            LastStatus = $"RETAINED '{name}' ({bytes.Length} bytes) loaded into the HELD engine; "
                       + $"hashed as A; WAITING for a real gesture (up to {_handWaitMs}ms) before "
                       + $"the resize round trip. surface={_width}x{_height} {Tids()}";
            return true;
        }

        if (!SyntheticDrag(synth, "retained")) { return false; }
        PaintAndHash("A-MUT");
        ApplyDump("sb-doc-after.json");

        LastStatus = $"RETAINED '{name}' ({bytes.Length} bytes) in the HELD engine; "
                   + $"pointer=SYNTHETIC mutated it; hashed A and A-MUT at "
                   + $"surface={_width}x{_height}; the SB_RESIZE walk hashes the rest "
                   + $"loads(shell)={_loadsShell} {Tids()}";
        return true;
    }

    /// <summary>
    /// ⭐ O3's SUBJECT: a deliberate sleep INSIDE one repaint on the render
    /// thread, and the two controls beside it.
    ///
    /// `SB_RENDER_STALL_MS` is the arm: the render thread sleeps inside a
    /// repaint, a resize posted DURING that sleep piles up in the queue, and the
    /// drain after it applies the LATEST size in exactly one frame. `Responding`
    /// stays True throughout, because the UI thread is not the one sleeping --
    /// that is the coat-3 claim, and it is why `Responding` is a LIVENESS
    /// control and never a residency proof.
    ///
    /// `SB_UI_STALL_MS` is the oracle-liveness control: it sleeps the XAML
    /// thread instead, so `Responding` must read False. Without it a True is
    /// unfalsifiable -- an oracle that cannot say False says nothing when it
    /// says True.
    ///
    /// ⛔ THE COMPLETION IS POSTED BEFORE THE SLEEP. The window drives
    /// `SB_RESIZE` off the scene's completion, so a completion posted after the
    /// stall would put the resize AFTER the stall it is supposed to arrive
    /// during, and the row would read `resize-during-stall=none` on a run that
    /// did everything right.
    /// </summary>
    private bool RenderStall()
    {
        if (_swapChain is null || _engine == IntPtr.Zero)
        {
            LastStatus = "no swapchain";
            return false;
        }

        var renderMs = ParseMs(Environment.GetEnvironmentVariable("SB_RENDER_STALL_MS"));
        _uiStallMs = ParseMs(Environment.GetEnvironmentVariable("SB_UI_STALL_MS"));
        if (renderMs <= 0 && _uiStallMs <= 0)
        {
            LastStatus = "SB_SCENE=stall needs SB_RENDER_STALL_MS or SB_UI_STALL_MS (a positive "
                       + "number of milliseconds); a stall scene that stalls for zero is a "
                       + "scene that measures nothing";
            return false;
        }

        // A document if one was named, so the stalled frame is a picture and not
        // an empty canvas. Optional: O3 is about threads, not about pixels.
        var svgPath = Environment.GetEnvironmentVariable("SB_SVG");
        if (!string.IsNullOrWhiteSpace(svgPath))
        {
            try
            {
                var bytes = System.IO.File.ReadAllBytes(svgPath);
                if (!ApplyLoad(new LoadCmd { Svg = bytes, Label = System.IO.Path.GetFileName(svgPath) }))
                {
                    return false;
                }
            }
            catch (Exception ex)
            {
                LastStatus = $"STALL FAILED: cannot read '{svgPath}': {ex.GetType().Name}";
                return false;
            }
        }

        _report($"STALL ARMED render-stall={renderMs}ms ui-stall={_uiStallMs}ms "
              + $"surface={_width}x{_height} {Tids()}");

        // The window may now drive its SB_RESIZE list: the sleep has not started.
        _scenePostsItsOwnCompletion = true;
        PostToUi(() => SceneCompleted?.Invoke());

        if (_uiStallMs > 0)
        {
            var ms = _uiStallMs;
            PostToUi(() => Thread.Sleep(ms));
        }

        if (renderMs > 0)
        {
            _stallMs = renderMs;
            RepaintOnce("stall", 0);
        }

        LastStatus = $"STALL render-stall={renderMs}ms ui-stall={_uiStallMs}ms slept on the "
                   + $"render thread; the STALL row carries what the post-stall drain applied "
                   + $"{Tids()}";
        return true;
    }

    /// <summary>
    /// ⭐ O4's SUBJECT: load a document, dump it, and WAIT FOR A REAL HAND.
    ///
    /// ⛔ THE WAIT IS A LATCH, NOT A SLEEP, and that is not a style choice: the
    /// hand's events arrive as queue commands, and this method runs on the
    /// thread that drains that queue. A scene that slept here would be waiting
    /// for events only it can deliver. So it arms a deadline, returns, and the
    /// gesture's own `Release` -- through the WinUI handlers, counted nowhere
    /// else -- writes the `POINTER REAL` row and the after-dump.
    ///
    /// ⛔ AND A TIMEOUT IS `NOT RUN`, NEVER A SYNTHETIC RECEIPT WEARING `REAL`
    /// (FREEZE §5 stop 4). `SB_SYNTH_DRAG` on this scene is its CONTROL and says
    /// `pointer=SYNTHETIC` on its own row; the two can never be confused,
    /// because the REAL counters can only be incremented inside the handlers.
    /// </summary>
    private bool RenderPointer()
    {
        if (_swapChain is null || _engine == IntPtr.Zero)
        {
            LastStatus = "no swapchain";
            return false;
        }

        var svgPath = Environment.GetEnvironmentVariable("SB_SVG");
        if (string.IsNullOrWhiteSpace(svgPath))
        {
            LastStatus = "SB_SCENE=pointer requires SB_SVG=<path to an .svg>";
            return false;
        }

        byte[] bytes;
        try { bytes = System.IO.File.ReadAllBytes(svgPath); }
        catch (Exception ex)
        {
            LastStatus = $"POINTER FAILED: cannot read '{svgPath}': {ex.GetType().Name}";
            return false;
        }

        var name = System.IO.Path.GetFileName(svgPath);
        if (!ApplyLoad(new LoadCmd { Svg = bytes, Label = name })) { return false; }
        ApplyDump("sb-doc-before.json");
        RepaintOnce("load", 0);

        var synth = Environment.GetEnvironmentVariable("SB_SYNTH_DRAG");
        if (!string.IsNullOrWhiteSpace(synth))
        {
            if (!SyntheticDrag(synth, "pointer")) { return false; }
            ApplyDump("sb-doc-after.json");
            LastStatus = $"POINTER '{name}' pointer=SYNTHETIC (the CONTROL arm; the hand was "
                       + $"not asked for) surface={_width}x{_height} {Tids()}";
            return true;
        }

        if (!ArmHandWait("pointer")) { return false; }
        LastStatus = $"POINTER '{name}' ({bytes.Length} bytes) loaded; WAITING for a real "
                   + $"gesture (up to {_handWaitMs}ms). A timeout is NOT RUN, never a "
                   + $"synthetic receipt labelled REAL. surface={_width}x{_height} {Tids()}";
        return true;
    }

    /// <summary>
    /// ⭐ O5's SUBJECT (F-2): paint once, announce the PID, and STAY.
    ///
    /// The scene does not run to completion in the sense the others do and it
    /// never exits: it paints one frame, writes a row carrying `pid=`, and
    /// leaves the app pumping until something kills it BY PID. `sitting.ps1
    /// -Stay/-Stop` is the harness's (N4); this is the row it reads, and the row
    /// is also the window's title, because a title is a channel session 0 can
    /// read when a log file is not yet flushed.
    ///
    /// ⚠️ The PID is the row's POINT: `verify_window.ps1`'s old teardown killed
    /// by NAME, which would kill a live `-Stay` belonging to someone else. A
    /// name is not an identity.
    /// </summary>
    private bool RenderStay()
    {
        if (_swapChain is null || _engine == IntPtr.Zero)
        {
            LastStatus = "no swapchain";
            return false;
        }

        var svgPath = Environment.GetEnvironmentVariable("SB_SVG");
        if (!string.IsNullOrWhiteSpace(svgPath))
        {
            try
            {
                var bytes = System.IO.File.ReadAllBytes(svgPath);
                if (!ApplyLoad(new LoadCmd { Svg = bytes, Label = System.IO.Path.GetFileName(svgPath) }))
                {
                    return false;
                }
            }
            catch (Exception ex)
            {
                LastStatus = $"STAY FAILED: cannot read '{svgPath}': {ex.GetType().Name}";
                return false;
            }
        }

        RepaintOnce("stay", 0);

        var pid = Environment.ProcessId;
        LastStatus = $"STAY pid={pid} surface={_width}x{_height} — run-and-stay: this scene "
                   + $"does NOT complete and does NOT exit; stop it by PID {Tids()}";
        return true;
    }

    /// <summary>
    /// Arm the wait for a real hand. Returns false only if the knob is malformed.
    /// </summary>
    private bool ArmHandWait(string scene)
    {
        var waitMs = ParseMs(Environment.GetEnvironmentVariable("SB_POINTER_WAIT_MS"));
        if (waitMs == 0) { waitMs = 30000; }
        if (waitMs < 0)
        {
            LastStatus = "SB_POINTER_WAIT_MS must be a positive number of milliseconds";
            return false;
        }
        _handWaitMs = waitMs;
        _handScene = scene;
        _handPressSeen = false;
        _handDeadlineMs = Environment.TickCount64 + waitMs;
        _scenePostsItsOwnCompletion = true;   // posted when the gesture closes, or on the refusal
        return true;
    }

    /// <summary>
    /// ⭐ THE SEAM'S POSITIVE CONTROL: `SB_SYNTH_DRAG=x,y,dx,dy[,k]`, PHYSICAL
    /// PIXELS, HARNESS-SUPPLIED.
    ///
    /// ⛔ THE SHELL STAYS BLIND TO WHAT IT HITS, AND THAT IS WHAT MAKES THIS A
    /// CONTROL RATHER THAN A SECOND MARQUEE. The harness reads
    /// `sb-doc-before.json`, picks an element and a delta from it, and passes
    /// them in; this method replays them through `jas_pointer_event` and cannot
    /// know which element it moved (BL1). The old synthesised gesture chose its
    /// own coordinates as fractions of the surface, moved nothing, and reported
    /// `press=1 move=2 release=1` for its whole life -- it could not have failed.
    ///
    /// `k` (the number of intermediate moves, default 2) is the fifth field
    /// rather than a knob of its own: O4 asks for k VARIED, and a control that
    /// cannot follow a varied k is weaker than the hand it stands in for. A
    /// fifth field costs no row in the knob table and cannot be set without
    /// setting the drag.
    /// </summary>
    private bool SyntheticDrag(string spec, string scene)
    {
        var parts = spec.Split(',');
        if (parts.Length < 4 || parts.Length > 5)
        {
            LastStatus = $"SB_SYNTH_DRAG='{spec}' malformed: want x,y,dx,dy[,k] in PHYSICAL "
                       + "pixels, the point and the delta chosen by the harness from "
                       + "sb-doc-before.json";
            return false;
        }

        var culture = System.Globalization.CultureInfo.InvariantCulture;
        var style = System.Globalization.NumberStyles.Float;
        if (!double.TryParse(parts[0], style, culture, out var x)
            || !double.TryParse(parts[1], style, culture, out var y)
            || !double.TryParse(parts[2], style, culture, out var dx)
            || !double.TryParse(parts[3], style, culture, out var dy))
        {
            LastStatus = $"SB_SYNTH_DRAG='{spec}': one of x,y,dx,dy is not a number";
            return false;
        }

        var k = 2;
        if (parts.Length == 5 && !int.TryParse(parts[4], out k))
        {
            LastStatus = $"SB_SYNTH_DRAG='{spec}': k (the move count) is not a number";
            return false;
        }
        if (k < 1)
        {
            LastStatus = $"SB_SYNTH_DRAG='{spec}': k must be at least 1 -- a drag with no move "
                       + "is a click, and it is not what this control exists to replay";
            return false;
        }

        JasCore.jas_pointer_event(_engine, JasCore.PointerPress, x, y, 0);
        for (var i = 1; i <= k; i++)
        {
            var t = (double)i / k;
            JasCore.jas_pointer_event(_engine, JasCore.PointerMove,
                x + (dx * t), y + (dy * t), JasCore.ModDragging);
        }
        JasCore.jas_pointer_event(_engine, JasCore.PointerRelease, x + dx, y + dy, 0);

        // THE SAME RECEIPT WRITER AS THE HAND'S, with a Kind that can never read
        // REAL. One row shape, two provenances, and the provenance is a field.
        ApplyPointerReport(new PointerReportCmd
        {
            Kind = "SYNTHETIC",
            PointerId = 0,
            Device = "Synthetic",
            Hit = "NONE",
            Press = 1,
            Move = k,
            Release = 1,
            PressX = x,
            PressY = y,
            ReleaseX = x + dx,
            ReleaseY = y + dy,
        });
        _report($"SYNTH-DRAG scene={scene} spec='{spec}' k={k} press@=({x:F1},{y:F1}) "
              + $"release@=({x + dx:F1},{y + dy:F1}) surface={_width}x{_height} {Tids()}");
        return true;
    }

    /// <summary>
    /// A millisecond knob's VALUE. 0 when unset, -1 when it is set to something
    /// that is not a number -- so "unset" and "nonsense" reach DIFFERENT branches
    /// at the call site instead of both defaulting quietly.
    ///
    /// ⛔ IT TAKES THE VALUE, NOT THE KNOB'S NAME, and that is O7's requirement
    /// rather than a preference: `GetEnvironmentVariable(name)` with a variable
    /// is a read the knob census cannot attribute, and that census REFUSES to
    /// guess rather than reporting a complete table over knobs it cannot see. So
    /// every knob in this shell is read at its own call site, as a literal.
    /// </summary>
    private static int ParseMs(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) { return 0; }
        return int.TryParse(raw, out var ms) ? ms : -1;
    }

    /// <summary>
    /// One golden, painted into the back buffer and presented <c>hold</c> times.
    /// The back buffer is re-fetched and re-released around EVERY present.
    /// </summary>
    private int PaintOnce(IntPtr scene, nuint len, int hold, ref string? failure)
    {
        var rc = JasCore.PaintOk;
        for (var f = 0; f < hold; f++)
        {
            _swapChain!.GetBuffer<IDXGISurface>(0, out var back);
            var ptr = Marshal.GetComInterfaceForObject(back, typeof(IDXGISurface));
            try
            {
                _paintTid = Environment.CurrentManagedThreadId;
                rc = JasCore.jas_paint_scene(ptr, scene, len, _width, _height);
            }
            finally
            {
                Marshal.Release(ptr);
            }
            if (rc != JasCore.PaintOk) { return rc; }

            _presentTid = Environment.CurrentManagedThreadId;
            var hr = _swapChain!.Present(1, default);
            if (hr.Failed) { failure = $"Present 0x{hr.Value:X8}"; return rc; }
            // Occlusion is NOT fatal here, and that is a deliberate difference
            // from Benchmark. That method reports per-frame TIMINGS, which are
            // meaningless for frames nobody saw. This one reports which goldens
            // the core could draw -- a fact about the painter.
        }
        return rc;
    }

    /// <summary>
    /// How long each held scene stays on screen, in presents. At a sync interval
    /// of 1 that is ~16 ms apiece; the default holds each for ~200 ms, so a human
    /// sees a slideshow rather than a flicker.
    /// </summary>
    private static int SceneHold() =>
        int.TryParse(Environment.GetEnvironmentVariable("SB_SCENE_HOLD"), out var hv) ? hv : 12;

    // =======================================================================
    // THE HASH — O1's instrument
    // =======================================================================

    /// <summary>
    /// SHA-256 of the back buffer, read through a STAGING texture.
    ///
    /// ⛔ EXACTLY `w * 4` BYTES PER ROW, WALKING `RowPitch`, AND NEVER
    /// `RowPitch * h`. A mapped D3D11 resource is padded: `RowPitch` is at least
    /// `w * 4` and is usually more, and the padding is UNINITIALISED memory. A
    /// hash over the whole mapped extent would therefore be a hash of the
    /// padding as much as of the picture -- unstable between runs for a reason
    /// that has nothing to do with what was drawn, and the first instinct on
    /// seeing it wobble would be to add a tolerance to a comparison that needs
    /// none.
    ///
    /// NO TOLERANCE IS THE DESIGN (§D): `Clear` runs every frame
    /// (`ffi_paint.rs:745-746`), nothing in the paint path reads a clock or a
    /// random source, MSAA is impossible under the flip model, and at 96 DPI with
    /// integer geometry there is no anti-aliasing to vary. So the hash is exact
    /// or the run is refused.
    /// </summary>
    private string? BackBufferSha256(out string note)
    {
        note = "ok";
        if (_swapChain is null || _device is null || _immediate is null)
        {
            note = "hash: no device";
            return null;
        }

        try
        {
            _swapChain!.GetBuffer<ID3D11Texture2D>(0, out var backTex);
            var backRes = (ID3D11Resource)backTex;

            var desc = new D3D11_TEXTURE2D_DESC
            {
                Width = _width,
                Height = _height,
                MipLevels = 1,
                ArraySize = 1,
                Format = DXGI_FORMAT.DXGI_FORMAT_B8G8R8A8_UNORM,
                SampleDesc = new DXGI_SAMPLE_DESC { Count = 1, Quality = 0 },
                Usage = D3D11_USAGE.D3D11_USAGE_STAGING,
                BindFlags = 0,
                CPUAccessFlags = D3D11_CPU_ACCESS_FLAG.D3D11_CPU_ACCESS_READ,
                MiscFlags = 0,
            };
            _device!.CreateTexture2D(in desc, null, out var staging);
            var stagingRes = (ID3D11Resource)staging;

            _immediate!.CopyResource(stagingRes, backRes);

            D3D11_MAPPED_SUBRESOURCE mapped = default;
            _immediate!.Map(stagingRes, 0, D3D11_MAP.D3D11_MAP_READ, 0, &mapped);
            try
            {
                using var sha = SHA256.Create();
                var rowBytes = checked((int)(_width * 4));
                var row = new byte[rowBytes];
                var basePtr = (byte*)mapped.pData;
                for (uint y = 0; y < _height; y++)
                {
                    Marshal.Copy((IntPtr)(basePtr + (y * mapped.RowPitch)), row, 0, rowBytes);
                    sha.TransformBlock(row, 0, rowBytes, null, 0);
                }
                sha.TransformFinalBlock(Array.Empty<byte>(), 0, 0);
                return Convert.ToHexString(sha.Hash!).ToLowerInvariant();
            }
            finally
            {
                _immediate!.Unmap(stagingRes, 0);
            }
        }
        catch (Exception ex)
        {
            note = $"hash: {ex.GetType().Name}: {ex.Message}";
            return null;
        }
    }

    /// <summary>
    /// The surface, stated so it cannot be misread.
    ///
    /// Under no scaling this is one number. Under scaling it names BOTH sizes and
    /// the factor between them, because the buffer is the DIP one and the screen
    /// is the physical one -- and a reader quoting "the surface" from this line
    /// would otherwise quote a resolution that was never rendered (jyh/jas#16).
    /// </summary>
    private string SurfaceLabel()
    {
        if (Math.Abs(_scaleX - 1f) < 0.001f && Math.Abs(_scaleY - 1f) < 0.001f)
        {
            return $"{_width}x{_height}px";
        }
        var pw = (uint)Math.Round(_width * _scaleX);
        var ph = (uint)Math.Round(_height * _scaleY);
        return $"{_width}x{_height}DIP buffer @scale {_scaleX:0.##}x{_scaleY:0.##} "
             + $"-> {pw}x{ph}px on screen (COMPOSITOR UPSCALES; jyh/jas#16)";
    }
}
