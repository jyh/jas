(** Main window with toolbar and tabbed canvas workspace. *)

let create_main_window ~get_model ~on_open () =
  let window = GWindow.window
    ~title:"Jas"
    ~width:1200 ~height:900
    () in
  window#connect#destroy ~callback:GMain.quit |> ignore;

  let vbox = GPack.vbox ~packing:window#add () in

  (* Dock layout + panel (created before menubar so menu can reference it) *)
  let app_config = Dock.load_app_config () in
  let dock_layout = Dock.load_layout app_config.active_layout in
  let dock_refresh = ref (fun () -> ()) in

  (* Create menubar with dock references *)
  Menubar.create get_model window ~on_open
    ~dock_layout ~refresh_dock:(fun () -> !dock_refresh ()) vbox;

  (* Horizontal layout: toolbar | notebook | dock *)
  let hbox = GPack.hbox ~packing:(vbox#pack ~expand:true ~fill:true) () in
  let toolbar_fixed = GPack.fixed ~packing:(hbox#pack ~expand:false) () in
  let notebook = GPack.notebook ~packing:(hbox#pack ~expand:true ~fill:true) () in
  let dock_box = GPack.vbox ~packing:(hbox#pack ~expand:false) () in

  (* Initialize dock panel *)
  let refresh = Dock_panel.create dock_box dock_layout in
  let refresh_and_save () = refresh (); Dock.save_layout_if_needed dock_layout in
  dock_refresh := refresh_and_save;

  let css = new GObj.css_provider (GtkData.CssProvider.create ()) in
  css#load_from_data "notebook, notebook header, notebook stack { background-color: #a0a0a0; }";
  notebook#misc#style_context#add_provider css 600;

  (window, toolbar_fixed, notebook, dock_box)
