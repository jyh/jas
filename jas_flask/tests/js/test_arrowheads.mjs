// Tests for engine/arrowheads — the SVG <marker> definitions and
// emission for the 14 arrow shapes plus "none". Covers
// emitArrowMarker (single shape), collectArrowMarkerRefs (walks the
// document for in-use shapes), and emitArrowDefs (full <defs> block).

import { describe, it } from "node:test";
import assert from "node:assert/strict";

import {
  ARROWHEAD_NAMES, getArrowShape, arrowSetback, arrowMarkerId,
  emitArrowMarker, collectArrowMarkerRefs, emitArrowDefs,
} from "../../static/js/engine/arrowheads.mjs";

describe("ARROWHEAD_NAMES", () => {
  it("lists 15 entries (14 shapes + none)", () => {
    assert.equal(ARROWHEAD_NAMES.length, 15);
    assert.equal(ARROWHEAD_NAMES[0], "none");
  });

  it("matches workspace/state.yaml stroke_start_arrowhead enum", () => {
    // The enum values are duplicated here on purpose — divergence
    // breaks the panel selects so this is a load-bearing assertion.
    const expected = [
      "none", "simple_arrow", "open_arrow", "closed_arrow",
      "stealth_arrow", "barbed_arrow", "half_arrow_upper",
      "half_arrow_lower", "circle", "open_circle", "square",
      "open_square", "diamond", "open_diamond", "slash",
    ];
    assert.deepEqual(ARROWHEAD_NAMES, expected);
  });
});

describe("getArrowShape", () => {
  it("returns null for none / empty / unknown", () => {
    assert.equal(getArrowShape("none"), null);
    assert.equal(getArrowShape(""), null);
    assert.equal(getArrowShape(null), null);
    assert.equal(getArrowShape("nonsense"), null);
  });

  it("returns a definition for every named shape", () => {
    for (const name of ARROWHEAD_NAMES.slice(1)) {
      const shape = getArrowShape(name);
      assert.ok(shape, `getArrowShape("${name}") should return a definition`);
      assert.ok(typeof shape.d === "string" && shape.d.length > 0);
      assert.ok(shape.style === "filled" || shape.style === "outline");
      assert.ok(typeof shape.back === "number");
      assert.ok(Array.isArray(shape.vbox) && shape.vbox.length === 4);
    }
  });
});

describe("arrowSetback", () => {
  it("returns 0 for no arrowhead", () => {
    assert.equal(arrowSetback("none", 1, 100), 0);
    assert.equal(arrowSetback("", 1, 100), 0);
    assert.equal(arrowSetback("nonsense", 1, 100), 0);
  });

  it("scales with stroke width and percentage", () => {
    // simple_arrow has back=4 → at width 1 / 100% setback is 4.
    assert.equal(arrowSetback("simple_arrow", 1, 100), 4);
    // 200% → 8; 50% → 2.
    assert.equal(arrowSetback("simple_arrow", 1, 200), 8);
    assert.equal(arrowSetback("simple_arrow", 1, 50), 2);
    // Width 2 / 100% → 8.
    assert.equal(arrowSetback("simple_arrow", 2, 100), 8);
  });
});

describe("arrowMarkerId", () => {
  it("encodes side / shape / scale into a stable string", () => {
    assert.equal(arrowMarkerId("simple_arrow", 100, "start"),
                 "jas-arr-start-simple_arrow-100");
    assert.equal(arrowMarkerId("diamond", 200, "end"),
                 "jas-arr-end-diamond-200");
  });

  it("rounds non-integer scales to int", () => {
    assert.equal(arrowMarkerId("circle", 99.7, "end"),
                 "jas-arr-end-circle-99");
  });

  it("falls back to 100 for non-finite scale", () => {
    assert.equal(arrowMarkerId("square", NaN, "start"),
                 "jas-arr-start-square-100");
    assert.equal(arrowMarkerId("square", null, "start"),
                 "jas-arr-start-square-100");
  });
});

