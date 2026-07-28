# scaling_rig — Arc 2 prototype #1 (wgpu / Vello)

A measured prototype, ratified in place of the dead Iced-vs-egui bake-off. It
answers one question, verbatim from the ratified verdict line:

> Does the wgpu/Vello path hold **60fps at 100k jas-shaped elements** with a
> **graceful (non-cliff) degradation curve to 1M**?

Answered twice on real hardware: Apple-Silicon **Metal** (this Mac, 2026-07-23)
and **D3D12** on a discrete NVIDIA GPU (kenai, 2026-07-26). Both pass the 100k
line and degrade gracefully; both wall out at the same 807k spec ceiling. The
offscreen mode — originally built for a WARP / Parallels API-truth pass, since
superseded by real Windows silicon — is the serialized floor and the curve of
record on both platforms.

This is a standalone crate under `prototypes/`. It does not touch any port
(`jas_dioxus/`, `JasSwift/`, `workspace_interpreter/`, the frozen trees) and is
not part of any workspace.

---

## What it measures

1. **Deterministic "jas-shaped" scene** (`src/scene.rs`). Not a rect farm — a
   seeded mix approximating a real illustration, per 1000 elements:
   - ~40% cubic-bezier stroked paths (varied widths/colors, ~30% dashed)
   - ~25% filled curved shapes (blobs / ellipses / rounded)
   - ~15% stroked **and** filled shapes
   - ~10% synthetic text-like glyph runs
   - ~10% groups with 2–3 deep nested transforms (some clipped)

   Elements are scattered over a 24k×24k document plane so pan/zoom drives
   worst-case overdraw. The scene is a pure function of a `u64` seed
   (SplitMix64, no OS entropy) — `cargo test` asserts *same seed ⇒ byte-identical
   scene digest*.

   **Glyph honesty note:** the "glyph runs" are synthetic letter-like bezier
   outlines, not shaped font glyphs. Wiring Vello's real glyph API
   (`Scene::draw_glyphs`) needs an embedded font + skrifa outline extraction; to
   keep the rig zero-asset the runs are hand-built closed cubic outlines shaped
   like short words. It is an honest approximation of the *encoding* cost (many
   small filled paths in a row), not a text-shaping benchmark.

2. **Retained-scene architecture** (`src/gpu.rs`). Geometry is encoded **once**
   per sweep point into a retained `vello::Scene`. Each frame a reused outer
   `Scene` is `reset()` + `append(&inner, camera)` — re-encoding the command
   stream under an animated pan+zoom camera affine (`src/camera.rs`), *not*
   re-tessellating geometry. This mirrors how a real editor retains a document
   and re-applies only the viewport transform per frame.

3. **Two render modes**, same architecture:
   - **windowed** (winit, the measured mode on Metal): renders to Vello's
     intermediate texture, then blits to the surface (Vello is compute-based and
     has no `render_to_surface`). Present mode `AutoNoVsync`. `frame_ms` = the
     steady-state inter-frame interval (true, GPU-pipelined throughput).
   - **offscreen** (no window/surface; the VM/CI mode): renders to an owned
     Rgba8Unorm storage texture and blocks on the GPU (`poll(Wait)`) each frame.
     `frame_ms` = fully serialized CPU+GPU time — a conservative floor, no
     pipelining.

