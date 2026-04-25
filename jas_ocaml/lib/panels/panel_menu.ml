(** Panel menu item types and per-panel lookup functions. *)

open Workspace_layout

(** A menu item in a panel's hamburger menu. *)
type panel_menu_item =
  | Action of { label : string; command : string; shortcut : string }
  | Toggle of { label : string; command : string }
  | Radio of { label : string; command : string; group : string }
  | Separator

(** All panel kinds, for iteration. *)
let all_panel_kinds = [| Layers; Color; Swatches; Stroke; Properties; Character; Paragraph; Artboards; Align; Boolean; Opacity; Magic_wand |]

(** Paragraph panel state-store handle. The yaml_panel_view sets
    this ref to the panel's [State_store.t] when rendering the
    Paragraph panel so menu commands like
    [toggle_hanging_punctuation] / [reset_paragraph_panel] can
    reach back into it (panel_menu cannot import yaml_panel_view —
    that would create a module dep cycle). [None] means the
    Paragraph panel isn't currently mounted. Phase 4. *)
let paragraph_store_ref : State_store.t option ref = ref None

(** Opacity panel state-store handle. Same pattern as
    [paragraph_store_ref]: yaml_panel_view sets this when the
    Opacity panel mounts so menu commands like
    [toggle_new_masks_clipping] / [toggle_new_masks_inverted] can
    flip the stored panel-local bools, and [make_opacity_mask] can
    read the current [new_masks_clipping] / [new_masks_inverted]
    values (rather than hardcoding the yaml defaults). [None] means
    the Opacity panel isn't currently mounted. OPACITY.md §Panel
    menu. *)
let opacity_store_ref : State_store.t option ref = ref None

(** Read a bool from the Opacity panel's state store, falling back
    to [default] when the ref isn't set or the key is missing /
    non-bool. Used by [make_opacity_mask] dispatch and
    [panel_is_checked] for the four opacity panel toggles. *)
let _opacity_store_bool (key : string) ~(default : bool) : bool =
  match !opacity_store_ref with
  | None -> default
  | Some store ->
    (match State_store.get_panel store "opacity_panel_content" key with
     | `Bool b -> b
     | _ -> default)

(** Helper: dispatch a Paragraph menu command through the live
    State_store + Controller. No-op when the store ref is unset
    (panel not mounted) or the model thunk yields [None]. *)
let paragraph_menu_dispatch (cmd : [< `Toggle of string | `Reset ])
    (get_model : unit -> Model.model) : unit =
  match !paragraph_store_ref with
  | None -> ()
  | Some store ->
    let m = get_model () in
    let ctrl = new Controller.controller ~model:m () in
    (match cmd with
     | `Toggle field ->
       Effects.sync_paragraph_panel_from_selection store ctrl;
       let cur = match State_store.get_panel store
                         "paragraph_panel_content" field with
         | `Bool b -> b | _ -> false in
       State_store.set_panel store "paragraph_panel_content"
         field (`Bool (not cur));
       Effects.apply_paragraph_panel_to_selection store ctrl
     | `Reset ->
       Effects.reset_paragraph_panel store ctrl)

(** Human-readable label for a panel kind. *)
let panel_label = function
  | Layers -> "Layers"
  | Color -> "Color"
  | Swatches -> "Swatches"
  | Stroke -> "Stroke"
  | Properties -> "Properties"
  | Character -> "Character"
  | Paragraph -> "Paragraph"
  | Artboards -> "Artboards"
  | Align -> "Align"
  | Boolean -> "Boolean"
  | Opacity -> "Opacity"
  | Magic_wand -> "Magic Wand"

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
  | Character -> [
      Toggle { label = "Show Snap to Glyph Options"; command = "toggle_snap_to_glyph_visible" };
      Separator;
      Toggle { label = "All Caps"; command = "toggle_all_caps" };
      Toggle { label = "Small Caps"; command = "toggle_small_caps" };
      Toggle { label = "Superscript"; command = "toggle_superscript" };
      Toggle { label = "Subscript"; command = "toggle_subscript" };
      Separator;
      Action { label = "Close Character"; command = "close_panel"; shortcut = "" } ]
  | Paragraph -> [
      Toggle { label = "Hanging Punctuation"; command = "toggle_hanging_punctuation" };
      Separator;
      Action { label = "Justification…"; command = "open_paragraph_justification"; shortcut = "" };
      Action { label = "Hyphenation…"; command = "open_paragraph_hyphenation"; shortcut = "" };
      Separator;
      Action { label = "Reset Panel"; command = "reset_paragraph_panel"; shortcut = "" };
      Separator;
      Action { label = "Close Paragraph"; command = "close_panel"; shortcut = "" } ]
  | Artboards -> [
      Action { label = "New Artboard"; command = "new_artboard"; shortcut = "" };
      Action { label = "Duplicate Artboards"; command = "duplicate_artboards"; shortcut = "" };
      Action { label = "Delete Artboards"; command = "delete_artboards"; shortcut = "" };
      Action { label = "Rename"; command = "rename_artboard"; shortcut = "" };
      Separator;
      Action { label = "Delete Empty Artboards"; command = "delete_empty_artboards"; shortcut = "" };
      Separator;
      (* Phase-1 deferred per ARTBOARDS.md — YAML action catalog grays these. *)
      Action { label = "Convert to Artboards"; command = "convert_to_artboards"; shortcut = "" };
      Action { label = "Artboard Options\xe2\x80\xa6"; command = "open_artboard_options"; shortcut = "" };
      Action { label = "Rearrange\xe2\x80\xa6"; command = "rearrange_artboards"; shortcut = "" };
      Separator;
      Action { label = "Reset Panel"; command = "reset_artboards_panel"; shortcut = "" };
      Separator;
      Action { label = "Close Artboards"; command = "close_panel"; shortcut = "" } ]
  | Align -> [
      Toggle { label = "Use Preview Bounds"; command = "toggle_use_preview_bounds" };
      Separator;
      Action { label = "Reset Panel"; command = "reset_align_panel"; shortcut = "" };
      Separator;
      Action { label = "Close Align"; command = "close_panel"; shortcut = "" } ]
  | Boolean -> [
      Action { label = "Repeat Boolean Operation"; command = "repeat_boolean_operation"; shortcut = "" };
      Action { label = "Boolean Options\xe2\x80\xa6"; command = "open_boolean_options"; shortcut = "" };
      Separator;
      Action { label = "Make Compound Shape"; command = "make_compound_shape"; shortcut = "" };
      Action { label = "Release Compound Shape"; command = "release_compound_shape"; shortcut = "" };
      Action { label = "Expand Compound Shape"; command = "expand_compound_shape"; shortcut = "" };
      Separator;
      Action { label = "Reset Panel"; command = "reset_boolean_panel"; shortcut = "" };
      Separator;
      Action { label = "Close Boolean"; command = "close_panel"; shortcut = "" } ]
  | Opacity -> [
      (* Mirrors jas_dioxus/src/panels/opacity_panel.rs — ten spec items
         from OPACITY.md plus a trailing Close Opacity. Phase-1 toggles
         for thumbnails/options/new-mask defaults are functional via
         State_store; mask-lifecycle and page-level commands are inert
         (YAML gates them with enabled_when: "false"). *)
      Toggle { label = "Hide Thumbnails"; command = "toggle_opacity_thumbnails" };
      Toggle { label = "Show Options"; command = "toggle_opacity_options" };
      Separator;
      Action { label = "Make Opacity Mask"; command = "make_opacity_mask"; shortcut = "" };
      Action { label = "Release Opacity Mask"; command = "release_opacity_mask"; shortcut = "" };
      Action { label = "Disable Opacity Mask"; command = "disable_opacity_mask"; shortcut = "" };
      Action { label = "Unlink Opacity Mask"; command = "unlink_opacity_mask"; shortcut = "" };
      Separator;
      Toggle { label = "New Opacity Masks Are Clipping"; command = "toggle_new_masks_clipping" };
      Toggle { label = "New Opacity Masks Are Inverted"; command = "toggle_new_masks_inverted" };
      Separator;
      Toggle { label = "Page Isolated Blending"; command = "toggle_page_isolated_blending" };
      Toggle { label = "Page Knockout Group"; command = "toggle_page_knockout_group" };
      Separator;
      Action { label = "Close Opacity"; command = "close_panel"; shortcut = "" } ]
  | Magic_wand -> [
      Action { label = "Reset Magic Wand"; command = "reset_magic_wand_panel"; shortcut = "" };
      Separator;
      Action { label = "Close Magic Wand"; command = "close_panel"; shortcut = "" } ]

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
    Wires snapshot, doc.set, doc.delete_at, doc.clone_at, doc.insert_after
    to operate on the active Model. Injects active_document rollups and
    (optionally) panel.layers_panel_selection from the caller — needed by
    Group B actions (delete_layer_selection, duplicate_layer_selection). *)
let dispatch_yaml_action
    ?(panel_selection : int list list = [])
    ?(on_selection_changed : (int list list -> unit) option = None)
    ?(params : (string * Yojson.Safe.t) list = [])
    ?(on_close_dialog : (unit -> unit) option = None)
    (action_name : string) (m : Model.model) : unit =
  ignore on_selection_changed;  (* reserved for future bidirectional sync *)
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
         let active_doc =
           Active_document_view.build ~panel_selection (Some m)
         in
         (* panel.layers_panel_selection: inject as list of __path__
            markers for Group B actions to iterate via reverse(...). *)
         let selection_json = `List (List.map (fun p ->
           `Assoc [("__path__", `List (List.map (fun i -> `Int i) p))]
         ) panel_selection) in
         let panel_json = `Assoc [
           ("layers_panel_selection", selection_json);
         ] in
         let ctx = [
           ("active_document", active_doc);
           ("panel", panel_json);
           ("param", `Assoc params);
         ] in
         (* Cleared selection (settable by set_panel_state: {key:
            layers_panel_selection, value: []}) — used by
            delete_layer_selection to signal empty selection after
            batch delete. *)
         let cleared_selection = ref false in
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
              List.iter (fun (dotted, expr_v) ->
                let expr_str = match expr_v with `String s -> s | _ -> "" in
                let v = Expr_eval.evaluate expr_str eval_ctx in
                (* Read the current elem from the working array so
                   successive field updates compose instead of each
                   overwriting the element from scratch. *)
                let elem = new_layers.(idx) in
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
                  | "name", Expr_eval.Str s ->
                    (match elem with
                     | Element.Layer le -> Element.Layer { le with name = s }
                     | _ -> elem)
                  | _ -> elem
                in
                new_layers.(idx) <- updated
              ) fields;
              m#set_document { d with Document.layers = new_layers }
            | _ -> ());
           `Null
         in
         (* doc.create_layer: { name }. Factory returning a new Layer
            Element stashed under __element_ref__. *)
         let doc_create_layer_h : Effects.platform_effect = fun value call_ctx _ ->
           let name_expr = match value with
             | `Assoc pairs ->
               (match List.assoc_opt "name" pairs with
                | Some (`String s) -> s | _ -> "'Layer'")
             | _ -> "'Layer'"
           in
           let eval_ctx = `Assoc call_ctx in
           let name = match Expr_eval.evaluate name_expr eval_ctx with
             | Expr_eval.Str s -> s
             | _ -> "Layer"
           in
           let new_layer = Element.make_layer ~name [||] in
           let stash_id = Printf.sprintf "__elem_%d__" !next_stash_id in
           incr next_stash_id;
           Hashtbl.add element_stash stash_id new_layer;
           `Assoc [("__element_ref__", `String stash_id)]
         in
         (* Helper: decode a JSON list of __path__ markers into int list list. *)
         let decode_path_list (v : Yojson.Safe.t) : int list list =
           match v with
           | `List items ->
             List.filter_map (fun item ->
               match item with
               | `Assoc pairs ->
                 (match List.assoc_opt "__path__" pairs with
                  | Some (`List idx_list) ->
                    let idx = List.filter_map (function
                      | `Int n when n >= 0 -> Some n
                      | _ -> None) idx_list in
                    if List.length idx = List.length idx_list then Some idx else None
                  | _ -> None)
               | _ -> None
             ) items
           | _ -> []
         in
         (* doc.wrap_in_group: { paths }. Wraps elements at given paths in
            a new Group at the topmost source position. *)
         let doc_wrap_in_group_h : Effects.platform_effect = fun spec call_ctx _ ->
           let paths_expr = match spec with
             | `Assoc pairs ->
               (match List.assoc_opt "paths" pairs with
                | Some (`String s) -> Some s | _ -> None)
             | _ -> None
           in
           (match paths_expr with
            | None -> ()
            | Some e ->
              let eval_ctx = `Assoc call_ctx in
              let v = Expr_eval.evaluate e eval_ctx in
              let paths = match v with
                | Expr_eval.List items -> decode_path_list (`List items)
                | _ -> []
              in
              if paths <> [] then begin
                let sorted = List.sort compare paths in
                let top_path = List.hd sorted in
                (* Top-level only for now — nested wrap_in_group requires
                   Document.insert_element_at which doesn't exist yet. *)
                if List.length top_path = 1 then begin
                  let insert_idx = List.hd top_path in
                  let d = m#document in
                  let children = List.filter_map (fun p ->
                    try Some (Document.get_element d p) with _ -> None
                  ) sorted in
                  if children <> [] then begin
                    let rev_sorted = List.rev sorted in
                    let new_doc = List.fold_left (fun acc p ->
                      Document.delete_element acc p
                    ) d rev_sorted in
                    let new_group = Element.make_group (Array.of_list children) in
                    let layers = new_doc.Document.layers in
                    let n = Array.length layers in
                    let clamped = max 0 (min insert_idx n) in
                    let new_layers = Array.init (n + 1) (fun i ->
                      if i < clamped then layers.(i)
                      else if i = clamped then new_group
                      else layers.(i - 1)) in
                    m#set_document { new_doc with Document.layers = new_layers }
                  end
                end
              end);
           `Null
         in
         (* doc.wrap_in_layer: { paths, name }. Appends a new top-level
            Layer at the end of document.layers containing the source
            elements. *)
         let doc_wrap_in_layer_h : Effects.platform_effect = fun spec call_ctx _ ->
           let paths_expr, name_expr = match spec with
             | `Assoc pairs ->
               let pe = match List.assoc_opt "paths" pairs with
                 | Some (`String s) -> Some s | _ -> None
               in
               let ne = match List.assoc_opt "name" pairs with
                 | Some (`String s) -> s | _ -> "'Layer'"
               in
               (pe, ne)
             | _ -> (None, "'Layer'")
           in
           (match paths_expr with
            | None -> ()
            | Some e ->
              let eval_ctx = `Assoc call_ctx in
              let v = Expr_eval.evaluate e eval_ctx in
              let paths = match v with
                | Expr_eval.List items -> decode_path_list (`List items)
                | _ -> []
              in
              if paths <> [] then begin
                let sorted = List.sort compare paths in
                let name = match Expr_eval.evaluate name_expr eval_ctx with
                  | Expr_eval.Str s -> s
                  | _ -> "Layer"
                in
                let d = m#document in
                let children = List.filter_map (fun p ->
                  try Some (Document.get_element d p) with _ -> None
                ) sorted in
                if children <> [] then begin
                  let rev_sorted = List.rev sorted in
                  let new_doc = List.fold_left (fun acc p ->
                    Document.delete_element acc p
                  ) d rev_sorted in
                  let new_layer = Element.make_layer ~name (Array.of_list children) in
                  let layers = new_doc.Document.layers in
                  let new_layers = Array.append layers [|new_layer|] in
                  m#set_document { new_doc with Document.layers = new_layers }
                end
              end);
           `Null
         in
         (* doc.unpack_group_at: path. Replaces a Group with its
            children in place. Top-level only for now. *)
         let doc_unpack_group_at_h : Effects.platform_effect = fun value call_ctx _ ->
           let path_expr = match value with `String s -> s | _ -> "" in
           let eval_ctx = `Assoc call_ctx in
           let path_val = Expr_eval.evaluate path_expr eval_ctx in
           (match path_val with
            | Expr_eval.Path [idx] when
                idx >= 0 && idx < Array.length m#document.Document.layers ->
              let d = m#document in
              (match d.Document.layers.(idx) with
               | Element.Group { children; _ } ->
                 let n = Array.length d.Document.layers in
                 let k = Array.length children in
                 let new_layers = Array.init (n - 1 + k) (fun i ->
                   if i < idx then d.Document.layers.(i)
                   else if i < idx + k then children.(i - idx)
                   else d.Document.layers.(i - k + 1))
                 in
                 m#set_document { d with Document.layers = new_layers }
               | _ -> ())
            | _ -> ());
           `Null
         in
         (* doc.insert_at: { parent_path, index, element }. *)
         let doc_insert_at_h : Effects.platform_effect = fun spec call_ctx _ ->
           let parent_expr, idx_expr, element_arg = match spec with
             | `Assoc pairs ->
               let pe = match List.assoc_opt "parent_path" pairs with
                 | Some (`String s) -> s | _ -> "path()"
               in
               let ie = List.assoc_opt "index" pairs in
               let ea = List.assoc_opt "element" pairs in
               (pe, ie, ea)
             | _ -> ("path()", None, None)
           in
           let eval_ctx = `Assoc call_ctx in
           let parent_val = Expr_eval.evaluate parent_expr eval_ctx in
           let idx = match idx_expr with
             | Some (`Int i) -> i
             | Some (`String s) ->
               (match Expr_eval.evaluate s eval_ctx with
                | Expr_eval.Number n -> Float.to_int n
                | _ -> 0)
             | _ -> 0
           in
           let resolve_elem () =
             let ref_json = match element_arg with
               | Some (`Assoc _ as j) -> Some j
               | Some (`String name) -> List.assoc_opt name call_ctx
               | _ -> None
             in
             match ref_json with
             | Some (`Assoc [("__element_ref__", `String id)]) ->
               Hashtbl.find_opt element_stash id
             | _ -> None
           in
           (match parent_val, resolve_elem () with
            | Expr_eval.Path [], Some elem ->
              (* Top-level insert *)
              let d = m#document in
              let n = Array.length d.Document.layers in
              let insert_idx = max 0 (min idx n) in
              let new_layers = Array.init (n + 1) (fun i ->
                if i < insert_idx then d.Document.layers.(i)
                else if i = insert_idx then elem
                else d.Document.layers.(i - 1))
              in
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
         (* set_panel_state: {key: layers_panel_selection, value: "[]"}
            signals that the action cleared the panel selection. We
            record the fact so the caller can empty its own selection
            state after dispatch returns. *)
         let set_panel_state_h : Effects.platform_effect = fun spec _ _ ->
           (match spec with
            | `Assoc pairs ->
              let key = match List.assoc_opt "key" pairs with
                | Some (`String s) -> s | _ -> ""
              in
              if key = "layers_panel_selection" then
                cleared_selection := true
            | _ -> ());
           `Null
         in
         (* list_push: {target: panel.isolation_stack, value: <path-expr>}.
            Phase 3 Group D (enter_isolation_mode) — pushes the evaluated
            path onto yaml_panel_view's isolation stack. Other targets
            are ignored. *)
         let list_push_h : Effects.platform_effect = fun spec call_ctx _ ->
           (match spec with
            | `Assoc pairs ->
              let target = match List.assoc_opt "target" pairs with
                | Some (`String s) -> s | _ -> ""
              in
              if target = "panel.isolation_stack" then begin
                let value_expr = match List.assoc_opt "value" pairs with
                  | Some (`String s) -> s | _ -> "null"
                in
                let eval_ctx = `Assoc call_ctx in
                match Expr_eval.evaluate value_expr eval_ctx with
                | Expr_eval.Path p ->
                  Layers_panel_state.push_isolation_level p
                | _ -> ()
              end
            | _ -> ());
           `Null
         in
         (* pop: "panel.isolation_stack" — Phase 3 Group D
            (exit_isolation_mode). *)
         let pop_h : Effects.platform_effect = fun value _ _ ->
           (match value with
            | `String "panel.isolation_stack" ->
              Layers_panel_state.pop_isolation_level ()
            | _ -> ());
           `Null
         in
         (* close_dialog: invoke the ~on_close_dialog callback if the
            caller supplied one (used by Layer Options sheet dismiss).
            Matches both bare `- close_dialog` and `- close_dialog: null`. *)
         let close_dialog_h : Effects.platform_effect = fun _ _ _ ->
           (match on_close_dialog with
            | Some cb -> cb ()
            | None -> ());
           `Null
         in
         (* Boolean panel destructive ops. See BOOLEAN.md Panel actions.
            DIVIDE / TRIM / MERGE ship in phase 9e. *)
         let boolean_options_from_store store =
           let def = Boolean_apply.default_boolean_options in
           let get k = State_store.get store k in
           let precision = match get "boolean_precision" with
             | `Float f -> f
             | `Int i -> float_of_int i
             | _ -> def.precision
           in
           let rrp = match get "boolean_remove_redundant_points" with
             | `Bool b -> b | _ -> def.remove_redundant_points
           in
           let drup = match get "boolean_divide_remove_unpainted" with
             | `Bool b -> b | _ -> def.divide_remove_unpainted
           in
           { Boolean_apply.precision; remove_redundant_points = rrp;
             divide_remove_unpainted = drup }
         in
         let make_boolean_op_h op_name : Effects.platform_effect =
           fun _ _ store ->
             let options = boolean_options_from_store store in
             Boolean_apply.apply_destructive_boolean ~options m op_name;
             `Null
         in
         let make_compound_creation_h op_name : Effects.platform_effect =
           fun _ _ _ ->
             Boolean_apply.apply_compound_creation m op_name;
             `Null
         in
         let repeat_boolean_op_h : Effects.platform_effect = fun _ _ store ->
           let last = match State_store.get store "last_boolean_op" with
             | `String s -> Some s | _ -> None
           in
           let options = boolean_options_from_store store in
           Boolean_apply.apply_repeat_boolean_operation ~options m last;
           `Null
         in
         let reset_boolean_panel_h : Effects.platform_effect = fun _ _ _ ->
           (* No extra tear-down; the yaml `set: last_boolean_op: null`
              in the same action clears the repeat state. *)
           `Null
         in
         let make_cs_h : Effects.platform_effect = fun _ _ _ ->
           Boolean_apply.apply_make_compound_shape m;
           `Null
         in
         let release_cs_h : Effects.platform_effect = fun _ _ _ ->
           Boolean_apply.apply_release_compound_shape m;
           `Null
         in
         let expand_cs_h : Effects.platform_effect = fun _ _ _ ->
           Boolean_apply.apply_expand_compound_shape m;
           `Null
         in
         (* ── Artboard handlers (ARTBOARDS.md) ────────────────────
            Mirror jas_dioxus / JasSwift artboard doc.* effects:
            create, delete-by-id, duplicate, set-field, set-options-
            field, move-up, move-down. Each clones the artboards
            list, mutates, and calls m#set_document. *)
         let with_artboards new_artboards =
           let d = m#document in
           m#set_document { d with Document.artboards = new_artboards }
         in
         let apply_artboard_override (ab : Artboard.artboard) field v =
           match field, v with
           | "name", Expr_eval.Str s -> { ab with Artboard.name = s }
           | "x", Expr_eval.Number n -> { ab with Artboard.x = n }
           | "y", Expr_eval.Number n -> { ab with Artboard.y = n }
           | "width", Expr_eval.Number n -> { ab with Artboard.width = n }
           | "height", Expr_eval.Number n -> { ab with Artboard.height = n }
           | "fill", Expr_eval.Str s ->
             { ab with Artboard.fill = Artboard.fill_from_canonical s }
           | "show_center_mark", Expr_eval.Bool b ->
             { ab with Artboard.show_center_mark = b }
           | "show_cross_hairs", Expr_eval.Bool b ->
             { ab with Artboard.show_cross_hairs = b }
           | "show_video_safe_areas", Expr_eval.Bool b ->
             { ab with Artboard.show_video_safe_areas = b }
           | "video_ruler_pixel_aspect_ratio", Expr_eval.Number n ->
             { ab with Artboard.video_ruler_pixel_aspect_ratio = n }
           | _ -> ab
         in
         let doc_create_artboard_h : Effects.platform_effect = fun value call_ctx _ ->
           let eval_ctx = `Assoc call_ctx in
           let d = m#document in
           (* Mint unique id. *)
           let existing = List.map (fun (a : Artboard.artboard) -> a.id) d.Document.artboards in
           let rec mint n =
             if n > 100 then None
             else
               let c = Artboard.generate_id () in
               if List.mem c existing then mint (n + 1) else Some c
           in
           (match mint 0 with
            | None -> ()
            | Some id ->
              let ab0 = Artboard.default_with_id id in
              let ab0 = { ab0 with Artboard.name = Artboard.next_name d.Document.artboards } in
              let ab = match value with
                | `Assoc pairs ->
                  List.fold_left (fun ab (k, ev) ->
                    let vv = match ev with
                      | `String s -> Expr_eval.evaluate s eval_ctx
                      | `Int n -> Expr_eval.Number (float_of_int n)
                      | `Float n -> Expr_eval.Number n
                      | `Bool b -> Expr_eval.Bool b
                      | _ -> Expr_eval.Null
                    in
                    apply_artboard_override ab k vv
                  ) ab0 pairs
                | _ -> ab0
              in
              with_artboards (d.Document.artboards @ [ab]));
           `Null
         in
         let doc_delete_artboard_by_id_h : Effects.platform_effect = fun value call_ctx _ ->
           let eval_ctx = `Assoc call_ctx in
           let id_expr = match value with `String s -> s | _ -> "" in
           (match Expr_eval.evaluate id_expr eval_ctx with
            | Expr_eval.Str target ->
              let d = m#document in
              let filtered = List.filter
                (fun (a : Artboard.artboard) -> a.id <> target)
                d.Document.artboards
              in
              if List.length filtered <> List.length d.Document.artboards then
                with_artboards filtered
            | _ -> ());
           `Null
         in
         let doc_duplicate_artboard_h : Effects.platform_effect = fun value call_ctx _ ->
           let eval_ctx = `Assoc call_ctx in
           let id_expr, ox_expr, oy_expr = match value with
             | `String s -> s, None, None
             | `Assoc pairs ->
               let getp k = match List.assoc_opt k pairs with
                 | Some (`String s) -> Some s | _ -> None
               in
               (match getp "id" with Some s -> s | None -> ""),
               getp "offset_x", getp "offset_y"
             | _ -> "", None, None
           in
           let eval_num s_opt default =
             match s_opt with
             | Some s ->
               (match Expr_eval.evaluate s eval_ctx with
                | Expr_eval.Number n -> n | _ -> default)
             | None -> default
           in
           let ox = eval_num ox_expr 20.0 in
           let oy = eval_num oy_expr 20.0 in
           (match Expr_eval.evaluate id_expr eval_ctx with
            | Expr_eval.Str target ->
              let d = m#document in
              (match List.find_opt
                       (fun (a : Artboard.artboard) -> a.id = target)
                       d.Document.artboards with
               | None -> ()
               | Some source ->
                 let existing = List.map
                   (fun (a : Artboard.artboard) -> a.id)
                   d.Document.artboards in
                 let rec mint n =
                   if n > 100 then None
                   else
                     let c = Artboard.generate_id () in
                     if List.mem c existing then mint (n + 1) else Some c
                 in
                 (match mint 0 with
                  | None -> ()
                  | Some new_id ->
                    let dup = {
                      source with
                      Artboard.id = new_id;
                      name = Artboard.next_name d.Document.artboards;
                      x = source.x +. ox;
                      y = source.y +. oy;
                    } in
                    with_artboards (d.Document.artboards @ [dup])))
            | _ -> ());
           `Null
         in
         let doc_set_artboard_field_h : Effects.platform_effect = fun value call_ctx _ ->
           let eval_ctx = `Assoc call_ctx in
           (match value with
            | `Assoc pairs ->
              let id_expr = match List.assoc_opt "id" pairs with
                | Some (`String s) -> s | _ -> "" in
              let field = match List.assoc_opt "field" pairs with
                | Some (`String s) -> s | _ -> "" in
              let v_eval = match List.assoc_opt "value" pairs with
                | Some (`String s) -> Expr_eval.evaluate s eval_ctx
                | Some (`Int n) -> Expr_eval.Number (float_of_int n)
                | Some (`Float n) -> Expr_eval.Number n
                | Some (`Bool b) -> Expr_eval.Bool b
                | _ -> Expr_eval.Null
              in
              (match Expr_eval.evaluate id_expr eval_ctx with
               | Expr_eval.Str target ->
                 let d = m#document in
                 let new_abs = List.map
                   (fun (a : Artboard.artboard) ->
                     if a.id = target then apply_artboard_override a field v_eval
                     else a)
                   d.Document.artboards in
                 with_artboards new_abs
               | _ -> ())
            | _ -> ());
           `Null
         in
         let doc_set_artboard_options_field_h : Effects.platform_effect = fun value call_ctx _ ->
           let eval_ctx = `Assoc call_ctx in
           (match value with
            | `Assoc pairs ->
              let field = match List.assoc_opt "field" pairs with
                | Some (`String s) -> s | _ -> "" in
              let v = match List.assoc_opt "value" pairs with
                | Some (`String s) -> Expr_eval.evaluate s eval_ctx
                | Some (`Bool b) -> Expr_eval.Bool b
                | _ -> Expr_eval.Null
              in
              (match v with
               | Expr_eval.Bool flag ->
                 let d = m#document in
                 let new_opts = match field with
                   | "fade_region_outside_artboard" ->
                     { d.Document.artboard_options with
                       Artboard.fade_region_outside_artboard = flag }
                   | "update_while_dragging" ->
                     { d.Document.artboard_options with
                       Artboard.update_while_dragging = flag }
                   | _ -> d.Document.artboard_options
                 in
                 m#set_document { d with Document.artboard_options = new_opts }
               | _ -> ())
            | _ -> ());
           `Null
         in
         let extract_id_list (v : Expr_eval.value) : string list =
           match v with
           | Expr_eval.List items ->
             (* items are Yojson.Safe.t; strings round-trip through
                JSON encoding of Value.List. *)
             List.filter_map (function
               | `String s -> Some s
               | _ -> None) items
           | _ -> []
         in
         let move_artboards up ids =
           let d = m#document in
           let arr = Array.of_list d.Document.artboards in
           let n = Array.length arr in
           let selected = List.fold_left (fun set s -> s :: set) [] ids in
           let is_selected i =
             i >= 0 && i < n && List.mem arr.(i).Artboard.id selected
           in
           let changed = ref false in
           if up then
             for i = 0 to n - 1 do
               if is_selected i && i > 0 && not (is_selected (i - 1)) then begin
                 let tmp = arr.(i - 1) in
                 arr.(i - 1) <- arr.(i);
                 arr.(i) <- tmp;
                 changed := true
               end
             done
           else
             for i = n - 1 downto 0 do
               if is_selected i && i < n - 1 && not (is_selected (i + 1)) then begin
                 let tmp = arr.(i + 1) in
                 arr.(i + 1) <- arr.(i);
                 arr.(i) <- tmp;
                 changed := true
               end
             done;
           if !changed then
             with_artboards (Array.to_list arr)
         in
         let doc_move_artboards_up_h : Effects.platform_effect = fun value call_ctx _ ->
           let eval_ctx = `Assoc call_ctx in
           let ids_expr = match value with `String s -> s | _ -> "" in
           let ids = extract_id_list (Expr_eval.evaluate ids_expr eval_ctx) in
           move_artboards true ids;
           `Null
         in
         let doc_move_artboards_down_h : Effects.platform_effect = fun value call_ctx _ ->
           let eval_ctx = `Assoc call_ctx in
           let ids_expr = match value with `String s -> s | _ -> "" in
           let ids = extract_id_list (Expr_eval.evaluate ids_expr eval_ctx) in
           move_artboards false ids;
           `Null
         in
         let base_platform_effects = [
           ("snapshot", snapshot_h);
           ("doc.set", doc_set_h);
           ("doc.delete_at", doc_delete_at_h);
           ("doc.clone_at", doc_clone_at_h);
           ("doc.insert_after", doc_insert_after_h);
           ("doc.insert_at", doc_insert_at_h);
           ("doc.create_layer", doc_create_layer_h);
           ("doc.wrap_in_group", doc_wrap_in_group_h);
           ("doc.wrap_in_layer", doc_wrap_in_layer_h);
           ("doc.unpack_group_at", doc_unpack_group_at_h);
           ("set_panel_state", set_panel_state_h);
           ("list_push", list_push_h);
           ("pop", pop_h);
           ("boolean_union", make_boolean_op_h "union");
           ("boolean_intersection", make_boolean_op_h "intersection");
           ("boolean_exclude", make_boolean_op_h "exclude");
           ("boolean_subtract_front", make_boolean_op_h "subtract_front");
           ("boolean_subtract_back", make_boolean_op_h "subtract_back");
           ("boolean_crop", make_boolean_op_h "crop");
           ("boolean_divide", make_boolean_op_h "divide");
           ("boolean_trim", make_boolean_op_h "trim");
           ("boolean_merge", make_boolean_op_h "merge");
           ("boolean_union_compound", make_compound_creation_h "union");
           ("boolean_subtract_front_compound", make_compound_creation_h "subtract_front");
           ("boolean_intersection_compound", make_compound_creation_h "intersection");
           ("boolean_exclude_compound", make_compound_creation_h "exclude");
           ("repeat_boolean_operation", repeat_boolean_op_h);
           ("reset_boolean_panel", reset_boolean_panel_h);
           ("make_compound_shape", make_cs_h);
           ("release_compound_shape", release_cs_h);
           ("expand_compound_shape", expand_cs_h);
           ("doc.create_artboard", doc_create_artboard_h);
           ("doc.delete_artboard_by_id", doc_delete_artboard_by_id_h);
           ("doc.duplicate_artboard", doc_duplicate_artboard_h);
           ("doc.set_artboard_field", doc_set_artboard_field_h);
           ("doc.set_artboard_options_field", doc_set_artboard_options_field_h);
           ("doc.move_artboards_up", doc_move_artboards_up_h);
           ("doc.move_artboards_down", doc_move_artboards_down_h);
         ] in
         let platform_effects = match on_close_dialog with
           | Some _ -> ("close_dialog", close_dialog_h) :: base_platform_effects
           | None -> base_platform_effects
         in
         let store = State_store.create () in
         Effects.run_effects ~platform_effects effects ctx store;
         (* If the action cleared the selection, tell the caller. *)
         if !cleared_selection then
           (match on_selection_changed with
            | Some cb -> cb []
            | None -> ())
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
    dispatch_yaml_action ~panel_selection:(get_panel_selection ()) "new_layer" (get_model ())
  | ("toggle_all_layers_visibility" | "toggle_all_layers_outline"
     | "toggle_all_layers_lock") when kind = Layers ->
    dispatch_yaml_action cmd (get_model ())
  | ("new_group" | "flatten_artwork" | "collect_in_new_layer")
    when kind = Layers ->
    dispatch_yaml_action ~panel_selection:(get_panel_selection ()) cmd (get_model ())
  | "enter_isolation_mode" when kind = Layers ->
    dispatch_yaml_action ~panel_selection:(get_panel_selection ())
      "enter_isolation_mode" (get_model ())
  | "exit_isolation_mode" when kind = Layers ->
    dispatch_yaml_action "exit_isolation_mode" (get_model ())
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
  | "toggle_hanging_punctuation" when kind = Paragraph ->
    paragraph_menu_dispatch (`Toggle "hanging_punctuation") get_model
  | "reset_paragraph_panel" when kind = Paragraph ->
    paragraph_menu_dispatch `Reset get_model
  | "make_compound_shape" when kind = Boolean ->
    Boolean_apply.apply_make_compound_shape (get_model ())
  | "release_compound_shape" when kind = Boolean ->
    Boolean_apply.apply_release_compound_shape (get_model ())
  | "expand_compound_shape" when kind = Boolean ->
    Boolean_apply.apply_expand_compound_shape (get_model ())
  (* Opacity panel mask-lifecycle commands route to the controller.
     new_masks_clipping / new_masks_inverted now come from the
     panel's State_store (seeded from yaml defaults; toggles below
     flip the stored values). *)
  | "make_opacity_mask" when kind = Opacity ->
    let ctrl = new Controller.controller ~model:(get_model ()) () in
    let clip = _opacity_store_bool "new_masks_clipping" ~default:true in
    let invert = _opacity_store_bool "new_masks_inverted" ~default:false in
    ctrl#make_mask_on_selection ~clip ~invert
  | "release_opacity_mask" when kind = Opacity ->
    let ctrl = new Controller.controller ~model:(get_model ()) () in
    ctrl#release_mask_on_selection
  | "disable_opacity_mask" when kind = Opacity ->
    let ctrl = new Controller.controller ~model:(get_model ()) () in
    ctrl#toggle_mask_disabled_on_selection
  | "unlink_opacity_mask" when kind = Opacity ->
    let ctrl = new Controller.controller ~model:(get_model ()) () in
    ctrl#toggle_mask_linked_on_selection
  (* Opacity panel-local toggles flip the stored bool in the
     State_store so subsequent [make_opacity_mask] dispatches and
     the menu's [checked_when] predicates see the live value. *)
  | ("toggle_opacity_thumbnails" | "toggle_opacity_options"
     | "toggle_new_masks_clipping" | "toggle_new_masks_inverted")
    when kind = Opacity ->
    (match !opacity_store_ref with
     | None -> ()
     | Some store ->
       let key = match cmd with
         | "toggle_opacity_thumbnails" -> "thumbnails_hidden"
         | "toggle_opacity_options" -> "options_shown"
         | "toggle_new_masks_clipping" -> "new_masks_clipping"
         | "toggle_new_masks_inverted" -> "new_masks_inverted"
         | _ -> assert false in
       let default = match key with
         | "new_masks_clipping" -> true
         | _ -> false in
       let cur = _opacity_store_bool key ~default in
       State_store.set_panel store "opacity_panel_content"
         key (`Bool (not cur)))
  | _ -> ()

(** Query whether a toggle/radio command is checked. *)
let panel_is_checked _kind cmd layout =
  match color_panel_mode_of_command cmd with
  | Some mode -> layout.color_panel_mode = mode
  | None ->
    match cmd with
    | "toggle_opacity_thumbnails" ->
      _opacity_store_bool "thumbnails_hidden" ~default:false
    | "toggle_opacity_options" ->
      _opacity_store_bool "options_shown" ~default:false
    | "toggle_new_masks_clipping" ->
      _opacity_store_bool "new_masks_clipping" ~default:true
    | "toggle_new_masks_inverted" ->
      _opacity_store_bool "new_masks_inverted" ~default:false
    | _ -> false
