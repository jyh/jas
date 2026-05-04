(** PDF emitter (PRINT.md §Phase 1B). Uses Cairo's PDF surface
    (cairo2 OCaml bindings; same Cairo that powers the canvas, so no
    new dependency).

    Walks the document, emitting one page per artboard (or a single
    page covering the artboard union when
    [print_preferences.ignore_artboards] is set). Element coverage
    matches Rust + Swift: path (cubic + smooth + quad-as-cubic +
    arc-as-line fallback), rect, line, circle, ellipse, polyline,
    polygon, basic text via Cairo.show_text (toy font API), groups,
    layers. PrintLayers filter applied at layer boundaries;
    Visible_printable currently collapses to Visible until a future
    [Layer.print] flag lands. *)

type page = {
  media_w : float;
  media_h : float;
  src_x : float;
  src_y : float;
  src_w : float;
  src_h : float;
}

let artboard_bounds_union (abs : Artboard.artboard list) =
  let min_x = ref infinity and min_y = ref infinity in
  let max_x = ref neg_infinity and max_y = ref neg_infinity in
  List.iter (fun (ab : Artboard.artboard) ->
    if ab.x < !min_x then min_x := ab.x;
    if ab.y < !min_y then min_y := ab.y;
    if ab.x +. ab.width > !max_x then max_x := ab.x +. ab.width;
    if ab.y +. ab.height > !max_y then max_y := ab.y +. ab.height
  ) abs;
  (!min_x, !min_y, !max_x -. !min_x, !max_y -. !min_y)

let collect_pages (doc : Document.document) : page list =
  if doc.print_preferences.ignore_artboards || doc.artboards = [] then begin
    let (x, y, w, h) =
      if doc.artboards = [] then (0.0, 0.0, 612.0, 792.0)
      else artboard_bounds_union doc.artboards
    in
    [{ media_w = w; media_h = h; src_x = x; src_y = y; src_w = w; src_h = h }]
  end
  else
    List.map (fun (ab : Artboard.artboard) ->
      { media_w = ab.width; media_h = ab.height;
        src_x = ab.x; src_y = ab.y;
        src_w = ab.width; src_h = ab.height }
    ) doc.artboards

let scaling_pair (doc : Document.document) =
  match doc.print_preferences.scaling_mode with
  | Print_preferences.Do_not_scale | Print_preferences.Fit_to_page -> (1.0, 1.0)
  | Print_preferences.Custom_scale ->
    let s = doc.print_preferences.custom_scale /. 100.0 in
    (s, s)

let layer_passes_filter ~visibility (filter : Print_preferences.print_layers) =
  match filter with
  | Print_preferences.All_layers -> true
  | Visible_printable | Visible -> visibility <> Element.Invisible

let color_rgba (c : Element.color) =
  match c with
  | Rgb { r; g; b; a } -> (r, g, b, a)
  | Hsb _ | Cmyk _ -> (0.0, 0.0, 0.0, 1.0)

let apply_transform cr (t : Element.transform option) =
  match t with
  | None -> ()
  | Some t ->
    let m = { Cairo.xx = t.a; yx = t.b; xy = t.c; yy = t.d;
              x0 = t.e; y0 = t.f } in
    Cairo.transform cr m

let quad_to_cubic_cps (p0 : float * float) (pc : float * float) (p1 : float * float) =
  let (p0x, p0y) = p0 and (pcx, pcy) = pc and (p1x, p1y) = p1 in
  let cp1 = (p0x +. 2.0 /. 3.0 *. (pcx -. p0x),
             p0y +. 2.0 /. 3.0 *. (pcy -. p0y)) in
  let cp2 = (p1x +. 2.0 /. 3.0 *. (pcx -. p1x),
             p1y +. 2.0 /. 3.0 *. (pcy -. p1y)) in
  (cp1, cp2)

