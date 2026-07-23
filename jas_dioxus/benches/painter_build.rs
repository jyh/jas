//! R10 de-risking-spike bench (spike deliverable #6).
//!
//! Measures the cost of BUILDING a scene through the `Painter` seam with
//! rendering subtracted out, by driving the synthetic scene into
//! [`NoOpPainter`] (a do-nothing sink). This makes R10 concrete — the refuter
//! called the v1 benchmark "theater" because it measured nothing reproducible;
//! this is a native, CI-reproducible number for scene-build cost, which the
//! ≤10% perf budget is stated against.
//!
//! Custom harness (no criterion) so `cargo test` stays lean. Run with:
//!   cargo bench --bench painter_build
//!
//! It reports ns per scene-build and ns per Painter call at a couple of scene
//! sizes, plus the RecordingPainter overhead (build + record) for context. It
//! does NOT measure whole-frame rendering — that is a browser-side manual
//! spot-measure (R10), explicitly out of scope here.

use std::hint::black_box;
use std::time::Instant;

use jas_dioxus::painter::recording::RecordingPainter;
use jas_dioxus::painter::scene::build_synthetic_scene;
use jas_dioxus::painter::sink::NoOpPainter;

/// Calls emitted per synthetic scene of size `n`: 6 per iteration + 4 framing
/// (push_state/push_group/pop_group/pop_state).
fn calls_for(n: usize) -> u64 {
    (6 * n + 4) as u64
}

fn bench_noop(n: usize, reps: usize) -> (f64, u64) {
    // Warm up.
    {
        let mut sink = NoOpPainter::new();
        build_synthetic_scene(&mut sink, n);
        black_box(sink.calls);
    }
    let start = Instant::now();
    let mut total_calls = 0u64;
    for _ in 0..reps {
        let mut sink = NoOpPainter::new();
        build_synthetic_scene(black_box(&mut sink), black_box(n));
        total_calls = total_calls.wrapping_add(black_box(sink.calls));
    }
    let elapsed = start.elapsed();
    let per_build_ns = elapsed.as_nanos() as f64 / reps as f64;
    (per_build_ns, total_calls)
}

fn bench_recording(n: usize, reps: usize) -> f64 {
    {
        let mut rec = RecordingPainter::new();
        build_synthetic_scene(&mut rec, n);
        black_box(rec.commands().len());
    }
    let start = Instant::now();
    for _ in 0..reps {
        let mut rec = RecordingPainter::new();
        build_synthetic_scene(black_box(&mut rec), black_box(n));
        black_box(rec.commands().len());
    }
    start.elapsed().as_nanos() as f64 / reps as f64
}

fn main() {
    println!("painter scene-build bench (NoOpPainter sink) — R10 first number");
    println!("{:>8} {:>12} {:>14} {:>16} {:>16}", "N", "calls", "build (us)", "ns/call (noop)", "ns/call (record)");

    for &(n, reps) in &[(1_000usize, 2_000usize), (10_000usize, 300usize), (50_000usize, 60usize)] {
        let (noop_ns, calls_seen) = bench_noop(n, reps);
        let rec_ns = bench_recording(n, reps);
        let expected = calls_for(n) * reps as u64;
        assert_eq!(calls_seen, expected, "sink call count mismatch (build loop elided?)");

        let calls = calls_for(n) as f64;
        println!(
            "{:>8} {:>12} {:>14.2} {:>16.2} {:>16.2}",
            n,
            calls_for(n),
            noop_ns / 1_000.0,
            noop_ns / calls,
            rec_ns / calls,
        );
    }

    println!();
    println!("Interpretation: 'ns/call (noop)' is the pure per-op build/traversal");
    println!("cost the perf budget rides on; 'ns/call (record)' adds the golden");
    println!("materialization overhead (test-only, never in production).");
}
