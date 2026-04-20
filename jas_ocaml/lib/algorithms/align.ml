(** Align and distribute operations — OCaml port of
    [jas_dioxus/src/algorithms/align.rs]. See
    [transcripts/ALIGN.md] for the spec.

    This module owns the geometry of the 14 Align panel buttons.
    Each operation reads a list of (path, element) pairs plus an
    [align_reference] (selection bbox, artboard rectangle, or
    designated key object) and returns a list of
    [align_translation] values for the caller to apply.

    The module is side-effect free. Callers are responsible for
    taking a document snapshot, pre-pending each element's
    transform with the returned (dx, dy), and committing the
    transaction. *)

type bounds = float * float * float * float
(** Axis-aligned bounding box (x, y, width, height). *)

type element_path = int list

(** Fixed reference a single Align / Distribute / Distribute
    Spacing operation consults. *)
type align_reference =
  | Selection of bounds
  | Artboard of bounds
  | Key_object of { bbox : bounds; path : element_path }

let reference_bbox = function
  | Selection b | Artboard b -> b
  | Key_object { bbox; _ } -> bbox

let reference_key_path = function
  | Key_object { path; _ } -> Some path
  | _ -> None

(** Per-element translation emitted by an Align operation. *)
type align_translation = {
  path : element_path;
  dx : float;
  dy : float;
}

(** Bounds-lookup function. Pass [preview_bounds] when Use
    Preview Bounds is checked in the panel menu; otherwise pass
    [geometric_bounds]. *)
type bounds_fn = Element.element -> bounds

let preview_bounds : bounds_fn = Element.bounds
let geometric_bounds : bounds_fn = Element.geometric_bounds

(** Union the bounding boxes of an element list using the given
    bounds function. Returns [(0, 0, 0, 0)] when the list is
    empty. *)
let union_bounds elements bounds_fn =
  match elements with
  | [] -> (0.0, 0.0, 0.0, 0.0)
  | _ ->
    let min_x = ref infinity in
    let min_y = ref infinity in
    let max_x = ref neg_infinity in
    let max_y = ref neg_infinity in
    List.iter (fun e ->
      let (x, y, w, h) = bounds_fn e in
      if x < !min_x then min_x := x;
      if y < !min_y then min_y := y;
      if x +. w > !max_x then max_x := x +. w;
      if y +. h > !max_y then max_y := y +. h
    ) elements;
    (!min_x, !min_y, !max_x -. !min_x, !max_y -. !min_y)

(** Axis of an operation — horizontal ops move in x, vertical
    in y. *)
type axis = Horizontal | Vertical

(** Which edge or midpoint along the axis the operation anchors
    to. *)
type axis_anchor = Anchor_min | Anchor_center | Anchor_max

(** Extract (lo, hi, mid) along the given axis from a bbox. *)
let axis_extent (x, y, w, h) = function
  | Horizontal -> (x, x +. w, x +. w /. 2.0)
  | Vertical -> (y, y +. h, y +. h /. 2.0)

(** The anchor position of a bbox along a given axis. *)
let anchor_position bbox axis anchor =
  let (lo, hi, mid) = axis_extent bbox axis in
  match anchor with
  | Anchor_min -> lo
  | Anchor_center -> mid
  | Anchor_max -> hi
