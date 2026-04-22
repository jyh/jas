// Public API for the JS expression evaluator.
//
// Parallels `workspace_interpreter/expr.py`. Parsed ASTs are cached
// per source string in a process-wide Map — re-evaluating the same
// expression (inside a foreach or a per-frame overlay) skips the
// tokenize + parse step.
//
// Returns a typed Value (value.mjs). Never throws — returns mkNull()
// on any failure path.

import { parse, ParseError } from "./parser.mjs";
import { evalNode } from "./evaluator.mjs";
import { mkNull, toStringCoerce } from "./value.mjs";
import { Scope } from "./scope.mjs";

// Interpolation regex matches `{{…}}` blocks with minimal capture.
const INTERP_RE = /\{\{(.+?)\}\}/g;

// AST cache keyed by source string. `null` caches unparseable input
// so known-bad strings don't re-tokenize.
const AST_CACHE = new Map();

/**
 * Evaluate an expression string against a Scope. Returns a Value;
 * null/empty input yields mkNull().
 *
 * @param {string} source - the expression source
 * @param {Scope|object} scopeOrCtx - a Scope, or a plain dict that
 *   will be wrapped in a fresh Scope
 */
export function evaluate(source, scopeOrCtx) {
  if (!source || typeof source !== "string") return mkNull();
  const trimmed = source.trim();
  if (trimmed.length === 0) return mkNull();

  let ast;
  if (AST_CACHE.has(trimmed)) {
    ast = AST_CACHE.get(trimmed);
  } else {
    try {
      ast = parse(trimmed);
    } catch (e) {
      if (e instanceof ParseError) {
        if (isDebugEnabled()) {
          console.warn(`expr parse failed: ${JSON.stringify(trimmed)}: ${e.message}`);
        }
        ast = null;
      } else {
        throw e;
      }
    }
    AST_CACHE.set(trimmed, ast);
  }

  if (ast === null) return mkNull();

  const scope = scopeOrCtx instanceof Scope ? scopeOrCtx : new Scope(scopeOrCtx);
  try {
    const result = evalNode(ast, scope);
    if (result.kind === "null" && isDebugEnabled()) {
      console.debug(`expr null result: ${JSON.stringify(trimmed)}`);
    }
    return result;
  } catch (e) {
    if (isDebugEnabled()) {
      console.warn(`expr eval raised: ${JSON.stringify(trimmed)}: ${e.message}`);
    }
    return mkNull();
  }
}

/**
 * Evaluate a text string with embedded `{{…}}` expression regions.
 * Text outside the braces is literal. Each evaluated expression is
 * coerced to a string via `toStringCoerce`.
 */
export function evaluateText(text, scopeOrCtx) {
  if (!text || typeof text !== "string") return "";
  if (!text.includes("{{")) return text;
  const scope = scopeOrCtx instanceof Scope ? scopeOrCtx : new Scope(scopeOrCtx);
  return text.replace(INTERP_RE, (_, expr) =>
    toStringCoerce(evaluate(expr.trim(), scope))
  );
}

/**
 * Clear the AST cache. Useful between tests or when hot-reloading
 * YAML during development.
 */
export function clearCache() {
  AST_CACHE.clear();
}

// Debug-mode logging gated by the JAS_DEBUG_EXPR env var (Node) or a
// window.JAS_DEBUG_EXPR boolean (browser). Matches the gate used in
// the OCaml and Swift interpreters.
let _debugCached = null;
function isDebugEnabled() {
  if (_debugCached !== null) return _debugCached;
  if (typeof process !== "undefined" && process.env) {
    _debugCached = process.env.JAS_DEBUG_EXPR === "1";
    return _debugCached;
  }
  if (typeof globalThis !== "undefined" && globalThis.JAS_DEBUG_EXPR) {
    _debugCached = true;
    return true;
  }
  _debugCached = false;
  return false;
}
