//! Windows measurement binary: raw Win32 `WM_POINTER` input + a minimal wgpu
//! ink trail, feeding the cross-platform [`pen_spike`] latency ledger.
//!
//! Two modes:
//!   * `--list-pointers` — enumerate pointer devices (`GetPointerDevices`) and
//!     print type / max-contacts / tip-pressure range. The Wacom-passthrough
//!     truth-check for the Captain's later desk sitting. Sessionless-safe (a zero
//!     device count is a valid, reported outcome).
//!   * default — open a borderless window, `EnableMouseInPointer(TRUE)` so a mouse
//!     also drives the WM_POINTER path, timestamp every pointer event across the
//!     app-internal pipeline, `--seconds N` then auto-exit writing JSON + a table.
//!
//! WARP caveat: on the Parallels VM the only wgpu adapter is the software WARP
//! rasterizer (`DeviceType::Cpu`). The INPUT-side timing (hw -> receipt ->
//! encode) is honest there; the present-side timing is real but WARP-polluted
//! and is labeled as such in the report.

use std::num::NonZeroIsize;
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::{SystemTime, UNIX_EPOCH};

use clap::{Parser, ValueEnum};

use raw_window_handle::{
    RawDisplayHandle, RawWindowHandle, Win32WindowHandle, WindowsDisplayHandle,
};

use windows::core::w;
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Gdi::{ValidateRect, HBRUSH};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Performance::{QueryPerformanceCounter, QueryPerformanceFrequency};
use windows::Win32::UI::Input::Pointer::*;
use windows::Win32::UI::WindowsAndMessaging::*;
// windows-rs splits pointer-device enumeration oddly: the FUNCTIONS
// (GetPointerDevices / GetPointerDeviceProperties) live in UI::Input::Pointer
// (glob-imported above), but the STRUCTS and TYPE CONSTANTS live in UI::Controls.
use windows::Win32::UI::Controls::{
    POINTER_DEVICE_INFO, POINTER_DEVICE_PROPERTY, POINTER_DEVICE_TYPE,
    POINTER_DEVICE_TYPE_EXTERNAL_PEN, POINTER_DEVICE_TYPE_INTEGRATED_PEN,
    POINTER_DEVICE_TYPE_TOUCH, POINTER_DEVICE_TYPE_TOUCH_PAD,
};

use pen_spike::ledger::{EventRecord, LatencyLedger, PointerKind};
use pen_spike::qpc::QpcClock;
use pen_spike::report::{write_csv, RunMeta, RunReport};
use pen_spike::stats::Summary;

/// Max points retained in the drawn ink trail (visual only; irrelevant to timing).
const MAX_TRAIL: usize = 1024;

/// Trivial pass-through pipeline: clip-space position in, flat ink color out.
const WGSL: &str = r#"
@vertex
fn vs(@location(0) pos: vec2<f32>) -> @builtin(position) vec4<f32> {
    return vec4<f32>(pos, 0.0, 1.0);
}
@fragment
fn fs() -> @location(0) vec4<f32> {
    return vec4<f32>(0.85, 0.92, 1.0, 1.0);
}
"#;

#[derive(Clone, Copy, Debug, ValueEnum)]
enum Backend {
    /// DirectX 12 — on the Parallels VM this resolves to the WARP software adapter.
    Dx12,
    Vulkan,
    /// GL segfaults under Parallels; present only for parity, never pick it on the VM.
    Gl,
}

impl Backend {
    fn to_wgpu(self) -> wgpu::Backends {
        match self {
            Backend::Dx12 => wgpu::Backends::DX12,
            Backend::Vulkan => wgpu::Backends::VULKAN,
            Backend::Gl => wgpu::Backends::GL,
        }
    }
}

/// Pen-latency measurement plumbing (Windows). Backend is always explicit; there
/// is deliberately no "all backends" option (an all-backends probe attempts GL,
/// which segfaults under Parallels).
#[derive(Parser, Debug)]
#[command(about, long_about = None)]
struct Cli {
    /// Enumerate pointer devices and exit (the Wacom-passthrough truth-check).
    #[arg(long)]
    list_pointers: bool,

