(** Tool protocol and implementations for the canvas tool system.

    Each tool implements the canvas_tool class type and receives events
    from the canvas widget. Tools own their interaction state and
    draw their overlays. The tool_context provides access to the model,
    controller, and canvas services without coupling tools to the widget. *)

(* ------------------------------------------------------------------ *)
(* Tool context                                                        *)
(* ------------------------------------------------------------------ *)

type tool_context = {
  model : Model.model;
  controller : Controller.controller;
  hit_test_selection : float -> float -> bool;
  hit_test_handle : float -> float -> (int list * int * string) option;
  hit_test_text : float -> float -> (int list * Element.element) option;
  request_update : unit -> unit;
  start_text_edit : int list -> Element.element -> unit;
  commit_text_edit : unit -> unit;
  draw_element_overlay : Cairo.context -> Element.element -> int list -> unit;
}

(* ------------------------------------------------------------------ *)
(* Tool class type                                                     *)
(* ------------------------------------------------------------------ *)

class type canvas_tool = object
  method on_press : tool_context -> float -> float -> shift:bool -> alt:bool -> unit
  method on_move : tool_context -> float -> float -> shift:bool -> dragging:bool -> unit
  method on_release : tool_context -> float -> float -> shift:bool -> alt:bool -> unit
  method on_double_click : tool_context -> float -> float -> unit
  method on_key : tool_context -> int -> bool
  method draw_overlay : tool_context -> Cairo.context -> unit
  method activate : tool_context -> unit
  method deactivate : tool_context -> unit
end

(* ------------------------------------------------------------------ *)
(* Geometry helpers                                                    *)
(* ------------------------------------------------------------------ *)

let constrain_angle sx sy ex ey =
  let dx = ex -. sx and dy = ey -. sy in
  let dist = sqrt (dx *. dx +. dy *. dy) in
  if dist = 0.0 then (ex, ey)
  else
    let angle = atan2 dy dx in
    let snapped = Float.round (angle /. (Float.pi /. 4.0)) *. (Float.pi /. 4.0) in
    (sx +. dist *. cos snapped, sy +. dist *. sin snapped)

let polygon_sides = 5

let regular_polygon_points x1 y1 x2 y2 n =
  let ex = x2 -. x1 and ey = y2 -. y1 in
  let s = sqrt (ex *. ex +. ey *. ey) in
  if s = 0.0 then List.init n (fun _ -> (x1, y1))
  else
    let mx = (x1 +. x2) /. 2.0 and my = (y1 +. y2) /. 2.0 in
    let px = -. ey /. s and py = ex /. s in
    let d = s /. (2.0 *. tan (Float.pi /. float_of_int n)) in
    let cx = mx +. d *. px and cy = my +. d *. py in
    let r = s /. (2.0 *. sin (Float.pi /. float_of_int n)) in
    let theta0 = atan2 (y1 -. cy) (x1 -. cx) in
    List.init n (fun k ->
      let angle = theta0 +. 2.0 *. Float.pi *. float_of_int k /. float_of_int n in
      (cx +. r *. cos angle, cy +. r *. sin angle))

(* ------------------------------------------------------------------ *)
(* Pen tool types                                                      *)
(* ------------------------------------------------------------------ *)

type pen_point = {
  mutable px : float;
  mutable py : float;
  mutable hx_in : float;
  mutable hy_in : float;
  mutable hx_out : float;
  mutable hy_out : float;
  mutable smooth : bool;
}

let make_pen_point x y =
  { px = x; py = y; hx_in = x; hy_in = y; hx_out = x; hy_out = y; smooth = false }

let handle_size = 6.0
let pen_close_radius = 6.0

(* ------------------------------------------------------------------ *)
(* Selection tool base                                                 *)
(* ------------------------------------------------------------------ *)

