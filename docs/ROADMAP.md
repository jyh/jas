# ROADMAP — the grand one

**Status: RULED. The roadmap sitting was held 2026-09-03 (desk EV) and settled all six
questions this document put to it; §5 now records the rulings rather than asking them.
Still no dates — do not plan against §3 dates, there are none.**

**Cite for every ruling below: `2026-09-03-ROADMAP-SITTING-minute.md`, the sitting's
minute, which is the record.** Where this document and that minute disagree, the minute
wins.

Commissioned by the Captain at the 2026-09-03 council: *"a lot of what we have done so
far is infrastructural parity, which is great and necessary … the big roadmap for jas is
much grander … look through the notes for where we discussed our grand vision (and my
personal project for the Last Supper), and let's get back on that track."*

---

## How to read this document — the two-state rule

A roadmap is a document about the future, and the future has no test. This one is
therefore held to the only discipline that survives that: **every line on this page is in
exactly one of two states, and never a third.**

1. 📎 **Sourced** — it quotes something already written, with `file:line`. You can check it.
2. 🟨 **PLACEHOLDER** — the record is silent, and the block is left *empty* rather than
   guessed at.

**There is no third state, and in particular there is no "jas's best guess at what he
meant".** Where the record is silent this document says so and stops. That is the whole
reason it is safe to read.

**The one placeholder this draft carried (§4.1) is now discharged — and the way it was
discharged is the discipline working.** The record was not silent after all; it was filed
under another name, which a census by phrase could not see. §4.1 is filled **by pointer**,
never by reconstruction. See §4.0.

Its companions: `VISION.md` is the intent, `ARCH.md` is the architecture as built,
`transcripts/AI.md` is the founding statement in the Captain's own words, `POLICY.md` §1
is the port law. **Where this document and those disagree, they win and this one is
stale** — see §0, which is a live demonstration of exactly that hazard.

---

## The boundary this document sits inside — ruled at the sitting

**R0, ruled by the Captain unprompted: the framework stays OPEN; once AI-supported
features are added, the *product* becomes PROPRIETARY.** The line falls inside a single
milestone rather than between two of them, so it is stated here once and honoured
throughout:

* **Open, in this repository** — the operation API, canvas perception, the operation and
  transaction journal, the conformance corpora, the interpreter, every app. The hooks a
  model calls are framework.
* **Proprietary, in a private fork** — the assistant itself, its practised moves, and the
  *contents* of the intent ledger. Never a directory inside this tree.
* **The intent ledger splits:** its **schema is open** — a third party may write their own
  assistant against it — while the **reasoning it records is proprietary**.

⇒ **Consequence for §3.1 and for this whole page: the AI milestone is described here at
the level of its API surface only.** That is not an omission to be filled in later by
someone tidying the document; it is the boundary. The private fork does not exist yet and
is created only when the Captain names it.

---

## 0. ⚠️ THE FINDING THAT SHAPES THIS DOCUMENT

**Before drafting a roadmap I re-measured what is actually built, rather than reading
`VISION.md`'s account of itself. The two disagree in four places — and every one of them
understates the truth.** `VISION.md` describes as *open* four things that have since
shipped:

| `VISION.md` says | measured today, 2026-09-03 | verdict |
|---|---|---|
| `:196-198` — concept packs: *"Remaining, in dependency order: the document `LiveVariant::Generated` instance arm; operations; the fitter (`promote`); and a constraint representation."* | All four parts ship. `workspace/concepts/regular_polygon.yaml` carries `generator:` `fitter:` `operations:` `constraints:`; `gear.yaml` carries generator/operations/constraints; the corpora `workspace/tests/concept_operations.yaml`, `concept_fitters.yaml`, `concept_constraints.yaml` all exist; `promote_to_concept` and `apply_concept_operation` are in both active ports' controller + `op_apply`. `CONCEPTS.md:251-252` states it plainly: *"All six increments are complete."* | ❌ **STALE** |
| `:322-323` — *"(No capture/replay recorder exists yet; this regime is unbuilt.)"* | The recorder exists: `jas_dioxus/src/recorder/` (`core` · `hooks` · `replay` · `fidelity`), `RECORDER.md`, `scripts/ingest_recording.py`, four capture seams. It is **Rust/wasm only** — so "unbuilt" is false and "one port" is the true statement. | ❌ **STALE** |
| `:357-359` — *"the next critical-path item is the concept-pack format + constraint representation"* | Both shipped. The critical path has moved and the document never noticed. | ❌ **STALE** |
| `:380-382` — *"there is no fast unit-stage `cargo build --no-default-features` guard"* | `test.yml:824` and `:1182` both run `cargo build --bins --no-default-features`. | ❌ **STALE** |

**And four of its open items are TRUE, re-measured and confirmed** — which is what makes
the table above evidence rather than a complaint:

