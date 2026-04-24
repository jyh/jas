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

describe("data.* mutation effects", () => {
  function dataStore(seed = {}) {
    return new StateStore({ data: seed });
  }

  it("data.set writes a leaf value", () => {
    const store = dataStore({ brush_libraries: { lib1: { brushes: [] } } });
    runEffects(
      [{ "data.set": { path: "brush_libraries.lib1.name", value: '"Lib 1"' } }],
      store.asContext(), store,
    );
    assert.equal(store.data.brush_libraries.lib1.name, "Lib 1");
  });

  it("data.set with explicit data. prefix works the same", () => {
    const store = dataStore({ x: { y: 1 } });
    runEffects(
      [{ "data.set": { path: "data.x.y", value: "42" } }],
      store.asContext(), store,
    );
    assert.equal(store.data.x.y, 42);
  });

  it("data.list_append adds to a list at the path (raw object value)", () => {
    const store = dataStore({
      brush_libraries: {
        lib1: { brushes: [{ slug: "a" }] },
      },
    });
    runEffects(
      [{
        "data.list_append": {
          path: "brush_libraries.lib1.brushes",
          value: { slug: "b", type: "calligraphic" },
        },
      }],
      store.asContext(), store,
    );
    const brushes = store.data.brush_libraries.lib1.brushes;
    assert.equal(brushes.length, 2);
    assert.equal(brushes[1].slug, "b");
  });

  it("data.list_remove drops an item by index", () => {
    const store = dataStore({
      brush_libraries: {
        lib1: { brushes: [{ slug: "a" }, { slug: "b" }, { slug: "c" }] },
      },
    });
    runEffects(
      [{ "data.list_remove": { path: "brush_libraries.lib1.brushes", index: "1" } }],
      store.asContext(), store,
    );
    const slugs = store.data.brush_libraries.lib1.brushes.map((b) => b.slug);
    assert.deepEqual(slugs, ["a", "c"]);
  });

  it("data.list_remove out-of-range is a no-op", () => {
    const store = dataStore({
      brush_libraries: { lib1: { brushes: [{ slug: "a" }] } },
    });
    const before = store.data.brush_libraries.lib1.brushes.length;
    runEffects(
      [{ "data.list_remove": { path: "brush_libraries.lib1.brushes", index: "99" } }],
      store.asContext(), store,
    );
    assert.equal(store.data.brush_libraries.lib1.brushes.length, before);
  });

  it("data.list_insert inserts at the given index (raw object value)", () => {
    const store = dataStore({
      brush_libraries: {
        lib1: { brushes: [{ slug: "a" }, { slug: "c" }] },
      },
    });
    runEffects(
      [{
        "data.list_insert": {
          path: "brush_libraries.lib1.brushes",
          index: "1",
          value: { slug: "b" },
        },
      }],
      store.asContext(), store,
    );
    const slugs = store.data.brush_libraries.lib1.brushes.map((b) => b.slug);
    assert.deepEqual(slugs, ["a", "b", "c"]);
  });

  it("data.list_sort orders by a key expression", () => {
    const store = dataStore({
      brush_libraries: {
        lib1: { brushes: [{ name: "C" }, { name: "A" }, { name: "B" }] },
      },
    });
    runEffects(
      [{
        "data.list_sort": {
          path: "brush_libraries.lib1.brushes",
          key: "item.name",
        },
      }],
      store.asContext(), store,
    );
    const names = store.data.brush_libraries.lib1.brushes.map((b) => b.name);
    assert.deepEqual(names, ["A", "B", "C"]);
  });
});

