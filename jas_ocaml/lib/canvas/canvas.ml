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
  Dock.ensure_pane_layout dock_layout ~viewport_w:1200.0 ~viewport_h:900.0;
  let dock_refresh = ref (fun () -> ()) in

  (* Create menubar with dock references *)
  Menubar.create get_model window ~on_open
    ~dock_layout ~refresh_dock:(fun () -> !dock_refresh ()) vbox;

  (* Horizontal layout: toolbar | notebook | dock *)
  let hbox = GPack.hbox ~packing:(vbox#pack ~expand:true ~fill:true) () in
  let toolbar_fixed = GPack.fixed ~packing:(hbox#pack ~expand:false) () in
  let notebook = GPack.notebook ~packing:(hbox#pack ~expand:true ~fill:true) () in
  let dock_box = GPack.vbox ~packing:(hbox#pack ~expand:false) () in

  (* Apply pane widths *)
  let apply_pane_widths () =
    match Dock.panes dock_layout with
    | None -> ()
    | Some pl ->
      let toolbar_visible = Pane.is_pane_visible pl Pane.Toolbar in
      let dock_visible = Pane.is_pane_visible pl Pane.Dock in
      let maximized = pl.canvas_maximized in
      if maximized || not toolbar_visible then begin
        toolbar_fixed#misc#hide ()
      end else begin
        toolbar_fixed#misc#show ();
        let tw = (Option.get (Pane.pane_by_kind pl Pane.Toolbar)).Pane.width in
        toolbar_fixed#misc#set_size_request ~width:(int_of_float tw) ()
      end;
      if maximized || not dock_visible then begin
        dock_box#misc#hide ()
      end else begin
        dock_box#misc#show ();
        let dw = (Option.get (Pane.pane_by_kind pl Pane.Dock)).Pane.width in
        dock_box#misc#set_size_request ~width:(int_of_float dw) ()
      end
  in
  apply_pane_widths ();

  (* Initialize dock panel *)
  let refresh = Dock_panel.create dock_box dock_layout in
  let refresh_and_save () =
    apply_pane_widths ();
    refresh ();
    Dock.save_layout_if_needed dock_layout
  in
  dock_refresh := refresh_and_save;

  (* Viewport resize handler *)
  ignore (window#event#connect#configure ~callback:(fun ev ->
    let w = float_of_int (GdkEvent.Configure.width ev) in
    let h = float_of_int (GdkEvent.Configure.height ev) in
    Dock.panes_mut dock_layout (fun pl ->
      Pane.on_viewport_resize pl ~new_w:w ~new_h:h);
    apply_pane_widths ();
    false
  ));

  let css = new GObj.css_provider (GtkData.CssProvider.create ()) in
  css#load_from_data "notebook, notebook header, notebook stack { background-color: #a0a0a0; }";
  notebook#misc#style_context#add_provider css 600;

  (window, toolbar_fixed, notebook, dock_box)
