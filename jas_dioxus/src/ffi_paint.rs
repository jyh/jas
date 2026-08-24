//! S-B SPIKE SEAM: paint into a DXGI surface the host owns.
//!
//! **This is a spike entry point, not ratified ABI.** It lives outside `ffi.rs`
//! deliberately: `ffi.rs` is the S-A surface that BL1-BL6 were written for, and
//! this function exists only while S-B decides whether the C#/WinUI-3
//! materializer variant is viable.
//!
//! SEPARATE MODULES DO NOT KEEP IT OUT OF THE HEADER, and this comment used to
//! claim they did. **cbindgen does not evaluate `#[cfg]`** — it parses the whole
//! crate from `lib.rs` and emitted this seam as an unconditional declaration,
//! producing precisely the header-that-lies the separation was supposed to
//! prevent: a consumer building without `d2d` compiling against a symbol absent
//! from the library. `check_cbindgen_freshness.py` caught it minutes after the
//! seam was written, which is the gate doing exactly its job on its author.
//!
//! The real fix is the `[defines]` block in `cbindgen.toml`, which maps
//! `feature = d2d` and `windows` onto `JAS_WITH_D2D` / `_WIN32` so the generated
//! declarations carry `#if` guards. **A C consumer must define `JAS_WITH_D2D`
//! to see anything in this module.**
//!
//! WHAT IT PROVES, AND WHAT IT DOES NOT. It proves the whole seam: that a
//! WinUI-3 host can create a D3D11 device and a composition swapchain, hand
//! Rust a back buffer, and have Direct2D pixels appear on the desktop. It does
//! NOT paint a document — that is the next checkpoint, and it needs the element
//! render path rather than a new boundary.
//!
//! THE OWNERSHIP RULE, which is the part that must survive into real ABI:
//! **the surface is BORROWED for the duration of the call.** Rust addrefs
//! nothing, retains nothing, and frees nothing. The host owns the device, the
//! swapchain and the back buffer, and is free to resize or drop them the moment
//! this returns. That is what keeps BL4 to a single rule — every crossing
//! allocation Rust owns is released by `jas_free`, and this call allocates
//! nothing that crosses.
//!
//! BL2 still applies: call on the thread that owns the device context. For a
//! WinUI host that is the UI thread, which is also where
//! `ISwapChainPanelNative::SetSwapChain` must be called.

use core::ffi::c_void;

use windows::core::Interface;
use windows::Win32::Graphics::Direct2D::Common::{D2D1_COLOR_F, D2D_RECT_F};
use windows::Win32::Graphics::Direct3D11::{ID3D11Device, ID3D11DeviceContext, ID3D11Resource};
use windows::Win32::Graphics::Dxgi::{IDXGIDevice, IDXGISurface};

use crate::painter::direct2d::surface::SurfaceTarget;

/// Status codes for the spike seam. Deliberately NOT `JasStatus`: that enum is
/// the frozen five-class contract of the S-A surface, and widening a frozen
/// vocabulary for a spike is how a spike becomes load-bearing by accident.
pub const JAS_PAINT_OK: i32 = 0;
/// Caller passed NULL. POSITIVE so it cannot collide with an HRESULT.
pub const JAS_PAINT_NULL_SURFACE: i32 = 1;
/// The pointer was not a usable `IDXGISurface`. Positive, same reason.
pub const JAS_PAINT_NOT_A_SURFACE: i32 = 2;

// ANY OTHER NON-ZERO RETURN IS THE RAW HRESULT, and that is a repair rather than
// a design. The first version collapsed every COM failure into a single -3, so
// the host learned only that `SurfaceTarget::from_dxgi_surface` had failed --
// which is the WHERE and never the WHY. Diagnosing it then required editing and
// rebuilding both sides. HRESULTs are negative on failure and the two sentinels
// above are positive, so the spaces cannot overlap.

/// The probe pattern's background, as `(r, g, b)` in 0..=255.
///
/// CHOSEN TO BE UNLIKELY, NOT TO BE PRETTY. The desktop verifier proves the
/// frame reached the screen by counting pixels of exactly these two colours in
/// a screenshot, so a colour the Windows shell also uses would let a run pass
/// on somebody else's pixels. That is the same law the CI lane guard runs on:
/// assert a value only the thing actually running can produce.
pub const PROBE_BG: (u8, u8, u8) = (0, 96, 96);
/// The probe pattern's square.
pub const PROBE_FG: (u8, u8, u8) = (255, 0, 255);