4. **Metrics** per sweep point: avg + p95 frame time (ms), and three nested spans
   of the same frame — `encode` (the `Scene::append` cost), `cpu` (encode **plus**
   `render_to_texture`, i.e. all CPU work before the hand-off), and total
   `frame` — plus fps and `cpu_fraction` = cpu/frame. Use `cpu`, not `encode`, as
   "the CPU cost": `encode` under-reports it by 6.8–11.4× (finding #3). 2s warmup
   discarded, 8s measured. Sweep: 10k, 50k, 100k, 250k, 500k, 800k.

---

## Toolchain (resolved 2026-07-23)

`Cargo.lock` is not committed (the repo ignores `*.lock`). Pinned versions for
reproduction: **vello 0.9.0**, **wgpu 29.0.4** (vello 0.9 pins wgpu 29, so the
direct dep is `wgpu = "29"` to unify the `Device` types), **winit 0.30.13**,
**kurbo 0.13**, **peniko 0.6**. Built with rustc 1.94.1, `edition = "2021"`.

## Results — 2026-07-23, Apple M5 Pro, macOS 26.5.2, Metal

Both runs at retina resolution **3200×2000** (6.4 Mpx), seed `0x6a6173`, AA=Area.

### Offscreen — serialized CPU+GPU (the clean, reproducible curve of record)

| elements | frame avg (ms) | frame p95 (ms) | encode avg (ms) | fps |
|---------:|---------------:|---------------:|----------------:|----:|
| 10,000   | 4.47  | 7.44  | 0.09 | 223.8 |
| 50,000   | 10.16 | 13.98 | 0.45 | 98.4  |
| 100,000  | 12.65 | 13.98 | 0.87 | **79.0** |
| 250,000  | 31.25 | 38.21 | 2.14 | 32.0  |
| 500,000  | 56.13 | 59.01 | 4.22 | 17.8  |
| 800,000  | 87.41 | 91.86 | 6.73 | 11.4  |

### Windowed — AutoNoVsync, GPU-pipelined (the real present path)

| elements | frame avg (ms) | frame p95 (ms) | encode avg (ms) | fps |
|---------:|---------------:|---------------:|----------------:|----:|
| 10,000   | 10.14 | 17.01 | 0.10 | 98.6  |
| 50,000   | 6.71  | 16.92 | 0.50 | 149.0 |
| 100,000  | 8.69  | 16.75 | 0.92 | **115.0** |
| 250,000  | 17.65 | 19.21 | 2.17 | 56.7  |
| 500,000  | 32.87 | 35.49 | 4.20 | 30.4  |
| 800,000  | 51.31 | 53.84 | 6.74 | 19.5  |

Files: `results/2026-07-23-m-series-metal.json` (windowed),
`results/2026-07-23-m-series-metal-offscreen.json` (offscreen).

### Reading the two tables

- **Pipelining ≈ 2× at scale.** Windowed (pipelined) roughly doubles offscreen
  (serialized) throughput past 250k (250k: 56.7 vs 32.0 fps; 500k: 30.4 vs 17.8),
  because the CPU work overlaps GPU work and there is no `poll(Wait)` barrier.
  Offscreen is therefore a conservative *floor*. Finding #3 explains the size of
  that gain in hindsight: the achievable speedup is `(cpu+gpu)/max(cpu,gpu)`, so a
  2× gain means the Mac's frame is close to an even CPU/GPU split — which a later
  spot check confirmed (`cpu_fraction` ≈ 0.50, though on a busy machine). The same
  arithmetic predicts kenai's much smaller 1.2×, because kenai's frame is ~80% CPU.
- **Windowed fast-end is noisy.** At ≤100k the windowed distribution is bimodal
  (`frame_avg` ~7–10 ms but `frame_p95` ~17 ms, the ~60 Hz compositor beat);
  macOS partially throttles even under `AutoNoVsync`, so windowed fps below 100k
  is unreliable and even non-monotone (50k reads faster than 10k). Trust the
  **offscreen** curve for shape; trust windowed for "does the real present path
  clear the bar at 100k" (it does).

---

## Results — 2026-07-26, kenai (Ryzen 7 8700F + RTX 5060 Ti), Windows 11, D3D12

`KENAI` | AMD Ryzen 7 8700F 8-Core | Windows 11 Home 25H2 (build 26200) |
adapter **NVIDIA GeForce RTX 5060 Ti (DiscreteGpu)** — real hardware, not WARP.
Offscreen at **3200×2000**, the Mac's exact resolution, so the two curves are
directly comparable. Both modes are measured; the windowed run needed a
scheduled task inside the logged-on desktop session, because a plain ssh run has
no desktop and fails with `Invalid surface`.

> ### ⚠ MEMORY CONDITION — these numbers were taken at an overclock
>
> **Memory: 2×16 GB DDR5 at 6000 MT/s (EXPO profile ENABLED).** The SPD on these
> DIMMs declares **4800 MT/s**; the vendor shipped the EXPO profile on, so this
> table was measured **25% above the JEDEC baseline the machine is rated for.**
>
> That profile was disabled on 2026-07-27 after the machine reported three fatal
> Machine Check Exceptions in one day. **This table is therefore faster than the
> machine can honestly hold.** It is kept because it is the comparison of record
> against the Mac and because it is now half of a controlled experiment — see
> *Results — 2026-07-28, the same machine at JEDEC 4800* below, which re-takes
> the whole ladder with memory speed as the only variable.
>
> The condition is stated here rather than footnoted because it is not a caveat
> about precision, it is a different machine configuration.

| elements | frame avg (ms) | frame p95 (ms) | encode avg (ms) | **cpu avg (ms)** | fps | **cpu fraction** |
|---------:|---------------:|---------------:|----------------:|-----------------:|----:|-----------------:|
| 10,000   | 2.93   | 3.30   | 0.13  | 1.48   | 341.8 | 0.50 |
| 50,000   | 7.55   | 8.21   | 0.84  | 5.97   | 132.4 | 0.79 |
| 100,000  | 14.28  | 14.72  | 1.65  | 11.14  | **70.0** | 0.78 |
| 250,000  | 46.66  | 47.70  | 3.92  | 37.34  | 21.4  | 0.80 |
| 500,000  | 88.26  | 90.32  | 7.79  | 70.58  | 11.3  | 0.80 |
| 800,000  | 141.25 | 144.49 | 12.87 | 112.95 | 7.1   | 0.80 |

File: `results/2026-07-26-rtx5060ti-dx12-offscreen.json`. Re-run four times; frame
times reproduce within 0.3% (800k within 2%).

> **That 0.3% does not hold at 4800, and it is the load-bearing number for
> reading any small delta in this document.** Three runs at JEDEC 4800
> (2026-07-28) spread **1.8% at 10k–100k, 3.4% at 250k, 5.9% at 500k and 3.8% at
> 800k** — an order of magnitude wider. Whether the noise floor genuinely differs
> by memory configuration or the 0.3% was optimistic cannot be settled from here:
> EXPO is disabled, so the four-run 6000 measurement cannot be repeated. What IS
> settled is that **at 4800 a difference smaller than ~6% at the high end is not
> a measurement**, and the 4800 tables below are read against that floor rather
> than against 0.3%.

`cpu avg` is encode **plus** `render_to_texture` — everything the CPU does before
it hands off and waits — and `cpu fraction` is its share of the frame. Read the
gap between the `encode` and `cpu` columns: at 800k the encode metric reports
12.87 ms while the CPU actually spends 112.95 ms, so **`encode` alone
under-reports CPU by 6.8–11.4× across the ladder.** Everything in that gap is
inside Vello's resolve and buffer upload. And `cpu fraction` settling at
**0.78–0.80** from 50k up is the rig measuring, by itself, the same quantity that
external process-CPU sampling put at 0.82 and that the pipelining ceiling implies
independently — see finding #3.

### Windowed — AutoNoVsync, GPU-pipelined (the real present path)

Physical window **2400×1500**. Driven from the interactive desktop via a
`LogonType Interactive` scheduled task — see "Windows invocation" below, since a
plain ssh run cannot do this.

| elements | frame avg (ms) | frame p95 (ms) | encode avg (ms) | cpu avg (ms) | fps | **cpu fraction** | pipelining gain |
|---------:|---------------:|---------------:|----------------:|-------------:|----:|-----------------:|----------------:|
| 10,000   | 1.91   | 2.14   | 0.14  | 1.67   | 523.3 | 0.87 | 1.53× |
| 50,000   | 7.25   | 8.44   | 0.90  | 6.91   | 137.9 | 0.95 | 1.04× |
| 100,000  | 11.97  | 12.62  | 1.71  | 11.53  | **83.5** | 0.96 | 1.19× |
| 250,000  | 37.03  | 42.08  | 4.49  | 36.56  | 27.0  | 0.99 | 1.26× |
| 500,000  | 77.49  | 79.14  | 8.45  | 76.98  | 12.9  | 0.99 | 1.14× |
| 800,000  | 123.53 | 125.61 | 13.12 | 123.00 | 8.1   | 1.00 | 1.14× |

File: `results/2026-07-26-rtx5060ti-dx12-windowed.json`. `pipelining gain` is this
table's frame time against the offscreen table's, both from the runs published here.

Three things to read here.

**`cpu fraction` reaches 1.00. This is the finding at its sharpest.** In the
pipelined present path the CPU work occupies essentially the *entire* frame period
— 0.95 at 50k rising to 1.00 at 800k. The GPU is completely hidden behind CPU
work; there is nothing left to overlap. So on this path **the renderer's
throughput simply _is_ the throughput of one CPU thread encoding and resolving
scenes.** Every frame-rate number in this document above 50k is a measurement of
single-thread CPU speed wearing a graphics costume.

That also closes the loop arithmetically. Offscreen runs at `cpu fraction` 0.80,
i.e. frame = cpu + 20% GPU wait; windowed hides the wait entirely, so the
predicted gain is `1/0.80` = **1.25×**. Measured 1.14–1.26× from 100k up. The
prediction and the measurement were produced by different code paths on different
runs and agree to within noise.

**Windows measures the present path more cleanly than macOS does.** kenai's
windowed curve is strictly monotone and its p95 tracks its average closely
(1.91/2.14, 11.97/12.62). The Mac's windowed run is bimodal at the fast end —
`frame_p95` pinned near 17 ms, the ~60 Hz compositor beat — and *non-monotone*
(its 10k reads slower than its 50k), because macOS partially throttles even under
`AutoNoVsync`. kenai's 523 fps at 10k shows no refresh cap whatsoever. So *within*
a run, the windowed shape is trustworthy at every point on the ladder on Windows
and only above 100k on the Mac.

**Windowed still varies run to run, though — more than offscreen does.** Two kenai
windowed sweeps differed by up to 12% at a single point (50k: 6.48 vs 7.25 ms),
against offscreen's 0.3%. That noise is what makes the 50k pipelining gain read
1.04× here. Treat the gain column as approximate and the `cpu fraction` column —
stable across both runs — as the load-bearing one.

**The pipelining gain independently confirms finding #3.** Overlapping CPU and
GPU can only hide the GPU portion of a frame, so the achievable speedup is
`(cpu+gpu)/max(cpu,gpu)`. kenai gains just **1.14–1.26×** where the Mac gains up
to 2×. Solving that back: kenai's frame is ~80% unhideable CPU — which is the
*same fraction* the process-CPU measurement found independently (0.82 of 16 cores
busy). Two unrelated instruments agreeing on one number is the strongest evidence
in this document that the workload is CPU bound. The Mac's larger gain is
consistent too: its encode is ~2× faster and its window is 1.8× the pixels, so a
proportionally larger share of its frame is GPU work available to hide.

A note on the resolution mismatch: kenai's window is 2400×1500 against the Mac's
3200×2000, so the windowed tables are not pixel-matched the way the offscreen ones
are. Per finding #3 this is worth ~2%, well below the gaps being discussed — but
the offscreen tables remain the comparison of record.

### kenai vs the Mac — the crossover

| elements | kenai ms | Mac ms | kenai/Mac | encode ratio | ns/element (kenai, Mac) |
|---------:|---------:|-------:|----------:|-------------:|------------------------:|
| 10,000   | 2.90   | 4.47  | **0.65×** | 1.33× | 290, 447 |
| 50,000   | 7.52   | 10.16 | **0.74×** | 1.80× | 150, 203 |
| 100,000  | 14.34  | 12.65 | 1.13×     | 1.97× | 143, 126 |
| 250,000  | 46.09  | 31.25 | 1.47×     | 1.87× | 184, 125 |
| 500,000  | 87.72  | 56.13 | 1.56×     | 1.84× | 175, 112 |
| 800,000  | 139.56 | 87.41 | 1.60×     | 1.89× | 174, 109 |

**kenai is ~1.4× faster below the crossover (somewhere in 50k–100k) and ~1.6×
slower above it.** Two costs pulling in opposite directions: kenai's fixed
per-frame overhead is lower (D3D12 submit is cheaper here than Metal at retina),
while its per-element cost is ~1.6× higher. The encode column isolates the
second cleanly — `Scene::append` is pure single-thread CPU, no GPU involved, and
the Mac wins it by a near-constant **1.8–2.0×** from 50k up. That is an M5 Pro
memory-bandwidth win on what is essentially a large copy (unified LPDDR5X vs
dual-channel DDR5), and it sets the shape of the whole high end.

---

## Results — 2026-07-28, the same machine at JEDEC 4800 (EXPO disabled)

**Same box, same GPU, same binary, same resolution, same seed. Memory speed is
the only variable.** That makes this pair a controlled experiment rather than a
re-measurement, and it is the reason the section is worth its length.

> ### MEMORY CONDITION — stated, as above
>
> **2×16 GB DDR5 at 4800 MT/s, the JEDEC baseline the SPD declares. EXPO
> disabled.** Verified at the time of the run:
> `ConfiguredClockSpeed = 4800` on both DIMMs.
>
> The comparison is clean on the code axis too, and this was checked rather than
> assumed: the last change to the measured path is `93ec17f` (RIGCPU,
> 2026-07-26T13:03:28), and **nothing has touched `src/` since**, so the binary
> that produced both tables is the same code. The 6000-era offscreen file was
> generated at 13:02:19 — 69 s before that commit — but it already carries the
> `avg_cpu_ms` / `cpu_fraction` fields RIGCPU introduced, so it was produced by
> that code uncommitted and committed a minute later.

Offscreen, 3200×2000. `4800` is the **mean of three runs**
(`results/2026-07-28-rtx5060ti-dx12-offscreen-4800{,-run2,-run3}.json`); `noise`
is the observed spread across those three, and a delta smaller than its own noise
column is **not a result**.

| elements | 6000 ms | 4800 ms | Δ frame | noise | real? | encode 6000 | encode 4800 | **Δ encode** |
|---------:|--------:|--------:|--------:|------:|:-----:|------------:|------------:|-------------:|
| 10,000   | 2.93   | 3.16   | +8.0% | 1.9% | yes | 0.13  | 0.17  | +33.3%\* |
| 50,000   | 7.55   | 8.17   | +8.2% | 2.0% | yes | 0.84  | 0.98  | **+16.7%** |
| 100,000  | 14.28  | 15.09  | +5.6% | 1.8% | yes | 1.65  | 1.91  | **+16.0%** |
| 250,000  | 46.66  | 48.01  | +2.9% | 3.4% | no  | 3.92  | 4.66  | **+19.0%** |
| 500,000  | 88.26  | 89.11  | +1.0% | 5.9% | no  | 7.79  | 9.23  | **+18.5%** |
| 800,000  | 141.25 | 143.72 | +1.7% | 3.8% | no  | 12.87 | 14.84 | **+15.3%** |

\* 10k encode is 0.13 ms against a 0.01 ms reporting resolution; treat it as
quantisation, not as a 33% effect.

Windowed, 2400×1500, single run
(`results/2026-07-28-rtx5060ti-dx12-windowed-4800.json`): **100k = 80.1 fps**
against 83.5 at 6000. Per the windowed caveat above, that mode varies by up to
12% between runs and three of its six points came out *faster* at the lower
memory speed — so the windowed table confirms the verdict and **nothing else**.
Do not read its deltas.

### What this measures: finding #3, now by intervention rather than inference

Finding #3 concluded this workload is CPU- and memory-bandwidth bound. It argued
that from two instruments that agreed — the pipelining gain solved back to ~80%
unhideable CPU, and the process-CPU measurement independently reading 0.82. Both
are inferences from a fixed machine.

Cutting memory bandwidth by **20%** (6000 → 4800) is a *direct* test, and
`Scene::append` moves with it almost exactly:

**−20% memory bandwidth → +15.3% to +19.0% encode time, flat across the entire
ladder.**

That is the prediction "encode is a large bandwidth-bound copy" makes, and it is
now measured rather than reasoned. It also confirms the crossover analysis: the
Mac's 1.8–2.0× encode win was attributed to unified LPDDR5X bandwidth against
dual-channel DDR5, and DDR5 bandwidth is exactly what was varied here.

Total CPU per frame rose ~8% at 100k and ~3% at the top (two-run mean), so the
non-encode CPU work is bandwidth-sensitive too, but far less than encode.

### Why a 20% bandwidth cut costs only ~5% of a frame

Because encode is only **5–13% of frame time** on this machine. A 16% rise in a
13% component is ~2% of the frame; the rest of the observed low-end delta is the
rest of the CPU work. Above 250k the effect disappears into a 3.4–5.9% noise
floor — **not because the machine stopped caring about bandwidth, but because the
instrument cannot resolve it there.** The encode column, which is measured
directly rather than by difference, shows the effect is still fully present at
800k.

**The honest summary for a reader deciding what to trust: the recorded 6000
numbers are 5–8% optimistic at and below 100k, and within noise above it.**

**PASS_WITH_CAVEATS, now on both platforms.**

- **60fps @ 100k — PASS on Metal and on D3D12, in both modes, AND at kenai's
  honest memory speed.** Mac: 79 fps serialized offscreen, 115 fps windowed.
  kenai at EXPO 6000: **69.7 fps** serialized offscreen at retina 3200×2000, and
  **83.5 fps** on the real windowed present path.
  **kenai re-measured at JEDEC 4800 (2026-07-28), which is what the machine can
  honestly hold: 66.3 fps offscreen and 80.1 fps windowed — both still PASS.**
  The offscreen margin narrows from 1.17× to **1.10×**, which is the thinnest
  number in this document and the one to watch if the scene mix ever gets heavier.
  All numbers clear the bar; the Mac clears it with more room. Both platforms are
  measured on real hardware (`device_type` = IntegratedGpu / DiscreteGpu), not a
  software rasterizer.
- **Graceful (non-cliff) degradation — PASS within the reachable range, on both.**
  Offscreen frame time grows smoothly and roughly linearly with element count —
  Mac 12.6 → 31 → 56 → 87 ms and kenai 14.3 → 46 → 88 → 140 ms across
  100k → 250k → 500k → 800k; no discontinuous collapse on either. Per-element cost
  is flat to within a quarter across the top 16× of the ladder (kenai 143–184
  ns/element from 100k up, Mac 109–126). Windowed `frame_avg` is likewise monotone
  from 50k up on the Mac.
- **…to 1M — FAIL (hard ceiling, not a curve), and the ceiling is portable.**
  A single retained `vello::Scene` cannot reach 1M elements at all on Vello 0.9 —
  see finding #2 below. The natural architecture walls out at **~807k** with a
  `Validation Error`, well short of 1M. Verified on kenai 2026-07-26 to land on the
  *identical* boundary as the Mac: **807k renders (140.84 ms), 808k panics** — a
  different vendor, backend and OS hitting the same element count, which confirms
  this is the WebGPU spec limit rather than a device quirk. Reaching 1M needs the
  document split into multiple scene batches (a distinct multi-pass / compositing
  architecture the conductor should weigh).

Net: the wgpu/Vello path is comfortably fast enough at 100k on both Metal and
D3D12 and degrades gracefully on both, but "one retained scene to 1M" is blocked
by a hard spec ceiling at 807k that no hardware will lift. The 1M target is an
architecture question, not a frame-time question. And per finding #3, the frame
times here are a measure of single-thread CPU encoding, not of either GPU — so
the performance lever, when we need one, is on the CPU side.

---

## Three load-bearing findings (why the rig exists — "expect API iteration")

1. **Vello's `util::RenderContext` caps scenes at ~250–500k** by requesting
   `Limits::default()`, whose `max_storage_buffer_binding_size` is 128 MiB.
   Vello's single scene-encoding buffer exceeds that (~536 B/element here) and
   raises a fatal `Validation Error` at 500k. The rig does **not** use
   `RenderContext`; it builds the device with the adapter's real limits
   (`make_device` in `src/gpu.rs`), unlocking the M-series' much larger cap.
   *Any real editor on this path must do the same.*

2. **Single-scene ceiling ≈ 807k elements (WebGPU workgroup limit).** Even with
   raised buffer limits, one of Vello 0.9's compute stages dispatches a 1-D
   workgroup count proportional to scene size (~0.0811 groups/element here). At
   ~807k that hits the WebGPU hard limit `max_compute_workgroups_per_dimension`
   = 65535 (empirically: 807k renders, 808k crashes). This is why the default
   ladder tops out at 800k, and why literal 1M in a single scene is impossible on
   Vello 0.9 without chunking.

3. **This rig is single-thread CPU bound, not GPU bound — it is not really a GPU
   benchmark.** Discovered on kenai 2026-07-26, where the GPU could be
   instrumented directly (`nvidia-smi` sampled during runs). Four independent
   measurements agree:

   - **GPU utilization 21–46%**, and the driver *downclocks* under load —
     ~1400–1700 MHz of a 3090 MHz maximum, drawing 24–30 W of a 180 W budget.
     A GPU-bound workload pegs utilization and boosts clocks; this does neither.
   - **0.82 of 16 cores busy** (process CPU time / wall time), identical at 100k
     and 800k. Effectively one thread doing all the work with fifteen cores idle;
     the missing 18% is the `poll(Wait)` fence block.
   - **4× the pixels costs 1.4–3.5%.** Going from 1600×1000 to 3200×2000 (1.6 →
     6.4 Mpx) changed frame time by +3.5% at 100k and +1.4% at 800k. Cost tracks
     element count, not pixels, so rasterization is not the limiter either.
   - **The pipelining gain agrees, from the opposite direction.** Overlapping CPU
     and GPU can only hide the GPU portion, so the ceiling is
     `(cpu+gpu)/max(cpu,gpu)`. kenai's windowed mode gains only 1.14–1.26× over
     serialized offscreen, which solves back to a frame that is ~80% unhideable
     CPU — the *same 82%* the process-CPU measurement found by a completely
     different route. Two unrelated instruments landing on one number is the
     strongest single piece of evidence here.

   Two consequences. First, **the Mac-vs-kenai gap above is a CPU comparison**,
   not a verdict on either GPU — the RTX 5060 Ti and the M5 Pro GPU are both
   loafing, and neither result is evidence about GPU capability. Second, **the
   optimization lever at scale is the CPU encode path, not the GPU**: retain or
   incrementally update the scene instead of re-appending it every frame, and use
   the idle cores. GPU headroom is abundant on both platforms.

   **The rig now measures this itself.** Originally only `encode` (the
   `Scene::append` slice) was timed, and it **under-reports CPU by 6.8–11.4×** —
   at 800k it reads 12.87 ms against 112.95 ms actually spent. So a `cpu_ms` span
   (encode + `render_to_texture`, stopping before any wait) and a derived
   `cpu_fraction` were added, identical in both modes. kenai self-reports
   `cpu_fraction` **0.78–0.80** from 50k up, converging with the external 0.82
   from two other directions. Anyone reading these numbers should use the `cpu`
   column, not `encode`, as "the CPU cost".

   *Not yet measured cleanly:* the Mac's `cpu_fraction`. A spot check read ~0.50,
   consistent with its ~2× pipelining gain, but it was taken while the machine was
   compiling two worktrees, so it is contaminated and is deliberately not tabled.
   The Mac tables above predate the metric and need one quiet re-run.

---

## How to run

```bash
cd prototypes/scaling_rig

# Mac — measured windowed sweep on Metal (a window appears; it closes when done)
cargo run --release -- --backend metal --mode windowed

# Mac — clean serialized curve at retina resolution
cargo run --release -- --backend metal --mode offscreen --width 3200 --height 2000

# Single point / custom ladder
cargo run --release -- --backend metal --mode offscreen --elements 100000
cargo run --release -- --backend metal --mode offscreen --points 10000,100000,500000

# Tests (scene determinism, mix ratios, stats, host provenance)
cargo test
```

### Windows invocation — and the backend trap

**Always name `--backend` explicitly.** There is deliberately no "all backends"
option: an all-backends probe attempts GL, which **segfaults under Parallels**.
Pick the one backend you mean.

```powershell
# kenai — the curve of record, matching the Mac's resolution exactly
cargo run --release -- --backend dx12 --mode offscreen --width 3200 --height 2000

# Windowed on Windows needs an INTERACTIVE DESKTOP. Straight over ssh this fails
# with `Invalid surface` — an ssh session has no desktop to present into.
cargo run --release -- --backend dx12 --mode windowed
```

**Driving a windowed run remotely anyway.** If a desktop session is logged on
(check `Get-Process explorer | Select SessionId`), a scheduled task with
`LogonType Interactive` runs *in* that session and can create a surface, which is
how the windowed table above was measured over ssh. Redirect stdout, because you
cannot see the task's console:

```powershell
$rig = "C:\Users\jyh\projects\claude\jas\prototypes\scaling_rig"
$cmd = "/c cd /d `"$rig`" && target\release\scaling_rig.exe --backend dx12 " +
       "--mode windowed --out win.json > `"$rig\win_log.txt`" 2>&1"
$a = New-ScheduledTaskAction -Execute "cmd.exe" -Argument $cmd
$p = New-ScheduledTaskPrincipal -UserId "jyh" -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName RigWindowed -Action $a -Principal $p
Start-ScheduledTask -TaskName RigWindowed     # then poll .State until Ready
Unregister-ScheduledTask -TaskName RigWindowed -Confirm:$false
```

**PowerShell traps that will cost you a run.** `Select-Object -First N` on a
long-running command *terminates the upstream pipeline* — it kills the benchmark
mid-sweep, and you will fetch a stale JSON without noticing. And `a,b,c` is an
array literal, so `--points 10000,50000` arrives as separate arguments and clap
rejects it; quote it as `"10000,50000"`.

Every results file records `machine`, `chip`, `os`, `adapter` and `device_type`,
so a record proves which box and which GPU produced it — and in particular proves
it was `DiscreteGpu`/`IntegratedGpu` rather than a software rasterizer (`Cpu`).
Check that field before trusting any number: the Parallels runs were WARP, and
nothing in the older JSON said so.

The chosen backend is forced via `WGPU_BACKEND` before any wgpu init, set from
`--backend` in `main()`.

### CLI

| flag | default | meaning |
|------|---------|---------|
| `--backend` | *(required)* | `metal` \| `dx12` \| `vulkan` \| `gl` — explicit, never all |
| `--mode` | `windowed` | `windowed` (Metal, measured) \| `offscreen` (VM/CI) |
| `--elements N` | — | single point instead of the sweep |
| `--points a,b,c` | — | custom ladder |
| `--seconds` | `8` | measured seconds per point |
| `--warmup` | `2` | discarded warmup seconds per point |
| `--width` / `--height` | `1600`/`1000` | offscreen exact size; windowed uses the window's physical (retina) size |
| `--seed` | `0x6a6173` | deterministic scene seed |
| `--out` | `results.json` | output JSON path |

Machine context (chip, OS, backend, resolution, present mode, the retained-scene
architecture note, the timing-mode note) is recorded in every `results.json`.
