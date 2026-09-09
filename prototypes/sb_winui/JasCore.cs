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
    /// <summary>No session -- distinct from a dead surface.</summary>
    internal const int PaintNullEngine = 8;
    /// <summary>
    /// The document holds an element the native walk cannot draw, so NOTHING
    /// was drawn. Not the same as <see cref="PaintSceneIncomplete"/>: that one
    /// is a BACKEND gap, this one is an element still routing to the legacy
    /// renderer, and the two are fixed in different files.
    /// </summary>
    internal const int PaintDocumentIncomplete = 9;
    /// <summary>The bytes are not parseable as SVG (or not UTF-8).</summary>
    internal const int PaintBadSvg = 10;

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
        PaintNullEngine => "NULL ENGINE -- there is no session to paint; the shell never created one, or freed it early",
        PaintDocumentIncomplete => "DOCUMENT INCOMPLETE -- the document holds an element the native walk cannot draw yet (text, a freeform gradient, a Live element), so NOTHING was drawn rather than part of it",
        PaintBadSvg => "BAD SVG -- the file is not parseable XML, or not UTF-8. NOT the same as an empty drawing",
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

    /// <summary>
    /// A jas session. Opaque on this side by design (BL1): the shell holds a
    /// handle and never a document.
    /// </summary>
    [DllImport(Lib)]
    internal static extern IntPtr jas_engine_new();

    [DllImport(Lib)]
    internal static extern void jas_engine_free(IntPtr engine);

    /// <summary>
    /// Open an SVG into the session, replacing whatever it held.
    ///
    /// A BYTE SPAN, not a string, and not just for BL5's cp1252 reason: an SVG
    /// is UTF-8 on disk and the bytes are handed over exactly as read, so the
    /// core does its own decoding and refuses invalid input by name. A managed
    /// round trip through <c>File.ReadAllText</c> would silently substitute
    /// U+FFFD for a bad byte and the core would then parse the SUBSTITUTION.
    /// </summary>
    [DllImport(Lib)]
    internal static extern int jas_load_svg(IntPtr engine, byte[] svg, nuint len);

    /// <summary>
    /// Paint the session's LIVE document into a DXGI surface -- no display-list
    /// round trip. Refuses (<see cref="PaintDocumentIncomplete"/>) rather than
    /// presenting a document with elements missing.
    /// </summary>
    [DllImport(Lib)]
    internal static extern int jas_paint_document(
        IntPtr engine, IntPtr dxgiSurface, float width, float height);

    /// <summary>
    /// Paint ONE FRAME: the session's live document, then the ACTIVE TOOL'S
    /// OVERLAY on top of it.
    ///
    /// This is the call that makes a selection visible. <see
    /// cref="jas_paint_document"/> draws the document alone, so a selected
    /// element looks exactly like an unselected one and a marquee in flight is
    /// not on the screen at all. Kept separate from it deliberately: the golden
    /// and document receipts were photographed through that one, and quietly
    /// adding an overlay would change every one of those pictures.
    /// </summary>
    [DllImport(Lib)]
    internal static extern int jas_paint_frame(
        IntPtr engine, IntPtr dxgiSurface, float width, float height);

    // -- node 5: the pointer ------------------------------------------------
    //
    // ⛔ SCALARS ONLY (BL5). Not one string parameter in this group: the tool
    // is chosen by INDEX, the modifiers are bit flags, and the coordinates are
    // doubles. Nothing here can be mangled by a cp1252 marshalling default.
    //
    // ⛔ AND THIS SHELL DOES NOT KNOW WHAT A CLICK MEANS. It sends WHERE the
    // pointer went; hit-testing, marquee state, tool modes and the ops that
    // result all live in the core. That is BL1, and it is the whole reason
    // there is a pointer entry point at all rather than C# computing ops.

    internal const uint PointerPress = 0;
    internal const uint PointerMove = 1;
    internal const uint PointerRelease = 2;

    internal const uint ModShift = 1u << 0;
    internal const uint ModAlt = 1u << 1;
    internal const uint ModDragging = 1u << 2;

    /// <summary>
    /// One pointer transition. <paramref name="x"/> and <paramref name="y"/>
    /// are PHYSICAL pixels -- what the swapchain is sized in -- and the core
    /// converts to DIPs itself using the scale set below.
    /// </summary>
    [DllImport(Lib)]
    internal static extern int jas_pointer_event(
        IntPtr engine, uint kind, double x, double y, uint mods);

    /// <summary>
    /// Tell the core this display's physical-pixels-per-DIP.
    ///
    /// ⛔ THE SHELL REPORTS IT AND DOES NOT APPLY IT. Dividing here would put
    /// the single most common Windows-app defect on this side of the boundary,
    /// where no Rust test can see it.
    /// </summary>
    [DllImport(Lib)]
    internal static extern int jas_set_dpi_scale(IntPtr engine, double scale);

    /// <summary>Select the tool the pointer drives, by index.</summary>
    [DllImport(Lib)]
    internal static extern int jas_set_tool(IntPtr engine, nuint index);

    /// <summary>How many tools the core offers.</summary>
    [DllImport(Lib)]
    internal static extern nuint jas_tool_count();

    /// <summary>
    /// The tool id at <c>index</c>: a pointer into <c>'static</c> core memory
    /// plus a length, exactly like <see cref="jas_corpus_name"/>. Nothing is
    /// allocated, so nothing is freed. NULL and 0 when out of range.
    /// </summary>
    [DllImport(Lib)]
    internal static extern IntPtr jas_tool_name(nuint index, out nuint len);

    /// <summary>
    /// How many elements the session has selected.
    ///
    /// ⛔ <c>nuint.MaxValue</c> FOR A NULL SESSION, not 0. A count cannot
    /// express a refusal, and 0 there would read as "nothing selected" about a
    /// session that does not exist -- which is exactly the vacuous success this
    /// shell keeps refusing everywhere else.
    /// </summary>
    [DllImport(Lib)]
    internal static extern nuint jas_selection_len(IntPtr engine);

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

    // -- the JSON surface (BL4): Rust owns the bytes, we copy and free -------
    //
    // ⛔ NONE OF THIS EXISTED BEFORE N1. At 3c8fddce every `DllImport` in this
    // file returned a SCALAR: there was no `JasBytes`, no `jas_free` and no
    // `jas_document_json` (grep -> 0). So the harness had no way to ask the core
    // what document it was holding, which is why O1's mutation clause and O4's
    // before/after oracle both needed a binding before they needed a scene.

    /// <summary>
    /// <c>JasBytes</c> -- an owned UTF-8 span, Rust-side (`ffi.rs:42-46`).
    ///
    /// ⛔ THE LAYOUT IS THE CONTRACT: `#[repr(C)] { *const u8, usize }`. `usize`
    /// is <c>nuint</c> here and NOT <c>int</c> -- on x64 a 4-byte field would
    /// misalign the pointer's neighbour and read length from the wrong half of
    /// the struct, which is the class of bug that shows up as a plausible-looking
    /// wrong number rather than as a crash.
    ///
    /// ⛔ AND IT IS RETURNED BY VALUE. A 16-byte struct comes back through the
    /// x64 hidden-return-pointer convention on both sides, which is why this is a
    /// struct rather than an out-parameter: the ABI is what it is and describing
    /// it differently on this side would corrupt every call.
    /// </summary>
    [StructLayout(LayoutKind.Sequential)]
    internal struct JasBytes
    {
        internal IntPtr Ptr;
        internal nuint Len;
    }

    /// <summary>
    /// Release a span this ABI returned (BL4). Safe on the empty <c>JasBytes</c>
    /// (`ptr == NULL && len == 0` is the canonical empty result).
    /// </summary>
    [DllImport(Lib)]
    internal static extern void jas_free(JasBytes b);

    /// <summary>
    /// The session's document as canonical test JSON -- the SAME bytes the
    /// cross-language corpus compares.
    ///
    /// ⚠️ A SUMMARY, NOT GEOMETRY (`ffi.rs:330-331`, BL6), and BLIND TO THE TOOL
    /// OVERLAY: `jas_paint_frame` draws the overlay and this does not describe
    /// it. So this is the DOCUMENT oracle and the hash is the PIXEL oracle, and
    /// neither is offered as the other.
    ///
    /// BL2: a call for this engine, so it happens on the engine's own thread --
    /// which is why <c>Canvas.Dump</c> is a queue command and not a method the
    /// window can call.
    /// </summary>
    [DllImport(Lib)]
    internal static extern JasBytes jas_document_json(IntPtr engine);

    /// <summary>
    /// The session's document as SVG -- the artefact a person SAVES.
    ///
    /// ⛔ NOT <see cref="jas_document_json"/>, AND THE DIFFERENCE IS THE WHOLE
    /// POINT. That one is canonical test JSON, "a summary, not geometry" (BL6):
    /// it is the corpus's comparison surface and it is lossy about the drawing.
    /// This is `geometry::svg::document_to_svg`, the same writer every port
    /// saves through, so a document saved on Windows and one saved on the web
    /// are the same bytes.
    ///
    /// BL4: the span is Rust-owned -- <see cref="TakeString"/> copies and frees.
    /// BL2: a call for this engine, so it happens on the `jas-render` thread.
    /// </summary>
    [DllImport(Lib)]
    internal static extern JasBytes jas_document_svg(IntPtr engine);

    /// <summary>
    /// The menubar's evaluated `enabled` / `checked` state: the canonical
    /// `menu_state` array, a flat pre-order `{path, action, enabled, checked}`
    /// per action item.
    ///
    /// ⭐ THIS IS WHAT KEEPS A SECOND MENUBAR FROM BEING AUTHORED HERE. The
    /// shell does not evaluate `active_document.can_undo`; it reads the boolean
    /// the core computed, from the SAME pass the cross-app byte-gate pins.
    ///
    /// ⚠️ THE CTX IS A MERGE, AND IT IS NOT `jas_widget_tree`'S NULL-CTX
    /// CONVENTION. A panel's scope is wholly the engine's; a menubar's is not.
    /// The engine supplies `active_document.{has_selection, selection_count,
    /// can_undo, can_redo, is_modified}` and WINS on them -- a shell that could
    /// assert `can_undo` would be holding document state, which is BL1. The
    /// shell supplies everything else (`state.tab_count`,
    /// `active_document.has_filename`, `workspace.*`, `panels.*`, `panes.*`),
    /// because tabs, filenames and chrome visibility are session facts and have
    /// never been the engine's.
    ///
    /// ⛔ A NULL `ctx` IS "THE SHELL SUPPLIES NOTHING", NOT "EMPTY SCOPE", and a
    /// ctx that does not PARSE comes back as the empty span rather than being
    /// treated as `{}` -- so a marshalling slip on this side cannot present a
    /// plausible menu built from no session state at all. An empty result is
    /// therefore a REFUSAL to be reported, never a menubar with no items.
    /// </summary>
    [DllImport(Lib)]
    internal static extern JasBytes jas_menu_state(IntPtr engine, byte[]? ctxJson, nuint ctxLen);

    /// <summary>
    /// The menubar's STATIC shape — labels, shortcuts, separators, submenu
    /// titles. The other half of <see cref="jas_menu_state"/>.
    ///
    /// ⛔ WITHOUT THIS THE SHELL CAN DRAW 55 CORRECTLY-ENABLED MENU ITEMS WITH
    /// NO TEXT ON THEM. `jas_menu_state` answers "which entries are enabled
    /// right now" and emits neither labels nor separators nor submenu nodes, by
    /// design — it is the cross-app byte-gate for the DYNAMIC half. Every other
    /// port gets the static half by projecting the compiled bundle in-process,
    /// because every other port is an interpreter; this shell is not, and §1
    /// forbids it reading the bundle itself.
    ///
    /// Read ONCE — the structure cannot change without a rebuild — and joined to
    /// <see cref="jas_menu_state"/> on `path` at each menu open.
    ///
    /// ⛔ TAKES NO ENGINE, AND THAT IS THE CORE'S DECISION, NOT AN OVERSIGHT.
    /// The menubar is a property of the compiled bundle, not of a document
    /// session. A handle passed here would be a dead arm wearing a driven arm's
    /// signature.
    /// </summary>
    [DllImport(Lib)]
    internal static extern JasBytes jas_menu_structure();

    // -- events (BL1: the shell sends events, never state) -------------------

    /// <summary>Status codes from `ffi.rs:77-87`. Mirrored, not guessed.</summary>
    internal const int StatusOk = 0;
    internal const int StatusMalformedEnvelope = 1;
    internal const int StatusUnknownVerb = 2;
    internal const int StatusMissingParam = 3;
    internal const int StatusBadParamType = 4;
    internal const int StatusMissingTarget = 5;
    internal const int StatusBadUtf8 = 100;
    internal const int StatusBadJson = 101;
    internal const int StatusNullHandle = 102;

    /// <summary>
    /// Render a `JasStatus` for a human.
    ///
    /// ⛔ A SECOND EXPLAINER, DELIBERATELY, AND IT MUST NEVER BE MERGED WITH
    /// <see cref="Explain"/>. The two vocabularies are DISJOINT BY DESIGN and
    /// the header says so in its own voice -- the paint codes are "deliberately
    /// NOT `JasStatus`". They overlap numerically (`2` is `not an IDXGISurface`
    /// in one and `UnknownVerb` in the other), so one function serving both
    /// would render a plausible sentence about the wrong seam, which is the
    /// exact failure the `PaintSizeMismatch` comment above already paid for.
    /// The 100-block is transport (the bytes never reached `op_apply`); 1-5 are
    /// the five FROZEN `OpError` classes, spelled as the negative fixtures
    /// spell them.
    /// </summary>
    internal static string ExplainStatus(int st) => st switch
    {
        StatusOk => "ok",
        StatusMalformedEnvelope => "MalformedEnvelope -- the envelope carries no `op` verb",
        StatusUnknownVerb => "UnknownVerb -- the verb is not in op_apply's vocabulary",
        StatusMissingParam => "MissingParam -- the verb needs a parameter the envelope omits",
        StatusBadParamType => "BadParamType -- a parameter is present with the wrong type",
        StatusMissingTarget => "MissingTarget -- the op names an element the document does not hold",
        StatusBadUtf8 => "BAD UTF-8 -- the bytes never reached op_apply; a marshalling fault, not a rejection",
        StatusBadJson => "BAD JSON -- the bytes are not parseable; a marshalling fault, not a rejection",
        StatusNullHandle => "NULL ENGINE -- there is no session to dispatch into",
        _ => $"UNKNOWN JasStatus {st}",
    };

    /// <summary>
    /// Apply one op envelope (BL1: the shell sends events, never state).
    ///
    /// Returns <see cref="StatusOk"/> or the frozen class of the rejection;
    /// detail via <see cref="jas_last_error_json"/>.
    ///
    /// ⚠️ `Ok` IS NOT "SOMETHING HAPPENED". The history verbs -- `undo`, `redo`,
    /// `snapshot` -- return `Ok` unconditionally (`op_apply.rs:1866-1885`), so an
    /// undo on an empty journal is a successful no-op. Anything asserting that an
    /// edit LANDED must read a document fact before and after, never this code.
    ///
    /// BL2: a call for this engine, so it happens on the `jas-render` thread.
    /// </summary>
    [DllImport(Lib)]
    internal static extern int jas_dispatch_event(IntPtr engine, byte[] opJson, nuint len);

    /// <summary>
    /// Detail for the last rejection: `{"class":"...", "name"|"id":"..."}` with
    /// the class spelled as the negative fixtures spell it.
    ///
    /// ⛔ EMPTY MEANS "THE LAST CALL SUCCEEDED", and that is a reading, not an
    /// absence: <see cref="jas_dispatch_event"/> CLEARS it on entry, so an empty
    /// span after a non-Ok status would itself be a finding.
    /// </summary>
    [DllImport(Lib)]
    internal static extern JasBytes jas_last_error_json(IntPtr engine);

    /// <summary>
    /// The boundary counters as JSON: per-function rows plus totals.
    ///
    /// ⭐ THIS IS O1's IDENTITY ORACLE. `jas_engine_new` and `jas_engine_free`
    /// record their own crossings (`ffi.rs:274`, `:284`), so "the engine was
    /// created once and never freed" is a fact the CORE reports rather than a
    /// claim the shell makes about itself.
    ///
    /// ⚠️ READ IT LAST. Releasing the span calls <c>jas_free</c>, which IS a
    /// counted crossing (`ffi.rs:551-556`), so a dump taken mid-interaction
    /// perturbs the next reading.
    /// </summary>
    [DllImport(Lib)]
    internal static extern JasBytes jas_instr_counters_json();

    /// <summary>
    /// Copy a Rust-owned span into a C# string and free it -- BL4 in one place,
    /// so no caller has to remember the second half.
    ///
    /// The free is in a `finally`: a decoding failure must not also leak, and an
    /// exception on the copy is exactly when the release is easiest to forget.
    /// </summary>
    internal static string TakeString(JasBytes b)
    {
        try
        {
            if (b.Ptr == IntPtr.Zero || b.Len == 0) { return string.Empty; }
            return System.Text.Encoding.UTF8.GetString((byte*)b.Ptr, (int)b.Len);
        }
        finally
        {
            jas_free(b);
        }
    }

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
