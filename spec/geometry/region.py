"""WHAT A REGION IS -- the denotation, not an algorithm.

This module answers one question: given a list of closed rings and the fill
rule that reads them, IS THIS POINT IN THE REGION? Everything else here
(distance to the boundary, ring simplicity, the sampling box) exists only to
let a checker ask that question at places where it has a defined answer.

It computes no boolean operation, no sweep, no normalisation. It knows
nothing about how a region is produced -- which is the entire point, because
the instrument that rules a producer must not be the producer.

WHERE THE DENOTATION COMES FROM. Not from any implementation. It is the
definition SVG and PDF give for `fill-rule`, restated in this repository's
own spec text, `transcripts/BOOLEAN.md` (RULED 2026-07-26):

    "A polygon set does not have a fill rule of its own -- it CARRIES the one
     its source declared."
    "The rule reads the WHOLE SET AT ONCE, exactly as SVG and PDF define it,
     not ring by ring. Under non-zero, nested same-orientation rings are a
     SOLID and overlapping ones are their UNION; under even-odd they are a
     HOLE and their symmetric difference."
    "Generated results declare EVEN-ODD."

Made executable, that is: cast a ray from the point and count what the
boundary does to it. Under NON-ZERO the point is in the region when the
signed crossing total (the winding number) is not zero; under EVEN-ODD when
the unsigned crossing count is odd. Both totals are taken over EVERY ring of
the set at once, which is what "the rule reads the whole set" means.

WHY THE RAY IS CAST OVER THE OPERANDS AND NEVER OVER THE OUTPUT. A checker
that asks "is this point in the result" and answers it from the result alone
has learned nothing. The law is `a point is in A u B iff it is in A or in B`,
and the left half is computed from the OUTPUT rings while the right half is
computed from the ORIGINAL OPERAND rings. Two independent readings of the
same plane; a producer bug moves one and not the other.

WHAT THIS BUYS THAT ELEMENTWISE RING EQUALITY CANNOT. The region is unique.
The ring encoding is not: ring order, starting vertex, winding direction,
one-ring-versus-two for a pinch, and retained collinear vertices are all
free, and two encodings that differ in every one of those denote the same
region. A law written here rules the region and is blind to the encoding, so
it neither blocks a re-encoding nor is fooled by one.

THE SUBJECT OF MEASUREMENT SETS THE MEASUREMENT'S RESOLUTION -- read this
before writing another sampled clause.

    A sampling box built from the geometry under test is a function of the
    OUTPUT, so an output that runs away carries the instrument with it. Every
    counted quantity stays healthy while the questions being asked move
    somewhere else entirely. Two countermeasures live here, and they are
    different in kind:

      `containment_defect` -- EXACT, no probe, no box. The clause a runaway
      cannot survive, because it is not measured at places the runaway chose.
      Prefer an exact clause whenever the property admits one.

      the INSIDE count -- a sampled clause must publish how many of its
      probes landed in the region being adjudicated, not only how many it
      was willing to answer. A refusal count measures the instrument's
      caution; it does not measure information. A vector can accept 88 of 88
      probes and ask nothing at all about its subject.

THE ULP RULE -- READ BEFORE ADDING A LAW HERE.

    This is a THIRD floating-point dialect and it will not agree bit-for-bit
    with Rust or with Swift on a borderline value. Membership is a
    DISCONTINUOUS function of the point, so a probe within an ulp of an edge
    is exactly where the three dialects may answer differently -- and would
    make a checker FLAKY rather than strict. The countermeasure is not a
    tolerance on the answer (there is no tolerance on a boolean); it is
    `distance_to_boundary` below, and a law that REFUSES to rule a probe
    lying within a declared epsilon of any edge of any operand or of the
    result. A point on a boundary has no defined answer and no law may
    invent one.

UNITS. Coordinates are DOCUMENT POINTS throughout. `EPSILON_POINTS_DEFAULT`
below is stated in the same unit and derived from a real quantisation step;
a law must take its epsilon from its fixture, not from here.
"""

