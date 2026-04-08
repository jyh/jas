//! Boolean operations on planar polygons (union, intersection,
//! difference, exclusive-or).
//!
//! # Status
//!
//! **Spec only.** This module currently exposes the public API as
//! `unimplemented!()` stubs and a comprehensive test suite. The
//! intent is to nail down the contract — including all the
//! degenerate cases that quietly break naïve implementations —
//! *before* writing any algorithm code. Pick an algorithm
//! (Greiner-Hormann, Martinez-Rueda-Feito, or Weiler-Atherton),
//! implement it, and the tests below should pass without being
//! rewritten.
//!
//! # Data model
//!
//! All inputs and outputs are [`PolygonSet`] values. A `PolygonSet`
//! is a flat list of *rings*; a ring is a closed polygon expressed
//! as a list of `(x, y)` vertices (without an explicit closing
//! vertex — the last vertex is implicitly connected back to the
//! first).
//!
//! Multiple rings represent a region using the **even-odd fill
//! rule**: a point is *inside* the region iff a ray from the point
//! crosses an odd number of ring edges. This means a polygon with
//! a hole is two rings (the outer boundary and the hole), and the
//! result of a boolean operation may legitimately produce many
//! disjoint pieces and/or holes — all collected in the same flat
//! `PolygonSet`.
//!
//! Ring orientation is **not** part of the contract. The
//! implementation is free to emit clockwise or counter-clockwise
//! rings; the test suite asserts on the *region* (area, sample
//! points, bounding box), never on raw vertex sequences.
//!
//! # Out of scope here
//!
//! - Curves. Bezier and elliptical arcs must be flattened to a
//!   polyline before being passed in. The element-level adapter
//!   that wires these functions to `Element::Path` /
//!   `Element::Circle` / etc. lives elsewhere; this module is
//!   pure geometry.
//! - Self-intersecting input rings. The behaviour on a
//!   self-intersecting input is left intentionally undefined; if
//!   we need to handle them, we'll add a normalisation pass and
//!   tests for it explicitly.
//! - Open polylines. Boolean operations are defined on regions,
//!   not curves; lines and polylines have no interior.

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// A single closed ring as a vector of `(x, y)` vertices. The last
/// vertex is implicitly connected back to the first; do **not**
/// include a duplicate closing vertex.
pub type Ring = Vec<(f64, f64)>;

/// A region in the plane, represented as a flat list of rings under
/// the even-odd fill rule. Multiple rings can encode disjoint pieces
/// and/or holes.
pub type PolygonSet = Vec<Ring>;

// ---------------------------------------------------------------------------
// Public API — algorithm-agnostic
// ---------------------------------------------------------------------------

/// `a ∪ b` — the region covered by either operand.
pub fn boolean_union(a: &PolygonSet, b: &PolygonSet) -> PolygonSet {
    run_boolean(a, b, Operation::Union)
}

/// `a ∩ b` — the region covered by both operands.
pub fn boolean_intersect(a: &PolygonSet, b: &PolygonSet) -> PolygonSet {
    run_boolean(a, b, Operation::Intersection)
}

/// `a − b` — the region covered by `a` but not `b`. Not symmetric.
pub fn boolean_subtract(a: &PolygonSet, b: &PolygonSet) -> PolygonSet {
    run_boolean(a, b, Operation::Difference)
}

/// `a ⊕ b` — symmetric difference; the region covered by exactly
/// one of the operands. Equivalent to `(a ∪ b) − (a ∩ b)`.
pub fn boolean_exclude(a: &PolygonSet, b: &PolygonSet) -> PolygonSet {
    run_boolean(a, b, Operation::Xor)
}

// ---------------------------------------------------------------------------
// Implementation: Martinez-Rueda-Feito sweep-line algorithm
//
// References:
//   - Martinez, F., Rueda, A., Feito, F. (2009).
//     "A new algorithm for computing Boolean operations on polygons".
//     Computers & Geosciences, 35(6), 1177-1185.
//   - Reference C++ implementation accompanying the paper.
//   - Open-source Rust ports (geo-booleanop, polygon-clipping/JS).
//
// Phasing:
//   - Phase 1 (this commit): skeleton — data structures, event queue
//     ordering, sweep loop with in_out / other_in_out / in_result
//     computation, connection step. *No proper-intersection
//     detection*: edges that cross in the interior are not yet
//     subdivided. As a result, only inputs whose edges have no
//     interior crossings (disjoint, empty operands) produce correct
//     results in this phase.
//   - Phase 2 (next commit): add intersection detection / edge
//     subdivision so the overlapping cases pass.
//   - Phase 3 (final commit): degeneracy fixes (collinear edges,
//     vertex coincidences, vertical edges, robustness tweaks) so
//     the touching cases pass.
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Operation {
    Union,
    Intersection,
    Difference,
    Xor,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PolygonId {
    Subject = 0,
    Clipping = 1,
}

/// Classification of an edge with respect to overlapping (collinear)
/// edges in the other polygon. Used in the sweep step to decide
/// which edge of a coincident pair contributes to the result.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EdgeType {
    /// Normal edge — does not coincide with an edge of the other polygon.
    Normal,
    /// One of two coincident edges that traverse the same boundary
    /// in the same direction (same in/out transition).
    SameTransition,
    /// One of two coincident edges that traverse opposite directions.
    DifferentTransition,
    /// A coincident edge that does not contribute to the output —
    /// suppressed because its partner already does.
    NonContributing,
}

