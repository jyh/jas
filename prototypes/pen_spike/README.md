# pen_spike — Arc 2 prototype #2 (pen-latency plumbing)

The measurement apparatus for the ratified pen pipeline (council #3): raw
`WM_POINTER`, a dedicated input thread eventually, and **sub-20 ms
motion-to-photon on real iron**. This crate is the **PLUMBING** phase — it
builds and unit-tests the latency ledger and the Win32 + wgpu probe that feeds
it. The **measured** runs (an interactive desktop session, later the Captain's
Wacom over USB passthrough) are a human desk-sitting and are deliberately
**out of this phase's scope**. This rig is built so a human can do them in one
double-click plus one CLI flag.

Standalone crate under `prototypes/`. It touches no port (`jas_dioxus/`,
`JasSwift/`, `workspace_interpreter/`, the frozen trees) and is not part of any
workspace, exactly like the sibling `scaling_rig`.

---

## The split — pure lib, Win32 bin

* **Library** (`src/lib.rs` + `qpc` / `ledger` / `stats` / `report`): pure,
  platform-independent logic. Every timestamp and the QPC frequency are *data*,
  so the whole ledger → stats → JSON/CSV layer compiles and `cargo test`s on
  **any** host — including this Mac. 22 unit tests cover tick↔micros conversion,
  the ring buffer (overflow / drop-oldest / wrap), stage extraction with its
  missing-endpoint and negative-span guards, the percentile stats, and the
  JSON/CSV writers.
* **Binary** (`src/main.rs` + `src/win.rs`): Windows-only. Raw Win32
  `WM_POINTER` input plus a minimal wgpu ink trail, feeding the ledger. On any
  non-Windows host `main` is a stub that points you at `cargo test`
  (the Win32/GPU deps are `cfg(windows)`-gated, so the Mac test build stays
  lean).

---

## What it measures (and what it cannot)

Per pointer event the bin captures four instants, all in raw QPC ticks:

| instant | source |
|---|---|
| `hw_timestamp` | `POINTER_INFO.PerformanceCount` — the OS/driver hardware timestamp (an honest `None` + flag if the driver reports none) |
| `handler_receipt_qpc` | `QueryPerformanceCounter` the moment our `WM_POINTER*` handler ran |
| `encode_start_qpc` | when we began encoding the wgpu frame for that event |
| `present_submitted_qpc` | when we submitted the present for that frame |

From those, five **stage** durations (avg / p50 / p95 / p99 / min / max, in µs):

| stage | span | meaning |
|---|---|---|
| `hw_to_receipt` | hw → receipt | OS/driver + message-queue delay |
| `receipt_to_encode` | receipt → encode | our dispatch overhead |
| `encode_to_present` | encode → present | our encode + submit cost |
| `receipt_to_present` | receipt → present | **app-internal end-to-end** (always available) |
| `hw_to_present` | hw → present | **fullest app-internal end-to-end** (needs a hw timestamp) |

**This is app-internal latency only.** It is a strict **lower bound** on true
motion-to-photon: it excludes compositor, scan-out, and panel response, which
need real hardware plus a high-speed camera pointed at the glass. The verdict
below is labeled accordingly.

---

## Toolchain (resolved 2026-07-23)

`Cargo.lock` is not committed (the repo ignores `*.lock`). Pinned for
reproduction, all from the VM's warm cache: **windows 0.62.2**, **wgpu 30.0.0**,
**raw-window-handle 0.6.2**, **pollster 1.0**, **bytemuck 1.25**, **clap 4**,
**serde 1** / **serde_json 1**. Built with **rustc 1.97.1**,
target `aarch64-pc-windows-msvc`, `edition = "2021"`.

wgpu 30 API notes banked while wiring the probe (they bit, in order): `Instance::new`
takes the descriptor **by value** and `InstanceDescriptor` has no `Default`
(use `new_without_display_handle`); `get_current_texture` returns a
`CurrentSurfaceTexture` **enum**, not a `Result`; present moved to
`Queue::present(tex)`; `SurfaceConfiguration` gained `color_space`;
`PipelineLayoutDescriptor` swapped `push_constant_ranges` for `immediate_size`;
`RenderPipelineDescriptor`/`RenderPassDescriptor` use `multiview_mask`;
`VertexState::buffers` is now `&[Option<VertexBufferLayout>]`. In windows-rs the
pointer-device **functions** live in `UI::Input::Pointer` but the **structs and
type constants** live in `UI::Controls`.

---

## How the Captain runs it — the next VM desk-sitting

Two commands, at an **interactive** Windows session (not over ssh — window
creation needs a desktop). Build first (see below), then, from
`C:\Users\jyh\projects\claude\jas\prototypes\pen_spike`:

```bat
:: 1. Truth-check the input hardware. With the Wacom attached you should see a
::    pen device, its type, and its tip-pressure logical range.
target\release\pen_spike.exe --list-pointers

:: 2. Measure. A borderless window opens; DOODLE in it for the whole window.
::    It auto-exits after --seconds, writes JSON, and prints the stage table.
target\release\pen_spike.exe --seconds 30 --csv pen_spike_events.csv
```

`EnableMouseInPointer(TRUE)` is set, so **a plain mouse also drives the
`WM_POINTER` path** — you get a real run even before the pen is attached; the
pen just makes it a pen run.

### Attaching the Wacom (Parallels USB passthrough)

Parallels menu **Devices → USB & Bluetooth → [your Wacom]** to hand the tablet
to the VM. Then re-run `--list-pointers`: `pointer devices` should become ≥ 1
with `pen=true` and a tip-pressure range. (Sessionless / detached it reports
`pointer devices: 0`, which is the expected negative result — see below.)

### The WARP present-timing caveat — read before trusting the table

The Parallels VM has **no hardware GPU**; the only wgpu adapter is the **WARP
software rasterizer** (`--backend dx12`, which the report labels
`Cpu (WARP software rasterizer)`). Therefore:

* The **input-side** stages (`hw_to_receipt`, `receipt_to_encode`) are the
  **honest** signal on the VM — they are pure Win32 timing, no GPU involved.
* The **present-side** stages (`encode_to_present`, and the `*_to_present`
  end-to-ends) are **real but WARP-polluted**: software rasterization inflates
  them. The JSON records this in `meta.present_timing_note`. Treat present-side
  VM numbers as an upper bound on the wrong hardware, not as the pipeline's
  cost. A hardware-GPU sitting (bare-metal Windows, or the eventual real iron)
  is what makes the present side meaningful.

Backend is **always explicit** (`--backend dx12` default). There is no
all-backends option, on purpose: an all-backends probe attempts GL, which
**segfaults under Parallels**.

---

## Verdict — against the ratified line

**The ratified verdict line this rig exists to fill in:**

> **app-internal latency ≤ ~8 ms** — recorded as a **LOWER BOUND** on
> motion-to-photon (compositor + scan-out + panel are not measured here).

Fill it from a hardware-GPU sitting using `hw_to_present` (or `receipt_to_present`
when no hardware timestamp is present). ~8 ms at a 10 MHz QPC is 80 000 ticks;
the ledger and its `cargo test` are pinned to that arithmetic. The number is a
floor, never a ceiling: real motion-to-photon is this **plus** everything past
`present_submitted`, so a passing app-internal figure is necessary, not
sufficient, for the sub-20 ms goal.

---

## Build (in the VM)

The `arc2-prototypes` branch is not pushed, so sources are transferred, not
`git clone`d — the repo copy stays authoritative.

VM build trees mirror the Mac layout under
`C:\Users\jyh\projects\claude\jas\prototypes\` (this rig at
`...\prototypes\pen_spike`, the GPU smoke at `...\prototypes\wgpu_smoke`).

```bash
# From the Mac repo (prototypes/):
tar -cf - -C pen_spike Cargo.toml src | \
  ssh -o BatchMode=yes win-vm 'tar -xf - -C ~/projects/claude/jas/prototypes/pen_spike && \
  cd ~/projects/claude/jas/prototypes/pen_spike && cargo build --release'
```

## CLI

| flag | default | meaning |
|------|---------|---------|
| `--list-pointers` | off | enumerate pointer devices and exit (the Wacom truth-check) |
| `--backend` | `dx12` | `dx12` (WARP on the VM) \| `vulkan` \| `gl` — explicit, never all |
| `--seconds N` | `30` | measured seconds, then auto-exit |
| `--ring N` | `65536` | latency-ledger ring capacity (records; oldest overwritten past this) |
| `--width` / `--height` | `1000`/`700` | initial window client size |
| `--out PATH` | `pen_spike_results.json` | summary + provenance JSON |
| `--csv PATH` | — | optional per-event CSV dump |

The JSON header records machine/backend/adapter, the WARP present-timing note,
the app-internal scope note, QPC frequency, and whether `EnableMouseInPointer`
took — the full provenance for any number this rig produces.

---

## This phase's verification (plumbing only)

* **Mac** `cargo test` — 22/22 green (lib is cross-platform).
* **VM** `cargo build --release` (`aarch64-pc-windows-msvc`) — clean, no warnings.
* **VM** `cargo test --lib` — 22/22 green on MSVC.
* **VM** `--list-pointers` over ssh — runs, reports `QPC frequency: 24000000`,
  `pointer devices: 0` (the honest sessionless outcome; the desk-sitting with the
  Wacom attached is what turns that into ≥ 1).
* The **windowed `--seconds` run is intentionally NOT executed here** — window
  creation needs an interactive desktop; that is the desk-sitting's job.
