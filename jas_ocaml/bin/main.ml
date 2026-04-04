let () =
  ignore (GMain.init ());
  let main_window, fixed = Jas.Canvas.create_main_window () in
  let toolbar = Jas.Toolbar.create ~title:"Tools" ~x:10 ~y:10 fixed in
  let model = Jas.Model.create () in
  let controller = Jas.Controller.create ~model () in
  let _canvas = Jas.Canvas_subwindow.create
    ~model ~controller ~toolbar ~x:100 ~y:50 ~width:820 ~height:640 fixed in

  (* Keyboard shortcuts: V = Selection, A = Direct Selection, \ = Line *)
  main_window#event#connect#key_press ~callback:(fun ev ->
    let key = GdkEvent.Key.keyval ev in
    if key = GdkKeysyms._v || key = GdkKeysyms._V then begin
      toolbar#select_tool Jas.Toolbar.Selection; true
    end else if key = GdkKeysyms._a || key = GdkKeysyms._A then begin
      toolbar#select_tool Jas.Toolbar.Direct_selection; true
    end else if key = GdkKeysyms._backslash then begin
      toolbar#select_tool Jas.Toolbar.Line; true
    end else if key = GdkKeysyms._m || key = GdkKeysyms._M then begin
      toolbar#select_tool Jas.Toolbar.Rect; true
    end else false
  ) |> ignore;

  main_window#show ();
  GMain.main ()