    /// GPU backend (explicit; never all). dx12 == WARP on the VM.
    #[arg(long, value_enum, default_value_t = Backend::Dx12)]
    backend: Backend,

    /// Measured seconds, then auto-exit.
    #[arg(long, default_value_t = 30.0)]
    seconds: f64,

    /// Latency-ledger ring capacity (records; oldest overwritten past this).
    #[arg(long, default_value_t = 65_536)]
    ring: usize,

    /// Initial window client width / height.
    #[arg(long, default_value_t = 1000)]
    width: u32,
    #[arg(long, default_value_t = 700)]
    height: u32,

    /// Output JSON path (summary + provenance).
    #[arg(long, default_value = "pen_spike_results.json")]
    out: PathBuf,

    /// Optional per-event CSV dump path.
    #[arg(long)]
    csv: Option<PathBuf>,
}

// ---------------------------------------------------------------------------
// QPC helpers
// ---------------------------------------------------------------------------

fn qpc_now() -> i64 {
    let mut v = 0i64;
    // QueryPerformanceCounter never fails on any supported OS; treat a failure
    // as a hard environment error.
    unsafe { QueryPerformanceCounter(&mut v).expect("QueryPerformanceCounter failed") };
    v
}

fn qpc_frequency() -> i64 {
    let mut v = 0i64;
    unsafe { QueryPerformanceFrequency(&mut v).expect("QueryPerformanceFrequency failed") };
    v
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn run() -> ExitCode {
    let cli = Cli::parse();
    let result = if cli.list_pointers {
        list_pointers()
    } else {
        measure(&cli)
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("pen_spike: {e}");
            ExitCode::from(1)
        }
    }
}

// ---------------------------------------------------------------------------
// --list-pointers
// ---------------------------------------------------------------------------

fn device_type_str(t: POINTER_DEVICE_TYPE) -> &'static str {
    // `POINTER_DEVICE_TYPE` is a newtype, not an enum; compare by value.
    if t == POINTER_DEVICE_TYPE_INTEGRATED_PEN {
        "integrated-pen"
    } else if t == POINTER_DEVICE_TYPE_EXTERNAL_PEN {
        "external-pen"
    } else if t == POINTER_DEVICE_TYPE_TOUCH {
        "touch"
    } else if t == POINTER_DEVICE_TYPE_TOUCH_PAD {
        "touch-pad"
    } else {
        "other"
    }
}

fn wide_to_string(w: &[u16]) -> String {
    let end = w.iter().position(|&c| c == 0).unwrap_or(w.len());
    String::from_utf16_lossy(&w[..end])
}

fn list_pointers() -> Result<(), String> {
    let freq = qpc_frequency();
    println!("QPC frequency: {freq} ticks/s");

    let mut count: u32 = 0;
    unsafe { GetPointerDevices(&mut count, None) }.map_err(|e| format!("GetPointerDevices count: {e}"))?;
    println!("pointer devices: {count}");
    if count == 0 {
        println!("(none — expected when sessionless, or no pen/touch attached.");
        println!(" attach the Wacom via the Parallels 'Devices > USB' menu, then re-run at the desk.)");
        return Ok(());
    }

    let mut devs: Vec<POINTER_DEVICE_INFO> =
        (0..count).map(|_| unsafe { core::mem::zeroed() }).collect();
    unsafe { GetPointerDevices(&mut count, Some(devs.as_mut_ptr())) }
        .map_err(|e| format!("GetPointerDevices fill: {e}"))?;

    for (i, d) in devs.iter().enumerate() {
        let ty = device_type_str(d.pointerDeviceType);
        let product = wide_to_string(&d.productString);
        let has_pen = d.pointerDeviceType == POINTER_DEVICE_TYPE_INTEGRATED_PEN
            || d.pointerDeviceType == POINTER_DEVICE_TYPE_EXTERNAL_PEN;
        println!(
            "[{i}] type={ty} pen={} maxContacts={} product=\"{product}\"",
            has_pen, d.maxActiveContacts
        );
        print_pressure(d.device);
    }
    Ok(())
}

