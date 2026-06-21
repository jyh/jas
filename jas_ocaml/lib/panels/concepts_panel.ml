(** Concepts panel native glue (CONCEPTS.md section 6). The panel body (concept
    row list + Place footer) is rendered by the generic YAML interpreter from
    [workspace/panels/concepts.yaml] — a [foreach] over [data.concepts]. This
    module supplies the native Place arm (the [place_concept_instance] action is
    a [log] stub, like Place Instance) and the render-time concept resolver.

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

(** PLACE INSTANCE: append a generated instance of the panel-selected concept to
    the active layer (CONCEPTS.md section 6). No-op when none is selected. Mints
    the element id (value-in-op), then [place_concept_instance] — one undo step
    via the Controller's self-bracketing. *)
let place_concept_instance (store : State_store.t) (m : Model.model) : unit =
  match selected_concept store with
  | None -> ()
  | Some concept_id ->
    let existing = existing_ids m#document in
    (match mint existing with
     | None -> ()
     | Some elem_id ->
       let params = default_params concept_id in
       let ctrl = new Controller.controller ~model:m () in
       ctrl#place_concept_instance concept_id params elem_id)

(** SET PARAM: write [value] onto parameter [name] of the single selected
    Generated instance so it re-generates live (CONCEPTS.md section 6.4). No-op
    unless exactly one Generated element is selected. One undo step via the
    Controller's self-bracketing. Mirrors the Rust [set_concept_param] arm. *)
let set_concept_param (_store : State_store.t) (m : Model.model)
    (name : string) (value : float) : unit =
  let doc = m#document in
  match Document.PathMap.bindings doc.Document.selection with
  | [ (path, _) ] ->
    (match (try Some (Document.get_element doc path) with _ -> None) with
     | Some (Element.Live (Element.Generated _)) ->
       let ctrl = new Controller.controller ~model:m () in
       ctrl#set_concept_param path name value
     | _ -> ())
  | _ -> ()

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
