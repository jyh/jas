(** Text-on-path tool: click on a path to add text, drag to create new curve,
    drag offset handle to reposition text start point. *)

let offset_handle_radius = 5.0

class text_path_tool = object (_self)
  val mutable drag_start : (float * float) option = None
  val mutable drag_end : (float * float) option = None
  val mutable control_pt : (float * float) option = None
  (* Offset handle drag state *)
  val mutable offset_dragging = false
  val mutable offset_drag_path : int list option = None
  val mutable offset_preview : float option = None

  (* Find if (x,y) is near the start-offset handle of a selected TextPath *)
  method private find_selected_textpath_handle (ctx : Canvas_tool.tool_context) x y =
    let doc = ctx.model#document in
    let r = offset_handle_radius +. 2.0 in
    let result = ref None in
    Document.PathMap.iter (fun _key (es : Document.element_selection) ->
      if !result = None then begin
        let elem = Document.get_element doc es.es_path in
        match elem with
        | Element.Text_path { d; start_offset; _ } when d <> [] ->
          let (hx, hy) = Element.path_point_at_offset d start_offset in
          if abs_float (x -. hx) <= r && abs_float (y -. hy) <= r then
            result := Some (es.es_path, elem)
        | _ -> ()
      end
    ) doc.Document.selection;
    !result

  method on_press (ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(alt : bool) =
    ignore (shift, alt);
    ctx.model#snapshot;
    (* 1) Check offset handle drag *)
    (match _self#find_selected_textpath_handle ctx x y with
     | Some (path, _elem) ->
       offset_dragging <- true;
       offset_drag_path <- Some path;
       offset_preview <- None
     | None ->
       (* 2) Start drag-create *)
       drag_start <- Some (x, y);
       drag_end <- Some (x, y);
       control_pt <- None)

  method on_move (ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(dragging : bool) =
    ignore (shift, dragging);
    (* Offset handle drag *)
    if offset_dragging then begin
      (match offset_drag_path with
       | Some path ->
         let doc = ctx.model#document in
         (try
           let elem = Document.get_element doc path in
           (match elem with
            | Element.Text_path { d; _ } when d <> [] ->
              offset_preview <- Some (Element.path_closest_offset d x y);
              ctx.request_update ()
            | _ -> ())
         with _ -> ())
       | None -> ())
    end else
      match drag_start with
      | Some (sx, sy) ->
        drag_end <- Some (x, y);
        let mx = (sx +. x) /. 2.0 and my = (sy +. y) /. 2.0 in
        let dx = x -. sx and dy = y -. sy in
        let dist = sqrt (dx *. dx +. dy *. dy) in
        if dist > Canvas_tool.drag_threshold then begin
          let nx = -. dy /. dist and ny = dx /. dist in
          control_pt <- Some (mx +. nx *. dist *. 0.3, my +. ny *. dist *. 0.3)
        end;
        ctx.request_update ()
      | None -> ()

  method on_release (ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(alt : bool) =
    ignore (shift, alt);
    (* Offset handle drag commit *)
    if offset_dragging then begin
      (match offset_drag_path, offset_preview with
       | Some path, Some new_offset ->
         let doc = ctx.model#document in
         (try
           let elem = Document.get_element doc path in
           (match elem with
            | Element.Text_path t ->
              let new_elem = Element.Text_path { t with start_offset = new_offset } in
              ctx.controller#set_document (Document.replace_element doc path new_elem)
            | _ -> ())
         with _ -> ())
       | _ -> ());
      offset_dragging <- false;
      offset_drag_path <- None;
      offset_preview <- None;
      ctx.request_update ()
    end else begin
      match drag_start with
      | None -> ()
      | Some (sx, sy) ->
        drag_start <- None;
        drag_end <- None;
        let w = abs_float (x -. sx) and h = abs_float (y -. sy) in
        if w <= Canvas_tool.drag_threshold && h <= Canvas_tool.drag_threshold then begin
          (* Click (not drag): check if we hit a Path to convert *)
          (match ctx.hit_test_path_curve x y with
           | Some (path, elem) ->
             (match elem with
              | Element.Path { d; _ } ->
                let start_off = Element.path_closest_offset d x y in
                let tp = Element.make_text_path
                  ~start_offset:start_off
                  ~fill:(Some Element.{ fill_color = { r = 0.0; g = 0.0; b = 0.0; a = 1.0 } })
                  d "" in
                let new_doc = Document.replace_element (ctx.model#document) path tp in
                ctx.controller#set_document new_doc;
                ctx.controller#select_element path;
                ctx.start_text_edit path tp;
                ctx.request_update ()
              | Element.Text_path _ ->
                ctx.controller#select_element path;
                ctx.start_text_edit path elem;
                ctx.request_update ()
              | _ -> ())
           | None -> ())
        end else begin
          (* Drag: create a new text-on-path element *)
          let d = match control_pt with
            | Some (cx, cy) ->
              [Element.MoveTo (sx, sy); Element.CurveTo (cx, cy, cx, cy, x, y)]
            | None ->
              [Element.MoveTo (sx, sy); Element.LineTo (x, y)]
          in
          let elem = Element.make_text_path
            ~fill:(Some Element.{ fill_color = { r = 0.0; g = 0.0; b = 0.0; a = 1.0 } })
            d "Lorem Ipsum" in
          ctx.controller#add_element elem;
          let doc = ctx.model#document in
          let li = doc.Document.selected_layer in
          let layer = doc.Document.layers.(li) in
          let ci = (match layer with
            | Element.Layer { children; _ } -> Array.length children - 1
            | _ -> 0) in
          let path = [li; ci] in
          ctx.start_text_edit path elem;
          ctx.request_update ()
        end;
        control_pt <- None
    end

  method on_double_click (ctx : Canvas_tool.tool_context) x y =
    (match ctx.hit_test_path_curve x y with
     | Some (path, elem) ->
       (match elem with
        | Element.Text_path _ ->
          ctx.controller#select_element path;
          ctx.start_text_edit path elem;
          ctx.request_update ()
        | _ -> ())
     | None -> ())

  method on_key (_ctx : Canvas_tool.tool_context) (_key : int) = false
  method activate (_ctx : Canvas_tool.tool_context) = ()
  method deactivate (ctx : Canvas_tool.tool_context) = ctx.commit_text_edit ()

  method draw_overlay (ctx : Canvas_tool.tool_context) cr =
    (* Draw drag-create preview *)
    (match drag_start, drag_end with
     | Some (sx, sy), Some (ex, ey) ->
       Cairo.set_source_rgba cr 0.4 0.4 0.4 1.0;
       Cairo.set_line_width cr 1.0;
       Cairo.set_dash cr [| 4.0; 4.0 |];
       Cairo.move_to cr sx sy;
       (match control_pt with
        | Some (cx, cy) ->
          Cairo.curve_to cr cx cy cx cy ex ey
        | None ->
          Cairo.line_to cr ex ey);
       Cairo.stroke cr;
       Cairo.set_dash cr [||]
     | _ -> ());
    (* Draw offset handle for selected TextPath elements *)
    let doc = ctx.model#document in
    Document.PathMap.iter (fun _key (es : Document.element_selection) ->
      let elem = Document.get_element doc es.es_path in
      match elem with
      | Element.Text_path { d; start_offset; _ } when d <> [] ->
        let offset = match offset_dragging, offset_drag_path, offset_preview with
          | true, Some p, Some preview when p = es.es_path -> preview
          | _ -> start_offset
        in
        let (hx, hy) = Element.path_point_at_offset d offset in
        let r = offset_handle_radius in
        (* Diamond shape *)
        Cairo.set_source_rgb cr 1.0 0.55 0.0;
        Cairo.set_line_width cr 1.5;
        Cairo.move_to cr hx (hy -. r);
        Cairo.line_to cr (hx +. r) hy;
        Cairo.line_to cr hx (hy +. r);
        Cairo.line_to cr (hx -. r) hy;
        Cairo.Path.close cr;
        Cairo.set_source_rgb cr 1.0 0.78 0.31;
        Cairo.fill_preserve cr;
        Cairo.set_source_rgb cr 1.0 0.55 0.0;
        Cairo.stroke cr
      | _ -> ()
    ) doc.Document.selection
end
