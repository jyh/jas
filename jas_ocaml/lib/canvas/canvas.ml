(** Main window with floating pane layout (toolbar, canvas, dock).

    Each pane is absolutely positioned in a GtkFixed container with a
    title bar for dragging and shared border handles between snapped panes. *)

let title_bar_height = 20

(* Drag state *)
type edge = Edge_left | Edge_right | Edge_top | Edge_bottom

type drag_state =
  | No_drag
  | Pane_drag of { pane_id : int; off_x : float; off_y : float }
  | Border_drag of { snap_idx : int; mutable start_coord : float; is_vertical : bool }
  | Edge_drag of { pane_id : int; edge : edge;
                   start_gx : float; start_gy : float;
                   start_x : float; start_y : float;
                   start_w : float; start_h : float }

let drag = ref No_drag
let snap_preview : Pane.snap_constraint list ref = ref []

(* ------------------------------------------------------------------ *)
(* Title bar                                                          *)
(* ------------------------------------------------------------------ *)

let make_title_bar ~workspace_layout ~refresh_all ~pane_id ~kind ~(config : Pane.pane_config) ~collapsed () =
  let title_bar = GBin.event_box () in
  title_bar#misc#set_size_request ~height:title_bar_height ();
  let hbox = GPack.hbox ~packing:title_bar#add () in

  (* Helper: clickable label (no GtkButton minimum size issues) *)
  let make_clickable_label text ~callback ~packing =
    let eb = GBin.event_box ~packing () in
    let lbl = GMisc.label ~text ~packing:eb#add () in
    let lbl_css = new GObj.css_provider (GtkData.CssProvider.create ()) in
    lbl_css#load_from_data (Printf.sprintf "* { color: %s; font-size: 11px; padding: 0 2px; background: transparent; }" !(Dock_panel.theme_text_button));
    lbl#misc#style_context#add_provider lbl_css 600;
    eb#event#add [`BUTTON_PRESS];
    ignore (eb#event#connect#button_press ~callback:(fun _ -> callback (); true))
  in

  (* Collapse chevron (only if pane has collapsed_width) *)
  (match config.collapsed_width with
   | Some _ ->
     let chevron = if collapsed then "\xC2\xBB" else "\xC2\xAB" in (* » or « *)
     make_clickable_label chevron ~packing:(hbox#pack ~expand:false) ~callback:(fun () ->
       (match Workspace_layout.anchored_dock workspace_layout Workspace_layout.Right with
        | Some d ->
          Workspace_layout.toggle_dock_collapsed workspace_layout d.id;
          let collapsed = (match Workspace_layout.anchored_dock workspace_layout Workspace_layout.Right with
            | Some d -> d.collapsed | None -> false) in
          Workspace_layout.panes_mut workspace_layout (fun pl ->
            let dock_pane = Pane.pane_by_kind pl Pane.Dock in
            let override = match dock_pane, collapsed with
              | Some p, true ->
                p.config <- { p.config with fixed_width = true };
                let cw = match p.config.collapsed_width with Some w -> w | None -> 32.0 in
                Some (p.id, cw)
              | Some p, false ->
                p.config <- { p.config with fixed_width = false };
                None
              | _ -> None in
            Pane.tile_panes pl ~collapsed_override:override)
        | None -> ());
       refresh_all ())
   | None -> ());

  if not collapsed then begin
    (* Spacer pushes close button to the right *)
    let spacer = GMisc.label ~text:"" ~packing:(hbox#pack ~expand:true ~fill:true) () in
    spacer#misc#set_size_request ~width:0 ();
    (* Close button *)
    make_clickable_label "\xC3\x97" ~packing:(hbox#pack ~expand:false) ~callback:(fun () ->
      Workspace_layout.panes_mut workspace_layout (fun pl -> Pane.hide_pane pl kind);
      refresh_all ())
  end;

  (* Title bar drag — mousedown starts pane drag *)
  title_bar#event#add [`BUTTON_PRESS];
  ignore (title_bar#event#connect#button_press ~callback:(fun ev ->
    if GdkEvent.get_type ev = `TWO_BUTTON_PRESS && config.double_click_action = Pane.Maximize then begin
      Workspace_layout.panes_mut workspace_layout (fun pl -> Pane.toggle_canvas_maximized pl);
      refresh_all ();
      true
    end else begin
      let x = GdkEvent.Button.x_root ev in
      let y = GdkEvent.Button.y_root ev in
      (* Read current pane position for offset calculation *)
      let px, py = match Workspace_layout.panes workspace_layout with
        | Some pl -> (match Pane.find_pane pl pane_id with
          | Some p -> (p.x, p.y)
          | None -> (0.0, 0.0))
        | None -> (0.0, 0.0)
      in
      drag := Pane_drag { pane_id; off_x = x -. px; off_y = y -. py };
      Workspace_layout.panes_mut workspace_layout (fun pl -> Pane.bring_pane_to_front pl pane_id);
      refresh_all ();
      true
    end
  ));

  let css = new GObj.css_provider (GtkData.CssProvider.create ()) in
  css#load_from_data (Printf.sprintf "box, * { background-color: %s; color: %s; font-size: 11px; margin: 0; }" !(Dock_panel.theme_bg_dark) !(Dock_panel.theme_text_dim));
  title_bar#misc#style_context#add_provider css 600;

  (title_bar, css)

let edge_handle_size = 6

let add_edge_handles ~pane_container ~pane_id ~workspace_layout ~drag ~refresh_all:(_refresh_all : unit -> unit) (_frame : GPack.box) =
  let edges = [Edge_left; Edge_right; Edge_top; Edge_bottom] in
  let handles = List.map (fun edge ->
    let eb = GBin.event_box () in
    eb#misc#set_size_request ~width:edge_handle_size ~height:edge_handle_size ();
    let cursor_type = match edge with
      | Edge_left | Edge_right -> `SB_H_DOUBLE_ARROW
      | Edge_top | Edge_bottom -> `SB_V_DOUBLE_ARROW
    in
    eb#event#add [`BUTTON_PRESS; `POINTER_MOTION; `BUTTON_RELEASE; `ENTER_NOTIFY; `LEAVE_NOTIFY];
    ignore (eb#event#connect#enter_notify ~callback:(fun _ ->
      let win = eb#misc#window in
      if Gobject.get_oid win <> 0 then
        Gdk.Window.set_cursor win (Gdk.Cursor.create cursor_type);
      false));
    ignore (eb#event#connect#leave_notify ~callback:(fun _ ->
      let win = eb#misc#window in
      if Gobject.get_oid win <> 0 then
        Gdk.Window.set_cursor win (Gdk.Cursor.create `LEFT_PTR);
      false));
    ignore (eb#event#connect#button_press ~callback:(fun ev ->
      let gx = GdkEvent.Button.x_root ev in
      let gy = GdkEvent.Button.y_root ev in
      (match Workspace_layout.panes workspace_layout with
       | Some pl ->
         (match Pane.find_pane pl pane_id with
          | Some p ->
            drag := Edge_drag { pane_id; edge;
                                start_gx = gx; start_gy = gy;
                                start_x = p.x; start_y = p.y;
                                start_w = p.width; start_h = p.height };
            GMain.Grab.add pane_container#coerce
          | None -> ())
       | None -> ());
      true));
    pane_container#put eb#coerce ~x:0 ~y:0;
    (edge, eb)
  ) edges in
  handles

let position_edge_handles handles ~x ~y ~w ~h =
  let es = edge_handle_size in
  List.iter (fun (edge, (eb : GBin.event_box)) ->
    let ex, ey, ew, eh = match edge with
      | Edge_left -> (x, y, es, h)
      | Edge_right -> (x + w - es, y, es, h)
      | Edge_top -> (x + es, y, w - 2 * es, es)
      | Edge_bottom -> (x + es, y + h - es, w - 2 * es, es)
    in
    let parent = eb#misc#parent in
    (match parent with
     | Some p ->
       (try
         let layout = new GPack.layout (Gobject.try_cast p#as_widget "GtkLayout") in
         layout#move eb#coerce ~x:ex ~y:ey
       with _ ->
         let fixed = new GPack.fixed (Gobject.try_cast p#as_widget "GtkFixed") in
         fixed#move eb#coerce ~x:ex ~y:ey)
     | None -> ());
    eb#misc#set_size_request ~width:(max 1 ew) ~height:(max 1 eh) ();
    eb#misc#show ()
  ) handles

(* ------------------------------------------------------------------ *)
(* Main window                                                        *)
(* ------------------------------------------------------------------ *)

let brand_icon_path size =
  let candidates = [
    Printf.sprintf "assets/brand/icons/icon_%d.png" size;
    Printf.sprintf "../assets/brand/icons/icon_%d.png" size;
    Filename.concat
      (Filename.concat (Filename.dirname Sys.executable_name) "..")
      (Printf.sprintf "assets/brand/icons/icon_%d.png" size);
  ] in
  List.find_opt Sys.file_exists candidates

let create_main_window ~get_model ~on_open () =
  let window = GWindow.window
    ~title:"Jas"
    ~width:1200 ~height:900
    () in
  window#connect#destroy ~callback:GMain.quit |> ignore;

  (* App window icon *)
  (match brand_icon_path 256 with
   | Some path ->
     (try window#set_icon (Some (GdkPixbuf.from_file path))
      with _ -> ())
   | None -> ());

  let vbox = GPack.vbox ~packing:window#add () in

  (* Dock layout *)
  let app_config = Workspace_layout.load_app_config () in
  let workspace_layout = Workspace_layout.load_or_migrate_workspace app_config in
  Workspace_layout.ensure_pane_layout workspace_layout ~viewport_w:1200.0 ~viewport_h:900.0;
  let dock_refresh = ref (fun () -> ()) in

  (* Menubar row: logo + menubar *)
  let menubar_row = GPack.hbox ~packing:(vbox#pack ~expand:false ~fill:false) () in
  let menubar_row_css = new GObj.css_provider (GtkData.CssProvider.create ()) in
  menubar_row_css#load_from_data (Printf.sprintf "box { background-color: %s; }" !(Dock_panel.theme_window_bg));
  menubar_row#misc#style_context#add_provider menubar_row_css 600;
  (match brand_icon_path 32 with
   | Some path ->
     (try
       let orig = GdkPixbuf.from_file path in
       let h = 32 in
       let w = h * (GdkPixbuf.get_width orig) / (GdkPixbuf.get_height orig) in
       let pb = GdkPixbuf.create ~width:w ~height:h
         ~bits:(GdkPixbuf.get_bits_per_sample orig)
         ~has_alpha:(GdkPixbuf.get_has_alpha orig) () in
       GdkPixbuf.scale ~dest:pb ~width:w ~height:h
         ~scale_x:(float_of_int w /. float_of_int (GdkPixbuf.get_width orig))
         ~scale_y:(float_of_int h /. float_of_int (GdkPixbuf.get_height orig))
         ~interp:`BILINEAR orig;
       let img = GMisc.image ~pixbuf:pb ~packing:(menubar_row#pack ~expand:false ~padding:4) () in
       ignore img
     with _ -> ())
   | None -> ());
  Menubar.create get_model window ~on_open
    ~workspace_layout ~app_config ~refresh_dock:(fun () -> !dock_refresh ())
    (menubar_row :> GPack.box);

  (* Pane container: GtkLayout for absolute positioning.
     Unlike GtkFixed, GtkLayout doesn't expand the window when
     children extend beyond its allocation. *)
  let pane_container = GPack.layout ~packing:(vbox#pack ~expand:true ~fill:true) () in
  pane_container#event#add [`POINTER_MOTION; `BUTTON_RELEASE];
  ignore (pane_container#misc#connect#draw ~callback:(fun cr ->
    let (r, g, b) = Theme.hex_to_rgb !(Dock_panel.theme_window_bg) in
    Cairo.set_source_rgb cr r g b;
    Cairo.paint cr;
    false  (* propagate to children *)
  ));
  let notebook_css_ref = ref (new GObj.css_provider (GtkData.CssProvider.create ())) in
  (* container_css_ref removed — viewport bg is painted via Cairo draw callback *)

  (* Toolbar pane *)
  let toolbar_frame = GPack.vbox () in
  let tb_border_css = new GObj.css_provider (GtkData.CssProvider.create ()) in
  tb_border_css#load_from_data (Printf.sprintf "box { background-color: %s; }" !(Dock_panel.theme_bg));
  toolbar_frame#misc#style_context#add_provider tb_border_css 600;
  let toolbar_title = ref (GBin.event_box ()) in
  let toolbar_title_css = ref (new GObj.css_provider (GtkData.CssProvider.create ())) in
  let toolbar_fixed = GPack.fixed () in
  toolbar_frame#pack !toolbar_title#coerce ~expand:false;
  toolbar_frame#pack toolbar_fixed#coerce ~expand:true ~fill:true;

  (* Canvas pane *)
  let canvas_frame = GPack.vbox () in
  let canvas_css = new GObj.css_provider (GtkData.CssProvider.create ()) in
  canvas_css#load_from_data (Printf.sprintf "box { background-color: %s; }" !(Dock_panel.theme_bg));
  canvas_frame#misc#style_context#add_provider canvas_css 600;
  let canvas_title = ref (GBin.event_box ()) in
  let canvas_title_css = ref (new GObj.css_provider (GtkData.CssProvider.create ())) in
  let notebook = GPack.notebook () in
  canvas_frame#pack !canvas_title#coerce ~expand:false;
  canvas_frame#pack notebook#coerce ~expand:true ~fill:true;

  (* Empty-state logo: draw brand mark in top-right when no tabs are open.
     Uses manual RGBA→ARGB32 conversion since Gdk.Cairo.set_source_pixbuf
     is not available in this version of lablgtk3. *)
  ignore (notebook#misc#connect#draw ~callback:(fun cr ->
    let no_pages = (try ignore (notebook#get_nth_page 0); false with _ -> true) in
    if no_pages then begin
      (match brand_icon_path 48 with
       | Some path ->
         (try
           let orig = GdkPixbuf.from_file path in
           let dw = 54 and dh = 24 in
           let pb = GdkPixbuf.create ~width:dw ~height:dh
             ~bits:(GdkPixbuf.get_bits_per_sample orig)
             ~has_alpha:(GdkPixbuf.get_has_alpha orig) () in
           GdkPixbuf.scale ~dest:pb ~width:dw ~height:dh
             ~scale_x:(float_of_int dw /. float_of_int (GdkPixbuf.get_width orig))
             ~scale_y:(float_of_int dh /. float_of_int (GdkPixbuf.get_height orig))
             ~interp:`BILINEAR orig;
           (* Convert GdkPixbuf RGBA bytes to Cairo ARGB32 surface *)
           let w = GdkPixbuf.get_width pb in
           let h = GdkPixbuf.get_height pb in
           let rowstride = GdkPixbuf.get_rowstride pb in
           let has_alpha = GdkPixbuf.get_has_alpha pb in
           let n_ch = GdkPixbuf.get_n_channels pb in
           let src = Gpointer.bytes_of_region (GdkPixbuf.get_pixels pb) in
           let stride = Cairo.Image.stride_for_width Cairo.Image.ARGB32 w in
           let data = Bigarray.Array1.create
             Bigarray.int8_unsigned Bigarray.c_layout (stride * h) in
           for y = 0 to h - 1 do
             for x = 0 to w - 1 do
               let si = y * rowstride + x * n_ch in
               let r = Char.code (Bytes.get src (si + 0)) in
               let g = Char.code (Bytes.get src (si + 1)) in
               let b = Char.code (Bytes.get src (si + 2)) in
               let a = if has_alpha then Char.code (Bytes.get src (si + 3)) else 255 in
               let rp = r * a / 255 in
               let gp = g * a / 255 in
               let bp = b * a / 255 in
               let di = y * stride + x * 4 in
               data.{di + 0} <- bp;
               data.{di + 1} <- gp;
               data.{di + 2} <- rp;
               data.{di + 3} <- a;
             done
           done;
           let surf = Cairo.Image.create_for_data8 data Cairo.Image.ARGB32 ~w ~h in
           let alloc = notebook#misc#allocation in
           let x = float_of_int (alloc.Gtk.width - dw - 10) in
           let y = 10.0 in
           Cairo.set_source_surface cr surf ~x ~y;
           Cairo.paint cr ~alpha:0.25
         with _ -> ())
       | None -> ())
    end;
    false
  ));

  (* Dock pane *)
  let dock_frame = GPack.vbox () in
  let dock_css = new GObj.css_provider (GtkData.CssProvider.create ()) in
  dock_css#load_from_data (Printf.sprintf "box { background-color: %s; }" !(Dock_panel.theme_bg));
  dock_frame#misc#style_context#add_provider dock_css 600;
  let dock_title = ref (GBin.event_box ()) in
  let dock_title_css = ref (new GObj.css_provider (GtkData.CssProvider.create ())) in
  let dock_box = GPack.vbox () in
  dock_frame#pack !dock_title#coerce ~expand:false;
  dock_frame#pack dock_box#coerce ~expand:true ~fill:true;

  (* Add frames to container — canvas first (back), then toolbar and dock (front).
     In GtkLayout, last-added draws on top, so this ensures toolbar and dock
     float above the canvas when it is maximized. *)
  pane_container#put canvas_frame#coerce ~x:72 ~y:0;
  pane_container#put toolbar_frame#coerce ~x:0 ~y:0;
  pane_container#put dock_frame#coerce ~x:760 ~y:0;

  (* Edge resize handles *)
  let pl_ids = match Workspace_layout.panes workspace_layout with Some pl -> pl | None ->
    Pane.default_three_pane ~viewport_w:1200.0 ~viewport_h:900.0 in
  let toolbar_id = (match Pane.pane_by_kind pl_ids Pane.Toolbar with Some p -> p.id | None -> 0) in
  let canvas_id = (match Pane.pane_by_kind pl_ids Pane.Canvas with Some p -> p.id | None -> 1) in
  let dock_id_pane = (match Pane.pane_by_kind pl_ids Pane.Dock with Some p -> p.id | None -> 2) in
  let toolbar_edges = add_edge_handles ~pane_container ~pane_id:toolbar_id ~workspace_layout ~drag ~refresh_all:(fun () -> !dock_refresh ()) toolbar_frame in
  let canvas_edges = add_edge_handles ~pane_container ~pane_id:canvas_id ~workspace_layout ~drag ~refresh_all:(fun () -> !dock_refresh ()) canvas_frame in
  let dock_edges = add_edge_handles ~pane_container ~pane_id:dock_id_pane ~workspace_layout ~drag ~refresh_all:(fun () -> !dock_refresh ()) dock_frame in

  (* Border handles and snap lines *)
  let border_handles : GBin.event_box list ref = ref [] in
  let snap_widgets : GMisc.drawing_area list ref = ref [] in

  let configure_guard = ref false in
  let refresh_all () =
    configure_guard := true;
    (* Re-apply theme CSS to all pane frames, notebook, container, and queue toolbar redraw *)
    let bg = !(Dock_panel.theme_bg) in
    tb_border_css#load_from_data (Printf.sprintf "box { background-color: %s; }" bg);
    canvas_css#load_from_data (Printf.sprintf "box { background-color: %s; }" bg);
    dock_css#load_from_data (Printf.sprintf "box { background-color: %s; }" bg);
    (!notebook_css_ref)#load_from_data (Printf.sprintf "notebook, notebook header, notebook stack { background-color: %s; }" bg);
    menubar_row_css#load_from_data (Printf.sprintf "box { background-color: %s; }" !(Dock_panel.theme_window_bg));
    let title_css_data = Printf.sprintf "box, * { background-color: %s; color: %s; font-size: 11px; margin: 0; }"
      !(Dock_panel.theme_bg_dark) !(Dock_panel.theme_text_dim) in
    (!toolbar_title_css)#load_from_data title_css_data;
    (!canvas_title_css)#load_from_data title_css_data;
    (!dock_title_css)#load_from_data title_css_data;
    pane_container#misc#queue_draw ();
    toolbar_fixed#misc#queue_draw ();
    let geos = match Workspace_layout.panes workspace_layout with
      | None -> [] | Some pl -> Pane_rendering.pane_geometries pl
    in
    let borders = match Workspace_layout.panes workspace_layout with
      | None -> [] | Some pl -> Pane_rendering.shared_borders pl
    in
    let maximized = match Workspace_layout.panes workspace_layout with
      | Some pl -> pl.canvas_maximized | None -> false
    in

    let set_size_if_changed (widget : #GObj.widget) ~width ~height =
      let alloc = widget#misc#allocation in
      if alloc.Gtk.width <> width || alloc.Gtk.height <> height then
        widget#misc#set_size_request ~width ~height ()
    in
    List.iter (fun (geo : Pane_rendering.pane_geometry) ->
      let x = int_of_float geo.x in
      let y = int_of_float geo.y in
      let w = max 1 (int_of_float geo.width) in
      let h = max 1 (int_of_float geo.height) in
      match geo.kind with
      | Pane.Toolbar ->
        if geo.visible then begin
          toolbar_frame#misc#show_all ();
          pane_container#move toolbar_frame#coerce ~x ~y;
          set_size_if_changed toolbar_frame ~width:w ~height:h;
          position_edge_handles toolbar_edges ~x ~y ~w ~h
        end else
          toolbar_frame#misc#hide ()
      | Pane.Canvas ->
        canvas_frame#misc#show ();
        pane_container#move canvas_frame#coerce ~x ~y;
        set_size_if_changed canvas_frame ~width:w ~height:h;
        position_edge_handles canvas_edges ~x ~y ~w ~h;
        (* Hide/show title bar for maximized *)
        if maximized then !canvas_title#misc#hide ()
        else !canvas_title#misc#show ()
      | Pane.Dock ->
        if geo.visible then begin
          dock_frame#misc#show ();
          pane_container#move dock_frame#coerce ~x ~y;
          set_size_if_changed dock_frame ~width:w ~height:h;
          position_edge_handles dock_edges ~x ~y ~w ~h;
        end else
          dock_frame#misc#hide ()
    ) geos;


    (* Remove old border handles *)
    List.iter (fun w -> pane_container#remove w#coerce) !border_handles;
    border_handles := [];

    (* Add shared border handles *)
    List.iter (fun (b : Pane_rendering.shared_border) ->
      let handle = GBin.event_box () in
      handle#misc#set_size_request ~width:(int_of_float b.bw) ~height:(int_of_float b.bh) ();
      handle#event#add [`BUTTON_PRESS; `ENTER_NOTIFY; `LEAVE_NOTIFY];
      let highlight_css = new GObj.css_provider (GtkData.CssProvider.create ()) in
      highlight_css#load_from_data "* { background-color: rgba(74, 144, 217, 0.5); }";
      let clear_css = new GObj.css_provider (GtkData.CssProvider.create ()) in
      clear_css#load_from_data "* { background-color: transparent; }";
      handle#misc#style_context#add_provider clear_css 600;
      let cursor_type = if b.is_vertical then `SB_H_DOUBLE_ARROW else `SB_V_DOUBLE_ARROW in
      ignore (handle#event#connect#enter_notify ~callback:(fun _ ->
        let win = handle#misc#window in
        if Gobject.get_oid win <> 0 then
          Gdk.Window.set_cursor win (Gdk.Cursor.create cursor_type);
        handle#misc#style_context#remove_provider clear_css;
        handle#misc#style_context#add_provider highlight_css 600;
        false));
      ignore (handle#event#connect#leave_notify ~callback:(fun _ ->
        let win = handle#misc#window in
        if Gobject.get_oid win <> 0 then
          Gdk.Window.set_cursor win (Gdk.Cursor.create `LEFT_PTR);
        handle#misc#style_context#remove_provider highlight_css;
        handle#misc#style_context#add_provider clear_css 600;
        false));
      ignore (handle#event#connect#button_press ~callback:(fun ev ->
        let coord = if b.is_vertical then GdkEvent.Button.x_root ev else GdkEvent.Button.y_root ev in
        drag := Border_drag { snap_idx = b.snap_idx; start_coord = coord; is_vertical = b.is_vertical };
        (* Grab so all motion/release events go to pane_container *)
        GMain.Grab.add pane_container#coerce;
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
    (match Workspace_layout.panes workspace_layout with
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

    Workspace_layout.save_layout_if_needed workspace_layout;
    (* Defer resetting the configure guard so configure events triggered
       by set_size_request during this refresh are suppressed. *)
    ignore (GMain.Idle.add (fun () -> configure_guard := false; false))
  in

  (* Build title bars (must happen after refresh_all is defined) *)
  let rebuild_title_bars () =
    (* Remove old title bars by widget reference *)
    toolbar_frame#remove !toolbar_title#coerce;
    canvas_frame#remove !canvas_title#coerce;
    dock_frame#remove !dock_title#coerce;

    let tpl = match Workspace_layout.panes workspace_layout with Some pl -> Some pl | None -> None in
    let toolbar_id = match tpl with Some pl -> (match Pane.pane_by_kind pl Pane.Toolbar with Some p -> p.id | None -> 0) | None -> 0 in
    let canvas_id = match tpl with Some pl -> (match Pane.pane_by_kind pl Pane.Canvas with Some p -> p.id | None -> 1) | None -> 1 in
    let dock_id = match tpl with Some pl -> (match Pane.pane_by_kind pl Pane.Dock with Some p -> p.id | None -> 2) | None -> 2 in

    let (tb, tb_css) = make_title_bar ~workspace_layout ~refresh_all:(fun () -> !dock_refresh ())
      ~pane_id:toolbar_id ~kind:Pane.Toolbar ~config:(Pane.config_for_kind Pane.Toolbar) ~collapsed:false () in
    toolbar_title := tb;
    toolbar_title_css := tb_css;
    toolbar_frame#pack tb#coerce ~expand:false;
    toolbar_frame#reorder_child tb#coerce ~pos:0;

    let (cb, cb_css) = make_title_bar ~workspace_layout ~refresh_all:(fun () -> !dock_refresh ())
      ~pane_id:canvas_id ~kind:Pane.Canvas ~config:(Pane.config_for_kind Pane.Canvas) ~collapsed:false () in
    canvas_title := cb;
    canvas_title_css := cb_css;
    canvas_frame#pack cb#coerce ~expand:false;
    canvas_frame#reorder_child cb#coerce ~pos:0;

    let dock_collapsed = match Workspace_layout.anchored_dock workspace_layout Workspace_layout.Right with
      | Some d -> d.collapsed | None -> false in
    let (db, db_css) = make_title_bar ~workspace_layout ~refresh_all:(fun () -> !dock_refresh ())
      ~pane_id:dock_id ~kind:Pane.Dock ~config:(Pane.config_for_kind Pane.Dock) ~collapsed:dock_collapsed () in
    dock_title := db;
    dock_title_css := db_css;
    dock_frame#pack db#coerce ~expand:false;
    dock_frame#reorder_child db#coerce ~pos:0
  in
  rebuild_title_bars ();

  (* Initialize dock panel *)
  let dock_refresh_panel = Dock_panel.create dock_box workspace_layout in
  dock_refresh := (fun () -> refresh_all (); dock_refresh_panel ());

  (* Mouse move handler *)
  ignore (pane_container#event#connect#motion_notify ~callback:(fun ev ->
    let mx = GdkEvent.Motion.x_root ev in
    let my = GdkEvent.Motion.y_root ev in
    (match !drag with
     | Pane_drag { pane_id; off_x; off_y } ->
       let new_x = mx -. off_x in
       let new_y = my -. off_y in
       Workspace_layout.panes_mut workspace_layout (fun pl ->
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
       Workspace_layout.panes_mut workspace_layout (fun pl ->
         Pane.drag_shared_border pl ~snap_idx:bd.snap_idx ~delta);
       refresh_all ()
     | Edge_drag ed ->
       let dx = mx -. ed.start_gx in
       let dy = my -. ed.start_gy in
       Workspace_layout.panes_mut workspace_layout (fun pl ->
         match Pane.find_pane pl ed.pane_id with
         | None -> ()
         | Some p ->
           let min_w = p.config.min_width in
           let min_h = p.config.min_height in
           (match ed.edge with
            | Edge_right ->
              p.width <- max (ed.start_w +. dx) min_w
            | Edge_left ->
              let new_w = max (ed.start_w -. dx) min_w in
              p.x <- ed.start_x +. ed.start_w -. new_w;
              p.width <- new_w
            | Edge_bottom ->
              p.height <- max (ed.start_h +. dy) min_h
            | Edge_top ->
              let new_h = max (ed.start_h -. dy) min_h in
              p.y <- ed.start_y +. ed.start_h -. new_h;
              p.height <- new_h));
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
         Workspace_layout.panes_mut workspace_layout (fun pl ->
           Pane.apply_snaps pl pane_id ~new_snaps:preview
             ~viewport_w:pl.viewport_width ~viewport_h:pl.viewport_height);
       snap_preview := []
     | Border_drag _ ->
       GMain.Grab.remove pane_container#coerce
     | Edge_drag _ ->
       GMain.Grab.remove pane_container#coerce
     | No_drag -> ());
    drag := No_drag;
    refresh_all ();
    true
  ));

  (* Viewport resize handler — use pane_container allocation (configure
     event reports bogus heights on macOS/GTK3). Re-entrancy is guarded
     by refresh_all's own flag. *)
  ignore (window#event#connect#configure ~callback:(fun _ev ->
    if not !configure_guard then begin
      configure_guard := true;
      let alloc = pane_container#misc#allocation in
      let w = float_of_int alloc.Gtk.width in
      let h = float_of_int alloc.Gtk.height in
      if w > 10.0 && h > 10.0 && w < 10000.0 && h < 10000.0 then begin
        pane_container#set_width (int_of_float w);
        pane_container#set_height (int_of_float h);
        Workspace_layout.panes_mut workspace_layout (fun pl ->
          Pane.on_viewport_resize pl ~new_w:w ~new_h:h;
          (* Re-tile with collapsed override if dock is collapsed *)
          let dock_collapsed = match Workspace_layout.anchored_dock workspace_layout Workspace_layout.Right with
            | Some d -> d.collapsed | None -> false in
          if dock_collapsed then
            let override = match Pane.pane_by_kind pl Pane.Dock with
              | Some p ->
                let cw = match p.config.collapsed_width with Some w -> w | None -> 32.0 in
                Some (p.id, cw)
              | None -> None in
            Pane.tile_panes pl ~collapsed_override:override);
        refresh_all ()
      end;
      ignore (GMain.Idle.add (fun () -> configure_guard := false; false))
    end;
    false
  ));

  let nb_css = !notebook_css_ref in
  nb_css#load_from_data (Printf.sprintf "notebook, notebook header, notebook stack { background-color: %s; }" !(Dock_panel.theme_bg));
  notebook#misc#style_context#add_provider nb_css 600;

  (* Initial layout — deferred until the window is mapped and has a
     valid size. Tile panes to fit the actual container and establish
     proper snap constraints. *)
  ignore (window#misc#connect#map ~callback:(fun () ->
    let alloc = pane_container#misc#allocation in
    let w = float_of_int alloc.Gtk.width in
    let h = float_of_int alloc.Gtk.height in
    if w > 10.0 && h > 10.0 then begin
      pane_container#set_width (int_of_float w);
      pane_container#set_height (int_of_float h);
      Workspace_layout.panes_mut workspace_layout (fun pl ->
        Pane.on_viewport_resize pl ~new_w:w ~new_h:h;
        Pane.repair_snaps pl ~viewport_w:w ~viewport_h:h)
    end;
    refresh_all ()
  ));

  (window, toolbar_fixed, notebook, dock_box)
