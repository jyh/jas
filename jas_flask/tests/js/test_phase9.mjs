// Integration tests for Phase 9: hit_test primitive + translate / rect-select
// / delete doc.* effects.

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

import { StateStore } from "../../static/js/engine/store.mjs";
import { Model } from "../../static/js/engine/model.mjs";
import { runEffects } from "../../static/js/engine/effects.mjs";
import { registerTools, dispatchEvent, _resetForTesting } from "../../static/js/engine/tools.mjs";
import {
  mkLayer, mkRect, mkCircle, setSelection, getElement,
} from "../../static/js/engine/document.mjs";
import { evaluate } from "../../static/js/engine/expr.mjs";
import { Scope } from "../../static/js/engine/scope.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const WORKSPACE_JSON = resolve(__dirname, "../../../workspace/workspace.json");
const workspaceDataPromise = readFile(WORKSPACE_JSON, "utf-8").then(JSON.parse);

function makeDoc() {
  return {
    layers: [mkLayer({
      name: "L1",
      children: [
        mkRect({ x: 0, y: 0, width: 20, height: 20 }),
        mkRect({ x: 50, y: 50, width: 20, height: 20 }),
      ],
    })],
    selection: [],
    artboards: [],
  };
}

describe("doc.translate_selection", () => {
  it("moves selected rect by (dx, dy)", () => {
    const model = new Model(setSelection(makeDoc(), [[0, 0]]));
    const store = new StateStore();
    runEffects(
      [{ "doc.translate_selection": { dx: "10", dy: "20" } }],
      store.asContext(),
      store,
      { model },
    );
    const rect = getElement(model.document, [0, 0]);
    assert.equal(rect.x, 10);
    assert.equal(rect.y, 20);
  });

  it("moves multiple selected elements", () => {
    const model = new Model(setSelection(makeDoc(), [[0, 0], [0, 1]]));
    const store = new StateStore();
    runEffects(
      [{ "doc.translate_selection": { dx: "5", dy: "0" } }],
      store.asContext(),
      store,
      { model },
    );
    assert.equal(getElement(model.document, [0, 0]).x, 5);
    assert.equal(getElement(model.document, [0, 1]).x, 55);
  });

  it("no-op on zero translation", () => {
    const model = new Model(setSelection(makeDoc(), [[0, 0]]));
    const before = model.document;
    const store = new StateStore();
    runEffects(
      [{ "doc.translate_selection": { dx: "0", dy: "0" } }],
      store.asContext(),
      store,
      { model },
    );
    assert.equal(model.document, before); // reference equality
  });
});

describe("doc.select_in_rect", () => {
  it("selects all elements intersecting rect", () => {
    const model = new Model(makeDoc());
    const store = new StateStore();
    runEffects(
      [{ "doc.select_in_rect": { x1: "0", y1: "0", x2: "25", y2: "25" } }],
      store.asContext(),
      store,
      { model },
    );
    assert.equal(model.selection.length, 1);
    assert.deepEqual(model.selection[0], [0, 0]);
  });

  it("selects both when rect covers both", () => {
    const model = new Model(makeDoc());
    const store = new StateStore();
    runEffects(
      [{ "doc.select_in_rect": { x1: "0", y1: "0", x2: "100", y2: "100" } }],
      store.asContext(),
      store,
      { model },
    );
    assert.equal(model.selection.length, 2);
  });

  it("additive mode adds to existing selection", () => {
    const model = new Model(setSelection(makeDoc(), [[0, 0]]));
    const store = new StateStore();
    runEffects(
      [{ "doc.select_in_rect": {
        x1: "40", y1: "40", x2: "80", y2: "80", additive: "true",
      } }],
      store.asContext(),
      store,
      { model },
    );
    assert.equal(model.selection.length, 2);
  });

  it("non-additive replaces selection", () => {
    const model = new Model(setSelection(makeDoc(), [[0, 0]]));
    const store = new StateStore();
    runEffects(
      [{ "doc.select_in_rect": {
        x1: "40", y1: "40", x2: "80", y2: "80", additive: "false",
      } }],
      store.asContext(),
      store,
      { model },
    );
    assert.equal(model.selection.length, 1);
    assert.deepEqual(model.selection[0], [0, 1]);
  });
});

