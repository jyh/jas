(** Main window with floating pane layout (toolbar, canvas, dock).

    Each pane is absolutely positioned in a GtkFixed container with a
    title bar for dragging and shared border handles between snapped panes. *)

let title_bar_height = 20

(* Drag state *)
type drag_state =
  | No_drag
  | Pane_drag of { pane_id : int; off_x : float; off_y : float }
  | Border_drag of { snap_idx : int; mutable start_coord : float; is_vertical : bool }

let drag = ref No_drag
let snap_preview : Pane.snap_constraint list ref = ref []

(* ------------------------------------------------------------------ *)
(* Title bar                                                          *)
(* ------------------------------------------------------------------ *)

let make_title_bar ~dock_layout ~refresh_all ~pane_id ~kind ~(config : Pane.pane_config) () =
  let title_bar = GBin.event_box () in
  title_bar#misc#set_size_request ~height:title_bar_height ();
  let hbox = GPack.hbox ~packing:title_bar#add () in

  let _lbl = GMisc.label ~text:config.label
    ~packing:(hbox#pack ~expand:true ~fill:true) () in

  let close_btn = GButton.button ~label:"\xC3\x97" ~packing:(hbox#pack ~expand:false) () in
  close_btn#misc#set_size_request ~width:20 ~height:title_bar_height ();
  ignore (close_btn#connect#clicked ~callback:(fun () ->
    Dock.panes_mut dock_layout (fun pl -> Pane.hide_pane pl kind);
    refresh_all ()
  ));

  (* Title bar drag — mousedown starts pane drag *)
  title_bar#event#add [`BUTTON_PRESS];
  ignore (title_bar#event#connect#button_press ~callback:(fun ev ->
    if GdkEvent.get_type ev = `TWO_BUTTON_PRESS && config.double_click_action = Pane.Maximize then begin
      Dock.panes_mut dock_layout (fun pl -> Pane.toggle_canvas_maximized pl);
      refresh_all ();
      true
    end else begin
      let x = GdkEvent.Button.x_root ev in
      let y = GdkEvent.Button.y_root ev in
      (* Read current pane position for offset calculation *)
      let px, py = match Dock.panes dock_layout with
        | Some pl -> (match Pane.find_pane pl pane_id with
          | Some p -> (p.x, p.y)
          | None -> (0.0, 0.0))
        | None -> (0.0, 0.0)
      in
      drag := Pane_drag { pane_id; off_x = x -. px; off_y = y -. py };
      Dock.panes_mut dock_layout (fun pl -> Pane.bring_pane_to_front pl pane_id);
      refresh_all ();
      true
    end
  ));

  let css = new GObj.css_provider (GtkData.CssProvider.create ()) in
  css#load_from_data "* { background-color: #383838; color: #d9d9d9; font-size: 11px; padding: 0 4px; }";
  title_bar#misc#style_context#add_provider css 600;

  title_bar

(* ------------------------------------------------------------------ *)
(* Main window                                                        *)
(* ------------------------------------------------------------------ *)

let create_main_window ~get_model ~on_open () =
  let window = GWindow.window
    ~title:"Jas"
    ~width:1200 ~height:900
    () in
  window#connect#destroy ~callback:GMain.quit |> ignore;

  let vbox = GPack.vbox ~packing:window#add () in

  (* Dock layout *)
  let app_config = Dock.load_app_config () in
  let dock_layout = Dock.load_layout app_config.active_layout in
  Dock.ensure_pane_layout dock_layout ~viewport_w:1200.0 ~viewport_h:900.0;
  let dock_refresh = ref (fun () -> ()) in

  (* Menubar *)
  Menubar.create get_model window ~on_open
    ~dock_layout ~refresh_dock:(fun () -> !dock_refresh ()) vbox;

  (* Pane container: GtkFixed for absolute positioning *)
  let pane_container = GPack.fixed ~packing:(vbox#pack ~expand:true ~fill:true) () in
  pane_container#event#add [`POINTER_MOTION; `BUTTON_RELEASE];

  (* Create persistent pane frame widgets *)
  (* Toolbar pane *)
  let toolbar_frame = GPack.vbox () in
  let toolbar_title = ref (GBin.event_box ()) in
  let toolbar_fixed = GPack.fixed () in
  toolbar_frame#pack !toolbar_title#coerce ~expand:false;
  toolbar_frame#pack toolbar_fixed#coerce ~expand:true ~fill:true;

  (* Canvas pane *)
  let canvas_frame = GPack.vbox () in
  let canvas_title = ref (GBin.event_box ()) in
  let notebook = GPack.notebook () in
  canvas_frame#pack !canvas_title#coerce ~expand:false;
  canvas_frame#pack notebook#coerce ~expand:true ~fill:true;

  (* Dock pane *)
  let dock_frame = GPack.vbox () in
  let dock_title = ref (GBin.event_box ()) in
  let dock_box = GPack.vbox () in
  dock_frame#pack !dock_title#coerce ~expand:false;
  dock_frame#pack dock_box#coerce ~expand:true ~fill:true;

  (* Add frames to container (initially) *)
  pane_container#put toolbar_frame#coerce ~x:0 ~y:0;
  pane_container#put canvas_frame#coerce ~x:72 ~y:0;
  pane_container#put dock_frame#coerce ~x:760 ~y:0;

  (* Border handles and snap lines *)
  let border_handles : GBin.event_box list ref = ref [] in
  let snap_widgets : GMisc.drawing_area list ref = ref [] in

  let refresh_all () =
    let geos = match Dock.panes dock_layout with
      | None -> [] | Some pl -> Pane_rendering.pane_geometries pl
    in
    let borders = match Dock.panes dock_layout with
      | None -> [] | Some pl -> Pane_rendering.shared_borders pl
    in
    let maximized = match Dock.panes dock_layout with
      | Some pl -> pl.canvas_maximized | None -> false
    in

    (* Update pane positions and sizes *)
    List.iter (fun (geo : Pane_rendering.pane_geometry) ->
      let x = int_of_float geo.x in
      let y = int_of_float geo.y in
      let w = int_of_float geo.width in
      let h = int_of_float geo.height in
      match geo.kind with
      | Pane.Toolbar ->
        if geo.visible then begin
          toolbar_frame#misc#show ();
          pane_container#move toolbar_frame#coerce ~x ~y;
          toolbar_frame#misc#set_size_request ~width:w ~height:h ()
        end else
          toolbar_frame#misc#hide ()
      | Pane.Canvas ->
        canvas_frame#misc#show ();
        pane_container#move canvas_frame#coerce ~x ~y;
        canvas_frame#misc#set_size_request ~width:w ~height:h ();
        (* Hide/show title bar for maximized *)
        if maximized then !canvas_title#misc#hide ()
        else !canvas_title#misc#show ()
      | Pane.Dock ->
        if geo.visible then begin
          dock_frame#misc#show ();
          pane_container#move dock_frame#coerce ~x ~y;
          dock_frame#misc#set_size_request ~width:w ~height:h ()
        end else
          dock_frame#misc#hide ()
    ) geos;

    ignore geos; (* z-order handled by GtkFixed widget order *)

    (* Remove old border handles *)
    List.iter (fun w -> pane_container#remove w#coerce) !border_handles;
    border_handles := [];

    (* Add shared border handles *)
    List.iter (fun (b : Pane_rendering.shared_border) ->
      let handle = GBin.event_box () in
      handle#misc#set_size_request ~width:(int_of_float b.bw) ~height:(int_of_float b.bh) ();
      handle#event#add [`BUTTON_PRESS; `ENTER_NOTIFY; `LEAVE_NOTIFY];
      let cursor_type = if b.is_vertical then `SB_H_DOUBLE_ARROW else `SB_V_DOUBLE_ARROW in
      ignore (handle#event#connect#enter_notify ~callback:(fun _ ->
        let win = handle#misc#window in
        if Gobject.get_oid win <> 0 then
          Gdk.Window.set_cursor win (Gdk.Cursor.create cursor_type);
        false));
      ignore (handle#event#connect#leave_notify ~callback:(fun _ ->
        let win = handle#misc#window in
        if Gobject.get_oid win <> 0 then
          Gdk.Window.set_cursor win (Gdk.Cursor.create `LEFT_PTR);
        false));
      ignore (handle#event#connect#button_press ~callback:(fun ev ->
        let coord = if b.is_vertical then GdkEvent.Button.x_root ev else GdkEvent.Button.y_root ev in
        drag := Border_drag { snap_idx = b.snap_idx; start_coord = coord; is_vertical = b.is_vertical };
        true
      ));
      pane_container#put handle#coerce ~x:(int_of_float b.bx) ~y:(int_of_float b.by);
      handle#misc#show ();
      border_handles := handle :: !border_handles
    ) borders;

    (* Remove old snap lines *)
    List.iter (fun w -> pane_container#remove w#coerce) !snap_widgets;
    snap_widgets := [];

    (* Add snap preview lines *)
    (match Dock.panes dock_layout with
     | Some pl ->
       let lines = Pane_rendering.snap_lines !snap_preview pl in
       List.iter (fun (l : Pane_rendering.snap_line) ->
         let da = GMisc.drawing_area () in
         da#misc#set_size_request ~width:(int_of_float l.lw) ~height:(int_of_float l.lh) ();
         ignore (da#misc#connect#draw ~callback:(fun cr ->
           Cairo.set_source_rgba cr 0.196 0.471 0.863 0.8;
           Cairo.rectangle cr 0.0 0.0 ~w:l.lw ~h:l.lh;
           Cairo.fill cr;
           true
         ));
         pane_container#put da#coerce ~x:(int_of_float l.lx) ~y:(int_of_float l.ly);
         da#misc#show ();
         snap_widgets := da :: !snap_widgets
       ) lines
     | None -> ());

    (* Force redraw of the pane container to clear smeared artifacts *)
    pane_container#misc#queue_draw ();

    Dock.save_layout_if_needed dock_layout
  in

  (* Build title bars (must happen after refresh_all is defined) *)
  let rebuild_title_bars () =
    (* Remove old title bars *)
    let children = toolbar_frame#children in
    if List.length children > 0 then toolbar_frame#remove (List.hd children);
    let children = canvas_frame#children in
    if List.length children > 0 then canvas_frame#remove (List.hd children);
    let children = dock_frame#children in
    if List.length children > 0 then dock_frame#remove (List.hd children);

    let tpl = match Dock.panes dock_layout with Some pl -> Some pl | None -> None in
    let toolbar_id = match tpl with Some pl -> (match Pane.pane_by_kind pl Pane.Toolbar with Some p -> p.id | None -> 0) | None -> 0 in
    let canvas_id = match tpl with Some pl -> (match Pane.pane_by_kind pl Pane.Canvas with Some p -> p.id | None -> 1) | None -> 1 in
    let dock_id = match tpl with Some pl -> (match Pane.pane_by_kind pl Pane.Dock with Some p -> p.id | None -> 2) | None -> 2 in

    let tb = make_title_bar ~dock_layout ~refresh_all:(fun () -> !dock_refresh ())
      ~pane_id:toolbar_id ~kind:Pane.Toolbar ~config:(Pane.config_for_kind Pane.Toolbar) () in
    toolbar_title := tb;
    toolbar_frame#pack tb#coerce ~expand:false;
    toolbar_frame#reorder_child tb#coerce ~pos:0;

    let cb = make_title_bar ~dock_layout ~refresh_all:(fun () -> !dock_refresh ())
      ~pane_id:canvas_id ~kind:Pane.Canvas ~config:(Pane.config_for_kind Pane.Canvas) () in
    canvas_title := cb;
    canvas_frame#pack cb#coerce ~expand:false;
    canvas_frame#reorder_child cb#coerce ~pos:0;

    let db = make_title_bar ~dock_layout ~refresh_all:(fun () -> !dock_refresh ())
      ~pane_id:dock_id ~kind:Pane.Dock ~config:(Pane.config_for_kind Pane.Dock) () in
    dock_title := db;
    dock_frame#pack db#coerce ~expand:false;
    dock_frame#reorder_child db#coerce ~pos:0
  in
  rebuild_title_bars ();

  (* Initialize dock panel *)
  let dock_refresh_panel = Dock_panel.create dock_box dock_layout in
  dock_refresh := (fun () -> refresh_all (); dock_refresh_panel ());

  (* Mouse move handler *)
  ignore (pane_container#event#connect#motion_notify ~callback:(fun ev ->
    let mx = GdkEvent.Motion.x_root ev in
    let my = GdkEvent.Motion.y_root ev in
    (match !drag with
     | Pane_drag { pane_id; off_x; off_y } ->
       let new_x = mx -. off_x in
       let new_y = my -. off_y in
       Dock.panes_mut dock_layout (fun pl ->
         Pane.set_pane_position pl pane_id ~x:new_x ~y:new_y;
         let preview = Pane.detect_snaps pl ~dragged:pane_id
           ~viewport_w:pl.viewport_width ~viewport_h:pl.viewport_height in
         if preview <> [] then
           Pane.align_to_snaps pl pane_id ~snaps:preview
             ~viewport_w:pl.viewport_width ~viewport_h:pl.viewport_height;
         snap_preview := preview);
       refresh_all ()
     | Border_drag bd ->
       let current = if bd.is_vertical then mx else my in
       let delta = current -. bd.start_coord in
       bd.start_coord <- current;
       Dock.panes_mut dock_layout (fun pl ->
         Pane.drag_shared_border pl ~snap_idx:bd.snap_idx ~delta);
       refresh_all ()
     | No_drag -> ());
    true
  ));

  (* Mouse release handler *)
  ignore (pane_container#event#connect#button_release ~callback:(fun _ev ->
    (match !drag with
     | Pane_drag { pane_id; _ } ->
       let preview = !snap_preview in
       if preview <> [] then
         Dock.panes_mut dock_layout (fun pl ->
           Pane.apply_snaps pl pane_id ~new_snaps:preview
             ~viewport_w:pl.viewport_width ~viewport_h:pl.viewport_height);
       snap_preview := []
     | Border_drag _ -> ()
     | No_drag -> ());
    drag := No_drag;
    refresh_all ();
    true
  ));

  (* Viewport resize handler *)
  ignore (window#event#connect#configure ~callback:(fun ev ->
    let w = float_of_int (GdkEvent.Configure.width ev) in
    let h = float_of_int (GdkEvent.Configure.height ev) in
    Dock.panes_mut dock_layout (fun pl ->
      Pane.on_viewport_resize pl ~new_w:w ~new_h:h);
    refresh_all ();
    false
  ));

  let css = new GObj.css_provider (GtkData.CssProvider.create ()) in
  css#load_from_data "notebook, notebook header, notebook stack { background-color: #a0a0a0; }";
  notebook#misc#style_context#add_provider css 600;

  (* Initial layout *)
  refresh_all ();

  (window, toolbar_fixed, notebook, dock_box)
