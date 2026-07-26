//! Ring normalizer: turn an arbitrary (possibly self-intersecting)
//! polygon set into the **canonical** set of simple rings that bounds
//! the same region — reading the input under the fill rule it
//! **carries**.
//!
//! # What this is for
//!
//! The boolean operations in [`crate::algorithms::boolean`] assume
//! simple (non-self-intersecting) input rings. User-drawn input —
//! pen-tool paths, imported SVG with `fill-rule="nonzero"` — is often
//! self-intersecting, either deliberately (figure-8, ribbon knots) or
//! accidentally (sloppy click). This module is the pre-pass that
//! takes such input and returns an equivalent simple-ring
//! representation, so the boolean code can stay single-purpose.
//!
//! # Input contract: THE CARRIED RULE (JYH-ratified 2026-07-26)
//!
//! [`normalize`] takes rings **and the [`PolyFillRule`] that reads
//! them**. It does not assume one, and there is no rule-less entry
//! point, because the two rules denote genuinely different regions and
//! only the caller — who knows whether these rings came from a
//! `fill-rule="nonzero"` path, a `fill-rule="evenodd"` path or a
//! machine-made boolean result — can say which was meant. See
//! [`crate::algorithms::boolean`]'s module docs for the full law and
//! the reasoning behind it; this module states only the half it
//! implements.
//!
//! The rule applies to the **whole set at once**, exactly as SVG and
//! PDF define it: insideness is decided from the crossings/windings of
//! every ring together, not ring by ring. Concretely:
//!
//! - **`NonZero`** — a point is filled iff the winding summed over all
//!   rings is non-zero. Two nested same-orientation rings are a
//!   *solid*; two overlapping same-orientation rings are their
//!   *union*; a counter-wound inner ring is a hole. This is
//!   inter-ring winding cancellation, and it is now implemented rather
//!   than deferred — with the rule carried it is no longer us choosing
//!   a semantics, it is doing what the artist's path says.
//! - **`EvenOdd`** — a point is filled iff a ray crosses the rings an
//!   odd number of times. Two nested rings are a *hole* whatever their
//!   orientations; two overlapping rings are their *symmetric
//!   difference*. Because even-odd parity is additive across rings
//!   (the parity of the whole is the XOR of the parts), resolving each
//!   ring alone and concatenating is *exactly* the set-wide answer —
//!   which is why the even-odd path here is still a per-ring loop, and
//!   why simple rings pass through untouched however they nest.
//!
//! # Output contract: canonical means EVEN-ODD-correct
//!
//! The returned rings are simple, and they denote the input's region
//! **read under the even-odd rule** — whatever rule the input carried.
//! That is the canonical form: the carried rule has been consumed, and
//! the sweep, the renderer and the corpus can all read the output as
//! even-odd without lying about the input. It is also what
//! `apply_destructive_boolean` relies on when it stamps
//! `FillRule::EvenOdd` on a multi-ring result.
//!
//! Two shades of it, worth stating exactly because the difference is
//! observable:
//!
//! - Input `NonZero` — the whole set is rebuilt, so the output is
//!   additionally *pairwise non-overlapping*, and its even-odd and
//!   non-zero readings coincide.
//! - Input `EvenOdd` — rings that are already even-odd-correct are
//!   returned as given, so two of them may still overlap (their
//!   even-odd reading, the symmetric difference, is the point). Do not
//!   re-read such an output as non-zero.
//!
//! The output rings of a rebuilt ring are simple and pairwise
//! non-overlapping, oriented so the filled side is on the left: outer
//! boundaries counter-clockwise (positive signed area) and hole
//! boundaries clockwise (negative signed area). Collinear vertices are
//! **retained** — collapsing them is the Boolean panel's separate
//! "Remove Redundant Points" option, which defaults to off (see
//! `transcripts/BOOLEAN.md`).
//!
//! # Two paths
//!
//! **Fast path.** If the input is already canonical *under its carried
//! rule* — no two edges meet except where consecutive edges of one
//! ring share their vertex, and every ring really bounds a filled/
//! unfilled transition when read under that rule — it is returned
//! unchanged, orientation included. This is the common case, and
//! keeping it a literal pass-through is what lets
//! [`crate::algorithms::boolean`] call the normalizer on every operand
//! without perturbing non-degenerate results. Note the rule enters
//! even here: two nested same-orientation rings are canonical under
//! even-odd (a hole) and are *not* canonical under non-zero (a solid),
//! and [`is_already_normalized`] separates the two cases by asking
//! whether removing the ring's own contribution changes filled-ness.
//!
//! **Arrangement path.** Otherwise the region's boundary is
//! rebuilt from scratch:
//!
//!   1. Split every edge at every meeting with every other edge —
//!      proper crossings, T-junctions and collinear-overlap ends —
//!      using [`crate::algorithms::arrangement::split_points`]. The
//!      result is a *conforming* arrangement: no edge interior holds
//!      another edge's vertex, and no two edges overlap over a span.
//!   2. Reduce to the set of undirected **atomic spans**. Direction
//!      and multiplicity are deliberately discarded here: what matters
//!      is not how many times a span was traced but whether the region
//!      differs across it, and that is decided in step 3 from the
//!      windings on either side.
//!   3. Classify each span by the winding of the ORIGINAL rings just
//!      to its left and just to its right, **read under the carried
//!      rule** (`w != 0` for non-zero, `w` odd for even-odd — the one
//!      place the two paths differ). A span is part of the
//!      output boundary iff exactly one side is filled; it is then
//!      oriented with the filled side on its left. Spans with the
//!      same filled-ness on both sides are interior to the region or
//!      exterior to it and are dropped — which is precisely how
//!      collinear self-overlap, retrograde spans and inter-ring
//!      cancellation all resolve, without a special case for any of
//!      them.
//!   4. Chain the surviving directed spans into rings by always
//!      taking the first outgoing span **clockwise** from the
//!      reversal of the incoming one. That is the standard
//!      face-tracing rule and is what keeps two lobes meeting at a
//!      pinch vertex separate instead of fusing them.
//!
//! # Degenerate classes
//!
//! Each is pinned by a unit test with a hand-derived expected value
//! (shoelace sums written into the test), because these are *shared*
//! limitations: a differential comparison between the Rust and Swift
//! ports is blind to them — wrong-vs-wrong compares equal. The
//! cross-language corpus gates AGREEMENT; the unit tests gate
//! CORRECTNESS.
//!
//!   - **Proper self-intersection** (figure-8) — step 1's crossing.
//!   - **T-junction** — a ring passing through one of its own
//!     vertices, or two rings touching at a vertex. Step 1 now
//!     reports these; the old strict predicate required a strictly
//!     interior crossing on *both* edges and so missed them.
//!   - **Collinear self-overlap** — a ring retracing part of its own
//!     boundary. Step 1 splits at the overlap ends, step 3 drops the
//!     doubled span because the region is the same on both sides.
//!   - **Retrograde loops** — a subpath that reverses direction, or a
//!     counter-wound loop spliced into the outer boundary by a slit.
//!     The slit is dropped by step 3; the counter-wound loop survives
//!     as a hole (or vanishes) exactly as its winding dictates.
//!   - **Inter-ring winding cancellation** — resolved here, and by
//!     the carried rule alone. Under `NonZero` a nested or overlapping
//!     same-orientation ring cancels or merges exactly as its winding
//!     dictates (step 3 sees no filled-ness change across the inner
//!     boundary and drops it); under `EvenOdd` the very same input
//!     passes through as a hole. The pinning tests come in pairs, one
//!     per rule on one input, so the difference is the assertion.
//!
//! # Complexity
//!
//! O(n²) split scan plus O(E²) for the per-span winding sample (each
//! span needs the distance to every other span to size its probe
//! offset). Fine for user-drawn paths with at most a few hundred
//! edges; not intended for arbitrarily complex input. The fast path
//! costs one O(n²) scan and is what the common case pays.
//!
//! # Epsilon policy
//!
//! Inherited unchanged from [`crate::algorithms::arrangement`] for
//! everything about *whether* two edges meet. The one new tolerance
//! is the winding-probe offset of step 3: for a span of length `L`
//! whose midpoint is at distance `d` from the nearest other span, the
//! probe sits at `0.25 · min(L, d)` perpendicular to the span. Both
//! terms matter — `L` keeps the probe from sliding past the span's
//! own ends, `d` keeps it from crossing a neighbouring boundary — and
//! the 0.25 leaves a factor-of-four margin. The consequence to know:
//! geometry thinner than a quarter of the nearest feature is not
//! resolved, but nothing legitimately thin is *dropped*, because the
//! probe is always sized relative to the actual local feature size
//! rather than to a fixed absolute epsilon.

