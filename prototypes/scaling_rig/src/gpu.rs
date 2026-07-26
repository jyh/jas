//! wgpu + Vello render paths and the timed sweep drivers.
//!
//! Architecture (shared by both modes):
//!   * Scene GEOMETRY is encoded ONCE per sweep point into a retained `vello::Scene`.
//!   * Each frame a reused outer `Scene` is `reset()` + `append(&inner, camera)` — this
//!     re-encodes the command stream under the animated camera affine (cheap relative
//!     to re-tessellating geometry), mirroring how a real editor retains a document and
//!     only re-applies the viewport transform per frame.
//!
//! DEVICE LIMITS: we do NOT use Vello's `util::RenderContext`, because it requests
//! `Limits::default()` whose `max_storage_buffer_binding_size` is 128 MiB — Vello's
//! single scene-encoding buffer blows past that around ~250k-500k jas-shaped elements
//! (a hard `Validation Error`, not a slowdown). We instead create the device with the
//! adapter's real limits, unlocking the M-series' much larger storage-buffer cap. This
//! is a load-bearing finding: the retained single-`Scene` design is gated by device
//! limits long before it is gated by frame time.
//!
//! OFFSCREEN renders to an owned Rgba8Unorm storage texture and blocks on the GPU
//! (`poll(Wait)`) each frame — a fully serialized CPU+GPU time; the VM/CI mode.
//!
//! WINDOWED renders to Vello's intermediate texture then blits to the surface (Vello
//! is compute-based and has no `render_to_surface`). Present mode is `AutoNoVsync` so
//! the measured inter-frame interval reflects true throughput, not the display cap.
//! This is the measured mode on Mac Metal.

use std::sync::Arc;
use std::time::Instant;

use vello::peniko::Color;
use vello::wgpu;
use vello::{AaConfig, AaSupport, RenderParams, Renderer, RendererOptions, Scene};
use wgpu::util::TextureBlitter;
use winit::application::ApplicationHandler;
use winit::dpi::LogicalSize;
use winit::event::WindowEvent;
use winit::event_loop::{ActiveEventLoop, EventLoop};
use winit::keyboard::{Key, NamedKey};
use winit::window::{Window, WindowId};

use crate::camera::camera;
use crate::metrics::{PointAccum, PointResult};
use crate::scene::build_scene;

pub const AA: AaConfig = AaConfig::Area;

#[derive(Clone)]
pub struct SweepConfig {
    pub points: Vec<usize>,
    pub width: u32,
    pub height: u32,
    pub seed: u64,
    pub warmup: f64,
    pub measure: f64,
}

fn renderer_options() -> RendererOptions {
    RendererOptions {
        use_cpu: false,
        antialiasing_support: AaSupport::area_only(),
        // macOS: a single init thread is the linebender-recommended setting.
        num_init_threads: std::num::NonZeroUsize::new(1),
        pipeline_cache: None,
    }
}

fn render_params(w: u32, h: u32) -> RenderParams {
    RenderParams {
        base_color: Color::WHITE,
        width: w,
        height: h,
        antialiasing_method: AA,
    }
}

// ---------------------------------------------------------------------------
// Device / instance construction (with raised limits)
// ---------------------------------------------------------------------------

fn make_instance() -> wgpu::Instance {
    // `WGPU_BACKEND` is always set by main() — explicit backend only, never a probe.
    let backends = wgpu::Backends::from_env().unwrap_or_default();
    wgpu::Instance::new(wgpu::InstanceDescriptor {
        display: None,
        backends,
        flags: wgpu::InstanceFlags::from_build_config().with_env(),
        memory_budget_thresholds: wgpu::MemoryBudgetThresholds::default(),
        backend_options: wgpu::BackendOptions::from_env_or_default(),
    })
}

