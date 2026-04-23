// Tests for the JS Scope wrapper.

import { describe, it } from "node:test";
import assert from "node:assert/strict";

import { Scope, buildHandlerScope } from "../../static/js/engine/scope.mjs";
import { NULL, NUMBER, STRING, BOOL, PATH } from "../../static/js/engine/value.mjs";

describe("Scope", () => {
  it("get returns raw value", () => {
    const s = new Scope({ state: { x: 42 } });
    assert.deepEqual(s.get("state"), { x: 42 });
    assert.equal(s.get("missing"), undefined);
  });

  it("set mutates top-level", () => {
    const s = new Scope();
    s.set("panel", { color: { r: 255 } });
    assert.deepEqual(s.get("panel"), { color: { r: 255 } });
  });

  it("extend returns new scope without mutating parent", () => {
    const parent = new Scope({ state: { x: 1 } });
    const child = parent.extend({ tool: { mode: "idle" } });
    assert.equal(child.get("tool").mode, "idle");
    assert.equal(parent.get("tool"), undefined);
  });

  it("toDict returns plain object", () => {
    const s = new Scope({ a: 1, b: 2 });
    assert.deepEqual(s.toDict(), { a: 1, b: 2 });
  });
});

describe("Scope.resolvePath", () => {
  const s = new Scope({
    event: {
      x: 100,
      y: 200,
      modifiers: { shift: true, ctrl: false },
      key: null,
    },
    tool: {
      selection: { mode: "idle" },
    },
    list_with_paths: [{ __path__: [0, 1] }],
  });

  it("single segment", () => {
    const v = s.resolvePath(["event"]);
    assert.equal(v.kind, STRING); // fromJson turns dict into opaque string marker
    assert.equal(v.value, "__dict__");
  });

  it("nested dict access", () => {
    const v = s.resolvePath(["event", "x"]);
    assert.equal(v.kind, NUMBER);
    assert.equal(v.value, 100);
  });

  it("deeper nested access", () => {
    const v = s.resolvePath(["event", "modifiers", "shift"]);
    assert.equal(v.kind, BOOL);
    assert.equal(v.value, true);
  });

  it("missing path yields null", () => {
    assert.equal(s.resolvePath(["event", "missing"]).kind, NULL);
    assert.equal(s.resolvePath(["nowhere"]).kind, NULL);
    assert.equal(s.resolvePath(["event", "modifiers", "nope"]).kind, NULL);
  });

  it("explicit null stays null", () => {
    assert.equal(s.resolvePath(["event", "key"]).kind, NULL);
  });

  it("empty segments yield null", () => {
    assert.equal(s.resolvePath([]).kind, NULL);
  });

  it("array index access", () => {
    const v = s.resolvePath(["list_with_paths", "0"]);
    assert.equal(v.kind, PATH);
    assert.deepEqual(v.value, [0, 1]);
  });
});

describe("buildHandlerScope", () => {
  it("defaults to empty namespaces", () => {
    const s = buildHandlerScope();
    assert.deepEqual(s.get("state"), {});
    assert.deepEqual(s.get("event"), {});
    assert.deepEqual(s.get("tool"), {});
    assert.deepEqual(s.get("platform"), {});
    assert.deepEqual(s.get("features"), {});
  });

  it("populates provided namespaces", () => {
    const s = buildHandlerScope({
      state: { active_tool: "selection" },
      event: { type: "mousedown", x: 50, y: 75 },
      platform: { is_web: true, os: "macos" },
    });
    assert.equal(s.resolvePath(["state", "active_tool"]).value, "selection");
    assert.equal(s.resolvePath(["event", "x"]).value, 50);
    assert.equal(s.resolvePath(["platform", "is_web"]).value, true);
  });
});