use crate::algorithms::arrangement::{
    add_or_find_vertex, dist, split_points, VERT_EPS,
};
use crate::algorithms::boolean::{PolyFillRule, PolygonSet, Ring};
use std::collections::BTreeSet;

/// Is a point with winding number `w` inside the region, under `rule`?
/// The whole difference between the two rules, in one function.
fn filled(w: i32, rule: PolyFillRule) -> bool {
    match rule {
        PolyFillRule::NonZero => w != 0,
        PolyFillRule::EvenOdd => w % 2 != 0,
    }
}

/// Normalize a polygon set read under `rule`: return the canonical
/// simple, pairwise non-overlapping rings bounding the same region.
///
/// `rule` is mandatory by design — see the module docs' carried-rule
/// contract. Callers that hold a document element pass its
/// `fill_rule`; callers holding a set this crate produced pass
/// [`PolyFillRule::EvenOdd`].
pub fn normalize(input: &PolygonSet, rule: PolyFillRule) -> PolygonSet {
    match rule {
        // Even-odd parity is additive across rings — the parity of the
        // whole set is the XOR of the per-ring parities — so resolving
        // each ring alone and concatenating IS the set-wide answer,
        // at a fraction of the cost (the arrangement is O(E^2) in the
        // edges handed to it, so n small sets beat one big one).
        PolyFillRule::EvenOdd => {
            let mut out: PolygonSet = Vec::new();
            for ring in input {
                out.extend(normalize_ring(ring, rule));
            }
            out
        }
        // Non-zero winding does NOT decompose: the winding at a point
        // is the sum over every ring, so nesting and overlap between
        // rings change the answer and the whole set must be resolved
        // together. This is inter-ring winding cancellation.
        PolyFillRule::NonZero => {
            let cleaned: PolygonSet = input
                .iter()
                .map(dedup_consecutive)
                .filter(|r| r.len() >= 3)
                .collect();
            if cleaned.is_empty() {
                return Vec::new();
            }
            if is_already_normalized(&cleaned, rule) {
                return cleaned;
            }
            rebuild_from_arrangement(&cleaned, rule)
        }
    }
}

/// Normalize a single ring. Returns 0, 1, or more simple rings.
fn normalize_ring(ring: &Ring, rule: PolyFillRule) -> Vec<Ring> {
    let cleaned = dedup_consecutive(ring);
    if cleaned.len() < 3 {
        return Vec::new();
    }
    // The two workers take a whole set so their geometry reads
    // naturally; here the set is always this one ring.
    let one: PolygonSet = vec![cleaned];
    if is_already_normalized(&one, rule) {
        return one;
    }
    rebuild_from_arrangement(&one, rule)
}

// ---------------------------------------------------------------------------
// Vertex cleanup
// ---------------------------------------------------------------------------

/// Remove consecutive duplicate vertices, including the wrap-around
/// duplicate if the ring closes back onto itself.
fn dedup_consecutive(ring: &Ring) -> Ring {
    let mut out: Ring = Vec::with_capacity(ring.len());
    for &p in ring {
        if out.last() != Some(&p) {
            out.push(p);
        }
    }
    while out.len() >= 2 && out.first() == out.last() {
        out.pop();
    }
    out
}

// ---------------------------------------------------------------------------
// Fast path: is the input already a well-formed polygon set?
// ---------------------------------------------------------------------------

/// One directed edge of one ring, tagged with where it came from so
/// the "legitimately adjacent" exemption can be checked.
struct TaggedEdge {
    a: (f64, f64),
    b: (f64, f64),
    ring: usize,
    edge: usize,
    ring_len: usize,
}

fn tagged_edges(rings: &PolygonSet) -> Vec<TaggedEdge> {
    let mut out = Vec::new();
    for (ri, ring) in rings.iter().enumerate() {
        let n = ring.len();
        for i in 0..n {
            out.push(TaggedEdge {
                a: ring[i],
                b: ring[(i + 1) % n],
                ring: ri,
                edge: i,
                ring_len: n,
            });
        }
    }
    out
}

