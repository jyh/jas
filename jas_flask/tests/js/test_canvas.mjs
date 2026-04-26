// Tests for the canvas layer orchestrator (document + selection + overlay).

import { describe, it } from "node:test";
import assert from "node:assert/strict";

import {
  renderCanvas, renderDocumentLayer, renderSelectionLayer, renderOverlayLayer,
  renderArtboardFillLayer, renderArtboardDecorationLayer,
} from "../../static/js/engine/canvas.mjs";
import {
  mkLayer, mkRect, mkCircle, setSelection,
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
    assert.equal((svg.match(/<rect /g) || []).length, 2);
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
