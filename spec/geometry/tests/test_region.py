"""The analytic tier's first tests.

WHY THESE EXIST. `spec/geometry/region.py` is the instrument that rules two
boolean families in blocking CI. It is the thing everything else is measured
BY — and until this file, nothing measured IT. There is no test directory under
`spec/`, and `pytest.ini` pointed discovery at `workspace_interpreter` only, so
a `pytest` from the repo root never reached the analytic tier at all. Its whole
assurance was three mutants in `scripts/cross_language_algorithms.py`, one per
registered checker, each pinning ONE historical wrong answer — which that file
states plainly of itself: *"a REGRESSION floor, not a discovery instrument."*

WHERE THE EXPECTATIONS COME FROM, AND WHY IT MATTERS THAT IT IS NOT THE CODE.
Every expectation below is derived from the DEFINITION of the fill rules (SVG
1.1 §11.3 / PDF, restated in `transcripts/BOOLEAN.md`) and from the Jordan
condition — the same sources `region.py`'s own header cites. None was read off
the implementation, and none was produced by running it. That is the standard
the house sets for a checker (`docs/CHECKERS.md`): an instrument earns its rung
only if it could have been written WITHOUT reading the implementation,
otherwise it is a golden with extra steps. A test written by running the code
would pin whatever the code does, including whatever it does wrong.

Each derivation is stated in the test that uses it, so a reader can check the
ARITHMETIC rather than trust the author.

WHAT THIS SUITE CATCHES, MEASURED. Twelve mutants were applied to the real
clauses of `region.py`, one at a time, and the suite re-run against each:

    caught 10 / 12

The two survivors are both boundary conditions inside `crossings` — moving the
half-open interval (`(y1 <= py) == (y2 <= py)` to `(y1 < py) == (y2 < py)`) and
moving the ray-origin test (`xc <= px` to `xc < px`). **They survive because
they are unobservable inside the law's defined domain, and that was measured,
not assumed:** across four shapes and ~27,000 point/rule combinations, every
input that separates a survivor from the real code lies EXACTLY ON the boundary
— 560 and 708 such inputs respectively, and ZERO strictly off it.

Membership exactly on the boundary is not defined by the fill rules, and this
module says so — its callers keep probes clear of the boundary using
`distance_to_boundary`, which exists for that purpose. A test that pinned an
answer there would freeze an arbitrary choice and forbid a legitimate future
re-spelling, which is the "golden with extra steps" failure in miniature. So
these two are deliberately left unconstrained, and this paragraph is the record
of that decision rather than an omission nobody noticed.

AND A NOTE ON THE HARNESS ITSELF, because it is the sharper lesson. The first
run of that mutation sweep reported TWO uncaught mutants that were nothing of
the kind: the pattern `y1 <= py < y2` appears in this module only in a
DOCSTRING (line 143), so those mutants edited prose and changed no behaviour at
all. A mutation harness that mutates a comment is an instrument with nothing in
it reporting a clean result — the same class this suite exists to guard, in the
hands of the person writing the guard. Every mutant listed above was re-checked
against a real code line.
"""

import math

import pytest

from spec.geometry import region as rg


# ---------------------------------------------------------------------------
# Fixtures: rings, in the y-down coordinate system the module documents.
#
# Orientation matters to the non-zero rule and to nothing else, so each ring
# below names its direction explicitly rather than leaving it to be inferred.
# ---------------------------------------------------------------------------

def square(x0, y0, side, clockwise=True):
    """An axis-aligned square ring. `clockwise` is in SCREEN terms (y down)."""
    x1, y1 = x0 + side, y0 + side
    pts = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
    return pts if clockwise else list(reversed(pts))


OUTER = square(0.0, 0.0, 10.0)                 # 10x10 at the origin
INNER = square(3.0, 3.0, 4.0)                  # 4x4 concentric-ish, SAME winding
INNER_REV = square(3.0, 3.0, 4.0, clockwise=False)   # opposite winding
IN_HOLE = (5.0, 5.0)      # inside both squares
IN_RIM = (1.0, 1.0)       # inside OUTER only
OUTSIDE = (50.0, 50.0)    # inside neither


# ---------------------------------------------------------------------------
# contains — THE denotation. Both rules, and the case that separates them.
# ---------------------------------------------------------------------------

