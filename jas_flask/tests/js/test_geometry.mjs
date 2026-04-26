// Tests for geometry primitives — bounds, hit test, translation.

import { describe, it } from "node:test";
import assert from "node:assert/strict";

import {
  elementBounds, pointInRect, rectsIntersect,
  hitTest, hitTestRect, translateElement,
  calligraphicOutline, controlPoints,
} from "../../static/js/engine/geometry.mjs";
import {
  mkRect, mkCircle, mkEllipse, mkLine, mkPath, mkText,
  mkGroup, mkLayer,
} from "../../static/js/engine/document.mjs";

describe("elementBounds — leaf types", () => {
  it("rect", () => {
    const b = elementBounds(mkRect({ x: 10, y: 20, width: 30, height: 40 }));
    assert.deepEqual(b, { x: 10, y: 20, width: 30, height: 40 });
  });

  it("circle", () => {
    const b = elementBounds(mkCircle({ cx: 50, cy: 50, r: 10 }));
    assert.deepEqual(b, { x: 40, y: 40, width: 20, height: 20 });
  });

  it("ellipse", () => {
    const b = elementBounds(mkEllipse({ cx: 100, cy: 100, rx: 20, ry: 15 }));
    assert.deepEqual(b, { x: 80, y: 85, width: 40, height: 30 });
  });

  it("line uses min/max for axis-aligned box", () => {
    const b = elementBounds(mkLine({ x1: 10, y1: 50, x2: 80, y2: 20 }));
    assert.deepEqual(b, { x: 10, y: 20, width: 70, height: 30 });
  });

  it("path from endpoint-only commands", () => {
    const b = elementBounds(mkPath({
      d: [
        { type: "M", x: 0, y: 0 },
        { type: "L", x: 100, y: 50 },
        { type: "Z" },
      ],
    }));
    assert.deepEqual(b, { x: 0, y: 0, width: 100, height: 50 });
  });

  it("text estimates width from content", () => {
    const b = elementBounds(mkText({ x: 0, y: 12, content: "abc", font_size: 10 }));
    assert.equal(b.width, 3 * 10 * 0.55);
  });

  it("unknown / degenerate → zero box", () => {
    assert.deepEqual(elementBounds(null), { x: 0, y: 0, width: 0, height: 0 });
    assert.deepEqual(elementBounds({ type: "weird" }), { x: 0, y: 0, width: 0, height: 0 });
  });
});

describe("elementBounds — containers union", () => {
  it("group bounds span its children", () => {
    const g = mkGroup({
      children: [
        mkRect({ x: 0, y: 0, width: 10, height: 10 }),
        mkRect({ x: 20, y: 30, width: 5, height: 5 }),
      ],
    });
    const b = elementBounds(g);
    assert.deepEqual(b, { x: 0, y: 0, width: 25, height: 35 });
  });

  it("empty container → zero box", () => {
    assert.deepEqual(
      elementBounds(mkGroup()),
      { x: 0, y: 0, width: 0, height: 0 }
    );
  });

  it("layer recurses into nested groups", () => {
    const l = mkLayer({
      children: [
        mkRect({ x: 0, y: 0, width: 5, height: 5 }),
        mkGroup({ children: [mkRect({ x: 10, y: 10, width: 5, height: 5 })] }),
      ],
    });
    const b = elementBounds(l);
    assert.equal(b.x, 0);
    assert.equal(b.width, 15);
  });
});

describe("pointInRect / rectsIntersect", () => {
  it("pointInRect inside and outside", () => {
    const r = { x: 0, y: 0, width: 10, height: 10 };
    assert.ok(pointInRect(5, 5, r));
    assert.ok(!pointInRect(-1, 5, r));
    assert.ok(!pointInRect(5, 15, r));
  });

  it("pointInRect inclusive on boundary", () => {
    const r = { x: 0, y: 0, width: 10, height: 10 };
    assert.ok(pointInRect(0, 0, r));
    assert.ok(pointInRect(10, 10, r));
  });

  it("rectsIntersect overlap / touch / disjoint", () => {
    const a = { x: 0, y: 0, width: 10, height: 10 };
    const b = { x: 5, y: 5, width: 10, height: 10 };
    const c = { x: 20, y: 20, width: 5, height: 5 };
    assert.ok(rectsIntersect(a, b));
    assert.ok(!rectsIntersect(a, c));
  });
});

