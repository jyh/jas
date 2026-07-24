//! The per-event latency ledger: a fixed-capacity ring buffer of QPC-stamped
//! pointer events, plus the stage-duration extraction each event supports.
//!
//! A record captures four instants along the app-internal path of one pointer
//! event, all in raw QPC ticks (see [`crate::qpc`] for the tick domain):
//!
//! * `hw_timestamp`         — `POINTER_INFO.PerformanceCount`, the OS/driver's
//!                            hardware timestamp for the input (may be absent).
//! * `handler_receipt_qpc`  — `QueryPerformanceCounter` the instant our
//!                            WM_POINTER* handler ran.
//! * `encode_start_qpc`     — when we began encoding the wgpu frame for it.
//! * `present_submitted_qpc`— when we submitted the present for that frame.
//!
//! Motion-to-photon (light actually leaving the glass) is NOT here — that needs
//! real hardware plus a high-speed camera at the desk. This ledger measures the
//! app-internal segment, which is a *lower bound* on end-to-end latency.

use serde::Serialize;

/// Which WM_POINTER* message produced the record.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum PointerKind {
    Down,
    Update,
    Up,
}

impl PointerKind {
    pub fn as_str(self) -> &'static str {
        match self {
            PointerKind::Down => "down",
            PointerKind::Update => "update",
            PointerKind::Up => "up",
        }
    }
}

/// One pointer event, timestamped at each pipeline stage in raw QPC ticks.
///
/// `hw_timestamp` is `None` when the driver did not supply a usable
/// `PerformanceCount` (recorded honestly rather than faked). `encode_start_qpc`
/// / `present_submitted_qpc` are `None` when no frame was produced for this
/// event (e.g. the event was coalesced into a later frame).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub struct EventRecord {
    pub seq: u64,
    pub kind: PointerKind,
    pub hw_timestamp: Option<i64>,
    pub handler_receipt_qpc: i64,
    pub encode_start_qpc: Option<i64>,
    pub present_submitted_qpc: Option<i64>,
}

/// A latency stage: the tick span between two of an event's instants.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stage {
    /// Hardware timestamp -> our handler ran. OS/driver + message-queue delay.
    HwToReceipt,
    /// Handler ran -> we began encoding the frame. Our dispatch overhead.
    ReceiptToEncode,
    /// Encode began -> present submitted. Our encode + submit cost.
    EncodeToPresent,
    /// Handler ran -> present submitted. App-internal end-to-end (always
    /// available once a frame is produced, even without a hardware timestamp).
    ReceiptToPresent,
    /// Hardware timestamp -> present submitted. The fullest app-internal
    /// end-to-end; needs a valid hardware timestamp.
    HwToPresent,
}

impl Stage {
    /// Every stage, in pipeline order, for iteration in summaries/reports.
    pub const ALL: [Stage; 5] = [
        Stage::HwToReceipt,
        Stage::ReceiptToEncode,
        Stage::EncodeToPresent,
        Stage::ReceiptToPresent,
        Stage::HwToPresent,
    ];

    /// Stable machine key (JSON field / CSV column stem).
    pub fn key(self) -> &'static str {
        match self {
            Stage::HwToReceipt => "hw_to_receipt",
            Stage::ReceiptToEncode => "receipt_to_encode",
            Stage::EncodeToPresent => "encode_to_present",
            Stage::ReceiptToPresent => "receipt_to_present",
            Stage::HwToPresent => "hw_to_present",
        }
    }

    /// Human-readable label for the printed table.
    pub fn label(self) -> &'static str {
        match self {
            Stage::HwToReceipt => "hw -> handler receipt",
            Stage::ReceiptToEncode => "receipt -> encode start",
            Stage::EncodeToPresent => "encode -> present submit",
            Stage::ReceiptToPresent => "receipt -> present (app end-to-end)",
            Stage::HwToPresent => "hw -> present (full app end-to-end)",
        }
    }
}

impl EventRecord {
    /// The tick span for `stage`, or `None` if an endpoint is missing or the
    /// span is negative (a backwards reading we refuse to report — see
    /// [`crate::qpc::QpcClock::duration_us`]).
    pub fn stage_ticks(&self, stage: Stage) -> Option<i64> {
        let d = match stage {
            Stage::HwToReceipt => self.handler_receipt_qpc - self.hw_timestamp?,
            Stage::ReceiptToEncode => self.encode_start_qpc? - self.handler_receipt_qpc,
            Stage::EncodeToPresent => self.present_submitted_qpc? - self.encode_start_qpc?,
            Stage::ReceiptToPresent => self.present_submitted_qpc? - self.handler_receipt_qpc,
            Stage::HwToPresent => self.present_submitted_qpc? - self.hw_timestamp?,
        };
        if d < 0 {
            None
        } else {
            Some(d)
        }
    }
}

/// Fixed-capacity ring buffer of [`EventRecord`]s.
///
/// A long doodling session at a high pen report rate can outrun any bounded
/// store; the ring keeps the most-recent `capacity` records and counts the rest
/// as `dropped` (an honest overflow signal rather than unbounded growth or a
/// silent stop). For a 30 s sitting at ~250 Hz, ~7.5k records fit in the default
/// 65_536-slot ring with room to spare.
pub struct LatencyLedger {
    capacity: usize,
    buf: Vec<EventRecord>,
    /// Index of the next slot to write once the buffer is full.
    head: usize,
    /// Count of records overwritten (i.e. lost off the tail).
    dropped: u64,
}

