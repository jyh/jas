// Tests for the JS Document data model + mutations + Model wrapper.

import { describe, it } from "node:test";
import assert from "node:assert/strict";

import {
  mkRect, mkCircle, mkEllipse, mkLine, mkPath, mkText, mkGroup, mkLayer,
  isContainer, emptyDocument, getElement, cloneDocument,
  docToJson, docFromJson,
  setSelection, addToSelection, toggleSelection, clearSelection,
  partialCpsForPath, setPartialCps, togglePartialCp,
} from "../../static/js/engine/document.mjs";

import { Model } from "../../static/js/engine/model.mjs";

describe("element constructors", () => {
  it("mkRect sets type + geometry + defaults", () => {
    const r = mkRect({ x: 10, y: 20, width: 30, height: 40 });
    assert.equal(r.type, "rect");
    assert.equal(r.x, 10);
    assert.equal(r.width, 30);
    assert.equal(r.visibility, "preview");
    assert.equal(r.locked, false);
  });

  it("mkLayer sets name + empty children", () => {
    const l = mkLayer({ name: "L1" });
    assert.equal(l.type, "layer");
    assert.equal(l.name, "L1");
    assert.deepEqual(l.children, []);
  });

  it("mkGroup sets children", () => {
    const g = mkGroup({ children: [mkRect(), mkCircle({ r: 5 })] });
    assert.equal(g.children.length, 2);
    assert.equal(g.children[1].type, "circle");
  });

  it("each element carries common defaults", () => {
    for (const fn of [mkRect, mkCircle, mkEllipse, mkLine, mkPath, mkText]) {
      const e = fn();
      assert.equal(e.visibility, "preview");
      assert.equal(e.locked, false);
      assert.equal(e.opacity, 1.0);
    }
  });

  it("common defaults can be overridden", () => {
    const r = mkRect({ visibility: "invisible", locked: true });
    assert.equal(r.visibility, "invisible");
    assert.equal(r.locked, true);
  });
});

describe("isContainer", () => {
  it("group and layer are containers", () => {
    assert.ok(isContainer(mkGroup()));
    assert.ok(isContainer(mkLayer()));
  });
  it("leaf elements are not containers", () => {
    for (const fn of [mkRect, mkCircle, mkEllipse, mkLine, mkPath, mkText]) {
      assert.ok(!isContainer(fn()));
    }
  });
  it("null / undefined safe", () => {
    assert.ok(!isContainer(null));
    assert.ok(!isContainer(undefined));
  });
});

describe("Document / getElement", () => {
  it("emptyDocument has one layer", () => {
    const d = emptyDocument();
    assert.equal(d.layers.length, 1);
    assert.equal(d.selection.length, 0);
  });

  it("emptyDocument seeds one Letter-sized white artboard", () => {
    // Cross-app contract: every observable document has at least one
    // artboard (jas_dioxus/src/document/artboard.rs §invariant). Flask
    // overrides the Rust struct's transparent default with white so a
    // freshly created document shows a visible "page" against the dark
    // pasteboard (see actions.yaml::new_document and the bootstrap).
    const d = emptyDocument();
    assert.equal(d.artboards.length, 1);
    const ab = d.artboards[0];
    assert.equal(ab.name, "Artboard 1");
    assert.equal(ab.x, 0);
    assert.equal(ab.y, 0);
    assert.equal(ab.width, 612);
    assert.equal(ab.height, 792);
    assert.equal(ab.fill, "#ffffff");
    assert.equal(typeof ab.id, "string");
    assert.equal(ab.id.length, 8);
    assert.equal(ab.show_center_mark, false);
    assert.equal(ab.show_cross_hairs, false);
    assert.equal(ab.show_video_safe_areas, false);
    assert.equal(ab.video_ruler_pixel_aspect_ratio, 1.0);
  });

  it("emptyDocument has artboard_options with fade on by default", () => {
    const d = emptyDocument();
    assert.equal(d.artboard_options.fade_region_outside_artboard, true);
    assert.equal(d.artboard_options.update_while_dragging, true);
  });

  it("emptyDocument generates a fresh artboard id each call", () => {
    const a = emptyDocument();
    const b = emptyDocument();
    assert.notEqual(a.artboards[0].id, b.artboards[0].id);
  });

  it("getElement walks single-level path", () => {
    const d = emptyDocument();
    const l = getElement(d, [0]);
    assert.equal(l.type, "layer");
  });

  it("getElement walks nested path", () => {
    const d = {
      layers: [mkLayer({
        children: [mkRect(), mkGroup({ children: [mkCircle({ r: 3 })] })],
      })],
      selection: [], artboards: [],
    };
    assert.equal(getElement(d, [0]).type, "layer");
    assert.equal(getElement(d, [0, 0]).type, "rect");
    assert.equal(getElement(d, [0, 1, 0]).type, "circle");
    assert.equal(getElement(d, [0, 1, 0]).r, 3);
  });

  it("getElement returns null on invalid path", () => {
    const d = emptyDocument();
    assert.equal(getElement(d, [99]), null);
    assert.equal(getElement(d, [0, 99]), null);
    assert.equal(getElement(d, []), null);
  });

  it("getElement rejects path through leaf", () => {
    const d = {
      layers: [mkLayer({ children: [mkRect()] })],
      selection: [], artboards: [],
    };
    assert.equal(getElement(d, [0, 0, 0]), null);
  });
});

