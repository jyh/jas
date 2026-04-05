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

  | Text_path { d; content; start_offset; font_family; font_size; fill; opacity; transform; _ } ->
    Cairo.Group.push cr;
    apply_transform cr transform;
    begin match fill with
    | Some { fill_color = c } -> Cairo.set_source_rgba cr c.r c.g c.b c.a
    | None -> Cairo.set_source_rgb cr 0.0 0.0 0.0
    end;
    Cairo.select_font_face cr font_family;
    Cairo.set_font_size cr font_size;
    (* Flatten path to polyline for arc-length parameterization *)
    let flatten_path cmds =
      let pts = ref [] in
      let cx = ref 0.0 and cy = ref 0.0 in
      let steps = 20 in
      List.iter (fun cmd ->
        let open Element in
        match cmd with
        | MoveTo (x, y) -> cx := x; cy := y; pts := (x, y) :: !pts
        | LineTo (x, y) -> cx := x; cy := y; pts := (x, y) :: !pts
        | CurveTo (x1, y1, x2, y2, x, y) ->
          let sx = !cx and sy = !cy in
          for i = 1 to steps do
            let t = float_of_int i /. float_of_int steps in
            let t2 = t *. t in let t3 = t *. t *. t in
            let mt = 1.0 -. t in let mt2 = mt *. mt in let mt3 = mt *. mt *. mt in
            let px = mt3 *. sx +. 3.0 *. mt2 *. t *. x1 +. 3.0 *. mt *. t2 *. x2 +. t3 *. x in
            let py = mt3 *. sy +. 3.0 *. mt2 *. t *. y1 +. 3.0 *. mt *. t2 *. y2 +. t3 *. y in
            pts := (px, py) :: !pts
          done;
          cx := x; cy := y
        | QuadTo (x1, y1, x, y) ->
          let sx = !cx and sy = !cy in
          for i = 1 to steps do
            let t = float_of_int i /. float_of_int steps in
            let mt = 1.0 -. t in
            let px = mt *. mt *. sx +. 2.0 *. mt *. t *. x1 +. t *. t *. x in
            let py = mt *. mt *. sy +. 2.0 *. mt *. t *. y1 +. t *. t *. y in
            pts := (px, py) :: !pts
          done;
          cx := x; cy := y
        | ClosePath | SmoothCurveTo _ | SmoothQuadTo _ | ArcTo _ ->
          (* Simplified: treat as lineTo for arc/smooth variants *)
          ()
      ) cmds;
      List.rev !pts
    in
    let flat = flatten_path d in
    (* Compute cumulative arc lengths *)
    let n = List.length flat in
    if n >= 2 then begin
      let arr = Array.of_list flat in
      let dists = Array.make n 0.0 in
      for i = 1 to n - 1 do
        let (px, py) = arr.(i - 1) in
        let (qx, qy) = arr.(i) in
        dists.(i) <- dists.(i - 1) +. sqrt ((qx -. px) ** 2.0 +. (qy -. py) ** 2.0)
      done;
      let total_len = dists.(n - 1) in
      if total_len > 0.0 then begin
        let offset = ref (start_offset *. total_len) in
        let len = String.length content in
        let j = ref 0 in
        while !j < len do
          let ch = String.make 1 content.[!j] in
          let extents = Cairo.text_extents cr ch in
          let cw = extents.Cairo.x_advance in
          let mid = !offset +. cw /. 2.0 in
          if mid > total_len then j := len  (* stop *)
          else begin
            (* Find segment containing mid *)
            let seg = ref 1 in
            while !seg < n - 1 && dists.(!seg) < mid do incr seg done;
            let d0 = dists.(!seg - 1) and d1 = dists.(!seg) in
            let frac = if d1 > d0 then (mid -. d0) /. (d1 -. d0) else 0.0 in
            let (ax, ay) = arr.(!seg - 1) and (bx, by) = arr.(!seg) in
            let px = ax +. frac *. (bx -. ax) in
            let py = ay +. frac *. (by -. ay) in
            let angle = atan2 (by -. ay) (bx -. ax) in
            Cairo.save cr;
            Cairo.translate cr px py;
            Cairo.rotate cr angle;
            Cairo.move_to cr (-. cw /. 2.0) (font_size /. 3.0);
            Cairo.show_text cr ch;
            Cairo.restore cr;
            offset := !offset +. cw
          end;
          incr j
        done
      end
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

