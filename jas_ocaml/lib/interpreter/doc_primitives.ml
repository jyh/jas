(** Document-aware evaluator primitives.

    [hit_test] / [hit_test_deep] / [selection_contains] /
    [selection_empty] need access to the current Document while
    expressions are being evaluated. [Yaml_tool]'s dispatch handler
    calls [register_document] before running a handler's effects;
    the [doc_guard] type returned has a [restore] method that the
    caller invokes (or lets drop) after dispatch so nested dispatch
    works correctly.

    Returns plain OCaml types (option for paths, bool for selection
    checks) — [Expr_eval] wraps them as [value]s. This avoids a
    module-dependency cycle with [Expr_eval]. *)

let current_document : Document.document option ref = ref None

(** Registration handle — when its [restore] method is called
    (typically at the end of the dispatch block that opened it),
    the previous document is reinstated. *)
type doc_guard = { restore : unit -> unit }

(** Register [doc] as the current document for doc-aware primitives.
    Returns a guard; call [guard.restore ()] to put back the prior
    document (which may be [None]). Nested registrations stack. *)
let register_document (doc : Document.document) : doc_guard =
  let prior = !current_document in
  current_document := Some doc;
  { restore = (fun () -> current_document := prior) }

(** Run [f] with [doc] registered, restoring the prior on completion. *)
let with_doc (doc : Document.document) (f : unit -> 'a) : 'a =
  let g = register_document doc in
  let finalize () = g.restore () in
  Fun.protect ~finally:finalize f

(** [hit_test x y]: top-level layer-child scan. [None] on miss. *)
let hit_test (x : float) (y : float) : int list option =
  match !current_document with
  | None -> None
  | Some doc ->
    let result = ref None in
    let layer_count = Array.length doc.layers in
    (try
      for li = layer_count - 1 downto 0 do
        let layer = doc.layers.(li) in
        if Element.is_locked layer then ()
        else begin
          let children = match layer with
            | Element.Layer { children; _ } -> children
            | _ -> [||]
          in
          let cn = Array.length children in
          for ci = cn - 1 downto 0 do
            let child = children.(ci) in
            if Element.is_locked child then ()
            else begin
              let (bx, by, bw, bh) = Element.bounds child in
              if x >= bx && x <= bx +. bw &&
                 y >= by && y <= by +. bh then begin
                result := Some [li; ci];
                raise Exit
              end
            end
          done
        end
      done;
      None
    with Exit -> !result)

let rec hit_test_elem_recurse (path : int list) (elem : Element.element)
    (x : float) (y : float) : int list option =
  if Element.is_locked elem then None
  else
    match elem with
    | Element.Group { children; _ }
    | Element.Layer { children; _ } ->
      let cn = Array.length children in
      let result = ref None in
      (try
        for i = cn - 1 downto 0 do
          let child = children.(i) in
          let sub_path = path @ [i] in
          (match hit_test_elem_recurse sub_path child x y with
           | Some p -> result := Some p; raise Exit
           | None -> ())
        done;
        None
      with Exit -> !result)
    | _ ->
      let (bx, by, bw, bh) = Element.bounds elem in
      if x >= bx && x <= bx +. bw && y >= by && y <= by +. bh
      then Some path
      else None

let hit_test_deep (x : float) (y : float) : int list option =
  match !current_document with
  | None -> None
  | Some doc ->
    let layer_count = Array.length doc.layers in
    let result = ref None in
    (try
      for li = layer_count - 1 downto 0 do
        match hit_test_elem_recurse [li] doc.layers.(li) x y with
        | Some p -> result := Some p; raise Exit
        | None -> ()
      done
    with Exit -> ());
    !result

(** [selection_contains path]: true when the path is in the current
    document's selection. *)
let selection_contains (path : int list) : bool =
  match !current_document with
  | None -> false
  | Some doc -> Document.PathMap.mem path doc.selection

(** [selection_empty]: true when the current doc's selection is
    empty (or no doc registered). *)
let selection_empty () : bool =
  match !current_document with
  | None -> true
  | Some doc -> Document.PathMap.is_empty doc.selection
