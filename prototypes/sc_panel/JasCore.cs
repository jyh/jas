using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;

namespace ScPanel;

/// <summary>
/// The Rust core's <c>extern "C"</c> boundary, as the materializer sees it.
///
/// EVERY METHOD HERE IS A COUNTED CROSSING. The Rust side increments a counter
/// per invocation (jas_dioxus::ffi_instr), so the chatter figures S-C reports
/// come from the boundary itself and not from counting call sites in this file.
/// A static count of the call sites below would pass identically on a shell that
/// was never run -- which is the whole reason the counter exists.
///
/// The surface is TEN materializer functions plus TWO apparatus functions, and
/// they are kept visibly separate because the disproportion gate is measured
/// against the materializer budget only. Apparatus that counted toward the
/// budget would let the instrument consume the thing it exists to measure.
/// </summary>
internal static class JasCore
{
    private const string Lib = "jas_dioxus";

    // -- MATERIALIZER SURFACE (10) — budget-bearing -------------------------

    [DllImport(Lib)] internal static extern IntPtr jas_engine_new();
    [DllImport(Lib)] internal static extern void jas_engine_free(IntPtr e);
    [DllImport(Lib)] internal static extern void jas_free(JasBytes b);
    [DllImport(Lib)] internal static extern JasBytes jas_version();
    [DllImport(Lib)] internal static extern JasBytes jas_document_json(IntPtr e);
    [DllImport(Lib)] internal static extern int jas_dispatch_event(IntPtr e, byte[] opJson, nuint len);
    [DllImport(Lib)] internal static extern JasBytes jas_last_error_json(IntPtr e);
    [DllImport(Lib)] internal static extern JasBytes jas_widget_tree(IntPtr e, byte[] panelId, nuint panelLen, byte[]? ctx, nuint ctxLen);
    [DllImport(Lib)] internal static extern JasBytes jas_bind_values(IntPtr e, byte[] panelId, nuint len);

    /// <summary>
    /// THE TICK (S-C.2). One control's new value in; every bind row that MOVED,
    /// across every open panel, out.
    ///
    /// ⚠️ NOTE WHAT IS *NOT* IN THIS SIGNATURE: no channel, no colour, no mode.
    /// The event names a WIDGET and its new value, and the engine reads that
    /// widget's `bind.value` out of the panel spec to learn what it means. That
    /// is what keeps this file a materializer: a shell that sent {"h":210} would
    /// be naming the engine's model, and one that sent a hex would be doing the
    /// colour arithmetic.
    ///
    /// The reply CARRIES the changed rows, so a tick is ONE crossing plus its
    /// jas_free -- not a dispatch followed by a separate fetch, which under a
    /// Rust-owns-it ABI would be three.
    /// </summary>
    [DllImport(Lib)] internal static extern JasBytes jas_panel_event(IntPtr e, byte[] panelId, nuint panelLen, byte[] eventJson, nuint eventLen);

    // -- APPARATUS (2) — NOT part of the surface, NOT budget-bearing -------

    [DllImport(Lib)] internal static extern void jas_instr_reset();
    [DllImport(Lib)] internal static extern JasBytes jas_instr_counters_json();

    /// <summary>
    /// A span the Rust side owns (BL4). Copy it, then release with jas_free.
    /// </summary>
    [StructLayout(LayoutKind.Sequential)]
    internal struct JasBytes
    {
        public IntPtr Ptr;
        public nuint Len;
    }

    /// <summary>
    /// Copy a Rust-owned span to a C# string and release it.
    ///
    /// ⚠️ THE RELEASE IS ITSELF A COUNTED CROSSING. Every value this shell reads
    /// therefore costs TWO crossings, not one -- the read and the free. That is a
    /// real property of a Rust-owns-it ABI and it belongs in the chatter figure
    /// rather than being netted out of it, because a shell cannot avoid it.
    /// </summary>
    internal static string Take(JasBytes b)
    {
        if (b.Ptr == IntPtr.Zero || b.Len == 0)
        {
            return string.Empty;
        }
        var bytes = new byte[(int)b.Len];
        Marshal.Copy(b.Ptr, bytes, 0, (int)b.Len);
        jas_free(b);
        // UTF-8 EXPLICITLY, never the platform default. The default P/Invoke
        // CharSet is Ansi -- cp1252 on this box -- and that is this seat's
        // day-one defect class wearing an ABI costume (BL5).
        return Encoding.UTF8.GetString(bytes);
    }

    internal static byte[] Utf8(string s) => Encoding.UTF8.GetBytes(s);

    /// <summary>
    /// Point the loader at the cdylib. Fails LOUDLY: a resolver that quietly
    /// returns zero produces a DllNotFoundException at the first call site,
    /// which reads as a missing FUNCTION rather than a missing FILE.
    /// </summary>
    internal static void Bind()
    {
        var explicitPath = Environment.GetEnvironmentVariable("JAS_CORE_DLL");
        var dll = !string.IsNullOrWhiteSpace(explicitPath) ? explicitPath : FindCoreDll();
        if (!File.Exists(dll))
        {
            throw new FileNotFoundException(
                $"jas_dioxus.dll not found at '{dll}'. Build it with:\n" +
                "  cargo build --no-default-features --features ffi --lib\n" +
                "or set JAS_CORE_DLL to its path.", dll);
        }
        NativeLibrary.SetDllImportResolver(
            Assembly.GetExecutingAssembly(),
            (name, _, _) => name == Lib ? NativeLibrary.Load(dll) : IntPtr.Zero);
    }

    /// <summary>
    /// Walk UP until the repo root is recognised, then take the cdylib from
    /// there. Deliberately not a counted chain of "..": the depth changes with
    /// Debug vs Release and with the target triple, so counting is wrong exactly
    /// when someone changes configuration and does not think to recount.
    /// </summary>
    private static string FindCoreDll()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !Directory.Exists(Path.Combine(dir.FullName, "jas_dioxus")))
        {
            dir = dir.Parent;
        }
        var root = dir?.FullName ?? AppContext.BaseDirectory;
        return Path.Combine(root, "jas_dioxus", "target", "debug", "jas_dioxus.dll");
    }
}
