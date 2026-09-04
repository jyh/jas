# S-B — the C#/WinUI-3 materializer shell

Spike for D1's port-six variant: a **materializer shell, not a third
interpreter**, over the Rust core with `Direct2DPainter` behind the ratified
`Painter` trait. This directory is the C# half. It is a SPIKE — it decides the
variant, it is not a product.

Scope boundary inherited from S-A, stated in `../ffi_spike/README.md`:

> No swapchain, no rendering. That is S-B, and its seam should be designed
> against a real `SwapChainPanel` rather than in advance.

## Knobs

Every environment variable this shell reads, and nothing else. F-1 was closed as
"working as intended" because `SB_SCENE_FINAL` **is** refused by name when it
names a golden the corpus does not hold — but a reader could not find that out,
because the README documented none of `SB_FRAMES`, `SB_SCENE_HOLD` or
`SB_SCENE_FINAL`. A close by documentation that nothing gates rots on the first
knob added after it, so `scripts/check_shell_knobs.py` censuses every
`GetEnvironmentVariable("...")` in `*.cs` and reds in BOTH directions: a knob
read and not listed here, and a row here naming a knob nothing reads.

`kind` is a closed vocabulary. `benchmark` inputs decide what is measured;
`interaction` inputs decide how the canvas behaves under a resize or a pointer;
`provenance` is the one input that decides WHICH BINARY RAN, which is a
different question from either.

*(N6 owns the full README pass. This table is written by N1+N2 because the gate
that reads it goes LIVE in the same pull request, and a gate landed red is a
gate its own executor is invited to weaken.)*

