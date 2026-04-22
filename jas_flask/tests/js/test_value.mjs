// Tests for the JS Value primitives.
//
// Run with: node --test jas_flask/tests/js/test_value.mjs

import { describe, it } from "node:test";
import assert from "node:assert/strict";

import {
  mkNull, mkBool, mkNumber, mkString, mkColor, mkList, mkPath,
  toBool, toStringCoerce, strictEq,
  fromJson, toJson,
  NULL, BOOL, NUMBER, STRING, COLOR, LIST, PATH,
} from "../../static/js/engine/value.mjs";

describe("Value constructors", () => {
  it("mkNull", () => {
    const v = mkNull();
    assert.equal(v.kind, NULL);
    assert.equal(v.value, null);
  });

  it("mkBool coerces", () => {
    assert.equal(mkBool(1).value, true);
    assert.equal(mkBool(0).value, false);
    assert.equal(mkBool("").value, false);
  });

  it("mkNumber rejects NaN", () => {
    assert.throws(() => mkNumber(NaN));
    assert.throws(() => mkNumber("not a number"));
  });

  it("mkColor normalizes #rgb to #rrggbb", () => {
    assert.equal(mkColor("#abc").value, "#aabbcc");
    assert.equal(mkColor("#ABCDEF").value, "#abcdef");
    assert.equal(mkColor("ff0000").value, "#ff0000"); // prepend #
  });

  it("mkPath coerces indices to integers", () => {
    const p = mkPath([1.5, 2, 3.9]);
    assert.deepEqual(p.value, [1, 2, 3]);
  });
});

describe("toBool", () => {
  it("null is falsy", () => assert.equal(toBool(mkNull()), false));
  it("bool is itself", () => {
    assert.equal(toBool(mkBool(true)), true);
    assert.equal(toBool(mkBool(false)), false);
  });
  it("number nonzero is truthy", () => {
    assert.equal(toBool(mkNumber(0)), false);
    assert.equal(toBool(mkNumber(1)), true);
    assert.equal(toBool(mkNumber(-1)), true);
  });
  it("string nonempty is truthy", () => {
    assert.equal(toBool(mkString("")), false);
    assert.equal(toBool(mkString("x")), true);
  });
  it("color is always truthy", () => {
    assert.equal(toBool(mkColor("#000000")), true);
  });
  it("list nonempty is truthy", () => {
    assert.equal(toBool(mkList([])), false);
    assert.equal(toBool(mkList([mkNumber(1)])), true);
  });
  it("path nonempty is truthy", () => {
    assert.equal(toBool(mkPath([])), false);
    assert.equal(toBool(mkPath([0])), true);
  });
});

describe("toStringCoerce", () => {
  it("null → empty", () => assert.equal(toStringCoerce(mkNull()), ""));
  it("bool → 'true'/'false'", () => {
    assert.equal(toStringCoerce(mkBool(true)), "true");
    assert.equal(toStringCoerce(mkBool(false)), "false");
  });
  it("integer number has no decimal point", () => {
    assert.equal(toStringCoerce(mkNumber(42)), "42");
  });
  it("float number keeps decimals", () => {
    assert.equal(toStringCoerce(mkNumber(1.5)), "1.5");
  });
  it("color preserves #rrggbb", () => {
    assert.equal(toStringCoerce(mkColor("#ff00aa")), "#ff00aa");
  });
  it("path uses dot separator", () => {
    assert.equal(toStringCoerce(mkPath([0, 2, 1])), "0.2.1");
  });
});

describe("strictEq", () => {
  it("same null", () => assert.ok(strictEq(mkNull(), mkNull())));
  it("different kinds are unequal", () => {
    assert.ok(!strictEq(mkNumber(0), mkBool(false)));
    assert.ok(!strictEq(mkString("1"), mkNumber(1)));
  });
  it("color normalizes case", () => {
    assert.ok(strictEq(mkColor("#ff0000"), mkColor("#FF0000")));
  });
  it("list element-wise", () => {
    const a = mkList([mkNumber(1), mkString("a")]);
    const b = mkList([mkNumber(1), mkString("a")]);
    const c = mkList([mkNumber(1), mkString("b")]);
    assert.ok(strictEq(a, b));
    assert.ok(!strictEq(a, c));
  });
  it("path element-wise", () => {
    assert.ok(strictEq(mkPath([0, 1, 2]), mkPath([0, 1, 2])));
    assert.ok(!strictEq(mkPath([0, 1]), mkPath([0, 1, 2])));
  });
});

describe("fromJson / toJson round-trip", () => {
  it("null", () => {
    const v = fromJson(null);
    assert.equal(v.kind, NULL);
    assert.equal(toJson(v), null);
  });
  it("boolean", () => {
    assert.equal(fromJson(true).kind, BOOL);
    assert.equal(toJson(fromJson(true)), true);
  });
  it("number", () => {
    assert.equal(fromJson(3.14).kind, NUMBER);
    assert.equal(toJson(fromJson(3.14)), 3.14);
  });
  it("string (non-color) stays string", () => {
    const v = fromJson("hello");
    assert.equal(v.kind, STRING);
    assert.equal(v.value, "hello");
  });
  it("hex string detected as color", () => {
    assert.equal(fromJson("#ff0000").kind, COLOR);
    assert.equal(fromJson("#f00").kind, COLOR);
  });
  it("non-hex-looking string stays string", () => {
    assert.equal(fromJson("#notacolor").kind, STRING);
    assert.equal(fromJson("# not a color").kind, STRING);
  });
  it("array → list, recursively", () => {
    const v = fromJson([1, "a", null]);
    assert.equal(v.kind, LIST);
    assert.equal(v.value[0].kind, NUMBER);
    assert.equal(v.value[1].kind, STRING);
    assert.equal(v.value[2].kind, NULL);
  });
  it("__path__ marker → path", () => {
    const v = fromJson({ __path__: [0, 1, 2] });
    assert.equal(v.kind, PATH);
    assert.deepEqual(v.value, [0, 1, 2]);
  });
  it("path round-trip", () => {
    const j = { __path__: [3, 1, 4] };
    const v = fromJson(j);
    assert.deepEqual(toJson(v), j);
  });
});
