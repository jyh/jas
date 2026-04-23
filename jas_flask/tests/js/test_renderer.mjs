// Tests for the SVG renderer (document layer + element renderers).

import { describe, it } from "node:test";
import assert from "node:assert/strict";

import {
  renderElement, renderDocument,
  setBrushLibraries, lookupBrush,
} from "../../static/js/engine/renderer.mjs";
import {
  mkRect, mkCircle, mkEllipse, mkLine, mkPath, mkText,
  mkGroup, mkLayer,
} from "../../static/js/engine/document.mjs";

describe("renderer — leaf elements", () => {
  it("rect emits <rect x= y= width= height= …/>", () => {
    const svg = renderElement(mkRect({ x: 10, y: 20, width: 30, height: 40, fill: "#ff0000" }));
    assert.match(svg, /^<rect /);
    assert.match(svg, /x="10"/);
    assert.match(svg, /y="20"/);
    assert.match(svg, /width="30"/);
    assert.match(svg, /height="40"/);
    assert.match(svg, /fill="#ff0000"/);
  });

  it("circle", () => {
    const svg = renderElement(mkCircle({ cx: 50, cy: 50, r: 10 }));
    assert.match(svg, /<circle/);
    assert.match(svg, /cx="50"/);
    assert.match(svg, /r="10"/);
  });

  it("ellipse", () => {
    const svg = renderElement(mkEllipse({ cx: 50, cy: 50, rx: 10, ry: 5 }));
    assert.match(svg, /<ellipse/);
    assert.match(svg, /rx="10"/);
    assert.match(svg, /ry="5"/);
  });

  it("line", () => {
    const svg = renderElement(mkLine({ x1: 0, y1: 0, x2: 100, y2: 50 }));
    assert.match(svg, /x1="0"/);
    assert.match(svg, /x2="100"/);
  });

  it("text escapes content", () => {
    const svg = renderElement(mkText({ x: 0, y: 12, content: "<hi>" }));
    assert.match(svg, /&lt;hi&gt;/);
    assert.doesNotMatch(svg, /<hi>/);
  });

  it("path with M + L + Z", () => {
    const svg = renderElement(mkPath({
      d: [
        { type: "M", x: 0, y: 0 },
        { type: "L", x: 10, y: 10 },
        { type: "Z" },
      ],
    }));
    assert.match(svg, /d="M 0 0 L 10 10 Z"/);
  });
});

describe("renderer — styles", () => {
  it("fill: null → fill=\"none\"", () => {
    const svg = renderElement(mkRect({ fill: null }));
    assert.match(svg, /fill="none"/);
  });

  it("stroke object → stroke + stroke-width", () => {
    const svg = renderElement(mkRect({
      stroke: { color: "#000000", width: 2 },
    }));
    assert.match(svg, /stroke="#000000"/);
    assert.match(svg, /stroke-width="2"/);
  });

  it("opacity emits when !== 1", () => {
    const svg = renderElement(mkRect({ opacity: 0.5 }));
    assert.match(svg, /opacity="0.5"/);
  });

  it("opacity=1 omitted", () => {
    const svg = renderElement(mkRect({ opacity: 1.0 }));
    assert.doesNotMatch(svg, /opacity=/);
  });

  it("outline visibility forces thin outline", () => {
    const svg = renderElement(mkRect({ visibility: "outline", fill: "#ff0000" }));
    assert.match(svg, /fill="none"/);
    assert.match(svg, /stroke="#666"/);
  });

  it("invisible → empty string", () => {
    assert.equal(renderElement(mkRect({ visibility: "invisible" })), "");
  });
});

describe("renderer — containers", () => {
  it("group wraps children in <g>", () => {
    const svg = renderElement(mkGroup({
      children: [mkRect({ x: 0, y: 0, width: 5, height: 5 })],
    }));
    assert.match(svg, /^<g/);
    assert.match(svg, /<rect /);
    assert.match(svg, /<\/g>$/);
  });

  it("layer wraps children in <g>", () => {
    const svg = renderElement(mkLayer({
      children: [mkRect(), mkCircle({ r: 3 })],
    }));
    assert.match(svg, /<rect /);
    assert.match(svg, /<circle /);
  });

  it("nested group", () => {
    const svg = renderElement(mkGroup({
      children: [mkGroup({ children: [mkRect()] })],
    }));
    // Two <g> opens, two closes.
    assert.equal((svg.match(/<g/g) || []).length, 2);
  });

  it("container opacity", () => {
    const svg = renderElement(mkGroup({ opacity: 0.3, children: [] }));
    assert.match(svg, /opacity="0.3"/);
  });
});

describe("renderDocument", () => {
  it("concatenates layer renderings", () => {
    const doc = {
      layers: [
        mkLayer({ children: [mkRect({ x: 0, y: 0, width: 5, height: 5 })] }),
        mkLayer({ children: [mkCircle({ r: 3 })] }),
      ],
      selection: [], artboards: [],
    };
    const svg = renderDocument(doc);
    assert.match(svg, /<rect /);
    assert.match(svg, /<circle /);
  });

  it("empty document → empty string", () => {
    assert.equal(renderDocument({ layers: [], selection: [], artboards: [] }), "");
  });
});