import math

# The two rules a ring set can be read under, spelled as the fixtures spell
# them (`a_fill_rule`, `b_fill_rule`, `fill_rule`).
EVEN_ODD = "evenodd"
NON_ZERO = "nonzero"
FILL_RULES = (EVEN_ODD, NON_ZERO)

# The standing convention for a ring list that declares nothing:
# transcripts/BOOLEAN.md clause 1, "a bare PolygonSet crossing a function
# boundary inside the algorithm layer means EVEN-ODD, already canonical".
DEFAULT_FILL_RULE = EVEN_ODD

# The rule a GENERATED result is read under: BOOLEAN.md clause 4, "Generated
# results declare EVEN-ODD ... because it does not depend on the sweep
# emitting consistent winding: a hole stays a hole even if a future
# connection step hands it back wound the wrong way."
#
# THIS CLAUSE IS LOAD-BEARING FOR EVERY LAW BELOW, and it is not decoration:
# both ports emit `subtract_inner_creates_hole` as an outer ring and a hole
# WOUND THE SAME WAY (shoelace +100 and +16), so the hole's winding number is
# 2 and a non-zero reading of that result would report the hole FILLED. The
# result must be read even-odd or it is misread.
RESULT_FILL_RULE = EVEN_ODD

# A probe closer than this to any edge is refused rather than answered. The
# derivation, which a law must restate in its own fixture rather than inherit
# silently: every port serialises document coordinates through a shared
# 4-decimal formatter, so 1e-4 pt is the finest distinction that survives the
# wire, and a probe must stand off by more than one such step in order for
# the three float dialects to agree which side of an edge it is on. Ten steps
# is the margin taken here; in document points it is a thousandth of a point,
# far below any distinction an artist can make.
EPSILON_POINTS_DEFAULT = 1e-3

# Cross-products below this magnitude are treated as zero. Coordinates in
# this corpus are small (|x| < 1e3), so a cross product of 1e-9 is fifteen
# orders of magnitude below a genuine one; nothing here is scale-free and a
# law over large coordinates must say so.
_AREA_EPS = 1e-9


def _closed_edges(ring):
    """The ring's directed edges, closed, with zero-length edges dropped.

    A zero-length edge crosses no ray and bounds nothing, so dropping it
    changes no region -- and keeping it would make two encodings of the same
    region disagree, which is exactly what this module refuses to do.
    """
    n = len(ring)
    out = []
    for i in range(n):
        a = (float(ring[i][0]), float(ring[i][1]))
        b = (float(ring[(i + 1) % n][0]), float(ring[(i + 1) % n][1]))
        if a != b:
            out.append((a, b))
    return out


def crossings(rings, point):
    """(signed, unsigned) crossing totals of a +x ray from `point`.

    The half-open rule `y1 <= py < y2` counts each crossing exactly once even
    when the ray passes through a vertex, which is what makes the count
    independent of where a ring chooses to start and of whether a collinear
    vertex was retained. `signed` is the winding number; `unsigned` is the
    plain crossing count whose parity is the even-odd answer.
    """
    px, py = float(point[0]), float(point[1])
    signed = unsigned = 0
    for ring in rings:
        for (x1, y1), (x2, y2) in _closed_edges(ring):
            if (y1 <= py) == (y2 <= py):
                continue                      # no crossing of the ray's line
            # Where the edge meets the ray's line, relative to px.
            t = (py - y1) / (y2 - y1)
            xc = x1 + t * (x2 - x1)
            if xc <= px:
                continue                      # the crossing is behind us
            unsigned += 1
            signed += 1 if y2 > y1 else -1
    return signed, unsigned


def winding_number(rings, point):
    """The signed number of times the boundary wraps anticlockwise-in-y-down
    around `point`. Zero iff the point is outside under the non-zero rule."""
    return crossings(rings, point)[0]


