// The harness behind the PINCH_MAP_THRESHOLD table in
// jas_dioxus/src/algorithms/boolean.rs (and its twin table in
// JasSwift/Sources/Algorithms/Boolean.swift). Standalone and NOT wired to
// any build or gate: it exists so a reader can re-derive the numbers that
// doc asserts instead of trusting them. `PinchBench.swift` beside it is
// the Swift half.
//
// It COPIES the two `first_repeated_vertex` bodies as boolean.rs spells
// them rather than importing them, so that it can be compiled alone;
// if those bodies change, change these too or the table stops meaning
// anything.
//
// Build and run: rustc -O pinch_bench.rs -o pinch_bench && ./pinch_bench
//
// Discipline: pinch-free rings (both bodies must scan to the end),
// `black_box` on BOTH the argument and the result, per-case calibration
// to >=100ms of work, best-of-5 timed repeats.

use std::collections::HashMap;
use std::hint::black_box;
use std::time::Instant;

type Ring = Vec<(f64, f64)>;

fn vertex_key(v: &(f64, f64)) -> Option<(u64, u64)> {
    if v.0.is_nan() || v.1.is_nan() {
        return None;
    }
    Some(((v.0 + 0.0).to_bits(), (v.1 + 0.0).to_bits()))
}

fn first_repeated_vertex_scan(ring: &Ring) -> Option<(usize, usize)> {
    for j in 1..ring.len() {
        for i in 0..j {
            if ring[i] == ring[j] {
                return Some((i, j));
            }
        }
    }
    None
}

fn first_repeated_vertex_map(ring: &Ring) -> Option<(usize, usize)> {
    let mut seen: HashMap<(u64, u64), usize> = HashMap::with_capacity(ring.len());
    for (j, v) in ring.iter().enumerate() {
        let Some(key) = vertex_key(v) else { continue };
        match seen.get(&key) {
            Some(&i) => return Some((i, j)),
            None => {
                seen.insert(key, j);
            }
        }
    }
    None
}

/// The harness floor: same call shape, no work. Whatever this costs is
/// black_box + call overhead, not algorithm.
fn noop(ring: &Ring) -> Option<(usize, usize)> {
    if ring.is_empty() {
        Some((0, 0))
    } else {
        None
    }
}

/// A pinch-free ring of `n` distinct vertices on a circle.
fn ring_of(n: usize) -> Ring {
    (0..n)
        .map(|k| {
            let t = (k as f64) * std::f64::consts::TAU / (n as f64);
            (100.0 * t.cos(), 100.0 * t.sin())
        })
        .collect()
}

fn time_once(f: fn(&Ring) -> Option<(usize, usize)>, ring: &Ring, iters: u64) -> f64 {
    let t = Instant::now();
    for _ in 0..iters {
        black_box(f(black_box(ring)));
    }
    t.elapsed().as_secs_f64()
}

/// Seconds per call, best of 5, after calibrating `iters` to >=100ms.
fn bench(f: fn(&Ring) -> Option<(usize, usize)>, ring: &Ring) -> f64 {
    let mut iters: u64 = 64;
    loop {
        let s = time_once(f, ring, iters);
        if s >= 0.1 || iters > 1 << 34 {
            break;
        }
        iters *= 4;
    }
    let mut best = f64::INFINITY;
    for _ in 0..5 {
        let per = time_once(f, ring, iters) / iters as f64;
        if per < best {
            best = per;
        }
    }
    best
}

fn fmt(sec: f64) -> String {
    if sec < 1e-6 {
        format!("{:.1} ns", sec * 1e9)
    } else {
        format!("{:.2} us", sec * 1e6)
    }
}

fn main() {
    // Sanity: both bodies must agree that these rings are pinch-free.
    for n in [4usize, 64, 128, 256, 4096] {
        let r = ring_of(n);
        assert_eq!(first_repeated_vertex_scan(&r), None, "n={n} scan");
        assert_eq!(first_repeated_vertex_map(&r), None, "n={n} map");
    }
    let floor = bench(noop, &ring_of(4));
    println!("harness floor (noop call, black_box both sides): {}", fmt(floor));
    println!("{:>6} | {:>10} | {:>10} | {:>10}", "n", "scan", "map", "map/scan");
    for n in [4usize, 64, 127, 128, 256, 4096] {
        let r = ring_of(n);
        let s = bench(first_repeated_vertex_scan, &r);
        let m = bench(first_repeated_vertex_map, &r);
        println!(
            "{:>6} | {:>10} | {:>10} | {:>9.1}x",
            n,
            fmt(s),
            fmt(m),
            m / s
        );
    }
    // Crossover: smallest n at which the map is at least as fast.
    let mut cross = None;
    for n in (8..=400).step_by(4) {
        let r = ring_of(n);
        if bench(first_repeated_vertex_map, &r) <= bench(first_repeated_vertex_scan, &r) {
            cross = Some(n);
            break;
        }
    }
    println!("crossover (map first wins), step 4: {:?}", cross);
}
