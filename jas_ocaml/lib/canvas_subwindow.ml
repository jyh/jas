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

let handle_size = 6.0

let control_points (elem : Element.element) =
  let open Element in
  match elem with
  | Line { x1; y1; x2; y2; _ } -> [(x1, y1); (x2, y2)]
  | Rect { x; y; width; height; _ } ->
    [(x, y); (x +. width, y); (x +. width, y +. height); (x, y +. height)]
  | Circle { cx; cy; r; _ } ->
    [(cx, cy -. r); (cx +. r, cy); (cx, cy +. r); (cx -. r, cy)]
  | Ellipse { cx; cy; rx; ry; _ } ->
    [(cx, cy -. ry); (cx +. rx, cy); (cx, cy +. ry); (cx -. rx, cy)]
  | _ ->
    let (bx, by, bw, bh) = Element.bounds elem in
    [(bx, by); (bx +. bw, by); (bx +. bw, by +. bh); (bx, by +. bh)]

let draw_element_overlay cr (elem : Element.element) (selected_cps : int list) =
  let open Element in
  Cairo.set_source_rgb cr 0.0 0.47 1.0;
  Cairo.set_line_width cr 1.0;
  Cairo.set_dash cr [||];
  begin match elem with
  | Line { x1; y1; x2; y2; _ } ->
    Cairo.move_to cr x1 y1;
    Cairo.line_to cr x2 y2;
    Cairo.stroke cr
  | Rect { x; y; width; height; rx; ry; _ } ->
    if rx > 0.0 || ry > 0.0 then
      rounded_rect cr x y width height rx ry
    else
      Cairo.rectangle cr x y ~w:width ~h:height;
    Cairo.stroke cr
  | Circle { cx; cy; r; _ } ->
    Cairo.arc cr cx cy ~r ~a1:0.0 ~a2:(2.0 *. Float.pi);
    Cairo.stroke cr
  | Ellipse { cx; cy; rx; ry; _ } ->
    Cairo.save cr;
    Cairo.translate cr cx cy;
    Cairo.scale cr rx ry;
    Cairo.arc cr 0.0 0.0 ~r:1.0 ~a1:0.0 ~a2:(2.0 *. Float.pi);
    Cairo.restore cr;
    Cairo.stroke cr
  | Polyline { points; _ } ->
    draw_points cr points false;
    Cairo.stroke cr
  | Polygon { points; _ } ->
    draw_points cr points true;
    Cairo.stroke cr
  | Path { d; _ } ->
    build_path cr d;
    Cairo.stroke cr
  | _ ->
    let (bx, by, bw, bh) = Element.bounds elem in
    Cairo.rectangle cr bx by ~w:bw ~h:bh;
    Cairo.stroke cr
  end;
  (* Draw handles *)
  let half = handle_size /. 2.0 in
  List.iteri (fun i (px, py) ->
    Cairo.rectangle cr (px -. half) (py -. half) ~w:handle_size ~h:handle_size;
    if List.mem i selected_cps then
      Cairo.set_source_rgb cr 0.0 0.47 1.0
    else
      Cairo.set_source_rgb cr 1.0 1.0 1.0;
    Cairo.fill_preserve cr;
    Cairo.set_source_rgb cr 0.0 0.47 1.0;
    Cairo.stroke cr
  ) (control_points elem)

