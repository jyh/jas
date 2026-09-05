# Vision — Product & Architecture North Star

This is the durable statement of **where the application is going and why**. It is a
living document: it will change as we learn.

- **`VISION.md` (this file)** — the destination and the architecture that gets us there.
- **`ARCH.md`** — the architecture *as built today*. It currently describes a tree-path,
  immutable-document MVC across the native apps. As the foundations below land, `ARCH.md`
  must be updated to match; where this document and `ARCH.md` disagree, `ARCH.md` is the
  present and this document is the intent.
- Raw vision notes live in `transcripts/AI.md`.

A naming note that applies everywhere: we call this a **vector illustration application**.
We never name a specific commercial product, in code, schema, docs, or fixtures.

---

## 1. The soul: help the artist

We are building a vector illustration application that keeps the ideas artists love about
the classic tools and goes far beyond them. Everything serves one goal:

> **Shorten the distance between what is in the artist's head and what appears on the
> canvas — and keep them in flow while they close it.**

Every beloved feature of the classic tools is really this idea repeated: the Bézier pen
shrank the gap for curves; compound/pathfinder shapes shrank it for complex forms; live
corners shrank it for adjustment. So the test for *anything* — a feature, a fix, a piece of
"more" — is:

> **Does this shrink intention→result, or does it just add surface?**

Alongside it, two non-negotiables of feel: the tool stays **out of the way** (flow:
speed, directness, predictability), and the artist is **fearless** (everything is
reversible; nothing is ever permanent).

---

## 2. The pillars of "more"

1. **Liveness everywhere, by design.** Non-destructive and parametric from the ground up —
   not bolted on. Every shape stays editable back to its intent, forever.
2. **The tool understands intent.** Not generating art *for* the artist, but assisting:
   cleaning and snapping paths, helping with color, and — crucially — understanding
   *semantic relationships*: drag a block and its connectors follow; move one eye and the
   other mirrors; re-pose a standing figure to reach for a flower; change a hand-drawn
   gear's tooth count in one step while keeping technical precision.
3. **Retroactive structuring.** The artist never pre-thinks structure. They draw freely,
   then *declare or infer* meaning late ("this is a gear", "make the teeth editable"),
   non-destructively. We already do this for one case — selecting shapes and combining them
   into a live, releasable compound shape; the vision generalizes that single proven pattern
   to every concept.
4. **Multiple simultaneous interpretations.** The same marks can be *at once* a greeting, a
   tree, and part of a face — overlapping, at different semantic levels. The artist edits
   through one **lens** at a time while the tool keeps the others coherent (or flags an
   honest conflict).
5. **Gestural, conversational flow.** Brainstorm speed with print-ready, CAD-grade output.
   A conversation between the hand and the machine — "Claude Code, but for drawing", where
   traditional skills (sketching, drawing, painting) stay primary and the tool *knows* what
   is being made and helps bring it to life.
6. **Breadth across project types.** Portrait, animation, brochure (professional type and
   print), technical drawing (transmission gears), technical diagram (an architecture
   diagram), and more — each with a short concept→creation distance, fast revisions, liveness
   everywhere, and deep technical control without the burden of constant tool/panel switching.

---

## 3. The engineering values (non-negotiable)

- **Equivalence by spec, exactly.** Built as five implementations — `jas_flask` (the generic
  reference renderer), `jas_dioxus` (Rust), `JasSwift` (Swift), `jas_ocaml` (OCaml), `jas`
  (Python) — all equivalent at the `five-port-parity` tag; the live enforcement now spans the
  active ports (Rust, Swift) plus the `workspace_interpreter/` reference, with the frozen
  ports preserved at the tag (`POLICY.md` §1). "Exactly the same" means **same observable
  semantics** — same element tree, same state transitions, same resolved widget/element
  properties, same algorithm results — **not same pixels** (platforms render differently,
  and that is correct).
- **Minimize manual testing** — it is the most expensive part of development.
- **A common specification** — behavior is expressed once, in `workspace/*.yaml`, and
  interpreted by all apps. Native code is discouraged.
- **High performance, scalable to massive drawings** (we expect 100k–1M elements eventually).
- **Clean, factored code** following good software-engineering practice, in all languages.
- **Built to grow and change** — features will be added and reworked continuously.

