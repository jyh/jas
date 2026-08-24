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

    private ID3D11Device? _device;
    private IDXGISwapChain1? _swapChain;
    private uint _width;
    private uint _height;

    public string LastStatus { get; private set; } = "not started";
    public string Adapter { get; private set; } = "unknown";
    public string BareStatus { get; private set; } = "not tried";

    /// <summary>Create the device and swapchain, and bind them to the panel.</summary>
    public void Attach(SwapChainPanel panel, uint width, uint height)
    {
        _width = Math.Max(width, 1);
        _height = Math.Max(height, 1);

        // BGRA_SUPPORT is REQUIRED for Direct2D interop, and omitting it fails
        // later and elsewhere: the device creates fine and D2D refuses the
        // surface, which reads as a D2D fault rather than a device flag.
        const D3D11_CREATE_DEVICE_FLAG flags = D3D11_CREATE_DEVICE_FLAG.D3D11_CREATE_DEVICE_BGRA_SUPPORT;

        // WARP fallback so a box with no usable GPU produces a slow frame rather
        // than an unexplained device failure. The Rust-side tests use WARP for
        // the same reason.
        var hr = PInvoke.D3D11CreateDevice(
            null, D3D_DRIVER_TYPE.D3D_DRIVER_TYPE_HARDWARE, default, flags, default,
            SdkVersion, out var device, out _);
        Adapter = "hardware";
        if (hr.Failed)
        {
            PInvoke.D3D11CreateDevice(
                null, D3D_DRIVER_TYPE.D3D_DRIVER_TYPE_WARP, default, flags, default,
                SdkVersion, out device, out _).ThrowOnFailure();
            Adapter = "warp";
        }
        _device = device;

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
    /// Hand the back buffer to Rust, then present.
    ///
    /// The surface reference is released here, every frame. Rust borrowed it and
    /// did not addref, so this side is the only owner; skipping the release
    /// leaks a buffer reference per frame, which manifests as a resize that
    /// silently stops working rather than as a leak anybody notices.
    /// </summary>
    public bool RenderFrame()
    {
        if (_swapChain is null)
        {
            LastStatus = "no swapchain";
            return false;
        }

        _swapChain.GetBuffer<IDXGISurface>(0, out var surface);
        var surfacePtr = Marshal.GetIUnknownForObject(surface);
        try
        {
            var rc = JasCore.jas_paint_probe_surface(surfacePtr, _width, _height);
            if (rc != JasCore.PaintOk)
            {
                LastStatus = $"rust paint failed: {JasCore.Explain(rc)}";
                return false;
            }
        }
        finally
        {
            Marshal.Release(surfacePtr);
            // ...and the RCW's own reference from GetBuffer. ONE decrement, not
            // FinalReleaseComObject: that releases every outstanding reference at
            // once and crashed the app before its window appeared.
            Marshal.ReleaseComObject(surface);
        }

        // SyncInterval 1: one frame is all this checkpoint draws, and vsync keeps
        // the single Present from racing the compositor's first paint.
        //
        // NOT ThrowOnFailure. That maps the HRESULT onto a CLR exception type and
        // throws the number away: a failing Present surfaced as
        // "InvalidCastException: Specified cast is not valid", which points at a
        // cast that does not exist in this method. The same collapse the Rust
        // side had to undo one commit earlier -- keep the code, print the code.
        // DISCRIMINATOR: is the interface dispatch itself healthy? GetDesc1 is
        // harmless and reads back what we asked for. If IT works, the vtable is
        // fine and Present is failing for its own reasons; if it does not, the
        // problem is how this interface is being called, not what is being asked.
        string descNote;
        try
        {
            var live = _swapChain.GetDesc1();
            descNote = $"GetDesc1 ok {live.Width}x{live.Height} buffers={live.BufferCount}";
        }
        catch (Exception dex)
        {
            descNote = $"GetDesc1 threw {dex.GetType().Name}";
        }

        // Present1 is IDXGISwapChain1's OWN method; Present is inherited from
        // IDXGISwapChain. Trying both separates "this call is wrong" from "this
        // interface is reached wrongly".
        var hr = _swapChain.Present(1, default);
        var p1 = default(Windows.Win32.Foundation.HRESULT);
        if (hr.Failed)
        {
            var pp = new DXGI_PRESENT_PARAMETERS();
            p1 = _swapChain.Present1(1, default, in pp);
            if (p1.Failed)
            {
                LastStatus = $"Present 0x{hr.Value:X8} / Present1 0x{p1.Value:X8} [{descNote}] [{BareStatus}]";
                return false;
            }
        }
        LastStatus = $"presented {_width}x{_height} on {Adapter}";
        return true;
    }

    public void Dispose()
    {
        _swapChain = null;
        _device = null;
    }
}
