# Widget Events

> **Scope note.** This contract binds the active ports (Rust, Swift), the
> engine's panel door, and the `workspace_interpreter/` reference, per
> `POLICY.md` §1. The frozen ports honor the tag, not this document.

This document says what happens when a person commits a value into a
panel or dialog widget, presses a boolean one, or clicks a button:

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

The table below is the whole vocabulary for the eighteen kinds it names. A
behavior on one of these kinds whose `event` is not listed for that kind
is refused by the lint.

<!-- widget-event-table:begin -->
```
number_input: commit, change
length_input: commit, change
text_input: commit, change, input, blur, keydown
select: commit, change
icon_select: commit, change
icon_button_group: commit, change
reference_point_widget: commit, change
combo_box: commit, change
slider: commit, change
color_bar: commit, change
color_hue_bar: commit, change
color_gradient: commit, change
toggle: click, change
checkbox: click, change
radio: click, change
dropdown: toggle, alt_toggle
radio_group: toggle
button: click, mouse_down, mouse_up
icon_button: click, mouse_down, mouse_up
gradient_slider: commit
```
<!-- widget-event-table:end -->

- **Input kinds** are `number_input`, `length_input`, `text_input`,
  `select`, `icon_select`, `icon_button_group`, `reference_point_widget`, `combo_box`, `slider`, `color_bar`, `color_hue_bar` and `color_gradient`. `commit` and `change` are
  synonyms on these kinds: both name "a value was committed".
- **`text_input` has three more events: `input`, `blur` and `keydown`.**
  They are not commits. A commit never runs them. They carry search-as-
  you-type and key handling (§Typing in a text field).
- **Boolean kinds** are `toggle` and `checkbox`. `click` and `change` are
  synonyms on these kinds: both name "the widget was pressed".
- **Item kinds** are `dropdown`. `toggle` is a plain pick of one declared
  item and `alt_toggle` an Alt pick. They are NOT synonyms: each runs only
  the behaviors declared for itself (see §Picking a dropdown item).
- **The check kind** is `radio`. `click` and `change` are synonyms: both
  name "the radio was pressed". A press CHECKS a radio and never unchecks
  it (see §Checking a radio).
- **The option kind** is `radio_group`. `toggle` picks one of its
  `options` by that option's `id` (see §Picking a radio option).
- **The click kinds** are `button` and `icon_button`. `click` runs the
  widget's `click` behaviors, else its node-level `action` (see §Clicking a
  button). `mouse_down` and `mouse_up` carry press-and-hold handling. A
  click never runs them, and this document does not define them beyond
  naming them.

- **The stops kind** is `gradient_slider`. Its one behavior event,
  `commit`, names "a gesture finished". A shell reports gestures, not
  values (see §The stops kind).

**Outside this contract, deliberately:** every other widget kind. That
includes the color widgets other than `color_bar`, `color_hue_bar` and
`color_gradient`. Their events are not
ruled here, and there is nothing missing from this section: extending the
contract to a kind is a change to this document, the module and the lint
together.

## The stops kind

A `gradient_slider` edits a list of colour stops, and its gestures need the
slider law (`transcripts/GRADIENT.md`, *The slider law (precisely)*;
executable in `workspace_interpreter/gradient_law.py`). No shell computes
that law, so a shell reports each gesture with its RAW parameters, and the
procedure (`widget_event.gesture`) applies it. The parameters are a stop or
pair index, a `location` in percent along the bar, and `dy`, the pointer's
distance in pixels from the bar's centre line.

The widget's three binds (`stops`, `selected_stop_index`,
`selected_midpoint_index`) must each be a `panel.` field, or every gesture is
refused `NotWritable`.

