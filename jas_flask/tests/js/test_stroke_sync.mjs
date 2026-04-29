// Tests for engine/stroke_sync — the pure helpers used by
// canvas_bootstrap to mirror an element's stroke attrs into global
// state and to build the SVG stroke-dasharray string from the Stroke
// panel's individual dash / gap fields.

import { describe, it } from "node:test";
import assert from "node:assert/strict";

import {
  elementToStateWrites, buildDasharray,
} from "../../static/js/engine/stroke_sync.mjs";

// Quick lookup helper: pull the value for `key` from a writes array.
function pick(writes, key) {
  const w = writes.find((e) => e.key === key);
  return w ? w.value : undefined;
}

// STR-305 — selection sync round-trip. Selecting an element should
// mirror its fill / stroke / stroke-width / cap / join / miterlimit /
// dasharray onto global state so the Color and Stroke panels update.
describe("elementToStateWrites — STR-305 selection sync", () => {
  it("empty / null element yields no writes", () => {
    assert.deepEqual(elementToStateWrites(null), []);
    assert.deepEqual(elementToStateWrites(undefined), []);
  });

  it("flat fill / stroke / stroke-width", () => {
    const elem = {
      type: "rect",
      fill: "#ff0000",
      stroke: "#000000",
      "stroke-width": 4,
    };
    const writes = elementToStateWrites(elem);
    assert.equal(pick(writes, "fill_color"), "#ff0000");
    assert.equal(pick(writes, "stroke_color"), "#000000");
    assert.equal(pick(writes, "stroke_width"), 4);
  });

  it("legacy {color, width} stroke object", () => {
    const elem = {
      type: "rect",
      stroke: { color: "#ff00ff", width: 6 },
    };
    const writes = elementToStateWrites(elem);
    assert.equal(pick(writes, "stroke_color"), "#ff00ff");
    assert.equal(pick(writes, "stroke_width"), 6);
  });

  it("explicit null fill / stroke surfaces as null in state", () => {
    const writes = elementToStateWrites({
      type: "rect", fill: null, stroke: null,
    });
    assert.equal(pick(writes, "fill_color"), null);
    assert.equal(pick(writes, "stroke_color"), null);
  });

  it("cap / join / miterlimit / dasharray mirror through", () => {
    const elem = {
      type: "rect",
      "stroke-linecap": "round",
      "stroke-linejoin": "bevel",
      "stroke-miterlimit": 8,
      "stroke-dasharray": "12 6 0 6",
    };
    const writes = elementToStateWrites(elem);
    assert.equal(pick(writes, "stroke_cap"), "round");
    assert.equal(pick(writes, "stroke_join"), "bevel");
    assert.equal(pick(writes, "stroke_miter_limit"), 8);
    assert.equal(pick(writes, "stroke_dasharray"), "12 6 0 6");
    assert.equal(pick(writes, "stroke_dashed"), true);
  });

  it("missing cap / join fall back to SVG defaults so panel resets", () => {
    const writes = elementToStateWrites({ type: "rect" });
    assert.equal(pick(writes, "stroke_cap"), "butt");
    assert.equal(pick(writes, "stroke_join"), "miter");
    assert.equal(pick(writes, "stroke_dasharray"), "");
    assert.equal(pick(writes, "stroke_dashed"), false);
  });

  it("empty dasharray flags stroke_dashed=false", () => {
    const writes = elementToStateWrites({
      type: "rect", "stroke-dasharray": "",
    });
    assert.equal(pick(writes, "stroke_dashed"), false);
  });

  it("dasharray=\"none\" flags stroke_dashed=false", () => {
    const writes = elementToStateWrites({
      type: "rect", "stroke-dasharray": "none",
    });
    assert.equal(pick(writes, "stroke_dashed"), false);
  });

  it("round-trip: switching selection mirrors the new element", () => {
    // Select element A: round cap, weight 4
    const writesA = elementToStateWrites({
      type: "rect",
      "stroke-linecap": "round", "stroke-width": 4,
    });
    assert.equal(pick(writesA, "stroke_cap"), "round");
    assert.equal(pick(writesA, "stroke_width"), 4);
    // Select element B: butt cap, weight 1
    const writesB = elementToStateWrites({
      type: "rect", "stroke-width": 1,
    });
    assert.equal(pick(writesB, "stroke_cap"), "butt");
    assert.equal(pick(writesB, "stroke_width"), 1);
  });

  it("STR-304: arrowhead state mirrors back to global state", () => {
    const elem = {
      type: "path",
      "jas-stroke-start-arrowhead": "closed_arrow",
      "jas-stroke-start-arrowhead-scale": 75,
      "jas-stroke-end-arrowhead": "diamond",
      "jas-stroke-end-arrowhead-scale": 200,
    };
    const writes = elementToStateWrites(elem);
    assert.equal(pick(writes, "stroke_start_arrowhead"), "closed_arrow");
    assert.equal(pick(writes, "stroke_start_arrowhead_scale"), 75);
    assert.equal(pick(writes, "stroke_end_arrowhead"), "diamond");
    assert.equal(pick(writes, "stroke_end_arrowhead_scale"), 200);
  });

  it("STR-304: missing arrowhead state falls back to none/100", () => {
    const writes = elementToStateWrites({ type: "path" });
    assert.equal(pick(writes, "stroke_start_arrowhead"), "none");
    assert.equal(pick(writes, "stroke_end_arrowhead"), "none");
    assert.equal(pick(writes, "stroke_start_arrowhead_scale"), 100);
    assert.equal(pick(writes, "stroke_end_arrowhead_scale"), 100);
  });
});

// buildDasharray powers STR-302 (Dash-Dot preset). Add coverage so
// the dash/gap → dasharray pipeline doesn't silently regress.
describe("buildDasharray", () => {
  it("returns empty when stroke_dashed is off", () => {
    const s = { stroke_dashed: false, stroke_dash_1: 12, stroke_gap_1: 6 };
    assert.equal(buildDasharray(s), "");
  });

  it("returns empty for null state", () => {
    assert.equal(buildDasharray(null), "");
    assert.equal(buildDasharray(undefined), "");
  });

  it("walks 1 pair when only first is set", () => {
    const s = {
      stroke_dashed: true,
      stroke_dash_1: 8, stroke_gap_1: 4,
    };
    assert.equal(buildDasharray(s), "8 4");
  });

  it("Dash-Dot preset yields 4 elements", () => {
    const s = {
      stroke_dashed: true,
      stroke_dash_1: 12, stroke_gap_1: 6,
      stroke_dash_2: 0, stroke_gap_2: 6,
    };
    assert.equal(buildDasharray(s), "12 6 0 6");
  });

  it("missing gap ends the pattern early", () => {
    const s = {
      stroke_dashed: true,
      stroke_dash_1: 12, stroke_gap_1: 6,
      stroke_dash_2: 4,  // gap_2 absent
    };
    assert.equal(buildDasharray(s), "12 6");
  });

  it("zero values are valid (Dash-Dot uses dash_2=0)", () => {
    const s = {
      stroke_dashed: true,
      stroke_dash_1: 0, stroke_gap_1: 6,
    };
    assert.equal(buildDasharray(s), "0 6");
  });

  it("walks all three pairs when fully populated", () => {
    const s = {
      stroke_dashed: true,
      stroke_dash_1: 1, stroke_gap_1: 2,
      stroke_dash_2: 3, stroke_gap_2: 4,
      stroke_dash_3: 5, stroke_gap_3: 6,
    };
    assert.equal(buildDasharray(s), "1 2 3 4 5 6");
  });
});
