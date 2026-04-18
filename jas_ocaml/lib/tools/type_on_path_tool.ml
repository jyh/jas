(** Type-on-path tool with native in-place text editing.

    Click on a Path to convert it to a Text_path and start editing; click
    on an existing Text_path to edit; drag to create a new Text_path along
    a curve; drag the orange diamond to reposition the start offset. While
    editing, mouse drag extends the selection and standard editing keys
    are routed via [on_key_event]. *)

let offset_handle_radius = 5.0
let blink_half_period_ms = 530.0

let now_ms () = Unix.gettimeofday () *. 1000.0

let cursor_visible epoch_ms =
  let elapsed = max 0.0 (now_ms () -. epoch_ms) in
  let phase = int_of_float (elapsed /. blink_half_period_ms) in
  phase mod 2 = 0

let make_measure font_family font_weight font_style font_size =
  try
    let surf = Cairo.Image.create Cairo.Image.ARGB32 ~w:1 ~h:1 in
    let cr = Cairo.create surf in
    let slant = if font_style = "italic" || font_style = "oblique" then Cairo.Italic else Cairo.Upright in
    let weight = if font_weight = "bold" then Cairo.Bold else Cairo.Normal in
    Cairo.select_font_face cr font_family ~slant ~weight;
    Cairo.set_font_size cr font_size;
    fun s ->
      if s = "" then 0.0
      else (Cairo.text_extents cr s).Cairo.x_advance
  with _ ->
    fun s -> float_of_int (String.length s) *. font_size *. 0.55

let stub_measure font_size s =
  float_of_int (String.length s) *. font_size *. 0.55

(* Build a path_text layout for the currently-edited Text_path element. *)
type path_render = {
  pr_d : Element.path_command list;
  pr_start_offset : float;
  pr_font_size : float;
  pr_fill : Element.fill option;
  pr_stroke : Element.stroke option;
}

