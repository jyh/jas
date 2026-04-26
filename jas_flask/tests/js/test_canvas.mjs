// Tests for the canvas layer orchestrator (document + selection + overlay).

import { describe, it } from "node:test";
import assert from "node:assert/strict";

import {
  renderCanvas, renderDocumentLayer, renderSelectionLayer, renderOverlayLayer,
  renderArtboardFillLayer, renderArtboardDecorationLayer,
} from "../../static/js/engine/canvas.mjs";
import {
  mkLayer, mkRect, mkCircle, setSelection, setPartialCps,
} from "../../static/js/engine/document.mjs";
import { Scope } from "../../static/js/engine/scope.mjs";

function makeDoc() {
  return {
    layers: [mkLayer({ children: [
      mkRect({ x: 10, y: 10, width: 20, height: 20 }),
      mkCircle({ cx: 100, cy: 100, r: 15 }),
    ] })],
    selection: [],
    artboards: [],
  };
}

describe("renderDocumentLayer", () => {
  it("renders all layers", () => {
    const svg = renderDocumentLayer(makeDoc());
    assert.match(svg, /<rect /);
    assert.match(svg, /<circle /);
  });
});

describe("renderSelectionLayer", () => {
  it("empty for no selection", () => {
    assert.equal(renderSelectionLayer(makeDoc()), "");
  });

  it("dashed bbox per selected element", () => {
    const doc = setSelection(makeDoc(), [[0, 0]]);
    const svg = renderSelectionLayer(doc);
    assert.match(svg, /<rect/);
    assert.match(svg, /stroke-dasharray/);
    assert.match(svg, /x="10"/);
  });

  it("multiple selections produce multiple bboxes", () => {
    const doc = setSelection(makeDoc(), [[0, 0], [0, 1]]);
    const svg = renderSelectionLayer(doc);
    // Two bboxes + control-point handles for each. Bboxes are
    // dashed; handles have white fill — count just the bboxes by
    // the dasharray attribute.
    assert.equal((svg.match(/stroke-dasharray="4 2"/g) || []).length, 2);
  });

  it("emits a control-point handle at each anchor of a selected rect", () => {
    // Whole-element (All) selection: every handle filled solid.
    const doc = setSelection(makeDoc(), [[0, 0]]);
    const svg = renderSelectionLayer(doc);
    const handlesOnly = svg.replace(/<rect [^/]*stroke-dasharray[^/]*\/>/g, "");
    assert.equal((handlesOnly.match(/<rect /g) || []).length, 4);
    const SEL_COLOR = "rgba\\(0, 120, 215, 0\\.9\\)";
    assert.match(handlesOnly, new RegExp(`fill="${SEL_COLOR}"`));
  });

  it("partial selection: only listed CPs solid, others white outlined", () => {
    // Rect has 4 CPs (TL=0, TR=1, BR=2, BL=3). Mark CPs 0 and 2 as
    // partial-selected — those should fill solid blue, the other two
    // should fill white with a selection-blue outline.
    let doc = setSelection(makeDoc(), [[0, 0]]);
    doc = setPartialCps(doc, [0, 0], [0, 2]);
    const svg = renderSelectionLayer(doc);
    const handlesOnly = svg.replace(/<rect [^/]*stroke-dasharray[^/]*\/>/g, "");
    // Still 4 handle rects.
    assert.equal((handlesOnly.match(/<rect /g) || []).length, 4);
    // Two solid-blue handles, two white.
    const solid = (handlesOnly.match(/fill="rgba\(0, 120, 215, 0\.9\)"/g) || []).length;
    const white = (handlesOnly.match(/fill="white"/g) || []).length;
    assert.equal(solid, 2);
    assert.equal(white, 2);
  });

  it("degenerate bounds skipped", () => {
    const doc = {
      layers: [mkLayer({ children: [mkRect({ x: 0, y: 0, width: 0, height: 0 })] })],
      selection: [[0, 0]],
      artboards: [],
    };
    assert.equal(renderSelectionLayer(doc), "");
  });
});