let handle_size = 6.0

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
  | Path { d; _ } | Text_path { d; _ } ->
    build_path cr d;
    Cairo.stroke cr
  | _ ->
    let (bx, by, bw, bh) = Element.bounds elem in
    Cairo.rectangle cr bx by ~w:bw ~h:bh;
    Cairo.stroke cr
  end;
  (* Draw Bezier handles for selected path control points *)
  let handle_circle_radius = 3.0 in
  (match elem with
   | Path { d; _ } | Text_path { d; _ } when selected_cps <> [] ->
     let anchors = control_points elem in
     List.iter (fun cp_idx ->
       let ax, ay = try List.nth anchors cp_idx with _ -> (0.0, 0.0) in
       if cp_idx < List.length anchors then begin
         let (h_in, h_out) = Element.path_handle_positions d cp_idx in
         Cairo.set_source_rgb cr 0.0 0.47 1.0;
         Cairo.set_line_width cr 1.0;
         (match h_in with
          | Some (hx, hy) ->
            Cairo.move_to cr ax ay;
            Cairo.line_to cr hx hy;
            Cairo.stroke cr;
            Cairo.arc cr hx hy ~r:handle_circle_radius ~a1:0.0 ~a2:(2.0 *. Float.pi);
            Cairo.set_source_rgb cr 1.0 1.0 1.0;
            Cairo.fill_preserve cr;
            Cairo.set_source_rgb cr 0.0 0.47 1.0;
            Cairo.stroke cr
          | None -> ());
         (match h_out with
          | Some (hx, hy) ->
            Cairo.move_to cr ax ay;
            Cairo.line_to cr hx hy;
            Cairo.stroke cr;
            Cairo.arc cr hx hy ~r:handle_circle_radius ~a1:0.0 ~a2:(2.0 *. Float.pi);
            Cairo.set_source_rgb cr 1.0 1.0 1.0;
            Cairo.fill_preserve cr;
            Cairo.set_source_rgb cr 0.0 0.47 1.0;
            Cairo.stroke cr
          | None -> ())
       end
     ) selected_cps
   | _ -> ());
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
        | Element.Text_path { transform; _ }
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
    val hit_radius = 6.0
    (* Inline text editing state *)
    val mutable text_editor : GEdit.entry option = None
    val mutable editing_path : int list option = None
    (* Active tool and tool instances *)
    val mutable active_tool : Canvas_tool.canvas_tool = Tool_factory.create_tool Toolbar.Selection
    val mutable current_tool_type : Toolbar.tool = Toolbar.Selection

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

    method private hit_test_selection px py =
      Document.PathMap.exists (fun _path (es : Document.element_selection) ->
        let elem = Document.get_element current_doc es.es_path in
        let cps = Element.control_points elem in
        List.exists (fun i ->
          let (cpx, cpy) = List.nth cps i in
          abs_float (px -. cpx) <= hit_radius && abs_float (py -. cpy) <= hit_radius
        ) es.es_control_points
      ) current_doc.Document.selection

    method private hit_test_path_curve px py =
      let doc = current_doc in
      let threshold = hit_radius +. 2.0 in
      let result = ref None in
      List.iteri (fun li layer ->
        let children = match layer with
          | Element.Layer { children; _ } -> children
          | _ -> []
        in
        List.iteri (fun ci child ->
          if !result = None then
            match child with
            | Element.Path { d; _ } | Element.Text_path { d; _ } ->
              let dist = Element.path_distance_to_point d px py in
              if dist <= threshold then
                result := Some ([li; ci], child)
            | Element.Group { children = gc; _ } ->
              List.iteri (fun gi gchild ->
                if !result = None then
                  match gchild with
                  | Element.Path { d; _ } | Element.Text_path { d; _ } ->
                    let dist = Element.path_distance_to_point d px py in
                    if dist <= threshold then
                      result := Some ([li; ci; gi], gchild)
                  | _ -> ()
              ) gc
            | _ -> ()
        ) children
      ) doc.Document.layers;
      !result

    method private hit_test_handle px py =
      Document.PathMap.fold (fun _path (es : Document.element_selection) acc ->
        match acc with
        | Some _ -> acc
        | None ->
          let elem = Document.get_element current_doc es.es_path in
          (match elem with
           | Element.Path { d; _ } ->
             List.fold_left (fun acc2 cp_idx ->
               match acc2 with
               | Some _ -> acc2
               | None ->
                 let (h_in, h_out) = Element.path_handle_positions d cp_idx in
                 (match h_in with
                  | Some (hx, hy) when abs_float (px -. hx) <= hit_radius
                    && abs_float (py -. hy) <= hit_radius ->
                    Some (es.es_path, cp_idx, "in")
                  | _ ->
                    match h_out with
                    | Some (hx, hy) when abs_float (px -. hx) <= hit_radius
                      && abs_float (py -. hy) <= hit_radius ->
                      Some (es.es_path, cp_idx, "out")
                    | _ -> None)
             ) None es.es_control_points
           | _ -> None)
      ) current_doc.Document.selection None

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
           | Element.Text_path t when t.content <> new_text ->
             let new_elem = Element.Text_path { t with content = new_text } in
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
      | Element.Text_path { d; content; start_offset; font_size; font_family; _ } ->
        let (px, py) = Element.path_point_at_offset d start_offset in
        let entry = GEdit.entry ~packing:(fun w ->
          fixed#put w ~x:(pos_x + int_of_float px) ~y:(pos_y + int_of_float (py -. font_size -. 4.0))
        ) () in
        entry#set_text content;
        let font_desc = GPango.font_description_from_string (Printf.sprintf "%s %d" font_family (int_of_float font_size)) in
        entry#misc#modify_font font_desc;
        let bw = max (int_of_float (float_of_int (String.length content) *. font_size *. 0.7) + 20) 200 in
        entry#misc#set_size_request ~width:bw ~height:(int_of_float font_size + 8) ();
        entry#connect#activate ~callback:(fun () -> _self#commit_text_edit) |> ignore;
        entry#misc#show ();
        entry#misc#grab_focus ();
        entry#select_region ~start:0 ~stop:(String.length content);
        text_editor <- Some entry
      | _ -> ()

    method private tool_context : Canvas_tool.tool_context = {
      Canvas_tool.model = model;
      controller = controller;
      hit_test_selection = (fun x y -> _self#hit_test_selection x y);
      hit_test_handle = (fun x y -> _self#hit_test_handle x y);
      hit_test_text = (fun x y -> _self#hit_test_text x y);
      hit_test_path_curve = (fun x y -> _self#hit_test_path_curve x y);
      request_update = (fun () -> canvas_area#misc#queue_draw ());
      start_text_edit = (fun path elem -> _self#start_text_edit path elem);
      commit_text_edit = (fun () -> _self#commit_text_edit);
      draw_element_overlay = draw_element_overlay;
    }

    method private switch_tool =
      let new_tool_type = toolbar#current_tool in
      if new_tool_type <> current_tool_type then begin
        let saved_selection = current_doc.Document.selection in
        let ctx = _self#tool_context in
        active_tool#deactivate ctx;
        current_tool_type <- new_tool_type;
        active_tool <- Tool_factory.create_tool new_tool_type;
        active_tool#activate ctx;
        (* Preserve selection across tool changes *)
        let doc = current_doc in
        if doc.Document.selection <> saved_selection then
          model#set_document { doc with Document.selection = saved_selection }
      end

    method pen_finish =
      (* For backward compatibility: deactivate pen tool to finish *)
      let ctx = _self#tool_context in
      active_tool#deactivate ctx;
      active_tool <- Tool_factory.create_tool Toolbar.Pen

    method pen_finish_close =
      _self#pen_finish

    method pen_cancel =
      (* Reset pen tool by creating a fresh instance *)
      active_tool <- Tool_factory.create_tool Toolbar.Pen;
      canvas_area#misc#queue_draw ()

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

      (* Draw canvas: white background, then document layers, then tool overlay *)
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
        (* Draw active tool overlay *)
        _self#switch_tool;
        active_tool#draw_overlay _self#tool_context cr;
        true
      ) |> ignore;

      (* Canvas mouse events — dispatched through active tool *)
      canvas_area#event#add [`BUTTON_PRESS; `BUTTON_RELEASE; `POINTER_MOTION];
      canvas_area#event#connect#button_press ~callback:(fun ev ->
        if GdkEvent.Button.button ev = 1 then begin
          _self#switch_tool;
          let x = GdkEvent.Button.x ev in
          let y = GdkEvent.Button.y ev in
          let shift = Gdk.Convert.test_modifier `SHIFT (GdkEvent.Button.state ev) in
          let alt = Gdk.Convert.test_modifier `MOD1 (GdkEvent.Button.state ev) in
          let ctx = _self#tool_context in
          let event_type = GdkEvent.get_type ev in
          if event_type = `TWO_BUTTON_PRESS then
            active_tool#on_double_click ctx x y
          else
            active_tool#on_press ctx x y ~shift ~alt;
          true
        end else false
      ) |> ignore;
      canvas_area#event#connect#motion_notify ~callback:(fun ev ->
        _self#switch_tool;
        let x = GdkEvent.Motion.x ev in
        let y = GdkEvent.Motion.y ev in
        let shift = Gdk.Convert.test_modifier `SHIFT (GdkEvent.Motion.state ev) in
        let buttons = GdkEvent.Motion.state ev in
        let dragging = Gdk.Convert.test_modifier `BUTTON1 buttons in
        let ctx = _self#tool_context in
        active_tool#on_move ctx x y ~shift ~dragging;
        true
      ) |> ignore;
      canvas_area#event#connect#button_release ~callback:(fun ev ->
        if GdkEvent.Button.button ev = 1 then begin
          _self#switch_tool;
          let x = GdkEvent.Button.x ev in
          let y = GdkEvent.Button.y ev in
          let shift = Gdk.Convert.test_modifier `SHIFT (GdkEvent.Button.state ev) in
          let alt = Gdk.Convert.test_modifier `MOD1 (GdkEvent.Button.state ev) in
          let ctx = _self#tool_context in
          active_tool#on_release ctx x y ~shift ~alt;
          true
        end else false
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
