let () =
  ignore (GMain.init ());

  (* Install the brush library registry consulted by the canvas
     renderer when a path carries a stroke_brush slug. The registry
     is populated from the loaded workspace; absent / empty when
     workspace.json doesn't ship brush libraries. See BRUSHES.md. *)
  (match Jas.Workspace_loader.load () with
   | Some ws ->
     Jas.Canvas_subwindow.set_brush_libraries (Jas.Workspace_loader.brush_libraries ws)
   | None -> ());

  (* Install the recent_colors bridge: mirrors model.recent_colors
     into every registered panel.recent_colors after a Panel_menu
     push, so native Color Panel pushes flow into the Swatches Panel
     YAML state and YAML Swatches Panel pushes flow back into the
     Color Panel state. *)
  Jas.Yaml_panel_view.install_recent_colors_bridge ();

  (* Install the Paragraph panel hamburger menu's dialog opener.
     [Panel_menu] cannot import [Yaml_dialog_view] directly because
     [Yaml_panel_view] already routes through [Panel_menu]; this
     callback breaks the cycle. *)
  Jas.Panel_menu.register_dialog_opener (fun dlg_id ->
    match Jas.Yaml_dialog_view.open_dialog dlg_id [] [] with
    | Some ds -> Jas.Yaml_dialog_view.show_dialog ds
    | None -> ());

  (* Color panel's swatch double-click (and any other yaml caller
     that wants to open a dialog with params) routes through this
     hook. Yaml_panel_view can't reach Yaml_dialog_view directly
     without a module cycle. *)
  Jas.Yaml_panel_view.open_yaml_dialog_hook := (fun dlg_id raw_params ->
    match Jas.Yaml_dialog_view.open_dialog dlg_id raw_params [] with
    | Some ds -> Jas.Yaml_dialog_view.show_dialog ds
    | None -> ());

  (* Toolbar long-press tool-alternates flyout: a slot button's
     mouse_down -> start_timer -> open_dialog routes through this hook
     to pop the [modal: false] alternates dialog as a non-blocking
     flyout (distinct from the modal show_dialog above). Same
     cycle-avoidance rationale: Yaml_panel_view can't reach
     Yaml_dialog_view directly. *)
  Jas.Yaml_panel_view.open_nonmodal_dialog_hook := (fun dlg_id raw_params ->
    match Jas.Yaml_dialog_view.open_dialog dlg_id raw_params [] with
    | Some ds -> Jas.Yaml_dialog_view.show_nonmodal_dialog ds
    | None -> ());

  let dummy_model = Jas.Model.create () in
  (* On any document change, refresh the color panel's fill/stroke
     swatches + hex entry in-place (no body rebuild). The full
     panel rebuild caused a visible pulse on every selection
     change; the targeted update only touches the 3 widgets that
     actually depend on selection-driven state. *)
  dummy_model#on_document_changed (fun _ ->
    Jas.Yaml_panel_view.update_color_panel_widgets ());
  let active_model = ref dummy_model in
  let active_canvas = ref None in
  let all_canvases : Jas.Canvas_subwindow.canvas_subwindow list ref = ref [] in
  let notebook_ref = ref None in
  let toolbar_ref = ref None in

  let main_window_ref = ref None in

  let add_canvas new_model =
    (* If a canvas for this file already exists, focus it instead of
       opening a duplicate. Untitled documents are always unique. *)
    let existing = List.find_opt (fun (c : Jas.Canvas_subwindow.canvas_subwindow) ->
      c#model#filename = new_model#filename
      && not (Jas.Menubar.is_untitled c#model#filename)
    ) !all_canvases in
    match existing, !notebook_ref with
    | Some c, Some notebook ->
      let n = notebook#page_num c#widget in
      if n >= 0 then notebook#goto_page n;
      active_model := c#model;
      active_canvas := Some c;
      Jas.Yaml_panel_view.update_color_panel_widgets ()
    | _, _ ->
    match !notebook_ref, !toolbar_ref, !main_window_ref with
    | Some notebook, Some toolbar, Some main_window ->
      let controller = Jas.Controller.create ~model:new_model () in
      let on_focus () =
        active_model := new_model;
        Jas.Yaml_panel_view.paragraph_panel_resync_from_active_model ();
        Jas.Yaml_panel_view.update_color_panel_widgets ()
      in
      let on_save () = Jas.Menubar.save new_model main_window () in
      let canvas = Jas.Canvas_subwindow.create
        ~model:new_model ~controller ~toolbar ~on_focus ~on_save notebook in
      (* Refresh the Paragraph panel when this model's selection
         changes (PG-055). Safe no-op when no Paragraph panel is
         open. *)
      new_model#on_document_changed (fun _ ->
        Jas.Yaml_panel_view.paragraph_panel_resync_from_active_model ());
      (* Also refresh the color panel's fill/stroke + hex widgets
         in-place on every document change — targeted update
         instead of a full body rebuild so the user doesn't see a
         visible pulse on every selection change. *)
      new_model#on_document_changed (fun _ ->
        Jas.Yaml_panel_view.update_color_panel_widgets ());
      active_model := new_model;
      active_canvas := Some canvas;
      all_canvases := canvas :: !all_canvases;
      (* Switch to the new tab *)
      let n = notebook#page_num canvas#widget in
      notebook#goto_page n;
      (* Refresh the color panel's fill/stroke + hex from this
         canvas's initial selection. Model.create doesn't fire
         on_document_changed for the doc supplied via constructor,
         so session restore would otherwise leave the panel
         showing the previous model's colors (or defaults). *)
      Jas.Yaml_panel_view.update_color_panel_widgets ()
    | _ -> ()
  in

  let get_model () = !active_model in
  let get_fill_on_top () = match !toolbar_ref with Some t -> t#fill_on_top | None -> true in
  let main_window, toolbar_fixed, notebook, dock_box = Jas.Canvas.create_main_window ~get_model ~get_fill_on_top ~on_open:add_canvas () in
  main_window_ref := Some main_window;
  notebook_ref := Some notebook;
  let toolbar = Jas.Toolbar.create ~get_model () in
  toolbar_ref := Some toolbar;
  (* Read the active appearance's text color so YAML text labels
     (slider H/S/B/%/# captions etc.) re-skin when the user switches
     between Dark / Medium / Light Gray. Routed through a hook
     because Yaml_panel_view can't depend on Dock_panel without
     creating a cycle. *)
  Jas.Yaml_panel_view.theme_text_hook := (fun () -> !Jas.Dock_panel.theme_text);
  (* Dark background for the toolbar long-press tool-alternates flyout, so
     its #cccccc-tinted icons pop bright the way they do on the dark
     toolbar instead of reading gray on GTK's default light popup bg.
     Same hook pattern as theme_text_hook to avoid a renderer ↔ dock
     cycle. *)
  Jas.Yaml_panel_view.dialog_bg_hook := (fun () -> !Jas.Dock_panel.theme_bg_dark);
  (* Map an active_tool string to its native [Toolbar.tool]. Accepts BOTH the
     short ROUTING ids the bundle dispatches (the strings written by
     [set: { active_tool: ... }] in shortcuts.yaml / tool_alternates.yaml,
     e.g. [add_anchor]/[delete_anchor]/[type]) AND the longer tool-definition
     id aliases ([add_anchor_point]/[delete_anchor_point]/[type_tool]) the
     earlier code used. Carrying both fixes a PRE-EXISTING bug where the
     add/delete-anchor and type flyout buttons -- which dispatch the SHORT
     routing ids -- silently failed to switch tools, and lets the bundle-driven
     keyboard path (below) route through this same single mapping. *)
  let tool_of_name (name : string) : Jas.Toolbar.tool option =
    match name with
    | "selection" -> Some Jas.Toolbar.Selection
    | "partial_selection" -> Some Jas.Toolbar.Partial_selection
    | "interior_selection" -> Some Jas.Toolbar.Interior_selection
    | "magic_wand" -> Some Jas.Toolbar.Magic_wand
    | "pen" -> Some Jas.Toolbar.Pen
    | "add_anchor" | "add_anchor_point" -> Some Jas.Toolbar.Add_anchor_point
    | "delete_anchor" | "delete_anchor_point" -> Some Jas.Toolbar.Delete_anchor_point
    | "anchor_point" -> Some Jas.Toolbar.Anchor_point
    | "pencil" -> Some Jas.Toolbar.Pencil
    | "paintbrush" -> Some Jas.Toolbar.Paintbrush
    | "blob_brush" -> Some Jas.Toolbar.Blob_brush
    | "path_eraser" -> Some Jas.Toolbar.Path_eraser
    | "smooth" -> Some Jas.Toolbar.Smooth
    | "type" | "type_tool" -> Some Jas.Toolbar.Type_tool
    | "type_on_path" -> Some Jas.Toolbar.Type_on_path
    | "line" -> Some Jas.Toolbar.Line
    | "rect" -> Some Jas.Toolbar.Rect
    | "rounded_rect" -> Some Jas.Toolbar.Rounded_rect
    | "ellipse" -> Some Jas.Toolbar.Ellipse
    | "polygon" -> Some Jas.Toolbar.Polygon
    | "star" -> Some Jas.Toolbar.Star
    | "lasso" -> Some Jas.Toolbar.Lasso
    | "scale" -> Some Jas.Toolbar.Scale
    | "rotate" -> Some Jas.Toolbar.Rotate
    | "shear" -> Some Jas.Toolbar.Shear
    | "hand" -> Some Jas.Toolbar.Hand
    | "zoom" -> Some Jas.Toolbar.Zoom
    | "artboard" -> Some Jas.Toolbar.Artboard
    | "eyedropper" -> Some Jas.Toolbar.Eyedropper
    | _ -> None
  in
  (* Route YAML ``set: { active_tool: "<name>" }`` effects from
     dialog buttons through the toolbar. The color picker's
     eyedropper button sets active_tool="eyedropper" and dismisses
     the dialog; without this hook the set effect would write to a
     scratch store and the canvas tool wouldn't change. *)
  Jas.Yaml_panel_view.set_active_tool_hook := (fun name ->
    match tool_of_name name with
    | Some t -> toolbar#select_tool t
    | None -> ());

  (* ── Bundle-rendered toolbar (STEP A of the toolbar migration) ──
     Render the toolbar pane's [tool_grid] + fill/stroke widget from
     workspace.json via the generic [Yaml_panel_view] renderer, mirroring
     what Rust and Swift already do, instead of the hand-built native
     [Toolbar] GTK class. The native [toolbar] object is kept (the canvas
     and keyboard shortcuts still drive tool selection through it), but
     its widget is hidden and no longer mounted — STEP B will delete the
     class. Two-step keeps the change reversible. *)
  (* Map a native tool variant back to its workspace state string, so a
     tool change from ANY source (keyboard shortcut, spacebar Hand,
     toolbar click routed via set_active_tool_hook) updates the string
     the YAML [bind.checked] expressions read. *)
  let tool_to_name (t : Jas.Toolbar.tool) : string =
    match t with
    | Jas.Toolbar.Selection -> "selection"
    | Jas.Toolbar.Partial_selection -> "partial_selection"
    | Jas.Toolbar.Interior_selection -> "interior_selection"
    | Jas.Toolbar.Magic_wand -> "magic_wand"
    | Jas.Toolbar.Pen -> "pen"
    | Jas.Toolbar.Add_anchor_point -> "add_anchor"
    | Jas.Toolbar.Delete_anchor_point -> "delete_anchor"
    | Jas.Toolbar.Anchor_point -> "anchor_point"
    | Jas.Toolbar.Pencil -> "pencil"
    | Jas.Toolbar.Paintbrush -> "paintbrush"
    | Jas.Toolbar.Blob_brush -> "blob_brush"
    | Jas.Toolbar.Path_eraser -> "path_eraser"
    | Jas.Toolbar.Smooth -> "smooth"
    | Jas.Toolbar.Type_tool -> "type"
    | Jas.Toolbar.Type_on_path -> "type_on_path"
    | Jas.Toolbar.Line -> "line"
    | Jas.Toolbar.Rect -> "rect"
    | Jas.Toolbar.Rounded_rect -> "rounded_rect"
    | Jas.Toolbar.Ellipse -> "ellipse"
    | Jas.Toolbar.Polygon -> "polygon"
    | Jas.Toolbar.Star -> "star"
    | Jas.Toolbar.Lasso -> "lasso"
    | Jas.Toolbar.Scale -> "scale"
    | Jas.Toolbar.Rotate -> "rotate"
    | Jas.Toolbar.Shear -> "shear"
    | Jas.Toolbar.Hand -> "hand"
    | Jas.Toolbar.Zoom -> "zoom"
    | Jas.Toolbar.Artboard -> "artboard"
    | Jas.Toolbar.Eyedropper -> "eyedropper"
  in
  (* The native toolbar has no widget anymore — it is a plain tool-state
     controller (STEP B). Only the bundle toolbar is mounted below. *)
  (* Holder packed into the toolbar pane's GtkFixed at (0,0). Rebuilt in
     place by [rebuild_bundle_toolbar] so the highlight tracks the tool. *)
  let bundle_toolbar_holder = GPack.vbox () in
  toolbar_fixed#put bundle_toolbar_holder#coerce ~x:0 ~y:0;
  let rebuild_bundle_toolbar () =
    List.iter (fun w -> bundle_toolbar_holder#remove w)
      bundle_toolbar_holder#children;
    Jas.Yaml_panel_view.mount_toolbar
      ~packing:(bundle_toolbar_holder#pack ~expand:false ~fill:false)
      ~get_model:(fun () -> Some (get_model ())) ();
    bundle_toolbar_holder#misc#show_all ()
  in
  (* Every native tool change mirrors its string + rebuilds the toolbar
     so the bind.checked highlight re-evaluates. *)
  Jas.Toolbar.tool_changed_hook := (fun t ->
    let name = tool_to_name t in
    if !Jas.Yaml_panel_view.active_tool_name <> name then begin
      Jas.Yaml_panel_view.active_tool_name := name;
      rebuild_bundle_toolbar ()
    end);
  Jas.Yaml_panel_view.toolbar_rerender_hook := rebuild_bundle_toolbar;
  (* Seed the string from the toolbar's current tool, then render once. *)
  Jas.Yaml_panel_view.active_tool_name := tool_to_name toolbar#current_tool;
  rebuild_bundle_toolbar ();

  (* Tool to restore when spacebar pass-through to Hand releases.
     None when no Space-held pass-through is active. Per
     HAND_TOOL.md Spacebar pass-through. *)
  let prior_tool_for_spacebar : Jas.Toolbar.tool option ref = ref None in

  ignore dock_box; (* Dock panel is created inside create_main_window *)

  (* Restore the previous session's tabs (jas_dioxus / JasSwift do the
     same — see Session.swift). Each restored canvas re-enters via
     [add_canvas] so it's wired into the notebook + active_canvas
     bookkeeping the same way as freshly opened tabs. The active-tab
     pointer is honoured via a final [goto_page] after all tabs are
     loaded. *)
  let restored_active : int option ref = ref None in
  (match Jas.Session.load_session () with
   | None -> ()
   | Some (active_idx, tabs) ->
     restored_active := active_idx;
     (* Push the [Untitled-N] counter past any restored slot so the
        first File→New after restore picks an unused number rather
        than colliding with a restored tab. *)
     Jas.Model.advance_next_untitled_past
       (List.map (fun (fn, _) -> fn) tabs);
     List.iter (fun (filename, doc) ->
       let m = Jas.Model.create ~document:doc ~filename () in
       (* Model.create initializes saved_doc = document so is_modified
          starts false — restored content is considered saved-state
          (matches JasSwift / jas_dioxus). *)
       add_canvas m
     ) tabs;
     (* Switch to the restored active tab. Defaults to last-added if
        no active index. *)
     (match active_idx with
      | Some i when i >= 0 ->
        (try notebook#goto_page i with _ -> ())
      | _ -> ()));
  ignore !restored_active;

  (* Prune [all_canvases] when a tab is closed. The close-button
     handler in canvas_subwindow calls notebook#remove_page but has
     no reference to [all_canvases]; without this, persist_session
     would re-save the closed canvas's model and the tab would
     reappear after restart. *)
  notebook#connect#page_removed ~callback:(fun page _page_num ->
    all_canvases := List.filter (fun (c : Jas.Canvas_subwindow.canvas_subwindow) ->
      c#widget#misc#get_oid <> page#misc#get_oid
    ) !all_canvases
  ) |> ignore;

  (* Update active model/canvas when switching tabs. The per-canvas
     on_focus callback only fires when the canvas is clicked, which
     misses the case where the user switches tabs via the tab bar —
     the panel state (recent colors, fill/stroke, etc.) would keep
     showing the previous tab's model until the user clicked into
     the new tab's canvas. *)
  notebook#connect#switch_page ~callback:(fun page_num ->
    let page = notebook#get_nth_page page_num in
    match List.find_opt (fun (c : Jas.Canvas_subwindow.canvas_subwindow) ->
      c#widget#misc#get_oid = page#misc#get_oid
    ) !all_canvases with
    | Some c ->
      active_model := c#model;
      active_canvas := Some c;
      Jas.Yaml_panel_view.paragraph_panel_resync_from_active_model ();
      Jas.Yaml_panel_view.update_color_panel_widgets ()
    | None -> ()
  ) |> ignore;

  (* Keyboard shortcuts: V = Selection, A = Partial Selection, \ = Line *)
  main_window#event#connect#key_press ~callback:(fun ev ->
    let key = GdkEvent.Key.keyval ev in
    (* If a tool is in an editing session (e.g. type tool), give it first
       chance at the full key event before any global shortcuts fire. *)
    (* Skip routing to the canvas tool when a panel widget (entry,
       combo, etc.) has focus — typing should land in the focused
       widget, not in the active text-edit session. The canvas's
       drawing area only takes focus when clicked, so checking it via
       [canvas#has_focus] distinguishes "user clicked into a panel
       input" from "user is editing text on the canvas". *)
    let editing_handled = match !active_canvas with
      | Some c when c#tool_is_editing && c#canvas#has_focus ->
        c#forward_key_event ev
      | _ -> false
    in
    if editing_handled then true
    else
    (* Forward to active tool first (e.g. Space for anchor repositioning) *)
    let tool_handled = match !active_canvas with
      | Some c -> c#forward_key key
      | None -> false
    in
    if tool_handled then true
    (* Bare-letter tool shortcuts (V/A/P/M/N/etc.) must not fire when
       Ctrl or Cmd is held — those modifier combos are reserved for
       menu accelerators (Ctrl-N New, Ctrl-P Print, Ctrl-A Select All,
       Ctrl-V Paste, Ctrl-S Save). Without this guard the tool
       shortcut intercepts the keypress and the menu accelerator
       never sees it.

       Likewise, when a panel entry has focus (canvas does not), bare
       letter / minus / etc. keystrokes must reach the entry instead
       of switching tools — otherwise typing "-12" in a numeric input
       would activate the Delete-Anchor tool. *)
    else if List.mem `CONTROL (GdkEvent.Key.state ev)
         || List.mem `META (GdkEvent.Key.state ev) then false
    else if (
      (* Defer to a focused panel widget that takes text input
         (GtkEntry, GtkSpinButton, GtkTextView). Otherwise — including
         the no-focus case at app startup, or when focus is on the
         canvas / a button — the bare-letter shortcut runs. The C
         binding raises [Null_pointer] when no widget is focused;
         treat that as "no input is grabbing the keystroke". *)
      try
        let focused = GtkWindow.Window.get_focus main_window#as_window in
        let tname = Gobject.Type.name (Gobject.get_type focused) in
        tname = "GtkEntry" || tname = "GtkSpinButton" || tname = "GtkTextView"
      with _ -> false
    ) then false
    else if key = GdkKeysyms._space
             && not (List.mem `CONTROL (GdkEvent.Key.state ev))
             && not (List.mem `META (GdkEvent.Key.state ev)) then begin
      (* Spacebar pass-through to Hand. Save the current tool and
         switch to Hand for the duration of the hold. Per HAND_TOOL.md
         Spacebar pass-through. The matching keyup is below. *)
      if toolbar#current_tool <> Jas.Toolbar.Hand
         && !prior_tool_for_spacebar = None
      then begin
        prior_tool_for_spacebar := Some toolbar#current_tool;
        toolbar#select_tool Jas.Toolbar.Hand
      end;
      true
    end else if key = GdkKeysyms._Escape
             || key = GdkKeysyms._Return || key = GdkKeysyms._KP_Enter then begin
      (match !active_canvas with Some c -> c#pen_finish | None -> ());
      (* OPACITY.md section Preview interactions: Escape exits
         mask-isolation first (if active); otherwise exits
         mask-editing mode back to content-mode. *)
      if key = GdkKeysyms._Escape then begin
        let m = !active_model in
        if m#mask_isolation_path <> None then
          m#set_mask_isolation_path None
        else match m#editing_target with
          | Jas.Model.Mask _ -> m#set_editing_target Jas.Model.Content
          | Jas.Model.Content -> ()
      end;
      true
    end else if (key = GdkKeysyms._Delete || key = GdkKeysyms._BackSpace)
              && (match !active_canvas with
                  | Some c -> c#canvas#has_focus
                  | None -> true) then begin
      (* Delete-selection only fires when the canvas has focus —
         otherwise Backspace / Delete in a panel entry would also
         wipe the canvas selection. *)
      let m = !active_model in
      let doc = m#document in
      if not (Jas.Document.PathMap.is_empty doc.Jas.Document.selection) then begin
        (* Reference-aware delete (warn-then-orphan). The paths the
           delete will remove are exactly the [es_path] of each
           selection entry — the same set [delete_selection] folds over.
           [orphaned_references] is the shared, cross-language-pinned
           predicate (operand-opaque; excludes referrers being deleted);
           feed it those paths. *)
        let selection_paths =
          Jas.Document.PathMap.fold
            (fun _ (es : Jas.Document.element_selection) acc ->
              es.Jas.Document.es_path :: acc)
            doc.Jas.Document.selection [] in
        let orphaned =
          Jas.Dependency_index.orphaned_references doc selection_paths in
        let proceed =
          match orphaned with
          | [] -> true  (* No live reference orphaned: delete as today. *)
          | _ ->
            (* Some live references would be left empty: confirm first.
               Cancel aborts entirely (no snapshot, no delete). *)
            Jas.Menubar.confirm_delete_orphans (List.length orphaned) main_window
        in
        if proceed then begin
          (* OP_LOG.md section 9 Phase P4 — route the keyboard Delete through the
             SHARED [Jas.Op_apply.op_apply] dispatcher ([apply_delete_selection],
             the SAME [Document.delete_selection] body) so the gesture JOURNALS a
             real [delete_selection] op (one named undo step). The synchronous
             orphan confirm above IS the confirm path; only the mutation routes
             here. Mirrors the Swift [delete_orphan_confirm_ok] / Rust. *)
          let ctrl = Jas.Controller.create ~model:m () in
          m#with_txn (fun () ->
            m#name_txn "delete_orphan_confirm_ok";
            Jas.Op_apply.op_apply m ctrl
              (`Assoc [ ("op", `String "delete_selection") ]))
        end
      end;
      true
    end else begin
      let state = GdkEvent.Key.state ev in
      let has_ctrl = List.mem `CONTROL state in
      let has_shift = List.mem `SHIFT state in
      if has_ctrl && key = GdkKeysyms._z then begin
        (!active_model)#undo; true
      end else if has_ctrl && has_shift && key = GdkKeysyms._Z then begin
        (!active_model)#redo; true
      end else if has_ctrl && (key = GdkKeysyms._equal || key = GdkKeysyms._plus) then begin
        (* Ctrl/Cmd+= zooms in centered at viewport center. Per
           ZOOM_TOOL.md Keyboard shortcuts and actions. *)
        let m = !active_model in
        let z = m#zoom_level in
        let z_new = max 0.1 (min 64.0 (z *. 1.2)) in
        let cx = m#viewport_w /. 2.0 in
        let cy = m#viewport_h /. 2.0 in
        let doc_cx = (cx -. m#view_offset_x) /. z in
        let doc_cy = (cy -. m#view_offset_y) /. z in
        m#set_zoom_level z_new;
        m#set_view_offset_x (cx -. doc_cx *. z_new);
        m#set_view_offset_y (cy -. doc_cy *. z_new);
        true
      end else if has_ctrl && (key = GdkKeysyms._minus || key = GdkKeysyms._underscore) then begin
        let m = !active_model in
        let z = m#zoom_level in
        let z_new = max 0.1 (min 64.0 (z /. 1.2)) in
        let cx = m#viewport_w /. 2.0 in
        let cy = m#viewport_h /. 2.0 in
        let doc_cx = (cx -. m#view_offset_x) /. z in
        let doc_cy = (cy -. m#view_offset_y) /. z in
        m#set_zoom_level z_new;
        m#set_view_offset_x (cx -. doc_cx *. z_new);
        m#set_view_offset_y (cy -. doc_cy *. z_new);
        true
      end else if has_ctrl && key = GdkKeysyms._1 then begin
        (* Ctrl/Cmd+1 — zoom to actual size. *)
        (!active_model)#set_zoom_level 1.0;
        true
      end else if has_ctrl && key = GdkKeysyms._0 then begin
        (* Ctrl/Cmd+0 — fit active artboard. Cmd+Alt+0 fits all
           artboards (the union). *)
        let has_alt = List.mem `MOD1 state in
        let m = !active_model in
        let abs_list = m#document.Jas.Document.artboards in
        if has_alt && abs_list <> [] then begin
          let inf = infinity and neg_inf = neg_infinity in
          let min_x = ref inf in
          let min_y = ref inf in
          let max_x = ref neg_inf in
          let max_y = ref neg_inf in
          List.iter (fun ab ->
            let open Jas.Artboard in
            if ab.x < !min_x then min_x := ab.x;
            if ab.y < !min_y then min_y := ab.y;
            if ab.x +. ab.width > !max_x then max_x := ab.x +. ab.width;
            if ab.y +. ab.height > !max_y then max_y := ab.y +. ab.height
          ) abs_list;
          let bx = !min_x in
          let by = !min_y in
          let bw = !max_x -. !min_x in
          let bh = !max_y -. !min_y in
          let pad = 20.0 in
          let avail_w = m#viewport_w -. 2.0 *. pad in
          let avail_h = m#viewport_h -. 2.0 *. pad in
          if avail_w > 0.0 && avail_h > 0.0 && bw > 0.0 && bh > 0.0 then begin
            let z = max 0.1 (min 64.0 (min (avail_w /. bw) (avail_h /. bh))) in
            m#set_zoom_level z;
            m#set_view_offset_x (m#viewport_w /. 2.0 -. (bx +. bw /. 2.0) *. z);
            m#set_view_offset_y (m#viewport_h /. 2.0 -. (by +. bh /. 2.0) *. z)
          end
        end else begin
          match abs_list with
          | ab :: _ ->
            let open Jas.Artboard in
            let pad = 20.0 in
            let avail_w = m#viewport_w -. 2.0 *. pad in
            let avail_h = m#viewport_h -. 2.0 *. pad in
            if avail_w > 0.0 && avail_h > 0.0 && ab.width > 0.0 && ab.height > 0.0 then begin
              let z = max 0.1 (min 64.0 (min (avail_w /. ab.width) (avail_h /. ab.height))) in
              m#set_zoom_level z;
              m#set_view_offset_x (m#viewport_w /. 2.0 -. (ab.x +. ab.width /. 2.0) *. z);
              m#set_view_offset_y (m#viewport_h /. 2.0 -. (ab.y +. ab.height /. 2.0) *. z)
            end
          | [] -> ()
        end;
        true
      end else if not has_ctrl && (key = GdkKeysyms._d || key = GdkKeysyms._D) then begin
        (* Reset fill/stroke defaults *)
        toolbar#reset_defaults;
        true
      end else if not has_ctrl && not has_shift && key = GdkKeysyms._x then begin
        (* Toggle fill_on_top *)
        toolbar#toggle_fill_on_top;
        true
      end else if not has_ctrl && has_shift && key = GdkKeysyms._X then begin
        (* Swap fill and stroke colors *)
        toolbar#swap_fill_stroke;
        true
      end else begin
        (* ── Tool shortcuts (bundle-driven, TESTING_STRATEGY.md
           section 5 rec 3, Phase 2b) ──
           The hardcoded per-tool [GdkKeysyms] match arms were replaced by
           this single fallback: normalize the GTK key event into a
           framework-neutral [Key_resolver.chord] and resolve it against the
           shared bundle [shortcuts] table via [Key_resolver.resolve_key],
           the SAME pure resolver pinned cross-language by the key corpus.
           A [select_tool] result is dispatched through [tool_of_name] +
           [toolbar#select_tool] -- the SAME path the toolbar uses -- so one
           table now drives both the toolbar and the keyboard.

           This fallback is reached only AFTER every stateful / modal arm
           above (Space hand pass-through, Escape/Return, Delete/Backspace,
           and fill/stroke D/X/Shift+X) has had its chance, so those keep
           precedence. Ctrl/Meta chords never reach here -- the menu-modifier
           guard near the top of this handler returns [false] for them, so
           GTK menu accelerators (Ctrl+N etc.) stay authoritative.

           Token: a printable ASCII keyval equals its ASCII code, so it maps
           directly to its single-character token (GTK delivers the SHIFTED
           keyval, e.g. [_B] for Shift+b, which [canon_key] folds to the same
           uppercase letter while [shift] is carried separately). Anything
           outside printable ASCII (named keys etc.) has no tool binding and
           falls through unmatched. *)
        let alt = List.mem `MOD1 state in
        if key >= 0x20 && key <= 0x7e then begin
          let token = String.make 1 (Char.chr key) in
          let chord =
            Jas.Key_resolver.make_chord ~key:token
              ~ctrl:has_ctrl ~shift:has_shift ~alt ~meta:false () in
          match Jas.Key_resolver.resolve_key chord with
          | Some { Jas.Key_resolver.action = "select_tool"; params } ->
            (match List.assoc_opt "tool" params with
             | Some (`String tool_id) ->
               (match tool_of_name tool_id with
                | Some t -> toolbar#select_tool t; true
                | None -> false)
             | _ -> false)
          | _ -> false
        end else false
      end
    end
  ) |> ignore;

  main_window#event#connect#key_release ~callback:(fun ev ->
    let key = GdkEvent.Key.keyval ev in
    (* Spacebar pass-through restore: if a prior tool was saved on
       Space-down, restore it on Space-up. Per HAND_TOOL.md
       Spacebar pass-through. *)
    if key = GdkKeysyms._space then begin
      match !prior_tool_for_spacebar with
      | Some prior ->
        prior_tool_for_spacebar := None;
        toolbar#select_tool prior;
        true
      | None ->
        (match !active_canvas with
         | Some c -> c#forward_key_release key
         | None -> false)
    end else
    match !active_canvas with
    | Some c -> c#forward_key_release key
    | None -> false
  ) |> ignore;

  (* Persist the open canvases as a session blob so the next launch
     can restore them. Called both as a no-modified-tabs fast-path and
     after the unsaved-changes dialog allows the close. Tabs are
     written in notebook order so [active_index] stays stable. *)
  let persist_session () =
    (* notebook page order — all_canvases is reverse-of-open-order. *)
    let ordered =
      List.sort (fun (a : Jas.Canvas_subwindow.canvas_subwindow) b ->
        compare (notebook#page_num a#widget) (notebook#page_num b#widget))
        !all_canvases in
    let tabs = List.map (fun (c : Jas.Canvas_subwindow.canvas_subwindow) ->
      { Jas.Session.filename = c#model#filename;
        document = c#model#document })
      ordered in
    let active_index =
      let n = notebook#current_page in
      if n >= 0 then Some n else None in
    Jas.Session.save_session ~tabs ~active_index
  in

  (* SIGINT (Ctrl-C in the terminal) bypasses the GTK delete-event
     path entirely, so without this handler the session would be lost
     when the user kills the app from the launching shell. Save and
     exit. SIGTERM gets the same treatment so [kill PID] is also
     graceful. *)
  let handle_signal _ =
    persist_session ();
    exit 0
  in
  Sys.set_signal Sys.sigint (Sys.Signal_handle handle_signal);
  Sys.set_signal Sys.sigterm (Sys.Signal_handle handle_signal);

  (* Intercept window close to prompt for unsaved changes.
     Collects all modified models. If any exist, shows a dialog with
     Cancel / Don't Save / Save / Save All. Returns true from
     delete_event to block the close, false to allow it. *)
  main_window#event#connect#delete ~callback:(fun _ev ->
    let modified = List.filter (fun c -> c#model#is_modified) !all_canvases in
    if modified = [] then begin
      persist_session ();
      false
    end
    else begin
      let names = String.concat ", "
        (List.map (fun (c : Jas.Canvas_subwindow.canvas_subwindow) ->
          Printf.sprintf "\"%s\"" c#model#filename) modified) in
      let dialog = GWindow.dialog ~title:"Save Changes" ~modal:true ~parent:main_window () in
      dialog#add_button "Cancel" `CANCEL;
      dialog#add_button "Don't Save" `REJECT;
      dialog#add_button "Save" `ACCEPT;
      dialog#add_button "Save All" `YES;
      let label = GMisc.label
        ~text:(Printf.sprintf "Do you want to save changes to %s?" names)
        ~packing:dialog#vbox#add () in
      ignore label;
      let response = dialog#run () in
      dialog#destroy ();
      match response with
      | `YES ->
        (* Save All: save every modified model, abort if any save is cancelled *)
        let cancelled = List.exists (fun (c : Jas.Canvas_subwindow.canvas_subwindow) ->
          Jas.Menubar.save c#model main_window ();
          c#model#is_modified
        ) modified in
        if not cancelled then persist_session ();
        cancelled  (* true = block close, false = allow *)
      | `ACCEPT ->
        (* Save: save only the active model *)
        let m = !active_model in
        if m#is_modified then begin
          Jas.Menubar.save m main_window ();
          if m#is_modified then true  (* save cancelled, block close *)
          else begin persist_session (); false end
        end else begin persist_session (); false end
      | `REJECT -> persist_session (); false  (* Don't Save: allow close *)
      | _ -> true  (* Cancel: block close *)
    end
  ) |> ignore;

  main_window#show ();
  GMain.main ()
