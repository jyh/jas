# S-B — the C#/WinUI-3 materializer shell

Spike for D1's port-six variant: a **materializer shell, not a third
interpreter**, over the Rust core with `Direct2DPainter` behind the ratified
`Painter` trait. This directory is the C# half. It is a SPIKE — it decides the
variant, it is not a product.

Scope boundary inherited from S-A, stated in `../ffi_spike/README.md`:

> No swapchain, no rendering. That is S-B, and its seam should be designed
> against a real `SwapChainPanel` rather than in advance.

**What changed, and it is the shape of this whole document.** Through
checkpoint 3 the shell was a PAINTER: one-shot methods that created an engine,
drew, freed it and returned — all of them on the XAML thread, with a 60-frame
benchmark loop sitting on the resize path. It is now a CANVAS: `Canvas.cs`
holds ONE engine for the life of the window, on ONE render thread; the UI
thread only enqueues; a resize costs one frame; and the pointer is real. The
measurement history below is kept in full and **every table in it says which
shell it was taken on** — the benchmark loop was moved verbatim into
`Benchmark()`, so the old numbers still mean what they meant.

## The canvas — one engine, one render thread, one frame per drain

`Canvas` (`Canvas.cs:205`) owns the D3D11 device, the composition swapchain,
the offscreen target, the **engine handle** (the retained document), the
surface size and the selected tool. It runs a dedicated `Thread` named
`jas-render` (`Canvas.cs:527-530`) pumping a `BlockingCollection<Cmd>`. The UI
thread's entire relationship with it is to enqueue.

```
UI thread (XAML)                        render thread (owns engine + device + swapchain)
────────────────                        ────────────────────────────────────────────────
SizeChanged ─► SurfacePolicy ─► enqueue  loop:
PointerPressed/Moved/Released ─► enqueue   Take() ONE (blocking), then TryTake() to EMPTY
CaptureLost/Canceled ─► synth Release      apply the batch IN ENQUEUE ORDER:
scene dispatch ─► enqueue Scene(...)         consecutive Resizes → latest wins
                                             Repaints → collapse to one
BindPanel (SetSwapChain) ◄─ TryEnqueue ◄─    Pointer events → IN ORDER, never coalesced
Title / StatusLine ◄─ TryEnqueue ◄─          engine calls, dumps, counters: here only
                                           if dirty: ONE jas_paint_frame → ONE Present(1)
                                           write the receipt row (tids on it)
```

**The drain shape is a correctness clause, not a style.**
`GetConsumingEnumerable()` takes one item per pass, which is one repaint per
pointer event — the old 60-frame problem at a new scale. So the loop takes one
item blocking and then drains to exhaustion, applies the batch in enqueue
order, and latches only *consecutive* resizes: a Move is never applied after
its Release.

**Thread ownership (BL2, `ffi.rs:16-17`: every call for an engine must happen
on the thread that created it, and the core is `Rc`-based, so not `Send`).**

| owns | thread |
|---|---|
| the engine and every `JasCore` call for it, the device, the swapchain, the back buffer, `ResizeBuffers`, `GC.Collect`, the staging-texture hash, the `sb-runs.log` append | the `jas-render` thread |
| the panel, `SetSwapChain`, `AppWindow.Resize`, `Title`, `StatusLine`, the pointer handlers, `SurfacePolicy.Decide` at the event | the XAML thread |

A dedicated thread, not the pool: BL2 needs one stable identity for the
engine's whole life, and a pool continuation is a different thread each time.
The `DispatcherQueue` is captured on the UI thread **before** the render thread
starts. `SetSwapChain` is posted **fire-and-forget** at handoff and after every
successful `ResizeBuffers`; a blocking wait there would be a deadlock by a
second door. Every receipt row carries
`ui-tid=… render-tid=… paint-tid=… present-tid=… render-has-dispatcher=false`,
each captured at its own site, so residency is proven by ids rather than by the
window merely staying responsive.

**`Repaint()` is split from `Benchmark()`** (`Canvas.cs:1403` / `:1557`).
`Repaint(cause)` draws the current scene ONCE and reads no frame count; the
resize path is `Resize → Repaint`, and its row says `frames=1` because there is
no other value it can say. `Benchmark()` is the old loop, moved verbatim: first
frame excluded from the mean, occlusion counted and fatal, both routes
preserved. `SB_FRAMES` is read in exactly one place outside the receipt
line — inside `Benchmark`.

