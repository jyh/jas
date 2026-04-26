// Phase 3b smoke tests: validate that the line, ellipse, hand, and
// zoom tool yamls dispatch cleanly through engine/tools.mjs and
// land on the correct doc / store mutations.
//
// These tools were already authored as yaml; this file just
// proves the wiring is alive end-to-end.

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

import { Model } from "../../static/js/engine/model.mjs";
import { emptyDocument, getElement } from "../../static/js/engine/document.mjs";
import { StateStore } from "../../static/js/engine/store.mjs";
import { registerTools, dispatchEvent, _resetForTesting }
  from "../../static/js/engine/tools.mjs";

const ws = JSON.parse(fs.readFileSync(
  new URL("../../../workspace/workspace.json", import.meta.url)));

const noMods = { shift: false, ctrl: false, alt: false, meta: false };

function newRig() {
  _resetForTesting();
  const model = new Model(emptyDocument());
  const store = new StateStore();
  registerTools(ws.tools, store);
  return { model, store };
}

describe("line tool", () => {
  beforeEach(_resetForTesting);

  it("press-drag-release commits a line element", () => {
    const { model, store } = newRig();
    dispatchEvent("line", { type: "mousedown", x: 5, y: 10, modifiers: noMods },
                  store, { model });
    assert.equal(store.get("tool.line.mode"), "drawing");
    dispatchEvent("line", { type: "mousemove", x: 50, y: 60, modifiers: noMods },
                  store, { model });
    dispatchEvent("line", { type: "mouseup", x: 50, y: 60, modifiers: noMods },
                  store, { model });
    assert.equal(store.get("tool.line.mode"), "idle");
    assert.equal(model.document.layers[0].children.length, 1);
    const ln = getElement(model.document, [0, 0]);
    assert.equal(ln.type, "line");
    assert.equal(ln.x1, 5);
    assert.equal(ln.y1, 10);
    assert.equal(ln.x2, 50);
    assert.equal(ln.y2, 60);
  });

  it("hypot < 2 click is suppressed (no line committed)", () => {
    // Stray click — distance below the 2px threshold should not
    // produce a degenerate line. Native LineTool guards against
    // this; the yaml mirrors it.
    const { model, store } = newRig();
    dispatchEvent("line", { type: "mousedown", x: 10, y: 10, modifiers: noMods },
                  store, { model });
    dispatchEvent("line", { type: "mouseup", x: 11, y: 11, modifiers: noMods },
                  store, { model });
    assert.equal(model.document.layers[0].children.length, 0);
  });

  it("escape resets mode to idle without committing", () => {
    const { model, store } = newRig();
    dispatchEvent("line", { type: "mousedown", x: 0, y: 0, modifiers: noMods },
                  store, { model });
    dispatchEvent("line",
      { type: "keydown", key: "Escape", modifiers: noMods }, store, { model });
    assert.equal(store.get("tool.line.mode"), "idle");
    assert.equal(model.document.layers[0].children.length, 0);
  });
});

describe("ellipse tool", () => {
  beforeEach(_resetForTesting);

  it("press adds a zero-sized ellipse; drag resizes it", () => {
    // Ellipse uses a different shape: snapshot + add zero-sized
    // element on mousedown, then doc.set_attr each mousemove
    // re-centers / resizes the just-added element.
    const { model, store } = newRig();
    dispatchEvent("ellipse",
      { type: "mousedown", x: 100, y: 100, modifiers: noMods }, store, { model });
    assert.equal(model.document.layers[0].children.length, 1);
    const e0 = getElement(model.document, [0, 0]);
    assert.equal(e0.type, "ellipse");
    assert.equal(e0.cx, 100);
    assert.equal(e0.rx, 0);

    dispatchEvent("ellipse",
      { type: "mousemove", x: 200, y: 180, modifiers: noMods }, store, { model });
    const e1 = getElement(model.document, [0, 0]);
    // Center: midpoint of start and current.
    assert.equal(e1.cx, 150);
    assert.equal(e1.cy, 140);
    // Radii: half the abs delta.
    assert.equal(e1.rx, 50);
    assert.equal(e1.ry, 40);
  });

  it("mouseup leaves the resized ellipse on the layer", () => {
    const { model, store } = newRig();
    dispatchEvent("ellipse",
      { type: "mousedown", x: 0, y: 0, modifiers: noMods }, store, { model });
    dispatchEvent("ellipse",
      { type: "mousemove", x: 40, y: 60, modifiers: noMods }, store, { model });
    dispatchEvent("ellipse",
      { type: "mouseup", x: 40, y: 60, modifiers: noMods }, store, { model });
    assert.equal(store.get("tool.ellipse.mode"), "idle");
    assert.equal(model.document.layers[0].children.length, 1);
    const e = getElement(model.document, [0, 0]);
    assert.equal(e.cx, 20);
    assert.equal(e.rx, 20);
    assert.equal(e.ry, 30);
  });
});