let draw_selection_overlays cr (doc : Document.document) =
  let open Document in
  PathMap.iter (fun path (es : element_selection) ->
    match path with
    | [] -> ()
    | _ ->
      Cairo.save cr;
      let node = ref (List.nth doc.layers (List.hd path)) in
      if List.length path > 1 then begin
        apply_transform cr (match !node with
          | Element.Layer { transform; _ } -> transform
          | Element.Group { transform; _ } -> transform
          | _ -> None);
        let rest = List.tl path in
        let intermediate = List.filteri (fun i _ -> i < List.length rest - 1) rest in
        List.iter (fun idx ->
          let children = match !node with
            | Element.Group { children; _ } | Element.Layer { children; _ } -> children
            | _ -> []
          in
          node := List.nth children idx;
          apply_transform cr (match !node with
            | Element.Group { transform; _ } | Element.Layer { transform; _ } -> transform
            | _ -> None)
        ) intermediate;
        let children = match !node with
          | Element.Group { children; _ } | Element.Layer { children; _ } -> children
          | _ -> []
        in
        let last_idx = List.nth rest (List.length rest - 1) in
        node := List.nth children last_idx
      end;
      (* Apply the selected element's own transform *)
      apply_transform cr (match !node with
        | Element.Line { transform; _ } | Element.Rect { transform; _ }
        | Element.Circle { transform; _ } | Element.Ellipse { transform; _ }
        | Element.Polyline { transform; _ } | Element.Polygon { transform; _ }
        | Element.Path { transform; _ } | Element.Text { transform; _ }
        | Element.Group { transform; _ } | Element.Layer { transform; _ } -> transform);
      draw_element_overlay cr !node es.es_control_points;
      Cairo.restore cr
  ) doc.selection

class canvas_subwindow ~(model : Model.model) ~(controller : Controller.controller)
    ~(toolbar : Toolbar.toolbar) ~x ~y ~width ~height ~(bbox : bounding_box) (fixed : GPack.fixed) =
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
    (* Line tool drag state *)
    val mutable line_drag_start : (float * float) option = None
    val mutable line_drag_end : (float * float) option = None

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

      (* Draw canvas: white background, then document layers, then drag preview *)
      canvas_area#misc#connect#draw ~callback:(fun cr ->
        let alloc = canvas_area#misc#allocation in
        let w = float_of_int alloc.Gtk.width in
        let h = float_of_int alloc.Gtk.height in
        Cairo.set_source_rgb cr 1.0 1.0 1.0;
        Cairo.rectangle cr 0.0 0.0 ~w ~h;
        Cairo.fill cr;
        List.iter (draw_element cr) current_doc.Document.layers;
        (* Draw selection overlays *)
        draw_selection_overlays cr current_doc;
        (* Draw drag preview *)
        begin match line_drag_start, line_drag_end with
        | Some (sx, sy), Some (ex, ey) ->
          Cairo.set_source_rgba cr 0.4 0.4 0.4 1.0;
          Cairo.set_line_width cr 1.0;
          Cairo.set_dash cr [| 4.0; 4.0 |];
          if toolbar#current_tool = Toolbar.Rect || toolbar#current_tool = Toolbar.Selection then begin
            let x = min sx ex in
            let y = min sy ey in
            let w = abs_float (ex -. sx) in
            let h = abs_float (ey -. sy) in
            Cairo.rectangle cr x y ~w ~h
          end else begin
            Cairo.move_to cr sx sy;
            Cairo.line_to cr ex ey
          end;
          Cairo.stroke cr;
          Cairo.set_dash cr [||]
        | _ -> ()
        end;
        true
      ) |> ignore;

      (* Canvas mouse events for line tool *)
      canvas_area#event#add [`BUTTON_PRESS; `BUTTON_RELEASE; `POINTER_MOTION];
      canvas_area#event#connect#button_press ~callback:(fun ev ->
        if (toolbar#current_tool = Toolbar.Selection
            || toolbar#current_tool = Toolbar.Line
            || toolbar#current_tool = Toolbar.Rect)
           && GdkEvent.Button.button ev = 1 then begin
          let x = GdkEvent.Button.x ev in
          let y = GdkEvent.Button.y ev in
          line_drag_start <- Some (x, y);
          line_drag_end <- Some (x, y);
          true
        end else false
      ) |> ignore;
      canvas_area#event#connect#motion_notify ~callback:(fun ev ->
        begin match line_drag_start with
        | Some _ ->
          let x = GdkEvent.Motion.x ev in
          let y = GdkEvent.Motion.y ev in
          line_drag_end <- Some (x, y);
          canvas_area#misc#queue_draw ();
          true
        | None -> false
        end
      ) |> ignore;
      canvas_area#event#connect#button_release ~callback:(fun ev ->
        begin match line_drag_start with
        | Some (sx, sy) when GdkEvent.Button.button ev = 1 ->
          let ex = GdkEvent.Button.x ev in
          let ey = GdkEvent.Button.y ev in
          line_drag_start <- None;
          line_drag_end <- None;
          if toolbar#current_tool = Toolbar.Selection then begin
            let x = min sx ex in
            let y = min sy ey in
            let w = abs_float (ex -. sx) in
            let h = abs_float (ey -. sy) in
            controller#select_rect x y w h;
            true
          end else
          let default_stroke = Some Element.{
            stroke_color = { r = 0.0; g = 0.0; b = 0.0; a = 1.0 };
            stroke_width = 1.0;
            stroke_linecap = Butt;
            stroke_linejoin = Miter;
          } in
          let elem = if toolbar#current_tool = Toolbar.Rect then
            Element.Rect {
              x = min sx ex; y = min sy ey;
              width = abs_float (ex -. sx); height = abs_float (ey -. sy);
              rx = 0.0; ry = 0.0;
              fill = None; stroke = default_stroke;
              opacity = 1.0; transform = None;
            }
          else
            Element.Line {
              x1 = sx; y1 = sy; x2 = ex; y2 = ey;
              stroke = default_stroke;
              opacity = 1.0; transform = None;
            }
          in
          let line = elem in
          controller#add_element line;
          true
        | _ ->
          line_drag_start <- None;
          line_drag_end <- None;
          false
        end
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

let create ?(model = Model.create ()) ~controller ~toolbar ~x ~y ~width ~height ?(bbox = make_bounding_box ()) fixed =
  new canvas_subwindow ~model ~controller ~toolbar ~x ~y ~width ~height ~bbox fixed