| knob | meaning | default | scene | kind |
|---|---|---|---|---|
| `JAS_CORE_DLL` | absolute path to the `jas_dioxus` cdylib to load; otherwise the debug artifact is found by walking up to `jas_dioxus/Cargo.toml` | *(search upward from the exe)* | all | provenance |
| `SB_FRAMES` | how many frames the benchmark loop runs; the first is excluded from every mean | `60` | `benchmark` | benchmark |
| `SB_FULLSCREEN` | `1` puts the window on the full-screen presenter BEFORE first layout, so the surface is the display's and not WinUI's default | *(unset: windowed)* | all | benchmark |
| `SB_HIT` | which element carries the pointer handlers: `panel` (the `SwapChainPanel` itself) or `sibling` (a transparent `Border` in the same grid cell). The receipt says `hit=PANEL` or `hit=SIBLING` | `panel` | all | interaction |
| `SB_MODE` | `direct` lets the core paint the back buffer; anything else uses the offscreen target plus one full-surface copy | *(unset: offscreen)* | `benchmark` | benchmark |
| `SB_PAINT_ON_UI` | `1` marshals the paint AND the present through the `DispatcherQueue`, so `paint-tid == present-tid == ui-tid` on every row. O3's DESIGN-RED control: it exists to make the residency assertion fail by construction, so a green one is known to have been capable of red | *(unset: paint and present on the render thread)* | all | interaction |
| `SB_POINTER_WAIT_MS` | how long a scene waits for a REAL gesture before writing `NOT RUN: hand refused`; a timeout is never a synthetic receipt wearing `REAL` | `30000` | `pointer`, `retained` | interaction |
| `SB_RENDER_STALL_MS` | milliseconds the RENDER thread sleeps inside one repaint. A resize posted during the sleep appears as exactly one row after it, at the latest size; `Responding` stays `True`, because the thread that sleeps is not the one that pumps | *(unset: no stall)* | `stall` | interaction |
| `SB_RESIZE` | a comma-separated LIST of window sizes to drive after the scene, e.g. `1000x600,original`; `original` is the `AppWindow` size recorded at first layout. Each step is posted when the previous one has landed, never after a sleep | *(unset: no driven resize)* | all | interaction |
| `SB_SCENE` | which workload runs: `benchmark`, `goldens`, `document`, `retained`, `stall`, `pointer`, `stay`, `selection-marquee`. An empty value resolves to `benchmark`, so every historical invocation keeps its meaning; an unrecognised value is refused by name, and the old spelling `selection` is REFUSED pointing at `selection-marquee` rather than silently running it | `benchmark` | all | benchmark |
| `SB_SCENE_FINAL` | which golden is painted LAST, so the photograph is of a chosen frame rather than of whatever the loop ended on; refused by name if the corpus does not hold it | `ref_shapes.json` | `goldens` | benchmark |
| `SB_SCENE_HOLD` | how many presents each held frame stays on screen; at a sync interval of 1 the default is roughly 200 ms apiece | `12` | `goldens`, `document`, `selection-marquee` | benchmark |
| `SB_SIZE` | pin the swapchain at an explicit `WxH` in PHYSICAL pixels, so a copy can be priced at a stated surface. Mutually exclusive with `SB_RESIZE`: a later resize is refused by name | *(unset: the laid-out DIP size)* | all | benchmark |
| `SB_SQUEEZE` | `1` sets `PreferredMinimumHeight = 1` and squeezes the window to the status row, so the panel's `SizeChanged` fires with height 0 through the real window manager | *(unset: no squeeze)* | all | interaction |
| `SB_SURFACE_PROBE` | a `WxH` fed straight to `SurfacePolicy.Decide` — including `0x0` — so the policy function can be exercised without a window manager. The receipt says `policy=PROBE` | *(unset: no probe)* | all | interaction |
| `SB_SVG` | path to the `.svg` a document-bearing scene opens; required by `document`, `retained`, `pointer` and `selection-marquee`, optional for `stall` and `stay`, and refused by name when a scene that needs it has none. `retained` additionally refuses any file but the CALIBRATED `complex_document.svg`, because O1 compares hashes with no tolerance | *(none: the scene refuses)* | `document`, `retained`, `pointer`, `selection-marquee`, `stall`, `stay` | benchmark |
| `SB_SYNTH_DRAG` | `x,y,dx,dy[,k]` in PHYSICAL pixels, replayed through `jas_pointer_event` on the render thread as press, `k` moves (default 2) and release. The seam's positive control: the harness picks the point and the delta from `sb-doc-before.json`, so the shell cannot know what it hit. The receipt says `pointer=SYNTHETIC` and can never say `REAL` | *(unset: the scene waits for a real hand)* | `retained`, `pointer` | interaction |
| `SB_TOOL` | which tool index the pointer drives. Only `0` (selection) is answered this wave; any other value is refused by name, because captured-only forwarding is wrong for a tool that reads idle motion | `0` | all | interaction |
| `SB_TOPMOST` | `1` keeps the window at the top of the z-order, so a console that appears later cannot cover the canvas in a capture | *(unset: normal z-order)* | all | benchmark |
| `SB_UI_STALL_MS` | milliseconds the XAML thread sleeps. O3's ORACLE-LIVENESS control: `Responding` must read `False`, because an oracle that cannot say `False` says nothing when it says `True` | *(unset: no stall)* | `stall` | interaction |

## RESOLVED — and both defects had ONE cause

**S-B checkpoint 3 works. Both routes run 300 frames on hardware with no
failure.** `Present` succeeds every frame, the heap corruption is gone, and the
`E_NOINTERFACE` never returns.

### The cause: the wrong interface pointer

The host handed Rust `Marshal.GetIUnknownForObject(...)` — the object's
**IUnknown** pointer — and Rust called through it as an `IDXGISurface*`. For a
COM object exposing several interfaces those are **different pointers**, so every
call landed on a wrong vtable slot. The fix is one call per site:

```csharp
Marshal.GetComInterfaceForObject(surface, typeof(IDXGISurface))
```

**One bug, two very different symptoms, and that is why it took so long.** On the
direct route the back buffer's IUnknown happens to coincide with its
IDXGISurface, so the paint "worked" and only the later `Present` failed —
`E_NOINTERFACE`, from a call that never names an interface. On the offscreen
route the target is an `ID3D11Texture2D`, whose IUnknown is **not** its
IDXGISurface, so the same code corrupted the heap (`0xC0000374`). A latent defect
that one of two callers could not expose.

Every hypothesis in the table below was **correctly excluded** — none of them was
the cause. The table is kept because the exclusions are what made the remaining
space small enough to see the real one, and because re-running reproduces them.

### Measured, 1904x941, hardware, 300 frames each