def contains(rings, point, rule=DEFAULT_FILL_RULE):
    """Is `point` in the region these rings denote under `rule`?

    NON-ZERO: the winding number is not zero. EVEN-ODD: the crossing count is
    odd. Both read the whole set at once. An unknown rule is REFUSED rather
    than defaulted -- a silent default is how a declared rule gets discarded,
    which is the defect the carried-rule ruling exists to prevent.
    """
    if rule not in FILL_RULES:
        raise ValueError(f"not a fill rule: {rule!r} (expected one of "
                         f"{', '.join(FILL_RULES)})")
    signed, unsigned = crossings(rings, point)
    return (signed != 0) if rule == NON_ZERO else (unsigned % 2 == 1)


def contains_per_ring(rings, point):
    """Per-ring membership: `[bool]`, one entry per ring, each read alone.

    Not a fill rule -- a decomposition. It is what a nesting question is
    asked with (`is this ring inside that one`), and what the laminarity of a
    result is measured over.
    """
    return [crossings([ring], point)[1] % 2 == 1 for ring in rings]


# ---------------------------------------------------------------
# Distance to the boundary -- the instrument that makes a law STRICT
# ---------------------------------------------------------------

def _distance_point_segment(point, a, b):
    px, py = point
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    if dx == 0.0 and dy == 0.0:
        return math.hypot(px - ax, py - ay)
    t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)
    t = max(0.0, min(1.0, t))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def distance_to_boundary(rings, point):
    """The distance from `point` to the nearest edge of any ring.

    `inf` when there is no edge at all, which is the honest answer for an
    empty region: every point is unambiguously outside it.
    """
    best = math.inf
    for ring in rings:
        for a, b in _closed_edges(ring):
            d = _distance_point_segment((float(point[0]), float(point[1])),
                                        a, b)
            if d < best:
                best = d
    return best


def bounding_box(ring_sets):
    """(x0, y0, x1, y1) over every vertex of every ring of every set given,
    or None when there is not one vertex anywhere."""
    xs, ys = [], []
    for rings in ring_sets:
        for ring in rings:
            for pt in ring:
                xs.append(float(pt[0]))
                ys.append(float(pt[1]))
    if not xs:
        return None
    return (min(xs), min(ys), max(xs), max(ys))


def _box_distance(box, point):
    """How far `point` lies outside `box`; 0.0 when it is inside or on it."""
    x0, y0, x1, y1 = box
    dx = max(x0 - point[0], 0.0, point[0] - x1)
    dy = max(y0 - point[1], 0.0, point[1] - y1)
    return math.hypot(dx, dy)


