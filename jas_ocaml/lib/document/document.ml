(** Immutable document model.

    A document is an ordered array of layers.

    Elements within the document are identified by their path: a list of integer
    indices tracing the route from the document's layer array to the element.
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

(** Sorted, de-duplicated list of control-point indices.

    The wrapper enforces the invariant: the backing list is sorted
    ascending and contains no duplicates. All constructors and
    operations preserve it. *)
module SortedCps = struct
  type t = int list  (* sorted, unique *)

  let empty : t = []

  let from_list (xs : int list) : t =
    List.sort_uniq compare xs

  let single i : t = [i]

  let mem i (s : t) = List.mem i s

  let to_list (s : t) : int list = s

  let length (s : t) = List.length s

  let is_empty (s : t) = s = []

  let insert i (s : t) : t =
    if List.mem i s then s else from_list (i :: s)

  let symmetric_difference (a : t) (b : t) : t =
    let in_a_only = List.filter (fun x -> not (List.mem x b)) a in
    let in_b_only = List.filter (fun x -> not (List.mem x a)) b in
    from_list (in_a_only @ in_b_only)
end

(** Per-element selection kind: either the element is fully selected
    (`SelKindAll`) or only a subset of its CPs are selected
    (`SelKindPartial of SortedCps.t`). *)
type selection_kind =
  | SelKindAll
  | SelKindPartial of SortedCps.t

let selection_kind_contains kind i =
  match kind with
  | SelKindAll -> true
  | SelKindPartial s -> SortedCps.mem i s

let selection_kind_count kind ~total =
  match kind with
  | SelKindAll -> total
  | SelKindPartial s -> SortedCps.length s

let selection_kind_is_all kind ~total =
  match kind with
  | SelKindAll -> true
  | SelKindPartial s -> SortedCps.length s = total

let selection_kind_to_sorted kind ~total =
  match kind with
  | SelKindAll ->
    let rec range i n = if i >= n then [] else i :: range (i + 1) n in
    range 0 total
  | SelKindPartial s -> SortedCps.to_list s

(** Per-element selection state. *)
type element_selection = {
  es_path : element_path;
  es_kind : selection_kind;
}

(** A selection is a map from element path to its selection state. *)
module PathMap = Map.Make(struct
  type t = element_path
  let compare = compare
end)

type selection = element_selection PathMap.t

(** A document consisting of an ordered array of layers. *)
type document = {
  layers : element array;
  selected_layer : int;
  selection : selection;
}

let make_document ?(selected_layer = 0) ?(selection = PathMap.empty) layers =
  { layers; selected_layer; selection }

(** Build a fully-selected entry for [path]. *)
let element_selection_all path =
  { es_path = path; es_kind = SelKindAll }

(** Build a partial entry for [path] from a list of CP indices. *)
let element_selection_partial path cps =
  { es_path = path; es_kind = SelKindPartial (SortedCps.from_list cps) }

(** Legacy constructor kept for compatibility with existing call sites. *)
let make_element_selection ?(control_points = []) path =
  if control_points = [] then element_selection_all path
  else element_selection_partial path control_points

(** Return the set of all element paths in the selection. *)
let selected_paths sel =
  PathMap.fold (fun path _ acc -> PathSet.add path acc) sel PathSet.empty

(** Return the element_selection for the given path, or None. *)
let get_element_selection sel path =
  PathMap.find_opt path sel

let default_document () = make_document
  ~selection:PathMap.empty [| Element.make_layer [||] |]

let bounds doc =
  if Array.length doc.layers = 0 then (0.0, 0.0, 0.0, 0.0)
  else
    let all_bounds = Array.map Element.bounds doc.layers in
    let min_x = Array.fold_left (fun acc (x, _, _, _) -> min acc x) infinity all_bounds in
    let min_y = Array.fold_left (fun acc (_, y, _, _) -> min acc y) infinity all_bounds in
    let max_x = Array.fold_left (fun acc (x, _, w, _) -> max acc (x +. w)) neg_infinity all_bounds in
    let max_y = Array.fold_left (fun acc (_, y, _, h) -> max acc (y +. h)) neg_infinity all_bounds in
    (min_x, min_y, max_x -. min_x, max_y -. min_y)

(** Return the children of an element, if it is a group or layer. *)
let children_of = function
  | Group { children; _ } | Layer { children; _ } -> children
  | _ -> failwith "element has no children"

(** Return the element at the given path in the document. *)
let get_element doc path =
  match path with
  | [] -> failwith "path must be non-empty"
  | [i] -> doc.layers.(i)
  | i :: rest ->
    let rec walk node = function
      | [] -> node
      | j :: rest -> walk (children_of node).(j) rest
    in
    walk doc.layers.(i) rest

let effective_visibility doc path =
  match path with
  | [] -> Element.Preview
  | i :: rest ->
    if i >= Array.length doc.layers then Element.Preview
    else
      let node = ref doc.layers.(i) in
      let effective = ref (Element.get_visibility !node) in
      let rec walk = function
        | [] -> ()
        | j :: rest ->
          let children = children_of !node in
          if j >= Array.length children then ()
          else begin
            node := children.(j);
            let v = Element.get_visibility !node in
            if compare v !effective < 0 then effective := v;
            walk rest
          end
      in
      walk rest;
      !effective

(** Return a copy of the array with element at index n replaced. *)
let array_replace_nth arr n x =
  let a = Array.copy arr in
  a.(n) <- x; a

(** Return the node with new_children substituted. *)
let with_children node new_children =
  match node with
  | Group { opacity; transform; locked; visibility; _ } ->
    Group { children = new_children; opacity; transform; locked; visibility }
  | Layer { name; opacity; transform; locked; visibility; _ } ->
    Layer { name; children = new_children; opacity; transform; locked; visibility }
  | _ -> failwith "element has no children"

(** Recursively replace the element at [rest] inside a group/layer node. *)
let rec replace_in_group node rest new_elem =
  match rest with
  | [] -> new_elem
  | [i] ->
    with_children node (array_replace_nth (children_of node) i new_elem)
  | i :: rest ->
    let cs = children_of node in
    let new_child = replace_in_group cs.(i) rest new_elem in
    with_children node (array_replace_nth cs i new_child)

(** Return a new array with x inserted after position n. *)
let array_insert_after arr n x =
  let len = Array.length arr in
  Array.init (len + 1) (fun i ->
    if i <= n then arr.(i)
    else if i = n + 1 then x
    else arr.(i - 1))

(** Recursively insert new_elem after the position indicated by rest. *)
let rec insert_after_in_group node rest new_elem =
  match rest with
  | [] -> failwith "rest must be non-empty"
  | [i] ->
    with_children node (array_insert_after (children_of node) i new_elem)
  | i :: rest ->
    let cs = children_of node in
    let new_child = insert_after_in_group cs.(i) rest new_elem in
    with_children node (array_replace_nth cs i new_child)

(** Return a new document with new_elem inserted immediately after path. *)
let insert_element_after doc path new_elem =
  match path with
  | [] -> failwith "path must be non-empty"
  | [i] ->
    { doc with layers = array_insert_after doc.layers i new_elem }
  | i :: rest ->
    let layer = doc.layers.(i) in
    let new_layer = insert_after_in_group layer rest new_elem in
    { doc with layers = array_replace_nth doc.layers i new_layer }

(** Return a new document with the element at [path] replaced by [new_elem]. *)
let replace_element doc path new_elem =
  match path with
  | [] -> failwith "path must be non-empty"
  | [i] ->
    { doc with layers = array_replace_nth doc.layers i new_elem }
  | i :: rest ->
    let layer = doc.layers.(i) in
    let new_layer = replace_in_group layer rest new_elem in
    { doc with layers = array_replace_nth doc.layers i new_layer }

(** Return a new array with element at index n removed. *)
let array_remove_nth arr n =
  let len = Array.length arr in
  Array.init (len - 1) (fun i -> if i < n then arr.(i) else arr.(i + 1))

(** Recursively remove the element at [rest] inside a group/layer node. *)
let rec remove_from_group node rest =
  match rest with
  | [] -> failwith "rest must be non-empty"
  | [i] -> with_children node (array_remove_nth (children_of node) i)
  | i :: rest ->
    let cs = children_of node in
    let new_child = remove_from_group cs.(i) rest in
    with_children node (array_replace_nth cs i new_child)

(** Return a new document with the element at [path] removed. *)
let delete_element doc path =
  match path with
  | [] -> failwith "path must be non-empty"
  | [i] -> { doc with layers = array_remove_nth doc.layers i }
  | i :: rest ->
    let layer = doc.layers.(i) in
    let new_layer = remove_from_group layer rest in
    { doc with layers = array_replace_nth doc.layers i new_layer }

(** Return a new document with all selected elements removed and selection cleared. *)
let delete_selection doc =
  let paths = PathMap.fold (fun _ es acc -> es.es_path :: acc) doc.selection [] in
  let sorted_paths = List.sort (fun a b -> compare b a) paths in
  let doc' = List.fold_left (fun d p -> delete_element d p) doc sorted_paths in
  { doc' with selection = PathMap.empty }