| `VISION.md` says | measured today | verdict |
|---|---|---|
| `:164` / `:228` — AI integration is *greenfield* | zero hits for `anthropic\|openai\|llm\|agent_api\|ai_plan\|tool_schema` across both active ports and the reference interpreter | ✅ **HOLDS** |
| `:239` — animation is *greenfield* | the only `keyframe\|timeline\|animation` hits are undo/redo prose (`model.rs:904`, `Model.swift:1308`) | ✅ **HOLDS** |
| `:206-207` — *"the event vocabulary is mouse-only (no gestures/pressure as first-class)"* | zero hits for `pressure` in the workspace spec or the Rust tool layer | ✅ **HOLDS** |
| `:246` — collaboration/versioning unbuilt | zero hits for `doc_id\|op_invert\|merge_journal` in either active port | ✅ **HOLDS** |

⇒ 🔑 **THE LESSON THIS DOCUMENT IS BUILT ON.** A false open-item misprices every plan
made from it, **and it does so in both directions**: a phantom gap invites redundant work
exactly as a phantom gate invites misplaced trust. `VISION.md` is an honest document that
went stale in the one direction nobody audits — *toward pessimism* — because a shipped
feature updates the code and the feature's own design doc, and nobody re-reads the vision
to cross it off.

**The practical consequence, and the sitting took it: the concept-pack road, which
`VISION.md` still presents as the next critical-path item, is FINISHED. The lane is
further along than its own north star believes.** The sitting spent itself on what comes
after that road (§5), and ordered `VISION.md` repaired in a separate PR.

⚖️ **A FIFTH CANDIDATE WAS ADJUDICATED SEPARATELY AND IS NOT IN THE TABLE ABOVE, BECAUSE
IT IS A DIFFERENT KIND OF ROW.** `VISION.md:396` — *"Add the widget/effect parity guard
and validator cross-reference layer"* — names **two** artifacts, and is **HALF**
discharged: the widget and effect parity guards are both fully shipped as CI-wired,
self-tested gates, while the validator cross-reference layer is **one of its four defined
sub-checks** shipped. ⛔ **Ruled with it: when `VISION.md` is repaired, this line is
SPLIT, never ticked** — ticking it alongside its four wholly-stale neighbours would erase
three genuinely open gates and manufacture the opposite defect. See §6 for the residue.

---

## 1. THE VISION — in the Captain's words, quoted

The vision is **not** missing. `transcripts/AI.md` is the founding statement, in his own
prose, and `VISION.md` is its worked-out architecture. What follows quotes rather than
paraphrases, because a roadmap that restates a vision in someone else's words has already
lost the thing it was protecting.

### 1.1 The soul

> **"Shorten the distance between what is in the artist's head and what appears on the
> canvas — and keep them in flow while they close it."** — `VISION.md:23-24`

and the test that follows from it, which is the sharpest sentence in the corpus:

> **"Does this shrink intention→result, or does it just add surface?"** — `VISION.md:31`

Two non-negotiables of feel: the tool stays **out of the way**, and the artist is
**fearless** — *"everything is reversible; nothing is ever permanent"* (`VISION.md:33-35`).

### 1.2 What "grander" actually means — the six pillars (`VISION.md:41-64`)

1. **Liveness everywhere, by design** — *"Yes, liveness everywhere, like it was built in
   as a basic concept from the start."* (`transcripts/AI.md:1`) *"Every shape stays
   editable back to its intent, forever."* (`VISION.md:42`)
2. **The tool understands intent** — *"if I am drawing a block diagram, when I drag a
   block, the connecting lines come with it. Or if I am drawing a portrait, the tool can
   help me with proportions, anatomy, coloring. For example if I move the position of one
   eye, the tool can automatically move the other to match. If I have drawn a figure that
   is standing, I can easily transform it to reach down and pick a flower. If I have a
   technical drawing, say of a gear, I can change the number of teeth in the gear in a
   single step, while also retaining the technical precision."* (`transcripts/AI.md:3`)
3. **Retroactive structuring** — the artist never pre-thinks structure; they draw freely,
   then *"declare or infer meaning late"*, non-destructively (`VISION.md:48-52`).
4. **Multiple simultaneous interpretations** — *"The same marks can be at once a greeting,
   a tree, and part of a face — overlapping, at different semantic levels."* The artist
   edits through one **lens** while the tool keeps the others coherent *"(or flags an
   honest conflict)"* (`VISION.md:53-56`).
5. **Gestural, conversational flow** — *"it would look like a conversation between my hand
   and the machine"* (`transcripts/AI.md:21`); *"transform the 'slow and detailed' process
   … into a performative act with the organic speed of a brainstorm and the 'Print-Ready'
   output of a CAD professional"* (`transcripts/AI.md:26`); *"a 'Claude Code' but for
   illustration … where traditional artist skills like sketching, drawing, painting are
   all primary and natural but the tool 'knows' what I am drawing or painting, and assists
   me to bring it to life"* (`transcripts/AI.md:28`).
