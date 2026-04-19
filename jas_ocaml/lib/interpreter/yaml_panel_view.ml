(** YAML-interpreted panel body renderer for GTK.

    Walks a JSON element tree from the compiled workspace and creates
    corresponding GTK widgets. Uses the expression evaluator for
    bind values and the workspace loader for panel specs. *)

open Workspace_layout

(** Module-level ref to the model accessor, set by create_panel_body. *)
let _get_model_ref : (unit -> Model.model option) ref = ref (fun () -> None)

(** Module-level ref to the panel-local state store, set by
    create_panel_body. Widget renderers read it to register write-back
    callbacks; None means "no store threaded, skip write-back". *)
let _current_store : State_store.t option ref = ref None

(** Module-level ref to the active panel id (e.g. "character_panel",
    "stroke_panel"). Set by create_panel_body alongside
    [_current_store]. *)
let _current_panel_id : string option ref = ref None

(** Parse a bind expression like "panel.X" or "state.X" and write
    [value] into the appropriate scope of [_current_store]. Silent
    no-op when either ref is unset or the expression doesn't match
    a recognised scope+key pattern. Used by the widget renderers'
    change callbacks to flow user edits back to the store (where
    the subscription fires the apply pipeline). *)
let _write_back_bind (bind_expr : string) (value : Yojson.Safe.t) : unit =
  match !_current_store, !_current_panel_id with
  | Some store, Some panel_id ->
    let parts = String.split_on_char '.' bind_expr in
    (match parts with
     | "panel" :: field :: _ ->
       (* Phase 4: paragraph writes route through the dedicated
          setter so mutual exclusion + sync + apply happen atomically.
          Skipped when no model is threaded (test harness). *)
       if panel_id = "paragraph_panel_content" then begin
         match !_get_model_ref () with
         | Some model ->
           let ctrl = new Controller.controller ~model () in
           Effects.set_paragraph_panel_field store ctrl field value
         | None ->
           State_store.set_panel store panel_id field value
       end else
         State_store.set_panel store panel_id field value
     | "state" :: field :: _ ->
       State_store.set store field value
     | _ -> ())
  | _ -> ()

(** Module-level set of collapsed element paths in the layers panel. *)
module PathKey = struct
  type t = int list
  let compare = compare
end
module PathSet2 = Set.Make(PathKey)
let _layers_collapsed : PathSet2.t ref = ref PathSet2.empty

(** Module-level set of panel-selected element paths. *)
let _layers_panel_selection : PathSet2.t ref = ref PathSet2.empty

(** Module-level path of the layer being renamed, or None. *)
let _layers_renaming : int list option ref = ref None

(** Module-level drag source and target paths for drag-and-drop. *)
let _layers_drag_source : int list option ref = ref None
let _layers_drag_target : int list option ref = ref None

(** Search query for filtering the layers tree by name. *)
let _layers_search_query : string ref = ref ""

(** Isolation mode stack — descendants of the deepest entry are shown.
    Lives in Layers_panel_state to avoid a dep cycle with panel_menu. *)

(** Set of element type names (lowercase) currently hidden by the filter. *)
module StrSet = Set.Make(String)
let _layers_hidden_types : StrSet.t ref = ref StrSet.empty

(** Saved direct-child lock states keyed by container path. *)
module PathMap2 = Map.Make(PathKey)
let _layers_saved_lock_states : bool list PathMap2.t ref = ref PathMap2.empty

(** Solo/unsolo state: (soloed_path, map from sibling path to saved visibility). *)
let _layers_solo_state : (int list * (int list * Element.visibility) list) option ref = ref None

(** Callback to trigger re-render when UI state changes. *)
let _rerender_layers : (unit -> unit) ref = ref (fun () -> ())

(** Return the current layers panel selection as a list of paths. *)
let get_layers_panel_selection () : int list list =
  PathSet2.elements !_layers_panel_selection

