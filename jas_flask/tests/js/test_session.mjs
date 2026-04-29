// Tests for engine/session.mjs — localStorage round-trip of the
// per-tab documents and engine state. Node has no localStorage, so we
// install a tiny shim onto globalThis.window before importing the
// module under test.

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";

class FakeLocalStorage {
  constructor() { this._data = new Map(); }
  getItem(k) { return this._data.has(k) ? this._data.get(k) : null; }
  setItem(k, v) { this._data.set(k, String(v)); }
  removeItem(k) { this._data.delete(k); }
  clear() { this._data.clear(); }
  key(i) { return Array.from(this._data.keys())[i] ?? null; }
  get length() { return this._data.size; }
}

globalThis.window = { localStorage: new FakeLocalStorage() };

const { saveSession, loadSession, clearSession, _SESSION_KEY } =
  await import("../../static/js/engine/session.mjs");
const { Model } = await import("../../static/js/engine/model.mjs");
const { emptyDocument, mkRect } =
  await import("../../static/js/engine/document.mjs");

function entry(canvasId, model) { return { canvas_id: canvasId, model }; }

describe("session.mjs", () => {
  beforeEach(() => globalThis.window.localStorage.clear());

  it("loadSession returns null when nothing has been saved", () => {
    assert.equal(loadSession(), null);
  });

  it("round-trips an empty single-tab workspace", () => {
    const m = new Model(emptyDocument(), "Untitled-1");
    saveSession([entry("canvas_surface_0", m)], { active_tab: 0, tab_count: 1 });
    const r = loadSession();
    assert.ok(r);
    assert.equal(r.documents.length, 1);
    assert.equal(r.documents[0].canvas_id, "canvas_surface_0");
    assert.equal(r.documents[0].filename, "Untitled-1");
    assert.deepEqual(r.documents[0].document, m.document);
    assert.equal(r.state.active_tab, 0);
    assert.equal(r.state.tab_count, 1);
  });

  it("persists multiple tabs and preserves order", () => {
    const m0 = new Model(emptyDocument(), "Cover");
    const doc1 = emptyDocument();
    doc1.layers[0].children = [
      mkRect({ x: 10, y: 20, width: 30, height: 40, fill: "#ff0000" }),
    ];
    const m1 = new Model(doc1, "Page");
    saveSession([
      entry("canvas_surface_0", m0),
      entry("canvas_surface_1", m1),
    ], { active_tab: 1, tab_count: 2 });
    const r = loadSession();
    assert.equal(r.documents.length, 2);
    assert.equal(r.documents[0].canvas_id, "canvas_surface_0");
    assert.equal(r.documents[1].canvas_id, "canvas_surface_1");
    assert.equal(r.documents[1].document.layers[0].children[0].fill, "#ff0000");
    assert.equal(r.state.active_tab, 1);
  });

  it("preserves the model generation per tab", () => {
    const m = new Model(emptyDocument());
    m.snapshot();
    m.mutate((d) => ({ ...d }));
    const before = m.generation;
    saveSession([entry("canvas_surface_0", m)], {});
    const r = loadSession();
    assert.equal(r.documents[0].generation, before);
  });

  it("clearSession removes the saved workspace", () => {
    saveSession([entry("c0", new Model(emptyDocument()))], {});
    assert.ok(loadSession());
    clearSession();
    assert.equal(loadSession(), null);
  });

  it("malformed JSON returns null", () => {
    globalThis.window.localStorage.setItem(_SESSION_KEY, "{not valid json");
    assert.equal(loadSession(), null);
  });

  it("V1 (single-document) payload is dropped on load", () => {
    // V1 used `{version:1, document}`; V2 uses `{version:2, documents}`.
    // We don't migrate — V1 is from an older Flask without a tab system.
    globalThis.window.localStorage.setItem(_SESSION_KEY, JSON.stringify({
      version: 1, document: emptyDocument(),
    }));
    assert.equal(loadSession(), null);
  });

  it("payload missing documents array returns empty list", () => {
    globalThis.window.localStorage.setItem(_SESSION_KEY, JSON.stringify({
      version: 2, state: { active_tab: 0 },
    }));
    const r = loadSession();
    assert.ok(r);
    assert.equal(r.documents.length, 0);
  });

  it("documents with bad shape are filtered out", () => {
    globalThis.window.localStorage.setItem(_SESSION_KEY, JSON.stringify({
      version: 2,
      documents: [
        { canvas_id: "ok", document: { layers: [] } },
        { canvas_id: "bad" }, // missing document
        { document: "string-not-object" },
      ],
      state: {},
    }));
    const r = loadSession();
    assert.equal(r.documents.length, 1);
    assert.equal(r.documents[0].canvas_id, "ok");
  });

  it("saveSession is a no-op without window.localStorage", () => {
    const ws = globalThis.window;
    globalThis.window = {};
    assert.doesNotThrow(() => saveSession([
      entry("c0", new Model(emptyDocument())),
    ], {}));
    globalThis.window = ws;
  });
});