6. **Breadth across project types** — *"One project might be a portrait drawing or
   painting. Another might be an animation. Another might be a brochure with precise
   professional requirements for type and formatting. Another might be a technical drawing
   of the gears in a automobile transmission. Another might be a technical diagram of an
   LLM architecture. And more."* (`transcripts/AI.md:30`)

For each of those project types he named four wants (`transcripts/AI.md:32-35`): the
concept→creation distance is short; revisions are streamlined *because* the tool knows
what is being drawn; liveness and non-destructive editing are everywhere; and the deep
technical control of tools and panels is there **without** *"feel[ing] burdened by
switching tools and panels just so I can get something done."*

### 1.3 The "shaper" — the one fully-specified unbuilt feature in the record

`transcripts/AI.md:7-19` describes a concrete AI-assisted mode, and it is the single
richest unbuilt thing anywhere in the notes:

> the artist draws freehand, in live mode, where **the hand-drawn ink stays on one layer,
> and the precision layer generates vector paths**; geometric primitives are inferred from
> the freehand object; and the assistant projects **a subtle dynamic grid that aligns with
> the artist's perspective** to help them draw.

with a feature table (`transcripts/AI.md:14-19`) mapping hand-sketch action → technical
output: varying pressure → defined stroke weights; quick scribbling → *"perfectly spaced
vector hatch patterns"*; rough stacking → instant distribution and tidy-up. And the
gestural shortcuts at `:22-24`: double-tap a line for exact coordinates, flick an element
to send-to-back, lasso and pinch to scale to a percentage.

**This is a milestone, not a mood** — see §3.4. I flag it because it is the most
buildable-looking item in the founding notes and it has never appeared in any queue.

### 1.4 The engineering values (`transcripts/AI.md:37-43`, `VISION.md:68-83`)

Five apps for the same features *and* cross-app behavioural confidence; minimizing manual
testing *"because that is the most expensive part of the development"*; reliance on common
specification; *"high performance and scalable to massive drawings"* (`VISION.md:81`
prices it: **100k–1M elements eventually**); clean factored code in all languages; and
anticipation that features grow and change.

### 1.5 The reconciliation — why the parity work was never a detour

The Captain's own framing at council was that the parity work was *"great and
necessary"* but not the grand thing. `VISION.md:91-94` states why the two are the same
road, and it is the most important paragraph in the corpus:

> **"Equivalence (five identical apps) and the AI-assisted vision are not in tension. They
> are the same architecture, seen twice.** Every abstraction we build to keep the five
> apps identical is exactly the abstraction an agentic AI needs; every layer we build for
> the artist is what we pin for equivalence. **There is one road, not a fork."**

with the corollary that governs how every milestone below should be built: *"Don't chase
features; pin the interpreter."* (`VISION.md:98`) A feature is `workspace/*.yaml`
interpreted by a thin engine; pin the interpreter layers with shared gated conformance
tests and every feature on them is identical **by construction**.

### 1.6 Artist primacy — the vision's one enforced law (`VISION.md:253-265`)

Not a guideline. Five invariants: reversibility is absolute (*"the AI's most of all"*);
the AI **proposes, never commits unbidden**; every AI action is legible as named
operations in the artist's own vocabulary; **the artist is the aesthetic oracle** — the AI
verifies objective constraints but never decides "good"; and skill stays primary. The
architectural claim is the strong part:

> *"Because the AI has no mutation path except proposing transactions through the gate,
> primacy is enforced by construction and verifiable in CI — impossible to violate, not
> merely discouraged."* — `VISION.md:261-262`

> *"The AI is a **gap-shrinker** between conception and creation — never an
> intention-substituter."* — `VISION.md:264-265`

---

## 2. WHERE WE ARE — measured today, not inherited

Every number below is a command run on `main` at `a179efe4` on 2026-09-03. I re-measured
rather than quoting the 08/20 survey, because that survey is 14 days old and `main` has
moved a great deal since.

### 2.1 The suites

| lane | result |
|---|---|
| Rust `cargo test` (`jas_dioxus/`) | **3053 passed · 0 failed · 19 ignored**, plus **35** cross-language |
| Python reference interpreter `pytest -q` | **1302 passed · 0 failed** |
| Swift `swift test` (`JasSwift/`) | **3028 tests in 46 suites passed**, exit 0 — *the runner's own words add* **"with 5 known issues"**, and I report that clause rather than dropping it |
| Browser (`wasm-pack test --headless --chrome`) | 69/69 at the last measurement (2026-09-02) |

Open PRs **as of the sitting, 2026-09-03**: flask's `#99` and `#100` (both ready, held
for his or flask's word) and this document's own PR. `#96` — the Direct2D whole-op witness
pass — merged during the sitting. **This line is a snapshot with a date on it, not a
standing fact; check the repository, not this page.**

### 2.2 The foundations — all three critical-path items are SHIPPED

`VISION.md:335-359` names three things everything stands on. All three are in:

1. **Stable element identity** — ✅ additive `common.id` in all four native apps.
2. **The operation / transaction log** — ✅ the typed `Transaction` journal, the enforced
   `set_document` chokepoint, the mandatory `checkpoint_equivalence` gate (replay ==
   snapshot, byte-identical), 33 verbs unified.
3. **The expression-language conformance corpus** — ✅ a cross-language CI gate.

Plus the keystone, **stable identity + the live dependency graph** (`VISION.md:168-184`),
shipped 2026-06: `Reference` elements resolving by id, a derived `DependencyIndex` with
cross-language-locked Kahn ordering, incremental *and* cached recompute held to a
from-scratch == incremental gate.

**And, per §0, one more that the vision has not noticed it finished: concept packs, all
four parts.** A concept is data — generator, operations, fitter, constraints — each
corpus-pinned across the active ports. **The gear is data.** That is `VISION.md` §6.3's
own flagship example, delivered.

### 2.3 The parity phase — what it actually bought

This is the work the Captain called *"infrastructural parity, which is great and
necessary"*. Stated plainly so the sitting can price what it is standing on: two active
ports (Rust, Swift) plus a live Python reference interpreter as the spec's executable
meaning; two ports frozen at `five-port-parity` as tag-pinned toolchain canaries
(`POLICY.md` §1); 26 tools migrated native→data as `workspace/tools/*.yaml`; and a
conformance-corpus discipline that pins interpreter layers rather than chasing features.

The most recent months of this seat's work have been a **mutation-driven witness census**:
asking of each operation not "is it tested" but **"what would have to break for a lane to
go red"**. On the Canvas2D backend that pass is complete, and it found ops that could be
deleted wholesale at a fully green board. That discipline is the reason §0 exists — it is
the same question turned on a document instead of on code.

### 2.4 The one thing in flight — the Windows app

**Ruled the lane's priority** (council 2026-09-01 r.6e: *"Especially we want the windows
app working asap"*, and *"priority order in the jas lane: Windows app first; everything
else in the lane yields"*). The variant is **WinUI 3**. The definition of done is ruled
and is not a checklist: *"until a Windows app RUNS the goldens end to end — that is the
definition of done."*

Node 1 landed (PR `#69`): `jas_paint_scene` joins the Direct2D painter to the surface the
host presents. Its own finding is worth carrying into the roadmap, because it is this
document's lesson in miniature — *"No jas artwork had reached the surface a window
presents, on any run, ever. Every green Windows run to date drew a square."* Node 2 —
making the document walk take a `&mut dyn Painter` so it compiles natively at all — is
the big one and is flask's.

---

## 3. THE GRAND MILESTONES

Derived from §1's quotes. **Each names its first observable: the first thing you could
SEE that proves the milestone has started, rather than a percentage.**

**The order below is the RULED order, not a derived one.** The draft that went into the
sitting ordered these by dependency and recommended gesture (then §3.1) before the AI
operation API (then §3.2). **The sitting ruled the other way** — the AI operation API
first — and the two sections have been swapped so that reading order and priority order
are the same thing. The reasons of record are in §5 Q2, and the accepted cost is stated
there too: the shaper (§3.4) waits one extra step. ⚠️ **The numbering therefore changed
between the draft and this version: old §3.1 is now §3.2 and old §3.2 is now §3.1.** No
other milestone moved.

Ordering is by ruled priority; there are no dates.

There are no dates on this page. Every estimate this lane has made from precedent rather
than measurement has been wrong, and a date in a roadmap is the most re-read unmeasured
number there is.

### 3.0 The Windows app — *in flight, and it outranks everything below*
Ruled priority; see §2.4. **First observable: already met** (node 1 landed).
**Done observable: a Windows app runs the goldens end to end.**

### 3.1 The AI operation API and canvas perception — *the open half of "Claude Code, but for drawing"*
📎 Sourced: `VISION.md:157-166` (6.1), `:223-231` (6.7), `transcripts/AI.md:5, 28`.
**Ruled first after Windows** (§5 Q2).

⛔ **THIS SECTION DESCRIBES THE API SURFACE AND NOTHING ABOVE IT — BY RULING, NOT BY
OVERSIGHT.** Under R0 (see the boundary block above) this milestone is the one place the
open/proprietary line falls *inside* a milestone. What is scoped here, and what is
therefore in this repository, is the **framework**: the hooks a model calls. The assistant
that calls them is proprietary and lives in a private fork that does not exist yet. **A
future reader tidying this page should not "complete" this section — there is nothing
missing from it.**

**In scope here (open):**
* **The operation API** — tool schemas generated from `actions.yaml`, so the callable
  surface is the same data the apps are built from rather than a hand-kept parallel list.
* **Canvas perception** — structural query over the document **and** visual raster, so a
  caller can see the canvas the way the artist does.
* **The proposal path** — a proposed operation is a *transaction* through the existing
  gate, previewed live, accepted or rejected by the artist, and landing in the journal as
  a named, undoable transaction indistinguishable from a hand-made one.