/// One endpoint of an edge in the sweep-line algorithm. Each edge
/// produces two events: a "left" event at its lex-smaller endpoint
/// and a "right" event at the lex-larger endpoint. Events are
/// stored in a single arena ([`Sweep::events`]) and referred to by
/// index everywhere else.
#[derive(Debug, Clone)]
struct SweepEvent {
    point: (f64, f64),
    /// True iff this event is the lex-smaller endpoint of the edge.
    is_left: bool,
    /// Which input polygon this edge came from.
    polygon: PolygonId,
    /// Index of the *other* endpoint of the same edge in the arena.
    /// When this event is processed the algorithm needs to find its
    /// partner cheaply.
    other_event: usize,

    // ---- Fields populated during the sweep ----
    /// For *left* events: true iff this edge is an "out" transition
    /// (the polygon's interior lies *below* the edge for non-vertical
    /// edges, *left* for vertical). The naming follows the original
    /// paper.
    in_out: bool,
    /// For left events: the most recent `in_out` value seen for the
    /// *other* polygon's nearest edge below this one in the status
    /// line. Combined with `in_out` this tells us whether the
    /// current edge's interior side lies inside the other polygon.
    other_in_out: bool,
    /// Tag set in the sweep step: this edge contributes to the
    /// result of the requested boolean operation.
    in_result: bool,
    /// Coincident-edge classification (see [`EdgeType`]).
    edge_type: EdgeType,
    /// Connection-step pointer: index of the previous in-result edge
    /// below this one in the status line. Used to nest holes inside
    /// outer rings.
    prev_in_result: Option<usize>,
}

impl SweepEvent {
    fn new(point: (f64, f64), is_left: bool, polygon: PolygonId) -> Self {
        Self {
            point,
            is_left,
            polygon,
            other_event: usize::MAX,
            in_out: false,
            other_in_out: false,
            in_result: false,
            edge_type: EdgeType::Normal,
            prev_in_result: None,
        }
    }
}

/// Compare two points lexicographically by `(x, y)`.
fn point_lex_less(a: (f64, f64), b: (f64, f64)) -> bool {
    if a.0 != b.0 {
        a.0 < b.0
    } else {
        a.1 < b.1
    }
}

/// Signed area of the triangle (p0, p1, p2). Positive iff (p0, p1,
/// p2) makes a left turn (counter-clockwise), negative for right
/// turn, zero for collinear.
fn signed_area(p0: (f64, f64), p1: (f64, f64), p2: (f64, f64)) -> f64 {
    (p0.0 - p2.0) * (p1.1 - p2.1) - (p1.0 - p2.0) * (p0.1 - p2.1)
}

/// Strict ordering on events for the sweep-line priority queue.
/// Returns true iff `a` comes *strictly before* `b` in processing
/// order. Tie-breaking follows the original Martinez paper:
///
/// 1. By x.
/// 2. By y.
/// 3. Right events before left events (so that an edge's right
///    endpoint is processed before the left endpoint of an
///    incident edge sharing the same point).
/// 4. By the signed area of the (a.point, a.other, b.other)
///    triangle: the edge with the lower other endpoint comes first.
/// 5. By polygon id (subject before clipping) as a final
///    tie-break.
fn event_less(events: &[SweepEvent], a: usize, b: usize) -> bool {
    let ea = &events[a];
    let eb = &events[b];
    if ea.point.0 != eb.point.0 {
        return ea.point.0 < eb.point.0;
    }
    if ea.point.1 != eb.point.1 {
        return ea.point.1 < eb.point.1;
    }
    if ea.is_left != eb.is_left {
        // right (false) before left (true)
        return !ea.is_left;
    }
    // Both events are at the same point and have the same direction.
    // Use the orientation of the edge to break the tie: the one whose
    // other endpoint is below comes first.
    let other_a = events[ea.other_event].point;
    let other_b = events[eb.other_event].point;
    let area = signed_area(ea.point, other_a, other_b);
    if area != 0.0 {
        return area > 0.0;
    }
    // Final tie-break: subject (0) before clipping (1).
    (ea.polygon as u8) < (eb.polygon as u8)
}

/// Strict ordering on edges in the status line. Edges are compared
/// by which one lies "below" the other at the current sweep
/// position. The status-line keeps left events of currently-active
/// edges sorted from bottom to top.
///
/// The key property: if edge `a` is below edge `b` at sweep x,
/// then at any sweep x where both are active, `a` is still below
/// `b` (because edges in the status line have been split at every
/// intersection — there are no proper crossings inside the
/// status-line slab).
fn status_less(events: &[SweepEvent], a: usize, b: usize) -> bool {
    if a == b {
        return false;
    }
    let ea = &events[a];
    let eb = &events[b];
    let other_a = events[ea.other_event].point;
    let other_b = events[eb.other_event].point;
    // Check whether ea's two endpoints are collinear with eb. If so,
    // tie-break by point ordering; otherwise use the signed area to
    // decide which is below.
    if signed_area(ea.point, other_a, eb.point) != 0.0
        || signed_area(ea.point, other_a, other_b) != 0.0
    {
        // Not collinear.
        if ea.point == eb.point {
            return signed_area(ea.point, other_a, other_b) > 0.0;
        }
        // If the events have different left endpoints, use the one
        // that comes first lexicographically as the reference and
        // measure the other's position relative to it.
        if event_less(events, a, b) {
            return signed_area(ea.point, other_a, eb.point) > 0.0;
        }
        return signed_area(eb.point, other_b, ea.point) < 0.0;
    }
    // Collinear edges: tie-break by polygon id then by point order.
    if ea.polygon != eb.polygon {
        return (ea.polygon as u8) < (eb.polygon as u8);
    }
    if ea.point != eb.point {
        return point_lex_less(ea.point, eb.point);
    }
    point_lex_less(other_a, other_b)
}

