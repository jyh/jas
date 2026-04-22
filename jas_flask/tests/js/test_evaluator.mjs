// Tests for the JS expression evaluator (end-to-end parse + eval).

import { describe, it } from "node:test";
import assert from "node:assert/strict";

import { evaluate, evaluateText, clearCache } from "../../static/js/engine/expr.mjs";
import { Scope, buildHandlerScope } from "../../static/js/engine/scope.mjs";
import {
  NULL, BOOL, NUMBER, STRING, COLOR, LIST, PATH,
} from "../../static/js/engine/value.mjs";

describe("evaluator — literals", () => {
  it("number literal", () => {
    const v = evaluate("42", {});
    assert.equal(v.kind, NUMBER);
    assert.equal(v.value, 42);
  });

  it("string literal", () => {
    const v = evaluate('"hello"', {});
    assert.equal(v.kind, STRING);
    assert.equal(v.value, "hello");
  });

  it("color literal", () => {
    assert.equal(evaluate("#ff0000", {}).kind, COLOR);
  });

  it("bool / null literals", () => {
    assert.equal(evaluate("true", {}).kind, BOOL);
    assert.equal(evaluate("null", {}).kind, NULL);
  });

  it("empty input → null", () => {
    assert.equal(evaluate("", {}).kind, NULL);
    assert.equal(evaluate("   ", {}).kind, NULL);
  });
});

describe("evaluator — path access", () => {
  const ctx = {
    state: { active_tool: "selection", count: 5 },
    event: {
      x: 100, y: 200,
      modifiers: { shift: true, ctrl: false },
      key: null,
    },
    tool: {
      selection: { mode: "idle" },
    },
  };

  it("single namespace reference", () => {
    // Top-level dict becomes an opaque string marker per fromJson.
    const v = evaluate("state", ctx);
    assert.ok(v.kind === STRING || v.kind === NULL);
  });

  it("nested dict access", () => {
    assert.equal(evaluate("state.active_tool", ctx).value, "selection");
    assert.equal(evaluate("state.count", ctx).value, 5);
  });

  it("deeper nested access", () => {
    assert.equal(evaluate("event.modifiers.shift", ctx).value, true);
    assert.equal(evaluate("event.modifiers.ctrl", ctx).value, false);
    assert.equal(evaluate("tool.selection.mode", ctx).value, "idle");
  });

  it("missing path → null", () => {
    assert.equal(evaluate("nowhere", ctx).kind, NULL);
    assert.equal(evaluate("state.missing", ctx).kind, NULL);
    assert.equal(evaluate("event.modifiers.nope", ctx).kind, NULL);
  });

  it("explicit null stays null", () => {
    assert.equal(evaluate("event.key", ctx).kind, NULL);
  });
});

describe("evaluator — operators", () => {
  it("equality on strings", () => {
    const ctx = { tool: { selection: { mode: "idle" } } };
    assert.equal(evaluate('tool.selection.mode == "idle"', ctx).value, true);
    assert.equal(evaluate('tool.selection.mode == "drag"', ctx).value, false);
  });

  it("inequality", () => {
    assert.equal(evaluate("1 != 2", {}).value, true);
  });

  it("comparison on numbers", () => {
    assert.equal(evaluate("3 < 5", {}).value, true);
    assert.equal(evaluate("3 <= 3", {}).value, true);
    assert.equal(evaluate("5 > 3", {}).value, true);
    assert.equal(evaluate("3 >= 3", {}).value, true);
  });

  it("arithmetic", () => {
    assert.equal(evaluate("2 + 3", {}).value, 5);
    assert.equal(evaluate("10 - 4", {}).value, 6);
    assert.equal(evaluate("3 * 4", {}).value, 12);
    assert.equal(evaluate("15 / 4", {}).value, 3.75);
    assert.equal(evaluate("10 / 0", {}).kind, NULL);
  });

  it("string concatenation via +", () => {
    assert.equal(evaluate('"a" + "b"', {}).value, "ab");
    assert.equal(evaluate('"x=" + 5', {}).value, "x=5");
  });

  it("arithmetic on paths", () => {
    const ctx = { event: { x: 100 }, tool: { selection: { drag_start_x: 30 } } };
    assert.equal(evaluate("event.x - tool.selection.drag_start_x", ctx).value, 70);
  });

  it("precedence: * before +", () => {
    assert.equal(evaluate("2 + 3 * 4", {}).value, 14);
    assert.equal(evaluate("(2 + 3) * 4", {}).value, 20);
  });
});

describe("evaluator — unary and logical", () => {
  it("unary not", () => {
    assert.equal(evaluate("not true", {}).value, false);
    assert.equal(evaluate("not false", {}).value, true);
  });

  it("unary minus", () => {
    assert.equal(evaluate("-5", {}).value, -5);
    assert.equal(evaluate("-(2 + 3)", {}).value, -5);
  });

  it("logical and (short-circuit)", () => {
    assert.equal(evaluate("true and true", {}).value, true);
    assert.equal(evaluate("true and false", {}).value, false);
    // Short-circuits on falsy left
    assert.equal(evaluate("false and undefined_fn()", {}).value, false);
  });

  it("logical or (short-circuit)", () => {
    assert.equal(evaluate("false or true", {}).value, true);
    // Short-circuits on truthy left
    assert.equal(evaluate("true or undefined_fn()", {}).value, true);
  });
});

