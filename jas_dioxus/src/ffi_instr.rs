//! Boundary instrumentation for the S-C chatter measurement.
//!
//! # Why this exists, and why a grep would not do
//!
//! S-C prices the materializer by **boundary chatter**: `extern "C"` invocations
//! AND bytes crossed, per named user interaction. The sequencing ruling
//! (`SEQUENCE-sc-spike-2026-08-24.md` §3.3) makes one instruction the most
//! important in the document, and it is this seat's own vacuous-lane law turned
//! on a counting deliverable:
//!
//! > **A static count of call sites in the C# source passes identically on a
//! > shell that was never run.** The source is on disk whether or not anything
//! > executed.
//!
//! That is the same failure the d2d CI lane had: a test NAME is in the tree on
//! every platform, so counting names proves nothing about execution. **So the
//! receipt for S-C is a counter incremented BY THE CROSSING ITSELF**, dumped
//! from a running process. A zero for an interaction that was performed is RED —
//! it means the interaction did not cross, or the shell did not run — and is
//! never to be reported as `skip`.
//!
//! # Population, stated rather than implied
//!
//! [`Crossing`] enumerates the **8 functions of the materializer surface** as it
//! stands on `main` at `22e5e30e` (all in `ffi.rs`). It deliberately does NOT
//! include the two S-B paint probes, which exist only on the S-B branch and are
//! not part of a panel's surface — a distinction that cost a round of correction
//! to establish, because "half-unbuilt" is a ratio whose denominator IS the tree
//! being counted.
//!
//! The two instrumentation entry points — `jas_instr_reset` and
//! `jas_instr_counters_json`, which live in `ffi.rs` beside every other
//! `extern "C"` — are **NOT part of that surface** and must never be counted
//! into it. They are the measuring apparatus, not the thing measured, and
//! [`Crossing`] deliberately has no variant for either.

use std::sync::atomic::{AtomicU64, Ordering};

/// One countable boundary function. The discriminant is an index into the
/// counter arrays, so adding a variant means adding a name to [`Crossing::NAMES`]
/// and nothing else.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(usize)]
pub enum Crossing {
    EngineNew = 0,
    EngineFree = 1,
    Free = 2,
    Version = 3,
    DocumentJson = 4,
    DispatchEvent = 5,
    LastErrorJson = 6,
    WidgetTree = 7,
}

impl Crossing {
    /// The surface, in discriminant order. Kept beside the enum so the JSON dump
    /// carries the ABI's own names rather than Rust identifiers.
    pub(crate) const NAMES: [&'static str; Crossing::COUNT] = [
        "jas_engine_new",
        "jas_engine_free",
        "jas_free",
        "jas_version",
        "jas_document_json",
        "jas_dispatch_event",
        "jas_last_error_json",
        "jas_widget_tree",
    ];

    /// Deliberately NOT `pub`: this is the instrument's own internal shape, and
    /// a `pub` const here is emitted by cbindgen into the C header as
    /// `#define Crossing_COUNT`. The header is the ABI contract a C consumer
    /// compiles against; it should describe what the shell can CALL, not the
    /// dimensions of a Rust-side counter that will change whenever the surface
    /// grows. (It was `pub` on the first push, and the cbindgen freshness gate
    /// caught the resulting drift immediately.)
    pub(crate) const COUNT: usize = 8;

    pub fn name(self) -> &'static str {
        Crossing::NAMES[self as usize]
    }
}

/// Per-function counters. Process-global and atomic rather than thread-local:
/// BL2 pins one ENGINE to one thread, but the shell may well call `jas_version`
/// or free a span from elsewhere, and a counter that silently missed those
/// crossings would understate chatter — the direction that flatters the result.
struct Counters {
    calls: [AtomicU64; Crossing::COUNT],
    bytes_in: [AtomicU64; Crossing::COUNT],
    bytes_out: [AtomicU64; Crossing::COUNT],
}