**`SurfacePolicy.Decide(w, h, hasSurface)` is three-valued** (`Canvas.cs:69`)
and is the shell's only answer to a zero dimension: `Refuse` once a surface
exists (the last good surface is kept and the row says
`RESIZE REFUSED 1184x0 — surface stays 1184x726`), `Defer` before the first
attach (refusing there would brick startup), `Accept` otherwise. There is no
`Math.Max(…, 1)` anywhere in the shell; the swapchain is never resized to a
size nobody asked for.

**Input is real.** `PointerPressed` captures the pointer and enqueues a press;
`PointerMoved` enqueues a move ONLY while captured (a hover is not a drag);
`PointerReleased` enqueues a release and drops the capture; `PointerCaptureLost`
and `PointerCanceled` close an open gesture with a synthetic release and are
idempotent. Coordinates are sent in PHYSICAL pixels (`Position` in DIPs ×
`CompositionScaleX/Y`) with the scale reported through `jas_set_dpi_scale`, so
the divide never lives in C#. Modifiers mirror the ABI's bits and are never
renumbered.

## The scenes

One knob selects the workload. An empty value resolves to `benchmark`, so every
invocation written before the scenes existed keeps its meaning; an unrecognised
value is refused by name on the render thread (`Canvas.cs:1711-1758`).

| scene | what it runs | needs |
|---|---|---|
| `benchmark` | the frame loop, verbatim from the one-shot shell: N frames, first excluded from the mean, both routes | — |
| `goldens` | every scene in the core's corpus, each held for a number of presents, ending on a chosen frame | — |
| `document` | the ONE-SHOT path kept BY NAME as a control: its own engine, created and freed per call, painting one document. Its `engines-created` reads 2 (the retained one plus this) and `engines-freed` reads 1 | a document |
| `retained` | the identity walk: load, mutate, resize away and back, hashing the back buffer at every stop through a staging texture before `Present` | the calibrated document |
| `stall` | a deliberate sleep inside ONE repaint on the render thread, or on the XAML thread, or both — the residency and liveness controls | a stall length |
| `pointer` | load, dump the document, and wait for a REAL gesture; a timeout is `NOT RUN`, never a synthetic receipt wearing `REAL` | a document |
| `stay` | paint once and do not complete and do not exit; the row carries the PID | optional document |
| `selection-marquee` | the synthesised marquee as it stood at checkpoint 3, renamed and kept as a CONTROL. It moves nothing and selects N; it proves nothing about the pointer seam. The old spelling `selection` is REFUSED by name pointing here, so no invocation written before the rename can silently run the wrong arm | a document |

Every scene's row ends with the tid tail, and every row is appended to
`sb-runs.log` under one lock and mirrored into the window title — the title is
how a measurement reaches a session-1 observer, the file is how it reaches
session 0.

## Knobs

Every environment variable this shell reads, and nothing else. F-1 was closed as
"working as intended" because `SB_SCENE_FINAL` **is** refused by name when it
names a golden the corpus does not hold — but a reader could not find that out,
because the README documented none of `SB_FRAMES`, `SB_SCENE_HOLD` or
`SB_SCENE_FINAL`. A close by documentation that nothing gates rots on the first
knob added after it, so `scripts/check_shell_knobs.py` censuses every
`GetEnvironmentVariable("...")` in `*.cs` and reds in BOTH directions: a knob
read and not listed here, and a row here naming a knob nothing reads.

**The gate checks the table's SHAPE; a reader checks its TRUTH.** A row that
says the wrong thing in the right columns passes, so every `meaning`, `default`,
`scene` and `kind` below was read back against its `GetEnvironmentVariable` site
and its fallback — not against the row above it. Where a knob is read at several
sites, the row says what each does.

`kind` is a closed vocabulary. `benchmark` inputs decide what is measured;
`interaction` inputs decide how the canvas behaves under a resize or a pointer;
`provenance` is the one input that decides WHICH BINARY RAN, which is a
different question from either.

