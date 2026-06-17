(** Panel menu item types and per-panel lookup functions. *)

open Workspace_layout

(** A menu item in a panel's hamburger menu. Defined in
    [Panel_menu_yaml] (the generic builder) and re-exported here so the
    construction of these variants — which the genericity gate counts
    in [panel_menu.ml] — lives outside this file. Existing callers and
    tests keep using [Panel_menu.Action {..}] / bare [Action {..}]
    unchanged. *)
type panel_menu_item = Panel_menu_yaml.panel_menu_item =
  | Action of { label : string; command : string; shortcut : string }
  | Toggle of { label : string; command : string }
  | Radio of { label : string; command : string; group : string }
  | Separator

(** All panel kinds, for iteration. *)
let all_panel_kinds = [| Layers; Color; Swatches; Stroke; Properties; Character; Paragraph; Artboards; Align; Boolean; Opacity; Magic_wand |]

(** Registry of mounted panel stores, keyed by the panel content id
    (e.g. "paragraph_panel_content", "opacity_panel_content"). The
    yaml_panel_view registers a store on mount; menu-command
    dispatchers that need to reach back into a panel's state look it
    up by id. Replaces a prior pair of per-panel ref-cells
    (paragraph_store_ref / opacity_store_ref) plus a duplicate
    (panel_id, store) list-registry that lived in yaml_panel_view —
    one mechanism, one source of truth. Module-level singleton
    because the GTK app is single-threaded. *)
let panel_stores : (string, State_store.t) Hashtbl.t = Hashtbl.create 16

(** Register (or replace) the store for a panel id. Yaml_panel_view
    calls this on every panel mount so menu commands and cross-panel
    bridges can reach the live store. *)
let register_panel_store (panel_id : string) (store : State_store.t) : unit =
  Hashtbl.replace panel_stores panel_id store

(** Drop the registered store for a panel id. Call from the
    yaml_panel_view destroy hook so menu commands targeting an
    unmounted panel see [None] rather than a stale handle. *)
let unregister_panel_store (panel_id : string) : unit =
  Hashtbl.remove panel_stores panel_id

(** Look up a panel store by id; [None] when the panel is not
    currently mounted. *)
let lookup_panel_store (panel_id : string) : State_store.t option =
  Hashtbl.find_opt panel_stores panel_id

(** Iterate every registered panel store. Cross-panel bridges
    (recent_colors etc.) use this to fan out a write to siblings. *)
let iter_panel_stores (f : string -> State_store.t -> unit) : unit =
  Hashtbl.iter f panel_stores

(** Single source of truth for the four Opacity-panel toggle
    commands: command name to (state-store key, default value). Used
    by both panel_dispatch and panel_is_checked so the two cannot
    drift out of sync when a new toggle is added. *)
let opacity_toggle_table : (string * (string * bool)) list = [
  "toggle_opacity_thumbnails", ("thumbnails_hidden", false);
  "toggle_opacity_options", ("options_shown", false);
  "toggle_new_masks_clipping", ("new_masks_clipping", true);
  "toggle_new_masks_inverted", ("new_masks_inverted", false);
]

(** Read a bool from the Opacity panel's state store, falling back
    to [default] when the panel isn't mounted or the key is missing /
    non-bool. Used by [make_opacity_mask] dispatch and
    [panel_is_checked] for the four opacity panel toggles. *)
