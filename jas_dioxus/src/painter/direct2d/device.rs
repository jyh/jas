//! A headless Direct2D render target — no HWND, no swapchain, no desktop.
//!
//! This is what makes B1 runnable in CI and on a box with no display, and it is
//! why B1 could start before the interactive-session question was settled at
//! all. B1's capability study compared two routes and chose this one:
//!
//!   (a) `ID2D1Factory::CreateWicBitmapRenderTarget` over an `IWICBitmap` —
//!       needs zero D3D, and still upgrades to a full `ID2D1DeviceContext`
//!       (effects included) via QueryInterface. **Not thrown away for S-B2.**
//!   (b) `D3D11CreateDevice` + `ID2D1Factory1::CreateDevice` + a
//!       `D2D1_BITMAP_OPTIONS_TARGET` bitmap + a staging bitmap for readback.
//!
//! DPI IS PINNED TO 96 DELIBERATELY (B1 divergence D4). `DWRITE_GLYPH_RUN`
//! coordinates are DIPs and `fontEmSize` is "logical size in DIPs (1/96 inch),
//! not points", while `TextRun.size` and `PlacedGlyph.x/y` are CSS px. 1 DIP
//! equals 1 CSS px ONLY at 96 DPI. Leave the target's DPI to the system and on a
//! 120/144-DPI display every glyph silently rescales relative to the paths drawn
//! by the other thirteen methods.
//!
//! PIXEL FORMAT IS `_UNORM`, NOT `_UNORM_SRGB` (B1 divergence D5): the browser
//! blends in gamma-encoded sRGB and D2D reads `_UNORM` values verbatim, so this
//! is the format that matches. `_UNORM_SRGB` would linearise and diverge.

use windows::core::Result;
use windows::Win32::Graphics::Direct2D::Common::{
    D2D1_ALPHA_MODE_PREMULTIPLIED, D2D1_PIXEL_FORMAT,
};
use windows::Win32::Graphics::Direct2D::{
    D2D1CreateFactory, ID2D1Factory, ID2D1RenderTarget, D2D1_FACTORY_TYPE_SINGLE_THREADED,
    D2D1_RENDER_TARGET_PROPERTIES, D2D1_RENDER_TARGET_TYPE_DEFAULT, D2D1_RENDER_TARGET_USAGE_NONE,
    D2D1_FEATURE_LEVEL_DEFAULT,
};
use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_B8G8R8A8_UNORM;
use windows::Win32::Graphics::Imaging::{
    CLSID_WICImagingFactory, GUID_WICPixelFormat32bppPBGRA, IWICBitmap, IWICImagingFactory,
    WICBitmapCacheOnLoad, WICBitmapLockRead,
};
use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_INPROC_SERVER,
    COINIT_APARTMENTTHREADED};

/// The DPI every headless target is pinned to. See the module note: DIPs are
/// CSS pixels only here.
pub const PINNED_DPI: f32 = 96.0;

/// One headless surface: a WIC bitmap plus the D2D render target drawing into it.
pub struct HeadlessTarget {
    _size: (u32, u32),
    bitmap: IWICBitmap,
    target: ID2D1RenderTarget,
    // Keep the factories alive for the lifetime of the target.
    _d2d: ID2D1Factory,
    _wic: IWICImagingFactory,
}

impl HeadlessTarget {
    /// Create a `width` x `height` BGRA surface with DPI pinned to 96.
    pub fn new(width: u32, height: u32) -> Result<Self> {
        unsafe {
            // Apartment-threaded: WIC is fine either way, and a spike has no
            // reason to ask for MTA. Ignore the "already initialised" HRESULT --
            // a test binary may init COM more than once per process.
            let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);

            let wic: IWICImagingFactory =
                CoCreateInstance(&CLSID_WICImagingFactory, None, CLSCTX_INPROC_SERVER)?;
            // PBGRA = premultiplied BGRA, which is what D2D wants and what the
            // readback contract in this module documents.
            let bitmap: IWICBitmap = wic.CreateBitmap(
                width,
                height,
                &GUID_WICPixelFormat32bppPBGRA,
                WICBitmapCacheOnLoad,
            )?;

            let d2d: ID2D1Factory =
                D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, None)?;

