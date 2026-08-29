using System.Runtime.InteropServices;
using Microsoft.UI.Xaml.Controls;
using Windows.Win32;
using Windows.Win32.Graphics.Direct3D;
using Windows.Win32.Graphics.Direct3D11;
using Windows.Win32.Graphics.Dxgi;
using Windows.Win32.Graphics.Dxgi.Common;
using WinRT;

namespace SbWinUi;

/// <summary>
/// <c>ISwapChainPanelNative</c>, hand-declared.
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

/// <summary>
/// Owns the D3D11 device and the composition swapchain, and lends Rust a back
/// buffer to draw into.
///
/// THE OWNERSHIP DIRECTION IS THE POINT OF S-B, and it follows from the ratified
/// boundary laws rather than convenience:
///
/// * BL6 says geometry never crosses, so Rust rasterizes and this shell supplies
///   the canvas. A shell that received geometry and drew it would be the third
///   interpreter D1 rejected.
/// * BL4 keeps every crossing allocation Rust-owned and released by
///   <c>jas_free</c>. If Rust created the swapchain and handed it back, this side
///   would hold a Rust-created COM object released by <c>Release</c> instead:
///   two ownership rules on a boundary whose whole value is having one.
///
/// So the device, the swapchain and the back buffer are all ours. Resize is ours
/// too, which is the practical dividend: <c>ResizeBuffers</c> happens here with
/// no round trip, and Rust never holds a reference that would have to be dropped
/// first.
/// </summary>
internal sealed unsafe class SwapChainHost : IDisposable
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
    /// <c>SdkVersion</c> is one: it is not in the generated metadata here, and a
    /// bare hex number in a comparison is what a later reader cannot check.
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

    private ID3D11Device? _device;
    private ID3D11DeviceContext? _immediate;
    private ID3D11Texture2D? _offscreen;
    private ID3D11Resource? _offscreenRes;

    // NO Marshal.ReleaseComObject ANYWHERE IN THE FRAME PATH, and that is a fix
    // rather than a style choice. It was added as an experiment (testing whether
    // an outstanding back-buffer reference was blocking Present -- it was not)
    // and left in. Over sixty frames it corrupted the heap: the host died with
    // 0xC0000374 in ntdll, while the SAME build on the direct route survived
    // because that route stops at frame 1 and never accumulated the damage.
    //
    // ReleaseComObject decrements a reference the runtime is also tracking, so
    // pairing it with an explicit Marshal.Release double-releases. The RCW's own
    // reference belongs to the runtime; only the pointer taken by
    // GetIUnknownForObject belongs to this code.

    /// <summary>
    /// OFFSCREEN mode: Rust paints a texture WE own, and we copy it into the back
    /// buffer. DIRECT mode: Rust paints the back buffer itself.
    ///
    /// Both are legitimate designs, not a workaround and a real one. Direct is
    /// zero-copy and is what the variant wants; offscreen costs one full-surface
    /// GPU copy per frame and is what every compositor-hosted renderer that
    /// cannot touch the swapchain does. S-C has to price that copy either way, so
    /// measuring it here is not detour work.
    /// </summary>
    public static bool OffscreenMode =>
        Environment.GetEnvironmentVariable("SB_MODE") != "direct";
    private IDXGISwapChain1? _swapChain;
    private uint _width;
    private uint _height;

    /// <summary>
    /// The panel's composition scale at the last (re)size, recorded so the run
    /// can SAY what it rendered.
    ///
    /// ⛔ THIS DOES NOT FIX THE DIP DEFECT (jyh/jas#16) -- IT STOPS THE RUN LYING
    /// ABOUT IT. `Canvas.SizeChanged` reports DIPs, and that value goes straight
    /// into swapchain creation while `CompositionScaleX/Y` is read nowhere, so
    /// under 150% scaling the core renders 3.60 Mpx and the compositor upscales
    /// to 8.29. That is a fidelity defect and it is deliberately still booked:
    /// fixing it properly means sizing the buffer in physical pixels AND applying
    /// the inverse transform (IDXGISwapChain2::SetMatrixTransform), and I cannot
    /// see the result -- Smart App Control blocks this app from opening a window
    /// on this box. **A fidelity change made blind is not a fix, it is a guess.**
    ///
    /// What IS fixable without a window is the LABEL. `LastStatus` printed
    /// `{_width}x{_height}` with no unit, which reads as the surface and is the
    /// DIP size. Same class as every other defect this branch has found: a value
    /// that describes something other than what it claims. The run now states
    /// DIP size, scale, and the physical pixels the compositor actually fills,
    /// so nobody can quote a surface size this harness never rendered.
    /// </summary>
    private float _scaleX = 1f;
    private float _scaleY = 1f;

    public string LastStatus { get; private set; } = "not started";
    public string Adapter { get; private set; } = "unknown";
    public string BareStatus { get; private set; } = "not tried";
    public string PaintNote { get; private set; } = "not run";
    /// <summary>The last resize, split into its three parts. "not resized" until one happens.</summary>
    public string ResizeCost { get; private set; } = "not resized";
    public string DebugLayer { get; private set; } = "off";

    /// <summary>
    /// Whatever the D3D debug layer has to say. Empty when the layer is absent.
    /// </summary>
    private string DrainInfoQueue()
    {
        try
        {
            if (_device is not IDXGIDevice) { /* keep the cast attempt below honest */ }
            var iq = (ID3D11InfoQueue)_device!;
            var n = iq.GetNumStoredMessages();
            if (n == 0) return "info queue empty";
            var lines = new List<string>();
            for (ulong i = n > 6 ? n - 6 : 0; i < n; i++)
            {
                nuint len = 0;
                iq.GetMessage(i, null, ref len);
                var buf = Marshal.AllocHGlobal((int)len);
                try
                {
                    iq.GetMessage(i, (Windows.Win32.Graphics.Direct3D11.D3D11_MESSAGE*)buf, ref len);
                    var msg = (Windows.Win32.Graphics.Direct3D11.D3D11_MESSAGE*)buf;
                    var text = Marshal.PtrToStringAnsi((IntPtr)msg->pDescription, (int)msg->DescriptionByteLength).TrimEnd('\0');
                    lines.Add(text);
                }
                finally { Marshal.FreeHGlobal(buf); }
            }
            return string.Join(" || ", lines);
        }
        catch (Exception ex)
        {
            return $"info queue unavailable ({ex.GetType().Name})";
        }
    }

    /// <summary>Create the device and swapchain, and bind them to the panel.</summary>
    public void Attach(SwapChainPanel panel, uint width, uint height)
    {
        _width = Math.Max(width, 1);
        _height = Math.Max(height, 1);
        // Recorded, not applied -- see the field comment. A scale of 1 means the
        // DIP size and the physical size coincide and the label collapses to one
        // number; anything else means the compositor is upscaling.
        _scaleX = panel.CompositionScaleX <= 0 ? 1f : panel.CompositionScaleX;
        _scaleY = panel.CompositionScaleY <= 0 ? 1f : panel.CompositionScaleY;

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
            // and MSAA is not permitted, which is why SampleDesc is 1/0.
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

        // Must happen on the UI thread; so must every later Present.
        var native = panel.As<ISwapChainPanelNative>();
        var unk = Marshal.GetIUnknownForObject(_swapChain);
        try
        {
            native.SetSwapChain(unk);
        }
        finally
        {
            // SetSwapChain addrefs what it keeps; this is our own reference.
            // (Tested: omitting this does NOT change Present's failure, so the
            // release was never the cause -- it is kept because it is correct.)
            Marshal.Release(unk);
        }
    }

    /// <summary>
    /// (Re)create the offscreen target at the CURRENT `_width`/`_height`.
    ///
    /// SPLIT OUT OF `Attach` FOR THE RESIZE PATH, and the split is the fix rather
    /// than tidying: while this lived inline it ran exactly once, so the target
    /// kept its initial size for the life of the window. The comment above it
    /// said "same size and format as the back buffer" -- true when it ran, and
    /// assumed forever after.
    /// </summary>
    private void CreateOffscreenTarget()
    {
        // Same size and format as the back buffer AT THIS MOMENT, bindable as a
        // render target so Direct2D can draw into it, and copyable to the back
        // buffer with a single CopyResource.
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
    /// a mismatched copy instead of faulting, and the debug layer that would
    /// report the drop is an optional Windows feature that is not installed on
    /// this box. Before the Rust-side guard existed, that combination returned
    /// OK and presented a STALE FRAME. So this method exists as one unit, and
    /// `jas_paint_probe_offscreen` refuses if it is ever half-done.
    ///
    /// THE OLD BUFFER REFERENCES MUST BE GONE FIRST. `ResizeBuffers` fails with
    /// DXGI_ERROR_INVALID_CALL while any back-buffer reference is outstanding.
    /// `RenderFrame` releases the surface it borrows every frame -- see the note
    /// there, which says a leak here "manifests as a resize that silently stops
    /// working". That sentence described a resize that did not exist when it was
    /// written; it describes this one.
    ///
    /// Called on the UI thread, like every other swapchain operation (BL2).
    /// </summary>
    public bool Resize(uint width, uint height)
    {
        if (_swapChain is null || _device is null) { LastStatus = "resize: not started"; return false; }
        var w = Math.Max(width, 1);
        var h = Math.Max(height, 1);
        if (w == _width && h == _height) return true;

        // Drop our reference to the old target BEFORE resizing, so the only
        // outstanding references are the swapchain's own.
        _offscreenRes = null;
        _offscreen = null;

        // MEASURED, NOT ANTICIPATED: without the two lines below, ResizeBuffers
        // threw DXGI_ERROR_INVALID_CALL (0x887A0001) on BOTH routes, every time.
        //
        // RenderFrame calls GetBuffer<IDXGISurface>, which hands back a managed
        // RCW. The raw interface pointer taken from it IS released each frame,
        // but the RCW itself is only released when the GC finalizes it -- which
        // is non-deterministic and had not happened by the time Resize ran. DXGI
        // refuses ResizeBuffers while ANY back-buffer reference is outstanding,
        // so the resize failed on a reference nothing in the frame path looked
        // like it was holding.
        //
        // The file's own comment predicted this in the abstract -- "skipping the
        // release leaks a buffer reference per frame, which manifests as a resize
        // that silently stops working" -- written when no resize existed. It does
        // not manifest silently; it throws. The comment was right about the cause
        // and wrong about the symptom, which is worth more than either alone.
        //
        // AND THE FIX IS DELIBERATELY HERE AND NOT IN THE FRAME PATH. The README
        // records Marshal.ReleaseComObject in the per-frame path corrupting the
        // heap over sixty frames (0xC0000374 in ntdll), and FinalReleaseComObject
        // crashing outright by over-release. A collection at RESIZE time runs
        // once per user gesture, releases the outstanding RCWs deterministically,
        // and never touches the hot path that was corrupting.
        var swGc = System.Diagnostics.Stopwatch.StartNew();
        GC.Collect();
        GC.WaitForPendingFinalizers();
        swGc.Stop();

        // ⚠️ `ResizeBuffers` IS PROJECTED AS `void`, NOT AS AN HRESULT, unlike
        // `Present` a few lines below which returns one and is checked with
        // `hr.Failed`. CsWin32 generates it PreserveSig(false), so failure
        // arrives as a thrown COMException and an `if` on the return value does
        // not compile. Two neighbouring calls on the SAME interface with two
        // different error conventions is exactly the kind of thing that gets
        // "tidied" into a silent hole later, so it is named here.
        //
        // 0 buffers / UNKNOWN format = "keep the count and format you had", so a
        // throw here is a real failure and not a description mismatch.
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
            // The target is gone and the swapchain is in an unknown state; say so
            // rather than limping on with a null target and a misleading size.
            _width = 0; _height = 0;
            return false;
        }

        _width = w;
        _height = h;
        var swTgt = System.Diagnostics.Stopwatch.StartNew();
        // ONLY THE ROUTE THAT USES IT PAYS FOR IT. Measured 08/28: this ran
        // unconditionally, so the DIRECT route allocated an offscreen target it
        // never touches -- on every resize, and in Attach before that. Reported
        // in REPORT-RESIZE rather than fixed mid-sweep, because changing the
        // instrument between arms is the one thing the control-pair method
        // exists to prevent. Fixed now that the sweep is banked.
        //
        // It does not move the published number: target-recreate was 0.11ms on
        // BOTH routes, so removing it from direct changes direct's total by that
        // and leaves the OFFSCREEN-MINUS-DIRECT comparison exactly where it was.
        if (OffscreenMode) { CreateOffscreenTarget(); }
        swTgt.Stop();

        // THE THREE PARTS ARE REPORTED SEPARATELY, and the GC one especially.
        //
        // The collect is MY addition (it is what makes ResizeBuffers legal at
        // all here), so folding it into one "resize cost" would price my repair
        // as if it were the platform's. Whoever optimises this needs to see which
        // third is which -- and the OFFSCREEN route is the only one that pays the
        // target-recreation third, which is precisely the per-route difference
        // the coupling argument is about.
        ResizeCost = $"rcw-release={swGc.Elapsed.TotalMilliseconds:F2}ms "
                   + $"resizebuffers={swBuf.Elapsed.TotalMilliseconds:F2}ms "
                   + $"target-recreate={swTgt.Elapsed.TotalMilliseconds:F2}ms";
        LastStatus = $"resized to {SurfaceLabel()} :: {ResizeCost}";
        return true;
    }

    /// <summary>
    /// Hand the back buffer to Rust, then present.
    ///
    /// The surface reference is released here, every frame. Rust borrowed it and
    /// did not addref, so this side is the only owner; skipping the release
    /// leaks a buffer reference per frame, which manifests as a resize that
    /// silently stops working rather than as a leak anybody notices.
    /// </summary>
    /// <summary>
    /// Draw and present, by whichever route SB_MODE selects, and TIME IT.
    ///
    /// The timings are the point as much as the pixels: S-C has to price the
    /// offscreen copy against the direct path, and a copy whose cost is asserted
    /// rather than measured is the kind of number this fleet keeps having to
    /// correct. Frames are run in a loop so one scheduling hiccup does not become
    /// the figure.
    /// </summary>
    public bool RenderFrame()
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
                // Rust paints the offscreen surface and copies it in; Direct2D
                // never touches the back buffer. Timed as ONE number and named
                // that way -- splitting paint from copy would need two crossings
                // and would measure the split, not the work.
                _swapChain.GetBuffer<IDXGISurface>(0, out var back);
                // GetComInterfaceForObject, NOT GetIUnknownForObject, AND THIS IS
                // THE HEAP CORRUPTION.
                //
                // GetIUnknownForObject returns the object's IUnknown pointer.
                // Rust receives it as an IDXGISurface* and calls through that
                // vtable. For a COM object exposing several interfaces those are
                // DIFFERENT pointers, so every call lands on a wrong slot -- which
                // is undefined behaviour, and manifested as 0xC0000374 in ntdll
                // rather than as a clean failure.
                //
                // It survived on the direct route because a swapchain back buffer
                // hands back an IUnknown that coincides with its IDXGISurface, so
                // the wrong-pointer bug was invisible there. The offscreen target
                // is an ID3D11Texture2D, whose IUnknown is NOT its IDXGISurface,
                // and the same code then corrupts the heap. A latent defect that
                // only one of two callers could expose.
                var backPtr = Marshal.GetComInterfaceForObject(back, typeof(IDXGISurface));
                var offPtr = Marshal.GetComInterfaceForObject(_offscreen!, typeof(IDXGISurface));
                try
                {
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
                // Same correction as the offscreen branch above: ask for the
                // interface Rust will actually call through. This route happened
                // to work with the IUnknown pointer, which is precisely why it
                // was worth fixing here too rather than only where it broke.
                var ptr = Marshal.GetComInterfaceForObject(target, typeof(IDXGISurface));
                try
                {
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

            sw.Restart();
            var hr = _swapChain.Present(1, default);
            sw.Stop();
            present.Add(sw.Elapsed.TotalMilliseconds);
            if (hr.Failed) { failure = $"Present 0x{hr.Value:X8}"; break; }

            // ⛔ OCCLUSION IS A SUCCESS CODE, AND THIS LINE USED NOT TO EXIST.
            //
            // `hr.Failed` above tests the sign bit. DXGI_STATUS_OCCLUDED has it
            // clear, so an occluded present passed straight through and was
            // counted as an ordinary frame -- while its documented meaning is
            // that THE PRESENT WAS INVISIBLE TO THE USER.
            //
            // For this harness that is not a cosmetic gap. Every timing it
            // reports is a per-frame cost, and a run whose frames nobody saw
            // produces numbers that describe a different experiment than the one
            // requested -- the same failure mode as the unforwarded SB_FRAMES,
            // reached through the graphics stack instead of the launcher. The
            // runs happen on a busy desktop (the verifier's own capture lists
            // Chrome, Settings, a terminal and explorer), so occlusion is a live
            // possibility and not a theoretical one.
            //
            // Counted rather than broken out of: which frames were invisible is
            // the diagnostic, and breaking on the first would throw it away.
            if (hr.Value == StatusOccluded) { occluded++; }
        }

        // ⛔ AN OCCLUDED RUN IS RED, NOT A SLOW ONE. Reporting timings from
        // frames nobody saw would be reporting a measurement that did not
        // happen -- and it would look entirely plausible, which is what makes it
        // worth failing on. The count and the denominator both travel, because
        // "3 of 300" and "300 of 300" are different diagnoses.
        if (failure is null && occluded > 0)
        {
            failure = $"OCCLUDED {occluded}/{present.Count} presents were INVISIBLE TO THE USER "
                    + "(DXGI_STATUS_OCCLUDED, a success code) -- these timings do not describe "
                    + "frames anyone saw; re-run with the window unobscured";
        }

        static string Stat(string name, List<double> xs)
        {
            if (xs.Count == 0) return $"{name} n/a";
            if (xs.Count == 1) return $"{name} first={xs[0]:F2}ms (one frame only)";

            // THE FIRST FRAME IS EXCLUDED FROM THE MEAN, not merely printed
            // beside it. It carries device warm-up, shader compilation and
            // one-time allocation: measured here at 1092ms on the offscreen route
            // against a 0.71ms minimum. Averaging that in produced a "mean" of
            // 19.20ms that described nothing -- not the first frame, not the
            // steady state, and it would have gone into S-C's comparison as the
            // cost of a copy.
            var rest = xs.Skip(1).ToList();
            return $"{name} first={xs[0]:F2}ms steady-mean={rest.Average():F2}ms " +
                   $"min={rest.Min():F2}ms max={rest.Max():F2}ms n={rest.Count}+1";
        }

        var route = offscreen ? "OFFSCREEN+copy" : "DIRECT";
        if (failure is not null)
        {
            LastStatus = $"{route} FAILED at frame {paint.Count}: {failure} [{Stat("paint", paint)}]";
            return false;
        }

        LastStatus = $"{route} {SurfaceLabel()} on {Adapter} :: " +
                     $"{Stat("paint", paint)} | {Stat("paint+copy", copy)} | {Stat("present", present)}";
        return true;
    }

    /// <summary>
    /// The surface, stated so it cannot be misread.
    ///
    /// Under no scaling this is one number and reads as it always did. Under
    /// scaling it names BOTH sizes and the factor between them, because the
    /// buffer is the DIP one and the screen is the physical one -- and a reader
    /// quoting "the surface" from this line would otherwise quote a resolution
    /// that was never rendered. The unit is spelled out for the same reason the
    /// measurement doctrine puts the unit beside the number.
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

    public void Dispose()
    {
        _swapChain = null;
        _device = null;
    }
}
