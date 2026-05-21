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

## 3. The executable specification

### 3.1 What the specification is

The specification is approximately 23,000 lines of YAML organized as a
directory tree under `workspace/`. It declares the application's panels,
dialogs, tools, menus, keyboard shortcuts, theme tokens, and document state
model. It is *executable* in the sense that each implementation contains a
generic interpreter that reads the YAML at startup and constructs working UI
directly from it, rather than treating the YAML as documentation that has
been re-encoded in each port.

Each declarative construct in the YAML has a corresponding native renderer
in each port. A `container` becomes a `VBox` in PySide6, a `VStack` in
SwiftUI, a `<div>` in HTML, a Cairo layout group in OCaml's GTK binding, and
a `dioxus::div` in Rust. A `number_input` becomes the platform's native
numeric-input widget. Behavioral semantics — bidirectional bindings, dialog
state with get/set lambdas, action dispatch, slider snap-on-write,
theme-aware styling — are also part of the YAML and are evaluated by the
same interpreter that constructs the widgets.

This approach has a lineage in executable specifications for language
semantics, discussed in Section 8. The contribution here is to apply the
pattern to interactive application UI: not just the static structure of the
interface, but its reactive behavior under user input.

### 3.2 The shared interpreter and the escape hatch

Each port carries two layers of code: a shared interpreter that loads YAML
and dispatches it through generic renderers, and a per-port escape hatch for
platform-specific concerns that the generic renderers cannot adequately
express. The shared interpreter is approximately 12,500 lines (originating
in Python and reused or ported to the other languages); the per-port
renderer layers vary substantially in size, reflecting how often each
platform requires native code that the generic dispatch cannot produce.

The escape hatch is not a flaw in the methodology; it is the methodology's
load-bearing flexibility. Custom canvas widgets, hardware-accelerated
drawing surfaces, platform-specific gesture handling, and complex state
synchronization with native UI frameworks (such as SwiftUI's reactive
`@ObservedObject` model) all fall outside what YAML can practically
describe. The discipline is that everything *that can* be expressed in YAML
is expressed in YAML; native code exists only where the specification's
expressive power runs out.

### 3.3 Running example: the Color Panel

The Color Panel illustrates the architecture in a compact form. The YAML
specification for the Color Panel comprises four files:

- `workspace/panels/color.yaml` (493 lines) — the panel layout, slider rows
  by mode (HSB / RGB / CMYK / Grayscale / Web Safe), fill-stroke widget
  binding, recent-colors strip, mode buttons, hamburger menu
- `workspace/dialogs/color_picker.yaml` (250 lines) — the modal color picker
  with hex field, 2D gradient, hue bar, channel inputs, color-swatches link
- `workspace/templates/color_picker_fields.yaml` (37 lines) — reusable
  HSB / RGB / CMYK row template
- `workspace/templates/fill_stroke_widget.yaml` (110 lines) — the small
  fill / stroke selector widget

Total: 890 lines of declarative YAML, written once and consumed by all five
implementations.

The per-port native code dedicated to the Color Panel ranges from zero to
over a thousand lines. The OCaml port carries no dedicated color-panel
code: the generic YAML interpreter is sufficient. The Swift port adds 59
lines of state-bridging code (`ColorPanelSync.swift`) to mediate between the
YAML-driven state model and SwiftUI's reactive update cycle. The Python
port adds approximately 123 lines for a custom color-bar widget painted
with QPainter. The Rust port adds approximately 1,300 lines spread across
three files (`color_panel_view.rs`, `color_panel.rs`,
`fill_stroke_widget.rs`) implementing the gradient widget, the hue bar, and
a custom fill-stroke composite — immediate-mode rendering that does not fit
the Dioxus declarative idiom.

This distribution is informative. The platforms whose UI idioms are closely
aligned with the YAML's declarative model require very little native code;
the platforms where the model collides with a different rendering paradigm
require more. The amount of native code per port is, in effect, a measure of
how well the specification's expressive power matches the target framework.
Section 4 returns to this distribution as a correctness benefit, as
cross-port comparison reveals where the specification is underspecified.

**Figure 4.** An excerpt from `workspace/panels/color.yaml` showing the
top-level container, two concrete widgets (an icon button and a color
swatch), their bindings, and click behaviors. The full file is 493 lines;
the form below illustrates the declarative style.