            let props = D2D1_RENDER_TARGET_PROPERTIES {
                r#type: D2D1_RENDER_TARGET_TYPE_DEFAULT,
                pixelFormat: D2D1_PIXEL_FORMAT {
                    // _UNORM, not _UNORM_SRGB -- see the module note (D5).
                    format: DXGI_FORMAT_B8G8R8A8_UNORM,
                    alphaMode: D2D1_ALPHA_MODE_PREMULTIPLIED,
                },
                dpiX: PINNED_DPI,
                dpiY: PINNED_DPI,
                usage: D2D1_RENDER_TARGET_USAGE_NONE,
                minLevel: D2D1_FEATURE_LEVEL_DEFAULT,
            };
            let target = d2d.CreateWicBitmapRenderTarget(&bitmap, &props)?;

            Ok(Self { _size: (width, height), bitmap, target, _d2d: d2d, _wic: wic })
        }
    }

    /// The D2D render target. `BeginDraw`/`EndDraw` are the caller's.
    pub fn target(&self) -> &ID2D1RenderTarget {
        &self.target
    }

    /// Copy the surface out as premultiplied BGRA, 4 bytes per pixel, row-major.
    pub fn read_bgra(&self) -> Result<Vec<u8>> {
        let (w, h) = self._size;
        unsafe {
            let lock = self.bitmap.Lock(std::ptr::null(), WICBitmapLockRead.0 as u32)?;
            let stride = lock.GetStride()?;
            let mut size = 0u32;
            let mut data = std::ptr::null_mut();
            lock.GetDataPointer(&mut size, &mut data)?;
            let src = std::slice::from_raw_parts(data as *const u8, size as usize);
            // WIC rows are stride-padded; hand back a tight w*4 buffer so the
            // caller never has to know the stride.
            let row = (w as usize) * 4;
            let mut out = Vec::with_capacity(row * h as usize);
            for y in 0..h as usize {
                let start = y * stride as usize;
                out.extend_from_slice(&src[start..start + row]);
            }
            Ok(out)
        }
    }

    pub fn size(&self) -> (u32, u32) {
        self._size
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use windows::Win32::Graphics::Direct2D::Common::D2D1_COLOR_F;
    use windows::Win32::Graphics::Direct2D::D2D1_DRAW_TEXT_OPTIONS_NONE;

    /// THE HEADLESS GATE. If this cannot pass there is no B1 at all — every
    /// other Direct2D test in this crate depends on getting a target with no
    /// window, and the whole reason B1 precedes S-B2 is that it needs no desktop.
    #[test]
    fn a_target_exists_with_no_window() {
        let t = HeadlessTarget::new(16, 16).expect("headless target");
        assert_eq!(t.size(), (16, 16));
    }

    /// Readback must be the right shape before any pixel assertion means
    /// anything: 4 bytes per pixel, width*height pixels.
    #[test]
    fn readback_is_bgra_four_bytes_per_pixel() {
        let t = HeadlessTarget::new(8, 4).expect("headless target");
        let px = t.read_bgra().expect("readback");
        assert_eq!(px.len(), 8 * 4 * 4);
    }

    /// A cleared surface is uniformly that colour. This proves the target is
    /// really wired to the bitmap we read back — a target that draws into the
    /// void would leave the buffer at its initial value and this would pass by
    /// accident, so the clear colour is deliberately NOT zero.
    #[test]
    fn clearing_reaches_the_readback_buffer() {
        let t = HeadlessTarget::new(4, 4).expect("headless target");
        unsafe {
            let rt = t.target();
            rt.BeginDraw();
            // opaque mid-blue, premultiplied-safe at alpha 1
            rt.Clear(Some(&D2D1_COLOR_F { r: 0.0, g: 0.0, b: 1.0, a: 1.0 }));
            rt.EndDraw(None, None).expect("EndDraw");
        }
        let px = t.read_bgra().expect("readback");
        // BGRA: blue is byte 0, alpha byte 3.
        assert_eq!(&px[0..4], &[255u8, 0, 0, 255], "first pixel should be opaque blue");
        assert!(px.chunks(4).all(|p| p == [255u8, 0, 0, 255]), "every pixel");
    }

    /// The DPI pin (B1 divergence D4). If this ever reads anything but 96, text
    /// silently rescales relative to every path the other thirteen methods draw.
    #[test]
    fn dpi_is_pinned_to_96_so_one_dip_is_one_css_pixel() {
        let t = HeadlessTarget::new(4, 4).expect("headless target");
        let mut dx = 0.0f32;
        let mut dy = 0.0f32;
        unsafe { t.target().GetDpi(&mut dx, &mut dy) };
        assert_eq!((dx, dy), (96.0, 96.0), "DPI must be pinned; DIPs are CSS px only at 96");
        let _ = D2D1_DRAW_TEXT_OPTIONS_NONE; // keep the text import honest
    }
}
