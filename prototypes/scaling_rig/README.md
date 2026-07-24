# scaling_rig — Arc 2 prototype #1 (wgpu / Vello)

A measured prototype, ratified in place of the dead Iced-vs-egui bake-off. It
answers one question, verbatim from the ratified verdict line:

> Does the wgpu/Vello path hold **60fps at 100k jas-shaped elements** with a
> **graceful (non-cliff) degradation curve to 1M**?

First verdict is on real Apple-Silicon Metal (this Mac). The offscreen mode is
built for the later WARP / Parallels-VM API-truth pass (the VM exposes no
hardware GPU).

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

## Verdict — against the ratified line

**PASS_WITH_CAVEATS.**

- **60fps @ 100k — PASS.** 79 fps in the serialized offscreen floor and 115 fps
  (avg) on the real windowed present path, both at full retina 3200×2000. The bar
  is cleared with headroom even in the conservative measurement.
- **Graceful (non-cliff) degradation — PASS within the reachable range.**
  Offscreen frame time grows smoothly and roughly linearly with element count
  (12.6 → 31 → 56 → 87 ms across 100k → 250k → 500k → 800k); no discontinuous
  collapse. Windowed `frame_avg` is likewise monotone from 50k up.
- **…to 1M — FAIL (hard ceiling, not a curve).** A single retained `vello::Scene`
  cannot reach 1M elements at all on Vello 0.9 — see finding #2 below. The natural
  architecture walls out at **~807k** with a `Validation Error`, well short of 1M.
  Reaching 1M needs the document split into multiple scene batches (a distinct
  multi-pass / compositing architecture the conductor should weigh).

Net: the wgpu/Vello path is comfortably fast enough at 100k and degrades
gracefully, but "one retained scene to 1M" is blocked by a hard device/spec
ceiling around 807k. The 1M target is an architecture question, not a
frame-time question.

---

## Two load-bearing findings (why the rig exists — "expect API iteration")

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

# Tests (scene determinism, mix ratios, stats)
cargo test
```

### Future VM / WARP invocation — and the backend trap

The Parallels VM has **no hardware GPU**; it will run the **offscreen** mode
against a software backend for API-truth. **Always name `--backend` explicitly.**
There is deliberately no "all backends" option: an all-backends probe attempts
GL, which **segfaults under Parallels**. Pick the one backend you mean.

```bash
# In the VM (software rendering) — pick the backend explicitly, offscreen only
cargo run --release -- --backend vulkan --mode offscreen --elements 100000
# or --backend dx12 on WARP. Never omit --backend; never probe all.
```

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
