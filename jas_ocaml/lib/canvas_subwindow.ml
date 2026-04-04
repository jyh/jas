(** A floating canvas subwindow embedded inside the main workspace. *)

[@@@warning "-32"]

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

  | Text { x; y; content; font_family; font_size; text_width; text_height; fill; opacity; transform; _ } ->
    Cairo.Group.push cr;
    apply_transform cr transform;
    begin match fill with
    | Some { fill_color = c } -> Cairo.set_source_rgba cr c.r c.g c.b c.a
    | None -> Cairo.set_source_rgb cr 0.0 0.0 0.0
    end;
    if text_width > 0.0 && text_height > 0.0 then begin
      (* Area text: use Pango for word wrapping *)
      let layout = Pango.Layout.create (Cairo_pango.Font_map.create_context (Cairo_pango.Font_map.get_default ())) in
      let font_desc = Pango.Font.from_string (Printf.sprintf "%s %d" font_family (int_of_float font_size)) in
      Pango.Layout.set_font_description layout font_desc;
      Pango.Layout.set_text layout content;
      Pango.Layout.set_width layout (int_of_float (text_width *. float_of_int Pango.scale));
      Pango.Layout.set_wrap layout `WORD;
      Cairo.move_to cr x y;
      Cairo_pango.show_layout cr layout
    end else begin
      Cairo.select_font_face cr font_family;
      Cairo.set_font_size cr font_size;
      Cairo.move_to cr x y;
      Cairo.show_text cr content
    end;
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

let constrain_angle sx sy ex ey =
  let dx = ex -. sx and dy = ey -. sy in
  let dist = sqrt (dx *. dx +. dy *. dy) in
  if dist = 0.0 then (ex, ey)
  else
    let angle = atan2 dy dx in
    let snapped = Float.round (angle /. (Float.pi /. 4.0)) *. (Float.pi /. 4.0) in
    (sx +. dist *. cos snapped, sy +. dist *. sin snapped)

let polygon_sides = 5

let regular_polygon_points x1 y1 x2 y2 n =
  let ex = x2 -. x1 and ey = y2 -. y1 in
  let s = sqrt (ex *. ex +. ey *. ey) in
  if s = 0.0 then List.init n (fun _ -> (x1, y1))
  else
    let mx = (x1 +. x2) /. 2.0 and my = (y1 +. y2) /. 2.0 in
    let px = -. ey /. s and py = ex /. s in
    let d = s /. (2.0 *. tan (Float.pi /. float_of_int n)) in
    let cx = mx +. d *. px and cy = my +. d *. py in
    let r = s /. (2.0 *. sin (Float.pi /. float_of_int n)) in
    let theta0 = atan2 (y1 -. cy) (x1 -. cx) in
    List.init n (fun k ->
      let angle = theta0 +. 2.0 *. Float.pi *. float_of_int k /. float_of_int n in
      (cx +. r *. cos angle, cy +. r *. sin angle))

let handle_size = 6.0

(** A control point in the pen tool's in-progress path. *)
type pen_point = {
  mutable px : float;
  mutable py : float;
  mutable hx_in : float;
  mutable hy_in : float;
  mutable hx_out : float;
  mutable hy_out : float;
  mutable smooth : bool;
}

let make_pen_point x y =
  { px = x; py = y; hx_in = x; hy_in = y; hx_out = x; hy_out = y; smooth = false }

let control_points (elem : Element.element) =
  Element.control_points elem

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
    (* Move-drag state *)
    val mutable moving = false
    val hit_radius = 6.0
    (* Inline text editing state *)
    val mutable text_editor : GEdit.entry option = None
    val mutable editing_path : int list option = None
    (* Pen tool state *)
    val mutable pen_points : pen_point list = []
    val mutable pen_dragging = false
    val mutable pen_mouse_x = 0.0
    val mutable pen_mouse_y = 0.0

    method widget = frame#coerce
    method canvas = canvas_area
    method model = model
    method title = current_doc.Document.title
    method x = pos_x
    method y = pos_y
    method bbox = bbox

    method private hit_test_text px py =
      let doc = current_doc in
      let result = ref None in
      List.iteri (fun li layer ->
        let children = match layer with
          | Element.Layer { children; _ } -> children
          | _ -> []
        in
        List.iteri (fun ci child ->
          if !result = None then
            match child with
            | Element.Text _ ->
              let (bx, by, bw, bh) = Element.bounds child in
              if px >= bx && px <= bx +. bw && py >= by && py <= by +. bh then
                result := Some ([li; ci], child)
            | _ -> ()
        ) children
      ) doc.Document.layers;
      !result

    method private commit_text_edit =
      match text_editor, editing_path with
      | Some entry, Some path ->
        let new_text = entry#text in
        let doc = current_doc in
        (try
          let old_elem = Document.get_element doc path in
          (match old_elem with
           | Element.Text t when t.content <> new_text ->
             let new_elem = Element.Text { t with content = new_text } in
             model#set_document (Document.replace_element doc path new_elem)
           | _ -> ())
        with _ -> ());
        entry#misc#hide ();
        entry#destroy ();
        text_editor <- None;
        editing_path <- None
      | _ -> ()

    method private start_text_edit path text_elem =
      _self#commit_text_edit;
      editing_path <- Some path;
      match text_elem with
      | Element.Text { x = tx; y = ty; content; font_size; font_family; _ } ->
        let entry = GEdit.entry ~packing:(fun w ->
          fixed#put w ~x:(pos_x + int_of_float tx) ~y:(pos_y + int_of_float (ty -. font_size))
        ) () in
        entry#set_text content;
        let font_desc = GPango.font_description_from_string (Printf.sprintf "%s %d" font_family (int_of_float font_size)) in
        entry#misc#modify_font font_desc;
        let bw = max (int_of_float (float_of_int (String.length content) *. font_size *. 0.6) + 20) 100 in
        entry#misc#set_size_request ~width:bw ~height:(int_of_float font_size + 4) ();
        entry#connect#activate ~callback:(fun () -> _self#commit_text_edit) |> ignore;
        entry#misc#show ();
        entry#misc#grab_focus ();
        entry#select_region ~start:0 ~stop:(String.length content);
        text_editor <- Some entry
      | _ -> ()

    val pen_close_radius = 6.0

    method pen_finish_close = _self#pen_finish_impl true
    method pen_finish = _self#pen_finish_impl false

    method private pen_finish_impl force_close =
      let pts = List.rev pen_points in
      let n = List.length pts in
      if n >= 2 then begin
        let p0 = List.hd pts in
        let pn = List.nth pts (n - 1) in
        let dist = sqrt ((pn.px -. p0.px) ** 2.0 +. (pn.py -. p0.py) ** 2.0) in
        let close = force_close || (n >= 3 && dist <= pen_close_radius) in
        (* Only skip last point if it actually coincides with start *)
        let skip_last = close && n >= 3 && dist <= pen_close_radius in
        let use_pts = if skip_last then List.filteri (fun i _ -> i < n - 1) pts else pts in
        let rest = List.tl use_pts in
        let cmds = ref [Element.MoveTo (p0.px, p0.py)] in
        let prev = ref p0 in
        List.iter (fun curr ->
          cmds := Element.CurveTo (!prev.hx_out, !prev.hy_out,
                                   curr.hx_in, curr.hy_in,
                                   curr.px, curr.py) :: !cmds;
          prev := curr
        ) rest;
        if close then begin
          let last = !prev in
          cmds := Element.ClosePath :: Element.CurveTo (last.hx_out, last.hy_out,
                                   p0.hx_in, p0.hy_in,
                                   p0.px, p0.py) :: !cmds
        end;
        let default_stroke = Some Element.{
          stroke_color = { r = 0.0; g = 0.0; b = 0.0; a = 1.0 };
          stroke_width = 1.0;
          stroke_linecap = Butt;
          stroke_linejoin = Miter;
        } in
        let elem = Element.make_path ~stroke:default_stroke (List.rev !cmds) in
        controller#add_element elem
      end;
      pen_points <- [];
      pen_dragging <- false;
      canvas_area#misc#queue_draw ()

    method pen_cancel =
      pen_points <- [];
      pen_dragging <- false;
      canvas_area#misc#queue_draw ()

    method private draw_pen_overlay cr =
      let pts = List.rev pen_points in
      if pts = [] then ()
      else begin
        (* Draw committed curve segments *)
        if List.length pts >= 2 then begin
          Cairo.set_source_rgb cr 0.0 0.0 0.0;
          Cairo.set_line_width cr 1.0;
          let p0 = List.hd pts in
          Cairo.move_to cr p0.px p0.py;
          let prev = ref p0 in
          List.iter (fun curr ->
            Cairo.curve_to cr !prev.hx_out !prev.hy_out
              curr.hx_in curr.hy_in curr.px curr.py;
            prev := curr
          ) (List.tl pts);
          Cairo.stroke cr
        end;
        (* Draw preview curve from last point to mouse *)
        if not pen_dragging then begin
          let last = List.hd pen_points in (* pen_points is reversed, head is last *)
          let p0 = List.nth pts 0 in
          let n = List.length pts in
          let dist = sqrt ((pen_mouse_x -. p0.px) ** 2.0 +. (pen_mouse_y -. p0.py) ** 2.0) in
          let near_start = n >= 2 && dist <= pen_close_radius in
          Cairo.set_source_rgba cr 0.4 0.4 0.4 1.0;
          Cairo.set_line_width cr 1.0;
          Cairo.set_dash cr [| 4.0; 4.0 |];
          Cairo.move_to cr last.px last.py;
          if near_start then
            Cairo.curve_to cr last.hx_out last.hy_out
              p0.hx_in p0.hy_in p0.px p0.py
          else
            Cairo.curve_to cr last.hx_out last.hy_out
              pen_mouse_x pen_mouse_y pen_mouse_x pen_mouse_y;
          Cairo.stroke cr;
          Cairo.set_dash cr [||]
        end;
        (* Draw handle lines and anchor points *)
        let half = handle_size /. 2.0 in
        List.iter (fun pt ->
          if pt.smooth then begin
            Cairo.set_source_rgb cr 0.0 0.47 1.0;
            Cairo.set_line_width cr 1.0;
            Cairo.move_to cr pt.hx_in pt.hy_in;
            Cairo.line_to cr pt.hx_out pt.hy_out;
            Cairo.stroke cr;
            (* Handle circles *)
            Cairo.arc cr pt.hx_in pt.hy_in ~r:3.0 ~a1:0.0 ~a2:(2.0 *. Float.pi);
            Cairo.set_source_rgb cr 1.0 1.0 1.0;
            Cairo.fill_preserve cr;
            Cairo.set_source_rgb cr 0.0 0.47 1.0;
            Cairo.stroke cr;
            Cairo.arc cr pt.hx_out pt.hy_out ~r:3.0 ~a1:0.0 ~a2:(2.0 *. Float.pi);
            Cairo.set_source_rgb cr 1.0 1.0 1.0;
            Cairo.fill_preserve cr;
            Cairo.set_source_rgb cr 0.0 0.47 1.0;
            Cairo.stroke cr
          end;
          (* Anchor square *)
          Cairo.rectangle cr (pt.px -. half) (pt.py -. half) ~w:handle_size ~h:handle_size;
          Cairo.set_source_rgb cr 0.0 0.47 1.0;
          Cairo.fill_preserve cr;
          Cairo.stroke cr
        ) pts
      end

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
          if moving then begin
            let dx = ex -. sx in
            let dy = ey -. sy in
            Document.PathMap.iter (fun _path (es : Document.element_selection) ->
              let elem = Document.get_element current_doc es.es_path in
              let moved = Element.move_control_points elem es.es_control_points dx dy in
              Cairo.set_source_rgb cr 0.0 0.47 1.0;
              Cairo.set_line_width cr 1.0;
              Cairo.set_dash cr [| 4.0; 4.0 |];
              draw_element_overlay cr moved es.es_control_points;
              Cairo.set_dash cr [||]
            ) current_doc.Document.selection
          end else begin
            Cairo.set_source_rgba cr 0.4 0.4 0.4 1.0;
            Cairo.set_line_width cr 1.0;
            Cairo.set_dash cr [| 4.0; 4.0 |];
            if toolbar#current_tool = Toolbar.Polygon then begin
              let pts = regular_polygon_points sx sy ex ey polygon_sides in
              (match pts with
               | (fx, fy) :: rest ->
                 Cairo.move_to cr fx fy;
                 List.iter (fun (px, py) -> Cairo.line_to cr px py) rest;
                 Cairo.Path.close cr
               | [] -> ())
            end else if toolbar#current_tool = Toolbar.Text_tool || toolbar#current_tool = Toolbar.Rect || toolbar#current_tool = Toolbar.Selection || toolbar#current_tool = Toolbar.Direct_selection || toolbar#current_tool = Toolbar.Group_selection then begin
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
          end
        | _ -> ()
        end;
        (* Draw pen tool overlay *)
        if toolbar#current_tool = Toolbar.Pen then
          _self#draw_pen_overlay cr;
        true
      ) |> ignore;

      (* Canvas mouse events for line tool *)
      canvas_area#event#add [`BUTTON_PRESS; `BUTTON_RELEASE; `POINTER_MOTION];
      canvas_area#event#connect#button_press ~callback:(fun ev ->
        if toolbar#current_tool = Toolbar.Pen && GdkEvent.Button.button ev = 1 then begin
          let event_type = GdkEvent.get_type ev in
          if event_type = `TWO_BUTTON_PRESS then begin
            (* Double click: remove extra point from first click, finish *)
            (match pen_points with _ :: rest -> pen_points <- rest | [] -> ());
            _self#pen_finish;
            true
          end else begin
            let x = GdkEvent.Button.x ev in
            let y = GdkEvent.Button.y ev in
            (* Check if clicking near the start point to close *)
            let pts = List.rev pen_points in
            let n = List.length pts in
            if n >= 2 then begin
              let p0 = List.hd pts in
              let dist = sqrt ((x -. p0.px) ** 2.0 +. (y -. p0.py) ** 2.0) in
              if dist <= pen_close_radius then begin
                _self#pen_finish_close;
                true
              end else begin
                pen_dragging <- true;
                pen_points <- (make_pen_point x y) :: pen_points;
                canvas_area#misc#queue_draw ();
                true
              end
            end else begin
              pen_dragging <- true;
              pen_points <- (make_pen_point x y) :: pen_points;
              canvas_area#misc#queue_draw ();
              true
            end
          end
        end else
        if (toolbar#current_tool = Toolbar.Selection
            || toolbar#current_tool = Toolbar.Direct_selection
            || toolbar#current_tool = Toolbar.Group_selection
            || toolbar#current_tool = Toolbar.Text_tool
            || toolbar#current_tool = Toolbar.Line
            || toolbar#current_tool = Toolbar.Rect
            || toolbar#current_tool = Toolbar.Polygon)
           && GdkEvent.Button.button ev = 1 then begin
          let x = GdkEvent.Button.x ev in
          let y = GdkEvent.Button.y ev in
          (* Check if clicking on a selected CP → move mode *)
          let is_sel_tool = toolbar#current_tool = Toolbar.Selection
            || toolbar#current_tool = Toolbar.Direct_selection
            || toolbar#current_tool = Toolbar.Group_selection in
          let hit = is_sel_tool && Document.PathMap.exists (fun _path (es : Document.element_selection) ->
            let elem = Document.get_element current_doc es.es_path in
            let cps = Element.control_points elem in
            List.exists (fun i ->
              let (px, py) = List.nth cps i in
              abs_float (x -. px) <= hit_radius && abs_float (y -. py) <= hit_radius
            ) es.es_control_points
          ) current_doc.Document.selection in
          line_drag_start <- Some (x, y);
          line_drag_end <- Some (x, y);
          moving <- hit;
          true
        end else false
      ) |> ignore;
      canvas_area#event#connect#motion_notify ~callback:(fun ev ->
        if toolbar#current_tool = Toolbar.Pen then begin
          let x = GdkEvent.Motion.x ev in
          let y = GdkEvent.Motion.y ev in
          pen_mouse_x <- x;
          pen_mouse_y <- y;
          if pen_dragging then begin
            match pen_points with
            | pt :: _ ->
              pt.hx_out <- x;
              pt.hy_out <- y;
              pt.hx_in <- 2.0 *. pt.px -. x;
              pt.hy_in <- 2.0 *. pt.py -. y;
              pt.smooth <- true
            | [] -> ()
          end;
          canvas_area#misc#queue_draw ();
          true
        end else
        begin match line_drag_start with
        | Some (sx, sy) ->
          let x = GdkEvent.Motion.x ev in
          let y = GdkEvent.Motion.y ev in
          let shift = Gdk.Convert.test_modifier `SHIFT (GdkEvent.Motion.state ev) in
          let (cx, cy) = if shift then constrain_angle sx sy x y else (x, y) in
          line_drag_end <- Some (cx, cy);
          canvas_area#misc#queue_draw ();
          true
        | None -> false
        end
      ) |> ignore;
      canvas_area#event#connect#button_release ~callback:(fun ev ->
        if toolbar#current_tool = Toolbar.Pen && GdkEvent.Button.button ev = 1 then begin
          pen_dragging <- false;
          canvas_area#misc#queue_draw ();
          true
        end else
        begin match line_drag_start with
        | Some (sx, sy) when GdkEvent.Button.button ev = 1 ->
          let raw_ex = GdkEvent.Button.x ev in
          let raw_ey = GdkEvent.Button.y ev in
          let shift = Gdk.Convert.test_modifier `SHIFT (GdkEvent.Button.state ev) in
          let was_moving = moving in
          line_drag_start <- None;
          line_drag_end <- None;
          moving <- false;
          let option = Gdk.Convert.test_modifier `MOD1 (GdkEvent.Button.state ev) in
          if was_moving then begin
            let (ex, ey) = if shift then constrain_angle sx sy raw_ex raw_ey else (raw_ex, raw_ey) in
            let dx = ex -. sx in
            let dy = ey -. sy in
            if dx <> 0.0 || dy <> 0.0 then begin
              if option then controller#copy_selection dx dy
              else controller#move_selection dx dy
            end;
            canvas_area#misc#queue_draw ();
            true
          end else
          (* Selection tools: shift means extend *)
          let extend = shift in
          if toolbar#current_tool = Toolbar.Selection then begin
            let x = min sx raw_ex in
            let y = min sy raw_ey in
            let w = abs_float (raw_ex -. sx) in
            let h = abs_float (raw_ey -. sy) in
            controller#select_rect ~extend x y w h;
            true
          end else if toolbar#current_tool = Toolbar.Group_selection then begin
            let x = min sx raw_ex in
            let y = min sy raw_ey in
            let w = abs_float (raw_ex -. sx) in
            let h = abs_float (raw_ey -. sy) in
            controller#group_select_rect ~extend x y w h;
            true
          end else if toolbar#current_tool = Toolbar.Direct_selection then begin
            let x = min sx raw_ex in
            let y = min sy raw_ey in
            let w = abs_float (raw_ex -. sx) in
            let h = abs_float (raw_ey -. sy) in
            controller#direct_select_rect ~extend x y w h;
            true
          end else
          (* Text tool: edit existing, place point text, or drag area text *)
          if toolbar#current_tool = Toolbar.Text_tool then begin
            let w = abs_float (raw_ex -. sx) in
            let h = abs_float (raw_ey -. sy) in
            if w > 4.0 || h > 4.0 then begin
              (* Dragged a marquee: create area text *)
              let tx = min sx raw_ex in
              let ty = min sy raw_ey in
              let elem = Element.make_text ~text_width:w ~text_height:h
                ~fill:(Some Element.{
                  fill_color = { r = 0.0; g = 0.0; b = 0.0; a = 1.0 }
                }) tx ty "Lorem Ipsum" in
              controller#add_element elem;
              true
            end else begin
              match _self#hit_test_text sx sy with
              | Some (path, text_elem) ->
                _self#start_text_edit path text_elem;
                true
              | None ->
                let elem = Element.make_text ~fill:(Some Element.{
                  fill_color = { r = 0.0; g = 0.0; b = 0.0; a = 1.0 }
                }) sx sy "Lorem Ipsum" in
                controller#add_element elem;
                true
            end
          end else
          (* Drawing tools: shift means constrain angle *)
          let (ex, ey) = if shift then constrain_angle sx sy raw_ex raw_ey else (raw_ex, raw_ey) in
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
          else if toolbar#current_tool = Toolbar.Polygon then
            let pts = regular_polygon_points sx sy ex ey polygon_sides in
            Element.Polygon {
              points = pts;
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
          controller#add_element elem;
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
