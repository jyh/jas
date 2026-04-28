(* Eyedropper extract / apply helpers. See eyedropper.mli +
   transcripts/EYEDROPPER_TOOL.md. Cross-language parity with
   jas_dioxus/src/algorithms/eyedropper.rs and
   JasSwift/Sources/Algorithms/Eyedropper.swift is mechanical. *)

(* ───────────────────────────────────────────────────────────────── *)
(* Data                                                                *)
(* ───────────────────────────────────────────────────────────────── *)

type appearance = {
  app_fill : Element.fill option;
  app_stroke : Element.stroke option;
  app_opacity : float option;
  app_blend_mode : Element.blend_mode option;
  app_stroke_brush : string option;
  app_width_points : Element.stroke_width_point list;
  app_character : Yojson.Safe.t option;
  app_paragraph : Yojson.Safe.t option;
}

let empty_appearance : appearance = {
  app_fill = None;
  app_stroke = None;
  app_opacity = None;
  app_blend_mode = None;
  app_stroke_brush = None;
  app_width_points = [];
  app_character = None;
  app_paragraph = None;
}

type config = {
  fill : bool;

  stroke : bool;
  stroke_color : bool;
  stroke_weight : bool;
  stroke_cap_join : bool;
  stroke_align : bool;
  stroke_dash : bool;
  stroke_arrowheads : bool;
  stroke_profile : bool;
  stroke_brush : bool;

  opacity : bool;
  opacity_alpha : bool;
  opacity_blend : bool;

  character : bool;
  character_font : bool;
  character_size : bool;
  character_leading : bool;
  character_kerning : bool;
  character_tracking : bool;
  character_color : bool;

  paragraph : bool;
  paragraph_align : bool;
  paragraph_indent : bool;
  paragraph_space : bool;
  paragraph_hyphenate : bool;
}

let default_config : config = {
  fill = true;
  stroke = true;
  stroke_color = true;
  stroke_weight = true;
  stroke_cap_join = true;
  stroke_align = true;
  stroke_dash = true;
  stroke_arrowheads = true;
  stroke_profile = true;
  stroke_brush = true;
  opacity = true;
  opacity_alpha = true;
  opacity_blend = true;
  character = true;
  character_font = true;
  character_size = true;
  character_leading = true;
  character_kerning = true;
  character_tracking = true;
  character_color = true;
  paragraph = true;
  paragraph_align = true;
  paragraph_indent = true;
  paragraph_space = true;
  paragraph_hyphenate = true;
}

(* ───────────────────────────────────────────────────────────────── *)
(* Eligibility                                                          *)
(* ───────────────────────────────────────────────────────────────── *)

let is_container = function
  | Element.Group _ | Element.Layer _ -> true
  | _ -> false

let is_source_eligible (e : Element.element) : bool =
  if Element.get_visibility e = Element.Invisible then false
  else not (is_container e)

let is_target_eligible (e : Element.element) : bool =
  if Element.is_locked e then false
  else not (is_container e)

(* ───────────────────────────────────────────────────────────────── *)
(* Element accessors                                                    *)
(* ───────────────────────────────────────────────────────────────── *)

(* Fill / stroke accessors mirror the magic_wand.ml shape. *)
let fill_of (e : Element.element) : Element.fill option =
  match e with
  | Element.Rect { fill; _ }
  | Element.Circle { fill; _ }
  | Element.Ellipse { fill; _ }
  | Element.Polyline { fill; _ }
  | Element.Polygon { fill; _ }
  | Element.Path { fill; _ }
  | Element.Text { fill; _ }
  | Element.Text_path { fill; _ } -> fill
  | Element.Live (Compound_shape cs) -> cs.fill
  | _ -> None

let stroke_of (e : Element.element) : Element.stroke option =
  match e with
  | Element.Line { stroke; _ }
  | Element.Rect { stroke; _ }
  | Element.Circle { stroke; _ }
  | Element.Ellipse { stroke; _ }
  | Element.Polyline { stroke; _ }
  | Element.Polygon { stroke; _ }
  | Element.Path { stroke; _ }
  | Element.Text { stroke; _ }
  | Element.Text_path { stroke; _ } -> stroke
  | Element.Live (Compound_shape cs) -> cs.stroke
  | _ -> None

