(** Concepts panel native glue (CONCEPTS.md section 6). The panel body (concept
    row list + Place footer) is rendered by the generic YAML interpreter from
    [workspace/panels/concepts.yaml] — a [foreach] over [data.concepts]. This
    module supplies the native Place arm (which BUILDS the VALUE-IN-OP
    [place_concept_instance] op for the panel view to route through
    [Op_apply.op_apply]) and the render-time concept resolver.

    Panel-selection ([selected_concept]) is a single concept id (or none),
    written into the panel's State_store scope by the GENERIC
    [concepts_panel_select] ([set_panel_state]); the place arm reads it. *)

let content_id = "concepts_panel_content"
let selected_key = "selected_concept"

(* The compiled workspace, loaded once — concepts are static registry data. *)
let workspace = lazy (Workspace_loader.load ())

(** The panel-selected concept id, or [None] when none is selected. *)
let selected_concept (store : State_store.t) : string option =
  match State_store.get_panel store content_id selected_key with
  | `String s when s <> "" -> Some s
  | _ -> None

(* Gather every existing element id so a freshly minted id avoids collisions
   (mirrors Symbols_panel.existing_ids). *)
let existing_ids (doc : Document.document) : (string, unit) Hashtbl.t =
  let set = Hashtbl.create 16 in
  let rec gather elem =
    (match Element.id_of elem with
     | Some id -> Hashtbl.replace set id ()
     | None -> ());
    match elem with
    | Element.Group { children; _ } | Element.Layer { children; _ } ->
      Array.iter gather children
    | _ -> ()
  in
  Array.iter gather doc.Document.layers;
  Array.iter gather doc.Document.symbols;
  set

(* Mint a collision-free stable id, retrying up to 100 times (mirrors
   Symbols_panel.mint / the Rust mint loop). *)
let mint (existing : (string, unit) Hashtbl.t) : string option =
  let rec loop n =
    if n <= 0 then None
    else
      let c = Element.generate_id () in
      if Hashtbl.mem existing c then loop (n - 1) else Some c
  in
  loop 100

(** The declared default parameters of [concept_id] as a JSON object
    [{ name -> default }] from the registry; [`Assoc []] when the concept or its
    params are missing. *)
let default_params (concept_id : string) : Yojson.Safe.t =
  match Lazy.force workspace with
  | None -> `Assoc []
  | Some ws ->
    (match Workspace_loader.concept ws concept_id with
     | None -> `Assoc []
     | Some spec ->
       (match Workspace_loader.json_member "params" spec with
        | Some (`List params) ->
          `Assoc (List.filter_map (fun p ->
            match Workspace_loader.json_member "name" p,
                  Workspace_loader.json_member "default" p with
            | Some (`String name), Some default -> Some (name, default)
            | _ -> None) params)
        | _ -> `Assoc []))

(** PLACE INSTANCE: build the VALUE-IN-OP [place_concept_instance] op for the
    panel-selected concept (CONCEPTS.md section 6-7) — the concept id, its
    RESOLVED default params (from the registry, baked in so replay never
    re-consults it), and a freshly minted element id. [None] when no concept is
    selected (or the id space is exhausted). The caller brackets one undo and
    routes the op through [Op_apply.op_apply] so it both mutates AND journals,
    replayable like the sibling structural verbs. *)
let place_concept_op (store : State_store.t) (m : Model.model)
  : Yojson.Safe.t option =
  match selected_concept store with
  | None -> None
  | Some concept_id ->
    let existing = existing_ids m#document in
    (match mint existing with
     | None -> None
     | Some elem_id ->
       let params = default_params concept_id in
       Some (`Assoc [
         ("op", `String "place_concept_instance");
         ("concept_id", `String concept_id);
         ("params", params);
         ("elem_id", `String elem_id);
       ]))

(** SET PARAM: build the VALUE-IN-OP [set_concept_param] op that writes [value]
    onto parameter [name] of the single selected Generated instance so it
    re-generates live (CONCEPTS.md section 6.4). [None] unless exactly one
    Generated element is selected. The path / name / value are baked into the op
    (resolved at production time, never re-derived on replay). The caller
    brackets one undo and routes through [Op_apply.op_apply]. *)
let set_concept_param_op (_store : State_store.t) (m : Model.model)
    (name : string) (value : float) : Yojson.Safe.t option =
  let doc = m#document in
  match Document.PathMap.bindings doc.Document.selection with
  | [ (path, _) ] ->
    (match (try Some (Document.get_element doc path) with _ -> None) with
     | Some (Element.Live (Element.Generated _)) ->
       Some (`Assoc [
         ("op", `String "set_concept_param");
         ("path", `List (List.map (fun i -> `Int i) path));
         ("name", `String name);
         ("value", `Float value);
       ])
     | _ -> None)
  | _ -> None

