(** YAML-driven canvas tool — the OCaml analogue of
    [jas_dioxus/src/tools/yaml_tool.rs] and
    [JasSwift/Sources/Tools/YamlTool.swift].

    Parses a tool spec (typically from workspace.json under
    [tools.<id>]) into a [tool_spec], seeds a private [State_store]
    with its state defaults, and routes [canvas_tool] events
    through the declared handlers via [Effects.run_effects] +
    [Yaml_tool_effects.build].

    Phase 5 of the OCaml YAML tool-runtime migration: [canvas_tool]
    conformance + event dispatch. Overlay rendering is minimal
    for now (Phase 5b adds rect/line/polygon/star/buffer/pen/
    partial-selection renderers). *)

(** Tool-overlay declaration — guard expression plus a render
    JSON subtree. *)
type overlay_spec = {
  guard : string option;
  render : Yojson.Safe.t;
}

(** Parsed shape of a tool YAML spec. *)
type tool_spec = {
  id : string;
  cursor : string option;
  menu_label : string option;
  shortcut : string option;
  state_defaults : (string * Yojson.Safe.t) list;
  handlers : (string * Yojson.Safe.t list) list;
  overlay : overlay_spec list;
  (** Overlay declarations. Most tools have zero or one entry;
      the transform-tool family (Scale / Rotate / Shear) uses
      multiple to layer the reference-point cross over the
      drag-time bbox ghost. Each entry's guard is evaluated
      independently. *)
}

let parse_state_defaults (val_ : Yojson.Safe.t option)
  : (string * Yojson.Safe.t) list =
  match val_ with
  | Some (`Assoc pairs) ->
    List.map (fun (key, defn) ->
      match defn with
      | `Assoc d ->
        (match List.assoc_opt "default" d with
         | Some v -> (key, v)
         | None -> (key, `Null))
      | _ -> (key, defn)
    ) pairs
  | _ -> []

let parse_handlers (val_ : Yojson.Safe.t option)
  : (string * Yojson.Safe.t list) list =
  match val_ with
  | Some (`Assoc pairs) ->
    List.filter_map (fun (name, effects) ->
      match effects with
      | `List effs -> Some (name, effs)
      | _ -> None
    ) pairs
  | _ -> []

let parse_overlay_entry (pairs : (string * Yojson.Safe.t) list)
  : overlay_spec option =
  match List.assoc_opt "render" pairs with
  | Some render ->
    let guard = match List.assoc_opt "if" pairs with
      | Some (`String s) -> Some s
      | _ -> None
    in
    Some { guard; render }
  | None -> None

(** Accept either a single [{if, render}] dict (most tools) or a
    list of such dicts (transform-tool family). Both produce the
    same [overlay_spec list] downstream. *)
let parse_overlay (val_ : Yojson.Safe.t option) : overlay_spec list =
  match val_ with
  | Some (`Assoc pairs) ->
    (match parse_overlay_entry pairs with
     | Some o -> [o]
     | None -> [])
  | Some (`List items) ->
    List.filter_map (function
      | `Assoc pairs -> parse_overlay_entry pairs
      | _ -> None
    ) items
  | _ -> []

(** Parse a single tool spec, typically loaded from workspace.json
    under [tools.<id>]. Returns [None] if the spec is missing its
    required [id] field. *)
let tool_spec_from_workspace (spec : Yojson.Safe.t) : tool_spec option =
  match spec with
  | `Assoc pairs ->
    (match List.assoc_opt "id" pairs with
     | Some (`String id) ->
       Some {
         id;
         cursor = (match List.assoc_opt "cursor" pairs with
                   | Some (`String s) -> Some s | _ -> None);
         menu_label = (match List.assoc_opt "menu_label" pairs with
                       | Some (`String s) -> Some s | _ -> None);
         shortcut = (match List.assoc_opt "shortcut" pairs with
                     | Some (`String s) -> Some s | _ -> None);
         state_defaults = parse_state_defaults
                            (List.assoc_opt "state" pairs);
         handlers = parse_handlers (List.assoc_opt "handlers" pairs);
         overlay = parse_overlay (List.assoc_opt "overlay" pairs);
       }
     | _ -> None)
  | _ -> None

(** Fetch a handler list by event name. Returns [] when the event
    has no declared handler — callers treat that as a no-op. *)
let handler (spec : tool_spec) (event_name : string) : Yojson.Safe.t list =
  match List.assoc_opt event_name spec.handlers with
  | Some effs -> effs
  | None -> []

(* ═══════════════════════════════════════════════════════════════
   Overlay rendering (Phase 5b)

   Ports jas_dioxus/src/tools/yaml_tool.rs draw_*_overlay functions
   to Cairo. Each render type is a small draw_ helper; dispatch
   happens in the [yaml_tool] class's [draw_overlay] method below.
   ═══════════════════════════════════════════════════════════════ *)

(** Subset of CSS style properties the overlay renderer understands.
    Matches [yaml_tool.rs] OverlayStyle. *)
type overlay_style = {
  fill : string option;
  stroke : string option;
  stroke_width : float option;
  stroke_dasharray : float list option;
}

let empty_style = {
  fill = None; stroke = None;
  stroke_width = None; stroke_dasharray = None;
}

(** Parse a CSS-like ["key: value; key: value"] string into an
    overlay_style. Unknown keys and malformed rules are ignored. *)
let parse_style (s : string) : overlay_style =
  let rules = String.split_on_char ';' s in
  List.fold_left (fun acc rule ->
    let rule = String.trim rule in
    if rule = "" then acc
    else
      match String.index_opt rule ':' with
      | None -> acc
      | Some i ->
        let key = String.trim (String.sub rule 0 i) in
        let value = String.trim (String.sub rule (i + 1)
                                   (String.length rule - i - 1)) in
        (match key with
         | "fill" -> { acc with fill = Some value }
         | "stroke" -> { acc with stroke = Some value }
         | "stroke-width" ->
           (try { acc with stroke_width = Some (float_of_string value) }
            with _ -> acc)
         | "stroke-dasharray" ->
           let parts =
             value
             |> String.map (fun c -> if c = ',' then ' ' else c)
             |> String.split_on_char ' '
             |> List.filter (fun p -> p <> "")
             |> List.filter_map (fun p ->
               try Some (float_of_string p) with _ -> None)
           in
           if parts = [] then acc
           else { acc with stroke_dasharray = Some parts }
         | _ -> acc)
  ) empty_style rules

(** Parse a CSS color string into ``(r, g, b, a)`` normalized to
    ``[0.0, 1.0]``. Accepts:
    - ``#rrggbb`` / ``#rgb``
    - ``rgb(R, G, B)`` with integer 0-255 components
    - ``rgba(R, G, B, A)`` with integer 0-255 R/G/B and float 0-1 A
    - a handful of named colors (``black``, ``white``, ``none``).

    Returns [None] for ``none`` or unparseable input. *)
let parse_color (s : string) : (float * float * float * float) option =
  let s = String.trim s in
  if s = "" || s = "none" then None
  else if s = "black" then Some (0.0, 0.0, 0.0, 1.0)
  else if s = "white" then Some (1.0, 1.0, 1.0, 1.0)
  else if String.length s > 0 && s.[0] = '#' then
    let hex = String.sub s 1 (String.length s - 1) in
    let expand3 c = String.make 2 c in
    let hex = if String.length hex = 3 then
        expand3 hex.[0] ^ expand3 hex.[1] ^ expand3 hex.[2]
      else hex in
    if String.length hex <> 6 then None
    else
      try
        let r = float_of_int (int_of_string ("0x" ^ String.sub hex 0 2)) /. 255.0 in
        let g = float_of_int (int_of_string ("0x" ^ String.sub hex 2 2)) /. 255.0 in
        let b = float_of_int (int_of_string ("0x" ^ String.sub hex 4 2)) /. 255.0 in
        Some (r, g, b, 1.0)
      with _ -> None
  else
    (* rgb(...) / rgba(...) *)
    let prefix_rgba = "rgba(" in
    let prefix_rgb = "rgb(" in
    let body, has_alpha =
      if String.length s > String.length prefix_rgba
         && String.sub s 0 (String.length prefix_rgba) = prefix_rgba then
        Some (String.sub s (String.length prefix_rgba)
                (String.length s - String.length prefix_rgba)), true
      else if String.length s > String.length prefix_rgb
              && String.sub s 0 (String.length prefix_rgb) = prefix_rgb then
        Some (String.sub s (String.length prefix_rgb)
                (String.length s - String.length prefix_rgb)), false
      else None, false
    in
    match body with
    | None -> None
    | Some b ->
      let b = String.trim b in
      let b = if String.length b > 0 && b.[String.length b - 1] = ')'
              then String.sub b 0 (String.length b - 1)
              else b in
      let parts = List.map String.trim (String.split_on_char ',' b) in
      (try
         let to_unit s = float_of_string s /. 255.0 in
         (match parts with
          | [r; g; b] when not has_alpha ->
            Some (to_unit r, to_unit g, to_unit b, 1.0)
          | [r; g; b; a] when has_alpha ->
            Some (to_unit r, to_unit g, to_unit b, float_of_string a)
          | _ -> None)
       with _ -> None)

(** Evaluate an overlay numeric field. [None] / null / non-numeric
    → 0.0; string → evaluated as an expression. *)
let eval_number_field (ctx : Yojson.Safe.t) (field : Yojson.Safe.t option)
  : float =
  match field with
  | None | Some `Null -> 0.0
  | Some (`Int i) -> float_of_int i
  | Some (`Float f) -> f
  | Some (`String s) ->
    (match Expr_eval.evaluate s ctx with
     | Expr_eval.Number n -> n
     | _ -> 0.0)
  | _ -> 0.0

