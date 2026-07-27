//! Timing accumulation and the JSON result schema.

use serde::Serialize;

/// Per-sweep-point timing, in three nested spans of the same frame:
///
/// - `encode_ms` — Vello `Scene::append` under the camera transform, CPU only.
/// - `cpu_ms` — encode **plus** `render_to_texture`, i.e. everything the CPU does
///   before it hands off and waits. This is the load-bearing one: the rig turned
///   out to be single-thread CPU bound, and `encode_ms` alone under-reports the
///   CPU cost by roughly 8x because most of it hides inside `render_to_texture`
///   (Vello's resolve + buffer upload).
/// - `frame_ms` — the full per-frame cost as measured by the active mode
///   (see `RunResults.timing_note`).
///
/// `cpu_fraction` = `avg_cpu_ms / avg_frame_ms`, the share of a frame that no
/// amount of GPU pipelining can hide. On kenai this reads ~0.82, matching both an
/// external process-CPU measurement and the observed pipelining ceiling.
#[derive(Serialize, Clone)]
pub struct PointResult {
    pub elements: usize,
    pub frames: usize,
    pub avg_encode_ms: f64,
    pub p95_encode_ms: f64,
    pub avg_cpu_ms: f64,
    pub p95_cpu_ms: f64,
    pub avg_frame_ms: f64,
    pub p95_frame_ms: f64,
    pub fps: f64,
    pub cpu_fraction: f64,
}

/// Collects samples for one sweep point, then reduces to a `PointResult`.
pub struct PointAccum {
    pub elements: usize,
    encode: Vec<f64>,
    cpu: Vec<f64>,
    frame: Vec<f64>,
}

impl PointAccum {
    pub fn new(elements: usize) -> Self {
        Self { elements, encode: Vec::new(), cpu: Vec::new(), frame: Vec::new() }
    }

    pub fn push(&mut self, encode_ms: f64, cpu_ms: f64, frame_ms: f64) {
        self.encode.push(encode_ms);
        self.cpu.push(cpu_ms);
        self.frame.push(frame_ms);
    }

    pub fn finish(mut self) -> PointResult {
        let (avg_encode, p95_encode) = stats(&mut self.encode);
        let (avg_cpu, p95_cpu) = stats(&mut self.cpu);
        let (avg_frame, p95_frame) = stats(&mut self.frame);
        let fps = if avg_frame > 0.0 { 1000.0 / avg_frame } else { 0.0 };
        let cpu_fraction = if avg_frame > 0.0 { avg_cpu / avg_frame } else { 0.0 };
        PointResult {
            elements: self.elements,
            frames: self.frame.len(),
            avg_encode_ms: round2(avg_encode),
            p95_encode_ms: round2(p95_encode),
            avg_cpu_ms: round2(avg_cpu),
            p95_cpu_ms: round2(p95_cpu),
            avg_frame_ms: round2(avg_frame),
            p95_frame_ms: round2(p95_frame),
            fps: round2(fps),
            cpu_fraction: (cpu_fraction * 1000.0).round() / 1000.0,
        }
    }
}

fn round2(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}

/// Returns (mean, p95). Sorts the slice in place. Empty => (0, 0).
fn stats(samples: &mut [f64]) -> (f64, f64) {
    if samples.is_empty() {
        return (0.0, 0.0);
    }
    let mean = samples.iter().sum::<f64>() / samples.len() as f64;
    samples.sort_by(|a, b| a.partial_cmp(b).unwrap());
    // Nearest-rank p95.
    let idx = (((samples.len() as f64) * 0.95).ceil() as usize).saturating_sub(1);
    let p95 = samples[idx.min(samples.len() - 1)];
    (mean, p95)
}

#[derive(Serialize)]
pub struct RunResults {
    pub machine: String,
    pub chip: String,
    pub os: String,
    pub backend: String,
    /// The GPU wgpu actually selected, and whether it is real hardware. Without
    /// these a record cannot prove it was not software-rasterized (WARP/lavapipe),
    /// which would make every number meaningless.
    pub adapter: String,
    pub device_type: String,
    pub mode: String,
    pub present_mode: String,
    pub antialiasing: String,
    pub width: u32,
    pub height: u32,
    pub seed: u64,
    pub warmup_secs: f64,
    pub measure_secs: f64,
    pub architecture_note: String,
    pub timing_note: String,
    pub generated_unix: u64,
    pub points: Vec<PointResult>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stats_mean_and_p95() {
        let mut s: Vec<f64> = (1..=100).map(|v| v as f64).collect();
        let (mean, p95) = stats(&mut s);
        assert!((mean - 50.5).abs() < 1e-9);
        assert_eq!(p95, 95.0);
    }

    #[test]
    fn stats_empty_is_zero() {
        let mut s: Vec<f64> = vec![];
        assert_eq!(stats(&mut s), (0.0, 0.0));
    }

    /// The three series are reduced independently and the frame count comes from
    /// the frame series. This exists because `cpu_ms` was added late: it must be
    /// its own series, not silently aliased to encode or frame.
    #[test]
    fn accum_reduces_three_independent_series() {
        let mut a = PointAccum::new(1234);
        a.push(1.0, 10.0, 100.0);
        a.push(3.0, 30.0, 300.0);
        let r = a.finish();
        assert_eq!(r.elements, 1234);
        assert_eq!(r.frames, 2);
        assert_eq!(r.avg_encode_ms, 2.0);
        assert_eq!(r.avg_cpu_ms, 20.0);
        assert_eq!(r.avg_frame_ms, 200.0);
        assert_eq!(r.fps, 5.0); // 1000 / 200
    }

    /// `cpu_fraction` is the whole point of the new metric — it is what the
    /// external process-CPU sampling on kenai measured as 0.82, so the rig must
    /// report the same quantity itself.
    #[test]
    fn cpu_fraction_reports_the_cpu_share_of_a_frame() {
        let mut a = PointAccum::new(1);
        a.push(12.7, 114.0, 139.6); // kenai's measured 800k frame
        let r = a.finish();
        assert!(
            (r.cpu_fraction - 0.82).abs() < 0.01,
            "expected ~0.82, got {}",
            r.cpu_fraction
        );
    }

    /// A degenerate point must not divide by zero.
    #[test]
    fn cpu_fraction_of_no_frames_is_zero() {
        assert_eq!(PointAccum::new(0).finish().cpu_fraction, 0.0);
    }
}