describe("brush.* library shortcuts", () => {
  function brushStore() {
    const lib = {
      name: "Test Library",
      brushes: [
        { slug: "a", name: "Alpha", type: "calligraphic" },
        { slug: "b", name: "Beta",  type: "calligraphic" },
        { slug: "c", name: "Gamma", type: "calligraphic" },
      ],
    };
    return new StateStore({
      data: { brush_libraries: { lib1: lib } },
      panel: { brushes: { selected_library: "lib1", selected_brushes: [] } },
    });
  }

  it("brush.delete_selected removes the matching brushes", () => {
    const store = brushStore();
    store.panel.brushes.selected_brushes = ["b"];
    // The spec passes library/slugs as expression strings; the
    // handler evaluates them against scope. For tests we hand it
    // explicit literal expressions so the test does not depend on
    // active-panel binding.
    runEffects(
      [{
        "brush.delete_selected": {
          library: '"lib1"',
          slugs: '["b"]',
        },
      }],
      store.asContext(), store,
    );
    const slugs = store.data.brush_libraries.lib1.brushes.map((b) => b.slug);
    assert.deepEqual(slugs, ["a", "c"]);
    // Selection cleared after delete.
    assert.deepEqual(store.panel.brushes.selected_brushes, []);
  });

  it("brush.delete_selected handles multiple slugs", () => {
    const store = brushStore();
    runEffects(
      [{
        "brush.delete_selected": {
          library: '"lib1"',
          slugs: '["a", "c"]',
        },
      }],
      store.asContext(), store,
    );
    const slugs = store.data.brush_libraries.lib1.brushes.map((b) => b.slug);
    assert.deepEqual(slugs, ["b"]);
  });

  it("brush.duplicate_selected makes copies with fresh slugs", () => {
    const store = brushStore();
    runEffects(
      [{
        "brush.duplicate_selected": {
          library: '"lib1"',
          slugs: '["b"]',
        },
      }],
      store.asContext(), store,
    );
    const brushes = store.data.brush_libraries.lib1.brushes;
    assert.equal(brushes.length, 4);
    // Copy is inserted immediately after the original.
    const slugs = brushes.map((b) => b.slug);
    assert.deepEqual(slugs, ["a", "b", "b_copy", "c"]);
    // Name has " copy" appended.
    const copy = brushes.find((b) => b.slug === "b_copy");
    assert.equal(copy.name, "Beta copy");
    // Selection now points at the new copies.
    assert.deepEqual(store.panel.brushes.selected_brushes, ["b_copy"]);
  });

  it("brush.duplicate_selected generates unique slugs on collisions", () => {
    const store = brushStore();
    // Pre-existing copy of `a` should force the new copy to use _copy_2.
    store.data.brush_libraries.lib1.brushes.push(
      { slug: "a_copy", name: "Alpha copy", type: "calligraphic" },
    );
    runEffects(
      [{
        "brush.duplicate_selected": {
          library: '"lib1"',
          slugs: '["a"]',
        },
      }],
      store.asContext(), store,
    );
    const slugs = store.data.brush_libraries.lib1.brushes.map((b) => b.slug);
    assert.ok(slugs.includes("a_copy_2"), `expected a_copy_2 in ${slugs}`);
  });

  it("brush.append adds a new brush to the named library", () => {
    const store = brushStore();
    runEffects(
      [{
        "brush.append": {
          library: '"lib1"',
          brush: { slug: "d", name: "Delta", type: "calligraphic" },
        },
      }],
      store.asContext(), store,
    );
    const slugs = store.data.brush_libraries.lib1.brushes.map((b) => b.slug);
    assert.deepEqual(slugs, ["a", "b", "c", "d"]);
  });

  it("brush.update patches an existing master brush in place", () => {
    const store = brushStore();
    runEffects(
      [{
        "brush.update": {
          library: '"lib1"',
          slug: '"b"',
          patch: { name: "Beta v2", size: 8 },
        },
      }],
      store.asContext(), store,
    );
    const b = store.data.brush_libraries.lib1.brushes.find((x) => x.slug === "b");
    assert.equal(b.name, "Beta v2");
    assert.equal(b.size, 8);
    // Untouched fields preserved.
    assert.equal(b.type, "calligraphic");
  });

  it("data.list_sort orders brushes alphabetically by name", () => {
    const store = brushStore();
    // Shuffle the names so the default order is non-alpha.
    store.data.brush_libraries.lib1.brushes = [
      { slug: "z", name: "Zebra" },
      { slug: "a", name: "Apple" },
      { slug: "m", name: "Mango" },
    ];
    runEffects(
      [{
        "data.list_sort": {
          path: "data.brush_libraries.lib1.brushes",
          key: "item.name",
        },
      }],
      store.asContext(), store,
    );
    const names = store.data.brush_libraries.lib1.brushes.map((b) => b.name);
    assert.deepEqual(names, ["Apple", "Mango", "Zebra"]);
  });
});