| route | steady-mean | min | max |
|---|---|---|---|
| DIRECT paint (zero-copy) | **0.92 ms** | 0.48 | 1.38 |
| OFFSCREEN paint + GPU copy | **1.07 ms** | 0.63 | 1.73 |

**The full-surface GPU copy costs ~0.15 ms, about 16% on top of the paint.**
That is the figure S-C exists to weigh, and it is now measured rather than
assumed. `Present` is ~5.2-5.5 ms on both routes: vsync-bound at
`SyncInterval 1`, identical either way, so it does not separate them.

**The first frame is excluded from every mean and reported separately** — it runs
2.3-4.3 ms against a 0.5 ms steady state, and an earlier version of this harness
folded a 1092 ms first frame into a "mean" of 19.20 ms that described nothing.

### Re-measured 2026-08-24 at a second surface size — and the area model is dead

Four runs, one session, one binary: `{direct, offscreen}` x `{default,
fullscreen}`, 300 frames each. The default pair is the CONTROL, so the comparison
never has to cross sessions.

| run | surface | Mpx | paint mean | present mean | **present max** | paint+present |
|---|---|---|---|---|---|---|
| DIRECT | 1904x941 | 1.79 | 1.14 | 5.09 | **11.95** | 6.23 |
| OFFSCREEN | 1904x941 | 1.79 | 1.26 | 4.92 | **6.25** | 6.18 |
| DIRECT | 2560x1405 | 3.60 | 1.14 | 5.30 | **12.20** | 6.44 |
| OFFSCREEN | 2560x1405 | 3.60 | 1.27 | 4.92 | **6.50** | 6.19 |

**The copy is 0.12 ms at 1.79 Mpx and 0.13 ms at 3.60 Mpx. Area doubled; the copy
grew 8%.** A linear-in-area model predicted 0.24 ms. **It is dominated by fixed
cost, not bandwidth**, across this range — so "16% on the paint" is a ratio that
falls as documents get real AND does not climb as windows get bigger.

**Per frame the routes are indistinguishable**: totals 6.18-6.44 ms all bracket
the 6.25 ms vsync interval at this display's 160 Hz. ⚠️ **But the tail reverses
the mean** — `present max` hit 11.95 and 12.20 ms on both DIRECT runs (nearly two
intervals: a dropped frame) against 6.25 and 6.50 ms on both OFFSCREEN runs.
2 of 2 versus 0 of 2.

⚠️ **The control did not reproduce its own banked figure**: paint was 0.92 ms on
08-24 morning and 1.14 ms in this session, +24%. **The cross-session drift is
larger than the effect being measured**, which is why the copy is only ever
quoted as a within-session delta.

### ⛔ DEFECT FOUND BY THIS RUN: the swapchain is sized in DIPs, not pixels

`SB_FULLSCREEN=1` reports **2560x1405, not 3840x2160**. The desktop is at 150%
scaling: 3840x2160 physical is 2560x1440 in DIPs, less 35 DIPs for the status
row. `Canvas.SizeChanged` gives DIPs and that value goes straight into swapchain
creation; **`CompositionScaleX/Y` is read nowhere in this prototype**.

**So the core renders 3.60 Mpx and the compositor upscales 1.5x to fill 8.29 Mpx**
— on a vector illustration app, a fidelity defect rather than a tuning detail. It
is invisible in every timing above because it makes the work smaller for both
routes equally. **Not fixed here**: it is real work with consequences for the pen
pipeline, and it belongs on a backlog rather than inside a measurement run. It
also means the true physical-4K copy cost remains unmeasured.

### What is still open

The **direct route is the one the variant wants** and it now works, so the
Graphics Tools install docketed for the Captain is no longer blocking: it was
wanted to explain the `E_NOINTERFACE`, and the `E_NOINTERFACE` is explained.

---

## Historical: the defect as it stood before the cause was found

Kept because the exclusion method is the transferable part.

The chain ran end to end and the last step failed. **Rust's paint returned 0**;
`Present` then returned `0x80004002`.

