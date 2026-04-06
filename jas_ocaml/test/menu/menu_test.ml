let run_test name f =
  f ();
  Printf.printf "  PASS: %s\n" name

let () =
  ignore (GMain.init ());
  Printf.printf "Menu tests:\n";

  run_test "menubar loads without error" (fun () ->
    let model = Jas.Model.create () in
    let _main_window, _toolbar_fixed, _notebook =
      Jas.Canvas.create_main_window ~get_model:(fun () -> model) ~on_open:(fun _ -> ()) () in
    ());

  Printf.printf "All menu tests passed.\n"