/// Name and device type of the adapter this run will use, for the results record.
///
/// Requests an adapter with the same options and the same already-forced
/// `WGPU_BACKEND` as the sweep, so it names the adapter the sweep gets. Returns
/// `("unknown", "unknown")` rather than failing — provenance must never abort a run.
pub fn probe_adapter_info() -> (String, String) {
    match pollster::block_on(make_instance().request_adapter(&wgpu::RequestAdapterOptions {
        power_preference: wgpu::PowerPreference::HighPerformance,
        compatible_surface: None,
        force_fallback_adapter: false,
    })) {
        Ok(adapter) => {
            let info = adapter.get_info();
            (info.name, format!("{:?}", info.device_type))
        }
        Err(_) => ("unknown".to_string(), "unknown".to_string()),
    }
}

/// Adapter + device + queue with the adapter's *full* limits (not the conservative
/// 128 MiB storage-buffer default). `compatible` is the surface for windowed mode.
fn make_device(
    instance: &wgpu::Instance,
    compatible: Option<&wgpu::Surface<'_>>,
) -> (wgpu::Adapter, wgpu::Device, wgpu::Queue) {
    let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
        power_preference: wgpu::PowerPreference::HighPerformance,
        compatible_surface: compatible,
        force_fallback_adapter: false,
    }))
    .expect("no GPU adapter for the selected backend");

    let limits = adapter.limits(); // raise storage-buffer cap to the hardware max
    let features = adapter.features() & wgpu::Features::CLEAR_TEXTURE;
    let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
        label: Some("scaling_rig-device"),
        required_features: features,
        required_limits: limits,
        ..Default::default()
    }))
    .expect("request_device failed");
    (adapter, device, queue)
}

fn make_target(device: &wgpu::Device, w: u32, h: u32) -> (wgpu::Texture, wgpu::TextureView) {
    let tex = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("vello-intermediate"),
        size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        usage: wgpu::TextureUsages::STORAGE_BINDING | wgpu::TextureUsages::TEXTURE_BINDING,
        format: wgpu::TextureFormat::Rgba8Unorm,
        view_formats: &[],
    });
    let view = tex.create_view(&wgpu::TextureViewDescriptor::default());
    (tex, view)
}

// ---------------------------------------------------------------------------
// Offscreen
// ---------------------------------------------------------------------------

/// Run the sweep with no window/surface. Fully serialized CPU+GPU per frame.
pub fn run_offscreen(cfg: &SweepConfig) -> Vec<PointResult> {
    let instance = make_instance();
    let (_adapter, device, queue) = make_device(&instance, None);
    let mut renderer = Renderer::new(&device, renderer_options()).expect("Vello renderer");

    let (w, h) = (cfg.width, cfg.height);
    let (_target, view) = make_target(&device, w, h);

    let mut results = Vec::new();
    let run_start = Instant::now();
    for &n in &cfg.points {
        let inner = build_scene(cfg.seed, n);
        let mut outer = Scene::new();
        let mut accum = PointAccum::new(n);
        let point_start = Instant::now();
        loop {
            let point_elapsed = point_start.elapsed().as_secs_f64();
            if point_elapsed >= cfg.warmup + cfg.measure {
                break;
            }
            let t = run_start.elapsed().as_secs_f64();
            let fstart = Instant::now();
            outer.reset();
            outer.append(&inner, Some(camera(t, w, h)));
            let encode_ms = fstart.elapsed().as_secs_f64() * 1000.0;

            renderer
                .render_to_texture(&device, &queue, &outer, &view, &render_params(w, h))
                .expect("render_to_texture failed");
            device
                .poll(wgpu::PollType::wait_indefinitely())
                .expect("device poll failed");
            let frame_ms = fstart.elapsed().as_secs_f64() * 1000.0;

            if point_elapsed >= cfg.warmup {
                accum.push(encode_ms, frame_ms);
            }
        }
        let r = accum.finish();
        print_row(&r);
        results.push(r);
    }
    results
}

// ---------------------------------------------------------------------------
// Windowed
// ---------------------------------------------------------------------------

