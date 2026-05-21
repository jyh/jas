# Five Implementations, One Spec: AI-Paired Engineering as a Revival of N-Version Programming

Jason Hickey · Independent
jasonh@gmail.com · github.com/jyh/jas

> Work performed on personal time, independent of the author's employer.
> Views and opinions are the author's own and do not represent any organization.

---

## Abstract

I report a case study in AI-paired software engineering: five working ports
of a vector illustration application across Rust, Swift, OCaml, Python, and
browser-based platforms, built by a single developer in approximately 120
evening hours. The methodology pairs AI-assisted implementation with two
safeguards — a precise executable YAML specification serving as the single
source of truth, and parallel implementations functioning as a built-in
differential-testing layer. The five ports share a 23,000-line specification;
per-port native code ranges from 0 to roughly 95,000 lines, reflecting the
specification's escape hatch. I argue that AI-paired engineering, conditional
on these two safeguards, makes feasible scope of work that conventionally
requires multiple developer-years, and frame the methodology as a revival of
N-version programming, a 1980s approach abandoned on cost grounds that AI
changes. The paper reports concrete artifacts and honest limitations of the
single-developer case study.

---

## 1. Introduction

Mature vector illustration applications — exemplified by Adobe Illustrator and
Inkscape — represent decades of team development. I have used vector
illustration applications, primarily Adobe Illustrator, since 1990, for
engineering drawings in my professional work and for visual art outside it.
Such applications have long seemed to put extending them — adding features,
porting to new platforms — out of reach for individuals. This project began as
a test of whether AI-paired engineering could change that.

The artifact is five working implementations of a vector illustration
application, sharing a single executable specification and developed by one
developer over approximately 120 evening hours across seven calendar weeks.
The five implementations span Rust/Dioxus, Swift, OCaml, Python/PySide6, and a
browser-based Flask sketch — five languages, five paradigms, five UI
frameworks. The shared specification is approximately 23,000 lines of YAML;
per-port native code ranges from a few thousand to roughly 95,000 lines,
reflecting a specification escape hatch for platform-specific concerns.

This paper reports the methodology. Its central claim is that AI-paired
engineering, when paired with two specific safeguards, makes feasible for a
single developer a body of work that would conventionally require multiple
developer-years. The safeguards are:

1. **A precise, executable specification** serving as the single source of
   truth. The specification consolidates design decisions into one artifact
   and is rendered into all N implementations by shared and per-port renderer
   code. Its cost is paid once and amortizes sub-linearly across N
   implementations.

2. **Parallel implementations functioning as a built-in correctness check.**
   Each port stress-tests the others and exposes places where the
   specification is underspecified. Per-port cost is linear in N; correctness
   gain is sub-linear but real — particularly in catching the visual and
   behavioral divergences that automated tests miss.

I argue these two safeguards can be understood as a revival of N-version
programming [Avizienis 1985] — a 1980s methodology that called for multiple
independent implementations to improve reliability, but was largely abandoned
because the cost of producing N independent implementations exceeded the
reliability benefit. AI fundamentally changes that economic argument. With
AI handling most of the per-port mechanical work, N implementations of a
single specification become feasible for a single developer, and the
resulting differential-testing layer makes the productivity claim defensible
without sacrificing correctness.

**Contributions.** This paper contributes:

- A case study of a single developer producing five platform-spanning
  implementations of a complex desktop application across seven weeks of
  evening work.
- A specific methodology pairing an executable specification with parallel
  implementations as a differential-testing layer.
- A field report on AI-paired software engineering in practice, including
  concrete prompts, persistent memory patterns, delegation strategies, and
  honest failure modes.
- An open-source artifact (github.com/jyh/jas) and a reusable manual-testing
  protocol.

**Paper structure.** Section 2 describes the project setup. Section 3
introduces the executable specification (Condition 1). Section 4 reports on
parallel implementations as a correctness check (Condition 2). Section 5 is a
field report on AI-paired engineering in practice. Section 6 presents the
evidence supporting the scope claim. Section 7 discusses limitations, Section
8 positions the work in the literature, and Section 9 concludes.

---

## 2. Setup

The project began with a deliberate choice to span five platforms rather than
focus on one. Two motivations drove this. First, multi-platform implementation
served as a test of the methodology: if the same specification could drive
five visibly equivalent ports across five disparate UI frameworks, the
specification was load-bearing enough to be useful, not just a documentation
artifact. Second, multiple implementations provided what would become this
paper's second condition — a built-in correctness check. The five platforms
were selected to span paradigms, ownership models, and runtime
characteristics.

**The five implementations.**

- *jas_dioxus* (Rust, Dioxus framework) offers strict memory and concurrency
  guarantees and targets a high-performance web application. Rust's policy
  strictness was hypothesized to be a stress test for AI code generation; in
  practice it became the largest port by line count but not the most
  difficult to develop.

- *JasSwift* (Swift, SwiftUI) targets macOS and iOS, providing
  hardware-accelerated rendering and platform-native UI conventions.

- *jas_ocaml* (OCaml) prioritizes safety and explicit interface management.
  The author has long experience in OCaml[^rwocaml] and treated this
  implementation as a control case for whether AI-paired engineering could
  match the speed of expert-language development.

- *jas* (Python, PySide6) prioritizes development speed and serves as a
  desktop reference using Qt's mature cross-platform widget set.

- *jas_flask* (Python + Flask + HTML/JavaScript) is a server-rendered
  reference and early UI sketching ground. Its behavior is fully YAML-driven,
  with no per-feature server code, and it is not feature-complete in the
  sense the four native ports are.

[^rwocaml]: The author co-authored *Real World OCaml*, O'Reilly Media.

**App scope.** The application implements a substantial subset of the feature
set found in mature vector illustration applications: 27 tools (Pen, Pencil,
Paintbrush, Blob Brush, Eyedropper, Magic Wand, Lasso, Path Eraser, Hand,
Zoom, Selection, transforms such as Scale and Rotate, and shape tools), 14
panels (Color, Swatches, Layers, Stroke, Brushes, Character, Paragraph,
Align, Artboards, Opacity, Gradient, Boolean, Properties, and Magic Wand),
and 22 dialogs (Color Picker, Document Setup, Print Preferences, Brush
Options, Hyphenation, Justification, and others). The application supports
vector paths, text with paragraph and character styling, layers, transforms,
undo, document save and restore, and PDF export. Across the five ports the
project includes approximately 4,600 automated test functions and 36 manual-
test transcript files; the Color Panel alone defines 98 numbered manual
scenarios.

**Comparison anchors.** Adobe Illustrator has been developed continuously
since 1987, representing roughly 39 years of large-team work. Inkscape, the
leading open-source comparison, has been under continuous development since
2003. Commercial alternatives such as Affinity Designer and Figma also
represent multi-developer-year efforts by sustained teams. The artifact
described in this paper does not match these in feature completeness — it
lacks gradient mesh, advanced text shaping at the level of professional
typesetting engines, raster effects, full SVG round-trip fidelity, plugins,
and color management beyond basic profiles. Its contribution is not in
matching mature applications, but in demonstrating that a substantial subset
is achievable by a single developer in dramatically less time under a
specific methodology.

---

<!-- DRAFT IN PROGRESS — sections 3–9 forthcoming -->