let _opacity_store_bool (key : string) ~(default : bool) : bool =
  match lookup_panel_store "opacity_panel_content" with
  | None -> default
  | Some store ->
    (match State_store.get_panel store "opacity_panel_content" key with
     | `Bool b -> b
     | _ -> default)

(** Callback for opening a YAML dialog by id. Registered at app
    startup by [bin/main.ml] (which can import [Yaml_dialog_view]).
    [Panel_menu] can't import [Yaml_dialog_view] directly because
    the dep graph routes [Yaml_panel_view] through [Panel_menu]
    already, so a direct import would form a cycle. *)
let _dialog_opener : (string -> unit) option ref = ref None

(** Install the dialog-opening callback. Called once at app startup
    by [bin/main.ml]. Subsequent calls replace the handler. *)
let register_dialog_opener (f : string -> unit) : unit =
  _dialog_opener := Some f

(** Hook for the reference-aware Symbols-panel Delete confirm fired from
    the panel hamburger menu (SYMBOLS.md section 8). Given the count
    [n] (> 0) of live instances the master still has, returns [true] to
    proceed (delete) and [false] to abort. Wired by [Menubar.create] to
    the SAME modal the layers delete confirm uses — its body reads
    "Deleting will leave N live instance(s) empty.", the cross-language
    pinned wording of the shared delete_symbol_orphan_confirm dialog. The
    default proceeds unconditionally (headless / before-wiring); only
    consulted when the master has instances. *)
let symbols_confirm_delete_hook : (int -> bool) ref = ref (fun _ -> true)

(** Helper: dispatch a Paragraph menu command through the live
    State_store + Controller. No-op when the panel isn't mounted or
    the model thunk yields [None]. *)
let paragraph_menu_dispatch (cmd : [< `Toggle of string | `Reset ])
    (get_model : unit -> Model.model) : unit =
  match lookup_panel_store "paragraph_panel_content" with
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

(** Read a character-panel toggle's bool from the registered store.
    Returns [default] when the panel isn't mounted or the key is
    missing / non-bool. Used by [panel_is_checked] for the menu's
    five Character toggles. *)
let _character_store_bool (key : string) ~(default : bool) : bool =
  match lookup_panel_store "character_panel_content" with
  | None -> default
  | Some store ->
    (match State_store.get_panel store "character_panel_content" key with
     | `Bool b -> b
     | _ -> default)