fn srgb(c: (u8, u8, u8)) -> D2D1_COLOR_F {
    D2D1_COLOR_F {
        r: c.0 as f32 / 255.0,
        g: c.1 as f32 / 255.0,
        b: c.2 as f32 / 255.0,
        a: 1.0,
    }
}

/// Paint the S-B probe pattern into a caller-owned DXGI surface.
///
/// Returns `JAS_PAINT_OK` (0), a positive sentinel for a bad pointer, or the
/// raw HRESULT of whichever COM call failed. The host presents; this does not.
///
/// # Safety
/// `surface` must be NULL or a valid `IDXGISurface` COM pointer that stays
/// alive for the duration of the call. Ownership is NOT transferred: the caller
/// still releases it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_paint_probe_surface(surface: *mut c_void, width: f32, height: f32) -> i32 {
    if surface.is_null() {
        return JAS_PAINT_NULL_SURFACE;
    }

    // BORROWED, not owned: `from_raw_borrowed` does not addref and will not
    // release. Getting this wrong in the other direction -- `from_raw` -- would
    // hand Rust an owning reference to the host's back buffer and free it out
    // from under the swapchain on drop.
    let surface: &IDXGISurface = match unsafe { IDXGISurface::from_raw_borrowed(&surface) } {
        Some(s) => s,
        None => return JAS_PAINT_NOT_A_SURFACE,
    };

    let target = match SurfaceTarget::from_dxgi_surface(surface) {
        Ok(t) => t,
        Err(e) => return e.code().0,
    };

    let dc = target.context();
    unsafe {
        dc.BeginDraw();
        dc.Clear(Some(&srgb(PROBE_BG)));

        // A centred square at a third of the smaller dimension, so the pattern
        // is recognisable at any panel size and the verifier's pixel counts do
        // not depend on the window happening to be a particular shape.
        let side = (width.min(height) / 3.0).max(8.0);
        let (cx, cy) = (width / 2.0, height / 2.0);
        let brush = match dc.CreateSolidColorBrush(&srgb(PROBE_FG), None) {
            Ok(b) => b,
            Err(e) => {
                let _ = dc.EndDraw(None, None);
                return e.code().0;
            }
        };
        dc.FillRectangle(
            &D2D_RECT_F {
                left: cx - side / 2.0,
                top: cy - side / 2.0,
                right: cx + side / 2.0,
                bottom: cy + side / 2.0,
            },
            &brush,
        );

        if let Err(e) = dc.EndDraw(None, None) {
            return e.code().0;
        }
    }

    JAS_PAINT_OK
}

