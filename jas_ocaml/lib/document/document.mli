(** Immutable document model.

    A document is an ordered list of layers. Elements are identified by
    their path: a list of integer indices into the tree. *)

(** A path identifies an element by its position in the document tree. *)
type element_path = int list

(** A set of element paths. *)
module PathSet : Set.S with type elt = element_path

(** Sorted, de-duplicated collection of control-point indices. *)
module SortedCps : sig
  type t
  val empty : t
  val from_list : int list -> t
  val single : int -> t
  val mem : int -> t -> bool
  val to_list : t -> int list
  val length : t -> int
  val is_empty : t -> bool
  val insert : int -> t -> t
  val symmetric_difference : t -> t -> t
end

(** Selection kind: either the element is fully selected (`SelKindAll`)
    or only a subset of its CPs are selected (`SelKindPartial`). *)
type selection_kind =
  | SelKindAll
  | SelKindPartial of SortedCps.t

val selection_kind_contains : selection_kind -> int -> bool
val selection_kind_count : selection_kind -> total:int -> int
val selection_kind_is_all : selection_kind -> total:int -> bool
val selection_kind_to_sorted : selection_kind -> total:int -> int list

(** Per-element selection state. *)
type element_selection = {
  es_path : element_path;
  es_kind : selection_kind;
}

(** A map from element path to its selection state. *)
module PathMap : Map.S with type key = element_path

(** A selection is a map from element path to element_selection. *)
type selection = element_selection PathMap.t

(** A document consisting of an ordered list of layers plus
    artboards and document-global artboard options. *)
type document = {
  layers : Element.element array;
  selected_layer : int;
  selection : selection;
  artboards : Artboard.artboard list;
  artboard_options : Artboard.options;
}

val make_document :
  ?selected_layer:int -> ?selection:selection ->
  ?artboards:Artboard.artboard list ->
  ?artboard_options:Artboard.options ->
  Element.element array -> document

(** Convenience: build a fully-selected entry. *)
val element_selection_all : element_path -> element_selection

(** Convenience: build a partial entry from a CP index list. *)
val element_selection_partial : element_path -> int list -> element_selection

(** Legacy constructor: empty CP list -> SelKindAll, otherwise SelKindPartial. *)
val make_element_selection :
  ?control_points:int list -> element_path -> element_selection

val selected_paths : selection -> PathSet.t
val get_element_selection : selection -> element_path -> element_selection option
val default_document : unit -> document
val bounds : document -> float * float * float * float
val get_element : document -> element_path -> Element.element
val replace_element : document -> element_path -> Element.element -> document

(** Effective visibility of the element at [path], computed as the
    minimum of the visibilities of every element along the path from
    the root layer down to the target. A parent Group/Layer caps the
    visibility of everything it contains. *)
val effective_visibility : document -> element_path -> Element.visibility

val insert_element_after : document -> element_path -> Element.element -> document
val delete_element : document -> element_path -> document
val delete_selection : document -> document
val children_of : Element.element -> Element.element array
val with_children : Element.element -> Element.element array -> Element.element