impl LatencyLedger {
    /// Create a ledger holding at most `capacity` records (must be > 0).
    pub fn new(capacity: usize) -> Self {
        assert!(capacity > 0, "ledger capacity must be positive");
        Self {
            capacity,
            buf: Vec::with_capacity(capacity),
            head: 0,
            dropped: 0,
        }
    }

    /// Append a record, overwriting the oldest if the ring is full.
    pub fn record(&mut self, ev: EventRecord) {
        if self.buf.len() < self.capacity {
            self.buf.push(ev);
        } else {
            self.buf[self.head] = ev;
            self.dropped += 1;
            self.head = (self.head + 1) % self.capacity;
        }
    }

    /// Number of records currently retained (<= capacity).
    pub fn len(&self) -> usize {
        self.buf.len()
    }

    pub fn is_empty(&self) -> bool {
        self.buf.is_empty()
    }

    /// Records overwritten off the tail because the ring filled.
    pub fn dropped(&self) -> u64 {
        self.dropped
    }

    /// Capacity the ring was built with.
    pub fn capacity(&self) -> usize {
        self.capacity
    }

    /// Iterate retained records oldest-to-newest.
    pub fn iter(&self) -> impl Iterator<Item = &EventRecord> + '_ {
        let n = self.buf.len();
        let full = n == self.capacity;
        (0..n).map(move |i| {
            // Before the first wrap, records sit in insertion order at 0..n and
            // `head` is 0. Once full, `head` points at the oldest record.
            let idx = if full { (self.head + i) % self.capacity } else { i };
            &self.buf[idx]
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rec(seq: u64) -> EventRecord {
        EventRecord {
            seq,
            kind: PointerKind::Update,
            hw_timestamp: Some(1_000),
            handler_receipt_qpc: 1_100,
            encode_start_qpc: Some(1_150),
            present_submitted_qpc: Some(1_400),
        }
    }

    #[test]
    fn under_capacity_keeps_all_in_order() {
        let mut l = LatencyLedger::new(4);
        for s in 0..3 {
            l.record(rec(s));
        }
        assert_eq!(l.len(), 3);
        assert_eq!(l.dropped(), 0);
        let seqs: Vec<u64> = l.iter().map(|e| e.seq).collect();
        assert_eq!(seqs, vec![0, 1, 2]);
    }

    #[test]
    fn overflow_drops_oldest_and_counts() {
        let mut l = LatencyLedger::new(4);
        for s in 0..6 {
            l.record(rec(s));
        }
        assert_eq!(l.len(), 4);
        assert_eq!(l.dropped(), 2);
        // Oldest two (0,1) fell off; ring holds the most recent four in order.
        let seqs: Vec<u64> = l.iter().map(|e| e.seq).collect();
        assert_eq!(seqs, vec![2, 3, 4, 5]);
    }

    #[test]
    fn exactly_full_iterates_in_order() {
        let mut l = LatencyLedger::new(3);
        for s in 0..3 {
            l.record(rec(s));
        }
        assert_eq!(l.dropped(), 0);
        let seqs: Vec<u64> = l.iter().map(|e| e.seq).collect();
        assert_eq!(seqs, vec![0, 1, 2]);
    }

    #[test]
    fn wrap_many_times_keeps_last_window() {
        let mut l = LatencyLedger::new(3);
        for s in 0..10 {
            l.record(rec(s));
        }
        assert_eq!(l.len(), 3);
        assert_eq!(l.dropped(), 7);
        let seqs: Vec<u64> = l.iter().map(|e| e.seq).collect();
        assert_eq!(seqs, vec![7, 8, 9]);
    }

    #[test]
    fn stage_ticks_all_present() {
        let e = rec(0);
        assert_eq!(e.stage_ticks(Stage::HwToReceipt), Some(100)); // 1100 - 1000
        assert_eq!(e.stage_ticks(Stage::ReceiptToEncode), Some(50)); // 1150 - 1100
        assert_eq!(e.stage_ticks(Stage::EncodeToPresent), Some(250)); // 1400 - 1150
        assert_eq!(e.stage_ticks(Stage::ReceiptToPresent), Some(300)); // 1400 - 1100
        assert_eq!(e.stage_ticks(Stage::HwToPresent), Some(400)); // 1400 - 1000
    }

    #[test]
    fn missing_hw_timestamp_skips_hw_stages() {
        let mut e = rec(0);
        e.hw_timestamp = None;
        assert_eq!(e.stage_ticks(Stage::HwToReceipt), None);
        assert_eq!(e.stage_ticks(Stage::HwToPresent), None);
        // Non-hw stages are unaffected.
        assert_eq!(e.stage_ticks(Stage::ReceiptToPresent), Some(300));
    }

    #[test]
    fn missing_present_skips_present_stages() {
        let mut e = rec(0);
        e.present_submitted_qpc = None;
        assert_eq!(e.stage_ticks(Stage::EncodeToPresent), None);
        assert_eq!(e.stage_ticks(Stage::ReceiptToPresent), None);
        assert_eq!(e.stage_ticks(Stage::HwToPresent), None);
        assert_eq!(e.stage_ticks(Stage::ReceiptToEncode), Some(50));
    }

    #[test]
    fn negative_span_is_rejected() {
        // A hardware timestamp AFTER our receipt (cross-domain skew) must not
        // surface as a negative latency.
        let mut e = rec(0);
        e.hw_timestamp = Some(2_000); // later than handler_receipt_qpc (1_100)
        assert_eq!(e.stage_ticks(Stage::HwToReceipt), None);
    }
}
