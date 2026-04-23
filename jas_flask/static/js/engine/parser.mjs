// Recursive-descent parser for the workspace expression language.
//
// Mirrors `workspace_interpreter/expr_parser.py`. AST nodes are plain
// `{ type, ... }` objects — JSON-serializable, comparable in tests via
// `deepEqual`, no class hierarchy.
//
// Grammar (from SCHEMA.md):
//
//   sequence     = let_expr (';' let_expr)*
//   let_expr     = 'let' IDENT '=' sequence 'in' let_expr | assign
//   assign       = ternary '<-' assign | ternary
//   ternary      = 'if' expr 'then' expr 'else' expr | or_expr
//   or_expr      = and_expr ('or' and_expr)*
//   and_expr     = not_expr ('and' not_expr)*
//   not_expr     = 'not' not_expr | '-' not_expr | comparison
//   comparison   = addition (comp_op addition)?
//   addition     = multiplication (('+' | '-') multiplication)*
//   multiplication = primary (('*' | '/') primary)*
//   primary      = atom accessor*
//   atom         = 'fun' ... | IDENT '(' args? ')' | IDENT
//                | literal | '(' expr ')' | '[' list ']'

import { tokenize, TK } from "./lexer.mjs";

// AST node factories.
function Literal(value, kind) { return { type: "literal", value, kind }; }
function Path_(segments) { return { type: "path", segments }; }
function FuncCall(name, args) { return { type: "func_call", name, args }; }
function IndexAccess(obj, index) { return { type: "index_access", obj, index }; }
function DotAccess(obj, member) { return { type: "dot_access", obj, member }; }
function BinaryOp(op, left, right) { return { type: "binary_op", op, left, right }; }
function UnaryOp(op, operand) { return { type: "unary_op", op, operand }; }
function Ternary(condition, trueExpr, falseExpr) {
  return { type: "ternary", condition, trueExpr, falseExpr };
}
function LogicalOp(op, left, right) { return { type: "logical_op", op, left, right }; }
function Lambda(params, body) { return { type: "lambda", params, body }; }
function Let(name, value, body) { return { type: "let", name, value, body }; }
function Assign(target, value) { return { type: "assign", target, value }; }
function Sequence(left, right) { return { type: "sequence", left, right }; }

export class ParseError extends Error {
  constructor(msg) {
    super(msg);
    this.name = "ParseError";
  }
}

class Parser {
  constructor(tokens) {
    this.tokens = tokens;
    this.pos = 0;
  }

  _peek() { return this.tokens[this.pos]; }
  _advance() { return this.tokens[this.pos++]; }
  _at(...kinds) { return kinds.includes(this._peek().kind); }

  _expect(kind) {
    const t = this._advance();
    if (t.kind !== kind) {
      throw new ParseError(`Expected ${kind}, got ${t.kind}`);
    }
    return t;
  }

  parse() {
    if (this._peek().kind === TK.EOF) return null;
    const node = this._parseSequence();
    if (this._peek().kind !== TK.EOF) {
      throw new ParseError(`Unexpected token after expression: ${this._peek().kind}`);
    }
    return node;
  }

  _parseSequence() {
    let node = this._parseLet();
    while (this._at(TK.SEMICOLON)) {
      this._advance();
      const right = this._parseLet();
      node = Sequence(node, right);
    }
    return node;
  }

  _parseLet() {
    if (this._at(TK.LET)) {
      this._advance();
      const name = this._expect(TK.IDENT).value;
      this._expect(TK.EQUALS);
      const value = this._parseSequence();
      this._expect(TK.IN);
      const body = this._parseLet();
      return Let(name, value, body);
    }
    return this._parseAssign();
  }

  _parseAssign() {
    const node = this._parseTernary();
    if (this._at(TK.LARROW)) {
      this._advance();
      if (node.type === "path" && node.segments.length === 1) {
        const value = this._parseAssign();
        return Assign(node.segments[0], value);
      }
      throw new ParseError("Assignment target must be an identifier");
    }
    return node;
  }

  _parseTernary() {
    if (this._at(TK.IF)) {
      this._advance();
      const condition = this._parseSequence();
      this._expect(TK.THEN);
      const trueExpr = this._parseSequence();
      this._expect(TK.ELSE);
      const falseExpr = this._parseSequence();
      return Ternary(condition, trueExpr, falseExpr);
    }
    return this._parseOr();
  }

  _parseOr() {
    let node = this._parseAnd();
    while (this._at(TK.OR)) {
      this._advance();
      node = LogicalOp("or", node, this._parseAnd());
    }
    return node;
  }

  _parseAnd() {
    let node = this._parseNot();
    while (this._at(TK.AND)) {
      this._advance();
      node = LogicalOp("and", node, this._parseNot());
    }
    return node;
  }

  _parseNot() {
    if (this._at(TK.NOT)) {
      this._advance();
      return UnaryOp("not", this._parseNot());
    }
    if (this._at(TK.MINUS)) {
      this._advance();
      return UnaryOp("-", this._parseNot());
    }
    return this._parseComparison();
  }

  _parseComparison() {
    const node = this._parseAddition();
    const opMap = {
      [TK.EQ]: "==",
      [TK.NEQ]: "!=",
      [TK.LT]: "<",
      [TK.GT]: ">",
      [TK.LTE]: "<=",
      [TK.GTE]: ">=",
    };
    const k = this._peek().kind;
    if (opMap[k]) {
      this._advance();
      const right = this._parseAddition();
      return BinaryOp(opMap[k], node, right);
    }
    return node;
  }