let opacity_of (e : Element.element) : float =
  match e with
  | Element.Line { opacity; _ }
  | Element.Rect { opacity; _ }
  | Element.Circle { opacity; _ }
  | Element.Ellipse { opacity; _ }
  | Element.Polyline { opacity; _ }
  | Element.Polygon { opacity; _ }
  | Element.Path { opacity; _ }
  | Element.Text { opacity; _ }
  | Element.Text_path { opacity; _ }
  | Element.Group { opacity; _ }
  | Element.Layer { opacity; _ } -> opacity
  | Element.Live (Compound_shape cs) -> cs.opacity

let stroke_brush_of (e : Element.element) : string option =
  match e with
  | Element.Path { stroke_brush; _ } -> stroke_brush
  | _ -> None

let width_points_of (e : Element.element) : Element.stroke_width_point list =
  match e with
  | Element.Line { width_points; _ } -> width_points
  | Element.Path { width_points; _ } -> width_points
  | _ -> []

(* ───────────────────────────────────────────────────────────────── *)
(* Element setters: opacity / blend_mode                                *)
(* ───────────────────────────────────────────────────────────────── *)

(* element.ml provides with_fill / with_stroke / with_stroke_brush /
   with_width_points but no with_opacity / with_blend_mode setters.
   The Eyedropper apply path uses these only here, so define them
   locally rather than expanding the public Element interface. *)

let with_opacity (e : Element.element) (op : float) : Element.element =
  match e with
  | Line r -> Line { r with opacity = op }
  | Rect r -> Rect { r with opacity = op }
  | Circle r -> Circle { r with opacity = op }
  | Ellipse r -> Ellipse { r with opacity = op }
  | Polyline r -> Polyline { r with opacity = op }
  | Polygon r -> Polygon { r with opacity = op }
  | Path r -> Path { r with opacity = op }
  | Text r -> Text { r with opacity = op }
  | Text_path r -> Text_path { r with opacity = op }
  | Group r -> Group { r with opacity = op }
  | Layer r -> Layer { r with opacity = op }
  | Live (Compound_shape cs) ->
    Live (Compound_shape { cs with opacity = op })

let with_blend_mode (e : Element.element) (bm : Element.blend_mode)
  : Element.element =
  match e with
  | Line r -> Line { r with blend_mode = bm }
  | Rect r -> Rect { r with blend_mode = bm }
  | Circle r -> Circle { r with blend_mode = bm }
  | Ellipse r -> Ellipse { r with blend_mode = bm }
  | Polyline r -> Polyline { r with blend_mode = bm }
  | Polygon r -> Polygon { r with blend_mode = bm }
  | Path r -> Path { r with blend_mode = bm }
  | Text r -> Text { r with blend_mode = bm }
  | Text_path r -> Text_path { r with blend_mode = bm }
  | Group r -> Group { r with blend_mode = bm }
  | Layer r -> Layer { r with blend_mode = bm }
  | Live (Compound_shape cs) ->
    Live (Compound_shape { cs with blend_mode = bm })

(* ───────────────────────────────────────────────────────────────── *)
(* Extract                                                              *)
(* ───────────────────────────────────────────────────────────────── *)

let extract_appearance (e : Element.element) : appearance =
  {
    app_fill = fill_of e;
    app_stroke = stroke_of e;
    app_opacity = Some (opacity_of e);
    app_blend_mode = Some (Element.get_blend_mode e);
    app_stroke_brush = stroke_brush_of e;
    app_width_points = width_points_of e;
    app_character = None;  (* Phase 1 stub *)
    app_paragraph = None;  (* Phase 1 stub *)
  }

(* ───────────────────────────────────────────────────────────────── *)
(* Apply                                                                *)
(* ───────────────────────────────────────────────────────────────── *)

