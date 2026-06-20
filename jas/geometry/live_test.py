"""Tests for geometry.live: element_to_polygon_set, apply_operation,
bounds_of_polygon_set, and CompoundShape.evaluate/bounds.

Mirrors the jas_dioxus live.rs tests for cross-language parity.
"""

def _rect_at(x, y, w=10.0, h=10.0):
    from geometry.element import Rect
    return Rect(x=x, y=y, width=w, height=h, rx=0.0, ry=0.0)


def _bbox(ring):
    xs = [p[0] for p in ring]
    ys = [p[1] for p in ring]
    return (min(xs), min(ys), max(xs), max(ys))


def test_element_to_polygon_set_rect():
    from geometry.live import DEFAULT_PRECISION, element_to_polygon_set
    ps = element_to_polygon_set(_rect_at(0, 0), DEFAULT_PRECISION)
    assert len(ps) == 1
    assert ps[0] == [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]


def test_compound_shape_union_of_two_rects():
    from geometry.element import CompoundOperation, CompoundShape
    from geometry.live import DEFAULT_PRECISION
    cs = CompoundShape(
        operation=CompoundOperation.UNION,
        operands=(_rect_at(0, 0), _rect_at(5, 0)),
    )
    polygons = cs.evaluate(DEFAULT_PRECISION)
    assert len(polygons) == 1
    min_x, min_y, max_x, max_y = _bbox(polygons[0])
    assert abs(min_x - 0.0) < 1e-6
    assert abs(max_x - 15.0) < 1e-6
    assert abs(min_y - 0.0) < 1e-6
    assert abs(max_y - 10.0) < 1e-6


def test_compound_shape_intersection():
    from geometry.element import CompoundOperation, CompoundShape
    from geometry.live import DEFAULT_PRECISION
    cs = CompoundShape(
        operation=CompoundOperation.INTERSECTION,
        operands=(_rect_at(0, 0), _rect_at(5, 0)),
    )
    polygons = cs.evaluate(DEFAULT_PRECISION)
    assert len(polygons) == 1
    min_x, _, max_x, _ = _bbox(polygons[0])
    assert abs(min_x - 5.0) < 1e-6
    assert abs(max_x - 10.0) < 1e-6


def test_compound_shape_exclude_is_symmetric_difference():
    from geometry.element import CompoundOperation, CompoundShape
    from geometry.live import DEFAULT_PRECISION
    cs = CompoundShape(
        operation=CompoundOperation.EXCLUDE,
        operands=(_rect_at(0, 0), _rect_at(5, 0)),
    )
    polygons = cs.evaluate(DEFAULT_PRECISION)
    assert len(polygons) == 2  # two disjoint strips


def test_compound_shape_subtract_front():
    from geometry.element import CompoundOperation, CompoundShape
    from geometry.live import DEFAULT_PRECISION
    cs = CompoundShape(
        operation=CompoundOperation.SUBTRACT_FRONT,
        operands=(_rect_at(0, 0), _rect_at(5, 0)),
    )
    polygons = cs.evaluate(DEFAULT_PRECISION)
    assert len(polygons) == 1
    min_x, _, max_x, _ = _bbox(polygons[0])
    assert abs(min_x - 0.0) < 1e-6
    assert abs(max_x - 5.0) < 1e-6


def test_compound_shape_bounds_reflects_evaluation():
    from geometry.element import CompoundOperation, CompoundShape
    cs = CompoundShape(
        operation=CompoundOperation.UNION,
        operands=(_rect_at(0, 0), _rect_at(5, 0)),
    )
    bx, by, bw, bh = cs.bounds()
    assert abs(bx - 0.0) < 1e-6
    assert abs(by - 0.0) < 1e-6
    assert abs(bw - 15.0) < 1e-6
    assert abs(bh - 10.0) < 1e-6


def test_empty_compound_has_empty_bounds():
    from geometry.element import CompoundOperation, CompoundShape
    cs = CompoundShape(operation=CompoundOperation.UNION, operands=())
    assert cs.bounds() == (0.0, 0.0, 0.0, 0.0)