class type_on_path_tool = object (_self)
  inherit Canvas_tool.default_methods
  val mutable drag_start : (float * float) option = None
  val mutable drag_end : (float * float) option = None
  val mutable control_pt : (float * float) option = None
  (* Offset handle drag state *)
  val mutable offset_dragging = false
  val mutable offset_drag_path : int list option = None
  val mutable offset_preview : float option = None
  (* Editing session *)
  val mutable session : Text_edit.t option = None
  val mutable did_snapshot : bool = false

  method private build_layout (ctx : Canvas_tool.tool_context) =
    match session with
    | None -> None
    | Some s ->
      if Text_edit.target s <> Text_edit.Edit_text_path then None
      else
        try
          let elem = Document.get_element ctx.model#document (Text_edit.path s) in
          match elem with
          | Element.Text_path { d; start_offset; font_size; font_family; font_weight; font_style; fill; stroke; _ } ->
            let measure = make_measure font_family font_weight font_style font_size in
            let content = Text_edit.content s in
            let lay = Path_text_layout.layout d content start_offset font_size measure in
            let pr = { pr_d = d; pr_start_offset = start_offset;
                       pr_font_size = font_size; pr_fill = fill; pr_stroke = stroke } in
            Some (pr, lay)
          | _ -> None
        with _ -> None

  method private cursor_at ctx x y =
    match _self#build_layout ctx with
    | None -> 0
    | Some (_, lay) -> Path_text_layout.hit_test lay x y

  method private ensure_snapshot (ctx : Canvas_tool.tool_context) =
    if not did_snapshot then begin
      ctx.model#snapshot;
      did_snapshot <- true
    end

  method private sync_to_model (ctx : Canvas_tool.tool_context) =
    match session with
    | None -> ()
    | Some s ->
      match Text_edit.apply_to_document s ctx.model#document with
      | Some new_doc -> ctx.controller#set_document new_doc
      | None -> ()

  method private current_element_tspans (ctx : Canvas_tool.tool_context) =
    match session with
    | None -> [||]
    | Some s ->
      try
        match Document.get_element ctx.model#document (Text_edit.path s) with
        | Element.Text { tspans; _ } -> tspans
        | Element.Text_path { tspans; _ } -> tspans
        | _ -> [||]
      with _ -> [||]

  method private replace_element_tspans
      (ctx : Canvas_tool.tool_context) path new_tspans =
    try
      let elem = Document.get_element ctx.model#document path in
      let new_elem = match elem with
        | Element.Text r -> Some (Element.Text { r with tspans = new_tspans })
        | Element.Text_path r -> Some (Element.Text_path { r with tspans = new_tspans })
        | _ -> None
      in
      match new_elem with
      | Some e ->
        let new_doc = Document.replace_element ctx.model#document path e in
        ctx.controller#set_document new_doc
      | None -> ()
    with _ -> ()

  method private begin_session_existing
      (ctx : Canvas_tool.tool_context) path elem cursor =
    let content = match elem with
      | Element.Text_path { content; _ } -> content
      | _ -> ""
    in
    let s = Text_edit.create
      ~path ~target:Text_edit.Edit_text_path ~content ~insertion:cursor in
    Text_edit.set_blink_epoch_ms s (now_ms ());
    session <- Some s;
    did_snapshot <- false;
    ctx.controller#select_element path

  method private end_session () =
    session <- None;
    did_snapshot <- false;
    drag_start <- None;
    drag_end <- None;
    control_pt <- None

  (* Find if (x,y) is near the start-offset handle of a selected TextPath *)
  method private find_selected_textpath_handle (ctx : Canvas_tool.tool_context) x y =
    let doc = ctx.model#document in
    let r = offset_handle_radius +. 2.0 in
    let result = ref None in
    Document.PathMap.iter (fun _key (es : Document.element_selection) ->
      if !result = None then begin
        try
          let elem = Document.get_element doc es.es_path in
          match elem with
          | Element.Text_path { d; start_offset; _ } when d <> [] ->
            let (hx, hy) = Element.path_point_at_offset d start_offset in
            if abs_float (x -. hx) <= r && abs_float (y -. hy) <= r then
              result := Some (es.es_path, elem)
          | _ -> ()
        with _ -> ()
      end
    ) doc.Document.selection;
    !result

  method on_press (ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(alt : bool) =
    ignore (shift, alt);
    (* 1) If editing, check whether the click stays on the edited path *)
    (match session with
     | Some s ->
       let edited_path = Text_edit.path s in
       (match ctx.hit_test_path_curve x y with
        | Some (path, _) when path = edited_path ->
          let cursor = _self#cursor_at ctx x y in
          Text_edit.set_insertion s cursor ~extend:false;
          Text_edit.set_drag_active s true;
          Text_edit.set_blink_epoch_ms s (now_ms ());
          ctx.request_update ()
        | _ ->
          _self#end_session ();
          _self#begin_press_no_session ctx x y)
     | None -> _self#begin_press_no_session ctx x y)

  method private begin_press_no_session (ctx : Canvas_tool.tool_context) x y =
    (* 2) Offset handle drag *)
    (match _self#find_selected_textpath_handle ctx x y with
     | Some (path, _elem) ->
       offset_dragging <- true;
       offset_drag_path <- Some path;
       offset_preview <- None
     | None ->
       (* 3) Hit-test for existing Path or Text_path *)
       (match ctx.hit_test_path_curve x y with
        | Some (path, elem) ->
          (match elem with
           | Element.Text_path _ ->
             _self#begin_session_existing ctx path elem 0;
             (match session with
              | Some s ->
                let cursor = _self#cursor_at ctx x y in
                Text_edit.set_insertion s cursor ~extend:false;
                Text_edit.set_drag_active s true;
                Text_edit.set_blink_epoch_ms s (now_ms ());
                ctx.request_update ()
              | None -> ())
           | Element.Path { d; _ } ->
             ctx.model#snapshot;
             did_snapshot <- true;
             let start_off = Element.path_closest_offset d x y in
             let tp = Element.make_text_path
               ~start_offset:start_off
               ~fill:(Some Element.{ fill_color = Rgb { r = 0.0; g = 0.0; b = 0.0; a = 1.0 }; fill_opacity = 1.0 })
               d "" in
             let new_doc = Document.replace_element ctx.model#document path tp in
             ctx.controller#set_document new_doc;
             ctx.controller#select_element path;
             let s = Text_edit.create
               ~path ~target:Text_edit.Edit_text_path ~content:"" ~insertion:0 in
             Text_edit.set_blink_epoch_ms s (now_ms ());
             session <- Some s;
             ctx.request_update ()
           | _ -> ())
        | None ->
          (* 4) Start drag-create *)
          drag_start <- Some (x, y);
          drag_end <- Some (x, y);
          control_pt <- None))

  method on_move (ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(dragging : bool) =
    ignore shift;
    (* If editing and drag_active, extend cursor *)
    (match session with
     | Some s when Text_edit.drag_active s && dragging ->
       let cursor = _self#cursor_at ctx x y in
       Text_edit.set_insertion s cursor ~extend:true;
       Text_edit.set_blink_epoch_ms s (now_ms ());
       ctx.request_update ()
     | _ ->
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
         | None -> ())

  method on_release (ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(alt : bool) =
    ignore (shift, alt);
    (* If editing, finish drag selection *)
    (match session with
     | Some s when Text_edit.drag_active s ->
       Text_edit.set_drag_active s false;
       Text_edit.set_blink_epoch_ms s (now_ms ());
       ctx.request_update ()
     | _ ->
       if offset_dragging then begin
         (match offset_drag_path, offset_preview with
          | Some path, Some new_offset ->
            let doc = ctx.model#document in
            (try
              ctx.model#snapshot;
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
           if w <= Canvas_tool.drag_threshold && h <= Canvas_tool.drag_threshold then
             control_pt <- None
           else begin
             ctx.model#snapshot;
             did_snapshot <- true;
             let d = match control_pt with
               | Some (cx, cy) ->
                 [Element.MoveTo (sx, sy); Element.CurveTo (cx, cy, cx, cy, x, y)]
               | None ->
                 [Element.MoveTo (sx, sy); Element.LineTo (x, y)]
             in
             let elem = Element.make_text_path
               ~fill:(Some Element.{ fill_color = Rgb { r = 0.0; g = 0.0; b = 0.0; a = 1.0 }; fill_opacity = 1.0 })
               d "" in
             ctx.controller#add_element elem;
             let doc = ctx.model#document in
             let li = doc.Document.selected_layer in
             if li >= 0 && li < Array.length doc.Document.layers then begin
               let layer = doc.Document.layers.(li) in
               let ci = (match layer with
                 | Element.Layer { children; _ } -> Array.length children - 1
                 | _ -> 0) in
               let path = [li; ci] in
               ctx.controller#select_element path;
               let s = Text_edit.create
                 ~path ~target:Text_edit.Edit_text_path ~content:"" ~insertion:0 in
               Text_edit.set_blink_epoch_ms s (now_ms ());
               session <- Some s
             end;
             control_pt <- None;
             ctx.request_update ()
           end
       end)

  method on_double_click (ctx : Canvas_tool.tool_context) (_x : float) (_y : float) =
    match session with
    | None -> ()
    | Some s ->
      Text_edit.select_all s;
      Text_edit.set_blink_epoch_ms s (now_ms ());
      ctx.request_update ()

  method on_key (_ctx : Canvas_tool.tool_context) (_key : int) = false
  method on_key_release (_ctx : Canvas_tool.tool_context) (_key : int) = false
  method activate (_ctx : Canvas_tool.tool_context) = ()
  method deactivate (_ctx : Canvas_tool.tool_context) = _self#end_session ()

  method! captures_keyboard () = session <> None
  method! is_editing () = session <> None

  method! cursor_css_override () =
    if session <> None then Some "ibeam" else None

  method! paste_text (ctx : Canvas_tool.tool_context) text =
    match session with
    | None -> false
    | Some s ->
      let elem_tspans = _self#current_element_tspans ctx in
      (match Text_edit.try_paste_tspans s elem_tspans text with
       | Some new_tspans ->
         _self#ensure_snapshot ctx;
         _self#replace_element_tspans ctx (Text_edit.path s) new_tspans;
         let new_content = Tspan.concat_content new_tspans in
         let caret = Text_edit.insertion s + Text_layout.utf8_char_count text in
         Text_edit.set_content s new_content ~insertion:caret ~anchor:caret;
         Text_edit.set_blink_epoch_ms s (now_ms ());
         ctx.request_update ();
         true
       | None ->
         _self#ensure_snapshot ctx;
         Text_edit.insert s text;
         Text_edit.set_blink_epoch_ms s (now_ms ());
         _self#sync_to_model ctx;
         ctx.request_update ();
         true)

  method! on_key_event (ctx : Canvas_tool.tool_context) key (mods : Canvas_tool.key_mods) =
    match session with
    | None -> false
    | Some s ->
      let bump () = Text_edit.set_blink_epoch_ms s (now_ms ()) in
      let cmd = Canvas_tool.key_mods_cmd mods in
      if cmd && (key = "a" || key = "A") then begin
        Text_edit.select_all s; bump (); ctx.request_update (); true
      end else if cmd && (key = "z" || key = "Z") then begin
        if mods.shift then Text_edit.redo s else Text_edit.undo s;
        bump (); _self#sync_to_model ctx; ctx.request_update (); true
      end else if cmd && (key = "c" || key = "C") then begin
        let elem_tspans = _self#current_element_tspans ctx in
        ignore (Text_edit.copy_selection_with_tspans s elem_tspans);
        true
      end else if cmd && (key = "x" || key = "X") then begin
        let elem_tspans = _self#current_element_tspans ctx in
        (match Text_edit.copy_selection_with_tspans s elem_tspans with
         | Some _ ->
           _self#ensure_snapshot ctx;
           Text_edit.backspace s;
           bump (); _self#sync_to_model ctx; ctx.request_update ()
         | None -> ());
        true
      end else if key = "Escape" then begin
        _self#end_session (); ctx.request_update (); true
      end else if key = "Backspace" then begin
        _self#ensure_snapshot ctx;
        Text_edit.backspace s;
        bump (); _self#sync_to_model ctx; ctx.request_update (); true
      end else if key = "Delete" then begin
        _self#ensure_snapshot ctx;
        Text_edit.delete_forward s;
        bump (); _self#sync_to_model ctx; ctx.request_update (); true
      end else if key = "ArrowLeft" then begin
        Text_edit.set_insertion s (max 0 (Text_edit.insertion s - 1)) ~extend:mods.shift;
        bump (); ctx.request_update (); true
      end else if key = "ArrowRight" then begin
        Text_edit.set_insertion s (Text_edit.insertion s + 1) ~extend:mods.shift;
        bump (); ctx.request_update (); true
      end else if key = "Home" then begin
        Text_edit.set_insertion s 0 ~extend:mods.shift;
        bump (); ctx.request_update (); true
      end else if key = "End" then begin
        Text_edit.set_insertion s (String.length (Text_edit.content s)) ~extend:mods.shift;
        bump (); ctx.request_update (); true
      end else if String.length key = 1 && not cmd then begin
        _self#ensure_snapshot ctx;
        Text_edit.insert s key;
        bump (); _self#sync_to_model ctx; ctx.request_update (); true
      end else false

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
      try
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
      with _ -> ()
    ) doc.Document.selection;
    (* Editing overlay: caret + selection *)
    (match _self#build_layout ctx with
     | None -> ()
     | Some (pr, lay) ->
       let s = match session with Some s -> s | None -> assert false in
       (* Selection: highlight glyphs in [lo, hi) *)
       if Text_edit.has_selection s then begin
         let (lo, hi) = Text_edit.selection_range s in
         Cairo.set_source_rgba cr 0.529 0.808 0.980 0.45;
         Array.iter (fun (g : Path_text_layout.path_glyph) ->
           if g.idx >= lo && g.idx < hi && not g.overflow then begin
             let half = g.width /. 2.0 in
             let h = pr.pr_font_size in
             let bx = g.cx -. cos g.angle *. half in
             let by = g.cy -. sin g.angle *. half in
             let ax = g.cx +. cos g.angle *. half in
             let ay = g.cy +. sin g.angle *. half in
             let nx = -. sin g.angle *. (h /. 2.0) in
             let ny = cos g.angle *. (h /. 2.0) in
             Cairo.move_to cr (bx +. nx) (by +. ny);
             Cairo.line_to cr (ax +. nx) (ay +. ny);
             Cairo.line_to cr (ax -. nx) (ay -. ny);
             Cairo.line_to cr (bx -. nx) (by -. ny);
             Cairo.Path.close cr;
             Cairo.fill cr
           end
         ) lay.glyphs
       end;
       (* Caret: blinking line at insertion, perpendicular to path *)
       if cursor_visible (Text_edit.blink_epoch_ms s) then begin
         match Path_text_layout.cursor_pos lay (Text_edit.insertion s) with
         | None -> ()
         | Some (cx, cy, angle) ->
           let h = pr.pr_font_size in
           let nx = -. sin angle in
           let ny = cos angle in
           let color = match pr.pr_fill with
             | Some f -> f.fill_color
             | None -> match pr.pr_stroke with
               | Some st -> st.stroke_color
               | None -> Element.black
           in
           let (r, g, b, _) = Element.color_to_rgba color in
           Cairo.set_source_rgba cr r g b 1.0;
           Cairo.set_line_width cr 1.5;
           Cairo.move_to cr (cx +. nx *. (h *. 0.7)) (cy +. ny *. (h *. 0.7));
           Cairo.line_to cr (cx -. nx *. (h *. 0.2)) (cy -. ny *. (h *. 0.2));
           Cairo.stroke cr
       end)
end
