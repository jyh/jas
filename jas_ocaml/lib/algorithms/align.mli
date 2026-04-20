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

val align_along_axis
  : (element_path * Element.element) list
  -> align_reference -> axis -> axis_anchor -> bounds_fn
  -> align_translation list

val align_left
  : (element_path * Element.element) list -> align_reference -> bounds_fn
  -> align_translation list
val align_horizontal_center
  : (element_path * Element.element) list -> align_reference -> bounds_fn
  -> align_translation list
val align_right
  : (element_path * Element.element) list -> align_reference -> bounds_fn
  -> align_translation list
val align_top
  : (element_path * Element.element) list -> align_reference -> bounds_fn
  -> align_translation list
val align_vertical_center
  : (element_path * Element.element) list -> align_reference -> bounds_fn
  -> align_translation list
val align_bottom
  : (element_path * Element.element) list -> align_reference -> bounds_fn
  -> align_translation list

val distribute_along_axis
  : (element_path * Element.element) list
  -> align_reference -> axis -> axis_anchor -> bounds_fn
  -> align_translation list

val distribute_left
  : (element_path * Element.element) list -> align_reference -> bounds_fn
  -> align_translation list
val distribute_horizontal_center
  : (element_path * Element.element) list -> align_reference -> bounds_fn
  -> align_translation list
val distribute_right
  : (element_path * Element.element) list -> align_reference -> bounds_fn
  -> align_translation list
val distribute_top
  : (element_path * Element.element) list -> align_reference -> bounds_fn
  -> align_translation list
val distribute_vertical_center
  : (element_path * Element.element) list -> align_reference -> bounds_fn
  -> align_translation list
val distribute_bottom
  : (element_path * Element.element) list -> align_reference -> bounds_fn
  -> align_translation list

val distribute_spacing_along_axis
  : (element_path * Element.element) list -> align_reference
  -> axis -> float option -> bounds_fn
  -> align_translation list

val distribute_vertical_spacing
  : (element_path * Element.element) list -> align_reference
  -> float option -> bounds_fn
  -> align_translation list

val distribute_horizontal_spacing
  : (element_path * Element.element) list -> align_reference
  -> float option -> bounds_fn
  -> align_translation list