| knob | meaning | default | scene | kind |
|---|---|---|---|---|
| `JAS_CORE_DLL` | path to the `jas_dioxus` cdylib to load, and the only input that decides WHICH BINARY the numbers below describe. Unset, the loader walks up from the exe for a directory holding `jas_dioxus/Cargo.toml` and takes `jas_dioxus/target/debug/jas_dioxus.dll` from it. A path that does not exist throws BY NAME at bind time, naming the cargo command that builds it — a resolver that returned nothing would surface later as a missing *function* instead of a missing *file* (`JasCore.cs:408`, `FindCoreDll` below it) | *(search upward from the exe)* | all | provenance |
| `SB_FRAMES` | how many frames `Benchmark()` runs; the first is excluded from every mean and reported separately (`Canvas.cs:1561`). It is read in exactly one other place — the receipt line, which echoes the RAW value into every row of every scene (`MainWindow.xaml.cs:786`), so a row from a `retained` or `pointer` run carries an `SB_FRAMES=` field that nothing in that run read | `60` | `benchmark` | benchmark |
| `SB_FULLSCREEN` | `1` puts the window on the full-screen presenter BEFORE first layout, so the FIRST `SizeChanged` — the one that starts the run — is already the display's size rather than WinUI's default (`MainWindow.xaml.cs:121`). Set after layout it would label a run 4K while measuring a small window | *(unset: windowed)* | all | benchmark |
| `SB_HIT` | which element carries the pointer handlers: `panel` (the `SwapChainPanel` itself) or `sibling` (a transparent `Border` in the same grid cell, made visible only on this arm); any other value is REFUSED by name rather than falling back, because a run asked for the sibling that quietly used the panel would report the wrong arm in the one field the branch exists to answer (`MainWindow.xaml.cs:182-201`). The receipt says `hit=PANEL` or `hit=SIBLING`. **DECIDED on kenai 2026-09-03, one box: both arms fired and reported identical coordinates, so the answer is `panel`.** The `sibling` arm is KEPT as a switch because the docs do not settle hit-testability of a `Background`-less `SwapChainPanel`, and one box is one box | `panel` | all | interaction |
| `SB_MODE` | `direct` lets the core paint the back buffer; anything else uses an offscreen target plus one full-surface GPU copy (`Canvas.cs:484`). **It changes what `Benchmark()` measures and nothing else** (`Canvas.cs:1562`): the offscreen target is created on every attach and every resize whatever the scene (`Canvas.cs:1050`, `:1196`), but `Repaint()` always paints the back buffer directly through `jas_paint_frame`, so a `retained`, `pointer` or `stall` row is a DIRECT-route row however this is set | *(unset: offscreen)* | `benchmark` | benchmark |
| `SB_PAINT_ON_UI` | `1` marshals the paint AND the present through the `DispatcherQueue`, so `paint-tid == present-tid == ui-tid` on every row. O3's DESIGN-RED control: it exists to make the residency assertion fail by construction, so a green one is known to have been capable of red. Read ONCE into a static (`Canvas.cs:279`) — a run cannot change its answer half way through — and it switches the thread INSIDE the one paint step rather than forking a second paint path, because two paths would drift and the control would then measure the drift | *(unset: paint and present on the render thread)* | all | interaction |
| `SB_POINTER_WAIT_MS` | how long a scene waits for a REAL gesture before writing `NOT RUN: hand refused`; a timeout is never a synthetic receipt wearing `REAL`. The wait is a deadline, not a sleep — the thread that would sleep is the one that drains the gesture's own events (`Canvas.cs:2419-2429`). A non-numeric value is refused by name | `30000` | `pointer`, `retained` | interaction |
| `SB_RENDER_STALL_MS` | milliseconds the RENDER thread sleeps inside ONE repaint (`Canvas.cs:2251`, applied at `Canvas.cs:1421-1428`). The sleep is latched to that single repaint — the field is zeroed before it starts — so a stalled scene does not stall every later frame. A resize posted during the sleep appears as exactly one row after it, at the latest size; `Responding` stays `True`, because the thread that sleeps is not the one that pumps. Unset it and `SB_UI_STALL_MS` together and the `stall` scene REFUSES: a stall that stalls for zero measures nothing | *(unset: no render-thread stall)* | `stall` | interaction |
| `SB_RESIZE` | a comma-separated LIST of window sizes to drive after the scene, e.g. `1000x600,original`; `original` is the `AppWindow` size recorded at first layout, and it is a sentinel because this knob sets a WINDOW size while a hash is of the SURFACE, so a window size fed back returns a smaller surface. Each step is posted when the previous one has LANDED on the render thread, never after a sleep; a malformed token refuses by name rather than falling back to no resize (`MainWindow.xaml.cs:625-656`) | *(unset: no driven resize)* | all | interaction |
| `SB_SCENE` | which workload runs: `benchmark`, `goldens`, `document`, `retained`, `stall`, `pointer`, `stay`, `selection-marquee` (`Canvas.cs:1711-1758`). An empty value resolves to `benchmark` (`MainWindow.xaml.cs:472-473`), so every historical invocation keeps its meaning; an unrecognised value is refused by name; and the old spelling `selection` is REFUSED pointing at `selection-marquee` rather than silently running it, because that scene is a control and a receipt must never be ambiguous about which arm produced it | `benchmark` | all | benchmark |
| `SB_SCENE_FINAL` | which golden is painted LAST, so the photograph is of a chosen frame rather than of whatever the loop ended on (`Canvas.cs:1808`). A name the corpus does not hold fails the scene BY NAME after the sweep, listing every golden the corpus does hold | `ref_shapes.json` | `goldens` | benchmark |
| `SB_SCENE_HOLD` | how many presents each held frame stays on screen (`Canvas.cs:2573`); at a sync interval of 1 that is ~16 ms apiece, so the default holds each for roughly 200 ms and a human sees a slideshow rather than a flicker | `12` | `goldens`, `document`, `selection-marquee` | benchmark |
| `SB_SIZE` | pin the swapchain at an explicit `WxH` in PHYSICAL pixels, so a copy can be priced at a stated surface (`MainWindow.xaml.cs:430`). Deliberately NOT the fix for the DIP defect below — it is the narrower thing, an explicit size input. A malformed value refuses loudly rather than falling back to the laid-out size, which would label a run 4K and measure it at 3.6 Mpx. Mutually exclusive with `SB_RESIZE`: a later resize is refused by name (`MainWindow.xaml.cs:389`) | *(unset: the laid-out DIP size)* | all | benchmark |
| `SB_SQUEEZE` | `1` sets `PreferredMinimumHeight = 1` and squeezes the window to the status row, so the panel's `SizeChanged` fires with height 0 through the real window manager rather than through a probe (`MainWindow.xaml.cs:574`). It needs an `OverlappedPresenter` and REFUSES by name on any other kind — a squeeze that did not happen must not read as a squeeze that was accepted | *(unset: no squeeze)* | all | interaction |
| `SB_SURFACE_PROBE` | a `WxH` fed straight to `SurfacePolicy.Decide` — including `0x0` — so the policy function can be exercised without a window manager (`MainWindow.xaml.cs:534`). The receipt says `policy=PROBE`, and the ACCEPT arm lives here too (`1000x600` accepts and resizes), because a refusal arm alone is satisfied by a function that refuses everything | *(unset: no probe)* | all | interaction |
| `SB_SVG` | path to the `.svg` a document-bearing scene opens; required by `document`, `retained`, `pointer` and `selection-marquee`, optional for `stall` and `stay`, and refused by name when a scene that needs it has none. `retained` additionally refuses any file but the CALIBRATED `complex_document.svg` (`Canvas.cs:2126`, `:2171-2178`), because O1 compares hashes with no tolerance | *(none: the scene refuses)* | `document`, `retained`, `pointer`, `selection-marquee`, `stall`, `stay` | benchmark |
| `SB_SYNTH_DRAG` | `x,y,dx,dy[,k]` in PHYSICAL pixels, replayed through `jas_pointer_event` on the render thread as press, `k` moves (default 2) and release (`Canvas.cs:2197`, `:2349`, replayed at `:2452`). The seam's positive control: the harness picks the point and the delta from `sb-doc-before.json`, so the shell cannot know what it hit. `k` is the fifth field rather than a knob of its own because a control that cannot follow a varied `k` is weaker than the hand it stands in for. The receipt says `pointer=SYNTHETIC` and can never say `REAL` | *(unset: the scene waits for a real hand)* | `retained`, `pointer` | interaction |
| `SB_TOOL` | which tool index the pointer drives, checked at first layout before any scene is enqueued (`MainWindow.xaml.cs:414-423`). Only `0` (selection) is answered this wave; **any other value is refused BY NAME and the run stops**, because captured-only forwarding is answered for the selection tool only and a tool that reads idle motion (the pen sets its cursor on every unpressed move) would be driven with the wrong event stream. A run that asked for the pen and silently got selection would report a gesture the tool never saw | `0` | all | interaction |
| `SB_TOPMOST` | `1` keeps the window at the top of the z-order, so a console that appears later cannot cover the canvas in a capture — Windows Terminal ignores `-WindowStyle Hidden`, measured across three consecutive runs. It needs an `OverlappedPresenter` and is SILENTLY SKIPPED on any other kind (`MainWindow.xaml.cs:136-140`), so a full-screen run is never topmost. Opt-in, so every timing already on record keeps meaning what it meant | *(unset: normal z-order)* | all | benchmark |
| `SB_UI_STALL_MS` | milliseconds the XAML thread sleeps, posted to it from the scene (`Canvas.cs:2252`, `:2288-2292`). O3's ORACLE-LIVENESS control: `Responding` must read `False`, because an oracle that cannot say `False` says nothing when it says `True`. Unset it and `SB_RENDER_STALL_MS` together and the `stall` scene refuses. Combining it with `SB_PAINT_ON_UI=1` cannot hang: the paint step's hand-over to the sleeping thread refuses by name after 5 s | *(unset: no UI-thread stall)* | `stall` | interaction |