(** Evaluate an overlay bool field (expression-string-or-literal).
    Matches [yaml_tool.rs]'s inline decoder for [close_hint] etc. *)
let eval_bool_field (ctx : Yojson.Safe.t) (field : Yojson.Safe.t option)
  : bool =
  match field with
  | None | Some `Null -> false
  | Some (`Bool b) -> b
  | Some (`String s) ->
    (match Expr_eval.evaluate s ctx with
     | v -> Expr_eval.to_bool v)
  | _ -> false

(** Evaluate an overlay string field that may be an expression. *)
let eval_string_field (ctx : Yojson.Safe.t) (field : Yojson.Safe.t option)
  : string =
  match field with
  | None | Some `Null -> ""
  | Some (`String s) ->
    (match Expr_eval.evaluate s ctx with
     | Expr_eval.Str v -> v
     | _ -> s)
  | _ -> ""

let render_get (render : Yojson.Safe.t) (key : string) : Yojson.Safe.t option =
  match render with
  | `Assoc pairs -> List.assoc_opt key pairs
  | _ -> None

let render_string (render : Yojson.Safe.t) (key : string) : string =
  match render_get render key with
  | Some (`String s) -> s
  | _ -> ""

(** Apply the Cairo source + line-width + dash state from a parsed
    style. Returns [true] when a stroke color was set — the caller
    uses this to decide whether to run [Cairo.stroke]. *)
let apply_stroke_style (cr : Cairo.context) (style : overlay_style) : bool =
  match style.stroke with
  | None -> false
  | Some stroke ->
    (match parse_color stroke with
     | None -> false
     | Some (r, g, b, a) ->
       Cairo.set_source_rgba cr r g b a;
       (match style.stroke_width with
        | Some w -> Cairo.set_line_width cr w
        | None -> ());
       (match style.stroke_dasharray with
        | Some dashes -> Cairo.set_dash cr (Array.of_list dashes)
        | None -> ());
       true)

let clear_dash_if_set (cr : Cairo.context) (style : overlay_style) : unit =
  match style.stroke_dasharray with
  | Some _ -> Cairo.set_dash cr [||]
  | None -> ()

(** Apply the Cairo source from a fill style. Returns [true] when a
    fill color was set. *)
let apply_fill_style (cr : Cairo.context) (style : overlay_style) : bool =
  match style.fill with
  | None -> false
  | Some fill ->
    (match parse_color fill with
     | None -> false
     | Some (r, g, b, a) ->
       Cairo.set_source_rgba cr r g b a;
       true)

(* ── build_rounded_rect_path ───────────────────────────── *)

(** Build a rounded-rectangle path. Caller decides whether to fill
    or stroke. Max-radius is clamped to half the shorter side so
    arcs don't overlap on small rects. *)
let build_rounded_rect_path (cr : Cairo.context)
    (x : float) (y : float) (w : float) (h : float)
    (rx : float) (ry : float) : unit =
  let r = Float.max 0.0
            (Float.min (Float.max rx ry)
               (Float.min (w /. 2.0) (h /. 2.0))) in
  Cairo.move_to cr (x +. r) y;
  Cairo.line_to cr (x +. w -. r) y;
  Cairo.curve_to cr (x +. w) y (x +. w) y (x +. w) (y +. r);
  Cairo.line_to cr (x +. w) (y +. h -. r);
  Cairo.curve_to cr (x +. w) (y +. h) (x +. w) (y +. h) (x +. w -. r) (y +. h);
  Cairo.line_to cr (x +. r) (y +. h);
  Cairo.curve_to cr x (y +. h) x (y +. h) x (y +. h -. r);
  Cairo.line_to cr x (y +. r);
  Cairo.curve_to cr x y x y (x +. r) y;
  Cairo.Path.close cr

(* ── Render handlers ────────────────────────────────────── *)

(* Marquee zoom rectangle: thin dashed stroke between (x1, y1) and
   (x2, y2). Used by the Zoom tool drag overlay when scrubby_zoom
   is off. Per ZOOM_TOOL.md Drag - marquee zoom. *)
(* Draw the 8 resize handles on the single panel-selected artboard
   per ARTBOARD_TOOL.md §Drag-to-resize. Mirrors Rust /
   Swift draw_artboard_resize_handles. Handles are 8 px screen-space
   squares; coordinates transform from document to viewport via
   model#zoom_level + view_offset_*. *)
let draw_artboard_resize_handles (cr : Cairo.context)
    (render : Yojson.Safe.t) (eval_ctx : Yojson.Safe.t)
    (model : Model.model) : unit =
  let id =
    match render_get render "artboard_id" with
    | Some (`String s) ->
      (match Expr_eval.evaluate s eval_ctx with
       | Expr_eval.Str v -> v
       | _ -> "")
    | _ -> ""
  in
  if id = "" then () else
  let doc = model#document in
  match List.find_opt (fun (a : Artboard.artboard) -> a.id = id)
          doc.artboards with
  | None -> ()
  | Some ab ->
    let zoom = model#zoom_level in
    let offx = model#view_offset_x in
    let offy = model#view_offset_y in
    let cx = ab.x +. ab.width /. 2.0 in
    let cy = ab.y +. ab.height /. 2.0 in
    let positions = [
      (ab.x, ab.y);
      (cx, ab.y);
      (ab.x +. ab.width, ab.y);
      (ab.x +. ab.width, cy);
      (ab.x +. ab.width, ab.y +. ab.height);
      (cx, ab.y +. ab.height);
      (ab.x, ab.y +. ab.height);
      (ab.x, cy);
    ] in
    let handle_size = 8.0 in
    let half = handle_size /. 2.0 in
    Cairo.save cr;
    Cairo.set_line_width cr 1.5;
    List.iter (fun (dx, dy) ->
      let vx = dx *. zoom +. offx in
      let vy = dy *. zoom +. offy in
      Cairo.set_source_rgb cr 1.0 1.0 1.0;
      Cairo.rectangle cr (vx -. half) (vy -. half)
        ~w:handle_size ~h:handle_size;
      Cairo.fill_preserve cr;
      Cairo.set_source_rgb cr 0.0 (120.0 /. 255.0) 1.0;
      Cairo.stroke cr
    ) positions;
    Cairo.restore cr

(* Draw the outline-preview rectangle for in-flight move / resize /
   duplicate gestures when update_while_dragging is false. *)
let draw_artboard_outline_preview (cr : Cairo.context)
    (render : Yojson.Safe.t) (eval_ctx : Yojson.Safe.t)
    (model : Model.model) : unit =
  let id =
    match render_get render "artboard_id" with
    | Some (`String s) ->
      (match Expr_eval.evaluate s eval_ctx with
       | Expr_eval.Str v -> v
       | _ -> "")
    | _ -> ""
  in
  if id = "" then () else
  let doc = model#document in
  match List.find_opt (fun (a : Artboard.artboard) -> a.id = id)
          doc.artboards with
  | None -> ()
  | Some ab ->
    let zoom = model#zoom_level in
    let offx = model#view_offset_x in
    let offy = model#view_offset_y in
    let vx = ab.x *. zoom +. offx in
    let vy = ab.y *. zoom +. offy in
    let vw = ab.width *. zoom in
    let vh = ab.height *. zoom in
    Cairo.save cr;
    Cairo.set_source_rgb cr 0.0 (120.0 /. 255.0) 1.0;
    Cairo.set_line_width cr 1.0;
    Cairo.rectangle cr vx vy ~w:vw ~h:vh;
    Cairo.stroke cr;
    Cairo.restore cr

let draw_marquee_rect_overlay (cr : Cairo.context) (render : Yojson.Safe.t)
    (eval_ctx : Yojson.Safe.t) : unit =
  let x1 = eval_number_field eval_ctx (render_get render "x1") in
  let y1 = eval_number_field eval_ctx (render_get render "y1") in
  let x2 = eval_number_field eval_ctx (render_get render "x2") in
  let y2 = eval_number_field eval_ctx (render_get render "y2") in
  let x = min x1 x2 in
  let y = min y1 y2 in
  let w = abs_float (x1 -. x2) in
  let h = abs_float (y1 -. y2) in
  if w > 0.0 && h > 0.0 then begin
    Cairo.save cr;
    Cairo.set_source_rgb cr 0.4 0.4 0.4;
    Cairo.set_line_width cr 1.0;
    Cairo.set_dash cr [| 4.0; 2.0 |];
    Cairo.rectangle cr x y ~w ~h;
    Cairo.stroke cr;
    Cairo.restore cr
  end

let draw_rect_overlay (cr : Cairo.context) (render : Yojson.Safe.t)
    (eval_ctx : Yojson.Safe.t) : unit =
  let x = eval_number_field eval_ctx (render_get render "x") in
  let y = eval_number_field eval_ctx (render_get render "y") in
  let w = eval_number_field eval_ctx (render_get render "width") in
  let h = eval_number_field eval_ctx (render_get render "height") in
  let rx = eval_number_field eval_ctx (render_get render "rx") in
  let ry = eval_number_field eval_ctx (render_get render "ry") in
  let style = parse_style (render_string render "style") in
  let rounded = rx > 0.0 || ry > 0.0 in
  let build_path () =
    if rounded then build_rounded_rect_path cr x y w h rx ry
    else Cairo.rectangle cr x y ~w ~h
  in
  if apply_fill_style cr style then begin
    build_path ();
    Cairo.fill cr
  end;
  if apply_stroke_style cr style then begin
    build_path ();
    Cairo.stroke cr;
    clear_dash_if_set cr style
  end

let draw_line_overlay (cr : Cairo.context) (render : Yojson.Safe.t)
    (eval_ctx : Yojson.Safe.t) : unit =
  let x1 = eval_number_field eval_ctx (render_get render "x1") in
  let y1 = eval_number_field eval_ctx (render_get render "y1") in
  let x2 = eval_number_field eval_ctx (render_get render "x2") in
  let y2 = eval_number_field eval_ctx (render_get render "y2") in
  let style = parse_style (render_string render "style") in
  if apply_stroke_style cr style then begin
    Cairo.move_to cr x1 y1;
    Cairo.line_to cr x2 y2;
    Cairo.stroke cr;
    clear_dash_if_set cr style
  end

(** Shared closed-polygon drawing: build a path from [points], apply
    fill/stroke, reset dash. Used by polygon, star, and
    buffer_polygon. *)
let draw_closed_polygon_from_points (cr : Cairo.context)
    (points : (float * float) list) (render : Yojson.Safe.t) : unit =
  match points with
  | [] -> ()
  | (x0, y0) :: rest ->
    let style = parse_style (render_string render "style") in
    let build_path () =
      Cairo.move_to cr x0 y0;
      List.iter (fun (px, py) -> Cairo.line_to cr px py) rest;
      Cairo.Path.close cr
    in
    if apply_fill_style cr style then begin
      build_path ();
      Cairo.fill cr
    end;
    if apply_stroke_style cr style then begin
      build_path ();
      Cairo.stroke cr;
      clear_dash_if_set cr style
    end

let draw_buffer_polygon_overlay (cr : Cairo.context)
    (render : Yojson.Safe.t) : unit =
  let name = render_string render "buffer" in
  if name = "" then ()
  else
    let points = Point_buffers.points name in
    draw_closed_polygon_from_points cr points render

let draw_buffer_polyline_overlay (cr : Cairo.context)
    (render : Yojson.Safe.t) (eval_ctx : Yojson.Safe.t) : unit =
  let name = render_string render "buffer" in
  if name = "" then ()
  else
    let points = Point_buffers.points name in
    if List.length points < 2 then ()
    else begin
      let style = parse_style (render_string render "style") in
      if apply_stroke_style cr style then begin
        (match points with
         | (x0, y0) :: rest ->
           Cairo.move_to cr x0 y0;
           List.iter (fun (px, py) -> Cairo.line_to cr px py) rest
         | [] -> ());
        Cairo.stroke cr;
        clear_dash_if_set cr style
      end;
      (* Close-at-release hint: dashed line from last buffer point
         back to the first when [close_hint] is truthy. *)
      let hint_on = eval_bool_field eval_ctx
                      (render_get render "close_hint") in
      if hint_on && List.length points >= 2 then begin
        let (sx, sy) = List.hd points in
        let (ex, ey) = List.nth points (List.length points - 1) in
        (match style.stroke with
         | Some stroke ->
           (match parse_color stroke with
            | Some (r, g, b, a) ->
              Cairo.set_source_rgba cr r g b a;
              Cairo.set_line_width cr 1.0;
              Cairo.set_dash cr [| 4.0; 4.0 |];
              Cairo.move_to cr ex ey;
              Cairo.line_to cr sx sy;
              Cairo.stroke cr;
              Cairo.set_dash cr [||]
            | None -> ())
         | None -> ())
      end
    end

let draw_regular_polygon_overlay (cr : Cairo.context)
    (render : Yojson.Safe.t) (eval_ctx : Yojson.Safe.t) : unit =
  let x1 = eval_number_field eval_ctx (render_get render "x1") in
  let y1 = eval_number_field eval_ctx (render_get render "y1") in
  let x2 = eval_number_field eval_ctx (render_get render "x2") in
  let y2 = eval_number_field eval_ctx (render_get render "y2") in
  let sides = int_of_float
                (eval_number_field eval_ctx (render_get render "sides")) in
  let sides = if sides <= 0 then 5 else sides in
  let pts = Regular_shapes.regular_polygon_points x1 y1 x2 y2 sides in
  draw_closed_polygon_from_points cr pts render

let draw_star_overlay (cr : Cairo.context) (render : Yojson.Safe.t)
    (eval_ctx : Yojson.Safe.t) : unit =
  let x1 = eval_number_field eval_ctx (render_get render "x1") in
  let y1 = eval_number_field eval_ctx (render_get render "y1") in
  let x2 = eval_number_field eval_ctx (render_get render "x2") in
  let y2 = eval_number_field eval_ctx (render_get render "y2") in
  let points_n = int_of_float
                   (eval_number_field eval_ctx (render_get render "points")) in
  let points_n = if points_n <= 0 then 5 else points_n in
  let pts = Regular_shapes.star_points x1 y1 x2 y2 points_n in
  draw_closed_polygon_from_points cr pts render

(** Partial Selection tool overlay: blue handle circles on every
    selected Path plus a blue rubber-band rectangle in marquee mode. *)
let draw_partial_selection_overlay (cr : Cairo.context)
    (render : Yojson.Safe.t) (eval_ctx : Yojson.Safe.t)
    (doc : Document.document) : unit =
  let (sr, sg, sb) = (0.0, 120.0 /. 255.0, 1.0) in
  Document.PathMap.iter (fun path _ ->
    match Document.get_element doc path with
    | Element.Path pe ->
      let anchors = Element.control_points (Element.Path pe) in
      List.iteri (fun ai (ax, ay) ->
        let (h_in_opt, h_out_opt) = Element.path_handle_positions pe.d ai in
        let draw_handle = function
          | Some (hx, hy) ->
            Cairo.set_source_rgba cr sr sg sb 1.0;
            Cairo.set_line_width cr 1.0;
            Cairo.move_to cr ax ay;
            Cairo.line_to cr hx hy;
            Cairo.stroke cr;
            Cairo.arc cr hx hy ~r:3.0 ~a1:0.0 ~a2:(2.0 *. Float.pi);
            Cairo.set_source_rgba cr 1.0 1.0 1.0 1.0;
            Cairo.fill_preserve cr;
            Cairo.set_source_rgba cr sr sg sb 1.0;
            Cairo.stroke cr
          | None -> ()
        in
        draw_handle h_in_opt;
        draw_handle h_out_opt
      ) anchors
    | _ -> ()
  ) doc.Document.selection;
  (* Marquee rect. *)
  let mode = eval_string_field eval_ctx (render_get render "mode") in
  if mode = "marquee" then begin
    let sx = eval_number_field eval_ctx (render_get render "marquee_start_x") in
    let sy = eval_number_field eval_ctx (render_get render "marquee_start_y") in
    let cx = eval_number_field eval_ctx (render_get render "marquee_cur_x") in
    let cy = eval_number_field eval_ctx (render_get render "marquee_cur_y") in
    let rx = Float.min sx cx in
    let ry = Float.min sy cy in
    let rw = Float.abs (cx -. sx) in
    let rh = Float.abs (cy -. sy) in
    Cairo.set_source_rgba cr 0.0 (120.0 /. 255.0) (215.0 /. 255.0) 0.1;
    Cairo.rectangle cr rx ry ~w:rw ~h:rh;
    Cairo.fill cr;
    Cairo.set_source_rgba cr 0.0 (120.0 /. 255.0) (215.0 /. 255.0) 0.8;
    Cairo.set_line_width cr 1.0;
    Cairo.rectangle cr rx ry ~w:rw ~h:rh;
    Cairo.stroke cr
  end

(** Pen tool overlay: committed curves between anchors, preview
    curve from last anchor to mouse, handle lines + dots, anchor
    squares, close indicator on hover. *)
let draw_pen_overlay (cr : Cairo.context) (render : Yojson.Safe.t)
    (eval_ctx : Yojson.Safe.t) : unit =
  let name = render_string render "buffer" in
  if name = "" then ()
  else
    let anchors = Anchor_buffers.anchors name in
    if anchors = [] then ()
    else begin
      let mouse_x = eval_number_field eval_ctx (render_get render "mouse_x") in
      let mouse_y = eval_number_field eval_ctx (render_get render "mouse_y") in
      let close_radius = Float.max 1.0
                           (eval_number_field eval_ctx
                              (render_get render "close_radius")) in
      let placing = eval_bool_field eval_ctx (render_get render "placing") in
      (* 1. Committed curves between consecutive anchors. *)
      if List.length anchors >= 2 then begin
        Cairo.set_source_rgba cr 0.0 0.0 0.0 1.0;
        Cairo.set_line_width cr 1.0;
        let first = List.hd anchors in
        Cairo.move_to cr first.Anchor_buffers.x first.Anchor_buffers.y;
        let rec draw_rest prev = function
          | [] -> ()
          | (curr : Anchor_buffers.anchor) :: rest ->
            Cairo.curve_to cr
              prev.Anchor_buffers.hx_out prev.Anchor_buffers.hy_out
              curr.Anchor_buffers.hx_in curr.Anchor_buffers.hy_in
              curr.Anchor_buffers.x curr.Anchor_buffers.y;
            draw_rest curr rest
        in
        draw_rest first (List.tl anchors);
        Cairo.stroke cr
      end;
      (* 2. Preview curve from last anchor to mouse. *)
      if placing then begin
        let last = List.nth anchors (List.length anchors - 1) in
        let first = List.hd anchors in
        let dx = mouse_x -. first.x in
        let dy = mouse_y -. first.y in
        let near_start = List.length anchors >= 2
                         && Float.hypot dx dy <= close_radius in
        Cairo.set_source_rgba cr (100.0 /. 255.0) (100.0 /. 255.0)
          (100.0 /. 255.0) 1.0;
        Cairo.set_line_width cr 1.0;
        Cairo.set_dash cr [| 4.0; 4.0 |];
        Cairo.move_to cr last.x last.y;
        if near_start then
          Cairo.curve_to cr
            last.hx_out last.hy_out
            first.hx_in first.hy_in
            first.x first.y
        else
          Cairo.curve_to cr
            last.hx_out last.hy_out
            mouse_x mouse_y
            mouse_x mouse_y;
        Cairo.stroke cr;
        Cairo.set_dash cr [||]
      end;
      (* 3. Handle lines + 4. Anchor squares. *)
      let (sr, sg, sb) = (0.0, 120.0 /. 255.0, 1.0) in
      let handle_r = 3.0 in
      let anchor_half = 5.0 in
      List.iter (fun (a : Anchor_buffers.anchor) ->
        if a.smooth then begin
          Cairo.set_source_rgba cr sr sg sb 1.0;
          Cairo.set_line_width cr 1.0;
          Cairo.move_to cr a.hx_in a.hy_in;
          Cairo.line_to cr a.hx_out a.hy_out;
          Cairo.stroke cr;
          Cairo.arc cr a.hx_in a.hy_in
            ~r:handle_r ~a1:0.0 ~a2:(2.0 *. Float.pi);
          Cairo.set_source_rgba cr 1.0 1.0 1.0 1.0;
          Cairo.fill_preserve cr;
          Cairo.set_source_rgba cr sr sg sb 1.0;
          Cairo.stroke cr;
          Cairo.arc cr a.hx_out a.hy_out
            ~r:handle_r ~a1:0.0 ~a2:(2.0 *. Float.pi);
          Cairo.set_source_rgba cr 1.0 1.0 1.0 1.0;
          Cairo.fill_preserve cr;
          Cairo.set_source_rgba cr sr sg sb 1.0;
          Cairo.stroke cr
        end;
        Cairo.set_source_rgba cr sr sg sb 1.0;
        Cairo.rectangle cr (a.x -. anchor_half) (a.y -. anchor_half)
          ~w:(anchor_half *. 2.0) ~h:(anchor_half *. 2.0);
        Cairo.fill_preserve cr;
        Cairo.stroke cr
      ) anchors;
      (* 5. Close indicator: green circle around the first anchor
         when the cursor is within close_radius. *)
      if List.length anchors >= 2 then begin
        let first = List.hd anchors in
        let dx = mouse_x -. first.x in
        let dy = mouse_y -. first.y in
        if Float.hypot dx dy <= close_radius then begin
          Cairo.set_source_rgba cr 0.0 (200.0 /. 255.0) 0.0 1.0;
          Cairo.set_line_width cr 2.0;
          Cairo.arc cr first.x first.y
            ~r:(anchor_half +. 2.0) ~a1:0.0 ~a2:(2.0 *. Float.pi);
          Cairo.stroke cr
        end
      end
    end

(** Add a 24-segment rotated-ellipse path at (cx, cy) to the current
    Cairo path. Caller decides whether to fill or stroke. *)
let add_oval_path (cr : Cairo.context)
    (cx : float) (cy : float)
    (rx : float) (ry : float) (rad : float) : unit =
  let segments = 24 in
  let cs = cos rad and sn = sin rad in
  for i = 0 to segments do
    let t = 2.0 *. Float.pi *. float_of_int i /. float_of_int segments in
    let lx = rx *. cos t in
    let ly = ry *. sin t in
    let x = cx +. lx *. cs -. ly *. sn in
    let y = cy +. lx *. sn +. ly *. cs in
    if i = 0 then Cairo.move_to cr x y
    else Cairo.line_to cr x y
  done;
  Cairo.Path.close cr

(* Blob Brush oval cursor + drag preview.
   See BLOB_BRUSH_TOOL.md Overlay.

   The two transform-tool overlay helpers below are inserted between
   the comment and the function definition; the docstring marker has
   been demoted to a plain comment to avoid the warning-50 unattached
   documentation comment error. *)

(** Resolve the reference-point coordinate for a transform-tool
    overlay. Reads the [ref_point] field (typically the expression
    [state.transform_reference_point]) — when it's a list of two
    numbers, returns those. Otherwise falls back to the selection
    union bbox center. Returns [None] when there is no selection. *)
let resolve_overlay_ref_point (render : Yojson.Safe.t)
    (eval_ctx : Yojson.Safe.t) (doc : Document.document)
  : (float * float) option =
  let custom = match render_get render "ref_point" with
    | Some (`String expr) ->
      (match Expr_eval.evaluate expr eval_ctx with
       | Expr_eval.List items when List.length items >= 2 ->
         let to_f = function
           | `Int i -> Some (float_of_int i)
           | `Float f -> Some f | _ -> None
         in
         (match to_f (List.nth items 0), to_f (List.nth items 1) with
          | Some rx, Some ry -> Some (rx, ry) | _ -> None)
       | _ -> None)
    | _ -> None
  in
  match custom with
  | Some _ -> custom
  | None ->
    let elements = Document.PathMap.bindings doc.selection
                   |> List.filter_map (fun (path, _) ->
                     try Some (Document.get_element doc path)
                     with _ -> None)
    in
    if elements = [] then None
    else
      let (x, y, w, h) =
        Align.union_bounds elements Align.geometric_bounds in
      Some (x +. w /. 2.0, y +. h /. 2.0)

(** Draw the cyan-blue reference-point cross used by Scale, Rotate,
    Shear. 12 px crosshair + 2 px dot, color [#4A9EFF]. Hidden when
    there is no selection. See [SCALE_TOOL.md] \167 Reference-point
    cross overlay. *)
let draw_reference_point_cross (cr : Cairo.context)
    (render : Yojson.Safe.t) (eval_ctx : Yojson.Safe.t)
    (doc : Document.document) : unit =
  match resolve_overlay_ref_point render eval_ctx doc with
  | None -> ()
  | Some (rx, ry) ->
    let r = float_of_int 0x4A /. 255.0
    and g = float_of_int 0x9E /. 255.0
    and b = float_of_int 0xFF /. 255.0 in
    Cairo.set_source_rgba cr r g b 1.0;
    Cairo.set_line_width cr 1.0;
    let arm = 6.0 in
    Cairo.move_to cr (rx -. arm) ry;
    Cairo.line_to cr (rx +. arm) ry;
    Cairo.stroke cr;
    Cairo.move_to cr rx (ry -. arm);
    Cairo.line_to cr rx (ry +. arm);
    Cairo.stroke cr;
    Cairo.arc cr rx ry ~r:2.0 ~a1:0.0 ~a2:(2.0 *. Float.pi);
    Cairo.fill cr

(** Draw the dashed post-transform bounding-box ghost during a drag.
    Reads [transform_kind] ("scale" / "rotate" / "shear"), press +
    cursor + shift_held, composes the matrix via [Transform_apply]
    and renders the union bbox of the selection under that matrix. *)
let draw_bbox_ghost (cr : Cairo.context) (render : Yojson.Safe.t)
    (eval_ctx : Yojson.Safe.t) (doc : Document.document) : unit =
  match resolve_overlay_ref_point render eval_ctx doc with
  | None -> ()
  | Some (rx, ry) ->
    let kind =
      match render_get render "transform_kind" with
      | Some (`String s) ->
        (match Expr_eval.evaluate s eval_ctx with
         | Expr_eval.Str v -> v
         | _ -> "")
      | _ -> ""
    in
    let px = eval_number_field eval_ctx (render_get render "press_x") in
    let py = eval_number_field eval_ctx (render_get render "press_y") in
    let cx = eval_number_field eval_ctx (render_get render "cursor_x") in
    let cy = eval_number_field eval_ctx (render_get render "cursor_y") in
    let shift = eval_bool_field eval_ctx (render_get render "shift_held") in
    let matrix = match kind with
      | "scale" ->
        let denom_x = px -. rx and denom_y = py -. ry in
        let sx = if abs_float denom_x < 1e-9 then 1.0
                 else (cx -. rx) /. denom_x in
        let sy = if abs_float denom_y < 1e-9 then 1.0
                 else (cy -. ry) /. denom_y in
        let (sx, sy) = if shift then
          let prod = sx *. sy in
          let sign = if prod >= 0.0 then 1.0 else -. 1.0 in
          let s = sign *. sqrt (abs_float prod) in
          (s, s)
        else (sx, sy)
        in
        Transform_apply.scale_matrix ~sx ~sy ~rx ~ry
      | "rotate" ->
        let tp = atan2 (py -. ry) (px -. rx) in
        let tc = atan2 (cy -. ry) (cx -. rx) in
        let theta_deg = (tc -. tp) *. 180.0 /. Float.pi in
        let theta_deg = if shift
          then Float.round (theta_deg /. 45.0) *. 45.0
          else theta_deg in
        Transform_apply.rotate_matrix ~theta_deg ~rx ~ry
      | "shear" ->
        let dx = cx -. px and dy = cy -. py in
        if shift then begin
          if abs_float dx >= abs_float dy then
            let denom = max (abs_float (py -. ry)) 1e-9 in
            let k = dx /. denom in
            Transform_apply.shear_matrix
              ~angle_deg:(atan k *. 180.0 /. Float.pi)
              ~axis:"horizontal" ~axis_angle_deg:0.0 ~rx ~ry
          else
            let denom = max (abs_float (px -. rx)) 1e-9 in
            let k = dy /. denom in
            Transform_apply.shear_matrix
              ~angle_deg:(atan k *. 180.0 /. Float.pi)
              ~axis:"vertical" ~axis_angle_deg:0.0 ~rx ~ry
        end else begin
          let ax = px -. rx and ay = py -. ry in
          let axis_len = max (sqrt (ax *. ax +. ay *. ay)) 1e-9 in
          let perp_x = -. ay /. axis_len and perp_y = ax /. axis_len in
          let perp_dist = (cx -. px) *. perp_x +. (cy -. py) *. perp_y in
          let k = perp_dist /. axis_len in
          let axis_angle_deg = atan2 ay ax *. 180.0 /. Float.pi in
          Transform_apply.shear_matrix
            ~angle_deg:(atan k *. 180.0 /. Float.pi)
            ~axis:"custom" ~axis_angle_deg ~rx ~ry
        end
      | _ -> Element.identity_transform
    in
    let elements = Document.PathMap.bindings doc.selection
                   |> List.filter_map (fun (path, _) ->
                     try Some (Document.get_element doc path)
                     with _ -> None)
    in
    if elements = [] then () else begin
      let (bx, by, bw, bh) =
        Align.union_bounds elements Align.geometric_bounds in
      let p = Element.apply_point matrix in
      let c0 = p bx by in
      let c1 = p (bx +. bw) by in
      let c2 = p (bx +. bw) (by +. bh) in
      let c3 = p bx (by +. bh) in
      let r = float_of_int 0x4A /. 255.0
    and g = float_of_int 0x9E /. 255.0
    and b = float_of_int 0xFF /. 255.0 in
      Cairo.set_source_rgba cr r g b 1.0;
      Cairo.set_line_width cr 1.0;
      Cairo.set_dash cr [| 4.0; 2.0 |];
      Cairo.move_to cr (fst c0) (snd c0);
      Cairo.line_to cr (fst c1) (snd c1);
      Cairo.line_to cr (fst c2) (snd c2);
      Cairo.line_to cr (fst c3) (snd c3);
      Cairo.Path.close cr;
      Cairo.stroke cr;
      Cairo.set_dash cr [||]
    end

let draw_oval_cursor_overlay (cr : Cairo.context)
    (render : Yojson.Safe.t) (eval_ctx : Yojson.Safe.t) : unit =
  let cx = eval_number_field eval_ctx (render_get render "x") in
  let cy = eval_number_field eval_ctx (render_get render "y") in
  let size = Float.max 1.0
               (eval_number_field eval_ctx (render_get render "default_size")) in
  let angle_deg = eval_number_field eval_ctx
                    (render_get render "default_angle") in
  let roundness = Float.max 1.0
                    (eval_number_field eval_ctx
                       (render_get render "default_roundness")) in
  let stroke_color_str =
    let s = render_string render "stroke_color" in
    if s = "" then "#000000" else s
  in
  let stroke_rgba = match parse_color stroke_color_str with
    | Some rgba -> rgba
    | None -> (0.0, 0.0, 0.0, 1.0)
  in
  let dashed = eval_bool_field eval_ctx (render_get render "dashed") in
  let mode =
    (* Evaluate the mode expression; Rust accepts either a bare
       literal quoted string or an expression returning a string. *)
    match render_get render "mode" with
    | Some (`String s) ->
      let trimmed =
        if String.length s >= 2
           && ((s.[0] = '\'' && s.[String.length s - 1] = '\'')
               || (s.[0] = '"' && s.[String.length s - 1] = '"'))
        then String.sub s 1 (String.length s - 2)
        else
          (match Expr_eval.evaluate s eval_ctx with
           | Expr_eval.Str v -> v
           | _ -> s)
      in
      trimmed
    | _ -> "idle"
  in
  let rx = size *. 0.5 in
  let ry = size *. (roundness /. 100.0) *. 0.5 in
  let rad = angle_deg *. Float.pi /. 180.0 in
  (* Drag preview: if a buffer is named and mode != idle, draw each
     buffered point as an oval. Painting = semi-transparent fill;
     erasing = dashed outline. *)
  if mode <> "idle" then begin
    match render_get render "buffer" with
    | Some (`String buffer_name) when buffer_name <> "" ->
      let points = Point_buffers.points buffer_name in
      if List.length points >= 2 then begin
        let (r, g, b, _) = stroke_rgba in
        if mode = "painting" then begin
          Cairo.set_source_rgba cr r g b 0.3;
          List.iter (fun (px, py) ->
            add_oval_path cr px py rx ry rad;
            Cairo.fill cr
          ) points
        end else if mode = "erasing" then begin
          Cairo.set_source_rgba cr r g b 1.0;
          Cairo.set_line_width cr 1.0;
          Cairo.set_dash cr [| 3.0; 3.0 |];
          List.iter (fun (px, py) ->
            add_oval_path cr px py rx ry rad;
            Cairo.stroke cr
          ) points;
          Cairo.set_dash cr [||]
        end
      end
    | _ -> ()
  end;
  (* Hover cursor outline at (cx, cy). Dashed stroke signals erase. *)
  let (r, g, b, a) = stroke_rgba in
  Cairo.set_source_rgba cr r g b a;
  Cairo.set_line_width cr 1.0;
  if dashed then Cairo.set_dash cr [| 4.0; 4.0 |];
  add_oval_path cr cx cy rx ry rad;
  Cairo.stroke cr;
  if dashed then Cairo.set_dash cr [||];
  (* Center crosshair for precision aiming. *)
  Cairo.move_to cr (cx -. 3.0) cy;
  Cairo.line_to cr (cx +. 3.0) cy;
  Cairo.move_to cr cx (cy -. 3.0);
  Cairo.line_to cr cx (cy +. 3.0);
  Cairo.stroke cr

(* ─────────────────────────────────────────────────────────────────
   cursor_color_chip — a 12x12 chip following the cursor at offset
   (+12, +12), filled with the cached fill color and bordered with
   the cached stroke color. See EYEDROPPER_TOOL.md §Overlay. *)

(** Convert a JSON color value (hex string, [r;g;b] / [r;g;b;a]
    array, or {r,g,b,a} object) to a (r, g, b, a) tuple in [0, 1].
    Falls back to opaque black on parse failure. Mirrors the
    Rust color_value_to_css. *)
let color_value_to_rgba (v : Yojson.Safe.t) : float * float * float * float =
  match v with
  | `String s ->
    (match parse_color s with
     | Some rgba -> rgba
     | None -> (0.0, 0.0, 0.0, 1.0))
  | `List items when List.length items >= 3 ->
    let to_f = function
      | `Float f -> f
      | `Int i -> float_of_int i
      | _ -> 0.0
    in
    let r = to_f (List.nth items 0) in
    let g = to_f (List.nth items 1) in
    let b = to_f (List.nth items 2) in
    let a =
      if List.length items >= 4 then to_f (List.nth items 3) else 1.0
    in
    (r, g, b, a)
  | `Assoc fields ->
    let f k = match List.assoc_opt k fields with
      | Some (`Float v) -> v
      | Some (`Int i) -> float_of_int i
      | _ -> 0.0
    in
    (f "r", f "g", f "b",
     match List.assoc_opt "a" fields with
     | Some (`Float v) -> v
     | Some (`Int i) -> float_of_int i
     | _ -> 1.0)
  | _ -> (0.0, 0.0, 0.0, 1.0)

let draw_cursor_color_chip_overlay (cr : Cairo.context)
    (render : Yojson.Safe.t) (eval_ctx : Yojson.Safe.t) : unit =
  let cx = eval_number_field eval_ctx (render_get render "x") in
  let cy = eval_number_field eval_ctx (render_get render "y") in
  (* Resolve the [cache:] field. Accept either an inline JSON object
     or a string expression of the form [state.<key>] — read the
     underlying object directly out of eval_ctx since Expr_eval has
     no Assoc value variant. *)
  let cache_value : Yojson.Safe.t =
    match render_get render "cache" with
    | None -> `Null
    | Some (`String expr) ->
      let trimmed = String.trim expr in
      let key =
        if String.length trimmed > 6
           && String.sub trimmed 0 6 = "state."
        then String.sub trimmed 6 (String.length trimmed - 6)
        else trimmed
      in
      (match eval_ctx with
       | `Assoc top ->
         (match List.assoc_opt "state" top with
          | Some (`Assoc state_fields) ->
            (match List.assoc_opt key state_fields with
             | Some v -> v
             | None -> `Null)
          | _ -> `Null)
       | _ -> `Null)
    | Some v -> v
  in
  if cache_value = `Null then ()
  else begin
    let chip_x = cx +. 12.0 in
    let chip_y = cy +. 12.0 in
    let chip_w = 12.0 in
    let chip_h = 12.0 in

    (* Extract fill.color from cache. None means render the
       none-glyph (white square + red diagonal). *)
    let fill_color : Yojson.Safe.t option =
      match cache_value with
      | `Assoc cf ->
        (match List.assoc_opt "fill" cf with
         | Some (`Assoc ff) -> List.assoc_opt "color" ff
         | _ -> None)
      | _ -> None
    in
    (match fill_color with
     | Some color_v ->
       let (r, g, b, a) = color_value_to_rgba color_v in
       Cairo.set_source_rgba cr r g b a;
       Cairo.rectangle cr chip_x chip_y ~w:chip_w ~h:chip_h;
       Cairo.fill cr
     | None ->
       (* None glyph: white square with a red diagonal slash. *)
       Cairo.set_source_rgba cr 1.0 1.0 1.0 1.0;
       Cairo.rectangle cr chip_x chip_y ~w:chip_w ~h:chip_h;
       Cairo.fill cr;
       Cairo.set_source_rgba cr 1.0 0.0 0.0 1.0;
       Cairo.set_line_width cr 1.5;
       Cairo.move_to cr chip_x (chip_y +. chip_h);
       Cairo.line_to cr (chip_x +. chip_w) chip_y;
       Cairo.stroke cr);

    (* Border — 1px from cache.stroke.color, else fixed neutral
       #888 so the chip stays visible against any backdrop. *)
    let stroke_color : Yojson.Safe.t option =
      match cache_value with
      | `Assoc cf ->
        (match List.assoc_opt "stroke" cf with
         | Some (`Assoc sf) -> List.assoc_opt "color" sf
         | _ -> None)
      | _ -> None
    in
    let (r, g, b, a) =
      match stroke_color with
      | Some v -> color_value_to_rgba v
      | None ->
        let neutral = 0x88 in
        let f = float_of_int neutral /. 255.0 in
        (f, f, f, 1.0)
    in
    Cairo.set_source_rgba cr r g b a;
    Cairo.set_line_width cr 1.0;
    Cairo.rectangle cr (chip_x +. 0.5) (chip_y +. 0.5)
      ~w:(chip_w -. 1.0) ~h:(chip_h -. 1.0);
    Cairo.stroke cr
  end

