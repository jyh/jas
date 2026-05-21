# I built five vector illustration apps in seven weeks of evenings. Here's what made it possible.

I have used Adobe Illustrator since 1990 — for engineering drawings at
work, for visual art outside work. I have always been frustrated by my
inability to extend it: features I'd want, platforms it didn't support,
workflows it didn't accommodate. Building a serious vector illustration
application has always seemed out of reach. Illustrator is the work of
decades and a sustained team.

This spring I spent seven weeks of evenings testing whether AI-paired
engineering, with Claude Code, could change that. The result is five
working ports of a vector illustration application, sharing a single
executable specification, developed in approximately 120 hours.

It's not a complete clone of Illustrator. It's enough to demonstrate that
the scope is no longer hopeless for one person.

**What I built.** Five platforms:

- Rust (Dioxus) — high-performance web
- Swift (SwiftUI) — macOS and iOS
- OCaml (GTK/Cairo) — desktop
- Python (PySide6/Qt) — cross-platform desktop
- Python + Flask — browser sketch

Each port supports 27 tools, 14 panels, 22 dialogs, vector paths, text
with paragraph and character styling, layers, transforms, undo, document
save and restore, and PDF export. Across all five: ~336,000 lines of
code, 4,600 automated tests, 36 manual-test transcripts, 1,807 commits
across 48 days.

**The thesis.** AI is the productivity engine. But raw AI productivity
collapses into debugging without two specific safeguards: a precise
executable specification, and parallel implementations as a correctness
check.

**Condition 1: A precise executable specification.** The project's
specification — 23,000 lines of YAML — is the single source of truth.
Each port has a generic interpreter that reads YAML and constructs
working UI. When a feature is added, the YAML changes once and
propagates to all five ports.

Concretely, for the Color Panel:

- 890 lines of shared YAML
- 0 lines of native code in OCaml (generic interpreter sufficient)
- 59 lines in Swift (state-bridge)
- 123 lines in Python (one custom widget)
- 1,309 lines in Rust (custom canvas widgets)
- 0 lines in Flask (server-side YAML-driven)

Five working color panels from 890 lines of shared specification plus
~1,500 lines of platform-specific glue. The spec amortizes the
conceptual work across N implementations.

**Condition 2: Parallel implementations as differential testing.** Five
ports producing visibly different output reveals a flaw — either in the
spec (it permits more than one interpretation) or in one of the ports
(it has a bug), or both.

This is differential testing applied to interactive UI. Compiler people
have been doing this since 1998 (CSmith). It was abandoned for
application code because building N independent implementations was too
expensive. AI changes that argument.

N-version programming was proposed in 1985 as a path to software
reliability. It died because the cost of N independent implementations
exceeded the reliability benefit. The first half of that argument
doesn't hold any more. AI handles the per-port mechanical work. N
implementations become feasible for one developer.

The economic argument for N implementations — once impractical, now
feasible — is to me the most durable claim of this work.

**Methodology, briefly.** Two iterative loops. The outer loop turns
prose design documents into the YAML specification, using a specific
prompt that asks Claude to rank inconsistencies and completeness issues
by priority. The inner loop turns specification into working software
across all five ports, with manual cross-port testing catching
divergence. Memory persists across sessions — 57 memory entries
accumulated, capturing decisions, corrections, and project state.
Periodic codebase-review prompts catch drift.

The slowest part is manual testing. Automated tests catch state-level
regression; visual, timing, and behavioral details require human
inspection. The Color Panel alone defines 98 numbered manual test
scenarios that I ran across each port and marked with pass dates.

**What didn't work.** AI failure modes recurred throughout:

- Long-context drift in extended sessions (memory mitigates)
- Confident hallucinations of file paths and symbols (grep first)
- Optimistic completion summaries (always read the diff)
- Spec underspecification surfacing only at integration time (the
  methodology working as designed)

The safety net for `--dangerously-skip-permissions` mode was the
combination of automated tests, manual testing, and N implementations.
A destructive change would either break a test or produce a visible
divergence between ports.

**Honest caveats.** This is one developer's experience. I have 35 years
of background in vector illustration applications and deep expertise in
OCaml and Python (less in Swift and Rust). A novice might get smaller
gains; we don't know yet. The 120-hour estimate is from commit
timestamps, not tracked time. The scope comparison to Illustrator (since
1987) or Inkscape (since 2003) is a scope anchor, not a measured
baseline. The methodology depends on a domain that can be described
declaratively; it likely doesn't generalize to game engines or kernel
code.

The methodology also assumes AI capable of producing per-port mechanical
work at low cost. That's true today with Claude Opus 4.6 and 4.7. It
will look different at different model capability levels and in
different tooling environments.

**Why this matters.** For multi-platform application UI, the
conventional cost has been multi-developer-year teams. The combination
of executable spec + N implementations + AI for the mechanical work
changes that cost structure. The full technical writeup is at arxiv.
Source code and methodology documents at github.com/jyh/jas.
