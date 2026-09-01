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

⇒ THE TWO SIDES SPEAK DIFFERENT VOCABULARIES, and that is the real work. Canvas2D
is a STATEFUL PATH BUILDER (`begin_path` / `move_to` / `line_to` / `fill`);
`Painter` is WHOLE-PRIMITIVE (`fill_path` takes a complete path). Porting is
therefore accumulation and re-expression, not substitution -- but it is
MECHANICAL for 264 of the 270 sites, and this gate exists to keep the remaining
six honest rather than to relitigate them.

⛔ THE SIX THAT DO NOT MAP, and they are a RATIFIED-INTERFACE question, not a
porting decision. They are listed in `UNMAPPED` below with the reason each is
hard. A `Painter` that grew them would stop being a display list, so the answer
is probably "these call sites leave `canvas/`", not "the trait grows" -- but
that is the Captain's or the port owner's call and this gate does not presume it.

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

CALL = re.compile(r"\bctx\.([a-z_][a-z0-9_]*)")

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
UNMAPPED = {
    "measure_text": (
        "A QUERY that returns metrics. `Painter` is write-only apart from "
        "`supports(cap) -> bool`; a display list cannot answer 'how wide is "
        "this text' because it has not been rasterised yet. Text measurement "
        "has to come from a font service the caller owns, not from the painter."
    ),
    "get_image_data": (
        "PIXEL READBACK. A display list has no pixels to read. Whatever this "
        "site needs (hit-testing, an eyedropper, a cached tile) has to be "
        "expressed against a surface, not against a painter."
    ),
    "put_image_data": (
        "PIXEL WRITEBACK, the same boundary in reverse."
    ),
    "draw_image_with_html_canvas_element": (
        "Composites ANOTHER CANVAS. The display-list analogue would be an image "
        "primitive the trait does not have, and adding one means deciding how "
        "every backend sources and owns that image."
    ),
    "canvas": (
        "Reaches the underlying `HtmlCanvasElement` -- a web handle by "
        "definition. Every use of it is a site that has to be re-expressed "
        "rather than translated."
    ),
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
        for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            for m in CALL.finditer(line):
                found.setdefault(m.group(1), []).append((f.name, n))
    return found


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

    print(f"check_canvas_portability: OK -- {total} ctx.* site(s), "
          f"{len(found)} distinct method(s); {len(found) - len(UNMAPPED)} mapped, "
          f"{len(UNMAPPED)} declared-unmapped over {unmapped_sites} site(s).")
    print("\nThe unmapped set (RATIFIED-INTERFACE question, may only shrink):")
    for k in sorted(UNMAPPED):
        where = ", ".join(f"{f}:{n}" for f, n in found[k])
        print(f"  ctx.{k}  [{len(found[k])} site(s): {where}]")
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
          "planted undeclared method is matched; the pattern is positively "
          "controlled against a real site; the two tables are disjoint)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    return self_test() if a.self_test else check()


if __name__ == "__main__":
    sys.exit(main())