def test_path_flattens_into_polygon_set():
    from geometry.element import ClosePath, LineTo, MoveTo, Path
    from geometry.live import DEFAULT_PRECISION, element_to_polygon_set
    p = Path(d=(
        MoveTo(0.0, 0.0),
        LineTo(10.0, 0.0),
        LineTo(10.0, 10.0),
        LineTo(0.0, 10.0),
        ClosePath(),
    ))
    ps = element_to_polygon_set(p, DEFAULT_PRECISION)
    assert len(ps) == 1
    min_x, min_y, max_x, max_y = _bbox(ps[0])
    assert abs(min_x - 0.0) < 1e-6
    assert abs(max_x - 10.0) < 1e-6


def test_expand_produces_polygon_per_ring():
    from geometry.element import (
        Color,
        CompoundOperation,
        CompoundShape,
        Fill,
        Polygon,
    )
    from geometry.live import DEFAULT_PRECISION
    red = Fill(color=Color.rgb(1.0, 0.0, 0.0))
    cs = CompoundShape(
        operation=CompoundOperation.EXCLUDE,
        operands=(_rect_at(0, 0), _rect_at(5, 0)),
        fill=red,
    )
    expanded = cs.expand(DEFAULT_PRECISION)
    # XOR of two overlapping rects → 2 non-overlapping strips → 2 polygons
    assert len(expanded) == 2
    for poly in expanded:
        assert isinstance(poly, Polygon)
        assert poly.fill == red


def test_release_returns_operands_verbatim():
    from geometry.element import CompoundOperation, CompoundShape
    r1 = _rect_at(0, 0)
    r2 = _rect_at(5, 0)
    cs = CompoundShape(
        operation=CompoundOperation.UNION,
        operands=(r1, r2),
    )
    released = cs.release()
    assert released == (r1, r2)


def test_multi_subpath_path_yields_multi_ring():
    from geometry.element import ClosePath, LineTo, MoveTo, Path
    from geometry.live import DEFAULT_PRECISION, element_to_polygon_set
    p = Path(d=(
        MoveTo(0.0, 0.0), LineTo(10.0, 0.0), LineTo(10.0, 10.0),
        LineTo(0.0, 10.0), ClosePath(),
        MoveTo(20.0, 0.0), LineTo(30.0, 0.0), LineTo(30.0, 10.0),
        LineTo(20.0, 10.0), ClosePath(),
    ))
    ps = element_to_polygon_set(p, DEFAULT_PRECISION)
    assert len(ps) == 2


# ── ReferenceElem (REFERENCE_GRAPH.md Phase 1a) ─────────────────
# Mirror the jas_dioxus live.rs reference tests for cross-language parity.

class _MapResolver:
    """A test resolver backed by an id→element dict."""
    def __init__(self, mapping):
        self._mapping = mapping

    def resolve(self, ref):
        return self._mapping.get(ref)


def test_recorded_replays_copy_translate_and_re_derives_when_input_changes():
    # Recipe: copy the input "eye", then translate that derived copy +50x.
    # The derived copy is the recorded element's output; editing the source
    # eye must re-derive it live. Mirrors the Rust live.rs test.
    from document.op_log import PrimitiveOp
    from geometry.element import RecordedElem
    from geometry.live import DEFAULT_PRECISION
    recipe = (
        PrimitiveOp(op="copy", params={"from": ["eye"], "dx": 0.0, "dy": 0.0}),
        PrimitiveOp(op="translate", params={"ids": ["$0"], "dx": 50.0, "dy": 0.0}),
    )
    recorded = RecordedElem(ops=recipe, inputs=("eye",), id="rec")

    # Source eye at (0,0,10,10) → derived copy translated +50 → bbox [50,60].
    resolver = _MapResolver({"eye": _rect_at(0, 0)})
    visiting = set()
    ps = recorded.evaluate_with(DEFAULT_PRECISION, resolver, visiting)
    assert len(ps) == 1, "one derived output element"
    min_x, _, max_x, _ = _bbox(ps[0])
    assert abs(min_x - 50.0) < 1e-6 and abs(max_x - 60.0) < 1e-6
    assert visiting == set()

    # Edit the source eye (move to x=100) → the derived copy follows.
    resolver2 = _MapResolver({"eye": _rect_at(100, 0)})
    ps2 = recorded.evaluate_with(DEFAULT_PRECISION, resolver2, set())
    min_x2, _, max_x2, _ = _bbox(ps2[0])
    assert abs(min_x2 - 150.0) < 1e-6 and abs(max_x2 - 160.0) < 1e-6, (
        "derived copy re-derived against the edited source")


