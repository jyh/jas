(** Panel menu item types and per-panel lookup functions. *)

open Workspace_layout

(** A menu item in a panel's hamburger menu. *)
type panel_menu_item =
  | Action of { label : string; command : string; shortcut : string }
  | Toggle of { label : string; command : string }
  | Radio of { label : string; command : string; group : string }
  | Separator

(** All panel kinds, for iteration. *)
let all_panel_kinds = [| Layers; Color; Swatches; Stroke; Properties |]

(** Human-readable label for a panel kind. *)
let panel_label = function
  | Layers -> "Layers"
  | Color -> "Color"
  | Swatches -> "Swatches"
  | Stroke -> "Stroke"
  | Properties -> "Properties"

(** Menu items for a panel kind. *)
let panel_menu = function
  | Layers ->
    [ Action { label = "New Layer..."; command = "new_layer"; shortcut = "" };
      Action { label = "New Group"; command = "new_group"; shortcut = "" };
      Separator;
      Action { label = "Hide All Layers"; command = "toggle_all_layers_visibility"; shortcut = "" };
      Action { label = "Outline All Layers"; command = "toggle_all_layers_outline"; shortcut = "" };
      Action { label = "Lock All Layers"; command = "toggle_all_layers_lock"; shortcut = "" };
      Separator;
      Action { label = "Enter Isolation Mode"; command = "enter_isolation_mode"; shortcut = "" };
      Action { label = "Exit Isolation Mode"; command = "exit_isolation_mode"; shortcut = "" };
      Separator;
      Action { label = "Flatten Artwork"; command = "flatten_artwork"; shortcut = "" };
      Action { label = "Collect in New Layer"; command = "collect_in_new_layer"; shortcut = "" };
      Separator;
      Action { label = "Close Layers"; command = "close_panel"; shortcut = "" } ]
  | Color ->
    [ Radio { label = "Grayscale"; command = "mode_grayscale"; group = "color_mode" };
      Radio { label = "RGB"; command = "mode_rgb"; group = "color_mode" };
      Radio { label = "HSB"; command = "mode_hsb"; group = "color_mode" };
      Radio { label = "CMYK"; command = "mode_cmyk"; group = "color_mode" };
      Radio { label = "Web Safe RGB"; command = "mode_web_safe_rgb"; group = "color_mode" };
      Separator;
      Action { label = "Invert"; command = "invert_color"; shortcut = "" };
      Action { label = "Complement"; command = "complement_color"; shortcut = "" };
      Separator;
      Action { label = "Close Color"; command = "close_panel"; shortcut = "" } ]
  | Swatches -> [Action { label = "Close Swatches"; command = "close_panel"; shortcut = "" }]
  | Stroke -> [Action { label = "Close Stroke"; command = "close_panel"; shortcut = "" }]
  | Properties -> [Action { label = "Close Properties"; command = "close_panel"; shortcut = "" }]

(** Set the active color (fill or stroke per fill_on_top), push to recent colors. *)
let set_active_color color ~fill_on_top (m : Model.model) =
  if fill_on_top then begin
    m#set_default_fill (Some (Element.make_fill color));
    if not (Document.PathMap.is_empty m#document.Document.selection) then begin
      m#snapshot;
      let ctrl = Controller.create ~model:m () in
      ctrl#set_selection_fill (Some (Element.make_fill color))
    end
  end else begin
    let width = match m#default_stroke with Some s -> s.stroke_width | None -> 1.0 in
    m#set_default_stroke (Some (Element.make_stroke ~width color));
    if not (Document.PathMap.is_empty m#document.Document.selection) then begin
      m#snapshot;
      let ctrl = Controller.create ~model:m () in
      ctrl#set_selection_stroke (Some (Element.make_stroke ~width color))
    end
  end;
  let hex = Element.color_to_hex color in
  let rc = List.filter (fun c -> c <> hex) m#recent_colors in
  let rc = hex :: rc in
  let rc = if List.length rc > 10 then List.filteri (fun i _ -> i < 10) rc else rc in
  m#set_recent_colors rc

(** Set the active color without pushing to recent colors (live slider drag). *)
let set_active_color_live color ~fill_on_top (m : Model.model) =
  if fill_on_top then
    m#set_default_fill (Some (Element.make_fill color))
  else begin
    let width = match m#default_stroke with Some s -> s.stroke_width | None -> 1.0 in
    m#set_default_stroke (Some (Element.make_stroke ~width color))
  end

(** Dispatch a layers action through the compiled YAML effects (Phase 3).
    Wires snapshot and doc.set to operate on the active Model, and
    injects active_document.top_level_layer_paths / top_level_layers
    into the evaluation context. *)
let dispatch_yaml_action (action_name : string) (m : Model.model) : unit =
  match Workspace_loader.load () with
  | None -> ()
  | Some ws ->
    match Workspace_loader.json_member "actions" ws.data with
    | Some (`Assoc actions_map) ->
      (match List.assoc_opt action_name actions_map with
       | Some (`Assoc action_def) ->
         let effects = match List.assoc_opt "effects" action_def with
           | Some (`List e) -> e | _ -> []
         in
         (* Build active_document view from model.document *)
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
         let active_doc = `Assoc [
           ("top_level_layers", `List top_level_layers);
           ("top_level_layer_paths", `List top_level_layer_paths);
         ] in
         let ctx = [("active_document", active_doc)] in
         (* Platform handlers: snapshot → model snapshot; doc.set → element mutation *)
         (* Element stash — Phase 3 Group B doc.clone_at / doc.delete_at
            return Elements; we store them here keyed by their `as:` name
            (or for clones, by a marker in the returned JSON). *)
         let element_stash : (string, Element.element) Hashtbl.t = Hashtbl.create 4 in
         let next_stash_id = ref 0 in
         let snapshot_h : Effects.platform_effect = fun _ _ _ ->
           m#snapshot; `Null in
         let doc_set_h : Effects.platform_effect = fun spec call_ctx _ ->
           let path_expr = match spec with
             | `Assoc pairs ->
               (match List.assoc_opt "path" pairs with
                | Some (`String s) -> s | _ -> "")
             | _ -> ""
           in
           let fields = match spec with
             | `Assoc pairs ->
               (match List.assoc_opt "fields" pairs with
                | Some (`Assoc fs) -> fs | _ -> [])
             | _ -> []
           in
           (* Evaluate against call-time ctx (which includes foreach's
              `p` and let's `target`), NOT the outer registration ctx. *)
           let eval_ctx = `Assoc call_ctx in
           let path_val = Expr_eval.evaluate path_expr eval_ctx in
           let indices = match path_val with Expr_eval.Path p -> p | _ -> [] in
           (* Support only top-level paths for now *)
           (match indices with
            | [idx] when idx >= 0 && idx < Array.length m#document.Document.layers ->
              let d = m#document in
              let new_layers = Array.copy d.Document.layers in
              let elem = new_layers.(idx) in
              List.iter (fun (dotted, expr_v) ->
                let expr_str = match expr_v with `String s -> s | _ -> "" in
                let v = Expr_eval.evaluate expr_str eval_ctx in
                let updated = match dotted, v with
                  | "common.visibility", Expr_eval.Str s ->
                    let vis = match s with
                      | "invisible" -> Element.Invisible
                      | "outline" -> Element.Outline
                      | "preview" -> Element.Preview
                      | _ -> Element.get_visibility elem
                    in
                    Element.set_visibility vis elem
                  | "common.locked", Expr_eval.Bool b ->
                    Element.set_locked b elem
                  | _ -> elem
                in
                new_layers.(idx) <- updated
              ) fields;
              m#set_document { d with Document.layers = new_layers }
            | _ -> ());
           `Null
         in
         (* doc.delete_at: deletes element at path, stashes + returns a ref. *)
         let doc_delete_at_h : Effects.platform_effect = fun value call_ctx _ ->
           let path_expr = match value with `String s -> s | _ -> "" in
           let eval_ctx = `Assoc call_ctx in
           let path_val = Expr_eval.evaluate path_expr eval_ctx in
           match path_val with
           | Expr_eval.Path [idx] when idx >= 0
              && idx < Array.length m#document.Document.layers ->
             let d = m#document in
             let elem = d.Document.layers.(idx) in
             let new_layers = Array.init (Array.length d.Document.layers - 1) (fun i ->
               if i < idx then d.Document.layers.(i)
               else d.Document.layers.(i + 1))
             in
             m#set_document { d with Document.layers = new_layers };
             let stash_id = Printf.sprintf "__elem_%d__" !next_stash_id in
             incr next_stash_id;
             Hashtbl.add element_stash stash_id elem;
             `Assoc [("__element_ref__", `String stash_id)]
           | _ -> `Null
         in
         (* doc.clone_at: deep-copies element at path, stashes + returns ref. *)
         let doc_clone_at_h : Effects.platform_effect = fun value call_ctx _ ->
           let path_expr = match value with `String s -> s | _ -> "" in
           let eval_ctx = `Assoc call_ctx in
           let path_val = Expr_eval.evaluate path_expr eval_ctx in
           match path_val with
           | Expr_eval.Path [idx] when idx >= 0
              && idx < Array.length m#document.Document.layers ->
             (* Element is a variant; deep-copy via re-construction. For
                now, just copy the record reference since Layer is
                functional (all fields copied on update). *)
             let elem = m#document.Document.layers.(idx) in
             let stash_id = Printf.sprintf "__elem_%d__" !next_stash_id in
             incr next_stash_id;
             Hashtbl.add element_stash stash_id elem;
             `Assoc [("__element_ref__", `String stash_id)]
           | _ -> `Null
         in
         (* doc.insert_after: resolves element arg (raw ref or ctx name)
            and inserts after path. *)
         let doc_insert_after_h : Effects.platform_effect = fun spec call_ctx _ ->
           let path_expr, element_arg = match spec with
             | `Assoc pairs ->
               let pe = match List.assoc_opt "path" pairs with
                 | Some (`String s) -> s | _ -> ""
               in
               let ea = List.assoc_opt "element" pairs in
               (pe, ea)
             | _ -> ("", None)
           in
           let eval_ctx = `Assoc call_ctx in
           let path_val = Expr_eval.evaluate path_expr eval_ctx in
           (* Resolve element: a raw __element_ref__ JSON, or an
              identifier pointing to such a JSON in call_ctx. *)
           let resolve_elem () : Element.element option =
             let ref_json = match element_arg with
               | Some (`Assoc _ as j) -> Some j
               | Some (`String name) ->
                 List.assoc_opt name call_ctx
               | _ -> None
             in
             match ref_json with
             | Some (`Assoc [("__element_ref__", `String id)]) ->
               Hashtbl.find_opt element_stash id
             | _ -> None
           in
           (match path_val, resolve_elem () with
            | Expr_eval.Path [idx], Some elem when idx >= 0 ->
              let d = m#document in
              let n = Array.length d.Document.layers in
              let insert_pos = min (idx + 1) n in
              let new_layers = Array.init (n + 1) (fun i ->
                if i < insert_pos then d.Document.layers.(i)
                else if i = insert_pos then elem
                else d.Document.layers.(i - 1))
              in
              m#set_document { d with Document.layers = new_layers }
            | _ -> ());
           `Null
         in
         let platform_effects = [
           ("snapshot", snapshot_h);
           ("doc.set", doc_set_h);
           ("doc.delete_at", doc_delete_at_h);
           ("doc.clone_at", doc_clone_at_h);
           ("doc.insert_after", doc_insert_after_h);
         ] in
         (* Snapshot once before the batch mutation *)
         let store = State_store.create () in
         Effects.run_effects ~platform_effects effects ctx store
       | _ -> ())
    | _ -> ()

(** Dispatch a menu command for a panel kind. *)
let panel_dispatch kind cmd addr layout ~fill_on_top ~get_model
    ?(get_panel_selection = fun () -> []) () =
  (* Mode changes *)
  (match color_panel_mode_of_command cmd with
   | Some mode -> layout.color_panel_mode <- mode
   | None -> ());
  match cmd with
  | "close_panel" -> close_panel layout addr
  | "new_layer" when kind = Layers ->
    let m = get_model () in
    let d = m#document in
    let used = Array.fold_left (fun acc e ->
      match e with
      | Element.Layer le -> le.name :: acc
      | _ -> acc) [] d.Document.layers in
    let rec find_name n =
      let candidate = Printf.sprintf "Layer %d" n in
      if List.mem candidate used then find_name (n + 1) else candidate
    in
    let name = find_name 1 in
    let new_layer = Element.make_layer ~name [||] in
    (* Insert above the topmost panel-selected top-level layer, or at end *)
    let panel_sel = get_panel_selection () in
    let top_level_indices = List.filter_map (function
      | [i] -> Some i
      | _ -> None) panel_sel in
    let insert_pos = match List.sort compare top_level_indices with
      | [] -> Array.length d.Document.layers
      | first :: _ -> first + 1
    in
    let layers = d.Document.layers in
    let n = Array.length layers in
    let new_layers = Array.init (n + 1) (fun i ->
      if i < insert_pos then layers.(i)
      else if i = insert_pos then new_layer
      else layers.(i - 1)) in
    m#snapshot;
    m#set_document { d with Document.layers = new_layers }
  | ("toggle_all_layers_visibility" | "toggle_all_layers_outline"
     | "toggle_all_layers_lock") when kind = Layers ->
    dispatch_yaml_action cmd (get_model ())
  | "new_group"
  | "enter_isolation_mode" | "exit_isolation_mode"
  | "flatten_artwork" | "collect_in_new_layer"
    when kind = Layers -> ()  (* Tier-3 stubs for actions that need panel selection *)
  | "invert_color" when kind = Color ->
    let m = get_model () in
    let color = if fill_on_top then
      Option.map (fun (f : Element.fill) -> f.fill_color) m#default_fill
    else
      Option.map (fun (s : Element.stroke) -> s.stroke_color) m#default_stroke
    in
    (match color with
     | Some c ->
       let (r, g, b, _) = Element.color_to_rgba c in
       let inverted = Element.color_rgb (1.0 -. r) (1.0 -. g) (1.0 -. b) in
       set_active_color inverted ~fill_on_top m
     | None -> ())
  | "complement_color" when kind = Color ->
    let m = get_model () in
    let color = if fill_on_top then
      Option.map (fun (f : Element.fill) -> f.fill_color) m#default_fill
    else
      Option.map (fun (s : Element.stroke) -> s.stroke_color) m#default_stroke
    in
    (match color with
     | Some c ->
       let (h, s, br, _) = Element.color_to_hsba c in
       if s > 0.001 then begin
         let new_h = Float.rem (h +. 180.0) 360.0 in
         let complemented = Element.color_hsb new_h s br in
         set_active_color complemented ~fill_on_top m
       end
     | None -> ())
  | _ -> ()

(** Query whether a toggle/radio command is checked. *)
let panel_is_checked _kind cmd layout =
  match color_panel_mode_of_command cmd with
  | Some mode -> layout.color_panel_mode = mode
  | None -> false