/// Best-effort tip-pressure range via `GetPointerDeviceProperties` (HID usage
/// page 0x0D / usage 0x30 = Tip Pressure). Failures are noted, not fatal.
fn print_pressure(device: HANDLE) {
    let mut pc: u32 = 0;
    if unsafe { GetPointerDeviceProperties(device, &mut pc, None) }.is_err() || pc == 0 {
        println!("      (no device properties reported)");
        return;
    }
    let mut props: Vec<POINTER_DEVICE_PROPERTY> =
        (0..pc).map(|_| unsafe { core::mem::zeroed() }).collect();
    if unsafe { GetPointerDeviceProperties(device, &mut pc, Some(props.as_mut_ptr())) }.is_err() {
        println!("      (device properties unavailable)");
        return;
    }
    let mut printed = false;
    for p in &props {
        if p.usagePageId == 0x0D && p.usageId == 0x30 {
            println!(
                "      tip-pressure logical range: {}..{}",
                p.logicalMin, p.logicalMax
            );
            printed = true;
        }
    }
    if !printed {
        println!("      (no tip-pressure usage in {pc} reported properties)");
    }
}

// ---------------------------------------------------------------------------
// Measurement window + GPU
// ---------------------------------------------------------------------------

/// Minimal wgpu present path: clear + draw the ink trail as a line strip.
struct Gpu {
    surface: wgpu::Surface<'static>,
    device: wgpu::Device,
    queue: wgpu::Queue,
    config: wgpu::SurfaceConfiguration,
    pipeline: wgpu::RenderPipeline,
    vbuf: wgpu::Buffer,
}

/// GPU handle plus the provenance strings for the report header.
struct GpuInit {
    gpu: Gpu,
    adapter_name: String,
    adapter_type: String,
    present_mode: String,
    surface_format: String,
    backend: String,
}

