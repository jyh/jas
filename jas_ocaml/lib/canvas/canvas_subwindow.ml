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

(* ── Brush library registry ──────────────────────────────────
   The Path renderer needs brush parameters keyed by the
   <library>/<brush> slug carried on Path.stroke_brush. Threading
   brush_libraries through every drawing helper would be invasive,
   so a module-local mutable ref serves as the registry — same
   pragmatic pattern Swift's CanvasSubwindow uses. App startup
   calls set_brush_libraries with the loaded workspace data. *)

let _brush_libraries : Yojson.Safe.t ref = ref `Null

let set_brush_libraries (libs : Yojson.Safe.t) : unit =
  _brush_libraries := libs

(* Wire the standalone Brush_registry as the source of truth.
   yaml_tool_effects.brush.* effects update Brush_registry; the
   canvas registry mirrors. App startup also calls
   set_brush_libraries directly with the loaded workspace data;
   that flows through Brush_registry too via the symmetry below. *)
let () = Brush_registry.on_change (fun libs -> _brush_libraries := libs)

(* ── Reference resolver registry (REFERENCE_GRAPH.md Phase 1b/4b) ──
   The live render arm resolves by-id references through an
   [element_resolver]. Threading a resolver through every drawing
   helper signature would be invasive, so — like the brush registry
   above — a module-local mutable ref holds the resolver for the
   duration of one paint. As of Phase 4b the draw callback installs a
   resolver over the Model's PERSISTENT id->element index (carried with
   the document, rebuilt only at the mutation chokepoint) instead of
   rebuilding the index from the document each frame; the cycle-guard set
   stays a fresh local per top-level evaluate. *)

let _ref_resolver : Live.element_resolver ref = ref Live.null_resolver

(* Extract an element's fill, used so a reference can inherit the
   resolved target's fill when its own is None (REFERENCE_GRAPH.md
   Fork F3). None for kinds with no fill (Line / Group / Layer). *)
let _element_fill (elem : Element.element) : Element.fill option =
  match elem with
  | Rect { fill; _ } | Circle { fill; _ } | Ellipse { fill; _ }
  | Polyline { fill; _ } | Polygon { fill; _ } | Path { fill; _ }
  | Text { fill; _ } | Text_path { fill; _ } -> fill
  | Live (Compound_shape cs) -> cs.fill
  | Live (Reference r) -> r.ref_fill
  | Live (Recorded rec_) -> rec_.rec_fill
  | Live (Generated gen) -> gen.gen_fill
  | Line _ | Group _ | Layer _ -> None

(* Extract an element's stroke; companion to [_element_fill]. *)
let _element_stroke (elem : Element.element) : Element.stroke option =
  match elem with
  | Rect { stroke; _ } | Circle { stroke; _ } | Ellipse { stroke; _ }
  | Line { stroke; _ } | Polyline { stroke; _ } | Polygon { stroke; _ }
  | Path { stroke; _ } | Text { stroke; _ } | Text_path { stroke; _ } -> stroke
  | Live (Compound_shape cs) -> cs.stroke
  | Live (Reference r) -> r.ref_stroke
  | Live (Recorded rec_) -> rec_.rec_stroke
  | Live (Generated gen) -> gen.gen_stroke
  | Group _ | Layer _ -> None

(* Look up a brush by "<library>/<brush>" slug. Returns None for
   missing slug, malformed input, or unknown library/brush. *)
let lookup_brush (slug : string) : Yojson.Safe.t option =
  match String.index_opt slug '/' with
  | None -> None
  | Some sep ->
    let lib_id = String.sub slug 0 sep in
    let brush_slug = String.sub slug (sep + 1) (String.length slug - sep - 1) in
    (match !_brush_libraries with
     | `Assoc libs ->
       (match List.assoc_opt lib_id libs with
        | Some (`Assoc lib_fields) ->
          (match List.assoc_opt "brushes" lib_fields with
           | Some (`List brushes) ->
             List.find_opt (fun b ->
               match b with
               | `Assoc fields ->
                 (match List.assoc_opt "slug" fields with
                  | Some (`String s) -> s = brush_slug
                  | _ -> false)
               | _ -> false
             ) brushes
           | _ -> None)
        | _ -> None)
     | _ -> None)

(* Extract Calligraphic brush params from JSON. Non-Calligraphic
   types return None (Phase 1 "Calligraphic only" scope). *)
let calligraphic_from_json (brush : Yojson.Safe.t) : Calligraphic_outline.t option =
  match brush with
  | `Assoc fields ->
    (match List.assoc_opt "type" fields with
     | Some (`String "calligraphic") ->
       let get_num key default =
         match List.assoc_opt key fields with
         | Some (`Int n) -> float_of_int n
         | Some (`Float f) -> f
         | _ -> default
       in
       Some Calligraphic_outline.{
         angle = get_num "angle" 0.0;
         roundness = get_num "roundness" 100.0;
         size = get_num "size" 5.0;
       }
     | _ -> None)
  | _ -> None

(* Extract Art brush params (inline polygon artwork) from JSON. Non-Art
   types return None. *)