(* Helper for the Stroke group's per-sub-toggle apply. Mirrors the
   Rust apply_stroke_with_subs and the Swift applyStrokeWithSubs.
   When the source has no stroke, propagate "no stroke" (master is
   on, caller already gated). When all sub-toggles are off, leave
   the target's stroke alone. *)
let apply_stroke_with_subs
    (target : Element.element)
    (src : Element.stroke option)
    (cfg : config)
  : Element.element =
  match src with
  | None -> Element.with_stroke target None
  | Some s ->
    let any_sub =
      cfg.stroke_color || cfg.stroke_weight || cfg.stroke_cap_join
      || cfg.stroke_align || cfg.stroke_dash || cfg.stroke_arrowheads
    in
    if not any_sub then target
    else
      let existing : Element.stroke =
        match stroke_of target with
        | Some t -> t
        | None ->
          (* No existing stroke on target — synthesise a base from
             the source's color and width. Sub-toggles below will
             overwrite individual fields. *)
          {
            stroke_color = s.stroke_color;
            stroke_width = s.stroke_width;
            stroke_linecap = Element.Butt;
            stroke_linejoin = Element.Miter;
            stroke_miter_limit = 4.0;
            stroke_align = Element.Center;
            stroke_dash_pattern = [];
            stroke_dash_align_anchors = false;
            stroke_start_arrow = Element.Arrow_none;
            stroke_end_arrow = Element.Arrow_none;
            stroke_start_arrow_scale = 1.0;
            stroke_end_arrow_scale = 1.0;
            stroke_arrow_align = Element.Tip_at_end;
            stroke_opacity = 1.0;
          }
      in
      let new_stroke : Element.stroke = {
        stroke_color =
          if cfg.stroke_color then s.stroke_color else existing.stroke_color;
        stroke_width =
          if cfg.stroke_weight then s.stroke_width else existing.stroke_width;
        stroke_linecap =
          if cfg.stroke_cap_join then s.stroke_linecap else existing.stroke_linecap;
        stroke_linejoin =
          if cfg.stroke_cap_join then s.stroke_linejoin else existing.stroke_linejoin;
        stroke_miter_limit =
          if cfg.stroke_cap_join then s.stroke_miter_limit
          else existing.stroke_miter_limit;
        stroke_align =
          if cfg.stroke_align then s.stroke_align else existing.stroke_align;
        stroke_dash_pattern =
          if cfg.stroke_dash then s.stroke_dash_pattern
          else existing.stroke_dash_pattern;
        stroke_dash_align_anchors = existing.stroke_dash_align_anchors;
        stroke_start_arrow =
          if cfg.stroke_arrowheads then s.stroke_start_arrow
          else existing.stroke_start_arrow;
        stroke_end_arrow =
          if cfg.stroke_arrowheads then s.stroke_end_arrow
          else existing.stroke_end_arrow;
        stroke_start_arrow_scale =
          if cfg.stroke_arrowheads then s.stroke_start_arrow_scale
          else existing.stroke_start_arrow_scale;
        stroke_end_arrow_scale =
          if cfg.stroke_arrowheads then s.stroke_end_arrow_scale
          else existing.stroke_end_arrow_scale;
        stroke_arrow_align =
          if cfg.stroke_arrowheads then s.stroke_arrow_align
          else existing.stroke_arrow_align;
        stroke_opacity =
          if cfg.stroke_color then s.stroke_opacity else existing.stroke_opacity;
      } in
      Element.with_stroke target (Some new_stroke)

let apply_appearance
    (target : Element.element)
    (app : appearance)
    (cfg : config)
  : Element.element =
  let result = ref target in

  (* Fill *)
  if cfg.fill then result := Element.with_fill !result app.app_fill;

  (* Stroke (master + sub-toggles, then brush + profile separately) *)
  if cfg.stroke then begin
    result := apply_stroke_with_subs !result app.app_stroke cfg;
    if cfg.stroke_brush then
      result := Element.with_stroke_brush !result app.app_stroke_brush;
    if cfg.stroke_profile then
      result := Element.with_width_points !result app.app_width_points
  end;

  (* Opacity (master + 2 sub-toggles) *)
  if cfg.opacity then begin
    (match cfg.opacity_alpha, app.app_opacity with
     | true, Some op -> result := with_opacity !result op
     | _ -> ());
    (match cfg.opacity_blend, app.app_blend_mode with
     | true, Some bm -> result := with_blend_mode !result bm
     | _ -> ())
  end;

  (* Character / Paragraph: Phase 1 stub — no-op. *)
  !result

(* ───────────────────────────────────────────────────────────────── *)
(* JSON serialization                                                   *)
(* ───────────────────────────────────────────────────────────────── *)

(* The cache lives in state.eyedropper_cache as a Yojson value. We
   round-trip [appearance] through a JSON object whose keys match the
   Rust serde-derived form (and the Swift hand-written dict shape):
   `fill` / `stroke` / `opacity` / `blend_mode` / `stroke_brush` /
   `width_points` / `character` / `paragraph`. Empty fields are
   omitted. *)

let linecap_to_string : Element.linecap -> string = function
  | Butt -> "butt"
  | Round_cap -> "round"
  | Square -> "square"

let linecap_of_string = function
  | "round" -> Element.Round_cap
  | "square" -> Element.Square
  | _ -> Element.Butt

let linejoin_to_string : Element.linejoin -> string = function
  | Miter -> "miter"
  | Round_join -> "round"
  | Bevel -> "bevel"

let linejoin_of_string = function
  | "round" -> Element.Round_join
  | "bevel" -> Element.Bevel
  | _ -> Element.Miter

let stroke_align_to_string : Element.stroke_align -> string = function
  | Center -> "center"
  | Inside -> "inside"
  | Outside -> "outside"

let stroke_align_of_string = function
  | "inside" -> Element.Inside
  | "outside" -> Element.Outside
  | _ -> Element.Center

let arrow_align_to_string : Element.arrow_align -> string = function
  | Tip_at_end -> "tip_at_end"
  | Center_at_end -> "center_at_end"

let arrow_align_of_string = function
  | "center_at_end" -> Element.Center_at_end
  | _ -> Element.Tip_at_end

(* Color round-trip uses the SVG hex form ("rrggbb"). *)
let color_to_json (c : Element.color) : Yojson.Safe.t =
  `String (Element.color_to_hex c)

let color_of_json : Yojson.Safe.t -> Element.color = function
  | `String s ->
    (match Element.color_from_hex s with
     | Some c -> c
     | None -> Element.black)
  | _ -> Element.black

let fill_to_json (f : Element.fill) : Yojson.Safe.t =
  `Assoc [
    "color", color_to_json f.fill_color;
    "opacity", `Float f.fill_opacity;
  ]

