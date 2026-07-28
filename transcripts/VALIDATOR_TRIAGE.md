# VALIDATOR TRIAGE — the strong JSON Schema path, turned on and refereed

**Phase:** the validator phase, part 1 of 3 (JYH ruled it its own phase,
2026-07-27: "better earlier than later"). Part 1 is DIAGNOSTIC. This document
is a referee's report, not a repair. Nothing in `schema/`, `workspace/`, or
`workspace_interpreter/validator.py` was changed.

**Base commit:** `a0d03b75` (public main; the Preservation Law wave).

**Coverage-gap row this discharges:** `validator-strong-schema-never-runs` in
`scripts/corpus_manifest.json`.

---

## 0. The headline

**Nothing falls out of the committed data.**

Every document the project validates passes the real `Draft202012Validator`
exactly as it passed the hand-rolled subset. 31 documents, 0 strong errors,
0 subset errors, 0 disagreeing documents — and the strong validator earned
that verdict by performing **2462 keyword assertions**, 290 of which
(`$ref`, `pattern`, `oneOf`, `minimum`, `exclusiveMinimum`) the subset checker
had never performed at all.

That is a good result and it is stated plainly. It is also a **narrow** one.
The findings below are all findings about the *instrument*, not the data, and
one of them bounds how much the headline is worth: **18 of the 25 top-level
sections of the workspace have no schema at all**, so "the schemas find
nothing" is a statement about 7 sections, not about the workspace.

---

## 1. Method

1. Measure the baseline with `jsonschema` absent (the historical state).
2. Install `jsonschema` in a way that can be switched on and off per command,
   so both validators can be run over identical inputs in the same session.
3. Re-run every lane that reaches the validator, plus the surrounding gates.
4. **Mutation-prove the diagnosis itself**: poison the strong branch and show
   the subset lane is unaffected (the strong branch was dead); neuter the
   subset and count what reds (how much the subset was actually gating).
5. Differentially compare the two validators three ways:
   - a **keyword census** of the five shipped schemas — which constructs are
     used, and which the subset does not implement (a hole even where the two
     currently agree);
   - a **mutation battery** — 50 single-point corruptions of the real
     committed documents, both validators run on each;
   - **48 isolated micro-schema probes** — one JSON Schema construct each,
     including constructs the shipped schemas do not use yet, to map the
     subset's behaviour as a whole rather than only where it is exercised
     today.

Harness scripts (scratchpad, not committed): `diffval.py` (census, metaschema
check, real documents, keyword tally, fixtures, mutation battery),
`valtriage_probe.py` (48 micro-probes), `valtriage_wide.py` (raw on-disk YAML,
full merged workspace, schema-coverage census), `valtriage_wiring.py` (how
`_validate_structural` builds the strong validator).

## 2. The install

`jsonschema` was **not** present: `importlib.util.find_spec('jsonschema')` →
`None` against `/Users/jyh/projects/claude/jas/.venv/bin/python3` (Python
3.11.15). `git log -S jsonschema --all` returns four commits, all of which are
`validator.py`'s own import guard or the corpus-manifest gap rows — **it has
never appeared in any requirements file or CI lane in the repository's
history**, back to `6e4c560b "Flask parity: schema infrastructure + tool schema
+ selection prototype"`, the commit that introduced `validator.py`.

Installed **out of tree**, so the maintainer's `.venv` is untouched and the
strong path can be toggled per command:

```
python3 -m pip install --target <scratchpad>/pylibs jsonschema
# -> jsonschema 4.26.0, jsonschema-specifications 2025.9.1,
#    referencing 0.37.0, rpds-py 2026.6.3, attrs 26.1.0, typing_extensions 4.16.0
```

Strong path on:  `PYTHONPATH=<scratchpad>/pylibs python3 …`
Strong path off: the same command with `PYTHONPATH` unset.

## 3. Every lane, with numbers

### 3a. Lanes that actually reach the validator

