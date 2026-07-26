// The Swift half of the harness behind the pinchMapThreshold table in
// JasSwift/Sources/Algorithms/Boolean.swift (and its twin in
// jas_dioxus/src/algorithms/boolean.rs). Standalone and NOT wired to any
// build or gate: it exists so a reader can re-derive the numbers that doc
// asserts instead of trusting them. `pinch_bench.rs` beside it is the
// Rust half.
//
// It COPIES the two `firstRepeatedVertex` bodies as Boolean.swift spells
// them rather than importing them, so that it can be compiled alone;
// if those bodies change, change these too or the table stops meaning
// anything.
//
// Build and run: swiftc -O PinchBench.swift -o pb && ./pb
//
// Same discipline as the Rust harness: pinch-free rings, an opaque
// barrier on BOTH the argument and the result (`@inline(never)`, Swift's
// nearest equivalent of `black_box`), per-case calibration to >=100ms,
// best-of-5 timed repeats, and a measured harness floor.

import Foundation

typealias BoolRing = [(Double, Double)]

struct BoolVertexKey: Hashable {
    let x: UInt64
    let y: UInt64
    init?(_ v: (Double, Double)) {
        if v.0.isNaN || v.1.isNaN { return nil }
        x = (v.0 + 0.0).bitPattern
        y = (v.1 + 0.0).bitPattern
    }
}

func firstRepeatedVertexScan(_ ring: BoolRing) -> (Int, Int)? {
    guard ring.count > 1 else { return nil }
    for j in 1..<ring.count {
        for i in 0..<j {
            if ring[i] == ring[j] { return (i, j) }
        }
    }
    return nil
}

func firstRepeatedVertexMap(_ ring: BoolRing) -> (Int, Int)? {
    var seen: [BoolVertexKey: Int] = [:]
    seen.reserveCapacity(ring.count)
    for (j, v) in ring.enumerated() {
        guard let key = BoolVertexKey(v) else { continue }
        if let i = seen[key] { return (i, j) }
        seen[key] = j
    }
    return nil
}

/// The harness floor: same call shape, no work.
func noopBody(_ ring: BoolRing) -> (Int, Int)? {
    ring.isEmpty ? (0, 0) : nil
}

// Swift has no `std::hint::black_box`. `@inline(never) func sink<T>(_: T) {}`
// is NOT enough: the optimizer does dead-argument elimination on a body it
// can see ignore its argument, after which the whole timed loop folds away
// (the first version of this harness measured 0.0 ns for the scan at every
// n). So the result barrier accumulates into a global -- an observable side
// effect that cannot be removed -- and the argument barrier returns its
// argument through a global-dependent branch so the call cannot be hoisted
// out of the loop.
var globalSink: Int = 0
var globalZero: Int = 0

@inline(never) func sink(_ value: (Int, Int)?) {
    if let v = value { globalSink &+= v.0 &+ v.1 } else { globalSink &+= 1 }
}
@inline(never) func opaque(_ ring: BoolRing) -> BoolRing {
    globalZero == 0 ? ring : []
}

func ringOf(_ n: Int) -> BoolRing {
    (0..<n).map { k in
        let t = Double(k) * 2.0 * Double.pi / Double(n)
        return (100.0 * cos(t), 100.0 * sin(t))
    }
}

func timeOnce(_ f: (BoolRing) -> (Int, Int)?, _ ring: BoolRing, _ iters: Int) -> Double {
    let t0 = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iters {
        sink(f(opaque(ring)))
    }
    let t1 = DispatchTime.now().uptimeNanoseconds
    return Double(t1 - t0) / 1e9
}

/// Seconds per call, best of 5, after calibrating `iters` to >=100ms.
func bench(_ f: (BoolRing) -> (Int, Int)?, _ ring: BoolRing) -> Double {
    var iters = 64
    while true {
        if timeOnce(f, ring, iters) >= 0.1 || iters > 1 << 30 { break }
        iters *= 4
    }
    var best = Double.infinity
    for _ in 0..<5 {
        best = min(best, timeOnce(f, ring, iters) / Double(iters))
    }
    return best
}

func fmt(_ sec: Double) -> String {
    sec < 1e-6 ? String(format: "%.1f ns", sec * 1e9)
               : String(format: "%.2f us", sec * 1e6)
}

for n in [4, 64, 127, 128, 256, 4096] {
    precondition(firstRepeatedVertexScan(ringOf(n)) == nil, "n=\(n) scan")
    precondition(firstRepeatedVertexMap(ringOf(n)) == nil, "n=\(n) map")
}
print("harness floor (noop call, barrier both sides): \(fmt(bench(noopBody, ringOf(4))))")
print("     n |       scan |        map |  map/scan")
for n in [4, 64, 127, 128, 256, 4096] {
    let r = ringOf(n)
    let s = bench(firstRepeatedVertexScan, r)
    let m = bench(firstRepeatedVertexMap, r)
    print(String(format: "%6d | %10@ | %10@ | %8.1fx", n, fmt(s) as NSString,
                 fmt(m) as NSString, m / s))
}
var cross: Int? = nil
for n in stride(from: 8, through: 400, by: 4) {
    let r = ringOf(n)
    if bench(firstRepeatedVertexMap, r) <= bench(firstRepeatedVertexScan, r) {
        cross = n
        break
    }
}
print("crossover (map first wins), step 4: \(String(describing: cross))")
print("(sink checksum, ignore: \(globalSink))")