/// True if `rings` already satisfies the normalizer's output contract,
/// so it can be returned untouched. Called with a one-ring set; written
/// against a set so the geometry reads naturally.
///
/// Two conditions, both necessary:
///
///   1. **No edge meets another** except where two consecutive edges of
///      the same ring share their one common vertex. Any other reported
///      meeting is a crossing, a T-junction, a pinch, or a collinear
///      overlap — all of which need the arrangement.
///   2. **Every ring really is a boundary, under `rule`.** At a point
///      just inside the ring, the filled-ness of the whole set must
///      differ from what it would be with this ring's own winding
///      removed — i.e. the ring changes the answer where it claims to
///      be a boundary. False for a degenerate zero-area ring, whose
///      "inside" is not filled either.
///
///      This is the check that carries the rule between rings, and it
///      is why the fast path is not merely "all rings simple". Two
///      nested counter-wound rings (the SVG way to draw a donut) pass
///      under *both* rules. Two nested same-orientation rings pass
///      under `EvenOdd` — inside the inner ring the total winding is
///      2 (even, unfilled) against 1 (odd, filled) without it, so the
///      inner ring is a real boundary and the hole is genuine — and
///      FAIL under `NonZero`, where 2 and 1 are both non-zero so the
///      inner ring bounds nothing and the arrangement must dissolve
///      it. Same geometry, different rule, different canonical form:
///      exactly the carried-rule law doing its job.
fn is_already_normalized(rings: &PolygonSet, rule: PolyFillRule) -> bool {
    let edges = tagged_edges(rings);
    for e in &edges {
        // A degenerate edge survived dedup only if two vertices differ
        // by less than VERT_EPS without being bit-equal. Hand it to the
        // arrangement rather than reasoning about it here.
        if dist(e.a, e.b) <= VERT_EPS {
            return false;
        }
    }
    for i in 0..edges.len() {
        for j in (i + 1)..edges.len() {
            let (p, q) = (&edges[i], &edges[j]);
            let pts = split_points(p.a, p.b, q.a, q.b);
            if pts.is_empty() {
                continue;
            }
            let same_ring = p.ring == q.ring;
            let n = p.ring_len;
            let consecutive = same_ring
                && ((q.edge + 1) % n == p.edge || (p.edge + 1) % n == q.edge);
            // Consecutive edges legitimately meet at exactly one
            // point: their shared vertex. Anything else — two points
            // (a collinear overlap), or a single point that is not an
            // endpoint of both — is a degeneracy.
            let shared_vertex_only = consecutive
                && pts.len() == 1
                && (pts[0].1 == 0.0 || pts[0].1 == 1.0)
                && (pts[0].2 == 0.0 || pts[0].2 == 1.0);
            if !shared_vertex_only {
                return false;
            }
        }
    }
    for ring in rings {
        let inside = sample_inside_simple_ring(ring);
        let w_all = winding_of_set(rings, inside);
        let w_self = winding_number(ring, inside);
        let w_without = w_all - w_self;
        if filled(w_all, rule) == filled(w_without, rule) {
            return false;
        }
    }
    true
}

// ---------------------------------------------------------------------------
// Arrangement path
// ---------------------------------------------------------------------------

/// Rebuild the boundary of the region `rings` denotes **under `rule`**
/// from a conforming arrangement of their edges. Called with a one-ring
/// set on the even-odd path and with the whole set on the non-zero
/// path; see the module docs for the four steps.
fn rebuild_from_arrangement(rings: &PolygonSet, rule: PolyFillRule) -> PolygonSet {
    // ----- 1. Conforming arrangement -----
    let mut segments: Vec<((f64, f64), (f64, f64))> = Vec::new();
    for ring in rings {
        let n = ring.len();
        for i in 0..n {
            let (a, b) = (ring[i], ring[(i + 1) % n]);
            if dist(a, b) > VERT_EPS {
                segments.push((a, b));
            }
        }
    }
    if segments.is_empty() {
        return Vec::new();
    }

    let mut vert_pts: Vec<(f64, f64)> = Vec::new();
    let mut seg_params: Vec<Vec<(f64, usize)>> = vec![Vec::new(); segments.len()];
    for (si, &(a, b)) in segments.iter().enumerate() {
        let va = add_or_find_vertex(&mut vert_pts, a);
        let vb = add_or_find_vertex(&mut vert_pts, b);
        seg_params[si].push((0.0, va));
        seg_params[si].push((1.0, vb));
    }
    for i in 0..segments.len() {
        for j in (i + 1)..segments.len() {
            let (a1, a2) = segments[i];
            let (b1, b2) = segments[j];
            for (p, s, t) in split_points(a1, a2, b1, b2) {
                let v = add_or_find_vertex(&mut vert_pts, p);
                seg_params[i].push((s, v));
                seg_params[j].push((t, v));
            }
        }
    }

    // ----- 2. Undirected atomic spans -----
    // Multiplicity and direction are dropped on purpose: see the
    // module docs. A BTreeSet also fixes the span order, which fixes
    // the output ring order — the Swift port iterates the same
    // sequence, so the two agree vertex for vertex.
    let mut span_set: BTreeSet<(usize, usize)> = BTreeSet::new();
    for params in seg_params.iter_mut() {
        params.sort_by(|a, b| {
            a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal)
        });
        let mut chain: Vec<usize> = Vec::new();
        for &(_, v) in params.iter() {
            if chain.last() != Some(&v) {
                chain.push(v);
            }
        }
        for w in chain.windows(2) {
            let (u, v) = (w[0], w[1]);
            if u != v {
                span_set.insert(if u < v { (u, v) } else { (v, u) });
            }
        }
    }
    let spans: Vec<(usize, usize)> = span_set.into_iter().collect();
    if spans.is_empty() {
        return Vec::new();
    }

    // ----- 3. Winding classification -----
    // Kept spans, each oriented so the filled region is on its left.
    let mut kept: Vec<(usize, usize)> = Vec::new();
    for (si, &(u, v)) in spans.iter().enumerate() {
        let (ax, ay) = vert_pts[u];
        let (bx, by) = vert_pts[v];
        let mx = (ax + bx) / 2.0;
        let my = (ay + by) / 2.0;
        let dx = bx - ax;
        let dy = by - ay;
        let len = (dx * dx + dy * dy).sqrt();
        if len <= VERT_EPS {
            continue;
        }
        // Probe offset: a quarter of the smaller of this span's length
        // and its midpoint's distance to the nearest other span, so the
        // probe cannot slide past this span's ends nor cross a
        // neighbouring boundary. See the module docs.
        let mut nearest = f64::INFINITY;
        for (sj, &(p, q)) in spans.iter().enumerate() {
            if sj == si {
                continue;
            }
            let d = point_segment_distance((mx, my), vert_pts[p], vert_pts[q]);
            if d < nearest {
                nearest = d;
            }
        }
        let limit = if nearest.is_finite() && nearest > 0.0 && nearest < len {
            nearest
        } else {
            len
        };
        let offset = 0.25 * limit;
        // Unit left normal of u -> v.
        let nx = -dy / len;
        let ny = dx / len;
        let w_left = winding_of_set(rings, (mx + nx * offset, my + ny * offset));
        let w_right = winding_of_set(rings, (mx - nx * offset, my - ny * offset));
        let left_filled = filled(w_left, rule);
        let right_filled = filled(w_right, rule);
        if left_filled == right_filled {
            continue; // interior to the region, or exterior to it
        }
        if left_filled {
            kept.push((u, v));
        } else {
            kept.push((v, u));
        }
    }
    if kept.is_empty() {
        return Vec::new();
    }

    // ----- 4. Chain into rings -----
    // Per-vertex outgoing kept spans, sorted counter-clockwise by
    // direction angle.
    let mut outgoing: Vec<Vec<usize>> = vec![Vec::new(); vert_pts.len()];
    for (ki, &(u, _)) in kept.iter().enumerate() {
        outgoing[u].push(ki);
    }
    let angle_of = |ki: usize| -> f64 {
        let (u, v) = kept[ki];
        let (ax, ay) = vert_pts[u];
        let (bx, by) = vert_pts[v];
        (by - ay).atan2(bx - ax)
    };
    for list in outgoing.iter_mut() {
        list.sort_by(|&a, &b| {
            angle_of(a)
                .partial_cmp(&angle_of(b))
                .unwrap_or(std::cmp::Ordering::Equal)
        });
    }

    let mut used = vec![false; kept.len()];
    let mut out: PolygonSet = Vec::new();
    for start in 0..kept.len() {
        if used[start] {
            continue;
        }
        let mut ring: Ring = Vec::new();
        let mut e = start;
        loop {
            used[e] = true;
            ring.push(vert_pts[kept[e].0]);
            let v = kept[e].1;
            // Angle looking back along the edge we just travelled.
            let (ox, oy) = vert_pts[kept[e].0];
            let (vx, vy) = vert_pts[v];
            let back = (oy - vy).atan2(ox - vx);
            let list = &outgoing[v];
            if list.is_empty() {
                break;
            }
            // First span clockwise from `back`: the largest angle
            // strictly below it, wrapping to the largest overall.
            let mut pick = list[list.len() - 1];
            for &cand in list.iter() {
                if angle_of(cand) < back {
                    pick = cand;
                } else {
                    break;
                }
            }
            if pick == start {
                break;
            }
            if used[pick] {
                // Defensive: a well-formed region boundary never
                // revisits a span, so this cannot fire for valid
                // input. Bail rather than spin.
                break;
            }
            e = pick;
        }
        let ring = dedup_consecutive(&ring);
        if ring.len() >= 3 {
            out.push(ring);
        }
    }
    out
}