(** Helper: dispatch a Character menu toggle through the live
    State_store + Controller. Flips the panel-state bool, clears
    mutually-exclusive siblings (all_caps ↔ small_caps; superscript ↔
    subscript), and pushes the result onto the selected Text /
    Text_path so the menu and the in-panel icon toggles stay in
    sync. The [snap_to_glyph_visible] toggle skips the selection
    apply since it's purely panel-local UI state. *)
let character_menu_dispatch (key : string)
    (clear_on_set : string list)
    ~(apply_to_selection : bool)
    (get_model : unit -> Model.model) : unit =
  match lookup_panel_store "character_panel_content" with
  | None -> ()
  | Some store ->
    let cur = match State_store.get_panel store
                      "character_panel_content" key with
      | `Bool b -> b | _ -> false in
    let new_val = not cur in
    State_store.set_panel store "character_panel_content"
      key (`Bool new_val);
    if new_val then
      List.iter (fun sib ->
        State_store.set_panel store "character_panel_content"
          sib (`Bool false)) clear_on_set;
    if apply_to_selection then begin
      let m = get_model () in
      let ctrl = new Controller.controller ~model:m () in
      Effects.apply_character_panel_to_selection store ctrl
    end

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
  | Symbols -> "Symbols"

(** Menu items for a panel kind. Reads the panel's [menu:] array from
    the compiled workspace bundle (the single source of truth, review
    #15) and maps each entry to a [panel_menu_item] via the generic
    builder. The hand-written per-panel literals were deleted; the
    dispatch + checked-state bridges below remain as legitimate
    platform glue. The Color radio rows arrive param-folded from the
    builder as [set_color_panel_mode:<mode>] (see
    [color_panel_mode_of_command]); the Swatches "Open Swatch Library"
    dynamic submenu carries an explicit [action: open_swatch_library]
    so it surfaces as an [Action] the menu view can special-case. *)
let panel_menu (kind : panel_kind) : panel_menu_item list =
  Panel_menu_yaml.menu_items_from_yaml
    (Workspace_loader.panel_kind_to_content_id kind)

(** Listeners fired after a recent_colors push. Used by the
    Color/Swatches panel YAML state bridge so a native push can be
    mirrored into panel.recent_colors of every panel that exposes it. *)
let _recent_colors_listeners : (Model.model -> string -> unit) list ref = ref []

(** Register a callback fired after [push_recent_color] commits. *)
let add_recent_colors_listener cb =
  _recent_colors_listeners := cb :: !_recent_colors_listeners

(** Push a hex color to the model's recent_colors with move-to-front
    dedup and a max length of 10, then notify any registered
    listeners. Extracted from [set_active_color] so the listener
    behaviour stays in one place. *)
let push_recent_color (hex : string) (m : Model.model) =
  let rc = List.filter (fun c -> c <> hex) m#recent_colors in
  let rc = hex :: rc in
  let rc =
    if List.length rc > 10 then List.filteri (fun i _ -> i < 10) rc else rc
  in
  m#set_recent_colors rc;
  List.iter (fun cb ->
    try cb m hex with _ -> ()
  ) !_recent_colors_listeners

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
  push_recent_color hex m

(** Set the active color without pushing to recent colors (live slider drag).
    Mirrors [set_active_color] minus the [push_recent_color] tail — drag
    intermediates shouldn't pollute the recent strip, but still need to
    show in the canvas (selection) and the default fill/stroke so a
    subsequent click on an unfilled element picks up the dragged value. *)
let set_active_color_live color ~fill_on_top (m : Model.model) =
  if fill_on_top then begin
    m#set_default_fill (Some (Element.make_fill color));
    if not (Document.PathMap.is_empty m#document.Document.selection) then begin
      let ctrl = Controller.create ~model:m () in
      ctrl#set_selection_fill (Some (Element.make_fill color))
    end
  end else begin
    let width = match m#default_stroke with Some s -> s.stroke_width | None -> 1.0 in
    m#set_default_stroke (Some (Element.make_stroke ~width color));
    if not (Document.PathMap.is_empty m#document.Document.selection) then begin
      let ctrl = Controller.create ~model:m () in
      ctrl#set_selection_stroke (Some (Element.make_stroke ~width color))
    end
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
                     | Element.Layer le ->
                       let new_name = if s = "" then None else Some s in
                       Element.Layer { le with name = new_name }
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
         (* list_push: special-case targets routed to native state.
            - panel.isolation_stack — Phase 3 Group D
              (enter_isolation_mode); pushes the evaluated path onto
              yaml_panel_view's isolation stack.
            - panel.recent_colors — Swatches Panel set_active_color
              effect; routes the hex color into push_recent_color so
              model.recent_colors stays the single source of truth.
              Also mirrors the new recent_colors into the calling
              panel's store so the recent strip updates immediately.
              Cross-panel mirror to the sibling panel relies on the
              listener registry exposed by [add_recent_colors_listener]. *)
         let list_push_h : Effects.platform_effect = fun spec call_ctx store ->
           (match spec with
            | `Assoc pairs ->
              let target = match List.assoc_opt "target" pairs with
                | Some (`String s) -> s | _ -> ""
              in
              let value_expr = match List.assoc_opt "value" pairs with
                | Some (`String s) -> s | _ -> "null"
              in
              let eval_ctx = `Assoc call_ctx in
              if target = "panel.isolation_stack" then begin
                match Expr_eval.evaluate value_expr eval_ctx with
                | Expr_eval.Path p ->
                  Layers_panel_state.push_isolation_level p
                | _ -> ()
              end else if target = "panel.recent_colors" then begin
                (match Expr_eval.evaluate value_expr eval_ctx with
                 | Expr_eval.Color c | Expr_eval.Str c
                   when String.length c > 0 ->
                   (* Push to model — registered listeners (the
                      Yaml_panel_view recent_colors bridge) mirror
                      the new list into every panel.recent_colors
                      that is initialized, so the calling panel and
                      any sibling panel both update reactively. *)
                   ignore store;
                   push_recent_color c m
                 | _ -> ())
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
  (* Mode changes: track on the layout (controls the menu's
     [checked_when]) AND mirror into the color panel store so the
     YAML bind `panel.mode == "<mode>"` on each slider group sees
     the change on the next render. Without the store mirror the
     menu radios flip but the visible sliders stay on HSB. *)
  (match color_panel_mode_of_command cmd with
   | Some mode ->
     layout.color_panel_mode <- mode;
     let mode_str = match mode with
       | Grayscale -> "grayscale"
       | Rgb_mode -> "rgb"
       | Hsb_mode -> "hsb"
       | Cmyk_mode -> "cmyk"
       | Web_safe_rgb -> "web_safe_rgb" in
     (match lookup_panel_store "color_panel_content" with
      | Some store ->
        State_store.set_panel store "color_panel_content" "mode"
          (`String mode_str)
      | None -> ())
   | None -> ());
  match cmd with
  | "close_panel" ->
    close_panel layout addr;
    (* Reset color-panel mode to the YAML default (HSB) on close
       per CLR-028 — the spec says the mode is panel-local and
       should re-derive from the active color on reopen. Otherwise
       layout.color_panel_mode + panel.mode in the store both
       persist across the close/reopen cycle and the panel comes
       back in whichever mode the user last chose. *)
    if kind = Color then begin
      layout.color_panel_mode <- Hsb_mode;
      match lookup_panel_store "color_panel_content" with
      | Some store ->
        State_store.set_panel store "color_panel_content" "mode"
          (`String "hsb")
      | None -> ()
    end
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
  | "invert_active_color" when kind = Color ->
    (* Read fill_on_top from the Color panel's own state store
       (the fill/stroke widget writes there on swatch click)
       instead of the toolbar's flag — the two desync when the
       user picks a side in the panel without clicking the
       toolbar, so the menu would otherwise invert the wrong
       side (and the panel's hex display would track the side
       the panel thinks is active, leaving an inverted fill
       behind a stroke-side display showing black). *)
    let fill_on_top =
      match lookup_panel_store "color_panel_content" with
      | Some store ->
        (match State_store.get store "fill_on_top" with
         | `Bool b -> b | _ -> fill_on_top)
      | None -> fill_on_top in
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
  | "complement_active_color" when kind = Color ->
    let fill_on_top =
      match lookup_panel_store "color_panel_content" with
      | Some store ->
        (match State_store.get store "fill_on_top" with
         | `Bool b -> b | _ -> fill_on_top)
      | None -> fill_on_top in
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
  | ("open_paragraph_justification" | "open_paragraph_hyphenation")
    when kind = Paragraph ->
    (* Dialog openers route through a registered callback to break
       the dep cycle: Yaml_panel_view depends on Panel_menu, and
       Yaml_dialog_view depends on Yaml_panel_view, so Panel_menu
       cannot import Yaml_dialog_view directly. Bin/main installs a
       handler on startup; if no handler is registered (test
       harness, etc.) the click is a no-op. *)
    let dlg_id = if cmd = "open_paragraph_justification"
                 then "paragraph_justification"
                 else "paragraph_hyphenation" in
    (match !_dialog_opener with
     | Some open_fn -> open_fn dlg_id
     | None -> ())
  | "toggle_all_caps" when kind = Character ->
    character_menu_dispatch "all_caps" ["small_caps"]
      ~apply_to_selection:true get_model
  | "toggle_small_caps" when kind = Character ->
    character_menu_dispatch "small_caps" ["all_caps"]
      ~apply_to_selection:true get_model
  | "toggle_superscript" when kind = Character ->
    character_menu_dispatch "superscript" ["subscript"]
      ~apply_to_selection:true get_model
  | "toggle_subscript" when kind = Character ->
    character_menu_dispatch "subscript" ["superscript"]
      ~apply_to_selection:true get_model
  | "toggle_snap_to_glyph_visible" when kind = Character ->
    character_menu_dispatch "snap_to_glyph_visible" []
      ~apply_to_selection:false get_model
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
  | cmd when kind = Opacity && List.mem_assoc cmd opacity_toggle_table ->
    (match lookup_panel_store "opacity_panel_content" with
     | None -> ()
     | Some store ->
       let (key, default) = List.assoc cmd opacity_toggle_table in
       let cur = _opacity_store_bool key ~default in
       State_store.set_panel store "opacity_panel_content"
         key (`Bool (not cur)))
  (* Symbols panel (SYMBOLS.md section 8). The hamburger-menu entries
     fire the SAME native value-in-op arms the footer buttons do (mint
     ids / snapshot / shared symbol ops); the YAML actions are [log]
     stubs. Route through the symbols panel store so selection-gated ops
     read the live panel-selected master. *)
  | ("new_symbol" | "place_instance" | "delete_symbol_action")
    when kind = Symbols ->
    (match lookup_panel_store Symbols_panel.content_id with
     | None -> ()
     | Some store ->
       let m = get_model () in
       (match cmd with
        | "new_symbol" -> Symbols_panel.new_symbol store m
        | "place_instance" -> Symbols_panel.place_instance store m
        | "delete_symbol_action" ->
          Symbols_panel.delete_symbol_action store m
            ~confirm:(fun n -> !symbols_confirm_delete_hook n)
        | _ -> ()))
  | _ -> ()