def test_recorded_dangling_input_evaluates_empty():
    from document.op_log import PrimitiveOp
    from geometry.element import NullResolver, RecordedElem
    from geometry.live import DEFAULT_PRECISION
    recipe = (
        PrimitiveOp(op="copy", params={"from": ["x"], "dx": 0.0, "dy": 0.0}),
    )
    recorded = RecordedElem(ops=recipe, inputs=("x",))
    ps = recorded.evaluate_with(DEFAULT_PRECISION, NullResolver(), set())
    assert ps == []  # dangling input evaluates empty, never errors


def test_recorded_reports_its_inputs_as_dependencies():
    from document.op_log import PrimitiveOp
    from geometry.element import RecordedElem
    recipe = (
        PrimitiveOp(op="copy", params={"from": ["eye"], "dx": 0.0, "dy": 0.0}),
    )
    recorded = RecordedElem(ops=recipe, inputs=("eye",))
    assert recorded.dependencies() == ["eye"]


def test_recorded_live_round_trips_and_serializes():
    # A RecordedElem in a document survives the binary codec round-trip and
    # serializes the recorded kind + recipe via test_json. Mirrors the Rust
    # live.rs round-trip test.
    from document.document import Document
    from document.op_log import PrimitiveOp
    from geometry.binary import binary_to_document, document_to_binary
    from geometry.element import Layer, RecordedElem
    from geometry.test_json import document_to_test_json
    recipe = (
        PrimitiveOp(op="copy", params={"from": ["eye"], "dx": 0.0, "dy": 0.0}),
        PrimitiveOp(op="translate", params={"ids": ["$0"], "dx": 50.0, "dy": 0.0}),
    )
    rec = RecordedElem(ops=recipe, inputs=("eye",), id="rec")
    layer = Layer(name=None, children=(rec,))
    # No artboards, so the round-trip comparison isolates the recorded element.
    doc = Document(layers=(layer,), artboards=())

    json = document_to_test_json(doc)
    assert '"kind":"recorded"' in json, "serializes kind=recorded"
    assert '"inputs":["eye"]' in json, "serializes the input ids"
    assert '"op":"copy"' in json, "serializes the recipe ops"

    bytes_ = document_to_binary(doc, compress=False)
    back = binary_to_document(bytes_)
    assert document_to_test_json(back) == json, (
        "recorded element survives the binary round-trip")


def test_capture_recipe_normalizes_select_copy_move_to_input_addressed():
    # A captured journal segment ("watch what I did"): select the eye, copy
    # it, move the copy. select_rect carries its resolved targets (the
    # selected ids), as the op-capture path will populate. Mirrors the Rust
    # live.rs capture_recipe test.
    from document.op_log import PrimitiveOp
    from geometry.element import RecordedElem
    from geometry.live import DEFAULT_PRECISION, capture_recipe
    segment = [
        PrimitiveOp(op="select_rect", params={}, targets=["eye"]),
        PrimitiveOp(op="copy_selection", params={"dx": 0.0, "dy": 0.0}),
        PrimitiveOp(op="move_selection", params={"dx": 50.0, "dy": 0.0}),
    ]
    recipe, inputs = capture_recipe(segment)

    # Normalized to the input-addressed recipe; the read element is the input.
    assert inputs == ["eye"]
    assert len(recipe) == 2
    assert recipe[0].op == "copy"
    assert recipe[0].params["from"] == ["eye"]
    assert recipe[1].op == "translate"
    assert recipe[1].params["ids"] == ["$0"], (
        "the move targets the produced copy, not the input")

    # The captured recipe replays + re-derives like the hand-built one.
    recorded = RecordedElem(ops=tuple(recipe), inputs=tuple(inputs), id="rec")
    resolver = _MapResolver({"eye": _rect_at(0, 0)})
    ps = recorded.evaluate_with(DEFAULT_PRECISION, resolver, set())
    assert len(ps) == 1
    min_x, _, max_x, _ = _bbox(ps[0])
    assert abs(min_x - 50.0) < 1e-6 and abs(max_x - 60.0) < 1e-6, (
        "the captured recipe replays to the demonstrated output")