  _parseAddition() {
    let node = this._parseMultiplication();
    while (this._at(TK.PLUS, TK.MINUS)) {
      const op = this._advance().kind === TK.PLUS ? "+" : "-";
      node = BinaryOp(op, node, this._parseMultiplication());
    }
    return node;
  }

  _parseMultiplication() {
    let node = this._parsePrimary();
    while (this._at(TK.STAR, TK.SLASH)) {
      const op = this._advance().kind === TK.STAR ? "*" : "/";
      node = BinaryOp(op, node, this._parsePrimary());
    }
    return node;
  }

  _parsePrimary() {
    let node = this._parseAtom();
    // Accessor suffixes: .member, [index], (args)
    for (;;) {
      if (this._at(TK.DOT)) {
        this._advance();
        const tok = this._peek();
        // Allow identifiers and select keywords as property names.
        const asMemberOk = [
          TK.IDENT, TK.TRUE, TK.FALSE, TK.NULL,
          TK.NOT, TK.AND, TK.OR, TK.IN,
        ];
        if (asMemberOk.includes(tok.kind)) {
          const member = String(this._advance().value);
          if (node.type === "path") node.segments.push(member);
          else node = DotAccess(node, member);
        } else if (tok.kind === TK.NUMBER && Number.isInteger(tok.value)) {
          const idx = this._advance().value;
          if (node.type === "path") node.segments.push(String(idx));
          else node = DotAccess(node, String(idx));
        } else {
          throw new ParseError(`Expected identifier after '.', got ${tok.kind}`);
        }
      } else if (this._at(TK.LBRACKET)) {
        this._advance();
        const index = this._parseSequence();
        this._expect(TK.RBRACKET);
        node = IndexAccess(node, index);
      } else if (this._at(TK.LPAREN)) {
        this._advance();
        const args = [];
        if (!this._at(TK.RPAREN)) {
          args.push(this._parseSequence());
          while (this._at(TK.COMMA)) {
            this._advance();
            args.push(this._parseSequence());
          }
        }
        this._expect(TK.RPAREN);
        if (node.type === "path" && node.segments.length === 1) {
          node = FuncCall(node.segments[0], args);
        } else {
          node = FuncCall("__apply__", [node, ...args]);
        }
      } else {
        break;
      }
    }
    return node;
  }

  _parseAtom() {
    const tok = this._peek();

    if (tok.kind === TK.FUN) {
      this._advance();
      const params = [];
      if (this._at(TK.LPAREN)) {
        this._advance();
        if (!this._at(TK.RPAREN)) {
          params.push(this._expect(TK.IDENT).value);
          while (this._at(TK.COMMA)) {
            this._advance();
            params.push(this._expect(TK.IDENT).value);
          }
        }
        this._expect(TK.RPAREN);
      } else if (this._at(TK.IDENT)) {
        params.push(this._advance().value);
      }
      this._expect(TK.ARROW);
      const body = this._parseSequence();
      return Lambda(params, body);
    }

    if (tok.kind === TK.IDENT) {
      this._advance();
      const name = tok.value;
      if (this._at(TK.LPAREN)) {
        this._advance();
        const args = [];
        if (!this._at(TK.RPAREN)) {
          args.push(this._parseSequence());
          while (this._at(TK.COMMA)) {
            this._advance();
            args.push(this._parseSequence());
          }
        }
        this._expect(TK.RPAREN);
        return FuncCall(name, args);
      }
      return Path_([name]);
    }

    if (tok.kind === TK.NUMBER) { this._advance(); return Literal(tok.value, "number"); }
    if (tok.kind === TK.STRING) { this._advance(); return Literal(tok.value, "string"); }
    if (tok.kind === TK.COLOR)  { this._advance(); return Literal(tok.value, "color"); }
    if (tok.kind === TK.TRUE)   { this._advance(); return Literal(true, "bool"); }
    if (tok.kind === TK.FALSE)  { this._advance(); return Literal(false, "bool"); }
    if (tok.kind === TK.NULL)   { this._advance(); return Literal(null, "null"); }

    if (tok.kind === TK.LPAREN) {
      this._advance();
      const node = this._parseSequence();
      this._expect(TK.RPAREN);
      return node;
    }

    if (tok.kind === TK.LBRACKET) {
      this._advance();
      const items = [];
      if (!this._at(TK.RBRACKET)) {
        items.push(this._parseSequence());
        while (this._at(TK.COMMA)) {
          this._advance();
          items.push(this._parseSequence());
        }
      }
      this._expect(TK.RBRACKET);
      return Literal(items, "list");
    }

    throw new ParseError(`Unexpected token: ${tok.kind} (${JSON.stringify(tok.value)})`);
  }
}

/**
 * Parse an expression string. Returns an AST node, or `null` for empty
 * input. Throws `ParseError` on syntax failure (the caller — typically
 * `workspace_interpreter.validator` at compile time or `expr.eval` at
 * runtime — decides whether to surface or swallow).
 */
export function parse(source) {
  const tokens = tokenize(source);
  const parser = new Parser(tokens);
  return parser.parse();
}