describe("buffer_polyline overlay (Pencil)", () => {
  // The pencil.yaml overlay is type: buffer_polyline with `buffer:`
  // pointing at the named point buffer and `style:` for the stroke.
  // Renders a thin black polyline matching the raw drag — the
  // committed path is the smoothed fit_curve output, separate.
  const toolSpec = {
    id: "pencil",
    overlay: {
      if: "tool.pencil.mode == 'drawing'",
      render: {
        type: "buffer_polyline",
        buffer: "pencil_overlay_test",
        style: "stroke: black; stroke-width: 1;",
      },
    },
  };

  it("emits a polyline of the buffer's points while drawing", async () => {
    const buffers = await import("../../static/js/engine/point_buffers.mjs");
    buffers.clear("pencil_overlay_test");
    buffers.push("pencil_overlay_test", 10, 20);
    buffers.push("pencil_overlay_test", 30, 40);
    buffers.push("pencil_overlay_test", 50, 60);
    const scope = new Scope({ tool: { pencil: { mode: "drawing" } } });
    const svg = renderOverlayLayer(toolSpec, scope);
    assert.match(svg, /<polyline/);
    assert.match(svg, /points="10,20 30,40 50,60"/);
    assert.match(svg, /fill="none"/);
    assert.match(svg, /stroke: black/);
  });

  it("renders nothing when the guard is false", async () => {
    const buffers = await import("../../static/js/engine/point_buffers.mjs");
    buffers.clear("pencil_overlay_test");
    buffers.push("pencil_overlay_test", 10, 20);
    const scope = new Scope({ tool: { pencil: { mode: "idle" } } });
    assert.equal(renderOverlayLayer(toolSpec, scope), "");
  });

  it("renders nothing when the buffer is empty", async () => {
    const buffers = await import("../../static/js/engine/point_buffers.mjs");
    buffers.clear("pencil_overlay_test");
    const scope = new Scope({ tool: { pencil: { mode: "drawing" } } });
    assert.equal(renderOverlayLayer(toolSpec, scope), "");
  });
});

describe("partial_selection overlay", () => {
  // The partial_selection.yaml overlay has type "partial_selection_overlay"
  // — the Rust renderer draws path handles + a marquee rect. In Flask,
  // path handles already render in renderSelectionLayer; the overlay
  // only needs to emit the marquee rect when mode == 'marquee'.
  const toolSpec = {
    id: "partial_selection",
    overlay: {
      if: "true",
      render: {
        type: "partial_selection_overlay",
        mode: "tool.partial_selection.mode",
        marquee_start_x: "tool.partial_selection.marquee_start_x",
        marquee_start_y: "tool.partial_selection.marquee_start_y",
        marquee_cur_x: "tool.partial_selection.marquee_cur_x",
        marquee_cur_y: "tool.partial_selection.marquee_cur_y",
      },
    },
  };

  it("draws the marquee rect when mode == 'marquee'", () => {
    const scope = new Scope({ tool: { partial_selection: {
      mode: "marquee",
      marquee_start_x: 10, marquee_start_y: 20,
      marquee_cur_x: 110, marquee_cur_y: 80,
    } } });
    const svg = renderOverlayLayer(toolSpec, scope);
    assert.match(svg, /<rect/);
    assert.match(svg, /x="10"/);
    assert.match(svg, /y="20"/);
    assert.match(svg, /width="100"/);
    assert.match(svg, /height="60"/);
    // Dashed selection-blue stroke.
    assert.match(svg, /stroke-dasharray/);
  });

  it("renders nothing when mode != 'marquee'", () => {
    const scope = new Scope({ tool: { partial_selection: {
      mode: "idle",
      marquee_start_x: 0, marquee_start_y: 0,
      marquee_cur_x: 0, marquee_cur_y: 0,
    } } });
    assert.equal(renderOverlayLayer(toolSpec, scope), "");
  });
});

describe("renderOverlayLayer", () => {
  const toolSpec = {
    id: "selection",
    overlay: {
      if: "tool.selection.mode == 'marquee'",
      render: {
        type: "rect",
        x: "tool.selection.marquee_start_x",
        y: "tool.selection.marquee_start_y",
        width: "10",
        height: "10",
        style: "stroke: blue;",
      },
    },
  };

  it("empty when guard falsy", () => {
    const scope = new Scope({ tool: { selection: { mode: "idle" } } });
    assert.equal(renderOverlayLayer(toolSpec, scope), "");
  });

  it("renders when guard truthy", () => {
    const scope = new Scope({
      tool: { selection: { mode: "marquee", marquee_start_x: 50, marquee_start_y: 75 } },
    });
    const svg = renderOverlayLayer(toolSpec, scope);
    assert.match(svg, /<rect/);
    assert.match(svg, /x="50"/);
    assert.match(svg, /y="75"/);
    assert.match(svg, /style="stroke: blue;"/);
  });

  it("no overlay spec → empty", () => {
    assert.equal(renderOverlayLayer({ id: "x" }, new Scope({})), "");
    assert.equal(renderOverlayLayer(null, new Scope({})), "");
  });
});

// Minimal Artboard literals — match the cross-app contract documented in
// jas_dioxus/src/document/artboard.rs (id, name, x/y/width/height, fill,
// show_*, video_ruler_pixel_aspect_ratio).
function mkArtboard(over = {}) {
  return {
    id: "ab000001",
    name: "Artboard 1",
    x: 0, y: 0, width: 100, height: 80,
    fill: "transparent",
    show_center_mark: false,
    show_cross_hairs: false,
    show_video_safe_areas: false,
    video_ruler_pixel_aspect_ratio: 1.0,
    ...over,
  };
}

