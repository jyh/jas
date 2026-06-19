(** Menubar for the main window. *)

(* Module-level state for syncing Window menu check items after panel
   visibility changes that originate outside the menubar (right-click
   Close on a panel header, dock layout restore, etc.). The Window menu
   is built once at startup; this ref points at a sync closure that
   reads the live workspace_layout and pokes each registered
   check_menu_item's [#set_active] so the checkmarks stay truthful.
   Set inside [create]; called from canvas.ml's [dock_refresh] which
   already fires on every panel/dock state change. *)
let _sync_panel_checks_ref : (unit -> unit) ref = ref (fun () -> ())

(* Suppress check-menu-item activate callbacks fired by our own
   set_active calls in sync_panel_checks. Without this, the
   programmatic state update calls the toggle handler, which closes
   the panel, which re-fires sync_panel_checks via dock_refresh,
   which loops forever (beachball). *)
let _suppress_check_callback = ref false

let sync_panel_checks () = !_sync_panel_checks_ref ()

let group_selection (model : Model.model) () =
  let doc = model#document in
  let sel = doc.Document.selection in
  if Document.PathMap.is_empty sel then ()
  else begin
    let paths = Document.PathMap.fold (fun path _ acc -> path :: acc) sel [] in
    let sorted_paths = List.sort compare paths in
    if List.length sorted_paths < 2 then ()
    else begin
      (* Check all selected elements are siblings *)
      let parent p = match List.rev p with _ :: rest -> List.rev rest | [] -> [] in
      let first_parent = parent (List.hd sorted_paths) in
      if List.for_all (fun p -> parent p = first_parent) sorted_paths then begin
        let elements = List.map (fun p -> Document.get_element doc p) sorted_paths in
        (* Delete in reverse order *)
        let rev_paths = List.sort (fun a b -> compare b a) sorted_paths in
        let new_doc = List.fold_left Document.delete_element doc rev_paths in
        (* Create group and insert at position of first element *)
        let group = Element.make_group (Array.of_list elements) in
        let insert_path = List.hd sorted_paths in
        let layer_idx = List.hd insert_path in
        let child_idx = match insert_path with _ :: i :: _ -> i | _ -> 0 in
        let layer = new_doc.Document.layers.(layer_idx) in
        let old_children = Document.children_of layer in
        let n = Array.length old_children in
        let new_children = Array.init (n + 1) (fun i ->
          if i < child_idx then old_children.(i)
          else if i = child_idx then group
          else old_children.(i - 1)
        ) in
        let new_layer = Document.with_children layer new_children in
        let new_layers = Array.copy new_doc.Document.layers in
        new_layers.(layer_idx) <- new_layer;
        let new_sel = Document.PathMap.singleton insert_path
          (Document.make_element_selection insert_path) in
        (* Undoable edit (one self-bracketed undo step) via edit_document
           (OP_LOG.md Increment 1). *)
        model#edit_document { new_doc with
          Document.layers = new_layers;
          Document.selection = new_sel }
      end
    end
  end

(* "Make Instance" = the first user-facing way to create a live
   reference. Native UI glue (not a Controller op) composing two
   already-pinned ops under ONE snapshot: [create_reference] (the UI
   mints [target_id] / [ref_id], value-in-op, never inside a Controller)
   then a move of the now-selected reference by [paste_offset]. Enabled
   only when EXACTLY ONE whole element is selected (SelKindAll; not a
   control-point sub-selection); a no-op otherwise, like group's guard.
   The offset rides on the new reference's common transform via
   move_selection, so create-offset and move-to-reposition mutate the
   same field. Mirrors the Rust make_instance command. *)
