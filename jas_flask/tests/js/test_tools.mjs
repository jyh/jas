// Tests for the tool registry + event dispatcher.

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

import { StateStore } from "../../static/js/engine/store.mjs";
import {
  registerTools, getTool, getAllTools, dispatchEvent,
  activateTool, deactivateTool, _resetForTesting,
} from "../../static/js/engine/tools.mjs";

// Load the compiled workspace.json so the integration test can exercise
// the real selection tool YAML.
const __dirname = dirname(fileURLToPath(import.meta.url));
const WORKSPACE_JSON = resolve(__dirname, "../../../workspace/workspace.json");
const workspaceDataPromise = readFile(WORKSPACE_JSON, "utf-8").then(JSON.parse);

describe("registerTools", () => {
  beforeEach(_resetForTesting);

  it("registers tools by id", () => {
    registerTools(
      {
        t1: { id: "t1", handlers: {} },
        t2: { id: "t2", handlers: {} },
      },
      new StateStore(),
    );
    assert.ok(getTool("t1"));
    assert.ok(getTool("t2"));
    assert.equal(getTool("missing"), null);
  });

  it("seeds tool-local state from default declarations", () => {
    const store = new StateStore();
    registerTools(
      {
        pen: {
          id: "pen",
          handlers: {},
          state: {
            mode: { default: "idle" },
            anchor_count: { default: 0 },
          },
        },
      },
      store,
    );
    assert.equal(store.get("tool.pen.mode"), "idle");
    assert.equal(store.get("tool.pen.anchor_count"), 0);
  });

  it("does not clobber pre-existing tool state", () => {
    const store = new StateStore({ tool: { pen: { mode: "drawing" } } });
    registerTools(
      { pen: { id: "pen", handlers: {}, state: { mode: { default: "idle" } } } },
      store,
    );
    assert.equal(store.get("tool.pen.mode"), "drawing");
  });

  it("handles empty / missing tools gracefully", () => {
    registerTools(null, new StateStore());
    registerTools({}, new StateStore());
    registerTools(undefined, new StateStore());
    // No throw.
  });

  it("getAllTools returns a copy", () => {
    registerTools({ a: { id: "a", handlers: {} } }, new StateStore());
    const m = getAllTools();
    m.clear();
    assert.ok(getTool("a")); // internal registry untouched
  });
});

describe("dispatchEvent — basic", () => {
  beforeEach(_resetForTesting);

  it("runs matching handler", () => {
    const store = new StateStore();
    registerTools(
      {
        t: {
          id: "t",
          handlers: {
            on_mousedown: [{ set: "state.clicked", value: "true" }],
          },
        },
      },
      store,
    );
    dispatchEvent("t", { type: "mousedown", x: 10, y: 20 }, store);
    assert.equal(store.get("state.clicked"), true);
  });

  it("no-op for unknown tool", () => {
    dispatchEvent("nonexistent", { type: "mousedown" }, new StateStore());
    // Just doesn't throw.
  });

  it("no-op for unmatched event type", () => {
    const store = new StateStore();
    registerTools(
      { t: { id: "t", handlers: { on_mousedown: [] } } },
      store,
    );
    dispatchEvent("t", { type: "keyup" }, store);
    // No handler for keyup; doesn't throw.
  });

  it("handler reads $event", () => {
    const store = new StateStore();
    registerTools(
      {
        t: {
          id: "t",
          handlers: {
            on_mousedown: [{ set: "state.last_x", value: "event.x" }],
          },
        },
      },
      store,
    );
    dispatchEvent("t", { type: "mousedown", x: 42, y: 99 }, store);
    assert.equal(store.get("state.last_x"), 42);
  });

  it("handler reads $tool.<id>.*", () => {
    const store = new StateStore();
    registerTools(
      {
        pen: {
          id: "pen",
          state: { mode: { default: "idle" } },
          handlers: {
            on_mousedown: [
              {
                if: "tool.pen.mode == 'idle'",
                then: [{ set: "tool.pen.mode", value: "'drawing'" }],
              },
            ],
          },
        },
      },
      store,
    );
    dispatchEvent("pen", { type: "mousedown" }, store);
    assert.equal(store.get("tool.pen.mode"), "drawing");
  });
});

