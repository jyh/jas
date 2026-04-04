(** A floating toolbar subwindow embedded inside the workspace. *)

type tool = Selection | Direct_selection | Line

let tool_button_size = 32
let title_bar_height = 24

class toolbar ~title ~x ~y (fixed : GPack.fixed) =
  let frame = GBin.frame ~shadow_type:`ETCHED_IN () in
  let vbox = GPack.vbox ~packing:frame#add () in

  (* Title bar *)
  let title_bar = GMisc.drawing_area
    ~packing:(vbox#pack ~expand:false) () in
  let () = title_bar#misc#set_size_request ~height:title_bar_height () in

  (* Toolbar grid *)
  let grid = GPack.table ~rows:2 ~columns:2
    ~row_spacings:2 ~col_spacings:2
    ~packing:(vbox#pack ~expand:false) () in
  let selection_btn = GMisc.drawing_area () in
  let direct_btn = GMisc.drawing_area () in
  let line_btn = GMisc.drawing_area () in
  let () =
    selection_btn#misc#set_size_request ~width:tool_button_size ~height:tool_button_size ();
    direct_btn#misc#set_size_request ~width:tool_button_size ~height:tool_button_size ();
    line_btn#misc#set_size_request ~width:tool_button_size ~height:tool_button_size ();
    grid#attach ~left:0 ~top:0 selection_btn#coerce;
    grid#attach ~left:1 ~top:0 direct_btn#coerce;
    grid#attach ~left:0 ~top:1 line_btn#coerce
  in
  object
    val mutable pos_x = x
    val mutable pos_y = y
    val mutable current_tool = Selection
    val mutable dragging = false
    val mutable drag_offset_x = 0.0
    val mutable drag_offset_y = 0.0

    method current_tool = current_tool
    method widget = frame#coerce
    method x = pos_x
    method y = pos_y

    method select_tool t =
      current_tool <- t;
      selection_btn#misc#queue_draw ();
      direct_btn#misc#queue_draw ();
      line_btn#misc#queue_draw ()

    initializer
      fixed#put frame#coerce ~x:pos_x ~y:pos_y;
      frame#misc#set_size_request ~width:80 ~height:(title_bar_height + tool_button_size * 2 + 14) ();

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
      draw_tool_button selection_btn Selection (draw_arrow ~filled:true);
      draw_tool_button direct_btn Direct_selection (draw_arrow ~filled:false);
      draw_tool_button line_btn Line draw_line_icon;

      (* Click events *)
      let connect_click area tool_id =
        area#event#add [`BUTTON_PRESS];
        area#event#connect#button_press ~callback:(fun ev ->
          if GdkEvent.Button.button ev = 1 then begin
            current_tool <- tool_id;
            selection_btn#misc#queue_draw ();
            direct_btn#misc#queue_draw ();
            line_btn#misc#queue_draw ();
            true
          end else false
        ) |> ignore
      in
      connect_click selection_btn Selection;
      connect_click direct_btn Direct_selection;
      connect_click line_btn Line;

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
  end

let create ~title ~x ~y fixed =
  new toolbar ~title ~x ~y fixed
