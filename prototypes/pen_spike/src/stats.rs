//! Percentile / summary statistics over the ledger, per pipeline stage.
//!
//! Percentiles use the nearest-rank method (matching the sibling `scaling_rig`
//! prototype) so the two rigs report distributions the same way.

use serde::Serialize;

use crate::ledger::{LatencyLedger, Stage};
use crate::qpc::QpcClock;

/// Reduced timing for one stage, in microseconds.
#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct StageStats {
    /// Stable stage key (see [`Stage::key`]).
    pub stage: String,
    /// How many events contributed a value to this stage.
    pub count: usize,
    pub avg_us: f64,
    pub p50_us: f64,
    pub p95_us: f64,
    pub p99_us: f64,
    pub min_us: f64,
    pub max_us: f64,
}

impl StageStats {
    /// Reduce a set of microsecond samples. Sorts `samples` in place. An empty
    /// set yields an all-zero row with `count == 0`.
    pub fn from_samples(stage: &str, samples: &mut [f64]) -> Self {
        if samples.is_empty() {
            return Self {
                stage: stage.to_string(),
                count: 0,
                avg_us: 0.0,
                p50_us: 0.0,
                p95_us: 0.0,
                p99_us: 0.0,
                min_us: 0.0,
                max_us: 0.0,
            };
        }
        let avg = samples.iter().sum::<f64>() / samples.len() as f64;
        samples.sort_by(|a, b| a.partial_cmp(b).unwrap());
        Self {
            stage: stage.to_string(),
            count: samples.len(),
            avg_us: round2(avg),
            p50_us: round2(percentile(samples, 0.50)),
            p95_us: round2(percentile(samples, 0.95)),
            p99_us: round2(percentile(samples, 0.99)),
            min_us: round2(samples[0]),
            max_us: round2(samples[samples.len() - 1]),
        }
    }
}

/// Nearest-rank percentile of an already-sorted slice. `q` in [0, 1].
/// Empty slice returns 0.
fn percentile(sorted: &[f64], q: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let idx = (((sorted.len() as f64) * q).ceil() as usize).saturating_sub(1);
    sorted[idx.min(sorted.len() - 1)]
}

fn round2(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}

/// The full per-stage summary of a run.
#[derive(Clone, Debug, Serialize)]
pub struct Summary {
    pub stages: Vec<StageStats>,
    /// Retained events (== `ledger.len()`).
    pub events: usize,
    /// Retained events that carried a valid hardware timestamp.
    pub hw_valid_events: usize,
    /// Events overwritten off the ring's tail.
    pub dropped: u64,
}

impl Summary {
    /// Reduce a ledger to per-stage microsecond statistics under `clock`.
    pub fn from_ledger(ledger: &LatencyLedger, clock: &QpcClock) -> Self {
        let stages = Stage::ALL
            .iter()
            .map(|&stage| {
                let mut vals: Vec<f64> = ledger
                    .iter()
                    .filter_map(|ev| ev.stage_ticks(stage))
                    .map(|ticks| clock.ticks_to_micros(ticks))
                    .collect();
                StageStats::from_samples(stage.key(), &mut vals)
            })
            .collect();
        let hw_valid_events = ledger.iter().filter(|e| e.hw_timestamp.is_some()).count();
        Self {
            stages,
            events: ledger.len(),
            hw_valid_events,
            dropped: ledger.dropped(),
        }
    }

    /// Look up one stage's stats by key.
    pub fn stage(&self, key: &str) -> Option<&StageStats> {
        self.stages.iter().find(|s| s.stage == key)
    }