impl Counters {
    const fn new() -> Self {
        #[allow(clippy::declare_interior_mutable_const)]
        const Z: AtomicU64 = AtomicU64::new(0);
        Counters { calls: [Z; Crossing::COUNT], bytes_in: [Z; Crossing::COUNT], bytes_out: [Z; Crossing::COUNT] }
    }
}

static COUNTERS: Counters = Counters::new();

/// Record one crossing. `bytes_in` counts payload handed to Rust, `bytes_out`
/// counts payload handed back.
///
/// Ordering is `Relaxed`: these are independent counters read only after the
/// interaction has finished, so no other memory is ordered against them and the
/// cost stays off the measured path.
pub fn record(c: Crossing, bytes_in: usize, bytes_out: usize) {
    let i = c as usize;
    COUNTERS.calls[i].fetch_add(1, Ordering::Relaxed);
    COUNTERS.bytes_in[i].fetch_add(bytes_in as u64, Ordering::Relaxed);
    COUNTERS.bytes_out[i].fetch_add(bytes_out as u64, Ordering::Relaxed);
}

/// Zero every counter. Called at the START of a named interaction so the dump
/// that follows describes that interaction alone.
pub fn reset() {
    for i in 0..Crossing::COUNT {
        COUNTERS.calls[i].store(0, Ordering::Relaxed);
        COUNTERS.bytes_in[i].store(0, Ordering::Relaxed);
        COUNTERS.bytes_out[i].store(0, Ordering::Relaxed);
    }
}

/// Add an outbound payload size to a crossing ALREADY recorded by [`record`].
///
/// Two calls rather than one because these functions have EARLY RETURNS — a
/// null handle, bad UTF-8, unparseable JSON. The crossing is recorded on entry
/// so a refused call still counts (chatter is crossings, not successes), and the
/// payload is added at the point one actually exists. Recording only at the
/// successful exit would undercount exactly the calls a chatty shell makes and
/// gets nothing for.
pub fn record_out(c: Crossing, bytes_out: usize) {
    COUNTERS.bytes_out[c as usize].fetch_add(bytes_out as u64, Ordering::Relaxed);
}

/// Read one function's counters as `(calls, bytes_in, bytes_out)`.
pub fn read(c: Crossing) -> (u64, u64, u64) {
    let i = c as usize;
    (
        COUNTERS.calls[i].load(Ordering::Relaxed),
        COUNTERS.bytes_in[i].load(Ordering::Relaxed),
        COUNTERS.bytes_out[i].load(Ordering::Relaxed),
    )
}

