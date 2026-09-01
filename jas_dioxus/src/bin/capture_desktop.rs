//! Capture the composed desktop through DXGI Desktop Duplication, and say so.
//!
//! ⛔ WHY A SECOND CAPTURE TOOL EXISTS. `capture_desktop.ps1` copies the screen
//! with GDI (`Graphics.CopyFromScreen`). GDI reads the desktop's GDI surface,
//! and **a hardware-composed swapchain is not on it** — the compositor takes
//! that content directly. So a window whose pixels come from a `SwapChainPanel`
//! can be fully painted and still be captured as a hole.
//!
//! That is not a hypothesis. `verify_window.ps1`'s colour arm reports
//! INCONCLUSIVE on this box with the honest wording *"either the core did not
//! paint, OR a GDI screen copy cannot see hardware-composed swapchain
//! content — this arm cannot tell those apart"*. Measured 2026-09-01 on the
//! goldens run: the window title reported `GOLDENS 18/20 painted` while the GDI
//! capture found **zero** pixels of the colour those goldens paint.
//!
//! ⇒ **The ambiguity is a property of the INSTRUMENT, not of the app.** Desktop
//! Duplication reads the composed output — what the user actually sees,
//! overlays and swapchains included — so it can decide what GDI could only
//! shrug at.
//!
//! ⛔ IT MUST RUN IN THE INTERACTIVE SESSION. Session 0 has its own bare window
//! station; duplicating *its* output yields a black frame that looks exactly
//! like a broken app. `DXGI_ERROR_SESSION_DISCONNECTED` / `ACCESS_DENIED` here
//! usually means "you launched me from the agent shell", so that is REPORTED BY
//! NAME rather than left to look like a rendering failure.
//!
//! Usage: `capture_desktop <out.png>` — exit 0 on a written PNG, 1 with a
//! reason on stderr otherwise.

#[cfg(all(feature = "d2d", windows))]
fn main() -> std::process::ExitCode {
    match imp::run() {
        Ok(note) => {
            println!("{note}");
            std::process::ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("capture_desktop: {e}");
            std::process::ExitCode::FAILURE
        }
    }
}

#[cfg(not(all(feature = "d2d", windows)))]
fn main() -> std::process::ExitCode {
    // A tool that silently does nothing on the wrong target is worse than one
    // that is absent: the caller gets an exit code and no pixels.
    eprintln!(
        "capture_desktop: built without `d2d` on a non-Windows target; \
         nothing to duplicate"
    );
    std::process::ExitCode::FAILURE
}