## How the harness runs a scene

Two scripts, and the division between them is the point. `verify_window.ps1`
launches ONE app in session 1 and asserts a window; `sitting.ps1` drives a LIST
of scenes through it and closes its own totals.

```powershell
powershell -File prototypes\sb_winui\sitting.ps1 `
    -Scenes goldens,document `
    -Svg    test_fixtures\svg\complex_document.svg
```

What `sitting.ps1` does, in order, and every step of it is a trap already paid
for:

1. **It refuses if the shell is not built**, printing the real SDK path — the
   `dotnet` on PATH is runtime-only and shadows the SDK, so a bare
   `dotnet build` prints the same error as a machine with no SDK at all.
2. **It rebuilds the cdylib first, every time** (`cargo build
   --no-default-features --features d2d,ffi --lib`) and refuses to launch if
   that fails. THE LAST LANE TO TOUCH `target/` DECIDES WHAT THE SHELL LOADS: a
   `--features ffi` test lane overwrites `jas_dioxus.dll` with a library that
   compiles the painter out entirely, and the shell then dies with
   `EntryPointNotFoundException` on a symbol that exists in the source.
   Measured 2026-09-03: 7,351,296 bytes fails every scene, 7,766,528 bytes
   paints 21/21. `-NoRebuild` skips it and is only for someone who has just
   built it.
