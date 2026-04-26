// Tests for engine/svg_io.mjs.
//
// exportSVG is pure JS (no DOM dep) — testable in Node directly.
// importSVG needs DOMParser; skip those tests unless jsdom is
// available. The browser path is exercised manually for V1.

import { describe, it } from "node:test";
import assert from "node:assert/strict";

import { exportSVG, importSVG } from "../../static/js/engine/svg_io.mjs";
import { emptyDocument, mkRect, mkCircle, mkEllipse, mkLine, mkPath, mkLayer, mkGroup }
  from "../../static/js/engine/document.mjs";

describe("exportSVG", () => {
  it("emits an XML preamble + svg root with viewBox", () => {
    const out = exportSVG(emptyDocument(), { width: 800, height: 600 });
    assert.match(out, /^<\?xml version="1.0"/);
    assert.match(out, /<svg [^>]*viewBox="0 0 800 600"/);
    assert.match(out, /<\/svg>/);
  });

  it("wraps the default Layer 1 in a <g>", () => {
    const out = exportSVG(emptyDocument());
    assert.match(out, /<g[^>]*>/);
  });

  it("serializes a rect with paint attrs", () => {
    const doc = emptyDocument();
    doc.layers[0].children.push(
      mkRect({ x: 10, y: 20, width: 30, height: 40,
               fill: "#ff0000", stroke: "#000000", stroke_width: 2 }),
    );
    const out = exportSVG(doc);
    assert.match(out, /<rect[^/]*x="10"/);
    assert.match(out, /y="20"/);
    assert.match(out, /width="30"/);
    assert.match(out, /height="40"/);
    assert.match(out, /fill="#ff0000"/);
    assert.match(out, /stroke="#000000"/);
    assert.match(out, /stroke-width="2"/);
  });

  it("serializes circles, ellipses, lines, paths", () => {
    const doc = emptyDocument();
    doc.layers[0].children.push(
      mkCircle({ cx: 50, cy: 50, r: 10, fill: "blue" }),
      mkEllipse({ cx: 100, cy: 100, rx: 20, ry: 30 }),
      mkLine({ x1: 0, y1: 0, x2: 100, y2: 100, stroke: "black" }),
      mkPath({ d: [
        { type: "M", x: 0, y: 0 },
        { type: "C", x1: 10, y1: 0, x2: 10, y2: 10, x: 20, y: 10 },
        { type: "Z" },
      ], fill: "green" }),
    );
    const out = exportSVG(doc);
    assert.match(out, /<circle[^/]*cx="50"[^/]*r="10"/);
    assert.match(out, /<ellipse[^/]*rx="20"/);
    assert.match(out, /<line[^/]*x2="100"/);
    assert.match(out, /<path[^/]*d="M 0 0 C 10 0 10 10 20 10 Z"/);
  });

  it("escapes special characters in text content", () => {
    const doc = emptyDocument();
    doc.layers[0].children.push({
      type: "text", x: 10, y: 20, content: "a & b < c", font_size: 12,
    });
    const out = exportSVG(doc);
    assert.match(out, /a &amp; b &lt; c/);
  });

  it("nested groups serialize as nested <g>", () => {
    const doc = emptyDocument();
    doc.layers[0].children.push(
      mkGroup({ children: [
        mkRect({ x: 0, y: 0, width: 10, height: 10 }),
        mkRect({ x: 20, y: 0, width: 10, height: 10 }),
      ]}),
    );
    const out = exportSVG(doc);
    // Outer Layer <g>, inner Group <g>, two rects.
    assert.equal((out.match(/<g\b/g) || []).length, 2);
    assert.equal((out.match(/<rect\b/g) || []).length, 2);
  });

  it("opacity != 1 is serialized; opacity == 1 is omitted", () => {
    const doc = emptyDocument();
    doc.layers[0].children.push(
      mkRect({ x: 0, y: 0, width: 10, height: 10, opacity: 0.5 }),
      mkRect({ x: 20, y: 0, width: 10, height: 10 }),
    );
    const out = exportSVG(doc);
    assert.match(out, /opacity="0.5"/);
    // The default-opacity rect should not have an opacity attr.
    const rects = out.match(/<rect[^/]*\/>/g) || [];
    assert.equal(rects.length, 2);
    assert.equal(rects.filter(r => /opacity=/.test(r)).length, 1);
  });

  it("locked elements get a data-locked='true' marker", () => {
    const doc = emptyDocument();
    doc.layers[0].children.push(
      mkRect({ x: 0, y: 0, width: 10, height: 10, locked: true }),
    );
    const out = exportSVG(doc);
    assert.match(out, /data-locked="true"/);
  });

  it("default canvas size 800x600 when opts omitted", () => {
    const out = exportSVG(emptyDocument());
    assert.match(out, /width="800"/);
    assert.match(out, /height="600"/);
  });
});

describe("importSVG (skipped when DOMParser unavailable)", { skip: typeof DOMParser === "undefined" }, () => {
  it("returns null for empty / non-string input", () => {
    assert.equal(importSVG(""), null);
    assert.equal(importSVG(null), null);
  });
});
