(** Thread-local-equivalent (ref-cell) point buffers.

    Tools that accumulate coordinates during a drag (Lasso, Pencil)
    use named buffers here. The module-local assoc list plays the
    role of Rust's thread_local! / Swift's module ref. *)

let buffers : (string * (float * float) list) list ref = ref []

let clear (name : string) : unit =
  buffers := (name, []) :: List.filter (fun (k, _) -> k <> name) !buffers

let push (name : string) (x : float) (y : float) : unit =
  let existing = match List.assoc_opt name !buffers with
    | Some l -> l | None -> []
  in
  let updated = existing @ [(x, y)] in
  buffers := (name, updated) :: List.filter (fun (k, _) -> k <> name) !buffers

let length (name : string) : int =
  match List.assoc_opt name !buffers with
  | Some l -> List.length l
  | None -> 0

let points (name : string) : (float * float) list =
  match List.assoc_opt name !buffers with
  | Some l -> l
  | None -> []
