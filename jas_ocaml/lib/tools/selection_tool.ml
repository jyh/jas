(** Selection tools: selection, group selection, direct selection. *)

(* ------------------------------------------------------------------ *)
(* Selection tool base                                                 *)
(* ------------------------------------------------------------------ *)

class virtual selection_tool_base = object (self)
  val mutable drag_start : (float * float) option = None
  val mutable drag_end : (float * float) option = None
  val mutable moving = false

  method virtual private select_rect : Canvas_tool.tool_context -> float -> float -> float -> float -> extend:bool -> unit
  method virtual private check_handle_hit : Canvas_tool.tool_context -> float -> float -> bool

  method on_press (ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(alt : bool) =
    ignore (shift, alt);
    ctx.model#snapshot;
    if self#check_handle_hit ctx x y then ()
    else if ctx.hit_test_selection x y then begin
      drag_start <- Some (x, y);
      drag_end <- Some (x, y);
      moving <- true
    end else begin
      drag_start <- Some (x, y);
      drag_end <- Some (x, y);
      moving <- false
    end

  method on_move (ctx : Canvas_tool.tool_context) x y ~shift ~(dragging : bool) =
    ignore dragging;
    match drag_start with
    | Some (sx, sy) ->
      let (cx, cy) = if shift then Canvas_tool.constrain_angle sx sy x y else (x, y) in
      drag_end <- Some (cx, cy);
      ctx.request_update ()
    | None -> ()

  method on_release (ctx : Canvas_tool.tool_context) x y ~shift ~alt =
    match drag_start with
    | None -> ()
    | Some (sx, sy) ->
      let was_moving = moving in
      drag_start <- None;
      drag_end <- None;
      moving <- false;
      if was_moving then begin
        let (ex, ey) = if shift then Canvas_tool.constrain_angle sx sy x y else (x, y) in
        let dx = ex -. sx and dy = ey -. sy in
        if dx <> 0.0 || dy <> 0.0 then begin
          if alt then ctx.controller#copy_selection dx dy
          else ctx.controller#move_selection dx dy
        end;
        ctx.request_update ()
      end else begin
        let rx = min sx x and ry = min sy y in
        let rw = abs_float (x -. sx) and rh = abs_float (y -. sy) in
        self#select_rect ctx rx ry rw rh ~extend:shift
      end

  method on_double_click (_ctx : Canvas_tool.tool_context) (_x : float) (_y : float) = ()
  method on_key (_ctx : Canvas_tool.tool_context) (_key : int) = false
  method activate (_ctx : Canvas_tool.tool_context) = ()
  method deactivate (_ctx : Canvas_tool.tool_context) = ()

  method draw_overlay (ctx : Canvas_tool.tool_context) cr =
    match drag_start, drag_end with
    | Some (sx, sy), Some (ex, ey) ->
      if moving then begin
        let dx = ex -. sx and dy = ey -. sy in
        Cairo.set_source_rgb cr 0.0 0.47 1.0;
        Cairo.set_line_width cr 1.0;
        Cairo.set_dash cr [| 4.0; 4.0 |];
        Document.PathMap.iter (fun _path (es : Document.element_selection) ->
          let elem = Document.get_element ctx.model#document es.es_path in
          let moved = Element.move_control_points elem es.es_control_points dx dy in
          ctx.draw_element_overlay cr moved es.es_control_points
        ) ctx.model#document.Document.selection;
        Cairo.set_dash cr [||]
      end else begin
        Cairo.set_source_rgba cr 0.4 0.4 0.4 1.0;
        Cairo.set_line_width cr 1.0;
        Cairo.set_dash cr [| 4.0; 4.0 |];
        let rx = min sx ex and ry = min sy ey in
        let rw = abs_float (ex -. sx) and rh = abs_float (ey -. sy) in
        Cairo.rectangle cr rx ry ~w:rw ~h:rh;
        Cairo.stroke cr;
        Cairo.set_dash cr [||]
      end
    | _ -> ()
end

(* ------------------------------------------------------------------ *)
(* Selection tool                                                      *)
(* ------------------------------------------------------------------ *)

class selection_tool = object
  inherit selection_tool_base

  method private check_handle_hit (_ctx : Canvas_tool.tool_context) (_x : float) (_y : float) = false
  method private select_rect (ctx : Canvas_tool.tool_context) x y w h ~extend =
    ctx.controller#select_rect ~extend x y w h
end

(* ------------------------------------------------------------------ *)
(* Group selection tool                                                *)
(* ------------------------------------------------------------------ *)

class group_selection_tool = object
  inherit selection_tool_base

  method private check_handle_hit (_ctx : Canvas_tool.tool_context) (_x : float) (_y : float) = false
  method private select_rect (ctx : Canvas_tool.tool_context) x y w h ~extend =
    ctx.controller#group_select_rect ~extend x y w h
end

(* ------------------------------------------------------------------ *)
(* Direct selection tool                                               *)
(* ------------------------------------------------------------------ *)

class direct_selection_tool = object (self)
  inherit selection_tool_base as super

  val mutable handle_drag : (int list * int * string) option = None
  val mutable handle_drag_start : (float * float) option = None
  val mutable handle_drag_end : (float * float) option = None

  method private check_handle_hit (ctx : Canvas_tool.tool_context) x y =
    match ctx.hit_test_handle x y with
    | Some (path, anchor_idx, ht) ->
      handle_drag <- Some (path, anchor_idx, ht);
      handle_drag_start <- Some (x, y);
      handle_drag_end <- Some (x, y);
      true
    | None -> false

  method private select_rect (ctx : Canvas_tool.tool_context) x y w h ~extend =
    ctx.controller#direct_select_rect ~extend x y w h

  method! on_move (ctx : Canvas_tool.tool_context) x y ~shift ~dragging =
    if handle_drag <> None then begin
      handle_drag_end <- Some (x, y);
      ctx.request_update ()
    end else
      super#on_move ctx x y ~shift ~dragging

  method! on_release (ctx : Canvas_tool.tool_context) x y ~shift ~alt =
    match handle_drag, handle_drag_start with
    | Some (path, anchor_idx, ht), Some (sx, sy) ->
      let dx = x -. sx and dy = y -. sy in
      handle_drag <- None;
      handle_drag_start <- None;
      handle_drag_end <- None;
      if dx <> 0.0 || dy <> 0.0 then
        ctx.controller#move_path_handle path anchor_idx ht dx dy;
      ctx.request_update ()
    | _ ->
      ignore (self : #selection_tool_base);
      super#on_release ctx x y ~shift ~alt

  method! draw_overlay (ctx : Canvas_tool.tool_context) cr =
    (match handle_drag, handle_drag_start, handle_drag_end with
     | Some (path, anchor_idx, ht), Some (sx, sy), Some (ex, ey) ->
       let dx = ex -. sx and dy = ey -. sy in
       let elem = Document.get_element ctx.model#document path in
       (match elem with
        | Element.Path ({ d; _ } as r) ->
          let new_d = Element.move_path_handle d anchor_idx ht dx dy in
          let moved = Element.Path { r with d = new_d } in
          let es_opt = Document.PathMap.find_opt path ctx.model#document.Document.selection in
          (match es_opt with
           | Some es ->
             Cairo.set_source_rgb cr 0.0 0.47 1.0;
             Cairo.set_line_width cr 1.0;
             Cairo.set_dash cr [| 4.0; 4.0 |];
             ctx.draw_element_overlay cr moved es.es_control_points;
             Cairo.set_dash cr [||]
           | None -> ())
        | _ -> ())
     | _ -> ());
    super#draw_overlay ctx cr
end