struct WindowApp {
    cfg: SweepConfig,
    instance: wgpu::Instance,
    window: Option<Arc<Window>>,
    surface: Option<wgpu::Surface<'static>>,
    config: Option<wgpu::SurfaceConfiguration>,
    device: Option<wgpu::Device>,
    queue: Option<wgpu::Queue>,
    target_view: Option<wgpu::TextureView>,
    blitter: Option<TextureBlitter>,
    renderer: Option<Renderer>,
    inner: Scene,
    outer: Scene,
    phys_w: u32,
    phys_h: u32,
    sweep_idx: usize,
    run_start: Instant,
    point_start: Instant,
    last_frame: Option<Instant>,
    accum: PointAccum,
    results: Vec<PointResult>,
    finished: bool,
}

impl WindowApp {
    fn new(cfg: SweepConfig) -> Self {
        let first = cfg.points[0];
        Self {
            instance: make_instance(),
            window: None,
            surface: None,
            config: None,
            device: None,
            queue: None,
            target_view: None,
            blitter: None,
            renderer: None,
            inner: Scene::new(),
            outer: Scene::new(),
            phys_w: cfg.width,
            phys_h: cfg.height,
            sweep_idx: 0,
            run_start: Instant::now(),
            point_start: Instant::now(),
            last_frame: None,
            accum: PointAccum::new(first),
            results: Vec::new(),
            finished: false,
            cfg,
        }
    }

    fn finish_point_and_advance(&mut self, event_loop: &ActiveEventLoop) {
        let accum = std::mem::replace(&mut self.accum, PointAccum::new(0));
        let r = accum.finish();
        print_row(&r);
        self.results.push(r);

        self.sweep_idx += 1;
        if self.sweep_idx >= self.cfg.points.len() {
            self.finished = true;
            event_loop.exit();
            return;
        }
        let n = self.cfg.points[self.sweep_idx];
        self.inner = build_scene(self.cfg.seed, n);
        self.accum = PointAccum::new(n);
        self.point_start = Instant::now();
        self.last_frame = None; // don't count the rebuild gap as a frame
    }

    fn reconfigure(&mut self) {
        if let (Some(surface), Some(device), Some(config)) =
            (&self.surface, &self.device, &self.config)
        {
            surface.configure(device, config);
        }
    }
}

impl ApplicationHandler for WindowApp {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.window.is_some() {
            return;
        }
        let attrs = Window::default_attributes()
            .with_title("scaling_rig — jas-shaped Vello sweep (Metal)")
            .with_inner_size(LogicalSize::new(self.cfg.width, self.cfg.height));
        let window = Arc::new(event_loop.create_window(attrs).expect("create_window"));
        let size = window.inner_size();
        let (pw, ph) = (size.width.max(1), size.height.max(1));

        let surface = self
            .instance
            .create_surface(window.clone())
            .expect("create_surface");
        let (adapter, device, queue) = make_device(&self.instance, Some(&surface));

        let caps = surface.get_capabilities(&adapter);
        let format = caps
            .formats
            .iter()
            .copied()
            .find(|f| {
                matches!(
                    f,
                    wgpu::TextureFormat::Rgba8Unorm | wgpu::TextureFormat::Bgra8Unorm
                )
            })
            .unwrap_or(caps.formats[0]);
        let config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format,
            width: pw,
            height: ph,
            present_mode: wgpu::PresentMode::AutoNoVsync,
            desired_maximum_frame_latency: 2,
            alpha_mode: wgpu::CompositeAlphaMode::Auto,
            view_formats: vec![],
        };
        surface.configure(&device, &config);

        let (_target, target_view) = make_target(&device, pw, ph);
        let blitter = TextureBlitter::new(&device, format);
        let renderer = Renderer::new(&device, renderer_options()).expect("Vello renderer");

        self.phys_w = pw;
        self.phys_h = ph;
        self.inner = build_scene(self.cfg.seed, self.cfg.points[0]);
        self.run_start = Instant::now();
        self.point_start = Instant::now();
        self.last_frame = None;

        self.surface = Some(surface);
        self.config = Some(config);
        self.device = Some(device);
        self.queue = Some(queue);
        self.target_view = Some(target_view);
        self.blitter = Some(blitter);
        self.renderer = Some(renderer);
        self.window = Some(window.clone());
        window.request_redraw();
    }

    fn window_event(&mut self, event_loop: &ActiveEventLoop, _id: WindowId, event: WindowEvent) {
        match event {
            WindowEvent::CloseRequested
            | WindowEvent::KeyboardInput {
                event:
                    winit::event::KeyEvent {
                        logical_key: Key::Named(NamedKey::Escape),
                        ..
                    },
                ..
            } => {
                self.finished = true;
                event_loop.exit();
            }
            WindowEvent::RedrawRequested => {
                if !self.finished {
                    self.draw(event_loop);
                }
            }
            _ => {}
        }
    }

    fn about_to_wait(&mut self, _event_loop: &ActiveEventLoop) {
        if !self.finished {
            if let Some(w) = &self.window {
                w.request_redraw();
            }
        }
    }
}