**The reproduction is exact.** `SB_SKIP_PAINT=1` acquires the back buffer and
does everything else identically, without calling Rust:

    SB_SKIP_PAINT=1 -> "RUSTOK presented 1904x941 on hardware"     Present SUCCEEDS
    (default)       -> "Present 0x80004002 [paint rc=ok]"          Present FAILS

So the variable is the Direct2D paint, not `GetBuffer`, and not the shell.

**Ruled out by experiment, each one run rather than reasoned away:**

| hypothesis | result |
|---|---|
| interface dispatch is broken | NO — `GetDesc1` returns a healthy 1904x941, buffers=2 |
| `Present` specifically | NO — `Present1` fails identically |
| the derived-interface `new` redeclaration | NO — presenting via base `IDXGISwapChain` fails identically |
| the D3D device was removed or reset | NO — `GetDeviceRemovedReason` reports device ok |
| `ISwapChainPanelNative` release | NO — omitting the release changes nothing |
| back-buffer RCW still referenced | NO — releasing it changes nothing (`FinalReleaseComObject` crashes the app: over-release) |
| a second `Present` in one frame | NO — the bisect probe was removed; a single post-paint `Present` still fails |
| D2D still holding the target | NO — `SetTarget(None)` now runs in `SurfaceTarget::Drop` and does not clear it |
| back buffer still bound to the D3D pipeline | NO — `OMSetRenderTargets(0,null,null)` + `Flush()` does not clear it |
| D2D objects destroyed before `Present` | NO — a device cache was tried, did not fix it, and hung the tests (see `surface.rs`) |

**The instrument that would answer it is unavailable.** The D3D11 debug layer
would state the reason outright, and `D3D11_CREATE_DEVICE_DEBUG` fails here
(`dbg=unavailable`) because the **Graphics Tools optional Windows feature is not
installed**. Installing it is a machine change and is the Captain's call, not
this spike's. That is the recommended next step and it is cheap and reversible.

Everything above is instrumented in the code, so re-running reproduces the whole
table rather than requiring it to be trusted.

## Status

**Checkpoints 1, 2 and 3 PASS (2026-08-24).** The shell builds, puts a window on
the desktop, creates a D3D11 device and composition swapchain, binds it to a
SwapChainPanel, and the Rust core paints it through Direct2D for 300 consecutive
frames on both the direct and offscreen routes.

Checkpoint 1's original evidence, kept because the harness is the point:

```
ok  : capture ran in session 1, bounds 2560x1440 at (0,0)
ok  : window present -- SbWinUi: JAS S-B MATERIALIZER CHECKPOINT 1
ok  : real desktop pixels (mean luma 58.4, 1832 colours)
VERIFY: PASS
```

**No D3D, no SwapChainPanel, no Rust yet — deliberately.** §5 of the seat
breadcrumb records what it cost to move two variables at once here: a
launch-mechanism fault was briefly believed to be the Dioxus CLI. The chain under
test in checkpoint 1 is exactly *dotnet SDK → WinUI 3 → interactive scheduled
task → a window a session-1 observer can see*.

## Build and verify

```powershell
%LOCALAPPDATA%\Microsoft\dotnet\dotnet.exe build prototypes\sb_winui\SbWinUi.csproj
powershell -File prototypes\sb_winui\verify_window.ps1 `
    -Title "JAS S-B MATERIALIZER CHECKPOINT 1" `
    -Exe   prototypes\sb_winui\bin\Debug\net10.0-windows10.0.22621.0\win-x64\SbWinUi.exe
```

Measured: build 66s cold (57s of it NuGet restore), resolving
`Microsoft.WindowsAppSDK 1.8.260804001`. **No Visual Studio is installed on this
box** — `vswhere` reports zero instances. WinUI 3 is reachable here purely
through the NuGet package plus the already-installed `WindowsAppRuntime` Appx
packages, unpackaged (`WindowsPackageType=None`).

Three toolchain traps apply and are documented in the seat breadcrumb §5b; all
three report a present thing as absent:

1. the `dotnet` on PATH is **runtime-only** and shadows the real SDK in
   `%LOCALAPPDATA%` — a bare `dotnet build` prints the same error as a machine
   with no SDK at all;
