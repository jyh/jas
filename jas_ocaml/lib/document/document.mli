(** Immutable document model.

    A document is an ordered list of layers. Elements are identified by
    their path: a list of integer indices into the tree. *)

(** A path identifies an element by its position in the document tree. *)
type element_path = int list

(** A set of element paths. *)
module PathSet : Set.S with type elt = element_path

(** Per-element selection state. *)
type element_selection = {
  es_path : element_path;
  es_control_points : int list;
}

(** A map from element path to its selection state. *)
module PathMap : Map.S with type key = element_path

(** A selection is a map from element path to element_selection. *)
type selection = element_selection PathMap.t

(** A document consisting of an ordered list of layers. *)
type document = {
  layers : Element.element list;
  selected_layer : int;
  selection : selection;
}

val make_document :
  ?selected_layer:int -> ?selection:selection ->
  Element.element list -> document

val make_element_selection :
  ?control_points:int list -> element_path -> element_selection

val selected_paths : selection -> PathSet.t
val get_element_selection : selection -> element_path -> element_selection option
val default_document : unit -> document
val bounds : document -> float * float * float * float
val get_element : document -> element_path -> Element.element
val replace_element : document -> element_path -> Element.element -> document
val insert_element_after : document -> element_path -> Element.element -> document
val delete_element : document -> element_path -> document
val delete_selection : document -> document
val children_of : Element.element -> Element.element list