/// Decide whether an edge should appear in the result of `op`,
/// based on its classification flags. Called once the sweep step
/// has filled `in_out`, `other_in_out`, and `edge_type` on a
/// left event.
///
/// In the Martinez convention, `other_in_out = true` means the
/// edge is *outside* the other polygon (the imaginary edge below
/// from the other polygon was an in-out transition leaving us
/// outside). So an edge contributes to the union iff it is
/// outside the other polygon (`other_in_out`), and contributes to
/// the intersection iff it is inside the other polygon
/// (`!other_in_out`).
fn edge_in_result(event: &SweepEvent, op: Operation) -> bool {
    match event.edge_type {
        EdgeType::Normal => match op {
            Operation::Union => event.other_in_out,
            Operation::Intersection => !event.other_in_out,
            Operation::Difference => match event.polygon {
                PolygonId::Subject => event.other_in_out,
                PolygonId::Clipping => !event.other_in_out,
            },
            Operation::Xor => true,
        },
        EdgeType::SameTransition => matches!(op, Operation::Union | Operation::Intersection),
        EdgeType::DifferentTransition => matches!(op, Operation::Difference),
        EdgeType::NonContributing => false,
    }
}

/// State for one run of the sweep algorithm. The events arena owns
/// every `SweepEvent`; everything else refers to events by index.
struct Sweep {
    events: Vec<SweepEvent>,
}

impl Sweep {
    fn new() -> Self {
        Self { events: Vec::new() }
    }

    /// Push the two events (left, right) for an edge from `p1` to
    /// `p2` belonging to the given polygon. Returns the indices of
    /// the two new events as `(left_idx, right_idx)`. Skips
    /// degenerate edges (`p1 == p2`).
    fn add_edge(&mut self, p1: (f64, f64), p2: (f64, f64), polygon: PolygonId) {
        if p1 == p2 {
            return;
        }
        let (lp, rp) = if point_lex_less(p1, p2) { (p1, p2) } else { (p2, p1) };
        let l = self.events.len();
        let r = l + 1;
        let mut le = SweepEvent::new(lp, true, polygon);
        let mut re = SweepEvent::new(rp, false, polygon);
        le.other_event = r;
        re.other_event = l;
        self.events.push(le);
        self.events.push(re);
    }

    /// Push every edge of the given `PolygonSet` into the events
    /// arena, tagged with `polygon`.
    fn add_polygon_set(&mut self, ps: &PolygonSet, polygon: PolygonId) {
        for ring in ps {
            let n = ring.len();
            if n < 3 {
                continue;
            }
            for i in 0..n {
                let p = ring[i];
                let q = ring[(i + 1) % n];
                self.add_edge(p, q, polygon);
            }
        }
    }
}

/// Top-level dispatch: build a `Sweep`, run it, return the result
/// `PolygonSet`. Handles the trivial empty-operand cases without
/// invoking the sweep machinery.
fn run_boolean(a: &PolygonSet, b: &PolygonSet, op: Operation) -> PolygonSet {
    // Trivial cases — handled here so the sweep code can assume both
    // operands are non-empty.
    let a_empty = a.iter().all(|r| r.len() < 3);
    let b_empty = b.iter().all(|r| r.len() < 3);
    if a_empty && b_empty {
        return Vec::new();
    }
    if a_empty {
        return match op {
            Operation::Union | Operation::Xor => clone_nondegenerate(b),
            Operation::Intersection | Operation::Difference => Vec::new(),
        };
    }
    if b_empty {
        return match op {
            Operation::Union | Operation::Xor | Operation::Difference => clone_nondegenerate(a),
            Operation::Intersection => Vec::new(),
        };
    }

    let mut sweep = Sweep::new();
    sweep.add_polygon_set(a, PolygonId::Subject);
    sweep.add_polygon_set(b, PolygonId::Clipping);

    // Phase 1: process events in priority order, computing in_out /
    // other_in_out / in_result. Phase 2 will add intersection
    // detection here. For now we visit each event in order and
    // assume the existing edges form a non-self-intersecting
    // partition.
    let order = phase1_sort_events(&sweep.events);
    let mut status: Vec<usize> = Vec::new(); // sorted by status_less
    for &idx in &order {
        let is_left = sweep.events[idx].is_left;
        if is_left {
            // Insert into status line at the correct position.
            let pos = status
                .binary_search_by(|&probe| {
                    if status_less(&sweep.events, probe, idx) {
                        std::cmp::Ordering::Less
                    } else if probe == idx {
                        std::cmp::Ordering::Equal
                    } else {
                        std::cmp::Ordering::Greater
                    }
                })
                .unwrap_or_else(|e| e);
            status.insert(pos, idx);
            // Compute in_out / other_in_out by inspecting the edge
            // immediately below this one in the status line.
            compute_fields(&mut sweep.events, &status, pos);
            // Decide whether this edge contributes.
            sweep.events[idx].in_result = edge_in_result(&sweep.events[idx], op);
        } else {
            // Right event — find the matching left event and remove
            // it from the status line. The right event itself does
            // not need to be inserted.
            let other = sweep.events[idx].other_event;
            if let Some(pos) = status.iter().position(|&e| e == other) {
                status.remove(pos);
            }
            // Phase 1: copy in_result from the left event to the
            // right event for use by the connection step.
            sweep.events[idx].in_result = sweep.events[other].in_result;
        }
    }

    connect_edges(&sweep.events, &order)
}