3. **It resolves the document to an absolute path** and refuses if it is
   missing — but only when the scene list contains a scene that opens one.
4. **It sets the scene and the document per iteration** (`SB_SCENE`, `SB_SVG`)
   and calls `verify_window.ps1` once per scene, requiring
   `JAS S-B MATERIALIZER CHECKPOINT 3 | RUSTOK` in the title. Requiring
   `| RUSTOK` is what turns a window-existence oracle into one that asserts the
   Rust half: the title is matched as a substring, so a bare title passes a
   window whose title says `RUSTFAIL`, and passes a capture taken before
   anything was drawn — its pixel arm measures the whole desktop, where the
   WALLPAPER supplies every colour it counts.
5. **It reads the receipt out of the title** — `RUSTOK (.+)$` — and survives
   its own absence: a failing scene has no `RUSTOK` line at all, and the
   obvious `.Matches.Groups[1]` throws on the exact path where the summary
   matters most.
6. **It closes its totals.** A scene attempted and landed in neither column is
   a lost row, and the runner declares its own verdict void rather than let a
   headline imply the rest.

`verify_window.ps1 -Title <substring> -Exe <absolute path> [-Seconds n]
[-ExpectColor r,g,b]` launches the exe through an interactive scheduled task in
session 1, captures the desktop, asserts the title and the pixel statistics, and
tears down. **`-Exe` must be absolute** — the task's working directory is not the
caller's, so a relative path resolves against `C:\Windows\system32`, the app
never starts, and the whole run reads as an ORACLE failure rather than a bad
argument. It refuses by name instead. As it stands on this commit the teardown
kills by process NAME; a run-and-stay switch and a PID-scoped teardown are
separate work.