describe("hitTest", () => {
  const doc = {
    layers: [mkLayer({
      children: [
        mkRect({ x: 0, y: 0, width: 10, height: 10 }),
        mkRect({ x: 50, y: 50, width: 10, height: 10 }),
        mkGroup({
          children: [
            mkCircle({ cx: 100, cy: 100, r: 10 }),
          ],
        }),
      ],
    })],
    selection: [], artboards: [],
  };

  it("returns path of hit element", () => {
    assert.deepEqual(hitTest(doc, 5, 5), [0, 0]);
  });

  it("returns null outside all elements", () => {
    assert.equal(hitTest(doc, 200, 200), null);
  });

  it("descends into groups", () => {
    assert.deepEqual(hitTest(doc, 100, 100), [0, 2, 0]);
  });

  it("topmost wins when elements overlap", () => {
    const d2 = {
      layers: [mkLayer({
        children: [
          mkRect({ x: 0, y: 0, width: 20, height: 20 }),  // idx 0
          mkRect({ x: 5, y: 5, width: 10, height: 10 }),   // idx 1 — on top
        ],
      })],
      selection: [], artboards: [],
    };
    assert.deepEqual(hitTest(d2, 10, 10), [0, 1]);
  });

  it("skips invisible elements", () => {
    const d3 = {
      layers: [mkLayer({
        children: [mkRect({ x: 0, y: 0, width: 10, height: 10, visibility: "invisible" })],
      })],
      selection: [], artboards: [],
    };
    assert.equal(hitTest(d3, 5, 5), null);
  });

  it("skips locked elements", () => {
    const d4 = {
      layers: [mkLayer({
        children: [mkRect({ x: 0, y: 0, width: 10, height: 10, locked: true })],
      })],
      selection: [], artboards: [],
    };
    assert.equal(hitTest(d4, 5, 5), null);
  });
});

describe("hitTestRect", () => {
  const doc = {
    layers: [mkLayer({
      children: [
        mkRect({ x: 0, y: 0, width: 10, height: 10 }),
        mkRect({ x: 20, y: 20, width: 10, height: 10 }),
        mkRect({ x: 100, y: 100, width: 10, height: 10 }),
      ],
    })],
    selection: [], artboards: [],
  };

  it("returns all intersecting elements", () => {
    const paths = hitTestRect(doc, { x: 0, y: 0, width: 25, height: 25 });
    assert.equal(paths.length, 2);
  });

  it("empty when no intersection", () => {
    const paths = hitTestRect(doc, { x: 200, y: 200, width: 10, height: 10 });
    assert.equal(paths.length, 0);
  });

  it("handles containers recursively", () => {
    const d2 = {
      layers: [mkLayer({
        children: [mkGroup({ children: [mkRect({ x: 5, y: 5, width: 5, height: 5 })] })],
      })],
      selection: [], artboards: [],
    };
    const paths = hitTestRect(d2, { x: 0, y: 0, width: 20, height: 20 });
    assert.deepEqual(paths, [[0, 0, 0]]);
  });
});

describe("translateElement", () => {
  it("rect translates x/y", () => {
    const r = translateElement(mkRect({ x: 10, y: 20, width: 5, height: 5 }), 3, 7);
    assert.equal(r.x, 13);
    assert.equal(r.y, 27);
    assert.equal(r.width, 5);
  });

  it("circle translates cx/cy", () => {
    const c = translateElement(mkCircle({ cx: 10, cy: 20, r: 5 }), 1, 2);
    assert.equal(c.cx, 11);
    assert.equal(c.cy, 22);
    assert.equal(c.r, 5);
  });

  it("line translates both endpoints", () => {
    const l = translateElement(mkLine({ x1: 0, y1: 0, x2: 10, y2: 10 }), 5, 5);
    assert.equal(l.x1, 5);
    assert.equal(l.y2, 15);
  });

  it("group translates children recursively", () => {
    const g = mkGroup({
      children: [mkRect({ x: 0, y: 0, width: 5, height: 5 })],
    });
    const g2 = translateElement(g, 10, 10);
    assert.equal(g2.children[0].x, 10);
    assert.equal(g2.children[0].y, 10);
    // Input not mutated
    assert.equal(g.children[0].x, 0);
  });

  it("path translates each command", () => {
    const p = translateElement(mkPath({
      d: [{ type: "M", x: 1, y: 2 }, { type: "L", x: 10, y: 20 }],
    }), 100, 200);
    assert.equal(p.d[0].x, 101);
    assert.equal(p.d[1].y, 220);
  });
});

