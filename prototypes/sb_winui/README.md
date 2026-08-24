# S-B — the C#/WinUI-3 materializer shell

Spike for D1's port-six variant: a **materializer shell, not a third
interpreter**, over the Rust core with `Direct2DPainter` behind the ratified
`Painter` trait. This directory is the C# half. It is a SPIKE — it decides the
variant, it is not a product.

Scope boundary inherited from S-A, stated in `../ffi_spike/README.md`:

> No swapchain, no rendering. That is S-B, and its seam should be designed
> against a real `SwapChainPanel` rather than in advance.

## Status

**Checkpoint 1 PASSES (2026-08-24): the shell builds and puts a window on the
desktop.** Verified, not assumed:

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