impl WindowApp {
    fn draw(&mut self, event_loop: &ActiveEventLoop) {
        let (w, h) = (self.phys_w, self.phys_h);
        let t = self.run_start.elapsed().as_secs_f64();
        let point_elapsed = self.point_start.elapsed().as_secs_f64();

        let fstart = Instant::now();
        self.outer.reset();
        self.outer.append(&self.inner, Some(camera(t, w, h)));
        let encode_ms = fstart.elapsed().as_secs_f64() * 1000.0;

        let device = self.device.as_ref().unwrap();
        let queue = self.queue.as_ref().unwrap();
        let surface = self.surface.as_ref().unwrap();
        let target_view = self.target_view.as_ref().unwrap();
        let blitter = self.blitter.as_ref().unwrap();
        let renderer = self.renderer.as_mut().unwrap();

        renderer
            .render_to_texture(device, queue, &self.outer, target_view, &render_params(w, h))
            .expect("render_to_texture");

        match surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(st)
            | wgpu::CurrentSurfaceTexture::Suboptimal(st) => {
                let view = st.texture.create_view(&wgpu::TextureViewDescriptor::default());
                let mut encoder =
                    device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: None });
                blitter.copy(device, &mut encoder, target_view, &view);
                queue.submit([encoder.finish()]);
                if let Some(w) = &self.window {
                    w.pre_present_notify();
                }
                st.present();
            }
            wgpu::CurrentSurfaceTexture::Outdated | wgpu::CurrentSurfaceTexture::Lost => {
                self.reconfigure();
                return;
            }
            _ => return, // Timeout / Occluded / Validation: skip
        }

        let now = Instant::now();
        if let Some(prev) = self.last_frame {
            let frame_ms = (now - prev).as_secs_f64() * 1000.0;
            if point_elapsed >= self.cfg.warmup {
                self.accum.push(encode_ms, frame_ms);
            }
        }
        self.last_frame = Some(now);

        if point_elapsed >= self.cfg.warmup + self.cfg.measure {
            self.finish_point_and_advance(event_loop);
        }
    }
}

/// Run the sweep in a real window. Returns (results, physical_width, physical_height).
pub fn run_windowed(cfg: &SweepConfig) -> (Vec<PointResult>, u32, u32) {
    let event_loop = EventLoop::new().expect("event loop");
    event_loop.set_control_flow(winit::event_loop::ControlFlow::Poll);
    let mut app = WindowApp::new(cfg.clone());
    event_loop.run_app(&mut app).expect("run_app");
    (app.results, app.phys_w, app.phys_h)
}

// ---------------------------------------------------------------------------

fn print_row(r: &PointResult) {
    println!(
        "{:>9}  {:>7}  {:>10.2}  {:>10.2}  {:>10.2}  {:>10.2}  {:>8.1}",
        r.elements, r.frames, r.avg_encode_ms, r.p95_encode_ms, r.avg_frame_ms, r.p95_frame_ms, r.fps
    );
}

pub fn print_header() {
    println!(
        "{:>9}  {:>7}  {:>10}  {:>10}  {:>10}  {:>10}  {:>8}",
        "elements", "frames", "enc_avg", "enc_p95", "frame_avg", "frame_p95", "fps"
    );
    println!("{}", "-".repeat(78));
}