* **The intent ledger's SCHEMA** — open, so a third party can write their own assistant
  against it. What a ledger entry *reasons* is proprietary; what shape it has is not.

Measured greenfield (§0) — zero AI integration anywhere in either active port. The
architecture is already laid *for* it: this is the payoff `VISION.md:91-94` promises, and
the reason the parity work was never a detour. The key difference from coding, in the
vision's own words: **review happens *before* commit**, and *"the artist — not a test
oracle — is the judge of 'good'"* (`:228`).

**First observable:** an operation proposed through the API, previewed live, accepted by
the artist, and landing in the journal as a named, undoable transaction — **with
`checkpoint_equivalence` green over it.** That last clause is the milestone: it is what
makes artist primacy (§1.6) machine-checked rather than promised, and it is checkable
entirely on the open side.

### 3.2 The gesture and lens layer — *pillar 5 + pillar 4*
📎 Sourced: `VISION.md:202-212` (6.4), `:53-56` (lenses), `transcripts/AI.md:21-24`.
**Ruled second** (§5 Q2), against this document's own draft recommendation.
Today's gap is measured and confirmed (§0): **the event vocabulary is mouse-only.** No
pressure, no gestures as first-class. The vision's unifying claim — *"one operation
vocabulary, three input channels (gesture, menu, AI)"* (`VISION.md:210-212`) — needs the
gesture channel to exist.
**First observable:** a normalized pointer event carries **pressure** through the tool
seam and a stroke's width responds to it, with a conformance case pinning the mapping in
both active ports.
**Still a prerequisite for the shaper (§3.4)** — which is why the sitting recorded the
cost of putting it second rather than pretending there was none.

### 3.3 Semantic relationships — *pillar 2, the thing he asked for first*
📎 Sourced: `transcripts/AI.md:3` (the connectors, the eyes, the figure, the gear).
Status is **split, and the split is the interesting part**: the gear *"change the number
of teeth in a single step"* is **DONE** — it is a concept operation on data (§2.2). The
connectors-follow-blocks case is buildable on the shipped reference graph
(`VISION.md:272-274` lists it under *buildable*). Re-posing a standing figure to reach for
a flower needs **inverse kinematics**, which the vision honestly files as frontier
(`:281`) and as *"the separate, harder layer"* (`:184`) — the one-way DAG does not do
bidirectional constraint solving.
**First observable:** drag a block in a diagram and its connector follows, with a
conformance case pinning the recompute in both ports.

⚖️ **RULED (§5 Q4) — the order inside this milestone is: connectors first, then mirrored
eyes, then the posed figure.** The gear is already done. The posed figure is **GATED**:
it is not queued behind the eyes, it is held until the brainstorm on the Captain's
personal project (§4) says whether the composition needs posing at all. **If it does, the
figure jumps the queue and the IK layer gets its own design block** rather than being
squeezed into this one — because the honest reading of `VISION.md:184` is that
bidirectional constraint solving is a different layer, not a harder case of this one.

### 3.4 The shaper — freehand ink + inferred precision
📎 Sourced: `transcripts/AI.md:7-19` in full (see §1.3).
**Never queued, never designed, fully described in the founding notes.** Depends on §3.2
(pressure) and §3.1 (inference) — **and the sitting's Q2 ruling puts it one step further
out than this document's draft proposed.** That cost was named and accepted, not
overlooked.
**First observable:** an ink layer and a precision layer coexisting, where a freehand
stroke produces a live vector path that stays editable back to the ink.

### 3.5 Retroactive structuring, generalized — *pillar 3*
📎 Sourced: `VISION.md:48-52`, `:186-200`.
The mechanism exists and is proven for two cases: compound shapes, and now `promote` — the
regular-polygon fitter that turns a raw selection into a parametric concept (§2.2). The
milestone is generalizing it, and the frontier half is *"fuzzy semantic fitting of messy
hand-drawing"* (`:278`).
**First observable:** a second, non-polygon fitter — one the artist would actually reach
for — promoting a hand-drawn selection into a live concept.

### 3.6 Multiple simultaneous interpretations — *pillar 4, the deepest idea in the vision*
📎 Sourced: `VISION.md:53-56`, `:274`.
Overlapping concept membership over shared atoms, edited through one lens at a time, with
the tool keeping the others coherent **or flagging an honest conflict**. The reference
graph makes many-to-many edges possible; nothing above it exists.
**First observable:** one set of marks carrying two concept memberships at once, with an
edit through lens A leaving lens B either coherent or **explicitly flagged** — the flag
being as much the deliverable as the coherence.

### 3.7 Versioning, then comments, then collaboration — *the ecosystem*
📎 Sourced: `VISION.md:242-251`.
Measured unbuilt (§0). The op log makes versioning *"nearly free — a version is a labeled
point in the op stream"*, and the vision says **build this early**; it delivers the
*"fast client revisions"* goal from `transcripts/AI.md:33`. Collaboration is *"merging
operation streams (the AI is just another participant)"* — named *strategically the
highest-value ecosystem item* but a large axis, deliberately kept merge-ready rather than
built.
**First observable (versioning):** a named point in the op stream, restorable, with a
semantic diff between two versions.

