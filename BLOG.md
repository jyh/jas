# I built five vector illustration apps in seven weeks of evenings — here's what made it possible

## Why this project

I have used Adobe Illustrator since 1990. I use it at work for technical
drawings — engineering diagrams, schematics, system layouts — and outside
work for visual art. I have always been frustrated by my inability to
extend it: a feature I'd like, a platform it doesn't support, a workflow
it doesn't accommodate.

Building a serious vector illustration application has always seemed out
of reach. Illustrator is the work of decades and a sustained team.
Inkscape, the leading open-source comparison, has been under continuous
development since 2003. A single person doesn't build something at that
scale.

That intuition was probably right in 2023. I'm not so sure it's right
today.

This spring I spent seven weeks of evenings testing whether AI-paired
engineering could change the answer. The result is five working ports of
a vector illustration application, sharing one specification, developed
in approximately 120 hours of evening work. It's not a complete clone of
Illustrator — significant pieces are missing — but it's enough working
software to make the question worth taking seriously.

This post is about what I did, what made it work, and where the
methodology breaks. The arxiv paper has the careful version; this is the
narrative one.

---

## What I built

The artifact spans five languages and five UI frameworks:

- **Rust** (Dioxus framework) — high-performance web app
- **Swift** (SwiftUI) — macOS and iOS native
- **OCaml** — GTK / Cairo desktop
- **Python** (PySide6 / Qt) — cross-platform desktop
- **Python + Flask** — server-rendered browser sketch

Each is a working desktop-class vector illustration tool. They share 27
tools (Pen, Pencil, Paintbrush, Blob Brush, Eyedropper, Magic Wand,
Lasso, transforms, shapes), 14 panels (Color, Swatches, Layers, Stroke,
Brushes, Character, Paragraph, Align, Artboards, Opacity, Gradient,
Boolean, Properties, Magic Wand), and 22 dialogs (Color Picker, Document
Setup, Print Preferences, and others). The applications support vector
paths, text with paragraph and character styling, layers, transforms,
undo, document save and restore, and PDF export.

Across the five ports the project totals approximately 336,000 lines of
code, with 4,600 automated tests and 36 manual-test transcript files.
There are 1,807 commits across 48 calendar days. The Color Panel alone
defines 98 numbered manual test scenarios.

It's still missing things. There's no gradient mesh, no professional
text shaping, no plugins, no full SVG round-trip fidelity, no proper
color management. It's not Illustrator and isn't trying to be. It's
enough to demonstrate that the scope is no longer hopeless for one
person.

---

## The methodology

The work proceeded through two iterative loops.

**The outer loop turns ideas into specifications.** I would write a
design document in English — what the feature should do, how it should
behave, what edges I could think of. Then I would run a specific prompt:

> *Please read and understand these requirements. Analyze them for
> inconsistencies and completeness. Make suggestions for improvements.
> Rank your responses in priority from high to low, and giving each a
> number. What are the benefits? What are the downsides? Be ready for a
> deep dive into any of the suggestions.*

The AI would return a ranked list of issues. I would pick the ones that
mattered and we would deep-dive each. The design document would be
rewritten with the clarifications. Only then would the YAML specification
be written.

This loop turned out to be the most important habit of the project.
Without it, the AI would produce plausible-looking code that subtly
missed what I actually wanted. With it, design issues surfaced before
they became implementation work.

**The inner loop turns specifications into working software.** The YAML
spec was picked up by each port's renderer and produced working UI. I
would run the application, exercise the feature, and look for places
where the behavior didn't match what I expected. Most differences turned
out to be spec gaps — the spec hadn't pinned down something subtle enough
to force the implementations to agree.

**Periodic codebase review.** Every week or two:

> *Review the entire codebase and evaluate it for clarity,
> maintainability, efficiency, complexity, safety, test coverage,
> pattern consistency, conformity with style conventions, functional
> equivalence across languages, and anything else of importance. Make
> suggestions for improvements, ranking them in priority from high to
> low, and giving each a number.*

This catches drift. By the time you've made fifty small changes, some
pattern has subtly diverged from the original intent. The review surfaces
it.

**Memory across sessions.** Claude Code maintains a file-based memory
system. Over seven weeks I accumulated 57 memory entries — corrections
that should stick, project state, references. Without it, every session
would start fresh. With it, the AI carried forward what I had already
taught it.

---

## The two conditions

Two specific things made AI-paired engineering work at this scale. Both
have to be in place. Either alone collapses.

**Condition 1: A precise executable specification.** The YAML
specification — roughly 23,000 lines across the project — is the single
source of truth. Each port has a generic interpreter that reads the YAML
and renders working UI. When a button is added, the YAML changes once,
and all five ports show the button. When a behavior is refined, it is
refined in one place.