let fill_of_json : Yojson.Safe.t -> Element.fill option = function
  | `Assoc fields ->
    let color =
      try color_of_json (List.assoc "color" fields)
      with Not_found -> Element.black
    in
    let opacity =
      match List.assoc_opt "opacity" fields with
      | Some (`Float f) -> f
      | Some (`Int i) -> float_of_int i
      | _ -> 1.0
    in
    Some { fill_color = color; fill_opacity = opacity }
  | _ -> None

let dash_pattern_to_json (dp : float list) : Yojson.Safe.t =
  `List (List.map (fun v -> `Float v) dp)

let dash_pattern_of_json : Yojson.Safe.t -> float list = function
  | `List items ->
    List.filter_map (function
      | `Float f -> Some f
      | `Int i -> Some (float_of_int i)
      | _ -> None) items
  | _ -> []

let stroke_to_json (s : Element.stroke) : Yojson.Safe.t =
  `Assoc [
    "color", color_to_json s.stroke_color;
    "width", `Float s.stroke_width;
    "linecap", `String (linecap_to_string s.stroke_linecap);
    "linejoin", `String (linejoin_to_string s.stroke_linejoin);
    "miter_limit", `Float s.stroke_miter_limit;
    "align", `String (stroke_align_to_string s.stroke_align);
    "dash_pattern", dash_pattern_to_json s.stroke_dash_pattern;
    "start_arrow", `String (Element.string_of_arrowhead s.stroke_start_arrow);
    "end_arrow", `String (Element.string_of_arrowhead s.stroke_end_arrow);
    "start_arrow_scale", `Float s.stroke_start_arrow_scale;
    "end_arrow_scale", `Float s.stroke_end_arrow_scale;
    "arrow_align", `String (arrow_align_to_string s.stroke_arrow_align);
    "opacity", `Float s.stroke_opacity;
  ]

let stroke_of_json : Yojson.Safe.t -> Element.stroke option = function
  | `Assoc fields ->
    let get k = List.assoc_opt k fields in
    let float_of k default =
      match get k with
      | Some (`Float f) -> f
      | Some (`Int i) -> float_of_int i
      | _ -> default
    in
    let string_of k default =
      match get k with
      | Some (`String s) -> s
      | _ -> default
    in
    let color =
      match get "color" with
      | Some j -> color_of_json j
      | None -> Element.black
    in
    Some Element.{
      stroke_color = color;
      stroke_width = float_of "width" 1.0;
      stroke_linecap = linecap_of_string (string_of "linecap" "butt");
      stroke_linejoin = linejoin_of_string (string_of "linejoin" "miter");
      stroke_miter_limit = float_of "miter_limit" 4.0;
      stroke_align = stroke_align_of_string (string_of "align" "center");
      stroke_dash_pattern =
        (match get "dash_pattern" with
         | Some j -> dash_pattern_of_json j
         | None -> []);
      stroke_dash_align_anchors = false;
      stroke_start_arrow =
        Element.arrowhead_of_string (string_of "start_arrow" "none");
      stroke_end_arrow =
        Element.arrowhead_of_string (string_of "end_arrow" "none");
      stroke_start_arrow_scale = float_of "start_arrow_scale" 1.0;
      stroke_end_arrow_scale = float_of "end_arrow_scale" 1.0;
      stroke_arrow_align =
        arrow_align_of_string (string_of "arrow_align" "tip_at_end");
      stroke_opacity = float_of "opacity" 1.0;
    }
  | _ -> None

let width_point_to_json (wp : Element.stroke_width_point) : Yojson.Safe.t =
  `Assoc [
    "t", `Float wp.swp_t;
    "width_left", `Float wp.swp_width_left;
    "width_right", `Float wp.swp_width_right;
  ]

