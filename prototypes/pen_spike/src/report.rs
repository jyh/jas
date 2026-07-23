//! Run metadata plus JSON / CSV serialization of a measurement session.
//!
//! JSON is the summary-of-record (metadata + per-stage stats); CSV is the raw
//! per-event dump (one row per retained record with its derived stage micros),
//! for offline plotting. Both writers take a generic `Write` so they are unit-
//! testable against an in-memory buffer on any host.

use std::io::{self, Write};

use serde::Serialize;

use crate::ledger::{LatencyLedger, Stage};
use crate::qpc::QpcClock;
use crate::stats::Summary;

/// Context recorded alongside every run (the "what machine / what backend"
/// provenance, mirroring `scaling_rig`'s results header).
#[derive(Clone, Debug, Serialize, Default)]
pub struct RunMeta {
    pub os: String,
    pub backend: String,
    pub adapter_name: String,
    /// e.g. "Cpu (WARP software rasterizer)".
    pub adapter_type: String,
    pub present_mode: String,
    pub surface_format: String,
    pub qpc_frequency: i64,
    /// Whether `EnableMouseInPointer(TRUE)` succeeded (mouse drives WM_POINTER).
    pub mouse_in_pointer: bool,
    pub requested_seconds: f64,
    pub ring_capacity: usize,
    pub generated_unix: u64,
    /// Honest caveat about present-side timing on this run's backend.
    pub present_timing_note: String,
    /// What the numbers do and do not include (app-internal vs motion-to-photon).
    pub scope_note: String,
}

/// A full run report: provenance + reduced statistics.
#[derive(Serialize)]
pub struct RunReport {
    pub meta: RunMeta,
    pub summary: Summary,
}

impl RunReport {
    pub fn new(meta: RunMeta, summary: Summary) -> Self {
        Self { meta, summary }
    }

    pub fn to_json_string(&self) -> serde_json::Result<String> {
        serde_json::to_string_pretty(self)
    }

    /// Write the report as pretty JSON to `w`.
    pub fn write_json<W: Write>(&self, w: &mut W) -> io::Result<()> {
        let s = self
            .to_json_string()
            .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
        w.write_all(s.as_bytes())?;
        w.write_all(b"\n")
    }
}

fn opt_i(v: Option<i64>) -> String {
    v.map(|x| x.to_string()).unwrap_or_default()
}

fn opt_us(v: Option<f64>) -> String {
    v.map(|x| format!("{x:.3}")).unwrap_or_default()
}

/// Write per-event CSV (one row per retained record) with derived stage micros.
///
/// Columns: raw QPC fields first (for auditing / re-derivation), then the five
/// stage durations in microseconds. Missing fields render as empty cells.
pub fn write_csv<W: Write>(w: &mut W, ledger: &LatencyLedger, clock: &QpcClock) -> io::Result<()> {
    writeln!(
        w,
        "seq,kind,hw_valid,hw_timestamp,handler_receipt_qpc,encode_start_qpc,present_submitted_qpc,\
hw_to_receipt_us,receipt_to_encode_us,encode_to_present_us,receipt_to_present_us,hw_to_present_us"
    )?;
    for ev in ledger.iter() {
        let us = |s: Stage| ev.stage_ticks(s).map(|t| clock.ticks_to_micros(t));
        writeln!(
            w,
            "{},{},{},{},{},{},{},{},{},{},{},{}",
            ev.seq,
            ev.kind.as_str(),
            ev.hw_timestamp.is_some(),
            opt_i(ev.hw_timestamp),
            ev.handler_receipt_qpc,
            opt_i(ev.encode_start_qpc),
            opt_i(ev.present_submitted_qpc),
            opt_us(us(Stage::HwToReceipt)),
            opt_us(us(Stage::ReceiptToEncode)),
            opt_us(us(Stage::EncodeToPresent)),
            opt_us(us(Stage::ReceiptToPresent)),
            opt_us(us(Stage::HwToPresent)),
        )?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ledger::{EventRecord, PointerKind};

    fn sample_ledger() -> (LatencyLedger, QpcClock) {
        let clock = QpcClock::from_frequency(10_000_000); // 1 tick = 0.1 us
        let mut led = LatencyLedger::new(8);
        led.record(EventRecord {
            seq: 0,
            kind: PointerKind::Down,
            hw_timestamp: Some(1_000),
            handler_receipt_qpc: 1_100,
            encode_start_qpc: Some(1_150),
            present_submitted_qpc: Some(1_400),
        });
        led.record(EventRecord {
            seq: 1,
            kind: PointerKind::Update,
            hw_timestamp: None,
            handler_receipt_qpc: 2_000,
            encode_start_qpc: Some(2_060),
            present_submitted_qpc: Some(2_300),
        });
        (led, clock)
    }

    #[test]
    fn json_roundtrips_with_expected_keys() {
        let (led, clock) = sample_ledger();
        let summary = Summary::from_ledger(&led, &clock);
        let meta = RunMeta {
            os: "windows".into(),
            backend: "dx12".into(),
            adapter_name: "Microsoft Basic Render Driver".into(),
            adapter_type: "Cpu (WARP)".into(),
            qpc_frequency: 10_000_000,
            ..Default::default()
        };
        let report = RunReport::new(meta, summary);
        let mut buf = Vec::new();
        report.write_json(&mut buf).unwrap();
        let v: serde_json::Value = serde_json::from_slice(&buf).unwrap();
        assert_eq!(v["meta"]["backend"], "dx12");
        assert_eq!(v["meta"]["qpc_frequency"], 10_000_000);
        assert_eq!(v["summary"]["events"], 2);
        assert_eq!(v["summary"]["hw_valid_events"], 1);
        // Stage array present and named.
        let stages = v["summary"]["stages"].as_array().unwrap();
        assert_eq!(stages.len(), 5);
        assert_eq!(stages[0]["stage"], "hw_to_receipt");
    }

    #[test]
    fn csv_has_header_and_one_row_per_event() {
        let (led, clock) = sample_ledger();
        let mut buf = Vec::new();
        write_csv(&mut buf, &led, &clock).unwrap();
        let text = String::from_utf8(buf).unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), 3); // header + 2 events
        assert!(lines[0].starts_with("seq,kind,hw_valid,"));
        assert!(lines[0].ends_with(",hw_to_present_us"));
        // Row 0 has a hardware timestamp; its hw_to_receipt cell = (1100-1000)
        // ticks * 0.1 us = 10.000; row 1 (no hw) leaves those cells empty.
        assert!(lines[1].starts_with("0,down,true,1000,1100,"));
        assert!(lines[1].contains(",10.000,")); // hw_to_receipt_us
        assert!(lines[2].starts_with("1,update,false,,2000,"));
        // Trailing hw_to_present cell is empty for the hw-less row.
        assert!(lines[2].ends_with(","));
    }
}
