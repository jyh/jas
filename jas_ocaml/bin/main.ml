let () =
  ignore (GMain.init ());
  let model = Jas.Model.create () in
  let active_model = ref model in
  let active_canvas = ref None in
  let fixed_ref = ref None in
  let toolbar_ref = ref None in

  let add_canvas new_model =
    match !fixed_ref, !toolbar_ref with
    | Some fixed, Some toolbar ->
      let controller = Jas.Controller.create ~model:new_model () in
      let on_focus () = active_model := new_model in
      let canvas = Jas.Canvas_subwindow.create
        ~model:new_model ~controller ~toolbar ~on_focus
        ~x:184 ~y:0 ~width:820 ~height:640 fixed in
      active_model := new_model;
      active_canvas := Some canvas
    | _ -> ()
  in

  let get_model () = !active_model in
  let main_window, fixed = Jas.Canvas.create_main_window ~get_model ~on_open:add_canvas () in
  fixed_ref := Some fixed;
  let toolbar = Jas.Toolbar.create ~title:"Tools" ~x:0 ~y:0 fixed in
  toolbar_ref := Some toolbar;
  let controller = Jas.Controller.create ~model () in
  let on_focus () = active_model := model in
  let canvas = Jas.Canvas_subwindow.create
    ~model ~controller ~toolbar ~on_focus
    ~x:84 ~y:0 ~width:820 ~height:640 fixed in
  active_canvas := Some canvas;

  (* Keyboard shortcuts: V = Selection, A = Direct Selection, \ = Line *)
  main_window#event#connect#key_press ~callback:(fun ev ->
    let key = GdkEvent.Key.keyval ev in
    if key = GdkKeysyms._v || key = GdkKeysyms._V then begin
      toolbar#select_tool Jas.Toolbar.Selection; true
    end else if key = GdkKeysyms._a || key = GdkKeysyms._A then begin
      toolbar#select_tool Jas.Toolbar.Direct_selection; true
    end else if key = GdkKeysyms._p || key = GdkKeysyms._P then begin
      toolbar#select_tool Jas.Toolbar.Pen; true
    end else if key = GdkKeysyms._t || key = GdkKeysyms._T then begin
      toolbar#select_tool Jas.Toolbar.Text_tool; true
    end else if key = GdkKeysyms._backslash then begin
      toolbar#select_tool Jas.Toolbar.Line; true
    end else if key = GdkKeysyms._m || key = GdkKeysyms._M then begin
      toolbar#select_tool Jas.Toolbar.Rect; true
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
      end else false
    end
  ) |> ignore;

  main_window#show ();
  GMain.main ()
