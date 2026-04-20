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

(** Generic alignment driver used by the six public Align
    operations. For each selected element whose bbox anchor
    differs from the reference bbox anchor along the given axis,
    emit a translation that moves it onto the target.

    Elements whose path matches [reference_key_path reference]
    are skipped — the key object never moves, per ALIGN.md Align
    To target. Zero-delta translations are omitted per the
    identity-value rule. *)
let align_along_axis elements reference axis anchor bounds_fn =
  let target = anchor_position (reference_bbox reference) axis anchor in
  let key_path = reference_key_path reference in
  List.filter_map (fun (path, elem) ->
    if Some path = key_path then None
    else
      let pos = anchor_position (bounds_fn elem) axis anchor in
      let delta = target -. pos in
      if delta = 0.0 then None
      else
        let (dx, dy) = match axis with
          | Horizontal -> (delta, 0.0)
          | Vertical -> (0.0, delta)
        in
        Some { path; dx; dy }
  ) elements

(** ALIGN_LEFT_BUTTON. *)
let align_left elements reference bounds_fn =
  align_along_axis elements reference Horizontal Anchor_min bounds_fn

(** ALIGN_HORIZONTAL_CENTER_BUTTON. *)
let align_horizontal_center elements reference bounds_fn =
  align_along_axis elements reference Horizontal Anchor_center bounds_fn

(** ALIGN_RIGHT_BUTTON. *)
let align_right elements reference bounds_fn =
  align_along_axis elements reference Horizontal Anchor_max bounds_fn

(** ALIGN_TOP_BUTTON. *)
let align_top elements reference bounds_fn =
  align_along_axis elements reference Vertical Anchor_min bounds_fn

(** ALIGN_VERTICAL_CENTER_BUTTON. *)
let align_vertical_center elements reference bounds_fn =
  align_along_axis elements reference Vertical Anchor_center bounds_fn

(** ALIGN_BOTTOM_BUTTON. *)
let align_bottom elements reference bounds_fn =
  align_along_axis elements reference Vertical Anchor_max bounds_fn

(** Generic driver for the six Distribute operations. Sorts the
    selection by current anchor position along the axis,
    determines the span from the reference (extremal anchors
    for Selection or Key_object, artboard extent for Artboard),
    and emits translations that place each element's anchor at
    an evenly-spaced position within the span.

    Distribute operations require at least 3 elements per
    ALIGN.md Enable and disable rules; fewer yields an empty
    output. Key objects are skipped; zero-delta translations
    are omitted. Output is sorted by path for determinism. *)
let distribute_along_axis elements reference axis anchor bounds_fn =
  let n = List.length elements in
  if n < 3 then []
  else begin
    let elements_arr = Array.of_list elements in
    let indexed = Array.init n (fun i ->
      let (_, e) = elements_arr.(i) in
      (i, anchor_position (bounds_fn e) axis anchor)
    ) in
    Array.sort (fun (_, a) (_, b) -> compare a b) indexed;
    let (min_anchor, max_anchor) =
      match reference with
      | Selection _ | Key_object _ ->
        (snd indexed.(0), snd indexed.(n - 1))
      | Artboard bbox ->
        let (lo, hi, _) = axis_extent bbox axis in
        (lo, hi)
    in
    let key_path = reference_key_path reference in
    let out = ref [] in
    Array.iteri (fun sorted_idx (original_idx, current) ->
      let t = float_of_int sorted_idx /. float_of_int (n - 1) in
      let new_anchor = min_anchor +. (max_anchor -. min_anchor) *. t in
      let delta = new_anchor -. current in
      if delta <> 0.0 then begin
        let (path, _) = elements_arr.(original_idx) in
        if Some path <> key_path then begin
          let (dx, dy) = match axis with
            | Horizontal -> (delta, 0.0)
            | Vertical -> (0.0, delta)
          in
          out := { path; dx; dy } :: !out
        end
      end
    ) indexed;
    List.sort (fun a b -> compare a.path b.path) !out
  end

(** DISTRIBUTE_LEFT_BUTTON. *)
let distribute_left elements reference bounds_fn =
  distribute_along_axis elements reference Horizontal Anchor_min bounds_fn

(** DISTRIBUTE_HORIZONTAL_CENTER_BUTTON. *)
let distribute_horizontal_center elements reference bounds_fn =
  distribute_along_axis elements reference Horizontal Anchor_center bounds_fn

(** DISTRIBUTE_RIGHT_BUTTON. *)
let distribute_right elements reference bounds_fn =
  distribute_along_axis elements reference Horizontal Anchor_max bounds_fn

(** DISTRIBUTE_TOP_BUTTON. *)
let distribute_top elements reference bounds_fn =
  distribute_along_axis elements reference Vertical Anchor_min bounds_fn