Grepped: `validate_workspace` has exactly two callers —
`workspace_interpreter/compile.py` and `workspace_interpreter/tests/test_validator.py`.
So the validator's entire blast radius is `scripts/check_workspace_json.sh`
(which invokes `compile`) and the `workspace_interpreter` pytest lane.

| lane | subset (historical) | strong (now) |
|---|---|---|
| `python3 -m pytest workspace_interpreter/ -q` | 1264 passed | **1264 passed** |
| `bash scripts/check_workspace_json.sh` | up to date, exit 0 | **up to date, exit 0** |

### 3b. The rest of the `workspace-json-fresh` CI lane, strong validator active

All green, unchanged: `check_menu_structure` OK; `check_toolbar_structure` OK
(13 slots, 29 tools); `check_action_refs` OK (256 references, 237 known
actions, 21 baselined no-ops); `check_panel_goldens.sh` up to date;
`check_path_b_exclusions` OK (5 panels); `check_intent_map.sh` up to date
(self-test: 236 actions, 24 journaling, 26+3+11 verb table, 36/45 doc.* split);
`check_preservation_corpus` OK (12 vectors); `check_corpus_manifest` OK.

### 3c. Baselines re-measured on the base commit (all match the brief)

| gate | measured |
|---|---|
| `cd jas_dioxus && cargo test --lib` | 2726 passed / 0 failed / 18 ignored |
| `cd JasSwift && swift test` | 2726 tests in 17 suites passed |
| `python3 -m pytest workspace_interpreter/ -q` | 1264 passed |
| `python3 scripts/cross_language_algorithms.py --lang rust,swift` | 849 passed, 0 failed, 24 algorithms |
| `python3 scripts/cross_language_commutativity.py --lang rust,swift` | 56 passed, 0 failed |
| `python3 scripts/check_corpus_manifest.py` | 26 families / 454 files / 27 coverage gaps |
| `python3 scripts/check_naming_rule.py` | OK, 1342 tracked text files |
| `cd jas_flask && python3 -m pytest tests/ -q` | 325 passed (identical with the strong path; `jas_flask` never calls `validate_workspace`) |

### 3d. Documents examined by the strong validator

| document set | count | strong errors |
|---|---|---|
| merged workspace, as `validate_workspace` feeds it (app + 27 tools + elements + preferences + features) | 31 | **0** |
| raw on-disk `workspace/tools/*.yaml`, validated directly (bypassing the loader) | 27 | **0** |
| compiled `workspace/workspace.json`, same five schemas | 31 | **0** |
| `app.schema.json` against the *full* merged workspace dict, not the 3-key slice | 1 | **0** |
| the 13 synthetic fixtures inside `tests/test_validator.py` | 13 | 6 (all intentional; see F1) |
| the 5 schema files against the 2020-12 **metaschema** (`check_schema`) | 5 | **0 — all five are valid JSON Schema** |

Loader check: for all 27 tools, `set(merged) == set(raw)` — the loader passes
tool dicts through key-for-key, so validating the merged dict and validating
the authored file are the same act.

## 4. Proof the diagnosis is real (mutation-proved, both directions)

**Probe 1 — was the strong branch dead?** Inserted
`raise AssertionError("MUTATION PROBE: strong jsonschema branch entered")` as
the first statement inside `if jsonschema is not None:`.

- `PYTHONPATH` unset → `1264 passed` (**unchanged**). The branch is never
  entered; it is dead code on any machine without `jsonschema`.
- `PYTHONPATH` set → `17 failed, 1247 passed`, and
  `check_workspace_json.sh` tracebacks at `validator.py:77`.

So exactly **17** of 1264 tests traverse `_validate_structural`, and before
this session **all 17 of them took the subset branch**, always, everywhere.

**Probe 2 — how much was the subset actually gating?** Replaced
`_validate_minimal`'s body with `return []`.