def containment_defect(rings, boxes, epsilon):
    """Which vertex of `rings` escapes EVERY box in `boxes`, or None.

    THE EXACT CLAUSE. It needs no probe, no seed and no sampling box, it is
    O(vertices), and its only tolerance is the serialisation epsilon the
    caller already had to derive. That matters because it is the one clause
    here whose subject is NOT a function of the measurement: everything else
    in this module answers questions AT PLACES, and the places are chosen
    from the geometry being ruled, so a result that runs away takes the
    measurement with it.

    WHY IT IS SOUND FOR A BOOLEAN OF TWO OPERANDS. Every one of the four
    operations returns a SUBSET of `A u B` -- union is A u B itself,
    intersection, difference and symmetric difference are each contained in
    it -- so `closure(result)` is contained in `closure(A) u closure(B)`,
    hence in `bbox(A) u bbox(B)`. A result VERTEX lies on the result's own
    boundary, so it lies in that union. Note the union of two RECTANGLES, not
    the rectangle of the union: the weaker hull form would admit a vertex in
    the empty corner between two distant operands, and there is no reason to
    give that away.

    WHY IT IS SOUND FOR A CANONICALISATION OF ONE. Canonicalisation changes
    the encoding and not the region, and every vertex it emits is an original
    vertex or an intersection of two input edges; both lie in `bbox(input)`.

    WHAT IT CATCHES THAT SAMPLING CANNOT. A far spurious ring -- the named
    failure mode of a sweep-line boolean, where a near-parallel intersection
    is computed at a huge coordinate. Sampling cannot catch it at any density
    a checker can afford, because the sampling box is a function of the
    output: the box grows to span the runaway, every probe still stands clear
    of every edge, the refusal count stays perfect, and NOTHING IS ASKED
    ABOUT THE REGION UNDER TEST. Measured on `union_overlapping_squares`: a
    1pt ring 100pt away left `accepted` at 88 of 88 against a floor of 64
    while the probes landing inside the region fell from 31 to zero.

    `boxes` may contain `None` for an operand with no vertex at all; such an
    operand contains nothing and admits nothing. If EVERY box is None the
    operands are empty, so a result vertex has nowhere legal to be, and the
    first one is reported -- which is the right answer, not an edge case.
    """
    real = [b for b in boxes if b is not None]
    for i, ring in enumerate(rings):
        for j, pt in enumerate(ring):
            p = (float(pt[0]), float(pt[1]))
            gap = min((_box_distance(b, p) for b in real), default=math.inf)
            if gap > epsilon:
                where = "; ".join(f"[{b[0]:g},{b[2]:g}]x[{b[1]:g},{b[3]:g}]"
                                  for b in real) or "(the operands are empty)"
                return (f"vertex {j} of result ring {i}, "
                        f"({p[0]:g}, {p[1]:g}), "
                        f"is {gap:g}pt outside every operand box {where}, "
                        f"tolerance {epsilon:g}pt")
    return None


# ---------------------------------------------------------------
# The structural properties -- what ring equality cannot express
# ---------------------------------------------------------------
#
# A region is a set of points; these two are properties of the ENCODING that
# no membership question can ask, because a badly encoded region can still
# sample correctly. They are the reason the law has a second half.

def _orient(a, b, c):
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])


def _on_segment(a, b, p):
    """`p` is collinear with a-b: does it lie within the segment's span?"""
    return (min(a[0], b[0]) - _AREA_EPS <= p[0] <= max(a[0], b[0]) + _AREA_EPS
            and min(a[1], b[1]) - _AREA_EPS <= p[1] <= max(a[1], b[1])
            + _AREA_EPS)


def segments_meet(a, b, c, d):
    """Do the closed segments a-b and c-d share ANY point?

    Touching counts. This is the non-adjacent test, where any contact at all
    means the ring is not simple.
    """
    o1, o2 = _orient(a, b, c), _orient(a, b, d)
    o3, o4 = _orient(c, d, a), _orient(c, d, b)
    if (abs(o1) > _AREA_EPS and abs(o2) > _AREA_EPS
            and abs(o3) > _AREA_EPS and abs(o4) > _AREA_EPS):
        return (o1 > 0) != (o2 > 0) and (o3 > 0) != (o4 > 0)
    if abs(o1) <= _AREA_EPS and _on_segment(a, b, c):
        return True
    if abs(o2) <= _AREA_EPS and _on_segment(a, b, d):
        return True
    if abs(o3) <= _AREA_EPS and _on_segment(c, d, a):
        return True
    if abs(o4) <= _AREA_EPS and _on_segment(c, d, b):
        return True
    return False