impl Gpu {
    fn new(hwnd: HWND, hinstance: HINSTANCE, backend: wgpu::Backends, width: u32, height: u32) -> Result<GpuInit, String> {
        let mut idesc = wgpu::InstanceDescriptor::new_without_display_handle();
        idesc.backends = backend;
        let instance = wgpu::Instance::new(idesc);

        // Raw-handle surface (no winit): build the Win32 handle from the HWND.
        let mut wh = Win32WindowHandle::new(
            NonZeroIsize::new(hwnd.0 as isize).ok_or("null HWND")?,
        );
        wh.hinstance = NonZeroIsize::new(hinstance.0 as isize);
        let rwh = RawWindowHandle::Win32(wh);
        let rdh = RawDisplayHandle::Windows(WindowsDisplayHandle::new());
        let surface = unsafe {
            instance.create_surface_unsafe(wgpu::SurfaceTargetUnsafe::RawHandle {
                raw_display_handle: Some(rdh),
                raw_window_handle: rwh,
            })
        }
        .map_err(|e| format!("create_surface: {e}"))?;

        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::None,
            force_fallback_adapter: false,
            compatible_surface: Some(&surface),
            apply_limit_buckets: false,
        }))
        .map_err(|e| format!("request_adapter: {e}"))?;

        let info = adapter.get_info();

        let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
            label: Some("pen_spike device"),
            required_features: wgpu::Features::empty(),
            required_limits: wgpu::Limits::downlevel_defaults(),
            experimental_features: wgpu::ExperimentalFeatures::disabled(),
            memory_hints: wgpu::MemoryHints::default(),
            trace: wgpu::Trace::Off,
        }))
        .map_err(|e| format!("request_device: {e}"))?;

        let caps = surface.get_capabilities(&adapter);
        let format = caps.formats[0];
        // Prefer lowest-latency present modes; fall back to the guaranteed Fifo.
        let present_mode = [
            wgpu::PresentMode::Immediate,
            wgpu::PresentMode::Mailbox,
            wgpu::PresentMode::Fifo,
        ]
        .into_iter()
        .find(|m| caps.present_modes.contains(m))
        .unwrap_or(caps.present_modes[0]);

        let config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format,
            color_space: wgpu::SurfaceColorSpace::default(),
            width: width.max(1),
            height: height.max(1),
            present_mode,
            desired_maximum_frame_latency: 1,
            alpha_mode: caps.alpha_modes[0],
            view_formats: vec![],
        };
        surface.configure(&device, &config);

        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("ink shader"),
            source: wgpu::ShaderSource::Wgsl(WGSL.into()),
        });
        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("ink layout"),
            bind_group_layouts: &[],
            immediate_size: 0,
        });
        let vbl = wgpu::VertexBufferLayout {
            array_stride: 8,
            step_mode: wgpu::VertexStepMode::Vertex,
            attributes: &[wgpu::VertexAttribute {
                format: wgpu::VertexFormat::Float32x2,
                offset: 0,
                shader_location: 0,
            }],
        };
        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("ink pipeline"),
            layout: Some(&layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vs"),
                buffers: &[Some(vbl)],
                compilation_options: Default::default(),
            },
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::LineStrip,
                strip_index_format: None,
                front_face: wgpu::FrontFace::Ccw,
                cull_mode: None,
                unclipped_depth: false,
                polygon_mode: wgpu::PolygonMode::Fill,
                conservative: false,
            },
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fs"),
                targets: &[Some(wgpu::ColorTargetState {
                    format,
                    blend: None,
                    write_mask: wgpu::ColorWrites::ALL,
                })],
                compilation_options: Default::default(),
            }),
            multiview_mask: None,
            cache: None,
        });

        let vbuf = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("ink vbuf"),
            size: (MAX_TRAIL * 8) as u64,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        let adapter_type = match info.device_type {
            wgpu::DeviceType::Cpu => "Cpu (WARP software rasterizer)".to_string(),
            other => format!("{other:?}"),
        };

        Ok(GpuInit {
            gpu: Gpu {
                surface,
                device,
                queue,
                config,
                pipeline,
                vbuf,
            },
            adapter_name: info.name,
            adapter_type,
            present_mode: format!("{present_mode:?}"),
            surface_format: format!("{format:?}"),
            backend: format!("{:?}", info.backend),
        })
    }

    fn resize(&mut self, width: u32, height: u32) {
        if width == 0 || height == 0 {
            return;
        }
        self.config.width = width;
        self.config.height = height;
        self.surface.configure(&self.device, &self.config);
    }

    /// Render the current trail. Returns (encode_start_qpc, present_submitted_qpc).
    fn render(&mut self, trail: &[[f32; 2]]) -> (i64, i64) {
        use wgpu::CurrentSurfaceTexture as Cst;
        let encode_start = qpc_now();
        let frame = match self.surface.get_current_texture() {
            Cst::Success(f) | Cst::Suboptimal(f) => f,
            Cst::Outdated | Cst::Lost => {
                self.surface.configure(&self.device, &self.config);
                match self.surface.get_current_texture() {
                    Cst::Success(f) | Cst::Suboptimal(f) => f,
                    _ => return (encode_start, qpc_now()),
                }
            }
            // Timeout | Occluded | Validation: skip this event's frame.
            _ => return (encode_start, qpc_now()),
        };
        let view = frame.texture.create_view(&wgpu::TextureViewDescriptor::default());

        let n = trail.len().min(MAX_TRAIL);
        if n > 0 {
            let tail = &trail[trail.len() - n..];
            self.queue
                .write_buffer(&self.vbuf, 0, bytemuck::cast_slice(tail));
        }

        let mut enc = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("ink enc") });
        {
            let mut rp = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("ink pass"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color {
                            r: 0.05,
                            g: 0.06,
                            b: 0.08,
                            a: 1.0,
                        }),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });
            if n >= 2 {
                rp.set_pipeline(&self.pipeline);
                rp.set_vertex_buffer(0, self.vbuf.slice(..(n as u64 * 8)));
                rp.draw(0..n as u32, 0..1);
            }
        }
        self.queue.submit(std::iter::once(enc.finish()));
        self.queue.present(frame);
        (encode_start, qpc_now())
    }
}

/// The state threaded through the window procedure via GWLP_USERDATA.
struct AppState {
    gpu: Gpu,
    ledger: LatencyLedger,
    trail: Vec<[f32; 2]>,
    seq: u64,
    deadline_qpc: i64,
}

