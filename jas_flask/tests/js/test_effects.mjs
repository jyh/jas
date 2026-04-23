// Tests for the effect dispatcher + StateStore.

import { describe, it } from "node:test";
import assert from "node:assert/strict";

import { StateStore } from "../../static/js/engine/store.mjs";
import { runEffects } from "../../static/js/engine/effects.mjs";
import { Scope } from "../../static/js/engine/scope.mjs";

// ─── StateStore ───────────────────────────────────────────

describe("StateStore — basic ops", () => {
  it("reads from explicit init", () => {
    const s = new StateStore({ state: { fill_color: "#ff0000" } });
    assert.equal(s.get("state.fill_color"), "#ff0000");
  });

  it("read unknown returns undefined", () => {
    const s = new StateStore();
    assert.equal(s.get("state.nowhere"), undefined);
    assert.equal(s.get("state.a.b.c"), undefined);
  });

  it("write at shallow path", () => {
    const s = new StateStore();
    s.set("state.x", 42);
    assert.equal(s.state.x, 42);
    assert.equal(s.get("state.x"), 42);
  });

  it("write at deep path creates intermediates", () => {
    const s = new StateStore();
    s.set("tool.selection.mode", "idle");
    assert.equal(s.tool.selection.mode, "idle");
    assert.equal(s.get("tool.selection.mode"), "idle");
  });

  it("write rejects unknown scope", () => {
    const s = new StateStore();
    assert.throws(() => s.set("unknown.x", 1));
  });

  it("write rejects bare scope", () => {
    const s = new StateStore();
    assert.throws(() => s.set("state", 1));
  });

  it("asContext returns namespace dict", () => {
    const s = new StateStore({ state: { x: 1 }, panel: { c: { r: 100 } } });
    const ctx = s.asContext();
    assert.deepEqual(ctx.state, { x: 1 });
    assert.deepEqual(ctx.panel, { c: { r: 100 } });
    assert.deepEqual(ctx.tool, {});
  });

  it("listeners fire with path + value", () => {
    const s = new StateStore();
    const calls = [];
    s.addListener((path, val) => calls.push([path, val]));
    s.set("state.x", 42);
    s.set("tool.pen.anchors", 3);
    assert.equal(calls.length, 2);
    assert.deepEqual(calls[0], ["state.x", 42]);
    assert.deepEqual(calls[1], ["tool.pen.anchors", 3]);
  });

  it("listener unsubscribe", () => {
    const s = new StateStore();
    let count = 0;
    const off = s.addListener(() => count++);
    s.set("state.x", 1);
    off();
    s.set("state.x", 2);
    assert.equal(count, 1);
  });
});

// ─── runEffects ───────────────────────────────────────────

describe("runEffects — set", () => {
  it("writes constant value", () => {
    const s = new StateStore();
    runEffects(
      [{ set: "$state.x", value: "42" }],
      s.asContext(),
      s,
    );
    assert.equal(s.get("state.x"), 42);
  });

  it("writes expression result", () => {
    const s = new StateStore({ state: { a: 3, b: 4 } });
    runEffects(
      [{ set: "state.c", value: "state.a + state.b" }],
      s.asContext(),
      s,
    );
    assert.equal(s.get("state.c"), 7);
  });

  it("handles target without $ prefix identically", () => {
    const s = new StateStore();
    runEffects(
      [{ set: "tool.selection.mode", value: '"idle"' }],
      s.asContext(),
      s,
    );
    assert.equal(s.get("tool.selection.mode"), "idle");
  });

  it("multiple sets see earlier writes (live scope)", () => {
    const s = new StateStore();
    runEffects(
      [
        { set: "state.x", value: "1" },
        { set: "state.y", value: "2" },
        { set: "state.sum", value: "state.x + state.y" },
      ],
      s.asContext(),
      s,
    );
    // The scope object wraps references to the store's inner state
    // dicts, so later effects see mutations from earlier ones within
    // the same dispatch. This is pragmatically useful (set X, then
    // compute Y from X) — YAML authors expect it.
    assert.equal(s.get("state.x"), 1);
    assert.equal(s.get("state.y"), 2);
    assert.equal(s.get("state.sum"), 3);
  });
});

describe("runEffects — if / then / else", () => {
  it("runs then branch when condition truthy", () => {
    const s = new StateStore();
    runEffects(
      [{
        if: "true",
        then: [{ set: "state.taken", value: '"then"' }],
        else: [{ set: "state.taken", value: '"else"' }],
      }],
      s.asContext(),
      s,
    );
    assert.equal(s.get("state.taken"), "then");
  });

  it("runs else branch when condition falsy", () => {
    const s = new StateStore();
    runEffects(
      [{
        if: "false",
        then: [{ set: "state.taken", value: '"then"' }],
        else: [{ set: "state.taken", value: '"else"' }],
      }],
      s.asContext(),
      s,
    );
    assert.equal(s.get("state.taken"), "else");
  });

  it("omitted else is a no-op", () => {
    const s = new StateStore({ state: { taken: "init" } });
    runEffects(
      [{ if: "false", then: [{ set: "state.taken", value: '"then"' }] }],
      s.asContext(),
      s,
    );
    assert.equal(s.get("state.taken"), "init");
  });

  it("condition reads store state", () => {
    const s = new StateStore({ state: { count: 5 } });
    runEffects(
      [{
        if: "state.count > 3",
        then: [{ set: "state.big", value: "true" }],
        else: [{ set: "state.big", value: "false" }],
      }],
      s.asContext(),
      s,
    );
    assert.equal(s.get("state.big"), true);
  });
});

describe("runEffects — let / in", () => {
  it("bindings visible to inner effects", () => {
    const s = new StateStore();
    runEffects(
      [{
        let: { x: "5 + 3" },
        in: [{ set: "state.x_plus_1", value: "x + 1" }],
      }],
      s.asContext(),
      s,
    );
    assert.equal(s.get("state.x_plus_1"), 9);
  });

  it("multiple bindings", () => {
    const s = new StateStore();
    runEffects(
      [{
        let: { a: "2", b: "3" },
        in: [{ set: "state.prod", value: "a * b" }],
      }],
      s.asContext(),
      s,
    );
    assert.equal(s.get("state.prod"), 6);
  });
});

describe("runEffects — doc placeholders", () => {
  it("doc.* effects are recognized but no-op in V1", () => {
    const s = new StateStore();
    const seen = [];
    runEffects(
      [
        { "doc.snapshot": {} },
        { "doc.add_element": { parent: "[0]", element: { type: "rect" } } },
      ],
      s.asContext(),
      s,
      { onDocEffect: (name, spec) => seen.push([name, spec]) },
    );
    assert.equal(seen.length, 2);
    assert.equal(seen[0][0], "doc.snapshot");
    assert.equal(seen[1][0], "doc.add_element");
  });
});

describe("runEffects — log", () => {
  it("log routes via onLog", () => {
    const s = new StateStore();
    const msgs = [];
    runEffects(
      [{ log: "hello" }],
      s.asContext(),
      s,
      { onLog: (m) => msgs.push(m) },
    );
    assert.deepEqual(msgs, ["hello"]);
  });
});

describe("runEffects — unknown", () => {
  it("unknown effects fire onUnknown callback", () => {
    const s = new StateStore();
    const unknowns = [];
    runEffects(
      [{ made_up_effect: "x" }],
      s.asContext(),
      s,
      { onUnknown: (e) => unknowns.push(e) },
    );
    assert.equal(unknowns.length, 1);
  });
});