describe("emitArrowMarker", () => {
  it("returns empty for none / unknown", () => {
    assert.equal(emitArrowMarker("none", "start", 100), "");
    assert.equal(emitArrowMarker("nonsense", "end", 100), "");
  });

  it("filled shape uses fill=context-stroke", () => {
    const m = emitArrowMarker("simple_arrow", "end", 100);
    assert.match(m, /^<marker /);
    assert.match(m, /fill="context-stroke"/);
    assert.match(m, /stroke="none"/);
  });

  it("outline shape uses stroke=context-stroke fill=none", () => {
    const m = emitArrowMarker("open_arrow", "end", 100);
    assert.match(m, /fill="none"/);
    assert.match(m, /stroke="context-stroke"/);
  });

  it("end side uses orient=auto", () => {
    const m = emitArrowMarker("simple_arrow", "end", 100);
    assert.match(m, /orient="auto"/);
  });

  it("start side uses orient=auto-start-reverse so the tip points outward", () => {
    const m = emitArrowMarker("simple_arrow", "start", 100);
    assert.match(m, /orient="auto-start-reverse"/);
  });

  it("scales viewBox + markerWidth/Height by the percentage", () => {
    // simple_arrow vbox is [-4 -2 4 4]. At 200% scale → [-8 -4 8 8].
    const m = emitArrowMarker("simple_arrow", "end", 200);
    assert.match(m, /viewBox="-8 -4 8 8"/);
    assert.match(m, /markerWidth="8"/);
    assert.match(m, /markerHeight="8"/);
  });

  it("includes a stable id for foo/scale/side", () => {
    const m = emitArrowMarker("diamond", "end", 75);
    assert.match(m, /id="jas-arr-end-diamond-75"/);
  });
});

describe("collectArrowMarkerRefs", () => {
  it("returns empty for empty / null doc", () => {
    assert.equal(collectArrowMarkerRefs(null).size, 0);
    assert.equal(collectArrowMarkerRefs({ layers: [] }).size, 0);
  });

  it("ignores elements without arrowheads", () => {
    const doc = { layers: [{ type: "rect", x: 0, y: 0 }] };
    assert.equal(collectArrowMarkerRefs(doc).size, 0);
  });

  it("ignores arrowhead=none", () => {
    const doc = {
      layers: [{
        type: "path",
        "jas-stroke-start-arrowhead": "none",
        "jas-stroke-end-arrowhead": "none",
      }],
    };
    assert.equal(collectArrowMarkerRefs(doc).size, 0);
  });

  it("registers (shape, side, scale) for each non-none endpoint", () => {
    const doc = {
      layers: [{
        type: "path",
        "jas-stroke-start-arrowhead": "closed_arrow",
        "jas-stroke-start-arrowhead-scale": 75,
        "jas-stroke-end-arrowhead": "diamond",
        "jas-stroke-end-arrowhead-scale": 200,
      }],
    };
    const refs = collectArrowMarkerRefs(doc);
    assert.equal(refs.size, 2);
    assert.ok(refs.has("closed_arrow|start|75"));
    assert.ok(refs.has("diamond|end|200"));
  });

  it("walks into containers", () => {
    const doc = {
      layers: [{
        type: "layer", name: "L",
        children: [{
          type: "group",
          children: [{
            type: "path",
            "jas-stroke-end-arrowhead": "circle",
          }],
        }],
      }],
    };
    const refs = collectArrowMarkerRefs(doc);
    assert.ok(refs.has("circle|end|100"));
  });

  it("dedupes identical (shape, side, scale) trios", () => {
    const doc = {
      layers: [
        {
          type: "path",
          "jas-stroke-end-arrowhead": "simple_arrow",
          "jas-stroke-end-arrowhead-scale": 100,
        },
        {
          type: "path",
          "jas-stroke-end-arrowhead": "simple_arrow",
          "jas-stroke-end-arrowhead-scale": 100,
        },
      ],
    };
    assert.equal(collectArrowMarkerRefs(doc).size, 1);
  });
});

describe("emitArrowDefs", () => {
  it("returns empty for docs with no arrowheads", () => {
    assert.equal(emitArrowDefs(null), "");
    assert.equal(emitArrowDefs({ layers: [] }), "");
    assert.equal(emitArrowDefs({
      layers: [{ type: "rect" }],
    }), "");
  });

  it("emits a <defs> block with one <marker> per ref", () => {
    const doc = {
      layers: [{
        type: "path",
        "jas-stroke-start-arrowhead": "closed_arrow",
        "jas-stroke-start-arrowhead-scale": 75,
        "jas-stroke-end-arrowhead": "diamond",
        "jas-stroke-end-arrowhead-scale": 200,
      }],
    };
    const defs = emitArrowDefs(doc);
    assert.match(defs, /^<defs>/);
    assert.match(defs, /id="jas-arr-start-closed_arrow-75"/);
    assert.match(defs, /id="jas-arr-end-diamond-200"/);
    assert.match(defs, /<\/defs>$/);
  });
});
