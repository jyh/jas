//! Boundary instrumentation for the S-C chatter measurement.
//!
//! # Why this exists, and why a grep would not do
//!
//! S-C prices the materializer by **boundary chatter**: `extern "C"` invocations
//! AND bytes crossed, per named user interaction. The sequencing ruling's §3.3
//! makes one instruction the most important in that document, and it is this
//! machine's own vacuous-lane law turned on a counting deliverable:
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
//! [`Crossing`] enumerates the **10 functions of the materializer surface**: the
//! 8 that stood on `main` at `22e5e30e`, plus `jas_bind_values` (S-C.1, because
//! `widget_tree` is value-blind by design) and `jas_panel_event` (S-C.2, the
//! write path a tick needs) — all in `ffi.rs`. It deliberately does NOT
//! include the two S-B paint probes, which exist only on the S-B branch and are
//! not part of a panel's surface — a distinction that cost a round of correction
//! to establish, because "half-unbuilt" is a ratio whose denominator IS the tree
//! being counted.
//!
//! # One list, written once
//!
//! [`Crossing::ALL`] is the single place the variants are enumerated. An earlier
//! test re-listed them by hand and went out of bounds the moment a ninth was
//! added — and because the index panic happened while holding the tests' shared
//! mutex, it POISONED the lock and failed four unrelated tests at their
//! `lock().unwrap()`. One omission produced five reds, four of them innocent and
//! all four pointing at a line nowhere near the defect. The tests now take the
//! lock through a poison-tolerant helper for the same reason: a cascade that
//! renames the culprit is worse than the original failure.
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
    BindValues = 8,
    /// The S-C.2 write path: one control's new value in, the changed bind rows
    /// out. Counted like any other crossing -- a tick's cost is what it is.
    PanelEvent = 9,
    /// ⭐ ROW DU / NODE 5: a pointer transition. Counted like any other
    /// crossing -- and this one arrives at MOUSEMOVE RATES, so its cost is the
    /// one most worth having on the ledger rather than estimated.
    PointerEvent = 10,
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
        "jas_bind_values",
        "jas_panel_event",
        "jas_pointer_event",
    ];

    /// Deliberately NOT `pub`: this is the instrument's own internal shape, and
    /// a `pub` const here is emitted by cbindgen into the C header as
    /// `#define Crossing_COUNT`. The header is the ABI contract a C consumer
    /// compiles against; it should describe what the shell can CALL, not the
    /// dimensions of a Rust-side counter that will change whenever the surface
    /// grows. (It was `pub` on the first push, and the cbindgen freshness gate
    /// caught the resulting drift immediately.)
    pub(crate) const COUNT: usize = 11;

    /// Every variant, in discriminant order. Exists so the variant list is
    /// written ONCE: a test that re-listed the variants by hand went out of
    /// bounds the moment a ninth was added, and the index panic it raised
    /// poisoned the shared mutex and failed four unrelated tests with it. One
    /// omission, five reds, and the four loudest were innocent.
    pub(crate) const ALL: [Crossing; Crossing::COUNT] = [
        Crossing::EngineNew,
        Crossing::EngineFree,
        Crossing::Free,
        Crossing::Version,
        Crossing::DocumentJson,
        Crossing::DispatchEvent,
        Crossing::LastErrorJson,
        Crossing::WidgetTree,
        Crossing::BindValues,
        Crossing::PanelEvent,
        Crossing::PointerEvent,
    ];

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

/// ⭐ **What the boundary CANNOT see, counted anyway.**
///
/// Gate ⑤ requires engine-side cost reported beside the crossings, because a
/// protocol can be cheap at the boundary precisely by being expensive behind it
/// — and the crossing count would call that a win. The delta protocol is exactly
/// that shape: it stays flat in crossings and in bytes by re-evaluating every
/// open panel's bindings on every tick, so the number that grows with the
/// document lives here and nowhere else.
///
/// ⛔ **These are APPARATUS, not surface.** They are reported in their own
/// `engine` object in the dump, never in `per_fn` and never in `crossings`;
/// [`Crossing`] has no variant for them, exactly as it has none for the two
/// `jas_instr_*` externs.
struct Engine {
    rows_evaluated: AtomicU64,
    panels_evaluated: AtomicU64,
    ticks: AtomicU64,
}

static ENGINE: Engine = Engine {
    rows_evaluated: AtomicU64::new(0),
    panels_evaluated: AtomicU64::new(0),
    ticks: AtomicU64::new(0),
};

