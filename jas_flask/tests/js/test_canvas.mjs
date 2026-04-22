// Tests for the canvas layer orchestrator (document + selection + overlay).

import { describe, it } from "node:test";
import assert from "node:assert/strict";

import {
  renderCanvas, renderDocumentLayer, renderSelectionLayer, renderOverlayLayer,
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

describe("renderCanvas", () => {
  it("returns all four layers", () => {
    const doc = setSelection(makeDoc(), [[0, 0]]);
    const out = renderCanvas({
      doc,
      activeTool: "selection",
      toolSpec: null,
      scope: new Scope({}),
      viewport: { pan_x: 100, pan_y: 50, zoom: 2 },
    });
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
