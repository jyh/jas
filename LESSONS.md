# Lessons Learned

## Dioxus 0.6 Controlled Inputs

### The "0" problem
A controlled input with `value: "0"` cannot be edited by deleting the "0" first.
When the user deletes the character, `oninput` fires with an empty string. If the
handler rejects the empty string (parse fails) and doesn't update the signal,
Dioxus re-applies `value: "0"` on the next render, overwriting the user's edit.

**Fix:** Store an `input_override` in state. When a parse fails, save the raw
text in the override so the `value:` binding returns the user's text instead of
the computed value. Clear the override when a valid value is parsed. Also add
`onfocus` handlers that call `input.select()` via web-sys so clicking on "0"
selects all text and the next keystroke replaces it.

### `type="number"` vs `type="text"`
Browser `<input type="number">` normalizes values aggressively (strips leading
zeros, rejects intermediate states). Combined with Dioxus controlled inputs,
this makes editing nearly impossible. Use `type="text"` and parse manually.

### `oninput` vs `onchange`
`onchange` fires on blur or Enter, but in Dioxus for `<input type="text">`,
pressing Enter may not reliably trigger `onchange`. Use `oninput` for immediate
updates. If deferred updates are needed, combine `oninput` (to track raw text)
with `onchange` (to apply), storing intermediate state so Dioxus doesn't
overwrite user input.

## Signal Writes During Render

Writing to a Dioxus signal during the render function causes a warning and can
produce infinite re-render loops:

```
Write on signal at ... happened while a component was running.
```

**Fix:** Move signal writes to event handlers. For example, instead of checking
a flag in render and setting a signal, set the signal directly in the
`ondoubleclick` handler that triggers the action.

## Canvas Element Lookup

`document.get_element_by_id("jas-canvas")` can fail even when the canvas exists
in the Dioxus virtual DOM. The element may not have the expected ID in the real
DOM, or it may be conditionally rendered (`if has_tabs`).

**Fix:** Fall back to `document.query_selector("canvas")` when ID lookup fails.

## Keyboard Event Propagation in Dialogs

The app's global `onkeydown` handler intercepts keys like `d`, `x`, `X` for
fill/stroke shortcuts. When a modal dialog has text inputs, typing these
characters triggers the shortcuts instead of inserting text.

**Fix:** Add `onkeydown: move |evt| { evt.stop_propagation(); }` on the dialog
container div so keyboard events from inputs don't bubble up to the global
handler.

## Mouse Events on Transparent Overlays

A `div` with `position:fixed; inset:0` but no background may not reliably
receive mouse events in all browsers.

**Fix:** Add a nearly-invisible background: `background: rgba(0,0,0,0.01)`.
Also use explicit sizing (`width:100vw; height:100vh`) instead of `inset:0`.

## Mouse Event Types

`onmousedown` on overlay divs may not fire reliably in Dioxus. `onclick` is
more reliable for capturing clicks on overlay elements.

## Logging

`log::info!` / `log::warn!` macros may not reach the browser console even when
`dioxus-logger` is initialized with `tracing::Level::INFO`. For reliable browser
console output, use `web_sys::console::log_1()` / `web_sys::console::warn_1()`
directly.

## HSB Color Preservation

When brightness is 0 (black) or saturation is 0 (white/gray), converting
RGB to HSB loses the hue (and sometimes saturation) information. This confuses
users: they set a hue on the colorbar, but the color stays black because S and B
are both 0.

**Fix:** Store `hue` and `sat` as independent fields in the color picker state.
Update them from RGB conversions only when the conversion is meaningful
(brightness > 0 for hue, saturation > 0 for hue). Use the preserved values in
`hsb_vals()`, `colorbar_pos()`, and `gradient_pos()` when the derived values
would be degenerate.