/// The dump. Totals are included because the ruling requires crossings AND bytes
/// together — either alone is misleading — and per-function rows are included
/// because a bare total hides which call is doing the crossing.
pub fn snapshot_json() -> String {
    let mut rows = Vec::with_capacity(Crossing::COUNT);
    let (mut tc, mut ti, mut to) = (0u64, 0u64, 0u64);
    for i in 0..Crossing::COUNT {
        let calls = COUNTERS.calls[i].load(Ordering::Relaxed);
        let bin = COUNTERS.bytes_in[i].load(Ordering::Relaxed);
        let bout = COUNTERS.bytes_out[i].load(Ordering::Relaxed);
        tc += calls;
        ti += bin;
        to += bout;
        rows.push(format!(
            "{{\"fn\":\"{}\",\"calls\":{},\"bytes_in\":{},\"bytes_out\":{}}}",
            Crossing::NAMES[i],
            calls,
            bin,
            bout
        ));
    }
    format!(
        "{{\"surface\":\"main@22e5e30e\",\"functions\":{},\"crossings\":{},\"bytes_in\":{},\"bytes_out\":{},\"bytes_total\":{},\"per_fn\":[{}]}}",
        Crossing::COUNT,
        tc,
        ti,
        to,
        ti + to,
        rows.join(",")
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// The counters are PROCESS-GLOBAL, and cargo runs tests in parallel threads
    /// inside one binary. Without this lock two tests would interleave their
    /// `reset()` and `record()` calls and fail intermittently — a flake
    /// manufactured by the instrument rather than found by it.
    static SERIAL: Mutex<()> = Mutex::new(());

    #[test]
    fn a_fresh_counter_reads_zero() {
        let _g = SERIAL.lock().unwrap();
        reset();
        for i in 0..Crossing::COUNT {
            let c = [
                Crossing::EngineNew,
                Crossing::EngineFree,
                Crossing::Free,
                Crossing::Version,
                Crossing::DocumentJson,
                Crossing::DispatchEvent,
                Crossing::LastErrorJson,
                Crossing::WidgetTree,
            ][i];
            assert_eq!(read(c), (0, 0, 0), "{} should start at zero", c.name());
        }
    }

    #[test]
    fn record_increments_exactly_one_function() {
        let _g = SERIAL.lock().unwrap();
        reset();
        record(Crossing::WidgetTree, 12, 340);

        assert_eq!(read(Crossing::WidgetTree), (1, 12, 340));
        // The negative control, and it is the point of the test: every OTHER
        // function must still read zero. A counter that incremented everything
        // would pass an assertion that only checked the one we touched.
        assert_eq!(read(Crossing::DispatchEvent), (0, 0, 0));
        assert_eq!(read(Crossing::Version), (0, 0, 0));
    }

    #[test]
    fn record_accumulates_across_calls() {
        let _g = SERIAL.lock().unwrap();
        reset();
        record(Crossing::DispatchEvent, 10, 0);
        record(Crossing::DispatchEvent, 5, 0);
        assert_eq!(read(Crossing::DispatchEvent), (2, 15, 0));
    }

    #[test]
    fn reset_zeroes_a_used_counter() {
        let _g = SERIAL.lock().unwrap();
        reset();
        record(Crossing::Version, 0, 99);
        assert_eq!(read(Crossing::Version).0, 1);
        reset();
        assert_eq!(read(Crossing::Version), (0, 0, 0));
    }

    #[test]
    fn snapshot_names_every_function_and_totals_agree() {
        let _g = SERIAL.lock().unwrap();
        reset();
        record(Crossing::Version, 0, 7);
        record(Crossing::WidgetTree, 3, 11);
        let js = snapshot_json();

        for n in Crossing::NAMES {
            assert!(js.contains(n), "dump must name {n}: {js}");
        }
        // Totals are derived in the dump; assert them against the parts so a
        // future edit cannot let the headline and the rows disagree.
        assert!(js.contains("\"crossings\":2"), "{js}");
        assert!(js.contains("\"bytes_in\":3,\"bytes_out\":18"), "{js}");
        assert!(js.contains("\"bytes_total\":21"), "{js}");
        assert!(js.contains("\"surface\":\"main@22e5e30e\""), "{js}");
    }

    #[test]
    fn names_are_in_discriminant_order() {
        // The dump indexes NAMES by discriminant. If the two ever drift, every
        // row in every published chatter table is silently mislabelled — the
        // numbers stay right and the attribution goes wrong, which is the harder
        // error to spot in a table that looks reasonable.
        assert_eq!(Crossing::EngineNew.name(), "jas_engine_new");
        assert_eq!(Crossing::EngineFree.name(), "jas_engine_free");
        assert_eq!(Crossing::Free.name(), "jas_free");
        assert_eq!(Crossing::Version.name(), "jas_version");
        assert_eq!(Crossing::DocumentJson.name(), "jas_document_json");
        assert_eq!(Crossing::DispatchEvent.name(), "jas_dispatch_event");
        assert_eq!(Crossing::LastErrorJson.name(), "jas_last_error_json");
        assert_eq!(Crossing::WidgetTree.name(), "jas_widget_tree");
    }
}
