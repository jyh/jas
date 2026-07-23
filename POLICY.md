# Project Policies

Authoritative policy document for the jas codebase (two active native
ports, a live Python reference interpreter, and two ports frozen at
the `five-port-parity` tag — see §1). When contributors, reviewers,
AI agents, or CI automation apply a policy, they cite this file.

Per-developer configs (like `.claude/CLAUDE.md`) may reference this
document; they should not restate it.

---

## 1. App equivalence and port status

**Port status (as of 2026-07-22, tag `five-port-parity`):**

| Component | Status | CI |
|---|---|---|
| `jas_dioxus` (Rust/Dioxus) | **Active** | blocking |
| `JasSwift` (Swift/AppKit) | **Active** | blocking |
| `workspace_interpreter/` (Python reference interpreter) | **Live reference** | blocking |
| `jas_ocaml` (OCaml/GTK) | **Frozen at the tag** | tag-pinned canary, non-blocking |
| `jas` (Python/Qt) | **Frozen at the tag** | tag-pinned canary, non-blocking |
| `jas_flask` (Python/Flask) | Non-gating reference renderer | non-blocking |

The four native apps were built as behaviorally identical peers of one
spec, and all four were at full parity at the `five-port-parity` tag.
From that point, active development continues in the Rust and Swift
ports; the OCaml port and the Python Qt app are preserved exactly as
tagged, with CI canary lanes that check out the tag (sources, fixtures,
and bundle together) so they can only fail on toolchain drift. Frozen
ports receive no new features; toolchain or security fixes only.

The **active** apps are **behaviorally identical** from the user's
perspective, modulo platform approximations documented in
`NATIVE_BOUNDARY.md`. Cross-language test fixtures in
`workspace/tests/` encode this invariant; every active interpreter must
produce identical output for the same input, and the Python reference
interpreter remains the executable definition of the spec's semantics.

---

## 2. Genericity — generic YAML preferred, native code discouraged

The Flask app is a thin, non-gating reference *renderer* of the shared
YAML/JSON artifacts — not the source of truth and not an interactive-parity
target (see `TESTING_STRATEGY.md` §6; the earlier "Flask is THE reference
implementation, develop Flask-first" charter is retired). It must still remain
generic: no jas-specific features baked into Flask code. All app-specific
features are declared through `workspace/*.yaml`.

All apps should use generic YAML-driven renderers wherever possible.
Native code is discouraged. The inventory of legitimate exceptions
lives in `NATIVE_BOUNDARY.md`.

### Dimensions this applies to

- Panel body rendering — via the YAML interpreter
- Panel labels — read from `panel.summary` in YAML, not hardcoded
- Panel menu items — declared in `workspace/panels/*.yaml:menu`
- Tool behavior — declared in `workspace/tools/*.yaml`
- Shortcuts, appearances, themes, actions, dialogs — all YAML

### Dimensions that remain native

Per `NATIVE_BOUNDARY.md`:

- Platform APIs (file dialogs, clipboard rich formats, IME)
- Performance kernels (path boolean, text layout, gradient compositing)
- Language infrastructure (error handling, concurrency, memory)
- Framework integration (Dioxus / SwiftUI / GTK / Qt widget factories)
- L2 domain primitives (element geometry types, SVG serialization)

### Enforcement

- **CI lint**: `scripts/genericity_check.py` runs on every PR; fails
  if the count of any native-code signature increases relative to
  `scripts/genericity_baseline.json`.
- **Per-review audit**: codebase reviews (§6) include a genericity
  compliance section.

---

## 3. Propagation order — one size does not fit all

Cross-language work has four canonical shapes; each has its own
preferred ordering.

### Adding a new feature

**Spec + conformance corpus → Rust → Swift.**

Author the generic spec (`workspace/*.yaml`) and its golden-pinned,
language-agnostic conformance corpus first, then propagate to the
most-developed native runtime (Rust), then Swift. The frozen ports
(§1) receive no feature propagation; Flask consumes the spec for
visual reference only and is not a propagation step. (The pre-freeze
order continued → OCaml → Python.)

### Removing native code in favor of YAML dispatch

**Pick the app where deletion is mechanically easiest first.**

Post-freeze this shape applies to the active apps only (no work, not
even deletions, lands in the frozen ports). Rationale: first port has
the most unknowns; the easier app validates the pattern.

### Cross-cutting bug fix

**Start where the bug was found** (the test fixture and repro live
there), then apply to the other active app — the fix is proven. A
frozen-port canary failure is a toolchain event, not a propagation
target.

### Schema / interpreter change

**Conformance corpus first** to pin the behavior (the Python reference
interpreter in `workspace_interpreter/` is the golden), then the active
natives (Rust, Swift) in any order — the shared fixture keeps them
aligned.

---

## 4. Test-first development

Write tests before writing code. Applies to all active surfaces (the
Rust and Swift apps, the reference interpreter, and the shared
spec/corpus).

Cross-language invariants go in `workspace/tests/` as YAML fixtures.
Language-specific unit tests go in each app's test directory.

---

## 5. Naming — product-agnostic framing

The Flask framework is generic across vector-illustration products,
so its code and docs avoid naming specific vendor products.

**Never** use "Adobe" or "Illustrator" in code, schema, or
documentation. Preferred term: "vector illustration application."
This applies to all 5 apps, all docs, all test fixtures.

---

## 6. Code-review process

When a reviewer runs a full codebase review (invoked by the user
asking to "review the codebase" or equivalent), the review evaluates:

- Clarity
- Maintainability
- Efficiency
- Complexity
- Safety
- Test coverage
- Pattern consistency
- Conformity with style conventions
- **Functional equivalence across languages**
- **Genericity policy compliance** (§2), referencing `NATIVE_BOUNDARY.md`

Review output ranks suggestions from high to low priority, numbered.
Each suggestion should be ready for a deep dive.

---

## 7. Language-specific rules

### OCaml: interface files required

(`jas_ocaml` is frozen per §1, so this rule now applies only to
toolchain-maintenance edits.) New `.ml` files require an accompanying
`.mli`. When making a substantive edit to an existing `.ml` that lacks
one, add a minimal `.mli` as part of the change.

Exception: concrete tool implementations in `lib/tools/*.ml` conform
to a shared interface and go through `tool_factory.ml`; they don't
need individual `.mli` files.

### Rust: per-item dead-code allows

In `jas_dioxus`, prefer per-item `#[allow(dead_code)]` with a one-line
comment explaining why, over module-wide `#![allow(dead_code)]`.
Reserve module-wide allows for modules where most items are
genuinely not-yet-wired (and note that at the top); don't reach for
it to silence a single warning.

---

## 8. Workspace YAML authoring

Workspace YAML specifications should include comprehensive,
human-readable English descriptions that fully describe the behavior.

Consumers of the schema (including future reviewers, translators, and
UI generators) rely on the descriptions to understand intent.

---

## Related documents

- `NATIVE_BOUNDARY.md` — catalog of legitimately-native code categories
- `FLASK_PARITY.md` — architectural analysis of Flask feature-parity
- `REVIEW_PLAN.md` — codebase-review backlog and status
- `ARCH.md` — high-level cross-language architecture
- `scripts/genericity_check.py` — CI lint implementation
- `scripts/genericity_baseline.json` — current count baseline