let add_path_commands cr (cmds : Element.path_command list) =
  let cur = ref (0.0, 0.0) in
  let prev_cubic_cp = ref None in
  let prev_quad_cp = ref None in
  List.iter (fun cmd ->
    match cmd with
    | Element.MoveTo (x, y) ->
      Cairo.move_to cr x y;
      cur := (x, y); prev_cubic_cp := None; prev_quad_cp := None
    | LineTo (x, y) ->
      Cairo.line_to cr x y;
      cur := (x, y); prev_cubic_cp := None; prev_quad_cp := None
    | CurveTo (x1, y1, x2, y2, x, y) ->
      Cairo.curve_to cr x1 y1 x2 y2 x y;
      cur := (x, y); prev_cubic_cp := Some (x2, y2); prev_quad_cp := None
    | SmoothCurveTo (x2, y2, x, y) ->
      let (cx, cy) = !cur in
      let (x1, y1) =
        match !prev_cubic_cp with
        | Some (px, py) -> (2.0 *. cx -. px, 2.0 *. cy -. py)
        | None -> (cx, cy)
      in
      Cairo.curve_to cr x1 y1 x2 y2 x y;
      cur := (x, y); prev_cubic_cp := Some (x2, y2); prev_quad_cp := None
    | QuadTo (x1, y1, x, y) ->
      let (cp1, cp2) = quad_to_cubic_cps !cur (x1, y1) (x, y) in
      let (cp1x, cp1y) = cp1 and (cp2x, cp2y) = cp2 in
      Cairo.curve_to cr cp1x cp1y cp2x cp2y x y;
      cur := (x, y); prev_cubic_cp := None; prev_quad_cp := Some (x1, y1)
    | SmoothQuadTo (x, y) ->
      let (cx, cy) = !cur in
      let q_ctrl =
        match !prev_quad_cp with
        | Some (px, py) -> (2.0 *. cx -. px, 2.0 *. cy -. py)
        | None -> (cx, cy)
      in
      let (cp1, cp2) = quad_to_cubic_cps !cur q_ctrl (x, y) in
      let (cp1x, cp1y) = cp1 and (cp2x, cp2y) = cp2 in
      Cairo.curve_to cr cp1x cp1y cp2x cp2y x y;
      cur := (x, y); prev_cubic_cp := None; prev_quad_cp := Some q_ctrl
    | ArcTo (_, _, _, _, _, x, y) ->
      (* Phase 1B deferral: arc-as-line fallback. *)
      Cairo.line_to cr x y;
      cur := (x, y); prev_cubic_cp := None; prev_quad_cp := None
    | ClosePath ->
      Cairo.Path.close cr;
      prev_cubic_cp := None; prev_quad_cp := None
  ) cmds

let add_polyline cr (points : (float * float) list) ~close =
  match points with
  | [] -> ()
  | (x0, y0) :: rest ->
    Cairo.move_to cr x0 y0;
    List.iter (fun (x, y) -> Cairo.line_to cr x y) rest;
    if close then Cairo.Path.close cr

let emit_paint cr ~fill ~stroke ~transform add_geom =
  if Option.is_none fill && Option.is_none stroke then ()
  else begin
    Cairo.save cr;
    apply_transform cr transform;
    add_geom ();
    (match fill with
     | None -> ()
     | Some (f : Element.fill) ->
       let (r, g, b, a) = color_rgba f.fill_color in
       Cairo.set_source_rgba cr r g b (a *. f.fill_opacity);
       (match stroke with
        | Some _ -> Cairo.fill_preserve cr
        | None -> Cairo.fill cr));
    (match stroke with
     | None -> ()
     | Some (s : Element.stroke) ->
       let (r, g, b, a) = color_rgba s.stroke_color in
       Cairo.set_source_rgba cr r g b (a *. s.stroke_opacity);
       Cairo.set_line_width cr s.stroke_width;
       Cairo.stroke cr);
    Cairo.restore cr
  end

let emit_stroke_only cr ~stroke ~transform add_geom =
  match stroke with
  | None -> ()
  | Some (s : Element.stroke) ->
    Cairo.save cr;
    apply_transform cr transform;
    add_geom ();
    let (r, g, b, a) = color_rgba s.stroke_color in
    Cairo.set_source_rgba cr r g b (a *. s.stroke_opacity);
    Cairo.set_line_width cr s.stroke_width;
    Cairo.stroke cr;
    Cairo.restore cr

let emit_text cr ~tspans ~font_family ~font_size ~x ~y ~fill ~transform =
  let s = String.concat "" (Array.to_list (Array.map
    (fun (sp : Element.tspan) -> sp.content) tspans)) in
  if s = "" then () else begin
    let (r, g, b, a) =
      match fill with
      | Some (f : Element.fill) ->
        let (r, g, b, a) = color_rgba f.fill_color in
        (r, g, b, a *. f.fill_opacity)
      | None -> (0.0, 0.0, 0.0, 1.0)
    in
    Cairo.save cr;
    apply_transform cr transform;
    Cairo.set_source_rgba cr r g b a;
    Cairo.select_font_face cr font_family;
    Cairo.set_font_size cr font_size;
    Cairo.move_to cr x y;
    Cairo.show_text cr s;
    Cairo.restore cr
  end

