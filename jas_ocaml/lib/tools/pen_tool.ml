(** Pen tool for creating Bezier paths. *)

type pen_state = PenIdle | PenPlacing | PenDragging

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

let handle_size = Canvas_tool.handle_draw_size
let pen_close_radius = Canvas_tool.hit_radius

class pen_tool = object (self)
  val mutable points : pen_point list = []
  val mutable pen_state : pen_state = PenIdle
  val mutable mouse_x = 0.0
  val mutable mouse_y = 0.0

  method private finish (ctx : Canvas_tool.tool_context) ?(close = false) () =
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
      let elem = Element.make_path ~stroke:Canvas_tool.default_stroke (List.rev !cmds) in
      ctx.controller#add_element elem
    end;
    points <- [];
    pen_state <- PenIdle;
    ctx.request_update ()

  method on_press (ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(alt : bool) =
    ignore (shift, alt);
    ctx.model#snapshot;
    let pts = List.rev points in
    let n = List.length pts in
    if n >= 2 then begin
      let p0 = List.hd pts in
      let dist = sqrt ((x -. p0.px) ** 2.0 +. (y -. p0.py) ** 2.0) in
      if dist <= pen_close_radius then begin
        self#finish ctx ~close:true ();
      end else begin
        pen_state <- PenDragging;
        points <- (make_pen_point x y) :: points;
        ctx.request_update ()
      end
    end else begin
      pen_state <- PenDragging;
      points <- (make_pen_point x y) :: points;
      ctx.request_update ()
    end

  method on_move (ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(dragging : bool) =
    ignore (shift, dragging);
    mouse_x <- x;
    mouse_y <- y;
    if pen_state = PenDragging then begin
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

  method on_release (ctx : Canvas_tool.tool_context) (_x : float) (_y : float) ~(shift : bool) ~(alt : bool) =
    ignore (shift, alt);
    (if pen_state = PenDragging then pen_state <- PenPlacing);
    ctx.request_update ()

  method on_double_click (ctx : Canvas_tool.tool_context) (_x : float) (_y : float) =
    (match points with _ :: rest -> points <- rest | [] -> ());
    self#finish ctx ()

  method on_key (ctx : Canvas_tool.tool_context) (_key : int) =
    if points <> [] then begin
      self#finish ctx ();
      true
    end else
      false

  method on_key_release (_ctx : Canvas_tool.tool_context) (_key : int) = false

  method activate (_ctx : Canvas_tool.tool_context) = ()

  method deactivate (ctx : Canvas_tool.tool_context) =
    if points <> [] then
      self#finish ctx ()

  method draw_overlay (_ctx : Canvas_tool.tool_context) cr =
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
      if pen_state <> PenDragging then begin
        let last = List.hd points in
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
        Cairo.rectangle cr (pt.px -. half) (pt.py -. half) ~w:handle_size ~h:handle_size;
        Cairo.set_source_rgb cr 0.0 0.47 1.0;
        Cairo.fill_preserve cr;
        Cairo.stroke cr
      ) pts
    end
end
