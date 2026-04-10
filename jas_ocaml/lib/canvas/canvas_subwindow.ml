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

(** Configure [cr] for an outline-mode draw. The spec says
    "stroke of size 0"; on Cairo, a 0-width stroke renders nothing,
    so we use a 1-pixel width which gives a thin black line at
    default zoom. No fill, solid black stroke. Used when an
    element's effective visibility is [Element.Outline]. *)
let apply_outline_style cr =
  Cairo.set_source_rgba cr 0.0 0.0 0.0 1.0;
  Cairo.set_line_width cr 1.0;
  Cairo.set_line_cap cr Cairo.BUTT;
  Cairo.set_line_join cr Cairo.JOIN_MITER

(** Draw an element to a Cairo context.

    [ancestor_vis] is the capping visibility inherited from parent
    Groups/Layers. The element's effective visibility is the minimum
    of its own and the ancestor's:

    - [Invisible] effective: the subtree is skipped entirely.
    - [Outline]   effective: every non-Text element is drawn with a
      thin black hairline stroke and no fill. Text and Text_path
      remain rendered as Preview.
    - [Preview]   effective: normal rendering. *)
let rec draw_element ?(ancestor_vis = Element.Preview) cr (elem : Element.element) =
  let open Element in
  let elem_vis = Element.get_visibility elem in
  let effective = if compare elem_vis ancestor_vis < 0 then elem_vis else ancestor_vis in
  if effective = Element.Invisible then ()
  else
  let outline = effective = Element.Outline in
  Cairo.save cr;
  begin match elem with
  | Line { x1; y1; x2; y2; stroke; opacity; transform; _ } ->
    Cairo.Group.push cr;
    apply_transform cr transform;
    if outline then apply_outline_style cr
    else apply_stroke cr stroke;
    Cairo.move_to cr x1 y1;
    Cairo.line_to cr x2 y2;
    Cairo.stroke cr;
    Cairo.Group.pop_to_source cr;
    Cairo.paint cr ~alpha:opacity

  | Rect { x; y; width; height; rx; ry; fill; stroke; opacity; transform; _ } ->
    Cairo.Group.push cr;
    apply_transform cr transform;
    if rx > 0.0 || ry > 0.0 then
      rounded_rect cr x y width height rx ry
    else
      Cairo.rectangle cr x y ~w:width ~h:height;
    if outline then begin
      apply_outline_style cr;
      Cairo.stroke cr
    end else fill_and_stroke cr fill stroke;
    Cairo.Group.pop_to_source cr;
    Cairo.paint cr ~alpha:opacity

  | Circle { cx; cy; r; fill; stroke; opacity; transform; _ } ->
    Cairo.Group.push cr;
    apply_transform cr transform;
    Cairo.arc cr cx cy ~r ~a1:0.0 ~a2:(2.0 *. Float.pi);
    if outline then begin
      apply_outline_style cr;
      Cairo.stroke cr
    end else fill_and_stroke cr fill stroke;
    Cairo.Group.pop_to_source cr;
    Cairo.paint cr ~alpha:opacity

  | Ellipse { cx; cy; rx; ry; fill; stroke; opacity; transform; _ } ->
    Cairo.Group.push cr;
    apply_transform cr transform;
    Cairo.save cr;
    Cairo.translate cr cx cy;
    Cairo.scale cr rx ry;
    Cairo.arc cr 0.0 0.0 ~r:1.0 ~a1:0.0 ~a2:(2.0 *. Float.pi);
    Cairo.restore cr;
    if outline then begin
      apply_outline_style cr;
      Cairo.stroke cr
    end else fill_and_stroke cr fill stroke;
    Cairo.Group.pop_to_source cr;
    Cairo.paint cr ~alpha:opacity

  | Polyline { points; fill; stroke; opacity; transform; _ } ->
    Cairo.Group.push cr;
    apply_transform cr transform;
    draw_points cr points false;
    if outline then begin
      apply_outline_style cr;
      Cairo.stroke cr
    end else fill_and_stroke cr fill stroke;
    Cairo.Group.pop_to_source cr;
    Cairo.paint cr ~alpha:opacity

  | Polygon { points; fill; stroke; opacity; transform; _ } ->
    Cairo.Group.push cr;
    apply_transform cr transform;
    draw_points cr points true;
    if outline then begin
      apply_outline_style cr;
      Cairo.stroke cr
    end else fill_and_stroke cr fill stroke;
    Cairo.Group.pop_to_source cr;
    Cairo.paint cr ~alpha:opacity

  | Path { d; fill; stroke; opacity; transform; _ } ->
    Cairo.Group.push cr;
    apply_transform cr transform;
    build_path cr d;
    if outline then begin
      apply_outline_style cr;
      Cairo.stroke cr
    end else fill_and_stroke cr fill stroke;
    Cairo.Group.pop_to_source cr;
    Cairo.paint cr ~alpha:opacity

  | Text { x; y; content; font_family; font_size; font_weight; font_style; text_width; text_height; fill; opacity; transform; _ } ->
    Cairo.Group.push cr;
    apply_transform cr transform;
    begin match fill with
    | Some { fill_color = c } ->
      let (r, g, b, a) = Element.color_to_rgba c in
      Cairo.set_source_rgba cr r g b a
    | None -> Cairo.set_source_rgb cr 0.0 0.0 0.0
    end;
    let slant = if font_style = "italic" || font_style = "oblique" then Cairo.Italic else Cairo.Upright in
    let weight = if font_weight = "bold" then Cairo.Bold else Cairo.Normal in
    (* Point and area text are both rendered as one Cairo line per
       laid-out line so they share the same metrics as the in-place
       editor (which queries Cairo text_extents via the type tool's
       measurer). For point text we just split on '\n'; for area text we
       run the editor's TextLayout module to do word-wrap.

       Cairo's show_text treats (x, y) as the *baseline*, so we offset
       by [font_size *. 0.8] (the layout module's ascent) to keep our
       (x, y) = top-left convention consistent with the editor's
       bounding box. *)
    Cairo.select_font_face cr font_family ~slant ~weight;
    Cairo.set_font_size cr font_size;
    let ascent = font_size *. 0.8 in
    if text_width > 0.0 && text_height > 0.0 then begin
      let measure s =
        if s = "" then 0.0 else (Cairo.text_extents cr s).Cairo.x_advance
      in
      let lay = Text_layout.layout content text_width font_size measure in
      Array.iter (fun (line : Text_layout.line_info) ->
        let seg = String.sub content line.start (line.end_ - line.start) in
        let seg = if String.length seg > 0 && seg.[String.length seg - 1] = '\n'
                  then String.sub seg 0 (String.length seg - 1) else seg in
        Cairo.move_to cr (x +. 0.0) (y +. line.baseline_y);
        Cairo.show_text cr seg
      ) lay.lines
    end else begin
      let lines = String.split_on_char '\n' content in
      List.iteri (fun i line ->
        let line_y = y +. ascent +. float_of_int i *. font_size in
        Cairo.move_to cr x line_y;
        Cairo.show_text cr line
      ) lines
    end;
    Cairo.Group.pop_to_source cr;
    Cairo.paint cr ~alpha:opacity

  | Text_path { d; content; start_offset; font_family; font_size; font_weight; font_style; fill; opacity; transform; _ } ->
    Cairo.Group.push cr;
    apply_transform cr transform;
    begin match fill with
    | Some { fill_color = c } ->
      let (r, g, b, a) = Element.color_to_rgba c in
      Cairo.set_source_rgba cr r g b a
    | None -> Cairo.set_source_rgb cr 0.0 0.0 0.0
    end;
    let slant = if font_style = "italic" || font_style = "oblique" then Cairo.Italic else Cairo.Upright in
    let weight = if font_weight = "bold" then Cairo.Bold else Cairo.Normal in
    Cairo.select_font_face cr font_family ~slant ~weight;
    Cairo.set_font_size cr font_size;
    (* Flatten path to polyline for arc-length parameterization *)
    let flatten_path cmds =
      let pts = ref [] in
      let cx = ref 0.0 and cy = ref 0.0 in
      let steps = Element.flatten_steps in
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

  | Group { children; opacity; transform; _ } ->
    Cairo.Group.push cr;
    apply_transform cr transform;
    Array.iter (fun c -> draw_element ~ancestor_vis:effective cr c) children;
    Cairo.Group.pop_to_source cr;
    Cairo.paint cr ~alpha:opacity

  | Layer { children; opacity; transform; _ } ->
    Cairo.Group.push cr;
    apply_transform cr transform;
    Array.iter (fun c -> draw_element ~ancestor_vis:effective cr c) children;
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
    let (r, g, b, a) = Element.color_to_rgba s.stroke_color in
    Cairo.set_source_rgba cr r g b a;
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
     | Some (f : Element.fill) ->
       let (r, g, b, a) = Element.color_to_rgba f.fill_color in
       Cairo.set_source_rgba cr r g b a
     | None -> ());
    Cairo.fill_preserve cr;
    apply_stroke cr stroke;
    Cairo.stroke cr
  end else if has_fill then begin
    (match fill with
     | Some (f : Element.fill) ->
       let (r, g, b, a) = Element.color_to_rgba f.fill_color in
       Cairo.set_source_rgba cr r g b a
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

and arc_to_beziers cx0 cy0 rx ry x_rotation large_arc sweep x y =
  (* W3C SVG endpoint-to-center parameterization (F.6) *)
  if (cx0 = x && cy0 = y) || (rx = 0.0 && ry = 0.0) then []
  else
    let pi = Float.pi in
    let rx = abs_float rx in
    let ry = abs_float ry in
    let phi = x_rotation *. pi /. 180.0 in
    let cos_phi = cos phi in
    let sin_phi = sin phi in
    let dx2 = (cx0 -. x) /. 2.0 in
    let dy2 = (cy0 -. y) /. 2.0 in
    let x1p = cos_phi *. dx2 +. sin_phi *. dy2 in
    let y1p = -. sin_phi *. dx2 +. cos_phi *. dy2 in
    let x1p_sq = x1p *. x1p in
    let y1p_sq = y1p *. y1p in
    let rx, ry =
      let lam = x1p_sq /. (rx *. rx) +. y1p_sq /. (ry *. ry) in
      if lam > 1.0 then
        let s = sqrt lam in (rx *. s, ry *. s)
      else (rx, ry)
    in
    let rx_sq = rx *. rx in
    let ry_sq = ry *. ry in
    let num = max 0.0 (rx_sq *. ry_sq -. rx_sq *. y1p_sq -. ry_sq *. x1p_sq) in
    let den = rx_sq *. y1p_sq +. ry_sq *. x1p_sq in
    let sq = if den > 0.0 then sqrt (num /. den) else 0.0 in
    let sq = if large_arc = sweep then -. sq else sq in
    let cxp = sq *. rx *. y1p /. ry in
    let cyp = -. sq *. ry *. x1p /. rx in
    let ccx = cos_phi *. cxp -. sin_phi *. cyp +. (cx0 +. x) /. 2.0 in
    let ccy = sin_phi *. cxp +. cos_phi *. cyp +. (cy0 +. y) /. 2.0 in
    let angle ux uy vx vy =
      let n = sqrt (ux *. ux +. uy *. uy) *. sqrt (vx *. vx +. vy *. vy) in
      if n = 0.0 then 0.0
      else
        let c = max (-1.0) (min 1.0 ((ux *. vx +. uy *. vy) /. n)) in
        let a = acos c in
        if ux *. vy -. uy *. vx < 0.0 then -. a else a
    in
    let theta1 = angle 1.0 0.0 ((x1p -. cxp) /. rx) ((y1p -. cyp) /. ry) in
    let dtheta = angle
      ((x1p -. cxp) /. rx) ((y1p -. cyp) /. ry)
      ((-. x1p -. cxp) /. rx) ((-. y1p -. cyp) /. ry)
    in
    let dtheta =
      if (not sweep) && dtheta > 0.0 then dtheta -. 2.0 *. pi
      else if sweep && dtheta < 0.0 then dtheta +. 2.0 *. pi
      else dtheta
    in
    let n_segs = max 1 (int_of_float (ceil (abs_float dtheta /. (pi /. 2.0)))) in
    let seg_angle = dtheta /. float_of_int n_segs in
    let alpha = sin seg_angle *. (sqrt (4.0 +. 3.0 *. (tan (seg_angle /. 2.0) ** 2.0)) -. 1.0) /. 3.0 in
    let curves = ref [] in
    let theta = ref theta1 in
    for _ = 0 to n_segs - 1 do
      let cos_t = cos !theta in
      let sin_t = sin !theta in
      let cos_t2 = cos (!theta +. seg_angle) in
      let sin_t2 = sin (!theta +. seg_angle) in
      let ex1 = rx *. cos_t in let ey1 = ry *. sin_t in
      let ex2 = rx *. cos_t2 in let ey2 = ry *. sin_t2 in
      let dx1 = -. rx *. sin_t in let dy1 = ry *. cos_t in
      let dx2 = -. rx *. sin_t2 in let dy2 = ry *. cos_t2 in
      let cp1x = cos_phi *. (ex1 +. alpha *. dx1) -. sin_phi *. (ey1 +. alpha *. dy1) +. ccx in
      let cp1y = sin_phi *. (ex1 +. alpha *. dx1) +. cos_phi *. (ey1 +. alpha *. dy1) +. ccy in
      let cp2x = cos_phi *. (ex2 -. alpha *. dx2) -. sin_phi *. (ey2 -. alpha *. dy2) +. ccx in
      let cp2y = sin_phi *. (ex2 -. alpha *. dx2) +. cos_phi *. (ey2 -. alpha *. dy2) +. ccy in
      let epx = cos_phi *. ex2 -. sin_phi *. ey2 +. ccx in
      let epy = sin_phi *. ex2 +. cos_phi *. ey2 +. ccy in
      curves := (cp1x, cp1y, cp2x, cp2y, epx, epy) :: !curves;
      theta := !theta +. seg_angle
    done;
    List.rev !curves

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
    | ArcTo (arx, ary, rot, la, sw, x, y) ->
      let (cx0, cy0) = Cairo.Path.get_current_point cr in
      let beziers = arc_to_beziers cx0 cy0 arx ary rot la sw x y in
      (match beziers with
       | [] -> Cairo.line_to cr x y
       | _ -> List.iter (fun (bx1, by1, bx2, by2, bx, by) ->
           Cairo.curve_to cr bx1 by1 bx2 by2 bx by) beziers);
      _last_ctrl := None
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

let handle_size = Canvas_tool.handle_draw_size

(* Selection-bbox display flag lives in [Canvas_tool] so the type
   tools can read it without a tools→canvas dependency cycle. *)
let show_selection_bbox = Canvas_tool.show_selection_bbox

let control_points (elem : Element.element) =
  Element.control_points elem

(** Draw the selection overlay for one element.

    Rule: every selected element (except [Text]/[Text_path]) is
    outlined by re-tracing its own geometry in bright blue, and its
    control-point squares are drawn on top. A CP listed in
    [selected_cps] is filled blue; the rest are filled white.

    [Text]/[Text_path] are the exception: they get a plain
    bounding-box rectangle (for area text the bbox aligns with the
    explicit area dimensions). No CP squares for Text/Text_path.

    Groups and Layers emit no overlay themselves — their descendants
    are individually in the selection (see [select_element]) and
    draw their own highlights. *)
let draw_element_overlay cr (elem : Element.element)
    ~is_partial:(_ : bool) (selected_cps : int list) =
  let open Element in
  Cairo.set_source_rgb cr 0.0 0.47 1.0;
  Cairo.set_line_width cr 1.0;
  Cairo.set_dash cr [||];

  (* Text and Text_path: bounding-box highlight only. No CP squares. *)
  match elem with
  | Text _ | Text_path _ ->
    let (bx, by, bw, bh) = Element.bounds elem in
    Cairo.rectangle cr bx by ~w:bw ~h:bh;
    Cairo.stroke cr
  (* Groups and Layers: nothing — their descendants render their own
     highlights when the group is selected. *)
  | Group _ | Layer _ -> ()
  | _ ->
  (* All other shapes: stroke the element's own geometry in blue. *)
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
  | _ -> ()
  end;
  (* Draw Bezier handles for selected path control points. *)
  let handle_circle_radius = 3.0 in
  (match elem with
   | Path { d; _ } when selected_cps <> [] ->
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
  (* Draw control-point squares for every non-Text, non-container
     selected element. *)
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
      let node = ref doc.layers.(List.hd path) in
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
            | _ -> [||]
          in
          node := children.(idx);
          apply_transform cr (match !node with
            | Element.Group { transform; _ } | Element.Layer { transform; _ } -> transform
            | _ -> None)
        ) intermediate;
        let children = match !node with
          | Element.Group { children; _ } | Element.Layer { children; _ } -> children
          | _ -> [||]
        in
        let last_idx = List.nth rest (List.length rest - 1) in
        node := children.(last_idx)
      end;
      (* Apply the selected element's own transform *)
      apply_transform cr (match !node with
        | Element.Line { transform; _ } | Element.Rect { transform; _ }
        | Element.Circle { transform; _ } | Element.Ellipse { transform; _ }
        | Element.Polyline { transform; _ } | Element.Polygon { transform; _ }
        | Element.Path { transform; _ } | Element.Text { transform; _ }
        | Element.Text_path { transform; _ }
        | Element.Group { transform; _ } | Element.Layer { transform; _ } -> transform);
      let n = Element.control_point_count !node in
      let cps = Document.selection_kind_to_sorted es.es_kind ~total:n in
      let is_partial = match es.es_kind with
        | Document.SelKindPartial _ -> true
        | Document.SelKindAll -> false
      in
      draw_element_overlay cr !node ~is_partial cps;
      Cairo.restore cr
  ) doc.selection

class canvas_subwindow ~(model : Model.model) ~(controller : Controller.controller)
    ~(toolbar : Toolbar.toolbar) ~(bbox : bounding_box) =

  (* The canvas drawing area is used directly as the notebook page widget.
     We avoid wrapping it in a GPack.fixed or GBin.frame because GPack.fixed
     does not propagate size allocation to its children — the canvas would
     remain at 0x0 pixels regardless of hexpand/vexpand settings.
     Text editors for inline editing use popup windows positioned relative
     to the canvas via Gdk.Window.get_origin, since there is no parent
     fixed container to place them in. *)
  let canvas_area = GMisc.drawing_area () in
  object (_self)
    val mutable current_doc = model#document
    val hit_radius = Canvas_tool.hit_radius
    (* Active tool and tool instances *)
    val mutable active_tool : Canvas_tool.canvas_tool = Tool_factory.create_tool Toolbar.Selection
    val mutable current_tool_type : Toolbar.tool = Toolbar.Selection

    method widget = canvas_area#coerce
    method canvas = canvas_area
    method model = model
    method title =
      if model#is_modified then model#filename ^ " *"
      else model#filename
    method bbox = bbox

    method private hit_test_text px py =
      let doc = current_doc in
      let result = ref None in
      Array.iteri (fun li layer ->
        let children = match layer with
          | Element.Layer { children; _ } -> children
          | _ -> [||]
        in
        Array.iteri (fun ci child ->
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
        let n = List.length cps in
        let indices = Document.selection_kind_to_sorted es.es_kind ~total:n in
        List.exists (fun i ->
          let (cpx, cpy) = List.nth cps i in
          abs_float (px -. cpx) <= hit_radius && abs_float (py -. cpy) <= hit_radius
        ) indices
      ) current_doc.Document.selection

    method private hit_test_path_curve px py =
      let doc = current_doc in
      let threshold = hit_radius +. 2.0 in
      let result = ref None in
      Array.iteri (fun li layer ->
        let children = match layer with
          | Element.Layer { children; _ } -> children
          | _ -> [||]
        in
        Array.iteri (fun ci child ->
          if !result = None then
            match child with
            | Element.Path { d; _ } | Element.Text_path { d; _ } ->
              let dist = Element.path_distance_to_point d px py in
              if dist <= threshold then
                result := Some ([li; ci], child)
            | Element.Group { children = gc; _ } ->
              Array.iteri (fun gi gchild ->
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
             let n = Element.control_point_count elem in
             let indices = Document.selection_kind_to_sorted es.es_kind ~total:n in
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
             ) None indices
           | _ -> None)
      ) current_doc.Document.selection None

    method private tool_context : Canvas_tool.tool_context = {
      Canvas_tool.model = model;
      controller = controller;
      hit_test_selection = (fun x y -> _self#hit_test_selection x y);
      hit_test_handle = (fun x y -> _self#hit_test_handle x y);
      hit_test_text = (fun x y -> _self#hit_test_text x y);
      hit_test_path_curve = (fun x y -> _self#hit_test_path_curve x y);
      request_update = (fun () -> canvas_area#misc#queue_draw ());
      draw_element_overlay = draw_element_overlay;
    }

    method private update_cursor =
      (* Active tool can override the per-tool cursor (e.g. the type
         tools switch to the system XTERM/I-beam while in an editing
         session). *)
      let cursor =
        match active_tool#cursor_css_override () with
        | Some "ibeam" -> Gdk.Cursor.create `XTERM
        | _ ->
          match current_tool_type with
          | Toolbar.Selection ->
            _self#make_arrow_cursor 0.0 0.0 0.0 1.0 1.0 1.0 false
          | Toolbar.Direct_selection ->
            _self#make_arrow_cursor 1.0 1.0 1.0 0.0 0.0 0.0 false
          | Toolbar.Group_selection ->
            _self#make_arrow_cursor 1.0 1.0 1.0 0.0 0.0 0.0 true
          | Toolbar.Pen -> _self#make_pen_cursor
          | Toolbar.Add_anchor_point -> _self#make_add_anchor_point_cursor
          | Toolbar.Pencil -> _self#make_pencil_cursor
          | Toolbar.Path_eraser -> _self#make_path_eraser_cursor
          | Toolbar.Type_tool -> _self#make_type_cursor
          | Toolbar.Type_on_path -> _self#make_type_on_path_cursor
          | _ -> Gdk.Cursor.create `CROSSHAIR
      in
      let win = canvas_area#misc#window in
      if Gobject.get_oid win <> 0 then
        Gdk.Window.set_cursor win cursor

    method private make_pen_cursor =
      (* Load pen cursor from reference PNG bitmap, scaled to 32x32 *)
      let candidates = [
        "assets/icons/pen tool.png";
        "../assets/icons/pen tool.png";
        Filename.concat (Filename.concat
          (Filename.dirname Sys.executable_name) "..")
          "assets/icons/pen tool.png";
      ] in
      let path = List.find Sys.file_exists candidates in
      let orig = GdkPixbuf.from_file path in
      let sz = 16 in
      let pixbuf = GdkPixbuf.create ~width:sz ~height:sz
        ~bits:(GdkPixbuf.get_bits_per_sample orig)
        ~has_alpha:(GdkPixbuf.get_has_alpha orig) () in
      GdkPixbuf.scale ~dest:pixbuf ~width:sz ~height:sz
        ~scale_x:(float_of_int sz /. float_of_int (GdkPixbuf.get_width orig))
        ~scale_y:(float_of_int sz /. float_of_int (GdkPixbuf.get_height orig))
        ~interp:`BILINEAR orig;
      Gdk.Cursor.create_from_pixbuf pixbuf ~x:1 ~y:1

    method private make_add_anchor_point_cursor =
      let candidates = [
        "assets/icons/add anchor point.png";
        "../assets/icons/add anchor point.png";
        Filename.concat (Filename.concat
          (Filename.dirname Sys.executable_name) "..")
          "assets/icons/add anchor point.png";
      ] in
      let path = List.find Sys.file_exists candidates in
      let orig = GdkPixbuf.from_file path in
      let sz = 16 in
      let pixbuf = GdkPixbuf.create ~width:sz ~height:sz
        ~bits:(GdkPixbuf.get_bits_per_sample orig)
        ~has_alpha:(GdkPixbuf.get_has_alpha orig) () in
      GdkPixbuf.scale ~dest:pixbuf ~width:sz ~height:sz
        ~scale_x:(float_of_int sz /. float_of_int (GdkPixbuf.get_width orig))
        ~scale_y:(float_of_int sz /. float_of_int (GdkPixbuf.get_height orig))
        ~interp:`BILINEAR orig;
      Gdk.Cursor.create_from_pixbuf pixbuf ~x:1 ~y:1

    method private make_pencil_cursor =
      let candidates = [
        "assets/icons/pencil tool.png";
        "../assets/icons/pencil tool.png";
        Filename.concat (Filename.concat
          (Filename.dirname Sys.executable_name) "..")
          "assets/icons/pencil tool.png";
      ] in
      let path = List.find Sys.file_exists candidates in
      let orig = GdkPixbuf.from_file path in
      let sz = 16 in
      let pixbuf = GdkPixbuf.create ~width:sz ~height:sz
        ~bits:(GdkPixbuf.get_bits_per_sample orig)
        ~has_alpha:(GdkPixbuf.get_has_alpha orig) () in
      GdkPixbuf.scale ~dest:pixbuf ~width:sz ~height:sz
        ~scale_x:(float_of_int sz /. float_of_int (GdkPixbuf.get_width orig))
        ~scale_y:(float_of_int sz /. float_of_int (GdkPixbuf.get_height orig))
        ~interp:`BILINEAR orig;
      Gdk.Cursor.create_from_pixbuf pixbuf ~x:1 ~y:15

    method private make_path_eraser_cursor =
      let candidates = [
        "assets/icons/path eraser tool.png";
        "../assets/icons/path eraser tool.png";
        Filename.concat (Filename.concat
          (Filename.dirname Sys.executable_name) "..")
          "assets/icons/path eraser tool.png";
      ] in
      let path = List.find Sys.file_exists candidates in
      let orig = GdkPixbuf.from_file path in
      let sz = 16 in
      let pixbuf = GdkPixbuf.create ~width:sz ~height:sz
        ~bits:(GdkPixbuf.get_bits_per_sample orig)
        ~has_alpha:(GdkPixbuf.get_has_alpha orig) () in
      GdkPixbuf.scale ~dest:pixbuf ~width:sz ~height:sz
        ~scale_x:(float_of_int sz /. float_of_int (GdkPixbuf.get_width orig))
        ~scale_y:(float_of_int sz /. float_of_int (GdkPixbuf.get_height orig))
        ~interp:`BILINEAR orig;
      Gdk.Cursor.create_from_pixbuf pixbuf ~x:1 ~y:15

    method private make_type_cursor =
      let candidates = [
        "assets/icons/type cursor.png";
        "../assets/icons/type cursor.png";
        Filename.concat (Filename.concat
          (Filename.dirname Sys.executable_name) "..")
          "assets/icons/type cursor.png";
      ] in
      try
        let path = List.find Sys.file_exists candidates in
        let orig = GdkPixbuf.from_file path in
        let sz = 16 in
        let pixbuf = GdkPixbuf.create ~width:sz ~height:sz
          ~bits:(GdkPixbuf.get_bits_per_sample orig)
          ~has_alpha:(GdkPixbuf.get_has_alpha orig) () in
        GdkPixbuf.scale ~dest:pixbuf ~width:sz ~height:sz
          ~scale_x:(float_of_int sz /. float_of_int (GdkPixbuf.get_width orig))
          ~scale_y:(float_of_int sz /. float_of_int (GdkPixbuf.get_height orig))
          ~interp:`BILINEAR orig;
        Gdk.Cursor.create_from_pixbuf pixbuf ~x:8 ~y:8
      with Not_found -> Gdk.Cursor.create `XTERM

    method private make_type_on_path_cursor =
      let candidates = [
        "assets/icons/type on a path cursor.png";
        "../assets/icons/type on a path cursor.png";
        Filename.concat (Filename.concat
          (Filename.dirname Sys.executable_name) "..")
          "assets/icons/type on a path cursor.png";
      ] in
      try
        let path = List.find Sys.file_exists candidates in
        let orig = GdkPixbuf.from_file path in
        let sz = 16 in
        let pixbuf = GdkPixbuf.create ~width:sz ~height:sz
          ~bits:(GdkPixbuf.get_bits_per_sample orig)
          ~has_alpha:(GdkPixbuf.get_has_alpha orig) () in
        GdkPixbuf.scale ~dest:pixbuf ~width:sz ~height:sz
          ~scale_x:(float_of_int sz /. float_of_int (GdkPixbuf.get_width orig))
          ~scale_y:(float_of_int sz /. float_of_int (GdkPixbuf.get_height orig))
          ~interp:`BILINEAR orig;
        (* Hot spot near the I-beam center; 16x16 logical pixels. *)
        Gdk.Cursor.create_from_pixbuf pixbuf ~x:8 ~y:6
      with Not_found -> Gdk.Cursor.create `XTERM

    method private make_arrow_cursor fr fg fb sr sg sb with_plus =
      (* Render arrow cursor at 16x16. GDK Quartz doubles on Retina → ~32pt. *)
      let size = 16 in
      let s = 16.0 /. 24.0 in
      let surface = Cairo.Image.create Cairo.Image.ARGB32 ~w:size ~h:size in
      let cr = Cairo.create surface in
      Cairo.scale cr s s;
      Cairo.move_to cr 4.0 1.0;
      Cairo.line_to cr 4.0 19.0;
      Cairo.line_to cr 8.0 15.0;
      Cairo.line_to cr 12.0 22.0;
      Cairo.line_to cr 15.0 20.0;
      Cairo.line_to cr 11.0 13.0;
      Cairo.line_to cr 16.0 13.0;
      Cairo.Path.close cr;
      Cairo.set_source_rgba cr fr fg fb 1.0;
      Cairo.fill_preserve cr;
      Cairo.set_source_rgba cr sr sg sb 1.0;
      Cairo.set_line_width cr 1.5;
      Cairo.stroke cr;
      if with_plus then begin
        Cairo.set_source_rgba cr 0.0 0.0 0.0 1.0;
        Cairo.set_line_width cr 2.0;
        Cairo.move_to cr 17.0 20.0;
        Cairo.line_to cr 23.0 20.0;
        Cairo.move_to cr 20.0 17.0;
        Cairo.line_to cr 20.0 23.0;
        Cairo.stroke cr
      end;
      let tmp = Filename.temp_file "jas_cursor" ".png" in
      Cairo.PNG.write surface tmp;
      let pixbuf = GdkPixbuf.from_file tmp in
      (try Sys.remove tmp with _ -> ());
      Gdk.Cursor.create_from_pixbuf pixbuf ~x:3 ~y:1

    method private switch_tool =
      let new_tool_type = toolbar#current_tool in
      let saved_selection = current_doc.Document.selection in
      let ctx = _self#tool_context in
      if new_tool_type <> current_tool_type then begin
        active_tool#deactivate ctx;
        current_tool_type <- new_tool_type;
        active_tool <- Tool_factory.create_tool new_tool_type;
        active_tool#activate ctx;
        _self#update_cursor;
      end;
      (* Preserve selection across tool changes *)
      let doc = current_doc in
      if doc.Document.selection <> saved_selection then
        model#set_document { doc with Document.selection = saved_selection }

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

    method forward_key key =
      let ctx = _self#tool_context in
      active_tool#on_key ctx key

    method forward_key_release key =
      let ctx = _self#tool_context in
      active_tool#on_key_release ctx key

    method tool_is_editing = active_tool#is_editing ()

    method forward_key_event ev =
      let ctx = _self#tool_context in
      if not (active_tool#captures_keyboard ()) then false
      else begin
        let keyval = GdkEvent.Key.keyval ev in
        let state = GdkEvent.Key.state ev in
        let mods : Canvas_tool.key_mods = {
          shift = List.mem `SHIFT state;
          ctrl = List.mem `CONTROL state;
          alt = List.mem `MOD1 state;
          meta = List.mem `META state;
        } in
        let key_name =
          if keyval = GdkKeysyms._Escape then Some "Escape"
          else if keyval = GdkKeysyms._Return || keyval = GdkKeysyms._KP_Enter then Some "Enter"
          else if keyval = GdkKeysyms._BackSpace then Some "Backspace"
          else if keyval = GdkKeysyms._Delete then Some "Delete"
          else if keyval = GdkKeysyms._Left then Some "ArrowLeft"
          else if keyval = GdkKeysyms._Right then Some "ArrowRight"
          else if keyval = GdkKeysyms._Up then Some "ArrowUp"
          else if keyval = GdkKeysyms._Down then Some "ArrowDown"
          else if keyval = GdkKeysyms._Home then Some "Home"
          else if keyval = GdkKeysyms._End then Some "End"
          else if keyval = GdkKeysyms._Tab then Some "Tab"
          else
            let s = GdkEvent.Key.string ev in
            if String.length s = 1 then Some s
            else if keyval >= 0x20 && keyval <= 0x7e then
              Some (String.make 1 (Char.chr keyval))
            else None
        in
        match key_name with
        | None -> false
        | Some k -> active_tool#on_key_event ctx k mods
      end

    initializer
      (* Register for document changes *)
      model#on_document_changed (fun doc ->
        current_doc <- doc;
        canvas_area#misc#queue_draw ()
      );

      (* Blink timer: redraw every ~half blink period while a tool is editing
         text, so the caret can toggle visibility. Also refreshes the
         cursor in case the active tool's cursor_css_override changed
         (e.g. the type tool entering or leaving a session). *)
      let last_editing = ref false in
      ignore (GMain.Timeout.add ~ms:265 ~callback:(fun () ->
        let editing_now = active_tool#is_editing () in
        if editing_now then canvas_area#misc#queue_draw ();
        if editing_now <> !last_editing then begin
          last_editing := editing_now;
          _self#update_cursor
        end;
        true  (* keep the timer alive *)
      ));


      (* Set initial cursor once the widget is realized *)
      canvas_area#misc#connect#realize ~callback:(fun () ->
        _self#update_cursor
      ) |> ignore;

      (* Draw canvas: white background, then document layers, then tool overlay *)
      canvas_area#misc#connect#draw ~callback:(fun cr ->
        let alloc = canvas_area#misc#allocation in
        let w = float_of_int alloc.Gtk.width in
        let h = float_of_int alloc.Gtk.height in
        Cairo.set_source_rgb cr 1.0 1.0 1.0;
        Cairo.rectangle cr 0.0 0.0 ~w ~h;
        Cairo.fill cr;
        Array.iter (draw_element cr) current_doc.Document.layers;
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

  end

(** Prompt to save a modified model before closing a tab.
    Returns true if the close should proceed, false to cancel.

    Three outcomes:
    - Save: calls the on_save callback (which triggers Menubar.save, handling
      both named files and the Save-As dialog for untitled documents). After
      saving, we re-check is_modified: if still true the user cancelled the
      Save-As dialog, so we abort the close.
    - Don't Save: proceeds without saving.
    - Cancel / dialog closed: aborts the close. *)
let confirm_close_save ~(model : Model.model) ~(save : unit -> unit) () =
  if not model#is_modified then true
  else begin
    let dialog = GWindow.dialog ~title:"Save Changes" ~modal:true () in
    dialog#add_button "Cancel" `CANCEL;
    dialog#add_button "Don't Save" `REJECT;
    dialog#add_button "Save" `ACCEPT;
    let label = GMisc.label
      ~text:(Printf.sprintf "Do you want to save changes to \"%s\"?" model#filename)
      ~packing:dialog#vbox#add () in
    ignore label;
    let response = dialog#run () in
    dialog#destroy ();
    match response with
    | `ACCEPT -> save (); not model#is_modified
    | `REJECT -> true
    | _ -> false
  end

let create ?(model = Model.create ()) ~controller ~toolbar ?(on_focus = fun () -> ()) ?(on_save = fun () -> ()) ?(bbox = make_bounding_box ()) (notebook : GPack.notebook) =
  let sub = new canvas_subwindow ~model ~controller ~toolbar ~bbox in
  (* GTK3 notebooks don't provide built-in closable tabs, so we build a
     custom tab label: an hbox containing the filename label and a flat
     close button. The close button triggers confirm_close_save before
     removing the page. *)
  let tab_hbox = GPack.hbox ~spacing:4 () in
  let tab_label = GMisc.label ~text:model#filename ~packing:tab_hbox#add () in
  let close_btn = GButton.button ~packing:tab_hbox#add () in
  close_btn#set_relief `NONE;
  ignore (GMisc.label ~text:"\xC3\x97" ~packing:close_btn#add ());
  notebook#append_page ~tab_label:tab_hbox#coerce sub#widget |> ignore;
  (* Close button handler *)
  close_btn#connect#clicked ~callback:(fun () ->
    if confirm_close_save ~model ~save:on_save () then begin
      let page_num = notebook#page_num sub#widget in
      if page_num >= 0 then notebook#remove_page page_num
    end
  ) |> ignore;
  (* Update tab label on document/filename changes *)
  let update_label () =
    let title = if model#is_modified then model#filename ^ " *" else model#filename in
    tab_label#set_text title
  in
  model#on_document_changed (fun _doc -> update_label ());
  model#on_filename_changed (fun _name -> update_label ());
  (* Fire on_focus when canvas is clicked *)
  sub#canvas#event#connect#button_press ~callback:(fun _ev ->
    on_focus (); false
  ) |> ignore;
  sub