- `PYTHONPATH` unset → `6 failed, 1258 passed`. Those six —
  `test_app_missing_name`, `test_tool_missing_id`, `test_tool_missing_handlers`,
  `test_tool_unknown_handler_key`, `test_tool_state_requires_default`,
  `test_error_accumulation` — are the **entire** observable gate strength of
  structural validation in this repository.
- `PYTHONPATH` set → `1264 passed`. With `jsonschema` present the subset is
  fully dead code.

Both probes were reverted; `git diff workspace_interpreter/validator.py` is
empty.

## 5. FINDINGS

Each is stated as a question for JYH, not a decision. F1–F2 are defects with
an owner; F3–F7 are the differential itself; F8–F10 are instrument-wiring and
scope; F11–F12 are vacuity notes.

---

### F1 — the one test that would have caught the `pattern` hole asserts nothing
`workspace_interpreter/tests/test_validator.py:43-49`,
`TestAppStructural::test_schema_version_format`. It builds
`{"app": {"name": "T"}, "schema_version": "not-a-version"}`, computes `errs`,
comments *"The minimal validator doesn't enforce pattern, but jsonschema
does"*, and then executes `_ = errs`. **It asserts nothing.**

Measured: strong = 1 error
(`schema_version: 'not-a-version' does not match '^[0-9]+\.[0-9]+$'`),
subset = 0. This is the **only** disagreement between the two validators
anywhere in the existing test suite, and the test that names it is a no-op.

**Schema or data?** Neither — a **test** defect. The schema is right and the
fixture is deliberately bad. The ruling needed: should this test now assert
`len(errs) == 1`? Doing so makes `jsonschema` a hard dependency of the test
suite, which is precisely the part-2 question, so it is banked, not fixed.

---

### F2 — `_validate_minimal`'s docstring claims a check it does not implement
`validator.py:87-90` — *"Handles `type`, `required`, `additionalProperties`,
`enum`, and `pattern`."* Body audit: `type`, `required`,
`additionalProperties`, `enum` all appear; **`pattern` appears nowhere in the
function.** 7 `pattern` occurrences in the shipped schemas; 51 applications
over the committed workspace; the subset performs none of them.

**Schema or data?** Neither — a **documentation** defect in the fallback. Fix
the docstring or fix the code is exactly part 2's question.

---

### F3 — the subset ignores 6 of the 12 assertion keywords the shipped schemas use

Keyword census over `schema/*.schema.json` (occurrences in the schema files;
applications = times the strong validator actually invoked the keyword against
the committed workspace):

| keyword | occurrences | applications | subset |
|---|---:|---:|---|
| `type` | 79 | 1152 | PARTIAL — only `object`/`array`/`string`/`integer` branches exist |
| `additionalProperties` | 25 | 327 | PARTIAL — only inside `type: object` |
| `properties` | 21 | 300 | PARTIAL — only inside `type: object` |
| `required` | 9 | 240 | PARTIAL — only inside `type: object` |
| `$ref` | 13 | 171 | **IGNORED** |
| `items` | 3 | 152 | PARTIAL — only inside `type: array`, and only when `items` is an object |
| `pattern` | 7 | 51 | **IGNORED** |
| `oneOf` | 5 | 50 | **IGNORED** |
| `minimum` | 10 | 17 | **IGNORED** |
| `enum` | 2 | 1 | PARTIAL — only inside `type: string` |
| `exclusiveMinimum` | 1 | 1 | **IGNORED** |
| `$defs` | 2 | n/a | **IGNORED** (targets unreachable without `$ref`) |

**290 of the 2462 keyword assertions (11.8%) the strong validator performs
over the committed workspace are invisible to the subset.** Where the `$ref`s
point matters more than the raw count: all 10 `handlers/on_*` values and all 3
`elements` style slots are behind a `$ref`, so under the subset the **entire
effect-list body of every tool handler and every element's fill/stroke/font is
unchecked**.

**Schema or data?** Neither — an **instrument** finding, and the core of the
part-2 decision.

---

### F4 — every keyword the subset *does* implement is gated behind a matching `type`