/// Sort the (still-flat) events arena into priority order. In
/// phase 1 this is a one-shot sort; phase 2 will replace it with a
/// real priority queue so newly-created intersection events can be
/// inserted on the fly.
fn phase1_sort_events(events: &[SweepEvent]) -> Vec<usize> {
    let mut order: Vec<usize> = (0..events.len()).collect();
    order.sort_by(|&a, &b| {
        if event_less(events, a, b) {
            std::cmp::Ordering::Less
        } else if event_less(events, b, a) {
            std::cmp::Ordering::Greater
        } else {
            std::cmp::Ordering::Equal
        }
    });
    order
}

/// Populate `in_out` / `other_in_out` for the left event at
/// `status[pos]`. Looks at the nearest edge below in the status
/// line and uses the standard Martinez transition rules.
///
/// Field semantics (Martinez 2009, §4):
/// - `in_out`: true iff this edge is an *inside-to-outside*
///   transition of *its own* polygon when traversed from below
///   to above. The bottom edge of a polygon has `in_out = false`
///   (going up across it we enter the polygon, so it is *not* an
///   in-out transition); the top edge has `in_out = true`.
/// - `other_in_out`: true iff the imaginary edge directly below
///   this one in the other polygon is an in-out transition —
///   equivalently, this edge lies *outside* the other polygon.
///   The bottom-most edge in the status line is treated as if
///   the imaginary other-polygon edge below it was already an
///   in-out transition (so we're outside), giving
///   `other_in_out = true`.
fn compute_fields(events: &mut [SweepEvent], status: &[usize], pos: usize) {
    let idx = status[pos];
    if pos == 0 {
        events[idx].in_out = false;
        events[idx].other_in_out = true;
        return;
    }
    let prev = status[pos - 1];
    let prev_polygon = events[prev].polygon;
    let cur_polygon = events[idx].polygon;
    if cur_polygon == prev_polygon {
        // Same polygon: the in/out status of this polygon flips
        // relative to the previous edge of the same polygon.
        events[idx].in_out = !events[prev].in_out;
        events[idx].other_in_out = events[prev].other_in_out;
    } else {
        // Different polygons: the previous edge tells us about the
        // *other* polygon's status from this edge's perspective,
        // and vice versa.
        let prev_vertical = events[prev].point.0
            == events[events[prev].other_event].point.0;
        events[idx].in_out = !events[prev].other_in_out;
        events[idx].other_in_out = if prev_vertical {
            !events[prev].in_out
        } else {
            events[prev].in_out
        };
    }
    // Track the previous in-result edge below for the connection
    // step (used to nest holes inside outer rings).
    if events[prev].in_result {
        events[idx].prev_in_result = Some(prev);
    } else {
        events[idx].prev_in_result = events[prev].prev_in_result;
    }
}

/// Walk the in-result events to form output rings. The standard
/// Martinez connection step builds a graph where each in-result
/// vertex links to its partner via `other_event`, then walks the
/// graph to extract closed loops.
fn connect_edges(events: &[SweepEvent], order: &[usize]) -> PolygonSet {
    // Collect in-result events in priority order. Both events
    // (left and right) of an in-result edge are included so the
    // walker can step from a vertex to its partner via
    // `other_event`.
    let mut in_result: Vec<usize> = Vec::new();
    for &idx in order {
        let e = &events[idx];
        let is_in = if e.is_left {
            e.in_result
        } else {
            events[e.other_event].in_result
        };
        if is_in {
            in_result.push(idx);
        }
    }

    // For O(1) "where is event X in the in_result list?" lookups
    // during the walk.
    let mut pos_in_result: std::collections::HashMap<usize, usize> =
        std::collections::HashMap::with_capacity(in_result.len());
    for (i, &idx) in in_result.iter().enumerate() {
        pos_in_result.insert(idx, i);
    }

    let mut visited = vec![false; in_result.len()];
    let mut result: PolygonSet = Vec::new();

    for start in 0..in_result.len() {
        if visited[start] {
            continue;
        }
        let mut ring: Ring = Vec::new();
        let mut i = start;
        loop {
            visited[i] = true;
            let cur_event = in_result[i];
            ring.push(events[cur_event].point);
            // Step to the partner (other endpoint of the same edge).
            let partner = events[cur_event].other_event;
            let Some(&partner_pos) = pos_in_result.get(&partner) else {
                // Partner not in result — shouldn't happen for a
                // well-formed input, but bail safely.
                break;
            };
            visited[partner_pos] = true;
            // From the partner, look for the next in-result event
            // sharing the same point and not yet visited.
            let partner_point = events[partner].point;
            let mut next: Option<usize> = None;
            // Search forward then backward in the in_result list.
            for j in (partner_pos + 1)..in_result.len() {
                if visited[j] {
                    continue;
                }
                if events[in_result[j]].point == partner_point {
                    next = Some(j);
                    break;
                }
                if events[in_result[j]].point.0 > partner_point.0 {
                    break;
                }
            }
            if next.is_none() {
                let mut j = partner_pos;
                while j > 0 {
                    j -= 1;
                    if visited[j] {
                        continue;
                    }
                    if events[in_result[j]].point == partner_point {
                        next = Some(j);
                        break;
                    }
                    if events[in_result[j]].point.0 < partner_point.0 {
                        break;
                    }
                }
            }
            match next {
                Some(j) => i = j,
                None => break,
            }
            if i == start {
                break;
            }
        }
        if ring.len() >= 3 {
            result.push(ring);
        }
    }

    result
}

