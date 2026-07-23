//! scaling_rig — Arc 2 prototype #1.
//!
//! Ratified question: does the wgpu/Vello path hold 60fps at 100k jas-shaped
//! elements with a GRACEFUL (non-cliff) degradation curve to 1M? First verdict
//! on this Mac's Metal GPU.

mod camera;
mod gpu;
mod metrics;
mod rng;
mod scene;

use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use clap::{Parser, ValueEnum};

use gpu::SweepConfig;
use metrics::RunResults;

#[derive(Clone, Copy, Debug, ValueEnum)]
enum Backend {
    Metal,
    Dx12,
    Vulkan,
    Gl,
}

impl Backend {
    /// The value understood by wgpu's `WGPU_BACKEND` env parser.
    fn as_env(self) -> &'static str {
        match self {
            Backend::Metal => "metal",
            Backend::Dx12 => "dx12",
            Backend::Vulkan => "vulkan",
            Backend::Gl => "gl",
        }
    }
}

#[derive(Clone, Copy, Debug, ValueEnum, PartialEq)]
enum Mode {
    Windowed,
    Offscreen,
}

/// jas-shaped Vello scaling rig. Backend selection is ALWAYS explicit — there is
/// deliberately no "all backends" option, because GL segfaults under the Parallels
/// VM and an all-backends probe would trip it.
#[derive(Parser, Debug)]
#[command(about, long_about = None)]
struct Cli {
    /// GPU backend (explicit; never defaulted to all). metal on this Mac; vulkan/dx12 on WARP.
    #[arg(long, value_enum)]
    backend: Backend,

    /// Single element count instead of the full sweep.
    #[arg(long)]
    elements: Option<usize>,

    /// Comma-separated sweep points, overriding the default 10k..1M ladder.
    #[arg(long)]
    points: Option<String>,

    /// Seconds measured per sweep point (after warmup).
    #[arg(long, default_value_t = 8.0)]
    seconds: f64,

    /// Warmup seconds discarded per sweep point.
    #[arg(long, default_value_t = 2.0)]
    warmup: f64,

    /// windowed (measured on Metal) or offscreen (VM/CI, no surface).
    #[arg(long, value_enum, default_value_t = Mode::Windowed)]
    mode: Mode,

    /// Output JSON path.
    #[arg(long, default_value = "results.json")]
    out: PathBuf,

    #[arg(long, default_value_t = 1600)]
    width: u32,

    #[arg(long, default_value_t = 1000)]
    height: u32,

    /// Deterministic scene seed.
    #[arg(long, default_value_t = 0x006A_6173)]
    seed: u64,
}

fn sysctl(key: &str) -> String {
    std::process::Command::new("sysctl")
        .args(["-n", key])
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "unknown".to_string())
}

fn os_string() -> String {
    let product = std::process::Command::new("sw_vers")
        .arg("-productVersion")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_default();
    if product.is_empty() {
        std::env::consts::OS.to_string()
    } else {
        format!("macOS {product}")
    }
}

fn main() {
    let cli = Cli::parse();

    // Force the backend BEFORE any wgpu/Vello initialization. Explicit only.
    std::env::set_var("WGPU_BACKEND", cli.backend.as_env());
    let _ = env_logger::try_init();

    // Default ladder tops out at 800k, not 1M: Vello 0.9 renders a single retained
    // Scene through one compute pipeline whose per-element dispatch hits the WebGPU
    // `max_compute_workgroups_per_dimension` cap of 65535 at ~807k jas-shaped
    // elements (a hard Validation Error, empirically 807k renders / 808k crashes).
    // Reaching a literal 1M needs the document split into multiple scene batches
    // (a distinct multi-pass architecture). Pass `--points ...` to override.
    let points: Vec<usize> = if let Some(n) = cli.elements {
        vec![n]
    } else if let Some(spec) = &cli.points {
        spec.split(',')
            .filter_map(|s| s.trim().parse::<usize>().ok())
            .collect()
    } else {
        vec![10_000, 50_000, 100_000, 250_000, 500_000, 800_000]
    };
    assert!(!points.is_empty(), "no sweep points");

    let cfg = SweepConfig {
        points: points.clone(),
        width: cli.width,
        height: cli.height,
        seed: cli.seed,
        warmup: cli.warmup,
        measure: cli.seconds,
    };

    let chip = sysctl("machdep.cpu.brand_string");
    let os = os_string();

    println!("scaling_rig — jas-shaped wgpu/Vello sweep");
    println!("  chip     : {chip}");
    println!("  os       : {os}");
    println!("  backend  : {}", cli.backend.as_env());
    println!("  mode     : {:?}", cli.mode);
    println!("  target   : {}x{} (offscreen exact; windowed = physical/retina)", cli.width, cli.height);
    println!("  seed     : {:#x}", cli.seed);
    println!("  per point: {:.0}s warmup + {:.0}s measure", cli.warmup, cli.seconds);
    println!("  sweep    : {points:?}");
    println!();
    gpu::print_header();

    let (results, phys_w, phys_h, mode_str, present_mode, timing_note) = match cli.mode {
        Mode::Offscreen => (
            gpu::run_offscreen(&cfg),
            cli.width,
            cli.height,
            "offscreen".to_string(),
            "none (no surface)".to_string(),
            "frame_ms = encode + render_to_texture + poll(Wait): fully serialized CPU+GPU, no pipelining".to_string(),
        ),
        Mode::Windowed => {
            let (r, pw, ph) = gpu::run_windowed(&cfg);
            (
                r,
                pw,
                ph,
                "windowed".to_string(),
                "AutoNoVsync".to_string(),
                "frame_ms = steady-state inter-frame interval (true throughput, GPU-pipelined); encode_ms = Scene::append CPU time".to_string(),
            )
        }
    };

    let generated_unix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    let out = RunResults {
        machine: "mac".to_string(),
        chip,
        os,
        backend: cli.backend.as_env().to_string(),
        mode: mode_str,
        present_mode,
        antialiasing: "Area".to_string(),
        width: phys_w,
        height: phys_h,
        seed: cli.seed,
        warmup_secs: cli.warmup,
        measure_secs: cli.seconds,
        architecture_note:
            "Geometry encoded once into a retained vello::Scene per point; per frame a reused outer Scene is reset()+append(inner, camera) — re-encodes the command stream under the camera affine, not the geometry."
                .to_string(),
        timing_note,
        generated_unix,
        points: results,
    };

    let json = serde_json::to_string_pretty(&out).expect("serialize");
    std::fs::write(&cli.out, &json).expect("write results");
    println!();
    println!("wrote {}", cli.out.display());
}
