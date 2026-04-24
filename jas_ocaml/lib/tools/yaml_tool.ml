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
  overlay : overlay_spec option;
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

let parse_overlay (val_ : Yojson.Safe.t option) : overlay_spec option =
  match val_ with
  | Some (`Assoc pairs) ->
    (match List.assoc_opt "render" pairs with
     | Some render ->
       let guard = match List.assoc_opt "if" pairs with
         | Some (`String s) -> Some s
         | _ -> None
       in
       Some { guard; render }
     | None -> None)
  | _ -> None

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
    match spec.overlay with
    | None -> ()
    | Some overlay ->
      let eval_ctx = State_store.eval_context store in
      let guard_ok = match overlay.guard with
        | None -> true
        | Some g ->
          (match Expr_eval.evaluate g eval_ctx with
           | v -> Expr_eval.to_bool v)
      in
      if guard_ok then
        let guard = Doc_primitives.register_document ctx.controller#document in
        let render_type = match overlay.render with
          | `Assoc pairs ->
            (match List.assoc_opt "type" pairs with
             | Some (`String s) -> s | _ -> "")
          | _ -> ""
        in
        (match render_type with
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
         | _ -> ());
        guard.restore ()
end

(** Convenience: parse the workspace tool dict and construct a
    [yaml_tool]. Returns [None] when the spec fails to parse
    (missing id). *)
let from_workspace_tool (spec : Yojson.Safe.t) : yaml_tool option =
  Option.map (fun s -> new yaml_tool s) (tool_spec_from_workspace spec)
