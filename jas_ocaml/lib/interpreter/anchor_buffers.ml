(** Anchor buffers for the Pen tool.

    Each anchor carries an (x, y) position plus in/out handle
    positions and a smooth/corner flag. On [push], the anchor is
    appended as a corner (handles coincident with the anchor).
    [set_last_out_handle] converts the latest anchor into a smooth
    one by setting the out-handle explicitly and mirroring the
    in-handle through the anchor. *)

type anchor = {
  x : float;
  y : float;
  hx_in : float;
  hy_in : float;
  hx_out : float;
  hy_out : float;
  smooth : bool;
}

let buffers : (string * anchor list) list ref = ref []

let clear (name : string) : unit =
  buffers := (name, []) :: List.filter (fun (k, _) -> k <> name) !buffers

let push (name : string) (x : float) (y : float) : unit =
  let corner = {
    x; y;
    hx_in = x; hy_in = y;
    hx_out = x; hy_out = y;
    smooth = false;
  } in
  let existing = match List.assoc_opt name !buffers with
    | Some l -> l | None -> []
  in
  buffers := (name, existing @ [corner])
    :: List.filter (fun (k, _) -> k <> name) !buffers

let pop (name : string) : unit =
  let existing = match List.assoc_opt name !buffers with
    | Some l -> l | None -> []
  in
  (match existing with
   | [] -> ()
   | _ ->
     let n = List.length existing in
     let trimmed = List.filteri (fun i _ -> i < n - 1) existing in
     buffers := (name, trimmed)
       :: List.filter (fun (k, _) -> k <> name) !buffers)

(** Set the out-handle of the last anchor and mirror the in-handle
    through the anchor position; marks the anchor smooth. *)
let set_last_out_handle (name : string) (hx : float) (hy : float) : unit =
  let existing = match List.assoc_opt name !buffers with
    | Some l -> l | None -> []
  in
  match List.rev existing with
  | [] -> ()
  | last :: rest ->
    let updated = {
      last with
      hx_out = hx; hy_out = hy;
      hx_in = 2.0 *. last.x -. hx;
      hy_in = 2.0 *. last.y -. hy;
      smooth = true;
    } in
    let new_list = List.rev (updated :: rest) in
    buffers := (name, new_list)
      :: List.filter (fun (k, _) -> k <> name) !buffers

let length (name : string) : int =
  match List.assoc_opt name !buffers with
  | Some l -> List.length l
  | None -> 0

let first (name : string) : anchor option =
  match List.assoc_opt name !buffers with
  | Some (a :: _) -> Some a
  | _ -> None

let anchors (name : string) : anchor list =
  match List.assoc_opt name !buffers with
  | Some l -> l
  | None -> []

(** Close-hit: true when (x, y) is within [radius] of the first
    anchor and the buffer has >= 2 anchors (so closing makes sense). *)
let close_hit (name : string) (x : float) (y : float) (radius : float) : bool =
  match List.assoc_opt name !buffers with
  | Some (first :: _ :: _) ->
    let dx = x -. first.x and dy = y -. first.y in
    let d = Float.sqrt (dx *. dx +. dy *. dy) in
    d <= radius
  | _ -> false