// Helper for outline tests: parse "M x y L x y L x y ... Z" into a list
// of [x, y] points, dropping the M / L / Z command letters.
function parseOutlinePoints(d) {
  if (!d) return [];
  const tokens = d.trim().split(/\s+/);
  const pts = [];
  let i = 0;
  while (i < tokens.length) {
    const t = tokens[i];
    if (t === "M" || t === "L") {
      pts.push([parseFloat(tokens[i + 1]), parseFloat(tokens[i + 2])]);
      i += 3;
    } else if (t === "Z") {
      i += 1;
    } else {
      i += 1;
    }
  }
  return pts;
}

describe("calligraphicOutline", () => {
  it("empty / degenerate input returns empty string", () => {
    assert.equal(calligraphicOutline([], { angle: 0, roundness: 100, size: 4 }), "");
    assert.equal(calligraphicOutline(
      [{ type: "M", x: 0, y: 0 }],
      { angle: 0, roundness: 100, size: 4 },
    ), "");
  });

  it("horizontal line, circular brush — outline is a stadium-like shape", () => {
    // Horizontal line, circular tip (roundness 100, size 4) → constant
    // half-width 2 perpendicular to the line. Sweep produces points 2pt
    // above and below the line, joined to form a closed path.
    const d = calligraphicOutline(
      [{ type: "M", x: 0, y: 0 }, { type: "L", x: 10, y: 0 }],
      { angle: 0, roundness: 100, size: 4 },
    );
    assert.ok(d.startsWith("M "), `expected leading M, got: ${d.slice(0, 30)}`);
    assert.ok(d.endsWith(" Z"), `expected trailing Z, got: ${d.slice(-10)}`);

    const pts = parseOutlinePoints(d);
    // Half-width is 2 → outline ys are ±2 (within fp tolerance).
    for (const [, y] of pts) {
      assert.ok(Math.abs(Math.abs(y) - 2) < 1e-3, `y=${y} not ±2`);
    }
    // Outline xs span 0..10.
    const xs = pts.map((p) => p[0]);
    assert.equal(Math.min(...xs), 0);
    assert.equal(Math.max(...xs), 10);
  });

  it("brush angle parallel to path → minor-axis effective width", () => {
    // Horizontal path, brush angle 0° (major axis horizontal),
    // roundness 50% → minor axis = 50% of major. Effective half-width
    // perpendicular to the path = b/2 = (4 · 0.5) / 2 = 1.
    const d = calligraphicOutline(
      [{ type: "M", x: 0, y: 0 }, { type: "L", x: 10, y: 0 }],
      { angle: 0, roundness: 50, size: 4 },
    );
    const pts = parseOutlinePoints(d);
    for (const [, y] of pts) {
      assert.ok(Math.abs(Math.abs(y) - 1) < 1e-3, `y=${y} not ±1`);
    }
  });

  it("brush angle perpendicular to path → major-axis effective width", () => {
    // Horizontal path, brush angle 90° (major axis vertical),
    // roundness 50% → effective half-width perpendicular to the path
    // = a/2 = 2.
    const d = calligraphicOutline(
      [{ type: "M", x: 0, y: 0 }, { type: "L", x: 10, y: 0 }],
      { angle: 90, roundness: 50, size: 4 },
    );
    const pts = parseOutlinePoints(d);
    for (const [, y] of pts) {
      assert.ok(Math.abs(Math.abs(y) - 2) < 1e-3, `y=${y} not ±2`);
    }
  });

  it("vertical path with horizontal brush angle → effective width is the minor axis", () => {
    // Vertical path tangent at 90°, brush angle 0° (major horizontal),
    // roundness 50% → effective width perpendicular to path uses the
    // major axis = a = 4 → half-width 2 horizontally on either side.
    const d = calligraphicOutline(
      [{ type: "M", x: 5, y: 0 }, { type: "L", x: 5, y: 10 }],
      { angle: 0, roundness: 50, size: 4 },
    );
    const pts = parseOutlinePoints(d);
    for (const [x] of pts) {
      assert.ok(Math.abs(Math.abs(x - 5) - 2) < 1e-3, `x=${x} not 5±2`);
    }
  });

  it("circular brush gives same width regardless of path direction", () => {
    // Roundness 100% → circular tip → effective width is constant
    // independent of path tangent direction. Diagonal path should still
    // yield half-width = 2 perpendicular distance.
    const d = calligraphicOutline(
      [{ type: "M", x: 0, y: 0 }, { type: "L", x: 10, y: 10 }],
      { angle: 30, roundness: 100, size: 4 },
    );
    const pts = parseOutlinePoints(d);
    // Distance from each outline point to the path-line x = y is half-width.
    // Distance from (px, py) to line x − y = 0 is |px − py| / √2.
    for (const [x, y] of pts) {
      const dist = Math.abs(x - y) / Math.SQRT2;
      assert.ok(Math.abs(dist - 2) < 1e-3, `dist=${dist} not 2`);
    }
  });

  it("multiple-segment path samples both segments", () => {
    // M 0,0 L 10,0 L 10,10 — corner. Outline should span both segments.
    const d = calligraphicOutline(
      [
        { type: "M", x: 0, y: 0 },
        { type: "L", x: 10, y: 0 },
        { type: "L", x: 10, y: 10 },
      ],
      { angle: 0, roundness: 100, size: 4 },
    );
    const pts = parseOutlinePoints(d);
    const xs = pts.map((p) => p[0]);
    const ys = pts.map((p) => p[1]);
    // Should reach all the way to the corner extremes.
    assert.ok(Math.max(...xs) >= 12 - 1e-3);
    assert.ok(Math.max(...ys) >= 10 - 1e-3);
  });

  it("cubic curve sampled and outlined", () => {
    // A simple cubic from (0,0) to (10,0) with control points pulling
    // up. Just verify we get a non-trivial closed path with samples.
    const d = calligraphicOutline(
      [
        { type: "M", x: 0, y: 0 },
        { type: "C", x1: 3, y1: 5, x2: 7, y2: 5, x: 10, y: 0 },
      ],
      { angle: 0, roundness: 100, size: 4 },
    );
    const pts = parseOutlinePoints(d);
    // 32 cubic samples → roughly 33 forward + 33 reverse = ~66 points.
    assert.ok(pts.length > 50, `expected >50 outline points, got ${pts.length}`);
    // Outline reaches above the curve (max y around peak).
    const ys = pts.map((p) => p[1]);
    assert.ok(Math.max(...ys) > 3, "outline should reach above curve");
    // The "right" (below-curve) side dips below y=0 at the endpoints
    // where the tangent is steepest. The exact minimum depends on the
    // tangent angle; at the cubic's endpoints the perpendicular drop is
    // ~half-width · cos(tangent) — well below zero but not the full -2.
    assert.ok(Math.min(...ys) < -0.5, "outline should dip below path baseline");
  });
});