(** Safely access a nested JSON member path (e.g. "style" -> "gap").
    Returns `Null if any intermediate value is not an object. *)
let safe_member (key : string) (j : Yojson.Safe.t) : Yojson.Safe.t =
  match j with
  | `Assoc _ -> Yojson.Safe.Util.member key j
  | _ -> `Null

(** Check if an element should be visible based on its bind.visible expression.
    Returns true if no bind.visible is present, or if the expression evaluates to truthy. *)
let is_visible (el : Yojson.Safe.t) (ctx : Yojson.Safe.t) : bool =
  let open Yojson.Safe.Util in
  match el |> member "bind" with
  | `Assoc _ as bind ->
    (match bind |> member "visible" |> to_string_option with
     | Some expr ->
       let result = Expr_eval.evaluate expr ctx in
       Expr_eval.to_bool result
     | None -> true)
  | _ -> true

(** Render a YAML element spec into GTK widgets.
    [packing] is the GTK packing function for the parent container.
    [ctx] is the evaluation context (JSON object with "state", "panel", "icons" keys). *)
let rec render_element ~packing ~ctx (el : Yojson.Safe.t) =
  if not (is_visible el ctx) then ()
  else
  let open Yojson.Safe.Util in
  (* Handle repeat directive: expand template for each item in source *)
  match el |> member "foreach", el |> member "do" with
  | `Assoc _, template when template <> `Null ->
    render_repeat ~packing ~ctx el
  | _ ->
  let etype = el |> member "type" |> to_string_option |> Option.value ~default:"placeholder" in
  match etype with
  | "container" | "row" | "col" -> render_container ~packing ~ctx el etype
  | "fill_stroke_widget" -> render_container ~packing ~ctx el "fill_stroke_widget"
  | "grid" -> render_grid ~packing ~ctx el
  | "text" -> render_text ~packing ~ctx el
  | "button" | "icon_button" -> render_button ~packing ~ctx el
  | "slider" -> render_slider ~packing ~ctx el
  | "number_input" -> render_number_input ~packing ~ctx el
  | "text_input" -> render_text_input ~packing ~ctx el
  | "select" -> render_select ~packing ~ctx el
  | "toggle" | "checkbox" -> render_toggle ~packing ~ctx el
  | "combo_box" -> render_combo_box ~packing ~ctx el
  | "color_swatch" -> render_color_swatch ~packing ~ctx el
  | "separator" -> render_separator ~packing el
  | "spacer" -> render_spacer ~packing ()
  | "disclosure" -> render_disclosure ~packing ~ctx el
  | "panel" -> render_panel ~packing ~ctx el
  | "tree_view" -> render_tree_view ~packing ~ctx el
  | "element_preview" -> render_element_preview ~packing el
  | "dropdown" -> render_layers_filter_dropdown ~packing el
  | _ -> render_placeholder ~packing el

and render_container ~packing ~ctx el etype =
  let open Yojson.Safe.Util in
  let layout_dir = el |> member "layout" |> to_string_option |> Option.value ~default:"column" in
  let is_row = layout_dir = "row" || etype = "row" in
  let gap = el |> member "style" |> safe_member "gap" |> to_int_option |> Option.value ~default:0 in
  if is_row then begin
    let hbox = GPack.hbox ~spacing:gap ~packing () in
    render_children ~packing:(hbox#pack ~expand:false) ~ctx el
  end else begin
    let vbox = GPack.vbox ~spacing:gap ~packing () in
    render_children ~packing:(vbox#pack ~expand:false) ~ctx el
  end

and render_grid ~packing ~ctx el =
  let open Yojson.Safe.Util in
  let _cols = el |> member "cols" |> to_int_option |> Option.value ~default:2 in
  (* GTK grid approximated with an HBox *)
  let hbox = GPack.hbox ~spacing:2 ~packing () in
  render_children ~packing:(hbox#pack ~expand:false) ~ctx el

and render_text ~packing ~ctx el =
  let open Yojson.Safe.Util in
  let content = el |> member "content" |> to_string_option |> Option.value ~default:"" in
  let text = if String.length content > 0 && (try let _ = String.index content '{' in true with Not_found -> false)
    then Expr_eval.evaluate_text content ctx
    else content in
  let lbl = GMisc.label ~text ~packing () in
  lbl#set_xalign 0.0

and render_button ~packing ~ctx:_ el =
  let open Yojson.Safe.Util in
  let label = el |> member "label" |> to_string_option
    |> Option.value ~default:(el |> member "summary" |> to_string_option |> Option.value ~default:"") in
  let _btn = GButton.button ~label ~packing () in
  ()

and render_slider ~packing ~ctx el =
  let open Yojson.Safe.Util in
  let min_val = el |> member "min" |> to_number_option |> Option.value ~default:0.0 in
  let max_val = el |> member "max" |> to_number_option |> Option.value ~default:100.0 in
  let step = el |> member "step" |> to_number_option |> Option.value ~default:1.0 in
  let initial = match el |> member "bind" |> safe_member "value" |> to_string_option with
    | Some expr ->
      let v = Expr_eval.evaluate expr ctx in
      (match v with Expr_eval.Number n -> n | _ -> min_val)
    | None -> min_val in
  let adj = GData.adjustment ~lower:min_val ~upper:max_val ~step_incr:step ~value:initial () in
  let _scale = GRange.scale `HORIZONTAL ~adjustment:adj ~draw_value:false ~packing () in
  ()

and render_number_input ~packing ~ctx el =
  let open Yojson.Safe.Util in
  let min_val = el |> member "min" |> to_number_option |> Option.value ~default:0.0 in
  let max_val = el |> member "max" |> to_number_option |> Option.value ~default:100.0 in
  let bind_expr = el |> member "bind" |> safe_member "value" |> to_string_option in
  let initial = match bind_expr with
    | Some expr ->
      let v = Expr_eval.evaluate expr ctx in
      (match v with Expr_eval.Number n -> n | _ -> min_val)
    | None -> min_val in
  let adj = GData.adjustment ~lower:min_val ~upper:max_val ~step_incr:1.0 ~value:initial () in
  let spin = GEdit.spin_button ~adjustment:adj ~digits:0 ~packing () in
  (* Write-back: commit on value change so the StateStore, and any
     subscription on the current panel scope, see the edit. *)
  (match bind_expr with
   | Some expr ->
     ignore (spin#connect#value_changed ~callback:(fun () ->
       _write_back_bind expr (`Float spin#value)))
   | None -> ())

and render_text_input ~packing ~ctx el =
  let open Yojson.Safe.Util in
  let placeholder = el |> member "placeholder" |> to_string_option |> Option.value ~default:"" in
  let bind_expr = el |> member "bind" |> safe_member "value" |> to_string_option in
  let initial = match bind_expr with
    | Some expr ->
      (match Expr_eval.evaluate expr ctx with
       | Expr_eval.Str s -> s
       | _ -> "")
    | None -> "" in
  let entry = GEdit.entry ~packing ~text:initial () in
  if placeholder <> "" then entry#set_placeholder_text placeholder;
  (* Write-back on focus-out / Enter (matches number_input's
     commit-on-change semantics rather than commit-per-keystroke). *)
  (match bind_expr with
   | Some expr ->
     ignore (entry#connect#activate ~callback:(fun () ->
       _write_back_bind expr (`String entry#text)));
     ignore (entry#event#connect#focus_out ~callback:(fun _ ->
       _write_back_bind expr (`String entry#text);
       false))
   | None -> ())

and render_select ~packing ~ctx el =
  let open Yojson.Safe.Util in
  let options = match el |> member "options" with `List l -> l | _ -> [] in
  let bind_expr = el |> member "bind" |> safe_member "value" |> to_string_option in
  (* Value strings parallel to the populated display rows — used to
     look up the selected row on change. *)
  let values = List.map (fun opt -> match opt with
    | `Assoc _ ->
      (match opt |> member "value" |> to_string_option with
       | Some v -> v
       | None -> Option.value ~default:"" (opt |> member "label" |> to_string_option))
    | `String s -> s
    | _ -> "") options in
  let (combo, (store, col)) = GEdit.combo_box_text ~packing () in
  List.iter (fun opt ->
    let label = match opt with
      | `Assoc _ ->
        let lbl = opt |> member "label" |> to_string_option in
        let v = opt |> member "value" |> to_string_option in
        (match lbl with Some l -> l | None -> Option.value ~default:"" v)
      | `String s -> s
      | _ -> "" in
    let row = store#append () in
    store#set ~row ~column:col label
  ) options;
  (* Select the option whose value matches the current bound state,
     falling back to the first entry. *)
  let current = match bind_expr with
    | Some expr ->
      (match Expr_eval.evaluate expr ctx with
       | Expr_eval.Str s -> s
       | _ -> "")
    | None -> "" in
  let active_idx =
    match List.mapi (fun i v -> (i, v)) values |> List.find_opt (fun (_, v) -> v = current) with
    | Some (i, _) -> i
    | None -> 0 in
  if List.length options > 0 then combo#set_active active_idx;
  (* Write-back on selection change. *)
  (match bind_expr with
   | Some expr ->
     ignore (combo#connect#changed ~callback:(fun () ->
       let idx = combo#active in
       if idx >= 0 && idx < List.length values then
         _write_back_bind expr (`String (List.nth values idx))))
   | None -> ())