    /// Print the stage table to stdout (the on-exit console summary).
    pub fn print_table(&self) {
        println!(
            "\nevents: {}  (hw-timestamped: {}, dropped off ring: {})",
            self.events, self.hw_valid_events, self.dropped
        );
        println!(
            "{:<38} {:>6} {:>10} {:>10} {:>10} {:>10} {:>10} {:>10}",
            "stage", "n", "avg_us", "p50_us", "p95_us", "p99_us", "min_us", "max_us"
        );
        for st in &self.stages {
            let label = Stage::ALL
                .iter()
                .find(|s| s.key() == st.stage)
                .map(|s| s.label())
                .unwrap_or(st.stage.as_str());
            println!(
                "{:<38} {:>6} {:>10.2} {:>10.2} {:>10.2} {:>10.2} {:>10.2} {:>10.2}",
                label, st.count, st.avg_us, st.p50_us, st.p95_us, st.p99_us, st.min_us, st.max_us
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ledger::{EventRecord, PointerKind};

    #[test]
    fn percentiles_of_one_to_hundred() {
        let mut s: Vec<f64> = (1..=100).map(|v| v as f64).collect();
        let st = StageStats::from_samples("x", &mut s);
        assert_eq!(st.count, 100);
        assert_eq!(st.avg_us, 50.5);
        assert_eq!(st.p50_us, 50.0); // ceil(100*0.5)-1 = 49 -> value 50
        assert_eq!(st.p95_us, 95.0);
        assert_eq!(st.p99_us, 99.0);
        assert_eq!(st.min_us, 1.0);
        assert_eq!(st.max_us, 100.0);
    }

    #[test]
    fn empty_samples_are_all_zero() {
        let mut s: Vec<f64> = vec![];
        let st = StageStats::from_samples("x", &mut s);
        assert_eq!(st.count, 0);
        assert_eq!(st.avg_us, 0.0);
        assert_eq!(st.p95_us, 0.0);
        assert_eq!(st.max_us, 0.0);
    }

    #[test]
    fn single_sample_all_stats_equal() {
        let mut s = vec![7.0];
        let st = StageStats::from_samples("x", &mut s);
        assert_eq!(st.count, 1);
        assert_eq!(st.avg_us, 7.0);
        assert_eq!(st.p50_us, 7.0);
        assert_eq!(st.p99_us, 7.0);
        assert_eq!(st.min_us, 7.0);
        assert_eq!(st.max_us, 7.0);
    }

    #[test]
    fn summary_over_ledger_uses_the_clock() {
        // 10 MHz clock: 1 tick = 0.1 us. Build three events whose
        // receipt->present spans are 3000, 4000, 5000 ticks => 300, 400, 500 us.
        let clock = QpcClock::from_frequency(10_000_000);
        let mut led = LatencyLedger::new(16);
        for (i, span) in [3_000i64, 4_000, 5_000].into_iter().enumerate() {
            led.record(EventRecord {
                seq: i as u64,
                kind: PointerKind::Update,
                hw_timestamp: Some(0),
                handler_receipt_qpc: 1_000,
                encode_start_qpc: Some(1_100),
                present_submitted_qpc: Some(1_000 + span),
            });
        }
        let sum = Summary::from_ledger(&led, &clock);
        assert_eq!(sum.events, 3);
        assert_eq!(sum.hw_valid_events, 3);
        assert_eq!(sum.dropped, 0);
        let r2p = sum.stage("receipt_to_present").unwrap();
        assert_eq!(r2p.count, 3);
        assert_eq!(r2p.avg_us, 400.0); // (300+400+500)/3
        assert_eq!(r2p.min_us, 300.0);
        assert_eq!(r2p.max_us, 500.0);
    }

    #[test]
    fn summary_counts_hw_valid_subset() {
        let clock = QpcClock::from_frequency(10_000_000);
        let mut led = LatencyLedger::new(16);
        // One with hw, one without.
        led.record(EventRecord {
            seq: 0,
            kind: PointerKind::Down,
            hw_timestamp: Some(500),
            handler_receipt_qpc: 1_000,
            encode_start_qpc: Some(1_100),
            present_submitted_qpc: Some(1_400),
        });
        led.record(EventRecord {
            seq: 1,
            kind: PointerKind::Update,
            hw_timestamp: None,
            handler_receipt_qpc: 2_000,
            encode_start_qpc: Some(2_100),
            present_submitted_qpc: Some(2_400),
        });
        let sum = Summary::from_ledger(&led, &clock);
        assert_eq!(sum.events, 2);
        assert_eq!(sum.hw_valid_events, 1);
        // hw_to_present has only the first event; receipt_to_present has both.
        assert_eq!(sum.stage("hw_to_present").unwrap().count, 1);
        assert_eq!(sum.stage("receipt_to_present").unwrap().count, 2);
    }
}
