# Project Policies

Authoritative policy document for the five-app jas codebase. When
contributors, reviewers, AI agents, or CI automation apply a policy,
they cite this file.

Per-developer configs (like `.claude/CLAUDE.md`) may reference this
document; they should not restate it.

---

## 1. App equivalence

The five apps — `jas` (Python/Qt), `jas_ocaml` (OCaml/GTK),
`jas_dioxus` (Rust/Dioxus), `JasSwift` (Swift/AppKit), and `jas_flask`
(Python/Flask) — are intended to be **behaviorally identical** from
the user's perspective, modulo platform approximations documented in
`NATIVE_BOUNDARY.md`.

Cross-language test fixtures in `workspace/tests/` encode this
invariant; every interpreter must produce identical output for the
same input.

---

## 2. Genericity — generic YAML preferred, native code discouraged

The Flask app is the reference implementation. It must remain generic:
no jas-specific features baked into Flask code. All app-specific
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

**Flask → Rust → Swift → OCaml → Python.**

Flask is the reference; propagate to the most-developed native
runtime first (Rust), then Swift, then OCaml, then Python (least
trafficked).

### Removing native code in favor of YAML dispatch

**Pick the app where deletion is mechanically easiest first.**

For panel menus and tool dispatchers, this is usually OCaml
(monolithic files) or Python (partial migration already exists); Swift
and Rust have per-panel / per-tool native files and are done later.

Rationale: first port has the most unknowns. Easier app validates the
pattern; later apps benefit from lessons learned.

### Cross-cutting bug fix

**Start where the bug was found** (the test fixture and repro live
there), then apply to all others in parallel — the fix is proven.

### Schema / interpreter change

**Flask first** to pin the behavior, natives in any order,
cross-language fixture added alongside so all 5 stay aligned.

---

## 4. Test-first development

Write tests before writing code. Applies to all 5 apps.

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

In `jas_ocaml`, new `.ml` files require an accompanying `.mli`. When
making a substantive edit to an existing `.ml` that lacks one, add a
minimal `.mli` as part of the change.

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
