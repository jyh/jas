// Tests for engine/session.mjs — localStorage round-trip of the
// document. Node has no localStorage, so we install a tiny shim
// onto globalThis.window before importing the module under test.

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

describe("session.mjs", () => {
  beforeEach(() => globalThis.window.localStorage.clear());

  it("loadSession returns null when nothing has been saved", () => {
    assert.equal(loadSession(), null);
  });

  it("saveSession + loadSession round-trips an empty document", () => {
    const model = new Model(emptyDocument(), "Untitled-1");
    saveSession(model);
    const r = loadSession();
    assert.ok(r);
    assert.equal(r.filename, "Untitled-1");
    assert.deepEqual(r.document, model.document);
  });

  it("saveSession persists a doc with elements", () => {
    const doc = emptyDocument();
    doc.layers[0].children = [
      mkRect({ x: 10, y: 20, width: 30, height: 40, fill: "#ff0000" }),
      mkRect({ x: 50, y: 60, width: 70, height: 80 }),
    ];
    const model = new Model(doc, "Test.svg");
    saveSession(model);
    const r = loadSession();
    assert.equal(r.document.layers[0].children.length, 2);
    assert.equal(r.document.layers[0].children[0].fill, "#ff0000");
    assert.equal(r.document.layers[0].children[1].x, 50);
  });

  it("clearSession removes the saved document", () => {
    const model = new Model(emptyDocument());
    saveSession(model);
    assert.ok(loadSession());
    clearSession();
    assert.equal(loadSession(), null);
  });

  it("loadSession with a malformed payload returns null", () => {
    globalThis.window.localStorage.setItem(_SESSION_KEY, "{not valid json");
    assert.equal(loadSession(), null);
  });

  it("loadSession with a future version returns null and warns", () => {
    globalThis.window.localStorage.setItem(_SESSION_KEY, JSON.stringify({
      version: 99, document: emptyDocument(),
    }));
    assert.equal(loadSession(), null);
  });

  it("loadSession with missing layers returns null", () => {
    globalThis.window.localStorage.setItem(_SESSION_KEY, JSON.stringify({
      version: 1, document: { not_layers: [] },
    }));
    assert.equal(loadSession(), null);
  });

  it("saveSession is a no-op without window.localStorage", () => {
    const ws = globalThis.window;
    globalThis.window = {};
    assert.doesNotThrow(() => saveSession(new Model(emptyDocument())));
    globalThis.window = ws;
  });

  it("generation is preserved across save / load", () => {
    const model = new Model(emptyDocument());
    model.snapshot();
    model.mutate((d) => ({ ...d }));
    const before = model.generation;
    saveSession(model);
    const r = loadSession();
    assert.equal(r.generation, before);
  });
});
