//! Route (b): a D2D device context drawing into a DXGI surface the HOST owns.
//!
//! `device.rs` implements route (a) -- a WIC bitmap, no D3D, no swapchain, no
//! desktop -- and says of route (b) only that it exists. This is route (b), and
//! it is what S-B needs: `ISwapChainPanelNative::SetSwapChain` requires an
//! `IDXGISwapChain` on a D3D11 device, and a WIC bitmap can never be one.
//!
//! WHO OWNS WHAT, AND WHY THAT WAY
//! -------------------------------
//! **The host owns the device, the swapchain and the surface. Rust borrows a
//! surface for the duration of one call and retains nothing across the
//! boundary.** That is not a preference; it is what the ratified boundary laws
//! leave standing:
//!
//! * **BL6 -- "geometry never crosses".** Rust rasterizes and the host supplies
//!   the canvas. The alternative, handing geometry out for the shell to draw,
//!   is the third-interpreter D1 explicitly rejected.
//! * **BL4 -- Rust owns every crossing allocation, released by `jas_free`.** If
//!   Rust created the swapchain and returned it, the host would hold a
//!   Rust-created COM object released by `Release` instead -- a second, silent
//!   ownership rule on a boundary whose whole value is having exactly one.
//!
//! It also happens to be the cheaper half. Because the surface arrives with its
//! device attached (`IDXGIDeviceSubObject::GetDevice`), **shipping code never
//! calls `D3D11CreateDevice`**; the `Win32_Graphics_Direct3D11` feature exists
//! in `Cargo.toml` for the tests below, which must fabricate a device to have a
//! surface to test with.
//!
//! AND `Direct2DPainter` NEEDS NO CHANGES AT ALL. It borrows
//! `&ID2D1RenderTarget` and reaches the factory through `self.rt.GetFactory()`
//! rather than storing one, and `ID2D1DeviceContext` derefs to
//! `ID2D1RenderTarget`. So the fourteen trait methods, `geometry.rs`,
//! `convert.rs` and `text.rs` are already target-agnostic and are not touched.
//! The entire gap between headless B1 and a live swapchain is this file.
//!
//! DPI AND PIXEL FORMAT ARE COPIED FROM `device.rs` ON PURPOSE (B1 divergences
//! D4 and D5): 96 DPI so that 1 DIP == 1 CSS px and glyph sizes agree with the
//! other thirteen methods, and `_UNORM` rather than `_UNORM_SRGB` so blending
//! matches the browser's gamma-encoded sRGB. A swapchain target that quietly
//! chose different values would diverge from the headless target that the
//! conformance corpus is pinned against -- same painter, two answers.

use std::mem::ManuallyDrop;

use windows::core::Result;
use windows::Win32::Graphics::Direct2D::Common::{
    D2D1_ALPHA_MODE_PREMULTIPLIED, D2D1_PIXEL_FORMAT,
};
use windows::Win32::Graphics::Direct2D::{
    D2D1CreateFactory, ID2D1Bitmap1, ID2D1Device, ID2D1DeviceContext, ID2D1Factory1,
    ID2D1RenderTarget, D2D1_BITMAP_OPTIONS_CANNOT_DRAW, D2D1_BITMAP_OPTIONS_TARGET,
    D2D1_BITMAP_PROPERTIES1, D2D1_DEVICE_CONTEXT_OPTIONS_NONE, D2D1_FACTORY_TYPE_SINGLE_THREADED,
};
use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_B8G8R8A8_UNORM;
use windows::Win32::Graphics::Dxgi::{IDXGIDevice, IDXGISurface};

use super::device::PINNED_DPI;

/// A D2D device context bound to a surface owned by someone else.
///
/// Dropping this releases the context and the target bitmap. It does NOT
/// release the caller's surface, device or swapchain -- those were never ours.
pub struct SurfaceTarget {
    context: ID2D1DeviceContext,
    /// Held only to keep the target alive for the context's lifetime; the
    /// context does not addref it in a way we can rely on across a `SetTarget`.
    _bitmap: ID2D1Bitmap1,
    _device: ID2D1Device,
    _factory: ID2D1Factory1,
}