let make_instance (model : Model.model) () =
  let doc = model#document in
  let sel = doc.Document.selection in
  (* Require exactly one whole-element selection. *)
  match Document.PathMap.bindings sel with
  | [ (target_path, es) ] when es.Document.es_kind = Document.SelKindAll ->
    (* Gather every existing element id so the freshly minted target_id /
       ref_id can avoid collisions. *)
    let existing = Hashtbl.create 16 in
    let rec gather elem =
      (match Element.id_of elem with
       | Some id -> Hashtbl.replace existing id ()
       | None -> ());
      match elem with
      | Element.Group { children; _ } | Element.Layer { children; _ } ->
        Array.iter gather children
      | _ -> ()
    in
    Array.iter gather doc.Document.layers;
    (* Mint two distinct, collision-free ids (mirrors the artboard mint
       loop). [None] when 100 attempts all collide. *)
    let mint () =
      let rec loop n =
        if n <= 0 then None
        else
          let c = Element.generate_id () in
          if Hashtbl.mem existing c then loop (n - 1)
          else Some c
      in
      loop 100
    in
    (match mint () with
     | None -> ()
     | Some target_id ->
       Hashtbl.replace existing target_id ();
       (match mint () with
        | None -> ()
        | Some ref_id ->
          (* create_reference + offset-move under ONE transaction = a single
             undo step: with_txn opens the bracket; the edit_document inside each
             Controller mutator JOINS it (OP_LOG.md Increment 1). *)
          let ctrl = new Controller.controller ~model () in
          model#with_txn (fun () ->
            ctrl#create_reference target_path target_id ref_id;
            ctrl#move_selection Canvas_tool.paste_offset Canvas_tool.paste_offset)))
  | _ -> ()

let ungroup_selection (model : Model.model) () =
  let doc = model#document in
  let sel = doc.Document.selection in
  if Document.PathMap.is_empty sel then ()
  else begin
    (* Collect selected paths that are Groups *)
    let group_paths = Document.PathMap.fold (fun path _ acc ->
      try
        let elem = Document.get_element doc path in
        (match elem with Element.Group _ -> path :: acc | _ -> acc)
      with _ -> acc
    ) sel [] in
    let sorted_paths = List.sort compare group_paths in
    if sorted_paths = [] then ()
    else begin
      (* Process in reverse order to preserve indices *)
      let new_doc = List.fold_left (fun doc gpath ->
        let group_elem = Document.get_element doc gpath in
        let children = Document.children_of group_elem in
        (* Delete the group *)
        let doc = Document.delete_element doc gpath in
        let layer_idx = List.hd gpath in
        let child_idx = match gpath with _ :: i :: _ -> i | _ -> 0 in
        let layer = doc.Document.layers.(layer_idx) in
        let old_children = Document.children_of layer in
        let n_old = Array.length old_children in
        let n_new = Array.length children in
        let new_children = Array.init (n_old + n_new) (fun i ->
          if i < child_idx then old_children.(i)
          else if i < child_idx + n_new then children.(i - child_idx)
          else old_children.(i - n_new)
        ) in
        let new_layer = Document.with_children layer new_children in
        let new_layers = Array.copy doc.Document.layers in
        new_layers.(layer_idx) <- new_layer;
        { doc with Document.layers = new_layers }
      ) doc (List.rev sorted_paths) in
      (* Build selection for unpacked children *)
      let new_sel = ref Document.PathMap.empty in
      let offset = ref 0 in
      List.iter (fun gpath ->
        let group_elem = Document.get_element doc gpath in
        let children = Document.children_of group_elem in
        let n_children = Array.length children in
        let layer_idx = List.hd gpath in
        let child_idx = (match gpath with _ :: i :: _ -> i | _ -> 0) + !offset in
        for j = 0 to n_children - 1 do
          let path = [layer_idx; child_idx + j] in
          let elem = Document.get_element new_doc path in
          let n = Element.control_point_count elem in
          new_sel := Document.PathMap.add path
            (Document.make_element_selection ~control_points:(List.init n Fun.id) path)
            !new_sel
        done;
        offset := !offset + n_children - 1
      ) sorted_paths;
      (* Undoable edit (one self-bracketed undo step) via edit_document. *)
      model#edit_document { new_doc with Document.selection = !new_sel }
    end
  end

let ungroup_all (model : Model.model) () =
  let doc = model#document in
  let changed = ref false in
  let rec flatten children =
    Array.to_list children |> List.concat_map (fun child ->
      match child with
      | Element.Group { children = gc; locked = false; _ } ->
        changed := true;
        flatten gc
      | Element.Group r ->
        (* Locked group: recurse into children but keep the group *)
        let new_children = Array.of_list (flatten r.children) in
        [Element.Group { r with children = new_children }]
      | _ -> [child]
    )
  in
  let new_layers = Array.map (fun layer ->
    match layer with
    | Element.Layer r ->
      let new_children = Array.of_list (flatten r.children) in
      Element.Layer { r with children = new_children }
    | _ -> layer
  ) doc.Document.layers in
  if !changed then
    (* Undoable edit (one self-bracketed undo step) via edit_document. *)
    model#edit_document { doc with
      Document.layers = new_layers;
      Document.selection = Document.PathMap.empty }

let copy_selection (model : Model.model) () =
  let doc = model#document in
  let sel = doc.Document.selection in
  if Document.PathMap.is_empty sel then ()
  else begin
    let elements = Document.PathMap.fold (fun path _ acc ->
      try Document.get_element doc path :: acc
      with _ -> acc
    ) sel [] in
    match elements with
    | [] -> ()
    | elems ->
      let temp_doc = Document.make_document
        [|Element.make_layer (Array.of_list (List.rev elems))|] in
      let svg = Svg.document_to_svg temp_doc in
      let clipboard = GtkBase.Clipboard.get Gdk.Atom.clipboard in
      GtkBase.Clipboard.set_text clipboard svg
  end

(* Reference-aware delete/cut (warn-then-orphan), the CONFIRM half.
   [n] is the count of live references that the pending operation would
   orphan (the length of [Dependency_index.orphaned_references ...]).
   [verb] is the gerund naming the action ("Deleting" / "Cutting").
   Verbatim wording is cross-language pinned: it must be byte-identical
   in every app, so it lives in one named, verb-parameterized helper so
   delete and cut share it and cannot drift. *)
let delete_orphan_warning_body ~(verb : string) (n : int) =
  Printf.sprintf "%s will leave %d live %s empty."
    verb n (if n = 1 then "instance" else "instances")

(* Generalized modal confirm shown when a delete/cut would orphan [n]
   (> 0) live references. Mirrors the [revert] confirm above
   (synchronous [#run] / [#destroy]) but uses custom button labels.
   [action] labels both the title and the destructive confirming button
   ("Delete" / "Cut"); [verb] is the gerund fed to the cross-language
   body ("Deleting" / "Cutting"). [Cancel] is the focused default so the
   safe choice wins a stray Enter. Returns [true] only when the user
   picks the destructive action. *)
let confirm_orphans ~(action : string) ~(verb : string) (n : int)
    (parent : GWindow.window) =
  let dialog = GWindow.dialog ~title:action ~modal:true ~parent () in
  ignore (GMisc.label ~text:(delete_orphan_warning_body ~verb n)
            ~xpad:12 ~ypad:12 ~packing:dialog#vbox#add ());
  dialog#add_button "Cancel" `CANCEL;
  dialog#add_button action `CONFIRM;
  dialog#set_default_response `CANCEL;
  let response = dialog#run () in
  dialog#destroy ();
  match response with `CONFIRM -> true | _ -> false

(* Modal confirm for a delete that would orphan [n] (> 0) live
   references. Thin wrapper over {!confirm_orphans} pinning the delete
   labels ("Delete" / "Deleting"); kept as a named entry point for the
   delete call site. Returns [true] only on the destructive [Delete]. *)
let confirm_delete_orphans (n : int) (parent : GWindow.window) =
  confirm_orphans ~action:"Delete" ~verb:"Deleting" n parent

(* Modal confirm for a cut that would orphan [n] (> 0) live references.
   Same dialog shape as the delete confirm; only the title /
   confirming-button label ("Cut") and the body verb ("Cutting") differ.
   Returns [true] only on the destructive [Cut]. *)
let confirm_cut_orphans (n : int) (parent : GWindow.window) =
  confirm_orphans ~action:"Cut" ~verb:"Cutting" n parent

(* Cut = copy-to-clipboard + delete the selection, so it can orphan
   live instances exactly like Delete. Reference-aware (warn-then-orphan)
   guard mirroring the keyboard-delete confirm in bin/main.ml: the paths
   the cut removes are exactly the [es_path] of each selection entry (the
   same set [delete_selection] folds over). Feed those to the shared,
   cross-language-pinned [orphaned_references] predicate. Empty -> cut
   exactly as before (no dialog, no regression). Non-empty -> confirm
   first; Cancel aborts entirely (no snapshot, no copy, no delete, so the
   clipboard is left unchanged); Cut runs the full copy + snapshot +
   delete as one undo step. *)
let cut_selection (model : Model.model) (parent : GWindow.window) () =
  let doc = model#document in
  if Document.PathMap.is_empty doc.Document.selection then ()
  else begin
    let selection_paths =
      Document.PathMap.fold
        (fun _ (es : Document.element_selection) acc ->
          es.Document.es_path :: acc)
        doc.Document.selection [] in
    let orphaned =
      Dependency_index.orphaned_references doc selection_paths in
    let proceed =
      match orphaned with
      | [] -> true  (* No live reference orphaned: cut as today. *)
      | _ -> confirm_cut_orphans (List.length orphaned) parent
    in
    if proceed then begin
      (* Undoable edit (one self-bracketed undo step) via edit_document
         (OP_LOG.md Increment 1). copy_selection only writes the system
         clipboard, so it carries no document mutation to bracket. *)
      copy_selection model ();
      model#edit_document (Document.delete_selection model#document)
    end
  end

let rec translate_element elem dx dy =
  if dx = 0.0 && dy = 0.0 then elem
  else
    match elem with
    | Element.Group { id; children; opacity; transform; locked; visibility; blend_mode;
                      isolated_blending; knockout_group; _ } ->
      Element.Group { name = None; id; children = Array.map (fun c -> translate_element c dx dy) children;
                      opacity; transform; locked; visibility; blend_mode;
                      mask = None;
                      isolated_blending; knockout_group }
    | Element.Layer { name; id; children; opacity; transform; locked; visibility; blend_mode;
                      isolated_blending; knockout_group; _ } ->
      Element.Layer { name; id; children = Array.map (fun c -> translate_element c dx dy) children;
                      opacity; transform; locked; visibility; blend_mode;
                      mask = None;
                      isolated_blending; knockout_group }
    | Element.Live (Element.Reference _) ->
      (* A reference has no geometry of its own; a whole-element move
         rides on common.transform via the [is_all] Reference arm in
         move_control_points. Mirrors the Rust translate_element. *)
      Element.move_control_points ~is_all:true elem [] dx dy
    | _ ->
      let n = Element.control_point_count elem in
      let indices = List.init n Fun.id in
      Element.move_control_points elem indices dx dy

let is_svg text =
  let s = String.trim text in
  let starts_with prefix =
    String.length s >= String.length prefix &&
    String.sub s 0 (String.length prefix) = prefix
  in
  starts_with "<?xml" || starts_with "<svg"

let paste_clipboard (model : Model.model) offset () =
  (* The document write happens later, in the async clipboard callback, so the
     undo bracket must live there too: each branch ends with a single
     edit_document (one self-bracketed undo step). A synchronous snapshot here
     would push a checkpoint before the (possibly empty) clipboard arrives.
     OP_LOG.md Increment 1. *)
  let clipboard = GtkBase.Clipboard.get Gdk.Atom.clipboard in
  GtkBase.Clipboard.request_text clipboard ~callback:(fun text_opt ->
    match text_opt with
    | None -> ()
    | Some text when String.length text = 0 -> ()
    | Some text ->
      let doc = model#document in
      let new_sel = ref Document.PathMap.empty in
      if is_svg text then begin
        let pasted_doc = Svg.svg_to_document text in
        let new_layers = Array.copy doc.Document.layers in
        Array.iter (fun pasted_layer ->
          let children = match pasted_layer with
            | Element.Layer { children; _ } ->
              Array.map (fun c -> translate_element c offset offset) children
            | _ -> [||]
          in
          if Array.length children = 0 then ()
          else begin
            let name = match pasted_layer with
              | Element.Layer { name = Some s; _ } when s <> "" -> Some s
              | _ -> None
            in
            (* Find matching layer by name *)
            let target_idx = ref (-1) in
            (match name with
             | Some pname ->
               Array.iteri (fun i existing ->
                 if !target_idx < 0 then
                   match existing with
                   | Element.Layer { name = Some n; _ } when n = pname ->
                     target_idx := i
                   | _ -> ()
               ) new_layers
             | None -> ());
            if !target_idx < 0 then
              target_idx := doc.Document.selected_layer;
            let idx = !target_idx in
            (* Record paths for pasted elements *)
            let base = match new_layers.(idx) with
              | Element.Layer { children = ec; _ } -> Array.length ec
              | _ -> 0
            in
            Array.iteri (fun j child ->
              let path = [idx; base + j] in
              let n = Element.control_point_count child in
              new_sel := Document.PathMap.add path
                (Document.make_element_selection ~control_points:(List.init n Fun.id) path)
                !new_sel
            ) children;
            match new_layers.(idx) with
            | Element.Layer { name = n; id; children = ec; opacity; transform; locked; visibility; blend_mode;
                              isolated_blending; knockout_group; _ } ->
              new_layers.(idx) <- Element.Layer { name = n; id; children = Array.append ec children; opacity; transform; locked; visibility; blend_mode;
                                                   mask = None;
                                                   isolated_blending; knockout_group }
            | _ -> ()
          end
        ) pasted_doc.Document.layers;
        model#edit_document { doc with layers = new_layers;
                                      selection = !new_sel }
      end else begin
        (* Plain text: create a Text element. Sanitize first so an
           OS-clipboard payload with stray non-UTF-8 bytes can't
           crash the canvas draw — Cairo's show_text aborts on
           invalid UTF-8. Drop bytes ≥ 0x80 when the input isn't
           valid UTF-8 as a whole. *)
        let text = Type_tool.sanitize_utf8 text in
        let elem = Element.make_text (offset) (offset +. 16.0) text in
        let idx = doc.Document.selected_layer in
        let base = match doc.Document.layers.(idx) with
          | Element.Layer { children; _ } -> Array.length children
          | _ -> 0
        in
        let path = [idx; base] in
        let n = Element.control_point_count elem in
        new_sel := Document.PathMap.add path
          (Document.make_element_selection ~control_points:(List.init n Fun.id) path)
          !new_sel;
        let new_layers = Array.mapi (fun i l ->
          if i = idx then
            match l with
            | Element.Layer layer ->
              Element.Layer { layer with children = Array.append layer.children [| elem |] }
            | _ -> l
          else l
        ) doc.Document.layers in
        model#edit_document { doc with layers = new_layers;
                                      selection = !new_sel }
      end
  )

let open_file on_open (parent : GWindow.window) () =
  let dialog = GWindow.file_chooser_dialog
    ~action:`OPEN
    ~title:"Open"
    ~parent
    () in
  dialog#add_button_stock `CANCEL `CANCEL;
  dialog#add_button_stock `OPEN `ACCEPT;
  let filter = GFile.filter ~name:"SVG Files" ~patterns:["*.svg"] () in
  dialog#add_filter filter;
  dialog#set_filter filter;
  begin match dialog#run () with
  | `ACCEPT ->
    begin match dialog#filename with
    | Some path ->
      let max_file_size = 100 * 1024 * 1024 in
      let ic = open_in path in
      let n = in_channel_length ic in
      if n > max_file_size then begin
        close_in ic;
        dialog#destroy ();
        let _ = GWindow.message_dialog ~message:"File too large (over 100 MB)."
          ~message_type:`ERROR ~buttons:GWindow.Buttons.ok ~parent () in ()
      end else begin
        let svg = really_input_string ic n in
        close_in ic;
        let new_model = Model.create
          ~document:(Svg.svg_to_document svg) ~filename:path () in
        dialog#destroy ();
        on_open new_model
      end
    | None -> dialog#destroy ()
    end
  | _ -> dialog#destroy ()
  end

let save_as (model : Model.model) (parent : GWindow.window) () =
  let dialog = GWindow.file_chooser_dialog
    ~action:`SAVE
    ~title:"Save As"
    ~parent
    () in
  dialog#add_button_stock `CANCEL `CANCEL;
  dialog#add_button_stock `SAVE `ACCEPT;
  dialog#set_current_name (Filename.basename model#filename);
  let filter = GFile.filter ~name:"SVG Files" ~patterns:["*.svg"] () in
  dialog#add_filter filter;
  dialog#set_filter filter;
  dialog#set_do_overwrite_confirmation true;
  begin match dialog#run () with
  | `ACCEPT ->
    begin match dialog#filename with
    | Some path ->
      let svg = Svg.document_to_svg model#document in
      let oc = open_out path in
      output_string oc svg;
      close_out oc;
      model#mark_saved;
      model#set_filename path
    | None -> ()
    end
  | _ -> ()
  end;
  dialog#destroy ()

let is_untitled filename =
  String.length filename >= 9 && String.sub filename 0 9 = "Untitled-"

(** Strip a known extension from [filename] and append .pdf. Falls
    back to "Untitled.pdf" for empty / Untitled-N names. *)
let pdf_filename_for filename =
  let trimmed = String.trim filename in
  if trimmed = "" || is_untitled trimmed then "Untitled.pdf"
  else
    let stem =
      try Filename.chop_extension trimmed
      with Invalid_argument _ -> trimmed
    in
    Filename.basename stem ^ ".pdf"

(** PRINT.md §1B File menu Export to PDF... entry. Generates a PDF
    via Pdf.document_to_pdf and writes it to a user-chosen path. *)
let export_to_pdf (model : Model.model) (parent : GWindow.window) () =
  let dialog = GWindow.file_chooser_dialog
    ~action:`SAVE
    ~title:"Export to PDF"
    ~parent
    () in
  dialog#add_button_stock `CANCEL `CANCEL;
  dialog#add_button_stock `SAVE `ACCEPT;
  dialog#set_current_name (pdf_filename_for model#filename);
  let filter = GFile.filter ~name:"PDF Files" ~patterns:["*.pdf"] () in
  dialog#add_filter filter;
  dialog#set_filter filter;
  dialog#set_do_overwrite_confirmation true;
  begin match dialog#run () with
  | `ACCEPT ->
    begin match dialog#filename with
    | Some path ->
      let bytes = Pdf.document_to_pdf model#document in
      let oc = open_out_bin path in
      output_string oc bytes;
      close_out oc
    | None -> ()
    end
  | _ -> ()
  end;
  dialog#destroy ()

let save (model : Model.model) (parent : GWindow.window) () =
  if is_untitled model#filename then
    save_as model parent ()
  else begin
    let svg = Svg.document_to_svg model#document in
    let oc = open_out model#filename in
    output_string oc svg;
    close_out oc;
    model#mark_saved
  end

let revert (get_model : unit -> Model.model) (parent : GWindow.window) () =
  let model = get_model () in
  if not model#is_modified then ()
  else if is_untitled model#filename then ()
  else begin
    let dialog = GWindow.message_dialog
      ~message:(Printf.sprintf "Revert to the saved version of \"%s\"?\n\nAll current modifications will be lost." model#filename)
      ~message_type:`WARNING
      ~buttons:GWindow.Buttons.ok_cancel
      ~parent
      () in
    let response = dialog#run () in
    dialog#destroy ();
    match response with
    | `OK ->
      let max_file_size = 100 * 1024 * 1024 in
      let ic = open_in model#filename in
      let n = in_channel_length ic in
      if n > max_file_size then begin
        close_in ic;
        let _ = GWindow.message_dialog ~message:"File too large (over 100 MB)."
          ~message_type:`ERROR ~buttons:GWindow.Buttons.ok ~parent () in ()
      end else begin
        let svg = really_input_string ic n in
        close_in ic;
        (* Reverting is an undoable edit (one self-bracketed undo step). *)
        model#edit_document (Svg.svg_to_document svg);
        model#mark_saved
      end
    | _ -> ()
  end

let create (get_model : unit -> Model.model) (parent : GWindow.window) ~on_open ?(workspace_layout : Workspace_layout.workspace_layout option) ?(app_config : Workspace_layout.app_config option) ?(refresh_dock : (unit -> unit) option) (vbox : GPack.box) =
  let m () = get_model () in
  (* Menubar *)
  let menubar = GMenu.menu_bar ~packing:(fun w -> vbox#pack w) () in
  let menubar_css = new GObj.css_provider (GtkData.CssProvider.create ()) in
  let apply_menubar_css () =
    menubar_css#load_from_data (Printf.sprintf
      "menubar, menubar > menuitem, menu, menu > menuitem { background-color: %s; color: %s; }"
      !(Dock_panel.theme_bg_dark) !(Dock_panel.theme_text))
  in
  apply_menubar_css ();
  menubar#misc#style_context#add_provider menubar_css 600;
  let factory = new GMenu.factory menubar in
  (* Attach the factory's accel_group to the parent window so menu
     accelerators (Ctrl-N, Ctrl-S, Ctrl-P, etc.) actually fire as
     keyboard shortcuts. Without this the keysym shows in the menu
     label but the keypress is never routed to the menu callback. *)
  parent#add_accel_group factory#accel_group;

  (* File menu *)
  let _file_menu = factory#add_submenu "File" in
  let file_factory = new GMenu.factory ~accel_group:factory#accel_group _file_menu in
  (* Document.default_document () builds with empty artboards which
     gives a featureless gray pasteboard. Seed the at-least-one
     invariant so a fresh canvas opens with a visible white artboard. *)
  ignore (file_factory#add_item "New" ~key:GdkKeysyms._n ~callback:(fun () ->
    let layers = [| Element.make_layer [||] |] in
    let (abs, _) = Artboard.ensure_invariant [] in
    let doc = Document.make_document ~artboards:abs layers in
    on_open (Model.create ~document:doc ())));
  ignore (file_factory#add_item "Open..." ~key:GdkKeysyms._o ~callback:(open_file on_open parent));
  ignore (file_factory#add_item "Save" ~key:GdkKeysyms._s ~callback:(fun () -> save (m ()) parent ()));
  ignore (file_factory#add_item "Save As..." ~key:GdkKeysyms._s ~callback:(fun () -> save_as (m ()) parent ()));
  ignore (file_factory#add_item "Revert" ~callback:(revert m parent));
  ignore (file_factory#add_separator ());
  (* PRINT.md §1: Document Setup, Print, Export to PDF.
     Dialog flows route through [Yaml_dialog_view] which renders the
     workspace YAML, wires widget write-backs, and dispatches the
     OK / Cancel / Print actions. ``active_document`` outer scope is
     required so init expressions like
     ``active_document.print_preferences.copies`` resolve to persisted
     document values rather than falling back to the YAML defaults. *)
  let open_print_phase_dialog dialog_id () =
    let outer_scope = [
      ("active_document",
       Active_document_view.build (Some (m ())));
    ] in
    match Yaml_dialog_view.open_dialog ~outer_scope dialog_id [] [] with
    | Some ds -> Yaml_dialog_view.show_dialog ~parent ~outer_scope ds
    | None -> ()
  in
  ignore (file_factory#add_item "Document Setup..."
    ~callback:(open_print_phase_dialog "document_setup"));
  ignore (file_factory#add_item "Print..." ~key:GdkKeysyms._p
    ~callback:(open_print_phase_dialog "print"));
  ignore (file_factory#add_item "Export to PDF..." ~callback:(fun () ->
    export_to_pdf (m ()) parent ()));
  ignore (file_factory#add_separator ());
  ignore (file_factory#add_item "Quit" ~key:GdkKeysyms._q ~callback:(fun () -> GMain.quit ()));

  (* Edit menu *)
  let _edit_menu = factory#add_submenu "Edit" in
  let edit_factory = new GMenu.factory ~accel_group:factory#accel_group _edit_menu in
  ignore (edit_factory#add_item "Undo" ~key:GdkKeysyms._z ~callback:(fun () -> (m ())#undo));
  ignore (edit_factory#add_item "Redo" ~callback:(fun () -> (m ())#redo));
  ignore (edit_factory#add_separator ());
  ignore (edit_factory#add_item "Cut" ~key:GdkKeysyms._x ~callback:(fun () -> cut_selection (m ()) parent ()));
  ignore (edit_factory#add_item "Copy" ~key:GdkKeysyms._c ~callback:(fun () -> copy_selection (m ()) ()));
  ignore (edit_factory#add_item "Paste" ~key:GdkKeysyms._v ~callback:(fun () -> paste_clipboard (m ()) Canvas_tool.paste_offset ()));
  ignore (edit_factory#add_item "Paste in Place" ~callback:(fun () -> paste_clipboard (m ()) 0.0 ()));
  ignore (edit_factory#add_separator ());
  ignore (edit_factory#add_item "Select All" ~key:GdkKeysyms._a ~callback:(fun () ->
    let model = m () in
    (new Controller.controller ~model ())#select_all));

  (* Object menu *)
  let _object_menu = factory#add_submenu "Object" in
  let object_factory = new GMenu.factory ~accel_group:factory#accel_group _object_menu in
  ignore (object_factory#add_item "Group" ~key:GdkKeysyms._g ~callback:(fun () -> group_selection (m ()) ()));
  ignore (object_factory#add_item "Ungroup" ~callback:(fun () -> ungroup_selection (m ()) ()));
  ignore (object_factory#add_item "Ungroup All" ~callback:(fun () -> ungroup_all (m ()) ()));
  ignore (object_factory#add_separator ());
  (* The Controller mutators self-bracket via edit_document (one undo step);
     no separate snapshot needed (OP_LOG.md Increment 1). *)
  ignore (object_factory#add_item "Lock" ~key:GdkKeysyms._2 ~callback:(fun () ->
    let model = m () in (new Controller.controller ~model ())#lock_selection));
  ignore (object_factory#add_item "Unlock All" ~callback:(fun () ->
    let model = m () in (new Controller.controller ~model ())#unlock_all));
  ignore (object_factory#add_separator ());
  ignore (object_factory#add_item "Hide" ~key:GdkKeysyms._3 ~callback:(fun () ->
    let model = m () in (new Controller.controller ~model ())#hide_selection));
  ignore (object_factory#add_item "Show All" ~callback:(fun () ->
    let model = m () in (new Controller.controller ~model ())#show_all));
  ignore (object_factory#add_separator ());
  ignore (object_factory#add_item "Make Instance" ~callback:(fun () ->
    make_instance (m ()) ()));

  (* View menu *)
  let _view_menu = factory#add_submenu "View" in
  let view_factory = new GMenu.factory ~accel_group:factory#accel_group _view_menu in
  let bump_zoom factor () =
    let model = m () in
    let cx = model#viewport_w /. 2.0 in
    let cy = model#viewport_h /. 2.0 in
    let z = model#zoom_level in
    let doc_cx = (cx -. model#view_offset_x) /. z in
    let doc_cy = (cy -. model#view_offset_y) /. z in
    let z' = max 0.1 (min 64.0 (z *. factor)) in
    model#set_zoom_level z';
    model#set_view_offset_x (cx -. doc_cx *. z');
    model#set_view_offset_y (cy -. doc_cy *. z');
    parent#misc#queue_draw ()
  in
  ignore (view_factory#add_item "Zoom In" ~key:GdkKeysyms._plus
    ~callback:(bump_zoom 1.2));
  ignore (view_factory#add_item "Zoom Out" ~key:GdkKeysyms._minus
    ~callback:(bump_zoom (1.0 /. 1.2)));
  ignore (view_factory#add_item "Fit in Window" ~key:GdkKeysyms._0
    ~callback:(fun () ->
      (m ())#center_view_on_current_artboard;
      parent#misc#queue_draw ()));

  (* Window menu *)
  let _window_menu = factory#add_submenu "Window" in
  let window_factory = new GMenu.factory ~accel_group:factory#accel_group _window_menu in

  (* Workspace submenu *)
  (match workspace_layout, app_config, refresh_dock with
   | Some layout, Some config, Some refresh ->
     let _ws_menu = window_factory#add_submenu "Workspace" in
     let ws_factory = new GMenu.factory _ws_menu in
     (* List saved layouts, filtering out "Workspace" *)
     let visible = List.filter (fun n -> n <> Workspace_layout.workspace_layout_name) config.Workspace_layout.saved_layouts in
     List.iter (fun name ->
       let prefix = if name = config.Workspace_layout.active_layout then "\xE2\x9C\x93 " else "    " in
       ignore (ws_factory#add_item (prefix ^ name) ~callback:(fun () ->
         Workspace_layout.save_layout layout;
         let loaded = Workspace_layout.load_layout name in
         layout.Workspace_layout.version <- loaded.Workspace_layout.version;
         layout.Workspace_layout.name <- Workspace_layout.workspace_layout_name;
         layout.Workspace_layout.anchored <- loaded.Workspace_layout.anchored;
         layout.Workspace_layout.floating <- loaded.Workspace_layout.floating;
         layout.Workspace_layout.hidden_panels <- loaded.Workspace_layout.hidden_panels;
         layout.Workspace_layout.z_order <- loaded.Workspace_layout.z_order;
         layout.Workspace_layout.focused_panel <- loaded.Workspace_layout.focused_panel;
         layout.Workspace_layout.appearance <- loaded.Workspace_layout.appearance;
         layout.Workspace_layout.pane_layout <- loaded.Workspace_layout.pane_layout;
         layout.Workspace_layout.next_id <- loaded.Workspace_layout.next_id;
         config.Workspace_layout.active_layout <- name;
         config.Workspace_layout.active_appearance <- loaded.Workspace_layout.appearance;
         Dock_panel.set_theme loaded.Workspace_layout.appearance;
         Workspace_layout.save_app_config config;
         Workspace_layout.save_layout layout;
         refresh ()
       ))
     ) visible;
     ignore (ws_factory#add_separator ());
     (* Save As... *)
     ignore (ws_factory#add_item "Save As\xE2\x80\xA6" ~callback:(fun () ->
       let dialog = GWindow.dialog ~title:"Save Workspace As" ~parent ~modal:true () in
       let vbox = dialog#vbox in
       let prefill = if config.Workspace_layout.active_layout <> Workspace_layout.workspace_layout_name
         then config.Workspace_layout.active_layout else "" in
       let entry = GEdit.entry ~text:prefill ~packing:vbox#add () in
       dialog#add_button_stock `CANCEL `CANCEL;
       dialog#add_button_stock `SAVE `ACCEPT;
       let response = dialog#run () in
       let name = String.trim (entry#text) in
       dialog#destroy ();
       if response = `ACCEPT && name <> "" then begin
         if String.lowercase_ascii name = String.lowercase_ascii Workspace_layout.workspace_layout_name then begin
           let info = GWindow.message_dialog ~message:"\xE2\x80\x9CWorkspace\xE2\x80\x9D is a system workspace that is saved automatically."
             ~message_type:`INFO ~buttons:GWindow.Buttons.ok ~parent ~modal:true () in
           ignore (info#run ());
           info#destroy ()
         end else if List.mem name config.Workspace_layout.saved_layouts then begin
           let confirm = GWindow.message_dialog
             ~message:(Printf.sprintf "Layout \xE2\x80\x9C%s\xE2\x80\x9D already exists. Overwrite?" name)
             ~message_type:`QUESTION ~buttons:GWindow.Buttons.ok_cancel ~parent ~modal:true () in
           let resp = confirm#run () in
           confirm#destroy ();
           if resp = `OK then begin
             layout.Workspace_layout.appearance <- config.Workspace_layout.active_appearance;
             Workspace_layout.save_layout_as layout name;
             Workspace_layout.register_layout config name;
             config.Workspace_layout.active_layout <- name;
             Workspace_layout.save_app_config config
           end
         end else begin
           layout.Workspace_layout.appearance <- config.Workspace_layout.active_appearance;
           Workspace_layout.save_layout_as layout name;
           Workspace_layout.register_layout config name;
           config.Workspace_layout.active_layout <- name;
           Workspace_layout.save_app_config config
         end
       end
     ));
     ignore (ws_factory#add_separator ());
     (* Reset to Default *)
     ignore (ws_factory#add_item "Reset to Default" ~callback:(fun () ->
       Workspace_layout.reset_to_default layout;
       layout.Workspace_layout.name <- Workspace_layout.workspace_layout_name;
       config.Workspace_layout.active_layout <- Workspace_layout.workspace_layout_name;
       Workspace_layout.save_app_config config;
       Workspace_layout.save_layout layout;
       refresh ()
     ));
     (* Revert to Saved *)
     ignore (ws_factory#add_item "Revert to Saved" ~callback:(fun () ->
       if config.Workspace_layout.active_layout <> Workspace_layout.workspace_layout_name then begin
         let loaded = Workspace_layout.load_layout config.Workspace_layout.active_layout in
         layout.Workspace_layout.version <- loaded.Workspace_layout.version;
         layout.Workspace_layout.name <- Workspace_layout.workspace_layout_name;
         layout.Workspace_layout.anchored <- loaded.Workspace_layout.anchored;
         layout.Workspace_layout.floating <- loaded.Workspace_layout.floating;
         layout.Workspace_layout.hidden_panels <- loaded.Workspace_layout.hidden_panels;
         layout.Workspace_layout.z_order <- loaded.Workspace_layout.z_order;
         layout.Workspace_layout.focused_panel <- loaded.Workspace_layout.focused_panel;
         layout.Workspace_layout.pane_layout <- loaded.Workspace_layout.pane_layout;
         layout.Workspace_layout.next_id <- loaded.Workspace_layout.next_id;
         Workspace_layout.save_layout layout;
         refresh ()
       end
     ));
     ignore (ws_factory#add_separator ())
   | _ -> ());

  (* Appearance submenu — rebuilt on each show to update checkmarks *)
  (match app_config, refresh_dock with
   | Some config, Some refresh ->
     let app_menu = window_factory#add_submenu "Appearance" in
     let rec rebuild_appearance_menu () =
       List.iter (fun c -> c#destroy ()) app_menu#children;
       let app_factory = new GMenu.factory app_menu in
       List.iter (fun (entry : Theme.appearance_entry) ->
         let prefix = if entry.name = config.Workspace_layout.active_appearance then "\xE2\x9C\x93 " else "    " in
         ignore (app_factory#add_item (prefix ^ entry.label) ~callback:(fun () ->
           config.Workspace_layout.active_appearance <- entry.name;
           Dock_panel.set_theme entry.name;
           Workspace_layout.save_app_config config;
           apply_menubar_css ();
           refresh ();
           rebuild_appearance_menu ()
         ))
       ) Theme.predefined_appearances
     in
     rebuild_appearance_menu ()
   | _ -> ());

  (* Pane toggles *)
  (match workspace_layout, refresh_dock with
   | Some layout, Some refresh ->
     ignore (window_factory#add_separator ());
     ignore (window_factory#add_item "Tile" ~callback:(fun () ->
       (* OP_LOG 3d-2: route the menu Tile through the shared runtime
          dispatcher. [panes_mut] preserves the dirty signal (bumps after the
          op), and the dispatcher re-guards [pane_layout] internally. The
          corpus path is the no-override case. *)
       Workspace_layout.panes_mut layout (fun _pl ->
         Layout_apply.layout_apply layout (Layout_apply.op_tile_panes ()));
       refresh ()
     ));
     ignore (window_factory#add_separator ());
     let toggle_pane kind label =
       let active = match Workspace_layout.panes layout with
         | Some pl -> Pane.is_pane_visible pl kind
         | None -> false in
       ignore (window_factory#add_check_item label ~active ~callback:(fun _ ->
         if !_suppress_check_callback then () else begin
           (* OP_LOG 3d-2: route the pane visibility toggle through the shared
              runtime dispatcher; [panes_mut] preserves the dirty signal. *)
           Workspace_layout.panes_mut layout (fun pl ->
             let op =
               if Pane.is_pane_visible pl kind
               then Layout_apply.op_hide_pane kind
               else Layout_apply.op_show_pane kind
             in
             Layout_apply.layout_apply layout op);
           refresh ()
         end
       ))
     in
     toggle_pane Pane.Toolbar "Toolbar";
     toggle_pane Pane.Dock "Panels"
   | _ -> ());

  ignore (window_factory#add_separator ());

  (* Panel toggles — check-menu items so the Window menu shows a
     checkmark next to each visible panel. The menu is built once at
     startup; check states are kept truthful by [sync_panel_checks]
     (assigned below), which canvas.ml's dock_refresh fires after any
     panel/dock state change. *)
  let panel_checks : (Workspace_layout.panel_kind, GMenu.check_menu_item) Hashtbl.t =
    Hashtbl.create 16 in
  let toggle_panel kind label =
    let active = match workspace_layout with
      | Some layout -> Workspace_layout.is_panel_visible layout kind
      | None -> false in
    let item = window_factory#add_check_item label ~active ~callback:(fun _ ->
      if !_suppress_check_callback then () else
      match workspace_layout, refresh_dock with
      | Some layout, Some refresh ->
        if Workspace_layout.is_panel_visible layout kind then begin
          (* Find and close the panel *)
          let found = ref false in
          List.iter (fun (_, (d : Workspace_layout.dock)) ->
            Array.iteri (fun gi (g : Workspace_layout.panel_group) ->
              Array.iteri (fun pi k ->
                if k = kind && not !found then begin
                  (* OP_LOG 3d-2: route through the shared runtime dispatcher. *)
                  Layout_apply.layout_apply layout
                    (Layout_apply.op_close_panel
                       { group = { dock_id = d.id; group_idx = gi }; panel_idx = pi });
                  found := true
                end
              ) g.panels
            ) d.groups
          ) layout.anchored;
          List.iter (fun (fd : Workspace_layout.floating_dock) ->
            Array.iteri (fun gi (g : Workspace_layout.panel_group) ->
              Array.iteri (fun pi k ->
                if k = kind && not !found then begin
                  (* OP_LOG 3d-2: route through the shared runtime dispatcher. *)
                  Layout_apply.layout_apply layout
                    (Layout_apply.op_close_panel
                       { group = { dock_id = fd.dock.id; group_idx = gi }; panel_idx = pi });
                  found := true
                end
              ) g.panels
            ) fd.dock.groups
          ) layout.floating
        end else
          (* OP_LOG 3d-2: route through the shared runtime dispatcher. *)
          Layout_apply.layout_apply layout (Layout_apply.op_show_panel kind);
        refresh ()
      | _ -> ()
    ) in
    Hashtbl.replace panel_checks kind item
  in
  toggle_panel Workspace_layout.Align "Align";
  toggle_panel Workspace_layout.Artboards "Artboards";
  toggle_panel Workspace_layout.Boolean "Boolean";
  toggle_panel Workspace_layout.Character "Character";
  toggle_panel Workspace_layout.Color "Color";
  toggle_panel Workspace_layout.Layers "Layers";
  toggle_panel Workspace_layout.Magic_wand "Magic Wand";
  toggle_panel Workspace_layout.Opacity "Opacity";
  toggle_panel Workspace_layout.Paragraph "Paragraph";
  toggle_panel Workspace_layout.Properties "Properties";
  toggle_panel Workspace_layout.Stroke "Stroke";
  toggle_panel Workspace_layout.Swatches "Swatches";
  toggle_panel Workspace_layout.Symbols "Symbols";

  (* Wire the sync closure: canvas.ml's dock_refresh calls this after
     any panel state change to keep the Window menu checkmarks
     truthful even when the change originated outside the menubar
     (right-click Close, layout restore, panel drag-out, etc.). *)
  _sync_panel_checks_ref := (fun () ->
    match workspace_layout with
    | Some layout ->
      _suppress_check_callback := true;
      Fun.protect
        ~finally:(fun () -> _suppress_check_callback := false)
      @@ fun () ->
      Hashtbl.iter (fun kind item ->
        let visible = Workspace_layout.is_panel_visible layout kind in
        if item#active <> visible then item#set_active visible
      ) panel_checks
    | None -> ());
  (* Also expose via the Yaml_panel_view hook so dock_panel (which
     can't depend on Menubar without a module cycle) can fire the
     sync after panel-menu Close. *)
  Yaml_panel_view.panel_check_sync_hook := sync_panel_checks;
  (* Wire the Layers-panel delete confirm to the SAME modal the main
     Delete/Cut use, closing over the main window. Yaml_panel_view can't
     name Menubar directly (Menubar already depends on it), so its panel
     delete consults this hook only when the orphan set is non-empty. *)
  Yaml_panel_view.confirm_delete_orphans_hook :=
    (fun n -> confirm_delete_orphans n parent);
  (* Symbols-panel hamburger-menu Delete confirm: the SAME modal, so the
     menu path and the footer-button path show identical reference-aware
     warnings (SYMBOLS.md section 8). *)
  Panel_menu.symbols_confirm_delete_hook :=
    (fun n -> confirm_delete_orphans n parent)
