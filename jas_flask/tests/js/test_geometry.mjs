// Tests for geometry primitives — bounds, hit test, translation.

import { describe, it } from "node:test";
import assert from "node:assert/strict";

import {
  elementBounds, pointInRect, rectsIntersect,
  hitTest, hitTestRect, translateElement,
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