2. the same shadowing bites again at **app runtime** (`DOTNET_ROOT` must point at
   the LOCALAPPDATA install, or the app dies with "You must install or update
   .NET");
3. **Smart App Control is at Enforce** and blocks freshly built exes on first
   run; a rebuild clears it.

## Why `verify_window.ps1` exists, and why it does not check `MainWindowHandle`

The agent shell runs in **session 0**; the desktop is **session 1**. Measured
2026-08-23: a session-0 process enumerates **zero** visible top-level windows
while session 1 is running a full desktop, and `MainWindowHandle` reads `0` for a
session-1 process whose window is perfectly fine.

So `MainWindowHandle` reads 0 for a rendering app **and** for a blank one —
identical in both states. That is the same vacuity class
`scripts/check_native_backend_lane.py` was built against, and it fails in the
direction that looks like an application bug. The verifier therefore asserts a
**window title observed from inside session 1**, which only this app can produce,
plus pixel statistics proving the capture is of a real desktop rather than an
empty window station.

## What checkpoint 2 has to solve, and it is not a wiring job

The recon is unambiguous: **the existing `Direct2DPainter` cannot feed a
`SwapChainPanel` today.**

`HeadlessTarget` (`jas_dioxus/src/painter/direct2d/device.rs:46`) renders into an
**`IWICBitmap`** via `ID2D1Factory::CreateWicBitmapRenderTarget` (`device.rs:90`)
— "no HWND, no swapchain, no desktop", chosen deliberately so B1 could run
headless in CI. Pixels leave only as a CPU `Vec<u8>` from `read_bgra()`. There is
no D3D11 device, no `ID2D1Factory1`, no `ID2D1DeviceContext`, no swapchain
anywhere in the crate, and `HeadlessTarget::new(w, h)` accepts **only width and
height** — nothing can be injected.

`ISwapChainPanelNative::SetSwapChain` needs an `IDXGISwapChain` on a D3D11
device. So checkpoint 2 needs route (b), which `device.rs:10` names and does not
build: `D3D11CreateDevice` + `ID2D1Factory1::CreateDevice` + a device context
targeting the swapchain's back buffer.

**Two facts make that much cheaper than it sounds, and both are worth stating
because they were not obvious:**

* **`Direct2DPainter` itself needs ZERO changes.** It borrows
  `&'a ID2D1RenderTarget` (`painter.rs:60`) and reaches the factory through
  `self.rt.GetFactory()` rather than storing one. In windows-rs 0.62
  `ID2D1DeviceContext` derefs to `ID2D1RenderTarget`, so
  `Direct2DPainter::new(&*device_context)` compiles unchanged. All 14 trait
  methods, `geometry.rs`, `convert.rs` and `text.rs` are already target-agnostic.
  The gap is entirely in the *device*, not the painter.
* **DXGI is already compiled in.** `Win32_Graphics_Dxgi_Common` transitively
  enables `Win32_Graphics_Dxgi`, so `IDXGIFactory2::CreateSwapChainForComposition`
  and friends are present today. **Only `Win32_Graphics_Direct3D11` is missing**
  from the `windows` crate features (`jas_dioxus/Cargo.toml`), which is why
  `D3D11CreateDevice` is not merely unused but uncompilable.

One more known gap: **`ISwapChainPanelNative` has zero hits in windows-rs** — it
lives in Windows App SDK metadata, so it must be hand-declared on whichever side
calls it.

The FFI surface is no help yet either: `jas_dioxus/src/ffi.rs` exports eight
functions (`jas_engine_new/free`, `jas_free`, `jas_version`, `jas_document_json`,
`jas_dispatch_event`, `jas_last_error_json`, `jas_widget_tree`) and **not one
mentions a painter, a surface or a device handle**. Whatever seam checkpoint 2
chooses is new ABI, and per letter 13's BL1–BL6 it needs its ownership and
threading rules written down before it is coded.

## Not yet decided, and not being decided by default

Whether the Rust side should own the swapchain (host passes a panel/visual) or
the C# side should own it (host passes a device or a back-buffer surface) is a
**real design choice with an ownership and threading argument on each side**, and
it is the first thing checkpoint 2 must settle rather than discover. S-B has no
ruled kill-gate; if a point is reached where one is needed to judge whether the
variant is dying, that goes back to the Captain rather than being invented here.