impl AppState {
    fn push_point(&mut self, x: f32, y: f32) {
        self.trail.push([x, y]);
        if self.trail.len() > MAX_TRAIL {
            let overflow = self.trail.len() - MAX_TRAIL;
            self.trail.drain(0..overflow);
        }
    }
}

fn kind_of(msg: u32) -> Option<PointerKind> {
    match msg {
        WM_POINTERDOWN => Some(PointerKind::Down),
        WM_POINTERUPDATE => Some(PointerKind::Update),
        WM_POINTERUP => Some(PointerKind::Up),
        _ => None,
    }
}

/// Handle one WM_POINTER* message: stamp receipt, read the hardware timestamp,
/// extend the ink trail, render, and record the event.
unsafe fn handle_pointer(app: &mut AppState, hwnd: HWND, msg: u32, wparam: WPARAM) {
    let receipt = qpc_now();
    let kind = match kind_of(msg) {
        Some(k) => k,
        None => return,
    };
    let pointer_id = (wparam.0 & 0xFFFF) as u32;

    let mut info: POINTER_INFO = core::mem::zeroed();
    let got = GetPointerInfo(pointer_id, &mut info).is_ok();

    let hw_timestamp = if got && info.PerformanceCount != 0 {
        Some(info.PerformanceCount as i64)
    } else {
        None
    };

    if got {
        // Screen -> client-relative clip space via the window rect (borderless
        // popup: window rect == client). Exact placement is visually irrelevant.
        let mut wr = RECT::default();
        let _ = GetWindowRect(hwnd, &mut wr);
        let w = (wr.right - wr.left).max(1) as f32;
        let h = (wr.bottom - wr.top).max(1) as f32;
        let cx = (info.ptPixelLocation.x - wr.left) as f32;
        let cy = (info.ptPixelLocation.y - wr.top) as f32;
        app.push_point((cx / w) * 2.0 - 1.0, 1.0 - (cy / h) * 2.0);
    }

    let (encode_start, present_submitted) = app.gpu.render(&app.trail);

    let seq = app.seq;
    app.seq += 1;
    app.ledger.record(EventRecord {
        seq,
        kind,
        hw_timestamp,
        handler_receipt_qpc: receipt,
        encode_start_qpc: Some(encode_start),
        present_submitted_qpc: Some(present_submitted),
    });
}

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    let ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut AppState;
    if ptr.is_null() {
        return DefWindowProcW(hwnd, msg, wparam, lparam);
    }
    let app = &mut *ptr;

    match msg {
        WM_POINTERDOWN | WM_POINTERUPDATE | WM_POINTERUP => {
            handle_pointer(app, hwnd, msg, wparam);
            LRESULT(0)
        }
        WM_TIMER => {
            if qpc_now() >= app.deadline_qpc {
                let _ = DestroyWindow(hwnd);
            }
            LRESULT(0)
        }
        WM_SIZE => {
            let w = (lparam.0 & 0xFFFF) as u32;
            let h = ((lparam.0 >> 16) & 0xFFFF) as u32;
            app.gpu.resize(w, h);
            LRESULT(0)
        }
        WM_PAINT => {
            // We present from pointer events, not WM_PAINT; just validate to stop
            // the repaint storm.
            let _ = ValidateRect(Some(hwnd), None);
            LRESULT(0)
        }
        WM_DESTROY => {
            PostQuitMessage(0);
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn measure(cli: &Cli) -> Result<(), String> {
    let freq = qpc_frequency();
    let clock = QpcClock::from_frequency(freq);

    // Route mouse through the WM_POINTER path so a mouse exercises the pen
    // pipeline when no pen is present.
    let mouse_in_pointer = unsafe { EnableMouseInPointer(true) }.is_ok();

    let hinstance: HINSTANCE = unsafe { GetModuleHandleW(None) }
        .map_err(|e| format!("GetModuleHandleW: {e}"))?
        .into();

    let class_name = w!("pen_spike_window");
    let wc = WNDCLASSW {
        style: CS_HREDRAW | CS_VREDRAW,
        lpfnWndProc: Some(wndproc),
        hInstance: hinstance,
        hCursor: unsafe { LoadCursorW(None, IDC_ARROW) }.map_err(|e| format!("LoadCursorW: {e}"))?,
        hbrBackground: HBRUSH::default(),
        lpszClassName: class_name,
        ..Default::default()
    };
    if unsafe { RegisterClassW(&wc) } == 0 {
        return Err(format!("RegisterClassW failed: {:?}", unsafe { GetLastError() }));
    }

    let hwnd = unsafe {
        CreateWindowExW(
            WINDOW_EX_STYLE(0),
            class_name,
            w!("pen_spike"),
            WS_POPUP | WS_VISIBLE,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            cli.width as i32,
            cli.height as i32,
            None,
            None,
            Some(hinstance),
            None,
        )
    }
    .map_err(|e| format!("CreateWindowExW: {e}"))?;

    let init = Gpu::new(hwnd, hinstance, cli.backend.to_wgpu(), cli.width, cli.height)?;

    let deadline_qpc = qpc_now() + (cli.seconds * freq as f64) as i64;
    let mut app = Box::new(AppState {
        gpu: init.gpu,
        ledger: LatencyLedger::new(cli.ring.max(1)),
        trail: Vec::with_capacity(MAX_TRAIL),
        seq: 0,
        deadline_qpc,
    });

    unsafe {
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, &mut *app as *mut AppState as isize);
        let _ = ShowWindow(hwnd, SW_SHOW);
        // Wake ~10x/second so the deadline is honored even with no input.
        SetTimer(Some(hwnd), 1, 100, None);
    }

    println!(
        "pen_spike: measuring {:.1}s on {} / {} ({}), present={}. Doodle in the window...",
        cli.seconds, init.backend, init.adapter_name, init.adapter_type, init.present_mode
    );

    // Standard blocking message loop; WM_TIMER drives the deadline, WM_DESTROY
    // (from the deadline) posts WM_QUIT which ends the loop.
    let mut m = MSG::default();
    loop {
        let r = unsafe { GetMessageW(&mut m, None, 0, 0) };
        if r.0 <= 0 {
            break; // 0 == WM_QUIT, -1 == error
        }
        unsafe {
            let _ = TranslateMessage(&m);
            DispatchMessageW(&m);
        }
    }

    let present_timing_note = if init.adapter_type.starts_with("Cpu") {
        "present-side stages (encode_to_present, *_to_present) are REAL but \
         WARP-software-polluted; the input-side stages (hw_to_receipt, \
         receipt_to_encode) are the honest signal on this backend"
            .to_string()
    } else {
        "present-side stages measured on a hardware adapter".to_string()
    };

    let summary = Summary::from_ledger(&app.ledger, &clock);
    let meta = RunMeta {
        os: format!("windows {}", std::env::consts::ARCH),
        backend: init.backend,
        adapter_name: init.adapter_name,
        adapter_type: init.adapter_type,
        present_mode: init.present_mode,
        surface_format: init.surface_format,
        qpc_frequency: freq,
        mouse_in_pointer,
        requested_seconds: cli.seconds,
        ring_capacity: app.ledger.capacity(),
        generated_unix: unix_now(),
        present_timing_note,
        scope_note: "app-internal latency only (hw timestamp -> present submit); \
                     a LOWER BOUND on motion-to-photon, which needs real iron + a \
                     high-speed camera to measure"
            .to_string(),
    };

    summary.print_table();

    let report = RunReport::new(meta, summary);
    let mut buf = Vec::new();
    report
        .write_json(&mut buf)
        .map_err(|e| format!("serialize JSON: {e}"))?;
    std::fs::write(&cli.out, &buf).map_err(|e| format!("write {}: {e}", cli.out.display()))?;
    println!("\nwrote {}", cli.out.display());

    if let Some(csv_path) = &cli.csv {
        let mut f =
            std::fs::File::create(csv_path).map_err(|e| format!("create {}: {e}", csv_path.display()))?;
        write_csv(&mut f, &app.ledger, &clock).map_err(|e| format!("write CSV: {e}"))?;
        println!("wrote {}", csv_path.display());
    }

    Ok(())
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}
