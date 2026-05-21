# Article: Five Implementations, One Spec — Blueprint

This document is the planning blueprint for an article about the jas project.
It replaces the earlier brain-dump notes and captures all decisions made during
planning. Updates: append or modify; do not delete history without intent.

---

## 1. Thesis

> AI-paired engineering, when paired with (1) a precise executable specification
> and (2) parallel implementations as a correctness check, makes feasible for a
> single developer a body of work that would conventionally require multiple
> developer-years.

**Lead claim:** Scope-flavor productivity. The artifact is the existence proof;
no specific multiplier is asserted in the arxiv version. The blog/LinkedIn/X
versions lead with the artifact ("5 vector illustration apps in 7 weeks of
evenings"), with productivity as an implication, not a measured rate.

**Mechanism 1 — Spec = productivity enabler.** Sub-linear cost. The spec
amortizes conceptual work across N implementations; per-port cost drops to
mechanical work that AI handles well.

**Mechanism 2 — N implementations = correctness enabler.** Linear cost,
sub-linear correctness gain. Each port pressure-tests the spec and exposes
underspecification.

---

## 2. Title and abstract

### arxiv title

**Five Implementations, One Spec: AI-Paired Engineering as a Revival of N-Version Programming**

### Blog title

*I built five vector illustration apps in seven weeks of evenings — here's what made it possible*

### X opener (~12-tweet thread)

Tweet 1 leads with the N-version revival claim. Tweet 12 closes with soft
signal toward AI tooling roles + GitHub / LinkedIn links.

### Abstract (~160 words, first-person singular)

> I report a case study in AI-paired software engineering: five working ports
> of a vector illustration application across Rust, Swift, OCaml, Python, and
> browser-based platforms, built by a single developer in approximately 120
> evening hours. The methodology pairs AI-assisted implementation with two
> safeguards — a precise executable YAML specification serving as the single
> source of truth, and parallel implementations functioning as a built-in
> differential-testing layer. The five ports share a 23,000-line specification;
> per-port native code ranges from 0 to roughly 95,000 lines, reflecting the
> specification's escape hatch. I argue that AI-paired engineering, conditional
> on these two safeguards, makes feasible scope of work that conventionally
> requires multiple developer-years, and frame the methodology as a revival of
> N-version programming, a 1980s approach abandoned on cost grounds that AI
> changes. The paper reports concrete artifacts and honest limitations of the
> single-developer case study.

---

## 3. Paper structure (Hybrid, ~10 pages)

| # | Section                                            | %   | Pages | Notes |
|---|----------------------------------------------------|-----|-------|-------|
| 1 | Introduction                                       | 10% | ~1    | Thesis, contributions, personal hook (moderate; "I" voice; "primarily Adobe Illustrator since 1990") |
| 2 | Setup                                              | 10% | ~1    | 5 stacks with rationale; app scope; Adobe Illustrator + Inkscape as scope anchors |
| 3 | The executable specification                       | 20% | ~2    | Condition 1; Color Panel YAML as running example; cite K-Framework / WebAssembly lightly |
| 4 | Parallel implementations as correctness check      | 20% | ~2    | Condition 2; 5 Color Panel vignettes; cite CSmith + Avizienis 1985 (strong N-version revival claim) |
| 5 | AI-paired engineering in practice                  | 15% | ~1.5  | 6 subsections (see §5 below); very candid; prompts quoted verbatim; Claude Code features named |
| 6 | Evidence and results                               | 10% | ~1    | Numbers table; commit timeline; Inkscape / Illustrator scope anchors |
| 7 | Limitations                                        | 5%  | ~0.5  | 5 categorical paragraphs; Claude Opus 4.6/4.7 named explicitly |
| 8 | Related work                                       | 3%  | ~0.3  | 4 paragraphs: exec specs / differential testing + N-version (strong revival claim) / AI productivity / comparable applications |
| 9 | Conclusion                                         | 2%  | ~0.2  | Restate; gesture at generalization; point to repo |

### Voice and tone

- First-person singular ("I"), single-author conventions
- Confident on artifact; measured on productivity claim
- Honest on failure modes
- Cite METR 2025 and acknowledge it measures something different (per-task speed,
  not project-scope feasibility)

---

## 4. Color Panel as running example

Used in §3 (spec), §4 (N implementations / vignettes), §5 (AI methodology
examples). Numbers from measurement:

| Source              | LOC   |
|---------------------|-------|
| color.yaml          | 493   |
| color_picker.yaml   | 250   |
| color_picker_fields.yaml | 37 |
| fill_stroke_widget.yaml | 110 |
| **YAML subtotal**   | **890** |
| jas (Python) — color_bar_widget.py | 123 |
| jas_dioxus — color_panel_view + color_panel + fill_stroke_widget | 1,309 |
| JasSwift — ColorPanelSync.swift | 59 |
| jas_ocaml — *no dedicated files* | 0 |
| jas_flask — *server-side YAML* | ~0 |
| **Native subtotal** | **~1,491** |
| Manual test scenarios (CLR-001..263) | 98 |

**Headline:** 890 lines of shared YAML → 5 working color panels. Native
overhead ranges from 0 (OCaml, pure YAML) to 1,309 (Rust, custom canvas
widgets). This asymmetry is the strongest single demonstration of spec
amortization with a working escape hatch.

### Vignettes (concrete bugs caught by N implementations)

Each demonstrates spec underspecification exposed by differential testing.
Each is one paragraph in §4.

1. **H collapses to 0 when S→0.** Dragging Saturation to zero forced Hue to
   zero in some ports. Found via differential testing — other ports preserved
   H. Forced spec to specify "preserve prior H when S=0 because HSB is
   degenerate at S=0."

2. **K=100 forces C/M/Y to 0.** CMYK at K=100 is fully black regardless of
   CMY, but channel values still need preservation for when K is reduced.

3. **Web Safe RGB snap.** Snapping had to happen on write, not on display,
   otherwise switching modes would un-snap. Three ports got this wrong
   differently.

4. **Hex commit reverts on dialog OK.** State-mirror bug where typing into
   the hex box flipped color, but the eval context kept a stale snapshot.
   Found via cross-port testing where some ports cached and some didn't.

5. **Recent colors push during slider drag.** Should only push on release,
   not during drag. Several ports got this wrong by reusing the panel's hex
   commit path.

---

## 5. Section 5 detail — AI-paired engineering in practice

Six subsections, total ~1.5 pages. Very candid; quotes prompts verbatim;
names Claude Code features specifically.

### 5.1 The dialog-and-review loop (~0.3 page)

Quote analysis prompt and codebase-review prompt verbatim:

> *Please read and understand these requirements. Analyze them for
> inconsistencies and completeness. Make suggestions for improvements. Rank
> your responses in priority from high to low, and giving each a number. Be
> ready for a deep dive into any of the suggestions.*

> *Review the entire codebase and evaluate it for clarity, maintainability,
> efficiency, complexity, safety, test coverage, pattern consistency,
> conformity with style conventions, functional equivalence across languages,
> and anything else of importance. Make suggestions for improvements, ranking
> them in priority from high to low, and giving each a number.*

Five-step loop: design doc → analysis prompt → conversation → rewrite spec →
implement. Periodic codebase review consolidates drift. Note CLAUDE.md as
project-level persistent instruction file.

### 5.2 Memory as persistent state (~0.3 page)

- 57 memory entries accumulated across the project
- Four types: user, feedback, project, reference
- Claude Code auto-memory persists across sessions

Sample memory entry as Figure 5.

### 5.3 Manual testing as the dominant remaining cost (~0.3 page)

- Largest share of remaining developer time
- Per-component _TESTS.md transcripts with per-port pass dates
- Catches what automated tests miss: rendering, timing, focus, theme
- Quoted: "Sometimes easy, sometimes challenging but generally not
  fundamental" — direct from the source brain-dump

### 5.4 Delegation patterns: when subagents help, when they hurt (~0.3 page)

- Helps: parallel research, isolated lookups, mechanical multi-file changes
- Hurts: cross-file design questions, ownership-chain reasoning,
  "is this bug real" questions
- Memory captures specific failure modes (e.g., subagents over-flag Swift
  `@ObservedObject` as bugs without tracing ownership)
- Rule: subagent summaries describe intent, not effect; verify the diff

### 5.5 Honest failure modes (~0.3 page)

- Long-context drift (AI loses earlier decisions in extended sessions)
- Confident hallucinations of file paths / symbol names
- Optimistic completion summaries ("I implemented X" when X is half-done)
- Spec underspecification surfacing late (this is what makes N
  implementations valuable, but it's also a failure mode of the spec)
- `--dangerously-skip-permissions` trade-off — productivity essential, safety
  comes from spec + N + tests

### 5.6 Tooling implications and recommendations (~0.2 page)

**Features that mattered most:**
- Persistent memory across sessions
- File-editing tools (Edit, Write, Read)
- --dangerously-skip-permissions trust mode
- CLAUDE.md project-level instructions
- Long-context window (1M tokens) reducing re-explanation cost
- TaskList for tracking multi-step work
- Slash commands for repeatable prompts

**Features I'd want from future versions:**
- Stronger guardrails against hallucinated symbols
- Better cross-session retention without explicit memory writes
- Collaborative shared memory across developers
- More principled handling of "design fork" decision points

**Honest scope limit:** Methodology is tuned to current Claude Code + Claude
Opus 4.6/4.7. Replication on different stacks may need adjustment.

---

## 6. Evidence table

| Category | Value |
|---|---|
| **Effort** | |
| Calendar | 48 days (2026-04-02 → 2026-05-20, ~7 weeks) |
| Active days | 40 |
| Estimated developer-hours | 120–160 |
| Commits | 1,807 |
| **Code volume** | |
| Native apps LOC (5 ports) | 300,605 |
| Shared YAML + interpreter LOC | 35,435 |
| Grand total | ~336,000 |
| **Tests** | |
| Automated test functions | 4,613 |
| Cross-language test files | 28 |
| Manual test transcripts | 36 |
| Manual test scenarios (CLR alone) | 98 |
| **Features** | |
| Tools | 27 |
| Panels | 14 |
| Dialogs | 22 |
| **Methodology artifacts** | |
| Memory entries | 57 |
| Design / spec docs | 45 |
| Cross-port-divergence commits | 32 (explicit) |
| Fix commits total | 80 |

### LOC by app

| App | Language | LOC |
|---|---|---|
| jas | Python (PySide6) | 59,069 |
| jas_ocaml | OCaml | 69,043 |
| jas_dioxus | Rust (Dioxus) | 95,371 |
| JasSwift | Swift | 71,883 |
| jas_flask | Python + HTML | 5,239 |

Ordering tracks language verbosity; sanity check that implementations do
comparable work.

---

## 7. Figures (5 total)

| # | Figure | Section | Size | Style |
|---|---|---|---|---|
| 1 | Methodology workflow diagram | §3 (or §2) | ~0.4 pg | Linear sweep |
| 2 | Color Panel screenshots × 5 | §4 | ~0.5 pg | Bare, port-name labels |
| 3 | Spec amortization stacked bar | §3 | ~0.3 pg | Shared YAML vs. native LOC per port |
| 4 | Color Panel YAML excerpt | §3 | ~0.4 pg | ~30 lines code listing |
| 5 | Sample memory entry | §5 | ~0.2 pg | Frontmatter + body code listing |

Total figure space: ~1.8 pages of ~10.

---

## 8. Related work citations (~10)

| Cite | Use |
|---|---|
| Avizienis 1985 | N-version programming, abandoned on cost; §4, §8 |
| McKeeman 1998 | Differential testing original; §4, §8 |
| Yang et al. 2011 (CSmith) | Differential testing in compilers; §4, §8 |
| Roşu & Şerbănuţă | K-Framework; §3, §8 |
| Haas et al. | WebAssembly reference interpreter; §3, §8 |
| Peng et al. 2023 | Copilot RCT (55% faster on task); §5, §8 |
| Ziegler et al. 2024 | Large-scale Copilot measurement; §8 |
| METR 2025 | Counter-result (AI slowed experienced devs); §5, §7, §8 |
| Inkscape project docs | Scope anchor; §6, §7, §8 |
| Adobe Illustrator (industry source TBD) | Scope anchor; §6, §7, §8 |

### Strong N-version revival claim

"N-version programming was proposed in 1985, largely abandoned because the
cost of developing N independent implementations exceeded the reliability
benefit. AI fundamentally changes that economic argument. This paper is, to
our knowledge, the first existence proof that N implementations developed
against a shared specification, with AI handling most of the per-port
mechanical work, are feasible for a single developer."

### Honest framing relative to METR 2025

"Controlled studies measure narrow tasks and report 0–80% productivity gains;
METR 2025 found negative effects on experienced developers in familiar code.
This paper complements those studies with a project-scale case report
measuring not per-task speed but feasibility of scope. The methodologies
measure different things; both contribute to understanding when and how AI
is useful."

---

## 9. Limitations (5 categorical paragraphs, ~0.5 page)

1. **Single developer, no controlled comparison.** N=1, no control group,
   no replication, ~120 hour estimate rough.
2. **Scope vs. mature applications.** Subset of features; no gradient mesh,
   advanced text shaping, plugins, full SVG round-trip; visual pixel
   conformance not measured.
3. **Developer expertise as confound.** 35 years vector illustration
   domain; OCaml + Python expert; less so in Swift/Rust. Acknowledge as
   straightforward limitation; do not argue against.
4. **Generalization limits.** Methodology requires spec-friendly domain.
   N-version revival claim contingent on AI capability. Manual testing
   scales linearly with N. AI implementations are not truly independent in
   the N-version programming sense.
5. **AI capability is a moving target.** Claude Opus 4.6/4.7 named
   explicitly. April–May 2026 snapshot. Workflow tuned to current model
   capability and Claude Code tooling.

---

## 10. Channel pipeline

| Order | Channel | Length | Voice | Timing |
|---|---|---|---|---|
| 1 | arxiv paper | ~10 pages | Academic, first-person singular | First publish (peer-review window) |
| 2 | Personal blog | ~2,000 words | Personal, reflective | Follow arxiv |
| 3 | LinkedIn post | ~1,000 words | Professional | Follow blog |
| 4 | X thread | ~12 tweets | Punchy, N-version-revival hook | Follow LinkedIn |

### Blog (~2,000 words)

| Section | Words | Tone |
|---|---|---|
| Why this project | ~250 | Personal — Illustrator since 1990, frustration, AI as experiment |
| What I built | ~300 | Concrete — 5 ports, what each is, screenshots |
| The methodology | ~400 | Methodology — dialog loop, codebase review, memory, manual testing |
| The two conditions | ~500 | Technical — spec amortization, N implementations as differential testing |
| Stories from the field | ~300 | Personal — specific bugs found by divergence, AI failure modes |
| What this means | ~150 | Reflection — what generalizes, what doesn't |
| Caveats | ~100 | Honest — one developer, snapshot in time |

### LinkedIn (~1,000 words)

Condensed from blog. Work-speaks recruiting approach — no explicit
"looking for opportunities" line. Mentions Claude Code by name as the tool.

### X thread (~12 tweets)

1. Hook (artifact)
2. Concrete details
3. Conventional comparison (Illustrator 1987, Inkscape 2003 vs. 7 weeks)
4. Thesis — AI as productivity engine + two safeguards
5. Safeguard 1: spec (with Color Panel numbers)
6. Safeguard 2: N implementations as differential testing
7. The unlock — AI revives N-version programming
8. Methodology — dialog loop, memory, manual testing
9. Numbers
10. What didn't work — honest failure modes
11. Honest limitations
12. Soft signal + links (arxiv, blog, GitHub, LinkedIn)

---

## 11. Author info and operational checks

### Author line (top of arxiv paper)

> Jason Hickey
> Independent
> jasonh@gmail.com · github.com/jyh/jas

### Footer footnote (first page)

> Work performed on personal time, independent of the author's employer.
> Views and opinions are the author's own and do not represent any
> organization.

### Operational checks before submission

1. Google's external publication policy review — confirm jas work clears
   the personal-time / non-employer-related carveout
2. Confirm IP belongs to author (standard prior-inventions clause)
3. Document the project's personal-time origin in writing (commit dates,
   personal GitHub, personal equipment) before publication
4. Optional: notify employer of impending publication if policy requires

---

## 12. Decision log (locked decisions from planning conversation)

| # | Decision | Choice |
|---|---|---|
| 1 | Scope claim vs. rate claim | Scope claim for paper; rate claim implicit |
| 2 | Productivity multiplier in title | None in arxiv; blog leads with artifact, no multiplier |
| 3 | Two conditions: weight | Equal weight; N gets more novel examples |
| 4 | Productivity vs. correctness as headline | Productivity lead (scope), conditions as enablers |
| 5 | Paper structure | Hybrid (recommended) |
| 6 | Examples to feature | Color Panel as sole running example |
| 7 | N-version revival claim | Strong |
| 8 | METR positioning | Cite and acknowledge as measuring different thing |
| 9 | K-Framework lineage weight | Light |
| 10 | Adobe Illustrator naming | Yes, in paper only; not in code/specs |
| 11 | Inkscape citation | Project documentation |
| 12 | Bibliography density | ~10 citations |
| 13 | Section 5 subsections | 5 (plus new 5.6 for tooling implications) |
| 14 | Candor on failure modes | Very candid |
| 15 | Prompt quotation | Verbatim in body |
| 16 | Personal dialog flavor | Moderate (no direct snippets) |
| 17 | Limitations depth | Light (~0.5 page) |
| 18 | Limitations organization | Five categories |
| 19 | Expertise confound treatment | Acknowledge as straightforward limitation |
| 20 | Name Claude model | Yes — Claude Opus 4.6/4.7, April–May 2026 |
| 21 | Personal narrative weight | Moderate (intro + limitations) |
| 22 | Voice | First-person singular |
| 23 | Background detail | "Primarily Adobe Illustrator, since 1990" |
| 24 | Personal narrative placement | Intro + limitations only |
| 25 | Figure count | 5 |
| 26 | Workflow diagram style | Linear sweep |
| 27 | Color Panel screenshots | Bare, port-name labels |
| 28 | Spec amortization viz | Stacked bar |
| 29 | Channels | All three: arxiv + blog + LinkedIn + X |
| 30 | Long-form derivative | Personal blog as canonical |
| 31 | X thread tone | Punchy, claim-led |
| 32 | Publication order | Arxiv first, blog + social follow |
| 33 | arxiv title | "Five Implementations, One Spec: AI-Paired Engineering as a Revival of N-Version Programming" |
| 34 | Abstract length | Medium (~160 words) |
| 35 | Blog title | "I built five vector illustration apps in seven weeks of evenings — here's what made it possible" |
| 36 | X opener | Lead with N-version revival claim |
| 37 | Section 5.6 added | Yes, ~0.2 page tooling implications |
| 38 | Claude Code feature naming | Specific (memory, subagents, --dangerously-skip-permissions, etc.) |
| 39 | Author info in paper | Name + GitHub + email + Google-disclaimer footnote |
| 40 | LinkedIn recruiting signal | None explicit; work-speaks |
| 41 | X closing | Soft signal + links |

---

## 13. Open items / next steps

- Verify Google external publication policy and personal-time IP clearance
- Draft Section 1 (Introduction) — first writing pass
- Draft Section 3 (Spec) — establish the YAML excerpt and Figure 4
- Draft Section 5 (AI in practice) — most distinctive section
- Sketch Figure 1 (workflow diagram) — linear sweep
- Take Color Panel screenshots in all 5 ports for Figure 2
- Collect actual bibliographic data for 10 citations
- Source for Adobe Illustrator citation (interview, industry survey, or
  version history)
