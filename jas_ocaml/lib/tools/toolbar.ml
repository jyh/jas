(** A floating toolbar subwindow embedded inside the workspace. *)

type tool = Selection | Direct_selection | Group_selection | Pen | Add_anchor_point | Pencil | Text_tool | Text_path | Line | Rect | Polygon

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
    val mutable text_slot_tool = Text_tool
    val mutable shape_slot_tool = Rect
    val mutable dragging = false
    val mutable drag_offset_x = 0.0
    val mutable drag_offset_y = 0.0
    val mutable long_press_timer : GMain.Timeout.id option = None
    val mutable pen_long_press_timer : GMain.Timeout.id option = None
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
       | Pen | Add_anchor_point ->
         pen_slot_tool <- t
       | Text_tool | Text_path ->
         text_slot_tool <- t
       | Rect | Polygon ->
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

      let draw_pencil_icon cr ~alloc =
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        Cairo.set_source_rgb cr 0.8 0.8 0.8;
        Cairo.set_line_width cr 1.5;
        (* Pencil body *)
        Cairo.move_to cr (ox +. 6.0) (oy +. 22.0);
        Cairo.line_to cr (ox +. 20.0) (oy +. 8.0);
        Cairo.line_to cr (ox +. 24.0) (oy +. 4.0);
        Cairo.line_to cr (ox +. 26.0) (oy +. 6.0);
        Cairo.line_to cr (ox +. 22.0) (oy +. 10.0);
        Cairo.line_to cr (ox +. 8.0) (oy +. 24.0);
        Cairo.Path.close cr;
        Cairo.stroke cr;
        (* Tip *)
        Cairo.move_to cr (ox +. 6.0) (oy +. 22.0);
        Cairo.line_to cr (ox +. 4.0) (oy +. 26.0);
        Cairo.line_to cr (ox +. 8.0) (oy +. 24.0);
        Cairo.stroke cr
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
      draw_tool_button pencil_btn Pencil draw_pencil_icon;
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
      connect_click pencil_btn Pencil;

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
      add_item "Polygon" Polygon;
      menu#popup ~button:1 ~time:(GtkMain.Main.get_current_event_time ())
  end

let create ~title ~x ~y fixed =
  new toolbar ~title ~x ~y fixed