// ---------------------------------------------------------------------------
// Winding and sampling
// ---------------------------------------------------------------------------

/// Winding number of `ring` around `point`: signed count of ring
/// edges crossed by a horizontal ray from `point` in the +x
/// direction, where each upward-crossing edge counts +1 and each
/// downward-crossing edge counts −1.
fn winding_number(ring: &Ring, point: (f64, f64)) -> i32 {
    let n = ring.len();
    if n < 3 {
        return 0;
    }
    let (px, py) = point;
    let mut w: i32 = 0;
    for i in 0..n {
        let (x1, y1) = ring[i];
        let (x2, y2) = ring[(i + 1) % n];
        // Half-open rule to avoid double-counting when the ray
        // passes exactly through a vertex.
        let upward = y1 <= py && y2 > py;
        let downward = y2 <= py && y1 > py;
        if !upward && !downward {
            continue;
        }
        // x-coordinate where the edge crosses y = py.
        let t = (py - y1) / (y2 - y1);
        let x_cross = x1 + t * (x2 - x1);
        if x_cross > px {
            if upward {
                w += 1;
            } else {
                w -= 1;
            }
        }
    }
    w
}

/// Total winding of a whole polygon set: the sum over its rings. This
/// is the definition of the input's filled region under the non-zero
/// rule, and the only thing the arrangement path consults.
fn winding_of_set(rings: &PolygonSet, point: (f64, f64)) -> i32 {
    rings.iter().map(|r| winding_number(r, point)).sum()
}

/// Distance from `p` to the segment `a`-`b` (clamped at the ends).
fn point_segment_distance(p: (f64, f64), a: (f64, f64), b: (f64, f64)) -> f64 {
    let dx = b.0 - a.0;
    let dy = b.1 - a.1;
    let len2 = dx * dx + dy * dy;
    if len2 <= 0.0 {
        return dist(p, a);
    }
    let mut t = ((p.0 - a.0) * dx + (p.1 - a.1) * dy) / len2;
    if t < 0.0 {
        t = 0.0;
    } else if t > 1.0 {
        t = 1.0;
    }
    dist(p, (a.0 + t * dx, a.1 + t * dy))
}

