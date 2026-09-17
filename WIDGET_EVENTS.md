# Widget Events

> **Scope note.** This contract binds the active ports (Rust, Swift), the
> engine's panel door, and the `workspace_interpreter/` reference, per
> `POLICY.md` §1. The frozen ports honor the tag, not this document.

This document says what happens when a person commits a value into a
panel or dialog widget, or presses a boolean one:

- which declared events run,
- what `event.value` holds,
- whether the bound field is written, and whether that happens before or
  after the behaviors.

The executable meaning is `workspace_interpreter/widget_event.py`, and
its tests are in `workspace_interpreter/tests/test_widget_event.py`.
`scripts/gen_widget_event_corpus.py` runs it over shipped widgets to
generate the golden corpus `test_fixtures/widget_events/corpus.json`,
which is what the engine's value door and the active ports are held to.
`scripts/check_widget_event_contract.py` holds every workspace YAML file
to the event table below and to §What a behavior can read, and holds this
document's table to the module's.

## Why this exists

`schema/widget.schema.json` types a behavior's `event` as a free string.
Until this document, nothing said which events a value widget raises or
where the bound field's write falls relative to its behaviors. Each
executor of the panel YAML guessed, and the guesses differ (see
§Known port differences). The shipped YAML needs one answer:

- **Magic Wand's five toggles flip their own field** (`value: "not
  panel.fill_color"`). A bind write made before that behavior would flip
  the field straight back.
- **Stroke's arrowhead-scale combos mirror the edited value onto the
  other scale** (`value: "panel.start_arrowhead_scale"`). That copies the
  NEW value only if the bind write has already happened.

Those two cases are why the rule differs by kind. The rule codifies what
the YAML's authors already wrote for Magic Wand and Stroke.

**The Gradient panel's four value widgets were the exception, and their
YAML was repaired.** Their behaviors read the bare names `value` and
`checked`, which no event binds (§What a behavior can read), so each wrote
null into a `gradient_*` render key. Dither's checkbox could never be
checked, because its `change` behavior owns the press and did not write
the field. They now write `event.value`, and Dither's behavior also writes
`panel.dither`.

## The event table

The table below is the whole vocabulary for the eight value kinds. A
behavior on one of these kinds whose `event` is not listed for that kind
is refused by the lint.

<!-- widget-event-table:begin -->
```
number_input: commit, change
length_input: commit, change
text_input: commit, change, input, blur, keydown
select: commit, change
icon_select: commit, change
combo_box: commit, change
toggle: click, change
checkbox: click, change
```
<!-- widget-event-table:end -->

- **Input kinds** are `number_input`, `length_input`, `text_input`,
  `select`, `icon_select` and `combo_box`. `commit` and `change` are
  synonyms on these kinds: both name "a value was committed".
- **`text_input` has three more events: `input`, `blur` and `keydown`.**
  They are not commits. A commit never runs them. They carry search-as-
  you-type and key handling, and this document does not define them
  beyond naming them.
- **Boolean kinds** are `toggle` and `checkbox`. `click` and `change` are
  synonyms on these kinds: both name "the widget was pressed".

**Outside this contract, deliberately:** every other widget kind. That
includes `dropdown`, `icon_button_group`, `reference_point_widget`,
`slider`, `radio_group` and the color widgets. Their events are not
ruled here, and there is nothing missing from this section: extending the
contract to a kind is a change to this document, the module and the lint
together.

## Committing a value (input kinds)

A commit carries the text the person entered: the field's contents on
Enter or focus loss, or the picked option's value for `select`,
`icon_select` and `combo_box`. The procedure has four steps.

1. **Refuse, and do nothing at all, when any of these holds:**
   - the widget's `bind.disabled` expression is true (`Disabled`);
   - the commit carries no text (`MissingValue`);
   - the kind's parse refuses the text (`BadValue`, see §Parsing).
   A refused commit writes nothing and runs no behavior.
2. **Write the parsed value to the bound target**, when the target is
   writable, together with the global it is two-way bound to (see §The
   bound target).
3. **Then run every behavior whose `event` is `commit` or `change`**, in
   declaration order.
   - `event.value` is the parsed value, typed: a number for
     `number_input`, `length_input` and a numeric `combo_box`, `null` for
     a cleared nullable length, and a string otherwise.
   - A behavior with a `condition` runs only when the condition is true.
   - Within one behavior, its `effects` run first, then its `action` is
     dispatched with its `params`.
   - Behaviors read the store after step 2. A behavior that names the
     field being edited (`panel.start_arrowhead_scale`, a
     self-referential `params:` entry) reads the NEW value.