def test_capture_recipe_passes_through_id_primary_segment_no_selection_dep():
    # OP_LOG.md §5 Fork 4 / 3c-1: an id-primary journal segment captures as a
    # PASS-THROUGH — every operand id is read from the op PARAMS, never from a
    # select op's selection-resolved ``targets`` (note targets is EMPTY here, so a
    # capture that read targets would produce an empty recipe). select_by_ids sets
    # the working set; copy_by_ids -> copy{from}; move_by_ids -> translate on the
    # produced $0 handle. Mirrors the Rust live.rs test.
    from document.op_log import PrimitiveOp
    from geometry.element import RecordedElem
    from geometry.live import DEFAULT_PRECISION, capture_recipe
    segment = [
        PrimitiveOp(op="select_by_ids", params={"ids": ["eye"]}, targets=[]),
        PrimitiveOp(op="copy_by_ids",
                    params={"from": ["eye"], "dx": 0.0, "dy": 0.0}, targets=[]),
        PrimitiveOp(op="move_by_ids",
                    params={"ids": [], "dx": 50.0, "dy": 0.0}, targets=[]),
    ]
    recipe, inputs = capture_recipe(segment)

    # Operands came from params (targets was empty), so the recipe is non-empty.
    assert inputs == ["eye"]
    assert len(recipe) == 2
    assert recipe[0].op == "copy"
    assert recipe[0].params["from"] == ["eye"]
    assert recipe[1].op == "translate"
    assert recipe[1].params["ids"] == ["$0"], (
        "the move targets the produced copy handle, not the id-less copy")

    # The captured recipe replays + re-derives identically to the
    # selection-relative capture (proving the two capture forms agree).
    recorded = RecordedElem(ops=tuple(recipe), inputs=tuple(inputs), id="rec")
    resolver = _MapResolver({"eye": _rect_at(0, 0)})
    ps = recorded.evaluate_with(DEFAULT_PRECISION, resolver, set())
    assert len(ps) == 1
    min_x, _, max_x, _ = _bbox(ps[0])
    assert abs(min_x - 50.0) < 1e-6 and abs(max_x - 60.0) < 1e-6, (
        "the id-primary captured recipe replays to the demonstrated output")


def test_capture_recipe_id_primary_bare_move_reads_ids_from_params():
    # A bare id-primary move (no preceding copy): the working set is the op's own
    # ``ids`` PARAM, so translate operates on the named input directly. Mirrors the
    # Rust live.rs test.
    from document.op_log import PrimitiveOp
    from geometry.live import capture_recipe
    segment = [
        PrimitiveOp(op="select_by_ids", params={"ids": ["eye"]}, targets=[]),
        PrimitiveOp(op="move_by_ids",
                    params={"ids": ["eye"], "dx": 50.0, "dy": 0.0}, targets=[]),
    ]
    recipe, inputs = capture_recipe(segment)
    assert inputs == ["eye"]
    assert len(recipe) == 1
    assert recipe[0].op == "translate"
    assert recipe[0].params["ids"] == ["eye"], (
        "a bare id-primary move translates the named input directly")


def test_reference_evaluates_to_target_geometry():
    from geometry.element import ReferenceElem
    from geometry.live import DEFAULT_PRECISION
    resolver = _MapResolver({"r1": _rect_at(0, 0)})
    reference = ReferenceElem(target="r1")
    visiting = set()
    ps = reference.evaluate_with(DEFAULT_PRECISION, resolver, visiting)
    assert len(ps) == 1
    min_x, _, max_x, _ = _bbox(ps[0])
    assert abs(min_x - 0.0) < 1e-6
    assert abs(max_x - 10.0) < 1e-6
    # The cycle-guard set is left clean after a successful resolve.
    assert visiting == set()


