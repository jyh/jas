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

  let dummy_model = Jas.Model.create () in
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
      active_canvas := Some c
    | _, _ ->
    match !notebook_ref, !toolbar_ref, !main_window_ref with
    | Some notebook, Some toolbar, Some main_window ->
      let controller = Jas.Controller.create ~model:new_model () in
      let on_focus () = active_model := new_model in
      let on_save () = Jas.Menubar.save new_model main_window () in
      let canvas = Jas.Canvas_subwindow.create
        ~model:new_model ~controller ~toolbar ~on_focus ~on_save notebook in
      active_model := new_model;
      active_canvas := Some canvas;
      all_canvases := canvas :: !all_canvases;
      (* Switch to the new tab *)
      let n = notebook#page_num canvas#widget in
      notebook#goto_page n
    | _ -> ()
  in

  let get_model () = !active_model in
  let get_fill_on_top () = match !toolbar_ref with Some t -> t#fill_on_top | None -> true in
  let main_window, toolbar_fixed, notebook, dock_box = Jas.Canvas.create_main_window ~get_model ~get_fill_on_top ~on_open:add_canvas () in
  main_window_ref := Some main_window;
  notebook_ref := Some notebook;
  let toolbar = Jas.Toolbar.create ~title:"Tools" ~x:0 ~y:0 ~get_model toolbar_fixed in
  toolbar_ref := Some toolbar;
  (* Tool to restore when spacebar pass-through to Hand releases.
     None when no Space-held pass-through is active. Per
     HAND_TOOL.md Spacebar pass-through. *)
  let prior_tool_for_spacebar : Jas.Toolbar.tool option ref = ref None in

  ignore dock_box; (* Dock panel is created inside create_main_window *)

  (* Update active model/canvas when switching tabs *)
  notebook#connect#switch_page ~callback:(fun page_num ->
    let page = notebook#get_nth_page page_num in
    (* Find the canvas whose widget matches this page *)
    ignore page  (* We track focus via on_focus callbacks on click *)
  ) |> ignore;

  (* Keyboard shortcuts: V = Selection, A = Partial Selection, \ = Line *)
  main_window#event#connect#key_press ~callback:(fun ev ->
    let key = GdkEvent.Key.keyval ev in
    (* If a tool is in an editing session (e.g. type tool), give it first
       chance at the full key event before any global shortcuts fire. *)
    let editing_handled = match !active_canvas with
      | Some c when c#tool_is_editing -> c#forward_key_event ev
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
    else if key = GdkKeysyms._v || key = GdkKeysyms._V then begin
      toolbar#select_tool Jas.Toolbar.Selection; true
    end else if key = GdkKeysyms._a || key = GdkKeysyms._A then begin
      toolbar#select_tool Jas.Toolbar.Partial_selection; true
    end else if key = GdkKeysyms._p || key = GdkKeysyms._P then begin
      toolbar#select_tool Jas.Toolbar.Pen; true
    end else if key = GdkKeysyms._plus || key = GdkKeysyms._equal then begin
      toolbar#select_tool Jas.Toolbar.Add_anchor_point; true
    end else if key = GdkKeysyms._minus || key = GdkKeysyms._underscore then begin
      toolbar#select_tool Jas.Toolbar.Delete_anchor_point; true
    end else if key = GdkKeysyms._t || key = GdkKeysyms._T then begin
      toolbar#select_tool Jas.Toolbar.Type_tool; true
    end else if key = GdkKeysyms._backslash then begin
      toolbar#select_tool Jas.Toolbar.Line; true
    end else if key = GdkKeysyms._m || key = GdkKeysyms._M then begin
      toolbar#select_tool Jas.Toolbar.Rect; true
    end else if key = GdkKeysyms._q || key = GdkKeysyms._Q then begin
      toolbar#select_tool Jas.Toolbar.Lasso; true
    end else if key = GdkKeysyms._n then begin
      toolbar#select_tool Jas.Toolbar.Pencil; true
    end else if key = GdkKeysyms._E then begin
      toolbar#select_tool Jas.Toolbar.Path_eraser; true
    end else if key = GdkKeysyms._h || key = GdkKeysyms._H then begin
      toolbar#select_tool Jas.Toolbar.Hand; true
    end else if key = GdkKeysyms._z && not (List.mem `CONTROL (GdkEvent.Key.state ev))
             && not (List.mem `META (GdkEvent.Key.state ev)) then begin
      (* Bare Z (without Ctrl/Cmd, which is undo) selects Zoom. *)
      toolbar#select_tool Jas.Toolbar.Zoom; true
    end else if key = GdkKeysyms._Z && not (List.mem `CONTROL (GdkEvent.Key.state ev))
             && not (List.mem `META (GdkEvent.Key.state ev))
             && not (List.mem `SHIFT (GdkEvent.Key.state ev)) then begin
      toolbar#select_tool Jas.Toolbar.Zoom; true
    end else if key = GdkKeysyms._space
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
    end else if key = GdkKeysyms._Delete || key = GdkKeysyms._BackSpace then begin
      let m = !active_model in
      let doc = m#document in
      if not (Jas.Document.PathMap.is_empty doc.Jas.Document.selection) then begin
        m#snapshot;
        m#set_document (Jas.Document.delete_selection doc)
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
      end else false
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

  (* Intercept window close to prompt for unsaved changes.
     Collects all modified models. If any exist, shows a dialog with
     Cancel / Don't Save / Save / Save All. Returns true from
     delete_event to block the close, false to allow it. *)
  main_window#event#connect#delete ~callback:(fun _ev ->
    let modified = List.filter (fun c -> c#model#is_modified) !all_canvases in
    if modified = [] then false
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
        cancelled  (* true = block close, false = allow *)
      | `ACCEPT ->
        (* Save: save only the active model *)
        let m = !active_model in
        if m#is_modified then begin
          Jas.Menubar.save m main_window ();
          m#is_modified  (* block if save was cancelled *)
        end else false
      | `REJECT -> false  (* Don't Save: allow close *)
      | _ -> true  (* Cancel: block close *)
    end
  ) |> ignore;

  main_window#show ();
  GMain.main ()