### 3.8 Animation — *DEFERRED INDEFINITELY, keep-ready*
📎 Sourced: `VISION.md:233-240` (6.8).
Measured greenfield (§0), and **the vision does not want it built yet** — it wants one
discipline held: keep edit-time and playback-time cleanly separate, and never bake frame
state into the document. Then animation is additive rather than a rewrite.
**First observable:** a global `t` in the evaluation context that the incremental graph
already handles, with nothing else changed.
⚖️ **RULED (§5 Q3): BOTH PASSAGES STAND, AND ANIMATION IS DEFERRED INDEFINITELY.** The
apparent tension was not a contradiction to be resolved by picking a winner:
`transcripts/AI.md:30` names animation as a project type wanted, `VISION.md:233-240`
defers building it, and both are the Captain's. What the ruling settles is the *timing* —
**indefinite deferral, reopened only on his word** — and it converts the remaining half
into an obligation that binds now: **the discipline is a standing rule, checkable at any
time.** No frame state in the document; edit-time and playback-time stay separate. That
rule is enforceable today with nothing animated built, and it is what keeps this milestone
additive rather than a rewrite whenever it is reopened.

### 3.9 Scale — 100k–1M elements
📎 Sourced: `VISION.md:81`, `:289-307`.
The vision's own strategy is that **AI changes the arrival rate of complexity** (`:296`)
and that the answer is *generating parametric structure, not flattened primitives* —
*"a forest is a generator over a tree concept, not 500k shapes"* (`:294`). Concept packs
(§2.2) are therefore already the scale strategy, shipped.
**First observable:** telemetry that reports when a budget is approached — the vision asks
for it explicitly (`:302`) and it does not exist.

---

## 4. THE CAPTAIN'S PERSONAL PROJECT — THE LAST SUPPER

### 4.0 ⚠️ ERRATUM — the draft's central claim about this section was WRONG

**The draft that went into the sitting said, in bold: *"the phrase 'Last Supper' appears
NOWHERE on any fleet surface … the vision for it is oral. It exists only in the Captain's
head and in conversation."* The sitting found the record. That sentence is withdrawn.**

It is corrected rather than deleted, because the way it was wrong is the more useful
artifact:

* **The census was accurate.** Every count in it was real; the phrase genuinely does not
  occur on those surfaces.
* **The conclusion was false.** The project was ratified on **2026-07-27** under a
  *different name* — **"the apostles"** — as a north star for the arc that follows the
  parity work. Its design substance was written the same day and has been in the private
  record ever since, along with the verbatim conversation it came from.
* ⇒ 🔑 **A CENSUS BY PHRASE IS A CENSUS OF THE PHRASE.** Searching for a string and
  reporting "the idea is unrecorded" silently assumes the record uses your vocabulary. Two
  months of a ratified direction were invisible to the seat that most needed it, and the
  instrument reported zero the whole time — **correctly**, which is what made it
  believable. The remedy is not a better grep; it is to ask a person who was there before
  concluding that something was never written down.

This erratum is why §4.1 below is a **pointer** and not a reconstruction. The original
reasoning for keeping the block empty was right — an invented paragraph is
indistinguishable from a recorded one forever after — and it survives the correction
intact. Only the premise changed.

### 4.1 His description — by POINTER, not reproduced here

📎 **Sourced, and deliberately not quoted:** the project's founding document,
`ARC3-FOUNDING-0727.md`, written 2026-07-27 and held in the private record together with
the verbatim exchange it was distilled from. **The roadmap points at it; it does not copy
it.**

Two reasons, and they are different:

1. **R0 (see the boundary block above) places it on the proprietary side.** The founding
   document and the brainstorm that follows it belong with the product, not the framework.
2. **Even without R0, a summary here would compete with the original.** A pointer cannot
   go stale into a paraphrase; a summary can, and the whole point of §4 was to avoid
   producing text that reads like the Captain and is not.

What the pointer is safe to state, because it governs this repository's planning: the
founding document names the **next act** on this project as a **brainstorm conversation** —
its stated purpose being to help the artist discover what they mean, the message and the
scene — rather than a specification exercise. **That session is the Captain's to call.**
A design block to freeze the resulting contracts was announced on the same day in July and
never scheduled; it now has an owner and a trigger (§5, Q1).

⛔ **Do not fill this section in with content. It is filled.**

### 4.2 The brainstorm's agenda

**These ten questions were written for the roadmap sitting; the sitting reassigned them.**
They are now the agenda of the brainstorm session named in §4.1 — which is the right venue
for them, since they are questions for the artist about the work rather than questions for
the lane about the build. They are kept here because the roadmap is what makes them
findable, and because answers to them are what would order §3 better than any argument in
this document.

**What it is**
1. What *is* the Last Supper project? A single illustration; a series; a study; a
   reproduction; an original composition on the theme?