/// Paint an OFFSCREEN surface, then GPU-copy it into the host's back buffer.
///
/// The route the direct path cannot currently take. `jas_paint_probe_surface`
/// paints the back buffer itself and the host's subsequent `Present` fails with
/// `E_NOINTERFACE`; here Direct2D never touches the back buffer at all, so if
/// `Present` succeeds afterwards it confirms the mechanism by sidestepping it.
///
/// THE COPY LIVES HERE RATHER THAN IN THE HOST, and not for tidiness. C#'s
/// `ID3D11DeviceContext::CopyResource` threw `InvalidCastException` out of
/// `InterfaceMarshaler.ConvertToNative` even with both arguments already typed
/// as `ID3D11Resource` -- a CLR marshalling wrinkle around the generated
/// interop. windows-rs calls COM directly with no marshaller in between.
///
/// Ownership is unchanged: BOTH surfaces are the host's, borrowed for the call.
///
/// # Safety
/// Both pointers must be NULL or valid `IDXGISurface` COM pointers alive for the
/// duration of the call. Neither is released here.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_paint_probe_offscreen(
    back: *mut c_void,
    offscreen: *mut c_void,
    width: f32,
    height: f32,
) -> i32 {
    if back.is_null() || offscreen.is_null() {
        return JAS_PAINT_NULL_SURFACE;
    }

    // Paint the offscreen surface with the ordinary path first. If that fails
    // there is nothing worth copying, and its status code is already meaningful.
    let rc = unsafe { jas_paint_probe_surface(offscreen, width, height) };
    if rc != JAS_PAINT_OK {
        return rc;
    }

    let back_s: &IDXGISurface = match unsafe { IDXGISurface::from_raw_borrowed(&back) } {
        Some(s) => s,
        None => return JAS_PAINT_NOT_A_SURFACE,
    };
    let off_s: &IDXGISurface = match unsafe { IDXGISurface::from_raw_borrowed(&offscreen) } {
        Some(s) => s,
        None => return JAS_PAINT_NOT_A_SURFACE,
    };

    unsafe {
        // The device again comes FROM the surface, so no D3D11CreateDevice.
        let dxgi_device: IDXGIDevice = match off_s.GetDevice() {
            Ok(d) => d,
            Err(e) => return e.code().0,
        };
        let d3d: ID3D11Device = match dxgi_device.cast() {
            Ok(d) => d,
            Err(e) => return e.code().0,
        };
        let ctx: ID3D11DeviceContext = match d3d.GetImmediateContext() {
            Ok(c) => c,
            Err(e) => return e.code().0,
        };

        let dst: ID3D11Resource = match back_s.cast() {
            Ok(r) => r,
            Err(e) => return e.code().0,
        };
        let src: ID3D11Resource = match off_s.cast() {
            Ok(r) => r,
            Err(e) => return e.code().0,
        };
        ctx.CopyResource(&dst, &src);
        ctx.Flush();
    }

    JAS_PAINT_OK
}