4. **The result** is `committed` when step 2 wrote or step 3 ran
   something. It is `inert` when the widget binds nothing writable and
   declares no commit behavior.

## Pressing a boolean (toggle, checkbox)

A press carries no text. The new value is the negation of the bound
expression's current truth value, and an unbound widget reads as false.

1. **Refuse a disabled widget** (`Disabled`), and do nothing.
2. **If the widget declares any `click` or `change` behavior, those
   behaviors ARE the press.**
   - They run in declaration order, with `event.value` set to the new
     boolean.
   - **The bound field is not written.** The behavior owns the write,
     which is what makes a behavior that flips its own field correct.
   - This holds even when every declared behavior's `condition` is false.
     A skipped behavior still owns the press, so the field is not written
     behind it. The result is then `inert`.
3. **Otherwise, write the new boolean to the bound target** when it is
   writable, with its two-way bound global (`committed`). If it is not
   writable, the press is `inert`.

## What a behavior can read

Every expression a behavior evaluates starts from one of these names.
That covers its `condition`, its `params`, and the expressions in its
effects.

- the roots the event binds: `event`, `state`, `panel`, `tool`, `dialog`,
  `param` and `active_document` (`EVENT_ROOTS` in the module, derived from
  the store's evaluation context by its tests);
- the item name of an enclosing `foreach` (`as:`, else `item`), which the
  port's view supplies;
- a name bound by a `fun` or a `let`.

Any other name evaluates to null, and nothing reports it. The new value is
`event.value`; there is no bare `value` or `checked`. The lint refuses an
expression that reads another root, or that does not parse.

## Parsing, kind by kind

| kind | the text becomes | refused when |
|------|------------------|--------------|
| `number_input` | a number by the number grammar, clamped to the widget's declared `min:` / `max:` | the text is not in the grammar |
| `length_input` | `parse_length(text, unit:)` in pt (`UNIT_INPUTS.md`), clamped to the declared `min:` / `max:`. A blank entry is `null` when the widget declares `nullable: true`. | the parse refuses, or the entry is blank and the widget is not nullable |
| `text_input` | the text, verbatim (including the empty string and surrounding spaces) | never |
| `select`, `icon_select` | the declared value of the option whose `value`, written as a string, equals the text. With computed options (an expression, not a list) the text itself. | no declared option matches |
| `combo_box` | a number (clamped as above) when the text is in the number grammar; otherwise the text | the text is blank |
| `toggle`, `checkbox` | no text parse; see §Pressing | — |

- **The number grammar** is `-?[0-9]+(\.[0-9]+)?`, matched against the
  whole string, with ASCII digits only. Leading `+`, a leading or
  trailing `.`, exponents, `inf`, `NaN`, separators and surrounding
  spaces are all outside it. `test_fixtures/algorithms/number_commit.json`
  pins it: the active ports are compared on it by
  `scripts/cross_language_algorithms.py --algo number_commit`, and the
  reference's tests run every vector in it.
- **An undeclared bound does not clamp.** A bound that is not a number is
  undeclared; a YAML `true` is not a bound.
- **The reference's `set:` coercion is wider than this grammar on two
  inputs:** Unicode decimal digits, and a trailing newline (it applies
  `^…$` with `re.match`). A widget commit takes the narrow form, which is
  what both active ports already do.

## The bound target

- **The bound expression** is `bind.value`, else `bind.checked`, else a
  bare-string `bind:`. No shipped widget declares both `value` and
  `checked`.
- **Only `panel.<ident>` and `dialog.<ident>` are written by this
  layer**, where `<ident>` is ASCII letters, digits and `_`. A `panel.` path
  writes the widget's own panel, which the reference models as the
  active panel. A `dialog.` path writes the open dialog.
- **The two-way bind.** A panel's `init:` hydrates each field from an
  expression when the panel opens. When that expression is a bare
  `state.<ident>` (`weight: "state.stroke_width"`), the field and that
  global are one value, shown twice. A write to `panel.<field>` then
  writes `state.<ident>` too, in the same step and before any behavior.
  - The shipped YAML depends on this. Stroke's scale combos say "the native
    two-way bind already committed panel.start_arrowhead_scale", and the
    global is what "drives apply-to-selection". Magic Wand says "commits
    write back to both panel.<key> and state.magic_wand_<key>".
  - An `init:` expression that is anything else (`0`, `state.a + 1`,
    `hsb_h(…)`) is a one-way hydration, and nothing is mirrored.
  - The procedures take the widget's panel spec (`panel=`), and it is a
    required argument. Forgetting it silently drops the mirror.
  - *(This clause was missing from the contract's first version, #169. The
    corpus (#170) and the engine's door (#171) were built without it, and
    all three are corrected together.)*
- **Every other bind is read, never written, by this layer.** That
  covers a `state.` path, a `foreach` item's field (`ab.name`), an
  indexed path (`panel.stops[…].opacity`), an expression, and a name a
  port routes to native code (Opacity's `selection_mask_clip`). A widget
  with such a bind does its work through its declared behaviors, or
  through its port's native code, which this document does not rule.
- **The write is a store write** (both halves), and a store write notifies
  the store's subscribers. That notification is how the reference applies a panel to
  the selection (`effects.subscribe_stroke_panel`,
  `effects.subscribe_properties_panel`). A port's panel-write host is
  that subscriber's counterpart. It is not a second step of this
  procedure.

## Known port differences — read, not driven

Each line below was read at the cited `file:line` and has not been
executed. The golden corpus (`test_fixtures/widget_events/corpus.json`)
has two consumers besides the reference:

- the engine's panel door (`jas_panel_behavior`, `jas_dioxus/src/ffi.rs`);
- Swift's headless `WidgetEvent`
  (`JasSwift/Sources/Interpreter/WidgetEvent.swift`), held to it by
  `JasSwift/Tests/Interpreter/WidgetEventCorpusTests.swift`.

Neither is a port's panel VIEW. Swift's `YamlPanelBodyView` does not call
`WidgetEvent` yet, and the Rust web app does not call the door, so the
lines below still describe what each view does. Until a view routes
through its tested module, none of these is a measured failure.

- **Swift, `number_input`: a commit runs only `change` behaviors**
  (`JasSwift/Sources/Interpreter/YamlPanelBodyView.swift:1585`, which
  calls a handler that filters on `"change"` at `:2295`). Magic Wand's
  four `commit` behaviors do not run there.
- **Swift, `toggle`/`checkbox`: a press writes the bound field and runs no
  behavior** (`YamlPanelBodyView.swift:3245-3255`). Magic Wand's five
  `change` flips and Stroke's `stk_dashed` `click` flip do not run there.
- **Swift, `combo_box`:**
  - the widget is a menu of the declared options, with no free entry, so
    only a declared option's value can be committed;
  - that value is parsed with `Double(_:)`, which accepts `inf`, `nan` and
    exponents, and it is not clamped;
  - only `commit` behaviors run (`:3374-3389`);
  - a dialog combo writes the raw string and runs nothing (`:3390-3393`).
- **Rust, `number_input`: no declared behavior runs.** The panel write is
  a per-panel match whose fallthrough is `_ => {}`
  (`jas_dioxus/src/interpreter/renderer.rs:6341`), so a Magic Wand
  tolerance commit writes nothing and runs nothing.
- **Rust, `change` is dispatched only by `icon_button_group` and
  `reference_point_widget`** (`renderer.rs:5923`, `:6030`), which are
  outside this contract.
- **Rust, `toggle`: a declared `click` behavior replaces the write**
  (`renderer.rs:7405-7406`), which conforms. A declared `change` behavior
  does not run.
- **Rust, `combo_box`:** the widget is a free-entry input with an option
  list. The value is parsed with `str::parse::<f64>` (the same wide
  grammar as Swift's), with no clamp, and a blank entry is written as the
  empty string.
  Only `commit` behaviors run, through `run_input_commit_behavior`
  (`renderer.rs:3121`, called at `:7289`).
- **Both ports clamp `length_input`, and `UNIT_INPUTS.md` said "reject".**
  The ports were right, and that document is amended in the same change
  as this one.
- **Resolved: `SCHEMA.md` §behavior used to say that an entry's `action`
  runs before its `effects`.** Both active ports run the effects first, in
  their value handlers (`renderer.rs:3175-3186`,
  `YamlPanelBodyView.swift:2296-2312`) and in their click handlers
  (`renderer.rs:4700-4711`, `YamlPanelBodyView.swift:1245-1256`).
  `SCHEMA.md` now says so for every kind. None of the four shipped `click`
  entries that carry both depends on the order.

## What this document does not cover

- **The engine's value door** (`jas_panel_behavior` with a `value`) and
  the panel-write host. They implement this contract; they do not
  define it.
- **What `input`, `blur` and `keydown` mean on `text_input`.**
- **Dialog OK / Cancel / preview.** A dialog widget's commit follows this
  contract. What the dialog does with its state afterwards is
  `transcripts/SCALE_TOOL.md` §Preview and the dialog's own YAML.
- **Rendering**: how a port draws a widget, or when it sends the commit.