(* ═══════════════════════════════════════════════════════════════ *)

(** Build the [$event] scope for a pointer event. *)
let pointer_payload ?(dragging : bool option) (event_type : string)
    ~x ~y ~shift ~alt : Yojson.Safe.t =
  let base : (string * Yojson.Safe.t) list = [
    ("type", `String event_type);
    ("x", `Float x); ("y", `Float y);
    ("modifiers", `Assoc [
      ("shift", `Bool shift); ("alt", `Bool alt);
      ("ctrl", `Bool false); ("meta", `Bool false);
    ]);
  ] in
  let pairs = match dragging with
    | Some d -> base @ [("dragging", `Bool d)]
    | None -> base
  in
  `Assoc pairs

(** YAML-driven tool. Holds a [tool_spec] and a private [State_store]
    seeded with the tool's state defaults. Each [canvas_tool] method
    builds the [$event] scope, registers the current document for
    doc-aware primitives, and dispatches the matching handler list
    through [Effects.run_effects]. *)
class yaml_tool (spec : tool_spec) = object (_self)
  val spec : tool_spec = spec
  val store : State_store.t = State_store.create ()

  initializer
    State_store.init_tool store spec.id spec.state_defaults

  method spec = spec

  method tool_state (key : string) : Yojson.Safe.t =
    State_store.get_tool store spec.id key

  method private dispatch
      (event_name : string) (event : Yojson.Safe.t)
      (ctrl : Controller.controller) : unit =
    let effects = handler spec event_name in
    if effects <> [] then begin
      let ctx = [("event", event)] in
      let guard = Doc_primitives.register_document ctrl#document in
      let platform_effects = Yaml_tool_effects.build ctrl in
      Effects.run_effects ~platform_effects effects ctx store;
      guard.restore ()
    end

  method on_press (ctx : Canvas_tool.tool_context)
      (x : float) (y : float) ~(shift : bool) ~(alt : bool) =
    _self#dispatch "on_mousedown"
      (pointer_payload "mousedown" ~x ~y ~shift ~alt)
      ctx.controller;
    ctx.request_update ()

  method on_move (ctx : Canvas_tool.tool_context)
      (x : float) (y : float) ~(shift : bool) ~(dragging : bool) =
    _self#dispatch "on_mousemove"
      (pointer_payload "mousemove" ~x ~y ~shift ~alt:false ~dragging)
      ctx.controller;
    ctx.request_update ()

  method on_release (ctx : Canvas_tool.tool_context)
      (x : float) (y : float) ~(shift : bool) ~(alt : bool) =
    _self#dispatch "on_mouseup"
      (pointer_payload "mouseup" ~x ~y ~shift ~alt)
      ctx.controller;
    ctx.request_update ()

  method on_double_click (ctx : Canvas_tool.tool_context)
      (x : float) (y : float) =
    let payload = `Assoc [
      ("type", `String "dblclick");
      ("x", `Float x); ("y", `Float y);
    ] in
    _self#dispatch "on_dblclick" payload ctx.controller;
    ctx.request_update ()

  method on_key (_ctx : Canvas_tool.tool_context) (_keycode : int) = false
  method on_key_release (_ctx : Canvas_tool.tool_context) (_keycode : int) =
    false

  method activate (ctx : Canvas_tool.tool_context) =
    (* Reset tool-local state to declared defaults, then fire on_enter. *)
    State_store.init_tool store spec.id spec.state_defaults;
    let payload = `Assoc [("type", `String "enter")] in
    _self#dispatch "on_enter" payload ctx.controller;
    ctx.request_update ()

  method deactivate (ctx : Canvas_tool.tool_context) =
    let payload = `Assoc [("type", `String "leave")] in
    _self#dispatch "on_leave" payload ctx.controller;
    ctx.request_update ()

  method on_key_event (ctx : Canvas_tool.tool_context)
      (key : string) (mods : Canvas_tool.key_mods) =
    if handler spec "on_keydown" = [] then false
    else begin
      let payload = `Assoc [
        ("type", `String "keydown");
        ("key", `String key);
        ("modifiers", `Assoc [
          ("shift", `Bool mods.shift);
          ("alt", `Bool mods.alt);
          ("ctrl", `Bool mods.ctrl);
          ("meta", `Bool mods.meta);
        ]);
      ] in
      _self#dispatch "on_keydown" payload ctx.controller;
      ctx.request_update ();
      true
    end

  method captures_keyboard () = false
  method cursor_css_override () = spec.cursor
  method is_editing () = false
  method paste_text (_ctx : Canvas_tool.tool_context) (_text : string) = false

  method draw_overlay (ctx : Canvas_tool.tool_context) (cr : Cairo.context)
    : unit =
    if spec.overlay = [] then () else
    let eval_ctx = State_store.eval_context store in
    let guard_handle = Doc_primitives.register_document ctx.controller#document in
    List.iter (fun overlay ->
      let guard_ok = match overlay.guard with
        | None -> true
        | Some g ->
          (match Expr_eval.evaluate g eval_ctx with
           | v -> Expr_eval.to_bool v)
      in
      if guard_ok then begin
        let render_type = match overlay.render with
          | `Assoc pairs ->
            (match List.assoc_opt "type" pairs with
             | Some (`String s) -> s | _ -> "")
          | _ -> ""
        in
        match render_type with
        | "rect" -> draw_rect_overlay cr overlay.render eval_ctx
        | "line" -> draw_line_overlay cr overlay.render eval_ctx
        | "polygon" -> draw_regular_polygon_overlay cr overlay.render eval_ctx
        | "star" -> draw_star_overlay cr overlay.render eval_ctx
        | "buffer_polygon" -> draw_buffer_polygon_overlay cr overlay.render
        | "buffer_polyline" ->
          draw_buffer_polyline_overlay cr overlay.render eval_ctx
        | "pen_overlay" -> draw_pen_overlay cr overlay.render eval_ctx
        | "partial_selection_overlay" ->
          draw_partial_selection_overlay cr overlay.render eval_ctx
            ctx.controller#document
        | "oval_cursor" ->
          draw_oval_cursor_overlay cr overlay.render eval_ctx
        | "cursor_color_chip" ->
          draw_cursor_color_chip_overlay cr overlay.render eval_ctx
        | "reference_point_cross" ->
          draw_reference_point_cross cr overlay.render eval_ctx
            ctx.controller#document
        | "bbox_ghost" ->
          draw_bbox_ghost cr overlay.render eval_ctx
            ctx.controller#document
        | "marquee_rect" ->
          draw_marquee_rect_overlay cr overlay.render eval_ctx
        | "artboard_resize_handles" ->
          draw_artboard_resize_handles cr overlay.render eval_ctx
            ctx.controller#model
        | "artboard_outline_preview" ->
          draw_artboard_outline_preview cr overlay.render eval_ctx
            ctx.controller#model
        | _ -> ()
      end
    ) spec.overlay;
    guard_handle.restore ()
end

(** Convenience: parse the workspace tool dict and construct a
    [yaml_tool]. Returns [None] when the spec fails to parse
    (missing id). *)
let from_workspace_tool (spec : Yojson.Safe.t) : yaml_tool option =
  Option.map (fun s -> new yaml_tool s) (tool_spec_from_workspace spec)