describe("doc.delete_selection", () => {
  it("removes selected elements", () => {
    const model = new Model(setSelection(makeDoc(), [[0, 0]]));
    const store = new StateStore();
    runEffects(
      [{ "doc.delete_selection": {} }],
      store.asContext(),
      store,
      { model },
    );
    assert.equal(model.document.layers[0].children.length, 1);
    assert.equal(model.selection.length, 0);
  });

  it("removes multiple, index-shift safe", () => {
    const model = new Model(setSelection(makeDoc(), [[0, 0], [0, 1]]));
    const store = new StateStore();
    runEffects(
      [{ "doc.delete_selection": {} }],
      store.asContext(),
      store,
      { model },
    );
    assert.equal(model.document.layers[0].children.length, 0);
  });
});

describe("hit_test primitive", () => {
  beforeEach(_resetForTesting);

  it("evaluates to element path inside element bounds", async () => {
    const model = new Model(makeDoc());
    const store = new StateStore();
    const ws = await workspaceDataPromise;
    registerTools(ws.tools, store);

    // Dispatch a fake event that causes selection handler to run
    // hit_test; then verify via the effect's observable outcome.
    dispatchEvent(
      "selection",
      {
        type: "mousedown", x: 5, y: 5,
        modifiers: { shift: false, ctrl: false, alt: false, meta: false },
      },
      store,
      { model },
    );
    // First rect at (0,0,20,20) contains (5,5). The tool hit the
    // element, took a snapshot, set selection to that path, and
    // moved into drag_move mode.
    assert.equal(store.get("tool.selection.mode"), "drag_move");
    assert.equal(model.selection.length, 1);
    assert.deepEqual(model.selection[0], [0, 0]);
    assert.ok(model.canUndo);
  });

  it("returns null for empty space, tool enters marquee mode", async () => {
    const model = new Model(makeDoc());
    const store = new StateStore();
    const ws = await workspaceDataPromise;
    registerTools(ws.tools, store);

    dispatchEvent(
      "selection",
      {
        type: "mousedown", x: 200, y: 200,
        modifiers: { shift: false, ctrl: false, alt: false, meta: false },
      },
      store,
      { model },
    );
    assert.equal(store.get("tool.selection.mode"), "marquee");
    // Empty space + no shift → selection cleared.
    assert.equal(model.selection.length, 0);
  });
});

describe("selection tool — drag rectangle end-to-end", () => {
  beforeEach(_resetForTesting);

  it("marquee drag selects intersecting elements", async () => {
    const model = new Model(makeDoc());
    const store = new StateStore();
    const ws = await workspaceDataPromise;
    registerTools(ws.tools, store);

    // Start marquee at empty space.
    dispatchEvent("selection", {
      type: "mousedown", x: 100, y: 100,
      modifiers: { shift: false, ctrl: false, alt: false, meta: false },
    }, store, { model });
    assert.equal(store.get("tool.selection.mode"), "marquee");

    // Drag up to (0, 0) to cover first rect.
    dispatchEvent("selection", {
      type: "mousemove", x: 0, y: 0,
      modifiers: { shift: false, ctrl: false, alt: false, meta: false },
    }, store, { model });

    // Release — select_in_rect fires.
    dispatchEvent("selection", {
      type: "mouseup", x: 0, y: 0,
      modifiers: { shift: false, ctrl: false, alt: false, meta: false },
    }, store, { model });

    assert.equal(store.get("tool.selection.mode"), "idle");
    assert.equal(model.selection.length, 2); // both rects in [0..100, 0..100]
  });

  it("drag an element moves it", async () => {
    const model = new Model(makeDoc());
    const store = new StateStore();
    const ws = await workspaceDataPromise;
    registerTools(ws.tools, store);

    // Click on first rect (at 5,5 inside {0,0,20,20}).
    dispatchEvent("selection", {
      type: "mousedown", x: 5, y: 5,
      modifiers: { shift: false, ctrl: false, alt: false, meta: false },
    }, store, { model });
    assert.equal(store.get("tool.selection.mode"), "drag_move");

    // Drag by 30 px right, 40 px down.
    dispatchEvent("selection", {
      type: "mousemove", x: 35, y: 45,
      modifiers: { shift: false, ctrl: false, alt: false, meta: false },
    }, store, { model });

    // Release.
    dispatchEvent("selection", {
      type: "mouseup", x: 35, y: 45,
      modifiers: { shift: false, ctrl: false, alt: false, meta: false },
    }, store, { model });

    const rect = getElement(model.document, [0, 0]);
    assert.equal(rect.x, 30);
    assert.equal(rect.y, 40);
    assert.equal(store.get("tool.selection.mode"), "idle");
  });
});