A scene not in `sitting.ps1`'s list is run by setting its knobs and calling
`verify_window.ps1` directly. The knob table above is the complete list of what
can be set, which is the whole reason it is gated.

## Measured — and which shell each number came from

**The benchmark loop was moved into `Benchmark()` verbatim**, so the one-shot
shell's numbers are still comparable with a `benchmark` run today: same frame
count, same first-frame exclusion, same two routes. What is NOT comparable is
anything taken through a resize — on the one-shot shell a `SizeChanged` ran the
whole loop, and on the retained canvas it costs one frame.

### The ONE-SHOT shell, 1904x941, hardware, 300 frames each (2026-08-24)

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

### The ONE-SHOT shell, re-measured at a second surface size — and the area model is dead

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

⚠️ **`present max` is a MAX and reads like a typical cost.** The 12.20 ms cell
is a tail; the mean beside it is 5.30 ms. Quoting the max as the present cost
overstates it by 2.3x, and the two live in adjacent columns of one row.

### ⛔ DEFECT FOUND BY THIS RUN: the swapchain is sized in DIPs, not pixels

`SB_FULLSCREEN=1` reports **2560x1405, not 3840x2160**. The desktop is at 150%
scaling: 3840x2160 physical is 2560x1440 in DIPs, less 35 DIPs for the status
row. `Canvas.SizeChanged` gives DIPs and that value goes straight into swapchain
creation.

**So the core renders 3.60 Mpx and the compositor upscales 1.5x to fill 8.29 Mpx**
— on a Vector Illustration Application, a fidelity defect rather than a tuning
detail. It is invisible in every timing above because it makes the work smaller
for both routes equally. **Not fixed here**: it is real work with consequences
for the pen pipeline, and it belongs on a backlog rather than inside a
measurement run. It also means the true physical-4K copy cost remains unmeasured.
The pointer path is written to be right on both sides of that fix: it multiplies
by the composition scale and the core divides back, which is an identity today
and stays correct once the buffer is sized in pixels.

### The RETAINED CANVAS, measured on kenai 2026-09-03

These rows are the new shell's, taken on the box; nothing here is inferred from
the tables above.

| what | reading |
|---|---|
| a repaint caused by a pointer event | **~1.9 ms**, `frames=1` on every `REPAINT` row |
| the same event on the ONE-SHOT shell | **373 ms** per `SizeChanged`, because the resize path ran the whole 60-frame loop |
| `Present` on the DIRECT route | **4.8–5.06 ms regardless of surface** — vsync-bound, the same flatness the offscreen route showed |
| `hit=PANEL` vs `hit=SIBLING` | both arms fired, **identical coordinates**; the decision is `panel` |
| the `document` control's engine counters | `engines-created=2 engines-freed=1` — the retained engine plus the control's own, freed before the count is read |
| the `retained` walk's engine counters | `engines-created=1 engines-freed=0` at every stop, which is the claim those rows carry |

⚠️ **`engines-freed` read `0` on the first measurement of the merged shell and
nothing had leaked.** The counters were read inside the `try` while the control's
`jas_engine_free` ran in the `finally` — after the row was composed. The row was
a true statement about a moment one call too early. It is repaired in the code
(free, then count) rather than annotated, because an ordering fact reported as a
count is exactly the shape a reader cannot tell from a leak.

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

**The direct route is the one the variant wants** and it works, so the Graphics
Tools install docketed for the Captain is no longer blocking: it was wanted to
explain the `E_NOINTERFACE`, and the `E_NOINTERFACE` is explained.

---

## Historical: the defect as it stood before the cause was found

Kept because the exclusion method is the transferable part.

The chain ran end to end and the last step failed. **Rust's paint returned 0**;
`Present` then returned `0x80004002`.

**The reproduction is exact.** `SB_SKIP_PAINT=1` acquired the back buffer and
did everything else identically, without calling Rust:

    SB_SKIP_PAINT=1 -> "RUSTOK presented 1904x941 on hardware"     Present SUCCEEDS
    (default)       -> "Present 0x80004002 [paint rc=ok]"          Present FAILS

