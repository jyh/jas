(** Immutable document model.

    A document is an ordered list of layers.

    Elements within the document are identified by their path: a list of integer
    indices tracing the route from the document's layer list to the element.
    For example, path [0; 2] means layer 0, child 2.  Path [1] means layer 1
    itself.  This allows selections and updates without requiring element identity. *)

open Element

(** A path identifies an element by its position in the document tree. *)
type element_path = int list

(** A selection is a set of element paths. *)
module PathSet = Set.Make(struct
  type t = element_path
  let compare = compare
end)

(** Per-element selection state. *)
type element_selection = {
  es_path : element_path;
  es_selected : bool;
  es_control_points : int list;
}

(** A selection is a map from element path to its selection state. *)
module PathMap = Map.Make(struct
  type t = element_path
  let compare = compare
end)

type selection = element_selection PathMap.t

(** A document consisting of a title and an ordered list of layers. *)
type document = {
  title : string;
  layers : element list;
  selected_layer : int;
  selection : selection;
}

let make_document ?(title = "Untitled") ?(selected_layer = 0) ?(selection = PathMap.empty) layers =
  { title; layers; selected_layer; selection }

let make_element_selection ?(selected = true) ?(control_points = []) path =
  { es_path = path; es_selected = selected; es_control_points = control_points }

(** Return the set of all element paths in the selection. *)
let selected_paths sel =
  PathMap.fold (fun path _ acc -> PathSet.add path acc) sel PathSet.empty

(** Return the element_selection for the given path, or None. *)
let get_element_selection sel path =
  PathMap.find_opt path sel

let default_document () = make_document ~title:"Untitled"
  ~selection:PathMap.empty [Element.make_layer []]

let bounds doc =
  match doc.layers with
  | [] -> (0.0, 0.0, 0.0, 0.0)
  | _ ->
    let all_bounds = List.map Element.bounds doc.layers in
    let min_x = List.fold_left (fun acc (x, _, _, _) -> min acc x) infinity all_bounds in
    let min_y = List.fold_left (fun acc (_, y, _, _) -> min acc y) infinity all_bounds in
    let max_x = List.fold_left (fun acc (x, _, w, _) -> max acc (x +. w)) neg_infinity all_bounds in
    let max_y = List.fold_left (fun acc (_, y, _, h) -> max acc (y +. h)) neg_infinity all_bounds in
    (min_x, min_y, max_x -. min_x, max_y -. min_y)

(** Return the children of an element, if it is a group or layer. *)
let children_of = function
  | Group { children; _ } | Layer { children; _ } -> children
  | _ -> failwith "element has no children"

(** Return the element at the given path in the document. *)
let get_element doc path =
  match path with
  | [] -> failwith "path must be non-empty"
  | [i] -> List.nth doc.layers i
  | i :: rest ->
    let rec walk node = function
      | [] -> node
      | j :: rest -> walk (List.nth (children_of node) j) rest
    in
    walk (List.nth doc.layers i) rest

(** Replace the nth element of a list. *)
let list_replace_nth lst n x =
  List.mapi (fun i e -> if i = n then x else e) lst

(** Recursively replace the element at [rest] inside a group/layer node. *)
let rec replace_in_group node rest new_elem =
  match rest with
  | [] -> new_elem
  | [i] ->
    let cs = children_of node in
    let new_children = list_replace_nth cs i new_elem in
    (match node with
     | Group { opacity; transform; _ } -> Group { children = new_children; opacity; transform }
     | Layer { name; opacity; transform; _ } -> Layer { name; children = new_children; opacity; transform }
     | _ -> failwith "element has no children")
  | i :: rest ->
    let cs = children_of node in
    let child = List.nth cs i in
    let new_child = replace_in_group child rest new_elem in
    let new_children = list_replace_nth cs i new_child in
    (match node with
     | Group { opacity; transform; _ } -> Group { children = new_children; opacity; transform }
     | Layer { name; opacity; transform; _ } -> Layer { name; children = new_children; opacity; transform }
     | _ -> failwith "element has no children")

(** Return a new document with the element at [path] replaced by [new_elem]. *)
let replace_element doc path new_elem =
  match path with
  | [] -> failwith "path must be non-empty"
  | [i] ->
    { doc with layers = list_replace_nth doc.layers i new_elem }
  | i :: rest ->
    let layer = List.nth doc.layers i in
    let new_layer = replace_in_group layer rest new_elem in
    { doc with layers = list_replace_nth doc.layers i new_layer }
