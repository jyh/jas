# Native Code Boundary

Catalog of behaviors that remain native per-app, with justification.
Pairs with `POLICY.md` §2 (genericity) and `FLASK_PARITY.md` §1 (L1/L2/L3
tiering). CI enforcement (`scripts/genericity_check.py`) relies on this
document to distinguish legitimate native code from policy violations.

## How to use this document

**Reviewers**: when a PR adds native code, check whether it fits a
category below. If yes, the code is permitted — ask the contributor to
cite the category in the PR description. If no, push back or extend
this document in the same PR with justification.

**Contributors**: before adding native code, check this document for a
matching category. If none fits, either express the behavior in
workspace YAML, or extend this document with a new category (and
justify in the PR).

**CI lint**: when the `scripts/genericity_check.py` lint reports a
count increase, the error message directs contributors here. A new
native category is an acceptable resolution if added to this file in
the same PR (alongside a baseline update).

---

## Categories

### 1. Platform APIs (unavoidable)

Behaviors that only exist through native OS or browser APIs. These
cannot be expressed in YAML because they require calls into
platform-specific code that doesn't exist in the expression language.

| Category | Examples |
|---|---|
| **File I/O dialogs** | `NSOpenPanel`, `GtkFileChooser`, `<input type="file">`, File System Access API |
| **Clipboard rich formats** | Multi-MIME NSPasteboard entries, browser Clipboard API async reads, XA_STRING atoms |
| **Keyboard IME / composition** | CJK input, `compositionstart` / `compositionend` events, `NSTextInputClient` |
| **OS menu bar** | macOS global menu vs window-level menu, `QMenuBar`, `NSMenu`, AppKit menu validation |
| **OS notifications** | Web Notifications API, `UserNotifications` framework, `libnotify` |
| **File associations** | `.svg` double-click opens app — OS-integration-only |
| **Window / process lifecycle** | `app.on_quit`, `SIGTERM` handling, app-launch arguments |
| **Drag from OS** | OS-level drag-drop targets (Finder → app), `drop` events |
| **Pointer events beyond mouse** | `touchstart`, gesture events, pen pressure |
| **Font loading** | `NSFontManager`, `QFontDatabase`, `document.fonts` |
| **Printing** | `NSPrintOperation`, `QPrinter`, `window.print()` |

**Rule**: if the behavior requires calling a specific platform API
that only exists in native code, it belongs here.

---

### 2. Performance kernels (measured, not conjectured)

Math-heavy code where YAML-interpreted expressions couldn't hit 60fps
or would allocate too much per frame.

| Kernel | Why native |
|---|---|
| **Path boolean operations** | Weiler-Atherton / Bentley-Ottmann — milliseconds per call; YAML-expressed control flow would be 100× slower |
| **Text layout** | Knuth-Plass line breaking, BiDi, OpenType shaping — hundreds of glyph-level ops per second during typing |
| **Gradient compositing / raster pipeline** | Per-pixel math; must be native regardless |
| **Path flattening for hit-test** | Cubic-Bezier subdivision; numeric iteration |
| **SVG parsing** | Character-level scanning of large strings — tokenizer speed matters |
| **PDF / PNG export** | Platform rasterization libraries only available natively |
| **Color-space conversions (bulk)** | RGB ↔ HSB ↔ CMYK ↔ Lab — fine per-pixel; YAML eval overhead dominates at pixel scale |

**Rule**: adding a new performance-kernel entry requires either (a) a
benchmark reference in the parent feature's test file showing the
YAML-equivalent is slower than the native implementation's time
budget, or (b) a clear geometric / combinatorial argument that the
operation is fundamentally unsuited to interpreter dispatch.

Individual expression primitives (e.g. `path_length`, `hit_test`)
that wrap these kernels are fine — they give YAML access to native
speed without making the kernel YAML-expressed.

---

### 3. Language-specific infrastructure

Language-level features that YAML doesn't express. These are
categorically out of scope for the genericity policy — YAML would
have to invent an abstraction that doesn't map cleanly to any of the
5 runtimes.

| Category | Why native |
|---|---|
| **Error handling** | Rust `Result`, OCaml exceptions, Swift `throws`, Python exceptions, JS promises — each has different propagation semantics |
| **Concurrency / async** | Rust `async`, Swift actors, JS promises, OCaml Lwt, Python asyncio — no unified model |
| **Memory management** | Rust ownership, Swift ARC, GC'd languages — no YAML counterpart |
| **Framework reactivity** | Dioxus signals, SwiftUI `@State`, React-like hooks — wrap native closures |
| **Trait / protocol conformance** | Rust traits, Swift protocols, OCaml module signatures, Python ABCs — static-typing concepts |

**Rule**: these never appear in YAML. Contributors don't write them;
they use them as scaffolding for the framework's host-integration
layer (§4).

---

### 4. Framework / host integration

The thin adapter layer between the YAML runtime and each app's
native widget tree. Has no app-specific knowledge; just translates.

