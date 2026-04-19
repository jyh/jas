(** Build the [active_document] context namespace from a Model.

    Centralises the construction used by:
    - Panel body rendering
      (Yaml_panel_view.create_panel_body) — drives bind.disabled /
      bind.visible expressions that read active_document.*.
    - Layers-panel action dispatch (Panel_menu.dispatch_yaml_action) —
      evaluated against the same surface so action predicates and
      render-time predicates see the same values.

    [panel_selection] carries the layers-panel tree-selection so
    computed fields like new_layer_insert_index and
    layers_panel_selection_count see live panel state. Pass [] from
    callers that don't have layers-panel context. *)

let empty_no_model ?(panel_selection : int list list = []) () : Yojson.Safe.t =
  `Assoc [
    ("top_level_layers", `List []);
    ("top_level_layer_paths", `List []);
    ("next_layer_name", `String "Layer 1");
    ("new_layer_insert_index", `Int 0);
    ("layers_panel_selection_count", `Int (List.length panel_selection));
    ("has_selection", `Bool false);
    ("selection_count", `Int 0);
    ("element_selection", `List []);
  ]

let build
    ?(panel_selection : int list list = [])
    (model : Model.model option) : Yojson.Safe.t =
  match model with
  | None -> empty_no_model ~panel_selection ()
  | Some m ->
    let layers = m#document.Document.layers in
    let top_level_layers = Array.to_list layers
      |> List.mapi (fun i e -> (i, e))
      |> List.filter_map (fun (i, e) ->
        match e with
        | Element.Layer le ->
          let vis = match Element.get_visibility e with
            | Element.Invisible -> "invisible"
            | Element.Outline -> "outline"
            | Element.Preview -> "preview"
          in
          let path_json = `Assoc [("__path__", `List [`Int i])] in
          Some (`Assoc [
            ("kind", `String "Layer");
            ("name", `String le.name);
            ("common", `Assoc [
              ("visibility", `String vis);
              ("locked", `Bool (Element.is_locked e));
            ]);
            ("path", path_json);
          ])
        | _ -> None)
    in
    let top_level_layer_paths = List.mapi (fun i e ->
      match e with
      | Element.Layer _ -> Some (`Assoc [("__path__", `List [`Int i])])
      | _ -> None
    ) (Array.to_list layers) |> List.filter_map (fun x -> x) in
    let layer_names =
      Array.to_list layers
      |> List.filter_map (function
        | Element.Layer le -> Some le.name
        | _ -> None)
    in
    let rec find_n n =
      let candidate = Printf.sprintf "Layer %d" n in
      if List.mem candidate layer_names then find_n (n + 1)
      else candidate
    in
    let next_layer_name = find_n 1 in
    let top_level_selected = List.filter_map (function
      | [i] -> Some i
      | _ -> None) panel_selection in
    let new_layer_insert_index = match List.sort compare top_level_selected with
      | [] -> Array.length layers
      | first :: _ -> first + 1
    in
    (* Canvas selection from document.selection (PathMap from path to
       element_selection). Sort bindings by path for deterministic
       order across runs. *)
    let selection = m#document.Document.selection in
    let sorted_paths =
      Document.PathMap.bindings selection
      |> List.map (fun (path, _) -> path)
      |> List.sort compare
    in
    let element_selection_json = `List (List.map (fun path ->
      `Assoc [("__path__", `List (List.map (fun i -> `Int i) path))]
    ) sorted_paths) in
    let selection_count = List.length sorted_paths in
    `Assoc [
      ("top_level_layers", `List top_level_layers);
      ("top_level_layer_paths", `List top_level_layer_paths);
      ("next_layer_name", `String next_layer_name);
      ("new_layer_insert_index", `Int new_layer_insert_index);
      ("layers_panel_selection_count", `Int (List.length panel_selection));
      ("has_selection", `Bool (selection_count > 0));
      ("selection_count", `Int selection_count);
      ("element_selection", element_selection_json);
    ]