```yaml
content:
  type: container
  id: cp_content
  layout: column
  style: { padding: 4, gap: 6 }
  children:

    # Row 1: Fixed swatches | rule | Recent colors
    - type: container
      id: cp_swatches_row
      layout: row
      style: { gap: 2, alignment: center }
      children:

        - id: cp_none_swatch
          type: icon_button
          icon: color_none
          summary: "None"
          style: { size: 16 }
          behavior:
            - event: click
              action: set_active_color_none

        - id: cp_black_swatch
          type: color_swatch
          summary: "Black"
          style: { size: 16 }
          bind:
            color: "#000000"
          behavior:
            - event: click
              action: set_active_color
              params: { color: "#000000" }
```

### 3.4 Sub-linear cost across N implementations

The headline implication is this: 890 lines of declarative YAML drove five
working Color Panel implementations, with per-port native code totaling
roughly 1,500 lines spread across four of the five ports. The fifth port is
fully YAML-driven.

In conventional cross-platform development, each port carries the full
conceptual load of a feature independently. Color picker logic, slider
snapping, mode-button state, bidirectional channel bindings — all of these
would be reimplemented in each language and framework. The specification
consolidates these decisions into a single artifact. When a new feature is
added (a new slider mode, a new dialog field, a new keyboard shortcut), it
is added to the YAML once, and propagates to all five ports through their
interpreters. When a behavioral detail is refined — for example, the
HSB-degenerate-at-S=0 case discussed as a vignette in Section 4 — it is
refined in one place.

The cost of the specification is paid once and amortizes sub-linearly across
N implementations. The cost of per-port renderer code is paid per port, but
is much smaller than the cost of a full per-port implementation because the
renderer code only implements the escape hatch — the part the spec cannot
express. Across the project, native code totals approximately 300,000 lines
spread across five ports; the shared specification plus interpreter totals
approximately 35,000 lines. The interpretation is not that the project is
"8.5 times smaller" — much of the native code is platform glue with no YAML
counterpart — but that the specification carries the conceptual work, and
the per-port code carries the platform-specific machinery.

---

## 4. Parallel implementations as correctness check

### 4.1 N implementations as differential testing

The five implementations exist not only to demonstrate that the
specification is portable, but to make divergence between them observable.
Two ports producing visibly different output from the same specification
reveal a flaw — either in the specification (it permits more than one
reasonable interpretation), in one of the implementations (it has a bug),
or in both. The shared specification provides the contract; the parallel
implementations provide the cross-check.

This is differential testing [McKeeman 1998] applied to interactive
application code. Differential testing has succeeded most prominently in
compiler validation [Yang et al. 2011], where multiple independent compilers
already exist as targets to compare against. In this work, the
implementations are not independent — they are derived from a shared
specification — but they are independent enough in their use of native
platform features (rendering, layout, event handling, state management) that
bugs in either the spec or the implementations surface when output diverges.

In practice, much of this differential testing was performed manually rather
than automated. For each user-visible feature, a transcript file (e.g.,
`transcripts/COLOR_TESTS.md`) lists numbered scenarios that an operator runs
in each port and marks with a pass date. Automated tests catch state-level
divergence; manual transcripts catch visual, timing, and behavioral
divergence that automated tests miss.

### 4.2 Spec underspecification: bugs found by divergence

The most informative divergences are not implementation bugs but
specification gaps. The specification permits a reasonable interpretation,
two ports adopt different reasonable interpretations, and the divergence
forces the specification to be sharpened. Five examples from the Color
Panel illustrate the pattern.

**Hue collapses to zero when saturation drops to zero.** When the
saturation slider is dragged to zero in HSB mode, the hue channel becomes
mathematically meaningless — the color is gray at any hue. The Python and
Rust ports initially snapped hue to zero when saturation reached zero, a
literal reading of the HSB → RGB conversion. The OCaml port preserved the
prior hue value. The user-visible effect: dragging saturation to zero and
back up in Python or Rust produced a red, not the green the user had been
working with. Cross-port testing surfaced this within the first hour of
manual Color Panel testing. The specification was updated to require
explicit preservation of degenerate-channel values.