`_validate_minimal` dispatches on `schema.get("type")` and does nothing at all
when `type` is absent or is `number`/`boolean`/`null`/an array. Consequences,
each measured (§ micro-probes):

- `{"required": [...], "properties": {...}}` with no `type: object` → subset
  checks **nothing**; strong reports the missing property.
- `{"additionalProperties": false, ...}` with no `type: object` → subset
  accepts unknown fields.
- `{"items": {...}}` with no `type: array` → subset never descends.
- `{"type": "boolean"}` given `"yes"` → subset silent.
- `{"type": "number"}` given `"x"` → subset silent.
- `{"type": ["string","null"]}` given `3` → subset silent.
- `{"type": "integer", "enum": [1,2,3]}` given `9` → subset silent
  (`enum` is checked only in the `string` branch).

This is why the shipped `preferences.schema.json` is largely unenforced under
the subset: nine of its leaf constraints are `boolean` or `number` typed.

---

### F5 — mutation battery: 34 of 50 realistic corruptions are invisible to the subset

50 single-point corruptions of the **real committed documents** (richest tool =
`partial_selection.yaml`). Result: **16 caught by both, 34 caught only by the
strong validator, 0 caught only by the subset.** The 34:

*tool schema (14)* — `id: "Bad-Id"`; `id: "9tool"`; `tool_options_dialog`,
`tool_options_panel`, `tool_options_action` each violating `^[a-z][a-z0-9_]*$`;
`tool_options_dialog_on_alt_click: "yes"` (string for a boolean); a handler
whose value is a string instead of an effect list; effect-list items that are
ints; an effect-list item that is a list; and **all six overlay corruptions** —
unknown key, missing `render`, `if` as an int, `render` as a string, a list
entry missing `render`, and `overlay` as a bare string.

*elements schema (7)* — `fill: "red"`; `fill: "#ff00"`; `fill: 3`;
`stroke.color: "blue"`; `stroke.width: -5`; `stroke.width: "thick"`;
`font: {family: 3, size: -1}`.

*preferences schema (9)* — `autosave.enabled: "yes"`;
`autosave.interval_seconds: 0`; `units.show_in_panels: 1`;
`grid.spacing_px: -3`; `grid.subdivisions: 0`; `viewport.zoom_step: 0.5`;
`viewport.scrubby_zoom_gain: 0`; `viewport.scrubby_zoom: "on"`;
`smart_guides.snap_threshold_px: -1`.

*app schema (1)* — `schema_version: "two-point-oh"`.

*features schema (3)* — `available: 3`; `available: []`; (plus overlap above).

The 16 the subset does catch are all missing-required, unknown-field, or
object/array/string/integer type errors — exactly its documented reach.

**Schema or data?** Neither: these are synthetic. Their value is that they
name, concretely, what "validation passes" has meant historically.

---

### F6 — the subset is *stricter* than JSON Schema in two places (false positives)

Both directions matter: turning the strong path on **relaxes** these.

**(a) `type: integer` given an integral float.** JSON Schema 2020-12 says
`2.0` **is** an integer. The subset's `isinstance(doc, int)` rejects it.
Measured: strong = 0 errors, subset = 1 (`expected integer, got float`).

Live consequence: `app.window.width`, `height`, `min_width`, `min_height`,
`version`, and `preferences.grid.subdivisions` /
`preferences.autosave.interval_seconds` are `integer`-typed. Authoring
`width: 1200.0` in YAML is **rejected today and accepted after the switch**.
Nothing in the workspace does this now (0 errors either way), so no fixture
moves — but it is a real semantic change.

> **QUESTION FOR JYH.** Is JSON Schema's integral-float rule the meaning we
> want, or does the project want "integer" to mean "a YAML integer"? If the
> latter, the *schema* has to say so (there is no 2020-12 keyword for it —
> it would need a project-level lint), which makes this a schema question, not
> a data one. Banked, not decided.

