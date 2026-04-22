# Gradient tool

The Gradient tool is the on-canvas geometric editor for the active
gradient. It is the canvas-side counterpart to the Gradient panel (see
`GRADIENT.md`): where the panel edits a gradient through numeric inputs
and a 1-D stops strip, the tool edits it through direct manipulation on
the canvas — dragging endpoint handles, rotating, placing freeform
nodes.

This document is a stub. The full tool design — handle geometry,
gesture set, coordinate systems, visibility rules — is scheduled as a
follow-up. v1 of the Gradient feature ships with the panel from
`GRADIENT.md`; canvas editing goes through the panel's numeric inputs
until this tool lands.

## Contract with the Gradient panel

The single source of truth is the gradient object on `element.fill` or
`element.stroke` (per `GRADIENT.md` Document model). The panel and the
tool are two views of the same data:

- Both read from `element.fill` / `element.stroke` (per
  `state.fill_on_top`).
- Both write back to the same field via the standard commit pipeline.
- No synchronization protocol is needed — the data model *is* the
  protocol.

Shared state:

| Field                               | Purpose                                                      |
|-------------------------------------|--------------------------------------------------------------|
| `state.fill_on_top`                 | Which attribute (fill or stroke) the tool manipulates        |
| `state.selected_gradient_stop_index`| Selected stop/node index, shared with the panel              |

Activating the tool implicitly opens the Gradient panel tab (if
hidden). Closing the Gradient panel does not deactivate the tool.

## Scope (open design)

The following are scheduled for design and will be added to this
document when worked on:

- **Visibility rules** — when the handles / overlay render. Candidates:
  whenever the tool is active and the selection has a gradient on the
  active attribute; whenever the tool is active regardless of
  gradient-ness (with a promote-on-first-drag behavior mirroring the
  panel's fill-type coupling).
- **Linear-gradient handles** — start point, end point, rotational
  grip. Drag start/end to set the gradient vector; rotate via the grip
  modifies `angle`; stretching the vector modifies `aspect_ratio`.
- **Radial-gradient handles** — center point, outer radius handle,
  optional focal-point handle, major/minor axis handles when
  `aspect_ratio ≠ 100%`.
- **Freeform-gradient nodes** — primary manipulation UI for freeform
  gradients (the panel's stops strip is disabled for freeform).
  Click-to-add nodes; drag nodes to reposition; Delete key removes.
  Per-node color / opacity / spread edited through the panel's
  `STOP_OPACITY_COMBO` / `STOP_LOCATION_COMBO` (relabelled to Spread)
  while a node is selected.
- **Stop markers on-canvas for linear / radial** — the same stops
  shown in the panel's `GRADIENT_SLIDER` also render along the
  on-canvas gradient line (or radius), visually duplicated so the user
  can drag either view.
- **Coordinate systems** — whether endpoint positions are stored in
  bounding-box-normalized coords (0–1 within the element's bbox) or
  document-absolute coords. Bbox-normalized is the natural fit for
  stored gradients that survive transforms; document-absolute is the
  natural fit for a "linked" world-space gradient. Pick one as default
  with a link/unlink toggle comparable to opacity-mask linking.
- **Tool registration** — the tool's entry in `workspace/tools.yaml`
  (or equivalent), keyboard accelerator, toolbar icon.

## Panel-to-selection wiring status

Not yet implemented in any app. Target order per `CLAUDE.md`: Flask
first, then Rust, Swift, OCaml, Python.

- **Flask** (`jas_flask`): pending.
- **Rust** (`jas_dioxus`): pending.
- **Swift** (`JasSwift`): pending.
- **OCaml** (`jas_ocaml`): pending.
- **Python** (`jas`): pending.
