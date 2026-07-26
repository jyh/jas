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

4. **Metrics** per sweep point: avg + p95 frame time (ms), CPU encode time
   (the `Scene::append` cost) separated from total frame time, and fps. 2s warmup
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
  because the CPU `append` overlaps GPU work and there is no `poll(Wait)`
  barrier. Offscreen is therefore a conservative *floor*.
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

| elements | frame avg (ms) | frame p95 (ms) | encode avg (ms) | fps |
|---------:|---------------:|---------------:|----------------:|----:|
| 10,000   | 2.90   | 3.22   | 0.12  | 345.0 |
| 50,000   | 7.52   | 7.93   | 0.81  | 133.0 |
| 100,000  | 14.34  | 14.82  | 1.71  | **69.7** |
| 250,000  | 46.09  | 46.94  | 4.00  | 21.7  |
| 500,000  | 87.72  | 89.60  | 7.78  | 11.4  |
| 800,000  | 139.56 | 142.68 | 12.71 | 7.2   |

File: `results/2026-07-26-rtx5060ti-dx12-offscreen.json`. Re-run three times;
frame times reproduce within 0.3% (800k within 2%).

### Windowed — AutoNoVsync, GPU-pipelined (the real present path)

Physical window **2400×1500**. Driven from the interactive desktop via a
`LogonType Interactive` scheduled task — see "Windows invocation" below, since a
plain ssh run cannot do this.

| elements | frame avg (ms) | frame p95 (ms) | encode avg (ms) | fps | pipelining gain |
|---------:|---------------:|---------------:|----------------:|----:|----------------:|
| 10,000   | 1.76   | 1.89   | 0.14  | 567.4 | 1.65× |
| 50,000   | 6.48   | 6.80   | 0.86  | 154.3 | 1.16× |
| 100,000  | 11.74  | 12.20  | 1.69  | **85.2** | 1.22× |
| 250,000  | 33.79  | 38.02  | 3.96  | 29.6  | 1.36× |
| 500,000  | 74.99  | 76.29  | 7.86  | 13.3  | 1.17× |
| 800,000  | 117.97 | 119.79 | 13.06 | 8.5   | 1.18× |

File: `results/2026-07-26-rtx5060ti-dx12-windowed.json`.

Two things to read here.

**Windows measures the present path more cleanly than macOS does.** kenai's
windowed curve is strictly monotone and its p95 tracks its average closely
(1.76/1.89, 11.74/12.20). The Mac's windowed run is bimodal at the fast end —
`frame_p95` pinned near 17 ms, the ~60 Hz compositor beat — and *non-monotone*
(its 10k reads slower than its 50k), because macOS partially throttles even under
`AutoNoVsync`. kenai's 567 fps at 10k shows no refresh cap whatsoever. So on
Windows the windowed number is trustworthy at every point on the ladder, and on
the Mac only above 100k.

**The pipelining gain independently confirms finding #3.** Overlapping CPU and
GPU can only hide the GPU portion of a frame, so the achievable speedup is
`(cpu+gpu)/max(cpu,gpu)`. kenai gains just **1.16–1.36×** where the Mac gains up
to 2×. Solving that back: kenai's frame is ~82% unhideable CPU — which is the
*same 82%* the process-CPU measurement found independently (0.82 of 16 cores
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

## Verdict — against the ratified line

**PASS_WITH_CAVEATS, now on both platforms.**

- **60fps @ 100k — PASS on Metal and on D3D12, in both modes.** Mac: 79 fps
  serialized offscreen, 115 fps windowed. kenai: **69.7 fps** serialized offscreen
  at retina 3200×2000, and **85.2 fps** on the real windowed present path. All four
  numbers clear the bar; the Mac clears it with more room. Both platforms are
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
     `(cpu+gpu)/max(cpu,gpu)`. kenai's windowed mode gains only 1.16–1.36× over
     serialized offscreen, which solves back to a frame that is ~82% unhideable
     CPU — the *same 82%* the process-CPU measurement found by a completely
     different route. Two unrelated instruments landing on one number is the
     strongest single piece of evidence here.

   Two consequences. First, **the Mac-vs-kenai gap above is a CPU comparison**,
   not a verdict on either GPU — the RTX 5060 Ti and the M5 Pro GPU are both
   loafing, and neither result is evidence about GPU capability. Second, **the
   optimization lever at scale is the CPU encode path, not the GPU**: retain or
   incrementally update the scene instead of re-appending it every frame, and use
   the idle cores. GPU headroom is abundant on both platforms.

   A caveat on the rig's own instrumentation, worth knowing before trusting the
   `encode` column as "the CPU cost": it **under-reports CPU by roughly 8×**. At
   800k, `enc_avg` is 12.7 ms but the process burns ~114 ms of CPU per 139.6 ms
   frame, so ~100 ms of CPU is inside `render_to_texture` — Vello's resolve and
   buffer upload — which the rig never separately times. `enc_avg` is only the
   `Scene::append` slice. Splitting `render_to_texture` into resolve-vs-submit is
   the obvious next instrument.

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