---

## 4. The central reconciliation

The most important idea in this document:

> **Equivalence (five identical apps) and the AI-assisted vision are not in tension. They are
> the same architecture, seen twice.** Every abstraction we build to keep the five apps
> identical is exactly the abstraction an agentic AI needs; every layer we build for the
> artist is what we pin for equivalence. There is one road, not a fork.

Two corollaries:

- **Don't chase features; pin the interpreter.** A feature is `workspace/*.yaml` interpreted
  by a thin engine. Pin the handful of interpreter layers with shared, CI-gating conformance
  tests, and every feature built on them is identical *by construction*.
- **A gate is only worth having if it runs, fails loudly, and is watched.** (The cross-language
  algorithm harness silently sat dead-but-green in CI for seven weeks; see the
  near-term backlog in §11.)

**And a line drawn across that road, not a turn off it — ruled 2026-09-03.** *The framework
stays open; once AI-supported features are added, the **product** becomes proprietary.* The
operation API and canvas perception — the hooks a model calls — are framework and stay in
this repository, together with the journal, the corpora, the interpreter and every app. The
assistant that calls them, its practised moves, and the *contents* of the intent ledger are
proprietary and live in a **private fork**, never a directory inside this tree. The intent
ledger splits at the same seam: its **schema is open**, so a third party can write their own
assistant against it, while the **reasoning it records is proprietary**.

This changes nothing about the architecture above — that is the point of recording it here.
One road still, and everything §4 says about equivalence and the AI vision being the same
architecture seen twice holds on both sides of the line. What it changes is *where code
lands*, and it is written into the vision because the vision is where a reader looks to find
out what this project is.

---

## 5. The architecture, converged

The ten design directions (§6) reduce to a small set of compounding foundations. Each pays
off for many goals at once.

1. **A deterministic core with one operation vocabulary.** The action/effect vocabulary (the
   `workspace/actions.yaml` operations) is the *single* way the document changes. The AI, a
   gesture, a panel, and a future collaborator are all just *producers* of the same
   operations. No privileged mutation path.
2. **Stable element identity + a live dependency graph — the keystone.** *(Foundation SHIPPED
   2026-06; see §6.2.)* Identity is now path **and** id: the tree-path stays the UI address,
   and an additive `common.id` is the stable "which element" handle. Liveness is no longer only
   *containment*-based — a `Reference` element names its inputs by id, giving **reference-based,
   many-to-many** edges and a true dependency graph with incremental + cached recompute. This
   one change unlocks liveness, cross-tree relationships, multiple interpretations, versioning,
   comments, and collaboration — most of which (everything past the graph itself) remain to be
   built on top of the now-laid foundation.