(** Query whether a toggle/radio command is checked. *)
let panel_is_checked _kind cmd layout =
  match color_panel_mode_of_command cmd with
  | Some mode -> layout.color_panel_mode = mode
  | None ->
    match List.assoc_opt cmd opacity_toggle_table with
    | Some (key, default) -> _opacity_store_bool key ~default
    | None ->
      (* Character panel toggle commands map to bools in the
         "character_panel_content" panel scope. *)
      match cmd with
      | "toggle_snap_to_glyph_visible" ->
        _character_store_bool "snap_to_glyph_visible" ~default:false
      | "toggle_all_caps" ->
        _character_store_bool "all_caps" ~default:false
      | "toggle_small_caps" ->
        _character_store_bool "small_caps" ~default:false
      | "toggle_superscript" ->
        _character_store_bool "superscript" ~default:false
      | "toggle_subscript" ->
        _character_store_bool "subscript" ~default:false
      | _ -> false

(** True if the current selection contains at least one area-text
    element (Text with positive width AND positive height). Used by
    [panel_command_is_enabled] to gate Paragraph-panel menu items
    that only act on area text. *)
let _selection_has_area_text (m : Model.model) : bool =
  let any = ref false in
  Document.PathMap.iter (fun _ _ ->
    if not !any then ()
  ) m#document.Document.selection;
  let result = ref false in
  Document.PathMap.iter (fun path _ ->
    if not !result then
      match Document.get_element m#document path with
      | Element.Text { text_width; text_height; _ }
        when text_width > 0.0 && text_height > 0.0 -> result := true
      | _ -> ()
  ) m#document.Document.selection;
  let _ = !any in
  !result

let panel_command_is_enabled (kind : panel_kind) (cmd : string)
    (m : Model.model) : bool =
  match kind, cmd with
  | Paragraph,
    ( "toggle_hanging_punctuation"
    | "open_paragraph_justification"
    | "open_paragraph_hyphenation" ) ->
    _selection_has_area_text m
  | Color, ("invert_active_color" | "complement_active_color") ->
    (* The Color panel's Invert / Complement actions require a real
       color on the active side. Read state.fill_on_top from the
       Color panel's store (mirrors the dispatcher's source of
       truth) and check the matching model default. *)
    let fill_on_top =
      match lookup_panel_store "color_panel_content" with
      | Some store ->
        (match State_store.get store "fill_on_top" with
         | `Bool b -> b | _ -> true)
      | None -> true in
    if fill_on_top then m#default_fill <> None
    else m#default_stroke <> None
  | _ -> true
