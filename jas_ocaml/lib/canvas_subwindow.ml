(** A floating canvas subwindow embedded inside the main workspace. *)

(** Axis-aligned bounding box for the canvas coordinate space. *)
type bounding_box = {
  bbox_x : float;
  bbox_y : float;
  bbox_width : float;
  bbox_height : float;
}

let make_bounding_box ?(x = 0.0) ?(y = 0.0) ?(width = 800.0) ?(height = 600.0) () =
  { bbox_x = x; bbox_y = y; bbox_width = width; bbox_height = height }

let title_bar_height = 24

(** Draw an element to a Cairo context. *)
let rec draw_element cr (elem : Element.element) =
  let open Element in
  Cairo.save cr;
  begin match elem with
  | Line { x1; y1; x2; y2; stroke; opacity; transform } ->
    Cairo.Group.push cr;
    apply_transform cr transform;
    apply_stroke cr stroke;
    Cairo.move_to cr x1 y1;
    Cairo.line_to cr x2 y2;
    Cairo.stroke cr;
    Cairo.Group.pop_to_source cr;
    Cairo.paint cr ~alpha:opacity

  | Rect { x; y; width; height; rx; ry; fill; stroke; opacity; transform } ->
    Cairo.Group.push cr;
    apply_transform cr transform;
    if rx > 0.0 || ry > 0.0 then
      rounded_rect cr x y width height rx ry
    else
      Cairo.rectangle cr x y ~w:width ~h:height;
    fill_and_stroke cr fill stroke;
    Cairo.Group.pop_to_source cr;
    Cairo.paint cr ~alpha:opacity

  | Circle { cx; cy; r; fill; stroke; opacity; transform } ->
    Cairo.Group.push cr;
    apply_transform cr transform;
    Cairo.arc cr cx cy ~r ~a1:0.0 ~a2:(2.0 *. Float.pi);
    fill_and_stroke cr fill stroke;
    Cairo.Group.pop_to_source cr;
    Cairo.paint cr ~alpha:opacity

  | Ellipse { cx; cy; rx; ry; fill; stroke; opacity; transform } ->
    Cairo.Group.push cr;
    apply_transform cr transform;
    Cairo.save cr;
    Cairo.translate cr cx cy;
    Cairo.scale cr rx ry;
    Cairo.arc cr 0.0 0.0 ~r:1.0 ~a1:0.0 ~a2:(2.0 *. Float.pi);
    Cairo.restore cr;
    fill_and_stroke cr fill stroke;
    Cairo.Group.pop_to_source cr;
    Cairo.paint cr ~alpha:opacity

  | Polyline { points; fill; stroke; opacity; transform } ->
    Cairo.Group.push cr;
    apply_transform cr transform;
    draw_points cr points false;
    fill_and_stroke cr fill stroke;
    Cairo.Group.pop_to_source cr;
    Cairo.paint cr ~alpha:opacity

  | Polygon { points; fill; stroke; opacity; transform } ->
    Cairo.Group.push cr;
    apply_transform cr transform;
    draw_points cr points true;
    fill_and_stroke cr fill stroke;
    Cairo.Group.pop_to_source cr;
    Cairo.paint cr ~alpha:opacity

  | Path { d; fill; stroke; opacity; transform } ->
    Cairo.Group.push cr;
    apply_transform cr transform;
    build_path cr d;
    fill_and_stroke cr fill stroke;
    Cairo.Group.pop_to_source cr;
    Cairo.paint cr ~alpha:opacity

  | Text { x; y; content; font_family; font_size; fill; opacity; transform; _ } ->
    Cairo.Group.push cr;
    apply_transform cr transform;
    begin match fill with
    | Some { fill_color = c } -> Cairo.set_source_rgba cr c.r c.g c.b c.a
    | None -> Cairo.set_source_rgb cr 0.0 0.0 0.0
    end;
    Cairo.select_font_face cr font_family;
    Cairo.set_font_size cr font_size;
    Cairo.move_to cr x y;
    Cairo.show_text cr content;
    Cairo.Group.pop_to_source cr;
    Cairo.paint cr ~alpha:opacity

  | Group { children; opacity; transform } ->
    Cairo.Group.push cr;
    apply_transform cr transform;
    List.iter (draw_element cr) children;
    Cairo.Group.pop_to_source cr;
    Cairo.paint cr ~alpha:opacity

  | Layer { children; opacity; transform; _ } ->
    Cairo.Group.push cr;
    apply_transform cr transform;
    List.iter (draw_element cr) children;
    Cairo.Group.pop_to_source cr;
    Cairo.paint cr ~alpha:opacity
  end;
  Cairo.restore cr