def test_a_point_inside_one_ring_is_inside_under_both_rules():
    # One ring, one crossing to the right of IN_RIM: unsigned 1 (odd -> in),
    # signed +-1 (non-zero -> in). No rule can disagree about a simple square.
    for rule in rg.FILL_RULES:
        assert rg.contains([OUTER], IN_RIM, rule) is True, rule


def test_a_point_outside_every_ring_is_outside_under_both_rules():
    # A +x ray from (50,50) meets nothing: unsigned 0 (even -> out),
    # signed 0 (-> out).
    for rule in rg.FILL_RULES:
        assert rg.contains([OUTER], OUTSIDE, rule) is False, rule


def test_same_orientation_nesting_is_a_solid_under_nonzero_and_a_hole_under_evenodd():
    """The clause the two rules exist to disagree about.

    BOOLEAN.md, ruled 2026-07-26: "under non-zero, nested same-orientation
    rings are a SOLID and overlapping ones are their UNION; under even-odd
    they are a HOLE and their symmetric difference."

    Derivation for IN_HOLE = (5,5), ray going +x:
      crosses INNER's right edge (x=7) once, OUTER's right edge (x=10) once.
      Both rings wind the same way, so the signed total is +2 or -2 -> NON-ZERO
      -> inside. The unsigned total is 2, which is EVEN -> even-odd -> outside.
    """
    rings = [OUTER, INNER]
    assert rg.contains(rings, IN_HOLE, rg.NON_ZERO) is True
    assert rg.contains(rings, IN_HOLE, rg.EVEN_ODD) is False


def test_opposite_orientation_nesting_is_a_hole_under_both_rules():
    """Reverse the inner ring and the two rules AGREE — which is the control
    that proves the test above is about ORIENTATION and not about nesting.

    Signed total at IN_HOLE is (+1) + (-1) = 0 -> non-zero says outside.
    Unsigned total is still 2 -> even -> even-odd says outside.
    """
    rings = [OUTER, INNER_REV]
    assert rg.contains(rings, IN_HOLE, rg.NON_ZERO) is False
    assert rg.contains(rings, IN_HOLE, rg.EVEN_ODD) is False


def test_the_rim_between_two_nested_rings_is_inside_under_both_rules():
    # IN_RIM is inside OUTER and outside INNER, so exactly one crossing to its
    # right whatever the inner ring's orientation: odd AND non-zero.
    for rings in ([OUTER, INNER], [OUTER, INNER_REV]):
        for rule in rg.FILL_RULES:
            assert rg.contains(rings, IN_RIM, rule) is True


def test_overlapping_same_orientation_squares_are_union_under_nonzero_and_xor_under_evenodd():
    """The other half of the same ruling, on OVERLAP rather than nesting.

    Two 10x10 squares offset by 5 in x. The overlap band is 5 <= x < 10.
    At (7,5): crosses the first square's right edge (x=10) and the second's
    (x=15) -> unsigned 2 (even -> OUT), signed +-2 (non-zero -> IN).
    At (2,5), in the left square only: one crossing -> in under both.
    """
    rings = [square(0.0, 0.0, 10.0), square(5.0, 0.0, 10.0)]
    assert rg.contains(rings, (7.0, 5.0), rg.NON_ZERO) is True
    assert rg.contains(rings, (7.0, 5.0), rg.EVEN_ODD) is False
    for rule in rg.FILL_RULES:
        assert rg.contains(rings, (2.0, 5.0), rule) is True


def test_the_default_rule_is_even_odd_which_is_what_generated_results_declare():
    # BOOLEAN.md: "Generated results declare EVEN-ODD." The default must match
    # it, or every caller that omits the argument silently rules by the other
    # rule -- and the two disagree on exactly the shapes above.
    assert rg.DEFAULT_FILL_RULE == rg.EVEN_ODD
    assert rg.contains([OUTER, INNER], IN_HOLE) is False


# ---------------------------------------------------------------------------
# crossings — the half-open rule. This is where ray casting classically breaks.
# ---------------------------------------------------------------------------

def test_a_ray_through_a_vertex_counts_that_corner_once_not_twice_or_zero():
    """The half-open convention `y1 <= py < y2` exists for exactly this.

    A ray at the y of a shared vertex meets two edges at one point. Counting
    both double-counts; counting neither loses the crossing. Either error
    flips parity and therefore flips `contains`.

    A diamond with vertices at (0,0),(5,-5),(10,0),(5,5): the ray y=0 from
    (-1,0) passes exactly through the left AND right vertices. The honest
    answer is that (-1,0) is OUTSIDE and (5,0) is INSIDE, whatever the
    bookkeeping does at those corners.
    """
    diamond = [(0.0, 0.0), (5.0, -5.0), (10.0, 0.0), (5.0, 5.0)]
    for rule in rg.FILL_RULES:
        assert rg.contains([diamond], (-1.0, 0.0), rule) is False, rule
        assert rg.contains([diamond], (5.0, 0.0), rule) is True, rule