(** APPLY OPERATION: build the VALUE-IN-OP [apply_concept_operation] op for the
    named operation [op_id] of the single selected Generated instance (CONCEPTS.md
    section 9). The operation's effect is RESOLVED here, at production time: look
    the operation up in the registry by id, evaluate its [set:] expressions with
    the instance's CURRENT params bound under [param], and bake the resulting
    [changes] map into the op (value-in-op). [op_id] also rides on the op as
    journal metadata. [None] unless exactly one Generated element is selected, or
    when the concept/operation is unknown, or when the resolved [changes] map is
    empty. The caller brackets one undo and routes through [Op_apply.op_apply];
    replay merges [changes] and never re-evaluates the expressions. *)
let apply_concept_operation_op (_store : State_store.t) (m : Model.model)
    (op_id : string) : Yojson.Safe.t option =
  let doc = m#document in
  match Document.PathMap.bindings doc.Document.selection with
  | [ (path, _) ] ->
    (match (try Some (Document.get_element doc path) with _ -> None) with
     | Some (Element.Live (Element.Generated gen)) ->
       let concept_id = gen.Element.gen_concept_id in
       let params = gen.Element.gen_params in
       (* Resolve the operation's [set:] expressions over the instance's current
          params, bound under the [param] namespace (the generator's namespace),
          into the concrete [changes] map. Only numeric results are baked, stored
          as floats so serialization matches the conformance corpus. *)
       let changes =
         match Lazy.force workspace with
         | None -> None
         | Some ws ->
           (match Workspace_loader.concept ws concept_id with
            | None -> None
            | Some spec ->
              (match Workspace_loader.json_member "operations" spec with
               | Some (`List ops) ->
                 let operation = List.find_opt (fun o ->
                   match Workspace_loader.json_member "id" o with
                   | Some (`String oid) -> oid = op_id
                   | _ -> false) ops in
                 (match operation with
                  | None -> None
                  | Some operation ->
                    (match Workspace_loader.json_member "set" operation with
                     | Some (`Assoc set_kvs) ->
                       let ctx = `Assoc [ ("param", params) ] in
                       let resolved = List.filter_map (fun (name, expr_v) ->
                         match expr_v with
                         | `String src ->
                           (match Expr_eval.evaluate src ctx with
                            | Expr_eval.Number n -> Some (name, `Float n)
                            | _ -> None)
                         | _ -> None) set_kvs in
                       Some resolved
                     | _ -> None))
               | _ -> None))
       in
       (match changes with
        | Some (_ :: _ as change_kvs) ->
          Some (`Assoc [
            ("op", `String "apply_concept_operation");
            ("path", `List (List.map (fun i -> `Int i) path));
            ("op_id", `String op_id);
            ("changes", `Assoc change_kvs);
          ])
        | _ -> None)
     | _ -> None)
  | _ -> None

let num_of = function
  | `Int i -> float_of_int i
  | `Float f -> f
  | `Intlit s -> float_of_string s
  | _ -> 0.0

(** The render-time concept resolver: given a concept id, return [Some] a
    function that evaluates the concept's generator over a params object and
    yields its [(x, y)] points, or [None] when the concept is unknown. Lets the
    canvas draw a Generated instance's geometry (CONCEPTS.md 3b). *)
let concept_resolver : Live.concept_resolver = fun concept_id ->
  match Lazy.force workspace with
  | None -> None
  | Some ws ->
    (match Workspace_loader.concept ws concept_id with
     | None -> None
     | Some spec ->
       (match Workspace_loader.json_member "generator" spec with
        | Some (`String generator) ->
          Some (fun params ->
            let ctx = `Assoc [ ("param", params) ] in
            match Expr_eval.evaluate generator ctx with
            | Expr_eval.List items ->
              List.filter_map (function
                | `List [ a; b ] -> Some (num_of a, num_of b)
                | _ -> None) items
            | _ -> [])
        | _ -> None))
