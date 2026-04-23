// Tests for doc.* effects routed through a live Model.

import { describe, it } from "node:test";
import assert from "node:assert/strict";

import { StateStore } from "../../static/js/engine/store.mjs";
import { runEffects } from "../../static/js/engine/effects.mjs";
import { Model } from "../../static/js/engine/model.mjs";
import {
  emptyDocument, mkLayer, mkRect, mkCircle,
  setSelection,
} from "../../static/js/engine/document.mjs";

function makeModelWithElements() {
  const doc = {
    layers: [mkLayer({
      name: "L1",
      children: [mkRect({ x: 0, y: 0, width: 10, height: 10 }), mkCircle({ r: 5 })],
    })],
    selection: [],
    artboards: [],
  };
  return new Model(doc);
}

describe("doc.snapshot via runEffects", () => {
  it("pushes onto undo stack", () => {
    const model = new Model();
    const store = new StateStore();
    runEffects([{ "doc.snapshot": {} }], store.asContext(), store, { model });
    assert.ok(model.canUndo);
  });
});

describe("doc.clear_selection", () => {
  it("clears selection", () => {
    const model = makeModelWithElements();
    model.setDocument(setSelection(model.document, [[0, 0]]));
    assert.equal(model.selection.length, 1);

    const store = new StateStore();
    runEffects([{ "doc.clear_selection": {} }], store.asContext(), store, { model });
    assert.equal(model.selection.length, 0);
  });
});

describe("doc.set_selection", () => {
  it("sets selection from paths list", () => {
    const model = makeModelWithElements();
    const store = new StateStore();
    // Use dict-spec form — the selection tool YAML writes it this way:
    //   doc.set_selection: { paths: [hit] }
    // But with a let/in binding hit to a Path value. Here we inline the
    // paths using list literal tricks — fixture simulates the bound
    // result directly via scope.
    const scope = store.asContext();
    scope._hit = { __path__: [0, 0] };  // seed as if from hit_test
    // Simpler shape — pass raw paths array
    runEffects(
      [{ "doc.set_selection": { paths: [[0, 0], [0, 1]] } }],
      scope,
      store,
      { model },
    );
    assert.equal(model.selection.length, 2);
    assert.deepEqual(model.selection[0], [0, 0]);
    assert.deepEqual(model.selection[1], [0, 1]);
  });

  it("drops invalid paths", () => {
    const model = makeModelWithElements();
    const store = new StateStore();
    runEffects(
      [{ "doc.set_selection": { paths: [[0, 0], [99, 99]] } }],
      store.asContext(),
      store,
      { model },
    );
    assert.equal(model.selection.length, 1);
    assert.deepEqual(model.selection[0], [0, 0]);
  });
});

describe("doc.add_to_selection", () => {
  it("adds path to selection", () => {
    const model = makeModelWithElements();
    const store = new StateStore();
    runEffects(
      [{ "doc.add_to_selection": [0, 0] }],
      store.asContext(),
      store,
      { model },
    );
    assert.equal(model.selection.length, 1);
  });

  it("no-op on duplicate", () => {
    const model = makeModelWithElements();
    model.setDocument(setSelection(model.document, [[0, 0]]));
    const store = new StateStore();
    runEffects(
      [{ "doc.add_to_selection": [0, 0] }],
      store.asContext(),
      store,
      { model },
    );
    assert.equal(model.selection.length, 1);
  });
});

describe("doc.toggle_selection", () => {
  it("adds if absent", () => {
    const model = makeModelWithElements();
    const store = new StateStore();
    runEffects(
      [{ "doc.toggle_selection": [0, 0] }],
      store.asContext(),
      store,
      { model },
    );
    assert.equal(model.selection.length, 1);
  });

  it("removes if present", () => {
    const model = makeModelWithElements();
    model.setDocument(setSelection(model.document, [[0, 0]]));
    const store = new StateStore();
    runEffects(
      [{ "doc.toggle_selection": [0, 0] }],
      store.asContext(),
      store,
      { model },
    );
    assert.equal(model.selection.length, 0);
  });
});

