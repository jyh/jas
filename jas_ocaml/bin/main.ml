let () =
  ignore (GMain.init ());
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
  let main_window, toolbar_fixed, notebook, dock_box = Jas.Canvas.create_main_window ~get_model ~on_open:add_canvas () in
  main_window_ref := Some main_window;
  notebook_ref := Some notebook;
  let toolbar = Jas.Toolbar.create ~title:"Tools" ~x:0 ~y:0 ~get_model toolbar_fixed in
  toolbar_ref := Some toolbar;

  ignore dock_box; (* Dock panel is created inside create_main_window *)

  (* Update active model/canvas when switching tabs *)
  notebook#connect#switch_page ~callback:(fun page_num ->
    let page = notebook#get_nth_page page_num in
    (* Find the canvas whose widget matches this page *)
    ignore page  (* We track focus via on_focus callbacks on click *)
  ) |> ignore;

  (* Keyboard shortcuts: V = Selection, A = Direct Selection, \ = Line *)
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
      toolbar#select_tool Jas.Toolbar.Direct_selection; true
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
    end else if key = GdkKeysyms._Escape
             || key = GdkKeysyms._Return || key = GdkKeysyms._KP_Enter then begin
      (match !active_canvas with Some c -> c#pen_finish | None -> ());
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