and render_toggle ~packing ~ctx el =
  let open Yojson.Safe.Util in
  let label = el |> member "label" |> to_string_option |> Option.value ~default:"" in
  (* Accept either bind.value (the panel-bool convention) or the
     legacy bind.checked. Mirrors the Rust render_toggle dispatch. *)
  let bind_expr =
    match el |> member "bind" |> safe_member "value" |> to_string_option with
    | Some s -> Some s
    | None -> el |> member "bind" |> safe_member "checked" |> to_string_option in
  let checked = match bind_expr with
    | Some expr -> Expr_eval.to_bool (Expr_eval.evaluate expr ctx)
    | None -> false in
  let btn = GButton.check_button ~label ~active:checked ~packing () in
  (match bind_expr with
   | Some expr ->
     ignore (btn#connect#toggled ~callback:(fun () ->
       _write_back_bind expr (`Bool btn#active)))
   | None -> ())

and render_combo_box ~packing ~ctx:_ el =
  let open Yojson.Safe.Util in
  let options = match el |> member "options" with `List l -> l | _ -> [] in
  let (_combo, (store, col)) = GEdit.combo_box_text ~has_entry:true ~packing () in
  List.iter (fun opt ->
    let label = match opt with
      | `Assoc _ ->
        let lbl = opt |> member "label" |> to_string_option in
        let v = opt |> member "value" |> to_string_option in
        (match lbl with Some l -> l | None -> Option.value ~default:"" v)
      | `String s -> s
      | _ -> "" in
    let row = store#append () in
    store#set ~row ~column:col label
  ) options

and render_color_swatch ~packing ~ctx el =
  let open Yojson.Safe.Util in
  let size = el |> member "style" |> safe_member "size" |> to_int_option |> Option.value ~default:16 in
  let color_str = match el |> member "bind" |> safe_member "color" |> to_string_option with
    | Some expr ->
      let v = Expr_eval.evaluate expr ctx in
      (match v with Expr_eval.Color c -> c | Expr_eval.Str s -> s | _ -> "")
    | None -> "" in
  let btn = GButton.button ~packing () in
  btn#misc#set_size_request ~width:size ~height:size ();
  if String.length color_str > 0 then begin
    let css = Printf.sprintf "* { background-color: %s; border: 1px solid #666; min-width: %dpx; min-height: %dpx; padding: 0; }"
      color_str size size in
    let provider = GObj.css_provider () in
    provider#load_from_data css;
    btn#misc#style_context#add_provider provider 800
  end

and render_separator ~packing el =
  let open Yojson.Safe.Util in
  let orientation = el |> member "orientation" |> to_string_option |> Option.value ~default:"horizontal" in
  let sep = GMisc.separator (if orientation = "vertical" then `VERTICAL else `HORIZONTAL) ~packing () in
  ignore sep

and render_spacer ~packing () =
  let spacer = GPack.hbox ~packing () in
  spacer#misc#set_size_request ~height:4 ()

and render_disclosure ~packing ~ctx el =
  let open Yojson.Safe.Util in
  let label = el |> member "label" |> to_string_option |> Option.value ~default:"" in
  let label_text = if String.length label > 0 && (try let _ = String.index label '{' in true with Not_found -> false)
    then Expr_eval.evaluate_text label ctx
    else label in
  let expander = GBin.expander ~label:label_text ~expanded:true ~packing () in
  let vbox = GPack.vbox ~spacing:0 ~packing:expander#add () in
  render_children ~packing:(vbox#pack ~expand:false) ~ctx el

and render_panel ~packing ~ctx el =
  let open Yojson.Safe.Util in
  match el |> member "content" with
  | `Null -> render_placeholder ~packing el
  | content -> render_element ~packing ~ctx content

(** Handle eye button click with Alt-modifier detection for solo/unsolo. *)
and handle_eye_click path evt =
  let state = GdkEvent.Button.state evt in
  let modifiers = Gdk.Convert.modifier state in
  let alt = List.mem `MOD1 modifiers in
  match !_get_model_ref () with
  | None -> ()
  | Some m ->
    let d = m#document in
    if alt then begin
      (* Solo/unsolo among siblings *)
      let rec drop_last = function
        | [] | [_] -> []
        | x :: xs -> x :: drop_last xs
      in
      let parent_prefix = drop_last path in
      let sibling_paths =
        if parent_prefix = [] then
          let n = Array.length d.Document.layers in
          List.init n (fun i -> [i])
        else
          let parent = Document.get_element d parent_prefix in
          match parent with
          | Element.Group _ | Element.Layer _ ->
            let kids = Document.children_of parent in
            List.init (Array.length kids) (fun i -> parent_prefix @ [i])
          | _ -> []
      in
      let already_soloed = match !_layers_solo_state with
        | Some (sp, _) -> sp = path
        | None -> false
      in
      if already_soloed then begin
        let saved = match !_layers_solo_state with
          | Some (_, s) -> s
          | None -> []
        in
        m#snapshot;
        let new_doc = List.fold_left (fun acc (sp, vis) ->
          let e = Document.get_element acc sp in
          Document.replace_element acc sp (Element.set_visibility vis e)
        ) d saved in
        m#set_document new_doc;
        _layers_solo_state := None
      end else begin
        let saved = List.filter_map (fun sp ->
          if sp = path then None
          else
            let e = Document.get_element d sp in
            Some (sp, Element.get_visibility e)
        ) sibling_paths in
        m#snapshot;
        let new_doc = List.fold_left (fun acc sp ->
          if sp = path then
            let e = Document.get_element acc sp in
            if Element.get_visibility e = Element.Invisible then
              Document.replace_element acc sp (Element.set_visibility Element.Preview e)
            else acc
          else
            let e = Document.get_element acc sp in
            Document.replace_element acc sp (Element.set_visibility Element.Invisible e)
        ) d sibling_paths in
        m#set_document new_doc;
        _layers_solo_state := Some (path, saved)
      end
    end else begin
      _layers_solo_state := None;
      let e = Document.get_element d path in
      let new_vis = match Element.get_visibility e with
        | Element.Preview -> Element.Outline
        | Element.Outline -> Element.Invisible
        | Element.Invisible -> Element.Preview
      in
      m#snapshot;
      m#set_document (Document.replace_element d path (Element.set_visibility new_vis e))
    end

(** Delete currently panel-selected elements via YAML dispatch (Phase 3).
    The workspace/actions.yaml definition of delete_layer_selection is
    authoritative; this function just supplies the current selection. *)
and do_delete_panel_selection () =
  match !_get_model_ref () with
  | None -> ()
  | Some m ->
    let paths = PathSet2.elements !_layers_panel_selection in
    if paths = [] then ()
    else begin
      (* Guard against deleting the last layer at dispatch-boundary level —
         the YAML doesn't encode this policy yet. *)
      let d = m#document in
      let layer_count = Array.length d.Document.layers in
      let top_deletes = List.length (List.filter (fun p -> List.length p = 1) paths) in
      if top_deletes >= layer_count then ()
      else
        Panel_menu.dispatch_yaml_action
          ~panel_selection:paths
          ~on_selection_changed:(Some (fun _ ->
            _layers_panel_selection := PathSet2.empty))
          "delete_layer_selection" m
    end

(** Duplicate each panel-selected element in place via YAML dispatch. *)
and do_duplicate_panel_selection () =
  match !_get_model_ref () with
  | None -> ()
  | Some m ->
    let paths = PathSet2.elements !_layers_panel_selection in
    if paths = [] then ()
    else
      Panel_menu.dispatch_yaml_action
        ~panel_selection:paths
        "duplicate_layer_selection" m

(** Flatten groups in panel selection via YAML dispatch (Phase 3). *)
and do_flatten_artwork () =
  match !_get_model_ref () with
  | None -> ()
  | Some m ->
    let paths = PathSet2.elements !_layers_panel_selection in
    if paths = [] then ()
    else begin
      Panel_menu.dispatch_yaml_action
        ~panel_selection:paths
        ~on_selection_changed:(Some (fun _ ->
          _layers_panel_selection := PathSet2.empty))
        "flatten_artwork" m
    end

(** Move panel-selected elements into a new layer via YAML dispatch. *)
and do_collect_in_new_layer () =
  match !_get_model_ref () with
  | None -> ()
  | Some m ->
    let paths = PathSet2.elements !_layers_panel_selection in
    if paths = [] then ()
    else begin
      Panel_menu.dispatch_yaml_action
        ~panel_selection:paths
        "collect_in_new_layer" m
    end

(** Open a Layer Options dialog to edit the layer at path. *)
and open_layer_options_dialog path =
  match !_get_model_ref () with
  | None -> ()
  | Some m ->
    let d = m#document in
    let e = Document.get_element d path in
    match e with
    | Element.Layer le ->
      let dlg = GWindow.dialog ~title:"Layer Options" ~modal:true () in
      let vbox = dlg#vbox in
      let name_row = GPack.hbox ~spacing:8 ~packing:(vbox#pack ~expand:false) () in
      ignore (GMisc.label ~text:"Name:" ~packing:(name_row#pack ~expand:false) ());
      let name_entry = GEdit.entry ~text:le.name ~packing:(name_row#pack ~expand:true) () in
      let lock_cb = GButton.check_button ~label:"Lock" ~packing:(vbox#pack ~expand:false) () in
      lock_cb#set_active le.locked;
      let show_cb = GButton.check_button ~label:"Show" ~packing:(vbox#pack ~expand:false) () in
      show_cb#set_active (le.visibility <> Element.Invisible);
      let preview_cb = GButton.check_button ~label:"Preview" ~packing:(vbox#pack ~expand:false) () in
      preview_cb#set_active (le.visibility = Element.Preview);
      preview_cb#misc#set_sensitive show_cb#active;
      ignore (show_cb#connect#toggled ~callback:(fun () ->
        preview_cb#misc#set_sensitive show_cb#active));
      dlg#add_button_stock `CANCEL `CANCEL;
      dlg#add_button_stock `OK `OK;
      let result = dlg#run () in
      if result = `OK then begin
        let layer_id =
          String.concat "." (List.map string_of_int path)
        in
        let params = [
          ("layer_id", `String layer_id);
          ("name", `String name_entry#text);
          ("lock", `Bool lock_cb#active);
          ("show", `Bool show_cb#active);
          ("preview", `Bool preview_cb#active);
        ] in
        (* Route through the YAML layer_options_confirm action so the
           dialog commit logic lives in actions.yaml. *)
        Panel_menu.dispatch_yaml_action ~params "layer_options_confirm" m
      end;
      dlg#destroy ()
    | _ -> ()

(** Render the layers-panel type filter dropdown. Other dropdown widgets
    (none currently exist) fall through to placeholder. *)
and render_layers_filter_dropdown ~packing el =
  let open Yojson.Safe.Util in
  let id = el |> member "id" |> to_string_option |> Option.value ~default:"" in
  if id <> "lp_filter_button" then
    render_placeholder ~packing el
  else begin
    let btn = GButton.button ~label:"\xe2\x96\xbe" ~packing () in
    btn#misc#set_size_request ~width:20 ~height:20 ();
    let items = match el |> member "items" with
      | `List arr ->
        List.filter_map (fun item ->
          let l = item |> member "label" |> to_string_option in
          let v = item |> member "value" |> to_string_option in
          match l, v with
          | Some label, Some value -> Some (label, value)
          | _ -> None) arr
      | _ -> []
    in
    ignore (btn#connect#clicked ~callback:(fun () ->
      let menu = GMenu.menu () in
      List.iter (fun (label, value) ->
        let checked = not (StrSet.mem value !_layers_hidden_types) in
        let item = GMenu.check_menu_item ~label ~packing:menu#append () in
        item#set_active checked;
        ignore (item#connect#toggled ~callback:(fun () ->
          if StrSet.mem value !_layers_hidden_types
          then _layers_hidden_types := StrSet.remove value !_layers_hidden_types
          else _layers_hidden_types := StrSet.add value !_layers_hidden_types;
          !_rerender_layers ()))
      ) items;
      menu#misc#show_all ();
      menu#popup ~button:1 ~time:(Int32.of_int 0)))
  end

(** Render a fitted-viewBox SVG of an element as a GTK widget.
    Writes the SVG to a temp file and loads it via GdkPixbuf at the
    requested size, falling back to an empty frame on error. *)
and make_element_thumbnail ~packing (elem : Element.element) (size : int) =
  let (x, y, w, h) = Element.bounds elem in
  if not (Float.is_finite w && Float.is_finite h) || w <= 0.0 || h <= 0.0 then begin
    let frame = GBin.frame ~shadow_type:`ETCHED_IN ~packing () in
    frame#misc#set_size_request ~width:size ~height:size ();
    frame#misc#modify_bg [`NORMAL, `NAME "white"]
  end else begin
    let pad = max (Float.max w h *. 0.02) 0.5 in
    let vb = Printf.sprintf "%f %f %f %f" (x -. pad) (y -. pad) (w +. 2.0 *. pad) (h +. 2.0 *. pad) in
    let inner = Svg.element_svg "" elem in
    let svg_str = Printf.sprintf
      "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"%s\" preserveAspectRatio=\"xMidYMid meet\">%s</svg>"
      vb inner in
    let tmp = Filename.temp_file "jas_thumb" ".svg" in
    try
      let oc = open_out tmp in
      output_string oc svg_str;
      close_out oc;
      let pixbuf = GdkPixbuf.from_file_at_size tmp ~width:size ~height:size in
      (try Sys.remove tmp with _ -> ());
      let img = GMisc.image ~pixbuf ~packing () in
      img#misc#set_size_request ~width:size ~height:size ()
    with _ ->
      (try Sys.remove tmp with _ -> ());
      let frame = GBin.frame ~shadow_type:`ETCHED_IN ~packing () in
      frame#misc#set_size_request ~width:size ~height:size ();
      frame#misc#modify_bg [`NORMAL, `NAME "white"]
  end

and render_tree_view ~packing ~ctx:_ _el =
  let outer_eb = GBin.event_box ~packing () in
  outer_eb#misc#set_can_focus true;
  let vbox = GPack.vbox ~spacing:0 ~packing:outer_eb#add () in
  let get_model = !_get_model_ref in
  ignore (outer_eb#event#connect#key_press ~callback:(fun evt ->
    let key = GdkEvent.Key.keyval evt in
    let modifiers = GdkEvent.Key.state evt in
    let meta = List.mem `META modifiers || List.mem `CONTROL modifiers in
    if key = GdkKeysyms._Delete || key = GdkKeysyms._BackSpace then begin
      do_delete_panel_selection ();
      !_rerender_layers ();
      true
    end else if key = GdkKeysyms._a && meta then begin
      (match get_model () with
       | None -> ()
       | Some m ->
         let d = m#document in
         let all = ref PathSet2.empty in
         let rec collect elements prefix =
           Array.iteri (fun i e ->
             let p = prefix @ [i] in
             all := PathSet2.add p !all;
             match e with
             | Element.Group _ | Element.Layer _ ->
               collect (Document.children_of e) p
             | _ -> ()
           ) elements
         in
         collect d.Document.layers [];
         _layers_panel_selection := !all);
      !_rerender_layers ();
      true
    end else if key = GdkKeysyms._Escape then begin
      if !_layers_renaming <> None then begin
        _layers_renaming := None;
        !_rerender_layers ();
        true
      end else if Layers_panel_state.get_isolation_stack () <> [] then begin
        Layers_panel_state.pop_isolation_level ();
        !_rerender_layers ();
        true
      end else false
    end else false));
  (* Auto-expand ancestors of element-selected paths so selected elements
     are visible in the tree. *)
  (match get_model () with
   | None -> ()
   | Some m ->
     let d = m#document in
     let selected = Document.selected_paths d.Document.selection in
     Document.PathSet.iter (fun p ->
       let n = List.length p in
       for i = 1 to n - 1 do
         let rec take k lst = match k, lst with
           | 0, _ | _, [] -> []
           | k, h :: t -> h :: take (k - 1) t
         in
         let ancestor = take i p in
         _layers_collapsed := PathSet2.remove ancestor !_layers_collapsed
       done
     ) selected);
  (* Render breadcrumb bar if in isolation mode *)
  (if Layers_panel_state.get_isolation_stack () <> [] then begin
    let bar_eb = GBin.event_box ~packing:(vbox#pack ~expand:false) () in
    bar_eb#misc#modify_bg [`NORMAL, `NAME "#2a2a2a"];
    let bar = GPack.hbox ~spacing:4 ~packing:bar_eb#add () in
    let home_eb = GBin.event_box ~packing:(bar#pack ~expand:false) () in
    ignore (GMisc.label ~text:"\xe2\x8c\x82" ~packing:home_eb#add ());
    ignore (home_eb#event#connect#button_press ~callback:(fun _ ->
      Layers_panel_state.clear_isolation_stack ();
      !_rerender_layers ();
      true));
    let stack = Layers_panel_state.get_isolation_stack () in
    List.iteri (fun idx p ->
      ignore (GMisc.label ~text:">" ~packing:(bar#pack ~expand:false) ());
      match get_model () with
      | None -> ()
      | Some m2 ->
        let e = Document.get_element m2#document p in
        let label = match e with
          | Element.Layer le when le.name <> "" -> le.name
          | _ -> "<?>"
        in
        let seg_eb = GBin.event_box ~packing:(bar#pack ~expand:false) () in
        ignore (GMisc.label ~text:label ~packing:seg_eb#add ());
        let target_idx = idx + 1 in
        ignore (seg_eb#event#connect#button_press ~callback:(fun _ ->
          Layers_panel_state.set_isolation_stack (
            let rec take n lst = match n, lst with
              | 0, _ | _, [] -> []
              | n, h :: t -> h :: take (n - 1) t
            in take target_idx (Layers_panel_state.get_isolation_stack ()));
          !_rerender_layers ();
          true))
    ) stack
  end);
  (* Isolation logic is applied inline in the rendering loop. *)
  (* Helper: does element name contain the search query (case-insensitive) *)
  let matches_search name =
    let q = String.lowercase_ascii !_layers_search_query in
    if q = "" then true
    else
      let n = String.lowercase_ascii name in
      let rec find_sub s p si pi =
        if pi >= String.length p then true
        else if si >= String.length s then false
        else if s.[si] = p.[pi] then find_sub s p (si+1) (pi+1)
        else find_sub s p (si - pi + 1) 0
      in find_sub n q 0 0
  in
  let _ = matches_search in  (* reserved for future search integration *)
  let type_label e =
    match e with
    | Element.Line _ -> "Line" | Element.Rect _ -> "Rectangle"
    | Element.Circle _ -> "Circle" | Element.Ellipse _ -> "Ellipse"
    | Element.Polyline _ -> "Polyline" | Element.Polygon _ -> "Polygon"
    | Element.Path _ -> "Path" | Element.Text _ -> "Text"
    | Element.Text_path _ -> "Text Path"
    | Element.Group _ -> "Group" | Element.Layer _ -> "Layer"
  in
  let display_name e =
    match e with
    | Element.Layer le when le.name <> "" -> (le.name, true)
    | _ -> (Printf.sprintf "<%s>" (type_label e), false)
  in
  let is_container e = match e with Element.Group _ | Element.Layer _ -> true | _ -> false in
  let is_layer e = match e with Element.Layer _ -> true | _ -> false in
  let vis_icon v =
    match v with
    | Element.Outline -> "\xe2\x97\x90"
    | Element.Invisible -> "\xe2\x97\x8b"
    | Element.Preview -> "\xe2\x97\x89"
  in
  let layer_colors = [| "#4a90d9"; "#d94a4a"; "#4ad94a"; "#4a4ad9"; "#d9d94a";
                         "#d94ad9"; "#4ad9d9"; "#b0b0b0"; "#2a7a2a" |] in
  match get_model () with
  | None -> ()
  | Some m ->
    let doc = m#document in
    let selected_paths = Document.selected_paths doc.Document.selection in
    let rec add_children children depth path_prefix layer_color =
      let n = Array.length children in
      for ri = n - 1 downto 0 do
        let i = ri in
        let elem = children.(i) in
        let path = path_prefix @ [i] in
        (* Apply isolation filter: skip rows that aren't descendants of the
           deepest isolated container. Note we still recurse so descendants
           that do pass the filter are rendered. *)
        let passes_iso = match Layers_panel_state.get_isolation_stack () with
          | [] -> true
          | root :: _ ->
            List.length path > List.length root &&
            (let rec prefix_matches a b = match a, b with
              | _, [] -> true
              | [], _ -> false
              | ah :: at, bh :: bt -> ah = bh && prefix_matches at bt
            in prefix_matches path root)
        in
        if not passes_iso then begin
          (* Still recurse, maybe a deeper descendant qualifies *)
          (if is_container elem && not (PathSet2.mem path !_layers_collapsed) then
            let ch = Document.children_of elem in
            add_children ch (depth + 1) path layer_color)
        end else
        (* Apply search filter: skip if name doesn't match and no descendant does *)
        let passes_search =
          let q = String.lowercase_ascii !_layers_search_query in
          if q = "" then true
          else
            let (name_here, _) = display_name elem in
            let n = String.lowercase_ascii name_here in
            let rec find_sub s p si pi =
              if pi >= String.length p then true
              else if si >= String.length s then false
              else if s.[si] = p.[pi] then find_sub s p (si+1) (pi+1)
              else find_sub s p (si - pi + 1) 0
            in
            if find_sub n q 0 0 then true
            else
              (* Include ancestor if any descendant matches *)
              let rec has_match ee =
                let (ne, _) = display_name ee in
                let nn = String.lowercase_ascii ne in
                if find_sub nn q 0 0 then true
                else match ee with
                  | Element.Group _ | Element.Layer _ ->
                    let kids = Document.children_of ee in
                    Array.exists has_match kids
                  | _ -> false
              in has_match elem
        in
        (* Apply type filter *)
        let type_v = match elem with
          | Element.Line _ -> "line" | Element.Rect _ -> "rectangle"
          | Element.Circle _ -> "circle" | Element.Ellipse _ -> "ellipse"
          | Element.Polyline _ -> "polyline" | Element.Polygon _ -> "polygon"
          | Element.Path _ -> "path" | Element.Text _ -> "text"
          | Element.Text_path _ -> "text_path"
          | Element.Group _ -> "group" | Element.Layer _ -> "layer"
        in
        let passes_type = not (StrSet.mem type_v !_layers_hidden_types) in
        if not (passes_search && passes_type) then begin
          (* Still recurse in case descendants pass *)
          (if is_container elem && not (PathSet2.mem path !_layers_collapsed) then
            let ch = Document.children_of elem in
            add_children ch (depth + 1) path layer_color)
        end else
        let is_container = is_container elem in
        let is_selected = Document.PathSet.mem path selected_paths in
        let cur_color =
          if is_layer elem && List.length path = 1
          then layer_colors.(i mod Array.length layer_colors)
          else layer_color
        in
        let (name, _is_named) = display_name elem in
        let vis = Element.get_visibility elem in
        let locked = Element.is_locked elem in
        let is_panel_selected = PathSet2.mem path !_layers_panel_selection in
        let is_drop_target =
          match !_layers_drag_source, !_layers_drag_target with
          | Some src, Some tgt when src <> path && tgt = path -> true
          | _ -> false
        in
        let row_eb = GBin.event_box ~packing:(vbox#pack ~expand:false) () in
        (* Auto-scroll: if this is the first element-selected path, queue a
           grab_focus so the parent ScrolledWindow tries to keep it in view. *)
        if is_selected then begin
          let first_sel = Document.PathSet.min_elt_opt selected_paths in
          if first_sel = Some path then
            ignore (GMain.Idle.add (fun () -> row_eb#misc#grab_focus (); false))
        end;
        if is_panel_selected then
          row_eb#misc#modify_bg [`NORMAL, `NAME "#3a4a6a"]
        else if is_drop_target then
          row_eb#misc#modify_bg [`NORMAL, `NAME "#3a7bd5"];
        let row_path = path in
        ignore (row_eb#event#connect#button_press ~callback:(fun evt ->
          let button = GdkEvent.Button.button evt in
          if button = 3 then begin
            (* Right-click: show context menu *)
            if not (PathSet2.mem row_path !_layers_panel_selection) then begin
              _layers_panel_selection := PathSet2.singleton row_path;
              !_rerender_layers ()
            end;
            let menu = GMenu.menu () in
            let add_item ~label ?(sensitive=true) action =
              let item = GMenu.menu_item ~label ~packing:menu#append () in
              item#misc#set_sensitive sensitive;
              ignore (item#connect#activate ~callback:action)
            in
            let elem_at = match get_model () with
              | Some m2 -> Some (Document.get_element m2#document row_path)
              | None -> None
            in
            let is_layer_path = match elem_at with Some (Element.Layer _) -> true | _ -> false in
            let is_cont_path = match elem_at with Some (Element.Group _ | Element.Layer _) -> true | _ -> false in
            add_item ~label:"Options for Layer..." ~sensitive:is_layer_path (fun () ->
              open_layer_options_dialog row_path);
            add_item ~label:"Duplicate" (fun () -> do_duplicate_panel_selection ());
            add_item ~label:"Delete Selection" (fun () -> do_delete_panel_selection ());
            ignore (GMenu.separator_item ~packing:menu#append ());
            if Layers_panel_state.get_isolation_stack () = [] then
              add_item ~label:"Enter Isolation Mode" ~sensitive:is_cont_path (fun () ->
                Layers_panel_state.push_isolation_level row_path;
                !_rerender_layers ())
            else
              add_item ~label:"Exit Isolation Mode" (fun () ->
                Layers_panel_state.pop_isolation_level ();
                !_rerender_layers ());
            ignore (GMenu.separator_item ~packing:menu#append ());
            add_item ~label:"Flatten Artwork" (fun () -> do_flatten_artwork ());
            add_item ~label:"Collect in New Layer" (fun () -> do_collect_in_new_layer ());
            menu#misc#show_all ();
            menu#popup ~button ~time:(GdkEvent.Button.time evt);
            true
          end else begin
            let modifiers = Gdk.Convert.modifier (GdkEvent.Button.state evt) in
            let meta = List.mem `META modifiers || List.mem `CONTROL modifiers in
            let shift = List.mem `SHIFT modifiers in
            if shift && not (PathSet2.is_empty !_layers_panel_selection) then begin
              (* Range from last panel-selected to clicked, in visual order *)
              let anchor = PathSet2.max_elt !_layers_panel_selection in
              let _ = anchor in
              (* For simplicity, just replace with range pairs [anchor; row_path] *)
              _layers_panel_selection := PathSet2.add row_path (PathSet2.singleton anchor);
            end else if meta then begin
              if PathSet2.mem row_path !_layers_panel_selection
              then _layers_panel_selection := PathSet2.remove row_path !_layers_panel_selection
              else _layers_panel_selection := PathSet2.add row_path !_layers_panel_selection
            end else begin
              _layers_panel_selection := PathSet2.singleton row_path
            end;
            _layers_drag_source := Some row_path;
            _layers_drag_target := None;
            !_rerender_layers ();
            true
          end));
        ignore (row_eb#event#connect#enter_notify ~callback:(fun _ ->
          (match !_layers_drag_source with
           | Some src when src <> row_path ->
             _layers_drag_target := Some row_path;
             !_rerender_layers ();
             (* Auto-expand collapsed containers after 500ms hover during drag *)
             let is_cont = match elem with Element.Group _ | Element.Layer _ -> true | _ -> false in
             if is_cont && PathSet2.mem row_path !_layers_collapsed then
               ignore (GMain.Timeout.add ~ms:500 ~callback:(fun () ->
                 (if !_layers_drag_source <> None && !_layers_drag_target = Some row_path then begin
                    _layers_collapsed := PathSet2.remove row_path !_layers_collapsed;
                    !_rerender_layers ()
                  end);
                 false))
           | _ -> ());
          false));
        ignore (row_eb#event#connect#button_release ~callback:(fun _ ->
          (match !_layers_drag_source with
           | Some src when src <> row_path ->
             (match get_model () with
              | None -> ()
              | Some m2 ->
                let d = m2#document in
                (* Drag constraints: no cycle (target inside src), no drop
                   into a locked parent. *)
                let is_cycle =
                  List.length row_path >= List.length src &&
                  (let rec starts_with a b = match a, b with
                    | _, [] -> true | [], _ -> false
                    | ah :: at, bh :: bt -> ah = bh && starts_with at bt
                  in starts_with row_path src)
                in
                let parent_locked =
                  match row_path with
                  | [] | [_] -> false
                  | _ ->
                    let rec drop_last = function
                      | [] | [_] -> []
                      | x :: xs -> x :: drop_last xs
                    in
                    let parent_path = drop_last row_path in
                    let pe = Document.get_element d parent_path in
                    Element.is_locked pe
                in
                if is_cycle || parent_locked then ()
                else begin
                let moved = Document.get_element d src in
                m2#snapshot;
                let d1 = Document.delete_element d src in
                (* Adjust target if src was at same level and before target *)
                let target =
                  let slen = List.length src and tlen = List.length row_path in
                  if slen = tlen then
                    match List.rev src, List.rev row_path with
                    | si :: srest, ti :: trest when srest = trest && si < ti ->
                      List.rev (ti - 1 :: trest)
                    | _ -> row_path
                  else row_path
                in
                (* Insert "before target": insert_after at (target with last-1) if possible *)
                let insert_path =
                  match List.rev target with
                  | ti :: rest when ti > 0 -> List.rev (ti - 1 :: rest)
                  | _ -> target  (* First-child: degrade to insert_after target *)
                in
                m2#set_document (Document.insert_element_after d1 insert_path moved)
                end)
           | _ -> ());
          _layers_drag_source := None;
          _layers_drag_target := None;
          !_rerender_layers ();
          false));
        let hbox = GPack.hbox ~spacing:2 ~packing:row_eb#add () in
        if depth > 0 then begin
          let spacer = GMisc.label ~text:"" ~packing:(hbox#pack ~expand:false) () in
          spacer#misc#set_size_request ~width:(depth * 16) ()
        end;
        (* Eye button *)
        let eye_eb = GBin.event_box ~packing:(hbox#pack ~expand:false) () in
        ignore (GMisc.label ~text:(vis_icon vis) ~packing:eye_eb#add ());
        eye_eb#misc#set_size_request ~width:16 ();
        ignore (eye_eb#event#connect#button_press ~callback:(fun evt ->
          handle_eye_click path evt;
          !_rerender_layers ();
          true));
        (* Lock button *)
        let lock_eb = GBin.event_box ~packing:(hbox#pack ~expand:false) () in
        let lock_text = if locked then "\xf0\x9f\x94\x92" else "\xf0\x9f\x94\x93" in
        ignore (GMisc.label ~text:lock_text ~packing:lock_eb#add ());
        lock_eb#misc#set_size_request ~width:16 ();
        ignore (lock_eb#event#connect#button_press ~callback:(fun _ ->
          (match get_model () with
           | None -> ()
           | Some m2 ->
             let d = m2#document in
             let e = Document.get_element d path in
             let was_unlocked = not (Element.is_locked e) in
             let is_cont_elem = is_container in
             (* Save child lock states when locking a container *)
             if is_cont_elem && was_unlocked then begin
               let children = Document.children_of e in
               let saved = Array.to_list (Array.map Element.is_locked children) in
               _layers_saved_lock_states := PathMap2.add path saved !_layers_saved_lock_states
             end;
             m2#snapshot;
             let new_e = Element.set_locked was_unlocked e in
             let d1 = Document.replace_element d path new_e in
             (* When locking a container, also lock all direct children *)
             let d2 = if is_cont_elem && was_unlocked then begin
               let children = Document.children_of e in
               Array.fold_left (fun acc_doc i ->
                 let child_path = path @ [i] in
                 let child = Document.get_element acc_doc child_path in
                 Document.replace_element acc_doc child_path (Element.set_locked true child)
               ) d1 (Array.init (Array.length children) (fun i -> i))
             end else d1 in
             (* When unlocking a container, restore direct children's saved states *)
             let d3 = if is_cont_elem && not was_unlocked then begin
               match PathMap2.find_opt path !_layers_saved_lock_states with
               | None -> d2
               | Some saved ->
                 _layers_saved_lock_states := PathMap2.remove path !_layers_saved_lock_states;
                 List.fold_left (fun acc_doc (i, sl) ->
                   let child_path = path @ [i] in
                   let child = Document.get_element acc_doc child_path in
                   Document.replace_element acc_doc child_path (Element.set_locked sl child)
                 ) d2 (List.mapi (fun i s -> (i, s)) saved)
             end else d2 in
             m2#set_document d3);
          true));
        (* Twirl or gap *)
        let is_collapsed = PathSet2.mem path !_layers_collapsed in
        if is_container then begin
          let twirl_text = if is_collapsed then "\xe2\x96\xb6" else "\xe2\x96\xbc" in
          let twirl_eb = GBin.event_box ~packing:(hbox#pack ~expand:false) () in
          ignore (GMisc.label ~text:twirl_text ~packing:twirl_eb#add ());
          twirl_eb#misc#set_size_request ~width:16 ();
          let tp = path in
          ignore (twirl_eb#event#connect#button_press ~callback:(fun _ ->
            if PathSet2.mem tp !_layers_collapsed
            then _layers_collapsed := PathSet2.remove tp !_layers_collapsed
            else _layers_collapsed := PathSet2.add tp !_layers_collapsed;
            !_rerender_layers ();
            true))
        end else begin
          let gap = GMisc.label ~text:"" ~packing:(hbox#pack ~expand:false) () in
          gap#misc#set_size_request ~width:16 ()
        end;
        (* Preview thumbnail — fitted SVG of the element *)
        make_element_thumbnail ~packing:(hbox#pack ~expand:false) elem 24;
        (* Name — inline GEntry when renaming, GMisc.label otherwise *)
        (match !_layers_renaming with
         | Some rp when rp = path ->
           let initial = match elem with
             | Element.Layer le -> le.name
             | _ -> ""
           in
           let entry = GEdit.entry ~text:initial ~packing:(hbox#pack ~expand:true) () in
           let ep = path in
           ignore (entry#connect#activate ~callback:(fun () ->
             (match get_model () with
              | None -> ()
              | Some m2 ->
                let d = m2#document in
                let e = Document.get_element d ep in
                (match e with
                 | Element.Layer le ->
                   let new_layer = Element.Layer { le with name = entry#text } in
                   m2#snapshot;
                   m2#set_document (Document.replace_element d ep new_layer)
                 | _ -> ()));
             _layers_renaming := None;
             !_rerender_layers ()));
           ignore (entry#event#connect#key_press ~callback:(fun key ->
             if GdkEvent.Key.keyval key = GdkKeysyms._Escape then begin
               _layers_renaming := None;
               !_rerender_layers ();
               true
             end else false))
         | _ ->
           let name_eb = GBin.event_box ~packing:(hbox#pack ~expand:true) () in
           ignore (GMisc.label ~text:name ~packing:name_eb#add ());
           let np = path in
           let is_layer_elem = is_layer elem in
           ignore (name_eb#event#connect#button_press ~callback:(fun ev ->
             if is_layer_elem && GdkEvent.get_type ev = `TWO_BUTTON_PRESS then begin
               _layers_renaming := Some np;
               !_rerender_layers ();
               true
             end else false)));
        (* Select square *)
        let sq_eb = GBin.event_box ~packing:(hbox#pack ~expand:false) () in
        let sq = GBin.frame ~shadow_type:`ETCHED_IN ~packing:sq_eb#add () in
        sq#misc#set_size_request ~width:12 ~height:12 ();
        if is_selected then
          sq#misc#modify_bg [`NORMAL, `NAME "blue"];
        ignore (sq_eb#event#connect#button_press ~callback:(fun _ ->
          (match get_model () with
           | None -> ()
           | Some m2 ->
             let d = m2#document in
             let new_sel = Document.PathMap.singleton path (Document.element_selection_all path) in
             m2#set_document { d with Document.selection = new_sel });
          true));
        (* Recurse into children (skip if collapsed) *)
        if is_container && not is_collapsed then begin
          let ch = Document.children_of elem in
          add_children ch (depth + 1) path cur_color
        end
      done
    in
    let n = Array.length doc.Document.layers in
    for ri = n - 1 downto 0 do
      let i = ri in
      let elem = doc.Document.layers.(i) in
      let path = [i] in
      let is_container = is_container elem in
      let is_selected = Document.PathSet.mem path selected_paths in
      let layer_color = layer_colors.(i mod Array.length layer_colors) in
      let (name, _is_named) = display_name elem in
      let vis = Element.get_visibility elem in
      let locked = Element.is_locked elem in
      let is_panel_selected = PathSet2.mem path !_layers_panel_selection in
      let is_drop_target =
        match !_layers_drag_source, !_layers_drag_target with
        | Some src, Some tgt when src <> path && tgt = path -> true
        | _ -> false
      in
      let row_eb = GBin.event_box ~packing:(vbox#pack ~expand:false) () in
      if is_panel_selected then
        row_eb#misc#modify_bg [`NORMAL, `NAME "#3a4a6a"]
      else if is_drop_target then
        row_eb#misc#modify_bg [`NORMAL, `NAME "#3a7bd5"];
      let row_path = path in
      ignore (row_eb#event#connect#button_press ~callback:(fun _ ->
        _layers_panel_selection := PathSet2.singleton row_path;
        _layers_drag_source := Some row_path;
        _layers_drag_target := None;
        !_rerender_layers ();
        true));
      ignore (row_eb#event#connect#enter_notify ~callback:(fun _ ->
        (match !_layers_drag_source with
         | Some src when src <> row_path ->
           _layers_drag_target := Some row_path;
           !_rerender_layers ();
           let is_cont = match elem with Element.Group _ | Element.Layer _ -> true | _ -> false in
           if is_cont && PathSet2.mem row_path !_layers_collapsed then
             ignore (GMain.Timeout.add ~ms:500 ~callback:(fun () ->
               (if !_layers_drag_source <> None && !_layers_drag_target = Some row_path then begin
                  _layers_collapsed := PathSet2.remove row_path !_layers_collapsed;
                  !_rerender_layers ()
                end);
               false))
         | _ -> ());
        false));
      ignore (row_eb#event#connect#button_release ~callback:(fun _ ->
        (match !_layers_drag_source with
         | Some src when src <> row_path ->
           (match get_model () with
            | None -> ()
            | Some m2 ->
              let d = m2#document in
              let is_cycle =
                List.length row_path >= List.length src &&
                (let rec starts_with a b = match a, b with
                  | _, [] -> true | [], _ -> false
                  | ah :: at, bh :: bt -> ah = bh && starts_with at bt
                in starts_with row_path src)
              in
              let parent_locked =
                match row_path with
                | [] | [_] -> false
                | _ ->
                  let rec drop_last = function
                    | [] | [_] -> []
                    | x :: xs -> x :: drop_last xs
                  in
                  let parent_path = drop_last row_path in
                  let pe = Document.get_element d parent_path in
                  Element.is_locked pe
              in
              if is_cycle || parent_locked then ()
              else begin
              let moved = Document.get_element d src in
              m2#snapshot;
              let d1 = Document.delete_element d src in
              let target =
                let slen = List.length src and tlen = List.length row_path in
                if slen = tlen then
                  match List.rev src, List.rev row_path with
                  | si :: srest, ti :: trest when srest = trest && si < ti ->
                    List.rev (ti - 1 :: trest)
                  | _ -> row_path
                else row_path
              in
              let insert_path =
                match List.rev target with
                | ti :: rest when ti > 0 -> List.rev (ti - 1 :: rest)
                | _ -> target
              in
              m2#set_document (Document.insert_element_after d1 insert_path moved)
              end)
         | _ -> ());
        _layers_drag_source := None;
        _layers_drag_target := None;
        !_rerender_layers ();
        false));
      let hbox = GPack.hbox ~spacing:2 ~packing:row_eb#add () in
      (* Eye *)
      let eye_eb = GBin.event_box ~packing:(hbox#pack ~expand:false) () in
      ignore (GMisc.label ~text:(vis_icon vis) ~packing:eye_eb#add ());
      eye_eb#misc#set_size_request ~width:16 ();
      ignore (eye_eb#event#connect#button_press ~callback:(fun evt ->
        handle_eye_click path evt;
        !_rerender_layers ();
        true));
      (* Lock *)
      let lock_eb = GBin.event_box ~packing:(hbox#pack ~expand:false) () in
      let lock_text = if locked then "\xf0\x9f\x94\x92" else "\xf0\x9f\x94\x93" in
      ignore (GMisc.label ~text:lock_text ~packing:lock_eb#add ());
      lock_eb#misc#set_size_request ~width:16 ();
      ignore (lock_eb#event#connect#button_press ~callback:(fun _ ->
        (match get_model () with
         | None -> ()
         | Some m2 ->
           let d = m2#document in
           let e = Document.get_element d path in
           let was_unlocked = not (Element.is_locked e) in
           let is_cont_elem = is_container in
           if is_cont_elem && was_unlocked then begin
             let children = Document.children_of e in
             let saved = Array.to_list (Array.map Element.is_locked children) in
             _layers_saved_lock_states := PathMap2.add path saved !_layers_saved_lock_states
           end;
           m2#snapshot;
           let new_e = Element.set_locked was_unlocked e in
           let d1 = Document.replace_element d path new_e in
           let d2 = if is_cont_elem && was_unlocked then begin
             let children = Document.children_of e in
             Array.fold_left (fun acc_doc i ->
               let child_path = path @ [i] in
               let child = Document.get_element acc_doc child_path in
               Document.replace_element acc_doc child_path (Element.set_locked true child)
             ) d1 (Array.init (Array.length children) (fun i -> i))
           end else d1 in
           let d3 = if is_cont_elem && not was_unlocked then begin
             match PathMap2.find_opt path !_layers_saved_lock_states with
             | None -> d2
             | Some saved ->
               _layers_saved_lock_states := PathMap2.remove path !_layers_saved_lock_states;
               List.fold_left (fun acc_doc (i, sl) ->
                 let child_path = path @ [i] in
                 let child = Document.get_element acc_doc child_path in
                 Document.replace_element acc_doc child_path (Element.set_locked sl child)
               ) d2 (List.mapi (fun i s -> (i, s)) saved)
           end else d2 in
           m2#set_document d3);
        true));
      (* Twirl or gap *)
      let is_collapsed = PathSet2.mem path !_layers_collapsed in
      if is_container then begin
        let twirl_text = if is_collapsed then "\xe2\x96\xb6" else "\xe2\x96\xbc" in
        let twirl_eb = GBin.event_box ~packing:(hbox#pack ~expand:false) () in
        ignore (GMisc.label ~text:twirl_text ~packing:twirl_eb#add ());
        twirl_eb#misc#set_size_request ~width:16 ();
        let tp = path in
        ignore (twirl_eb#event#connect#button_press ~callback:(fun _ ->
          if PathSet2.mem tp !_layers_collapsed
          then _layers_collapsed := PathSet2.remove tp !_layers_collapsed
          else _layers_collapsed := PathSet2.add tp !_layers_collapsed;
          !_rerender_layers ();
          true))
      end else begin
        let gap = GMisc.label ~text:"" ~packing:(hbox#pack ~expand:false) () in
        gap#misc#set_size_request ~width:16 ()
      end;
      (* Preview thumbnail — fitted SVG of the element *)
      make_element_thumbnail ~packing:(hbox#pack ~expand:false) elem 24;
      (* Name — inline GEntry when renaming, GMisc.label otherwise *)
      (match !_layers_renaming with
       | Some rp when rp = path ->
         let initial = match elem with
           | Element.Layer le -> le.name
           | _ -> ""
         in
         let entry = GEdit.entry ~text:initial ~packing:(hbox#pack ~expand:true) () in
         let ep = path in
         ignore (entry#connect#activate ~callback:(fun () ->
           (match get_model () with
            | None -> ()
            | Some m2 ->
              let d = m2#document in
              let e = Document.get_element d ep in
              (match e with
               | Element.Layer le ->
                 let new_layer = Element.Layer { le with name = entry#text } in
                 m2#snapshot;
                 m2#set_document (Document.replace_element d ep new_layer)
               | _ -> ()));
           _layers_renaming := None;
           !_rerender_layers ()));
         ignore (entry#event#connect#key_press ~callback:(fun key ->
           if GdkEvent.Key.keyval key = GdkKeysyms._Escape then begin
             _layers_renaming := None;
             !_rerender_layers ();
             true
           end else false))
       | _ ->
         let name_eb = GBin.event_box ~packing:(hbox#pack ~expand:true) () in
         ignore (GMisc.label ~text:name ~packing:name_eb#add ());
         let np = path in
         let is_layer_elem = is_layer elem in
         ignore (name_eb#event#connect#button_press ~callback:(fun ev ->
           if is_layer_elem && GdkEvent.get_type ev = `TWO_BUTTON_PRESS then begin
             _layers_renaming := Some np;
             !_rerender_layers ();
             true
           end else false)));
      (* Select square *)
      let sq_eb = GBin.event_box ~packing:(hbox#pack ~expand:false) () in
      let sq = GBin.frame ~shadow_type:`ETCHED_IN ~packing:sq_eb#add () in
      sq#misc#set_size_request ~width:12 ~height:12 ();
      if is_selected then
        sq#misc#modify_bg [`NORMAL, `NAME "blue"];
      ignore (sq_eb#event#connect#button_press ~callback:(fun _ ->
        (match get_model () with
         | None -> ()
         | Some m2 ->
           let d = m2#document in
           let new_sel = Document.PathMap.singleton path (Document.element_selection_all path) in
           m2#set_document { d with Document.selection = new_sel });
        true));
      (* Recurse (skip if collapsed) *)
      if is_container && not is_collapsed then begin
        let ch = Document.children_of elem in
        add_children ch 1 path layer_color
      end
    done

and render_element_preview ~packing _el =
  let frame = GBin.frame ~shadow_type:`ETCHED_IN ~packing () in
  frame#misc#set_size_request ~width:32 ~height:32 ()

and render_placeholder ~packing el =
  let open Yojson.Safe.Util in
  let summary = match el |> member "summary" |> to_string_option with
    | Some s -> s
    | None -> el |> member "type" |> to_string_option |> Option.value ~default:"?" in
  let lbl = GMisc.label ~text:(Printf.sprintf "[%s]" summary) ~packing () in
  lbl#misc#set_size_request ~height:30 ()

and render_children ~packing ~ctx el =
  let open Yojson.Safe.Util in
  match el |> member "children" with
  | `List children ->
    List.iter (fun child -> render_element ~packing ~ctx child) children
  | _ -> ()

and render_repeat ~packing ~ctx el =
  let open Yojson.Safe.Util in
  let repeat_obj = el |> member "foreach" in
  let template = el |> member "do" in
  let source_expr = repeat_obj |> member "source" |> to_string_option |> Option.value ~default:"" in
  let var_name = repeat_obj |> member "as" |> to_string_option |> Option.value ~default:"item" in
  (* Resolve the source expression to raw JSON (preserving lists/objects) *)
  let items_json = Expr_eval.evaluate_to_json source_expr ctx in
  (* Determine layout direction from the element *)
  let layout_dir = el |> member "layout" |> to_string_option |> Option.value ~default:"column" in
  let gap = el |> member "style" |> safe_member "gap" |> to_int_option |> Option.value ~default:0 in
  let is_row = layout_dir = "row" || layout_dir = "wrap" in
  let container = if is_row
    then (GPack.hbox ~spacing:gap ~packing () :> GPack.box)
    else (GPack.vbox ~spacing:gap ~packing () :> GPack.box) in
  if layout_dir = "wrap" then
    container#misc#set_size_request ~width:0 ();
  (* Build scope from context and iterate with child scopes *)
  let scope = Scope.from_json ctx in
  (match items_json with
   | `List items ->
     List.iteri (fun i item ->
       (* Build item data with _index *)
       let item_obj = match item with
         | `Assoc pairs -> `Assoc (("_index", `Int i) :: pairs)
         | other -> `Assoc [("_index", `Int i); ("value", other)]
       in
       (* Push a child scope with the loop variable — parent unchanged *)
       let child_scope = Scope.extend scope [(var_name, item_obj)] in
       let child_ctx = Scope.to_json child_scope in
       render_element ~packing:(container#pack ~expand:false) ~ctx:child_ctx template
     ) items
   | _ -> ())

(** Helper to convert number from JSON safely. *)
and to_number_option (j : Yojson.Safe.t) : float option =
  match j with
  | `Int n -> Some (float_of_int n)
  | `Float f -> Some f
  | _ -> None

(** Create a YAML-interpreted panel body in a GTK container.
    Returns unit. The panel content is rendered from the compiled
    workspace JSON. *)
let create_panel_body ~packing ~(kind : panel_kind) ?(get_model = fun () -> None) () =
  let content_id = Workspace_loader.panel_kind_to_content_id kind in
  match Workspace_loader.load () with
  | None -> ()
  | Some ws ->
    match Workspace_loader.panel_content ws content_id with
    | None -> ()
    | Some content ->
      let state_defaults = Workspace_loader.state_defaults ws in
      let state_obj = `Assoc state_defaults in
      let panel_defaults = Workspace_loader.panel_state_defaults ws content_id in
      let icons_obj = Workspace_loader.icons ws in
      let swatch_libs = Workspace_loader.swatch_libraries ws in
      let data_obj = `Assoc [("swatch_libraries", swatch_libs)] in
      let ctx = `Assoc [
        ("state", state_obj);
        ("panel", `Assoc panel_defaults);
        ("icons", icons_obj);
        ("data", data_obj);
        ("_get_model", `Null)  (* Placeholder; actual model passed via closure *)
      ] in
      (* Panel-local state store: seeded with the yaml-declared
         defaults, lives for the life of the panel body. Widget
         callbacks write into it via [_write_back_bind]; a
         subscription wired below pushes Character-panel writes
         through to the selected text element. *)
      let store = State_store.create () in
      State_store.init_panel store content_id panel_defaults;
      _current_store := Some store;
      _current_panel_id := Some content_id;
      (* Store get_model in a ref accessible from render_tree_view *)
      _get_model_ref := get_model;
      (* Wire the Character-panel apply pipeline. [get_model] is
         already a thunk returning the live model; we adapt it to
         yield a Controller when one is available. *)
      let make_ctrl_getter () () =
        match get_model () with
        | Some model -> Controller.create ~model ()
        | None -> failwith "no model available for panel apply"
      in
      (if kind = Character then
         Effects.subscribe_character_panel store (make_ctrl_getter ()));
      (* Stroke panel writes global [stroke_*] keys; subscribe via the
         global channel (filtered by [is_stroke_render_key]) so
         widget changes reach the selected element. *)
      (if kind = Stroke then
         Effects.subscribe_stroke_panel store (make_ctrl_getter ()));
      (* Paragraph panel — Phase 4. Stash the store handle in
         panel_menu so the hamburger-menu commands
         (toggle_hanging_punctuation, reset_paragraph_panel) can
         reach it without creating a yaml_panel_view ↔ panel_menu
         dep cycle. Also sync from the current selection so the
         widgets reflect the selected paragraph attrs rather than
         the YAML defaults. *)
      (if kind = Paragraph then begin
         Panel_menu.paragraph_store_ref := Some store;
         (match get_model () with
          | Some m ->
            let ctrl = new Controller.controller ~model:m () in
            Effects.sync_paragraph_panel_from_selection store ctrl
          | None -> ())
       end);
      render_element ~packing ~ctx content