describe("buffer.* and doc.add_path_from_buffer", () => {
  it("buffer.push then doc.add_path_from_buffer creates a Path on layer 0", async () => {
    // Import point_buffers module to clear state between tests.
    const pointBuffers = await import("../../static/js/engine/point_buffers.mjs");
    pointBuffers.clear("test_buf");

    const model = new Model();
    const store = new StateStore();
    runEffects(
      [
        { "buffer.clear": { buffer: "test_buf" } },
        { "buffer.push": { buffer: "test_buf", x: "0", y: "0" } },
        { "buffer.push": { buffer: "test_buf", x: "5", y: "0" } },
        { "buffer.push": { buffer: "test_buf", x: "10", y: "0" } },
        { "doc.add_path_from_buffer": { buffer: "test_buf", fit_error: "1" } },
      ],
      store.asContext(),
      store,
      { model },
    );

    const layer = model.document.layers[0];
    assert.equal(layer.children.length, 1);
    const elem = layer.children[0];
    assert.equal(elem.type, "path");
    // First command is MoveTo to (0, 0) — the buffer's first point.
    assert.equal(elem.d[0].type, "M");
    assert.equal(elem.d[0].x, 0);
    assert.equal(elem.d[0].y, 0);
    // Subsequent commands are CurveTos.
    for (let i = 1; i < elem.d.length; i++) {
      assert.equal(elem.d[i].type, "C");
    }
  });

  it("doc.add_path_from_buffer with stroke_brush passes through", async () => {
    const pointBuffers = await import("../../static/js/engine/point_buffers.mjs");
    pointBuffers.clear("test_buf");

    const model = new Model();
    const store = new StateStore();
    // Seed state.stroke_brush so the YAML-style passthrough works.
    store.set("state.stroke_brush", "default_brushes/oval_5pt");

    runEffects(
      [
        { "buffer.clear": { buffer: "test_buf" } },
        { "buffer.push": { buffer: "test_buf", x: "0", y: "0" } },
        { "buffer.push": { buffer: "test_buf", x: "10", y: "10" } },
        {
          "doc.add_path_from_buffer": {
            buffer: "test_buf",
            stroke_brush: "state.stroke_brush",
          },
        },
      ],
      store.asContext(),
      store,
      { model },
    );

    const elem = model.document.layers[0].children[0];
    assert.equal(elem.stroke_brush, "default_brushes/oval_5pt");
  });

  it("doc.add_path_from_buffer with empty buffer is a no-op", async () => {
    const pointBuffers = await import("../../static/js/engine/point_buffers.mjs");
    pointBuffers.clear("empty_buf");

    const model = new Model();
    const store = new StateStore();
    runEffects(
      [{ "doc.add_path_from_buffer": { buffer: "empty_buf" } }],
      store.asContext(),
      store,
      { model },
    );

    assert.equal(model.document.layers[0].children.length, 0);
  });

  it("buffer.clear empties the buffer", async () => {
    const pointBuffers = await import("../../static/js/engine/point_buffers.mjs");
    pointBuffers.push("clr_buf", 1, 2);
    pointBuffers.push("clr_buf", 3, 4);
    assert.equal(pointBuffers.length("clr_buf"), 2);

    const store = new StateStore();
    runEffects(
      [{ "buffer.clear": { buffer: "clr_buf" } }],
      store.asContext(),
      store,
    );
    assert.equal(pointBuffers.length("clr_buf"), 0);
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