describe("controlPoints", () => {
  // Mirrors jas_dioxus/src/geometry/element.rs::control_points so
  // selection handles match the native apps.
  it("rect → four corners (TL, TR, BR, BL)", () => {
    const cps = controlPoints(mkRect({ x: 10, y: 20, width: 30, height: 40 }));
    assert.deepEqual(cps, [
      [10, 20], [40, 20], [40, 60], [10, 60],
    ]);
  });

  it("line → two endpoints", () => {
    const cps = controlPoints(mkLine({ x1: 5, y1: 5, x2: 25, y2: 35 }));
    assert.deepEqual(cps, [[5, 5], [25, 35]]);
  });

  it("circle → four cardinal points (top, right, bottom, left)", () => {
    const cps = controlPoints(mkCircle({ cx: 100, cy: 100, r: 20 }));
    assert.deepEqual(cps, [[100, 80], [120, 100], [100, 120], [80, 100]]);
  });

  it("ellipse → four cardinals using rx / ry", () => {
    const cps = controlPoints(mkEllipse({ cx: 50, cy: 50, rx: 30, ry: 10 }));
    assert.deepEqual(cps, [[50, 40], [80, 50], [50, 60], [20, 50]]);
  });

  it("path → anchor points at each command's destination", () => {
    const cps = controlPoints(mkPath({
      d: [
        { type: "M", x: 0, y: 0 },
        { type: "L", x: 10, y: 0 },
        { type: "C", x1: 12, y1: 0, x2: 12, y2: 5, x: 10, y: 10 },
        { type: "Z" },
      ],
    }));
    // Z contributes no anchor.
    assert.deepEqual(cps, [[0, 0], [10, 0], [10, 10]]);
  });

  it("group falls back to bounding-box corners", () => {
    const g = mkGroup({ children: [
      mkRect({ x: 0, y: 0, width: 10, height: 10 }),
      mkRect({ x: 30, y: 20, width: 5, height: 5 }),
    ] });
    const cps = controlPoints(g);
    assert.deepEqual(cps, [[0, 0], [35, 0], [35, 25], [0, 25]]);
  });
});
