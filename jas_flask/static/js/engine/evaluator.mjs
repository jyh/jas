// Tree-walking evaluator for the workspace expression-language AST.
//
// Mirrors a subset of `workspace_interpreter/expr_eval.py`. V1 scope:
// literals, paths, function calls (built-in primitives only), dot /
// index access, binary / unary operators, logical short-circuit,
// ternary, let, sequence. Defers: closures (Lambda), dynamic
// dispatch through `__apply__`, color-decomposition primitives.
//
// The evaluator's inputs are:
//   - `node`: an AST produced by parser.mjs
//   - `scope`: a Scope (scope.mjs) exposing the top-level namespaces
//
// Its output is always a Value (value.mjs). Never throws — errors
// collapse to `mkNull()` to match the other four interpreters'
// "expressions always terminate with a typed Value" contract.

import {
  NULL, BOOL, NUMBER, STRING, COLOR, LIST, PATH,
  mkNull, mkBool, mkNumber, mkString, mkColor, mkList,
  toBool, toStringCoerce, strictEq, fromJson, toJson,
} from "./value.mjs";
import { Scope } from "./scope.mjs";

/**
 * Evaluate an AST node against a Scope.
 * Returns a Value (never null/undefined; mkNull() on error paths).
 */
export function evalNode(node, scope) {
  if (!node) return mkNull();
  switch (node.type) {
    case "literal": return evalLiteral(node, scope);
    case "path": return evalPath(node.segments, scope);
    case "func_call": return evalFuncCall(node, scope);
    case "dot_access": return evalDotAccess(node, scope);
    case "index_access": return evalIndexAccess(node, scope);
    case "binary_op": return evalBinaryOp(node, scope);
    case "unary_op": return evalUnaryOp(node, scope);
    case "ternary": return evalTernary(node, scope);
    case "logical_op": return evalLogicalOp(node, scope);
    case "let": return evalLet(node, scope);
    case "sequence":
      evalNode(node.left, scope);
      return evalNode(node.right, scope);
    case "lambda":
    case "assign":
    default:
      return mkNull();
  }
}

// ─── Literals ───────────────────────────────────────────────

function evalLiteral(node, scope) {
  switch (node.kind) {
    case "number": return mkNumber(node.value);
    case "string": return mkString(node.value);
    case "color": return mkColor(node.value);
    case "bool": return mkBool(node.value);
    case "null": return mkNull();
    case "list":
      return mkList(node.value.map((item) => evalNode(item, scope)));
    default: return mkNull();
  }
}

// ─── Path resolution ────────────────────────────────────────
//
// Special-cases the first segment as a scope namespace lookup (state /
// panel / tool / event / …) matching the Python implementation.

function evalPath(segments, scope) {
  if (!segments || segments.length === 0) return mkNull();
  const first = segments[0];
  const obj = scope.get(first);
  if (obj === undefined) return mkNull();

  let cur = obj;
  for (let i = 1; i < segments.length; i++) {
    const seg = segments[i];
    if (cur === null || cur === undefined) return mkNull();
    if (Array.isArray(cur)) {
      const idx = parseInt(seg, 10);
      if (!Number.isNaN(idx) && idx >= 0 && idx < cur.length) {
        cur = cur[idx];
      } else if (seg === "length") {
        return mkNumber(cur.length);
      } else {
        return mkNull();
      }
    } else if (typeof cur === "string") {
      if (seg === "length") return mkNumber(cur.length);
      return mkNull();
    } else if (typeof cur === "object") {
      if (Object.prototype.hasOwnProperty.call(cur, seg)) {
        cur = cur[seg];
      } else {
        return mkNull();
      }
    } else {
      return mkNull();
    }
  }
  return fromJson(cur);
}

// ─── Accessors ──────────────────────────────────────────────

function evalDotAccess(node, scope) {
  const obj = evalNode(node.obj, scope);
  const member = node.member;

  // Path computed properties (Phase 3 §6.2).
  if (obj.kind === PATH) {
    const indices = obj.value;
    if (member === "depth") return mkNumber(indices.length);
    if (member === "parent") {
      if (indices.length === 0) return mkNull();
      return { kind: PATH, value: indices.slice(0, -1) };
    }
    if (member === "id") return mkString(indices.join("."));
    if (member === "indices") return mkList(indices.map(mkNumber));
    return mkNull();
  }

  if (obj.kind === LIST && member === "length") {
    return mkNumber(obj.value.length);
  }
  if (obj.kind === STRING && member === "length") {
    return mkNumber(obj.value.length);
  }

  // Numeric index into a list.
  if (obj.kind === LIST) {
    const idx = parseInt(member, 10);
    if (!Number.isNaN(idx) && idx >= 0 && idx < obj.value.length) {
      return obj.value[idx];
    }
  }

  return mkNull();
}

function evalIndexAccess(node, scope) {
  const obj = evalNode(node.obj, scope);
  const idxVal = evalNode(node.index, scope);

  if (obj.kind === LIST) {
    let i = null;
    if (idxVal.kind === NUMBER) i = Math.floor(idxVal.value);
    else if (idxVal.kind === STRING) {
      const parsed = parseInt(idxVal.value, 10);
      if (!Number.isNaN(parsed)) i = parsed;
    }
    if (i !== null && i >= 0 && i < obj.value.length) return obj.value[i];
  }

  return mkNull();
}

// ─── Operators ──────────────────────────────────────────────