describe("cloneDocument / JSON round-trip", () => {
  it("clone is independent", () => {
    const d1 = emptyDocument();
    const d2 = cloneDocument(d1);
    d2.layers[0].name = "Modified";
    assert.equal(d1.layers[0].name, "Layer 1");
  });

  it("JSON round-trip preserves structure", () => {
    const d = {
      layers: [mkLayer({ name: "Layer 1", children: [mkRect({ x: 5 })] })],
      selection: [[0, 0]],
      artboards: [],
    };
    const j = docToJson(d);
    const d2 = docFromJson(j);
    assert.deepEqual(d, d2);
  });

  it("brush attributes round-trip through clone and JSON", () => {
    // Document model is structurally open: stroke_brush /
    // stroke_brush_overrides ride along on path elements without any
    // explicit field declaration in mkPath. Verify they survive both
    // cloneDocument and JSON round-trip.
    const p = mkPath({
      d: [{ type: "M", x: 0, y: 0 }, { type: "L", x: 10, y: 10 }],
      stroke_brush: "default_brushes/oval_5pt",
      stroke_brush_overrides: '{"size": 8}',
    });
    assert.equal(p.stroke_brush, "default_brushes/oval_5pt");
    assert.equal(p.stroke_brush_overrides, '{"size": 8}');

    const d = {
      layers: [mkLayer({ children: [p] })],
      selection: [], artboards: [],
    };
    const cloned = cloneDocument(d);
    assert.equal(cloned.layers[0].children[0].stroke_brush,
                 "default_brushes/oval_5pt");
    assert.equal(cloned.layers[0].children[0].stroke_brush_overrides,
                 '{"size": 8}');

    const round = docFromJson(docToJson(d));
    assert.deepEqual(round, d);
  });
});

describe("selection mutations", () => {
  const makeDoc = () => ({
    layers: [mkLayer({ children: [mkRect(), mkCircle({ r: 5 })] })],
    selection: [],
    artboards: [],
  });

  it("setSelection filters invalid paths", () => {
    const d = setSelection(makeDoc(), [[0, 0], [0, 99], [99]]);
    assert.equal(d.selection.length, 1);
    assert.deepEqual(d.selection[0], [0, 0]);
  });

  it("addToSelection adds unique path", () => {
    let d = makeDoc();
    d = addToSelection(d, [0, 0]);
    d = addToSelection(d, [0, 1]);
    d = addToSelection(d, [0, 0]); // duplicate
    assert.equal(d.selection.length, 2);
  });

  it("toggleSelection adds if absent, removes if present", () => {
    let d = makeDoc();
    d = toggleSelection(d, [0, 0]);
    assert.equal(d.selection.length, 1);
    d = toggleSelection(d, [0, 0]);
    assert.equal(d.selection.length, 0);
  });

  it("clearSelection empties", () => {
    let d = setSelection(makeDoc(), [[0, 0], [0, 1]]);
    d = clearSelection(d);
    assert.equal(d.selection.length, 0);
  });

  it("partialCpsForPath returns null when no partial entry exists", () => {
    // No partial entry → SelectionKind::All semantics. Caller treats
    // null as "every CP is selected".
    const d = setSelection(makeDoc(), [[0, 0]]);
    assert.equal(partialCpsForPath(d, [0, 0]), null);
  });

  it("setPartialCps stores indices for a path; partialCpsForPath reads them", () => {
    let d = setSelection(makeDoc(), [[0, 0]]);
    d = setPartialCps(d, [0, 0], [0, 2]);
    assert.deepEqual(partialCpsForPath(d, [0, 0]), [0, 2]);
  });

  it("setPartialCps with empty array clears the partial entry", () => {
    let d = setSelection(makeDoc(), [[0, 0]]);
    d = setPartialCps(d, [0, 0], [1]);
    d = setPartialCps(d, [0, 0], []);
    assert.equal(partialCpsForPath(d, [0, 0]), null);
  });

  it("togglePartialCp adds an absent index", () => {
    let d = setSelection(makeDoc(), [[0, 0]]);
    d = togglePartialCp(d, [0, 0], 2);
    assert.deepEqual(partialCpsForPath(d, [0, 0]), [2]);
  });

  it("togglePartialCp removes a present index", () => {
    let d = setSelection(makeDoc(), [[0, 0]]);
    d = setPartialCps(d, [0, 0], [0, 2]);
    d = togglePartialCp(d, [0, 0], 0);
    assert.deepEqual(partialCpsForPath(d, [0, 0]), [2]);
  });

  it("togglePartialCp leaves indices sorted ascending", () => {
    let d = setSelection(makeDoc(), [[0, 0]]);
    d = togglePartialCp(d, [0, 0], 3);
    d = togglePartialCp(d, [0, 0], 1);
    d = togglePartialCp(d, [0, 0], 2);
    assert.deepEqual(partialCpsForPath(d, [0, 0]), [1, 2, 3]);
  });

  it("clearSelection drops partial entries too", () => {
    let d = setSelection(makeDoc(), [[0, 0]]);
    d = setPartialCps(d, [0, 0], [1]);
    d = clearSelection(d);
    assert.equal(partialCpsForPath(d, [0, 0]), null);
  });

  it("setSelection drops partial entries for paths no longer selected", () => {
    let d = setSelection(makeDoc(), [[0, 0], [0, 1]]);
    d = setPartialCps(d, [0, 1], [0]);
    d = setSelection(d, [[0, 0]]);
    assert.equal(partialCpsForPath(d, [0, 1]), null);
  });

  it("mutations don't alter input", () => {
    const d0 = makeDoc();
    const d1 = addToSelection(d0, [0, 0]);
    assert.equal(d0.selection.length, 0);
    assert.equal(d1.selection.length, 1);
  });
});