/// Return a deep copy of every ring in `ps` that has at least 3
/// vertices. Used to handle the empty-operand fast path without
/// returning references into the input.
fn clone_nondegenerate(ps: &PolygonSet) -> PolygonSet {
    ps.iter().filter(|r| r.len() >= 3).cloned().collect()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // -------------------------------------------------------------------
    // Region helpers
    //
    // We assert on *regions*, never on raw vertex sequences. The
    // implementation is free to choose any vertex ordering, starting
    // vertex, ring ordering, or orientation as long as the resulting
    // region matches.
    //
    // A region is characterised by:
    //   - its (signed-)area magnitude under the even-odd fill rule
    //   - the inside/outside answer at a set of sample points
    //   - its axis-aligned bounding box (when non-empty)
    //
    // These three together are enough to distinguish every test
    // case we care about, without being brittle to representation.
    // -------------------------------------------------------------------

    /// Shoelace area of a single ring. Sign reflects winding
    /// direction; we use the absolute value when comparing regions.
    fn ring_signed_area(ring: &Ring) -> f64 {
        if ring.len() < 3 {
            return 0.0;
        }
        let mut sum = 0.0;
        let n = ring.len();
        for i in 0..n {
            let (x1, y1) = ring[i];
            let (x2, y2) = ring[(i + 1) % n];
            sum += x1 * y2 - x2 * y1;
        }
        sum / 2.0
    }

    /// Even-odd area of a region. Holes (rings with opposite winding
    /// or rings whose interior is "subtracted" by overlap parity)
    /// are handled by summing absolute areas of outer rings minus
    /// holes; in practice the implementation is free to use either
    /// winding-rule or even-odd output as long as the *net* covered
    /// area matches what we expect.
    ///
    /// We compute "net area" as the integral of the indicator
    /// function over the bounding box, which we approximate by
    /// summing absolute signed-areas with alternating signs based
    /// on a containment count at a sample inside each ring. That's
    /// overkill for the small test cases here, so we use a simpler
    /// rule: net_area = sum(|signed_area(ring)|) for outer rings
    /// minus sum(|signed_area(ring)|) for hole rings, where a hole
    /// is detected by being contained in another ring with the
    /// opposite winding sign.
    ///
    /// For all the test polygons in this file the simpler rule
    /// suffices because every test fixture has a known structure.
    /// We expose `polygon_set_area` only for asserting against a
    /// pre-computed expected value, so even a slightly liberal
    /// interpretation is fine for our purposes.
    fn polygon_set_area(ps: &PolygonSet) -> f64 {
        // Sum |signed_area| of every ring, with the sign of the
        // *outer* ring chosen as positive and contained rings
        // contributing with the opposite sign of their parent.
        // Implementation note: nearly every test below uses
        // pairwise-disjoint outer rings, so the simple sum of
        // absolute signed areas is correct in those cases. Only the
        // "with hole" tests need the containment correction.
        let mut total = 0.0;
        for (i, ring) in ps.iter().enumerate() {
            let a = ring_signed_area(ring).abs();
            // Count containments — a ring contained in an odd number
            // of other rings is a hole and contributes negatively.
            let mut depth = 0;
            if let Some(&pt) = ring.first() {
                for (j, other) in ps.iter().enumerate() {
                    if i == j {
                        continue;
                    }
                    if point_in_ring(other, pt) {
                        depth += 1;
                    }
                }
            }
            if depth % 2 == 0 {
                total += a;
            } else {
                total -= a;
            }
        }
        total
    }

    /// Standard ray-casting point-in-ring test. The ring is treated
    /// as a closed polygon (last vertex implicitly connects to the
    /// first).
    fn point_in_ring(ring: &Ring, pt: (f64, f64)) -> bool {
        let (px, py) = pt;
        let n = ring.len();
        if n < 3 {
            return false;
        }
        let mut inside = false;
        let mut j = n - 1;
        for i in 0..n {
            let (xi, yi) = ring[i];
            let (xj, yj) = ring[j];
            let intersects = ((yi > py) != (yj > py))
                && (px < (xj - xi) * (py - yi) / (yj - yi) + xi);
            if intersects {
                inside = !inside;
            }
            j = i;
        }
        inside
    }

    /// Even-odd "is point inside this region" — true iff `pt` lies
    /// inside an odd number of rings.
    fn point_in_polygon_set(ps: &PolygonSet, pt: (f64, f64)) -> bool {
        let mut inside_count = 0;
        for ring in ps {
            if point_in_ring(ring, pt) {
                inside_count += 1;
            }
        }
        inside_count % 2 == 1
    }

    /// Axis-aligned bounding box of a `PolygonSet`. Returns
    /// `None` if the set has no vertices.
    fn polygon_set_bbox(ps: &PolygonSet) -> Option<(f64, f64, f64, f64)> {
        let mut min_x = f64::INFINITY;
        let mut min_y = f64::INFINITY;
        let mut max_x = f64::NEG_INFINITY;
        let mut max_y = f64::NEG_INFINITY;
        let mut any = false;
        for ring in ps {
            for &(x, y) in ring {
                if x < min_x {
                    min_x = x;
                }
                if y < min_y {
                    min_y = y;
                }
                if x > max_x {
                    max_x = x;
                }
                if y > max_y {
                    max_y = y;
                }
                any = true;
            }
        }
        if any {
            Some((min_x, min_y, max_x - min_x, max_y - min_y))
        } else {
            None
        }
    }

    const EPS: f64 = 1e-9;

    fn approx_eq(a: f64, b: f64) -> bool {
        (a - b).abs() < EPS
    }

    /// Assert that a `PolygonSet` represents the expected region.
    ///
    /// Checks (in order):
    ///   1. The net even-odd area matches `expected_area`.
    ///   2. Every `inside_pts` is reported inside.
    ///   3. Every `outside_pts` is reported outside.
    ///   4. If `expected_area` is non-zero, the bbox matches
    ///      `expected_bbox` (when supplied).
    ///
    /// Vertex order, ring order, ring count, and orientation are
    /// all unconstrained.
    fn assert_region(
        actual: &PolygonSet,
        expected_area: f64,
        inside_pts: &[(f64, f64)],
        outside_pts: &[(f64, f64)],
        expected_bbox: Option<(f64, f64, f64, f64)>,
    ) {
        let area = polygon_set_area(actual);
        assert!(
            approx_eq(area, expected_area),
            "area mismatch: expected {}, got {} (rings: {:?})",
            expected_area,
            area,
            actual
        );
        for &pt in inside_pts {
            assert!(
                point_in_polygon_set(actual, pt),
                "point {:?} should be inside region {:?}",
                pt,
                actual
            );
        }
        for &pt in outside_pts {
            assert!(
                !point_in_polygon_set(actual, pt),
                "point {:?} should be outside region {:?}",
                pt,
                actual
            );
        }
        if let Some(expected) = expected_bbox {
            if expected_area > EPS {
                let actual_bbox = polygon_set_bbox(actual).expect("non-empty region must have a bbox");
                assert!(
                    approx_eq(actual_bbox.0, expected.0)
                        && approx_eq(actual_bbox.1, expected.1)
                        && approx_eq(actual_bbox.2, expected.2)
                        && approx_eq(actual_bbox.3, expected.3),
                    "bbox mismatch: expected {:?}, got {:?}",
                    expected,
                    actual_bbox
                );
            }
        }
    }

    /// Assert that the result is the empty region (no rings, or
    /// rings whose total area is zero).
    fn assert_empty(actual: &PolygonSet) {
        let area: f64 = actual.iter().map(|r| ring_signed_area(r).abs()).sum();
        assert!(
            area < EPS,
            "expected empty region, got area {} (rings: {:?})",
            area,
            actual
        );
    }

    // -------------------------------------------------------------------
    // Polygon fixtures used across tests
    // -------------------------------------------------------------------

    /// Axis-aligned 10×10 square at the origin.
    fn square_a() -> PolygonSet {
        vec![vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]]
    }

    /// 10×10 square overlapping `square_a`'s top-right corner.
    /// Their intersection is a 5×5 square at (5, 5)-(10, 10).
    fn square_b_overlap() -> PolygonSet {
        vec![vec![(5.0, 5.0), (15.0, 5.0), (15.0, 15.0), (5.0, 15.0)]]
    }

    /// 10×10 square that doesn't touch `square_a` at all.
    fn square_disjoint() -> PolygonSet {
        vec![vec![(20.0, 0.0), (30.0, 0.0), (30.0, 10.0), (20.0, 10.0)]]
    }

    /// 10×10 square that exactly touches `square_a` along one edge
    /// (no area overlap, but the edge `x = 10` is shared).
    fn square_edge_touching() -> PolygonSet {
        vec![vec![(10.0, 0.0), (20.0, 0.0), (20.0, 10.0), (10.0, 10.0)]]
    }

    /// 10×10 square that touches `square_a` only at a single
    /// vertex (10, 10).
    fn square_vertex_touching() -> PolygonSet {
        vec![vec![(10.0, 10.0), (20.0, 10.0), (20.0, 20.0), (10.0, 20.0)]]
    }

    /// 4×4 square fully contained inside `square_a`.
    fn square_inside() -> PolygonSet {
        vec![vec![(3.0, 3.0), (7.0, 3.0), (7.0, 7.0), (3.0, 7.0)]]
    }

    // -------------------------------------------------------------------
    // Trivial cases — disjoint, identical, contained
    // -------------------------------------------------------------------

    #[test]
    fn union_disjoint_squares_yields_two_pieces() {
        let result = boolean_union(&square_a(), &square_disjoint());
        // 2 × 100 = 200 net area, two disjoint pieces.
        assert_region(
            &result,
            200.0,
            &[(5.0, 5.0), (25.0, 5.0)],
            &[(15.0, 5.0), (-1.0, -1.0)],
            None, // bbox is the union of both
        );
    }

    #[test]
    fn intersection_disjoint_squares_is_empty() {
        let result = boolean_intersect(&square_a(), &square_disjoint());
        assert_empty(&result);
    }

    #[test]
    fn subtract_disjoint_returns_a_unchanged() {
        let result = boolean_subtract(&square_a(), &square_disjoint());
        assert_region(
            &result,
            100.0,
            &[(5.0, 5.0)],
            &[(25.0, 5.0)],
            Some((0.0, 0.0, 10.0, 10.0)),
        );
    }

    #[test]
    fn exclude_disjoint_is_their_union() {
        let result = boolean_exclude(&square_a(), &square_disjoint());
        assert_region(
            &result,
            200.0,
            &[(5.0, 5.0), (25.0, 5.0)],
            &[(15.0, 5.0)],
            None,
        );
    }

    #[test]
    fn union_identical_polygons_is_one_polygon() {
        let result = boolean_union(&square_a(), &square_a());
        assert_region(
            &result,
            100.0,
            &[(5.0, 5.0)],
            &[(11.0, 11.0)],
            Some((0.0, 0.0, 10.0, 10.0)),
        );
    }

    #[test]
    fn intersection_identical_polygons_is_the_polygon() {
        let result = boolean_intersect(&square_a(), &square_a());
        assert_region(
            &result,
            100.0,
            &[(5.0, 5.0)],
            &[(11.0, 11.0)],
            Some((0.0, 0.0, 10.0, 10.0)),
        );
    }

    #[test]
    fn subtract_identical_polygons_is_empty() {
        let result = boolean_subtract(&square_a(), &square_a());
        assert_empty(&result);
    }

    #[test]
    fn exclude_identical_polygons_is_empty() {
        let result = boolean_exclude(&square_a(), &square_a());
        assert_empty(&result);
    }

    #[test]
    fn union_inner_polygon_is_the_outer() {
        let result = boolean_union(&square_a(), &square_inside());
        assert_region(
            &result,
            100.0,
            &[(5.0, 5.0), (4.0, 4.0)],
            &[(11.0, 11.0)],
            Some((0.0, 0.0, 10.0, 10.0)),
        );
    }

    #[test]
    fn intersection_with_inner_is_the_inner() {
        let result = boolean_intersect(&square_a(), &square_inside());
        assert_region(
            &result,
            16.0,
            &[(5.0, 5.0)],
            &[(2.0, 2.0), (8.0, 8.0)],
            Some((3.0, 3.0, 4.0, 4.0)),
        );
    }

    #[test]
    fn subtract_inner_creates_a_hole() {
        // a − b where b is fully inside a should leave a polygon
        // with a rectangular hole in the middle.
        let result = boolean_subtract(&square_a(), &square_inside());
        assert_region(
            &result,
            100.0 - 16.0,
            // points in the "donut" but not the hole
            &[(1.0, 1.0), (9.0, 9.0), (1.0, 9.0), (9.0, 1.0)],
            // points inside the hole
            &[(5.0, 5.0)],
            Some((0.0, 0.0, 10.0, 10.0)),
        );
    }

    // -------------------------------------------------------------------
    // Non-trivial overlap
    // -------------------------------------------------------------------

    #[test]
    fn union_overlapping_squares_is_l_shape() {
        let result = boolean_union(&square_a(), &square_b_overlap());
        // Union covers both squares minus the 5×5 overlap counted once.
        // = 100 + 100 − 25 = 175.
        assert_region(
            &result,
            175.0,
            &[(2.0, 2.0), (12.0, 12.0), (7.0, 7.0)],
            &[(2.0, 12.0), (12.0, 2.0)],
            Some((0.0, 0.0, 15.0, 15.0)),
        );
    }

    #[test]
    fn intersection_overlapping_squares_is_5x5_square() {
        let result = boolean_intersect(&square_a(), &square_b_overlap());
        assert_region(
            &result,
            25.0,
            &[(7.0, 7.0)],
            &[(2.0, 2.0), (12.0, 12.0)],
            Some((5.0, 5.0, 5.0, 5.0)),
        );
    }

    #[test]
    fn subtract_overlap_leaves_l_shape() {
        // a − b: the part of `a` not covered by `b`. Removes the
        // top-right 5×5 corner, leaving an L-shaped region of area 75.
        let result = boolean_subtract(&square_a(), &square_b_overlap());
        assert_region(
            &result,
            75.0,
            &[(2.0, 2.0), (2.0, 8.0), (8.0, 2.0)],
            &[(7.0, 7.0), (12.0, 12.0)],
            Some((0.0, 0.0, 10.0, 10.0)),
        );
    }

    #[test]
    fn exclude_overlapping_is_two_l_shapes() {
        let result = boolean_exclude(&square_a(), &square_b_overlap());
        // Two L-shapes joined at the corner; total area = 175 − 25 = 150.
        assert_region(
            &result,
            150.0,
            &[(2.0, 2.0), (12.0, 12.0)],
            &[(7.0, 7.0)],
            Some((0.0, 0.0, 15.0, 15.0)),
        );
    }

    // -------------------------------------------------------------------
    // Touching cases (no area overlap)
    //
    // These are the ones that quietly break naïve implementations:
    // edges that coincide exactly, vertices that lie on each other,
    // and shared edges that should not produce sliver artefacts.
    // -------------------------------------------------------------------

    #[test]
    fn union_edge_touching_squares_is_one_rectangle() {
        let result = boolean_union(&square_a(), &square_edge_touching());
        // Union should be a single 20×10 rectangle, area 200.
        assert_region(
            &result,
            200.0,
            &[(5.0, 5.0), (15.0, 5.0)],
            &[(-1.0, 5.0), (21.0, 5.0)],
            Some((0.0, 0.0, 20.0, 10.0)),
        );
    }

    #[test]
    fn intersection_edge_touching_squares_is_empty() {
        // Two squares sharing an edge have *no interior overlap*,
        // so the intersection is empty (or a zero-area edge, which
        // we treat as empty).
        let result = boolean_intersect(&square_a(), &square_edge_touching());
        assert_empty(&result);
    }

    #[test]
    fn subtract_edge_touching_returns_a_unchanged() {
        // Subtracting a polygon that touches but doesn't overlap
        // must not nibble away at the shared edge.
        let result = boolean_subtract(&square_a(), &square_edge_touching());
        assert_region(
            &result,
            100.0,
            &[(5.0, 5.0)],
            &[(15.0, 5.0)],
            Some((0.0, 0.0, 10.0, 10.0)),
        );
    }

    #[test]
    fn union_vertex_touching_squares_is_two_pieces_meeting_at_a_point() {
        // Two squares touching only at the corner (10, 10) should
        // produce a *region* of total area 200. Whether the
        // implementation reports them as one ring with a pinch
        // point or two separate rings is unspecified.
        let result = boolean_union(&square_a(), &square_vertex_touching());
        assert_region(
            &result,
            200.0,
            &[(5.0, 5.0), (15.0, 15.0)],
            &[(5.0, 15.0), (15.0, 5.0)],
            Some((0.0, 0.0, 20.0, 20.0)),
        );
    }

    #[test]
    fn intersection_vertex_touching_is_empty() {
        let result = boolean_intersect(&square_a(), &square_vertex_touching());
        assert_empty(&result);
    }

    // -------------------------------------------------------------------
    // Polygon with a hole as input
    // -------------------------------------------------------------------

    #[test]
    fn intersect_with_holed_polygon_preserves_hole() {
        // Donut: outer 10×10 square minus a 4×4 inner square.
        let donut: PolygonSet = vec![
            vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)],
            vec![(3.0, 3.0), (7.0, 3.0), (7.0, 7.0), (3.0, 7.0)],
        ];
        // Clip rectangle covering the right half of the outer square,
        // including some of the hole.
        let clip: PolygonSet = vec![vec![(5.0, 0.0), (10.0, 0.0), (10.0, 10.0), (5.0, 10.0)]];
        let result = boolean_intersect(&donut, &clip);
        // Intersection: right half of the donut. Area:
        //   right half of outer square = 50
        // − right half of hole         = 8
        //   net                        = 42
        assert_region(
            &result,
            42.0,
            &[(6.0, 1.0), (8.0, 8.0), (9.0, 5.0)],
            &[(5.5, 5.0), (1.0, 1.0)],
            Some((5.0, 0.0, 5.0, 10.0)),
        );
    }

    // -------------------------------------------------------------------
    // Regression / sanity checks for empty operands
    // -------------------------------------------------------------------

    #[test]
    fn union_with_empty_returns_other() {
        let empty: PolygonSet = vec![];
        let result = boolean_union(&square_a(), &empty);
        assert_region(
            &result,
            100.0,
            &[(5.0, 5.0)],
            &[(15.0, 15.0)],
            Some((0.0, 0.0, 10.0, 10.0)),
        );
    }

    #[test]
    fn intersect_with_empty_is_empty() {
        let empty: PolygonSet = vec![];
        let result = boolean_intersect(&square_a(), &empty);
        assert_empty(&result);
    }

    #[test]
    fn subtract_empty_from_a_returns_a() {
        let empty: PolygonSet = vec![];
        let result = boolean_subtract(&square_a(), &empty);
        assert_region(
            &result,
            100.0,
            &[(5.0, 5.0)],
            &[(15.0, 15.0)],
            Some((0.0, 0.0, 10.0, 10.0)),
        );
    }

    #[test]
    fn subtract_a_from_empty_is_empty() {
        let empty: PolygonSet = vec![];
        let result = boolean_subtract(&empty, &square_a());
        assert_empty(&result);
    }

    // -------------------------------------------------------------------
    // Triangle ∩ square — first non-axis-aligned operand
    //
    // Most boolean-op bugs only show up once at least one edge is
    // not horizontal/vertical. Worth covering at least one such
    // case in the spec.
    // -------------------------------------------------------------------

    #[test]
    fn triangle_intersect_square_clips_corner() {
        // Right triangle covering the lower-left of square_a.
        // Vertices: (0, 0), (10, 0), (0, 10). Area = 50.
        let triangle: PolygonSet = vec![vec![(0.0, 0.0), (10.0, 0.0), (0.0, 10.0)]];
        let result = boolean_intersect(&square_a(), &triangle);
        // The triangle is fully inside the square, so the
        // intersection is the triangle itself.
        assert_region(
            &result,
            50.0,
            &[(1.0, 1.0), (3.0, 3.0)],
            &[(8.0, 8.0), (6.0, 6.0)],
            Some((0.0, 0.0, 10.0, 10.0)),
        );
    }

    #[test]
    fn triangle_subtract_square_leaves_other_triangle() {
        // square − triangle (lower-left half) = upper-right half = area 50.
        let triangle: PolygonSet = vec![vec![(0.0, 0.0), (10.0, 0.0), (0.0, 10.0)]];
        let result = boolean_subtract(&square_a(), &triangle);
        assert_region(
            &result,
            50.0,
            &[(8.0, 8.0), (7.0, 5.0)],
            &[(1.0, 1.0), (3.0, 3.0)],
            Some((0.0, 0.0, 10.0, 10.0)),
        );
    }
}
