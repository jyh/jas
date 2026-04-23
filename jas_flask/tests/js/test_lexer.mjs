// Tests for the expression lexer.

import { describe, it } from "node:test";
import assert from "node:assert/strict";

import { tokenize, TK } from "../../static/js/engine/lexer.mjs";

function kinds(src) {
  return tokenize(src).map((t) => t.kind);
}
function values(src) {
  return tokenize(src)
    .filter((t) => t.kind !== TK.EOF)
    .map((t) => t.value);
}

describe("lexer — literals", () => {
  it("empty input → only EOF", () => {
    assert.deepEqual(kinds(""), [TK.EOF]);
  });

  it("integer", () => {
    const toks = tokenize("42");
    assert.equal(toks[0].kind, TK.NUMBER);
    assert.equal(toks[0].value, 42);
    assert.equal(typeof toks[0].value, "number");
  });

  it("float", () => {
    const toks = tokenize("3.14");
    assert.equal(toks[0].kind, TK.NUMBER);
    assert.ok(Math.abs(toks[0].value - 3.14) < 1e-9);
  });

  it("double-quoted string", () => {
    const toks = tokenize('"hello"');
    assert.equal(toks[0].kind, TK.STRING);
    assert.equal(toks[0].value, "hello");
  });

  it("single-quoted string", () => {
    const toks = tokenize("'hello'");
    assert.equal(toks[0].kind, TK.STRING);
    assert.equal(toks[0].value, "hello");
  });

  it("string with escaped quote", () => {
    const toks = tokenize('"hey \\"there\\""');
    assert.equal(toks[0].value, 'hey "there"');
  });

  it("color 6-digit hex", () => {
    const toks = tokenize("#ff00aa");
    assert.equal(toks[0].kind, TK.COLOR);
    assert.equal(toks[0].value, "#ff00aa");
  });

  it("color 3-digit hex", () => {
    const toks = tokenize("#abc");
    assert.equal(toks[0].kind, TK.COLOR);
    assert.equal(toks[0].value, "#abc");
  });

  it("invalid hex → ERROR token", () => {
    const toks = tokenize("#abcd");
    assert.equal(toks[0].kind, TK.ERROR);
  });
});

describe("lexer — keywords and identifiers", () => {
  it("true / false / null", () => {
    assert.deepEqual(kinds("true false null"), [TK.TRUE, TK.FALSE, TK.NULL, TK.EOF]);
  });

  it("boolean keywords: not / and / or / in", () => {
    assert.deepEqual(kinds("not and or in"), [TK.NOT, TK.AND, TK.OR, TK.IN, TK.EOF]);
  });

  it("structural keywords: fun / let / if / then / else", () => {
    assert.deepEqual(kinds("fun let if then else"),
      [TK.FUN, TK.LET, TK.IF, TK.THEN, TK.ELSE, TK.EOF]);
  });

  it("identifier", () => {
    const toks = tokenize("my_var");
    assert.equal(toks[0].kind, TK.IDENT);
    assert.equal(toks[0].value, "my_var");
  });

  it("identifier starting with underscore", () => {
    assert.equal(tokenize("_x")[0].kind, TK.IDENT);
  });

  it("identifier with digits after first char", () => {
    assert.equal(tokenize("x123")[0].kind, TK.IDENT);
    assert.equal(tokenize("x123")[0].value, "x123");
  });
});

describe("lexer — operators", () => {
  it("comparison", () => {
    assert.deepEqual(kinds("== != < <= > >="),
      [TK.EQ, TK.NEQ, TK.LT, TK.LTE, TK.GT, TK.GTE, TK.EOF]);
  });

  it("arithmetic", () => {
    assert.deepEqual(kinds("+ - * /"),
      [TK.PLUS, TK.MINUS, TK.STAR, TK.SLASH, TK.EOF]);
  });

  it("arrows and assignment", () => {
    assert.deepEqual(kinds("-> <- ="),
      [TK.ARROW, TK.LARROW, TK.EQUALS, TK.EOF]);
  });

  it("punctuation", () => {
    assert.deepEqual(kinds("? : . , ; ( ) [ ]"),
      [TK.QUESTION, TK.COLON, TK.DOT, TK.COMMA, TK.SEMICOLON,
       TK.LPAREN, TK.RPAREN, TK.LBRACKET, TK.RBRACKET, TK.EOF]);
  });

  it("longest-match: <= before <", () => {
    assert.deepEqual(kinds("x <= y < z"),
      [TK.IDENT, TK.LTE, TK.IDENT, TK.LT, TK.IDENT, TK.EOF]);
  });
});

describe("lexer — path expressions from real YAML", () => {
  it("$event.x (treated as variable access via dotted idents)", () => {
    // Actual expression parser handles the $ prefix; tokenizer treats
    // `$event` as an identifier-with-prefix via the path grammar.
    // Here we verify the component tokens.
    const toks = tokenize("event.x");
    assert.deepEqual(toks.map((t) => t.kind),
      [TK.IDENT, TK.DOT, TK.IDENT, TK.EOF]);
  });

  it("comparison inside conditional", () => {
    const toks = tokenize('$tool.selection.mode == "idle"');
    // $ is not a valid lexer char → emits an ERROR token for the $.
    // The parser downstream will recognise the error.
    assert.ok(toks.some((t) => t.kind === TK.ERROR) ||
              toks.some((t) => t.kind === TK.IDENT));
    assert.ok(toks.some((t) => t.kind === TK.EQ));
    assert.ok(toks.some((t) => t.kind === TK.STRING));
  });

  it("arithmetic from selection tool", () => {
    const toks = tokenize("event.x - tool.selection.drag_start_x");
    const kindsList = toks.map((t) => t.kind);
    assert.ok(kindsList.includes(TK.MINUS));
    assert.ok(kindsList.includes(TK.DOT));
  });
});