def test_dangling_reference_evaluates_empty():
    from geometry.element import NullResolver, ReferenceElem
    from geometry.live import DEFAULT_PRECISION
    reference = ReferenceElem(target="missing")
    ps = reference.evaluate_with(DEFAULT_PRECISION, NullResolver(), set())
    assert ps == []  # dangling reference evaluates empty, never errors


def test_reference_cycle_breaks_to_empty():
    from geometry.element import Element, ReferenceElem
    from geometry.live import DEFAULT_PRECISION

    # Resolver where id "a" resolves to a reference back to "a" — a
    # self-cycle. The threaded visited-set must break it.
    class _CycleResolver:
        def resolve(self, ref):
            if ref == "a":
                return ReferenceElem(target="a")
            return None

    reference = ReferenceElem(target="a")
    visiting = set()
    ps = reference.evaluate_with(DEFAULT_PRECISION, _CycleResolver(), visiting)
    assert ps == []  # cycle breaks to empty, no infinite recursion
    assert visiting == set()  # cycle-guard set restored after evaluation


def test_reference_reports_its_target_as_dependency():
    from geometry.element import ReferenceElem
    reference = ReferenceElem(target="t")
    assert reference.dependencies() == ["t"]


# ── Symbols P4: the instance transform field (SYMBOLS.md §4 / Fork F2) ──
# Mirror the jas_dioxus live.rs instance-transform eval tests. The instance
# transform (ReferenceElem.instance_transform) is distinct from the render
# CTM (ReferenceElem.transform / common.transform); it is applied to the
# resolved PolygonSet here, the single eval seam.

def test_reference_instance_transform_scales_target_geometry():
    # A reference whose instance transform is scale(2,2), targeting a 10x10
    # rect at the origin, evaluates to the rect geometry scaled 2x (a 20x20
    # ring). The instance transform is applied to every point of the resolved
    # PolygonSet (composition: instance.transform ∘ geometry).
    from geometry.element import ReferenceElem, Transform
    from geometry.live import DEFAULT_PRECISION
    resolver = _MapResolver({"r1": _rect_at(0, 0)})
    reference = ReferenceElem(target="r1",
                             instance_transform=Transform.scale(2.0, 2.0))
    visiting = set()
    scaled = reference.evaluate_with(DEFAULT_PRECISION, resolver, visiting)

    # Unscaled reference for comparison.
    plain = ReferenceElem(target="r1")
    unscaled = plain.evaluate_with(
        DEFAULT_PRECISION, _MapResolver({"r1": _rect_at(0, 0)}), set())

    assert len(scaled) == len(unscaled)  # same ring count, just scaled
    sminx, sminy, smaxx, smaxy = _bbox(scaled[0])
    uminx, uminy, umaxx, umaxy = _bbox(unscaled[0])
    assert abs(sminx - uminx * 2.0) < 1e-6
    assert abs(sminy - uminy * 2.0) < 1e-6
    assert abs(smaxx - umaxx * 2.0) < 1e-6
    assert abs(smaxy - umaxy * 2.0) < 1e-6
    # Concretely: the 10x10 rect at origin scales to a 20x20 box.
    assert abs(sminx - 0.0) < 1e-6 and abs(sminy - 0.0) < 1e-6
    assert abs(smaxx - 20.0) < 1e-6 and abs(smaxy - 20.0) < 1e-6
    assert visiting == set()


def test_reference_none_instance_transform_leaves_eval_unchanged():
    # The default instance transform is None; eval is identical to the
    # resolved target geometry (no transform applied, no double-apply).
    from geometry.element import ReferenceElem
    from geometry.live import DEFAULT_PRECISION, element_to_polygon_set
    resolver = _MapResolver({"r1": _rect_at(0, 0)})
    reference = ReferenceElem(target="r1")
    assert reference.instance_transform is None  # defaults to None
    via_ref = reference.evaluate_with(DEFAULT_PRECISION, resolver, set())
    # Equal to evaluating the target rect directly.
    direct = element_to_polygon_set(_rect_at(0, 0), DEFAULT_PRECISION)
    assert via_ref == direct


def test_compound_dependencies_default_empty():
    from geometry.element import CompoundOperation, CompoundShape
    cs = CompoundShape(operation=CompoundOperation.UNION, operands=())
    assert cs.dependencies() == []