def ring_defect(ring):
    """Why `ring` is not a SIMPLE closed curve bounding a region, or None.

    Simple means what it means in the Jordan sense: at least three distinct
    vertices, a non-zero enclosed area, and a boundary that never revisits a
    place. Consecutive edges may only meet at the vertex they share -- a pair
    that doubles back along itself is a slit, not a boundary.

    THIS IS THE CLAUSE THE PINCH REGRESSION VIOLATES. Both ports once emitted
    the exclusive-or of two overlapping squares as ONE self-touching
    twelve-vertex ring, because a connection step could not tell which of two
    regions touching at a pinch vertex it was on. That ring SAMPLES
    correctly: even-odd membership over it agrees with the region everywhere.
    Only a structural clause can see it.
    """
    pts = [(float(p[0]), float(p[1])) for p in ring]
    edges = _closed_edges(pts)
    if len(edges) < 3:
        return (f"only {len(edges)} non-degenerate edge(s); a ring needs "
                f"three to bound anything")
    area2 = 0.0
    for (x1, y1), (x2, y2) in edges:
        area2 += x1 * y2 - x2 * y1
    if abs(area2) <= _AREA_EPS:
        return (f"encloses no area (shoelace {area2 / 2.0:g}); its vertices "
                f"are collinear or it retraces itself exactly")
    n = len(edges)
    for i in range(n):
        a, b = edges[i]
        for j in range(i + 1, n):
            c, d = edges[j]
            adjacent = (j == i + 1) or (i == 0 and j == n - 1)
            if adjacent:
                # The shared vertex is legal. A DOUBLE-BACK is not: the far
                # endpoint of one edge lying on the other means the pair
                # overlaps rather than turning.
                shared = b if j == i + 1 else a
                far_a = a if j == i + 1 else b
                far_d = d if j == i + 1 else c
                if abs(_orient(far_a, shared, far_d)) <= _AREA_EPS:
                    v1 = (far_a[0] - shared[0], far_a[1] - shared[1])
                    v2 = (far_d[0] - shared[0], far_d[1] - shared[1])
                    if v1[0] * v2[0] + v1[1] * v2[1] > _AREA_EPS:
                        return (f"edges {i} and {j} double back along each "
                                f"other at {shared}: a slit, not a boundary")
                continue
            if segments_meet(a, b, c, d):
                return (f"edges {i} ({a}->{b}) and {j} ({c}->{d}) meet; a "
                        f"simple ring's boundary never revisits a place")
    return None


def laminarity_defect(per_ring_samples, ring_count):
    """Why the rings OVERLAP rather than nest, or None.

    `per_ring_samples` is one `[bool]` per probe, as `contains_per_ring`
    returns. A well-formed region's rings form a LAMINAR family: any two are
    nested one inside the other or their interiors are disjoint, never
    partially overlapping. Sampling can witness a violation but never prove
    its absence, which is the honest strength of a sampled law: if some probe
    is in ring i and not j, another is in j and not i, AND a third is in
    both, then those two boundaries CROSS.

    WHY NOT "non-zero membership equals even-odd membership", which is the
    form this property is usually written in. Because it is FALSE of correct
    output here, and measurably so: both ports emit
    `subtract_inner_creates_hole` with its hole wound the SAME way as its
    outer ring, so the winding number inside the hole is 2 -- non-zero says
    filled, even-odd says empty. That is not a defect; BOOLEAN.md clause 4
    declares results even-odd precisely so that the sweep's winding does not
    have to be consistent. A property phrased over the winding would red on
    shipping, correct geometry. Laminarity says the thing that was meant and
    is winding-blind.
    """
    if ring_count < 2:
        return None
    for i in range(ring_count):
        for j in range(i + 1, ring_count):
            only_i = only_j = both = None
            for k, sample in enumerate(per_ring_samples):
                a, b = sample[i], sample[j]
                if a and b and both is None:
                    both = k
                elif a and not b and only_i is None:
                    only_i = k
                elif b and not a and only_j is None:
                    only_j = k
            if only_i is not None and only_j is not None and both is not None:
                return (f"rings {i} and {j} CROSS: probe #{only_i} is in {i} "
                        f"alone, probe #{only_j} is in {j} alone, and probe "
                        f"#{both} is in both -- two boundaries that partially "
                        f"overlap, which no region's encoding may do")
    return None
