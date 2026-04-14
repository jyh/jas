(** Immutable lexical scope for expression evaluation.

    Bindings are stored as an immutable association list. New scopes are
    created via [extend] (push child scope) or [merge] (add bindings at
    same level). The scope chain implements static scoping — inner scopes
    shadow outer bindings without mutating them. *)

type t = {
  bindings : (string * Yojson.Safe.t) list;
  parent : t option;
}

let create (bindings : (string * Yojson.Safe.t) list) : t =
  { bindings; parent = None }

let from_json (ctx : Yojson.Safe.t) : t =
  match ctx with
  | `Assoc pairs -> { bindings = pairs; parent = None }
  | _ -> { bindings = []; parent = None }

(** Resolve a top-level key through the scope chain. *)
let rec get (scope : t) (key : string) : Yojson.Safe.t option =
  match List.assoc_opt key scope.bindings with
  | Some _ as v -> v
  | None -> match scope.parent with
    | Some p -> get p key
    | None -> None

(** Push a child scope. Self becomes the parent. *)
let extend (scope : t) (new_bindings : (string * Yojson.Safe.t) list) : t =
  { bindings = new_bindings; parent = Some scope }

(** Merge: create a new scope at the same level with additional bindings. *)
let merge (scope : t) (extra : (string * Yojson.Safe.t) list) : t =
  let merged = scope.bindings @ List.filter (fun (k, _) ->
    not (List.mem_assoc k scope.bindings)
  ) extra in
  { bindings = merged; parent = scope.parent }

(** Flatten the scope chain to a Yojson.Safe.t Assoc value. *)
let rec to_json (scope : t) : Yojson.Safe.t =
  let parent_pairs = match scope.parent with
    | Some p ->
      (match to_json p with
       | `Assoc pairs -> pairs
       | _ -> [])
    | None -> []
  in
  (* Child bindings override parent bindings *)
  let merged = scope.bindings @ List.filter (fun (k, _) ->
    not (List.mem_assoc k scope.bindings)
  ) parent_pairs in
  `Assoc merged