/// Record one tick's engine-side work: bind rows re-evaluated and panels walked.
pub fn record_engine(rows_evaluated: usize, panels_evaluated: usize) {
    ENGINE.rows_evaluated.fetch_add(rows_evaluated as u64, Ordering::Relaxed);
    ENGINE.panels_evaluated.fetch_add(panels_evaluated as u64, Ordering::Relaxed);
    ENGINE.ticks.fetch_add(1, Ordering::Relaxed);
}

/// `(rows_evaluated, panels_evaluated, ticks)`.
pub fn read_engine() -> (u64, u64, u64) {
    (
        ENGINE.rows_evaluated.load(Ordering::Relaxed),
        ENGINE.panels_evaluated.load(Ordering::Relaxed),
        ENGINE.ticks.load(Ordering::Relaxed),
    )
}

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

/// ⭐ ROW EK — **THE ONE TEST LOCK FOR THE SHARED COUNTERS**, and the guard that
/// makes a test hermetic.
///
/// ⛔ WHY IT LIVES HERE AND IS `pub(crate)` RATHER THAN PRIVATE TO A TESTS
/// MODULE. It used to be a `static SERIAL` inside `ffi_instr::tests`, which
/// serialised that module against ITSELF and against nothing else — while
/// `COUNTERS` is process-global and **every** `ffi_*` test writes it by calling
/// an export. `ffi.rs` alone has seven tests that build an engine, and
/// `ffi_pointer.rs` records on every `jas_pointer_event`. A lock private to one
/// module guarding a resource shared by four is not a lock; it is a comment.
///
/// **There is exactly one, and the old private mutex is DELETED rather than
/// left beside it** — two locks guarding one resource is the same defect
/// wearing a hat.
///
/// ⛔ IT SNAPSHOTS AND RESTORES, so a test that panics mid-way cannot poison the
/// next one with whatever it had counted so far. The restore runs in `Drop`,
/// which runs while unwinding.
///
/// ⛔ AND IT DOES NOT PROPAGATE POISON. A panic in any test poisons the mutex,
/// and `.unwrap()` on a poisoned lock panics in turn — so one genuine failure
/// reports as five, and the four bystanders panic at the lock line, nowhere
/// near the defect. The counters are plain atomics with no invariant a panic can
/// break, so recovering the guard is sound: the poison flag carries no
/// information here beyond "some other test failed", which the runner already
/// says. (That reasoning is inherited verbatim from the mutex this replaces —
/// it was right, it was just guarding too little.)
#[cfg(test)]
pub(crate) mod test_lock {
    use super::*;
    use std::sync::{Mutex, MutexGuard};

    static COUNTER_LOCK: Mutex<()> = Mutex::new(());

    /// The snapshot a guard restores on drop.
    type Saved = (Vec<(u64, u64, u64)>, (u64, u64, u64));

    pub(crate) struct CountersGuard {
        _lock: MutexGuard<'static, ()>,
        saved: Saved,
    }

    impl Drop for CountersGuard {
        fn drop(&mut self) {
            for (i, (c, bi, bo)) in self.saved.0.iter().enumerate() {
                COUNTERS.calls[i].store(*c, Ordering::Relaxed);
                COUNTERS.bytes_in[i].store(*bi, Ordering::Relaxed);
                COUNTERS.bytes_out[i].store(*bo, Ordering::Relaxed);
            }
            let (r, p, t) = self.saved.1;
            ENGINE.rows_evaluated.store(r, Ordering::Relaxed);
            ENGINE.panels_evaluated.store(p, Ordering::Relaxed);
            ENGINE.ticks.store(t, Ordering::Relaxed);
        }
    }

    /// Take the one lock and snapshot the counters. **Every test that touches
    /// them — in any module — calls this and holds the guard for its body.**
    pub(crate) fn lock() -> CountersGuard {
        let lock = COUNTER_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let calls = (0..Crossing::COUNT)
            .map(|i| (
                COUNTERS.calls[i].load(Ordering::Relaxed),
                COUNTERS.bytes_in[i].load(Ordering::Relaxed),
                COUNTERS.bytes_out[i].load(Ordering::Relaxed),
            ))
            .collect();
        let engine = (
            ENGINE.rows_evaluated.load(Ordering::Relaxed),
            ENGINE.panels_evaluated.load(Ordering::Relaxed),
            ENGINE.ticks.load(Ordering::Relaxed),
        );
        CountersGuard { _lock: lock, saved: (calls, engine) }
    }
}

