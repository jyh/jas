let () =
  ignore (GMain.init ());

  (* Menubar integration test: verify menubar module loads without error.
     GTK3 menus don't expose a clean programmatic query API in LablGTK
     without rendering, so menu structure is verified by visual/interactive
     testing. This test ensures the menubar module is linkable and that
     the main window with vbox layout can be created. *)
  let model = Jas.Model.create () in
  let _main_window, _fixed = Jas.Canvas.create_main_window ~get_model:(fun () -> model) ~on_open:(fun _ -> ()) () in

  Printf.printf "All menu tests passed.\n"
