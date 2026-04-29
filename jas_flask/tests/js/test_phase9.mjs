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

  it("partial CPs on a Path: translates only listed anchors", async () => {
    const { mkPath, setPartialCps } =
      await import("../../static/js/engine/document.mjs");
    const path = mkPath({ d: [
      { type: "M", x: 0, y: 0 },
      { type: "L", x: 100, y: 0 },
      { type: "L", x: 100, y: 80 },
      { type: "L", x: 0, y: 80 },
    ] });
    const doc = setSelection({
      layers: [mkLayer({ children: [path] })],
      selection: [], artboards: [],
    }, [[0, 0]]);
    // Mark anchors 1 and 2 (the right-side corners) as partial-selected.
    const docWithPartial = setPartialCps(doc, [0, 0], [1, 2]);
    const model = new Model(docWithPartial);
    const store = new StateStore();
    runEffects(
      [{ "doc.translate_selection": { dx: "10", dy: "5" } }],
      store.asContext(), store, { model },
    );
    const after = getElement(model.document, [0, 0]);
    // Anchor 0 unchanged.
    assert.equal(after.d[0].x, 0);
    assert.equal(after.d[0].y, 0);
    // Anchors 1 and 2 shifted by (10, 5).
    assert.equal(after.d[1].x, 110);
    assert.equal(after.d[1].y, 5);
    assert.equal(after.d[2].x, 110);
    assert.equal(after.d[2].y, 85);
    // Anchor 3 unchanged.
    assert.equal(after.d[3].x, 0);
    assert.equal(after.d[3].y, 80);
  });

  it("partial CPs translate the in/out handles attached to the moving anchor", async () => {
    const { mkPath, setPartialCps } =
      await import("../../static/js/engine/document.mjs");
    // M 0,0; C 10,-10  20,-10  30,0; C 40,10  50,10  60,0
    // Three anchors: 0, 1 (at 30,0), 2 (at 60,0). Each curve's handles
    // belong to the adjacent anchors.
    const path = mkPath({ d: [
      { type: "M", x: 0, y: 0 },
      { type: "C", x1: 10, y1: -10, x2: 20, y2: -10, x: 30, y: 0 },
      { type: "C", x1: 40, y1: 10,  x2: 50, y2: 10,  x: 60, y: 0 },
    ] });
    const doc = setSelection({
      layers: [mkLayer({ children: [path] })],
      selection: [], artboards: [],
    }, [[0, 0]]);
    const docWithPartial = setPartialCps(doc, [0, 0], [1]); // middle anchor
    const model = new Model(docWithPartial);
    const store = new StateStore();
    runEffects(
      [{ "doc.translate_selection": { dx: "5", dy: "5" } }],
      store.asContext(), store, { model },
    );
    const after = getElement(model.document, [0, 0]);
    // Anchor 1's destination shifts.
    assert.equal(after.d[1].x, 35);
    assert.equal(after.d[1].y, 5);
    // Anchor 1's in-handle (cmd[1].x2,y2) shifts with it.
    assert.equal(after.d[1].x2, 25);
    assert.equal(after.d[1].y2, -5);
    // Anchor 1's out-handle is on cmd[2] (next command's x1,y1) — shifts too.
    assert.equal(after.d[2].x1, 45);
    assert.equal(after.d[2].y1, 15);
    // Anchor 0's M unchanged.
    assert.equal(after.d[0].x, 0);
    // Anchor 2's destination unchanged (and its in-handle, cmd[2].x2,y2).
    assert.equal(after.d[2].x, 60);
    assert.equal(after.d[2].x2, 50);
  });
});