describe("number formatting", () => {
  it("integer has no decimal", () => {
    assert.match(renderElement(mkRect({ x: 42 })), /x="42"/);
  });

  it("float gets up to 6 decimals, trailing zeros trimmed", () => {
    assert.match(renderElement(mkRect({ x: 1.5 })), /x="1\.5"/);
    assert.match(renderElement(mkRect({ x: 0.1 + 0.2 })), /x="0\.3"/);
  });
});

describe("brush library registry", () => {
  it("setBrushLibraries replaces the registry", () => {
    setBrushLibraries({
      lib_a: { brushes: [{ slug: "b1", type: "calligraphic", angle: 0, roundness: 100, size: 4 }] },
    });
    assert.ok(lookupBrush("lib_a/b1"));
    setBrushLibraries({});
    assert.equal(lookupBrush("lib_a/b1"), null);
  });

  it("lookupBrush handles bad input", () => {
    setBrushLibraries({});
    assert.equal(lookupBrush(null), null);
    assert.equal(lookupBrush(""), null);
    assert.equal(lookupBrush("noslash"), null);
    assert.equal(lookupBrush("lib/missing"), null);
  });
});

describe("renderer — brushed paths", () => {
  it("path with stroke_brush emits brushed outline", () => {
    setBrushLibraries({
      default_brushes: {
        brushes: [
          { slug: "oval_5pt", type: "calligraphic", angle: 0, roundness: 100, size: 4 },
        ],
      },
    });
    const p = mkPath({
      d: [{ type: "M", x: 0, y: 0 }, { type: "L", x: 10, y: 0 }],
      stroke_brush: "default_brushes/oval_5pt",
      stroke: { color: "#ff0000" },
    });
    const svg = renderElement(p);
    // Brushed render emits a single closed path filled with stroke
    // colour; no plain stroke= attribute (we use fill).
    assert.match(svg, /^<path /);
    assert.match(svg, /fill="#ff0000"/);
    assert.match(svg, /stroke="none"/);
    assert.match(svg, /jas:stroke-brush="default_brushes\/oval_5pt"/);
    // Outline path should be closed (Z) and have multiple L commands.
    assert.match(svg, / Z"/);
  });

  it("path with stroke_brush but unknown slug falls back to plain", () => {
    setBrushLibraries({});
    const p = mkPath({
      d: [{ type: "M", x: 0, y: 0 }, { type: "L", x: 10, y: 0 }],
      stroke_brush: "no_such_lib/no_such_brush",
      stroke: { color: "#ff0000", width: 2 },
    });
    const svg = renderElement(p);
    // Falls back to plain path render — no jas:stroke-brush in output,
    // and the original stroke= attribute is honoured.
    assert.doesNotMatch(svg, /jas:stroke-brush/);
    assert.match(svg, /stroke="#ff0000"/);
    assert.match(svg, /stroke-width="2"/);
  });

  it("path without stroke_brush uses plain renderer", () => {
    const p = mkPath({
      d: [{ type: "M", x: 0, y: 0 }, { type: "L", x: 10, y: 0 }],
      stroke: { color: "#000000", width: 1 },
    });
    const svg = renderElement(p);
    assert.match(svg, /^<path /);
    assert.doesNotMatch(svg, /jas:stroke-brush/);
    assert.match(svg, /d="M 0 0 L 10 0"/);
  });

  it("stroke_brush of unknown brush type falls back to plain path", () => {
    // Phase 1 only renders Calligraphic; other types should not crash
    // — they fall back to the plain path render until their renderer
    // lands.
    setBrushLibraries({
      lib: { brushes: [{ slug: "art_brush", type: "art" }] },
    });
    const p = mkPath({
      d: [{ type: "M", x: 0, y: 0 }, { type: "L", x: 10, y: 0 }],
      stroke_brush: "lib/art_brush",
      stroke: { color: "#00ff00" },
    });
    const svg = renderElement(p);
    assert.match(svg, /^<path /);
    assert.doesNotMatch(svg, /jas:stroke-brush/);
    assert.match(svg, /stroke="#00ff00"/);
  });

  it("degenerate brushed path (single MoveTo) emits empty string", () => {
    setBrushLibraries({
      default_brushes: {
        brushes: [
          { slug: "oval_5pt", type: "calligraphic", angle: 0, roundness: 100, size: 4 },
        ],
      },
    });
    const p = mkPath({
      d: [{ type: "M", x: 5, y: 5 }],
      stroke_brush: "default_brushes/oval_5pt",
      stroke: { color: "#ff0000" },
    });
    const svg = renderElement(p);
    assert.equal(svg, "");
  });
});