3. **Concepts as declarative data packs.** A concept (gear, eye, connector, hatch, …) is
   *data*, not native code: a **fitter** (raw selection → parameters/roles — the "promote"
   that is the dual of today's `release`/`expand`), a **generator** (parameters → geometry),
   **operations** (its edit verbs), and **constraints** (its invariants). This is the same
   native→data migration already proven for tools.
4. **One seam, reused three times: native capture / shared semantics / pinned-at-the-boundary.**
   Interaction (native gesture recognition → normalized event → shared handler), rendering
   (shared cull/LOD decisions → native paint), and AI (canonical perception → shared plan →
   native-agnostic execution) all use the same boundary. Pin the normalized middle; let the
   edges be native.
5. **The operation log is the spine.** *(Foundation SHIPPED 2026-06, all four native apps;
   see §10 item 2 / `OP_LOG.md`.)* The transaction history is simultaneously undo/redo,
   the replay-test fixtures, the AI's action surface, and the versioning/collaboration
   substrate. Versioning, comments, collaboration, and the AI are all "history and
   participants over an identified, operation-based document."
6. **Two testing regimes** (see §9) that triple as the equivalence guarantee, the enabler of
   safe incremental optimization, and the mechanism that *deletes* manual testing.
7. **"Keep-it-ready" deferrals.** Two large axes — **animation** (time as a graph input) and
   **collaboration** (mergeable operations) — are not built now, but the core is kept ready
   for them (cheap now, expensive to retrofit). See §6.8 and §6.9.
8. **Artist primacy as an enforced, tested invariant** (§6.10) — not a guideline.

The recurring shape: **the document is always a *source description evaluated against a
context*, never a baked snapshot.** That single discipline is what makes liveness,
time-readiness, and equivalence all possible.

---

## 6. The ten design directions

Each is summarized with its idea, where we stand today (grounded in the code), the benefit,
and the honest downside/dependency.

### 6.1 Deterministic core + advisory AI layer
The AI never *is* the source of truth; it proposes deterministic operations on a deterministic
core, which executes and is fully pinned. The AI is centralized (one shared brain), never in
the synchronous draw path, and the core is fully usable with it switched off.
**Today:** the operation vocabulary, a portable document serialization (`test_json`), the
per-app effects engines, **and now the typed transaction journal** (§10 item 2 / `OP_LOG.md`)
already exist — the deterministic-operation surface an agent commits through is largely in
place. AI integration itself is greenfield. **Benefit:** equivalence survives (you test the *operation the AI committed*,
not the model); AI cost/complexity paid once. **Downside:** offline/latency story required; a
clean operation-API boundary must be held; depends on 6.2.

### 6.2 Stable identity + the live relationship graph — the keystone
Generalize liveness from owned-children to elements referenced by stable id, anywhere in the
document; build the dependency DAG with incremental recompute. **Today (SHIPPED 2026-06, all
four native apps — see `REFERENCE_GRAPH.md` / `SYMBOLS.md`; `jas_flask`'s JS engine is a
separate port outside this rollout):** an additive `common.id` exists on every
element (tree-paths kept for the UI); `LiveVariant` now has two arms (`CompoundShape` +
`Reference`), where a `Reference` names its target by id and resolves through an
`ElementResolver` seam; a derived `DependencyIndex` (`deps`/`rdeps`/`dangling`/`cycles`/
`topo_order`, with a cross-language-locked Kahn ordering) is a pure function of the document;
recompute is now both incremental (persistent id→element index, O(changed) maintenance) and
cached (a generation-epoched reference-geometry cache), each held to a from-scratch ==
incremental debug-assert gate; cycles/dangling break to empty at eval; identity round-trips
via SVG `id`/`<use>`; and Symbols (reusable masters + live instances) ride the same machinery.
**Benefit:** unlocks essentially the whole intent vision at once. **Still ahead:** write-time
cycle rejection (eval-time break already handles imported cycles); importing *foreign* `<use>`
as live vs. flattening; and bidirectional **constraint solving** (IK, mutual constraints) —
the one-way DAG covers most cases but constraint solving is a separate, harder layer.

### 6.3 Domains as declarative packs
Concepts (fitter + generator + operations + constraints) ship as data, interpreted identically
by all apps; breadth becomes content, not releases — authorable by the team, the community, or
the AI. **Today:** tools already migrated native→data (all but Type/TypeOnPath); the expression
language can **generate geometry** (`sin`/`cos`/`tan` degrees, `pow`, `range`, `fold`, pinned
across five apps); and the **concept-pack format + generator engine have shipped** — a concept is
a `workspace/concepts/*.yaml` (`params` + a generator expression → geometry), pinned by its own
cross-language conformance corpus (`CONCEPTS.md`; `regular_polygon`, `spiral`, `star`, and the
flagship `gear` ride it — with `mod`/`floor` added to the language for the gear/star parity). A
parametric concept is now data, **the gear included**. **✅ COMPLETE — all four parts now ship as data** (repaired 2026-09-03; this line
previously listed them as remaining): the document `LiveVariant::Generated` instance arm
(`document/document.rs:322`, `:965`, `document/controller.rs:594`, `:612`; Swift
`ActiveDocumentView.swift:205`, `ConceptsPanel.swift:104`), operations, the fitter
(`promote`), and a **constraint representation** — `workspace/concepts/regular_polygon.yaml`
carries all four keys, `gear.yaml` carries generator/operations/constraints, and each part
is pinned by its own cross-language corpus (`workspace/tests/concept_operations.yaml`,
`concept_fitters.yaml`, `concept_constraints.yaml`). `CONCEPTS.md:252`: *"All six
increments are complete."* **Benefit:** N domains
cost ~one engine, propagated to the active apps for free (frozen ports hold the tag-era packs). **Downside:** the generator engine is corpus-pinned, so
each addition stays safe; what remains genuinely unbuilt is not the deterministic fitter
but the *fuzzy* one — semantic fitting of messy hand-drawing stays frontier (§7).

### 6.4 Liveness as the bridge between brainstorm-speed and CAD-precision
A gesture produces a *live operation with inferred parameters*; the panel later tunes the same
parameters without redoing anything. The fast path and the precise path are **the same
operation at two times**, not two tools. **Today:** tools are already declarative handlers over
a normalized pointer payload, and preview-then-commit exists (e.g. the ellipse tool). The gap:
the event vocabulary is mouse-only (no gestures/pressure as first-class); promotion and "lenses"
are not generalized. **Benefit:** speed *and* precision; panels stay for depth without burdening
flow. **Downside:** "promotion" and mode/lens UX are subtle; gesture discoverability needs care.
The unifying elegance: one operation vocabulary, three input channels (gesture, menu, AI) — which
simultaneously gives discoverability (menu fallback), equivalence (the menu path is spec-able),
and AI integration (same op).

### 6.5 Two testing regimes (see §9)
Deterministic conformance for the core; perceptual/AI evaluation for the creative frontier.
Manual testing converges to a bounded, prioritized sample — and even manual sessions get
captured as replay fixtures so they are paid for once.

### 6.6 Performance is co-equal with liveness (see §8)
Incremental evaluation, spatial indexing, and dirty-region rendering must be designed in as
hooks now (even with simple implementations), because they are structural, not bolt-ons.

### 6.7 The AI operation-API + canvas perception
Make "Claude Code for drawing" concrete: tool schemas generated from `actions.yaml`; perception
via *structural* query (scoped subgraph) **and** *visual* raster (vision model); an agentic loop
of perceive → plan a transaction → **live preview** → self-critique → artist accepts/tweaks.
The key difference from coding: review happens **before** commit (liveness preview), and the
artist — not a test oracle — is the judge of "good". **Today:** greenfield, but built on 6.1.
**Benefit:** reuses everything; the AI and a human collaborator become the same thing.
**Downside:** vision of fine vector detail is imperfect; reviewability of large transactions
needs semantic summaries; perceive from a *canonical* render so plans stay uniform across apps.

### 6.8 Animation — keep it ready, don't build it yet
Keyframed/procedural animation is "liveness over time": add a global `t` to the evaluation
context and a timeline structure, and the incremental graph handles playback. Simulation
(recurrence) and rigging/IK (constraint solving × time) are separate hard layers.
**The one discipline to hold now:** keep edit-time (undo/history) and playback-time (the
animation cursor) cleanly separate, and never bake frame state into the document. Then animation
is additive, not a rewrite. **Today:** greenfield; the source-evaluated-against-context shape
that makes this free is already present.

### 6.9 The ecosystem — identity is the keystone here too
The operation log makes **versioning** nearly free (a version is a labeled point in the op
stream; semantic diffs via the AI) — build this early; it delivers the "fast client revisions"
goal. **Comments-on-objects** need stable ids. **Collaboration** = merging operation streams
(the AI is just another participant) — strategically the highest-value ecosystem item, but a
large axis: keep the op model merge-ready now, build later. **Interop:** export = `expand`
(bake to flat SVG/PDF), import = `promote` (fit structure) — but fix serialization fidelity
first (see §11). **Color/type/print** are more mature than expected (CMYK, ICC, rendering
intent, overprint, print pipeline already exist) — remaining work is completeness, scoped by
target domain.

### 6.10 Artist primacy as an enforced law
Operationalized as invariants, not vibes: **(a)** reversibility is absolute — every operation,
the AI's most of all, is undoable and the original recoverable (a cross-language `undo_redo_laws`
fixture already exists — extend it); **(b)** the AI *proposes*, never commits unbidden, through
the same gate as any operation; **(c)** every AI action is legible as named operations in the
artist's own vocabulary, with semantic summaries; **(d)** the artist is the aesthetic oracle —
the AI verifies objective constraints but never decides "good"; **(e)** skill stays primary —
direct manipulation is always fully capable alone; the AI removes drudgery, not artistry.
Because the AI has no mutation path except proposing transactions through the gate, **primacy is
enforced by construction and verifiable in CI** — impossible to violate, not merely discouraged.
The artist can *dial up* delegation by explicit, revocable consent, but autonomy is granted,
never assumed. The AI is a **gap-shrinker** between conception and creation — never an
intention-substituter.