class virtual selection_tool_base = object (self)
  val mutable drag_start : (float * float) option = None
  val mutable drag_end : (float * float) option = None
  val mutable moving = false

  method virtual private select_rect : tool_context -> float -> float -> float -> float -> extend:bool -> unit
  method virtual private check_handle_hit : tool_context -> float -> float -> bool

  method on_press (ctx : tool_context) x y ~(shift : bool) ~(alt : bool) =
    ignore (shift, alt);
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

  method on_move (ctx : tool_context) x y ~shift ~(dragging : bool) =
    ignore dragging;
    match drag_start with
    | Some (sx, sy) ->
      let (cx, cy) = if shift then constrain_angle sx sy x y else (x, y) in
      drag_end <- Some (cx, cy);
      ctx.request_update ()
    | None -> ()

  method on_release (ctx : tool_context) x y ~shift ~alt =
    match drag_start with
    | None -> ()
    | Some (sx, sy) ->
      let was_moving = moving in
      drag_start <- None;
      drag_end <- None;
      moving <- false;
      if was_moving then begin
        let (ex, ey) = if shift then constrain_angle sx sy x y else (x, y) in
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

  method on_double_click (_ctx : tool_context) (_x : float) (_y : float) = ()
  method on_key (_ctx : tool_context) (_key : int) = false
  method activate (_ctx : tool_context) = ()
  method deactivate (_ctx : tool_context) = ()

  method draw_overlay (ctx : tool_context) cr =
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

  method private check_handle_hit (_ctx : tool_context) (_x : float) (_y : float) = false
  method private select_rect (ctx : tool_context) x y w h ~extend =
    ctx.controller#select_rect ~extend x y w h
end

(* ------------------------------------------------------------------ *)
(* Group selection tool                                                *)
(* ------------------------------------------------------------------ *)

class group_selection_tool = object
  inherit selection_tool_base

  method private check_handle_hit (_ctx : tool_context) (_x : float) (_y : float) = false
  method private select_rect (ctx : tool_context) x y w h ~extend =
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

  method private check_handle_hit (ctx : tool_context) x y =
    match ctx.hit_test_handle x y with
    | Some (path, anchor_idx, ht) ->
      handle_drag <- Some (path, anchor_idx, ht);
      handle_drag_start <- Some (x, y);
      handle_drag_end <- Some (x, y);
      true
    | None -> false

  method private select_rect (ctx : tool_context) x y w h ~extend =
    ctx.controller#direct_select_rect ~extend x y w h

  method! on_move (ctx : tool_context) x y ~shift ~dragging =
    if handle_drag <> None then begin
      handle_drag_end <- Some (x, y);
      ctx.request_update ()
    end else
      super#on_move ctx x y ~shift ~dragging

  method! on_release (ctx : tool_context) x y ~shift ~alt =
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

  method! draw_overlay (ctx : tool_context) cr =
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

(* ------------------------------------------------------------------ *)
(* Drawing tool base                                                   *)
(* ------------------------------------------------------------------ *)

class virtual drawing_tool_base = object (_self)
  val mutable drag_start : (float * float) option = None
  val mutable drag_end : (float * float) option = None

  method virtual private create_element : float -> float -> float -> float -> Element.element option
  method virtual private draw_preview : Cairo.context -> float -> float -> float -> float -> unit

  method on_press (_ctx : tool_context) x y ~(shift : bool) ~(alt : bool) =
    ignore (shift, alt);
    drag_start <- Some (x, y);
    drag_end <- Some (x, y)

  method on_move (ctx : tool_context) x y ~shift ~(dragging : bool) =
    ignore dragging;
    match drag_start with
    | Some (sx, sy) ->
      let (cx, cy) = if shift then constrain_angle sx sy x y else (x, y) in
      drag_end <- Some (cx, cy);
      ctx.request_update ()
    | None -> ()

  method on_release (ctx : tool_context) x y ~shift ~(alt : bool) =
    ignore alt;
    match drag_start with
    | None -> ()
    | Some (sx, sy) ->
      let (ex, ey) = if shift then constrain_angle sx sy x y else (x, y) in
      drag_start <- None;
      drag_end <- None;
      (match _self#create_element sx sy ex ey with
       | Some elem -> ctx.controller#add_element elem
       | None -> ())

  method on_double_click (_ctx : tool_context) (_x : float) (_y : float) = ()
  method on_key (_ctx : tool_context) (_key : int) = false
  method activate (_ctx : tool_context) = ()
  method deactivate (_ctx : tool_context) = ()

  method draw_overlay (_ctx : tool_context) cr =
    match drag_start, drag_end with
    | Some (sx, sy), Some (ex, ey) ->
      Cairo.set_source_rgba cr 0.4 0.4 0.4 1.0;
      Cairo.set_line_width cr 1.0;
      Cairo.set_dash cr [| 4.0; 4.0 |];
      _self#draw_preview cr sx sy ex ey;
      Cairo.stroke cr;
      Cairo.set_dash cr [||]
    | _ -> ()
