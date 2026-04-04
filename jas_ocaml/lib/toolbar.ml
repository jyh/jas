(** A floating toolbar subwindow embedded inside the workspace. *)

type tool = Selection | Direct_selection | Group_selection | Text_tool | Line | Rect | Polygon

let tool_button_size = 32
let title_bar_height = 24
let long_press_ms = 500

class toolbar ~title ~x ~y (fixed : GPack.fixed) =
  let frame = GBin.frame ~shadow_type:`ETCHED_IN () in
  let vbox = GPack.vbox ~packing:frame#add () in

  (* Title bar *)
  let title_bar = GMisc.drawing_area
    ~packing:(vbox#pack ~expand:false) () in
  let () = title_bar#misc#set_size_request ~height:title_bar_height () in

  (* Toolbar grid *)
  let grid = GPack.table ~rows:3 ~columns:2
    ~row_spacings:2 ~col_spacings:2
    ~packing:(vbox#pack ~expand:false) () in
  let selection_btn = GMisc.drawing_area () in
  let direct_btn = GMisc.drawing_area () in
  let text_btn = GMisc.drawing_area () in
  let line_btn = GMisc.drawing_area () in
  let shape_btn = GMisc.drawing_area () in
  let () =
    selection_btn#misc#set_size_request ~width:tool_button_size ~height:tool_button_size ();
    direct_btn#misc#set_size_request ~width:tool_button_size ~height:tool_button_size ();
    text_btn#misc#set_size_request ~width:tool_button_size ~height:tool_button_size ();
    line_btn#misc#set_size_request ~width:tool_button_size ~height:tool_button_size ();
    shape_btn#misc#set_size_request ~width:tool_button_size ~height:tool_button_size ();
    grid#attach ~left:0 ~top:0 selection_btn#coerce;
    grid#attach ~left:1 ~top:0 direct_btn#coerce;
    grid#attach ~left:0 ~top:1 text_btn#coerce;
    grid#attach ~left:0 ~top:2 line_btn#coerce;
    grid#attach ~left:1 ~top:2 shape_btn#coerce
  in
  object (self)
    val mutable pos_x = x
    val mutable pos_y = y
    val mutable current_tool = Selection
    val mutable arrow_slot_tool = Direct_selection
    val mutable shape_slot_tool = Rect
    val mutable dragging = false
    val mutable drag_offset_x = 0.0
    val mutable drag_offset_y = 0.0
    val mutable long_press_timer : GMain.Timeout.id option = None
    val mutable shape_long_press_timer : GMain.Timeout.id option = None

    method current_tool = current_tool
    method widget = frame#coerce
    method x = pos_x
    method y = pos_y

    method select_tool t =
      current_tool <- t;
      (match t with
       | Direct_selection | Group_selection ->
         arrow_slot_tool <- t
       | Rect | Polygon ->
         shape_slot_tool <- t
       | _ -> ());
      self#redraw_all

    method private redraw_all =
      selection_btn#misc#queue_draw ();
      direct_btn#misc#queue_draw ();
      line_btn#misc#queue_draw ();
      shape_btn#misc#queue_draw ()

    initializer
      fixed#put frame#coerce ~x:pos_x ~y:pos_y;
      frame#misc#set_size_request ~width:80 ~height:(title_bar_height + tool_button_size * 3 + 18) ();

      (* Draw title bar *)
      title_bar#misc#connect#draw ~callback:(fun cr ->
        let alloc = title_bar#misc#allocation in
        let w = float_of_int alloc.Gtk.width in
        let h = float_of_int alloc.Gtk.height in
        Cairo.set_source_rgb cr 0.6 0.6 0.6;
        Cairo.rectangle cr 0.0 0.0 ~w ~h;
        Cairo.fill cr;
        Cairo.set_source_rgb cr 0.0 0.0 0.0;
        Cairo.select_font_face cr "Sans";
        Cairo.set_font_size cr 11.0;
        let extents = Cairo.text_extents cr title in
        let tx = (w -. extents.Cairo.width) /. 2.0 in
        let ty = (h +. extents.Cairo.height) /. 2.0 in
        Cairo.move_to cr tx ty;
        Cairo.show_text cr title;
        true
      ) |> ignore;

      (* Draw tool buttons *)
      let draw_arrow cr ~filled ~alloc =
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        Cairo.move_to cr (ox +. 5.0) (oy +. 2.0);
        Cairo.line_to cr (ox +. 5.0) (oy +. 24.0);
        Cairo.line_to cr (ox +. 10.0) (oy +. 18.0);
        Cairo.line_to cr (ox +. 15.0) (oy +. 26.0);
        Cairo.line_to cr (ox +. 18.0) (oy +. 24.0);
        Cairo.line_to cr (ox +. 13.0) (oy +. 16.0);
        Cairo.line_to cr (ox +. 20.0) (oy +. 16.0);
        Cairo.Path.close cr;
        Cairo.set_source_rgb cr 0.8 0.8 0.8;
        if filled then
          Cairo.fill cr
        else begin
          Cairo.set_line_width cr 1.5;
          Cairo.stroke cr
        end
      in

      let draw_arrow_plus cr ~alloc =
        draw_arrow cr ~filled:false ~alloc;
        (* Draw '+' badge in lower-right *)
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        Cairo.set_source_rgb cr 0.8 0.8 0.8;
        Cairo.set_line_width cr 1.5;
        Cairo.move_to cr (ox +. 20.0) (oy +. 20.0);
        Cairo.line_to cr (ox +. 27.0) (oy +. 20.0);
        Cairo.stroke cr;
        Cairo.move_to cr (ox +. 23.5) (oy +. 16.5);
        Cairo.line_to cr (ox +. 23.5) (oy +. 23.5);
        Cairo.stroke cr
      in

      let draw_line_icon cr ~alloc =
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        Cairo.set_source_rgb cr 0.8 0.8 0.8;
        Cairo.set_line_width cr 2.0;
        Cairo.move_to cr (ox +. 4.0) (oy +. 24.0);
        Cairo.line_to cr (ox +. 24.0) (oy +. 4.0);
        Cairo.stroke cr
      in

      let draw_tool_button area tool_id draw_icon =
        area#misc#connect#draw ~callback:(fun cr ->
          let alloc = area#misc#allocation in
          let bw = float_of_int alloc.Gtk.width in
          let bh = float_of_int alloc.Gtk.height in
          if current_tool = tool_id then begin
            Cairo.set_source_rgb cr 0.4 0.4 0.4;
            Cairo.rectangle cr 0.0 0.0 ~w:bw ~h:bh;
            Cairo.fill cr
          end else begin
            Cairo.set_source_rgb cr 0.27 0.27 0.27;
            Cairo.rectangle cr 0.0 0.0 ~w:bw ~h:bh;
            Cairo.fill cr
          end;
          draw_icon cr ~alloc;
          true
        ) |> ignore
      in
      let draw_rect_icon cr ~alloc =
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        Cairo.set_source_rgb cr 0.8 0.8 0.8;
        Cairo.set_line_width cr 1.5;
        Cairo.rectangle cr (ox +. 4.0) (oy +. 6.0) ~w:20.0 ~h:16.0;
        Cairo.stroke cr
      in

      let draw_polygon_icon cr ~alloc =
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        let cx = ox +. 14.0 and cy = oy +. 14.0 in
        let r = 11.0 in
        let n = 6 in
        Cairo.set_source_rgb cr 0.8 0.8 0.8;
        Cairo.set_line_width cr 1.5;
        for i = 0 to n - 1 do
          let angle = -. Float.pi /. 2.0 +. 2.0 *. Float.pi *. float_of_int i /. float_of_int n in
          let px = cx +. r *. cos angle in
          let py = cy +. r *. sin angle in
          if i = 0 then Cairo.move_to cr px py
          else Cairo.line_to cr px py
        done;
        Cairo.Path.close cr;
        Cairo.stroke cr
      in

      (* The arrow slot draws whichever tool is currently in the slot *)
      let draw_arrow_slot cr ~alloc =
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        (* Highlight if current tool matches the slot tool *)
        if current_tool = arrow_slot_tool then begin
          Cairo.set_source_rgb cr 0.4 0.4 0.4;
          Cairo.rectangle cr 0.0 0.0 ~w:bw ~h:bh;
          Cairo.fill cr
        end else begin
          Cairo.set_source_rgb cr 0.27 0.27 0.27;
          Cairo.rectangle cr 0.0 0.0 ~w:bw ~h:bh;
          Cairo.fill cr
        end;
        (match arrow_slot_tool with
        | Direct_selection -> draw_arrow cr ~filled:false ~alloc
        | Group_selection -> draw_arrow_plus cr ~alloc
        | _ -> ());
        (* Small triangle in lower-right indicating alternates *)
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        let s = 5.0 in
        Cairo.move_to cr (ox +. 28.0) (oy +. 28.0);
        Cairo.line_to cr (ox +. 28.0 -. s) (oy +. 28.0);
        Cairo.line_to cr (ox +. 28.0) (oy +. 28.0 -. s);
        Cairo.Path.close cr;
        Cairo.set_source_rgb cr 0.8 0.8 0.8;
        Cairo.fill cr
      in

      let draw_text_icon cr ~alloc =
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        Cairo.set_source_rgb cr 0.8 0.8 0.8;
        Cairo.select_font_face cr "Sans" ~weight:Cairo.Bold;
        Cairo.set_font_size cr 20.0;
        Cairo.move_to cr (ox +. 7.0) (oy +. 22.0);
        Cairo.show_text cr "T"
      in

      draw_tool_button text_btn Text_tool draw_text_icon;
      draw_tool_button selection_btn Selection (draw_arrow ~filled:true);
      (* Arrow slot uses custom draw that checks arrow_slot_tool *)
      direct_btn#misc#connect#draw ~callback:(fun cr ->
        let alloc = direct_btn#misc#allocation in
        draw_arrow_slot cr ~alloc;
        true
      ) |> ignore;
      draw_tool_button line_btn Line draw_line_icon;
      (* Shape slot: draws rect or polygon depending on shape_slot_tool *)
      shape_btn#misc#connect#draw ~callback:(fun cr ->
        let alloc = shape_btn#misc#allocation in
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        if current_tool = shape_slot_tool then begin
          Cairo.set_source_rgb cr 0.4 0.4 0.4;
          Cairo.rectangle cr 0.0 0.0 ~w:bw ~h:bh;
          Cairo.fill cr
        end else begin
          Cairo.set_source_rgb cr 0.27 0.27 0.27;
          Cairo.rectangle cr 0.0 0.0 ~w:bw ~h:bh;
          Cairo.fill cr
        end;
        (match shape_slot_tool with
         | Rect -> draw_rect_icon cr ~alloc
         | Polygon -> draw_polygon_icon cr ~alloc
         | _ -> ());
        (* Alternate triangle *)
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        let s = 5.0 in
        Cairo.move_to cr (ox +. 28.0) (oy +. 28.0);
        Cairo.line_to cr (ox +. 28.0 -. s) (oy +. 28.0);
        Cairo.line_to cr (ox +. 28.0) (oy +. 28.0 -. s);
        Cairo.Path.close cr;
        Cairo.set_source_rgb cr 0.8 0.8 0.8;
        Cairo.fill cr;
        true
      ) |> ignore;

      (* Click events *)
      let connect_click area tool_id =
        area#event#add [`BUTTON_PRESS];
        area#event#connect#button_press ~callback:(fun ev ->
          if GdkEvent.Button.button ev = 1 then begin
            current_tool <- tool_id;
            self#redraw_all;
            true
          end else false
        ) |> ignore
      in
      connect_click selection_btn Selection;
      connect_click text_btn Text_tool;
      connect_click line_btn Line;

      (* Arrow slot: click selects, long press shows menu *)
      direct_btn#event#add [`BUTTON_PRESS; `BUTTON_RELEASE];
      direct_btn#event#connect#button_press ~callback:(fun ev ->
        if GdkEvent.Button.button ev = 1 then begin
          (* Start long press timer *)
          long_press_timer <- Some (GMain.Timeout.add ~ms:long_press_ms ~callback:(fun () ->
            long_press_timer <- None;
            self#show_arrow_slot_menu;
            false
          ));
          true
        end else false
      ) |> ignore;
      direct_btn#event#connect#button_release ~callback:(fun ev ->
        if GdkEvent.Button.button ev = 1 then begin
          (* Cancel long press — treat as normal click *)
          (match long_press_timer with
           | Some id -> GMain.Timeout.remove id; long_press_timer <- None
           | None -> ());
          current_tool <- arrow_slot_tool;
          self#redraw_all;
          true
        end else false
      ) |> ignore;

      (* Shape slot: click selects, long press shows menu *)
      shape_btn#event#add [`BUTTON_PRESS; `BUTTON_RELEASE];
      shape_btn#event#connect#button_press ~callback:(fun ev ->
        if GdkEvent.Button.button ev = 1 then begin
          shape_long_press_timer <- Some (GMain.Timeout.add ~ms:long_press_ms ~callback:(fun () ->
            shape_long_press_timer <- None;
            self#show_shape_slot_menu;
            false
          ));
          true
        end else false
      ) |> ignore;
      shape_btn#event#connect#button_release ~callback:(fun ev ->
        if GdkEvent.Button.button ev = 1 then begin
          (match shape_long_press_timer with
           | Some id -> GMain.Timeout.remove id; shape_long_press_timer <- None
           | None -> ());
          current_tool <- shape_slot_tool;
          self#redraw_all;
          true
        end else false
      ) |> ignore;

      (* Title bar drag *)
      title_bar#event#add [`BUTTON_PRESS; `BUTTON_RELEASE; `POINTER_MOTION];
      title_bar#event#connect#button_press ~callback:(fun ev ->
        if GdkEvent.Button.button ev = 1 then begin
          dragging <- true;
          drag_offset_x <- GdkEvent.Button.x ev;
          drag_offset_y <- GdkEvent.Button.y ev;
          true
        end else false
      ) |> ignore;
      title_bar#event#connect#button_release ~callback:(fun ev ->
        if GdkEvent.Button.button ev = 1 then begin
          dragging <- false;
          true
        end else false
      ) |> ignore;
      title_bar#event#connect#motion_notify ~callback:(fun ev ->
        if dragging then begin
          let mx = GdkEvent.Motion.x ev in
          let my = GdkEvent.Motion.y ev in
          let dx = int_of_float (mx -. drag_offset_x) in
          let dy = int_of_float (my -. drag_offset_y) in
          pos_x <- pos_x + dx;
          pos_y <- pos_y + dy;
          fixed#move frame#coerce ~x:pos_x ~y:pos_y;
          true
        end else false
      ) |> ignore

    method private show_arrow_slot_menu =
      let menu = GMenu.menu () in
      let add_item label tool =
        let item = GMenu.check_menu_item ~label ~packing:menu#append () in
        item#set_active (arrow_slot_tool = tool);
        item#connect#activate ~callback:(fun () ->
          arrow_slot_tool <- tool;
          current_tool <- tool;
          self#redraw_all
        ) |> ignore
      in
      add_item "Direct Selection" Direct_selection;
      add_item "Group Selection" Group_selection;
      menu#popup ~button:1 ~time:(GtkMain.Main.get_current_event_time ())

    method private show_shape_slot_menu =
      let menu = GMenu.menu () in
      let add_item label tool =
        let item = GMenu.check_menu_item ~label ~packing:menu#append () in
        item#set_active (shape_slot_tool = tool);
        item#connect#activate ~callback:(fun () ->
          shape_slot_tool <- tool;
          current_tool <- tool;
          self#redraw_all
        ) |> ignore
      in
      add_item "Rectangle" Rect;
      add_item "Polygon" Polygon;
      menu#popup ~button:1 ~time:(GtkMain.Main.get_current_event_time ())
  end

let create ~title ~x ~y fixed =
  new toolbar ~title ~x ~y fixed
