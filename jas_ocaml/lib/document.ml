(** Immutable document model.

    A document is an ordered list of layers. *)

open Element

(** A document consisting of a title and an ordered list of layers. *)
type document = {
  title : string;
  layers : element list;
  selected_layer : int;
}

let make_document ?(title = "Untitled") ?(selected_layer = 0) layers =
  { title; layers; selected_layer }

let default_document () = make_document ~title:"Untitled" [Element.make_layer []]

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