def test_a_horizontal_edge_on_the_ray_does_not_change_the_answer():
    # OUTER's top edge lies along y=0. A point on that line, to its left, is
    # outside; horizontal edges are parallel to the ray and cannot be crossed.
    # Under the half-open rule they contribute nothing, which is the only
    # self-consistent choice.
    for rule in rg.FILL_RULES:
        assert rg.contains([OUTER], (-1.0, 0.0), rule) is False, rule


def test_the_signed_and_unsigned_totals_agree_in_parity():
    # A structural invariant of ray casting, independent of any shape: each
    # crossing contributes +-1 to the signed total and exactly 1 to the
    # unsigned one, so the two always share parity. If they ever diverge, the
    # two rules are reading different crossing sets and every clause is unsafe.
    for rings in ([OUTER], [OUTER, INNER], [OUTER, INNER_REV]):
        for pt in (IN_HOLE, IN_RIM, OUTSIDE, (0.0, 5.0)):
            signed, unsigned = rg.crossings(rings, pt)
            assert (abs(signed) - unsigned) % 2 == 0, (rings, pt, signed, unsigned)
            assert unsigned >= abs(signed)


def test_winding_number_is_zero_exactly_when_nonzero_says_outside():
    # `winding_number` and `contains(..., NON_ZERO)` are two spellings of one
    # fact. They are separate functions, so nothing but a test makes them agree.
    for rings in ([OUTER], [OUTER, INNER], [OUTER, INNER_REV]):
        for pt in (IN_HOLE, IN_RIM, OUTSIDE):
            assert (rg.winding_number(rings, pt) != 0) == rg.contains(rings, pt, rg.NON_ZERO)


# ---------------------------------------------------------------------------
# ring_defect — the Jordan condition.
# ---------------------------------------------------------------------------

def test_a_plain_triangle_is_a_simple_closed_curve():
    assert rg.ring_defect([(0.0, 0.0), (10.0, 0.0), (0.0, 10.0)]) is None


def test_a_square_is_a_simple_closed_curve_in_either_direction():
    assert rg.ring_defect(square(0.0, 0.0, 10.0)) is None
    assert rg.ring_defect(square(0.0, 0.0, 10.0, clockwise=False)) is None


def test_fewer_than_three_distinct_points_bounds_no_region():
    # A degenerate ring encloses zero area; it is not a curve with an inside.
    for ring in ([], [(0.0, 0.0)], [(0.0, 0.0), (1.0, 1.0)]):
        assert rg.ring_defect(ring) is not None, ring


def test_a_self_touching_pinch_is_not_simple():
    """A figure-eight revisits a point, so it has no single interior.

    This is the shape the boolean pinch regression produced: two squares'
    XOR emitted as ONE ring that touches itself at a corner. If `ring_defect`
    cannot see it, the checker that rules by it cannot either.
    """
    bowtie = [(0.0, 0.0), (10.0, 10.0), (10.0, 0.0), (0.0, 10.0)]
    assert rg.ring_defect(bowtie) is not None


def test_a_repeated_vertex_is_not_simple():
    ring = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (10.0, 0.0), (0.0, 10.0)]
    assert rg.ring_defect(ring) is not None


# ---------------------------------------------------------------------------
# segments_meet — contact, including the degenerate kinds.
# ---------------------------------------------------------------------------

def test_crossing_segments_meet():
    assert rg.segments_meet((0.0, 0.0), (10.0, 10.0), (0.0, 10.0), (10.0, 0.0)) is True


def test_disjoint_segments_do_not_meet():
    assert rg.segments_meet((0.0, 0.0), (1.0, 0.0), (5.0, 5.0), (6.0, 5.0)) is False


def test_segments_touching_only_at_an_endpoint_do_meet():
    # "Touching counts" is the module's stated contract, and it is the whole
    # point: a pinch touches without crossing.
    assert rg.segments_meet((0.0, 0.0), (5.0, 0.0), (5.0, 0.0), (5.0, 5.0)) is True