---

## 7. Buildable vs. frontier (be honest)

**Buildable on the foundations:**
- Parameter-driven concepts (the gear's tooth count); param + generator.
- Forward reference-propagation relationships (connectors follow blocks; mirrored eyes; FK posing).
- Multiple membership + hierarchy (overlapping/nested concept overlays over shared atoms).
- Keyframed/procedural animation; versioning; comments; deterministic fitters (curve-fit, boolean, repeat detection).

**Frontier (AI-assisted, must degrade gracefully — propose, surface conflicts, let the artist arbitrate):**
- Fuzzy semantic fitting of messy hand-drawing ("this is a gear/eye").
- Style-preserving regeneration (change tooth count while keeping the hand-drawn character).
- Constraint *negotiation* across competing interpretations ("fuller tree" vs. "legible greeting").
- Inverse kinematics / rigging; physical simulation.

The product ships the buildable tier with crisp, deterministic mechanisms and lets the AI tier
grow underneath **without changing the artist's flow** — the experience is the same whether the
fitter is a geometric heuristic or a model.

---

## 8. Scale philosophy

- **Distinguish logical complexity (document elements) from visual complexity (painted
  primitives).** They scale differently. The concept architecture (6.3) converts potential
  logical explosion into cheap visual complexity: the AI should **generate parametric structure,
  not flattened primitives** — a forest is a generator over a tree concept, not 500k shapes —
  so the model stays small and complexity is materialized lazily at render time.
- **AI changes the arrival rate of complexity** (and we may not see it coming) — so the
  performance *hooks* must exist early even if the implementations stay simple.
- **The incremental path:** clean interfaces make implementations swappable (linear scan →
  grid → R-tree; full recompute → incremental subgraph) with zero caller changes. The
  conformance harness (§9) is what makes each swap *safe* — it proves the faster implementation
  is behaviorally identical. Simple implementations must **degrade, not break**, under surprise
  scale; **telemetry** must report when budgets are approached.
- **Optimization is per-app; behavior is uniform.** Add the heavy index only in the app under
  scale pressure; equivalence holds because the harness pins the result.
- **Determinism traps to respect:** recompute order must derive from stable ids (not
  language-specific hashmap order); avoid non-deterministic parallel floating-point in the
  pinned path.

---

## 9. Testing philosophy

Three regimes; push everything as far *down* as possible (cheaper, cross-platform, CI-friendly):

1. **Deterministic conformance** — `(state, op)→state'`, expression evaluation, geometry and
   algorithms, liveness recompute (`incremental == from-scratch`), the resolved render-*tree*,
   generators. This regime *is* the equivalence harness.
2. **Capture / replay** — record the seam: an AI plan, a gesture, or a whole session becomes a
   deterministic fixture replayed across all apps. **Our 36 manual-test transcripts
   (`transcripts/*_TESTS.md`) are already scripted action sequences with coordinates and
   Do/Expect — adding session capture turns them into executable, cross-app regression
   fixtures, so each manual session is paid for once.** (**Repaired 2026-09-03: the recorder now
   exists** — `jas_dioxus/src/recorder/` (`core` · `hooks` · `replay` · `fidelity`),
   `RECORDER.md`, `scripts/ingest_recording.py`, four capture seams. This line previously
   read *"no capture/replay recorder exists yet; this regime is unbuilt"*, which is false.
   **The true statement is narrower and still an open item: it is Rust/wasm only** — zero
   recorder hits in `JasSwift/Sources` — so the regime exists in one port and the
   cross-app half of its value is unclaimed.)
3. **Perceptual / evaluative** — the irreducible frontier: "is the AI plan good?", "does it look
   right?", "does the gesture feel right?" Eval datasets, golden images (per-platform, sparingly),
   LLM-as-judge (calibrated), and a *bounded* human sample.

Disciplines: keep live model calls out of the merge gate (use recorded outputs); run AI quality
eval as a separate periodic metric gated on prompt/model changes; prefer render-tree conformance
over pixel baselines; tier CI (fast deterministic gate on every change; slower eval/perf/visual
tracks periodically) so heavy testing never fights iteration speed.

---

## 10. Critical path

Everything stands on three things — build them first:

1. **Stable element identity** — ✅ **SHIPPED** (additive `common.id` in all four native apps; coexists
   with tree-paths; round-trips via SVG `id`; duplicate clears id, undo/redo preserve it).
2. **The operation / transaction log** — ✅ **SHIPPED** (Increments 1–3 across all four native
   apps, merged to `main`; see `OP_LOG.md`). The atomic, reversible, summarizable unit is built:
   a runtime `op_apply`, a typed `Transaction` journal (`op_journal` + `journal_head`) layered
   *co-equally* over the snapshot stacks, the enforced `set_document` chokepoint (the
   consolidation of §11), the **mandatory `checkpoint_equivalence` gate** (replay == snapshot,
   byte-identical), the 33-verb `actions.yaml`↔`op_apply` unification, per-frame drag coalescing,
   id-primary addressing (3c-1), the runtime layout-op dispatcher (3d), and sibling-app
   production routing so *every* app's gestures journal — not just Rust's. **Still ahead:**
   capture/replay sessions **in the ports that do not have them** (§9 regime 2 — the
   highest-value follow-on; the recorder ships in Rust/wasm, see §9), journal persistence, and
   collaboration (op-inversion, `doc_id`, recorded-merge — 3c-2/3/4), all deliberately deferred
   but kept format-ready.
3. **The expression-language conformance corpus** — ✅ **SHIPPED as a cross-language gate.**
   `workspace/tests/expressions.yaml` is compiled to `test_fixtures/expressions/conformance.json`
   and self-checked in all four native apps **plus** the Python reference, CI-gated (with a
   freshness check). The closure lexical-scoping divergence it was meant to pin is fixed in OCaml
   **and** Rust — the gate immediately caught a second leak a manual survey had missed.
   **Geometry generators now ship on top of it** — `sin`/`cos`/`tan` (degrees), `pow`, `range`,
   `fold`, pinned by the corpus across all five interpreters. **Repaired 2026-09-03:** this
   line previously named the **concept-pack format + constraint representation** (6.3) as
   the next critical-path item. Both shipped, so this critical path is **fully discharged**
   — all three items in §10 are ✅, and the next work is a milestone rather than a
   foundation. `docs/ROADMAP.md` §3 carries the ruled sequence.

The live dependency graph (6.2 — ✅ shipped) and the operation-log spine (§5 item 5 / §10 item 2
— ✅ shipped) are both in. The concept-pack system (6.3) is **also shipped in full** — the second place this
document listed its parts as remaining, repaired 2026-09-03 with §6.3. The open chain, in
dependency order, is therefore: capture/replay sessions **beyond the first port**
(§9 regime 2) and the gesture/lens layer (6.4); the AI operation API and perception
(6.1/6.7); versioning (6.9). Animation (6.8) and collaboration (6.9) stay deferred-but-ready
throughout.

⚠️ **Dependency order is not build order, and the build order is ruled elsewhere.** The
2026-09-03 roadmap sitting ruled the AI operation API **before** the gesture/lens layer,
behind the Windows app; `docs/ROADMAP.md` §3 is the document of record for that sequence.
This paragraph states what depends on what, not what is built next.

---

## 11. Near-term runway (clearing the equivalence backlog)

The 2026-06-13 codebase review produced a prioritized backlog whose equivalence-pinning items are
direct prerequisites for this vision. The most relevant:

- **Restore the cross-language algorithm harness** so the lead implementation is actually
  verified (done, then it **silently re-broke** when Phase-4b put `IdIndex` in the web-gated
  `canvas::render` and core `model.rs` imported it — `--no-default-features` stopped compiling;
  re-fixed 2026-06 by moving the index into core `document::id_index`; `algorithm_roundtrip`
  418/0, commutativity 192/0). **Lesson, and the guard now exists — repaired 2026-09-03:** this line previously read
  *"there is no fast unit-stage `cargo build --no-default-features` guard … Add that
  guard."* It is in CI twice: `.github/workflows/test.yml:824` and `:1182` both run
  `cargo build --bins --no-default-features`, so a web-into-core leak no longer waits for
  the cross-language job to surface it.
- **Fix canonical-serialization fidelity** (CompoundShape and per-range tspans were silently
  dropped) — ✅ **done**: CompoundShape and per-range tspans now round-trip through JSON,
  binary, and SVG, pinned by the shared cross-language harness.
- **Build the expression-language conformance corpus and fix closure-scope divergence** — the
  prerequisite for concept packs (6.3). ✅ **done**: the corpus is now a cross-language gate (all
  four native apps + the Python reference self-check the same compiled cases in CI, with a
  freshness check), and the closure lexical-scoping divergence is fixed and pinned in **both**
  OCaml and Rust.
- **Consolidate to one mutation path** (Rust formerly had two effect runners: `renderer.rs`
  on `AppState`, `effects.rs` on `StateStore`/`Model`) — ✅ **done**: all mutation now funnels
  through the enforced `set_document` chokepoint (the `in_txn` assertion) in all four native
  apps — the prerequisite that made the op-log journal complete-by-construction (`OP_LOG.md`
  Increment 1). Artist primacy (6.10) is now architecturally enforced at this seam.
- **Add the widget/effect parity guard** — ✅ **done.** `scripts/check_widget_kind_dispatch.py`
  (CI `.github/workflows/test.yml:108` and `:648-649`) covers per-app widget-kind dispatch;
  `scripts/check_action_implementations.py` (CI `:121` and `:652-653`) covers the actions
  behind a widget. Both are CI-wired and both run their own `--self-test` first.
- **Add the validator cross-reference layer** — 🟡 **three of four sub-checks done.** ⛔ This
  line was **split** from the one above on 2026-09-03 rather than ticked, because the two
  halves are in different states and a single tick would have erased three open gates.
  Measured against the layer's own four-check definition: *every `action:` reference
  resolves* ✅ (`scripts/check_action_refs.py`, plus the reference interpreter's own test);
  *every `$state` read has a declaration* ✅ **done — built, self-tested AND LIVE on both
  platform families** — `scripts/check_state_reads.py`,
  `.github/workflows/test.yml:98` (ubuntu, the *workspace.json up-to-date* job) and
  `:742-743` (Windows, the *Structural gates* step) run `--self-test && ` the live scan.
  The gate landed on 2026-09-03 with its live arm COMMENTED OUT, because main carried 13
  findings it was written to surface; the tick above is dated from the day all 13 were
  repaired and both live lines uncommented, not from the day the script existed.
  **How the 13 were repaired matters more than that they were**: every one was rewritten
  IN THE YAML using forms the expression grammar already had, so no port gained an
  operator and every port's behaviour changed identically by construction. The 6 uses of a
  `contains` operator no port's lexer has became `any(list, fun x -> x == v)`, the
  higher-order builtin all three active evaluators already carry and the cross-language
  corpus already pins; the 2 `:=` setters became `<-`, the grammar's only assignment
  token, so typing in Artboard Options' reference-point X/Y writes again; the
  `#dialog.hex` colour bind became `dialog.color`, the form the Color Picker's own preview
  swatch uses, which retires the one YAML site that needed a hand-written `"#expr"`
  special case in two ports' renderers; the 3 undeclared `dialog.*_mode` reads sat on
  `include: variation_widget` nodes that `loader.resolve_includes` never reaches (it runs
  on `data["layout"]` only) and are now `template:` invocations — `resolve_templates` DOES
  run on every dialog's `content`, and the compiled `workspace.json` the active ports read
  carries the expansion, so the repair needed no interpreter change and no port change.
  **One finding could not be repaired and is named rather than excluded:** the `${...}`
  inside `sort_brushes_by_name`'s `data.list_sort` path. `${...}` is
  `loader.substitute_params`, which never runs on an effect payload, and NO port has any
  mechanism for a data path computed from state — every `data.*` effect reads `path:` as a
  literal dotted string, and three of the four ports implement no `data.*` effect at all.
  Inventing one would be exactly the new grammar this repair refused, so the action is now
  a log-only stub whose description says it is unimplemented and names the shape of the
  fix (a `brush.sort_by_name` shortcut taking `library:` as an expression, as
  `brush.delete_selected` already does). Sort by Name still does not sort; the difference
  is that the spec no longer claims it does. The gate needed no exemption for it.
  Each repair is pinned by a behavioural test that fails on the pre-repair YAML —
  `workspace_interpreter/tests/test_state_read_findings.py` (and the two setter arms in
  `test_artboards_effects.py`) — because a gate proves a string parses and only a test
  proves a check mark appears.
  The gate itself resolves 1,735 reads — 334 `state.`, 375 `panel.`, 475 `tool.<id>.`,
  551 `dialog.` — against 678 declarations, and prints the size of what it CANNOT cover
  rather than leaving it to be inferred: 39 ambient `panel.`/`dialog.` reads (the namespace
  is whichever panel is active, and nothing in the source names it) and 1,174 of the 14,307
  scalars mentioning a namespace that is not state at all (`param.`, `data.`,
  `active_document.`, `event.`, …). The item's `$state` spelling
  is FLASK_PARITY-era: the literal `$state` occurs in zero workspace YAML files.
  *no duplicate ids* ✅ **done for
  workspace ids** — `scripts/check_workspace_ids.py`, wired on both platform families (the
  ubuntu *workspace.json up-to-date* job and the Windows *Structural gates* step;
  `.github/workflows/test.yml:65` and `:700-701` when written). 16 collectors over the 90
  YAML sources the loader actually reads, uniqueness **per namespace**, with the one
  cross-namespace clause read out of the code rather than assumed (`actions:` and
  `native_intercepts:` are one action-verb table in `check_action_refs._resolvable`). It
  reads the SOURCES and composes them into nodes, not the compiled bundle: `safe_load` keeps
  the LAST of two duplicate mapping keys and raises nothing, so a duplicate is already gone
  from `workspace.json` before any bundle-reading gate sees it. The per-tool filename-stem
  match named in the old wording as "the only id check" is still exactly that, and still
  cannot see two tool files claiming one id — the merge drops one before the validator
  runs. *enum values match declared* ✅ **done, by schema, over every authored section
  — 2026-09-05.** `schema/` covered app, tool, elements, features and preferences; six
  schemas landed that day for the rest: `panel`, `dialog`, `action`, `menubar`, `layout`
  (the pane system holding the toolbar) and the shared `widget` tree they reach by a
  cross-file `$ref`. They close the top-level key set of every panel, dialog, action and
  menubar item, the widget key set and the widget `type` enum (the canonical kinds; the
  pane-system kinds admitted in `layout.yaml` only), every `bind:` value as an expression
  string, the effect vocabulary and the action categories as closed lists, and dialog
  state as stored (`type` + `default`) or derived (`get` + `set`). Wired in
  `workspace_interpreter/validator.py`, run by the compile every CI lane performs, with a
  planted-defect arm per class in `test_validator.py`. Read the "done" for what it COVERS:
  `style:`, per-kind widget properties beyond the type, effect payload shapes and
  expression parsing (layer 3) stay open, named in `schema/README.md`; the checker used
  without `jsonschema` refuses the same planted defects, driven with it forced absent. When first run on
  the real tree the six went red on 63 sites and every one was a form the census had
  missed — none a defect: a clean negative. (Until 2026-09-03 this line named TWO unbuilt
  gates; the state-read gate was built that day and ticked above once its live arm watched
  the tree; this one was the last, and this section now names NONE.)
  ✅ The related defect this line used to carry as unrepaired —
  `workspace_interpreter/validator.py`'s docstring naming itself the home of two validation
  layers it does not implement — was repaired in the same pull request as the gate above.
  The docstring now lists what the module validates today and points at where each other
  layer lives, including the one that lives nowhere.

---

## 12. Keeping this document and `ARCH.md` honest

- `ARCH.md` describes the system as built; update it whenever a foundation in §5 lands (in
  particular, when stable identity, the live graph, or the concept-pack runtime ship). Its
  implementation table now carries the post-freeze port statuses (`POLICY.md` §1).
- This document changes when the *intent* changes. Decisions made here (e.g. the keep-ready
  deferrals, artist-primacy invariants) should be cited when they constrain implementation work.