| gesture | parameters | what it does |
|---|---|---|
| `press` | `index`, `location` | selects the stop (the midpoint becomes −1) and snapshots the stops and the grab into `panel.<stops key>__press` |
| `drag` | `location`, `dy` | `drag_stop` over the SNAPSHOT; writes the stops and the selection |
| `release` | `location`, `dy` | as `drag`, then clears the snapshot and runs the `commit` behaviors |
| `press_midpoint` | `pair`, `location` | selects the midpoint (the stop becomes −1) and snapshots, with the grab |
| `drag_midpoint` | `location` | `drag_midpoint` over the snapshot; writes the stops |
| `release_midpoint` | `location` | as `drag_midpoint`, then clears the snapshot and runs the `commit` behaviors |
| `add` | `location` | `add_stop` over the current stops; selects the new stop; runs the `commit` behaviors |
| `key` | `key`, `shift` | GRADIENT.md's keyboard table over the current stops; runs the `commit` behaviors |

- **A marker moves by how far the pointer moved, never to the pointer.** A
  press carries the pointer's `location` too, and the snapshot keeps the
  GRAB: that location less the pressed marker's (a stop's `location`; a
  midpoint's absolute location, `a + (b − a) · midpoint_to_next / 100`). A
  `drag` or `release` passes its `location` less the grab to the law. So a
  click on a marker off its centre selects it and moves nothing, as
  GRADIENT.md asks of a click on a stop, and a marker does not jump to the
  pointer when a drag starts. A press with no numeric `location` is refused
  `LawRefused`, never read as a grab of 0: a shell that forgot it would
  otherwise move every marker it clicked.
- **A drag is computed from the press, never from the last preview**, and it
  runs NO behavior. The behaviors (which write the document) run once per
  gesture, so a drag is one undo step. The slider redraws from the store
  while it moves.
