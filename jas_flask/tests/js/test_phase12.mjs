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

describe("doc.path.commit_partial_marquee", () => {
  function makeDoc() {
    return {
      layers: [mkLayer({ children: [
        // Rect from (0,0) to (100,80). CPs: TL(0,0), TR(100,0),
        // BR(100,80), BL(0,80).
        { type: "rect", x: 0, y: 0, width: 100, height: 80,
          visibility: "preview", locked: false, opacity: 1 },
      ] })],
      selection: [],
      artboards: [],
    };
  }

  it("CPs inside the rect become partial-selected; element joins selection", async () => {
    const { partialCpsForPath } = await import("../../static/js/engine/document.mjs");
    const model = new Model(makeDoc());
    const store = new StateStore();
    // Marquee that covers the top edge: TL (0,0) and TR (100,0).
    runEffects(
      [{ "doc.path.commit_partial_marquee": {
        x1: "-5", y1: "-5", x2: "105", y2: "5", additive: "false",
      } }],
      store.asContext(), store, { model },
    );
    assert.deepEqual(model.document.selection, [[0, 0]]);
    assert.deepEqual(partialCpsForPath(model.document, [0, 0]), [0, 1]);
  });

  it("non-additive replaces an existing partial set", async () => {
    const { partialCpsForPath, setSelection, setPartialCps } =
      await import("../../static/js/engine/document.mjs");
    let doc = makeDoc();
    doc = setSelection(doc, [[0, 0]]);
    doc = setPartialCps(doc, [0, 0], [3]); // BL pre-selected
    const model = new Model(doc);
    const store = new StateStore();
    runEffects(
      [{ "doc.path.commit_partial_marquee": {
        x1: "-5", y1: "-5", x2: "5", y2: "5", additive: "false",
      } }],
      store.asContext(), store, { model },
    );
    // Marquee covers only TL → replaces [3] with [0].
    assert.deepEqual(partialCpsForPath(model.document, [0, 0]), [0]);
  });

  it("additive merges into the existing partial set", async () => {
    const { partialCpsForPath, setSelection, setPartialCps } =
      await import("../../static/js/engine/document.mjs");
    let doc = makeDoc();
    doc = setSelection(doc, [[0, 0]]);
    doc = setPartialCps(doc, [0, 0], [3]); // BL pre-selected
    const model = new Model(doc);
    const store = new StateStore();
    runEffects(
      [{ "doc.path.commit_partial_marquee": {
        x1: "-5", y1: "-5", x2: "5", y2: "5", additive: "true",
      } }],
      store.asContext(), store, { model },
    );
    assert.deepEqual(partialCpsForPath(model.document, [0, 0]), [0, 3]);
  });

  it("empty marquee with non-additive clears the selection", async () => {
    const { partialCpsForPath, setSelection } =
      await import("../../static/js/engine/document.mjs");
    let doc = makeDoc();
    doc = setSelection(doc, [[0, 0]]);
    const model = new Model(doc);
    const store = new StateStore();
    runEffects(
      [{ "doc.path.commit_partial_marquee": {
        x1: "200", y1: "200", x2: "300", y2: "300", additive: "false",
      } }],
      store.asContext(), store, { model },
    );
    assert.equal(model.document.selection.length, 0);
  });
});

describe("Pen tool effects", () => {
  it("anchor.push appends a corner anchor", async () => {
    const ab = await import("../../static/js/engine/anchor_buffers.mjs");
    ab.clear("test_pen_push");
    const store = new StateStore();
    runEffects(
      [{ "anchor.push": { buffer: "test_pen_push", x: "10", y: "20" } }],
      store.asContext(), store, {},
    );
    assert.equal(ab.length("test_pen_push"), 1);
    ab.clear("test_pen_push");
  });

  it("anchor.set_last_out flips smooth and mirrors in-handle", async () => {
    const ab = await import("../../static/js/engine/anchor_buffers.mjs");
    ab.clear("test_pen_smooth");
    const store = new StateStore();
    runEffects(
      [
        { "anchor.push": { buffer: "test_pen_smooth", x: "50", y: "50" } },
        { "anchor.set_last_out": { buffer: "test_pen_smooth", hx: "60", hy: "50" } },
      ],
      store.asContext(), store, {},
    );
    const [a] = ab.anchors("test_pen_smooth");
    assert.equal(a.hout_x, 60);
    assert.equal(a.hin_x, 40);
    assert.equal(a.smooth, true);
    ab.clear("test_pen_smooth");
  });

  it("anchor_buffer_length / anchor_buffer_close_hit primitives evaluate in YAML guards", async () => {
    const ab = await import("../../static/js/engine/anchor_buffers.mjs");
    const { evaluate } = await import("../../static/js/engine/expr.mjs");
    const { Scope } = await import("../../static/js/engine/scope.mjs");
    const { toBool, toJson } = await import("../../static/js/engine/value.mjs");
    ab.clear("test_pen_p");
    ab.push("test_pen_p", 100, 100);
    ab.push("test_pen_p", 200, 200);
    const scope = new Scope({});
    assert.equal(
      toJson(evaluate("anchor_buffer_length('test_pen_p')", scope)), 2);
    assert.equal(
      toBool(evaluate("anchor_buffer_close_hit('test_pen_p', 102, 102, 8)", scope)),
      true);
    assert.equal(
      toBool(evaluate("anchor_buffer_close_hit('test_pen_p', 200, 200, 8)", scope)),
      false); // last anchor isn't first
    ab.clear("test_pen_p");
  });

  it("doc.add_path_from_anchor_buffer appends a Path with CurveTos", async () => {
    const ab = await import("../../static/js/engine/anchor_buffers.mjs");
    ab.clear("test_pen_add");
    ab.push("test_pen_add", 0, 0);
    ab.push("test_pen_add", 50, 50);
    ab.push("test_pen_add", 100, 0);
    const model = new Model(emptyDocument());
    const store = new StateStore();
    runEffects(
      [{ "doc.add_path_from_anchor_buffer": {
        buffer: "test_pen_add", closed: "false",
      } }],
      store.asContext(), store, { model },
    );
    const elem = model.document.layers[0].children[0];
    assert.equal(elem.type, "path");
    // 1 MoveTo + 2 CurveTos.
    assert.equal(elem.d.length, 3);
    assert.equal(elem.d[0].type, "M");
    assert.equal(elem.d[1].type, "C");
    assert.equal(elem.d[2].type, "C");
    // Last command lands at the third anchor (100, 0).
    assert.equal(elem.d[2].x, 100);
    assert.equal(elem.d[2].y, 0);
    // Open paths default fill=null so they don't trap a filled hairline.
    assert.equal(elem.fill, null);
    ab.clear("test_pen_add");
  });

  it("doc.add_path_from_anchor_buffer with closed=true emits CurveTo + Z", async () => {
    const ab = await import("../../static/js/engine/anchor_buffers.mjs");
    ab.clear("test_pen_closed");
    ab.push("test_pen_closed", 0, 0);
    ab.push("test_pen_closed", 100, 0);
    ab.push("test_pen_closed", 50, 80);
    const model = new Model(emptyDocument());
    const store = new StateStore();
    runEffects(
      [{ "doc.add_path_from_anchor_buffer": {
        buffer: "test_pen_closed", closed: "true",
      } }],
      store.asContext(), store, { model },
    );
    const elem = model.document.layers[0].children[0];
    // M + 2 CurveTos + closing CurveTo + Z = 5 commands.
    assert.equal(elem.d.length, 5);
    assert.equal(elem.d[4].type, "Z");
    ab.clear("test_pen_closed");
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
