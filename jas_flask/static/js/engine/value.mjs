// Value primitives for the workspace expression language (JS port).
//
// Mirrors `workspace_interpreter/expr_types.py`. Five interpreters now
// implement the same value model (Python, Rust, Swift, OCaml, and this
// JS one). Cross-language test fixtures (workspace/tests/expressions/)
// enforce parity.
//
// Kind is a string tag — avoids the overhead of JS class-per-variant
// and keeps values JSON-serializable for postMessage / structured-clone.

export const NULL = "null";
export const BOOL = "bool";
export const NUMBER = "number";
export const STRING = "string";
export const COLOR = "color";
export const LIST = "list";
export const PATH = "path";

// Construct a Value of a given kind.
export function mkNull() {
  return { kind: NULL, value: null };
}
export function mkBool(b) {
  return { kind: BOOL, value: !!b };
}
export function mkNumber(n) {
  if (typeof n !== "number" || Number.isNaN(n)) {
    throw new TypeError(`mkNumber: ${n} is not a valid number`);
  }
  return { kind: NUMBER, value: n };
}
export function mkString(s) {
  return { kind: STRING, value: String(s) };
}
export function mkColor(hex) {
  // Normalize to lowercased #rrggbb.
  let s = String(hex).toLowerCase();
  if (!s.startsWith("#")) s = "#" + s;
  if (s.length === 4) {
    // #rgb → #rrggbb
    s = "#" + s[1] + s[1] + s[2] + s[2] + s[3] + s[3];
  }
  return { kind: COLOR, value: s };
}
export function mkList(items) {
  return { kind: LIST, value: Array.from(items) };
}
export function mkPath(indices) {
  return { kind: PATH, value: indices.map((i) => i | 0) };
}

// Coerce a Value to a JS boolean (truthiness). Matches the Python
// implementation's `to_bool` semantics:
//   Null → false
//   Bool → itself
//   Number → nonzero
//   String → nonempty
//   Color → always true
//   List → nonempty
//   Path → nonempty
export function toBool(v) {
  if (v == null) return false;
  switch (v.kind) {
    case NULL: return false;
    case BOOL: return v.value;
    case NUMBER: return v.value !== 0;
    case STRING: return v.value.length > 0;
    case COLOR: return true;
    case LIST: return v.value.length > 0;
    case PATH: return v.value.length > 0;
    default: return false;
  }
}

// Coerce a Value to a JS string (for text interpolation / display).
export function toStringCoerce(v) {
  if (v == null) return "";
  switch (v.kind) {
    case NULL: return "";
    case BOOL: return v.value ? "true" : "false";
    case NUMBER:
      return Number.isInteger(v.value) ? String(v.value | 0) : String(v.value);
    case STRING: return v.value;
    case COLOR: return v.value;
    case LIST: return "[list]";
    case PATH: return v.value.join(".");
    default: return "";
  }
}

// Strict equality across values. Same-kind + same-value only; no
// coercion. Color comparison normalizes casing.
export function strictEq(a, b) {
  if (!a || !b) return false;
  if (a.kind !== b.kind) return false;
  switch (a.kind) {
    case NULL: return true;
    case BOOL:
    case NUMBER:
    case STRING:
      return a.value === b.value;
    case COLOR:
      return a.value.toLowerCase() === b.value.toLowerCase();
    case LIST:
      if (a.value.length !== b.value.length) return false;
      for (let i = 0; i < a.value.length; i++) {
        if (!strictEq(a.value[i], b.value[i])) return false;
      }
      return true;
    case PATH:
      if (a.value.length !== b.value.length) return false;
      for (let i = 0; i < a.value.length; i++) {
        if (a.value[i] !== b.value[i]) return false;
      }
      return true;
    default: return false;
  }
}

// Convert a plain JSON-like JS value into a Value. Used when bridging
// from serde_json / context objects into the expression-eval layer.
export function fromJson(j) {
  if (j == null) return mkNull();
  if (typeof j === "boolean") return mkBool(j);
  if (typeof j === "number") return mkNumber(j);
  if (typeof j === "string") {
    // Detect #rrggbb color syntax for parity with other interpreters.
    const m = j.match(/^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/);
    if (m) return mkColor(j);
    return mkString(j);
  }
  if (Array.isArray(j)) return mkList(j.map(fromJson));
  if (typeof j === "object") {
    // {__path__: [0,1,2]} round-trip marker (Phase 3 §6.2).
    if (Array.isArray(j.__path__)) return mkPath(j.__path__);
    // Fallback — treat as opaque list of key-value pairs. Other
    // interpreters stringify as "__dict__" marker; matching that.
    return mkString("__dict__");
  }
  return mkNull();
}

// Inverse of fromJson — round-trip a Value to a JSON-able primitive.
export function toJson(v) {
  if (v == null) return null;
  switch (v.kind) {
    case NULL: return null;
    case BOOL: return v.value;
    case NUMBER:
      return Number.isInteger(v.value) ? (v.value | 0) : v.value;
    case STRING: return v.value;
    case COLOR: return v.value;
    case LIST: return v.value.map(toJson);
    case PATH: return { __path__: v.value.slice() };
    default: return null;
  }
}