The Color Panel shows this concretely:

- 890 lines of shared YAML across four files (panel, dialog, two
  templates)
- 0 lines of native code in OCaml (the generic interpreter is enough)
- 59 lines in Swift (a state-bridge file)
- 123 lines in Python (one custom widget)
- 1,309 lines in Rust (custom canvas widgets for the gradient and hue
  bar)
- 0 lines in Flask (fully YAML-driven server-side)

Five working color panels from 890 lines of shared specification plus
about 1,500 lines of platform-specific glue. That is the spec amortizing
across N implementations. The spec is the productivity multiplier.

**Condition 2: Parallel implementations as a correctness check.** Five
ports producing visibly different output reveals a flaw. Either the
spec permits more than one interpretation, or one of the ports has a
bug, or both. The shared specification provides the contract; the
parallel implementations provide the cross-check.

This is differential testing, applied to interactive UI by a single
developer. Compiler people have been doing this since 1998 — the CSmith
project found bugs in production compilers by running them on the same
test programs and comparing output. It was abandoned for application
code because building N independent implementations was too expensive.
AI changes that economic argument.

N-version programming was proposed in 1985 as a path to software
reliability. It died because the cost of building N independent
implementations exceeded the reliability benefit, and because empirical
work (Knight and Leveson, 1986) showed independent implementations often
failed in correlated ways anyway. The first half of that argument does
not hold any more. The second half is honestly weaker for AI-generated
implementations than for human-team ones — they share priors from
training data — but five ports across five UI frameworks and five
rendering models still provide real diversity.

The economic argument for N implementations — once impractical, now
feasible — is to me the most durable claim of the work. AI productivity
numbers will move around. The fact that producing N implementations
against a shared specification is now cheap, when it used to be
expensive, will not.

---

## Stories from the field

Some specific moments that illustrate the methodology working.

**The hue-collapse bug.** Dragging the Saturation slider to zero in HSB
mode forced Hue to zero in two of the four native ports. This is
mathematically defensible — at S=0 the hue is meaningless — but
user-hostile. Dragging Saturation back up produces red, not the green
you were just working with. OCaml and Swift preserved the hue; Python
and Rust snapped it. Cross-port testing found the bug in the first hour
of Color Panel testing. The specification was updated to require
explicit preservation of degenerate channels. Each port was fixed. The
exact same pattern surfaced again for K=100 in CMYK mode a few days
later.

**The dialog OK bug.** Type a new hex value into the color picker, press
OK. In four of five ports the color updates correctly. In Python the
dialog closes but the color reverts to the previous value. The cause:
the dialog's evaluation context had cached the hex field's value before
the typed-in value flowed through the state model. This kind of bug
would be silent in a single-implementation project. With five
implementations side by side, it stuck out.

**The over-flagging subagent.** During a code review, I asked an AI
subagent to check a Swift file. It flagged `@ObservedObject` patterns as
bugs. They weren't bugs — they were the textbook-correct pattern for
SwiftUI when the object's owner is upstream. The subagent had narrow
context and over-flagged. I learned to verify subagent diagnoses against
the ownership chain rather than trust the summary. That lesson became a
permanent memory entry.

**The "I implemented X" lie.** The AI occasionally reported a task
complete when it was actually partial. It would describe what it had
done, in confident prose, while having left out an important piece.
The fix isn't to argue with the summary — it's to read the diff.
Always read the diff.

---

## What this means

I think the methodology — executable spec, AI-paired implementation, N
implementations as differential testing — generalizes to a particular
shape of work: applications that can be described declaratively, with
multiple platform targets, and a feature surface large enough that AI
productivity gains compound.

I don't think it generalizes everywhere. Domains with deep imperative
interaction — game engines, kernel code, real-time systems — don't fit.
Domains with one obvious platform — pure backend services, command-line
tools — don't need N implementations. The sweet spot is multi-platform
application UI, which happens to be one of the more painful kinds of
conventional software development.

The methodology also assumes AI capable of producing per-port mechanical
work at low cost. That is true today with Claude Opus 4.6 and 4.7. A
less capable model or a less integrated tooling environment would shift
the picture.

---

## Caveats

This is one developer's experience. I have 35 years of background in
vector illustration applications and deep expertise in OCaml and Python
(less so in Swift and Rust). A novice attempting this methodology might
get smaller gains; we don't yet know how much smaller. There is no
control group, no replication, no controlled comparison.

The 120 hours is approximate, derived from commit timestamps rather than
tracked time. The order-of-magnitude comparison to Illustrator's decades
or Inkscape's twenty years is a scope anchor, not a measured baseline.

The full technical writeup is at arxiv. Source code and methodology
documents are at github.com/jyh/jas.