describe("renderArtboardFillLayer", () => {
  it("empty when no artboards", () => {
    const doc = { layers: [], selection: [], artboards: [] };
    assert.equal(renderArtboardFillLayer(doc), "");
  });

  it("emits no fill rect for a transparent artboard", () => {
    const doc = {
      layers: [], selection: [],
      artboards: [mkArtboard({ fill: "transparent" })],
    };
    assert.equal(renderArtboardFillLayer(doc), "");
  });

  it("emits fill rect for a colored artboard", () => {
    const doc = {
      layers: [], selection: [],
      artboards: [mkArtboard({ x: 10, y: 20, width: 30, height: 40, fill: "#ff8800" })],
    };
    const svg = renderArtboardFillLayer(doc);
    assert.match(svg, /<rect /);
    assert.match(svg, /x="10"/);
    assert.match(svg, /y="20"/);
    assert.match(svg, /width="30"/);
    assert.match(svg, /height="40"/);
    assert.match(svg, /fill="#ff8800"/);
  });

  it("preserves list order for multiple artboards", () => {
    const doc = {
      layers: [], selection: [],
      artboards: [
        mkArtboard({ id: "a", fill: "#111111", x: 0 }),
        mkArtboard({ id: "b", fill: "#222222", x: 200 }),
      ],
    };
    const svg = renderArtboardFillLayer(doc);
    assert.ok(svg.indexOf("#111111") < svg.indexOf("#222222"));
  });
});

describe("renderArtboardDecorationLayer", () => {
  it("empty when no artboards", () => {
    const doc = { layers: [], selection: [], artboards: [] };
    assert.equal(renderArtboardDecorationLayer(doc), "");
  });

  it("emits a thin border per artboard", () => {
    const doc = {
      layers: [], selection: [],
      artboards: [mkArtboard({ x: 5, y: 7, width: 50, height: 60 })],
    };
    const svg = renderArtboardDecorationLayer(doc);
    // First-pass: fade overlay disabled by default below; expect a border rect
    // sized to the artboard.
    assert.match(svg, /<rect[^/]*x="5"[^/]*y="7"[^/]*width="50"[^/]*height="60"[^/]*fill="none"/);
    assert.match(svg, /stroke="rgb\(48,48,48\)"/);
  });

  it("draws accent stroke on panel-selected artboards", () => {
    const doc = {
      layers: [], selection: [],
      artboards: [
        mkArtboard({ id: "a", x: 0 }),
        mkArtboard({ id: "b", x: 200 }),
      ],
    };
    const svg = renderArtboardDecorationLayer(doc, { panelSelectedIds: ["b"] });
    // One accent stroke (only "b"), in addition to two default borders.
    const accents = svg.match(/stroke="rgba\(0, ?120, ?215[^"]*"/g) || [];
    assert.equal(accents.length, 1);
  });

  it("emits label '<n>  <name>' for each artboard", () => {
    const doc = {
      layers: [], selection: [],
      artboards: [
        mkArtboard({ name: "Cover", x: 0, y: 100 }),
        mkArtboard({ name: "Page 2", x: 200, y: 100 }),
      ],
    };
    const svg = renderArtboardDecorationLayer(doc);
    assert.match(svg, /<text[^>]*>1  Cover<\/text>/);
    assert.match(svg, /<text[^>]*>2  Page 2<\/text>/);
  });

  it("paints a fade mask when fade_region_outside_artboard is set", () => {
    const doc = {
      layers: [], selection: [],
      artboards: [mkArtboard({ x: 50, y: 50, width: 100, height: 80 })],
      artboard_options: { fade_region_outside_artboard: true },
    };
    const svg = renderArtboardDecorationLayer(doc, {
      viewBox: { x: 0, y: 0, width: 800, height: 600 },
    });
    // The fade is rendered as a single <path> with even-odd fill rule:
    // outer rect = viewBox, inner rects = artboards (punched through).
    assert.match(svg, /<path[^>]*fill-rule="evenodd"/);
    assert.match(svg, /fill="rgba\(160, ?160, ?160[^"]*"/);
  });

  it("skips fade when artboard_options is absent", () => {
    const doc = {
      layers: [], selection: [],
      artboards: [mkArtboard()],
    };
    const svg = renderArtboardDecorationLayer(doc, {
      viewBox: { x: 0, y: 0, width: 800, height: 600 },
    });
    assert.doesNotMatch(svg, /fill-rule="evenodd"/);
  });
});

describe("renderCanvas", () => {
  it("returns all layers including artboard fill + decoration", () => {
    const doc = setSelection(makeDoc(), [[0, 0]]);
    const out = renderCanvas({
      doc,
      activeTool: "selection",
      toolSpec: null,
      scope: new Scope({}),
      viewport: { pan_x: 100, pan_y: 50, zoom: 2 },
    });
    assert.equal(typeof out.artboardFillLayer, "string");
    assert.equal(typeof out.artboardDecorationLayer, "string");
    assert.match(out.documentLayer, /<rect /);
    assert.match(out.selectionLayer, /stroke-dasharray/);
    assert.equal(out.overlayLayer, "");
    assert.equal(out.viewportTransform, "translate(100px, 50px) scale(2)");
  });

  it("defaults for missing viewport", () => {
    const out = renderCanvas({ doc: makeDoc() });
    assert.equal(out.viewportTransform, "translate(0,0) scale(1)");
  });
});