def test_element_to_polygon_set_resolves_reference():
    """A reference embedded in element_to_polygon_set_with resolves
    through the supplied resolver."""
    from geometry.element import ReferenceElem
    from geometry.live import DEFAULT_PRECISION, element_to_polygon_set_with
    resolver = _MapResolver({"r1": _rect_at(0, 0)})
    reference = ReferenceElem(target="r1")
    ps = element_to_polygon_set_with(reference, DEFAULT_PRECISION, resolver, set())
    assert len(ps) == 1
    min_x, _, max_x, _ = _bbox(ps[0])
    assert abs(min_x - 0.0) < 1e-6
    assert abs(max_x - 10.0) < 1e-6


def test_reference_via_null_resolver_is_dangling():
    """The 2-arg element_to_polygon_set wrapper uses a NullResolver, so a
    reference resolves to empty (existing call sites stay safe)."""
    from geometry.element import ReferenceElem
    from geometry.live import DEFAULT_PRECISION, element_to_polygon_set
    ps = element_to_polygon_set(ReferenceElem(target="r1"), DEFAULT_PRECISION)
    assert ps == []


# ── resolver_from_document (REFERENCE_GRAPH.md Phase 1b-ii) ──────
# Mirror jas_dioxus render.rs render_ref_index_resolves_reference_to_target:
# the render-scoped id->element resolver built from a Document resolves a
# by-id reference's target so it can display.


def test_resolver_from_document_resolves_reference_to_target():
    from dataclasses import replace
    from document.document import Document
    from geometry.element import Layer, ReferenceElem
    from geometry.live import DEFAULT_PRECISION, resolver_from_document

    # Document: one layer holding a rect with id "r1".
    rect = replace(_rect_at(0, 0), id="r1")
    doc = Document(layers=(Layer(name="Layer", children=(rect,)),))

    resolver = resolver_from_document(doc)
    # The rect is indexed by its id.
    assert resolver.resolve("r1") is rect
    # A missing id resolves to None (dangling, never an error).
    assert resolver.resolve("missing") is None

    # A reference to "r1" evaluates (via evaluate_with + the resolver) to
    # the rect's single ring.
    reference = ReferenceElem(target="r1")
    ps = reference.evaluate_with(DEFAULT_PRECISION, resolver, set())
    assert len(ps) == 1
    min_x, min_y, max_x, max_y = _bbox(ps[0])
    assert abs(min_x - 0.0) < 1e-6
    assert abs(min_y - 0.0) < 1e-6
    assert abs(max_x - 10.0) < 1e-6
    assert abs(max_y - 10.0) < 1e-6


def test_resolver_from_document_indexes_nested_descendants():
    """resolver_from_document recurses into Group/Layer children, but a
    top-level layer's own id is not a Phase-1 target."""
    from dataclasses import replace
    from document.document import Document
    from geometry.element import Group, Layer
    from geometry.live import resolver_from_document

    inner = replace(_rect_at(0, 0), id="deep")
    group = Group(children=(inner,), id="grp")
    layer = Layer(name="Layer", children=(group,), id="lyr")
    doc = Document(layers=(layer,))

    resolver = resolver_from_document(doc)
    # Nested shape and intermediate group are indexed.
    assert resolver.resolve("deep") is inner
    assert resolver.resolve("grp") is group
    # The top-level layer id is intentionally excluded (references
    # target shapes, not layers). Mirrors Rust register_ref_index.
    assert resolver.resolve("lyr") is None


# ── Symbols P1: an instance resolves a master from doc.symbols ──────
# Mirror jas_dioxus live.rs instance_resolves_to_master_geometry_from_symbols
# and render.rs render_ref_index_resolves_master_from_symbols.


