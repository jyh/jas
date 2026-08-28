using System.Reflection;
using System.Runtime.InteropServices;

namespace SbWinUi;

/// <summary>
/// The Rust core, as this shell sees it.
///
/// BL5 is why there is not one <c>string</c> in any signature here, exactly as
/// in the S-A spike: the default P/Invoke <c>CharSet</c> is <c>Ansi</c>, which is
/// the active code page (cp1252 on this box), and a <c>string</c> parameter would
/// silently mangle non-Latin-1 content in both directions. Nothing textual
/// crosses in this checkpoint, and when it does it will cross as a byte span.
/// </summary>
internal static class JasCore
{
    private const string Lib = "jas_dioxus";

    /// <summary>Status codes from <c>ffi_paint.rs</c>. Mirrored, not guessed.</summary>
    internal const int PaintOk = 0;
    internal const int PaintNullSurface = 1;
    internal const int PaintNotASurface = 2;
    /// <summary>
    /// The two surfaces disagree on size or format, so the copy would be DROPPED.
    ///
    /// ADDED WITH THE RESIZE PATH, and the `Explain` arm below matters as much as
    /// the constant: without it a 3 falls through to the HRESULT formatter and is
    /// reported as "HRESULT 0x00000003" -- a positive sentinel dressed up as a COM
    /// error, sending the next reader to look for a COM fault that never happened.
    /// </summary>
    internal const int PaintSizeMismatch = 3;
    /// <summary>
    /// The two surfaces belong to DIFFERENT D3D11 devices.
    ///
    /// The device-lost analogue of the size mismatch, and the platform treats the
    /// two oppositely: a size mismatch is dropped silently, a cross-device copy
    /// REMOVES the destination's device (0x887A0020, DRIVER_INTERNAL_ERROR).
    /// Reaching this code means the host recreated its device after a removal and
    /// kept an offscreen target belonging to the old one.
    /// </summary>
    internal const int PaintDeviceMismatch = 4;

    /// <summary>
    /// Render a paint status for a human.
    ///
    /// Anything that is not 0 or a positive sentinel IS AN HRESULT, so it is
    /// printed in hex. A COM error shown in decimal is effectively unsearchable
    /// -- nobody looks up -2005270523, and everybody recognises 0x887A0005.
    /// </summary>
    internal static string Explain(int rc) => rc switch
    {
        PaintOk => "ok",
        PaintNullSurface => "null surface",
        PaintNotASurface => "not an IDXGISurface",
        PaintSizeMismatch => "SIZE/FORMAT MISMATCH -- back buffer and offscreen target disagree; the host resized one and not the other",
        PaintDeviceMismatch => "DEVICE MISMATCH -- back buffer and offscreen target are on different D3D11 devices; the host recreated one after a device loss and kept the other",
        _ => $"HRESULT 0x{rc:X8}",
    };

    /// <summary>
    /// Paint the S-B probe pattern into a DXGI surface THIS SIDE OWNS.
    ///
    /// The surface is borrowed for the duration of the call: Rust addrefs
    /// nothing and releases nothing, so the caller keeps its reference and is
    /// free to resize or drop the swapchain the moment this returns.
    ///
    /// BL2: call on the thread that owns the device context. For this host that
    /// is the UI thread, which is also the only thread
    /// <c>ISwapChainPanelNative.SetSwapChain</c> may be called on.
    /// </summary>
    [DllImport(Lib)]
    internal static extern int jas_paint_probe_surface(IntPtr dxgiSurface, float width, float height);

    /// <summary>
    /// Paint an offscreen surface and GPU-copy it into the back buffer, both
    /// host-owned and both borrowed for the call.
    ///
    /// The copy is on the Rust side because C#'s CopyResource threw
    /// InvalidCastException out of InterfaceMarshaler.ConvertToNative even with
    /// both arguments already typed as ID3D11Resource. windows-rs calls COM
    /// directly, with no CLR marshaller in between.
    /// </summary>
    [DllImport(Lib)]
    internal static extern int jas_paint_probe_offscreen(
        IntPtr backSurface, IntPtr offscreenSurface, float width, float height);

    /// <summary>
    /// Point the loader at the cdylib.
    ///
    /// The DLL is a cargo build artifact, not a NuGet asset, so it is not beside
    /// the exe. <c>JAS_CORE_DLL</c> overrides; otherwise the default is the
    /// debug cdylib relative to this repo. Failing LOUDLY here matters: a
    /// resolver that quietly returns zero produces a <c>DllNotFoundException</c>
    /// at the first call site instead, which reads as a missing function rather
    /// than a missing file.
    /// </summary>
    internal static void Bind()
    {
        var explicitPath = Environment.GetEnvironmentVariable("JAS_CORE_DLL");
        var dll = !string.IsNullOrWhiteSpace(explicitPath) ? explicitPath : FindCoreDll();

        if (!File.Exists(dll))
        {
            throw new FileNotFoundException(
                $"jas_dioxus.dll not found at '{dll}'. Build it with:\n" +
                "  cargo build --no-default-features --features d2d,ffi --lib\n" +
                "or set JAS_CORE_DLL to its path.", dll);
        }

        NativeLibrary.SetDllImportResolver(
            Assembly.GetExecutingAssembly(),
            (name, _, _) => name == Lib ? NativeLibrary.Load(dll) : IntPtr.Zero);
    }

    /// <summary>
    /// Walk up from the binary until the repo root is recognised, then take the
    /// cdylib from there.
    ///
    /// THIS REPLACED A COUNTED CHAIN OF "..", which was wrong by one level and
    /// resolved to <c>prototypes/jas_dioxus/target/...</c>. Counting is brittle
    /// in the way that matters here: the depth changes with Debug vs Release,
    /// with the TFM folder, and with the RID folder, so the count is right only
    /// for the exact configuration it was written against. Recognising the root
    /// by a file that is actually there does not care about any of that.
    /// </summary>
    private static string FindCoreDll()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            var candidate = Path.Combine(dir.FullName, "jas_dioxus", "Cargo.toml");
            if (File.Exists(candidate))
            {
                return Path.Combine(
                    dir.FullName, "jas_dioxus", "target", "debug", "jas_dioxus.dll");
            }
            dir = dir.Parent;
        }
        // Report where the search STARTED, not just that it failed: "not found"
        // without a starting point is the least actionable message there is.
        throw new DirectoryNotFoundException(
            $"could not find the repo root (a directory containing jas_dioxus/Cargo.toml) " +
            $"searching upward from '{AppContext.BaseDirectory}'. Set JAS_CORE_DLL to " +
            $"point at jas_dioxus.dll directly.");
    }
}
