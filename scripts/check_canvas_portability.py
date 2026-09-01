#!/usr/bin/env python3
"""Every `ctx.*` call in `canvas/` must have a declared `Painter` mapping.

WHY THIS EXISTS. `canvas::render()` takes a `web_sys::CanvasRenderingContext2d`
and `pub mod canvas` is `#[cfg(feature = "web")]`, so the production document
walk is NOT COMPILED AT ALL in the native build. Until it takes a
`&mut dyn Painter`, no native surface -- Direct2D, and therefore no Windows
window -- can show a document. That port is the architectural node; this gate is
its ratchet.

MEASURED 2026-08-31 before this gate was written:

  270 `ctx.*` call sites, 45 distinct methods, across 5,872 lines of `canvas/`.
  The `Painter` trait has 17 methods and exactly ONE query (`supports`).

RE-MEASURED 2026-09-01 when the pattern was widened (see CALL below): the
original `\\bctx\\.` could not see a receiver named `off_ctx` / `luma_ctx` /
`art_ctx` (no word boundary after `_`), a `ctx()` accessor, or a call chained
onto the next line -- so the real figure was 300 sites over 46 methods, and
`clear_rect` was a method the gate had never met. A gate that under-counts
its subject under-prices the work it exists to price; the widened pattern is
what this file measures with now, and comment text is stripped first so a
method NAMED in prose is never counted as a call.

⇒ THE TWO SIDES SPEAK DIFFERENT VOCABULARIES, and that is the real work. Canvas2D
is a STATEFUL PATH BUILDER (`begin_path` / `move_to` / `line_to` / `fill`);
`Painter` is WHOLE-PRIMITIVE (`fill_path` takes a complete path). Porting is
therefore accumulation and re-expression, not substitution -- but it is
MECHANICAL for 264 of the 270 sites, and this gate exists to keep the remaining
six honest rather than to relitigate them.

⛔ THE SIX THAT DID NOT MAP were a RATIFIED-INTERFACE question, and it was
RULED (the helm, 2026-08-31 19:42, design word; council 2026-09-01 r.6c): the
trait does NOT grow. `measure_text` became a query on the crate's font-metrics
provider (`text_measure`); `get_image_data` / `put_image_data` /
`draw_image_with_html_canvas_element` became the caller-owned surface service
(`crate::surface`, web impl `surface::web::WebSurface`); `ctx.canvas` was
deleted in favour of a `TargetSize` parameter threaded from `render()`. The
`UNMAPPED` table below is therefore EMPTY -- kept as a table, with its rule,
because a new unmappable method is exactly the event this gate must red on.

⛔ AND THE BACKENDS DO NOT REACH INTO `canvas/`. Before 2026-09-01 the web
painter called `canvas::render::promote_mask_to_luminance` and
`canvas::render::blend_mode_css` -- a backend depending on the web-only legacy
walk it exists to replace. Both now live in `surface`; `painter/` referencing
`crate::canvas` is a red here (`check_backends`).

HOW THIS GATE IS MEANT TO BE USED. It is a RATCHET, not a wall. `UNMAPPED` may
only shrink. A NEW unmapped `ctx.*` method reds immediately; retiring one is a
one-line edit made in the same commit that removes its last call site. That way
the port can proceed incrementally -- which is the direction this codebase is
already going, having repeatedly extracted logic OUT of `canvas::render` for
exactly this reason (see `document/evaluated_bounds.rs`, whose header says so).

NOT CLAIMED: that the 264 mapped sites are EASY, only that a mapping exists for
each. This gate checks vocabulary, never behaviour.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
CANVAS = REPO / "jas_dioxus" / "src" / "canvas"

# Any receiver whose name ENDS in `ctx` (`ctx`, `off_ctx`, `luma_ctx`, `octx`),
# with or without a `()` accessor call (`off.ctx().set_transform`), followed by
# a method -- across whitespace and line breaks, so a chain broken onto the
# next line is still one site. `\b` before `[a-z_]*ctx` still anchors the
# receiver to a word start, so `context.` does not match (`context` does not
# end in `ctx`).
CALL = re.compile(r"\b[a-z_]*ctx(?:\(\))?\s*\.\s*([a-z_][a-z0-9_]*)")

# Comment text is not a call site. Strip `//` line comments (doc comments
# included) before scanning; a method named in prose beside its call would
# otherwise count twice, and one named only in prose would count once.
COMMENT = re.compile(r"//[^\n]*")

PAINTER = REPO / "jas_dioxus" / "src" / "painter"
# A backend must not reach into the legacy walk. Matched on code, not prose.
BACKEND_REACH = re.compile(r"\bcrate::canvas\b")

# Every Canvas2D method that has a `Painter` expression, and what it maps to.
# The value is documentation, not machinery -- a reader deciding whether a port
# is tractable should be able to answer that from this table alone.
MAPPED = {
    # -- path construction: accumulate into Vec<PathCommand>, emit ONE primitive
    "begin_path": "start a PathCommand buffer",
    "move_to": "PathCommand::MoveTo",
    "line_to": "PathCommand::LineTo",
    "bezier_curve_to": "PathCommand::CubicTo",
    "quadratic_curve_to": "PathCommand::QuadTo",
    "close_path": "PathCommand::Close",
    "rect": "PathCommand rect, or Painter::fill_rect",
    "ellipse": "Painter::fill_ellipse_arc / stroke_ellipse_arc",
    "fill": "Painter::fill_path(buffer, winding, brush, alpha)",
    "fill_with_canvas_winding_rule": "Painter::fill_path with FillRule",
    "stroke": "Painter::stroke_path(buffer, brush, stroke, alpha)",
    "fill_rect": "Painter::fill_rect",
    "stroke_rect": "Painter::stroke_rect",
    "clip": "Painter::clip",
    # -- state and transform
    "save": "Painter::push_state(transform)",
    "restore": "Painter::pop_state",
    "push_ctx_state": "Painter::push_state (local ctx_guard helper)",
    "translate": "folded into the Transform passed to push_state",
    "rotate": "folded into the Transform passed to push_state",
    "scale": "folded into the Transform passed to push_state",
    "transform": "folded into the Transform passed to push_state",
    "set_transform": "folded into the Transform passed to push_state",
    # -- paint
    "set_fill_style_str": "Brush::Solid",
    "set_stroke_style_str": "Brush::Solid",
    "set_fill_style_canvas_gradient": "Brush::Linear / Brush::Radial",
    "set_stroke_style_canvas_gradient": "Brush::Linear / Brush::Radial",
    "create_linear_gradient": "LinearGradient value",
    "create_radial_gradient": "RadialGradient value",
    "set_global_alpha": "the paint_alpha parameter each draw call takes",
    "global_alpha": "the paint_alpha parameter each draw call takes",
    "set_global_composite_operation": "Painter::push_group(alpha, BlendMode)",
    "clear_rect": "a fresh layer surface (push_isolated_layer), or a clear fill",
    # -- not drawing at all
    "clone": "nothing to port: a JS handle copy (the browser tests' surface helper)",
    # -- stroke style
    "set_line_width": "StrokeStyle::width",
    "set_line_cap": "StrokeStyle::cap",
    "set_line_join": "StrokeStyle::join",
    "set_miter_limit": "StrokeStyle::miter_limit",
    "set_line_dash": "StrokeStyle::dash",
    # -- text
    "fill_text": "Painter::draw_text_run(TextRun)",
    "set_font": "TextRun::font",
    "set_text_align": "TextRun::align",
    "set_text_baseline": "TextRun::baseline",
}

# ⛔ THE STOP-AND-FLAG SET. Each entry is (method, why it does not map).
# This list MAY ONLY SHRINK. See the module docstring: growing `Painter` to
# cover these would stop it being a display list, so the likely resolution is
# that these call sites leave `canvas/` -- but that is a ruling, not this
# gate's to make.
UNMAPPED: dict[str, str] = {
    # EMPTY since 2026-09-01 (see the module docstring). The five entries this
    # table carried -- measure_text · get_image_data · put_image_data ·
    # draw_image_with_html_canvas_element · canvas -- left `canvas/` as
    # caller-owned services under the ruling. An entry is added here ONLY
    # when a new `ctx.*` method genuinely cannot be a display-list expression,
    # and adding one is a ratified-interface question: STOP AND FLAG.
}


def scan():
    """Return {method: [(file, line)]} for every ctx.* call under canvas/."""
    found: dict[str, list[tuple[str, int]]] = {}
    files = sorted(CANVAS.glob("*.rs"))
    if not files:
        # ⛔ A SWEEP THAT NEVER LOOKED AND A SWEEP THAT FOUND NOTHING ARE THE
        # SAME NUMBER. If the directory moves, this gate must FAIL rather than
        # report a clean zero.
        raise SystemExit(
            f"FAIL [canvas-portability]: no .rs files under {CANVAS} -- the "
            f"gate found nothing because it looked nowhere. Refusing to report "
            f"clean."
        )
    for f in files:
        text = COMMENT.sub("", f.read_text(encoding="utf-8"))
        for m in CALL.finditer(text):
            n = text.count("\n", 0, m.start()) + 1
            found.setdefault(m.group(1), []).append((f.name, n))
    return found


def backend_reaches():
    """Return [(file, line)] for every code line under painter/ naming
    `crate::canvas` -- a backend reaching into the legacy walk."""
    files = sorted(PAINTER.rglob("*.rs"))
    if not files:
        raise SystemExit(
            f"FAIL [canvas-portability]: no .rs files under {PAINTER} -- the "
            f"backend arm found nothing because it looked nowhere. Refusing to "
            f"report clean."
        )
    hits = []
    for f in files:
        text = COMMENT.sub("", f.read_text(encoding="utf-8"))
        for m in BACKEND_REACH.finditer(text):
            n = text.count("\n", 0, m.start()) + 1
            hits.append((f.relative_to(PAINTER).as_posix(), n))
    return hits


def check() -> int:
    found = scan()
    known = set(MAPPED) | set(UNMAPPED)
    new = {k: v for k, v in found.items() if k not in known}

    total = sum(len(v) for v in found.values())
    unmapped_sites = sum(len(found.get(k, [])) for k in UNMAPPED)

    if new:
        print(f"FAIL [canvas-portability]: {len(new)} ctx.* method(s) with no "
              f"declared Painter mapping.\n")
        for k in sorted(new):
            where = ", ".join(f"{f}:{n}" for f, n in found[k][:4])
            print(f"  - ctx.{k}  ({len(found[k])} site(s): {where})")
        print("\nEither add it to MAPPED with the Painter expression it becomes,")
        print("or to UNMAPPED with the reason it cannot -- and if it belongs in")
        print("UNMAPPED, that is a ratified-interface question: STOP AND FLAG.")
        return 1

    # THE RATCHET'S OTHER ARM: a declared unmapped method that no longer has a
    # call site is a gap the fleet still believes it has. Same law the Direct2D
    # replay gate applies to its own DECLARED list.
    stale = [k for k in UNMAPPED if k not in found]
    if stale:
        print(f"FAIL [canvas-portability]: {len(stale)} declared-unmapped "
              f"method(s) have NO call site left: {sorted(stale)}")
        print("Retire them from UNMAPPED in the commit that removed the last")
        print("site -- a declared gap nothing emits overstates the work left.")
        return 1

    # THE BACKEND ARM: a painter backend that reaches into `canvas/` has made
    # the web-only legacy walk a dependency of the thing built to replace it.
    reaches = backend_reaches()
    if reaches:
        print(f"FAIL [canvas-portability]: {len(reaches)} backend reach(es) into "
              f"`crate::canvas` under painter/:")
        for f, n in reaches:
            print(f"  - painter/{f}:{n}")
        print("\nWhatever the backend needed from canvas/ belongs in a shared,")
        print("host-independent module (see `crate::surface`), not in the walk.")
        return 1

    print(f"check_canvas_portability: OK -- {total} ctx.* site(s), "
          f"{len(found)} distinct method(s); {len(found) - len(UNMAPPED)} mapped, "
          f"{len(UNMAPPED)} declared-unmapped over {unmapped_sites} site(s); "
          f"painter/ reaches into canvas/: 0.")
    if UNMAPPED:
        print("\nThe unmapped set (RATIFIED-INTERFACE question, may only shrink):")
        for k in sorted(UNMAPPED):
            where = ", ".join(f"{f}:{n}" for f, n in found[k])
            print(f"  ctx.{k}  [{len(found[k])} site(s): {where}]")
    else:
        print("\nThe unmapped set is EMPTY: every ctx.* site in canvas/ has a "
              "Painter expression.")
    return 0


def self_test() -> int:
    """BOTH ARMS DRIVEN. The gate is trusted for its RED."""
    failures = []

    # ARM 1 -- the real tree must be clean under the declared vocabulary.
    found = scan()
    if not found:
        failures.append("scan() found no ctx.* calls at all -- the instrument "
                        "is not measuring the subject")
    undeclared = set(found) - (set(MAPPED) | set(UNMAPPED))
    if undeclared:
        failures.append(f"the live tree carries undeclared methods {sorted(undeclared)}")

    # ARM 2 -- an UNDECLARED method must be caught. Driven against a synthetic
    # line rather than by editing the tree, so the arm cannot damage what it
    # measures.
    probe = CALL.findall("    ctx.teleport_the_artboard(1.0);")
    if probe != ["teleport_the_artboard"]:
        failures.append(f"the call pattern did not match a planted site: {probe}")

    # ARM 2b -- the receivers the ORIGINAL pattern could not see (2026-09-01):
    # a `_ctx` suffix, a `ctx()` accessor, a chain broken across a line. Each
    # is a real shape in canvas/render.rs today; a pattern that misses one
    # under-counts the subject.
    shapes = {
        "off_ctx.set_transform(1.0)": ["set_transform"],
        "luma.ctx().set_transform(1.0)": ["set_transform"],
        "ctx\n        .get_image_data(0.0)": ["get_image_data"],
        "context.fill()": [],   # `context` does not end in `ctx`: NOT a site
    }
    for src, want in shapes.items():
        got = CALL.findall(src)
        if got != want:
            failures.append(f"receiver shape {src!r}: matched {got}, want {want}")

    # ARM 2c -- prose is not a call site. A method named ONLY in a comment must
    # not count; the same method in code beside it counts once.
    prose = COMMENT.sub("", "    // ctx.ghost_method() is mentioned here\n    ctx.fill();")
    got = CALL.findall(prose)
    if got != ["fill"]:
        failures.append(f"comment stripping: matched {got}, want ['fill']")

    # ARM 2d -- the backend arm's pattern matches the reach it exists for, on
    # a code line, and not on the same text in a comment.
    if BACKEND_REACH.search(COMMENT.sub("", "    // crate::canvas::render in prose")):
        failures.append("backend arm matched prose")
    if not BACKEND_REACH.search("    crate::canvas::render::blend_mode_css(m)"):
        failures.append("backend arm missed a real reach")
    if "teleport_the_artboard" in (set(MAPPED) | set(UNMAPPED)):
        failures.append("the planted specimen collides with a real declaration")

    # ARM 3 -- THE POSITIVE CONTROL ON THE PATTERN ITSELF. A regex that matched
    # nothing would make arm 2 pass by accident and the whole gate report clean
    # forever. Assert it finds a method the tree really contains.
    if "begin_path" not in found:
        failures.append("ctx.begin_path is absent from the scan -- either the "
                        "tree changed shape or the pattern is dead")

    # ARM 4 -- the two tables must not overlap: a method declared BOTH mapped
    # and unmapped would make the ratchet meaningless.
    both = set(MAPPED) & set(UNMAPPED)
    if both:
        failures.append(f"declared as both mapped and unmapped: {sorted(both)}")

    if failures:
        print(f"check_canvas_portability SELF-TEST: FAIL ({len(failures)})")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("check_canvas_portability SELF-TEST: OK (live tree fully declared; a "
          "planted undeclared method is matched, in every receiver shape; prose "
          "is not counted; the backend arm sees code and not prose; the pattern "
          "is positively controlled against a real site; the two tables are "
          "disjoint)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    return self_test() if a.self_test else check()


if __name__ == "__main__":
    sys.exit(main())