let art_from_json (brush : Yojson.Safe.t) (stroke_weight : float) :
    Art_along_path.t option =
  let numv = function `Int n -> float_of_int n | `Float f -> f | _ -> 0.0 in
  match brush with
  | `Assoc fields ->
    (match List.assoc_opt "type" fields with
     | Some (`String "art") ->
       (match List.assoc_opt "artwork" fields with
        | Some (`Assoc aw) ->
          let num_of key default =
            match List.assoc_opt key aw with Some v -> numv v | None -> default
          in
          let artwork =
            match List.assoc_opt "polygons" aw with
            | Some (`List polys) ->
              List.map
                (function
                  | `List pts ->
                    List.filter_map
                      (function
                        | `List (x :: y :: _) -> Some (numv x, numv y)
                        | _ -> None)
                      pts
                  | _ -> [])
                polys
            | _ -> []
          in
          let field_num key default =
            match List.assoc_opt key fields with Some v -> numv v | None -> default
          in
          let field_bool key =
            match List.assoc_opt key fields with Some (`Bool b) -> b | _ -> false
          in
          Some
            Art_along_path.{
              artwork_width = num_of "width" 0.0;
              artwork_height = num_of "height" 0.0;
              artwork;
              scale = field_num "scale" 100.0;
              flip_across = field_bool "flip_across";
              flip_along = field_bool "flip_along";
              stroke_weight;
            }
        | _ -> None)
     | _ -> None)
  | _ -> None

(* Fill a polygon (list of points) on [cr]. *)
let fill_polygon cr = function
  | (x0, y0) :: rest ->
    Cairo.move_to cr x0 y0;
    List.iter (fun (x, y) -> Cairo.line_to cr x y) rest;
    Cairo.Path.close cr;
    Cairo.fill cr
  | [] -> ()

(* Render a brushed Path: Calligraphic -> variable-width outline polygon;
   Art -> artwork warped along the path. Fills with the stroke colour.
   Returns true if handled; false to fall back to plain stroke (missing
   brush, or a brush type without a renderer). *)
let draw_brushed_path cr (d : Element.path_command list)
    (stroke : Element.stroke option)
    (slug : string) : bool =
  match lookup_brush slug with
  | None -> false
  | Some brush ->
    let (r, g, b, a) = match stroke with
      | Some s -> Element.color_to_rgba s.stroke_color
      | None -> (0.0, 0.0, 0.0, 1.0)
    in
    let stroke_weight = match stroke with Some s -> s.stroke_width | None -> 1.0 in
    (match calligraphic_from_json brush with
     | Some cal ->
       let pts = Calligraphic_outline.outline d cal in
       if List.length pts < 3 then true
       else begin
         Cairo.set_source_rgba cr r g b a;
         fill_polygon cr pts;
         true
       end
     | None ->
       (match art_from_json brush stroke_weight with
        | Some art ->
          let polys = Art_along_path.warp d art in
          Cairo.set_source_rgba cr r g b a;
          List.iter
            (fun poly -> if List.length poly >= 3 then fill_polygon cr poly)
            polys;
          true
        | None -> false))

let title_bar_height = 24

(** Parse a CSS length in ``pt``; empty / unparseable -> [None].
    Mirrors Rust's ``parse_pt`` and Python's ``_parse_pt``. *)
let _parse_pt (s : string) : float option =
  if s = "" then None
  else
    let s = String.trim s in
    let s = if String.length s >= 2
            && String.sub s (String.length s - 2) 2 = "pt"
            then String.sub s 0 (String.length s - 2) else s in
    try Some (float_of_string s) with Failure _ -> None

(** Parse a percent scale string (e.g. ``"120"``). Empty / unparseable
    → ``1.0``. *)
let _parse_scale_percent (s : string) : float =
  if s = "" then 1.0
  else try float_of_string s /. 100.0 with Failure _ -> 1.0

(** Parse a rotation string in degrees. Empty / unparseable → ``0``. *)
let _parse_rotate_deg (s : string) : float =
  if s = "" then 0.0
  else try float_of_string s with Failure _ -> 0.0

(** Parse a CSS length in ``em``. Empty / unparseable -> [None]. Used
    for letter_spacing / kerning, which are both expressed in em. *)
let _parse_em (s : string) : float option =
  if s = "" then None
  else
    let s = String.trim s in
    let s = if String.length s >= 2
            && String.sub s (String.length s - 2) 2 = "em"
            then String.sub s 0 (String.length s - 2) else s in
    try Some (float_of_string s) with Failure _ -> None

(** Combined letter-spacing in pixels: tracking + numeric kerning, both
    in em, accumulate into one uniform inter-glyph advance. Named
    kerning modes (``Auto`` / ``Optical`` / ``Metrics``) parse as zero,
    matching Rust / Swift / Python.  *)
let _letter_spacing_px (letter_spacing : string) (kerning : string)
                       (font_size : float) : float =
  let ls = match _parse_em letter_spacing with Some v -> v | None -> 0.0 in
  let k  = match _parse_em kerning        with Some v -> v | None -> 0.0 in
  (ls +. k) *. font_size

(** Parse ``baseline_shift`` → ``(size_scale, y_shift)``. See the
    Python helper for the semantics. *)
let _parse_baseline_shift (s : string) (font_size : float) : float * float =
  if s = "super" then (0.7, -. font_size *. 0.35)
  else if s = "sub" then (0.7, font_size *. 0.2)
  else match _parse_pt s with
    | Some pt -> (1.0, -. pt)
    | None -> (1.0, 0.0)

(** Apply ``text_transform`` and ``font_variant`` to the content
    string. small-caps is rendered as uppercase for now (placeholder
    until an OpenType shaper lands — Rust uses the same shortcut). *)
let _apply_text_transform (tt : string) (fv : string) (content : string)
  : string =
  if tt = "uppercase" || fv = "small-caps" then String.uppercase_ascii content
  else if tt = "lowercase" then String.lowercase_ascii content
  else content

(** Draw a Text element's tspans in sequence on a shared baseline,
    each using its effective font (override || parent fallback) and
    effective text-decoration. Mirrors Rust's [draw_segmented_text]
    and Swift's [drawSegmentedText]. Covers TSPAN.md's rendering
    "minimum subset": font + decoration per tspan on one line. Omits
    per-tspan baseline-shift / transform / rotate / dx and multi-line
    wrapping — those collapse to element defaults for now. *)
let _draw_segmented_text cr ~x ~y ~fontsize ~fontfamily ~fontweight
    ~fontstyle ~textdecoration (tspans : Element.tspan array) : unit =
  let parent_bold = fontweight = "bold" in
  let parent_italic = fontstyle = "italic" || fontstyle = "oblique" in
  let parent_decor_tokens =
    String.split_on_char ' ' textdecoration
    |> List.filter (fun t -> t <> "" && t <> "none")
  in
  (* Baseline sits at the first visual line: element y + 0.8 *
     font_size. Segmented rendering is one-line only for now. *)
  let baseline = y +. fontsize *. 0.8 in
  let cx = ref x in
  Array.iter (fun (t : Element.tspan) ->
    (* Same UTF-8 guard as the flat-text path — sanitize the tspan
       content before any Cairo text call. *)
    let t_content =
      if String.is_valid_utf_8 t.content then t.content
      else begin
        let b = Buffer.create (String.length t.content) in
        String.iter (fun c ->
          if Char.code c < 0x80 then Buffer.add_char b c
        ) t.content;
        Buffer.contents b
      end in
    let t = { t with Element.content = t_content } in
    if t.content = "" then () else begin
      let eff_family = match t.font_family with
        | Some f -> f | None -> fontfamily in
      let eff_size = match t.font_size with
        | Some n -> n | None -> fontsize in
      let eff_bold = match t.font_weight with
        | Some w -> w = "bold" | None -> parent_bold in
      let eff_italic = match t.font_style with
        | Some s -> s = "italic" || s = "oblique" | None -> parent_italic in
      let slant = if eff_italic then Cairo.Italic else Cairo.Upright in
      let weight = if eff_bold then Cairo.Bold else Cairo.Normal in
      Cairo.select_font_face cr eff_family ~slant ~weight;
      Cairo.set_font_size cr eff_size;
      (* Per-tspan positioning:
         - dx (em): horizontal leading-edge nudge, scaled by eff_size.
         - baseline_shift (pt, + is up): subtracted from the shared
           baseline (Cairo y grows downward, same as the app convention).
         - rotate (deg) / transform (SVG matrix): wrap the tspan draw
           around its starting baseline point.  *)
      let dx_px = match t.dx with Some d -> d *. eff_size | None -> 0.0 in
      cx := !cx +. dx_px;
      let b_shift = match t.baseline_shift with Some s -> s | None -> 0.0 in
      let tspan_baseline = baseline -. b_shift in
      let rot_rad = match t.rotate with
        | Some d -> d *. Float.pi /. 180.0 | None -> 0.0 in
      let has_rotate = rot_rad <> 0.0 in
      let has_transform = match t.transform with Some _ -> true | None -> false in
      let w = (Cairo.text_extents cr t.content).Cairo.x_advance in
      (* Effective decoration: [Some []] overrides to no decoration;
         [None] inherits parent tokens. *)
      let has_u, has_s = match t.text_decoration with
        | Some members ->
          (List.mem "underline" members, List.mem "line-through" members)
        | None ->
          (List.mem "underline" parent_decor_tokens,
           List.mem "line-through" parent_decor_tokens)
      in
      let draw_body origin_x origin_baseline =
        Cairo.move_to cr origin_x origin_baseline;
        Cairo.show_text cr t.content;
        if has_u || has_s then begin
          let thickness = Float.max 1.0 (eff_size *. 0.07) in
          Cairo.save cr;
          Cairo.set_line_width cr thickness;
          if has_u then begin
            let ly = origin_baseline +. eff_size *. 0.12 in
            Cairo.move_to cr origin_x ly;
            Cairo.line_to cr (origin_x +. w) ly;
            Cairo.stroke cr
          end;
          if has_s then begin
            let ly = origin_baseline -. eff_size *. 0.3 in
            Cairo.move_to cr origin_x ly;
            Cairo.line_to cr (origin_x +. w) ly;
            Cairo.stroke cr
          end;
          Cairo.restore cr
        end
      in
      if has_rotate || has_transform then begin
        Cairo.save cr;
        Cairo.translate cr !cx tspan_baseline;
        (match t.transform with
         | Some tr ->
           let m = { Cairo.xx = tr.Element.a; yx = tr.b;
                     xy = tr.c; yy = tr.d;
                     x0 = tr.e; y0 = tr.f } in
           Cairo.transform cr m
         | None -> ());
        if has_rotate then Cairo.rotate cr rot_rad;
        draw_body 0.0 0.0;
        Cairo.restore cr
      end else
        draw_body !cx tspan_baseline;
      cx := !cx +. w
    end
  ) tspans

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

(** How the mask subtree's rendered alpha is applied to the element.
    Mirrors the Rust [MaskPlan] enum in
    [jas_dioxus/src/canvas/render.rs]. OPACITY.md \167Rendering. *)
type mask_plan =
  | Clip_in             (** [clip: true, invert: false]: [Cairo.DEST_IN]  *)
  | Clip_out            (** [clip: true, invert: true]:  [Cairo.DEST_OUT];
                            also [clip: false, invert: true] which
                            collapses to the same op for alpha-based
                            masks (zero-alpha outside region gives
                            [E * (1 - 0) = E] either way)            *)
  | Reveal_outside_bbox (** [clip: false, invert: false]: element stays
                            at full alpha outside the mask subtree's
                            bounding box; [DEST_IN] is applied only
                            inside the bbox via a clipped sub-context *)

(** Per-transform geometric-mean SCALE of a 2x3 affine — [sqrt(|det|)] of
    the linear part with [det = a*.d -. b*.c]. Returns [1.0] for [None] or a
    degenerate (det 0) transform. The building block of both
    [selection_outline_scale] and the element-stroke counter-scale. Mirrors
    the Python [transform_scale_factor]. *)
let transform_scale_factor (transform : Element.transform option) : float =
  match transform with
  | None -> 1.0
  | Some (tr : Element.transform) ->
    let det = Float.abs (tr.a *. tr.d -. tr.b *. tr.c) in
    if det > 0.0 then sqrt det else 1.0

(** Counter-scale an element's own STROKE for rendering. Returns
    [(element, accumulated_scale)] where [accumulated_scale = element_scale
    *. transform_scale_factor elem_own_transform] and the returned element
    has its stroke width DIVIDED by that scale.

    The element's own transform is applied to the painter before its stroke
    is drawn, so the matrix would thicken the stroke — on top of the
    [scale_strokes] bake that already multiplied the stored width at apply
    time. Dividing the stroke width here cancels the element-transform
    scaling so the stroke renders at its nominal (still zoom-scaled) width:
    [scale_strokes] ON scales the stroke ONCE with the object, OFF leaves it
    at the stored width. Only the element-transform chain is cancelled — the
    view/zoom transform is applied separately and still scales the stroke,
    matching [selection_outline_scale]. Returns [elem] unchanged when the
    accumulated scale is effectively 1.0 (or degenerate). The accumulated
    scale is threaded to children so a stroked shape inside a transformed
    group is counter-scaled by the full ancestor chain. Mirrors the Python
    [_counter_scaled_element]. *)
let counter_scaled_element (elem : Element.element) (element_scale : float)
    : Element.element * float =
  let elem_scale =
    element_scale *. transform_scale_factor (Element.get_transform elem) in
  if elem_scale > 1e-6 && Float.abs (elem_scale -. 1.0) > 1e-9 then begin
    (* Counter-scale the stroke width (if any) ... *)
    let elem = match _element_stroke elem with
      | Some (s : Element.stroke) ->
        Element.with_stroke elem
          (Some { s with stroke_width = s.stroke_width /. elem_scale })
      | None -> elem in
    (* ... and a rounded rect corner radii, so the corner stays a fixed size
       under a scale (scale_corners OFF default). When it was ON the apply
       baked rx,ry *= factor, so the net rendered radius scales once. *)
    let elem = match elem with
      | Element.Rect r when r.rx <> 0.0 || r.ry <> 0.0 ->
        Element.Rect { r with rx = r.rx /. elem_scale; ry = r.ry /. elem_scale }
      | _ -> elem in
    (elem, elem_scale)
  end
  else (elem, elem_scale)

(** Render a document element. When the element carries an active
    mask, rendering is redirected through [draw_element_with_mask]
    which composites the element body against the mask's subtree
    according to [mask_plan]. OPACITY.md \167Rendering. *)
let rec draw_element ?(ancestor_vis = Element.Preview) ?(element_scale = 1.0)
    cr (elem : Element.element) =
  match Element.get_mask elem with
  | Some mask ->
    (match mask_plan mask with
     | Some plan -> draw_element_with_mask cr elem mask plan ancestor_vis
                      element_scale
     | None -> draw_element_body ~ancestor_vis ~element_scale cr elem)
  | None -> draw_element_body ~ancestor_vis ~element_scale cr elem

(** Pick a [mask_plan] for the mask, or [None] when the mask is
    inactive ([disabled: true]). *)
and mask_plan (mask : Element.mask) : mask_plan option =
  if mask.Element.disabled then None
  else match mask.Element.clip, mask.Element.invert with
    | true, false -> Some Clip_in
    | true, true -> Some Clip_out
    (* Alpha-based masks can't distinguish [clip: false,
       invert: true] from [clip: true, invert: true] (both yield
       [E * (1 - M)] when the mask's outside-region alpha is 0),
       so route them through the same composite. *)
    | false, true -> Some Clip_out
    | false, false -> Some Reveal_outside_bbox

(** Return the transform that should be applied when rendering the
    mask's subtree on top of the ancestor coord system. Track C
    phase 3, OPACITY.md \167Document model:

    - [linked: true]  — mask inherits [Element.get_transform elem]
      (mask follows the element).
    - [linked: false] — mask uses [mask.unlink_transform] (the
      element's transform captured at unlink time, frozen so the
      mask stays fixed under subsequent element edits).

    Returns [None] when the picked transform is absent (identity
    case) so the caller can skip the [apply_transform] call. *)
and effective_mask_transform (mask : Element.mask) (elem : Element.element)
    : Element.transform option =
  if mask.Element.linked then Element.get_transform elem
  else mask.Element.unlink_transform

(** Render [elem] on [cr] with its opacity mask composited in per
    [plan]. The element body is drawn into a fresh Cairo group; the
    mask subtree is then painted on top of the group; the group is
    popped back onto the parent context.  OPACITY.md \167Rendering. *)
and draw_element_with_mask cr (elem : Element.element)
    (mask : Element.mask) (plan : mask_plan) ancestor_vis element_scale =
  Cairo.Group.push cr;
  draw_element_body ~ancestor_vis ~element_scale cr elem;
  (* Apply the mask's effective transform (per
     [effective_mask_transform]), then composite the mask subtree
     against the element body. Track C phase 3. *)
  Cairo.save cr;
  apply_transform cr (effective_mask_transform mask elem);
  (match plan with
   | Clip_in ->
     Cairo.set_operator cr Cairo.DEST_IN;
     draw_element ~ancestor_vis cr mask.Element.subtree;
     Cairo.set_operator cr Cairo.OVER
   | Clip_out ->
     Cairo.set_operator cr Cairo.DEST_OUT;
     draw_element ~ancestor_vis cr mask.Element.subtree;
     Cairo.set_operator cr Cairo.OVER
   | Reveal_outside_bbox ->
     (* [clip: false, invert: false]: keep the element body at full
        alpha outside the mask subtree's bounding box; apply
        [DEST_IN] only inside the bbox via a clipped sub-context.
        Outside the clip, the body from the first pass passes through
        untouched.  OPACITY.md \167Rendering. *)
     let (bx, by, bw, bh) = Element.bounds mask.Element.subtree in
     if bw > 0.0 && bh > 0.0 then begin
       Cairo.save cr;
       Cairo.rectangle cr bx by ~w:bw ~h:bh;
       Cairo.clip cr;
       Cairo.set_operator cr Cairo.DEST_IN;
       draw_element ~ancestor_vis cr mask.Element.subtree;
       Cairo.set_operator cr Cairo.OVER;
       Cairo.restore cr
     end
     (* Empty-bbox mask: body passes through unmodified. *)
  );
  Cairo.restore cr;
  Cairo.Group.pop_to_source cr;
  Cairo.paint cr

and draw_element_body ?(ancestor_vis = Element.Preview) ?(element_scale = 1.0)
    cr (elem : Element.element) =
  let open Element in
  let elem_vis = Element.get_visibility elem in
  let effective = if compare elem_vis ancestor_vis < 0 then elem_vis else ancestor_vis in
  if effective = Element.Invisible then ()
  else
  let outline = effective = Element.Outline in
  Cairo.save cr;
  (* Phase-1: element.blend_mode is stored on every element and round-trips
     through test_json, but the OCaml cairo2 binding only exposes the basic
     Porter-Duff operators (OVER, IN, OUT, etc.) — not the CSS/SVG blend
     operators MULTIPLY / DARKEN / HSL_HUE etc. that the underlying Cairo C
     library supports. Until the binding is upgraded (or a raw-cairo wrapper
     is added), all blend_mode values render as source-over. *)
  let _ = Element.get_blend_mode elem in
  (* Counter-scale the element's own stroke so the element transform (applied
     to [cr] per-shape below) does NOT thicken it — it renders at the nominal,
     zoom-scaled width, cancelling the matrix stroke scaling and the
     [scale_strokes] double-scale. [elem_scale] is threaded to children. *)
  let (elem, elem_scale) = counter_scaled_element elem element_scale in
  begin match elem with
  | Line { x1; y1; x2; y2; stroke; width_points; opacity; transform; _ } ->
    Cairo.Group.push cr;
    apply_transform cr transform;
    let stroke_align = ref Element.Center in
    if outline then apply_outline_style cr
    else begin
      let (_, al) = apply_stroke cr stroke in
      stroke_align := al
    end;
    (* Shorten line for arrowheads *)
    let lx1 = ref x1 and ly1 = ref y1 and lx2 = ref x2 and ly2 = ref y2 in
    if not outline then begin
      match stroke with
      | Some s ->
        let dx = !lx2 -. !lx1 in
        let dy = !ly2 -. !ly1 in
        let len = sqrt (dx *. dx +. dy *. dy) in
        if len > 0.0 then begin
          let ux = dx /. len and uy = dy /. len in
          let start_sb = Arrowheads.arrow_setback
            (Element.string_of_arrowhead s.stroke_start_arrow)
            s.stroke_width s.stroke_start_arrow_scale in
          let end_sb = Arrowheads.arrow_setback
            (Element.string_of_arrowhead s.stroke_end_arrow)
            s.stroke_width s.stroke_end_arrow_scale in
          lx1 := !lx1 +. ux *. start_sb;
          ly1 := !ly1 +. uy *. start_sb;
          lx2 := !lx2 -. ux *. end_sb;
          ly2 := !ly2 -. uy *. end_sb
        end
      | None -> ()
    end;
    if not outline && width_points <> [] then begin
      match stroke with
      | Some s ->
        let sc = Element.color_to_rgba s.stroke_color in
        Offset_path.render_variable_width_line cr !lx1 !ly1 !lx2 !ly2
          width_points sc s.stroke_linecap
      | None -> ()
    end else begin
      Cairo.move_to cr !lx1 !ly1;
      Cairo.line_to cr !lx2 !ly2;
      if outline then Cairo.stroke cr
      else stroke_aligned cr !stroke_align
    end;
    (* Arrowheads *)
    if not outline then begin
      match stroke with
      | Some s ->
        let center = s.stroke_arrow_align = Element.Center_at_end in
        let sc = Element.color_to_rgba s.stroke_color in
        Arrowheads.draw_arrowheads_line cr x1 y1 x2 y2
          (Element.string_of_arrowhead s.stroke_start_arrow)
          (Element.string_of_arrowhead s.stroke_end_arrow)
          s.stroke_start_arrow_scale s.stroke_end_arrow_scale
          s.stroke_width sc center
      | None -> ()
    end;
    Cairo.Group.pop_to_source cr;
    Cairo.paint cr ~alpha:opacity

  | Rect { x; y; width; height; rx; ry; fill; stroke; opacity; transform; fill_gradient; stroke_gradient; _ } ->
    Cairo.Group.push cr;
    apply_transform cr transform;
    let dasher_stroke = match stroke with
      | Some s when s.stroke_dash_align_anchors
                    && s.stroke_dash_pattern <> []
                    && rx = 0.0 && ry = 0.0
                    && fill_gradient = None
                    && stroke_gradient = None
                    && not outline -> Some s
      | _ -> None
    in
    (match dasher_stroke with
     | Some s ->
      (* Anchor-aligned dashing for non-rounded rect: fill (if any)
         with the rect path, then expand the stroke into solid
         sub-paths via Dash_renderer and stroke each. apply_stroke
         already cleared the platform Cairo dash. *)
      (match fill with
       | Some f ->
         let (r, g, b, a) = Element.color_to_rgba f.fill_color in
         Cairo.set_source_rgba cr r g b a;
         Cairo.rectangle cr x y ~w:width ~h:height;
         Cairo.fill cr
       | None -> ());
      let cmds = [
        MoveTo (x, y);
        LineTo (x +. width, y);
        LineTo (x +. width, y +. height);
        LineTo (x, y +. height);
        ClosePath;
      ] in
      let (_, align) = apply_stroke cr (Some s) in
      let expanded = Dash_renderer.expand_dashed_stroke
        cmds s.stroke_dash_pattern true in
      List.iter (fun sub ->
        build_path cr sub;
        stroke_aligned cr align
      ) expanded
     | None ->
      if rx > 0.0 || ry > 0.0 then
        rounded_rect cr x y width height rx ry
      else
        Cairo.rectangle cr x y ~w:width ~h:height;
      if outline then begin
        apply_outline_style cr;
        Cairo.stroke cr
      end else
        fill_stroke_gradient_full cr fill stroke fill_gradient stroke_gradient (x, y, width, height));
    Cairo.Group.pop_to_source cr;
    Cairo.paint cr ~alpha:opacity

  | Circle { cx; cy; r; fill; stroke; opacity; transform; fill_gradient; stroke_gradient; _ } ->
    Cairo.Group.push cr;
    apply_transform cr transform;
    Cairo.arc cr cx cy ~r ~a1:0.0 ~a2:(2.0 *. Float.pi);
    if outline then begin
      apply_outline_style cr;
      Cairo.stroke cr
    end else
      fill_stroke_gradient_full cr fill stroke fill_gradient stroke_gradient
        (cx -. r, cy -. r, r *. 2.0, r *. 2.0);
    Cairo.Group.pop_to_source cr;
    Cairo.paint cr ~alpha:opacity

  | Ellipse { cx; cy; rx; ry; fill; stroke; opacity; transform; fill_gradient; stroke_gradient; _ } ->
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
    end else
      fill_stroke_gradient_full cr fill stroke fill_gradient stroke_gradient
        (cx -. rx, cy -. ry, rx *. 2.0, ry *. 2.0);
    Cairo.Group.pop_to_source cr;
    Cairo.paint cr ~alpha:opacity

  | Polyline { points; fill; stroke; opacity; transform; fill_gradient; stroke_gradient; _ } ->
    Cairo.Group.push cr;
    apply_transform cr transform;
    draw_points cr points false;
    if outline then begin
      apply_outline_style cr;
      Cairo.stroke cr
    end else
      fill_stroke_gradient_full cr fill stroke fill_gradient stroke_gradient (poly_bbox points);
    Cairo.Group.pop_to_source cr;
    Cairo.paint cr ~alpha:opacity

  | Polygon { points; fill; stroke; opacity; transform; fill_gradient; stroke_gradient; _ } ->
    Cairo.Group.push cr;
    apply_transform cr transform;
    draw_points cr points true;
    if outline then begin
      apply_outline_style cr;
      Cairo.stroke cr
    end else
      fill_stroke_gradient_full cr fill stroke fill_gradient stroke_gradient (poly_bbox points);
    Cairo.Group.pop_to_source cr;
    Cairo.paint cr ~alpha:opacity

  | Path { d; fill; stroke; width_points; opacity; transform; stroke_brush; _ } ->
    Cairo.Group.push cr;
    apply_transform cr transform;
    if outline then begin
      build_path cr d;
      apply_outline_style cr;
      Cairo.stroke cr
    end
    (* Brushed render — when stroke_brush resolves to a known
       Calligraphic brush, fill the variable-width outline as a
       polygon using the path's stroke colour. Skips the native
       stroke + arrowhead pipeline below. See BRUSHES.md
       Stroke styling interaction. *)
    else if (match stroke_brush with Some _ -> true | None -> false)
         && draw_brushed_path cr d stroke
              (match stroke_brush with Some s -> s | None -> "")
    then begin
      (* Fill first if present — the brush owns only the stroke
         appearance, not any fill paint. *)
      (match fill with
       | Some f ->
         let (r, g, b, a) = Element.color_to_rgba f.fill_color in
         Cairo.set_source_rgba cr r g b a;
         build_path cr d;
         Cairo.fill cr
       | None -> ())
    end
    else begin
      (* Shorten path for arrowheads *)
      let stroke_cmds = match stroke with
        | Some s ->
          let start_sb = Arrowheads.arrow_setback
            (Element.string_of_arrowhead s.stroke_start_arrow)
            s.stroke_width s.stroke_start_arrow_scale in
          let end_sb = Arrowheads.arrow_setback
            (Element.string_of_arrowhead s.stroke_end_arrow)
            s.stroke_width s.stroke_end_arrow_scale in
          if start_sb > 0.0 || end_sb > 0.0 then
            Arrowheads.shorten_path d start_sb end_sb
          else d
        | None -> d
      in
      if width_points <> [] then begin
        match stroke with
        | Some s ->
          (* Fill first if present *)
          (match fill with
           | Some f ->
             let (r, g, b, a) = Element.color_to_rgba f.fill_color in
             Cairo.set_source_rgba cr r g b a;
             build_path cr d;
             Cairo.fill cr
           | None -> ());
          (* Variable-width stroke *)
          let sc = Element.color_to_rgba s.stroke_color in
          Offset_path.render_variable_width_path cr stroke_cmds width_points
            sc s.stroke_linecap
        | None ->
          build_path cr d;
          fill_and_stroke cr fill stroke
      end else begin
        match stroke with
        | Some s when s.stroke_dash_align_anchors
                      && s.stroke_dash_pattern <> [] ->
          (* Anchor-aligned dashing: fill (if any) with the original
             path, then expand the stroke into solid sub-paths via
             Dash_renderer and stroke each. set_stroke already
             cleared the platform dash. *)
          (match fill with
           | Some f ->
             let (r, g, b, a) = Element.color_to_rgba f.fill_color in
             Cairo.set_source_rgba cr r g b a;
             build_path cr d;
             Cairo.fill cr
           | None -> ());
          let (_, align) = apply_stroke cr (Some s) in
          let expanded = Dash_renderer.expand_dashed_stroke
            stroke_cmds s.stroke_dash_pattern true in
          List.iter (fun sub ->
            build_path cr sub;
            stroke_aligned cr align
          ) expanded
        | _ ->
          build_path cr stroke_cmds;
          fill_and_stroke cr fill stroke
      end;
      (* Arrowheads *)
      (match stroke with
       | Some s ->
         let center = s.stroke_arrow_align = Element.Center_at_end in
         let sc = Element.color_to_rgba s.stroke_color in
         Arrowheads.draw_arrowheads cr d
           (Element.string_of_arrowhead s.stroke_start_arrow)
           (Element.string_of_arrowhead s.stroke_end_arrow)
           s.stroke_start_arrow_scale s.stroke_end_arrow_scale
           s.stroke_width sc center
       | None -> ())
    end;
    Cairo.Group.pop_to_source cr;
    Cairo.paint cr ~alpha:opacity

  | Text { x; y; content; font_family; font_size;
           font_weight; font_style; text_width; text_height;
           fill; opacity; transform;
           text_transform; font_variant; baseline_shift; line_height;
           text_decoration; rotate; horizontal_scale; vertical_scale;
           letter_spacing; kerning; tspans;
           _ } ->
    (* Defensive UTF-8 guard: Cairo's text_extents / show_text raise
       Cairo.Error(INVALID_STRING) on non-UTF-8 input, which aborts
       the whole canvas draw and bricks the app. Sanitize element
       content here so a stray bad byte (e.g. from clipboard paste)
       degrades gracefully — invalid bytes are dropped, ASCII kept. *)
    let content =
      if String.is_valid_utf_8 content then content
      else begin
        let b = Buffer.create (String.length content) in
        String.iter (fun c ->
          if Char.code c < 0x80 then Buffer.add_char b c
        ) content;
        Buffer.contents b
      end in
    Cairo.Group.push cr;
    apply_transform cr transform;
    begin match fill with
    | Some { fill_color = c; _ } ->
      let (r, g, b, a) = Element.color_to_rgba c in
      Cairo.set_source_rgba cr r g b a
    | None -> Cairo.set_source_rgb cr 0.0 0.0 0.0
    end;
    (* Multi-tspan Text renders each tspan with its own effective
       font + decoration on a shared baseline. Single no-override
       tspan falls through to the flat path below. First pass covers
       font + decoration per tspan; per-tspan baseline-shift / rotate
       / transform / dx and wrapping are follow-ups. *)
    (* Empty paragraph wrappers are transparent for the fast path —
       their character-level fields are ignored at render time, only
       [build_segments_from_text] consumes them. Without this, the
       moment the Paragraph panel inserts an empty wrapper before
       existing flat content the renderer flips to the segmented
       (single-line) path and the paragraph collapses visually. *)
    let is_flat = Tspan.render_is_flat tspans in
    if not is_flat then begin
      _draw_segmented_text cr ~x ~y ~fontsize:font_size
        ~fontfamily:font_family ~fontweight:font_weight
        ~fontstyle:font_style ~textdecoration:text_decoration
        tspans;
      Cairo.Group.pop_to_source cr;
      Cairo.paint cr ~alpha:opacity
    end else begin
    (* Baseline-shift: "super"/"sub" shrink + offset; numeric "Npt"
       shifts up by N points with full size. Mirrors Rust /
       Python canvas. *)
    let (size_scale, y_shift) = _parse_baseline_shift baseline_shift font_size in
    let effective_fs = font_size *. size_scale in
    let slant = if font_style = "italic" || font_style = "oblique" then Cairo.Italic else Cairo.Upright in
    let weight = if font_weight = "bold" then Cairo.Bold else Cairo.Normal in
    (* text_transform / font_variant: small-caps is rendered as
       uppercase for now (same placeholder Rust uses — real OpenType
       small-caps substitution waits on a shaper). *)
    let content = _apply_text_transform text_transform font_variant content in
    (* H/V scale wraps the whole text draw around the element origin.
       Character rotation is *per-glyph* (matches SVG's <text rotate>
       spec and Illustrator's Character Rotation field): each glyph
       rotates around its own baseline position, leaving the overall
       layout on a horizontal baseline. [show_with_spacing] picks the
       per-glyph loop when [rot_rad] is non-zero. *)
    let h_scale = _parse_scale_percent horizontal_scale in
    let v_scale = _parse_scale_percent vertical_scale in
    let rot_rad = _parse_rotate_deg rotate *. Float.pi /. 180.0 in
    let needs_scale = h_scale <> 1.0 || v_scale <> 1.0 in
    if needs_scale then begin
      Cairo.save cr;
      Cairo.translate cr x y;
      Cairo.scale cr h_scale v_scale;
      Cairo.translate cr (-. x) (-. y)
    end;
    Cairo.select_font_face cr font_family ~slant ~weight;
    Cairo.set_font_size cr effective_fs;
    let ascent = effective_fs *. 0.8 in
    (* line_height: when non-empty, overrides the layout stride.
       Empty = Auto (120% of font size, which is what text_layout
       uses when we pass [effective_fs]).

       Phase 8: when line_height is empty (Character Auto) and the
       first paragraph wrapper carries jas:auto-leading, override
       the Auto default with [auto_leading%] of the font size. V1
       applies one Auto override element-wide using the first
       wrapper's value (per-paragraph leading would need text_layout
       to take per-segment font_size). *)
    let layout_fs = match _parse_pt line_height with
      | Some lh -> lh
      | None ->
        let auto_leading = Array.fold_left (fun acc (t : Element.tspan) ->
          match acc with Some _ -> acc | None ->
            if t.jas_role = Some "paragraph" then t.jas_auto_leading
            else None
        ) None tspans in
        match auto_leading with
        | Some pct -> effective_fs *. pct /. 100.0
        | None -> effective_fs in
    (* Cairo's [show_text] does not accept a per-glyph kern attribute,
       so when letter_spacing / numeric kerning resolves to a non-zero
       advance we draw character-by-character and add [ls_px] between
       chars. Zero keeps the fast single-call path.  Layout measurement
       must include the same extra advance, otherwise area-text
       wrapping would disagree with the visible width. *)
    let ls_px = _letter_spacing_px letter_spacing kerning effective_fs in
    let segment_width seg =
      let w = (Cairo.text_extents cr seg).Cairo.x_advance in
      let n = String.length seg in
      if ls_px = 0.0 || n < 2 then w
      else w +. float_of_int (n - 1) *. ls_px
    in
    let show_with_spacing seg base_x base_y =
      if ls_px = 0.0 && rot_rad = 0.0 then begin
        Cairo.move_to cr base_x base_y;
        Cairo.show_text cr seg
      end else begin
        (* Per-char loop covers two cases: non-zero letter_spacing
           (Cairo has no single-string kern attribute) and non-zero
           rotate (each glyph rotates around its own baseline). When
           both are zero we take the fast path above. *)
        let len = String.length seg in
        let pos = ref base_x in
        for i = 0 to len - 1 do
          let ch = String.make 1 seg.[i] in
          let cw = (Cairo.text_extents cr ch).Cairo.x_advance in
          if rot_rad = 0.0 then begin
            Cairo.move_to cr !pos base_y;
            Cairo.show_text cr ch
          end else begin
            Cairo.save cr;
            Cairo.translate cr !pos base_y;
            Cairo.rotate cr rot_rad;
            Cairo.move_to cr 0.0 0.0;
            Cairo.show_text cr ch;
            Cairo.restore cr
          end;
          pos := !pos +. cw +. ls_px
        done
      end
    in
    let has_underline = List.mem "underline" (String.split_on_char ' ' text_decoration) in
    let has_strike = List.mem "line-through" (String.split_on_char ' ' text_decoration) in
    let draw_line_decorations seg base_x base_y =
      if has_underline || has_strike then begin
        let w = segment_width seg in
        let thickness = Float.max 1.0 (effective_fs *. 0.07) in
        Cairo.save cr;
        Cairo.set_line_width cr thickness;
        if has_underline then begin
          let ly = base_y +. effective_fs *. 0.12 in
          Cairo.move_to cr base_x ly;
          Cairo.line_to cr (base_x +. w) ly;
          Cairo.stroke cr
        end;
        if has_strike then begin
          let ly = base_y -. effective_fs *. 0.3 in
          Cairo.move_to cr base_x ly;
          Cairo.line_to cr (base_x +. w) ly;
          Cairo.stroke cr
        end;
        Cairo.restore cr
      end
    in
    if text_width > 0.0 && text_height > 0.0 then begin
      let measure = segment_width in
      (* Phase 5: paragraph-aware layout. The wrapper tspans
         (jas_role = "paragraph") inside the element provide the
         per-paragraph indent / space / alignment attrs; absent
         wrappers fall through to a default segment so plain text
         renders identically to the old [layout] path. *)
      let psegs = Text_layout_paragraph.build_segments_from_text
                    tspans content true in
      let lay = Text_layout.layout_with_paragraphs
                  content text_width layout_fs psegs measure in
      Array.iter (fun (line : Text_layout.line_info) ->
        (* line.start / line.end_ are codepoint (char) indices into
           [content], not byte offsets — use utf8_sub so multi-byte
           UTF-8 sequences (e.g. NYT en-dashes / smart-quotes) aren't
           split mid-codepoint, which would produce a fragment Cairo
           rejects with INVALID_STRING. *)
        let seg = Text_layout.utf8_sub content line.start
                    (line.end_ - line.start) in
        let seg = if String.length seg > 0 && seg.[String.length seg - 1] = '\n'
                  then String.sub seg 0 (String.length seg - 1) else seg in
        let base_y = y +. line.baseline_y +. y_shift in
        (* Per-line x shift comes from the first glyph's x — the
           paragraph-aware layout already shifted it by left_indent
           + first_line_indent + alignment. *)
        let line_x_shift =
          if line.glyph_start < Array.length lay.glyphs
          then lay.glyphs.(line.glyph_start).x
          else 0.0 in
        let base_x = x +. line_x_shift in
        (* When the layout stretched glue widths (justify), the
           single show_text path would render each line with the
           canvas's *natural* inter-word advance and the result would
           look left-flush. Detect that by comparing the line's last
           visible glyph's right against the natural width of the
           line text — any non-trivial gap means a glue was stretched
           and we must position words individually using the layout's
           per-glyph x. *)
        let last_visible_right = ref 0.0 in
        let first_visible_x = ref infinity in
        for gi = line.glyph_start to line.glyph_end - 1 do
          let g = lay.glyphs.(gi) in
          if not g.is_trailing_space then begin
            if g.right > !last_visible_right then last_visible_right := g.right;
            if g.x < !first_visible_x then first_visible_x := g.x
          end
        done;
        let layout_w =
          if !first_visible_x = infinity then 0.0
          else Float.max 0.0 (!last_visible_right -. !first_visible_x) in
        let natural_w = measure seg in
        let glues_stretched = layout_w > natural_w +. 0.5 in
        if rot_rad <> 0.0 then begin
          (* Per-glyph rotation path takes the existing
             show_with_spacing branch. *)
          show_with_spacing seg base_x base_y;
          draw_line_decorations seg base_x base_y
        end else if not glues_stretched then begin
          (* Fast path: single show_text per line. *)
          show_with_spacing seg base_x base_y;
          draw_line_decorations seg base_x base_y
        end else begin
          (* Justified line: render word-by-word so each word lands
             at the x the composer computed (with stretched glue
             between words). *)
          let chars_v =
            let acc = ref [] in
            Text_layout.utf8_iteri (fun _ u -> acc := u :: !acc) seg;
            Array.of_list (List.rev !acc)
          in
          let buf = Buffer.create 32 in
          let word_x = ref 0.0 in
          let in_word = ref false in
          let flush_word () =
            if !in_word && Buffer.length buf > 0 then begin
              let w = Buffer.contents buf in
              Cairo.move_to cr !word_x base_y;
              Cairo.show_text cr w
            end;
            Buffer.clear buf;
            in_word := false
          in
          let nglyphs = line.glyph_end - line.glyph_start in
          for i = 0 to nglyphs - 1 do
            let g = lay.glyphs.(line.glyph_start + i) in
            let ch_opt = if i < Array.length chars_v
                         then Some chars_v.(i) else None in
            let is_ws = match ch_opt with
              | Some u -> Text_layout.uchar_is_whitespace u
              | None -> true in
            if not is_ws && not g.is_trailing_space then begin
              if not !in_word then begin
                word_x := x +. g.x;
                in_word := true;
                Buffer.clear buf
              end;
              (match ch_opt with
               | Some u -> Buffer.add_utf_8_uchar buf u
               | None -> ())
            end else if !in_word then
              flush_word ()
          done;
          flush_word ();
          draw_line_decorations seg base_x base_y
        end;
        (* Hyphenation broke a word at end of line. The composer
           reserved space for the hyphen but the source content has
           no hyphen char, so the renderer must draw the glyph
           itself. The synthetic hyphen sits at the line's rightmost
           glyph x — derive it from the last glyph (which the
           composer emitted with width = hyphen_w). *)
        if line.trailing_hyphen && rot_rad = 0.0 then begin
          let hyph_x = ref (x +. line_x_shift) in
          for gi = line.glyph_start to line.glyph_end - 1 do
            let g = lay.glyphs.(gi) in
            if not g.is_trailing_space then hyph_x := x +. g.x
          done;
          Cairo.move_to cr !hyph_x base_y;
          Cairo.show_text cr "-"
        end
      ) lay.lines;
      (* Phase 6: list markers. A list-style segment may span
         multiple paragraphs (the user typed "a\nb\nc" then clicked
         bullets — the model has one wrapper covering all three
         lines). The bullet must appear on every paragraph, so walk
         the layout's lines and treat any line whose predecessor
         ended at a hard break ('\n') as a sub-paragraph start.
         Counter values follow the run rule (consecutive same-style
         num-* increment, anything else resets) across the flattened
         sub-paragraph sequence. *)
      if psegs <> [] then begin
        let psegs_arr = Array.of_list psegs in
        let owning_seg_for_line line_start =
          let result = ref None in
          Array.iteri (fun i (s : Text_layout.paragraph_segment) ->
            if !result = None
               && s.char_start <= line_start && line_start < s.char_end
            then result := Some i
          ) psegs_arr;
          !result
        in
        (* Collect sub-paragraph starts: line_idx + style + indent. *)
        let sub_paras = ref [] in
        let prev_hard_break = ref true in
        Array.iteri (fun li (line : Text_layout.line_info) ->
          if !prev_hard_break then begin
            let (style, left_indent) =
              match owning_seg_for_line line.start with
              | Some i ->
                let s = psegs_arr.(i) in
                (s.list_style, s.left_indent)
              | None -> (None, 0.0)
            in
            sub_paras := (li, style, left_indent) :: !sub_paras
          end;
          prev_hard_break := line.hard_break
        ) lay.lines;
        let sub_paras = List.rev !sub_paras in
        (* Per-style counter run: consecutive same num-* style
           sub-paragraphs continue counting; a different style (or
           bullet, or none) breaks the run. *)
        let counters = ref [] in
        let prev_num = ref None in
        let current = ref 0 in
        List.iter (fun (_, style, _) ->
          let is_num = match style with
            | Some s -> String.length s >= 4 && String.sub s 0 4 = "num-"
            | None -> false
          in
          if is_num then begin
            if !prev_num = style then current := !current + 1
            else current := 1;
            counters := !current :: !counters;
            prev_num := style
          end else begin
            counters := 0 :: !counters;
            prev_num := None;
            current := 0
          end
        ) sub_paras;
        let counters = List.rev !counters in
        List.iter2 (fun (li, style, left_indent) cnt ->
          match style with
          | None -> ()
          | Some s when s = "" -> ()
          | Some s ->
            let marker = Text_layout_paragraph.marker_text s cnt in
            if String.length marker > 0 then begin
              let line = lay.lines.(li) in
              let baseline = y +. line.baseline_y +. y_shift in
              let marker_x = x +. left_indent in
              (* Markers are rendered via Pango so font fallback
                 picks up symbol glyphs (○ ■ □ ✓ etc.) the document
                 font doesn't have. Cairo's [show_text] selects the
                 element font directly and shows tofu for any missing
                 glyph; Pango's font-fallback machinery searches the
                 system fonts for a covering glyph.
                 [set_absolute_size] takes Pango units (pixels *
                 scale) so the marker matches Cairo's pixel font size
                 — passing the px size to ``"font 16"`` would mean
                 16pt ≈ 21px and the markers would render too large. *)
              let layout = Cairo_pango.create_layout cr in
              let desc = Pango.Font.from_string font_family in
              Pango.Font.set_absolute_size desc
                (effective_fs *. float_of_int Pango.scale);
              Pango.Layout.set_font_description layout desc;
              Pango.Layout.set_text layout marker;
              let (_w, h) = Pango.Layout.get_pixel_size layout in
              Cairo.move_to cr marker_x (baseline -. float_of_int h *. 0.8);
              Cairo_pango.show_layout cr layout
            end
        ) sub_paras counters
      end
    end else begin
      let lines = String.split_on_char '\n' content in
      List.iteri (fun i line ->
        let line_y = y +. ascent +. float_of_int i *. layout_fs +. y_shift in
        show_with_spacing line x line_y;
        draw_line_decorations line x line_y
      ) lines
    end;
    if needs_scale then Cairo.restore cr;
    Cairo.Group.pop_to_source cr;
    Cairo.paint cr ~alpha:opacity
    end

  | Text_path { d; content; start_offset; font_family; font_size; font_weight; font_style; fill; opacity; transform;
                letter_spacing; kerning; _ } ->
    Cairo.Group.push cr;
    apply_transform cr transform;
    begin match fill with
    | Some { fill_color = c; _ } ->
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
        (* letter_spacing + numeric kerning: add per-char advance to
           the arc-length offset so consecutive glyphs are spaced out
           along the path. Named kerning modes parse as 0. *)
        let ls_px = _letter_spacing_px letter_spacing kerning font_size in
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
            offset := !offset +. cw +. ls_px
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
    Array.iter (fun c ->
      draw_element ~ancestor_vis:effective ~element_scale:elem_scale cr c)
      children;
    Cairo.Group.pop_to_source cr;
    Cairo.paint cr ~alpha:opacity

  | Layer { children; opacity; transform; _ } ->
    Cairo.Group.push cr;
    apply_transform cr transform;
    Array.iter (fun c ->
      draw_element ~ancestor_vis:effective ~element_scale:elem_scale cr c)
      children;
    Cairo.Group.pop_to_source cr;
    Cairo.paint cr ~alpha:opacity

  | Live v ->
    (* Evaluate the live element, resolving references against the
       render-scoped resolver ([_ref_resolver], rebuilt each paint).
       The cycle guard is a fresh local per top-level evaluate. Per
       variant we also pick the paint: a reference inherits the
       resolved target's paint when its own is None (Fork F3).
       REFERENCE_GRAPH.md Phase 1b. *)
    let resolver = !_ref_resolver in
    let visiting = ref Live.VisitSet.empty in
    let (ps, live_fill, live_stroke, live_opacity, live_transform) =
      match v with
      | Compound_shape cs ->
        (Live.evaluate_with cs Live.default_precision resolver visiting,
         cs.fill, cs.stroke, cs.opacity, cs.transform)
      | Reference r ->
        let ps = Live.reference_evaluate r Live.default_precision resolver visiting in
        let target = resolver r.ref_target in
        let fill = match r.ref_fill with
          | Some _ as f -> f
          | None -> (match target with Some t -> _element_fill t | None -> None) in
        let stroke = match r.ref_stroke with
          | Some _ as s -> s
          | None -> (match target with Some t -> _element_stroke t | None -> None) in
        (ps, fill, stroke, r.ref_opacity, r.ref_transform)
      | Recorded rec_ ->
        (* A recorded element renders its replayed (derived) geometry,
           resolved against its inputs (RECORDED_ELEMENTS.md). *)
        (Live.recorded_evaluate rec_ Live.default_precision resolver visiting,
         rec_.rec_fill, rec_.rec_stroke, rec_.rec_opacity, rec_.rec_transform)
      | Generated gen ->
        (* A generated element renders its concept's evaluated geometry,
           resolving the concept's generator from the workspace registry
           (CONCEPTS.md 3b). *)
        (Live.generated_evaluate gen Live.default_precision
           Concepts_panel.concept_resolver,
         gen.gen_fill, gen.gen_stroke, gen.gen_opacity, gen.gen_transform)
    in
    Cairo.Group.push cr;
    apply_transform cr live_transform;
    (* Trace one closed sub-path per ring of the evaluated geometry. *)
    let has_geometry = List.exists (fun ring -> Array.length ring >= 2) ps in
    if has_geometry then begin
      List.iter (fun ring ->
        if Array.length ring >= 2 then begin
          let (x0, y0) = ring.(0) in
          Cairo.move_to cr x0 y0;
          for i = 1 to Array.length ring - 1 do
            let (x, y) = ring.(i) in
            Cairo.line_to cr x y
          done;
          Cairo.Path.close cr
        end
      ) ps;
      if outline then begin
        apply_outline_style cr;
        Cairo.stroke cr
      end else
        fill_and_stroke cr live_fill live_stroke
    end;
    Cairo.Group.pop_to_source cr;
    Cairo.paint cr ~alpha:live_opacity
  end;
  Cairo.restore cr

and apply_transform cr = function
  | None -> ()
  | Some (t : Element.transform) ->
    let open Cairo in
    let m = { xx = t.a; yx = t.b; xy = t.c; yy = t.d; x0 = t.e; y0 = t.f } in
    Cairo.transform cr m

and apply_stroke cr = function
  | None -> (1.0, Element.Center)
  | Some (s : Element.stroke) ->
    let (r, g, b, a) = Element.color_to_rgba s.stroke_color in
    Cairo.set_source_rgba cr r g b a;
    let effective_width = if s.stroke_align = Element.Center then s.stroke_width
      else s.stroke_width *. 2.0 in
    Cairo.set_line_width cr effective_width;
    begin match s.stroke_linecap with
    | Butt -> Cairo.set_line_cap cr Cairo.BUTT
    | Round_cap -> Cairo.set_line_cap cr Cairo.ROUND
    | Square -> Cairo.set_line_cap cr Cairo.SQUARE
    end;
    begin match s.stroke_linejoin with
    | Miter -> Cairo.set_line_join cr Cairo.JOIN_MITER
    | Round_join -> Cairo.set_line_join cr Cairo.JOIN_ROUND
    | Bevel -> Cairo.set_line_join cr Cairo.JOIN_BEVEL
    end;
    Cairo.set_miter_limit cr s.stroke_miter_limit;
    (* When stroke_dash_align_anchors is on, the renderer expands the
       dashed stroke into solid sub-paths via Dash_renderer and draws
       each as a solid stroke — so the platform's dash pattern must be
       empty here. See DASH_ALIGN.md §Algorithm. *)
    if s.stroke_dash_pattern <> [] && not s.stroke_dash_align_anchors then
      Cairo.set_dash cr (Array.of_list s.stroke_dash_pattern) ~ofs:0.0
    else
      Cairo.set_dash cr [||] ~ofs:0.0;
    (s.stroke_opacity, s.stroke_align)

and stroke_aligned cr align =
  match align with
  | Element.Center -> Cairo.stroke cr
  | Element.Inside ->
    Cairo.save cr;
    Cairo.clip_preserve cr;
    Cairo.stroke cr;
    Cairo.restore cr
  | Element.Outside ->
    Cairo.save cr;
    Cairo.rectangle cr (-1e6) (-1e6) ~w:2e6 ~h:2e6;
    Cairo.set_fill_rule cr Cairo.EVEN_ODD;
    Cairo.clip cr;
    Cairo.stroke cr;
    Cairo.restore cr

and fill_and_stroke cr fill stroke =
  fill_and_stroke_with_gradient cr fill stroke None (0.0, 0.0, 0.0, 0.0)

and fill_and_stroke_with_gradient cr fill stroke fill_gradient bbox =
  fill_stroke_gradient_full cr fill stroke fill_gradient None bbox

(** Phase 6 + 8: gradient-aware fill+stroke. When [fill_gradient] is
    [Some], builds a Cairo pattern for the fill. When
    [stroke_gradient] is [Some], builds one for the stroke. Both
    default back to the solid-color path when [None] or unrenderable. *)
and fill_stroke_gradient_full cr fill stroke fill_gradient stroke_gradient bbox =
  let has_fill = fill <> None in
  let has_stroke = stroke <> None in
  let has_gradient = match fill_gradient with
    | Some g -> g.Element.gtype <> Element.Gradient_freeform
                && List.length g.Element.gstops >= 2
    | None -> false in
  let parse_hex_to_rgba s =
    let s = if String.length s > 0 && s.[0] = '#'
            then String.sub s 1 (String.length s - 1) else s in
    if String.length s <> 6 then (0.0, 0.0, 0.0, 1.0)
    else
      try
        let r = float_of_int (int_of_string ("0x" ^ String.sub s 0 2)) /. 255.0 in
        let g = float_of_int (int_of_string ("0x" ^ String.sub s 2 2)) /. 255.0 in
        let b = float_of_int (int_of_string ("0x" ^ String.sub s 4 2)) /. 255.0 in
        (r, g, b, 1.0)
      with _ -> (0.0, 0.0, 0.0, 1.0) in
  let apply_stops pat stops =
    List.iter (fun (s : Element.gradient_stop) ->
      let (r, g, b, _) = parse_hex_to_rgba s.stop_color in
      let a = s.stop_opacity /. 100.0 in
      Cairo.Pattern.add_color_stop_rgba pat ~ofs:(s.stop_location /. 100.0) r g b a
    ) stops
  in
  let set_gradient_source (g : Element.gradient) =
    let (bx, by, bw, bh) = bbox in
    match g.gtype with
    | Element.Gradient_linear ->
      let cx = bx +. bw /. 2.0 in
      let cy = by +. bh /. 2.0 in
      let rad = g.gangle *. Float.pi /. 180.0 in
      let half_diag = sqrt (bw *. bw +. bh *. bh) /. 2.0 in
      let dx = cos rad *. half_diag in
      let dy = -. (sin rad) *. half_diag in
      let pat = Cairo.Pattern.create_linear ~x0:(cx -. dx) ~y0:(cy -. dy)
                                             ~x1:(cx +. dx) ~y1:(cy +. dy) in
      apply_stops pat g.gstops;
      Cairo.set_source cr pat
    | Element.Gradient_radial ->
      let cx = bx +. bw /. 2.0 in
      let cy = by +. bh /. 2.0 in
      let r = (max bw bh) /. 2.0 *. (g.gaspect_ratio /. 100.0) in
      let pat = Cairo.Pattern.create_radial ~x0:cx ~y0:cy ~r0:0.0
                                             ~x1:cx ~y1:cy ~r1:r in
      apply_stops pat g.gstops;
      Cairo.set_source cr pat
    | Element.Gradient_freeform -> ()
  in
  let has_stroke_gradient = match stroke_gradient with
    | Some g -> g.Element.gtype <> Element.Gradient_freeform
                && List.length g.Element.gstops >= 2
    | None -> false in
  let stroke_with_source () =
    (* Apply stroke width / cap / join / etc first (this may set a
       solid source as a side-effect), then override the source with
       the stroke gradient if present. *)
    let (_, align) = apply_stroke cr stroke in
    (if has_stroke_gradient then
       match stroke_gradient with
       | Some g -> set_gradient_source g
       | None -> ());
    stroke_aligned cr align
  in
  (* has_gradient is computed from fill_gradient above (line 899),
     so Some is the only reachable case here. If the invariant ever
     breaks, skip the gradient fill instead of crashing the paint. *)
  if has_gradient then begin
    (match fill_gradient with
     | None -> ()
     | Some g ->
       set_gradient_source g;
       if has_stroke then begin
         Cairo.fill_preserve cr;
         stroke_with_source ()
       end else
         Cairo.fill cr)
  end else if has_fill && has_stroke then begin
    (match fill with
     | Some (f : Element.fill) ->
       let (r, g, b, a) = Element.color_to_rgba f.fill_color in
       Cairo.set_source_rgba cr r g b a
     | None -> ());
    Cairo.fill_preserve cr;
    stroke_with_source ()
  end else if has_fill then begin
    (match fill with
     | Some (f : Element.fill) ->
       let (r, g, b, a) = Element.color_to_rgba f.fill_color in
       Cairo.set_source_rgba cr r g b a
     | None -> ());
    Cairo.fill cr
  end else if has_stroke then begin
    stroke_with_source ()
  end

and poly_bbox points =
  match points with
  | [] -> (0.0, 0.0, 0.0, 0.0)
  | (x0, y0) :: rest ->
    let (x_min, y_min, x_max, y_max) =
      List.fold_left (fun (xmn, ymn, xmx, ymx) (x, y) ->
        (min xmn x, min ymn y, max xmx x, max ymx y)
      ) (x0, y0, x0, y0) rest
    in
    (x_min, y_min, x_max -. x_min, y_max -. y_min)

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

(** Per-element transform option, for any element variant. *)
let element_transform (elem : Element.element) : Element.transform option =
  match elem with
  | Element.Line { transform; _ } | Element.Rect { transform; _ }
  | Element.Circle { transform; _ } | Element.Ellipse { transform; _ }
  | Element.Polyline { transform; _ } | Element.Polygon { transform; _ }
  | Element.Path { transform; _ } | Element.Text { transform; _ }
  | Element.Text_path { transform; _ }
  | Element.Group { transform; _ } | Element.Layer { transform; _ } -> transform
  | Element.Live (Element.Compound_shape cs) -> cs.transform
  | Element.Live (Element.Reference r) -> r.Element.ref_transform
  | Element.Live (Element.Recorded rec_) -> rec_.Element.rec_transform
  | Element.Live (Element.Generated gen) -> gen.Element.gen_transform

(** Combined transform SCALE of the element at [path] — the geometric
    mean of the linear part, [sqrt(|det|)] with [det = a*.d -. b*.c],
    multiplied over the element's own transform and every ancestor
    (group/layer) transform.

    The selection OUTLINE trace and the bezier tangent handles are drawn
    UNDER the element transform; dividing their fixed pen widths / circle
    radii by this factor cancels the element transform's scaling, so they
    render at a constant size (still scaled by zoom, like the handle
    squares). Returns [1.0] when there is no transform. [det] is
    multiplicative, so the order of the chain does not matter. Mirrors the
    Python [selection_outline_scale]. *)
let selection_outline_scale (doc : Document.document)
    (path : Document.element_path) : float =
  match path with
  | [] -> 1.0
  | first :: _ ->
    (* Resolve the element along [path], collecting the transform option
       at every node on the way (layer, each intermediate group, and the
       element itself). Bail to [1.0] if the path runs through a
       non-container (mirrors the Python early returns). *)
    let node = ref doc.Document.layers.(first) in
    let transforms = ref [] in
    let abort = ref false in
    if List.length path > 1 then begin
      transforms := [ element_transform !node ];  (* layer *)
      let rest = List.tl path in
      let intermediate =
        List.filteri (fun i _ -> i < List.length rest - 1) rest in
      List.iter (fun idx ->
        if not !abort then begin
          match !node with
          | Element.Group { children; _ } | Element.Layer { children; _ } ->
            node := children.(idx);
            transforms := element_transform !node :: !transforms
          | _ -> abort := true
        end
      ) intermediate;
      if not !abort then begin
        match !node with
        | Element.Group { children; _ } | Element.Layer { children; _ } ->
          node := children.(List.nth rest (List.length rest - 1))
        | _ -> abort := true
      end
    end;
    if !abort then 1.0
    else begin
      transforms := element_transform !node :: !transforms;
      List.fold_left (fun scale t -> scale *. transform_scale_factor t)
        1.0 !transforms
    end

(** Document-space control-point handle rects [(x, y, w, h)] for the
    element at [path].

    Each rect is centered at the element-transformed control point and
    is a constant [handle_size] square, so an element transform MOVES
    the handles but never SCALES the handle glyphs (they stay a fixed
    grab size). Returns [[]] for containers (Group/Layer) and
    Text/Text_path, which carry no control-point squares (mirrors
    [draw_element_overlay]). The caller draws these under the VIEW
    (pan/zoom) transform only, NOT the element transform. *)
let selection_handle_rects (doc : Document.document)
    (path : Document.element_path) : (float * float * float * float) list =
  match path with
  | [] -> []
  | first :: _ ->
    (* Resolve the element and collect ancestor transforms (outermost
       first: layer, then each intermediate group outward to inward). *)
    let node = ref doc.Document.layers.(first) in
    let ancestors = ref [] in
    let abort = ref false in
    if List.length path > 1 then begin
      ancestors := [ element_transform !node ];  (* layer *)
      let rest = List.tl path in
      let intermediate =
        List.filteri (fun i _ -> i < List.length rest - 1) rest in
      List.iter (fun idx ->
        if not !abort then begin
          (* A Layer is a container too (Python: [Layer] subclasses
             [Group]); descend into either's children. *)
          match !node with
          | Element.Group { children; _ } | Element.Layer { children; _ } ->
            node := children.(idx);
            ancestors := element_transform !node :: !ancestors
          | _ -> abort := true
        end
      ) intermediate;
      if not !abort then begin
        match !node with
        | Element.Group { children; _ } | Element.Layer { children; _ } ->
          node := children.(List.nth rest (List.length rest - 1))
        | _ -> abort := true
      end
    end;
    if !abort then []
    else begin
      let elem = !node in
      match elem with
      | Element.Text _ | Element.Text_path _
      | Element.Group _ | Element.Layer _ -> []
      | _ ->
        (* Apply transforms innermost-first: the element's own
           transform, then each ancestor outward (layer last) — matching
           the painter combined CTM. [ancestors] was built outermost
           first, so reversing it gives innermost-ancestor first. *)
        let chain =
          element_transform elem :: List.rev !ancestors in
        let half = handle_size /. 2.0 in
        List.map (fun (px, py) ->
          let (px, py) =
            List.fold_left (fun (px, py) t ->
              match t with
              | Some tr -> Element.apply_point tr px py
              | None -> (px, py)
            ) (px, py) chain
          in
          (px -. half, py -. half, handle_size, handle_size)
        ) (control_points elem)
    end

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
    ?(outline_scale = 1.0)
    ~is_partial:(_ : bool) (selected_cps : int list) =
  let open Element in
  (* Counter-scale fixed pen widths / circle radii by the element
     transform's scale ([outline_scale]) so the overlay — drawn UNDER
     that transform — renders at a constant width regardless of the
     element's scale (it stays zoom-scaled, like the handle squares).
     Mirrors the Python [_draw_element_overlay] [inv]. *)
  let inv = if outline_scale > 1e-6 then 1.0 /. outline_scale else 1.0 in
  Cairo.set_source_rgb cr 0.0 0.47 1.0;
  Cairo.set_line_width cr inv;
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
  (* Draw Bezier handles for selected path control points. The pen width
     and circle radii are counter-scaled by [inv] for the same reason as
     the outline pen above. *)
  let handle_circle_radius = 3.0 *. inv in
  (match elem with
   | Path { d; _ } when selected_cps <> [] ->
     let anchors = control_points elem in
     List.iter (fun cp_idx ->
       let ax, ay = try List.nth anchors cp_idx with _ -> (0.0, 0.0) in
       if cp_idx < List.length anchors then begin
         let (h_in, h_out) = Element.path_handle_positions d cp_idx in
         Cairo.set_source_rgb cr 0.0 0.47 1.0;
         Cairo.set_line_width cr inv;
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
  (* NOTE: the control-point handle SQUARES are intentionally NOT drawn
     here. They are drawn by [draw_selection_overlays] via
     [selection_handle_rects] at a FIXED size under the view (pan/zoom)
     transform only, so an element transform moves them but never scales
     the glyphs. The outline trace plus the bezier handles above stay
     under the element transform (they trace the geometry). *)
  ()

(* ── Artboard rendering (ARTBOARDS.md §Canvas appearance) ──────────
   Z-order passes, back to front:
     2. draw_artboard_fills       (per artboard, list order)
     4. draw_fade_overlay         (dims off-artboard regions)
     5. draw_artboard_borders     (thin default borders)
     6. draw_artboard_accent      (2px outer for panel-selected)
     7. draw_artboard_labels      ("N  Name" above top-left)
     8. draw_artboard_display_marks (center / cross hairs / safe areas)

   Phase-D first pass: colors are fixed constants; theme integration
   waits on threading the theme through the canvas subwindow. *)

let _hex_to_rgb hex =
  if String.length hex = 7 && String.get hex 0 = '#' then
    try
      let r = int_of_string ("0x" ^ String.sub hex 1 2) in
      let g = int_of_string ("0x" ^ String.sub hex 3 2) in
      let b = int_of_string ("0x" ^ String.sub hex 5 2) in
      Some (float_of_int r /. 255.0,
            float_of_int g /. 255.0,
            float_of_int b /. 255.0)
    with _ -> None
  else None

let draw_artboard_fills cr (doc : Document.document) =
  List.iter (fun (ab : Artboard.artboard) ->
    match ab.fill with
    | Artboard.Transparent ->
      (* Default white "paper" so the artboard reads as distinct from
         the gray pasteboard. (Future: a transparency-grid pref could
         opt out and draw a checkerboard instead.) *)
      Cairo.set_source_rgb cr 1.0 1.0 1.0;
      Cairo.rectangle cr ab.x ab.y ~w:ab.width ~h:ab.height;
      Cairo.fill cr
    | Artboard.Color hex ->
      (match _hex_to_rgb hex with
       | None -> ()
       | Some (r, g, b) ->
         Cairo.set_source_rgb cr r g b;
         Cairo.rectangle cr ab.x ab.y ~w:ab.width ~h:ab.height;
         Cairo.fill cr)
  ) doc.Document.artboards

let draw_fade_overlay _cr (_doc : Document.document) ~canvas_w:_ ~canvas_h:_ =
  (* No-op: the gray pasteboard + white artboard fill give enough
     contrast on their own. The legacy implementation used
     `DEST_OUT` to punch artboards out of a darken overlay, which
     wiped the artboard fill back to whatever Cairo's backing was
     (matching the Swift "all-white canvas" regression). Reinstate a
     non-destructive overlay if a future visual pass calls for it. *)
  ()

let draw_artboard_borders cr (doc : Document.document) =
  Cairo.set_source_rgb cr 0.2 0.2 0.2;
  Cairo.set_line_width cr 1.0;
  List.iter (fun (ab : Artboard.artboard) ->
    Cairo.rectangle cr ab.x ab.y ~w:ab.width ~h:ab.height;
    Cairo.stroke cr
  ) doc.Document.artboards

(* Z-layer 5b (PRINT.md §1A): red dashed bleed guide drawn just
   outside each artboard when any document_setup.bleed_* is non-zero. *)
let draw_bleed_guides cr (doc : Document.document) =
  let s = doc.Document.document_setup in
  if s.Document_setup.bleed_top = 0.0 && s.bleed_right = 0.0
     && s.bleed_bottom = 0.0 && s.bleed_left = 0.0
  then ()
  else begin
    Cairo.save cr;
    Cairo.set_source_rgb cr 0.9 0.0 0.0;
    Cairo.set_line_width cr 1.0;
    Cairo.set_dash cr ~ofs:0.0 [|4.0; 4.0|];
    List.iter (fun (ab : Artboard.artboard) ->
      match Document_setup.bleed_rect_for_artboard s ab with
      | Some (x, y, w, h) ->
        Cairo.rectangle cr x y ~w ~h;
        Cairo.stroke cr
      | None -> ()
    ) doc.Document.artboards;
    Cairo.restore cr
  end

let draw_artboard_accent cr (doc : Document.document) ~selected_ids =
  if selected_ids <> [] then begin
    Cairo.set_source_rgba cr 0.0 (120.0 /. 255.0) (215.0 /. 255.0) 0.95;
    Cairo.set_line_width cr 2.0;
    List.iter (fun (ab : Artboard.artboard) ->
      if List.mem ab.id selected_ids then begin
        let pad = 1.5 in
        Cairo.rectangle cr
          (ab.x -. pad) (ab.y -. pad)
          ~w:(ab.width +. 2.0 *. pad)
          ~h:(ab.height +. 2.0 *. pad);
        Cairo.stroke cr
      end
    ) doc.Document.artboards
  end

let draw_artboard_labels cr (doc : Document.document) =
  Cairo.set_source_rgb cr 0.78 0.78 0.78;
  Cairo.select_font_face cr "sans-serif" ~slant:Cairo.Upright ~weight:Cairo.Normal;
  Cairo.set_font_size cr 11.0;
  List.iteri (fun i (ab : Artboard.artboard) ->
    let label = Printf.sprintf "%d  %s" (i + 1) ab.name in
    (* Sit label just above the top-left corner. *)
    Cairo.move_to cr ab.x (ab.y -. 3.0);
    Cairo.show_text cr label
  ) doc.Document.artboards

let draw_artboard_display_marks cr (doc : Document.document) =
  Cairo.set_source_rgb cr 0.6 0.6 0.6;
  Cairo.set_line_width cr 1.0;
  List.iter (fun (ab : Artboard.artboard) ->
    let cx = ab.x +. ab.width /. 2.0 in
    let cy = ab.y +. ab.height /. 2.0 in
    if ab.show_center_mark then begin
      let arm = 5.0 in
      Cairo.move_to cr (cx -. arm) cy;
      Cairo.line_to cr (cx +. arm) cy;
      Cairo.move_to cr cx (cy -. arm);
      Cairo.line_to cr cx (cy +. arm);
      Cairo.stroke cr
    end;
    if ab.show_cross_hairs then begin
      Cairo.move_to cr ab.x cy;
      Cairo.line_to cr (ab.x +. ab.width) cy;
      Cairo.move_to cr cx ab.y;
      Cairo.line_to cr cx (ab.y +. ab.height);
      Cairo.stroke cr
    end;
    if ab.show_video_safe_areas then begin
      List.iter (fun frac ->
        let w = ab.width *. frac in
        let h = ab.height *. frac in
        Cairo.rectangle cr
          (ab.x +. (ab.width -. w) /. 2.0)
          (ab.y +. (ab.height -. h) /. 2.0)
          ~w ~h;
        Cairo.stroke cr
      ) [0.9; 0.8]
    end
  ) doc.Document.artboards

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
        | Element.Group { transform; _ } | Element.Layer { transform; _ } -> transform
        | Element.Live (Element.Compound_shape cs) -> cs.transform
        | Element.Live (Element.Reference r) -> r.Element.ref_transform
        | Element.Live (Element.Recorded rec_) -> rec_.Element.rec_transform
        | Element.Live (Element.Generated gen) -> gen.Element.gen_transform);
      let n = Element.control_point_count !node in
      let cps = Document.selection_kind_to_sorted es.es_kind ~total:n in
      let is_partial = match es.es_kind with
        | Document.SelKindPartial _ -> true
        | Document.SelKindAll -> false
      in
      draw_element_overlay cr !node
        ~outline_scale:(selection_outline_scale doc path)
        ~is_partial cps;
      Cairo.restore cr;
      (* Control-point handles: FIXED size at element-transformed
         positions, drawn under the VIEW (pan/zoom) transform only — the
         per-element transform was restored above — so the element
         transform moves the handles but never scales the glyphs. The
         filled-vs-white rule matches the old in-transform draw: a CP in
         the selection kind is filled blue, the rest white. *)
      Cairo.set_line_width cr 1.0;
      List.iteri (fun i (hx, hy, hw, hh) ->
        Cairo.rectangle cr hx hy ~w:hw ~h:hh;
        if Document.selection_kind_contains es.es_kind i then
          Cairo.set_source_rgb cr 0.0 0.47 1.0
        else
          Cairo.set_source_rgb cr 1.0 1.0 1.0;
        Cairo.fill_preserve cr;
        Cairo.set_source_rgb cr 0.0 0.47 1.0;
        Cairo.stroke cr
      ) (selection_handle_rects doc path)
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
      (* Tools that draw an element overlay carry no ancestor context, so
         the outline scale defaults to 1.0 (no counter-scaling). *)
      draw_element_overlay =
        (fun cr elem ~is_partial cps ->
          draw_element_overlay cr elem ~is_partial cps);
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
          | Toolbar.Partial_selection ->
            _self#make_arrow_cursor 1.0 1.0 1.0 0.0 0.0 0.0 false
          | Toolbar.Interior_selection ->
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
      (* Preserve selection across tool changes. Selection-only: a non-undoable
         write (OP_LOG.md sections 7 and 8). *)
      let doc = current_doc in
      if doc.Document.selection <> saved_selection then
        model#set_document_unbracketed { doc with Document.selection = saved_selection }

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
      (match key_name with
       | None -> false
       | Some k ->
         (* Escape / Enter must reach the active tool on_keydown even for
            non-capturing tools (every tool cancels or finishes an in-progress
            gesture this way); other keys only when the tool captures keyboard
            for a text-edit session. Mirrors the Rust keyboard router. *)
         if active_tool#captures_keyboard () || k = "Escape" || k = "Enter"
         then active_tool#on_key_event ctx k mods
         else false)

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
        (* Layer 1: pasteboard (canvas background). Medium gray;
           artboard fills draw white over it so the artboard reads as
           "paper on a layout table". Filled in screen-space before
           the view transform so it covers the viewport regardless of
           zoom and pan. *)
        Cairo.set_source_rgb cr 0.47 0.47 0.47;
        Cairo.rectangle cr 0.0 0.0 ~w ~h;
        Cairo.fill cr;
        (* Sync model viewport size with the current canvas
           bounds. First-time syncs re-center on the active
           artboard (the construction-time default 888x900 is
           replaced). Per HAND_TOOL.md Document-open behavior. *)
        if w > 0.0 && h > 0.0 then begin
          let was_default =
            abs_float (model#viewport_w -. 888.0) < 0.5
            && abs_float (model#viewport_h -. 900.0) < 0.5
          in
          model#set_viewport_w w;
          model#set_viewport_h h;
          if was_default then
            model#center_view_on_current_artboard
        end;
        (* Apply view transform: zoom + pan. Layers 2-9 draw in
           document coordinates; Cairo translates them to screen
           pixels. Tool overlay is drawn AFTER restoring the
           identity transform because tool-state coords are
           already in screen-pixel space. *)
        Cairo.save cr;
        Cairo.translate cr model#view_offset_x model#view_offset_y;
        Cairo.scale cr model#zoom_level model#zoom_level;
        (* Layer 2: artboard fills *)
        draw_artboard_fills cr current_doc;
        (* Install the Model's already-built persistent id->element index
           so the live render arm resolves by-id references this paint
           (REFERENCE_GRAPH.md section 2.4 Phase 4b). Paint no longer
           rebuilds the index per frame; it reads the index the Model
           carries with the document (an O(log n) lookup resolver over a
           shared Map), which the Model keeps equal to a from-scratch
           rebuild via its [assert] gate. The index spans layers + the
           off-canvas master store so an instance resolves a master
           (SYMBOLS.md section 2); masters are never in [layers], so this
           never paints them. *)
        _ref_resolver := Live.resolver_of_index model#id_index;
        (* Phase 4c: epoch the reference-geometry recompute cache off the
           Model's generation (cleared on any edit / undo / redo), so no-edit
           repaints reuse the cached target geometry. PER-APP perf cache; no
           behavior change (gated by a per-hit [assert (cached = fresh)] in
           [Live]). *)
        Live.set_recompute_cache_generation model#generation;
        (* Layer 3: document element tree. In mask-isolation mode
           (OPACITY.md Preview interactions), render only the
           mask subtree of the isolated element — everything else
           on the canvas is hidden until the user exits isolation. *)
        (match model#mask_isolation_path with
         | Some path ->
           (try
              let elem = Document.get_element current_doc path in
              match Element.get_mask elem with
              | Some mask -> draw_element cr mask.Element.subtree
              | None -> ()
            with _ -> ())
         | None ->
           Array.iter (draw_element cr) current_doc.Document.layers);
        (* Layer 4: fade overlay *)
        draw_fade_overlay cr current_doc ~canvas_w:w ~canvas_h:h;
        (* Layer 5: artboard borders *)
        draw_artboard_borders cr current_doc;
        (* Layer 5b: bleed guide rectangles (PRINT.md §1A). *)
        draw_bleed_guides cr current_doc;
        (* Layer 6: accent border for panel-selected artboards
           (empty list until panel_selection is threaded in). *)
        draw_artboard_accent cr current_doc ~selected_ids:[];
        (* Layer 7: artboard labels *)
        draw_artboard_labels cr current_doc;
        (* Layer 8: per-artboard display marks *)
        draw_artboard_display_marks cr current_doc;
        (* Layer 9: selection overlays *)
        draw_selection_overlays cr current_doc;
        Cairo.restore cr;
        (* Active tool overlay (screen-space, post-transform). *)
        _self#switch_tool;
        active_tool#draw_overlay _self#tool_context cr;
        true
      ) |> ignore;

      (* Canvas mouse events — dispatched through active tool. The
         drawing area is made focusable so clicks on the canvas pull
         keyboard focus away from any panel entry — Backspace then
         deletes the selected element instead of being swallowed by
         the entry that previously had focus. *)
      canvas_area#misc#set_can_focus true;
      canvas_area#event#add [`BUTTON_PRESS; `BUTTON_RELEASE; `POINTER_MOTION];
      canvas_area#event#connect#button_press ~callback:(fun ev ->
        if GdkEvent.Button.button ev = 1 then begin
          canvas_area#misc#grab_focus ();
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
        (* Forward to Dock_panel so a panel-drag preview can track
           the cursor across the canvas. No-op when no drag is in
           progress. *)
        Dock_panel.notify_drag_motion
          ~x_root:(GdkEvent.Motion.x_root ev)
          ~y_root:(GdkEvent.Motion.y_root ev);
        _self#switch_tool;
        let x = GdkEvent.Motion.x ev in
        let y = GdkEvent.Motion.y ev in
        let shift = Gdk.Convert.test_modifier `SHIFT (GdkEvent.Motion.state ev) in
        let alt = Gdk.Convert.test_modifier `MOD1 (GdkEvent.Motion.state ev) in
        let buttons = GdkEvent.Motion.state ev in
        let dragging = Gdk.Convert.test_modifier `BUTTON1 buttons in
        let ctx = _self#tool_context in
        active_tool#on_move ctx x y ~shift ~alt ~dragging;
        true
      ) |> ignore;
      canvas_area#event#connect#button_release ~callback:(fun ev ->
        if GdkEvent.Button.button ev = 1 then begin
          (* Cooperate with Dock_panel's drag-to-float: if a panel
             tab is being dragged and the user just released over the
             canvas (i.e. outside the dock), [Dock_panel.try_handle_drop]
             detaches the panel into a floating window. Returns true
             when consumed, in which case we skip the canvas tool's
             on_release so the active tool doesn't also process the
             event as a regular click. *)
          let x_root = GdkEvent.Button.x_root ev in
          let y_root = GdkEvent.Button.y_root ev in
          if Dock_panel.try_handle_drop ~x_root ~y_root then true
          else begin
            _self#switch_tool;
            let x = GdkEvent.Button.x ev in
            let y = GdkEvent.Button.y ev in
            let shift = Gdk.Convert.test_modifier `SHIFT (GdkEvent.Button.state ev) in
            let alt = Gdk.Convert.test_modifier `MOD1 (GdkEvent.Button.state ev) in
            let ctx = _self#tool_context in
            active_tool#on_release ctx x y ~shift ~alt;
            true
          end
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
  (* Adwaita's default label color is dark grey, which is illegible
     against the dark workspace tab strip. Force a light text color
     on the tab label + the close button's "×" label so both stay
     visible at the workspace's dark/medium-gray appearance. *)
  let provider = new GObj.css_provider (GtkData.CssProvider.create ()) in
  provider#load_from_data "label { color: #cccccc; }";
  tab_label#misc#style_context#add_provider provider 800;
  let close_btn = GButton.button ~packing:tab_hbox#add () in
  close_btn#set_relief `NONE;
  let close_label = GMisc.label ~text:"\xC3\x97" ~packing:close_btn#add () in
  close_label#misc#style_context#add_provider provider 800;
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