describe("evaluator — control flow", () => {
  it("ternary true branch", () => {
    assert.equal(evaluate("if true then 1 else 2", {}).value, 1);
  });

  it("ternary false branch", () => {
    assert.equal(evaluate("if false then 1 else 2", {}).value, 2);
  });

  it("ternary on path condition", () => {
    const ctx = { tool: { selection: { mode: "idle" } } };
    const v = evaluate('if tool.selection.mode == "idle" then "a" else "b"', ctx);
    assert.equal(v.value, "a");
  });

  it("let binding", () => {
    assert.equal(evaluate("let x = 5 in x + 3", {}).value, 8);
  });

  it("nested let", () => {
    assert.equal(evaluate("let x = 2 in let y = 3 in x * y", {}).value, 6);
  });
});

describe("evaluator — primitives", () => {
  it("min / max", () => {
    assert.equal(evaluate("min(3, 1, 4)", {}).value, 1);
    assert.equal(evaluate("max(3, 1, 4)", {}).value, 4);
  });

  it("abs / floor / ceil / round", () => {
    assert.equal(evaluate("abs(-5.5)", {}).value, 5.5);
    assert.equal(evaluate("floor(3.7)", {}).value, 3);
    assert.equal(evaluate("ceil(3.2)", {}).value, 4);
    assert.equal(evaluate("round(3.5)", {}).value, 4);
  });

  it("distance", () => {
    assert.equal(evaluate("distance(0, 0, 3, 4)", {}).value, 5);
  });

  it("length of string and list", () => {
    assert.equal(evaluate('length("hello")', {}).value, 5);
    assert.equal(evaluate("length([1, 2, 3])", {}).value, 3);
  });

  it("unknown primitive returns null", () => {
    assert.equal(evaluate("unknown_fn()", {}).kind, NULL);
  });
});

describe("evaluator — list literals", () => {
  it("list of numbers", () => {
    const v = evaluate("[1, 2, 3]", {});
    assert.equal(v.kind, LIST);
    assert.equal(v.value.length, 3);
    assert.equal(v.value[0].value, 1);
  });

  it("empty list", () => {
    const v = evaluate("[]", {});
    assert.equal(v.kind, LIST);
    assert.equal(v.value.length, 0);
  });
});

describe("evaluator — selection-tool expressions", () => {
  // Smoke-test actual expressions from workspace/tools/selection.yaml.

  const scope = buildHandlerScope({
    event: {
      x: 150, y: 80,
      modifiers: { shift: false, ctrl: false, alt: false, meta: false },
    },
    tool: {
      selection: {
        mode: "drag_move",
        marquee_start_x: 50, marquee_start_y: 50,
        marquee_end_x: 120, marquee_end_y: 80,
        drag_start_x: 100, drag_start_y: 70,
      },
    },
  });

  it("mode guard", () => {
    assert.equal(evaluate('tool.selection.mode == "marquee"', scope).value, false);
    assert.equal(evaluate('tool.selection.mode == "drag_move"', scope).value, true);
  });

  it("overlay size arithmetic", () => {
    // abs(marquee_end_x - marquee_start_x)
    assert.equal(
      evaluate("abs(tool.selection.marquee_end_x - tool.selection.marquee_start_x)", scope).value,
      70
    );
  });

  it("drag delta", () => {
    assert.equal(evaluate("event.x - tool.selection.drag_start_x", scope).value, 50);
    assert.equal(evaluate("event.y - tool.selection.drag_start_y", scope).value, 10);
  });

  it("shift-not modifier check", () => {
    assert.equal(evaluate("not event.modifiers.shift", scope).value, true);
  });

  it("marquee x range via min", () => {
    assert.equal(
      evaluate("min(tool.selection.marquee_start_x, tool.selection.marquee_end_x)", scope).value,
      50
    );
  });
});

describe("evaluateText — interpolation", () => {
  it("no braces returns literal", () => {
    assert.equal(evaluateText("hello", {}), "hello");
  });

  it("single interpolation", () => {
    assert.equal(evaluateText("x = {{42}}", {}), "x = 42");
  });

  it("multiple interpolations", () => {
    const ctx = { state: { name: "world" } };
    assert.equal(evaluateText("hi {{state.name}}!", ctx), "hi world!");
  });
});

describe("evaluator — AST cache", () => {
  it("same source reuses parsed AST", () => {
    clearCache();
    const v1 = evaluate("1 + 2", {});
    const v2 = evaluate("1 + 2", {});
    assert.equal(v1.value, 3);
    assert.equal(v2.value, 3);
  });

  it("parse errors cache as null", () => {
    clearCache();
    assert.equal(evaluate(")(", {}).kind, NULL);
    assert.equal(evaluate(")(", {}).kind, NULL);
  });
});