**(b) `patternProperties` + `additionalProperties: false`.** The subset does
not know about `patternProperties`, so it reports `unknown field` for keys a
pattern legally covers. Measured: strong = 0, subset = 1. **Latent** — no
shipped schema uses `patternProperties`. It becomes live the moment one does.

---

### F7 — the subset **crashes** on boolean subschemas

`{"type": "object", "properties": {"a": true}}` and `{"…": {"a": false}}` are
legal JSON Schema. `_validate_minimal` calls `schema.get("type")` on the
boolean and raises `AttributeError: 'bool' object has no attribute 'get'` —
an **unhandled exception escaping `validate_workspace`**, not a validation
error. Strong: `False schema does not allow 1` / clean, respectively.

**Latent** — no shipped schema uses boolean subschemas. But it means the
fallback is not merely weaker than JSON Schema, it is **not total** over
JSON Schema: a legal schema edit can turn `compile` into a traceback.

**Schema or data?** Neither — a **defect in `_validate_minimal`**. Part 2.

---

### F8 — how `_validate_structural` builds the strong validator (four gaps)

`validator.py:78` is `jsonschema.Draft202012Validator(schema)` — nothing else.

**(a) No `check_schema()`.** A malformed schema is not diagnosed. Measured:
`{"type": "objct"}` → strong **raises `UnknownType` uncaught**; subset returns
`[]` silently. So the switch converts one class of schema typo from *silence*
to *CI traceback*. All five shipped schemas pass `check_schema` today
(verified), so this reds nothing now.

> **QUESTION FOR JYH.** Should `_validate_structural` call `check_schema` and
> report a malformed schema as a validation error with a file name, rather
> than letting `jsonschema` raise through `compile`? That is a change to
> `validator.py`, which part 1 may not make.

**(b) No `format_checker`.** `format` is annotation-only unless a checker is
passed. Measured: `{"type":"string","format":"uri"}` given `"not a uri"` →
0 errors **as wired**, and still 0 errors **with `FORMAT_CHECKER`** (the `uri`
checker needs the `rfc3987` extra). So `format` is unenforced on **both**
paths. No shipped schema uses `format`; recorded so nobody later assumes it
works.

**(c) Cross-file `$ref` would raise.** The `$id`s are `https://jas/schema/*.schema.json`
— not resolvable. Measured: a `$ref: "tool.schema.json"` →
`_WrappedReferencingError: Unresolvable: tool.schema.json` uncaught; the
subset returns `[]`. Latent: today every `$ref` is an internal `#/$defs/…`.
Making the five schemas compose (a natural next step once panels/dialogs get
schemas) requires a `referencing.Registry`.

**(d) A typo'd keyword *name* is invisible to BOTH.** `{"requried": ["a"]}` →
strong 0, subset 0, and `check_schema` **passes** — JSON Schema treats unknown
keywords as annotations. Turning on the strong validator does not fix this
class. It needs a schema lint (an allow-list of keywords), which is neither
validator.

---

### F9 — 18 of the 25 top-level workspace sections have no schema at all

Schema-covered: `app`, `version`, `schema_version`, `tools`, `elements`,
`preferences`, `features`.

**Uncovered:** `actions`, `brush_libraries`, `concepts`, `default_layouts`,
`dialogs`, `gradient_libraries`, `icons`, `layout`, `lexical_contexts`,
`menubar`, `native_intercepts`, `panels`, `runtime_contexts`, `shortcuts`,
`state`, `swatch_libraries`, `templates`, `theme`.

This bounds the headline. Which validator runs is a smaller question than what
either one is pointed at.

> **QUESTION FOR JYH.** Does schema coverage for the uncovered 18 belong in
> the validator phase (part 2/3), or is it its own stone? Note that several of
> them already have bespoke Python gates (`check_menu_structure`,
> `check_toolbar_structure`, `check_action_refs`) — so the question is partly
> "schema or hand-written gate", which is a design fork, not a chore.

---

### F10 — `validator.py`'s module docstring is stale in two ways

