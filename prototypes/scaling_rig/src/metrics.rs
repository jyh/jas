//! Timing accumulation and the JSON result schema.

use serde::Serialize;

/// Per-sweep-point timing. `encode_ms` is the CPU cost of building the per-frame
/// scene (Vello `Scene::append` under the camera transform); `frame_ms` is the
/// full per-frame cost as measured by the active mode (see `RunResults.timing_note`).
#[derive(Serialize, Clone)]
pub struct PointResult {
    pub elements: usize,
    pub frames: usize,
    pub avg_encode_ms: f64,
    pub p95_encode_ms: f64,
    pub avg_frame_ms: f64,
    pub p95_frame_ms: f64,
    pub fps: f64,
}

/// Collects samples for one sweep point, then reduces to a `PointResult`.
pub struct PointAccum {
    pub elements: usize,
    encode: Vec<f64>,
    frame: Vec<f64>,
}

impl PointAccum {
    pub fn new(elements: usize) -> Self {
        Self { elements, encode: Vec::new(), frame: Vec::new() }
    }

    pub fn push(&mut self, encode_ms: f64, frame_ms: f64) {
        self.encode.push(encode_ms);
        self.frame.push(frame_ms);
    }

    pub fn finish(mut self) -> PointResult {
        let (avg_encode, p95_encode) = stats(&mut self.encode);
        let (avg_frame, p95_frame) = stats(&mut self.frame);
        let fps = if avg_frame > 0.0 { 1000.0 / avg_frame } else { 0.0 };
        PointResult {
            elements: self.elements,
            frames: self.frame.len(),
            avg_encode_ms: round2(avg_encode),
            p95_encode_ms: round2(p95_encode),
            avg_frame_ms: round2(avg_frame),
            p95_frame_ms: round2(p95_frame),
            fps: round2(fps),
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
}