// A THREAD-LOCAL D2D DEVICE CACHE WAS TRIED HERE AND REVERTED, and the reason is
// worth more than the code was.
//
// The hypothesis was sound: the documented D2D-on-swapchain pattern keeps the
// factory, device and context alive ACROSS the present, while this file builds
// and destroys all three per call, so every Direct2D object is gone by the time
// the host calls `Present`. Caching them is also what S-C will want for its
// number.
//
// It did not fix the E_NOINTERFACE, AND IT HUNG THE TEST SUITE -- because a
// cached D2D device belongs to ONE D3D device, and each test here fabricates its
// own WARP device. The second test then handed a surface from a different device
// to a context built on the first. A cache like this has to be KEYED on the
// device it was built from, and an unkeyed one is not a simpler version of that,
// it is a broken one.
//
// Left out rather than fixed: it is not the defect's cause, so adding a keyed
// cache now would be tuning inside an open bug. It belongs with S-C's
// performance work, where its cost can be measured instead of assumed.

impl SurfaceTarget {
    /// Wrap a caller-owned DXGI surface as a D2D target.
    ///
    /// The surface must have been created `BGRA`-capable and bindable as a
    /// render target; a swapchain back buffer from `CreateSwapChainForComposition`
    /// satisfies both. The surface is borrowed for the call only.
    pub fn from_dxgi_surface(surface: &IDXGISurface) -> Result<Self> {
        unsafe {
            // The device comes FROM the surface, which is what keeps
            // D3D11CreateDevice out of shipping code entirely.
            let dxgi_device: IDXGIDevice = surface.GetDevice()?;

            let factory: ID2D1Factory1 =
                D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, None)?;
            let device = factory.CreateDevice(&dxgi_device)?;
            let context = device.CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE)?;

            let props = D2D1_BITMAP_PROPERTIES1 {
                pixelFormat: D2D1_PIXEL_FORMAT {
                    format: DXGI_FORMAT_B8G8R8A8_UNORM,
                    alphaMode: D2D1_ALPHA_MODE_PREMULTIPLIED,
                },
                dpiX: PINNED_DPI,
                dpiY: PINNED_DPI,
                // TARGET so it can be drawn INTO; CANNOT_DRAW because it is a
                // destination, never a source brush.
                bitmapOptions: D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
                colorContext: ManuallyDrop::new(None),
            };
            let bitmap = context.CreateBitmapFromDxgiSurface(surface, Some(&props))?;
            context.SetTarget(&bitmap);
            // Belt and braces with the bitmap's own dpi: the context carries its
            // own DPI and an unset one defaults to the system's, which is the
            // D4 divergence arriving through a different door.
            context.SetDpi(PINNED_DPI, PINNED_DPI);

            Ok(Self {
                context,
                _bitmap: bitmap,
                _device: device,
                _factory: factory,
            })
        }
    }

    /// The render target to hand `Direct2DPainter::new`.
    ///
    /// Returned as `&ID2D1RenderTarget` rather than the context because that is
    /// the type the painter takes, and the deref is what lets every existing
    /// method work unchanged.
    pub fn render_target(&self) -> &ID2D1RenderTarget {
        &self.context
    }

    /// The context itself, for callers that need effects or `BeginDraw`/`EndDraw`.
    pub fn context(&self) -> &ID2D1DeviceContext {
        &self.context
    }
}