end

(* ------------------------------------------------------------------ *)
(* Line tool                                                           *)
(* ------------------------------------------------------------------ *)

let default_stroke = Some Element.{
  stroke_color = { r = 0.0; g = 0.0; b = 0.0; a = 1.0 };
  stroke_width = 1.0;
  stroke_linecap = Butt;
  stroke_linejoin = Miter;
}

class line_tool = object
  inherit drawing_tool_base

  method private create_element sx sy ex ey =
    Some (Element.Line {
      x1 = sx; y1 = sy; x2 = ex; y2 = ey;
      stroke = default_stroke;
      opacity = 1.0; transform = None;
    })

  method private draw_preview cr sx sy ex ey =
    Cairo.move_to cr sx sy;
    Cairo.line_to cr ex ey
end

(* ------------------------------------------------------------------ *)
(* Rect tool                                                           *)
(* ------------------------------------------------------------------ *)

class rect_tool = object
  inherit drawing_tool_base

  method private create_element sx sy ex ey =
    Some (Element.Rect {
      x = min sx ex; y = min sy ey;
      width = abs_float (ex -. sx); height = abs_float (ey -. sy);
      rx = 0.0; ry = 0.0;
      fill = None; stroke = default_stroke;
      opacity = 1.0; transform = None;
    })

  method private draw_preview cr sx sy ex ey =
    let rx = min sx ex and ry = min sy ey in
    let rw = abs_float (ex -. sx) and rh = abs_float (ey -. sy) in
    Cairo.rectangle cr rx ry ~w:rw ~h:rh
end

(* ------------------------------------------------------------------ *)
(* Polygon tool                                                        *)
(* ------------------------------------------------------------------ *)

class polygon_tool = object
  inherit drawing_tool_base

  method private create_element sx sy ex ey =
    let pts = regular_polygon_points sx sy ex ey polygon_sides in
    Some (Element.Polygon {
      points = pts;
      fill = None; stroke = default_stroke;
      opacity = 1.0; transform = None;
    })

  method private draw_preview cr sx sy ex ey =
    let pts = regular_polygon_points sx sy ex ey polygon_sides in
    match pts with
    | (fx, fy) :: rest ->
      Cairo.move_to cr fx fy;
      List.iter (fun (px, py) -> Cairo.line_to cr px py) rest;
      Cairo.Path.close cr
    | [] -> ()
end

(* ------------------------------------------------------------------ *)
(* Pen tool                                                            *)
(* ------------------------------------------------------------------ *)