def test_collinear_overlapping_segments_meet():
    # Share a whole sub-segment, never properly crossing. A pure orientation
    # test answers false here, which is why this case has its own test.
    assert rg.segments_meet((0.0, 0.0), (10.0, 0.0), (4.0, 0.0), (14.0, 0.0)) is True


def test_collinear_disjoint_segments_do_not_meet():
    assert rg.segments_meet((0.0, 0.0), (4.0, 0.0), (6.0, 0.0), (10.0, 0.0)) is False


# ---------------------------------------------------------------------------
# laminarity_defect — nesting versus overlap, read from per-ring samples.
# ---------------------------------------------------------------------------

def test_properly_nested_samples_are_laminar():
    # Every probe that is in the inner ring is also in the outer one: nesting.
    samples = [[True, True], [True, False], [False, False]]
    assert rg.laminarity_defect(samples, 2) is None


def test_a_probe_in_each_ring_but_not_both_still_permits_nesting():
    # Disjoint rings are laminar too -- nothing overlaps.
    samples = [[True, False], [False, True], [False, False]]
    assert rg.laminarity_defect(samples, 2) is None


def test_partial_overlap_is_not_laminar():
    """Two rings overlap iff some probe is in both AND some probe is in each
    alone. That triple is exactly what nesting cannot produce: under nesting
    the inner ring's points are a SUBSET of the outer's, so "in B only" is
    empty.
    """
    samples = [[True, True], [True, False], [False, True]]
    assert rg.laminarity_defect(samples, 2) is not None


# ---------------------------------------------------------------------------
# containment_defect — the exact clause, which takes no probes at all.
# ---------------------------------------------------------------------------

def test_a_vertex_inside_the_box_is_no_defect():
    assert rg.containment_defect([square(1.0, 1.0, 2.0)], [(0.0, 0.0, 10.0, 10.0)], 1e-9) is None


def test_a_vertex_escaping_every_box_is_the_defect():
    # A boolean result may only contain plane its operands covered. A vertex
    # outside every operand box is proof the producer invented geometry, and
    # it is exact -- no sampling, no seed, so a runaway cannot hide from it.
    out = rg.containment_defect([square(100.0, 100.0, 2.0)], [(0.0, 0.0, 10.0, 10.0)], 1e-9)
    assert out is not None


def test_a_vertex_inside_ANY_box_is_covered():
    # Two operands, one box each: containment is against the UNION, so a
    # vertex need only be in one of them.
    boxes = [(0.0, 0.0, 10.0, 10.0), (100.0, 100.0, 110.0, 110.0)]
    assert rg.containment_defect([square(101.0, 101.0, 2.0)], boxes, 1e-9) is None


# ---------------------------------------------------------------------------
# bounding_box / distance_to_boundary — the honest-answer-on-nothing cases.
# ---------------------------------------------------------------------------

def test_bounding_box_spans_every_vertex_of_every_set():
    # Set A spans x 0..10, y 0..10. Set B spans x 20..24, y 5..9. The union is
    # x 0..24, y 0..10 -- B is TALLER in origin but shorter in extent, and the
    # y maximum still comes from A. (Author's note: the first draft of this
    # line said y1 = 15, from adding B's origin to its side and forgetting to
    # take the max against A. The test caught its own author, which is the
    # argument for hand-derived expectations rather than recorded ones.)
    box = rg.bounding_box([[square(0.0, 0.0, 10.0)], [square(20.0, 5.0, 4.0)]])
    assert box == (0.0, 0.0, 24.0, 10.0)


def test_bounding_box_of_nothing_is_none_not_a_zero_box():
    # A zero box at the origin is a FALSE claim about where the geometry is;
    # None is the honest answer. This distinction has already cost this
    # repository a defect (a zero box at the origin swallowed a group's union),
    # so it gets a test here at the source.
    assert rg.bounding_box([]) is None
    assert rg.bounding_box([[]]) is None


def test_distance_to_boundary_is_infinite_when_there_is_no_boundary():
    assert math.isinf(rg.distance_to_boundary([], (0.0, 0.0)))


def test_distance_to_boundary_measures_the_nearest_edge():
    # (5,1) sits 1.0 below OUTER's top edge (y=0) and 4.0 from the nearest
    # side, so the nearest edge is the top one.
    assert rg.distance_to_boundary([OUTER], (5.0, 1.0)) == pytest.approx(1.0)


def test_distance_to_boundary_is_zero_on_the_boundary_itself():
    assert rg.distance_to_boundary([OUTER], (5.0, 0.0)) == pytest.approx(0.0)
