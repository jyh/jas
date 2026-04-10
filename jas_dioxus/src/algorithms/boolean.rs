//! Boolean operations on planar polygons (union, intersection,
//! difference, exclusive-or).
//!
// The public API is feature-complete and tested but not yet wired into
// the document model — the editor calls into this module via a future
// element-level adapter. Until that lands, every item here looks "dead"
// to cargo's reachability analysis.
#![allow(dead_code)]
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
// All three phases are implemented:
//   - Phase 1: data structures, event queue ordering, sweep loop with
//     in_out / other_in_out / in_result computation, connection step.
//   - Phase 2: intersection detection / edge subdivision.
//   - Phase 3: degeneracy fixes (collinear edges, vertex coincidences,
//     vertical edges, robustness tweaks).
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
/// Snap-rounding ratio: the grid spacing is `SNAP_RATIO * diagonal`
/// of the combined input bounding box. For a typical user-drawn
/// document (diagonal on the order of 10² units) this produces a
/// grid of 10⁻⁷ units — well below any visible resolution but well
/// above the 10⁻¹² / 10⁻⁹ thresholds used inside the sweep. The
/// goal is to fuse points that are "numerically equal" from the
/// algorithm's point of view before they hit the sweep, so the
/// sweep never has to reason about sub-epsilon differences.
const SNAP_RATIO: f64 = 1e-9;

