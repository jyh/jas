// Tests for the expression parser.

import { describe, it } from "node:test";
import assert from "node:assert/strict";

import { parse, ParseError } from "../../static/js/engine/parser.mjs";

describe("parser — literals", () => {
  it("empty input → null", () => {
    assert.equal(parse(""), null);
    assert.equal(parse("   "), null);
  });

  it("integer literal", () => {
    assert.deepEqual(parse("42"),
      { type: "literal", value: 42, kind: "number" });
  });

  it("string literal", () => {
    assert.deepEqual(parse('"hi"'),
      { type: "literal", value: "hi", kind: "string" });
  });

  it("color literal", () => {
    assert.deepEqual(parse("#ff0000"),
      { type: "literal", value: "#ff0000", kind: "color" });
  });

  it("boolean literals", () => {
    assert.deepEqual(parse("true"), { type: "literal", value: true, kind: "bool" });
    assert.deepEqual(parse("false"), { type: "literal", value: false, kind: "bool" });
  });

  it("null literal", () => {
    assert.deepEqual(parse("null"), { type: "literal", value: null, kind: "null" });
  });

  it("list literal", () => {
    const ast = parse("[1, 2, 3]");
    assert.equal(ast.type, "literal");
    assert.equal(ast.kind, "list");
    assert.equal(ast.value.length, 3);
  });

  it("empty list literal", () => {
    assert.deepEqual(parse("[]"), {
      type: "literal",
      value: [],
      kind: "list",
    });
  });
});

describe("parser — paths", () => {
  it("single segment → Path", () => {
    assert.deepEqual(parse("foo"), { type: "path", segments: ["foo"] });
  });

  it("dotted path", () => {
    assert.deepEqual(parse("state.foo.bar"),
      { type: "path", segments: ["state", "foo", "bar"] });
  });

  it("dotted path with trailing integer index", () => {
    // Matches how YAML authors reach list elements — `first` element
    // of a list is `items.0`. Note the lexer consumes `0.` as a float
    // when followed by more digits; this works for trailing-integer
    // access but not `items.0.name` (which the Python parser also
    // rejects).
    assert.deepEqual(parse("items.0"),
      { type: "path", segments: ["items", "0"] });
  });

  it("keywords allowed as dotted member names", () => {
    // Matches Python's behavior — useful for paths like `item.in` or
    // `foo.not` where the YAML author used a keyword as a key.
    const ast = parse("foo.not");
    assert.deepEqual(ast.segments, ["foo", "not"]);
  });
});

describe("parser — function calls", () => {
  it("no-arg call", () => {
    assert.deepEqual(parse("f()"), { type: "func_call", name: "f", args: [] });
  });

  it("single-arg call", () => {
    const ast = parse("abs(x)");
    assert.equal(ast.type, "func_call");
    assert.equal(ast.name, "abs");
    assert.equal(ast.args.length, 1);
  });

  it("multi-arg call", () => {
    const ast = parse("min(a, b, c)");
    assert.equal(ast.args.length, 3);
  });

  it("nested call", () => {
    const ast = parse("max(min(a, b), c)");
    assert.equal(ast.name, "max");
    assert.equal(ast.args[0].type, "func_call");
    assert.equal(ast.args[0].name, "min");
  });
});