**CMYK channels collapse when K reaches 100.** A parallel case in the CMYK
model. At K=100, the displayed color is black regardless of C, M, and Y.
Three of the four native ports initially zeroed C/M/Y when K crossed 100.
The fourth preserved them. The user-visible effect: dragging K back down
from 100 should restore the working color, not produce black. The
specification was updated to require channel preservation on degenerate
transitions.

**Web Safe RGB snap timing.** The Web Safe RGB mode constrains channel
values to multiples of 51. Initial implementations differed on *when* the
snap should occur: on slider drag, on slider release, on widget write-back,
or on display only. Two ports snapped on display and produced incorrect
committed values; one snapped on drag and produced jumpy visual feedback.
The specification was updated to require snap-on-write-back: the value
visible during drag is the snapped value, and the committed value matches
what is shown.

**Hex commit reverts on dialog OK.** The modal color picker dialog exposes a
hex field. When the user typed a new hex value and pressed OK, three of
four ports correctly applied the new color, but one (Python) reverted to
the previous value. The cause was that the dialog's evaluation context had
captured a snapshot of the hex field before the typed-in value flowed
through the get/set lambda chain. The specification required clarification
on when the dialog evaluation context must be rebuilt against typed-in
values rather than the render-time snapshot.

**Recent colors push during slider drag.** Recent colors should be added on
commit (slider release, hex Enter, swatch click), not during drag. Two
ports initially added every intermediate drag value to the recent list,
producing a stream of slight variations of the same color. The
specification was updated to make commit semantics explicit and to require
ports to push only on commit events.

These divergences are not anomalies; they are the methodology working as
designed. Each one would have been silently wrong in a single
implementation. With five implementations and manual cross-checking, each
was visible within hours of the relevant manual test session.

### 4.3 Cost and correctness trade-offs

The cost of N implementations is linear in N: each port requires its own
renderer code, its own manual testing pass, its own propagation of bug
fixes. In this project, total manual testing across five ports accounts
for the largest share of remaining developer time, more than spec writing
or per-port implementation.

The correctness benefit is sub-linear. Most spec-completeness bugs surface
between N=1 and N=2 — the moment a second implementation reveals that the
first made an unstated choice. N=3 catches a residual layer of subtler
bugs that depend on three-way comparison (one port agrees with the spec on
a subtle reading, two ports diverge in different directions). Beyond N=3,
additional implementations primarily verify that earlier-caught spec
refinements have been correctly propagated, and serve as protection against
regression on previously-found classes of bugs.

For this project, N=5 was chosen for reasons beyond differential testing —
diversity of platforms, languages, and frameworks — but a smaller N (3 or
4) would likely have provided most of the correctness benefit at
proportionally lower cost. The right N is a project-specific decision
driven by platform coverage requirements as much as by differential testing
economics.

### 4.4 Connection to N-version programming

N-version programming [Avizienis 1985] proposed multiple
independently-developed implementations as a path to software fault
tolerance: if N implementations are independent in their failure modes,
voting among them can mask single-implementation faults. The approach was
largely abandoned in practice because the cost of developing N independent
implementations of any substantial system was prohibitive, and because
empirical work [Knight and Leveson 1986] suggested that
independently-developed implementations often shared correlated failure
modes anyway.

AI-paired engineering changes the cost argument fundamentally. With a
shared specification and AI handling most of the per-port implementation
work, N implementations across N different languages and frameworks become
feasible for a single developer. The independence concern is genuinely
weakened: the implementations share a specification (deliberately) and
share priors from AI training data (less deliberately). However, the
implementations differ substantially in their use of native platform
features — UI frameworks, rendering models, state management idioms — which
provides a degree of platform-induced diversity that human-team N-version
programs of the 1980s could not easily achieve, since those programs
typically used the same language and platform across the N versions.

This is not a claim that N-version differential testing is now formally
equivalent to N-version programming as Avizienis proposed it. It is a
claim that the *economic argument* against N-version programming has
shifted, and that a methodology that uses N implementations as a
differential-testing layer rather than a fault-tolerance voting layer is
now practical for a single developer.

---

<!-- DRAFT IN PROGRESS — sections 5–9 forthcoming -->