impl Drop for SurfaceTarget {
    /// UNBIND THE BACK BUFFER — correct practice, and NOT the fix for the open
    /// Present defect. This docstring claimed it was; that claim was wrong and is
    /// corrected here rather than quietly deleted, because the exclusion is worth
    /// as much to the next reader as a fix would have been.
    ///
    /// MEASURED, by bisect, against a live WinUI-3 SwapChainPanel: presenting an
    /// UNTOUCHED back buffer succeeds, and presenting the same buffer after this
    /// target has drawn into it returns `E_NOINTERFACE` (0x80004002) from both
    /// `Present` and `Present1`, while `GetDesc1` on the same swapchain still
    /// reports a healthy 1904x941 with 2 buffers. So the swapchain is fine and
    /// the interface dispatch is fine; what is not fine is that Direct2D still
    /// holds the buffer as its render target.
    ///
    /// `EndDraw` is NOT sufficient — it ends the draw, it does not release the
    /// target. `SetTarget(None)` is what drops D2D's reference to the surface.
    /// Adding it did NOT clear the E_NOINTERFACE, so the cause lies elsewhere;
    /// it is kept because releasing a target you no longer own is right anyway.
    ///
    /// Doing it in `Drop` rather than asking callers to remember is deliberate:
    /// the failure it prevents appears in the HOST, one language and one process
    /// boundary away from the code responsible, as an error code that names
    /// neither Direct2D nor this file.
    fn drop(&mut self) {
        unsafe {
            self.context.SetTarget(None);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use windows::core::Interface;
    use windows::Win32::Foundation::HMODULE;
    use windows::Win32::Graphics::Direct2D::Common::D2D_RECT_F;
    use windows::Win32::Graphics::Direct3D::D3D_DRIVER_TYPE_WARP;
    use windows::Win32::Graphics::Direct3D11::{
        D3D11CreateDevice, ID3D11Device, ID3D11DeviceContext, ID3D11Texture2D,
        D3D11_BIND_RENDER_TARGET, D3D11_CPU_ACCESS_READ, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        D3D11_MAPPED_SUBRESOURCE, D3D11_MAP_READ, D3D11_SDK_VERSION, D3D11_TEXTURE2D_DESC,
        D3D11_USAGE_DEFAULT, D3D11_USAGE_STAGING,
    };
    use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SAMPLE_DESC};

    const W: u32 = 64;
    const H: u32 = 48;

    /// A D3D11 device on the WARP software adapter.
    ///
    /// WARP, not hardware, and that is deliberate: this test must run on a CI
    /// runner with no GPU and no display. `BGRA_SUPPORT` is required for D2D
    /// interop and its absence is a runtime failure with an unhelpful message.
    fn warp_device() -> (ID3D11Device, ID3D11DeviceContext) {
        let mut device: Option<ID3D11Device> = None;
        let mut context: Option<ID3D11DeviceContext> = None;
        unsafe {
            D3D11CreateDevice(
                None,
                D3D_DRIVER_TYPE_WARP,
                // HMODULE, not an Option: only meaningful for
                // D3D_DRIVER_TYPE_SOFTWARE, and a default handle is "none".
                HMODULE::default(),
                D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                None,
                D3D11_SDK_VERSION,
                Some(&mut device),
                None,
                Some(&mut context),
            )
            .expect("WARP device");
        }
        (device.unwrap(), context.unwrap())
    }

    fn texture(device: &ID3D11Device, staging: bool) -> ID3D11Texture2D {
        let desc = D3D11_TEXTURE2D_DESC {
            Width: W,
            Height: H,
            MipLevels: 1,
            ArraySize: 1,
            Format: DXGI_FORMAT_B8G8R8A8_UNORM,
            SampleDesc: DXGI_SAMPLE_DESC {
                Count: 1,
                Quality: 0,
            },
            Usage: if staging {
                D3D11_USAGE_STAGING
            } else {
                D3D11_USAGE_DEFAULT
            },
            BindFlags: if staging {
                0
            } else {
                D3D11_BIND_RENDER_TARGET.0 as u32
            },
            CPUAccessFlags: if staging {
                D3D11_CPU_ACCESS_READ.0 as u32
            } else {
                0
            },
            MiscFlags: 0,
        };
        let mut tex: Option<ID3D11Texture2D> = None;
        unsafe {
            device
                .CreateTexture2D(&desc, None, Some(&mut tex))
                .expect("texture");
        }
        tex.unwrap()
    }

    /// Read the rendered texture back as BGRA rows, via a staging copy.
    fn read_back(
        device: &ID3D11Device,
        ctx: &ID3D11DeviceContext,
        src: &ID3D11Texture2D,
    ) -> Vec<u8> {
        let staging = texture(device, true);
        let mut out = vec![0u8; (W * H * 4) as usize];
        unsafe {
            ctx.CopyResource(&staging, src);
            let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
            ctx.Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped))
                .expect("map");
            let src_ptr = mapped.pData as *const u8;
            for y in 0..H as usize {
                let row = src_ptr.add(y * mapped.RowPitch as usize);
                let dst = out.as_mut_ptr().add(y * (W as usize) * 4);
                std::ptr::copy_nonoverlapping(row, dst, (W as usize) * 4);
            }
            ctx.Unmap(&staging, 0);
        }
        out
    }

    fn px(buf: &[u8], x: u32, y: u32) -> (u8, u8, u8, u8) {
        let i = ((y * W + x) * 4) as usize;
        (buf[i + 2], buf[i + 1], buf[i], buf[i + 3]) // BGRA -> RGBA
    }

    /// THE POINT OF THE WHOLE FILE: paint into a surface this code did not
    /// create, and prove the pixels landed.
    ///
    /// Red-first value: before `SurfaceTarget` existed there was no way to
    /// target anything but a WIC bitmap, so this test could not be written at
    /// all. It fails loudly if the device context, the bitmap binding or the
    /// DPI plumbing is wrong, and it needs neither a GPU nor a desktop.
    #[test]
    fn paints_into_a_surface_the_caller_owns() {
        let (device, ctx) = warp_device();
        let tex = texture(&device, false);
        let surface: IDXGISurface = tex.cast().expect("surface");

        let target = SurfaceTarget::from_dxgi_surface(&surface).expect("surface target");
        let dc = target.context();

        unsafe {
            dc.BeginDraw();
            dc.Clear(Some(&windows::Win32::Graphics::Direct2D::Common::D2D1_COLOR_F {
                r: 0.0,
                g: 0.0,
                b: 0.0,
                a: 1.0,
            }));
            let brush = dc
                .CreateSolidColorBrush(
                    &windows::Win32::Graphics::Direct2D::Common::D2D1_COLOR_F {
                        r: 1.0,
                        g: 0.0,
                        b: 0.0,
                        a: 1.0,
                    },
                    None,
                )
                .expect("brush");
            dc.FillRectangle(
                &D2D_RECT_F {
                    left: 8.0,
                    top: 8.0,
                    right: 24.0,
                    bottom: 24.0,
                },
                &brush,
            );
            dc.EndDraw(None, None).expect("EndDraw");
        }

        let buf = read_back(&device, &ctx, &tex);

        // Inside the rect: opaque red. Outside: the black clear. Both are
        // asserted, because a target that silently drew nothing would leave the
        // whole surface at the clear colour and an inside-only check would pass
        // on a clear that happened to be red.
        assert_eq!(px(&buf, 16, 16), (255, 0, 0, 255), "inside the filled rect");
        assert_eq!(px(&buf, 48, 40), (0, 0, 0, 255), "outside the filled rect");
    }

    /// The DPI contract, asserted rather than assumed.
    ///
    /// At 96 DPI one DIP is one pixel, so a rect given in DIPs lands on exactly
    /// those pixel coordinates. If the context ever picked up the system DPI
    /// instead, this fails -- which is B1 divergence D4 caught at the boundary
    /// rather than in a glyph six months later.
    #[test]
    fn dips_are_pixels_because_the_target_pins_96_dpi() {
        let (device, ctx) = warp_device();
        let tex = texture(&device, false);
        let surface: IDXGISurface = tex.cast().expect("surface");
        let target = SurfaceTarget::from_dxgi_surface(&surface).expect("surface target");

        let (mut dx, mut dy) = (0.0f32, 0.0f32);
        unsafe { target.context().GetDpi(&mut dx, &mut dy) };
        assert_eq!((dx, dy), (PINNED_DPI, PINNED_DPI), "context DPI");

        unsafe {
            let dc = target.context();
            dc.BeginDraw();
            dc.Clear(Some(&windows::Win32::Graphics::Direct2D::Common::D2D1_COLOR_F {
                r: 0.0,
                g: 0.0,
                b: 0.0,
                a: 1.0,
            }));
            let brush = dc
                .CreateSolidColorBrush(
                    &windows::Win32::Graphics::Direct2D::Common::D2D1_COLOR_F {
                        r: 0.0,
                        g: 1.0,
                        b: 0.0,
                        a: 1.0,
                    },
                    None,
                )
                .expect("brush");
            // 10 DIPs wide starting at 10: at 96 DPI that is pixels 10..20.
            dc.FillRectangle(
                &D2D_RECT_F {
                    left: 10.0,
                    top: 10.0,
                    right: 20.0,
                    bottom: 20.0,
                },
                &brush,
            );
            dc.EndDraw(None, None).expect("EndDraw");
        }

        let buf = read_back(&device, &ctx, &tex);
        assert_eq!(px(&buf, 19, 19), (0, 255, 0, 255), "last pixel inside 10..20");
        assert_eq!(px(&buf, 20, 20), (0, 0, 0, 255), "first pixel outside 10..20");
    }

    /// The painter itself must work over this target with no changes.
    ///
    /// This is the claim the whole S-B plan rests on -- that the gap between
    /// headless B1 and a live swapchain is the DEVICE and nothing else. If
    /// `Direct2DPainter::new` ever stops accepting a device context, S-B's cost
    /// estimate changes completely, and it should change here, loudly.
    #[test]
    fn the_existing_painter_accepts_this_target_unchanged() {
        let (device, _ctx) = warp_device();
        let tex = texture(&device, false);
        let surface: IDXGISurface = tex.cast().expect("surface");
        let target = SurfaceTarget::from_dxgi_surface(&surface).expect("surface target");

        // The type-level assertion: this is exactly the call the WIC path makes.
        let _painter = crate::painter::direct2d::painter::Direct2DPainter::new(target.render_target());
    }
}