describe("parser — operators", () => {
  it("comparison", () => {
    const ast = parse("a == b");
    assert.deepEqual(ast, {
      type: "binary_op", op: "==",
      left: { type: "path", segments: ["a"] },
      right: { type: "path", segments: ["b"] },
    });
  });

  it("arithmetic precedence: + then *", () => {
    // a + b * c  →  a + (b * c)
    const ast = parse("a + b * c");
    assert.equal(ast.type, "binary_op");
    assert.equal(ast.op, "+");
    assert.equal(ast.right.type, "binary_op");
    assert.equal(ast.right.op, "*");
  });

  it("parens override precedence", () => {
    // (a + b) * c
    const ast = parse("(a + b) * c");
    assert.equal(ast.op, "*");
    assert.equal(ast.left.op, "+");
  });

  it("unary minus", () => {
    assert.deepEqual(parse("-x"), {
      type: "unary_op", op: "-",
      operand: { type: "path", segments: ["x"] },
    });
  });

  it("unary not", () => {
    const ast = parse("not x");
    assert.equal(ast.type, "unary_op");
    assert.equal(ast.op, "not");
  });

  it("and / or", () => {
    const ast = parse("a and b or c");
    // or has lower precedence: (a and b) or c
    assert.equal(ast.type, "logical_op");
    assert.equal(ast.op, "or");
    assert.equal(ast.left.op, "and");
  });
});

describe("parser — control flow", () => {
  it("ternary if/then/else", () => {
    const ast = parse("if a then b else c");
    assert.equal(ast.type, "ternary");
    assert.equal(ast.condition.segments[0], "a");
    assert.equal(ast.trueExpr.segments[0], "b");
    assert.equal(ast.falseExpr.segments[0], "c");
  });

  it("nested ternary", () => {
    const ast = parse("if a then b else if c then d else e");
    assert.equal(ast.falseExpr.type, "ternary");
  });

  it("let binding", () => {
    const ast = parse("let x = 1 in x + 2");
    assert.equal(ast.type, "let");
    assert.equal(ast.name, "x");
    assert.equal(ast.body.type, "binary_op");
  });

  it("lambda with single param", () => {
    const ast = parse("fun x -> x + 1");
    assert.equal(ast.type, "lambda");
    assert.deepEqual(ast.params, ["x"]);
  });

  it("lambda with multiple params", () => {
    const ast = parse("fun (a, b) -> a + b");
    assert.deepEqual(ast.params, ["a", "b"]);
  });

  it("lambda with no params", () => {
    const ast = parse("fun () -> 42");
    assert.deepEqual(ast.params, []);
  });

  it("assignment with <-", () => {
    const ast = parse("x <- 42");
    assert.equal(ast.type, "assign");
    assert.equal(ast.target, "x");
  });

  it("sequence with ;", () => {
    const ast = parse("a; b");
    assert.equal(ast.type, "sequence");
  });
});

describe("parser — access suffixes", () => {
  it("bracket index access on computed obj", () => {
    const ast = parse("f()[0]");
    assert.equal(ast.type, "index_access");
    assert.equal(ast.obj.type, "func_call");
  });

  it("dynamic bracket index", () => {
    const ast = parse("items[i]");
    // First a bare identifier `items` becomes a Path; then [...] turns
    // it into IndexAccess.
    assert.equal(ast.type, "index_access");
  });
});

describe("parser — errors", () => {
  it("unclosed paren throws", () => {
    assert.throws(() => parse("(a + b"), ParseError);
  });

  it("dot with no member throws", () => {
    assert.throws(() => parse("a."), ParseError);
  });

  it("unexpected trailing token throws", () => {
    assert.throws(() => parse("a b"), ParseError);
  });
});

describe("parser — selection tool expressions", () => {
  // Smoke test real expressions from workspace/tools/selection.yaml.
  it("path check on tool mode", () => {
    const ast = parse('tool.selection.mode == "idle"');
    assert.equal(ast.type, "binary_op");
    assert.equal(ast.op, "==");
  });

  it("not + function call", () => {
    const ast = parse("not selection_contains(hit)");
    assert.equal(ast.type, "unary_op");
    assert.equal(ast.op, "not");
    assert.equal(ast.operand.type, "func_call");
  });

  it("arithmetic between paths", () => {
    const ast = parse("event.x - tool.selection.drag_start_x");
    assert.equal(ast.type, "binary_op");
    assert.equal(ast.op, "-");
  });

  it("complex condition", () => {
    const ast = parse("hit == null and not event.modifiers.shift");
    assert.equal(ast.type, "logical_op");
    assert.equal(ast.op, "and");
  });
});