class pen_tool = object (self)
  val mutable points : pen_point list = []
  val mutable pen_dragging = false
  val mutable mouse_x = 0.0
  val mutable mouse_y = 0.0

  method private finish (ctx : tool_context) ?(close = false) () =
    let pts = List.rev points in
    let n = List.length pts in
    if n >= 2 then begin
      let p0 = List.hd pts in
      let pn = List.nth pts (n - 1) in
      let dist = sqrt ((pn.px -. p0.px) ** 2.0 +. (pn.py -. p0.py) ** 2.0) in
      let do_close = close || (n >= 3 && dist <= pen_close_radius) in
      let skip_last = do_close && n >= 3 && dist <= pen_close_radius in
      let use_pts = if skip_last then List.filteri (fun i _ -> i < n - 1) pts else pts in
      let rest = List.tl use_pts in
      let cmds = ref [Element.MoveTo (p0.px, p0.py)] in
      let prev = ref p0 in
      List.iter (fun curr ->
        cmds := Element.CurveTo (!prev.hx_out, !prev.hy_out,
                                 curr.hx_in, curr.hy_in,
                                 curr.px, curr.py) :: !cmds;
        prev := curr
      ) rest;
      if do_close then begin
        let last = !prev in
        cmds := Element.ClosePath :: Element.CurveTo (last.hx_out, last.hy_out,
                                 p0.hx_in, p0.hy_in,
                                 p0.px, p0.py) :: !cmds
      end;
      let elem = Element.make_path ~stroke:default_stroke (List.rev !cmds) in
      ctx.controller#add_element elem
    end;
    points <- [];
    pen_dragging <- false;
    ctx.request_update ()

  method on_press (ctx : tool_context) x y ~(shift : bool) ~(alt : bool) =
    ignore (shift, alt);
    let pts = List.rev points in
    let n = List.length pts in
    if n >= 2 then begin
      let p0 = List.hd pts in
      let dist = sqrt ((x -. p0.px) ** 2.0 +. (y -. p0.py) ** 2.0) in
      if dist <= pen_close_radius then begin
        self#finish ctx ~close:true ();
      end else begin
        pen_dragging <- true;
        points <- (make_pen_point x y) :: points;
        ctx.request_update ()
      end
    end else begin
      pen_dragging <- true;
      points <- (make_pen_point x y) :: points;
      ctx.request_update ()
    end

  method on_move (ctx : tool_context) x y ~(shift : bool) ~(dragging : bool) =
    ignore (shift, dragging);
    mouse_x <- x;
    mouse_y <- y;
    if pen_dragging then begin
      match points with
      | pt :: _ ->
        pt.hx_out <- x;
        pt.hy_out <- y;
        pt.hx_in <- 2.0 *. pt.px -. x;
        pt.hy_in <- 2.0 *. pt.py -. y;
        pt.smooth <- true
      | [] -> ()
    end;
    ctx.request_update ()

  method on_release (ctx : tool_context) (_x : float) (_y : float) ~(shift : bool) ~(alt : bool) =
    ignore (shift, alt);
    pen_dragging <- false;
    ctx.request_update ()

  method on_double_click (ctx : tool_context) (_x : float) (_y : float) =
    (match points with _ :: rest -> points <- rest | [] -> ());
    self#finish ctx ()

  method on_key (ctx : tool_context) (_key : int) =
    (* Escape, Return, Enter → finish; handled by key codes *)
    if points <> [] then begin
      self#finish ctx ();
      true
    end else
      false

  method activate (_ctx : tool_context) = ()

  method deactivate (ctx : tool_context) =
    if points <> [] then
      self#finish ctx ()

  method draw_overlay (_ctx : tool_context) cr =
    let pts = List.rev points in
    if pts = [] then ()
    else begin
      (* Draw committed curve segments *)
      if List.length pts >= 2 then begin
        Cairo.set_source_rgb cr 0.0 0.0 0.0;
        Cairo.set_line_width cr 1.0;
        let p0 = List.hd pts in
        Cairo.move_to cr p0.px p0.py;
        let prev = ref p0 in
        List.iter (fun curr ->
          Cairo.curve_to cr !prev.hx_out !prev.hy_out
            curr.hx_in curr.hy_in curr.px curr.py;
          prev := curr
        ) (List.tl pts);
        Cairo.stroke cr
      end;
      (* Draw preview curve from last point to mouse *)
      if not pen_dragging then begin
        let last = List.hd points in  (* points is reversed, head is last *)
        let p0 = List.hd pts in
        let n = List.length pts in
        let dist = sqrt ((mouse_x -. p0.px) ** 2.0 +. (mouse_y -. p0.py) ** 2.0) in
        let near_start = n >= 2 && dist <= pen_close_radius in
        Cairo.set_source_rgba cr 0.4 0.4 0.4 1.0;
        Cairo.set_line_width cr 1.0;
        Cairo.set_dash cr [| 4.0; 4.0 |];
        Cairo.move_to cr last.px last.py;
        if near_start then
          Cairo.curve_to cr last.hx_out last.hy_out
            p0.hx_in p0.hy_in p0.px p0.py
        else
          Cairo.curve_to cr last.hx_out last.hy_out
            mouse_x mouse_y mouse_x mouse_y;
        Cairo.stroke cr;
        Cairo.set_dash cr [||]
      end;
      (* Draw handle lines and anchor points *)
      let half = handle_size /. 2.0 in
      List.iter (fun pt ->
        if pt.smooth then begin
          Cairo.set_source_rgb cr 0.0 0.47 1.0;
          Cairo.set_line_width cr 1.0;
          Cairo.move_to cr pt.hx_in pt.hy_in;
          Cairo.line_to cr pt.hx_out pt.hy_out;
          Cairo.stroke cr;
          (* Handle circles *)
          Cairo.arc cr pt.hx_in pt.hy_in ~r:3.0 ~a1:0.0 ~a2:(2.0 *. Float.pi);
          Cairo.set_source_rgb cr 1.0 1.0 1.0;
          Cairo.fill_preserve cr;
          Cairo.set_source_rgb cr 0.0 0.47 1.0;
          Cairo.stroke cr;
          Cairo.arc cr pt.hx_out pt.hy_out ~r:3.0 ~a1:0.0 ~a2:(2.0 *. Float.pi);
          Cairo.set_source_rgb cr 1.0 1.0 1.0;
          Cairo.fill_preserve cr;
          Cairo.set_source_rgb cr 0.0 0.47 1.0;
          Cairo.stroke cr
        end;
        (* Anchor square *)
        Cairo.rectangle cr (pt.px -. half) (pt.py -. half) ~w:handle_size ~h:handle_size;
        Cairo.set_source_rgb cr 0.0 0.47 1.0;
        Cairo.fill_preserve cr;
        Cairo.stroke cr
      ) pts
    end
