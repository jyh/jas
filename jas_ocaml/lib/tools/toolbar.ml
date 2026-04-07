(** A floating toolbar subwindow embedded inside the workspace. *)

type tool = Selection | Direct_selection | Group_selection | Pen | Add_anchor_point | Delete_anchor_point | Pencil | Path_eraser | Smooth | Text_tool | Text_path | Line | Rect | Rounded_rect | Polygon | Star

let tool_button_size = 32
let title_bar_height = 24
let long_press_ms = Canvas_tool.long_press_ms

class toolbar ~title ~x ~y (fixed : GPack.fixed) =
  let frame = GBin.frame ~shadow_type:`ETCHED_IN () in
  let vbox = GPack.vbox ~packing:frame#add () in

  (* Title bar *)
  let title_bar = GMisc.drawing_area
    ~packing:(vbox#pack ~expand:false) () in
  let () = title_bar#misc#set_size_request ~height:title_bar_height () in

  (* Toolbar grid *)
  let grid = GPack.table ~rows:4 ~columns:2
    ~row_spacings:2 ~col_spacings:2
    ~packing:(vbox#pack ~expand:false) () in
  let selection_btn = GMisc.drawing_area () in
  let direct_btn = GMisc.drawing_area () in
  let pen_btn = GMisc.drawing_area () in
  let pencil_btn = GMisc.drawing_area () in
  let text_btn = GMisc.drawing_area () in
  let line_btn = GMisc.drawing_area () in
  let shape_btn = GMisc.drawing_area () in
  let () =
    selection_btn#misc#set_size_request ~width:tool_button_size ~height:tool_button_size ();
    direct_btn#misc#set_size_request ~width:tool_button_size ~height:tool_button_size ();
    pen_btn#misc#set_size_request ~width:tool_button_size ~height:tool_button_size ();
    pencil_btn#misc#set_size_request ~width:tool_button_size ~height:tool_button_size ();
    text_btn#misc#set_size_request ~width:tool_button_size ~height:tool_button_size ();
    line_btn#misc#set_size_request ~width:tool_button_size ~height:tool_button_size ();
    shape_btn#misc#set_size_request ~width:tool_button_size ~height:tool_button_size ();
    grid#attach ~left:0 ~top:0 selection_btn#coerce;
    grid#attach ~left:1 ~top:0 direct_btn#coerce;
    grid#attach ~left:0 ~top:1 pen_btn#coerce;
    grid#attach ~left:1 ~top:1 pencil_btn#coerce;
    grid#attach ~left:0 ~top:2 text_btn#coerce;
    grid#attach ~left:1 ~top:2 line_btn#coerce;
    grid#attach ~left:0 ~top:3 shape_btn#coerce
  in
  object (self)
    val mutable pos_x = x
    val mutable pos_y = y
    val mutable current_tool = Selection
    val mutable arrow_slot_tool = Direct_selection
    val mutable pen_slot_tool = Pen
    val mutable pencil_slot_tool = Pencil
    val mutable text_slot_tool = Text_tool
    val mutable shape_slot_tool = Rect
    val mutable dragging = false
    val mutable drag_offset_x = 0.0
    val mutable drag_offset_y = 0.0
    val mutable long_press_timer : GMain.Timeout.id option = None
    val mutable pen_long_press_timer : GMain.Timeout.id option = None
    val mutable pencil_long_press_timer : GMain.Timeout.id option = None
    val mutable text_long_press_timer : GMain.Timeout.id option = None
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
       | Pen | Add_anchor_point | Delete_anchor_point ->
         pen_slot_tool <- t
       | Pencil | Path_eraser | Smooth ->
         pencil_slot_tool <- t
       | Text_tool | Text_path ->
         text_slot_tool <- t
       | Rect | Rounded_rect | Polygon | Star ->
         shape_slot_tool <- t
       | _ -> ());
      self#redraw_all

    method private redraw_all =
      selection_btn#misc#queue_draw ();
      direct_btn#misc#queue_draw ();
      pen_btn#misc#queue_draw ();
      pencil_btn#misc#queue_draw ();
      text_btn#misc#queue_draw ();
      line_btn#misc#queue_draw ();
      shape_btn#misc#queue_draw ()

    initializer
      fixed#put frame#coerce ~x:pos_x ~y:pos_y;
      frame#misc#set_size_request ~width:80 ~height:(title_bar_height + tool_button_size * 4 + 24) ();

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
      let arrow_path cr ~alloc =
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
        Cairo.Path.close cr
      in

      (* Black arrow with white border *)
      let draw_selection_arrow cr ~alloc =
        arrow_path cr ~alloc;
        Cairo.set_source_rgb cr 0.0 0.0 0.0;
        Cairo.fill_preserve cr;
        Cairo.set_source_rgb cr 1.0 1.0 1.0;
        Cairo.set_line_width cr 1.0;
        Cairo.stroke cr
      in

      (* White arrow with black border *)
      let draw_direct_arrow cr ~alloc =
        arrow_path cr ~alloc;
        Cairo.set_source_rgb cr 1.0 1.0 1.0;
        Cairo.fill_preserve cr;
        Cairo.set_source_rgb cr 0.0 0.0 0.0;
        Cairo.set_line_width cr 1.0;
        Cairo.stroke cr
      in

      (* White arrow with black border + plus badge *)
      let draw_arrow_plus cr ~alloc =
        draw_direct_arrow cr ~alloc;
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        Cairo.set_source_rgb cr 0.0 0.0 0.0;
        Cairo.set_line_width cr 1.5;
        Cairo.move_to cr (ox +. 20.0) (oy +. 20.0);
        Cairo.line_to cr (ox +. 27.0) (oy +. 20.0);
        Cairo.stroke cr;
        Cairo.move_to cr (ox +. 23.5) (oy +. 16.5);
        Cairo.line_to cr (ox +. 23.5) (oy +. 23.5);
        Cairo.stroke cr
      in

      let draw_line_icon cr ~alloc =
        (* Line icon from SVG (viewBox 0 0 256 256), scaled to 28x28 *)
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        let s = 28.0 /. 256.0 in
        Cairo.save cr;
        Cairo.translate cr ox oy;
        Cairo.scale cr s s;
        Cairo.set_source_rgb cr 0.8 0.8 0.8;
        Cairo.set_line_width cr 8.0;
        Cairo.move_to cr 30.79 232.04;
        Cairo.line_to cr 231.78 31.05;
        Cairo.stroke cr;
        Cairo.restore cr
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

      let draw_rounded_rect_icon cr ~alloc =
        (* Rounded rect icon from SVG (viewBox 0 0 256 256), scaled to 28x28 *)
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        let s = 28.0 /. 256.0 in
        Cairo.save cr;
        Cairo.translate cr ox oy;
        Cairo.scale cr s s;
        Cairo.set_source_rgb cr 0.8 0.8 0.8;
        Cairo.set_line_width cr 8.0;
        let x = 23.33 and y = 58.26 in
        let w = 212.06 and h = 139.47 in
        let r = 30.0 in
        Cairo.move_to cr (x +. r) y;
        Cairo.line_to cr (x +. w -. r) y;
        Cairo.curve_to cr (x +. w) y (x +. w) y (x +. w) (y +. r);
        Cairo.line_to cr (x +. w) (y +. h -. r);
        Cairo.curve_to cr (x +. w) (y +. h) (x +. w) (y +. h) (x +. w -. r) (y +. h);
        Cairo.line_to cr (x +. r) (y +. h);
        Cairo.curve_to cr x (y +. h) x (y +. h) x (y +. h -. r);
        Cairo.line_to cr x (y +. r);
        Cairo.curve_to cr x y x y (x +. r) y;
        Cairo.Path.close cr;
        Cairo.stroke cr;
        Cairo.restore cr
      in

      let draw_star_icon cr ~alloc =
        (* Star icon from SVG (viewBox 0 0 256 256), scaled to 28x28 *)
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        let s = 28.0 /. 256.0 in
        Cairo.save cr;
        Cairo.translate cr ox oy;
        Cairo.scale cr s s;
        Cairo.set_source_rgb cr 0.8 0.8 0.8;
        Cairo.set_line_width cr 8.0;
        let pts = [
          (128.0, 50.18); (145.47, 103.95); (202.01, 103.95);
          (156.27, 137.18); (173.74, 190.95); (128.0, 157.72);
          (82.26, 190.95); (99.73, 137.18); (53.99, 103.95);
          (110.53, 103.95);
        ] in
        (match pts with
         | (fx, fy) :: rest ->
           Cairo.move_to cr fx fy;
           List.iter (fun (px, py) -> Cairo.line_to cr px py) rest;
           Cairo.Path.close cr;
           Cairo.stroke cr
         | [] -> ());
        Cairo.restore cr
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
        | Direct_selection -> draw_direct_arrow cr ~alloc
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

      let draw_text_path_icon cr ~alloc =
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        Cairo.set_source_rgb cr 0.8 0.8 0.8;
        Cairo.select_font_face cr "Sans" ~weight:Cairo.Bold;
        Cairo.set_font_size cr 16.0;
        Cairo.move_to cr (ox +. 2.0) (oy +. 18.0);
        Cairo.show_text cr "T";
        (* Wavy path *)
        Cairo.set_line_width cr 1.0;
        Cairo.move_to cr (ox +. 12.0) (oy +. 20.0);
        Cairo.curve_to cr (ox +. 16.0) (oy +. 8.0)
                          (ox +. 22.0) (oy +. 24.0)
                          (ox +. 26.0) (oy +. 12.0);
        Cairo.stroke cr
      in

      let draw_pen_icon cr ~alloc =
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        let s = 28.0 /. 256.0 in
        Cairo.save cr;
        Cairo.translate cr ox oy;
        Cairo.scale cr s s;
        Cairo.set_source_rgb cr 0.8 0.8 0.8;
        (* Outer path *)
        Cairo.move_to cr 163.07 190.51;
        Cairo.line_to cr 175.61 210.03;
        Cairo.line_to cr 84.93 255.99;
        Cairo.line_to cr 72.47 227.94;
        Cairo.curve_to cr 58.86 195.29 32.68 176.45 0.13 161.51;
        Cairo.line_to cr 0.0 4.58;
        Cairo.curve_to cr 0.0 2.38 2.8 (-0.28) 4.11 (-0.37);
        Cairo.curve_to cr 5.42 (-0.46) 8.07 0.08 9.42 0.97;
        Cairo.line_to cr 94.84 57.3;
        Cairo.line_to cr 143.22 89.45;
        Cairo.curve_to cr 135.93 124.03 139.17 161.04 163.08 190.51;
        Cairo.Path.close cr;
        (* Inner cutout (hole) *)
        Cairo.move_to cr 61.7 49.58;
        Cairo.line_to cr 23.48 24.2;
        Cairo.line_to cr 65.56 102.31;
        Cairo.curve_to cr 73.04 102.48 79.74 105.2 83.05 111.1;
        Cairo.curve_to cr 86.36 117.0 86.92 124.26 82.1 129.97;
        Cairo.curve_to cr 75.74 137.51 64.43 138.54 57.38 133.01;
        Cairo.curve_to cr 49.55 126.87 47.97 116.88 54.52 108.06;
        Cairo.line_to cr 12.09 30.4;
        Cairo.line_to cr 12.53 100.36;
        Cairo.line_to cr 12.24 154.67;
        Cairo.curve_to cr 37.86 166.32 59.12 182.87 73.77 206.51;
        Cairo.line_to cr 138.57 173.27;
        Cairo.curve_to cr 127.46 148.19 124.88 122.64 130.1 95.08;
        Cairo.line_to cr 61.7 49.58;
        Cairo.Path.close cr;
        Cairo.set_fill_rule cr Cairo.EVEN_ODD;
        Cairo.fill cr;
        Cairo.restore cr
      in

      let draw_add_anchor_point_icon cr ~alloc =
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        let s = 28.0 /. 256.0 in
        Cairo.save cr;
        Cairo.translate cr ox oy;
        Cairo.scale cr s s;
        Cairo.set_source_rgb cr 0.8 0.8 0.8;
        (* Outer nib path *)
        Cairo.move_to cr 170.82 209.27;
        Cairo.line_to cr 82.74 256.0;
        Cairo.line_to cr 71.75 230.69;
        Cairo.curve_to cr 60.04 197.72 31.98 175.62 0.51 162.2;
        Cairo.line_to cr 0.07 55.68;
        Cairo.line_to cr 0.0 7.02;
        Cairo.curve_to cr 0.0 5.03 0.62 2.32 1.66 1.26;
        Cairo.curve_to cr 2.7 0.2 6.93 (-0.46) 8.2 0.39;
        Cairo.line_to cr 138.64 88.51;
        Cairo.curve_to cr 133.74 121.05 134.34 154.96 153.1 182.9;
        Cairo.line_to cr 170.8 209.29;
        Cairo.Path.close cr;
        (* Inner cutout (hole) *)
        Cairo.move_to cr 126.44 94.04;
        Cairo.line_to cr 22.84 24.64;
        Cairo.line_to cr 64.53 103.04;
        Cairo.curve_to cr 72.96 102.18 78.79 106.55 81.68 113.38;
        Cairo.curve_to cr 84.57 120.21 83.22 127.73 76.64 132.26;
        Cairo.curve_to cr 68.89 137.62 59.69 137.18 53.59 130.52;
        Cairo.curve_to cr 47.97 124.39 48.07 116.05 53.28 108.03;
        Cairo.line_to cr 11.47 30.27;
        Cairo.line_to cr 12.07 155.27;
        Cairo.line_to cr 12.07 155.27;
        Cairo.curve_to cr 37.97 166.4 57.82 183.53 72.2 206.35;
        Cairo.line_to cr 135.06 172.9;
        Cairo.curve_to cr 127.76 157.48 124.47 142.76 123.95 126.67;
        Cairo.curve_to cr 123.54 115.97 124.21 105.79 126.42 94.03;
        Cairo.Path.close cr;
        Cairo.set_fill_rule cr Cairo.EVEN_ODD;
        Cairo.fill cr;
        (* Plus sign *)
        Cairo.move_to cr 232.87 153.61;
        Cairo.curve_to cr 229.4 156.72 224.13 159.41 219.01 161.41;
        Cairo.line_to cr 200.67 127.38;
        Cairo.line_to cr 166.99 145.47;
        Cairo.line_to cr 159.35 132.09;
        Cairo.line_to cr 193.51 113.89;
        Cairo.line_to cr 175.05 78.74;
        Cairo.line_to cr 188.64 71.1;
        Cairo.line_to cr 207.47 106.52;
        Cairo.line_to cr 240.85 88.53;
        Cairo.line_to cr 248.17 101.98;
        Cairo.line_to cr 214.87 120.12;
        Cairo.line_to cr 232.86 153.58;
        Cairo.Path.close cr;
        Cairo.fill cr;
        Cairo.restore cr
      in

      let draw_delete_anchor_point_icon cr ~alloc =
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        let s = 28.0 /. 256.0 in
        Cairo.save cr;
        Cairo.translate cr ox oy;
        Cairo.scale cr s s;
        Cairo.set_source_rgb cr 0.8 0.8 0.8;
        (* Outer nib path *)
        Cairo.move_to cr 171.16 209.05;
        Cairo.line_to cr 83.32 256.0;
        Cairo.curve_to cr 79.37 247.74 75.66 239.67 72.34 231.11;
        Cairo.curve_to cr 58.84 196.29 34.83 177.34 0.8 161.2;
        Cairo.line_to cr 0.4 106.59;
        Cairo.line_to cr 0.0 6.21;
        Cairo.curve_to cr 0.0 3.95 2.53 0.66 4.05 0.16;
        Cairo.curve_to cr 5.57 (-0.34) 8.47 0.37 10.38 1.67;
        Cairo.line_to cr 138.0 87.83;
        Cairo.curve_to cr 137.83 93.34 137.19 98.26 136.44 104.0;
        Cairo.curve_to cr 133.14 129.08 137.75 154.95 149.25 177.57;
        Cairo.line_to cr 171.15 209.05;
        Cairo.Path.close cr;
        (* Inner cutout *)
        Cairo.move_to cr 126.23 94.28;
        Cairo.line_to cr 23.74 25.13;
        Cairo.line_to cr 64.38 101.36;
        Cairo.curve_to cr 59.16 109.38 59.07 117.72 64.69 123.85;
        Cairo.curve_to cr 70.79 130.51 79.99 130.95 87.74 124.59;
        Cairo.curve_to cr 94.31 120.05 95.58 112.34 92.78 105.71;
        Cairo.curve_to cr 90.23 99.59 83.64 94.52 75.2 95.38;
        Cairo.line_to cr 23.73 25.13;
        Cairo.line_to cr 126.23 94.28;
        Cairo.Path.close cr;
        Cairo.set_fill_rule cr Cairo.EVEN_ODD;
        Cairo.fill cr;
        (* Minus sign (rotated rectangle) *)
        Cairo.save cr;
        Cairo.translate cr (-31.37) 110.38;
        Cairo.rotate cr (-28.0 *. Float.pi /. 180.0);
        Cairo.rectangle cr 158.95 110.41 ~w:93.43 ~h:15.36;
        Cairo.fill cr;
        Cairo.restore cr;
        Cairo.restore cr
      in

      let draw_pencil_icon cr ~alloc =
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        let s = 28.0 /. 256.0 in
        Cairo.save cr;
        Cairo.translate cr ox oy;
        Cairo.scale cr s s;
        Cairo.set_source_rgb cr 0.8 0.8 0.8;
        (* Outer path (main outline) *)
        Cairo.move_to cr 57.6 233.77;
        Cairo.line_to cr 5.83 255.77;
        Cairo.curve_to cr 2.04 257.38 (-0.59) 250.2 0.12 246.99;
        Cairo.line_to cr 15.75 175.88;
        Cairo.curve_to cr 16.99 170.25 17.94 166.36 21.83 161.79;
        Cairo.line_to cr 108.97 59.4;
        Cairo.line_to cr 152.73 9.16;
        Cairo.curve_to cr 159.64 1.23 172.84 (-3.41) 181.96 3.06;
        Cairo.curve_to cr 195.07 12.36 206.14 22.95 217.94 33.93;
        Cairo.curve_to cr 225.32 40.79 226.65 54.5 220.25 62.13;
        Cairo.line_to cr 191.96 95.82;
        Cairo.line_to cr 84.39 222.9;
        Cairo.curve_to cr 75.27 227.22 66.72 229.9 57.6 233.78;
        Cairo.Path.close cr;
        Cairo.fill cr;
        (* Gray facets *)
        Cairo.set_source_rgb cr 0.235 0.235 0.235;
        Cairo.move_to cr 208.57 55.33;
        Cairo.curve_to cr 212.62 47.93 207.38 40.51 202.08 36.15;
        Cairo.line_to cr 177.08 15.57;
        Cairo.curve_to cr 166.42 6.79 154.72 26.62 149.01 33.89;
        Cairo.curve_to cr 163.45 47.79 177.29 60.62 193.41 72.64;
        Cairo.curve_to cr 199.05 66.99 204.86 62.09 208.57 55.33;
        Cairo.Path.close cr;
        Cairo.fill cr;
        Cairo.move_to cr 70.01 189.48;
        Cairo.curve_to cr 64.87 189.83 59.66 190.72 56.07 188.36;
        Cairo.curve_to cr 53.24 186.5 52.14 178.64 53.23 174.8;
        Cairo.line_to cr 154.47 55.84;
        Cairo.curve_to cr 160.42 60.73 165.14 64.9 170.13 70.41;
        Cairo.line_to cr 70.01 189.48;
        Cairo.Path.close cr;
        Cairo.fill cr;
        Cairo.move_to cr 47.55 169.12;
        Cairo.curve_to cr 43.7 170.57 37.83 169.44 34.86 166.85;
        Cairo.line_to cr 76.41 117.48;
        Cairo.line_to cr 108.97 79.49;
        Cairo.line_to cr 138.8 44.51;
        Cairo.curve_to cr 142.42 44.61 145.79 48.23 147.44 51.6;
        Cairo.line_to cr 102.14 104.57;
        Cairo.line_to cr 47.55 169.11;
        Cairo.Path.close cr;
        Cairo.fill cr;
        Cairo.move_to cr 161.36 111.12;
        Cairo.line_to cr 93.27 191.72;
        Cairo.curve_to cr 88.75 197.06 84.94 201.71 79.55 206.85;
        Cairo.curve_to cr 76.45 203.48 74.45 196.7 78.52 191.88;
        Cairo.line_to cr 176.03 76.63;
        Cairo.curve_to cr 179.47 77.08 184.55 80.31 184.28 83.19;
        Cairo.line_to cr 161.36 111.13;
        Cairo.Path.close cr;
        Cairo.fill cr;
        (* White tip highlight *)
        Cairo.set_source_rgb cr 1.0 1.0 1.0;
        Cairo.move_to cr 71.47 214.03;
        Cairo.curve_to cr 60.16 218.55 50.33 222.1 39.16 227.63;
        Cairo.line_to cr 21.93 214.37;
        Cairo.curve_to cr 22.92 208.81 23.28 203.26 24.61 197.77;
        Cairo.line_to cr 29.0 179.73;
        Cairo.curve_to cr 30.63 176.51 40.55 177.54 42.67 180.44;
        Cairo.curve_to cr 45.87 184.84 45.86 192.69 49.8 196.26;
        Cairo.curve_to cr 53.77 199.86 60.42 197.04 64.72 199.43;
        Cairo.curve_to cr 69.02 201.82 69.61 208.63 71.47 214.03;
        Cairo.Path.close cr;
        Cairo.fill cr;
        Cairo.restore cr
      in

      let draw_path_eraser_icon cr ~alloc =
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        let s = 28.0 /. 256.0 in
        Cairo.save cr;
        Cairo.translate cr ox oy;
        Cairo.scale cr s s;
        Cairo.set_source_rgb cr 0.8 0.8 0.8;
        (* Outer path *)
        Cairo.move_to cr 169.86 33.13;
        Cairo.line_to cr 243.34 1.82;
        Cairo.curve_to cr 246.77 0.36 249.73 (-1.15) 253.26 1.3;
        Cairo.curve_to cr 255.47 2.84 256.6 6.18 255.67 10.06;
        Cairo.line_to cr 236.36 90.59;
        Cairo.line_to cr 128.34 216.3;
        Cairo.line_to cr 100.36 247.5;
        Cairo.curve_to cr 90.73 258.24 75.45 258.84 64.8 249.13;
        Cairo.line_to cr 36.8 223.61;
        Cairo.curve_to cr 27.71 215.33 27.26 200.13 35.38 190.66;
        Cairo.line_to cr 76.02 143.21;
        Cairo.line_to cr 169.85 33.13;
        Cairo.Path.close cr;
        Cairo.fill cr;
        (* Gray facets *)
        Cairo.set_source_rgb cr 0.235 0.235 0.235;
        Cairo.move_to cr 184.63 65.93;
        Cairo.curve_to cr 189.51 66.39 194.59 66.2 198.13 68.25;
        Cairo.curve_to cr 201.04 69.93 203.57 78.45 201.14 81.28;
        Cairo.line_to cr 116.25 180.28;
        Cairo.curve_to cr 109.28 176.56 104.39 171.21 100.36 164.52;
        Cairo.line_to cr 184.63 65.93;
        Cairo.Path.close cr;
        Cairo.fill cr;
        Cairo.move_to cr 44.69 212.9;
        Cairo.curve_to cr 36.95 201.82 53.37 190.58 61.74 180.12;
        Cairo.line_to cr 106.79 221.05;
        Cairo.line_to cr 90.97 239.52;
        Cairo.curve_to cr 82.2 249.76 69.76 237.13 64.2 232.21;
        Cairo.curve_to cr 57.24 226.04 50.08 220.63 44.68 212.9;
        Cairo.Path.close cr;
        Cairo.fill cr;
        Cairo.move_to cr 207.17 85.96;
        Cairo.curve_to cr 211.98 85.74 215.71 86.73 220.02 89.55;
        Cairo.line_to cr 154.89 165.84;
        Cairo.line_to cr 131.54 192.84;
        Cairo.curve_to cr 127.63 191.48 125.1 188.78 122.92 184.95;
        Cairo.line_to cr 207.17 85.97;
        Cairo.Path.close cr;
        Cairo.fill cr;
        Cairo.move_to cr 124.64 106.13;
        Cairo.line_to cr 175.0 47.68;
        Cairo.curve_to cr 177.8 51.64 180.01 56.74 178.33 59.8;
        Cairo.curve_to cr 173.13 69.28 165.51 76.42 158.5 84.62;
        Cairo.line_to cr 95.94 157.83;
        Cairo.curve_to cr 93.95 160.16 90.93 158.89 89.56 157.97;
        Cairo.curve_to cr 87.97 156.9 84.31 153.0 86.41 151.47;
        Cairo.curve_to cr 96.6 139.21 107.11 127.91 116.95 115.69;
        Cairo.line_to cr 124.64 106.13;
        Cairo.Path.close cr;
        Cairo.fill cr;
        (* White eraser tip + band *)
        Cairo.set_source_rgb cr 1.0 1.0 1.0;
        Cairo.move_to cr 183.88 41.54;
        Cairo.curve_to cr 191.96 36.87 200.2 34.23 208.22 31.18;
        Cairo.curve_to cr 221.06 26.3 214.11 26.93 232.64 41.38;
        Cairo.curve_to cr 235.55 41.71 227.33 76.83 225.67 77.25;
        Cairo.curve_to cr 222.3 80.28 212.1 79.09 210.75 75.03;
        Cairo.line_to cr 205.76 60.03;
        Cairo.line_to cr 189.06 56.22;
        Cairo.curve_to cr 184.53 55.19 184.95 47.11 183.89 41.54;
        Cairo.Path.close cr;
        Cairo.fill cr;
        (* Eraser band (rotated rect) *)
        Cairo.save cr;
        Cairo.translate cr 299.56 239.09;
        let angle = 131.58 *. Float.pi /. 180.0 in
        Cairo.rotate cr angle;
        Cairo.rectangle cr 0.0 0.0 ~w:14.58 ~h:61.84;
        Cairo.fill cr;
        Cairo.restore cr;
        Cairo.restore cr
      in

      let draw_smooth_icon cr ~alloc =
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        let s = 28.0 /. 256.0 in
        Cairo.save cr;
        Cairo.translate cr ox oy;
        Cairo.scale cr s s;
        (* Pencil body *)
        Cairo.set_source_rgb cr 0.8 0.8 0.8;
        Cairo.move_to cr 70.89 227.68;
        Cairo.line_to cr 4.52 255.09;
        Cairo.curve_to cr 0.88 256.59 (-0.91) 248.43 (-0.16) 245.21;
        Cairo.line_to cr 17.39 169.99;
        Cairo.curve_to cr 24.75 160.38 31.97 152.72 39.68 143.64;
        Cairo.line_to cr 131.03 36.05;
        Cairo.line_to cr 144.21 21.29;
        Cairo.curve_to cr 154.4 9.87 168.74 11.64 179.56 21.24;
        Cairo.line_to cr 205.01 43.83;
        Cairo.curve_to cr 214.73 52.45 213.09 65.99 204.99 75.55;
        Cairo.line_to cr 174.64 111.37;
        Cairo.line_to cr 86.01 216.71;
        Cairo.curve_to cr 81.53 222.03 77.91 224.78 70.89 227.68;
        Cairo.Path.close cr;
        Cairo.fill cr;
        (* Gray facets *)
        Cairo.set_source_rgb cr 0.235 0.235 0.235;
        Cairo.move_to cr 66.39 191.49;
        Cairo.curve_to cr 63.13 195.37 55.31 192.23 52.22 192.25;
        Cairo.curve_to cr 50.62 187.3 49.74 184.33 49.59 179.38;
        Cairo.line_to cr 145.52 66.15;
        Cairo.curve_to cr 151.28 70.25 156.08 74.56 160.81 79.96;
        Cairo.line_to cr 112.0 137.22;
        Cairo.line_to cr 66.39 191.49;
        Cairo.Path.close cr;
        Cairo.fill cr;
        Cairo.move_to cr 194.82 68.3;
        Cairo.curve_to cr 190.49 73.55 186.85 77.91 182.22 82.5;
        Cairo.line_to cr 141.05 44.73;
        Cairo.curve_to cr 147.58 35.76 157.41 18.57 169.33 28.72;
        Cairo.line_to cr 192.63 48.55;
        Cairo.curve_to cr 198.53 53.57 199.92 62.13 194.83 68.3;
        Cairo.Path.close cr;
        Cairo.fill cr;
        Cairo.move_to cr 32.69 171.62;
        Cairo.curve_to cr 35.03 169.5 35.9 166.47 38.13 163.87;
        Cairo.line_to cr 86.71 107.09;
        Cairo.line_to cr 131.67 54.87;
        Cairo.curve_to cr 134.96 55.93 137.97 58.23 139.63 61.75;
        Cairo.line_to cr 44.81 173.16;
        Cairo.curve_to cr 41.4 174.85 37.29 173.22 32.69 171.62;
        Cairo.Path.close cr;
        Cairo.fill cr;
        Cairo.move_to cr 74.85 208.97;
        Cairo.curve_to cr 72.95 205.46 70.31 201.15 71.65 197.51;
        Cairo.line_to cr 134.32 122.98;
        Cairo.curve_to cr 138.19 118.38 141.65 114.55 145.53 109.99;
        Cairo.line_to cr 166.6 85.22;
        Cairo.curve_to cr 169.52 87.53 172.2 88.21 174.12 90.63;
        Cairo.curve_to cr 167.84 101.81 159.75 109.64 151.85 119.0;
        Cairo.line_to cr 83.45 199.98;
        Cairo.curve_to cr 80.68 203.26 78.45 205.5 74.84 208.97;
        Cairo.Path.close cr;
        Cairo.fill cr;
        (* White tip highlight *)
        Cairo.set_source_rgb cr 1.0 1.0 1.0;
        Cairo.move_to cr 61.28 200.71;
        Cairo.curve_to cr 64.24 205.11 65.93 209.9 66.93 215.37;
        Cairo.line_to cr 35.72 228.83;
        Cairo.line_to cr 20.11 215.85;
        Cairo.line_to cr 26.48 181.11;
        Cairo.curve_to cr 30.34 181.56 36.75 180.57 39.5 183.8;
        Cairo.curve_to cr 43.15 188.1 42.2 194.89 45.63 199.46;
        Cairo.curve_to cr 50.38 200.86 55.12 200.42 61.27 200.72;
        Cairo.Path.close cr;
        Cairo.fill cr;
        (* "S" lettering *)
        Cairo.set_source_rgb cr 0.8 0.8 0.8;
        Cairo.move_to cr 210.2 175.94;
        Cairo.curve_to cr 221.68 185.28 259.83 188.72 255.69 222.01;
        Cairo.curve_to cr 254.5 231.57 248.08 241.8 237.42 246.05;
        Cairo.curve_to cr 222.73 251.9 206.61 250.52 192.05 244.82;
        Cairo.curve_to cr 192.52 240.14 193.6 236.89 195.16 233.15;
        Cairo.curve_to cr 204.66 236.94 214.74 238.68 224.8 236.57;
        Cairo.curve_to cr 233.48 234.75 238.62 228.4 239.23 220.41;
        Cairo.curve_to cr 239.88 211.86 235.9 205.22 227.47 201.4;
        Cairo.line_to cr 206.01 191.68;
        Cairo.curve_to cr 194.41 186.43 187.58 176.16 187.67 163.79;
        Cairo.curve_to cr 187.75 152.1 194.35 141.45 206.21 136.42;
        Cairo.curve_to cr 220.61 130.31 237.7 132.02 251.7 139.29;
        Cairo.curve_to cr 251.19 144.18 248.58 147.49 247.15 151.76;
        Cairo.curve_to cr 233.82 143.01 205.83 143.47 204.03 159.51;
        Cairo.curve_to cr 203.3 166.01 204.94 171.65 210.2 175.93;
        Cairo.Path.close cr;
        Cairo.fill cr;
        Cairo.restore cr
      in

      (* Pen slot: draws pen or add-anchor-point depending on pen_slot_tool *)
      pen_btn#misc#connect#draw ~callback:(fun cr ->
        let alloc = pen_btn#misc#allocation in
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        if current_tool = pen_slot_tool then begin
          Cairo.set_source_rgb cr 0.4 0.4 0.4;
          Cairo.rectangle cr 0.0 0.0 ~w:bw ~h:bh;
          Cairo.fill cr
        end else begin
          Cairo.set_source_rgb cr 0.27 0.27 0.27;
          Cairo.rectangle cr 0.0 0.0 ~w:bw ~h:bh;
          Cairo.fill cr
        end;
        (match pen_slot_tool with
         | Pen -> draw_pen_icon cr ~alloc
         | Add_anchor_point -> draw_add_anchor_point_icon cr ~alloc
         | Delete_anchor_point -> draw_delete_anchor_point_icon cr ~alloc
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
      (* Pencil slot: draws pencil or path-eraser depending on pencil_slot_tool *)
      pencil_btn#misc#connect#draw ~callback:(fun cr ->
        let alloc = pencil_btn#misc#allocation in
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        if current_tool = pencil_slot_tool then begin
          Cairo.set_source_rgb cr 0.4 0.4 0.4;
          Cairo.rectangle cr 0.0 0.0 ~w:bw ~h:bh;
          Cairo.fill cr
        end else begin
          Cairo.set_source_rgb cr 0.27 0.27 0.27;
          Cairo.rectangle cr 0.0 0.0 ~w:bw ~h:bh;
          Cairo.fill cr
        end;
        (match pencil_slot_tool with
         | Pencil -> draw_pencil_icon cr ~alloc
         | Path_eraser -> draw_path_eraser_icon cr ~alloc
         | Smooth -> draw_smooth_icon cr ~alloc
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
      (* Text slot: draws text or text-path depending on text_slot_tool *)
      text_btn#misc#connect#draw ~callback:(fun cr ->
        let alloc = text_btn#misc#allocation in
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        if current_tool = text_slot_tool then begin
          Cairo.set_source_rgb cr 0.4 0.4 0.4;
          Cairo.rectangle cr 0.0 0.0 ~w:bw ~h:bh;
          Cairo.fill cr
        end else begin
          Cairo.set_source_rgb cr 0.27 0.27 0.27;
          Cairo.rectangle cr 0.0 0.0 ~w:bw ~h:bh;
          Cairo.fill cr
        end;
        (match text_slot_tool with
         | Text_tool -> draw_text_icon cr ~alloc
         | Text_path -> draw_text_path_icon cr ~alloc
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
      draw_tool_button selection_btn Selection draw_selection_arrow;
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
         | Rounded_rect -> draw_rounded_rect_icon cr ~alloc
         | Polygon -> draw_polygon_icon cr ~alloc
         | Star -> draw_star_icon cr ~alloc
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
      (* Pen slot: click selects, long press shows menu *)
      pen_btn#event#add [`BUTTON_PRESS; `BUTTON_RELEASE];
      pen_btn#event#connect#button_press ~callback:(fun ev ->
        if GdkEvent.Button.button ev = 1 then begin
          pen_long_press_timer <- Some (GMain.Timeout.add ~ms:long_press_ms ~callback:(fun () ->
            pen_long_press_timer <- None;
            self#show_pen_slot_menu;
            false
          ));
          true
        end else false
      ) |> ignore;
      pen_btn#event#connect#button_release ~callback:(fun ev ->
        if GdkEvent.Button.button ev = 1 then begin
          (match pen_long_press_timer with
           | Some id -> GMain.Timeout.remove id; pen_long_press_timer <- None
           | None -> ());
          current_tool <- pen_slot_tool;
          self#redraw_all;
          true
        end else false
      ) |> ignore;
      (* Pencil slot: click selects, long press shows menu *)
      pencil_btn#event#add [`BUTTON_PRESS; `BUTTON_RELEASE];
      pencil_btn#event#connect#button_press ~callback:(fun ev ->
        if GdkEvent.Button.button ev = 1 then begin
          pencil_long_press_timer <- Some (GMain.Timeout.add ~ms:long_press_ms ~callback:(fun () ->
            pencil_long_press_timer <- None;
            self#show_pencil_slot_menu;
            false
          ));
          true
        end else false
      ) |> ignore;
      pencil_btn#event#connect#button_release ~callback:(fun ev ->
        if GdkEvent.Button.button ev = 1 then begin
          (match pencil_long_press_timer with
           | Some id -> GMain.Timeout.remove id; pencil_long_press_timer <- None
           | None -> ());
          current_tool <- pencil_slot_tool;
          self#redraw_all;
          true
        end else false
      ) |> ignore;

      (* Text slot: click selects, long press shows menu *)
      text_btn#event#add [`BUTTON_PRESS; `BUTTON_RELEASE];
      text_btn#event#connect#button_press ~callback:(fun ev ->
        if GdkEvent.Button.button ev = 1 then begin
          text_long_press_timer <- Some (GMain.Timeout.add ~ms:long_press_ms ~callback:(fun () ->
            text_long_press_timer <- None;
            self#show_text_slot_menu;
            false
          ));
          true
        end else false
      ) |> ignore;
      text_btn#event#connect#button_release ~callback:(fun ev ->
        if GdkEvent.Button.button ev = 1 then begin
          (match text_long_press_timer with
           | Some id -> GMain.Timeout.remove id; text_long_press_timer <- None
           | None -> ());
          current_tool <- text_slot_tool;
          self#redraw_all;
          true
        end else false
      ) |> ignore;
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

    method private show_pen_slot_menu =
      let menu = GMenu.menu () in
      let add_item label tool =
        let item = GMenu.check_menu_item ~label ~packing:menu#append () in
        item#set_active (pen_slot_tool = tool);
        item#connect#activate ~callback:(fun () ->
          pen_slot_tool <- tool;
          current_tool <- tool;
          self#redraw_all
        ) |> ignore
      in
      add_item "Pen" Pen;
      add_item "Add Anchor Point" Add_anchor_point;
      add_item "Delete Anchor Point" Delete_anchor_point;
      menu#popup ~button:1 ~time:(GtkMain.Main.get_current_event_time ())

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

    method private show_pencil_slot_menu =
      let menu = GMenu.menu () in
      let add_item label tool =
        let item = GMenu.check_menu_item ~label ~packing:menu#append () in
        item#set_active (pencil_slot_tool = tool);
        item#connect#activate ~callback:(fun () ->
          pencil_slot_tool <- tool;
          current_tool <- tool;
          self#redraw_all
        ) |> ignore
      in
      add_item "Pencil" Pencil;
      add_item "Path Eraser" Path_eraser;
      add_item "Smooth" Smooth;
      menu#popup ~button:1 ~time:(GtkMain.Main.get_current_event_time ())

    method private show_text_slot_menu =
      let menu = GMenu.menu () in
      let add_item label tool =
        let item = GMenu.check_menu_item ~label ~packing:menu#append () in
        item#set_active (text_slot_tool = tool);
        item#connect#activate ~callback:(fun () ->
          text_slot_tool <- tool;
          current_tool <- tool;
          self#redraw_all
        ) |> ignore
      in
      add_item "Text" Text_tool;
      add_item "Text on Path" Text_path;
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
      add_item "Rounded Rectangle" Rounded_rect;
      add_item "Polygon" Polygon;
      add_item "Star" Star;
      menu#popup ~button:1 ~time:(GtkMain.Main.get_current_event_time ())
  end

let create ~title ~x ~y fixed =
  new toolbar ~title ~x ~y fixed