#[cfg(all(feature = "d2d", windows))]
mod imp {
    use windows::core::{Interface, Result as WResult, GUID, PCWSTR};
    use windows::Win32::Foundation::{E_FAIL, HMODULE};
    use windows::Win32::Graphics::Direct3D::D3D_DRIVER_TYPE_HARDWARE;
    use windows::Win32::Graphics::Direct3D11::{
        D3D11CreateDevice, ID3D11Device, ID3D11DeviceContext, ID3D11Texture2D,
        D3D11_CPU_ACCESS_READ, D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_MAPPED_SUBRESOURCE,
        D3D11_MAP_READ, D3D11_SDK_VERSION, D3D11_TEXTURE2D_DESC, D3D11_USAGE_STAGING,
    };
    use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SAMPLE_DESC};
    use windows::Win32::Graphics::Dxgi::{
        IDXGIDevice, IDXGIOutput1, IDXGIOutputDuplication, IDXGIResource,
        DXGI_ERROR_WAIT_TIMEOUT, DXGI_OUTDUPL_FRAME_INFO,
    };
    use windows::Win32::Graphics::Imaging::{
        CLSID_WICImagingFactory, GUID_ContainerFormatPng, GUID_WICPixelFormat32bppBGRA,
        IWICImagingFactory, WICBitmapEncoderNoCache,
    };
    use windows::Win32::Foundation::GENERIC_WRITE;
    use windows::Win32::System::Com::{
        CoCreateInstance, CoInitializeEx, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED,
    };

    /// How many acquisitions to allow before believing a frame.
    ///
    /// ⛔ THE FIRST ACQUIRED FRAME IS NOT A PICTURE OF ANYTHING. Desktop
    /// Duplication hands back an *accumulated* frame whose `LastPresentTime` is
    /// zero when nothing has presented since duplication began — the desktop has
    /// not changed, so there is nothing new to give, and the texture contents
    /// are undefined rather than "the current screen". Saving that is how a
    /// capture tool writes a black PNG of a perfectly good desktop and gets the
    /// app blamed for it. So: keep acquiring until a frame carries a real
    /// present time.
    const SETTLE_TRIES: u32 = 60;

    pub fn run() -> Result<String, String> {
        let args: Vec<String> = std::env::args().skip(1).collect();

        // ⛔ FIRST, AND BEFORE THE SELFTEST BRANCH. It used to sit below, so
        // `--selftest` reached the WIC encoder on an uninitialised apartment and
        // died with "CoInitialize has not been called" -- a control that fails
        // for a reason the real path cannot have is worse than no control, and
        // this one caught itself on its first run.
        // `S_FALSE` ("already initialised on this thread") is success here.
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        }

        // ⭐ A POSITIVE CONTROL FOR THE HALF THAT CANNOT BE DRIVEN FROM HERE.
        // Duplication needs the interactive session, so a failure anywhere in
        // this tool arrives from a scheduled task as one line of text -- and the
        // first real failure was in the PNG WRITER, which has nothing to do with
        // duplication and can be driven from anywhere. `--selftest` runs the
        // encoder over a synthetic image, so "can this box write the PNG" is
        // separable from "can this process see the desktop" instead of the two
        // failing as one opaque HRESULT.
        if args.first().map(String::as_str) == Some("--selftest") {
            let out = args.get(1).cloned().unwrap_or_else(|| "selftest.png".into());
            let (w, h) = (64u32, 48u32);
            let stride = w * 4;
            let mut px = vec![0u8; (stride * h) as usize];
            for y in 0..h as usize {
                for x in 0..w as usize {
                    let i = y * stride as usize + x * 4;
                    px[i] = 204; // B
                    px[i + 1] = 102; // G
                    px[i + 2] = 51; // R
                    px[i + 3] = 255; // A
                }
            }
            write_png(&out, w, h, &px, stride).map_err(|e| format!("selftest write: {e}"))?;
            return Ok(format!("capture_desktop: selftest wrote {out} ({w}x{h})"));
        }

        let out = args
            .into_iter()
            .next()
            .ok_or_else(|| "usage: capture_desktop <out.png> | --selftest [out.png]".to_string())?;

        let (dev, ctx) = device().map_err(|e| format!("D3D11CreateDevice: {e}"))?;
        let dupl = duplication(&dev).map_err(|e| {
            format!(
                "DuplicateOutput: {e}\n\
                 => If this is ACCESS_DENIED or SESSION_DISCONNECTED, this process is \
                 almost certainly running in SESSION 0 (the agent shell). Desktop \
                 Duplication must run where the pixels are -- launch it through an \
                 INTERACTIVE scheduled task, as verify_window.ps1 does."
            )
        })?;

        let (tex, w, h, frames) = settle(&dupl).map_err(|e| format!("AcquireNextFrame: {e}"))?;
        let (pixels, stride) =
            read_back(&dev, &ctx, &tex, w, h).map_err(|e| format!("read back: {e}"))?;
        write_png(&out, w, h, &pixels, stride).map_err(|e| format!("write {out}: {e}"))?;

        Ok(format!(
            "capture_desktop: wrote {out} -- {w}x{h}, settled after {frames} acquisition(s), \
             DXGI Desktop Duplication (sees hardware-composed swapchains)"
        ))
    }

    fn device() -> WResult<(ID3D11Device, ID3D11DeviceContext)> {
        let mut d = None;
        let mut c = None;
        unsafe {
            D3D11CreateDevice(
                None,
                // HARDWARE, not WARP: duplication must come from the adapter
                // actually driving the output. A WARP device has no output.
                D3D_DRIVER_TYPE_HARDWARE,
                HMODULE::default(),
                D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                None,
                D3D11_SDK_VERSION,
                Some(&mut d),
                None,
                Some(&mut c),
            )?;
        }
        Ok((d.unwrap(), c.unwrap()))
    }

    fn duplication(dev: &ID3D11Device) -> WResult<IDXGIOutputDuplication> {
        unsafe {
            let dxgi: IDXGIDevice = dev.cast()?;
            let adapter = dxgi.GetAdapter()?;
            // Output 0. A multi-monitor box would want the one holding the
            // window; this harness pins the app to the primary, and capturing
            // the wrong output is visible as an obviously-wrong image rather
            // than as a subtly wrong verdict.
            let output = adapter.EnumOutputs(0)?;
            let output1: IDXGIOutput1 = output.cast()?;
            output1.DuplicateOutput(dev)
        }
    }

    /// Acquire until a frame carries a real present time. See [`SETTLE_TRIES`].
    fn settle(dupl: &IDXGIOutputDuplication) -> WResult<(ID3D11Texture2D, u32, u32, u32)> {
        unsafe {
            for i in 1..=SETTLE_TRIES {
                let mut info = DXGI_OUTDUPL_FRAME_INFO::default();
                let mut res: Option<IDXGIResource> = None;
                // 200ms: long enough that a quiet desktop still yields, short
                // enough that SETTLE_TRIES cannot hang the harness.
                if let Err(e) = dupl.AcquireNextFrame(200, &mut info, &mut res) {
                    // A timeout means "the desktop did not change", which is not
                    // an error -- keep waiting for a real present.
                    if e.code() == DXGI_ERROR_WAIT_TIMEOUT {
                        continue;
                    }
                    return Err(e);
                }
                let tex: ID3D11Texture2D = res.as_ref().unwrap().cast()?;
                if info.LastPresentTime != 0 {
                    let mut desc = D3D11_TEXTURE2D_DESC::default();
                    tex.GetDesc(&mut desc);
                    // The frame stays ACQUIRED through the copy: releasing it
                    // first invalidates the texture we are about to read.
                    return Ok((tex, desc.Width, desc.Height, i));
                }
                dupl.ReleaseFrame()?;
            }
            Err(windows::core::Error::new(
                E_FAIL,
                "no frame with a real present time after settling -- nothing \
                 presented, which on a live desktop means this is not the \
                 interactive session",
            ))
        }
    }

    fn read_back(
        dev: &ID3D11Device,
        ctx: &ID3D11DeviceContext,
        src: &ID3D11Texture2D,
        w: u32,
        h: u32,
    ) -> WResult<(Vec<u8>, u32)> {
        let desc = D3D11_TEXTURE2D_DESC {
            Width: w,
            Height: h,
            MipLevels: 1,
            ArraySize: 1,
            Format: DXGI_FORMAT_B8G8R8A8_UNORM,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            Usage: D3D11_USAGE_STAGING,
            BindFlags: 0,
            CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
            MiscFlags: 0,
        };
        let mut staging = None;
        unsafe { dev.CreateTexture2D(&desc, None, Some(&mut staging))? };
        let staging = staging.unwrap();

        let stride = w * 4;
        let mut out = vec![0u8; (stride * h) as usize];
        unsafe {
            ctx.CopyResource(&staging, src);
            let mut m = D3D11_MAPPED_SUBRESOURCE::default();
            ctx.Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut m))?;
            // ⛔ ROW PITCH IS NOT WIDTH*4. A mapped staging texture is padded to
            // the driver's alignment; copying the whole block in one memcpy
            // shears the image progressively down the frame -- which reads as a
            // rendering bug in whatever was captured.
            for y in 0..h as usize {
                std::ptr::copy_nonoverlapping(
                    (m.pData as *const u8).add(y * m.RowPitch as usize),
                    out.as_mut_ptr().add(y * stride as usize),
                    stride as usize,
                );
            }
            ctx.Unmap(&staging, 0);
        }
        Ok((out, stride))
    }

    fn write_png(path: &str, w: u32, h: u32, pixels: &[u8], stride: u32) -> WResult<()> {
        unsafe {
            let factory: IWICImagingFactory =
                CoCreateInstance(&CLSID_WICImagingFactory, None, CLSCTX_INPROC_SERVER)?;
            let encoder = factory.CreateEncoder(&GUID_ContainerFormatPng, std::ptr::null())?;
            let stream = factory.CreateStream()?;
            let wide: Vec<u16> = path.encode_utf16().chain(std::iter::once(0)).collect();
            // ⛔ GENERIC_WRITE, NOT STGM FLAGS. `dwDesiredAccess` here is a
            // Win32 access mask, not the STGM bag the name "stream" suggests;
            // passing `STGM_WRITE | STGM_CREATE` (0x1001) is accepted by the
            // type system and fails at runtime as
            // WINCODEC_ERR_INTERNALERROR (0x88982F48) -- a generic code that
            // says nothing about which argument was wrong. The `--selftest`
            // control is what localised it to this call in one run.
            stream.InitializeFromFilename(PCWSTR(wide.as_ptr()), GENERIC_WRITE.0)?;
            encoder.Initialize(&stream, WICBitmapEncoderNoCache)?;

            let mut frame = None;
            encoder.CreateNewFrame(&mut frame, &mut None)?;
            let frame = frame.unwrap();
            frame.Initialize(None)?;
            frame.SetSize(w, h)?;
            // Requested, then CHECKED. WIC may negotiate a different format, and
            // writing BGRA bytes into a frame that agreed to something else is
            // how a capture comes out channel-swapped -- which would make every
            // colour assertion downstream wrong in a way that still looks like
            // a picture.
            let mut fmt: GUID = GUID_WICPixelFormat32bppBGRA;
            frame.SetPixelFormat(&mut fmt)?;
            if fmt != GUID_WICPixelFormat32bppBGRA {
                return Err(windows::core::Error::new(
                    E_FAIL,
                    "WIC would not accept 32bppBGRA; refusing rather than writing \
                     channel-swapped pixels",
                ));
            }
            frame.WritePixels(h, stride, pixels)?;
            frame.Commit()?;
            encoder.Commit()?;
        }
        Ok(())
    }
}