describe("pencil tool", () => {
  beforeEach(_resetForTesting);

  it("press-drag-release commits a smoothed path", () => {
    // Pencil pushes points into the named buffer on each move and
    // calls doc.add_path_from_buffer on release; the engine's
    // fit_curve smooths the polyline into a Bezier sequence.
    const { model, store } = newRig();
    dispatchEvent("pencil",
      { type: "mousedown", x: 0, y: 0, modifiers: noMods }, store, { model });
    assert.equal(store.get("tool.pencil.mode"), "drawing");
    for (let i = 1; i <= 5; i++) {
      dispatchEvent("pencil",
        { type: "mousemove", x: i * 10, y: i * 5, modifiers: noMods },
        store, { model });
    }
    dispatchEvent("pencil",
      { type: "mouseup", x: 60, y: 30, modifiers: noMods }, store, { model });
    assert.equal(store.get("tool.pencil.mode"), "idle");
    assert.equal(model.document.layers[0].children.length, 1);
    const path = getElement(model.document, [0, 0]);
    assert.equal(path.type, "path");
    assert.ok(Array.isArray(path.d) && path.d.length >= 2,
      "path commands should include MoveTo + at least one CurveTo");
    assert.equal(path.d[0].type, "M");
  });

  it("escape during drag clears the buffer (no path committed)", () => {
    const { model, store } = newRig();
    dispatchEvent("pencil",
      { type: "mousedown", x: 0, y: 0, modifiers: noMods }, store, { model });
    dispatchEvent("pencil",
      { type: "mousemove", x: 10, y: 10, modifiers: noMods }, store, { model });
    dispatchEvent("pencil",
      { type: "keydown", key: "Escape", modifiers: noMods }, store, { model });
    assert.equal(store.get("tool.pencil.mode"), "idle");
    // mouseup after escape should not commit (mode is no longer drawing).
    dispatchEvent("pencil",
      { type: "mouseup", x: 10, y: 10, modifiers: noMods }, store, { model });
    assert.equal(model.document.layers[0].children.length, 0);
  });
});

describe("hand tool", () => {
  beforeEach(_resetForTesting);

  it("dispatch on hand events does not throw and does not mutate doc", () => {
    // Hand pans the canvas via state mutations, not document
    // mutations. Tool yaml may write to viewport state but should
    // never call doc.add_element / doc.set_attr / etc. — confirm
    // by asserting the document is unchanged.
    const { model, store } = newRig();
    const startGen = model.generation;
    dispatchEvent("hand",
      { type: "mousedown", x: 10, y: 10, modifiers: noMods }, store, { model });
    dispatchEvent("hand",
      { type: "mousemove", x: 50, y: 60, modifiers: noMods }, store, { model });
    dispatchEvent("hand",
      { type: "mouseup", x: 50, y: 60, modifiers: noMods }, store, { model });
    assert.equal(model.document.layers[0].children.length, 0);
    // generation should not have advanced (no document mutation).
    assert.equal(model.generation, startGen);
  });
});

describe("zoom tool", () => {
  beforeEach(_resetForTesting);

  it("dispatch on zoom events does not throw and does not mutate doc", () => {
    const { model, store } = newRig();
    const startGen = model.generation;
    dispatchEvent("zoom",
      { type: "mousedown", x: 10, y: 10, modifiers: noMods }, store, { model });
    dispatchEvent("zoom",
      { type: "mouseup", x: 10, y: 10, modifiers: noMods }, store, { model });
    assert.equal(model.document.layers[0].children.length, 0);
    assert.equal(model.generation, startGen);
  });
});
