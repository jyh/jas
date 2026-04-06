(** Smooth tool for simplifying path curves by re-fitting anchor points.

    {2 Overview}

    The Smooth tool is a brush-like tool that simplifies vector paths by
    reducing the number of anchor points while preserving the overall shape.
    The user drags the tool over a selected path, and the portion of the path
    that falls within the tool's circular influence region (radius =
    [smooth_size], currently 100 pt) is simplified in real time.

    Only selected, unlocked Path elements are affected.  Non-path elements
    (rectangles, ellipses, text, etc.) and locked paths are skipped.

    {2 Algorithm}

    Each time the tool processes a cursor position (on press and on drag),
    it runs the following pipeline on every selected path:

    {3 1. Flatten with command map}

    The path's command list (MoveTo, LineTo, CurveTo, QuadTo, etc.) is
    converted into a dense polyline of (x, y) points.  Curves are subdivided
    into [flatten_steps] (20) evenly-spaced samples using de Casteljau
    evaluation.  Straight segments produce a single point.

    Alongside the flat point array, a parallel {b command map} array is
    built: [cmd_map.(i)] records the index of the original path command that
    produced flat point [i].  This mapping is the key data structure that
    connects the polyline back to the original command list.

    {3 2. Hit detection}

    The flat points are scanned to find the {b contiguous range} that lies
    within the tool's circular influence region (distance <= [smooth_size]
    from the cursor).  The scan records [first_hit] and [last_hit] -- the
    indices of the first and last flat points inside the circle.

    If no flat points are within range, the path is skipped.

    {3 3. Command mapping}

    The flat-point hit indices are mapped back to original command indices
    via the command map: [first_cmd = cmd_map.(first_hit)] and
    [last_cmd = cmd_map.(last_hit)].  These define the range of original
    commands [[first_cmd, last_cmd]] that will be replaced.

    If [first_cmd = last_cmd], the influence region only touches points
    from a single command -- there is nothing to merge, so the path is
    skipped.  At least two commands must be affected for smoothing to
    have any effect.

    {3 4. Re-fit (Schneider curve fitting)}

    All flat points whose command index falls in [[first_cmd, last_cmd]]
    are collected into [range_flat].  The start point of [first_cmd] (i.e.
    the endpoint of the preceding command) is prepended to form
    [points_to_fit], ensuring the re-fitted curve begins exactly where the
    unaffected prefix ends.

    These points are passed to [Fit_curve.fit_curve], which implements the
    Schneider curve-fitting algorithm.  [smooth_error] (8.0) is the maximum
    allowed deviation.  Because this tolerance is relatively generous, the
    fitter typically produces fewer Bezier segments than the original
    commands -- that is the simplification.

    {3 5. Reassembly}

    The original command list is reconstructed in three parts:
    - {b Prefix}: commands [[0, first_cmd)] -- unchanged.
    - {b Middle}: the re-fitted CurveTo commands from step 4.
    - {b Suffix}: commands [(last_cmd, end]] -- unchanged.

    If the resulting command count is not strictly less than the original,
    the replacement is discarded (no improvement).  Otherwise the path
    element is replaced in the document.

    {2 Cumulative effect}

    The effect is cumulative: each drag pass removes more detail, producing
    progressively smoother curves.  Repeatedly dragging over the same region
    continues to simplify until the path can be represented by a single
    Bezier segment (or the fit can no longer reduce the command count).

    {2 Overlay}

    While the tool is active, a cornflower-blue circle (rgba 100, 149, 237,
    0.4) is drawn at the cursor position showing the influence region. *)

let smooth_size = 100.0
let smooth_error = 8.0
let flatten_steps = 20

(** Return the endpoint (final pen position) of a path command.

    Every path command except ClosePath moves the pen to a new position.
    For ClosePath (which returns to the last MoveTo), we return (0, 0)
    as a fallback -- ClosePath is not expected in a smoothable region. *)
let cmd_endpoint = function
  | Element.MoveTo (x, y) | Element.LineTo (x, y) -> (x, y)
  | Element.CurveTo (_, _, _, _, x, y) -> (x, y)
  | Element.QuadTo (_, _, x, y) -> (x, y)
  | Element.SmoothCurveTo (_, _, x, y) -> (x, y)
  | Element.SmoothQuadTo (x, y) -> (x, y)
  | Element.ArcTo (_, _, _, _, _, x, y) -> (x, y)
  | Element.ClosePath -> (0.0, 0.0)

