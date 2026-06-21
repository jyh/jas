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

let document_setup_view (s : Document_setup.t) : Yojson.Safe.t =
  `Assoc [
    ("bleed_top", `Float s.bleed_top);
    ("bleed_right", `Float s.bleed_right);
    ("bleed_bottom", `Float s.bleed_bottom);
    ("bleed_left", `Float s.bleed_left);
    ("bleed_uniform", `Bool s.bleed_uniform);
    ("show_images_outline", `Bool s.show_images_outline);
    ("highlight_substituted_glyphs", `Bool s.highlight_substituted_glyphs);
    ("grid_size", `Float s.grid_size);
    ("grid_color", `String s.grid_color);
    ("paper_color", `String s.paper_color);
    ("simulate_colored_paper", `Bool s.simulate_colored_paper);
    ("transparency_flattener_preset",
     `String (Print_preferences.flattener_preset_to_string s.transparency_flattener_preset));
    ("discard_white_overprint", `Bool s.discard_white_overprint);
  ]

let advanced_view (a : Print_preferences.advanced) : Yojson.Safe.t =
  `Assoc [
    ("print_as_bitmap", `Bool a.print_as_bitmap);
    ("overprint_flattener_preset",
     `String (Print_preferences.flattener_preset_to_string a.overprint_flattener_preset));
  ]

let color_management_view (c : Print_preferences.color_management) : Yojson.Safe.t =
  `Assoc [
    ("document_profile", `String c.document_profile);
    ("color_handling",
     `String (Print_preferences.color_handling_to_string c.color_handling));
    ("printer_profile", `String c.printer_profile);
    ("rendering_intent",
     `String (Print_preferences.rendering_intent_to_string c.rendering_intent));
    ("preserve_rgb_numbers", `Bool c.preserve_rgb_numbers);
  ]

let graphics_view (g : Print_preferences.graphics) : Yojson.Safe.t =
  `Assoc [
    ("flatness", `Float g.flatness);
    ("font_download",
     `String (Print_preferences.font_download_to_string g.font_download));
    ("postscript_level",
     `String (Print_preferences.postscript_level_to_string g.postscript_level));
    ("data_format",
     `String (Print_preferences.data_format_to_string g.data_format));
    ("compatible_gradient_printing", `Bool g.compatible_gradient_printing);
    ("raster_effects_resolution", `Float g.raster_effects_resolution);
  ]

let ink_override_view (ink : Print_preferences.ink_override) : Yojson.Safe.t =
  `Assoc [
    ("name", `String ink.name);
    ("print", `Bool ink.print);
    ("frequency", `Float ink.frequency);
    ("angle", `Float ink.angle);
    ("dot_shape", `String (Print_preferences.dot_shape_to_string ink.dot_shape));
  ]

let output_view (o : Print_preferences.output) : Yojson.Safe.t =
  `Assoc [
    ("mode", `String (Print_preferences.output_mode_to_string o.mode));
    ("emulsion", `String (Print_preferences.emulsion_to_string o.emulsion));
    ("image_polarity",
     `String (Print_preferences.image_polarity_to_string o.image_polarity));
    ("printer_resolution", `String o.printer_resolution);
    ("convert_spot_to_process", `Bool o.convert_spot_to_process);
    ("overprint_black", `Bool o.overprint_black);
    ("inks", `List (List.map ink_override_view o.inks));
  ]

let marks_and_bleed_view (m : Print_preferences.marks_and_bleed) : Yojson.Safe.t =
  `Assoc [
    ("all_printer_marks", `Bool m.all_printer_marks);
    ("trim_marks", `Bool m.trim_marks);
    ("registration_marks", `Bool m.registration_marks);
    ("color_bars", `Bool m.color_bars);
    ("page_information", `Bool m.page_information);
    ("printer_mark_type",
     `String (Print_preferences.printer_mark_type_to_string m.printer_mark_type));
    ("trim_mark_weight", `Float m.trim_mark_weight);
    ("mark_offset", `Float m.mark_offset);
    ("use_document_bleed", `Bool m.use_document_bleed);
    ("bleed_top", `Float m.bleed_top);
    ("bleed_right", `Float m.bleed_right);
    ("bleed_bottom", `Float m.bleed_bottom);
    ("bleed_left", `Float m.bleed_left);
  ]

