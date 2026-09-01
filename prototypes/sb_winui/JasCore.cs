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
internal static unsafe class JasCore
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
    /// The scene bytes are not a JSON ARRAY of commands.
    ///
    /// A bare object, a string, or a NULL pointer all decode as "valid JSON that
    /// replays as zero commands" -- complete, drawn nothing, and therefore OK.
    /// The core refuses by SHAPE so a marshalling slip on this side cannot
    /// present a blank window at success.
    /// </summary>
    internal const int PaintBadScene = 5;
    /// <summary>
    /// The painter could not draw part of the scene, so the frame would be
    /// missing artwork. The core REFUSES rather than presenting a partial
    /// document. Two goldens in the corpus land here by design: they carry a
    /// non-Normal blend, which needs an effect graph the Direct2D backend does
    /// not have. That is a DECLARED gap, not a failure of this shell.
    /// </summary>
    internal const int PaintSceneIncomplete = 6;
    /// <summary>The entry point exists but is a stub.</summary>
    internal const int PaintNotImplemented = 7;

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
        // ⛔ THESE THREE ARMS ARE THE SAME DEFECT THE `PaintSizeMismatch` COMMENT
        // ABOVE ALREADY NAMES, AND THEY WERE MISSING. `jas_paint_scene` has
        // returned 5, 6 and 7 since node 1 landed; without an arm each one fell
        // through to the HRESULT formatter and was reported as
        // "HRESULT 0x00000006" -- a positive sentinel dressed up as a COM error,
        // sending the reader to look for a COM fault that never happened. The
        // constant and its arm are one change, not two.
        PaintBadScene => "BAD SCENE -- the bytes are not a JSON array of commands; a marshalling slip, not a paint failure",
        PaintSceneIncomplete => "SCENE INCOMPLETE -- the painter could not draw part of it, so the core refused rather than present artwork-missing pixels (the declared non-Normal-blend gap does this)",
        PaintNotImplemented => "NOT IMPLEMENTED -- the entry point is a stub",
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
    /// Paint a RECORDED DISPLAY LIST -- real jas artwork -- into a DXGI surface
    /// this side owns. The node-1 export, called for the first time here.
    ///
    /// <c>scene</c> is a byte span, not a string: BL5 forbids a <c>string</c>
    /// parameter (the default P/Invoke CharSet is Ansi, cp1252 on this box) and
    /// the payload is UTF-8 JSON that would be mangled in both directions. It
    /// points into memory the CORE owns and hands out through
    /// <see cref="jas_corpus_scene"/>, so nothing here is pinned, copied or
    /// freed.
    /// </summary>
    [DllImport(Lib)]
    internal static extern int jas_paint_scene(
        IntPtr dxgiSurface, IntPtr scene, nuint len, float width, float height);

    /// <summary>How many recorded goldens the core carries.</summary>
    [DllImport(Lib)]
    internal static extern nuint jas_corpus_len();

    /// <summary>
    /// The name of golden <c>index</c>, as a pointer into <c>'static</c> core
    /// memory plus a length. NULL and length 0 when out of range.
    /// </summary>
    [DllImport(Lib)]
    internal static extern IntPtr jas_corpus_name(nuint index, out nuint len);

    /// <summary>The JSON bytes of golden <c>index</c>. Same ownership rule.</summary>
    [DllImport(Lib)]
    internal static extern IntPtr jas_corpus_scene(nuint index, out nuint len);

    /// <summary>
    /// The golden at <c>index</c>, as this shell wants it: a managed name and
    /// the raw (pointer, length) pair to hand straight back to
    /// <see cref="jas_paint_scene"/>.
    ///
    /// ⛔ THE BYTES ARE NOT COPIED INTO MANAGED MEMORY, deliberately. Copying
    /// them to a <c>byte[]</c> and re-pinning would add a second representation
    /// of the artifact whose whole purpose is that there is only one -- and the
    /// round trip through a managed encoder is exactly the BL5 mangling this
    /// boundary refuses elsewhere. The pointer is valid for the life of the
    /// library.
    ///
    /// The NAME is decoded with an EXPLICIT UTF-8 decoder rather than
    /// <c>Marshal.PtrToStringAnsi</c>: the corpus names are ASCII today, and
    /// relying on that is how a cp1252 default gets in later.
    /// </summary>
    internal static (string Name, IntPtr Scene, nuint Len) Golden(nuint index)
    {
        var np = jas_corpus_name(index, out var nlen);
        if (np == IntPtr.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(index),
                $"golden {index} is out of range; the core carries {jas_corpus_len()}");
        }
        var name = System.Text.Encoding.UTF8.GetString((byte*)np, (int)nlen);
        var sp = jas_corpus_scene(index, out var slen);
        if (sp == IntPtr.Zero)
        {
            // Name resolved and body did not: that is the core disagreeing with
            // itself, not a caller error, so it must not be reported as one.
            throw new InvalidOperationException(
                $"golden {index} ('{name}') has a name but no body -- the corpus " +
                "export is inconsistent");
        }
        return (name, sp, slen);
    }

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