| Category | Examples |
|---|---|
| **Widget factories** | Dioxus `rsx!` → VDOM, SwiftUI view bodies, GTK `GtkBuilder`, Qt `QWidget` subclasses |
| **Event dispatch bridge** | Translating Dioxus `MouseEvent` / `NSEvent` / `GdkEvent` / `QMouseEvent` into the YAML `$event` scope |
| **Paint callback** | Cairo `on_draw`, Core Graphics `drawRect:`, `CanvasRenderingContext2D` |
| **Filesystem / network I/O** | Flask `@app.route`, Rust `fs::read`, Swift `URLSession`, OCaml `Unix` |
| **State-store reactivity** | Notifying the widget tree when state changes (`Signal::set`, `@Published`, `signal::notify`) |

**Rule**: this is the *seam* code. Each function in this category
either (a) takes YAML-defined data and builds a native widget, or
(b) takes a native event and produces YAML-defined scope. No
app-level knowledge ("colors panel has X swatches") goes here.

---

### 5. Domain (L2) primitives

Vector-illustration primitives that are universally needed regardless
of the specific app. Shared framework-level math, not app-level
behavior.

| Category | Why native |
|---|---|
| **Element geometry types** | Rect, Circle, Path, Text, Layer, Group — fundamental shape of the domain |
| **Path commands** | M / L / C / Q / A / Z — SVG spec primitives |
| **Color conversions** | RGB ↔ HSB ↔ CMYK ↔ Lab conversions; hex parse / format |
| **Affine transforms** | Matrix compose, invert, apply |
| **Element bounds** | Axis-aligned bounding box per element type |
| **Serialization formats** | SVG read/write, msgpack binary format, JSON document shape |
| **Hit-test primitives** | Point-in-shape, rect-intersects-shape math |

**Rule**: shared across *any* vector app built on the framework.
Moving to YAML would mean re-implementing the math in the YAML
expression language — performance (§2) and correctness (§3) reasons
both say no. These are exposed to YAML via expression primitives
(e.g. `hit_test()`, `path_bounds()`) rather than being YAML-expressed
themselves.

Adding new L2 primitives requires demonstrating universality — the
primitive must be useful to vector-illustration applications
generally, not specific to jas.

---

### 6. Interactive text-editing tools

The **Type** tool and **Type on a Path** tool are permanent-native
in every app. Named here because the tool-as-YAML migration
(RUST_TOOL_RUNTIME.md, 13-of-18 Rust tools YAML-driven as of
2026-04-23) intentionally stopped before them.

| Tool | File (jas_dioxus) |
|---|---|
| **Type** | `src/tools/type_tool.rs` |
| **Type on a Path** | `src/tools/type_on_path_tool.rs` |

**Why native**: these tools are thin UX wrappers around three
native-only pieces this document already names — §1 keyboard IME
composition, §2 text-layout kernels, and the `TextEditSession`
state machine exposed through `CanvasTool::edit_session_mut()` so
the Character panel can write formatting overrides into the
next-typed-character. A YAML port would need to either:

1. Duplicate `TextEditSession`'s 20+ methods as `text.*` effects
   driven by per-keystroke handlers — ~3600 lines of native
   machinery mirrored by an equal-surface YAML shim, without
   removing any of the native machinery underneath; or
2. Invent a YAML syntax for declaring text-editor state machines
   (caret affinity, BiDi-aware selection, IME composition) that
   doesn't exist in any of the 5 runtimes.

Neither option removes native code — both add a YAML layer on top
of it. The *tool dispatch* that YamlTool normally replaces is
small compared to the session machinery these two tools wrap, so
the genericity-policy payoff doesn't justify the migration cost.

**Rule**: Type and Type-on-a-Path stay native in all apps. New
text-tool variants that want the same session infrastructure should
reuse `TextEditSession` rather than porting to YAML. Adding more
variants does not grow the legitimate-native surface any further
than "one new `_tool.rs` file per variant reusing existing
session machinery."

The `scripts/genericity_check.py` `rust.tool_files` baseline counts
these two files; reductions in that count should only come from
porting PartialSelection, PathEraser, or Smooth (the three non-text
native tools still on the migration backlog).

---

## Extending this document

When a PR needs to add native code that doesn't fit any category
above:

1. Propose a new category or sub-entry in this file, with
   justification explaining why the behavior can't be YAML
2. If the justification is performance, cite a benchmark
3. If the justification is platform-API, cite the API
4. If the justification is novel, expect review pushback and a
   discussion

When a PR moves code *out* of native (to YAML), the corresponding
category entry in this doc should either be removed (if the whole
category is now YAML-addressable) or narrowed (if only some cases
migrated).

---

## Related documents

- `POLICY.md` — the genericity policy this doc scopes exceptions for
- `FLASK_PARITY.md` — L1/L2/L3 architectural tiering
- `scripts/genericity_check.py` — the CI lint that cites this doc
