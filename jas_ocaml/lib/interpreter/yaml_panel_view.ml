(** YAML-interpreted panel body renderer for GTK.

    Walks a JSON element tree from the compiled workspace and creates
    corresponding GTK widgets. Uses the expression evaluator for
    bind values and the workspace loader for panel specs. *)

open Workspace_layout

(** Module-level ref to the model accessor, set by create_panel_body. *)
let _get_model_ref : (unit -> Model.model option) ref = ref (fun () -> None)

(** Module-level set of collapsed element paths in the layers panel. *)
module PathKey = struct
  type t = int list
  let compare = compare
end
module PathSet2 = Set.Make(PathKey)
let _layers_collapsed : PathSet2.t ref = ref PathSet2.empty

(** Callback to trigger re-render when collapsed state changes. *)
let _rerender_layers : (unit -> unit) ref = ref (fun () -> ())

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
  let initial = match el |> member "bind" |> safe_member "value" |> to_string_option with
    | Some expr ->
      let v = Expr_eval.evaluate expr ctx in
      (match v with Expr_eval.Number n -> n | _ -> min_val)
    | None -> min_val in
  let adj = GData.adjustment ~lower:min_val ~upper:max_val ~step_incr:1.0 ~value:initial () in
  let _spin = GEdit.spin_button ~adjustment:adj ~digits:0 ~packing () in
  ()

and render_text_input ~packing ~ctx:_ el =
  let open Yojson.Safe.Util in
  let _placeholder = el |> member "placeholder" |> to_string_option |> Option.value ~default:"" in
  let _entry = GEdit.entry ~packing () in
  ()

and render_select ~packing ~ctx:_ el =
  let open Yojson.Safe.Util in
  let options = match el |> member "options" with `List l -> l | _ -> [] in
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
  if List.length options > 0 then combo#set_active 0

and render_toggle ~packing ~ctx el =
  let open Yojson.Safe.Util in
  let label = el |> member "label" |> to_string_option |> Option.value ~default:"" in
  let checked = match el |> member "bind" |> safe_member "checked" |> to_string_option with
    | Some expr -> Expr_eval.to_bool (Expr_eval.evaluate expr ctx)
    | None -> false in
  let btn = GButton.check_button ~label ~active:checked ~packing () in
  ignore btn

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

and render_tree_view ~packing ~ctx:_ _el =
  let vbox = GPack.vbox ~spacing:0 ~packing () in
  let get_model = !_get_model_ref in
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
        let hbox = GPack.hbox ~spacing:2 ~packing:(vbox#pack ~expand:false) () in
        if depth > 0 then begin
          let spacer = GMisc.label ~text:"" ~packing:(hbox#pack ~expand:false) () in
          spacer#misc#set_size_request ~width:(depth * 16) ()
        end;
        (* Eye button *)
        let eye_eb = GBin.event_box ~packing:(hbox#pack ~expand:false) () in
        ignore (GMisc.label ~text:(vis_icon vis) ~packing:eye_eb#add ());
        eye_eb#misc#set_size_request ~width:16 ();
        ignore (eye_eb#event#connect#button_press ~callback:(fun _ ->
          (match get_model () with
           | None -> ()
           | Some m2 ->
             let d = m2#document in
             let e = Document.get_element d path in
                let new_vis = match Element.get_visibility e with
                  | Element.Preview -> Element.Outline
                  | Element.Outline -> Element.Invisible
                  | Element.Invisible -> Element.Preview
                in
                let new_e = Element.set_visibility new_vis e in
                m2#snapshot;
                m2#set_document (Document.replace_element d path new_e));
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
                let new_e = Element.set_locked (not (Element.is_locked e)) e in
                m2#snapshot;
                m2#set_document (Document.replace_element d path new_e));
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
        (* Preview *)
        let preview = GBin.frame ~shadow_type:`ETCHED_IN ~packing:(hbox#pack ~expand:false) () in
        preview#misc#set_size_request ~width:24 ~height:24 ();
        (* Name *)
        ignore (GMisc.label ~text:name ~packing:(hbox#pack ~expand:true) ());
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
      let hbox = GPack.hbox ~spacing:2 ~packing:(vbox#pack ~expand:false) () in
      (* Eye *)
      let eye_eb = GBin.event_box ~packing:(hbox#pack ~expand:false) () in
      ignore (GMisc.label ~text:(vis_icon vis) ~packing:eye_eb#add ());
      eye_eb#misc#set_size_request ~width:16 ();
      ignore (eye_eb#event#connect#button_press ~callback:(fun _ ->
        (match get_model () with
         | None -> ()
         | Some m2 ->
           let d = m2#document in
           let e = Document.get_element d path in
              let new_vis = match Element.get_visibility e with
                | Element.Preview -> Element.Outline
                | Element.Outline -> Element.Invisible
                | Element.Invisible -> Element.Preview
              in
              let new_e = Element.set_visibility new_vis e in
              m2#snapshot;
              m2#set_document (Document.replace_element d path new_e));
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
              let new_e = Element.set_locked (not (Element.is_locked e)) e in
              m2#snapshot;
              m2#set_document (Document.replace_element d path new_e));
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
      (* Preview *)
      let preview = GBin.frame ~shadow_type:`ETCHED_IN ~packing:(hbox#pack ~expand:false) () in
      preview#misc#set_size_request ~width:24 ~height:24 ();
      (* Name *)
      ignore (GMisc.label ~text:name ~packing:(hbox#pack ~expand:true) ());
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
      (* Store get_model in a ref accessible from render_tree_view *)
      _get_model_ref := get_model;
      render_element ~packing ~ctx content