`validator.py:17-19`: *"Current coverage: structural only for `app` and
`tools`."* It has covered `elements`, `preferences`, and `features` as well
since they were added — 5 schemas, not 2.

`validator.py:136-138` lists the callers of `validate_workspace` as
`workspace_interpreter.compile` **and** *"Flask dev-mode hot-reload — renders
errors inline in browser"*. Grepped: `validate_workspace` appears nowhere in
`jas_flask/`. **The second documented caller does not exist.** (`jas_flask` is
non-gating and must not be edited; this is a note about the docstring, which
is in the live reference interpreter.)

---

### F11 — micro-probe sweep: 48 constructs, 4 agreements

Isolated one-construct probes, including constructs the shipped schemas do not
use yet (a hole is a hole before it is stepped in):

**48 probes → 4 agree, 40 subset-blind holes, 2 subset false positives,
2 subset crashes.**

The four agreements are `type: integer` given `2.5`; `type: number` given `3`;
`format: uri` (inert on both); and explicit `additionalProperties: true`.

Complete list of JSON Schema 2020-12 constructs `_validate_minimal` **does not
implement**, measured blind:

`minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf`,
`pattern`, `minLength`, `maxLength`, `minItems`, `maxItems`, `uniqueItems`,
`contains`, `prefixItems`, `minProperties`, `maxProperties`, `propertyNames`,
`patternProperties`, `dependentRequired`, `dependentSchemas`,
`unevaluatedItems`/`unevaluatedProperties`, `allOf`, `anyOf`, `oneOf`, `not`,
`if`/`then`/`else`, `const`, `$ref`, `$defs`, `format`, boolean subschemas,
`type` values `number`/`boolean`/`null`, `type` as an array, `enum` outside
the string branch, `required`/`properties`/`additionalProperties`/`items`
without a matching sibling `type`, and draft-07 tuple-form `items` (which is
in fact **not valid** 2020-12 — the strong validator rejects the schema, the
subset would have silently accepted it).

---

### F12 — two vacuity notes on what the subset *does* check

- **`enum` fires exactly once** over the entire committed workspace
  (`preferences.units.default`). The other `enum` in the schemas is
  `tool.platform.items`, and **no shipped tool declares `platform`** — so the
  one construct the subset implements beyond raw structure is essentially
  untouched by real data.
- `check_schema` on all five schemas passes, so the corpus of schemas is
  itself well-formed; the strong validator is not going to red on schema
  malformation today.

---

## 6. Differential comparison table (summary)