let width_point_of_json : Yojson.Safe.t -> Element.stroke_width_point option =
  function
  | `Assoc fields ->
    let float_of k =
      match List.assoc_opt k fields with
      | Some (`Float f) -> Some f
      | Some (`Int i) -> Some (float_of_int i)
      | _ -> None
    in
    (match float_of "t", float_of "width_left", float_of "width_right" with
     | Some t, Some l, Some r ->
       Some { swp_t = t; swp_width_left = l; swp_width_right = r }
     | _ -> None)
  | _ -> None

let appearance_to_json (a : appearance) : Yojson.Safe.t =
  let fields = ref [] in
  let push k v = fields := (k, v) :: !fields in
  (match a.app_fill with Some f -> push "fill" (fill_to_json f) | None -> ());
  (match a.app_stroke with Some s -> push "stroke" (stroke_to_json s) | None -> ());
  (match a.app_opacity with Some op -> push "opacity" (`Float op) | None -> ());
  (match a.app_blend_mode with
   | Some bm -> push "blend_mode" (`String (Element.blend_mode_to_string bm))
   | None -> ());
  (match a.app_stroke_brush with
   | Some sb -> push "stroke_brush" (`String sb)
   | None -> ());
  if a.app_width_points <> [] then
    push "width_points"
      (`List (List.map width_point_to_json a.app_width_points));
  (match a.app_character with Some c -> push "character" c | None -> ());
  (match a.app_paragraph with Some p -> push "paragraph" p | None -> ());
  `Assoc (List.rev !fields)

let appearance_of_json : Yojson.Safe.t -> appearance = function
  | `Assoc fields ->
    let get k = List.assoc_opt k fields in
    let fill =
      match get "fill" with Some j -> fill_of_json j | None -> None
    in
    let stroke =
      match get "stroke" with Some j -> stroke_of_json j | None -> None
    in
    let opacity =
      match get "opacity" with
      | Some (`Float f) -> Some f
      | Some (`Int i) -> Some (float_of_int i)
      | _ -> None
    in
    let blend_mode =
      match get "blend_mode" with
      | Some (`String s) -> Element.blend_mode_of_string s
      | _ -> None
    in
    let stroke_brush =
      match get "stroke_brush" with
      | Some (`String s) -> Some s
      | _ -> None
    in
    let width_points =
      match get "width_points" with
      | Some (`List items) -> List.filter_map width_point_of_json items
      | _ -> []
    in
    let character = get "character" in
    let paragraph = get "paragraph" in
    {
      app_fill = fill;
      app_stroke = stroke;
      app_opacity = opacity;
      app_blend_mode = blend_mode;
      app_stroke_brush = stroke_brush;
      app_width_points = width_points;
      app_character = character;
      app_paragraph = paragraph;
    }
  | _ -> empty_appearance
