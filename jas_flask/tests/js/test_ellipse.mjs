// Integration tests for the ellipse tool. The yaml mirrors rect.yaml's
// press-drag-release pattern: mousedown enters drawing, mousemove
// updates screen-space cur coords (driving the overlay preview),
// mouseup commits an ellipse fitted into the start→end bounding box,
// or suppresses commit if the drag is < 1px in either dimension.

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

import { StateStore } from "../../static/js/engine/store.mjs";
import { Model } from "../../static/js/engine/model.mjs";
import { registerTools, dispatchEvent, _resetForTesting } from "../../static/js/engine/tools.mjs";
import { emptyDocument, getElement } from "../../static/js/engine/document.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const WORKSPACE_JSON = resolve(__dirname, "../../../workspace/workspace.json");
const workspaceDataPromise = readFile(WORKSPACE_JSON, "utf-8").then(JSON.parse);

const noMods = { shift: false, ctrl: false, alt: false, meta: false };

describe("ellipse tool — workspace registration", () => {
  it("ellipse spec is present in compiled workspace", async () => {
    const ws = await workspaceDataPromise;
    assert.ok(ws.tools.ellipse, "ellipse tool should be in compiled workspace");
    assert.equal(ws.tools.ellipse.id, "ellipse");
    assert.equal(ws.tools.ellipse.shortcut, "L");
  });
});

describe("ellipse tool — end-to-end element creation", () => {
  beforeEach(_resetForTesting);

  it("mousedown enters drawing mode; mouseup commits the ellipse", async () => {
    const ws = await workspaceDataPromise;
    const model = new Model(emptyDocument());
    const store = new StateStore();
    registerTools(ws.tools, store);

    dispatchEvent("ellipse", { type: "mousedown", x: 10, y: 20, modifiers: noMods },
                  store, { model });
    assert.equal(store.get("tool.ellipse.mode"), "drawing");
    // No element appended on mousedown — ellipse is committed on release.
    assert.equal(model.document.layers[0].children.length, 0);

    dispatchEvent("ellipse", { type: "mousemove", x: 80, y: 100, modifiers: noMods },
                  store, { model });
    // mousemove only updates tool-local cur coords. Still no element.
    assert.equal(model.document.layers[0].children.length, 0);
    assert.equal(store.get("tool.ellipse.cur_x"), 80);
    assert.equal(store.get("tool.ellipse.cur_y"), 100);

    dispatchEvent("ellipse", { type: "mouseup", x: 80, y: 100, modifiers: noMods },
                  store, { model });
    assert.equal(store.get("tool.ellipse.mode"), "idle");
    // Bounding box (10,20)→(80,100) is 70 wide × 80 tall.
    // Ellipse fits the box: cx=45, cy=60, rx=35, ry=40.
    assert.equal(model.document.layers[0].children.length, 1);
    const e = getElement(model.document, [0, 0]);
    assert.equal(e.type, "ellipse");
    assert.equal(e.cx, 45);
    assert.equal(e.cy, 60);
    assert.equal(e.rx, 35);
    assert.equal(e.ry, 40);
  });

  it("drag from bottom-right to top-left produces ellipse with positive rx/ry", async () => {
    const ws = await workspaceDataPromise;
    const model = new Model(emptyDocument());
    const store = new StateStore();
    registerTools(ws.tools, store);

    dispatchEvent("ellipse", { type: "mousedown", x: 100, y: 100, modifiers: noMods },
                  store, { model });
    dispatchEvent("ellipse", { type: "mousemove", x: 30, y: 20, modifiers: noMods },
                  store, { model });
    dispatchEvent("ellipse", { type: "mouseup", x: 30, y: 20, modifiers: noMods },
                  store, { model });

    const e = getElement(model.document, [0, 0]);
    assert.ok(e, "ellipse should be committed on mouseup");
    // Bounding box (30,20)→(100,100) is 70×80; cx=65, cy=60.
    assert.equal(e.cx, 65);
    assert.equal(e.cy, 60);
    assert.equal(e.rx, 35);
    assert.equal(e.ry, 40);
  });

  it("zero-size click (mousedown==mouseup) is suppressed — no ellipse committed", async () => {
    const ws = await workspaceDataPromise;
    const model = new Model(emptyDocument());
    const store = new StateStore();
    registerTools(ws.tools, store);

    dispatchEvent("ellipse", { type: "mousedown", x: 10, y: 10, modifiers: noMods },
                  store, { model });
    dispatchEvent("ellipse", { type: "mouseup", x: 10, y: 10, modifiers: noMods },
                  store, { model });
    assert.equal(model.document.layers[0].children.length, 0);
    assert.equal(store.get("tool.ellipse.mode"), "idle");
  });

  it("undo after ellipse drag removes the ellipse", async () => {
    const ws = await workspaceDataPromise;
    const model = new Model(emptyDocument());
    const store = new StateStore();
    registerTools(ws.tools, store);

    dispatchEvent("ellipse", { type: "mousedown", x: 10, y: 10, modifiers: noMods },
                  store, { model });
    dispatchEvent("ellipse", { type: "mousemove", x: 50, y: 60, modifiers: noMods },
                  store, { model });
    dispatchEvent("ellipse", { type: "mouseup", x: 50, y: 60, modifiers: noMods },
                  store, { model });

    assert.equal(model.document.layers[0].children.length, 1);
    model.undo();
    assert.equal(model.document.layers[0].children.length, 0);
  });

  it("Escape during a drag returns mode to idle without committing", async () => {
    const ws = await workspaceDataPromise;
    const model = new Model(emptyDocument());
    const store = new StateStore();
    registerTools(ws.tools, store);

    dispatchEvent("ellipse", { type: "mousedown", x: 10, y: 10, modifiers: noMods },
                  store, { model });
    dispatchEvent("ellipse", { type: "mousemove", x: 50, y: 60, modifiers: noMods },
                  store, { model });
    assert.equal(store.get("tool.ellipse.mode"), "drawing");

    dispatchEvent("ellipse", { type: "keydown", key: "Escape", modifiers: noMods },
                  store, { model });
    assert.equal(store.get("tool.ellipse.mode"), "idle");
    assert.equal(model.document.layers[0].children.length, 0);
  });
});