describe("doc.set_attr_on_selection", () => {
  it("sets attribute on every selected element", () => {
    const model = makeModelWithElements();
    model.setDocument(setSelection(model.document, [[0, 0], [0, 1]]));
    const store = new StateStore();
    runEffects(
      [{
        "doc.set_attr_on_selection": {
          attr: "stroke_brush",
          value: '"default_brushes/oval_5pt"',
        },
      }],
      store.asContext(),
      store,
      { model },
    );
    const children = model.document.layers[0].children;
    assert.equal(children[0].stroke_brush, "default_brushes/oval_5pt");
    assert.equal(children[1].stroke_brush, "default_brushes/oval_5pt");
  });

  it("leaves unselected elements untouched", () => {
    const model = makeModelWithElements();
    // Only the rect is selected.
    model.setDocument(setSelection(model.document, [[0, 0]]));
    const store = new StateStore();
    runEffects(
      [{
        "doc.set_attr_on_selection": {
          attr: "stroke_brush",
          value: '"default_brushes/oval_5pt"',
        },
      }],
      store.asContext(),
      store,
      { model },
    );
    const children = model.document.layers[0].children;
    assert.equal(children[0].stroke_brush, "default_brushes/oval_5pt");
    assert.equal(children[1].stroke_brush, undefined);
  });

  it("empty selection is a no-op", () => {
    const model = makeModelWithElements();
    const before = model.document;
    const store = new StateStore();
    runEffects(
      [{
        "doc.set_attr_on_selection": {
          attr: "stroke_brush",
          value: '"x/y"',
        },
      }],
      store.asContext(),
      store,
      { model },
    );
    // Document unchanged (deep equal).
    assert.deepEqual(model.document, before);
  });

  it("null value clears the attribute", () => {
    const model = makeModelWithElements();
    // Pre-set an attribute on the rect.
    const layer0 = model.document.layers[0];
    const r = { ...layer0.children[0], stroke_brush: "foo/bar" };
    const newLayer = { ...layer0, children: [r, layer0.children[1]] };
    model.setDocument({ ...model.document, layers: [newLayer] });
    model.setDocument(setSelection(model.document, [[0, 0]]));

    const store = new StateStore();
    runEffects(
      [{
        "doc.set_attr_on_selection": { attr: "stroke_brush", value: "null" },
      }],
      store.asContext(),
      store,
      { model },
    );
    assert.equal(model.document.layers[0].children[0].stroke_brush, null);
  });
});

describe("without model — onDocEffect observer", () => {
  it("fires for unrecognized doc.* effects", () => {
    const store = new StateStore();
    const seen = [];
    runEffects(
      [
        { "doc.translate_selection": { dx: "5", dy: "0" } },
        { "doc.rotate": { angle: "90" } },
      ],
      store.asContext(),
      store,
      { onDocEffect: (name) => seen.push(name) },
    );
    assert.deepEqual(seen, ["doc.translate_selection", "doc.rotate"]);
  });

  it("doc.snapshot without model falls through to observer", () => {
    const store = new StateStore();
    const seen = [];
    runEffects(
      [{ "doc.snapshot": {} }],
      store.asContext(),
      store,
      { onDocEffect: (name) => seen.push(name) },
    );
    assert.deepEqual(seen, ["doc.snapshot"]);
  });
});

describe("selection tool with real model — end-to-end", () => {
  it("shift-marquee drag then mouseup clears mode", async () => {
    const { readFile } = await import("node:fs/promises");
    const { fileURLToPath } = await import("node:url");
    const { dirname, resolve } = await import("node:path");
    const __dirname = dirname(fileURLToPath(import.meta.url));
    const ws = JSON.parse(await readFile(
      resolve(__dirname, "../../../workspace/workspace.json"), "utf-8"));

    const { registerTools, dispatchEvent, _resetForTesting } =
      await import("../../static/js/engine/tools.mjs");
    _resetForTesting();

    const model = makeModelWithElements();
    const store = new StateStore();
    registerTools(ws.tools, store);

    // mousedown on empty space → start marquee. hit_test is not
    // implemented yet; it returns null (unknown primitive) which
    // triggers the "empty space" branch.
    dispatchEvent("selection", {
      type: "mousedown",
      x: 200, y: 200,
      modifiers: { shift: false, ctrl: false, alt: false, meta: false },
    }, store, { model });
    assert.equal(store.get("tool.selection.mode"), "marquee");

    // mousemove updates marquee end.
    dispatchEvent("selection", {
      type: "mousemove",
      x: 300, y: 300,
      modifiers: { shift: false, ctrl: false, alt: false, meta: false },
    }, store, { model });
    assert.equal(store.get("tool.selection.marquee_end_x"), 300);

    // mouseup returns to idle (doc.select_in_rect is still a placeholder).
    dispatchEvent("selection", {
      type: "mouseup",
      x: 300, y: 300,
      modifiers: { shift: false, ctrl: false, alt: false, meta: false },
    }, store, { model, onDocEffect: () => {} });
    assert.equal(store.get("tool.selection.mode"), "idle");
  });
});