(** DISTRIBUTE_VERTICAL_CENTER_BUTTON. *)
let distribute_vertical_center elements reference bounds_fn =
  distribute_along_axis elements reference Vertical Anchor_center bounds_fn

(** DISTRIBUTE_BOTTOM_BUTTON. *)
let distribute_bottom elements reference bounds_fn =
  distribute_along_axis elements reference Vertical Anchor_max bounds_fn

(** Generic driver for the two Distribute Spacing operations.
    Sorts the selection along the axis by min-edge and
    equalises the gaps between consecutive bboxes.

    Behaviour depends on [explicit_gap]:
    - [None] (average mode): first and last elements hold;
      interior gaps average to (span - sum of sizes) / (n - 1).
    - [Some gap] (explicit mode): the key object holds; others
      walk outward from the key with exactly [gap] points of
      space between consecutive bboxes. Requires a key-object
      reference — returns empty otherwise.

    Fewer than 3 elements yield an empty output. Key objects are
    skipped; zero-delta translations are omitted. *)
let distribute_spacing_along_axis elements reference axis explicit_gap bounds_fn =
  let n = List.length elements in
  if n < 3 then []
  else begin
    let elements_arr = Array.of_list elements in
    let sorted = Array.init n (fun i ->
      let (_, e) = elements_arr.(i) in
      let (lo, hi, _) = axis_extent (bounds_fn e) axis in
      (i, lo, hi)
    ) in
    Array.sort (fun (_, a, _) (_, b, _) -> compare a b) sorted;

    let new_mins = match explicit_gap with
      | Some gap ->
        (match reference_key_path reference with
         | None -> [||]
         | Some kp ->
           let key_original_idx = ref None in
           Array.iteri (fun i (path, _) ->
             if path = kp then key_original_idx := Some i
           ) elements_arr;
           (match !key_original_idx with
            | None -> [||]
            | Some koi ->
              let key_sorted_idx = ref None in
              Array.iteri (fun i (oi, _, _) ->
                if oi = koi then key_sorted_idx := Some i
              ) sorted;
              (match !key_sorted_idx with
               | None -> [||]
               | Some ksi ->
                 let positions = Array.make n 0.0 in
                 let (_, k_lo, _) = sorted.(ksi) in
                 positions.(ksi) <- k_lo;
                 for i = ksi + 1 to n - 1 do
                   let (_, prev_lo, prev_hi) = sorted.(i - 1) in
                   let prev_size = prev_hi -. prev_lo in
                   positions.(i) <- positions.(i - 1) +. prev_size +. gap
                 done;
                 for i = ksi - 1 downto 0 do
                   let (_, lo, hi) = sorted.(i) in
                   let size = hi -. lo in
                   positions.(i) <- positions.(i + 1) -. gap -. size
                 done;
                 positions)))
      | None ->
        let (_, first_lo, _) = sorted.(0) in
        let (_, _, last_hi) = sorted.(n - 1) in
        let total_span = last_hi -. first_lo in
        let total_sizes = Array.fold_left
          (fun acc (_, lo, hi) -> acc +. (hi -. lo)) 0.0 sorted in
        let gap = (total_span -. total_sizes) /. float_of_int (n - 1) in
        let positions = Array.make n 0.0 in
        let cursor = ref first_lo in
        Array.iteri (fun i (_, lo, hi) ->
          positions.(i) <- !cursor;
          cursor := !cursor +. (hi -. lo) +. gap
        ) sorted;
        positions
    in
    if Array.length new_mins = 0 then []
    else begin
      let key_path = reference_key_path reference in
      let out = ref [] in
      Array.iteri (fun sorted_idx (original_idx, old_min, _) ->
        let delta = new_mins.(sorted_idx) -. old_min in
        if delta <> 0.0 then begin
          let (path, _) = elements_arr.(original_idx) in
          if Some path <> key_path then begin
            let (dx, dy) = match axis with
              | Horizontal -> (delta, 0.0)
              | Vertical -> (0.0, delta)
            in
            out := { path; dx; dy } :: !out
          end
        end
      ) sorted;
      List.sort (fun a b -> compare a.path b.path) !out
    end
  end

(** DISTRIBUTE_VERTICAL_SPACING_BUTTON. *)
let distribute_vertical_spacing elements reference explicit_gap bounds_fn =
  distribute_spacing_along_axis elements reference Vertical explicit_gap bounds_fn

(** DISTRIBUTE_HORIZONTAL_SPACING_BUTTON. *)
let distribute_horizontal_spacing elements reference explicit_gap bounds_fn =
  distribute_spacing_along_axis elements reference Horizontal explicit_gap bounds_fn