(** Return the start point of command at [cmd_idx] in an array.

    A path command's start point is the endpoint of the preceding command,
    since each command implicitly begins where the previous one ended.  For
    the first command (index 0), the start point is the origin (0, 0).

    Used during re-fitting to prepend the correct start point to the
    collected flat points, ensuring the re-fitted curve connects seamlessly
    with the unaffected prefix of the path. *)
let cmd_start_point cmds cmd_idx =
  if cmd_idx = 0 then (0.0, 0.0)
  else cmd_endpoint cmds.(cmd_idx - 1)

(** Flatten path commands (given as array) into a polyline with a parallel
    command-index map.

    Returns [(flat_points, cmd_map)] where:
    - [flat_points.(i)] is the (x, y) position of the i-th polyline sample.
    - [cmd_map.(i)] is the index of the original path command that produced
      [flat_points.(i)].

    MoveTo and LineTo commands produce exactly one flat point each.
    CurveTo commands are subdivided into [flatten_steps] samples using the
    cubic Bezier formula:
        B(t) = (1-t)^3*P0 + 3(1-t)^2*t*P1 + 3(1-t)*t^2*P2 + t^3*P3
    evaluated at t = 1/steps, 2/steps, ..., 1.  This captures the curve's
    shape as a dense polyline while recording which command each sample came
    from.  QuadTo commands are similarly subdivided using the quadratic
    formula.  ClosePath produces no points.  Rare commands (SmoothCurveTo,
    SmoothQuadTo, ArcTo) are approximated as a single point at their
    endpoint. *)
let flatten_with_cmd_map cmds =
  let pts = ref [] in
  let cmap = ref [] in
  let cx = ref 0.0 in
  let cy = ref 0.0 in
  Array.iteri (fun cmd_idx cmd ->
    match cmd with
    | Element.MoveTo (x, y) ->
      pts := (x, y) :: !pts;
      cmap := cmd_idx :: !cmap;
      cx := x; cy := y
    | Element.LineTo (x, y) ->
      pts := (x, y) :: !pts;
      cmap := cmd_idx :: !cmap;
      cx := x; cy := y
    | Element.CurveTo (x1, y1, x2, y2, ex, ey) ->
      for i = 1 to flatten_steps do
        let t = float_of_int i /. float_of_int flatten_steps in
        let mt = 1.0 -. t in
        let px = mt *. mt *. mt *. !cx
                 +. 3.0 *. mt *. mt *. t *. x1
                 +. 3.0 *. mt *. t *. t *. x2
                 +. t *. t *. t *. ex in
        let py = mt *. mt *. mt *. !cy
                 +. 3.0 *. mt *. mt *. t *. y1
                 +. 3.0 *. mt *. t *. t *. y2
                 +. t *. t *. t *. ey in
        pts := (px, py) :: !pts;
        cmap := cmd_idx :: !cmap
      done;
      cx := ex; cy := ey
    | Element.QuadTo (x1, y1, ex, ey) ->
      for i = 1 to flatten_steps do
        let t = float_of_int i /. float_of_int flatten_steps in
        let mt = 1.0 -. t in
        let px = mt *. mt *. !cx +. 2.0 *. mt *. t *. x1 +. t *. t *. ex in
        let py = mt *. mt *. !cy +. 2.0 *. mt *. t *. y1 +. t *. t *. ey in
        pts := (px, py) :: !pts;
        cmap := cmd_idx :: !cmap
      done;
      cx := ex; cy := ey
    | Element.SmoothCurveTo (_, _, ex, ey)
    | Element.SmoothQuadTo (ex, ey) ->
      (* Treat as line for flattening; these are rare in practice. *)
      pts := (ex, ey) :: !pts;
      cmap := cmd_idx :: !cmap;
      cx := ex; cy := ey
    | Element.ArcTo (_, _, _, _, _, ex, ey) ->
      pts := (ex, ey) :: !pts;
      cmap := cmd_idx :: !cmap;
      cx := ex; cy := ey
    | Element.ClosePath -> ()
  ) cmds;
  (Array.of_list (List.rev !pts), Array.of_list (List.rev !cmap))