describe("Model", () => {
  it("fresh model is unmodified with empty stacks", () => {
    const m = new Model();
    assert.ok(!m.isModified);
    assert.ok(!m.canUndo);
    assert.ok(!m.canRedo);
    assert.equal(m.generation, 0);
  });

  it("setDocument bumps generation and marks modified", () => {
    const m = new Model();
    m.setDocument(emptyDocument());
    assert.equal(m.generation, 1);
    assert.ok(m.isModified);
  });

  it("markSaved clears modified flag", () => {
    const m = new Model();
    m.setDocument(emptyDocument());
    m.markSaved();
    assert.ok(!m.isModified);
  });

  it("undo after snapshot restores prior state", () => {
    const m = new Model();
    m.snapshot();
    m.mutate((d) => addToSelection(d, [0]));
    assert.equal(m.selection.length, 1);
    m.undo();
    assert.equal(m.selection.length, 0);
  });

  it("redo after undo restores the change", () => {
    const m = new Model();
    m.snapshot();
    m.mutate((d) => addToSelection(d, [0]));
    m.undo();
    m.redo();
    assert.equal(m.selection.length, 1);
  });

  it("new mutation after undo clears redo stack", () => {
    const m = new Model();
    m.snapshot();
    m.mutate((d) => addToSelection(d, [0]));
    m.undo();
    assert.ok(m.canRedo);
    m.snapshot();
    m.mutate((d) => addToSelection(d, [0]));
    assert.ok(!m.canRedo);
  });

  it("undo stack capped at MAX_UNDO=100", () => {
    const m = new Model();
    for (let i = 0; i < 150; i++) {
      m.snapshot();
      m.mutate((d) => ({ ...d, _counter: i }));
    }
    assert.ok(m.canUndo);
    // Drain the stack; should not exceed 100
    let pops = 0;
    while (m.canUndo) { m.undo(); pops++; }
    assert.equal(pops, 100);
  });

  it("listener fires on every change", () => {
    const m = new Model();
    let count = 0;
    const unsubscribe = m.addListener(() => count++);
    m.setDocument(emptyDocument());
    m.mutate((d) => d);
    m.undo(); // undo stack empty, doesn't fire
    assert.equal(count, 2);
    unsubscribe();
    m.setDocument(emptyDocument());
    assert.equal(count, 2); // unsubscribed
  });

  it("isModified matches generation-counter semantics", () => {
    // Matches the post-saved_document cleanup behavior: is_modified
    // compares generation counters, so undo back to the saved state
    // still reads as modified (the user moved *through* the saved
    // state; they may want to redo).
    const m = new Model();
    m.snapshot();
    m.mutate((d) => d);
    m.markSaved();
    assert.ok(!m.isModified);
    m.undo();
    assert.ok(m.isModified); // because generation != savedGeneration
  });
});