#[cfg(test)]
mod tests {
    use super::*;
    use windows::Win32::Foundation::HMODULE;
    use windows::Win32::Graphics::Direct3D::D3D_DRIVER_TYPE_WARP;
    use windows::Win32::Graphics::Direct3D11::{
        D3D11CreateDevice, ID3D11Device, ID3D11DeviceContext, ID3D11Texture2D,
        D3D11_BIND_RENDER_TARGET, D3D11_CPU_ACCESS_READ, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        D3D11_MAPPED_SUBRESOURCE, D3D11_MAP_READ, D3D11_SDK_VERSION, D3D11_TEXTURE2D_DESC,
        D3D11_USAGE_DEFAULT, D3D11_USAGE_STAGING,
    };
    use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SAMPLE_DESC};

    const W: u32 = 90;
    const H: u32 = 60;

    fn warp() -> (ID3D11Device, ID3D11DeviceContext) {
        let mut d = None;
        let mut c = None;
        unsafe {
            D3D11CreateDevice(
                None,
                D3D_DRIVER_TYPE_WARP,
                HMODULE::default(),
                D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                None,
                D3D11_SDK_VERSION,
                Some(&mut d),
                None,
                Some(&mut c),
            )
            .expect("WARP");
        }
        (d.unwrap(), c.unwrap())
    }

    fn tex(dev: &ID3D11Device, staging: bool) -> ID3D11Texture2D {
        let desc = D3D11_TEXTURE2D_DESC {
            Width: W,
            Height: H,
            MipLevels: 1,
            ArraySize: 1,
            Format: DXGI_FORMAT_B8G8R8A8_UNORM,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            Usage: if staging { D3D11_USAGE_STAGING } else { D3D11_USAGE_DEFAULT },
            BindFlags: if staging { 0 } else { D3D11_BIND_RENDER_TARGET.0 as u32 },
            CPUAccessFlags: if staging { D3D11_CPU_ACCESS_READ.0 as u32 } else { 0 },
            MiscFlags: 0,
        };
        let mut t = None;
        unsafe { dev.CreateTexture2D(&desc, None, Some(&mut t)).expect("tex") };
        t.unwrap()
    }

    fn read(dev: &ID3D11Device, ctx: &ID3D11DeviceContext, src: &ID3D11Texture2D) -> Vec<u8> {
        let staging = tex(dev, true);
        let mut out = vec![0u8; (W * H * 4) as usize];
        unsafe {
            ctx.CopyResource(&staging, src);
            let mut m = D3D11_MAPPED_SUBRESOURCE::default();
            ctx.Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut m)).expect("map");
            for y in 0..H as usize {
                std::ptr::copy_nonoverlapping(
                    (m.pData as *const u8).add(y * m.RowPitch as usize),
                    out.as_mut_ptr().add(y * W as usize * 4),
                    W as usize * 4,
                );
            }
            ctx.Unmap(&staging, 0);
        }
        out
    }

    fn rgb_at(buf: &[u8], x: u32, y: u32) -> (u8, u8, u8) {
        let i = ((y * W + x) * 4) as usize;
        (buf[i + 2], buf[i + 1], buf[i])
    }

    /// The seam, exercised exactly as the C# host will call it: a raw pointer in,
    /// a status code out, pixels on a surface this code did not create.
    #[test]
    fn the_probe_paints_through_a_raw_pointer() {
        let (dev, ctx) = warp();
        let t = tex(&dev, false);
        let surface: IDXGISurface = t.cast().expect("surface");

        let rc = unsafe {
            jas_paint_probe_surface(surface.as_raw(), W as f32, H as f32)
        };
        assert_eq!(rc, JAS_PAINT_OK, "paint status");

        let buf = read(&dev, &ctx, &t);
        assert_eq!(rgb_at(&buf, W / 2, H / 2), PROBE_FG, "centre is the square");
        assert_eq!(rgb_at(&buf, 2, 2), PROBE_BG, "corner is the background");
    }

    /// THE OFFSCREEN ROUTE, tested WITHOUT a GUI.
    ///
    /// Written because the WinUI host died with `0xC0000374`
    /// (STATUS_HEAP_CORRUPTION) in ntdll the first time it took this route, while
    /// the direct route ran fine in the same build. Heap corruption deserves a
    /// deterministic reproduction rather than another launch of a windowed app:
    /// if this passes, the Rust half is not the corrupting side and the search
    /// moves to the host's COM reference handling.
    ///
    /// Two WARP textures on ONE device, exactly as the host has one device with a
    /// back buffer and an offscreen target.
    #[test]
    fn the_offscreen_route_paints_and_copies_without_corrupting_the_heap() {
        let (dev, ctx) = warp();
        let dst = tex(&dev, false);
        let src = tex(&dev, false);
        let dst_s: IDXGISurface = dst.cast().expect("dst surface");
        let src_s: IDXGISurface = src.cast().expect("src surface");

        // Run it repeatedly: a single call can corrupt the heap without tripping
        // over the damage, and the host was doing sixty frames.
        for _ in 0..16 {
            let rc = unsafe {
                jas_paint_probe_offscreen(dst_s.as_raw(), src_s.as_raw(), W as f32, H as f32)
            };
            assert_eq!(rc, JAS_PAINT_OK, "offscreen paint+copy status");
        }

        // The DESTINATION must carry the pattern -- proving the copy happened and
        // not merely that the paint did.
        let buf = read(&dev, &ctx, &dst);
        assert_eq!(rgb_at(&buf, W / 2, H / 2), PROBE_FG, "copied centre");
        assert_eq!(rgb_at(&buf, 2, 2), PROBE_BG, "copied corner");
    }

    /// A NULL surface must be a status code, never a crash. The host is C#, and
    /// a panic across an `extern "C"` boundary is undefined behaviour, not an
    /// exception the CLR can catch.
    #[test]
    fn a_null_surface_is_a_status_not_a_crash() {
        let rc = unsafe { jas_paint_probe_surface(std::ptr::null_mut(), 10.0, 10.0) };
        assert_eq!(rc, JAS_PAINT_NULL_SURFACE);
    }

    /// The two probe colours must stay distinguishable from each other and from
    /// black and white, because the desktop verifier counts them in a
    /// screenshot. If someone "tidies" them to nearby values this fails here
    /// rather than as an unexplained verifier miss later.
    #[test]
    fn the_probe_colours_are_far_apart_and_not_shell_colours() {
        let d = |a: (u8, u8, u8), b: (u8, u8, u8)| {
            (a.0 as i32 - b.0 as i32).abs()
                + (a.1 as i32 - b.1 as i32).abs()
                + (a.2 as i32 - b.2 as i32).abs()
        };
        assert!(d(PROBE_BG, PROBE_FG) > 300, "probe colours must be far apart");
        assert!(d(PROBE_BG, (0, 0, 0)) > 100, "background must not be near black");
        assert!(d(PROBE_FG, (255, 255, 255)) > 100, "square must not be near white");
    }
}