2. Is it a personal artwork you want to *make*, or a **benchmark** you want jas to be able
   to carry — or deliberately both?

**Medium and scale**
3. What medium is it in your head — line work; flat vector; painterly; a mix of hand-drawn
   ink and precision geometry (i.e. the shaper of §3.4)?
4. What is its physical scale and destination — print, and at what size? That decides
   whether the CMYK/ICC/overprint pipeline is on the critical path.
5. How many elements, roughly? This is the one number that tells us whether §3.9 (scale)
   is a prerequisite or a footnote.

**What jas must do that it cannot today**
6. Composition of many figures with maintained proportion and pose — is that the
   semantic/IK tier (§3.3), and is that what makes this project *your* project rather than
   something you could do in any existing tool?
7. Perspective — the founding notes describe *"a subtle dynamic grid that aligns with the
   artist's perspective"* (`transcripts/AI.md:10`). Is that grid a Last Supper
   requirement? (The composition is famously a one-point perspective construction, which
   is why I ask — **but the record does not say this, and I am asking, not asserting.**)
8. Which of the six pillars does it exercise hardest? That single answer would order §3
   better than any argument in this document.

**Process**
9. Do you want to work on it *while* jas is built — as the running usability oracle, the
   thing that finds what is missing by trying to use it — or after?
10. What would "jas can do the Last Supper" look like as an observable we could actually
    test?

### 4.3 Why this milestone outranks the rest of §3

📎 Sourced: `VISION.md:277-285` — the vision's own honest split between *buildable* and
*frontier*, and its rule that the product ships the buildable tier with crisp deterministic
mechanisms and lets the AI tier grow underneath **without changing the artist's flow**.

A real project of the Captain's own is the most valuable instrument this lane could have,
because it is the one oracle the conformance corpora structurally cannot be: **the corpora
prove the ports agree; only an artist making a real thing proves the tool is good.** The
vision says as much in its own terms — *"the artist is the aesthetic oracle"*
(`VISION.md:258`).

**§3's ordering should follow this project's needs, and the sitting built exactly one hook
for that: §3.3's posed figure is GATED on the brainstorm rather than queued.** That is the
mechanism by which an answer from the artist can still reorder the build without anyone
having to reopen this document — and it is the only place in §3 where a milestone's
position is held open on purpose.

---

## 5. WHAT THE ROADMAP SITTING DECIDED

**Held 2026-09-03 (desk EV). All six questions this document asked are ruled, plus one
the Captain raised unprompted before them (R0, stated in the boundary block above).**
The record is `2026-09-03-ROADMAP-SITTING-minute.md`; where this summary and the minute
disagree, the minute wins.

**R0 — THE BOUNDARY (raised unprompted, ahead of the questions).** The framework stays
open; once AI-supported features are added the *product* becomes proprietary, in a private
fork rather than a directory in this tree. The intent ledger's schema is open, its
reasoning proprietary. **Consequence: §3.1 is described here at API level only.** Full
statement in the boundary block near the top of this document.

**Q1 — §4.1, the Last Supper, in his words. ANSWERED, and the question's premise was
wrong.** The record exists, filed under another name and ratified 2026-07-27. §4.1 fills
by pointer; §4.0 carries the erratum; §4.2's ten questions become the agenda of the
brainstorm session, which is the Captain's to call. The design block announced in July and
never scheduled now has an owner (that brainstorm) and a trigger (the naming of the
private fork).

**Q2 — the ordering of §3 after Windows. RULED: §3.1 (the AI operation API) FIRST, THEN
§3.2 (gesture/pressure)** — against this document's own recommendation, which is preserved
below rather than quietly edited out. Reasons of record: the founding document holds that
the collaboration layer alone is buildable now; the AI channel proposes **operations**, not
pointer events, so the retrofit worry bears on the gesture-to-operation mapping and not on
the agent loop; and the brainstorm is the oracle that will order §3.3–§3.9 anyway.
**Cost accepted, not overlooked: the shaper (§3.4) waits one extra step.**

**Q3 — the §3.8 animation tension. RULED: both passages stand; animation is DEFERRED
INDEFINITELY**, reopened only on the Captain's word. The one discipline — no frame state
in the document, edit-time and playback-time separate — is a **standing, checkable rule**
that binds now. See §3.8.

**Q4 — which semantic relationship first. RULED: connectors, then mirrored eyes; the
posed figure (IK) is GATED on the brainstorm**, and jumps the queue with its own design
block if the composition needs posing. See §3.3.

**Q5 — does `VISION.md` get repaired now. RULED: yes, in a SEPARATE PR** — as this
document recommended. Only the four measured stale claims move, each to a sourced fact;
**`:396` is SPLIT, never ticked** (see §0 and §6); plus one new paragraph stating R0's
boundary, because the vision is where a reader looks for it. **This branch still does not
touch `VISION.md`.**