and apply_transform cr = function
  | None -> ()
  | Some (t : Element.transform) ->
    let open Cairo in
    let m = { xx = t.a; yx = t.b; xy = t.c; yy = t.d; x0 = t.e; y0 = t.f } in
    Cairo.transform cr m

and apply_stroke cr = function
  | None -> ()
  | Some (s : Element.stroke) ->
    Cairo.set_source_rgba cr s.stroke_color.r s.stroke_color.g s.stroke_color.b s.stroke_color.a;
    Cairo.set_line_width cr s.stroke_width;
    begin match s.stroke_linecap with
    | Butt -> Cairo.set_line_cap cr Cairo.BUTT
    | Round_cap -> Cairo.set_line_cap cr Cairo.ROUND
    | Square -> Cairo.set_line_cap cr Cairo.SQUARE
    end;
    begin match s.stroke_linejoin with
    | Miter -> Cairo.set_line_join cr Cairo.JOIN_MITER
    | Round_join -> Cairo.set_line_join cr Cairo.JOIN_ROUND
    | Bevel -> Cairo.set_line_join cr Cairo.JOIN_BEVEL
    end

and fill_and_stroke cr fill stroke =
  let has_fill = fill <> None in
  let has_stroke = stroke <> None in
  if has_fill && has_stroke then begin
    (match fill with
     | Some (f : Element.fill) -> Cairo.set_source_rgba cr f.fill_color.r f.fill_color.g f.fill_color.b f.fill_color.a
     | None -> ());
    Cairo.fill_preserve cr;
    apply_stroke cr stroke;
    Cairo.stroke cr
  end else if has_fill then begin
    (match fill with
     | Some (f : Element.fill) -> Cairo.set_source_rgba cr f.fill_color.r f.fill_color.g f.fill_color.b f.fill_color.a
     | None -> ());
    Cairo.fill cr
  end else if has_stroke then begin
    apply_stroke cr stroke;
    Cairo.stroke cr
  end

and draw_points cr points close =
  match points with
  | [] -> ()
  | (x, y) :: rest ->
    Cairo.move_to cr x y;
    List.iter (fun (px, py) -> Cairo.line_to cr px py) rest;
    if close then Cairo.Path.close cr

and build_path cr cmds =
  let _last_ctrl = ref None in
  List.iter (fun cmd ->
    let open Element in
    match cmd with
    | MoveTo (x, y) ->
      Cairo.move_to cr x y; _last_ctrl := None
    | LineTo (x, y) ->
      Cairo.line_to cr x y; _last_ctrl := None
    | CurveTo (x1, y1, x2, y2, x, y) ->
      Cairo.curve_to cr x1 y1 x2 y2 x y;
      _last_ctrl := Some (x2, y2)
    | SmoothCurveTo (x2, y2, x, y) ->
      let (cx, cy) = Cairo.Path.get_current_point cr in
      let (c1x, c1y) = match !_last_ctrl with
        | Some (lx, ly) -> (2.0 *. cx -. lx, 2.0 *. cy -. ly)
        | None -> (cx, cy)
      in
      Cairo.curve_to cr c1x c1y x2 y2 x y;
      _last_ctrl := Some (x2, y2)
    | QuadTo (x1, y1, x, y) ->
      (* Convert quadratic to cubic *)
      let (cx, cy) = Cairo.Path.get_current_point cr in
      let c1x = cx +. 2.0 /. 3.0 *. (x1 -. cx) in
      let c1y = cy +. 2.0 /. 3.0 *. (y1 -. cy) in
      let c2x = x +. 2.0 /. 3.0 *. (x1 -. x) in
      let c2y = y +. 2.0 /. 3.0 *. (y1 -. y) in
      Cairo.curve_to cr c1x c1y c2x c2y x y;
      _last_ctrl := Some (x1, y1)
    | SmoothQuadTo (x, y) ->
      let (cx, cy) = Cairo.Path.get_current_point cr in
      let (x1, y1) = match !_last_ctrl with
        | Some (lx, ly) -> (2.0 *. cx -. lx, 2.0 *. cy -. ly)
        | None -> (cx, cy)
      in
      let c1x = cx +. 2.0 /. 3.0 *. (x1 -. cx) in
      let c1y = cy +. 2.0 /. 3.0 *. (y1 -. cy) in
      let c2x = x +. 2.0 /. 3.0 *. (x1 -. x) in
      let c2y = y +. 2.0 /. 3.0 *. (y1 -. y) in
      Cairo.curve_to cr c1x c1y c2x c2y x y;
      _last_ctrl := Some (x1, y1)
    | ArcTo (_, _, _, _, _, x, y) ->
      (* Approximate arc with line to endpoint *)
      Cairo.line_to cr x y; _last_ctrl := None
    | ClosePath ->
      Cairo.Path.close cr; _last_ctrl := None
  ) cmds