⛔ **`SB_SKIP_PAINT` is REMOVED; both lines above are retained as NARRATIVE.**
No line of the shell has read it since the cause was found, it has no row in the
knob table — which is the complete list — and setting it today does nothing at
all. It is kept here because the two-line contrast is what named the variable,
and a reader who tries to reproduce it deserves to know that before the run
rather than after.

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

**The canvas landed 2026-09-03.** The engine is held for the life of the window
on a dedicated render thread, the repaint is split from the benchmark, the zero
surface is refused by a three-valued policy instead of clamped, and the pointer
is real. The scenes above are how each of those is observed; the receipt rows
carry the thread ids that prove where the paint ran.

Checkpoint 1's original evidence, kept because the harness is the point:

```
ok  : capture ran in session 1, bounds 2560x1440 at (0,0)
ok  : window present -- SbWinUi: JAS S-B MATERIALIZER CHECKPOINT 1
ok  : real desktop pixels (mean luma 58.4, 1832 colours)
VERIFY: PASS
```

**No D3D, no SwapChainPanel, no Rust yet — deliberately.** The seat breadcrumb
records what it cost to move two variables at once here: a launch-mechanism
fault was briefly believed to be the Dioxus CLI. The chain under test in
checkpoint 1 is exactly *dotnet SDK → WinUI 3 → interactive scheduled task → a
window a session-1 observer can see*.

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

Three toolchain traps apply and are documented in the seat breadcrumb; all
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

## How checkpoint 2 was settled — the ownership question, and what it cost

The recon said the existing `Direct2DPainter` could not feed a `SwapChainPanel`,
and it was right. `HeadlessTarget`
(`jas_dioxus/src/painter/direct2d/device.rs:46`) renders into an **`IWICBitmap`**
via `ID2D1Factory::CreateWicBitmapRenderTarget`, chosen deliberately so the
painter could run headless in CI; pixels left only as a CPU `Vec<u8>`. There was
no D3D11 device, no `ID2D1Factory1`, no `ID2D1DeviceContext` and no swapchain
anywhere in the crate.

**Two facts made the gap much cheaper than it looked, and both held:**

* **`Direct2DPainter` itself needed ZERO changes.** It borrows
  `&'a ID2D1RenderTarget` and reaches the factory through `self.rt.GetFactory()`
  rather than storing one. In windows-rs 0.62 `ID2D1DeviceContext` derefs to
  `ID2D1RenderTarget`, so `Direct2DPainter::new(&*device_context)` compiles
  unchanged. All 14 trait methods, `geometry.rs`, `convert.rs` and `text.rs`
  were already target-agnostic. The gap was entirely in the *device*.
* **DXGI was already compiled in.** `Win32_Graphics_Dxgi_Common` transitively
  enables `Win32_Graphics_Dxgi`, so `IDXGIFactory2::CreateSwapChainForComposition`
  and friends were present; only `Win32_Graphics_Direct3D11` had to be added to
  the `windows` crate features.

**`ISwapChainPanelNative` still has zero hits in windows-rs** — it lives in
Windows App SDK metadata, so it is hand-declared on the C# side, which calls it.

**The ownership question is DECIDED, and the decision is C#.** The shell owns
the D3D11 device, the composition swapchain and the back buffer; the core is
handed a surface pointer per frame and paints into it. What made the choice was
not the graphics but the threading rule: BL2 says every call for an engine must
happen on the thread that created it, so the thread that paints must be the
thread that owns the retained document — and that thread also has to own the
device it paints through. The alternative (Rust owns the swapchain, the host
passes a panel) would have put the engine's thread affinity on the far side of
the seam.

The FFI surface is no longer silent about painting either: `jas_paint_frame`,
`jas_paint_document`, `jas_paint_scene`, `jas_load_svg`, `jas_pointer_event`,
`jas_set_dpi_scale`, `jas_set_tool`, `jas_selection_len`, `jas_document_json`,
`jas_instr_counters_json` and `jas_free` are all bound in `JasCore.cs`, and each
carries its ownership and threading rule (BL1–BL6) in the doc comment above its
`DllImport` rather than in a document beside it.

S-B has no ruled kill-gate; if a point is reached where one is needed to judge
whether the variant is dying, that goes back to the Captain rather than being
invented here.