function evalBinaryOp(node, scope) {
  const l = evalNode(node.left, scope);
  const r = evalNode(node.right, scope);

  switch (node.op) {
    case "==": return mkBool(strictEq(l, r));
    case "!=": return mkBool(!strictEq(l, r));
    case "<":  return compareNumbers(l, r, (a, b) => a < b);
    case "<=": return compareNumbers(l, r, (a, b) => a <= b);
    case ">":  return compareNumbers(l, r, (a, b) => a > b);
    case ">=": return compareNumbers(l, r, (a, b) => a >= b);
    case "+":  return arithmeticOrConcat(l, r);
    case "-":  return numericOp(l, r, (a, b) => a - b);
    case "*":  return numericOp(l, r, (a, b) => a * b);
    case "/":
      if (r.kind === NUMBER && r.value === 0) return mkNull();
      return numericOp(l, r, (a, b) => a / b);
    default: return mkNull();
  }
}

function compareNumbers(l, r, cmp) {
  if (l.kind !== NUMBER || r.kind !== NUMBER) return mkBool(false);
  return mkBool(cmp(l.value, r.value));
}

function numericOp(l, r, op) {
  if (l.kind !== NUMBER || r.kind !== NUMBER) return mkNull();
  return mkNumber(op(l.value, r.value));
}

function arithmeticOrConcat(l, r) {
  // Both numbers → arithmetic. Else coerce to strings and concat.
  if (l.kind === NUMBER && r.kind === NUMBER) {
    return mkNumber(l.value + r.value);
  }
  if (l.kind === STRING || r.kind === STRING) {
    return mkString(toStringCoerce(l) + toStringCoerce(r));
  }
  return mkNull();
}

function evalUnaryOp(node, scope) {
  const v = evalNode(node.operand, scope);
  switch (node.op) {
    case "not": return mkBool(!toBool(v));
    case "-":
      if (v.kind === NUMBER) return mkNumber(-v.value);
      return mkNull();
    default: return mkNull();
  }
}

function evalTernary(node, scope) {
  const cond = evalNode(node.condition, scope);
  return evalNode(toBool(cond) ? node.trueExpr : node.falseExpr, scope);
}

function evalLogicalOp(node, scope) {
  // Short-circuit semantics, matching Python's `and` / `or`.
  const l = evalNode(node.left, scope);
  if (node.op === "and") {
    if (!toBool(l)) return l;
    return evalNode(node.right, scope);
  }
  if (node.op === "or") {
    if (toBool(l)) return l;
    return evalNode(node.right, scope);
  }
  return mkNull();
}

function evalLet(node, scope) {
  const val = evalNode(node.value, scope);
  // Let bindings extend scope with the evaluated raw JS value (so path
  // access into the binding works like a namespace).
  const extended = scope.extend({ [node.name]: toJson(val) });
  return evalNode(node.body, extended);
}

// ─── Function calls — built-in primitives ──────────────────
//
// The dispatch table is a plain object so that tests can introspect it
// and tools can later inject additional primitives (e.g. geometry
// functions exposed via hit_test).

export const PRIMITIVES = {
  // Math
  min: (args) => reduceNumeric(args, Math.min),
  max: (args) => reduceNumeric(args, Math.max),
  abs: (args) => args[0]?.kind === NUMBER ? mkNumber(Math.abs(args[0].value)) : mkNull(),
  floor: (args) => args[0]?.kind === NUMBER ? mkNumber(Math.floor(args[0].value)) : mkNull(),
  ceil: (args) => args[0]?.kind === NUMBER ? mkNumber(Math.ceil(args[0].value)) : mkNull(),
  round: (args) => args[0]?.kind === NUMBER ? mkNumber(Math.round(args[0].value)) : mkNull(),
  sqrt: (args) => args[0]?.kind === NUMBER ? mkNumber(Math.sqrt(args[0].value)) : mkNull(),
  sin: (args) => args[0]?.kind === NUMBER ? mkNumber(Math.sin(args[0].value)) : mkNull(),
  cos: (args) => args[0]?.kind === NUMBER ? mkNumber(Math.cos(args[0].value)) : mkNull(),
  tan: (args) => args[0]?.kind === NUMBER ? mkNumber(Math.tan(args[0].value)) : mkNull(),
  atan2: (args) => {
    if (args[0]?.kind === NUMBER && args[1]?.kind === NUMBER) {
      return mkNumber(Math.atan2(args[0].value, args[1].value));
    }
    return mkNull();
  },

  // Geometry (minimal)
  distance: (args) => {
    if (args.length === 4 && args.every((a) => a.kind === NUMBER)) {
      const dx = args[2].value - args[0].value;
      const dy = args[3].value - args[1].value;
      return mkNumber(Math.sqrt(dx * dx + dy * dy));
    }
    return mkNull();
  },

  // String
  length: (args) => {
    const v = args[0];
    if (!v) return mkNumber(0);
    if (v.kind === STRING || v.kind === LIST) return mkNumber(v.value.length);
    if (v.kind === PATH) return mkNumber(v.value.length);
    return mkNumber(0);
  },
  uppercase: (args) => args[0]?.kind === STRING ? mkString(args[0].value.toUpperCase()) : mkNull(),
  lowercase: (args) => args[0]?.kind === STRING ? mkString(args[0].value.toLowerCase()) : mkNull(),
};

function reduceNumeric(args, fn) {
  if (args.length === 0) return mkNull();
  let acc = null;
  for (const a of args) {
    if (a.kind !== NUMBER) return mkNull();
    acc = acc === null ? a.value : fn(acc, a.value);
  }
  return mkNumber(acc);
}

function evalFuncCall(node, scope) {
  const args = node.args.map((a) => evalNode(a, scope));
  const fn = PRIMITIVES[node.name];
  if (fn) return fn(args);
  // Unknown primitive: return null rather than throwing — matches the
  // other interpreters' lenient mode. Callers can opt into strict mode
  // for unit tests.
  return mkNull();
}