let rec emit_element cr (el : Element.element) ~filter =
  match el with
  | Layer { children; visibility; transform; _ } ->
    if not (layer_passes_filter ~visibility filter) then () else begin
      Cairo.save cr;
      apply_transform cr transform;
      Array.iter (fun child -> emit_element cr child ~filter) children;
      Cairo.restore cr
    end
  | Group { children; visibility; transform; _ } ->
    if visibility = Element.Invisible then () else begin
      Cairo.save cr;
      apply_transform cr transform;
      Array.iter (fun child -> emit_element cr child ~filter) children;
      Cairo.restore cr
    end
  | Rect { x; y; width; height; fill; stroke; transform; visibility; _ } ->
    if visibility = Element.Invisible then () else
    emit_paint cr ~fill ~stroke ~transform
      (fun () -> Cairo.rectangle cr x y ~w:width ~h:height)
  | Line { x1; y1; x2; y2; stroke; transform; visibility; _ } ->
    if visibility = Element.Invisible then () else
    emit_stroke_only cr ~stroke ~transform
      (fun () -> Cairo.move_to cr x1 y1; Cairo.line_to cr x2 y2)
  | Circle { cx; cy; r; fill; stroke; transform; visibility; _ } ->
    if visibility = Element.Invisible then () else
    emit_paint cr ~fill ~stroke ~transform
      (fun () -> Cairo.arc cr cx cy ~r ~a1:0.0 ~a2:(2.0 *. Float.pi))
  | Ellipse { cx; cy; rx; ry; fill; stroke; transform; visibility; _ } ->
    if visibility = Element.Invisible then () else
    emit_paint cr ~fill ~stroke ~transform
      (fun () ->
        Cairo.save cr;
        Cairo.translate cr cx cy;
        Cairo.scale cr rx ry;
        Cairo.arc cr 0.0 0.0 ~r:1.0 ~a1:0.0 ~a2:(2.0 *. Float.pi);
        Cairo.restore cr)
  | Polyline { points; fill; stroke; transform; visibility; _ } ->
    if visibility = Element.Invisible then () else
    emit_paint cr ~fill ~stroke ~transform
      (fun () -> add_polyline cr points ~close:false)
  | Polygon { points; fill; stroke; transform; visibility; _ } ->
    if visibility = Element.Invisible then () else
    emit_paint cr ~fill ~stroke ~transform
      (fun () -> add_polyline cr points ~close:true)
  | Path { d; fill; stroke; transform; visibility; _ } ->
    if visibility = Element.Invisible then () else
    emit_paint cr ~fill ~stroke ~transform
      (fun () -> add_path_commands cr d)
  | Text { tspans; font_family; font_size; x; y; fill; transform; visibility; _ } ->
    if visibility = Element.Invisible then () else
    emit_text cr ~tspans ~font_family ~font_size ~x ~y ~fill ~transform
  | Text_path _ | Live _ -> ()  (* Phase 1B deferral *)

let draw_page cr (doc : Document.document) (page : page) =
  Cairo.save cr;
  let (sx, sy) = scaling_pair doc in
  let px = doc.print_preferences.placement_x in
  let py = doc.print_preferences.placement_y in
  if px <> 0.0 || py <> 0.0 then Cairo.translate cr px py;
  if sx <> 1.0 || sy <> 1.0 then Cairo.scale cr sx sy;
  if page.src_x <> 0.0 || page.src_y <> 0.0 then
    Cairo.translate cr (-. page.src_x) (-. page.src_y);
  Array.iter (fun layer ->
    emit_element cr layer ~filter:doc.print_preferences.print_layers
  ) doc.layers;
  Cairo.restore cr

(** Convert a document to PDF bytes. *)
let document_to_pdf (doc : Document.document) : string =
  let buf = Buffer.create 4096 in
  let pages = collect_pages doc in
  let first = match pages with
    | p :: _ -> p
    | [] -> { media_w = 612.0; media_h = 792.0;
              src_x = 0.0; src_y = 0.0; src_w = 612.0; src_h = 792.0 }
  in
  let surface = Cairo.PDF.create_for_stream
      (Buffer.add_string buf)
      ~w:first.media_w ~h:first.media_h
  in
  let cr = Cairo.create surface in
  let first_done = ref false in
  List.iter (fun (page : page) ->
    if !first_done then begin
      Cairo.PDF.set_size surface ~w:page.media_w ~h:page.media_h;
      Cairo.show_page cr
    end;
    first_done := true;
    draw_page cr doc page
  ) pages;
  if !first_done then Cairo.show_page cr;
  Cairo.Surface.finish surface;
  Buffer.contents buf