describe("activateTool / deactivateTool", () => {
  beforeEach(_resetForTesting);

  it("activateTool fires on_enter", () => {
    const store = new StateStore();
    registerTools(
      {
        t: {
          id: "t",
          handlers: { on_enter: [{ set: "state.entered", value: "true" }] },
        },
      },
      store,
    );
    activateTool("t", store);
    assert.equal(store.get("state.entered"), true);
  });

  it("deactivateTool fires on_leave", () => {
    const store = new StateStore();
    registerTools(
      {
        t: {
          id: "t",
          handlers: { on_leave: [{ set: "state.left", value: "true" }] },
        },
      },
      store,
    );
    deactivateTool("t", store);
    assert.equal(store.get("state.left"), true);
  });
});

describe("integration — real selection tool from workspace.json", () => {
  beforeEach(_resetForTesting);

  it("loads selection tool from compiled workspace", async () => {
    const ws = await workspaceDataPromise;
    const store = new StateStore();
    registerTools(ws.tools, store);
    assert.ok(getTool("selection"));
    assert.equal(store.get("tool.selection.mode"), "idle");
    assert.equal(store.get("tool.selection.marquee_start_x"), 0);
  });

  it("on_enter resets mode to idle", async () => {
    const ws = await workspaceDataPromise;
    const store = new StateStore();
    registerTools(ws.tools, store);
    store.set("tool.selection.mode", "drag_move");
    activateTool("selection", store);
    assert.equal(store.get("tool.selection.mode"), "idle");
  });

  it("on_mousemove in marquee mode updates end coords", async () => {
    const ws = await workspaceDataPromise;
    const store = new StateStore();
    registerTools(ws.tools, store);
    // Put tool in marquee mode manually.
    store.set("tool.selection.mode", "marquee");
    store.set("tool.selection.marquee_start_x", 0);
    store.set("tool.selection.marquee_start_y", 0);
    dispatchEvent("selection", {
      type: "mousemove",
      x: 150,
      y: 80,
      modifiers: { shift: false, ctrl: false, alt: false, meta: false },
    }, store);
    assert.equal(store.get("tool.selection.marquee_end_x"), 150);
    assert.equal(store.get("tool.selection.marquee_end_y"), 80);
  });

  it("on_keydown Escape resets mode to idle", async () => {
    const ws = await workspaceDataPromise;
    const store = new StateStore();
    registerTools(ws.tools, store);
    store.set("tool.selection.mode", "marquee");
    dispatchEvent("selection", {
      type: "keydown",
      key: "Escape",
    }, store);
    assert.equal(store.get("tool.selection.mode"), "idle");
  });

  it("on_mouseup from marquee returns to idle", async () => {
    const ws = await workspaceDataPromise;
    const store = new StateStore();
    const docEffects = [];
    registerTools(ws.tools, store);
    store.set("tool.selection.mode", "marquee");
    store.set("tool.selection.marquee_start_x", 10);
    store.set("tool.selection.marquee_start_y", 20);
    store.set("tool.selection.marquee_end_x", 100);
    store.set("tool.selection.marquee_end_y", 80);
    dispatchEvent(
      "selection",
      {
        type: "mouseup",
        x: 100, y: 80,
        modifiers: { shift: false, ctrl: false, alt: false, meta: false },
      },
      store,
      { onDocEffect: (name, spec) => docEffects.push(name) },
    );
    assert.equal(store.get("tool.selection.mode"), "idle");
    // Should have fired doc.select_in_rect (V1 no-op via onDocEffect).
    assert.ok(docEffects.includes("doc.select_in_rect"));
  });
});
