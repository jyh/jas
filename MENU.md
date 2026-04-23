# Menu System

This document describes the menu bar structure, keyboard shortcuts, command
dispatch, and the implementation of each menu command.

---

## Menu Bar

The menu bar contains four menus:

```
[ File ] [ Edit ] [ Object ] [ View ]
```

Menus are defined as declarative data structures -- lists of items with
labels, keyboard shortcuts, and command identifiers. Each command maps to
a handler function that typically:

1. Calls `model.snapshot()` to push the current document onto the undo stack.
2. Computes a new Document via Controller methods.
3. Calls `model.set_document(new_doc)` to apply the change.

Commands that only read state (e.g. Zoom) may skip the snapshot step.

---

## File Menu

| Item | Shortcut | Description |
|------|----------|-------------|
| New | Ctrl+N | Replace the document with a fresh empty document. Prompts to save if modified. |
| Open | Ctrl+O | Open an SVG file. Parses the SVG and replaces the current document. |
| Save | Ctrl+S | Save the document to the current filename. If no filename, behaves as Save As. |
| Save As | Ctrl+Shift+S | Prompt for a filename, then export the document as SVG. |
| Revert | | Reload the document from the current file, discarding all changes. |
| --- | | separator |
| Quit | Ctrl+Q | Exit the application. Prompts to save if modified. |

### File operations

**Open** reads an SVG file, parses it into a Document using the SVG import
module, updates the model's filename, and replaces the document. The undo
stack is cleared.

**Save / Save As** exports the document to SVG using the SVG export module
and writes it to disk. After saving, the model records the saved state so
that `is_modified` returns false until the next mutation.

**Revert** re-reads the file at the current filename and replaces the
document. The undo stack is cleared.

---

## Edit Menu

| Item | Shortcut | Description |
|------|----------|-------------|
| Undo | Ctrl+Z | Restore the previous document from the undo stack. |
| Redo | Ctrl+Y | Restore the next document from the redo stack. |
| --- | | separator |
| Cut | Ctrl+X | Copy the selection to the clipboard, then delete it. |
| Copy | Ctrl+C | Copy the selected elements to an internal clipboard. |
| Paste | Ctrl+V | Insert clipboard elements into the active layer with an offset. |
| Paste in Place | Ctrl+Shift+V | Insert clipboard elements at their original positions (no offset). |
| --- | | separator |
| Select All | Ctrl+A | Select all elements in all layers. |

### Undo / Redo

Undo pops from the undo stack, pushes the current document onto the redo
stack, and restores. Redo does the reverse. Both fire document-changed
listeners to trigger a repaint. The undo stack holds up to 100 entries.

### Clipboard operations

The clipboard is internal to the application (not the system clipboard).
It stores a list of elements.

- **Copy** collects the selected elements by path (sorted so they appear
  in document order) and stores them in the clipboard.
- **Cut** copies then deletes the selection via `delete_selection()`.
- **Paste** inserts clipboard elements into the active layer. Each element
  is offset by `PASTE_OFFSET` (24 pt) in both x and y to visually
  distinguish the paste from the original. The pasted elements become the
  new selection.
- **Paste in Place** inserts clipboard elements at their original
  coordinates with no offset.

### Select All

Selects every element across all layers with all their control points.
Groups are included along with their children.

---

## Object Menu

| Item | Shortcut | Description |
|------|----------|-------------|
| Group | Ctrl+G | Wrap the selected elements into a new Group. |
| Ungroup | Ctrl+Shift+G | Replace each selected Group with its children. |
| Ungroup All | | Recursively ungroup all Groups in the selection. |
| --- | | separator |
| Lock | Ctrl+2 | Lock the selected elements so they cannot be selected or edited. |
| Unlock All | Ctrl+Alt+2 | Unlock all locked elements in the document. |

### Group / Ungroup

**Group** collects the selected elements that are siblings in the same
parent container, removes them, and inserts a new Group containing them at
the position of the first selected element. The new Group and all its
children become the selection.

Elements must be siblings (children of the same parent) to be grouped. If
the selection spans multiple containers, only sibling sets are grouped.

**Ungroup** iterates over the selected elements. For each Group, it removes
the Group and splices its children into the parent container at the Group's
position. The ungrouped children become the new selection.

**Ungroup All** recursively ungroups: it repeatedly ungroups until no
selected element is a Group. This flattens nested group hierarchies.

### Lock / Unlock

**Lock** sets `locked = true` on all selected elements, recursing into
Groups to lock children as well, then clears the selection. Locked elements
are skipped by all selection tools and hit-test operations.

**Unlock All** clears the `locked` flag on every element in the document
and selects the newly unlocked elements with all their control points.

---

## View Menu

| Item | Shortcut | Description |
|------|----------|-------------|
| Zoom In | Ctrl++ | Increase the canvas zoom level. |
| Zoom Out | Ctrl+- | Decrease the canvas zoom level. |
| Fit in Window | Ctrl+0 | Adjust zoom and pan so the entire document fits in the canvas. |

View commands do not modify the document and do not create undo entries.
They adjust the canvas viewport parameters (zoom scale and pan offset).

---

## Command Dispatch

Menu commands are connected to handler functions through the UI framework's
action system:

| Language | Mechanism |
|----------|-----------|
| Python | Qt `QAction.triggered` signal connected to a lambda or method |
| OCaml | GTK menu item `connect#activate` callback |
| Rust | Dioxus event handler closures in the menu bar component |
| Swift | AppKit `NSMenuItem` with `action` selector and `target` |

All handlers follow the same pattern: snapshot, mutate, update. The
framework-specific wiring differs but the logic is identical across
implementations.

---

## Keyboard Shortcut Summary

| Shortcut | Command |
|----------|---------|
| Ctrl+N | New |
| Ctrl+O | Open |
| Ctrl+S | Save |
| Ctrl+Shift+S | Save As |
| Ctrl+Q | Quit |
| Ctrl+Z | Undo |
| Ctrl+Y | Redo |
| Ctrl+X | Cut |
| Ctrl+C | Copy |
| Ctrl+V | Paste |
| Ctrl+Shift+V | Paste in Place |
| Ctrl+A | Select All |
| Ctrl+G | Group |
| Ctrl+Shift+G | Ungroup |
| Ctrl+2 | Lock |
| Ctrl+Alt+2 | Unlock All |
| Ctrl++ | Zoom In |
| Ctrl+- | Zoom Out |
| Ctrl+0 | Fit in Window |

On macOS (Swift implementation), Ctrl is replaced by Cmd (⌘).
