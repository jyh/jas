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

  it("applies state.fill_color / stroke_color defaults to a shape", () => {
    // Drawing tools (rect.yaml etc.) intentionally omit fill / stroke
    // from add_element so the engine fills in the active panel
    // colors. Without this, every shape would render with the SVG
    // default black fill regardless of what the user picked.
    const model = new Model(emptyDocument());
    const store = new StateStore({
      state: { fill_color: "#ffffff", stroke_color: "#000000", stroke_width: 1 },
    });
    runEffects(
      [{
        "doc.add_element": {
          parent: "[0]",
          element: {
            type: "rect", x: "10", y: "20", width: "30", height: "40",
          },
        },
      }],
      store.asContext(), store, { model },
    );
    const rect = model.document.layers[0].children[0];
    assert.equal(rect.fill, "#ffffff");
    assert.equal(rect.stroke, "#000000");
    assert.equal(rect["stroke-width"], 1);
  });

  it("explicit fill/stroke in the spec override the state defaults", () => {
    const model = new Model(emptyDocument());
    const store = new StateStore({
      state: { fill_color: "#ffffff", stroke_color: "#000000" },
    });
    runEffects(
      [{
        "doc.add_element": {
          parent: "[0]",
          element: {
            type: "rect", x: "0", y: "0", width: "1", height: "1",
            fill: "'#ff0000'",
          },
        },
      }],
      store.asContext(), store, { model },
    );
    const rect = model.document.layers[0].children[0];
    assert.equal(rect.fill, "#ff0000");
    // Stroke wasn't specified, so the state default still applies.
    assert.equal(rect.stroke, "#000000");
  });

  it("does not apply shape defaults to non-shape types", () => {
    // Layers / groups don't have fill/stroke; the defaults must not
    // pollute their fields.
    const model = new Model(emptyDocument());
    const store = new StateStore({
      state: { fill_color: "#ffffff", stroke_color: "#000000" },
    });
    runEffects(
      [{
        "doc.add_element": {
          parent: "[0]",
          element: { type: "group" },
        },
      }],
      store.asContext(), store, { model },
    );
    const g = model.document.layers[0].children[0];
    assert.equal(g.type, "group");
    assert.equal(g.fill, undefined);
    assert.equal(g.stroke, undefined);
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

describe("doc.path.probe_partial_hit", () => {
  function makeDoc() {
    return {
      layers: [mkLayer({ children: [
        { type: "rect", x: 10, y: 10, width: 100, height: 80,
          visibility: "preview", locked: false, opacity: 1 },
      ] })],
      selection: [],
      artboards: [],
    };
  }

  it("clicking a CP without shift replaces the partial selection with that CP", async () => {
    const { partialCpsForPath } = await import("../../static/js/engine/document.mjs");
    const model = new Model(makeDoc());
    const store = new StateStore({ tool: { partial_selection: { mode: "idle" } } });
    runEffects(
      [{ "doc.path.probe_partial_hit": {
        x: "10", y: "10", radius: "6", shift: "false",
      } }],
      store.asContext(), store, { model },
    );
    // CP 0 (TL corner) is at (10, 10) — exact hit.
    assert.deepEqual(model.document.selection, [[0, 0]]);
    assert.deepEqual(partialCpsForPath(model.document, [0, 0]), [0]);
    assert.equal(store.get("tool.partial_selection.mode"), "moving_pending");
  });

  it("shift-clicking a CP toggles it in the partial set", async () => {
    const { partialCpsForPath, setSelection, setPartialCps } =
      await import("../../static/js/engine/document.mjs");
    let doc = makeDoc();
    doc = setSelection(doc, [[0, 0]]);
    doc = setPartialCps(doc, [0, 0], [0]); // TL already partial
    const model = new Model(doc);
    const store = new StateStore({ tool: { partial_selection: { mode: "idle" } } });
    // Shift-click on TR (110, 10).
    runEffects(
      [{ "doc.path.probe_partial_hit": {
        x: "110", y: "10", radius: "6", shift: "true",
      } }],
      store.asContext(), store, { model },
    );
    assert.deepEqual(partialCpsForPath(model.document, [0, 0]), [0, 1]);
  });

  it("clicking empty space sets mode to marquee", () => {
    const model = new Model(makeDoc());
    const store = new StateStore({ tool: { partial_selection: { mode: "idle" } } });
    runEffects(
      [{ "doc.path.probe_partial_hit": {
        x: "500", y: "500", radius: "6", shift: "false",
      } }],
      store.asContext(), store, { model },
    );
    assert.equal(store.get("tool.partial_selection.mode"), "marquee");
    // No selection change.
    assert.equal(model.document.selection.length, 0);
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

  it("mousedown enters drawing mode; mouseup commits the rect", async () => {
    // rect.yaml authors the tool as: mousedown → set drawing/start
    // coords (no element created yet); mousemove → update cur coords;
    // mouseup → if drag size > 1px, snapshot + add_element. The yaml
    // matches RectTool semantics in jas_dioxus / JasSwift / jas_ocaml /
    // jas — commit on release, not press.
    const ws = await workspaceDataPromise;
    const model = new Model(emptyDocument());
    const store = new StateStore();
    registerTools(ws.tools, store);
    const noMods = { shift: false, ctrl: false, alt: false, meta: false };

    dispatchEvent("rect", { type: "mousedown", x: 10, y: 20, modifiers: noMods },
                  store, { model });
    assert.equal(store.get("tool.rect.mode"), "drawing");
    // No element appended on mousedown — rect is committed on release.
    assert.equal(model.document.layers[0].children.length, 0);

    dispatchEvent("rect", { type: "mousemove", x: 80, y: 100, modifiers: noMods },
                  store, { model });
    // mousemove only updates tool-local cur coords. Still no element.
    assert.equal(model.document.layers[0].children.length, 0);
    assert.equal(store.get("tool.rect.cur_x"), 80);
    assert.equal(store.get("tool.rect.cur_y"), 100);

    dispatchEvent("rect", { type: "mouseup", x: 80, y: 100, modifiers: noMods },
                  store, { model });
    assert.equal(store.get("tool.rect.mode"), "idle");
    // Rect lands at (10, 20) with size 70x80.
    assert.equal(model.document.layers[0].children.length, 1);
    const rect = getElement(model.document, [0, 0]);
    assert.equal(rect.type, "rect");
    assert.equal(rect.x, 10);
    assert.equal(rect.y, 20);
    assert.equal(rect.width, 70);
    assert.equal(rect.height, 80);
  });

  it("drag from bottom-right to top-left produces rect with clamped origin", async () => {
    const ws = await workspaceDataPromise;
    const model = new Model(emptyDocument());
    const store = new StateStore();
    registerTools(ws.tools, store);
    const noMods = { shift: false, ctrl: false, alt: false, meta: false };

    dispatchEvent("rect", { type: "mousedown", x: 100, y: 100, modifiers: noMods },
                  store, { model });
    dispatchEvent("rect", { type: "mousemove", x: 30, y: 20, modifiers: noMods },
                  store, { model });
    dispatchEvent("rect", { type: "mouseup", x: 30, y: 20, modifiers: noMods },
                  store, { model });

    const rect = getElement(model.document, [0, 0]);
    assert.ok(rect, "rect should be committed on mouseup");
    assert.equal(rect.x, 30);
    assert.equal(rect.y, 20);
    assert.equal(rect.width, 70);
    assert.equal(rect.height, 80);
  });

  it("zero-size click (mousedown==mouseup) is suppressed — no rect committed", async () => {
    // The yaml's `abs(event.x - tool.rect.start_x) > 1 and abs(event.y -
    // tool.rect.start_y) > 1` guard prevents a stray click from
    // creating a degenerate rect. Matches native RectTool behavior.
    const ws = await workspaceDataPromise;
    const model = new Model(emptyDocument());
    const store = new StateStore();
    registerTools(ws.tools, store);
    const noMods = { shift: false, ctrl: false, alt: false, meta: false };

    dispatchEvent("rect", { type: "mousedown", x: 10, y: 10, modifiers: noMods },
                  store, { model });
    dispatchEvent("rect", { type: "mouseup", x: 10, y: 10, modifiers: noMods },
                  store, { model });
    assert.equal(model.document.layers[0].children.length, 0);
    assert.equal(store.get("tool.rect.mode"), "idle");
  });

  it("undo after rect drag removes the rect", async () => {
    const ws = await workspaceDataPromise;
    const model = new Model(emptyDocument());
    const store = new StateStore();
    registerTools(ws.tools, store);
    const noMods = { shift: false, ctrl: false, alt: false, meta: false };

    dispatchEvent("rect", { type: "mousedown", x: 10, y: 10, modifiers: noMods },
                  store, { model });
    dispatchEvent("rect", { type: "mousemove", x: 50, y: 60, modifiers: noMods },
                  store, { model });
    dispatchEvent("rect", { type: "mouseup", x: 50, y: 60, modifiers: noMods },
                  store, { model });

    assert.equal(model.document.layers[0].children.length, 1);
    model.undo();
    assert.equal(model.document.layers[0].children.length, 0);
  });
});