class smooth_tool = object (_self)
  val mutable smoothing = false
  val mutable last_pos = (0.0, 0.0)

  method on_press (ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(alt : bool) =
    ignore (shift, alt);
    ctx.model#snapshot;
    smoothing <- true;
    last_pos <- (x, y);
    _self#smooth_at ctx x y

  method on_move (ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(dragging : bool) =
    ignore (shift, dragging);
    if smoothing then
      _self#smooth_at ctx x y;
    last_pos <- (x, y)

  method on_release (_ctx : Canvas_tool.tool_context) (_x : float) (_y : float) ~(shift : bool) ~(alt : bool) =
    ignore (shift, alt);
    smoothing <- false

  method on_double_click (_ctx : Canvas_tool.tool_context) (_x : float) (_y : float) = ()
  method on_key (_ctx : Canvas_tool.tool_context) (_keycode : int) = false
  method on_key_release (_ctx : Canvas_tool.tool_context) (_keycode : int) = false
  method activate (_ctx : Canvas_tool.tool_context) = ()
  method deactivate (_ctx : Canvas_tool.tool_context) = ()

  method draw_overlay (_ctx : Canvas_tool.tool_context) cr =
    let (x, y) = last_pos in
    Cairo.set_source_rgba cr 0.39 0.58 0.93 0.4;
    Cairo.set_line_width cr 1.0;
    Cairo.arc cr x y ~r:smooth_size ~a1:0.0 ~a2:(2.0 *. Float.pi);
    Cairo.stroke cr

  (** Run the smoothing pipeline at cursor position (x, y).

      For each selected, unlocked path with at least 2 commands:
        1. Flatten the path into a polyline with a command-index map.
        2. Find which flat points fall inside the influence circle.
        3. Map those flat indices back to original command indices.
        4. Re-fit the affected region with Schneider curve fitting.
        5. Splice the re-fitted curves into the original command list.
      If the result has fewer commands, update the document. *)
  method private smooth_at (ctx : Canvas_tool.tool_context) x y =
    let doc = ctx.model#document in
    let radius_sq = smooth_size *. smooth_size in
    let new_doc = ref doc in

    Document.PathMap.iter (fun _path es ->
      let path = es.Document.es_path in
      let elem = try Document.get_element !new_doc path with _ -> Element.make_layer [||] in
      match elem with
      | Element.Path r when not (Element.is_locked elem) && List.length r.d >= 2 ->
        let cmds = Array.of_list r.d in
        let (flat, cmd_map) = flatten_with_cmd_map cmds in
        if Array.length flat >= 2 then begin
          (* Find contiguous range of flat points within the circle. *)
          let first_hit = ref (-1) in
          let last_hit = ref (-1) in
          Array.iteri (fun i (px, py) ->
            let dx = px -. x in
            let dy = py -. y in
            if dx *. dx +. dy *. dy <= radius_sq then begin
              if !first_hit = -1 then first_hit := i;
              last_hit := i
            end
          ) flat;

          if !first_hit >= 0 && !last_hit >= 0 then begin
            let first_cmd = cmd_map.(!first_hit) in
            let last_cmd = cmd_map.(!last_hit) in

            if first_cmd < last_cmd then begin
              (* Collect flattened points for the affected command range. *)
              let range_flat = ref [] in
              Array.iteri (fun i pt ->
                let ci = cmd_map.(i) in
                if ci >= first_cmd && ci <= last_cmd then
                  range_flat := pt :: !range_flat
              ) flat;
              let range_flat = List.rev !range_flat in

              let start_point = cmd_start_point cmds first_cmd in
              let points_to_fit = start_point :: range_flat in

              if List.length points_to_fit >= 2 then begin
                let segments = Fit_curve.fit_curve points_to_fit smooth_error in
                if segments <> [] then begin
                  (* Build replacement commands. *)
                  let new_cmds = ref [] in
                  (* Commands before the affected range. *)
                  for i = 0 to first_cmd - 1 do
                    new_cmds := cmds.(i) :: !new_cmds
                  done;
                  (* Re-fitted curves. *)
                  List.iter (fun (seg : Fit_curve.segment) ->
                    new_cmds := Element.CurveTo (seg.c1x, seg.c1y, seg.c2x, seg.c2y,
                                                 seg.p2x, seg.p2y) :: !new_cmds
                  ) segments;
                  (* Commands after the affected range. *)
                  for i = last_cmd + 1 to Array.length cmds - 1 do
                    new_cmds := cmds.(i) :: !new_cmds
                  done;
                  let result = List.rev !new_cmds in

                  (* Only apply if we actually reduced. *)
                  if List.length result < List.length r.d then begin
                    let new_elem = Element.Path { r with d = result } in
                    new_doc := Document.replace_element !new_doc path new_elem
                  end
                end
              end
            end
          end
        end
      | _ -> ()
    ) doc.Document.selection;

    if !new_doc != doc then begin
      ctx.model#set_document !new_doc;
      ctx.request_update ()
    end
end
