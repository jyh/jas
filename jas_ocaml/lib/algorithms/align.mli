(** Align and distribute operations — see [transcripts/ALIGN.md]
    and [align.ml]. *)

type bounds = float * float * float * float
type element_path = int list

type align_reference =
  | Selection of bounds
  | Artboard of bounds
  | Key_object of { bbox : bounds; path : element_path }

val reference_bbox : align_reference -> bounds
val reference_key_path : align_reference -> element_path option

type align_translation = {
  path : element_path;
  dx : float;
  dy : float;
}

type bounds_fn = Element.element -> bounds

val preview_bounds : bounds_fn
val geometric_bounds : bounds_fn

val union_bounds : Element.element list -> bounds_fn -> bounds

type axis = Horizontal | Vertical
type axis_anchor = Anchor_min | Anchor_center | Anchor_max

val axis_extent : bounds -> axis -> float * float * float
val anchor_position : bounds -> axis -> axis_anchor -> float
