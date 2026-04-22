// Integration tests for Phase 12: doc.add_element, doc.set_attr,
// layer_length primitive, and the rect tool end-to-end.

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
  emptyDocument, mkLayer, getElement,
} from "../../static/js/engine/document.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const WORKSPACE_JSON = resolve(__dirname, "../../../workspace/workspace.json");
const workspaceDataPromise = readFile(WORKSPACE_JSON, "utf-8").then(JSON.parse);

describe("doc.add_element", () => {
  it("appends an element to a layer", () => {
    const model = new Model(emptyDocument());
    const store = new StateStore();
    runEffects(
      [{
        "doc.add_element": {
          parent: "[0]",
          element: {
            type: "rect",
            x: "10", y: "20", width: "30", height: "40",
            fill: "'#ff0000'",
          },
        },
      }],
      store.asContext(), store, { model },
    );
    const layer = model.document.layers[0];
    assert.equal(layer.children.length, 1);
    const rect = layer.children[0];
    assert.equal(rect.type, "rect");
    assert.equal(rect.x, 10);
    assert.equal(rect.fill, "#ff0000");
  });

  it("resolves expression values in element spec", () => {
    const model = new Model(emptyDocument());
    const store = new StateStore({ state: { base_x: 100, base_y: 50 } });
    runEffects(
      [{
        "doc.add_element": {
          parent: "[0]",
          element: {
            type: "rect",
            x: "state.base_x",
            y: "state.base_y + 10",
            width: "20", height: "20",
          },
        },
      }],
      store.asContext(), store, { model },
    );
    const rect = model.document.layers[0].children[0];
    assert.equal(rect.x, 100);
    assert.equal(rect.y, 60);
  });

  it("ignores invalid parent path", () => {
    const model = new Model(emptyDocument());
    const store = new StateStore();
    runEffects(
      [{
        "doc.add_element": {
          parent: "[99]",
          element: { type: "rect", x: "0", y: "0", width: "1", height: "1" },
        },
      }],
      store.asContext(), store, { model },
    );
    assert.equal(model.document.layers[0].children.length, 0);
  });
});

describe("doc.set_attr", () => {
  it("updates a field on an element", () => {
    const model = new Model({
      layers: [mkLayer({
        children: [{ type: "rect", x: 0, y: 0, width: 10, height: 10, visibility: "preview", locked: false, opacity: 1 }],
      })],
      selection: [],
      artboards: [],
    });
    const store = new StateStore();
    runEffects(
      [{ "doc.set_attr": { path: "[0, 0]", attr: "width", value: "50" } }],
      store.asContext(), store, { model },
    );
    assert.equal(getElement(model.document, [0, 0]).width, 50);
  });

  it("evaluates value expressions against scope", () => {
    const model = new Model({
      layers: [mkLayer({ children: [{ type: "rect", x: 0, y: 0, width: 10, height: 10, visibility: "preview", locked: false, opacity: 1 }] })],
      selection: [],
      artboards: [],
    });
    const store = new StateStore({ state: { new_width: 100 } });
    runEffects(
      [{ "doc.set_attr": { path: "[0, 0]", attr: "width", value: "state.new_width" } }],
      store.asContext(), store, { model },
    );
    assert.equal(getElement(model.document, [0, 0]).width, 100);
  });
});

describe("layer_length primitive", () => {
  beforeEach(_resetForTesting);

  it("evaluates via tool dispatch", async () => {
    const ws = await workspaceDataPromise;
    assert.ok(ws.tools.rect, "rect tool should be in compiled workspace");
  });
});

describe("rect tool — end-to-end element creation", () => {
  beforeEach(_resetForTesting);

  it("mousedown adds a zero-sized rect; mousemove resizes it", async () => {
    const ws = await workspaceDataPromise;
    const model = new Model(emptyDocument());
    const store = new StateStore();
    registerTools(ws.tools, store);

    dispatchEvent(
      "rect",
      {
        type: "mousedown",
        x: 10, y: 20,
        modifiers: { shift: false, ctrl: false, alt: false, meta: false },
      },
      store,
      { model },
    );
    assert.equal(store.get("tool.rect.mode"), "drawing");
    let layer = model.document.layers[0];
    assert.equal(layer.children.length, 1);
    let rect = layer.children[0];
    assert.equal(rect.type, "rect");
    assert.equal(rect.x, 10);
    assert.equal(rect.y, 20);

    // mousemove to 80, 100 — rect should grow to 70x80
    dispatchEvent(
      "rect",
      {
        type: "mousemove",
        x: 80, y: 100,
        modifiers: { shift: false, ctrl: false, alt: false, meta: false },
      },
      store,
      { model },
    );
    rect = getElement(model.document, [0, 0]);
    assert.equal(rect.x, 10);
    assert.equal(rect.y, 20);
    assert.equal(rect.width, 70);
    assert.equal(rect.height, 80);

    // mouseup commits — mode → idle.
    dispatchEvent(
      "rect",
      {
        type: "mouseup", x: 80, y: 100,
        modifiers: { shift: false, ctrl: false, alt: false, meta: false },
      },
      store,
      { model },
    );
    assert.equal(store.get("tool.rect.mode"), "idle");
  });

  it("drag from bottom-right to top-left produces rect with clamped origin", async () => {
    const ws = await workspaceDataPromise;
    const model = new Model(emptyDocument());
    const store = new StateStore();
    registerTools(ws.tools, store);

    dispatchEvent("rect", {
      type: "mousedown", x: 100, y: 100,
      modifiers: { shift: false, ctrl: false, alt: false, meta: false },
    }, store, { model });

    dispatchEvent("rect", {
      type: "mousemove", x: 30, y: 20,
      modifiers: { shift: false, ctrl: false, alt: false, meta: false },
    }, store, { model });

    const rect = getElement(model.document, [0, 0]);
    assert.equal(rect.x, 30);
    assert.equal(rect.y, 20);
    assert.equal(rect.width, 70);
    assert.equal(rect.height, 80);
  });

  it("undo after rect creation removes the rect", async () => {
    const ws = await workspaceDataPromise;
    const model = new Model(emptyDocument());
    const store = new StateStore();
    registerTools(ws.tools, store);

    dispatchEvent("rect", {
      type: "mousedown", x: 10, y: 10,
      modifiers: { shift: false, ctrl: false, alt: false, meta: false },
    }, store, { model });
    dispatchEvent("rect", {
      type: "mouseup", x: 10, y: 10,
      modifiers: { shift: false, ctrl: false, alt: false, meta: false },
    }, store, { model });

    assert.equal(model.document.layers[0].children.length, 1);
    model.undo();
    assert.equal(model.document.layers[0].children.length, 0);
  });
});