describe("doc.copy_selection", () => {
  it("duplicates each selected element offset by (dx, dy) and selects the copies", () => {
    const model = new Model(setSelection(makeDoc(), [[0, 0]]));
    const store = new StateStore();
    runEffects(
      [{ "doc.copy_selection": { dx: "10", dy: "5" } }],
      store.asContext(), store, { model },
    );
    const layer = model.document.layers[0];
    // Original (index 0) untouched; copy inserted at index 1.
    assert.equal(layer.children.length, 3);
    assert.equal(layer.children[0].x, 0);
    assert.equal(layer.children[0].y, 0);
    assert.equal(layer.children[1].x, 10);
    assert.equal(layer.children[1].y, 5);
    // Selection points at the copy.
    assert.deepEqual(model.document.selection, [[0, 1]]);
  });

  it("copies multiple selected elements in place; no index shift mishap", () => {
    const model = new Model(setSelection(makeDoc(), [[0, 0], [0, 1]]));
    const store = new StateStore();
    runEffects(
      [{ "doc.copy_selection": { dx: "1", dy: "1" } }],
      store.asContext(), store, { model },
    );
    const layer = model.document.layers[0];
    // Two originals + two copies.
    assert.equal(layer.children.length, 4);
    // Originals stay at their positions.
    assert.equal(layer.children[0].x, 0);
    assert.equal(layer.children[2].x, 50);
    // Copies are right after each original.
    assert.equal(layer.children[1].x, 1);
    assert.equal(layer.children[3].x, 51);
  });

  it("clears partial-CP entries on the new selection", async () => {
    const { setPartialCps, partialCpsForPath } =
      await import("../../static/js/engine/document.mjs");
    let doc = setSelection(makeDoc(), [[0, 0]]);
    doc = setPartialCps(doc, [0, 0], [0, 1]);
    const model = new Model(doc);
    const store = new StateStore();
    runEffects(
      [{ "doc.copy_selection": { dx: "5", dy: "5" } }],
      store.asContext(), store, { model },
    );
    assert.equal(partialCpsForPath(model.document, [0, 1]), null);
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

describe("groupSelection / ungroupSelection", () => {
  it("groups two siblings into a Group at the first selected position", async () => {
    const { groupSelection } = await import("../../static/js/engine/effects.mjs");
    const { setSelection } = await import("../../static/js/engine/document.mjs");
    const doc = setSelection({
      layers: [mkLayer({ children: [
        mkRect({ x: 0 }), mkCircle({ r: 5 }), mkRect({ x: 100 }),
      ] })],
      selection: [], artboards: [],
    }, [[0, 0], [0, 1]]);
    const next = groupSelection(doc);
    assert.equal(next.layers[0].children.length, 2);
    assert.equal(next.layers[0].children[0].type, "group");
    assert.equal(next.layers[0].children[0].children.length, 2);
    assert.equal(next.layers[0].children[0].children[0].type, "rect");
    assert.equal(next.layers[0].children[0].children[1].type, "circle");
    assert.equal(next.layers[0].children[1].type, "rect"); // the third rect
    assert.deepEqual(next.selection, [[0, 0]]);
  });

  it("groupSelection no-op when fewer than 2 selected", async () => {
    const { groupSelection } = await import("../../static/js/engine/effects.mjs");
    const { setSelection } = await import("../../static/js/engine/document.mjs");
    const doc = setSelection({
      layers: [mkLayer({ children: [mkRect(), mkCircle({ r: 5 })] })],
      selection: [], artboards: [],
    }, [[0, 0]]);
    assert.equal(groupSelection(doc), doc);
  });

  it("groupSelection no-op when selection paths aren't siblings", async () => {
    const { groupSelection } = await import("../../static/js/engine/effects.mjs");
    const { setSelection, mkGroup } = await import("../../static/js/engine/document.mjs");
    const doc = setSelection({
      layers: [mkLayer({ children: [
        mkGroup({ children: [mkRect()] }),
        mkRect({ x: 100 }),
      ] })],
      selection: [], artboards: [],
    }, [[0, 0, 0], [0, 1]]);
    // Different parent paths → not siblings.
    assert.equal(groupSelection(doc), doc);
  });

  it("ungroupSelection promotes children of a selected Group", async () => {
    const { ungroupSelection } = await import("../../static/js/engine/effects.mjs");
    const { setSelection, mkGroup } = await import("../../static/js/engine/document.mjs");
    const doc = setSelection({
      layers: [mkLayer({ children: [
        mkGroup({ children: [mkRect({ x: 1 }), mkRect({ x: 2 })] }),
        mkRect({ x: 3 }),
      ] })],
      selection: [], artboards: [],
    }, [[0, 0]]);
    const next = ungroupSelection(doc);
    // Layer is now [rect1, rect2, rect3] — group flattened in place.
    assert.equal(next.layers[0].children.length, 3);
    assert.equal(next.layers[0].children[0].type, "rect");
    assert.equal(next.layers[0].children[0].x, 1);
    assert.equal(next.layers[0].children[1].x, 2);
    assert.equal(next.layers[0].children[2].x, 3);
    // Selection becomes the promoted children.
    assert.deepEqual(next.selection, [[0, 0], [0, 1]]);
  });
});

describe("hit_test / hit_test_deep primitives", () => {
  beforeEach(_resetForTesting);

  it("hit_test stops at direct layer children (returns group path)", async () => {
    const { evaluate } = await import("../../static/js/engine/expr.mjs");
    const { Scope } = await import("../../static/js/engine/scope.mjs");
    const { mkGroup } = await import("../../static/js/engine/document.mjs");
    const model = new Model({
      layers: [mkLayer({ children: [
        mkGroup({ children: [mkRect({ x: 5, y: 5, width: 10, height: 10 })] }),
      ] })],
      selection: [], artboards: [],
    });
    const store = new StateStore();
    const ws = await workspaceDataPromise;
    registerTools(ws.tools, store);
    // Dispatch a click on the inner rect. Selection tool calls
    // hit_test, which should resolve to the GROUP path [0, 0],
    // not the inner rect at [0, 0, 0].
    dispatchEvent("selection",
      { type: "mousedown", x: 8, y: 8, modifiers: {} },
      store, { model });
    assert.deepEqual(model.selection[0], [0, 0]);
  });

  it("hit_test_deep recurses into groups (returns leaf path)", async () => {
    const { mkGroup } = await import("../../static/js/engine/document.mjs");
    const model = new Model({
      layers: [mkLayer({ children: [
        mkGroup({ children: [mkRect({ x: 5, y: 5, width: 10, height: 10 })] }),
      ] })],
      selection: [], artboards: [],
    });
    const store = new StateStore();
    const ws = await workspaceDataPromise;
    registerTools(ws.tools, store);
    // Interior Selection uses hit_test_deep; click on the inner
    // rect should resolve to the leaf path [0, 0, 0].
    dispatchEvent("interior_selection",
      { type: "mousedown", x: 8, y: 8, modifiers: {} },
      store, { model });
    assert.deepEqual(model.selection[0], [0, 0, 0]);
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