**Q6 — is "grander" direction or altitude. RULED: ALTITUDE** (`VISION.md:90-94`, *"one
road, not a fork"*), as this document read it. **§3 is the right list.** R0 is a business
line drawn across that road, not a turn off it.

### The recommendation this document made, and how it fared

Kept verbatim, because a recommendation that is quietly deleted after it loses teaches
nothing and a scoreboard of one is still a scoreboard.

> **After the Windows app: §3.1 (gesture/pressure), then §3.2 (the AI operation API).**
>
> - §3.1 is the **cheapest** of the grand items and is a measured, confirmed gap (§0)
>   rather than an inferred one.
> - It is a **prerequisite** for the shaper (§3.4), which is the most completely specified
>   unbuilt feature in the founding notes and has never been queued.
> - It is the **least reversible to get wrong**. `VISION.md:210-212` claims one operation
>   vocabulary with three input channels; two of the three exist. Adding the third *after*
>   the AI channel is built means retrofitting the event vocabulary underneath a live agent
>   loop — expensive to change, and exactly the "structural, not a bolt-on" shape
>   `VISION.md:219-221` warns about for performance hooks.
>
> **But §4.1 outranks this recommendation.** If the Last Supper needs perspective grids or
> figure posing, the order changes, and it should.

*(In the numbering of this version, that recommendation reads: gesture — now §3.2 — before
the AI operation API, now §3.1.)*

**Scored honestly: one right, one wrong, and the last line was the important one.** Q5 and
Q6 went as recommended. **Q2 did not**, and the ruling's counter-argument is the one this
document could not have made for itself: the third input channel carries *operations*, so
the retrofit risk it priced sits in the gesture-to-operation mapping rather than under the
agent loop — which makes the ordering much less irreversible than the recommendation
claimed. And the closing sentence — *"§4.1 outranks this recommendation"* — turned out to
be the operative one, since §4.1 was not empty at all.

---

## 6. WHAT I DID NOT VERIFY — stated as negatives

The house rule: report clean negatives as negatives, and never let an unmeasured thing sit
next to a measured one without a label.

- **The Swift suite's "5 known issues."** The run passed (exit 0, 3028 tests), but the
  runner reported five *known issues* and **I did not open them.** A known-issue count is
  a suppressed-failure count wearing a green hat; it belongs in this section, not in the
  suites table alone. Nothing in this roadmap depends on it, and nobody should read
  "Swift green" from §2.1 without also reading this line.
- **The browser lane** (69/69) is **2026-09-02's** number, re-verified on merged main
  then, not re-run for this document. `main` has moved since, more than once. **A commit
  count here would be wrong by the time anyone read it, so there is not one** — compare
  the dates against the repository if the number matters to you.
- **The Direct2D half of anything.** `direct2d/` does not compile in this seat, so every
  Windows statement in §2.4 is sourced from PR `#69` and the council ruling — **reasoned
  and quoted, not measured by me.**
- ✅ **`VISION.md:396` — RESOLVED since this draft, and the resolution is recorded here
  rather than moved, so the negative and its discharge sit together.** The draft said *"I
  did not determine whether it discharges the item"*. It has since been measured against
  the item's **definition** rather than its sentence — the line names two artifacts, and
  the second is defined elsewhere in the corpus as **four** named sub-checks. Result:
  **HALF discharged.** Both parity guards ship, CI-wired and self-tested. Of the four
  cross-reference sub-checks, one ships (and twice over), one is partial, and **two are
  absent.** ⇒ It is not a fifth stale row; it is a different *kind* of row, and §5 Q5
  rules that it must be **split, never ticked**.
  **The honest residue — three real, named, unbuilt gates**, which is the first concrete
  work §3 can point at below the milestones: a `$state`-read declaration gate; a workspace
  duplicate-id gate; and schemas for panels, dialogs, menubar, toolbar and actions, which
  is what would make the enum check real rather than partial.
- ⚠️ **A defect found while measuring the above, not repaired here.**
  `workspace_interpreter/validator.py`'s docstring names itself the home of two validation
  layers it does not implement, and withdraws the claim four lines later in the shape of a
  status note. **Read the code, not the docstring, even when the docstring is the
  subject** — quoting its layer list would have reported a layer as shipped. It needs its
  own small PR, or to be folded into whatever is built for the cross-reference layer.
- **Effort, cost, and sequencing for every item in §3.** No estimate on this page is
  measured, which is why there are none.
- **Whether §3 is complete.** It is derived from the written record. The record is not the
  Captain, and §4 is the standing proof that a substantial part of his intent has never
  been written down at all.

---

*Prepared by the jas seat, 2026-09-03, for the roadmap sitting (desk EV) and revised the
same day to carry its rulings. Measured at `main` `a179efe4`. Nothing in §4 is invented;
nothing in §1 is paraphrased; §4.0 records where the draft was wrong rather than hiding
it. The sitting's minute — `2026-09-03-ROADMAP-SITTING-minute.md` — is the record for
every ruling cited above.*