/// Compute the snap-rounding grid spacing for two input polygon
/// sets. Returns `None` if the combined input has no vertices or a
/// zero-diameter bounding box — in that case the caller skips
/// snapping and falls through to the regular empty-operand
/// handling.
///
/// The returned grid is always a **power of 2**. This is critical:
/// `(x / grid) * grid` is bit-exact only for power-of-2 grids, so
/// snap-rounding leaves already-aligned input unchanged down to the
/// last bit (and in particular leaves integer-coordinate fixtures
/// alone). Rounding the ideal grid (`diagonal * SNAP_RATIO`) to the
/// next *larger* power of 2 makes the actual grid slightly coarser
/// than the target, which is harmless — the effective ratio stays
/// within a factor of 2 of the intended value.
fn snap_grid(a: &PolygonSet, b: &PolygonSet) -> Option<f64> {
    let mut min_x = f64::INFINITY;
    let mut min_y = f64::INFINITY;
    let mut max_x = f64::NEG_INFINITY;
    let mut max_y = f64::NEG_INFINITY;
    let mut any = false;
    for ring in a.iter().chain(b.iter()) {
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
    if !any {
        return None;
    }
    let dx = max_x - min_x;
    let dy = max_y - min_y;
    let diagonal = (dx * dx + dy * dy).sqrt();
    if diagonal <= 0.0 {
        return None;
    }
    let target = diagonal * SNAP_RATIO;
    if target <= 0.0 || !target.is_finite() {
        return None;
    }
    // Round target up to the nearest power of 2: 2^ceil(log2(target)).
    let exponent = target.log2().ceil() as i32;
    Some((2.0_f64).powi(exponent))
}

/// Snap each vertex to the nearest point on a `grid`-spaced lattice,
/// remove any consecutive duplicate vertices (including wrap-around),
/// and drop rings that collapse to fewer than 3 distinct vertices.
///
/// Snap-rounding is the standard robustness technique for sweep-line
/// boolean ops: by collapsing vertices that are within half a grid
/// cell of each other, we guarantee that any two "meaningfully
/// different" input features stay distinct, and any two "numerically
/// equal" ones become literally equal. The sweep then never has to
/// choose between `!= 0.0` and `abs(x) < eps` — the answer is the
/// same either way.
fn snap_round(ps: &PolygonSet, grid: f64) -> PolygonSet {
    let snap = |x: f64| (x / grid).round() * grid;
    let mut out: PolygonSet = Vec::with_capacity(ps.len());
    for ring in ps {
        let mut new_ring: Ring = Vec::with_capacity(ring.len());
        for &(x, y) in ring {
            let p = (snap(x), snap(y));
            if new_ring.last() != Some(&p) {
                new_ring.push(p);
            }
        }
        // Wrap-around: if the ring closed back onto its first vertex
        // after snapping, drop the redundant last vertex.
        if new_ring.len() > 1 && new_ring.first() == new_ring.last() {
            new_ring.pop();
        }
        if new_ring.len() >= 3 {
            out.push(new_ring);
        }
    }
    out
}

fn run_boolean(a: &PolygonSet, b: &PolygonSet, op: Operation) -> PolygonSet {
    // Snap-round inputs onto a grid sized as a fixed fraction of the
    // combined bounding-box diagonal. See `SNAP_RATIO`.
    let (a_snap, b_snap) = match snap_grid(a, b) {
        Some(grid) => (snap_round(a, grid), snap_round(b, grid)),
        None => (clone_nondegenerate(a), clone_nondegenerate(b)),
    };

    // Resolve any self-intersections under the non-zero winding fill
    // rule, so the sweep below can keep assuming simple input rings.
    // The normalizer is a no-op for inputs that are already simple,
    // which is the common case.
    let a_norm = crate::algorithms::boolean_normalize::normalize(&a_snap);
    let b_norm = crate::algorithms::boolean_normalize::normalize(&b_snap);

    // The normalizer can introduce new vertices at intersection
    // points that don't land on the snap grid. Re-snap so downstream
    // Martinez still sees grid-aligned input. The grid is unchanged
    // because normalize() doesn't expand the bounding box.
    let (a_final, b_final) = match snap_grid(&a_norm, &b_norm) {
        Some(grid) => (snap_round(&a_norm, grid), snap_round(&b_norm, grid)),
        None => (a_norm, b_norm),
    };

    run_boolean_sweep(&a_final, &b_final, op)
}

/// Run just the Martinez sweep + connection step on already-prepared
/// inputs. Does NOT snap-round, normalize, or otherwise pre-process.
///
/// Factored out so tests can exercise the raw sweep on hand-crafted
/// fixtures where snap-rounding or normalization would otherwise
/// hide the condition under test.
fn run_boolean_sweep(a: &PolygonSet, b: &PolygonSet, op: Operation) -> PolygonSet {
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

    // Build the priority queue. Sorted in *descending* event_less
    // order so `pop` removes the smallest from the back in O(1).
    let mut queue: Vec<usize> = (0..sweep.events.len()).collect();
    queue.sort_by(|&a, &b| {
        if event_less(&sweep.events, a, b) {
            std::cmp::Ordering::Greater
        } else if event_less(&sweep.events, b, a) {
            std::cmp::Ordering::Less
        } else {
            std::cmp::Ordering::Equal
        }
    });

    // Trace of every event we processed, in pop order — needed by
    // the connection step.
    let mut processed: Vec<usize> = Vec::with_capacity(queue.len() * 2);
    let mut status: Vec<usize> = Vec::new(); // sorted by status_less

    while let Some(idx) = queue.pop() {
        processed.push(idx);
        let is_left = sweep.events[idx].is_left;
        if is_left {
            // Insert this edge into the status line at its proper
            // position.
            let pos = status_insert_pos(&sweep.events, &status, idx);
            status.insert(pos, idx);

            // Compute in_out / other_in_out from the edge directly
            // below. We do this *before* intersection handling so
            // the collinear-overlap branch (phase 3) can compare
            // in/out flags between two coincident edges.
            compute_fields(&mut sweep.events, &status, pos);

            // Check for intersections with the new neighbours: the
            // edge directly below (`prev`) and directly above
            // (`next`). Each `possible_intersection` may split one
            // or both edges and queue up the resulting sub-events,
            // *or* set edge_type on this event and the neighbour
            // when the two are collinear and overlapping.
            //
            // After splitting, neither edge changes its position
            // in the status line — only its right endpoint moves
            // — so the slot at `pos` still refers to the current
            // event below.
            if pos + 1 < status.len() {
                let above = status[pos + 1];
                possible_intersection(&mut sweep.events, &mut queue, idx, above, op);
            }
            if pos > 0 {
                let below = status[pos - 1];
                possible_intersection(&mut sweep.events, &mut queue, below, idx, op);
            }

            sweep.events[idx].in_result =
                edge_in_result(&sweep.events[idx], op);
        } else {
            // Right event — find the matching left event in the
            // status line and remove it. After removal, the
            // edges that used to be `pos-1` and `pos+1` become
            // direct neighbours; check them for intersection.
            let other = sweep.events[idx].other_event;
            if let Some(pos) = status.iter().position(|&e| e == other) {
                let above = if pos + 1 < status.len() {
                    Some(status[pos + 1])
                } else {
                    None
                };
                let below = if pos > 0 {
                    Some(status[pos - 1])
                } else {
                    None
                };
                status.remove(pos);
                if let (Some(b), Some(a)) = (below, above) {
                    possible_intersection(&mut sweep.events, &mut queue, b, a, op);
                }
            }
            // Propagate in_result from the left event so the
            // connection step can find both endpoints.
            sweep.events[idx].in_result =
                sweep.events[other].in_result;
        }
    }

    connect_edges(&sweep.events, &processed)
}

/// Find the insertion position for `idx` in `status` such that the
/// resulting `status` is still sorted by [`status_less`].
fn status_insert_pos(events: &[SweepEvent], status: &[usize], idx: usize) -> usize {
    status
        .binary_search_by(|&probe| {
            if status_less(events, probe, idx) {
                std::cmp::Ordering::Less
            } else if status_less(events, idx, probe) {
                std::cmp::Ordering::Greater
            } else {
                std::cmp::Ordering::Equal
            }
        })
        .unwrap_or_else(|e| e)
}

// ---------------------------------------------------------------------------
// Phase 2: priority queue helpers and intersection detection
// ---------------------------------------------------------------------------

/// Insert `idx` into the priority queue, maintaining descending
/// `event_less` order so that the smallest is at the back (where
/// `pop` removes it in O(1)).
fn queue_push(queue: &mut Vec<usize>, events: &[SweepEvent], idx: usize) {
    let pos = queue
        .binary_search_by(|&probe| {
            if event_less(events, probe, idx) {
                // probe is *earlier* than idx — should come *after*
                // idx in the descending arrangement.
                std::cmp::Ordering::Greater
            } else if event_less(events, idx, probe) {
                std::cmp::Ordering::Less
            } else {
                std::cmp::Ordering::Equal
            }
        })
        .unwrap_or_else(|e| e);
    queue.insert(pos, idx);
}

/// Result of intersecting two segments.
#[derive(Debug, Clone, Copy)]
enum Intersection {
    None,
    /// Single intersection point. The point may coincide with an
    /// endpoint of either or both segments — the caller decides
    /// whether splitting is required.
    Point((f64, f64)),
    /// Segments are collinear and share more than a single point.
    /// Phase 2 reports this as `None` and defers all collinear
    /// handling to phase 3, which will inject `EdgeType::*` flags
    /// rather than splitting.
    Overlap,
}

/// Geometric intersection of two segments `a = a1→a2` and
/// `b = b1→b2`.
fn find_intersection(
    a1: (f64, f64),
    a2: (f64, f64),
    b1: (f64, f64),
    b2: (f64, f64),
) -> Intersection {
    let dx_a = a2.0 - a1.0;
    let dy_a = a2.1 - a1.1;
    let dx_b = b2.0 - b1.0;
    let dy_b = b2.1 - b1.1;
    let denom = dx_a * dy_b - dy_a * dx_b;
    if denom.abs() < 1e-12 {
        // Parallel or collinear. We don't try to distinguish them
        // geometrically here; phase 3 handles collinear overlaps.
        return Intersection::Overlap;
    }
    let dx_ab = a1.0 - b1.0;
    let dy_ab = a1.1 - b1.1;
    let s = (dx_b * dy_ab - dy_b * dx_ab) / denom;
    let t = (dx_a * dy_ab - dy_a * dx_ab) / denom;
    // Allow a small slack at the endpoints so vertex-incident
    // intersections aren't missed by FP noise.
    const EPS: f64 = 1e-9;
    if s < -EPS || s > 1.0 + EPS || t < -EPS || t > 1.0 + EPS {
        return Intersection::None;
    }
    let s = s.clamp(0.0, 1.0);
    Intersection::Point((a1.0 + s * dx_a, a1.1 + s * dy_a))
}

/// Test whether the edges represented by left events `e1` and `e2`
/// intersect, and if they do, split each edge at the intersection
/// point so subsequent processing sees a clean partition.
///
/// For *transverse* (non-collinear) intersections this is the
/// phase 2 behaviour: split each edge at the intersection point if
/// it's strictly interior, and queue the new sub-events.
///
/// For *collinear-overlap* intersections this delegates to
/// [`handle_collinear`], which classifies one of the two edges as
/// `EdgeType::NonContributing` and the other as
/// `EdgeType::SameTransition` or `EdgeType::DifferentTransition`,
/// possibly subdividing the longer of the two so the kept and
/// suppressed copies span exactly the overlap region.
fn possible_intersection(
    events: &mut Vec<SweepEvent>,
    queue: &mut Vec<usize>,
    e1: usize,
    e2: usize,
    op: Operation,
) {
    if events[e1].polygon == events[e2].polygon {
        // Edges of the same polygon don't normally intersect in a
        // valid input. Same-polygon collinear overlaps are also
        // skipped — they'd indicate a degenerate self-touching
        // ring which is out of scope.
        return;
    }
    let a1 = events[e1].point;
    let a2 = events[events[e1].other_event].point;
    let b1 = events[e2].point;
    let b2 = events[events[e2].other_event].point;
    match find_intersection(a1, a2, b1, b2) {
        Intersection::None => {}
        Intersection::Point(p) => {
            // Only split an edge if `p` is strictly interior — at
            // an endpoint there's nothing to subdivide.
            if !points_eq(p, a1) && !points_eq(p, a2) {
                divide_segment(events, queue, e1, p);
            }
            if !points_eq(p, b1) && !points_eq(p, b2) {
                divide_segment(events, queue, e2, p);
            }
        }
        Intersection::Overlap => {
            handle_collinear(events, queue, e1, e2, op);
        }
    }
}

/// Phase 3 collinear-overlap handling. Called when
/// [`find_intersection`] reports the two edges as parallel /
/// collinear with non-zero overlap (or possibly parallel-disjoint
/// — we re-check that case here and return early).
///
/// On a real overlap, classifies the kept edge as
/// `SameTransition` (both edges traverse the boundary in the same
/// direction, so they're either both an in-transition or both an
/// out-transition) or `DifferentTransition` (one in, one out), and
/// marks the other as `NonContributing`. The connection step then
/// emits the kept edge once.
///
/// If the overlap is partial — only one endpoint coincides, or
/// neither — the longer edge(s) are subdivided so the kept and
/// suppressed copies have matching endpoints.
fn handle_collinear(
    events: &mut Vec<SweepEvent>,
    queue: &mut Vec<usize>,
    e1: usize,
    e2: usize,
    op: Operation,
) {
    let e1r = events[e1].other_event;
    let e2r = events[e2].other_event;
    let p1l = events[e1].point;
    let p1r = events[e1r].point;
    let p2l = events[e2].point;
    let p2r = events[e2r].point;

    // Re-check true collinearity. find_intersection's "Overlap"
    // result also fires for parallel-but-disjoint segments, so
    // verify that *all four* endpoints lie on the same line.
    if signed_area(p1l, p1r, p2l).abs() > 1e-9
        || signed_area(p1l, p1r, p2r).abs() > 1e-9
    {
        return;
    }

    // Check that the two segments actually overlap (not just
    // collinear-but-disjoint). Project to the dominant axis and
    // intersect the 1-D intervals. The dominant axis is the one
    // with the larger extent, which avoids dividing by a tiny
    // delta on a near-vertical or near-horizontal edge.
    let dx = (p1r.0 - p1l.0).abs();
    let dy = (p1r.1 - p1l.1).abs();
    let proj = |p: (f64, f64)| if dx >= dy { p.0 } else { p.1 };
    let s1_lo = proj(p1l).min(proj(p1r));
    let s1_hi = proj(p1l).max(proj(p1r));
    let s2_lo = proj(p2l).min(proj(p2r));
    let s2_hi = proj(p2l).max(proj(p2r));
    let lo = s1_lo.max(s2_lo);
    let hi = s1_hi.min(s2_hi);
    const TOUCH_EPS: f64 = 1e-9;
    if hi - lo <= TOUCH_EPS {
        // Touch at a single point or fully disjoint — neither is
        // an "overlap" for our purposes.
        return;
    }

    let left_coincide = points_eq(p1l, p2l);
    let right_coincide = points_eq(p1r, p2r);

    // Helper: classify the *kept* edge based on whether the two
    // overlapping edges traverse the boundary in the same
    // direction. The `in_out` field of a left event captures the
    // direction (in→out or out→in) of *its own polygon* across the
    // edge; if both events have the same `in_out`, they agree on
    // the direction of the shared boundary.
    let same_dir = events[e1].in_out == events[e2].in_out;
    let kept_type = if same_dir {
        EdgeType::SameTransition
    } else {
        EdgeType::DifferentTransition
    };

    if left_coincide && right_coincide {
        // Case A — edges are identical. Suppress one copy and
        // classify the other. Recompute in_result for both:
        // e1's in_result was set with EdgeType::Normal earlier
        // and is now stale.
        events[e1].edge_type = EdgeType::NonContributing;
        events[e2].edge_type = kept_type;
        events[e1].in_result = edge_in_result(&events[e1], op);
        events[e2].in_result = edge_in_result(&events[e2], op);
        return;
    }

    if left_coincide {
        // Case B — shared left endpoint, different right
        // endpoints. The shorter edge sits inside the longer; we
        // split the longer at the shorter's right.
        let (longer_left, shorter_right_pt) = if event_less(events, e1r, e2r) {
            // e1's right is earlier, so e1 is the shorter.
            (e2, p1r)
        } else {
            (e1, p2r)
        };
        // Project the split point onto the longer edge so the split
        // lies exactly on the longer's line, not on the (possibly
        // near-parallel) shorter's line.
        let longer_left_pt = events[longer_left].point;
        let longer_right_pt = events[events[longer_left].other_event].point;
        let shorter_right_pt =
            project_onto_segment(longer_left_pt, longer_right_pt, shorter_right_pt);
        // Mark the (now-overlap) portion: the shorter is kept; the
        // longer's left half (after splitting) is suppressed.
        if longer_left == e1 {
            events[e1].edge_type = EdgeType::NonContributing;
            events[e2].edge_type = kept_type;
        } else {
            events[e1].edge_type = kept_type;
            events[e2].edge_type = EdgeType::NonContributing;
        }
        events[e1].in_result = edge_in_result(&events[e1], op);
        events[e2].in_result = edge_in_result(&events[e2], op);
        divide_segment(events, queue, longer_left, shorter_right_pt);
        return;
    }

    if right_coincide {
        // Case C — shared right endpoint, different left
        // endpoints. We split the longer at the later left so that
        // the longer's right half exactly matches the shorter; that
        // right half is the suppressed overlap copy.
        let (longer_left, later_left_pt) = if event_less(events, e1, e2) {
            // e2's left is later, so e2 is the shorter; e1 is longer.
            (e1, p2l)
        } else {
            (e2, p1l)
        };
        // Project the split point onto the longer edge to keep the
        // sub-edges aligned with the longer's direction.
        let longer_left_pt = events[longer_left].point;
        let longer_right_pt = events[events[longer_left].other_event].point;
        let later_left_pt =
            project_onto_segment(longer_left_pt, longer_right_pt, later_left_pt);
        let (_l_split, nr_idx) = divide_segment(events, queue, longer_left, later_left_pt);
        // `nr_idx` is the left event of the longer's right half
        // (later_left_pt → shared right). That sub-edge is
        // collinear with the shorter; mark it suppressed.
        events[nr_idx].edge_type = EdgeType::NonContributing;
        let shorter = if longer_left == e1 { e2 } else { e1 };
        events[shorter].edge_type = kept_type;
        events[nr_idx].in_result = edge_in_result(&events[nr_idx], op);
        events[shorter].in_result = edge_in_result(&events[shorter], op);
        return;
    }

    // Case D — neither endpoint coincides. Two sub-cases:
    //   D1: one edge entirely contains the other.
    //   D2: edges overlap "in the middle" with neither containing
    //       the other.
    //
    // Sort the four endpoints by event order. The middle two span
    // the overlap region.
    let mut endpoints = [e1, e1r, e2, e2r];
    endpoints.sort_by(|&a, &b| {
        if event_less(events, a, b) {
            std::cmp::Ordering::Less
        } else if event_less(events, b, a) {
            std::cmp::Ordering::Greater
        } else {
            std::cmp::Ordering::Equal
        }
    });

    // The first endpoint owns one of the two left events; the
    // last endpoint owns one of the two right events. Determine
    // whether they belong to the same edge (containment) or
    // different edges (mid-overlap).
    let first = endpoints[0];
    let second = endpoints[1];
    let third = endpoints[2];
    let fourth = endpoints[3];

    if events[first].other_event == fourth {
        // Containment: edge `first..fourth` fully contains the
        // other. Split it twice — once at `second.point` and once
        // at `third.point`. The MIDDLE sub-edge of the longer is
        // the one that overlaps the shorter; mark it suppressed.
        //
        // Both split points are endpoints of the CONTAINED edge,
        // which may be slightly off the containing edge's line.
        // Project them onto the containing edge to keep the splits
        // aligned.
        let first_pt = events[first].point;
        let first_other_pt = events[events[first].other_event].point;
        let mid_left = project_onto_segment(first_pt, first_other_pt, events[second].point);
        let mid_right = project_onto_segment(first_pt, first_other_pt, events[third].point);
        // First split: `first` now represents (first.point, mid_left);
        // `nr1` is the left of the right half (mid_left, fourth.point).
        let (_l1, nr1) = divide_segment(events, queue, first, mid_left);
        // Second split (on the right half): `nr1` now represents
        // (mid_left, mid_right); `nr2` is the new left of the
        // tail (mid_right, fourth.point).
        let (_l2, _nr2) = divide_segment(events, queue, nr1, mid_right);
        // After both splits, `nr1` is the middle sub-edge — the
        // one collinear with the shorter. Mark it suppressed.
        events[nr1].edge_type = EdgeType::NonContributing;
        let shorter = if first == e1 { e2 } else { e1 };
        events[shorter].edge_type = kept_type;
        events[nr1].in_result = edge_in_result(&events[nr1], op);
        events[shorter].in_result = edge_in_result(&events[shorter], op);
    } else {
        // Partial overlap: split each edge at the other's interior
        // endpoint. The OVERLAP region is `(second.point,
        // third.point)`; on each edge it forms the right half of
        // the split (since first.point and fourth.point are the
        // outer endpoints of the union of the two segments).
        //
        // After divide_segment(first, second.point):
        //   - `first` represents (first.point, second.point)   non-overlap
        //   - `nr1`   represents (second.point, third.point)   overlap of e_first
        // After divide_segment(other_left, third.point):
        //   - `other_left` represents (second.point, third.point) overlap of e_other
        //   - `nr2`        represents (third.point, fourth.point) non-overlap
        //
        // Each split point is an endpoint of the OTHER edge and may
        // be slightly off the edge being split. Project onto the
        // respective edge to keep all sub-edges exactly aligned.
        let first_pt = events[first].point;
        let first_other_pt = events[events[first].other_event].point;
        let split_a =
            project_onto_segment(first_pt, first_other_pt, events[second].point);
        let other_left = events[fourth].other_event;
        let other_left_pt = events[other_left].point;
        let other_right_pt = events[events[other_left].other_event].point;
        let split_b =
            project_onto_segment(other_left_pt, other_right_pt, events[third].point);
        let (_l1, nr1) = divide_segment(events, queue, first, split_a);
        let (_l2, _nr2) = divide_segment(events, queue, other_left, split_b);
        // `nr1` is the overlap copy from `first`'s edge; suppress it.
        events[nr1].edge_type = EdgeType::NonContributing;
        // `other_left` (whichever of e1/e2 is NOT `first`) is the
        // overlap copy from the other edge; this is the kept one.
        let kept_left = if first == e1 { e2 } else { e1 };
        events[kept_left].edge_type = kept_type;
        events[nr1].in_result = edge_in_result(&events[nr1], op);
        events[kept_left].in_result = edge_in_result(&events[kept_left], op);
    }
}

/// Approximate point equality with the same epsilon used by
/// `find_intersection`.
fn points_eq(a: (f64, f64), b: (f64, f64)) -> bool {
    const EPS: f64 = 1e-9;
    (a.0 - b.0).abs() < EPS && (a.1 - b.1).abs() < EPS
}

/// Project `p` onto the line segment from `a` to `b`, clamped to
/// the segment's endpoints. Returns the point on the segment closest
/// to `p`.
///
/// This is used by [`handle_collinear`] when splitting one edge at
/// a point that is *supposed to be* on that edge but may be slightly
/// off because the two edges are only approximately collinear.
/// Splitting at the raw off-line point produces slanted sub-edges
/// and corrupts the sweep's invariants downstream (see the long
/// comment in `handle_collinear` for history). Projecting onto the
/// edge being split keeps all sub-edges perfectly aligned with the
/// original edge's direction.
fn project_onto_segment(a: (f64, f64), b: (f64, f64), p: (f64, f64)) -> (f64, f64) {
    let dx = b.0 - a.0;
    let dy = b.1 - a.1;
    let len_sq = dx * dx + dy * dy;
    if len_sq == 0.0 {
        return a;
    }
    let t = ((p.0 - a.0) * dx + (p.1 - a.1) * dy) / len_sq;
    let t = t.clamp(0.0, 1.0);
    (a.0 + t * dx, a.1 + t * dy)
}

/// Subdivide the edge whose left event is `edge_left_idx` at point
/// `p`. After this call:
///
/// - the original left event still refers to the *same* point but
///   its right partner has been replaced with a new event at `p`;
/// - a new left event is created at `p` whose right partner is the
///   original right event;
/// - the new "right of the left half" and "left of the right half"
///   events are pushed onto `queue` so they will be processed in
///   priority order.
/// Split an edge at point `p`. Returns `(l_idx, nr_idx)` where:
///   - `l_idx` is the new *right* event of the left half (at `p`).
///   - `nr_idx` is the new *left* event of the right half (at `p`).
///
/// After the call:
///   - `edge_left_idx` (unchanged identity) represents the LEFT half
///     (`orig_left_point` → `p`); its partner is `l_idx`.
///   - `nr_idx` represents the RIGHT half (`p` → `orig_right_point`);
///     its partner is the original right event.
///
/// Callers that need to refer to the right half (e.g.
/// [`handle_collinear`] tagging which sub-segment is the suppressed
/// overlap copy) MUST use `nr_idx` returned here. Walking through
/// `events[events[edge_left_idx].other_event].other_event` resolves
/// back to `edge_left_idx`, not to `nr_idx` — that "round trip" via
/// the new right-of-left-half points back to its own partner, which
/// is `edge_left_idx`.
fn divide_segment(
    events: &mut Vec<SweepEvent>,
    queue: &mut Vec<usize>,
    edge_left_idx: usize,
    p: (f64, f64),
) -> (usize, usize) {
    let edge_right_idx = events[edge_left_idx].other_event;
    let polygon = events[edge_left_idx].polygon;

    // l = right of the left half (at p, is_left = false)
    // nr = left of the right half (at p, is_left = true)
    let l_idx = events.len();
    let nr_idx = l_idx + 1;
    let mut l_event = SweepEvent::new(p, false, polygon);
    l_event.other_event = edge_left_idx;
    let mut nr_event = SweepEvent::new(p, true, polygon);
    nr_event.other_event = edge_right_idx;
    events.push(l_event);
    events.push(nr_event);

    // Re-link partner pointers.
    events[edge_left_idx].other_event = l_idx;
    events[edge_right_idx].other_event = nr_idx;

    queue_push(queue, events, l_idx);
    queue_push(queue, events, nr_idx);

    (l_idx, nr_idx)
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

    // -------------------------------------------------------------------
    // Algebraic property tests
    //
    // These verify identities the four operations are required to
    // satisfy (commutativity, associativity, decomposition,
    // involution). Failures here indicate a structural bug rather
    // than a missed corner case — most often something about how
    // intermediate results round-trip back through the sweep.
    //
    // We compare regions, not vertex sequences. `regions_equal`
    // accepts any vertex/ring/winding representation as long as the
    // covered region matches.
    // -------------------------------------------------------------------

    /// Sample grid covering the bbox of the test fixtures with a
    /// margin. Used to verify two regions cover the same point set.
    /// 21×21 = 441 points spaced 1.0 apart over [-2, 18]² is dense
    /// enough to detect any region-level discrepancy in the test
    /// fixtures (whose features are all integer-aligned).
    fn property_sample_grid() -> Vec<(f64, f64)> {
        let mut pts = Vec::with_capacity(441);
        for i in -2..=18 {
            for j in -2..=18 {
                // Offset by 0.5 so samples land in cell centers and
                // never on a polygon edge.
                pts.push((i as f64 + 0.5, j as f64 + 0.5));
            }
        }
        pts
    }

    /// True iff `p` and `q` represent the same region: same net
    /// even-odd area (within EPS), same inside/outside answer at
    /// every sample grid point, same bounding box (when non-empty).
    ///
    /// This is the equivalence relation the algorithm contract uses.
    /// Vertex order, ring order, ring count, and winding are all
    /// allowed to differ.
    fn regions_equal(p: &PolygonSet, q: &PolygonSet) -> bool {
        if !approx_eq(polygon_set_area(p), polygon_set_area(q)) {
            return false;
        }
        for pt in property_sample_grid() {
            if point_in_polygon_set(p, pt) != point_in_polygon_set(q, pt) {
                return false;
            }
        }
        match (polygon_set_bbox(p), polygon_set_bbox(q)) {
            (None, None) => true,
            (Some(_), None) | (None, Some(_)) => false,
            (Some(a), Some(b)) => {
                approx_eq(a.0, b.0)
                    && approx_eq(a.1, b.1)
                    && approx_eq(a.2, b.2)
                    && approx_eq(a.3, b.3)
            }
        }
    }

    /// Assert two regions are equal, with a diagnostic on failure.
    fn assert_regions_equal(p: &PolygonSet, q: &PolygonSet, label: &str) {
        assert!(
            regions_equal(p, q),
            "{}: regions differ\n  lhs (area {}): {:?}\n  rhs (area {}): {:?}",
            label,
            polygon_set_area(p),
            p,
            polygon_set_area(q),
            q,
        );
    }

    // -------------------------------------------------------------------
    // Commutativity: union, intersection, exclude
    //
    // Subtract is *not* commutative — see `subtract_is_not_commutative`
    // below for the negative pin.
    //
    // Tested against two non-trivial fixtures: overlapping squares
    // and a square containing a smaller square. The disjoint case is
    // omitted because every property is trivially true on it.
    // -------------------------------------------------------------------

    #[test]
    fn union_commutative_overlapping_squares() {
        let a = square_a();
        let b = square_b_overlap();
        assert_regions_equal(&boolean_union(&a, &b), &boolean_union(&b, &a), "union(a,b) vs union(b,a)");
    }

    #[test]
    fn union_commutative_square_with_inside() {
        let a = square_a();
        let b = square_inside();
        assert_regions_equal(&boolean_union(&a, &b), &boolean_union(&b, &a), "union(a,b) vs union(b,a)");
    }

    #[test]
    fn intersect_commutative_overlapping_squares() {
        let a = square_a();
        let b = square_b_overlap();
        assert_regions_equal(
            &boolean_intersect(&a, &b),
            &boolean_intersect(&b, &a),
            "intersect(a,b) vs intersect(b,a)",
        );
    }

    #[test]
    fn intersect_commutative_square_with_inside() {
        let a = square_a();
        let b = square_inside();
        assert_regions_equal(
            &boolean_intersect(&a, &b),
            &boolean_intersect(&b, &a),
            "intersect(a,b) vs intersect(b,a)",
        );
    }

    #[test]
    fn exclude_commutative_overlapping_squares() {
        let a = square_a();
        let b = square_b_overlap();
        assert_regions_equal(
            &boolean_exclude(&a, &b),
            &boolean_exclude(&b, &a),
            "exclude(a,b) vs exclude(b,a)",
        );
    }

    #[test]
    fn exclude_commutative_square_with_inside() {
        let a = square_a();
        let b = square_inside();
        assert_regions_equal(
            &boolean_exclude(&a, &b),
            &boolean_exclude(&b, &a),
            "exclude(a,b) vs exclude(b,a)",
        );
    }

    /// Pin: subtract is *not* commutative. If this test ever starts
    /// failing because someone "fixed" the asymmetry, the algorithm
    /// is wrong, not the test.
    #[test]
    fn subtract_is_not_commutative() {
        let a = square_a();
        let b = square_b_overlap();
        // a − b = L-shape, area 75
        // b − a = L-shape, area 75 (same area, different region!)
        // They have the same magnitude but cover different points.
        let ab = boolean_subtract(&a, &b);
        let ba = boolean_subtract(&b, &a);
        assert!(
            !regions_equal(&ab, &ba),
            "subtract should not be commutative; got equal regions"
        );
    }

    // -------------------------------------------------------------------
    // Decomposition: (a − b) ∪ (a ∩ b) = a
    //
    // This is the "the parts of a outside b, plus the parts of a
    // inside b, recover all of a" identity. It's the closest analog
    // to the user's "subtract then put it back" intuition.
    //
    // The naïve form (a − b) ∪ b is *not* equal to a — it equals
    // a ∪ b, since b's overhang outside a is preserved.
    // -------------------------------------------------------------------

    #[test]
    fn decomposition_overlapping_squares() {
        let a = square_a();
        let b = square_b_overlap();
        let lhs = boolean_union(&boolean_subtract(&a, &b), &boolean_intersect(&a, &b));
        assert_regions_equal(&lhs, &a, "(a − b) ∪ (a ∩ b) vs a");
    }

    #[test]
    fn decomposition_square_with_inside() {
        let a = square_a();
        let b = square_inside();
        let lhs = boolean_union(&boolean_subtract(&a, &b), &boolean_intersect(&a, &b));
        assert_regions_equal(&lhs, &a, "(a − b) ∪ (a ∩ b) vs a");
    }

    // -------------------------------------------------------------------
    // Involution: (a ⊕ b) ⊕ b = a
    //
    // XOR is its own inverse. This exercises the "feed an algorithm
    // result back into the algorithm" path that single-op tests
    // never hit.
    // -------------------------------------------------------------------

    #[test]
    fn exclude_involution_overlapping_squares() {
        let a = square_a();
        let b = square_b_overlap();
        let result = boolean_exclude(&boolean_exclude(&a, &b), &b);
        assert_regions_equal(&result, &a, "(a ⊕ b) ⊕ b vs a");
    }

    #[test]
    fn exclude_involution_square_with_inside() {
        let a = square_a();
        let b = square_inside();
        let result = boolean_exclude(&boolean_exclude(&a, &b), &b);
        assert_regions_equal(&result, &a, "(a ⊕ b) ⊕ b vs a");
    }

    // -------------------------------------------------------------------
    // Associativity (3-input): (a · b) · c = a · (b · c) for · ∈ {∪, ∩, ⊕}
    //
    // Subtract is *not* associative; see `subtract_is_not_associative`
    // below.
    //
    // The Venn fixture is three 10×10 squares arranged so all 7
    // regions of a 3-set Venn diagram are non-empty:
    //
    //   A: (0, 0)-(10, 10)
    //   B: (6, 0)-(16, 10)
    //   C: (3, 6)-(13, 16)
    //
    // Pairwise overlaps:
    //   A ∩ B = (6, 0)-(10, 10)         area 40
    //   A ∩ C = (3, 6)-(10, 10)         area 28
    //   B ∩ C = (6, 6)-(13, 10)         area 28
    //   A ∩ B ∩ C = (6, 6)-(10, 10)     area 16
    //
    // All coordinates are integers, so the algorithm produces
    // clean rational areas with negligible FP error.
    // -------------------------------------------------------------------

    fn venn_a() -> PolygonSet {
        vec![vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]]
    }

    fn venn_b() -> PolygonSet {
        vec![vec![(6.0, 0.0), (16.0, 0.0), (16.0, 10.0), (6.0, 10.0)]]
    }

    fn venn_c() -> PolygonSet {
        vec![vec![(3.0, 6.0), (13.0, 6.0), (13.0, 16.0), (3.0, 16.0)]]
    }

    #[test]
    fn union_associative_three_squares() {
        let a = venn_a();
        let b = venn_b();
        let c = venn_c();
        let lhs = boolean_union(&boolean_union(&a, &b), &c);
        let rhs = boolean_union(&a, &boolean_union(&b, &c));
        assert_regions_equal(&lhs, &rhs, "(a ∪ b) ∪ c vs a ∪ (b ∪ c)");
    }

    #[test]
    fn intersect_associative_three_squares() {
        let a = venn_a();
        let b = venn_b();
        let c = venn_c();
        let lhs = boolean_intersect(&boolean_intersect(&a, &b), &c);
        let rhs = boolean_intersect(&a, &boolean_intersect(&b, &c));
        assert_regions_equal(&lhs, &rhs, "(a ∩ b) ∩ c vs a ∩ (b ∩ c)");
    }

    #[test]
    fn exclude_associative_three_squares() {
        let a = venn_a();
        let b = venn_b();
        let c = venn_c();
        let lhs = boolean_exclude(&boolean_exclude(&a, &b), &c);
        let rhs = boolean_exclude(&a, &boolean_exclude(&b, &c));
        assert_regions_equal(&lhs, &rhs, "(a ⊕ b) ⊕ c vs a ⊕ (b ⊕ c)");
    }

    // ---------- Minimal reproducer for the XOR bug ----------
    //
    // The failing 3-input associativity test was a red herring: the
    // bug is a 2-input XOR bug, not anything about chained ops.
    //
    // Triggering condition: two operand polygons overlap such that
    // one or more *whole edges* are collinear with edges of the
    // other (specifically, the entire top and bottom edges of both
    // squares lie on the same horizontal lines y=0 and y=10).
    //
    // The existing exclude_overlapping_is_two_l_shapes test uses
    // square_b_overlap=(5,5)-(15,15) where the overlap is at a
    // *corner* — no full-edge collinearity — and works correctly.
    //
    // Diagnostic test below verifies the other three ops on the
    // same fixture, to confirm the bug is specific to XOR's
    // collinear-edge classification path.
    #[test]
    fn xor_minimal_repro_shared_top_and_bottom_edges() {
        // a and b overlap on (5,0)-(10,10). Both squares have their
        // top edge at y=10 and their bottom edge at y=0, so the two
        // input polygons share four collinear-edge pairs (the parts
        // of those horizontal edges in the overlap x-range).
        let a: PolygonSet = vec![vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]];
        let b: PolygonSet = vec![vec![(5.0, 0.0), (15.0, 0.0), (15.0, 10.0), (5.0, 10.0)]];
        // Expected XOR region: two disjoint 5x10 strips = (0,0)-(5,10) ∪ (10,0)-(15,10).
        // Total area: 100.
        let result = boolean_exclude(&a, &b);
        let area = polygon_set_area(&result);
        assert!(
            (area - 100.0).abs() < EPS,
            "XOR with shared horizontal edges: expected area 100, got {} (rings: {:?})",
            area,
            result
        );
    }

    // -------------------------------------------------------------------
    // Perturbation / robustness probes
    //
    // These explore what happens when two polygons are "nearly"
    // coincident rather than exactly coincident. The fixture is the
    // shared-edge repro (two 10x10 squares overlapping in 5x10) but
    // with `b` shifted vertically by a small delta, so its top and
    // bottom edges are no longer perfectly collinear with `a`'s.
    //
    // Three epsilons in the implementation govern the behaviour:
    //   - 1e-12 in find_intersection (denom.abs() < 1e-12 -> Overlap)
    //   - 1e-9 in points_eq, handle_collinear collinearity re-check,
    //     find_intersection parameter clamp, overlap extent check
    //   - strict `!= 0.0` in status_less (no epsilon)
    //
    // For each delta we run union and subtract on the perturbed
    // fixture, assert the result area is within 0.1 of correct (a
    // very loose tolerance — we're testing topology, not accuracy),
    // and eprintln the ring structure so any deviation is visible.
    //
    // Each test runs independently so a failing zone doesn't mask
    // the zones below it.

    fn perturbed_fixture(delta: f64) -> (PolygonSet, PolygonSet) {
        let a: PolygonSet = vec![vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]];
        let b: PolygonSet = vec![vec![
            (5.0, delta),
            (15.0, delta),
            (15.0, 10.0 + delta),
            (5.0, 10.0 + delta),
        ]];
        (a, b)
    }

    /// Area tolerance for perturbation tests. At delta <= 1e-6 a
    /// correct algorithm should differ from the ideal area by less
    /// than this; anything larger signals a real topological error.
    const ZONE_TOL: f64 = 0.1;

    fn check_perturbation(delta: f64, label: &str) {
        let (a, b) = perturbed_fixture(delta);
        // Expected areas (ignoring delta's contribution to |b|):
        //   |a ∪ b|  ≈ 150  (rect (0,0)-(15, 10+delta) minus tiny notches)
        //   |a − b|  ≈ 50   (rect (0,0)-(5, 10) plus/minus tiny slivers)
        let u = boolean_union(&a, &b);
        let s = boolean_subtract(&a, &b);
        let u_area = polygon_set_area(&u);
        let s_area = polygon_set_area(&s);
        let u_ok = (u_area - 150.0).abs() < ZONE_TOL;
        let s_ok = (s_area - 50.0).abs() < ZONE_TOL;
        if !u_ok || !s_ok {
            eprintln!("[{}] delta = {:e}", label, delta);
            eprintln!("  union  area = {} (expect ~150) rings = {}", u_area, u.len());
            eprintln!("    {:?}", u);
            eprintln!("  subtract area = {} (expect ~50) rings = {}", s_area, s.len());
            eprintln!("    {:?}", s);
        }
        assert!(u_ok, "{}: union area {} not within {} of 150", label, u_area, ZONE_TOL);
        assert!(s_ok, "{}: subtract area {} not within {} of 50", label, s_area, ZONE_TOL);
    }

    // Zone 1: well below SNAP_RATIO × diagonal. These deltas get
    // fused to zero by snap-rounding at the entry of run_boolean,
    // so the algorithm sees an exact shared-edge fixture.
    #[test]
    fn perturb_1e_minus_15() {
        check_perturbation(1e-15, "1e-15");
    }

    #[test]
    fn perturb_1e_minus_11() {
        check_perturbation(1e-11, "1e-11");
    }

    #[test]
    fn perturb_1e_minus_10() {
        check_perturbation(1e-10, "1e-10");
    }

    // Zone where perturbation survives snap-rounding (above the
    // grid cell) and the edges are distinct enough that
    // find_intersection returns Point, bypassing the collinear path.
    #[test]
    fn perturb_1e_minus_8() {
        check_perturbation(1e-8, "1e-8");
    }

    #[test]
    fn perturb_1e_minus_6() {
        check_perturbation(1e-6, "1e-6");
    }

    #[test]
    fn perturb_1e_minus_3() {
        check_perturbation(1e-3, "1e-3");
    }

    // -------------------------------------------------------------------
    // Projection fix: splits inside handle_collinear should produce
    // sub-edges that are exactly on the edge being split, not off-
    // line "slanted" sub-edges.
    //
    // The projection itself is unit-tested here. End-to-end coverage
    // of the off-line-split bug is indirect — the snap-rounding
    // pre-pass in run_boolean fuses sub-grid perturbations before
    // they can reach handle_collinear, so the ignored perturbation
    // tests pass via snap-rounding rather than via the projection.
    // The projection remains as a defence-in-depth fix so the bug
    // can't resurface if snap-rounding ever misses an input.
    // -------------------------------------------------------------------

    #[test]
    fn project_onto_segment_horizontal() {
        // Point sits above a horizontal edge; projection drops it to
        // the edge's y-coordinate.
        let p = project_onto_segment((0.0, 0.0), (10.0, 0.0), (5.0, 1e-11));
        assert_eq!(p, (5.0, 0.0));
    }

    #[test]
    fn project_onto_segment_vertical() {
        // Point sits just right of a vertical edge; projection snaps
        // to the edge's x-coordinate.
        let p = project_onto_segment((5.0, 0.0), (5.0, 10.0), (5.0 + 1e-11, 7.0));
        assert_eq!(p, (5.0, 7.0));
    }

    #[test]
    fn project_onto_segment_clamps_to_endpoints() {
        // Projection of a point before the segment's start clamps to
        // the start.
        let p = project_onto_segment((0.0, 0.0), (10.0, 0.0), (-5.0, 0.0));
        assert_eq!(p, (0.0, 0.0));
        let q = project_onto_segment((0.0, 0.0), (10.0, 0.0), (15.0, 0.0));
        assert_eq!(q, (10.0, 0.0));
    }

    #[test]
    fn project_onto_segment_diagonal() {
        // 45-degree edge; point slightly off the line projects
        // onto the nearest point on the line.
        let p = project_onto_segment((0.0, 0.0), (10.0, 10.0), (5.0, 5.0 + 1e-10));
        // Projection of (5, 5+1e-10) onto y=x is ((5+5+1e-10)/2, (5+5+1e-10)/2)
        //   = (5 + 5e-11, 5 + 5e-11).
        assert!((p.0 - 5.0).abs() < 1e-10);
        assert!((p.1 - 5.0).abs() < 1e-10);
        // Point is on the line exactly:
        assert_eq!(p.0, p.1);
    }

    #[test]
    fn project_onto_segment_degenerate_edge() {
        // Zero-length "edge": return the start point regardless of p.
        let p = project_onto_segment((5.0, 5.0), (5.0, 5.0), (100.0, 100.0));
        assert_eq!(p, (5.0, 5.0));
    }

    /// All four operations on the shared-edge fixture from
    /// `xor_minimal_repro_shared_top_and_bottom_edges`. This is the
    /// regression check for the collinear-shared-edge bug fixed in
    /// `divide_segment` / `handle_collinear`.
    #[test]
    fn shared_edges_all_ops() {
        let a: PolygonSet = vec![vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]];
        let b: PolygonSet = vec![vec![(5.0, 0.0), (15.0, 0.0), (15.0, 10.0), (5.0, 10.0)]];
        // |a∪b| = 150 (rect (0,0)-(15,10))
        // |a∩b| = 50  (rect (5,0)-(10,10))
        // |a−b| = 50  (rect (0,0)-(5,10))
        // |b−a| = 50  (rect (10,0)-(15,10))
        // |a⊕b| = 100 (the two rects above)
        assert!((polygon_set_area(&boolean_union(&a, &b)) - 150.0).abs() < EPS);
        assert!((polygon_set_area(&boolean_intersect(&a, &b)) - 50.0).abs() < EPS);
        assert!((polygon_set_area(&boolean_subtract(&a, &b)) - 50.0).abs() < EPS);
        assert!((polygon_set_area(&boolean_subtract(&b, &a)) - 50.0).abs() < EPS);
        assert!((polygon_set_area(&boolean_exclude(&a, &b)) - 100.0).abs() < EPS);
    }

    // -------------------------------------------------------------------
    // Self-intersecting input
    //
    // These verify that run_boolean feeds its inputs through the
    // normalizer pre-pass. For a self-intersecting bowtie (figure-8)
    // the filled region under non-zero winding is two triangles
    // meeting at (5, 5); the boolean ops should treat the input as
    // that two-triangle region.
    //
    // Bowtie vertices in visit order: (0,0) → (10,10) → (10,0) →
    // (0,10). Edges (0,0)-(10,10) and (10,0)-(0,10) cross at (5,5).
    // After normalization the input is two triangles:
    //   Left triangle:  (0,0), (5,5), (0,10)   area 25
    //   Right triangle: (5,5), (10,10), (10,0) area 25
    // Total filled area: 50.
    // -------------------------------------------------------------------

    fn bowtie() -> PolygonSet {
        vec![vec![(0.0, 0.0), (10.0, 10.0), (10.0, 0.0), (0.0, 10.0)]]
    }

    #[test]
    fn union_bowtie_with_empty_is_two_triangles() {
        let empty: PolygonSet = Vec::new();
        let result = boolean_union(&bowtie(), &empty);
        let area = polygon_set_area(&result);
        assert!(
            (area - 50.0).abs() < EPS,
            "expected area 50 (two triangles), got {}",
            area
        );
    }

    #[test]
    fn union_bowtie_with_covering_rectangle() {
        // Rectangle (0,0)-(10,10) covers both lobes completely.
        // Result should be the full 10x10 square, area 100.
        let rect: PolygonSet = vec![vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]];
        let result = boolean_union(&bowtie(), &rect);
        let area = polygon_set_area(&result);
        assert!(
            (area - 100.0).abs() < EPS,
            "expected area 100 (rectangle dominates), got {}",
            area
        );
    }

    #[test]
    fn intersect_bowtie_with_covering_rectangle() {
        // Rectangle (0,0)-(10,10) covers both lobes. Intersection
        // is the bowtie's filled region: two triangles, area 50.
        let rect: PolygonSet = vec![vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]];
        let result = boolean_intersect(&bowtie(), &rect);
        let area = polygon_set_area(&result);
        assert!(
            (area - 50.0).abs() < EPS,
            "expected area 50, got {}",
            area
        );
    }

    #[test]
    fn intersect_bowtie_with_bottom_half_rectangle() {
        // Rectangle (0,0)-(10,5) covers the bottom half of the
        // bounding box. Both lobes intersect it:
        //   Left triangle (0,0),(5,5),(0,10) clipped to y<=5
        //     gives (0,0),(5,5),(0,5) — area 12.5
        //   Right triangle (5,5),(10,10),(10,0) clipped to y<=5
        //     gives (5,5),(10,5),(10,0) — area 12.5
        // Total 25.
        let rect: PolygonSet = vec![vec![(0.0, 0.0), (10.0, 0.0), (10.0, 5.0), (0.0, 5.0)]];
        let result = boolean_intersect(&bowtie(), &rect);
        let area = polygon_set_area(&result);
        assert!(
            (area - 25.0).abs() < EPS,
            "expected area 25, got {} (rings: {:?})",
            area,
            result
        );
    }

    #[test]
    fn subtract_rectangle_from_bowtie() {
        // Bowtie − rectangle(0,0)-(10,5). Bowtie filled region is
        // 50; the rectangle removes the bottom 25 (12.5 from each
        // triangle); 25 remains.
        let rect: PolygonSet = vec![vec![(0.0, 0.0), (10.0, 0.0), (10.0, 5.0), (0.0, 5.0)]];
        let result = boolean_subtract(&bowtie(), &rect);
        let area = polygon_set_area(&result);
        assert!(
            (area - 25.0).abs() < EPS,
            "expected area 25, got {} (rings: {:?})",
            area,
            result
        );
    }

    /// Pin: subtract is *not* associative.
    /// (a − b) − c removes the b-and-c overhangs from a;
    /// a − (b − c) removes only the part of b that isn't in c, so
    /// the part of b that *is* in c stays subtracted from a only on
    /// the right side.
    #[test]
    fn subtract_is_not_associative() {
        // Construction: take a = square_a, b = square_b_overlap,
        // c = square_b_overlap. Then:
        //   (a − b) − c = (a − b) − b = a − b           (area 75)
        //   a − (b − c) = a − (b − b) = a − ∅ = a       (area 100)
        // Same operands, different result — confirms non-associativity.
        let a = square_a();
        let b = square_b_overlap();
        let c = square_b_overlap();
        let lhs = boolean_subtract(&boolean_subtract(&a, &b), &c);
        let rhs = boolean_subtract(&a, &boolean_subtract(&b, &c));
        assert!(
            !regions_equal(&lhs, &rhs),
            "subtract should not be associative; got equal regions"
        );
    }
}
