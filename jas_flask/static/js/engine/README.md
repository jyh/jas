# jas_flask/static/js/engine/

JS port of the workspace expression interpreter. The fifth
implementation alongside Python / Rust / Swift / OCaml. Cross-language
test fixtures in `workspace/tests/expressions.yaml` etc. enforce parity.

## Module layout

- **`value.mjs`** — Value primitives (`{kind, value}` tagged objects):
  Null, Bool, Number, String, Color, List, Path. Plus `toBool`,
  `toStringCoerce`, `strictEq`, `fromJson`, `toJson`.
- **`scope.mjs`** — Scope wrapper over the top-level namespace map
  (state / panel / tool / event / platform / features / config /
  param). `resolvePath(segments)` for dotted access.
- **`lexer.mjs`** — Tokenizer producing `{kind, value}` tokens with
  string-constant kinds. Mirrors `workspace_interpreter/expr_lexer.py`.
- **`parser.mjs`** — Recursive-descent parser producing plain-object
  AST nodes. Mirrors `workspace_interpreter/expr_parser.py`.
- **`evaluator.mjs`** — Tree-walking evaluator. Exports `evalNode(ast,
  scope)` plus a `PRIMITIVES` registry of built-in functions.
- **`expr.mjs`** — Public API: `evaluate(source, scope)`,
  `evaluateText(text, scope)`, `clearCache()`. Caches parsed ASTs
  per source string.

## Usage

```js
import { evaluate } from "./engine/expr.mjs";
import { buildHandlerScope } from "./engine/scope.mjs";

const scope = buildHandlerScope({
  event: { x: 100, y: 50, modifiers: { shift: true } },
  tool: { selection: { mode: "idle" } },
});

const v = evaluate('tool.selection.mode == "idle"', scope);
// v === { kind: "bool", value: true }
```

## Testing

Uses Node's built-in test runner (no framework dep). Run:

```
node --test jas_flask/tests/js/test_value.mjs \
           jas_flask/tests/js/test_scope.mjs \
           jas_flask/tests/js/test_lexer.mjs \
           jas_flask/tests/js/test_parser.mjs \
           jas_flask/tests/js/test_evaluator.mjs
```

## Current scope limitations

Implemented: literals, paths, function calls with built-in primitives,
dot/index access, binary/unary operators, logical short-circuit,
ternary, let, sequence. The existing suite is a subset — Python
fidelity for closures (`Lambda`), lexical `Assign` via `<-`, and the
full color-decomposition primitive family (`hsb_h`, `cmyk_c`, etc.)
lands as needed.

Debug mode: set `JAS_DEBUG_EXPR=1` (Node) or
`window.JAS_DEBUG_EXPR = true` (browser) to log parse failures and
null-result expressions — same gate used by the OCaml and Swift
interpreters.
