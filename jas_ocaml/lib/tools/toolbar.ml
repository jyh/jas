(** A floating toolbar subwindow embedded inside the workspace. *)

type tool = Selection | Partial_selection | Interior_selection | Magic_wand | Pen | Add_anchor_point | Delete_anchor_point | Anchor_point | Pencil | Paintbrush | Blob_brush | Path_eraser | Smooth | Type_tool | Type_on_path | Line | Rect | Rounded_rect | Polygon | Star | Lasso | Scale | Rotate | Shear | Hand | Zoom

(** Map a tool variant to its workspace/tools/*.yaml filename stem.
    Returns [None] for native-only tools without a YAML spec. Used
    by the double-click handlers to look up tool_options_dialog
    (PAINTBRUSH_TOOL.md §Tool options). *)
let tool_yaml_id = function
  | Selection -> Some "selection"
  | Partial_selection -> Some "partial_selection"
  | Interior_selection -> Some "interior_selection"
  | Magic_wand -> Some "magic_wand"
  | Pen -> Some "pen"
  | Add_anchor_point -> Some "add_anchor_point"
  | Delete_anchor_point -> Some "delete_anchor_point"
  | Anchor_point -> Some "anchor_point"
  | Pencil -> Some "pencil"
  | Paintbrush -> Some "paintbrush"
  | Blob_brush -> Some "blob_brush"
  | Path_eraser -> Some "path_eraser"
  | Smooth -> Some "smooth"
  | Line -> Some "line"
  | Rect -> Some "rect"
  | Rounded_rect -> Some "rounded_rect"
  | Polygon -> Some "polygon"
  | Star -> Some "star"
  | Lasso -> Some "lasso"
  | Scale -> Some "scale"
  | Rotate -> Some "rotate"
  | Shear -> Some "shear"
  | Hand -> Some "hand"
  | Zoom -> Some "zoom"
  | Type_tool | Type_on_path -> None

(** Look up a tool's [tool_options_dialog] field in workspace.json.
    Returns the dialog id when set, [None] otherwise. *)
let tool_options_dialog_id (t : tool) : string option =
  let open Option in
  bind (tool_yaml_id t) (fun yaml_id ->
    bind (Workspace_loader.load ()) (fun ws ->
      bind (Workspace_loader.json_member "tools" ws.data) (function
        | `Assoc tools ->
          bind (List.assoc_opt yaml_id tools) (function
            | `Assoc fields ->
              bind (List.assoc_opt "tool_options_dialog" fields) (function
                | `String s -> Some s
                | _ -> None)
            | _ -> None)
        | _ -> None)))

let tool_button_size = 32
let _title_bar_height = 24
let long_press_ms = Canvas_tool.long_press_ms

(* Theme-aware colors for Cairo rendering *)
let icon_rgb () = Theme.hex_to_rgb !(Dock_panel.theme_text)
let active_bg_rgb () = Theme.hex_to_rgb !(Dock_panel.theme_bg_tab)
let inactive_bg_rgb () = Theme.hex_to_rgb !(Dock_panel.theme_bg_dark)

class toolbar ~title:(_title : string) ~x ~y
    ?(get_model : (unit -> Model.model) option) (fixed : GPack.fixed) =
  let frame = GBin.frame ~shadow_type:`NONE () in
  let vbox = GPack.vbox ~packing:frame#add () in

  (* Toolbar grid — 5 rows × 2 cols. Row 4 hosts the transform-tool
     family: Scale (with Shear as long-press alternate) and Rotate.
     See SCALE_TOOL.md / ROTATE_TOOL.md / SHEAR_TOOL.md. *)
  let grid = GPack.table ~rows:5 ~columns:2
    ~row_spacings:2 ~col_spacings:2
    ~packing:(vbox#pack ~expand:false) () in
  let selection_btn = GMisc.drawing_area () in
  let direct_btn = GMisc.drawing_area () in
  let pen_btn = GMisc.drawing_area () in
  let pencil_btn = GMisc.drawing_area () in
  let text_btn = GMisc.drawing_area () in
  let line_btn = GMisc.drawing_area () in
  let shape_btn = GMisc.drawing_area () in
  let lasso_btn = GMisc.drawing_area () in
  let scale_btn = GMisc.drawing_area () in
  let rotate_btn = GMisc.drawing_area () in
  let () =
    selection_btn#misc#set_size_request ~width:tool_button_size ~height:tool_button_size ();
    direct_btn#misc#set_size_request ~width:tool_button_size ~height:tool_button_size ();
    pen_btn#misc#set_size_request ~width:tool_button_size ~height:tool_button_size ();
    pencil_btn#misc#set_size_request ~width:tool_button_size ~height:tool_button_size ();
    text_btn#misc#set_size_request ~width:tool_button_size ~height:tool_button_size ();
    line_btn#misc#set_size_request ~width:tool_button_size ~height:tool_button_size ();
    shape_btn#misc#set_size_request ~width:tool_button_size ~height:tool_button_size ();
    lasso_btn#misc#set_size_request ~width:tool_button_size ~height:tool_button_size ();
    scale_btn#misc#set_size_request ~width:tool_button_size ~height:tool_button_size ();
    rotate_btn#misc#set_size_request ~width:tool_button_size ~height:tool_button_size ();
    grid#attach ~left:0 ~top:0 selection_btn#coerce;
    grid#attach ~left:1 ~top:0 direct_btn#coerce;
    grid#attach ~left:0 ~top:1 pen_btn#coerce;
    grid#attach ~left:1 ~top:1 pencil_btn#coerce;
    grid#attach ~left:0 ~top:2 text_btn#coerce;
    grid#attach ~left:1 ~top:2 line_btn#coerce;
    grid#attach ~left:0 ~top:3 shape_btn#coerce;
    grid#attach ~left:1 ~top:3 lasso_btn#coerce;
    grid#attach ~left:0 ~top:4 scale_btn#coerce;
    grid#attach ~left:1 ~top:4 rotate_btn#coerce
  in

  (* Fill/stroke indicator widget *)
  let fs_area = GMisc.drawing_area () in
  let () =
    let fs_height = 60 in
    fs_area#misc#set_size_request ~width:(tool_button_size * 2 + 2)
      ~height:fs_height ();
    vbox#pack ~expand:false fs_area#coerce
  in
  object (self)
    val mutable pos_x = x
    val mutable pos_y = y
    val mutable current_tool = Selection
    val mutable arrow_slot_tool = Partial_selection
    val mutable pen_slot_tool = Pen
    val mutable pencil_slot_tool = Pencil
    val mutable text_slot_tool = Type_tool
    val mutable shape_slot_tool = Rect
    val mutable transform_slot_tool = Scale
    val mutable dragging = false
    val mutable drag_offset_x = 0.0
    val mutable drag_offset_y = 0.0
    val mutable long_press_timer : GMain.Timeout.id option = None
    val mutable pen_long_press_timer : GMain.Timeout.id option = None
    val mutable pencil_long_press_timer : GMain.Timeout.id option = None
    val mutable text_long_press_timer : GMain.Timeout.id option = None
    val mutable shape_long_press_timer : GMain.Timeout.id option = None
    val mutable transform_long_press_timer : GMain.Timeout.id option = None
    val mutable fill_on_top = true

    method current_tool = current_tool
    method widget = frame#coerce
    method x = pos_x
    method y = pos_y
    method fill_on_top = fill_on_top
    method set_fill_on_top v =
      fill_on_top <- v;
      fs_area#misc#queue_draw ()

    method toggle_fill_on_top =
      fill_on_top <- not fill_on_top;
      fs_area#misc#queue_draw ()

    method reset_defaults =
      (match get_model with
       | Some gm ->
         let m = gm () in
         m#set_default_fill None;
         m#set_default_stroke (Some (Element.make_stroke Element.black));
         fs_area#misc#queue_draw ()
       | None -> ())

    method swap_fill_stroke =
      (match get_model with
       | Some gm ->
         let m = gm () in
         let old_fill = m#default_fill in
         let old_stroke = m#default_stroke in
         (* Convert fill color to stroke, stroke color to fill *)
         let new_fill = (match old_stroke with
           | Some s -> Some { Element.fill_color = s.Element.stroke_color;
                              fill_opacity = s.Element.stroke_opacity }
           | None -> None) in
         let new_stroke = (match old_fill with
           | Some f -> Some (Element.make_stroke ~opacity:f.Element.fill_opacity
                               f.Element.fill_color)
           | None -> None) in
         m#set_default_fill new_fill;
         m#set_default_stroke new_stroke;
         fs_area#misc#queue_draw ()
       | None -> ())

    method redraw_fill_stroke =
      fs_area#misc#queue_draw ()

    method select_tool t =
      current_tool <- t;
      (match t with
       | Partial_selection | Interior_selection | Magic_wand ->
         arrow_slot_tool <- t
       | Pen | Add_anchor_point | Delete_anchor_point | Anchor_point ->
         pen_slot_tool <- t
       | Pencil | Path_eraser | Smooth ->
         pencil_slot_tool <- t
       | Type_tool | Type_on_path ->
         text_slot_tool <- t
       | Rect | Rounded_rect | Polygon | Star ->
         shape_slot_tool <- t
       | Scale | Shear ->
         transform_slot_tool <- t
       | _ -> ());
      self#redraw_all

    method private redraw_all =
      selection_btn#misc#queue_draw ();
      direct_btn#misc#queue_draw ();
      pen_btn#misc#queue_draw ();
      pencil_btn#misc#queue_draw ();
      text_btn#misc#queue_draw ();
      line_btn#misc#queue_draw ();
      shape_btn#misc#queue_draw ();
      lasso_btn#misc#queue_draw ();
      scale_btn#misc#queue_draw ();
      rotate_btn#misc#queue_draw ();
      fs_area#misc#queue_draw ()

    initializer
      fixed#put frame#coerce ~x:pos_x ~y:pos_y;
      frame#misc#set_size_request ~height:(tool_button_size * 4 + 24 + 60) ();

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

      (* Magic Wand: 28x28 cell. Diagonal handle line plus a sparkle
         polygon at the tip and a small accent star. Mirrors the Rust
         MagicWand SVG glyph (jas_dioxus/src/workspace/icons.rs). *)
      let draw_magic_wand_icon cr ~alloc =
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        let (fr, fg, fb) = icon_rgb () in
        Cairo.set_source_rgb cr fr fg fb;
        (* Handle: line from lower-left to upper-right. *)
        Cairo.set_line_width cr 2.0;
        Cairo.move_to cr (ox +. 4.0) (oy +. 24.0);
        Cairo.line_to cr (ox +. 17.0) (oy +. 11.0);
        Cairo.stroke cr;
        (* Sparkle at the tip — 4-point star. *)
        Cairo.move_to cr (ox +. 21.0) (oy +. 4.0);
        Cairo.line_to cr (ox +. 22.5) (oy +. 9.5);
        Cairo.line_to cr (ox +. 28.0) (oy +. 11.0);
        Cairo.line_to cr (ox +. 22.5) (oy +. 12.5);
        Cairo.line_to cr (ox +. 21.0) (oy +. 18.0);
        Cairo.line_to cr (ox +. 19.5) (oy +. 12.5);
        Cairo.line_to cr (ox +. 14.0) (oy +. 11.0);
        Cairo.line_to cr (ox +. 19.5) (oy +. 9.5);
        Cairo.Path.close cr;
        Cairo.fill cr;
        (* Small accent star, upper left. *)
        Cairo.move_to cr (ox +. 5.0) (oy +. 5.0);
        Cairo.line_to cr (ox +. 6.0) (oy +. 7.5);
        Cairo.line_to cr (ox +. 8.5) (oy +. 8.5);
        Cairo.line_to cr (ox +. 6.0) (oy +. 9.5);
        Cairo.line_to cr (ox +. 5.0) (oy +. 12.0);
        Cairo.line_to cr (ox +. 4.0) (oy +. 9.5);
        Cairo.line_to cr (ox +. 1.5) (oy +. 8.5);
        Cairo.line_to cr (ox +. 4.0) (oy +. 7.5);
        Cairo.Path.close cr;
        Cairo.fill cr
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
        let (fr, fg, fb) = icon_rgb () in Cairo.set_source_rgb cr fr fg fb;
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
            let (ar, ag, ab) = active_bg_rgb () in Cairo.set_source_rgb cr ar ag ab;
            Cairo.rectangle cr 0.0 0.0 ~w:bw ~h:bh;
            Cairo.fill cr
          end else begin
            let (ir, ig, ib) = inactive_bg_rgb () in Cairo.set_source_rgb cr ir ig ib;
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
        let (fr, fg, fb) = icon_rgb () in Cairo.set_source_rgb cr fr fg fb;
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
        let (fr, fg, fb) = icon_rgb () in Cairo.set_source_rgb cr fr fg fb;
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
        let (fr, fg, fb) = icon_rgb () in Cairo.set_source_rgb cr fr fg fb;
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
        let (fr, fg, fb) = icon_rgb () in Cairo.set_source_rgb cr fr fg fb;
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

      let draw_lasso_icon cr ~alloc =
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        let (fr, fg, fb) = icon_rgb () in Cairo.set_source_rgb cr fr fg fb;
        Cairo.set_line_width cr 1.5;
        Cairo.set_line_cap cr Cairo.ROUND;
        Cairo.move_to cr (ox +. 14.0) (oy +. 5.0);
        Cairo.curve_to cr (ox +. 6.0) (oy +. 5.0) (ox +. 3.0) (oy +. 10.0) (ox +. 3.0) (oy +. 14.0);
        Cairo.curve_to cr (ox +. 3.0) (oy +. 20.0) (ox +. 8.0) (oy +. 24.0) (ox +. 14.0) (oy +. 22.0);
        Cairo.curve_to cr (ox +. 20.0) (oy +. 20.0) (ox +. 22.0) (oy +. 16.0) (ox +. 20.0) (oy +. 12.0);
        Cairo.curve_to cr (ox +. 18.0) (oy +. 8.0) (ox +. 12.0) (oy +. 9.0) (ox +. 12.0) (oy +. 13.0);
        Cairo.curve_to cr (ox +. 12.0) (oy +. 16.0) (ox +. 16.0) (oy +. 17.0) (ox +. 17.0) (oy +. 15.0);
        Cairo.stroke cr
      in

      (* Scale — small square + larger square (extrusion). See
         SCALE_TOOL.md \167 Tool icon. *)
      let draw_scale_icon cr ~alloc =
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        let (fr, fg, fb) = icon_rgb () in Cairo.set_source_rgb cr fr fg fb;
        Cairo.set_line_width cr 1.5;
        Cairo.rectangle cr (ox +. 3.0) (oy +. 13.0) ~w:10.0 ~h:11.0;
        Cairo.stroke cr;
        Cairo.rectangle cr (ox +. 13.0) (oy +. 3.0) ~w:12.0 ~h:13.0;
        Cairo.stroke cr
      in

      (* Rotate — 270 deg arc with arrowhead. See ROTATE_TOOL.md
         \167 Tool icon. *)
      let draw_rotate_icon cr ~alloc =
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        let (fr, fg, fb) = icon_rgb () in Cairo.set_source_rgb cr fr fg fb;
        Cairo.set_line_width cr 1.5;
        Cairo.set_line_cap cr Cairo.ROUND;
        let cx = ox +. 14.0 and cy = oy +. 14.0 in
        Cairo.arc cr cx cy ~r:9.0 ~a1:(-. Float.pi /. 2.0) ~a2:Float.pi;
        Cairo.stroke cr;
        Cairo.move_to cr (ox +. 11.0) (oy +. 2.0);
        Cairo.line_to cr (ox +. 14.0) (oy +. 5.0);
        Cairo.line_to cr (ox +. 11.0) (oy +. 8.0);
        Cairo.stroke cr
      in

      (* Shear — right-leaning parallelogram. See SHEAR_TOOL.md
         \167 Tool icon. *)
      let draw_shear_icon cr ~alloc =
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        let (fr, fg, fb) = icon_rgb () in Cairo.set_source_rgb cr fr fg fb;
        Cairo.set_line_width cr 1.5;
        Cairo.move_to cr (ox +. 9.0)  (oy +. 4.0);
        Cairo.line_to cr (ox +. 26.0) (oy +. 4.0);
        Cairo.line_to cr (ox +. 19.0) (oy +. 24.0);
        Cairo.line_to cr (ox +. 2.0)  (oy +. 24.0);
        Cairo.Path.close cr;
        Cairo.stroke cr
      in

      (* The arrow slot draws whichever tool is currently in the slot *)
      let draw_arrow_slot cr ~alloc =
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        (* Highlight if current tool matches the slot tool *)
        if current_tool = arrow_slot_tool then begin
          let (ar, ag, ab) = active_bg_rgb () in Cairo.set_source_rgb cr ar ag ab;
          Cairo.rectangle cr 0.0 0.0 ~w:bw ~h:bh;
          Cairo.fill cr
        end else begin
          let (ir, ig, ib) = inactive_bg_rgb () in Cairo.set_source_rgb cr ir ig ib;
          Cairo.rectangle cr 0.0 0.0 ~w:bw ~h:bh;
          Cairo.fill cr
        end;
        (match arrow_slot_tool with
        | Partial_selection -> draw_direct_arrow cr ~alloc
        | Interior_selection -> draw_arrow_plus cr ~alloc
        | Magic_wand -> draw_magic_wand_icon cr ~alloc
        | _ -> ());
        (* Small triangle in lower-right indicating alternates *)
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        let s = 5.0 in
        Cairo.move_to cr (ox +. 28.0) (oy +. 28.0);
        Cairo.line_to cr (ox +. 28.0 -. s) (oy +. 28.0);
        Cairo.line_to cr (ox +. 28.0) (oy +. 28.0 -. s);
        Cairo.Path.close cr;
        let (fr, fg, fb) = icon_rgb () in Cairo.set_source_rgb cr fr fg fb;
        Cairo.fill cr
      in

      let draw_type_icon cr ~alloc =
        (* Type icon from assets/icons/type.svg (viewBox 0 0 256 256), scaled to 28x28 *)
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        let s = 28.0 /. 256.0 in
        Cairo.save cr;
        Cairo.translate cr ox oy;
        Cairo.scale cr s s;
        let (fr, fg, fb) = icon_rgb () in Cairo.set_source_rgb cr fr fg fb;
        Cairo.move_to cr 156.78 197.66;
        Cairo.line_to cr 100.75 197.48;
        Cairo.curve_to cr 96.82 194.4 96.71 181.39 100.77 178.84;
        Cairo.curve_to cr 104.79 176.31 116.01 180.43 117.52 175.37;
        Cairo.line_to cr 117.81 79.15;
        Cairo.curve_to cr 104.22 77.42 92.22 77.65 79.61 78.96;
        Cairo.line_to cr 77.77 97.29;
        Cairo.curve_to cr 71.41 98.59 65.94 98.55 59.23 97.22;
        Cairo.curve_to cr 58.49 84.22 58.18 72.18 59.38 58.35;
        Cairo.line_to cr 196.62 58.35;
        Cairo.curve_to cr 197.80 72.10 197.59 84.19 196.75 97.25;
        Cairo.curve_to cr 190.10 98.62 184.66 98.52 178.21 97.25;
        Cairo.line_to cr 176.38 78.97;
        Cairo.curve_to cr 163.73 77.71 151.71 77.51 138.23 79.15;
        Cairo.line_to cr 138.23 176.88;
        Cairo.line_to cr 156.82 178.76;
        Cairo.curve_to cr 158.02 184.54 158.40 189.25 156.78 197.67;
        Cairo.Path.close cr;
        Cairo.fill cr;
        Cairo.restore cr
      in

      let draw_type_on_path_icon cr ~alloc =
        (* Type-on-a-Path icon from assets/icons/type on a path.svg
           (viewBox 0 0 256 256), scaled to 28x28 *)
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        let s = 28.0 /. 256.0 in
        Cairo.save cr;
        Cairo.translate cr ox oy;
        Cairo.scale cr s s;
        let (fr, fg, fb) = icon_rgb () in Cairo.set_source_rgb cr fr fg fb;
        (* Caret/insertion-point glyph (top stroke) *)
        Cairo.move_to cr 146.65 143.92;
        Cairo.curve_to cr 146.90 149.81 136.63 147.47 133.15 143.77;
        Cairo.line_to cr 115.23 124.75;
        Cairo.curve_to cr 112.23 121.57 114.91 117.25 116.23 114.81;
        Cairo.curve_to cr 117.93 111.69 124.83 117.32 126.72 115.88;
        Cairo.curve_to cr 141.92 103.01 156.13 87.44 170.36 72.51;
        Cairo.curve_to cr 173.34 69.38 167.59 65.27 165.59 63.83;
        Cairo.curve_to cr 159.29 59.29 144.76 74.47 146.36 57.74;
        Cairo.curve_to cr 146.98 51.26 159.88 39.14 166.61 44.99;
        Cairo.curve_to cr 184.78 60.79 201.40 78.14 217.12 95.93;
        Cairo.curve_to cr 219.01 102.34 205.42 115.82 199.03 115.42;
        Cairo.curve_to cr 189.98 114.86 201.34 101.38 197.33 95.66;
        Cairo.curve_to cr 195.60 93.19 189.73 87.53 186.13 91.11;
        Cairo.line_to cr 146.09 130.89;
        Cairo.line_to cr 146.65 143.92;
        Cairo.Path.close cr;
        Cairo.fill cr;
        (* Underlying curve glyph *)
        Cairo.move_to cr 194.00 177.67;
        Cairo.curve_to cr 196.66 188.47 189.71 199.52 182.32 203.63;
        Cairo.curve_to cr 158.52 216.88 137.39 188.98 120.34 168.89;
        Cairo.curve_to cr 105.40 151.28 88.87 136.25 72.65 119.71;
        Cairo.curve_to cr 68.96 115.94 63.09 114.70 59.42 116.74;
        Cairo.curve_to cr 47.24 123.50 54.88 134.76 45.63 135.65;
        Cairo.curve_to cr 27.42 135.43 43.44 109.53 51.73 106.74;
        Cairo.curve_to cr 59.80 102.36 72.46 102.18 79.04 108.46;
        Cairo.curve_to cr 93.71 122.48 107.83 135.56 120.81 150.92;
        Cairo.curve_to cr 133.49 165.91 147.03 179.29 161.34 192.68;
        Cairo.curve_to cr 165.16 196.26 172.01 194.09 175.80 192.54;
        Cairo.curve_to cr 180.32 190.70 180.63 184.50 181.52 178.11;
        Cairo.curve_to cr 181.97 174.91 193.13 174.16 194.00 177.67;
        Cairo.Path.close cr;
        Cairo.fill cr;
        Cairo.restore cr
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
        let (fr, fg, fb) = icon_rgb () in Cairo.set_source_rgb cr fr fg fb;
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
        let (fr, fg, fb) = icon_rgb () in Cairo.set_source_rgb cr fr fg fb;
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
        let (fr, fg, fb) = icon_rgb () in Cairo.set_source_rgb cr fr fg fb;
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

      let draw_anchor_point_icon cr ~alloc =
        (* Convert Anchor Point: a center anchor square with two
           diagonal handle lines, suggesting a smooth/corner convert. *)
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        let cx = ox +. 14.0 and cy = oy +. 14.0 in
        Cairo.save cr;
        let (fr, fg, fb) = icon_rgb () in Cairo.set_source_rgb cr fr fg fb;
        (* Diagonal handle line *)
        Cairo.set_line_width cr 1.5;
        Cairo.move_to cr (cx -. 10.0) (cy -. 10.0);
        Cairo.line_to cr cx cy;
        Cairo.line_to cr (cx +. 10.0) (cy +. 10.0);
        Cairo.stroke cr;
        (* Handle endpoint circles *)
        let r = 2.5 in
        Cairo.arc cr (cx -. 10.0) (cy -. 10.0) ~r ~a1:0.0 ~a2:(2.0 *. Float.pi);
        Cairo.fill cr;
        Cairo.arc cr (cx +. 10.0) (cy +. 10.0) ~r ~a1:0.0 ~a2:(2.0 *. Float.pi);
        Cairo.fill cr;
        (* Anchor square (filled, with black outline) *)
        let half = 4.0 in
        Cairo.rectangle cr (cx -. half) (cy -. half) ~w:(half *. 2.0) ~h:(half *. 2.0);
        Cairo.fill cr;
        Cairo.set_source_rgb cr 0.0 0.0 0.0;
        Cairo.set_line_width cr 1.0;
        Cairo.rectangle cr (cx -. half) (cy -. half) ~w:(half *. 2.0) ~h:(half *. 2.0);
        Cairo.stroke cr;
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
        let (fr, fg, fb) = icon_rgb () in Cairo.set_source_rgb cr fr fg fb;
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
        let (ir, ig, ib) = inactive_bg_rgb () in Cairo.set_source_rgb cr ir ig ib;
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
        let (fr, fg, fb) = icon_rgb () in Cairo.set_source_rgb cr fr fg fb;
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
        let (ir, ig, ib) = inactive_bg_rgb () in Cairo.set_source_rgb cr ir ig ib;
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
        let (fr, fg, fb) = icon_rgb () in Cairo.set_source_rgb cr fr fg fb;
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
        let (ir, ig, ib) = inactive_bg_rgb () in Cairo.set_source_rgb cr ir ig ib;
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
        let (fr, fg, fb) = icon_rgb () in Cairo.set_source_rgb cr fr fg fb;
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
          let (ar, ag, ab) = active_bg_rgb () in Cairo.set_source_rgb cr ar ag ab;
          Cairo.rectangle cr 0.0 0.0 ~w:bw ~h:bh;
          Cairo.fill cr
        end else begin
          let (ir, ig, ib) = inactive_bg_rgb () in Cairo.set_source_rgb cr ir ig ib;
          Cairo.rectangle cr 0.0 0.0 ~w:bw ~h:bh;
          Cairo.fill cr
        end;
        (match pen_slot_tool with
         | Pen -> draw_pen_icon cr ~alloc
         | Add_anchor_point -> draw_add_anchor_point_icon cr ~alloc
         | Delete_anchor_point -> draw_delete_anchor_point_icon cr ~alloc
         | Anchor_point -> draw_anchor_point_icon cr ~alloc
         | _ -> ());
        (* Alternate triangle *)
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        let s = 5.0 in
        Cairo.move_to cr (ox +. 28.0) (oy +. 28.0);
        Cairo.line_to cr (ox +. 28.0 -. s) (oy +. 28.0);
        Cairo.line_to cr (ox +. 28.0) (oy +. 28.0 -. s);
        Cairo.Path.close cr;
        let (fr, fg, fb) = icon_rgb () in Cairo.set_source_rgb cr fr fg fb;
        Cairo.fill cr;
        true
      ) |> ignore;
      (* Pencil slot: draws pencil or path-eraser depending on pencil_slot_tool *)
      pencil_btn#misc#connect#draw ~callback:(fun cr ->
        let alloc = pencil_btn#misc#allocation in
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        if current_tool = pencil_slot_tool then begin
          let (ar, ag, ab) = active_bg_rgb () in Cairo.set_source_rgb cr ar ag ab;
          Cairo.rectangle cr 0.0 0.0 ~w:bw ~h:bh;
          Cairo.fill cr
        end else begin
          let (ir, ig, ib) = inactive_bg_rgb () in Cairo.set_source_rgb cr ir ig ib;
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
        let (fr, fg, fb) = icon_rgb () in Cairo.set_source_rgb cr fr fg fb;
        Cairo.fill cr;
        true
      ) |> ignore;
      (* Text slot: draws text or text-path depending on text_slot_tool *)
      text_btn#misc#connect#draw ~callback:(fun cr ->
        let alloc = text_btn#misc#allocation in
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        if current_tool = text_slot_tool then begin
          let (ar, ag, ab) = active_bg_rgb () in Cairo.set_source_rgb cr ar ag ab;
          Cairo.rectangle cr 0.0 0.0 ~w:bw ~h:bh;
          Cairo.fill cr
        end else begin
          let (ir, ig, ib) = inactive_bg_rgb () in Cairo.set_source_rgb cr ir ig ib;
          Cairo.rectangle cr 0.0 0.0 ~w:bw ~h:bh;
          Cairo.fill cr
        end;
        (match text_slot_tool with
         | Type_tool -> draw_type_icon cr ~alloc
         | Type_on_path -> draw_type_on_path_icon cr ~alloc
         | _ -> ());
        (* Alternate triangle *)
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        let s = 5.0 in
        Cairo.move_to cr (ox +. 28.0) (oy +. 28.0);
        Cairo.line_to cr (ox +. 28.0 -. s) (oy +. 28.0);
        Cairo.line_to cr (ox +. 28.0) (oy +. 28.0 -. s);
        Cairo.Path.close cr;
        let (fr, fg, fb) = icon_rgb () in Cairo.set_source_rgb cr fr fg fb;
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
          let (ar, ag, ab) = active_bg_rgb () in Cairo.set_source_rgb cr ar ag ab;
          Cairo.rectangle cr 0.0 0.0 ~w:bw ~h:bh;
          Cairo.fill cr
        end else begin
          let (ir, ig, ib) = inactive_bg_rgb () in Cairo.set_source_rgb cr ir ig ib;
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
        let (fr, fg, fb) = icon_rgb () in Cairo.set_source_rgb cr fr fg fb;
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
      (* Pencil slot: click selects, long press shows menu,
         double-click opens tool-options dialog if set. *)
      pencil_btn#event#add [`BUTTON_PRESS; `BUTTON_RELEASE];
      pencil_btn#event#connect#button_press ~callback:(fun ev ->
        if GdkEvent.Button.button ev = 1 then begin
          if GdkEvent.get_type ev = `TWO_BUTTON_PRESS then begin
            (* Cancel any pending long-press timer from the first
               click, then open the tool-options dialog if the tool
               exposes one. See PAINTBRUSH_TOOL.md §Tool options. *)
            (match pencil_long_press_timer with
             | Some id -> GMain.Timeout.remove id; pencil_long_press_timer <- None
             | None -> ());
            (match tool_options_dialog_id pencil_slot_tool with
             | Some dlg_id ->
               (match Yaml_dialog_view.open_dialog dlg_id [] [] with
                | Some ds -> Yaml_dialog_view.show_dialog ds
                | None -> ())
             | None -> ());
            true
          end
          else begin
            pencil_long_press_timer <- Some (GMain.Timeout.add ~ms:long_press_ms ~callback:(fun () ->
              pencil_long_press_timer <- None;
              self#show_pencil_slot_menu;
              false
            ));
            true
          end
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
      draw_tool_button lasso_btn Lasso draw_lasso_icon;
      connect_click lasso_btn Lasso;
      (* Rotate button — own slot, simple click selects. *)
      draw_tool_button rotate_btn Rotate draw_rotate_icon;
      connect_click rotate_btn Rotate;
      (* Scale slot — long-press exposes the Shear alternate, mirroring
         the shape slot pattern. Custom draw shows whichever of
         Scale / Shear is the current slot tool. *)
      scale_btn#misc#connect#draw ~callback:(fun cr ->
        let alloc = scale_btn#misc#allocation in
        let bw = float_of_int alloc.Gtk.width in
        let bh = float_of_int alloc.Gtk.height in
        if current_tool = transform_slot_tool then begin
          let (ar, ag, ab) = active_bg_rgb () in
          Cairo.set_source_rgb cr ar ag ab;
          Cairo.rectangle cr 0.0 0.0 ~w:bw ~h:bh;
          Cairo.fill cr
        end else begin
          let (ir, ig, ib) = inactive_bg_rgb () in
          Cairo.set_source_rgb cr ir ig ib;
          Cairo.rectangle cr 0.0 0.0 ~w:bw ~h:bh;
          Cairo.fill cr
        end;
        (match transform_slot_tool with
         | Scale -> draw_scale_icon cr ~alloc
         | Shear -> draw_shear_icon cr ~alloc
         | _ -> ());
        let ox = (bw -. 28.0) /. 2.0 in
        let oy = (bh -. 28.0) /. 2.0 in
        let s = 5.0 in
        Cairo.move_to cr (ox +. 28.0) (oy +. 28.0);
        Cairo.line_to cr (ox +. 28.0 -. s) (oy +. 28.0);
        Cairo.line_to cr (ox +. 28.0) (oy +. 28.0 -. s);
        Cairo.Path.close cr;
        let (fr, fg, fb) = icon_rgb () in
        Cairo.set_source_rgb cr fr fg fb;
        Cairo.fill cr;
        true
      ) |> ignore;
      scale_btn#event#add [`BUTTON_PRESS; `BUTTON_RELEASE];
      scale_btn#event#connect#button_press ~callback:(fun ev ->
        if GdkEvent.Button.button ev = 1 then begin
          transform_long_press_timer <- Some (GMain.Timeout.add ~ms:long_press_ms ~callback:(fun () ->
            transform_long_press_timer <- None;
            self#show_transform_slot_menu;
            false
          ));
          true
        end else false
      ) |> ignore;
      scale_btn#event#connect#button_release ~callback:(fun ev ->
        if GdkEvent.Button.button ev = 1 then begin
          (match transform_long_press_timer with
           | Some id -> GMain.Timeout.remove id; transform_long_press_timer <- None
           | None -> ());
          current_tool <- transform_slot_tool;
          self#redraw_all;
          true
        end else false
      ) |> ignore;

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

      (* Fill/stroke indicator drawing *)
      fs_area#misc#connect#draw ~callback:(fun cr ->
        let alloc = fs_area#misc#allocation in
        let aw = float_of_int alloc.Gtk.width in
        let ah = float_of_int alloc.Gtk.height in
        (* Background *)
        let (ir, ig, ib) = inactive_bg_rgb () in Cairo.set_source_rgb cr ir ig ib;
        Cairo.rectangle cr 0.0 0.0 ~w:aw ~h:ah;
        Cairo.fill cr;

        let get_fill_color () = match get_model with
          | Some gm -> (gm ())#default_fill
          | None -> None
        in
        let get_stroke_color () = match get_model with
          | Some gm -> (gm ())#default_stroke
          | None -> Some (Element.make_stroke Element.black)
        in

        let sq = 24.0 in
        let offset = 8.0 in
        let base_x = (aw -. sq -. offset) /. 2.0 in
        let base_y = 6.0 in

        (* Draw the fill and stroke squares, with fill_on_top determining order *)
        let draw_fill_square x y =
          match get_fill_color () with
          | Some f ->
            let (r, g, b, _) = Element.color_to_rgba f.Element.fill_color in
            Cairo.set_source_rgb cr r g b;
            Cairo.rectangle cr x y ~w:sq ~h:sq;
            Cairo.fill cr;
            Cairo.set_source_rgb cr 0.0 0.0 0.0;
            Cairo.set_line_width cr 1.0;
            Cairo.rectangle cr x y ~w:sq ~h:sq;
            Cairo.stroke cr
          | None ->
            (* None = white with red diagonal *)
            Cairo.set_source_rgb cr 1.0 1.0 1.0;
            Cairo.rectangle cr x y ~w:sq ~h:sq;
            Cairo.fill cr;
            Cairo.set_source_rgb cr 1.0 0.0 0.0;
            Cairo.set_line_width cr 1.5;
            Cairo.move_to cr x (y +. sq);
            Cairo.line_to cr (x +. sq) y;
            Cairo.stroke cr;
            Cairo.set_source_rgb cr 0.0 0.0 0.0;
            Cairo.set_line_width cr 1.0;
            Cairo.rectangle cr x y ~w:sq ~h:sq;
            Cairo.stroke cr
        in
        let draw_stroke_square x y =
          match get_stroke_color () with
          | Some s ->
            (* Hollow square with thick border *)
            let (r, g, b, _) = Element.color_to_rgba s.Element.stroke_color in
            Cairo.set_source_rgb cr r g b;
            Cairo.set_line_width cr 4.0;
            Cairo.rectangle cr (x +. 2.0) (y +. 2.0)
              ~w:(sq -. 4.0) ~h:(sq -. 4.0);
            Cairo.stroke cr;
            (* White center *)
            Cairo.set_source_rgb cr 1.0 1.0 1.0;
            Cairo.rectangle cr (x +. 5.0) (y +. 5.0)
              ~w:(sq -. 10.0) ~h:(sq -. 10.0);
            Cairo.fill cr
          | None ->
            (* None = white with red diagonal *)
            Cairo.set_source_rgb cr 1.0 1.0 1.0;
            Cairo.rectangle cr x y ~w:sq ~h:sq;
            Cairo.fill cr;
            Cairo.set_source_rgb cr 1.0 0.0 0.0;
            Cairo.set_line_width cr 1.5;
            Cairo.move_to cr x (y +. sq);
            Cairo.line_to cr (x +. sq) y;
            Cairo.stroke cr;
            Cairo.set_source_rgb cr 0.0 0.0 0.0;
            Cairo.set_line_width cr 1.0;
            Cairo.rectangle cr x y ~w:sq ~h:sq;
            Cairo.stroke cr
        in

        let fill_x = base_x and fill_y = base_y in
        let stroke_x = base_x +. offset and stroke_y = base_y +. offset in

        if fill_on_top then begin
          draw_stroke_square stroke_x stroke_y;
          draw_fill_square fill_x fill_y
        end else begin
          draw_fill_square fill_x fill_y;
          draw_stroke_square stroke_x stroke_y
        end;

        (* Swap arrow (top-right corner) *)
        let ax = base_x +. sq +. offset +. 2.0 in
        let ay = base_y in
        let (fr, fg, fb) = icon_rgb () in Cairo.set_source_rgb cr fr fg fb;
        Cairo.set_line_width cr 1.0;
        Cairo.move_to cr ax (ay +. 8.0);
        Cairo.line_to cr (ax +. 8.0) (ay +. 8.0);
        Cairo.line_to cr (ax +. 8.0) ay;
        Cairo.stroke cr;
        (* Arrow heads *)
        Cairo.move_to cr (ax +. 6.0) (ay +. 2.0);
        Cairo.line_to cr (ax +. 8.0) ay;
        Cairo.line_to cr (ax +. 10.0) (ay +. 2.0);
        Cairo.stroke cr;
        Cairo.move_to cr (ax +. 2.0) (ay +. 6.0);
        Cairo.line_to cr ax (ay +. 8.0);
        Cairo.line_to cr (ax +. 2.0) (ay +. 10.0);
        Cairo.stroke cr;

        (* Default reset (bottom-left corner) *)
        let dx = base_x -. 12.0 in
        let dy = base_y +. sq +. offset -. 4.0 in
        (* Small fill square *)
        Cairo.set_source_rgb cr 1.0 1.0 1.0;
        Cairo.rectangle cr dx dy ~w:8.0 ~h:8.0;
        Cairo.fill cr;
        Cairo.set_source_rgb cr 0.0 0.0 0.0;
        Cairo.set_line_width cr 1.0;
        Cairo.rectangle cr dx dy ~w:8.0 ~h:8.0;
        Cairo.stroke cr;
        (* Small stroke square *)
        Cairo.set_source_rgb cr 0.0 0.0 0.0;
        Cairo.set_line_width cr 2.0;
        Cairo.rectangle cr (dx +. 3.0) (dy +. 3.0) ~w:8.0 ~h:8.0;
        Cairo.stroke cr;

        (* Mode buttons row: Color | None *)
        let btn_y = base_y +. sq +. offset +. 10.0 in
        let btn_w = 20.0 and btn_h = 14.0 in
        (* Color button *)
        Cairo.set_source_rgb cr 0.5 0.5 0.5;
        Cairo.rectangle cr base_x btn_y ~w:btn_w ~h:btn_h;
        Cairo.fill cr;
        let (fr, fg, fb) = icon_rgb () in Cairo.set_source_rgb cr fr fg fb;
        Cairo.set_line_width cr 1.0;
        Cairo.rectangle cr base_x btn_y ~w:btn_w ~h:btn_h;
        Cairo.stroke cr;
        (* Gradient button (disabled) *)
        Cairo.set_source_rgb cr 0.35 0.35 0.35;
        Cairo.rectangle cr (base_x +. btn_w +. 2.0) btn_y ~w:btn_w ~h:btn_h;
        Cairo.fill cr;
        Cairo.set_source_rgb cr 0.5 0.5 0.5;
        Cairo.rectangle cr (base_x +. btn_w +. 2.0) btn_y ~w:btn_w ~h:btn_h;
        Cairo.stroke cr;
        (* None button *)
        Cairo.set_source_rgb cr 0.5 0.5 0.5;
        Cairo.rectangle cr (base_x +. (btn_w +. 2.0) *. 2.0) btn_y ~w:btn_w ~h:btn_h;
        Cairo.fill cr;
        let (fr, fg, fb) = icon_rgb () in Cairo.set_source_rgb cr fr fg fb;
        Cairo.rectangle cr (base_x +. (btn_w +. 2.0) *. 2.0) btn_y ~w:btn_w ~h:btn_h;
        Cairo.stroke cr;
        (* Red diagonal for None button *)
        Cairo.set_source_rgb cr 1.0 0.0 0.0;
        Cairo.set_line_width cr 1.0;
        Cairo.move_to cr (base_x +. (btn_w +. 2.0) *. 2.0) (btn_y +. btn_h);
        Cairo.line_to cr (base_x +. (btn_w +. 2.0) *. 2.0 +. btn_w) btn_y;
        Cairo.stroke cr;

        true
      ) |> ignore;

      (* Fill/stroke click events *)
      fs_area#event#add [`BUTTON_PRESS];
      fs_area#event#connect#button_press ~callback:(fun ev ->
        if GdkEvent.Button.button ev = 1 then begin
          let ex = GdkEvent.Button.x ev in
          let ey = GdkEvent.Button.y ev in
          let alloc = fs_area#misc#allocation in
          let aw = float_of_int alloc.Gtk.width in
          let sq = 24.0 and offset = 8.0 in
          let base_x = (aw -. sq -. offset) /. 2.0 in
          let base_y = 6.0 in
          let fill_x = base_x and fill_y = base_y in
          let stroke_x = base_x +. offset and stroke_y = base_y +. offset in

          (* Swap arrow region *)
          let ax = base_x +. sq +. offset +. 2.0 in
          let ay = base_y in
          if ex >= ax && ex <= ax +. 12.0 && ey >= ay && ey <= ay +. 12.0 then begin
            self#swap_fill_stroke;
            true
          end
          (* Default reset region *)
          else
          let dx = base_x -. 12.0 in
          let dy = base_y +. sq +. offset -. 4.0 in
          if ex >= dx && ex <= dx +. 12.0 && ey >= dy && ey <= dy +. 12.0 then begin
            self#reset_defaults;
            true
          end
          (* Mode buttons *)
          else
          let btn_y = base_y +. sq +. offset +. 10.0 in
          let btn_w = 20.0 and btn_h = 14.0 in
          if ey >= btn_y && ey <= btn_y +. btn_h then begin
            (* Color button *)
            if ex >= base_x && ex <= base_x +. btn_w then begin
              (* Open color picker for the active side *)
              (match get_model with
               | Some gm ->
                 let m = gm () in
                 let hex_color c =
                   let (r, g, b, _) = Element.color_to_rgba c in
                   Printf.sprintf "#%02x%02x%02x"
                     (int_of_float (r *. 255.0))
                     (int_of_float (g *. 255.0))
                     (int_of_float (b *. 255.0))
                 in
                 let target = if fill_on_top then "fill" else "stroke" in
                 let live_state = [
                   ("fill_color", `String (hex_color (match m#default_fill with Some f -> f.Element.fill_color | None -> Element.white)));
                   ("stroke_color", `String (hex_color (match m#default_stroke with Some s -> s.Element.stroke_color | None -> Element.black)));
                 ] in
                 (match Yaml_dialog_view.open_dialog "color_picker"
                   [("target", `String target)] live_state with
                  | Some ds -> Yaml_dialog_view.show_dialog ds
                  | None -> ())
               | None -> ());
              true
            end
            (* None button *)
            else if ex >= base_x +. (btn_w +. 2.0) *. 2.0
                 && ex <= base_x +. (btn_w +. 2.0) *. 2.0 +. btn_w then begin
              (match get_model with
               | Some gm ->
                 let m = gm () in
                 if fill_on_top then m#set_default_fill None
                 else m#set_default_stroke None;
                 fs_area#misc#queue_draw ()
               | None -> ());
              true
            end
            else false
          end
          (* Click on fill square to bring to front *)
          else if ex >= fill_x && ex <= fill_x +. sq
               && ey >= fill_y && ey <= fill_y +. sq then begin
            let is_double = GdkEvent.get_type ev = `TWO_BUTTON_PRESS in
            if is_double then begin
              (* Double-click opens color picker *)
              (match get_model with
               | Some gm ->
                 let m = gm () in
                 let initial = match m#default_fill with
                   | Some f -> f.Element.fill_color | None -> Element.white in
                 let hex_color c =
                   let (r, g, b, _) = Element.color_to_rgba c in
                   Printf.sprintf "#%02x%02x%02x"
                     (int_of_float (r *. 255.0))
                     (int_of_float (g *. 255.0))
                     (int_of_float (b *. 255.0))
                 in
                 let live_state = [
                   ("fill_color", `String (hex_color initial));
                   ("stroke_color", `String (hex_color (match m#default_stroke with Some s -> s.Element.stroke_color | None -> Element.black)));
                 ] in
                 (match Yaml_dialog_view.open_dialog "color_picker"
                   [("target", `String "fill")] live_state with
                  | Some ds -> Yaml_dialog_view.show_dialog ds
                  | None -> ())
               | None -> ())
            end else
              fill_on_top <- true;
            fs_area#misc#queue_draw ();
            true
          end
          (* Click on stroke square to bring to front *)
          else if ex >= stroke_x && ex <= stroke_x +. sq
               && ey >= stroke_y && ey <= stroke_y +. sq then begin
            let is_double = GdkEvent.get_type ev = `TWO_BUTTON_PRESS in
            if is_double then begin
              (* Double-click opens color picker *)
              (match get_model with
               | Some gm ->
                 let m = gm () in
                 let initial = match m#default_stroke with
                   | Some s -> s.Element.stroke_color | None -> Element.black in
                 let hex_color c =
                   let (r, g, b, _) = Element.color_to_rgba c in
                   Printf.sprintf "#%02x%02x%02x"
                     (int_of_float (r *. 255.0))
                     (int_of_float (g *. 255.0))
                     (int_of_float (b *. 255.0))
                 in
                 let live_state = [
                   ("fill_color", `String (hex_color (match m#default_fill with Some f -> f.Element.fill_color | None -> Element.white)));
                   ("stroke_color", `String (hex_color initial));
                 ] in
                 (match Yaml_dialog_view.open_dialog "color_picker"
                   [("target", `String "stroke")] live_state with
                  | Some ds -> Yaml_dialog_view.show_dialog ds
                  | None -> ())
               | None -> ())
            end else
              fill_on_top <- false;
            fs_area#misc#queue_draw ();
            true
          end
          else false
        end else false
      ) |> ignore;

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
      add_item "Anchor Point" Anchor_point;
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
      add_item "Partial Selection" Partial_selection;
      add_item "Interior Selection" Interior_selection;
      add_item "Magic Wand" Magic_wand;
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
      add_item "Type" Type_tool;
      add_item "Type on a Path" Type_on_path;
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

    method private show_transform_slot_menu =
      let menu = GMenu.menu () in
      let add_item label tool =
        let item = GMenu.check_menu_item ~label ~packing:menu#append () in
        item#set_active (transform_slot_tool = tool);
        item#connect#activate ~callback:(fun () ->
          transform_slot_tool <- tool;
          current_tool <- tool;
          self#redraw_all
        ) |> ignore
      in
      add_item "Scale" Scale;
      add_item "Shear" Shear;
      menu#popup ~button:1 ~time:(GtkMain.Main.get_current_event_time ())
  end

let create ~title ~x ~y ?get_model fixed =
  new toolbar ~title ~x ~y ?get_model fixed