- **While a snapshot exists, the panel shows the STORE's stops and
  selection.** A port whose panel scope is derived from the document (the
  engine's, `panel_scope::engine_scope`, after W2b-7) must let the store's
  `stops`, `selected_stop_index` and `selected_midpoint_index` stand over the
  document's for as long as `panel.<stops key>__press` is set. Otherwise a
  drag's preview is invisible whenever the selection holds a gradient, which
  is the only case a preview is for. In the reference the store IS the
  scope, so the rule changes nothing there. Once the snapshot is cleared,
  the scope derives from the document again, which by then holds what the
  release committed.
- **The current stops are the panel SCOPE's** (in the engine, the
  selection's gradient), not a store copy that the scope overrides. A press,
  an add and a key read them there.
- **`event.value` in a `commit` behavior is the new stops list.**
- **A `drag` or `release` with no snapshot of its kind is refused
  `NoPress`**, never read as a press and release at one point.
- **A gesture the law refuses writes nothing** and is refused `LawRefused`
  (an index naming no stop, an add outside [0, 100], a delete at the
  two-stop floor).
- **A key that names nothing is `inert`**: no stop or midpoint is selected,
  the key is not in the table, or it is Delete on a midpoint (midpoints
  cannot be deleted).
- A disabled widget refuses every gesture (`Disabled`), as every kind does.

## Picking a dropdown item (item kinds)

A pick names ONE declared item, by that item's `value`. It carries no
text and parses nothing. The procedure has three steps.

1. **Refuse, and do nothing at all, when any of these holds:**
   - the event is not `toggle` or `alt_toggle` (`WrongEvent`);
   - the widget's `bind.disabled` expression is true (`Disabled`);
   - the pick names no item (`MissingValue`);
   - no declared item has that `value` (`BadValue`). A `separator` entry
     is not an item.
2. **An `action` item runs its own `action`** (with its `params`, if any)
   and no behavior runs. That is how the Layers filter's "All" works.
3. **Any other item runs every behavior declared for the pick's event**, in
   declaration order, with `item` bound to the WHOLE declared item and
   `event.value` to its value. A dropdown binds no value, so nothing is
   written except what those behaviors write.

Before this section, the one shipped dropdown (the Layers type filter)
read `item.value` in its behaviors while nothing bound `item`. Every port
reached around the declared route to its own native state, and the
engine's panel door, which runs the declared route, would have written
`null` into the filter.

### Showing an item's check

A dropdown binds no value, so a `toggle` item's check is declared on the
dropdown by `bind.checked_in`: an expression that resolves to a LIST. A
`toggle` item is checked exactly when its `value` is an element of that
list, compared as JSON values. Nothing else is decided here:

- An `action` item's check says whether its action is already IN
  FORCE: running it now would change nothing (the Layers filter's "All"
  with nothing checked). It is known only when the item declares no
  `params`, the action is defined, and it has at least one effect, every
  one a `set_panel_state` that NAMES the dropdown's own panel. The item
  is then checked exactly when, for every such effect, the effect's
  `value` evaluated now equals the key's current value, compared as JSON
  values with numbers compared by value (`45` equals `45.0`). In every other case the check is unknown (`checked: null`),
  never `false`: an effect of any other kind could change something this
  test cannot see.
- With no `bind.checked_in`, or one that does not resolve to a list, no
  item's check is known. That is its own state, not "unchecked": the
  engine's panel plan sends `checked: null` for it, never `false`.

The Layers type filter declares `checked_in: "panel.type_filter"`, the
CHECKED types. The empty list, its default, checks no type item. That the
empty list also means "every type is listed" is the filter's own rule
(`layers.yaml`), not this section's.

## Committing a value (input kinds)

A commit carries the text the person entered: the field's contents on
Enter or focus loss, or the picked option's value for `select`,
`icon_select` and `combo_box`. The procedure has four steps.

1. **Refuse, and do nothing at all, when any of these holds:**
   - the widget's `bind.disabled` expression is true (`Disabled`);
   - the commit carries no text (`MissingValue`);
   - the kind's parse refuses the text (`BadValue`, see §Parsing);
   - the kind is `color_hue_bar` or `color_gradient` and the dialog is not
     in H mode (`WrongMode`, naming the mode; see §The bound target).
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

## Checking a radio (the check kind)

A radio is one choice among siblings that share a field. Each radio
declares its own `bind.checked` expression (Scale Options:
`dialog.uniform` and `not dialog.uniform`), so the siblings' exclusivity is
in the YAML, never in the port. A press carries no text.

1. **Refuse a disabled radio** (`Disabled`), and do nothing.
2. **A radio that is already checked is `inert`.** Its `bind.checked`
   expression is true, so nothing is written and nothing runs. A press
   never unchecks a radio.
3. **If the radio declares `on_check`, that effect list IS the check.**
   It runs with `event.value` set to `true`, and the bound field is not
   written. Every shipped radio declares one, because its `bind.checked`
   is a comparison (`dialog.axis == 'vertical'`) that cannot be written.
4. **Otherwise, write `true` to the bound target** when it is writable,
   with its two-way bound global (`committed`). If it is not writable, the
   press is `inert`.

`on_check` is a field on the node, beside `bind`, not a `behavior` entry.
That is why the radio's events are `click` and `change` while no shipped
radio declares a behavior. A radio that also declares `click` or `change`
behaviors runs those after `on_check`, in declaration order.

## Picking a radio option (the option kind)

A `radio_group` binds ONE expression, as a bare string (`bind:
"dialog.radio_channel"`), and declares `options`, each with an `id`. The
option whose `id` equals the bound value, compared as text, is the checked
one. A pick names one option by its `id`.

1. **Refuse, and do nothing at all, when any of these holds:**
   - the event is not `toggle` (`WrongEvent`);
   - the widget is disabled (`Disabled`);
   - the pick names no option (`MissingValue`);
   - no declared option has that `id` (`BadValue`).
2. **The option already checked is `inert`.**
3. **Otherwise, write the option's `id`, as a string, to the bound
   target** when it is writable, with its two-way bound global. Then run
   every behavior declared for `toggle`, with `event.value` set to the
   `id`. The result is `committed` when either wrote or ran something, and
   `inert` otherwise.

The Color Picker draws six one-option groups that share
`dialog.radio_channel`. Picking one writes its channel, which unchecks the
other five through their own comparisons.

## Clicking a button (the click kinds)

A `button` or `icon_button` can say what a click does in two ways: with
`click` behaviors, or with `action` and `params` on the node itself
(`SCHEMA.md` §Widget types). Every shipped dialog's OK, Cancel, Save and
Discard uses the node-level form (67 buttons, 2026-10-15). A click carries
no text and no value.

1. **Refuse, and do nothing at all, when any of these holds:**
   - the event is not `click` (`WrongEvent`);
   - the widget's `bind.disabled` expression is true (`Disabled`).
2. **If the widget declares any `click` behavior, those behaviors ARE the
   click.** They run in declaration order, and the node-level `action`
   does not run.
   - This holds even when every declared behavior's `condition` is false.
     A skipped behavior still owns the click, as it owns a boolean press,
     and the result is then `inert`.
   - The lint refuses a widget that declares both, because its `action`
     could never run. No shipped widget does.
3. **Otherwise, a node-level `action` is dispatched with its `params`**,
   exactly as a behavior's `action` is (§What a behavior can read). A
   string param is an expression, a YAML literal (`copy: false`) is that
   value, and a bare identifier that evaluates to null is its own name
   (`tool: selection` is the string "selection"). The result is
   `committed`.
4. **A widget with neither is `inert`.** A click writes no bind.

`event` is the click's modifier keys: `event.shift`, `event.ctrl`,
`event.meta` and `event.alt`, each `false` when the key was not held. There
is no `event.value`. The Boolean panel's "Alt-click makes a compound
shape" reads `event.alt` in a behavior's `condition`.

Rotate, Scale and Shear Options each have a Copy and an OK button that
dispatch the same action and differ only in a literal `copy:`. A port that
turned the YAML `false` into the text `False`, an unknown name, would copy
on OK. The reference's `TestShippedRotateButtons` holds this.

## Typing in a text field (`input`, `keydown`, `blur`)

A `text_input` has three events besides its commit. None is a commit: a
commit never runs them, and they write no bind. Each runs only the
behaviors declared for itself, in declaration order.

| event | when | `event.value` | `event.key` |
|---|---|---|---|
| `input` | the text changed (a keystroke, a paste) | the field's whole text after the change | absent |
| `keydown` | a key was pressed in the field | the field's text BEFORE the key acts | the key's name |
| `blur` | the field lost focus | the field's text | absent |

1. **Refuse, and do nothing at all, when any of these holds:**
   - the widget is not a `text_input` (`WrongKind`);
   - the event is not one of the three (`WrongEvent`);
   - there is no text, or a `keydown` names no key (`MissingValue`);
   - the widget's `bind.disabled` expression is true (`Disabled`).
2. **A key's name is the W3C `KeyboardEvent.key` value**: `Enter`,
   `Escape`, `Tab`, `Backspace`, or the printable character itself. The
   shipped behaviors compare against `Enter` and `Escape`.
3. **`keydown` reads the text before the key acts**, because that is what
   a key handler can know when it fires on every toolkit. Enter and Escape
   do not change the text, so both readings agree for every shipped use.
4. **The four modifiers ride beside them**, as on a click: `event.shift`,
   `event.ctrl`, `event.meta`, `event.alt`.
5. **A behavior in a template row reads its row** (`node`) beside `event`,
   as a click in the row does.

The two inline rename fields are the shipped users: the Layers row's
`lp_name_edit` and the Artboards panel's rename field confirm on Enter and
on blur, and cancel on Escape. The reference's procedure is
`widget_event.text_entry`.

## What a behavior can read

Every expression a behavior evaluates starts from one of these names.
That covers its `condition`, its `params`, and the expressions in its
effects.

- the roots the event binds: `event`, `state`, `panel`, `tool`, `dialog`,
  `param`, `active_document` and `data`, the store's library data
  (`EVENT_ROOTS` in the module, derived from the store's evaluation context
  by its tests);
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
| `reference_point_widget` | the text itself, when it is one of the kind's nine anchors, row by row: `top_left`, `top_center`, `top_right`, `middle_left`, `center`, `middle_right`, `bottom_left`, `bottom_center`, `bottom_right`. The KIND owns this vocabulary; no YAML declares it. | any other text |
| `select`, `icon_select`, `icon_button_group` | the declared value of the option whose `value`, written as a string, equals the text. With computed options (an expression, not a list) the text itself. | no declared option matches |
| `combo_box` | a number (clamped as above) when the text is in the number grammar; otherwise the text | the text is blank |
| `slider` | a number by the number grammar, clamped to `min:` / `max:` as `number_input` is, then SNAPPED to the declared `step:`: `min + floor((v − min) / step + 0.5) · step` (half up, offset from `min`, or from 0 with no `min`), then clamped again so a snap never leaves the range. No `step:`, or a step that is not a positive number, does not snap. A shell reports a drag as `change` (live) and the release as `commit`; both parse the same way. | the text is not in the grammar |
| `color_bar` | a POINT normalized to [0, 1]²: the text is `u,v`, two numbers by the number grammar joined by one comma (no spaces), each clamped to `[0, 1]`; `u` runs left to right, `v` top to bottom. The value is the pair `[u, v]`; the colour it names is `color_util.color_bar_rgb(u, v)` (`test_fixtures/algorithms/color_bar.json`), which every view of the bar also calls, so a shell sends the point and never computes a colour. A shell reports a drag as `change` (live: the colour shows, nothing is committed) and the release as `commit` (the colour is committed once); both parse the same way. | the text is not two numbers joined by one comma |
| `color_hue_bar` | ONE number `v` by the number grammar, clamped to `[0, 1]`: a point on the Color Picker's vertical strip, `v` running top to bottom. The value is `v`. The strip's pick never reads a `u`, so its text carries none. What a commit WRITES is the pick, not `v` (see §The bound target). A shell reports a drag as `change` and the release as `commit`; both parse and write the same way. Off H mode it is refused by the door; the Swift view's own channel write is outside the bind (deferred §5). `test_fixtures/algorithms/picker_commits.json` pins the parse, the refusals and the writes. | the text is not one number |
| `color_gradient` | a POINT, exactly as `color_bar`'s: the text is `u,v`, two numbers by the number grammar joined by one comma (no spaces), each clamped to `[0, 1]`; `u` runs left to right, `v` top to bottom. The value is the pair `[u, v]`. What a commit WRITES is the pick (see §The bound target). `change` and `commit` both parse and write the same way. `test_fixtures/algorithms/picker_commits.json` pins the parse, the refusals and the writes. | the text is not two numbers joined by one comma |
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
- **A write to the open dialog runs its `on_change`, once, at the end of
  the event.** The event is one batch: the bind write, then the declared
  behaviors, then the dialog's `on_change` action if anything in the batch
  wrote a dialog field. This is how the transform dialogs preview live
  (`rotate_options_preview`, "the canvas re-renders live"). *(Until
  2026-10-24 the reference wrote the bind outside any batch, so a typed
  angle previewed only at the next button press, while the engine already
  ran it in the batch.)*
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
- **The Color Picker's strip and field write their PICK, not their point**
  (finding 13). Both are the dialog's, and both read `dialog.radio_channel`,
  whose absence means `h`.
  - In H mode, `color_hue_bar` writes its bound target (`bind.value`, the
    dialog's `h`) with `strip_value(v, 359)`, and `color_gradient` writes
    `bind.saturation` and `bind.brightness` with the two halves of
    `gradient_sb(u, v)`. Each value is rounded half away from zero
    (`color_util`; `test_fixtures/algorithms/picker_picks.json`, its
    `written`). The pictures a native shell draws them from are the same
    two functions (the plan's `display.picture`), so a pick lands on the
    colour drawn under it.
  - In any other mode the commit is REFUSED, `WrongMode`, naming the mode
    (`radio_channel=<mode>`): nothing is written and no behavior runs. The other modes are deferred
    (the finding 13 design, §4). Only a TEXT mode other than `h` refuses: a
    `radio_channel` that is absent, or is not text, reads as `h`.
  - A pick writes only a `dialog.` target, and only when the widget is not in
    a panel. Any other bind is not written, so a strip or field with no
    writable bind and no behavior is `inert` (`EmptyBehavior`).
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

**Swift's panel view is routed.** `YamlPanelBodyView` sends every commit
and press of the eight kinds through `PanelWidgetEvents`
(`JasSwift/Sources/Interpreter/PanelWidgetEvents.swift`). That drives
`WidgetEvent` with the app's host, and
`JasSwift/Tests/Interpreter/PanelWidgetEventsTests.swift` drives it over
the shipped widgets. The host adds three things the contract leaves to a
port:

- **The render scope.** The disabled check and a press's current value
  read the scope the view rendered, which is what the person saw. A Swift
  panel scope overlays live selection values the store does not hold
  (Character, Paragraph). The scope's own names (a `foreach` item) reach
  the behaviors; its store namespaces do not.
- **The store the app has.** Swift never runs a panel's `init:`, and its
  store holds no bundle `state` defaults. So before an event, a two-way
  bound global that is absent is seeded from its field, and the two start
  as the one value this contract says they are.
- **The write and the dispatch.** The bind write goes through the
  panel-write host, and an action goes through the view's dispatcher,
  whose native intercepts (`set_concept_param`) the catalog does not have.

A Swift `combo_box` is still a menu of its declared options with no free
entry, so only a declared option's value can be committed. A combo whose
options are computed offers none.

**The Rust web app does not call the door yet**, so the Rust lines below
still describe what its view does. Until it routes through its tested
module, none of them is a measured failure.

- **Rust, `number_input`: no declared behavior runs.** The panel write is
  a per-panel match whose fallthrough is `_ => {}`
  (`jas_dioxus/src/interpreter/renderer.rs:6341`), so a Magic Wand
  tolerance commit writes nothing and runs nothing.
- **Rust, `change` is dispatched only by `icon_button_group` and
  `reference_point_widget`** (`render_icon_button_group`,
  `render_reference_point_widget`), each from its own loop, which reads a
  behavior's `condition` (2026-10-15).
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
- **The click kinds (§Clicking a button).** The web renderer conforms: its
  click handler is built from the declared `click` behaviors, and the
  node's `action` is used only when there are none (`render_button`,
  `renderer.rs`). The engine's door ran the node's `action` when every
  click behavior's `condition` was false, and Swift's view ran the node's
  `action` INSTEAD of any declared behavior. Both now follow step 2
  (2026-10-15; `panel_behavior.rs`, `WidgetEvent.clickRunsNodeAction`). No
  shipped widget reached either difference, and the lint keeps it that way.
- **Swift, a node-level `action`'s params** are evaluated against the view's
  render context, and a param that evaluates to null is DROPPED rather than
  passed as null or as its own name (`YamlPanelBodyView.swift`,
  `handleWidgetClick`). No shipped node-level param is a bare identifier,
  and an action reads a dropped param as null, so no shipped click differs.
  Swift's view does not route a click through `WidgetEvent` yet.
- **Resolved: `SCHEMA.md` §behavior used to say that an entry's `action`
  runs before its `effects`.** Both active ports run the effects first, in
  their value handlers (`renderer.rs:3175-3186`,
  `WidgetEvent.swift:317-321`) and in their click handlers
  (`renderer.rs:4700-4711`, `YamlPanelBodyView.swift:1175-1186`).
  `SCHEMA.md` now says so for every kind. None of the four shipped `click`
  entries that carry both depends on the order.

## What this document does not cover

- **The engine's value door** (`jas_panel_behavior` with a `value`) and
  the panel-write host. They implement this contract; they do not
  define it.
- **Dialog OK / Cancel / preview.** A dialog widget's commit follows this
  contract. What the dialog does with its state afterwards is
  `transcripts/SCALE_TOOL.md` §Preview and the dialog's own YAML.
- **Rendering**: how a port draws a widget, or when it sends the commit.