end

(* ------------------------------------------------------------------ *)
(* Text tool                                                           *)
(* ------------------------------------------------------------------ *)

class text_tool = object (_self)
  val mutable drag_start : (float * float) option = None
  val mutable drag_end : (float * float) option = None

  method on_press (_ctx : tool_context) x y ~(shift : bool) ~(alt : bool) =
    ignore (shift, alt);
    drag_start <- Some (x, y);
    drag_end <- Some (x, y)

  method on_move (ctx : tool_context) x y ~(shift : bool) ~(dragging : bool) =
    ignore (shift, dragging);
    if drag_start <> None then begin
      drag_end <- Some (x, y);
      ctx.request_update ()
    end

  method on_release (ctx : tool_context) x y ~(shift : bool) ~(alt : bool) =
    ignore (shift, alt);
    match drag_start with
    | None -> ()
    | Some (sx, sy) ->
      drag_start <- None;
      drag_end <- None;
      let w = abs_float (x -. sx) and h = abs_float (y -. sy) in
      if w > 4.0 || h > 4.0 then begin
        let tx = min sx x and ty = min sy y in
        let elem = Element.make_text ~text_width:w ~text_height:h
          ~fill:(Some Element.{
            fill_color = { r = 0.0; g = 0.0; b = 0.0; a = 1.0 }
          }) tx ty "Lorem Ipsum" in
        ctx.controller#add_element elem
      end else begin
        match ctx.hit_test_text sx sy with
        | Some (path, text_elem) ->
          ctx.start_text_edit path text_elem
        | None ->
          let elem = Element.make_text ~fill:(Some Element.{
            fill_color = { r = 0.0; g = 0.0; b = 0.0; a = 1.0 }
          }) sx sy "Lorem Ipsum" in
          ctx.controller#add_element elem
      end

  method on_double_click (_ctx : tool_context) (_x : float) (_y : float) = ()
  method on_key (_ctx : tool_context) (_key : int) = false
  method activate (_ctx : tool_context) = ()

  method deactivate (ctx : tool_context) =
    ctx.commit_text_edit ()

  method draw_overlay (_ctx : tool_context) cr =
    match drag_start, drag_end with
    | Some (sx, sy), Some (ex, ey) ->
      Cairo.set_source_rgba cr 0.4 0.4 0.4 1.0;
      Cairo.set_line_width cr 1.0;
      Cairo.set_dash cr [| 4.0; 4.0 |];
      let rx = min sx ex and ry = min sy ey in
      let rw = abs_float (ex -. sx) and rh = abs_float (ey -. sy) in
      Cairo.rectangle cr rx ry ~w:rw ~h:rh;
      Cairo.stroke cr;
      Cairo.set_dash cr [||]
    | _ -> ()
end

(* ------------------------------------------------------------------ *)
(* Tool factory                                                        *)
(* ------------------------------------------------------------------ *)

let create_tool (tool : Toolbar.tool) : canvas_tool =
  match tool with
  | Toolbar.Selection -> (new selection_tool :> canvas_tool)
  | Toolbar.Direct_selection -> (new direct_selection_tool :> canvas_tool)
  | Toolbar.Group_selection -> (new group_selection_tool :> canvas_tool)
  | Toolbar.Line -> (new line_tool :> canvas_tool)
  | Toolbar.Rect -> (new rect_tool :> canvas_tool)
  | Toolbar.Polygon -> (new polygon_tool :> canvas_tool)
  | Toolbar.Pen -> (new pen_tool :> canvas_tool)
  | Toolbar.Text_tool -> (new text_tool :> canvas_tool)