let print_preferences_view (p : Print_preferences.t) : Yojson.Safe.t =
  `Assoc [
    ("preset_name", `String p.preset_name);
    ("printer_name",
     match p.printer_name with Some s -> `String s | None -> `Null);
    ("copies", `Int p.copies);
    ("collate", `Bool p.collate);
    ("reverse_order", `Bool p.reverse_order);
    ("artboard_range_mode",
     `String (Print_preferences.artboard_range_mode_to_string p.artboard_range_mode));
    ("artboard_range", `String p.artboard_range);
    ("ignore_artboards", `Bool p.ignore_artboards);
    ("skip_blank_artboards", `Bool p.skip_blank_artboards);
    ("media_size", `String (Print_preferences.media_size_to_string p.media_size));
    ("media_width", `Float p.media_width);
    ("media_height", `Float p.media_height);
    ("orientation", `String (Print_preferences.orientation_to_string p.orientation));
    ("auto_rotate", `Bool p.auto_rotate);
    ("transverse", `Bool p.transverse);
    ("print_layers", `String (Print_preferences.print_layers_to_string p.print_layers));
    ("placement_x", `Float p.placement_x);
    ("placement_y", `Float p.placement_y);
    ("scaling_mode", `String (Print_preferences.scaling_mode_to_string p.scaling_mode));
    ("custom_scale", `Float p.custom_scale);
    ("tile_overlap_h", `Float p.tile_overlap_h);
    ("tile_overlap_v", `Float p.tile_overlap_v);
    ("tile_range", `String p.tile_range);
    ("marks_and_bleed", marks_and_bleed_view p.marks_and_bleed);
    ("output", output_view p.output);
    ("graphics", graphics_view p.graphics);
    ("color_management", color_management_view p.color_management);
    ("advanced", advanced_view p.advanced);
  ]

(** Build the [symbols] view (SYMBOLS.md section 8). One row per master in
    the off-canvas store: [id] is the master's stable id; [name] is its
    common.name falling back to a positional "Symbol N" (1-based) label so
    every row always shows something readable; [usage_count] is the number
    of live instances of that master — the length of its reverse-dependency
    list (rdeps) in the dependency index, the same signal that gates the
    reference-aware delete. Mirrors the Rust build_active_document_view
    symbols block. *)
let symbols_view (doc : Document.document) : Yojson.Safe.t =
  let dep_index = Dependency_index.build doc in
  let symbols_json =
    Array.to_list doc.Document.symbols
    |> List.mapi (fun i m ->
      let id = match Element.id_of m with Some s -> s | None -> "" in
      let name =
        match Element.name_of m with
        | Some n when n <> "" -> n
        | _ -> Printf.sprintf "Symbol %d" (i + 1)
      in
      let usage_count =
        match List.assoc_opt id dep_index.Dependency_index.rdeps with
        | Some refs -> List.length refs
        | None -> 0
      in
      `Assoc [
        ("id", `String id);
        ("name", `String name);
        ("usage_count", `Int usage_count);
      ])
  in
  `List symbols_json

(* The compiled workspace registry, loaded once (concepts are static data). *)
let concepts_workspace = lazy (Workspace_loader.load ())

(** [active_document.selected_concept] (CONCEPTS.md section 6.4): [`Null] unless
    exactly one Generated concept instance is selected; otherwise
    [{ concept_id, name, params: [{ name, value, min, max }, …] }] — the
    concept's registry param schema merged with the instance's current values
    (the instance value if present, else the schema default). Drives the
    Concepts panel's PARAMS mode. Mirrors the Rust [build_selected_concept_view]. *)
let selected_concept_view (doc : Document.document) : Yojson.Safe.t =
  match Document.PathMap.bindings doc.Document.selection with
  | [ (path, _) ] ->
    (match (try Some (Document.get_element doc path) with _ -> None) with
     | Some (Element.Live (Element.Generated gen)) ->
       let concept_id = gen.Element.gen_concept_id in
       (match Lazy.force concepts_workspace with
        | None -> `Null
        | Some ws ->
          (match Workspace_loader.concept ws concept_id with
           | None -> `Null
           | Some spec ->
             let name = match Workspace_loader.json_member "name" spec with
               | Some (`String s) -> s | _ -> concept_id in
             let inst_params = match gen.Element.gen_params with
               | `Assoc kvs -> kvs | _ -> [] in
             let params_out = match Workspace_loader.json_member "params" spec with
               | Some (`List ps) ->
                 List.filter_map (fun p ->
                   match Workspace_loader.json_member "name" p with
                   | Some (`String pname) ->
                     let value = match List.assoc_opt pname inst_params with
                       | Some v -> v
                       | None ->
                         (match Workspace_loader.json_member "default" p with
                          | Some d -> d | None -> `Null) in
                     let entry = [ ("name", `String pname); ("value", value) ] in
                     let entry = match Workspace_loader.json_member "min" p with
                       | Some mn -> entry @ [ ("min", mn) ] | None -> entry in
                     let entry = match Workspace_loader.json_member "max" p with
                       | Some mx -> entry @ [ ("max", mx) ] | None -> entry in
                     Some (`Assoc entry)
                   | _ -> None) ps
               | _ -> [] in
             (* The concept's named operations (CONCEPTS.md section 9):
                id + label + description, so the panel can render a button per
                operation. Empty when the concept declares no [operations:]. *)
             let operations_out = match Workspace_loader.json_member "operations" spec with
               | Some (`List ops) ->
                 List.filter_map (fun o ->
                   match Workspace_loader.json_member "id" o with
                   | Some (`String oid) ->
                     let label = match Workspace_loader.json_member "label" o with
                       | Some (`String s) -> s | _ -> oid in
                     let description = match Workspace_loader.json_member "description" o with
                       | Some (`String s) -> s | _ -> "" in
                     Some (`Assoc [
                       ("id", `String oid);
                       ("label", `String label);
                       ("description", `String description);
                     ])
                   | _ -> None) ops
               | _ -> [] in
             `Assoc [
               ("concept_id", `String concept_id);
               ("name", `String name);
               ("params", `List params_out);
               ("operations", `List operations_out);
             ]))
     | _ -> `Null)
  | _ -> `Null

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
    ("symbols", `List []);
    ("selected_concept", `Null);
    ("document_setup", document_setup_view Document_setup.default);
    ("print_preferences", print_preferences_view Print_preferences.default);
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
          let name_str = match le.name with Some s -> s | None -> "" in
          Some (`Assoc [
            ("kind", `String "Layer");
            ("name", `String name_str);
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
        | Element.Layer le -> le.name
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
      ("symbols", symbols_view m#document);
      ("selected_concept", selected_concept_view m#document);
      ("document_setup", document_setup_view m#document.Document.document_setup);
      ("print_preferences", print_preferences_view m#document.Document.print_preferences);
    ]

(** Build the selection-level predicates referenced by yaml
    expressions (``selection_has_mask``, ``selection_mask_clip``,
    ``selection_mask_invert``, ``selection_mask_linked``) per
    OPACITY.md \167States / \167Document model. Mixed selections count as
    "no mask"; the mask fields come from the first selected
    element's mask and drive the "first-wins" bindings on
    CLIP_CHECKBOX / INVERT_MASK_CHECKBOX / LINK_INDICATOR. Mirrors
    ``build_selection_predicates`` in ``jas_dioxus``. *)
let build_selection_predicates (model : Model.model option) : (string * Yojson.Safe.t) list =
  match model with
  | None ->
    [ ("selection_has_mask", `Bool false);
      ("selection_mask_clip", `Bool false);
      ("selection_mask_invert", `Bool false);
      (* Default [linked] to true so the LINK_INDICATOR shows the
         linked glyph when no mask exists — matches the "new masks
         are linked" spec default. *)
      ("selection_mask_linked", `Bool true);
      ("editing_target_is_mask", `Bool false) ]
  | Some m ->
    let doc = m#document in
    let has_mask = Controller.selection_has_mask doc in
    let (clip, invert, linked) = match Controller.first_mask doc with
      | Some mask ->
        (mask.Element.clip, mask.Element.invert, mask.Element.linked)
      | None -> (false, false, true)
    in
    let editing_mask = match m#editing_target with
      | Model.Mask _ -> true
      | Model.Content -> false
    in
    [ ("selection_has_mask", `Bool has_mask);
      ("selection_mask_clip", `Bool clip);
      ("selection_mask_invert", `Bool invert);
      ("selection_mask_linked", `Bool linked);
      ("editing_target_is_mask", `Bool editing_mask) ]