/// Zero every counter. Called at the START of a named interaction so the dump
/// that follows describes that interaction alone.
pub fn reset() {
    for i in 0..Crossing::COUNT {
        COUNTERS.calls[i].store(0, Ordering::Relaxed);
        COUNTERS.bytes_in[i].store(0, Ordering::Relaxed);
        COUNTERS.bytes_out[i].store(0, Ordering::Relaxed);
    }
    // The engine counters reset WITH the crossings. They describe the same named
    // interaction, and a reset that cleared one and not the other would report
    // this tick's crossings beside every tick's engine work.
    ENGINE.rows_evaluated.store(0, Ordering::Relaxed);
    ENGINE.panels_evaluated.store(0, Ordering::Relaxed);
    ENGINE.ticks.store(0, Ordering::Relaxed);
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
    let (rows_eval, panels_eval, ticks) = read_engine();
    format!(
        "{{\"surface\":\"main@22e5e30e+jas_bind_values+jas_panel_event\",\"functions\":{},\"crossings\":{},\"bytes_in\":{},\"bytes_out\":{},\"bytes_total\":{},\"per_fn\":[{}],\"engine\":{{\"rows_evaluated\":{},\"panels_evaluated\":{},\"ticks\":{}}}}}",
        Crossing::COUNT,
        tc,
        ti,
        to,
        ti + to,
        rows.join(","),
        rows_eval,
        panels_eval,
        ticks
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    /// ⚰️ THE PRIVATE `SERIAL` MUTEX THAT USED TO LIVE HERE IS GONE. It
    /// serialised this module against itself while three others wrote the same
    /// process-global counters unlocked — the row EK defect. Every caller now
    /// takes the ONE crate-level lock, and gets snapshot/restore with it.
    use super::test_lock::lock as serial;

    /// ⭐ ROW EK, THE ARM: **200 interleaved rounds against a concurrent
    /// recorder, and both sides take THE SAME LOCK.**
    ///
    /// ⛔ THE RED IT WAS WRITTEN AGAINST, MEASURED BEFORE THE FIX: with the
    /// background thread recording WITHOUT the lock -- which is exactly what
    /// every `ffi.rs` and `ffi_pointer.rs` test used to do -- this loop failed
    /// **3 runs out of 3** on the `leaked == 0` line. That is the row EK defect
    /// reproduced on demand rather than waited for.
    ///
    /// ⚠️ AND WHY THE BACKGROUND THREAD NOW LOCKS RATHER THAN STAYING THE
    /// VILLAIN: a test that permanently records unlocked does not just fail
    /// itself, it POISONS EVERY OTHER TEST IN THE BINARY. Leaving it in broke
    /// `snapshot_names_every_function_and_totals_agree` on `"crossings":2` --
    /// which is the helm's own 14:02 fingerprint, reproduced by my own fix
    /// attempt. The permanent arm proves the lock HOLDS under interleaving; the
    /// measurement above is what proves it was needed.
    ///
    /// ⛔ THE LOOP CARRIES ITS OWN CONTROL. A stress loop whose other thread
    /// never runs is a loop that always passes -- the same vacuous green as a
    /// mutation filter matching nothing. `observed` asserts the recorder made
    /// progress across the window, and the test FAILS if it never did.
    #[test]
    fn the_counters_survive_an_interleaved_recorder() {
        use std::sync::atomic::{AtomicBool, AtomicUsize};
        use std::sync::Arc;

        let stop = Arc::new(AtomicBool::new(false));
        let hits = Arc::new(AtomicUsize::new(0));
        let (s2, h2) = (Arc::clone(&stop), Arc::clone(&hits));

        let noise = std::thread::spawn(move || {
            while !s2.load(Ordering::Relaxed) {
                {
                    // The SAME lock the reader takes. This is what every test
                    // touching the counters now does.
                    let _g = serial();
                    record(Crossing::PointerEvent, 0, 0);
                }
                h2.fetch_add(1, Ordering::Relaxed);
                std::thread::yield_now();
            }
        });

        let start = hits.load(Ordering::Relaxed);
        for _ in 0..200 {
            let _g = serial();
            reset();
            assert_eq!(read(Crossing::PointerEvent).0, 0,
                       "a counter read under the lock saw another thread's                         crossing -- the lock does not cover every writer");
        }
        let observed = hits.load(Ordering::Relaxed) - start;

        stop.store(true, Ordering::Relaxed);
        noise.join().expect("noise thread");
        assert!(observed > 0,
                "the recorder never ran during the window, so this loop proved                  nothing -- that is not a green, it is a no-op");
    }

    /// ⭐ ROW EK, THE OTHER HALF OF THE DESIGN WORD: **a panicking test cannot
    /// poison the next one.**
    ///
    /// The guard snapshots on acquire and restores in `Drop`, and `Drop` runs
    /// while unwinding — so a test that panics half-way through counting leaves
    /// the counters exactly as it found them. Without that, the next test to
    /// take the lock inherits a partial count and fails for a reason that has
    /// nothing to do with it: one genuine failure reported as two, and the
    /// second one misleading.
    ///
    /// ⛔ AND THE LOCK MUST STILL BE TAKEABLE AFTERWARDS. A panic poisons a
    /// `Mutex`, and `.unwrap()` on a poisoned lock panics in turn — which would
    /// turn one failure into every subsequent test panicking at the lock line,
    /// nowhere near the defect. The second half of this arm is that the guard
    /// can still be acquired after the panic.
    #[test]
    fn a_panicking_test_restores_the_counters_and_leaves_the_lock_usable() {
        // The state the guard is supposed to hand back. Read under a guard,
        // which itself restores, so this observation cannot disturb it.
        let pre = { let _g = serial(); read(Crossing::EngineNew) };

        let panicked = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _g = serial();
            reset();
            record(Crossing::EngineNew, 7, 11);
            // ⛔ THE CONTROL: the write really happened, so the restore below is
            // undoing something rather than finding nothing to undo.
            assert_eq!(read(Crossing::EngineNew), (1, 7, 11));
            panic!("a test failing mid-count");
        }));
        assert!(panicked.is_err(), "the closure must actually have panicked");

        // ⛔ AND THE LOCK IS STILL TAKEABLE. A panic poisons a Mutex; taking it
        // with `.unwrap()` would panic in turn, turning one failure into every
        // later test dying at the lock line. This call is that half of the arm.
        let _g = serial();
        assert_eq!(read(Crossing::EngineNew), pre,
                   "Drop ran while unwinding and put back what it snapshotted");
    }

    #[test]
    fn a_fresh_counter_reads_zero() {
        let _g = serial();
        reset();
        for c in Crossing::ALL {
            assert_eq!(read(c), (0, 0, 0), "{} should start at zero", c.name());
        }
    }

    #[test]
    fn record_increments_exactly_one_function() {
        let _g = serial();
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
        let _g = serial();
        reset();
        record(Crossing::DispatchEvent, 10, 0);
        record(Crossing::DispatchEvent, 5, 0);
        assert_eq!(read(Crossing::DispatchEvent), (2, 15, 0));
    }

    #[test]
    fn reset_zeroes_a_used_counter() {
        let _g = serial();
        reset();
        record(Crossing::Version, 0, 99);
        assert_eq!(read(Crossing::Version).0, 1);
        reset();
        assert_eq!(read(Crossing::Version), (0, 0, 0));
    }

    #[test]
    fn snapshot_names_every_function_and_totals_agree() {
        let _g = serial();
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
        assert!(
            js.contains("\"surface\":\"main@22e5e30e+jas_bind_values+jas_panel_event\""),
            "{js}"
        );

        // ⛔ The engine counters are reported and are NOT in the surface. Both
        // halves asserted: present, and excluded from `crossings`. A dump that
        // folded them in would let apparatus inflate the figure it measures.
        assert!(js.contains("\"engine\":{\"rows_evaluated\":0"), "{js}");
        assert!(js.contains("\"crossings\":2"), "engine work is not a crossing: {js}");
        assert!(!js.contains("\"fn\":\"rows_evaluated\""), "{js}");
    }

    /// The engine counters count, reset with the crossings, and are readable —
    /// the same three claims the per-function counters carry, because gate ⑤
    /// leans on this number and an untested counter is a number nobody checked.
    #[test]
    fn engine_counters_record_reset_and_stay_out_of_the_surface() {
        let _g = serial();
        reset();
        assert_eq!(read_engine(), (0, 0, 0));
        record_engine(120, 2);
        record_engine(120, 2);
        assert_eq!(read_engine(), (240, 4, 2), "two ticks accumulate");

        // A NEGATIVE arm: recording engine work must not move any crossing.
        let js = snapshot_json();
        assert!(js.contains("\"crossings\":0"), "{js}");
        assert!(js.contains("\"rows_evaluated\":240,\"panels_evaluated\":4,\"ticks\":2"), "{js}");

        reset();
        assert_eq!(read_engine(), (0, 0, 0), "reset clears them WITH the crossings");
    }

    #[test]
    fn names_are_in_discriminant_order() {
        // The dump indexes NAMES by discriminant. If the two drift, every row in
        // every published chatter table is silently mislabelled -- the numbers
        // stay right and the attribution goes wrong, which is the harder error to
        // spot in a table that looks reasonable.
        for (i, c) in Crossing::ALL.into_iter().enumerate() {
            assert_eq!(c as usize, i, "ALL must be in discriminant order");
            assert_eq!(c.name(), Crossing::NAMES[i]);
        }
        assert_eq!(Crossing::BindValues.name(), "jas_bind_values");
        assert_eq!(Crossing::ALL.len(), Crossing::COUNT);
    }
}
