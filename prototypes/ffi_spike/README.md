# S-A — the boundary spike

**Flask (jas/windows), 2026-07-29.** A throwaway-shaped but repo-resident spike that
prices the `extern "C"` seam between the Rust core and a native C# shell.

Design and the boundary laws BL1–BL6: `jas_dioxus/src/ffi.rs`, which states each
law at the item it governs. Authorised by JYH as item 3 of the ratified order, with the
extern surface **authored during the spike** rather than pre-specified.

## What it answers

D1 keeps the Rust core and gives port six a new native frontend. Letter 13's working
hypothesis is a **C#/WinUI 3 shell as a MATERIALIZER** over that core — the Rust
interpreter computes the widget tree, C# turns node kinds into native controls. That
hypothesis has three cheap ways to die, and S-A is the first.

| gate | question | result |
|---|---|---|
| **(i)** | does it build **headless** from the CLI on kenai — cargo + dotnet, no Visual Studio? | **PASS** |
| **(ii)** | does `widget_tree` round-trip a panel byte-identical to the existing golden? | **PASS** — all 16 |
| **(iii)** | does `dispatch_event` apply an op and the canonical JSON read back? | **PASS** |

**Kill condition (letter 13): if (i) failed and could not be repaired in a day, the
variant lost to pure-Rust win32 on toolchain grounds alone.** It did not fail.

## Running it

```sh
# the cdylib (feature-gated; the default web build never sees it)
cd jas_dioxus && cargo build --no-default-features --features ffi --lib

# the harness
cd prototypes/ffi_spike && dotnet run -- <repo-root>

# or let MSBuild drive cargo, which is letter 13 section 2C's specific worry:
dotnet build -p:BuildRustCore=true
```

Exit 0 means every assertion held. 19 assertions, ~900 ms.

## Measured on kenai

| | |
|---|---|
| .NET SDK | 10.0.302, installed **without elevation** via `dotnet-install.ps1` |
| `dotnet build` (C# harness) | **4 s** |
| MSBuild → cargo → cdylib → build | **1 s** warm |
| cdylib | 6.0 MB debug |
| harness run | 903 ms, 19/19 |
| cbindgen | 0.29.4 → `jas_dioxus/include/jas_ffi.h`, 8 functions |

`winget` would not install the .NET SDK user-scope ("no applicable installer"), and
machine scope needs elevation a non-interactive session auto-declines. `dotnet-install.ps1`
into `%LOCALAPPDATA%\Microsoft\dotnet` is the supported no-admin path and is what CI uses.
**It is not on PATH**; prepend `$HOME/AppData/Local/Microsoft/dotnet`.

## What the harness actually proves

Beyond the three gates, it pins the two things most likely to rot silently:

* **The error channel is the ratified taxonomy, not a new one.** Codes 1–5 map by
  position onto the five frozen `OpError` classes; transport faults (bad UTF-8, bad JSON,
  null handle) live at ≥100 so they can never be mistaken for a core verdict. The harness
  drives all four reachable classes plus a transport fault and asserts the disjointness.
* **BL5 — UTF-8 byte spans, never `string`.** The default P/Invoke `CharSet` is `Ansi`,
  i.e. cp1252 on this box, which is this seat's day-one defect class wearing an ABI
  costume. The harness dispatches an op carrying `Ünïcodé-Ω-日本` and asserts it reads
  back intact from canonical JSON. There is not one `string` in any `DllImport` signature.

Gate (ii) is a real round-trip and not a self-consistency check because `jas_widget_tree`
makes the **identical call the corpus driver makes** at `cross_language_test.rs:5317`.

## Scope, stated

* **Console, not WinUI, deliberately** — a GUI would make gate (i) unanswerable, and
  nothing here needs a window.
* **No `jas_load_document`.** The design sketched one; `geometry::test_json` has no
  whole-document *parser*, only the writer, so implementing it would have meant inventing
  one. No gate needs it — gate (iii) starts from an empty model and builds through ops,
  which is the BL1 path anyway.
* **No swapchain, no rendering.** That is S-B, and its seam should be designed against a
  real `SwapChainPanel` rather than in advance.
* **This proves the boundary is cheap and correct. It does NOT price the materializer** —
  how many lines it takes to turn 38 widget kinds into WinUI controls. That is S-C, and it
  is the number that actually decides the variant.

## One anomaly, recorded rather than explained

During the post-change regression sweep, `cargo build --target wasm32-unknown-unknown`
crashed **rustc** with `STATUS_ACCESS_VIOLATION` (0xc0000005), once. It did **not**
reproduce — three consecutive rebuilds exit 0 — and there is **no corroborating system
event**: no WHEA-Logger entry of any id, no Kernel-Power 41, no bugcheck, no WER report,
no Application Error.

Two hypotheses, neither proven:

* **rustc incremental-cache corruption.** It happened on the *first* build after
  `crate-type` changed, which invalidates the incremental cache, and the crashing
  invocation carried `-C incremental=…`. This fits every observation and is the more
  parsimonious reading.
* **The memory fault.** kenai is running EXPO ON at 6000 — the speed it was crashing at —
  and this was under sustained multi-core load. A userspace corruption need not log WHEA.

Recorded here because a one-off compiler access violation on a machine under an active
hardware experiment should not be silently discarded, and because the honest verdict is
"unexplained, most likely the compiler, cannot be distinguished from the memory with the
evidence available." **If it recurs, that changes.**