| comparison | inputs | strong-only | subset-only | both | crashes |
|---|---:|---:|---:|---:|---:|
| committed documents (`validate_workspace`'s own feed) | 31 | 0 | 0 | 0 errors either way | 0 |
| raw on-disk tool YAML | 27 | 0 | 0 | 0 | 0 |
| compiled `workspace.json` | 31 | 0 | 0 | 0 | 0 |
| existing unit-test fixtures | 13 | **1** (F1) | 0 | 6 | 0 |
| mutation battery on real documents | 50 | **34** | 0 | 16 | 0 |
| isolated micro-schema probes | 48 | **40** | **2** | 4 | **2** |

Read the first three rows as the good news and the last three as the price of
the fallback: over real data the two validators are indistinguishable; over
*wrong* data they are not remotely the same instrument.

## 7. The one change committed

Per the phase's terms, the only permitted edit is making the strong path
installable, and only if it reds nothing.

1. `requirements.txt` — added `jsonschema` (with a comment pointing here).
   This is what the `workspace-interpreter` CI lane installs
   (`pip install -r requirements.txt`). **Verified: 1264 passed, unchanged.**
2. `.github/workflows/test.yml`, `workspace-json-fresh` lane — `pip install
   PyYAML` → `pip install PyYAML jsonschema`. This lane runs
   `check_workspace_json.sh`, the only CI step outside pytest that reaches the
   validator. **Verified: every step of that lane green with the strong
   validator active** (§3b).

Deliberately **not** changed:
- the five other `pip install PyYAML` lanes (`expr-corpus-fresh` and the four
  `concept-*-corpus-fresh` jobs) — they compile corpora via
  `scripts/compile_*_corpus.py`, never the workspace, and never reach the
  validator;
- `jas_flask/requirements.txt` — `jas_flask` never calls `validate_workspace`
  (F10), and flask is non-gating and not to be edited;
- the `python-canary` and `ocaml-canary` lanes — they check out the
  `five-port-parity` tag, so they read the tag's `requirements.txt`; a HEAD
  edit cannot reach them.

The dependency is **unpinned**, matching the rest of `requirements.txt`
(nothing in it is pinned). Whether the project's one *behaviour-defining*
dependency should be the one exception is a part-2/3 question — banked below.

## 8. Questions banked for JYH (no rulings invented)

1. **F1** — should `test_schema_version_format` assert the strong behaviour?
   Doing so makes `jsonschema` a hard test dependency, which pre-empts part 2.
2. **F6(a)** — JSON Schema says an integral float *is* an integer; the subset
   says otherwise. Which meaning does the project want, and if it wants the
   stricter one, where does that live given 2020-12 cannot express it?
3. **F8(a)** — should `_validate_structural` call `check_schema` so a
   malformed schema is a named validation error instead of a raised
   `UnknownType`?
4. **F8(d)** — a typo'd *keyword name* is invisible to both validators and to
   `check_schema`. Does the project want a keyword allow-list lint over
   `schema/*.schema.json`? That is a third instrument, not a choice between
   the two.
5. **F9** — do the 18 unschema'd top-level sections belong to this phase, and
   for the ones that already have bespoke Python gates, is the answer "schema"
   or "keep the gate"?
6. **§7** — pin `jsonschema`, or leave it unpinned like everything else?

## 9. Blind spots — what this triage did NOT establish

- **Scope.** Only the 5 shipped schemas and the documents `validate_workspace`
  feeds them were compared. **F9's 18 uncovered sections were not validated by
  anything**, so "nothing falls out" says nothing whatsoever about `actions`,
  `panels`, `dialogs`, `menubar`, `state`, `theme`, or the eleven others.
- **The mutation battery is hand-authored** (50 mutations) and the micro-probe
  sweep is hand-enumerated (48 constructs). Neither is exhaustive over JSON
  Schema. **Absence of a disagreement in a construct I did not probe is not
  evidence of agreement.** In particular I did not fuzz — no randomized
  document generation, no property-based comparison of the two validators.
- **One toolchain.** jsonschema 4.26.0, Python 3.11.15, macOS/arm64. CI runs
  Python 3.12 on ubuntu/macos, and the dependency is unpinned. A future
  jsonschema release changing a message, a default, or a keyword's strictness
  is **not** covered by anything I measured; the strong path is now a moving
  target that no gate pins.
- **`cross_language_workspace.py` was not executed** (it needs a full
  `cargo build --bins` + `swift build`). I established by grep that it does
  not import the validator and concluded it is out of scope — that conclusion
  rests on a grep, not on a run.
- **The frozen ports were not run.** `jas/` and `jas_ocaml/` canary lanes
  check out the `five-port-parity` tag, so my `requirements.txt` edit provably
  cannot reach them by construction — but I did not execute those lanes to
  demonstrate it.
- **YAML typing was not varied.** The `integer`-vs-integral-float divergence
  (F6a) depends on what PyYAML hands back; I measured one PyYAML version.
- **The micro-probes call `_validate_minimal` directly** with synthetic
  in-memory schemas, whereas production reaches it through
  `_validate_structural`, which loads schemas from `schema/`. The calling
  convention is identical (`path=""`), but the probes never exercise
  `_load_schema`.
- **This is a triage, not a repair.** The class is **OPEN**. Part 1 answers
  "what falls out of the *data*" (nothing) and "how far apart are the two
  validators" (very far, off the happy path). It does not answer whether the
  fallback should live, which is part 2, nor which validator is authoritative,
  which is part 3.