def test_resolver_from_document_resolves_master_from_symbols():
    """SYMBOLS.md §10 RESOLVE gate: ONE master rect (id "m1") in
    doc.symbols and ONE instance (a ReferenceElem id "i1" targeting "m1")
    in a layer. resolver_from_document ALSO indexes doc.symbols (a master's
    OWN id is the target), so the instance evaluates to the master's
    geometry — non-empty and equal to the rect's polygon set. This is the
    whole point of the off-canvas store: masters are resolvable but never in
    `layers`, so render never paints them."""
    from dataclasses import replace
    from document.document import Document
    from geometry.element import Layer, ReferenceElem
    from geometry.live import (
        DEFAULT_PRECISION,
        element_to_polygon_set,
        resolver_from_document,
    )

    # The master rect (matching symbols_basic) lives ONLY in doc.symbols.
    master = replace(_rect_at(9.0, 18.0, 27.0, 36.0), id="m1")
    # The instance lives in a layer, off the master.
    instance = ReferenceElem(target="m1", id="i1")
    doc = Document(
        layers=(Layer(name="Layer", children=(instance,)),),
        symbols=(master,),
    )

    resolver = resolver_from_document(doc)
    # The master (off-canvas) resolves by its OWN id from doc.symbols.
    assert resolver.resolve("m1") is master
    # The instance evaluates to the master's geometry (a single ring) equal
    # to evaluating the master rect directly.
    visiting: set = set()
    resolved = instance.evaluate_with(DEFAULT_PRECISION, resolver, visiting)
    assert resolved, "instance must resolve to the master geometry"
    master_ps = element_to_polygon_set(master, DEFAULT_PRECISION)
    assert resolved == master_ps, (
        "resolved instance geometry must equal the master rect's polygon set")
    assert not visiting, "cycle-guard set restored after resolve"
    # Masters are never painted: the master lives only in doc.symbols, never
    # in the layer tree (the off-canvas guarantee).
    assert len(doc.layers[0].children) == 1, "layer holds only the instance"
    assert doc.layers[0].children[0] is instance
    assert len(doc.symbols) == 1, "the master lives only in doc.symbols"


# ── GeneratedElem (CONCEPTS.md §6) ──────────────────────────────
# Mirror the jas_dioxus live.rs generated tests for cross-language parity.

def test_generated_evaluates_via_concept_resolver():
    # A resolver supplying one concept generator; the Generated element
    # evaluates through it to the concept's geometry (registry -> generator ->
    # points). With no concept (NullResolver) it evaluates empty, never raises.
    from geometry.element import GeneratedElem, ConceptDef, NullResolver
    from geometry.live import element_to_polygon_set_with, DEFAULT_PRECISION

    class _ConceptResolver:
        def resolve(self, ref):
            return None

        def resolve_concept(self, concept_id):
            if concept_id == "regular_polygon":
                return ConceptDef(
                    generator=(
                        "map(range(0, param.sides), fun i -> "
                        "let a = 360 * i / param.sides in "
                        "[param.radius * cos(a), param.radius * sin(a)])"),
                    closed=True)
            return None

    ge = GeneratedElem(concept_id="regular_polygon",
                       params={"sides": 4, "radius": 10})
    ps = element_to_polygon_set_with(
        ge, DEFAULT_PRECISION, _ConceptResolver(), set())
    assert len(ps) == 1, "one ring"
    assert len(ps[0]) == 4, "a square has 4 vertices"
    assert abs(ps[0][0][0] - 10.0) < 1e-9 and abs(ps[0][0][1]) < 1e-9, \
        "first vertex on +x at radius 10"

    # Unknown concept (NullResolver) -> empty, no error.
    assert element_to_polygon_set_with(
        ge, DEFAULT_PRECISION, NullResolver(), set()) == []


def test_dict_resolver_resolves_concepts_from_registry():
    # The production DictResolver resolves concept packs from the workspace
    # registry, so a placed Generated instance evaluates its geometry on the
    # render path (CONCEPTS.md 3b render wiring; mirrors Rust/Swift).
    from geometry.live import DictResolver
    from geometry.element import GeneratedElem

    r = DictResolver({})
    d = r.resolve_concept("regular_polygon")
    assert d is not None
    assert "cos(" in d.generator
    assert r.resolve_concept("no_such_concept") is None

    ge = GeneratedElem(concept_id="regular_polygon",
                       params={"sides": 4, "radius": 10})
    ps = ge.evaluate_with(1.0, r, set())
    assert len(ps) == 1
    assert len(ps[0]) == 4