and rounded_rect cr x y w h rx ry =
  let rx = min rx (w /. 2.0) in
  let ry = min ry (h /. 2.0) in
  Cairo.move_to cr (x +. rx) y;
  Cairo.line_to cr (x +. w -. rx) y;
  Cairo.curve_to cr (x +. w) y (x +. w) (y +. ry) (x +. w) (y +. ry);
  Cairo.line_to cr (x +. w) (y +. h -. ry);
  Cairo.curve_to cr (x +. w) (y +. h) (x +. w -. rx) (y +. h) (x +. w -. rx) (y +. h);
  Cairo.line_to cr (x +. rx) (y +. h);
  Cairo.curve_to cr x (y +. h) x (y +. h -. ry) x (y +. h -. ry);
  Cairo.line_to cr x (y +. ry);
  Cairo.curve_to cr x y (x +. rx) y (x +. rx) y

class canvas_subwindow ~(model : Model.model) ~x ~y ~width ~height ~(bbox : bounding_box) (fixed : GPack.fixed) =
  let frame = GBin.frame ~shadow_type:`ETCHED_IN () in
  let vbox = GPack.vbox ~packing:frame#add () in

  (* Title bar *)
  let title_bar = GMisc.drawing_area
    ~packing:(vbox#pack ~expand:false) () in
  let () = title_bar#misc#set_size_request ~height:title_bar_height () in

  (* Canvas drawing area *)
  let canvas_area = GMisc.drawing_area
    ~packing:(vbox#pack ~expand:true ~fill:true) () in
  object (_self)
    val mutable pos_x = x
    val mutable pos_y = y
    val mutable sub_width = width
    val mutable sub_height = height
    val mutable dragging = false
    val mutable drag_offset_x = 0.0
    val mutable drag_offset_y = 0.0
    val mutable current_doc = model#document

    method widget = frame#coerce
    method canvas = canvas_area
    method model = model
    method title = current_doc.Document.title
    method x = pos_x
    method y = pos_y
    method bbox = bbox

    initializer
      fixed#put frame#coerce ~x:pos_x ~y:pos_y;
      frame#misc#set_size_request ~width:sub_width ~height:sub_height ();

      (* Register for document changes *)
      model#on_document_changed (fun doc ->
        current_doc <- doc;
        title_bar#misc#queue_draw ();
        canvas_area#misc#queue_draw ()
      );

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
        Cairo.set_font_size cr 13.0;
        let title = current_doc.Document.title in
        let extents = Cairo.text_extents cr title in
        let tx = (w -. extents.Cairo.width) /. 2.0 in
        let ty = (h +. extents.Cairo.height) /. 2.0 in
        Cairo.move_to cr tx ty;
        Cairo.show_text cr title;
        true
      ) |> ignore;

      (* Draw canvas: white background, then document layers *)
      canvas_area#misc#connect#draw ~callback:(fun cr ->
        let alloc = canvas_area#misc#allocation in
        let w = float_of_int alloc.Gtk.width in
        let h = float_of_int alloc.Gtk.height in
        Cairo.set_source_rgb cr 1.0 1.0 1.0;
        Cairo.rectangle cr 0.0 0.0 ~w ~h;
        Cairo.fill cr;
        List.iter (draw_element cr) current_doc.Document.layers;
        true
      ) |> ignore;

      (* Title bar drag events *)
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

let create ?(model = Model.create ()) ~x ~y ~width ~height ?(bbox = make_bounding_box ()) fixed =
  new canvas_subwindow ~model ~x ~y ~width ~height ~bbox fixed