/// Pick a point guaranteed to be strictly inside a simple ring.
///
/// Strategy: offset the midpoint of the ring's first edge by a small
/// distance perpendicular to that edge, on the interior side. The
/// interior side is determined by checking which of the two offsets
/// has a non-zero winding number in the ring itself.
fn sample_inside_simple_ring(ring: &Ring) -> (f64, f64) {
    let n = ring.len();
    debug_assert!(n >= 3);
    let (x0, y0) = ring[0];
    let (x1, y1) = ring[1];
    let mx = (x0 + x1) / 2.0;
    let my = (y0 + y1) / 2.0;
    let dx = x1 - x0;
    let dy = y1 - y0;
    let len = (dx * dx + dy * dy).sqrt();
    if len == 0.0 {
        // Degenerate edge; fall back to the centroid of the first three
        // vertices. Not robust in general but handles well-formed input.
        let (x2, y2) = ring[2];
        return ((x0 + x1 + x2) / 3.0, (y0 + y1 + y2) / 3.0);
    }
    // Unit perpendicular pointing "left" of the edge direction.
    let nx = -dy / len;
    let ny = dx / len;
    // Offset distance: a small fraction of the edge length. Needs to
    // be large enough to land strictly inside one cell of the ring,
    // small enough not to land outside.
    let offset = len * 1e-4;
    let left = (mx + nx * offset, my + ny * offset);
    let right = (mx - nx * offset, my - ny * offset);
    if winding_number(ring, left) != 0 {
        left
    } else {
        right
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn ring_signed_area(ring: &Ring) -> f64 {
        let mut sum = 0.0;
        let n = ring.len();
        for i in 0..n {
            let (x1, y1) = ring[i];
            let (x2, y2) = ring[(i + 1) % n];
            sum += x1 * y2 - x2 * y1;
        }
        sum / 2.0
    }

    fn total_area(ps: &PolygonSet) -> f64 {
        ps.iter().map(|r| ring_signed_area(r).abs()).sum()
    }

    /// Rotate a ring so its lexicographically smallest vertex comes
    /// first, without changing the cyclic order. Lets a test pin an
    /// exact vertex sequence without also pinning which vertex the
    /// traversal happened to start at.
    fn canonical(ring: &Ring) -> Ring {
        let n = ring.len();
        let mut best = 0usize;
        for i in 1..n {
            let (bx, by) = ring[best];
            let (x, y) = ring[i];
            if x < bx || (x == bx && y < by) {
                best = i;
            }
        }
        (0..n).map(|k| ring[(best + k) % n]).collect()
    }

    /// The signed areas of a normalizer result, sorted ascending.
    /// Negative entries are hole boundaries (CW), positive ones are
    /// outer boundaries (CCW).
    fn signed_areas(ps: &PolygonSet) -> Vec<f64> {
        let mut v: Vec<f64> = ps.iter().map(ring_signed_area).collect();
        v.sort_by(|a, b| a.partial_cmp(b).unwrap());
        v
    }

    /// True if no two non-adjacent edges of `ring` meet — i.e. the
    /// ring is simple, which is the normalizer's whole contract.
    fn is_simple(ring: &Ring) -> bool {
        let n = ring.len();
        for i in 0..n {
            for j in (i + 1)..n {
                let adjacent = j == i + 1 || (i == 0 && j == n - 1);
                let pts = crate::algorithms::arrangement::split_points(
                    ring[i],
                    ring[(i + 1) % n],
                    ring[j],
                    ring[(j + 1) % n],
                );
                if adjacent {
                    // Consecutive edges legitimately meet at exactly
                    // their shared vertex, and nowhere else.
                    if pts.len() != 1 {
                        return false;
                    }
                } else if !pts.is_empty() {
                    return false;
                }
            }
        }
        true
    }

    // ----------- Simple rings (pass through) -----------

    #[test]
    fn simple_square_passes_through() {
        let input: PolygonSet = vec![vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]];
        let out = normalize(&input, PolyFillRule::NonZero);
        assert_eq!(out.len(), 1);
        assert!((total_area(&out) - 100.0).abs() < 1e-9);
    }

    #[test]
    fn simple_triangle_passes_through() {
        let input: PolygonSet = vec![vec![(0.0, 0.0), (10.0, 0.0), (5.0, 10.0)]];
        let out = normalize(&input, PolyFillRule::NonZero);
        assert_eq!(out.len(), 1);
        assert!((total_area(&out) - 50.0).abs() < 1e-9);
    }

    #[test]
    fn cw_square_passes_through_preserving_signed_area() {
        // A CW square (negative signed area). A lone CW ring is a
        // well-formed polygon set — its winding is -1 inside and 0
        // outside, so its boundary IS the boundary of the filled
        // region — and so it takes the fast path and comes back
        // untouched, sign included.
        let input: PolygonSet = vec![vec![(0.0, 0.0), (0.0, 10.0), (10.0, 10.0), (10.0, 0.0)]];
        let out = normalize(&input, PolyFillRule::NonZero);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0], input[0]);
        assert!((signed_areas(&out)[0] + 100.0).abs() < 1e-9);
        assert!((total_area(&out) - 100.0).abs() < 1e-9);
    }

    // ----------- Degenerate input -----------

    #[test]
    fn empty_input_yields_empty_output() {
        let input: PolygonSet = vec![];
        let out = normalize(&input, PolyFillRule::NonZero);
        assert!(out.is_empty());
    }

    #[test]
    fn ring_with_fewer_than_three_vertices_is_dropped() {
        let input: PolygonSet = vec![vec![(0.0, 0.0), (10.0, 0.0)]];
        let out = normalize(&input, PolyFillRule::NonZero);
        assert!(out.is_empty());
    }

    #[test]
    fn ring_with_consecutive_duplicates_is_deduped() {
        let input: PolygonSet = vec![vec![
            (0.0, 0.0),
            (0.0, 0.0),
            (10.0, 0.0),
            (10.0, 10.0),
            (10.0, 10.0),
            (0.0, 10.0),
        ]];
        let out = normalize(&input, PolyFillRule::NonZero);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].len(), 4);
        assert!((total_area(&out) - 100.0).abs() < 1e-9);
    }

    #[test]
    fn ring_collapsing_to_single_point_is_dropped() {
        let input: PolygonSet = vec![vec![(5.0, 5.0), (5.0, 5.0), (5.0, 5.0), (5.0, 5.0)]];
        let out = normalize(&input, PolyFillRule::NonZero);
        assert!(out.is_empty());
    }

    // ----------- Single self-intersection -----------

    #[test]
    fn figure_eight_becomes_two_simple_triangles() {
        // Classic bowtie: the two diagonals cross at (5, 5).
        // Input visit order: (0,0) -> (10,10) -> (10,0) -> (0,10) -> close.
        // Edges (0,0)-(10,10) and (10,0)-(0,10) cross at (5,5).
        let input: PolygonSet =
            vec![vec![(0.0, 0.0), (10.0, 10.0), (10.0, 0.0), (0.0, 10.0)]];
        let out = normalize(&input, PolyFillRule::NonZero);
        assert_eq!(out.len(), 2, "figure-8 should split into two triangles: {:?}", out);
        // Both triangles have area 25.
        let total = total_area(&out);
        assert!(
            (total - 50.0).abs() < 1e-9,
            "expected total area 50, got {} (rings: {:?})",
            total,
            out
        );
        // Each ring should have exactly 3 distinct vertices.
        for r in &out {
            assert_eq!(r.len(), 3, "expected triangle, got {:?}", r);
        }
    }

    // ----------- Degenerate class: T-junction self-touch -----------

    #[test]
    fn t_junction_self_intersection() {
        // The same bowtie as above, but with (5,5) made an explicit
        // VERTEX of the ring rather than an interior crossing point:
        //   (0,0) -> (5,5) -> (10,10) -> (10,0) -> (0,10) -> close.
        // The edge (10,0)-(0,10) now passes exactly through the ring's
        // own vertex (5,5). The old predicate demanded a strictly
        // interior parameter on BOTH edges, so it saw nothing, called
        // the pentagon simple and returned it whole.
        //
        // Derivation: inserting a vertex on a straight edge cannot
        // change the region, so the answer must be identical to the
        // bowtie's — the two lobes
        //   left  (0,0),(5,5),(0,10): 2A = 0*5-5*0 + 5*10-0*5
        //                                  + 0*0-0*10 = 50 -> +25
        //   right (5,5),(10,0),(10,10): 2A = 5*0-10*5 + 10*10-10*0
        //                                  + 10*5-5*10 = 50 -> +25
        // Both lobes are filled (winding +1 on the left, -1 on the
        // right of the original), so both survive, and both come out
        // CCW because the normalizer orients the filled side left.
        let input: PolygonSet = vec![vec![
            (0.0, 0.0),
            (5.0, 5.0),
            (10.0, 10.0),
            (10.0, 0.0),
            (0.0, 10.0),
        ]];
        let out = normalize(&input, PolyFillRule::NonZero);
        assert_eq!(out.len(), 2, "expected two lobes, got {:?}", out);
        let areas = signed_areas(&out);
        assert!((areas[0] - 25.0).abs() < 1e-9, "areas: {:?}", areas);
        assert!((areas[1] - 25.0).abs() < 1e-9, "areas: {:?}", areas);
        let mut got: Vec<Ring> = out.iter().map(canonical).collect();
        got.sort_by(|a, b| a.partial_cmp(b).unwrap());
        assert_eq!(
            got,
            vec![
                vec![(0.0, 0.0), (5.0, 5.0), (0.0, 10.0)],
                vec![(5.0, 5.0), (10.0, 0.0), (10.0, 10.0)],
            ]
        );
        for r in &out {
            assert!(is_simple(r), "output ring not simple: {:?}", r);
        }
    }

    #[test]
    fn pinch_at_a_revisited_vertex_splits_into_two_lobes() {
        // A ring that visits (5,5) twice — a "pinch" rather than a
        // crossing:
        //   (0,0) -> (5,5) -> (10,0) -> (10,10) -> (5,5) -> (0,10)
        // Both meetings are at endpoints of both edges, so again the
        // old strict predicate saw nothing.
        //
        // Derivation: the ring is two triangles joined at (5,5),
        //   (0,0),(5,5),(0,10) -> +25   (as computed above)
        //   (5,5),(10,0),(10,10) -> +25
        // and every point of either is wound exactly once, so both are
        // filled. Total 50 over two simple rings.
        let input: PolygonSet = vec![vec![
            (0.0, 0.0),
            (5.0, 5.0),
            (10.0, 0.0),
            (10.0, 10.0),
            (5.0, 5.0),
            (0.0, 10.0),
        ]];
        let out = normalize(&input, PolyFillRule::NonZero);
        assert_eq!(out.len(), 2, "expected two lobes, got {:?}", out);
        assert!((total_area(&out) - 50.0).abs() < 1e-9);
        for r in &out {
            assert_eq!(r.len(), 3, "expected a triangle, got {:?}", r);
            assert!(is_simple(r));
        }
    }

    // ----------- Degenerate class: collinear self-overlap -----------

    #[test]
    fn collinear_self_retrace() {
        // A 10x10 square whose top edge carries a SLIT: the path runs
        // in to (5,5) and straight back out along the same line.
        //   (0,0) -> (10,0) -> (10,10) -> (5,10) -> (5,5) -> (5,10)
        //         -> (0,10) -> close
        // The two slit edges are exact reverses of each other: a
        // collinear overlap over their whole span. The determinant is
        // zero, so the old predicate returned None and the ring came
        // back whole — not simple, with a zero-area spine hanging off
        // its boundary.
        //
        // Derivation. A retraced span contributes nothing to the
        // winding: to its left the count is +1 (from the square) -1 +1
        // = +1, and to its right it is +1 as well, so the region is
        // the same on both sides and the span is not a boundary. What
        // remains is the plain square, with the vertex (5,10) retained
        // (collapsing collinear vertices is the Boolean panel's
        // separate opt-in). Shoelace on (0,0),(10,0),(10,10),(5,10),
        // (0,10): 0 + 100 + 50 + 50 + 0 = 200 -> area 100.
        let input: PolygonSet = vec![vec![
            (0.0, 0.0),
            (10.0, 0.0),
            (10.0, 10.0),
            (5.0, 10.0),
            (5.0, 5.0),
            (5.0, 10.0),
            (0.0, 10.0),
        ]];
        let out = normalize(&input, PolyFillRule::NonZero);
        assert_eq!(out.len(), 1, "expected one ring, got {:?}", out);
        assert_eq!(
            canonical(&out[0]),
            vec![
                (0.0, 0.0),
                (10.0, 0.0),
                (10.0, 10.0),
                (5.0, 10.0),
                (0.0, 10.0)
            ]
        );
        let areas = signed_areas(&out);
        assert!((areas[0] - 100.0).abs() < 1e-9, "areas: {:?}", areas);
        assert!(is_simple(&out[0]));
    }

    // ----------- Degenerate class: retrograde loop -----------

    #[test]
    fn retrograde_loop_cancels_under_non_zero_winding() {
        // A ring that traces a big square CCW and also, spliced in via
        // a slit from the corner (0,0), a small COUNTER-rotating loop
        // in its interior:
        //   (0,0) -> (5,2) -> (5,4) -> (7,4) -> (7,2) -> (5,2)
        //         -> (0,0) -> (10,0) -> (10,10) -> (0,10) -> close
        // The inner loop runs CW: shoelace on (5,2),(5,4),(7,4),(7,2)
        // = 10 - 8 - 14 + 4 = -8, so signed area -4.
        //
        // Derivation. Inside the inner loop the winding is +1 (outer
        // square) + (-1) (inner CW loop) = 0, so that region is NOT
        // filled: the loop must survive as a HOLE, not vanish and not
        // fill. In the rest of the square the winding is +1. The slit
        // (0,0)-(5,2) is traversed both ways, so the winding is +1 on
        // both of its sides and it is dropped — the hole is not
        // connected to the outer boundary by a hairline.
        //
        // Expected output therefore: two rings, the square CCW at
        // +100 and the inner loop CW at -4, for a net filled area of
        // 96. Both simple. The old recursive-split normalizer found no
        // proper crossing at all here and returned the whole
        // ten-vertex tangle as if it were one simple ring.
        let input: PolygonSet = vec![vec![
            (0.0, 0.0),
            (5.0, 2.0),
            (5.0, 4.0),
            (7.0, 4.0),
            (7.0, 2.0),
            (5.0, 2.0),
            (0.0, 0.0),
            (10.0, 0.0),
            (10.0, 10.0),
            (0.0, 10.0),
        ]];
        let out = normalize(&input, PolyFillRule::NonZero);
        assert_eq!(out.len(), 2, "expected square + hole, got {:?}", out);
        let areas = signed_areas(&out);
        assert!((areas[0] + 4.0).abs() < 1e-9, "areas: {:?}", areas);
        assert!((areas[1] - 100.0).abs() < 1e-9, "areas: {:?}", areas);
        // Net filled area = outer minus hole.
        assert!((areas.iter().sum::<f64>() - 96.0).abs() < 1e-9);
        let mut got: Vec<Ring> = out.iter().map(canonical).collect();
        got.sort_by(|a, b| a.partial_cmp(b).unwrap());
        assert_eq!(
            got,
            vec![
                vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)],
                vec![(5.0, 2.0), (5.0, 4.0), (7.0, 4.0), (7.0, 2.0)],
            ]
        );
        for r in &out {
            assert!(is_simple(r), "output ring not simple: {:?}", r);
        }
    }

    #[test]
    fn co_rotating_spliced_loop_fuses_into_one_ring() {
        // The same shape as above but with the inner loop running the
        // SAME way as the outer square (CCW): (5,2) -> (7,2) -> (7,4)
        // -> (5,4). Inside it the winding is +1 + 1 = 2, which is
        // non-zero, so that region is filled — and being filled on
        // both sides of the loop, the loop is not a boundary at all.
        //
        // Derivation: the filled region is exactly the square, so the
        // answer is one CCW ring of area 100. This is the companion of
        // the test above: same slit, same loop, opposite winding,
        // completely different answer — which is the whole point of
        // evaluating the winding rather than counting rings.
        let input: PolygonSet = vec![vec![
            (0.0, 0.0),
            (5.0, 2.0),
            (7.0, 2.0),
            (7.0, 4.0),
            (5.0, 4.0),
            (5.0, 2.0),
            (0.0, 0.0),
            (10.0, 0.0),
            (10.0, 10.0),
            (0.0, 10.0),
        ]];
        let out = normalize(&input, PolyFillRule::NonZero);
        assert_eq!(out.len(), 1, "expected one ring, got {:?}", out);
        assert_eq!(
            canonical(&out[0]),
            vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]
        );
        assert!((signed_areas(&out)[0] - 100.0).abs() < 1e-9);
    }

    // ---------- Inter-ring winding cancellation: THE CARRIED RULE ----------
    //
    // These tests come in PAIRS: one input, both rules, two answers.
    // That pairing is the point — it is what makes the carried rule
    // observable rather than a comment. Each pair's expectation is
    // derived from first principles (winding counts and shoelace sums
    // written out below), never read back from the implementation,
    // because these are SHARED limitations across the two ports: the
    // differential referee compares wrong-with-wrong as equal, so
    // correctness has to be argued here and the corpus only gates that
    // Rust and Swift agree.

    #[test]
    fn nested_co_oriented_rings_are_a_hole_under_even_odd() {
        // Two CCW rings, one nested in the other: [0,20]^2 and
        // [5,15]^2.
        //
        // Derivation, even-odd. A ray from a point inside the inner
        // ring crosses two ring edges — even — so that region is NOT
        // filled: the inner ring is a genuine hole boundary. Between
        // the rings a ray crosses once — odd — filled. Both rings are
        // simple and neither crosses the other, and each is a real
        // filled/unfilled transition, so the fast path returns them
        // bit-identically, orientation included. Net filled area
        // 400 - 100 = 300 over 2 rings.
        let outer = vec![(0.0, 0.0), (20.0, 0.0), (20.0, 20.0), (0.0, 20.0)];
        let inner = vec![(5.0, 5.0), (15.0, 5.0), (15.0, 15.0), (5.0, 15.0)];
        let out = normalize(
            &vec![outer.clone(), inner.clone()],
            PolyFillRule::EvenOdd,
        );
        assert_eq!(out, vec![outer, inner]);
    }

    #[test]
    fn nested_co_oriented_rings_fill_solid_under_non_zero() {
        // THE SAME INPUT, read as the artist's `fill-rule="nonzero"`
        // path says to read it. This is inter-ring winding
        // cancellation: the 4th degenerate class, unblocked by the
        // carried-rule ruling.
        //
        // Derivation, non-zero. Inside the inner ring the winding is
        // +1 (outer, CCW) + 1 (inner, CCW) = 2, non-zero, so that
        // region IS filled. Between the rings the winding is +1, also
        // filled. Filled-ness is therefore the same on both sides of
        // the inner ring's boundary, so that boundary is not a
        // boundary at all and every one of its spans is dropped. What
        // survives is the outer square alone: one CCW ring, shoelace
        // 2A = 20*20*2 = 800 -> area 400.
        //
        // Under the OLD fixed even-odd reading this input was
        // unrepresentable: a nonzero document was silently turned into
        // a donut. That is the boundary lie the ruling closed.
        let outer = vec![(0.0, 0.0), (20.0, 0.0), (20.0, 20.0), (0.0, 20.0)];
        let inner = vec![(5.0, 5.0), (15.0, 5.0), (15.0, 15.0), (5.0, 15.0)];
        let out = normalize(&vec![outer, inner], PolyFillRule::NonZero);
        assert_eq!(out.len(), 1, "expected one solid ring, got {:?}", out);
        assert_eq!(
            canonical(&out[0]),
            vec![(0.0, 0.0), (20.0, 0.0), (20.0, 20.0), (0.0, 20.0)]
        );
        assert!((signed_areas(&out)[0] - 400.0).abs() < 1e-9);
    }

    #[test]
    fn nested_opposed_rings_are_a_hole_under_both_rules() {
        // The same nesting with the inner ring wound the other way —
        // the way SVG's own examples draw a donut.
        //
        // Derivation. Even-odd ignores orientation, so the answer is
        // the co-oriented even-odd answer: a hole. Non-zero agrees for
        // once, because inside the inner ring the winding is
        // +1 + (-1) = 0. The two rules AGREE here, which is precisely
        // why this shape is canonical: canonical output is rings whose
        // two readings coincide, and this input already is one. Both
        // rules therefore take the fast path and return it untouched:
        // 2 rings, net 400 - 100 = 300.
        let outer = vec![(0.0, 0.0), (20.0, 0.0), (20.0, 20.0), (0.0, 20.0)];
        let inner = vec![(5.0, 5.0), (5.0, 15.0), (15.0, 15.0), (15.0, 5.0)];
        for rule in [PolyFillRule::EvenOdd, PolyFillRule::NonZero] {
            let out = normalize(&vec![outer.clone(), inner.clone()], rule);
            assert_eq!(
                out,
                vec![outer.clone(), inner.clone()],
                "rule {:?} disturbed a canonical donut",
                rule
            );
        }
    }

    #[test]
    fn overlapping_rings_are_a_symmetric_difference_under_even_odd() {
        // Two CCW squares that genuinely overlap: [0,10]^2 and
        // [5,15]^2, boundaries crossing at (10,5) and (5,10).
        //
        // Derivation, even-odd. A ray from inside the overlap
        // [5,10]^2 crosses two edges — even — so the overlap is NOT
        // filled and the set means the symmetric difference. Each ring
        // is simple by itself and each is a real transition (crossing
        // into either square from outside flips parity), so the fast
        // path returns both untouched and the sweep sees the even-odd
        // set it was handed. Net filled area 100 + 100 - 2*25 = 150.
        let a = vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)];
        let b = vec![(5.0, 5.0), (15.0, 5.0), (15.0, 15.0), (5.0, 15.0)];
        let out =
            normalize(&vec![a.clone(), b.clone()], PolyFillRule::EvenOdd);
        assert_eq!(out, vec![a, b]);
    }

    #[test]
    fn overlapping_rings_are_a_union_under_non_zero() {
        // The same two squares under the rule a freehand scribble
        // carries. Inter-ring cancellation again, the overlap case.
        //
        // Derivation, non-zero. Inside the overlap the winding is
        // 1 + 1 = 2, non-zero, so the overlap IS filled and the set
        // means the union — one L-shaped octagon. The two crossings
        // become vertices, and the arcs of each square's boundary that
        // run through the other square have winding 2 on one side and
        // 1 on the other: filled both ways, so they are dropped.
        // Survivors, chained CCW:
        //   (0,0) (10,0) (10,5) (15,5) (15,15) (5,15) (5,10) (0,10)
        // Shoelace 2A = (0*0-10*0) + (10*5-10*0) + (10*5-15*5)
        //             + (15*15-15*5) + (15*15-5*15) + (5*10-5*15)
        //             + (5*10-0*10) + (0*0-0*10)
        //             = 0 + 50 - 25 + 150 + 150 - 25 + 50 + 0 = 350
        // -> area 175, which is also 100 + 100 - 25 as it must be.
        let a = vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)];
        let b = vec![(5.0, 5.0), (15.0, 5.0), (15.0, 15.0), (5.0, 15.0)];
        let out = normalize(&vec![a, b], PolyFillRule::NonZero);
        assert_eq!(out.len(), 1, "expected one union ring, got {:?}", out);
        assert_eq!(
            canonical(&out[0]),
            vec![
                (0.0, 0.0),
                (10.0, 0.0),
                (10.0, 5.0),
                (15.0, 5.0),
                (15.0, 15.0),
                (5.0, 15.0),
                (5.0, 10.0),
                (0.0, 10.0),
            ]
        );
        assert!((signed_areas(&out)[0] - 175.0).abs() < 1e-9);
        assert!(is_simple(&out[0]));
    }

    #[test]
    fn rings_sharing_a_collinear_edge_stay_two_under_even_odd() {
        // Two CCW squares sharing a full edge: [0,10]x[0,10] and
        // [10,20]x[0,10] — an INTER-ring collinear overlap.
        //
        // Derivation, even-odd. The shared span x=10 has one square on
        // each side, each crossed once, so parity is odd on both sides
        // — both filled — but even-odd's per-ring decomposition means
        // each ring is judged alone, and alone each is a simple ring
        // that is a real transition. Fast path, both untouched:
        // 2 rings, 100 + 100 = 200.
        let a = vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)];
        let b = vec![(10.0, 0.0), (20.0, 0.0), (20.0, 10.0), (10.0, 10.0)];
        let out =
            normalize(&vec![a.clone(), b.clone()], PolyFillRule::EvenOdd);
        assert_eq!(out, vec![a, b]);
    }

    #[test]
    fn rings_sharing_a_collinear_edge_fuse_under_non_zero() {
        // The same pair read set-wide. Derivation, non-zero: to the
        // left of the shared span x=10 the winding is +1 (first square
        // only); to its right it is +1 (second square only). Filled on
        // both sides, so the span is interior and is dropped, and the
        // two squares fuse into the single rectangle [0,20]x[0,10].
        // The collinear vertices (10,0) and (10,10) are RETAINED —
        // collapsing them is the Boolean panel's separate opt-in — so
        // the ring has six vertices. Shoelace on
        //   (0,0) (10,0) (20,0) (20,10) (10,10) (0,10):
        //   0 + 0 + 200 + 200 + 100 + 0 = ... taking terms
        //   x_i*y_{i+1} - x_{i+1}*y_i pairwise:
        //   0-0, 0-0, 200-0, 100-100 -> careful; total is 400
        // -> area 200 = 100 + 100, as region-preservation demands.
        let a = vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)];
        let b = vec![(10.0, 0.0), (20.0, 0.0), (20.0, 10.0), (10.0, 10.0)];
        let out = normalize(&vec![a, b], PolyFillRule::NonZero);
        assert_eq!(out.len(), 1, "expected one fused ring, got {:?}", out);
        assert_eq!(
            canonical(&out[0]),
            vec![
                (0.0, 0.0),
                (10.0, 0.0),
                (20.0, 0.0),
                (20.0, 10.0),
                (10.0, 10.0),
                (0.0, 10.0),
            ]
        );
        assert!((signed_areas(&out)[0] - 200.0).abs() < 1e-9);
        assert!(is_simple(&out[0]));
    }

    #[test]
    fn disjoint_rings_take_the_fast_path_untouched_under_both_rules() {
        // Two CCW squares that share nothing. Disjointness is the case
        // where the two rules cannot disagree — no point is enclosed
        // twice — so this pins that carrying the rule did not drag the
        // ordinary case onto the arrangement path under either
        // reading. The rings come back bit-identical, in input order.
        let a = vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)];
        let b = vec![(20.0, 0.0), (30.0, 0.0), (30.0, 10.0), (20.0, 10.0)];
        for rule in [PolyFillRule::EvenOdd, PolyFillRule::NonZero] {
            let out = normalize(&vec![a.clone(), b.clone()], rule);
            assert_eq!(out, vec![a.clone(), b.clone()], "rule {:?}", rule);
        }
    }

    #[test]
    fn a_degenerate_ring_does_not_take_its_siblings_with_it() {
        // One good ring plus one zero-area collinear ring, under both
        // rules. The flat ring encloses nothing under either reading —
        // its winding is 0 everywhere — so it is dropped and the
        // square survives with its region intact (area 100, simple).
        //
        // The two rules reach that answer by different routes, which
        // is worth stating: even-odd decomposes per ring, so the flat
        // ring is resolved alone and vanishes while the square never
        // leaves the fast path and comes back BIT-IDENTICAL. Non-zero
        // must read the set together, so the flat ring's self-overlap
        // drags the whole set onto the arrangement path; the square is
        // rebuilt vertex for vertex from its own spans, so its region
        // and vertex sequence are preserved but its traversal may
        // start anywhere — hence the canonical() comparison.
        let a = vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)];
        let flat = vec![(20.0, 0.0), (25.0, 0.0), (30.0, 0.0)];

        let eo = normalize(
            &vec![a.clone(), flat.clone()],
            PolyFillRule::EvenOdd,
        );
        assert_eq!(eo, vec![a.clone()]);

        let nz = normalize(&vec![a.clone(), flat], PolyFillRule::NonZero);
        assert_eq!(nz.len(), 1, "expected the square alone, got {:?}", nz);
        assert_eq!(canonical(&nz[0]), canonical(&a));
        assert!((signed_areas(&nz)[0] - 100.0).abs() < 1e-9);
    }

    #[test]
    fn a_multiply_wound_ring_is_a_rule_disagreement_too() {
        // The carried rule is not only about ring-to-ring relations:
        // a SINGLE ring traced twice around the same square winds to 2
        // everywhere inside it.
        //
        // Derivation. Non-zero: 2 != 0, so the square is filled —
        // one ring, area 100. Even-odd: 2 is even, so the interior is
        // NOT filled and the region is empty — zero rings. Same
        // vertices, opposite answers, and no amount of orientation
        // convention can paper over it. This is why the normalizer
        // cannot pick a rule on the caller's behalf.
        let twice: PolygonSet = vec![vec![
            (0.0, 0.0),
            (10.0, 0.0),
            (10.0, 10.0),
            (0.0, 10.0),
            (0.0, 0.0),
            (10.0, 0.0),
            (10.0, 10.0),
            (0.0, 10.0),
        ]];

        let nz = normalize(&twice, PolyFillRule::NonZero);
        assert_eq!(nz.len(), 1, "non-zero should fill it: {:?}", nz);
        assert!((total_area(&nz) - 100.0).abs() < 1e-9);

        let eo = normalize(&twice, PolyFillRule::EvenOdd);
        assert!(eo.is_empty(), "even-odd should empty it: {:?}", eo);
    }

    #[test]
    fn zero_area_collinear_ring_is_dropped() {
        // Three collinear vertices enclose nothing, so the non-zero
        // region is empty and the output must be empty too.
        let input: PolygonSet = vec![vec![(0.0, 0.0), (5.0, 0.0), (10.0, 0.0)]];
        assert!(normalize(&input, PolyFillRule::NonZero).is_empty());
    }
}
