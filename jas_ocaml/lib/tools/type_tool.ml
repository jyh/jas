(** Type tool with native in-place text editing.

    Click on existing unlocked text to edit; click empty to create a new
    empty text element and enter editing immediately. Drag to create area
    text. While editing, mouse drag extends the selection and standard
    editing keys are routed via [on_key_event]. *)

type text_render = {
  tr_x : float;
  tr_y : float;
  tr_font_size : float;
  tr_text_width : float;
  tr_text_height : float;
  tr_fill : Element.fill option;
  tr_stroke : Element.stroke option;
  tr_content : string;
}

let blink_half_period_ms = 530.0

let now_ms () = Unix.gettimeofday () *. 1000.0

let cursor_visible epoch_ms =
  let elapsed = max 0.0 (now_ms () -. epoch_ms) in
  let phase = int_of_float (elapsed /. blink_half_period_ms) in
  phase mod 2 = 0

(* Real Cairo-backed measurer that creates a temporary surface to query
   text_extents. Falls back to a 0.55 * font_size stub if Cairo cannot
   create a surface (e.g. headless tests). *)
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

(* Stub measurer kept for any test paths that import it. *)
let stub_measure font_size s =
  float_of_int (String.length s) *. font_size *. 0.55

let text_draw_bounds (t : Element.element) =
  match t with
  | Element.Text { x; y; content; font_size; text_width; text_height; _ } ->
    if text_width > 0.0 && text_height > 0.0 then
      (x, y, max text_width 1.0, max text_height 1.0)
    else begin
      let lines = String.split_on_char '\n' (if content = "" then " " else content) in
      let max_chars = List.fold_left (fun a l -> max a (String.length l)) 0 lines in
      let max_chars = max max_chars 1 in
      let w = float_of_int max_chars *. font_size *. 0.55 in
      let h = float_of_int (List.length lines) *. font_size in
      (x, y, w, h)
    end
  | _ -> (0.0, 0.0, 0.0, 0.0)

let in_box (bx, by, bw, bh) x y =
  x >= bx && x <= bx +. bw && y >= by && y <= by +. bh

(* Recursive hit-test that respects locked groups/elements *)
let hit_test_text doc x y =
  let result = ref None in
  let rec rec_ elem path =
    if !result = None then
      match elem with
      | Element.Layer { children; _ } ->
        Array.iteri (fun i c -> rec_ c (path @ [i])) children
      | Element.Group { children; locked; _ } ->
        if not locked then
          Array.iteri (fun i c -> rec_ c (path @ [i])) children
      | Element.Text _ ->
        let locked = Element.is_locked elem in
        if not locked then begin
          let b = text_draw_bounds elem in
          if in_box b x y then result := Some (path, elem)
        end
      | _ -> ()
  in
  Array.iteri (fun li layer -> rec_ layer [li]) doc.Document.layers;
  !result

class type_tool = object (_self)
  inherit Canvas_tool.default_methods

  val mutable drag_start : (float * float) option = None
  val mutable drag_end : (float * float) option = None
  val mutable session : Text_edit.t option = None
  val mutable did_snapshot : bool = false
  val mutable hover_text : bool = false

  method private build_layout (ctx : Canvas_tool.tool_context) =
    match session with
    | None -> None
    | Some s ->
      if Text_edit.target s <> Text_edit.Edit_text then None
      else
        let elem = Document.get_element ctx.model#document (Text_edit.path s) in
        match elem with
        | Element.Text { x; y; font_size; font_family; font_weight; font_style; text_width; text_height; fill; stroke; _ } ->
          let measure = make_measure font_family font_weight font_style font_size in
          let max_w = if text_width > 0.0 && text_height > 0.0 then text_width else 0.0 in
          let content = Text_edit.content s in
          let lay = Text_layout.layout content max_w font_size measure in
          let tr = {
            tr_x = x; tr_y = y; tr_font_size = font_size;
            tr_text_width = text_width; tr_text_height = text_height;
            tr_fill = fill; tr_stroke = stroke; tr_content = content;
          } in
          Some (tr, lay)
        | _ -> None

  method private cursor_at ctx x y =
    match _self#build_layout ctx with
    | None -> 0
    | Some (tr, lay) -> Text_layout.hit_test lay (x -. tr.tr_x) (y -. tr.tr_y)

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

  (* Read the current element's tspans from the doc for cut/copy/paste. *)
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

  (* Replace the tspans on the element at [path], leaving the document
     otherwise untouched. Used by the tspan-aware paste path. *)
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
      | Element.Text { content; _ } -> content
      | _ -> ""
    in
    let s = Text_edit.create
      ~path ~target:Text_edit.Edit_text ~content ~insertion:cursor in
    Text_edit.set_blink_epoch_ms s (now_ms ());
    session <- Some s;
    ctx.model#set_current_edit_session (Some (Text_edit.as_session_ref s));
    did_snapshot <- false;
    ctx.controller#select_element path

  method private begin_session_new (ctx : Canvas_tool.tool_context) x y w h =
    ctx.model#snapshot;
    did_snapshot <- true;
    let elem = Text_edit.empty_text_elem x y w h in
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
        ~path ~target:Text_edit.Edit_text ~content:"" ~insertion:0 in
      Text_edit.set_blink_epoch_ms s (now_ms ());
      session <- Some s;
      ctx.model#set_current_edit_session (Some (Text_edit.as_session_ref s))
    end

  method private end_session ?ctx () =
    session <- None;
    did_snapshot <- false;
    drag_start <- None;
    drag_end <- None;
    (match ctx with
     | Some (c : Canvas_tool.tool_context) ->
       c.model#set_current_edit_session None
     | None -> ())

  method has_session = session <> None
  method get_session = session

  method on_press (ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(alt : bool) =
    ignore (shift, alt);
    (match session with
     | Some s ->
       let elem = Document.get_element ctx.model#document (Text_edit.path s) in
       let in_elem = match elem with
         | Element.Text _ -> in_box (text_draw_bounds elem) x y
         | _ -> false
       in
       if in_elem then begin
         let cursor = _self#cursor_at ctx x y in
         Text_edit.set_insertion s cursor ~extend:false;
         Text_edit.set_drag_active s true;
         Text_edit.set_blink_epoch_ms s (now_ms ());
         ctx.request_update ()
       end else begin
         _self#end_session ~ctx ();
         (match hit_test_text ctx.model#document x y with
          | Some (path, elem) ->
            _self#begin_session_existing ctx path elem 0;
            (match session with
             | Some s ->
               let cursor = _self#cursor_at ctx x y in
               Text_edit.set_insertion s cursor ~extend:false;
               Text_edit.set_drag_active s true;
               Text_edit.set_blink_epoch_ms s (now_ms ());
               ctx.request_update ()
             | None -> ())
          | None ->
            drag_start <- Some (x, y);
            drag_end <- Some (x, y))
       end
     | None ->
       (match hit_test_text ctx.model#document x y with
        | Some (path, elem) ->
          _self#begin_session_existing ctx path elem 0;
          (match session with
           | Some s ->
             let cursor = _self#cursor_at ctx x y in
             Text_edit.set_insertion s cursor ~extend:false;
             Text_edit.set_drag_active s true;
             Text_edit.set_blink_epoch_ms s (now_ms ());
             ctx.request_update ()
           | None -> ())
        | None ->
          drag_start <- Some (x, y);
          drag_end <- Some (x, y)))

  method on_move (ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(dragging : bool) =
    ignore shift;
    match session with
    | Some s when Text_edit.drag_active s && dragging ->
      let cursor = _self#cursor_at ctx x y in
      Text_edit.set_insertion s cursor ~extend:true;
      Text_edit.set_blink_epoch_ms s (now_ms ());
      ctx.request_update ()
    | _ ->
      (if drag_start <> None then begin
        drag_end <- Some (x, y);
        ctx.request_update ()
      end);
      if session = None then
        hover_text <- (hit_test_text ctx.model#document x y) <> None
      else
        hover_text <- false

  method on_release (ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(alt : bool) =
    ignore (shift, alt);
    match session with
    | Some s ->
      Text_edit.set_drag_active s false;
      Text_edit.set_blink_epoch_ms s (now_ms ());
      drag_start <- None;
      drag_end <- None;
      ctx.request_update ()
    | None ->
      match drag_start with
      | None -> ()
      | Some (sx, sy) ->
        drag_start <- None;
        drag_end <- None;
        let w = abs_float (x -. sx) in
        let h = abs_float (y -. sy) in
        if w > Canvas_tool.drag_threshold || h > Canvas_tool.drag_threshold then
          _self#begin_session_new ctx (min sx x) (min sy y) w h
        else
          _self#begin_session_new ctx sx sy 0.0 0.0;
        ctx.request_update ()

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
  method deactivate (ctx : Canvas_tool.tool_context) = _self#end_session ~ctx ()

  method! captures_keyboard () = session <> None
  method! is_editing () = session <> None

  method! cursor_css_override () =
    (* While editing, always use the system I-beam. *)
    if session <> None then Some "ibeam"
    else if hover_text then Some "ibeam"
    else None

  method! paste_text (ctx : Canvas_tool.tool_context) text =
    match session with
    | None -> false
    | Some s ->
      (* Tspan-aware paste: when the session clipboard's flat text
         still matches, splice the captured tspan overrides back in
         at the caret. Otherwise fall through to flat insert. *)
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
        (* Capture the selection's tspan overrides from the current
           element so a later paste within this session can splice them
           back in. The flat string still goes to the system clipboard
           via the usual platform copy wiring. *)
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
        _self#end_session ~ctx (); ctx.request_update (); true
      end else if key = "Enter" then begin
        _self#ensure_snapshot ctx;
        Text_edit.insert s "\n";
        bump (); _self#sync_to_model ctx; ctx.request_update (); true
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
      end else if key = "ArrowUp" || key = "ArrowDown" then begin
        (match _self#build_layout ctx with
         | Some (_, lay) ->
           let new_pos =
             if key = "ArrowUp" then Text_layout.cursor_up lay (Text_edit.insertion s)
             else Text_layout.cursor_down lay (Text_edit.insertion s)
           in
           Text_edit.set_insertion s new_pos ~extend:mods.shift;
           bump (); ctx.request_update ()
         | None -> ());
        true
      end else if key = "Home" then begin
        (match _self#build_layout ctx with
         | Some (_, lay) ->
           let line_no = Text_layout.line_for_cursor lay (Text_edit.insertion s) in
           if line_no >= 0 && line_no < Array.length lay.lines then begin
             let line = lay.lines.(line_no) in
             Text_edit.set_insertion s line.start ~extend:mods.shift;
             bump (); ctx.request_update ()
           end
         | None -> ());
        true
      end else if key = "End" then begin
        (match _self#build_layout ctx with
         | Some (_, lay) ->
           let line_no = Text_layout.line_for_cursor lay (Text_edit.insertion s) in
           if line_no >= 0 && line_no < Array.length lay.lines then begin
             let line = lay.lines.(line_no) in
             Text_edit.set_insertion s line.end_ ~extend:mods.shift;
             bump (); ctx.request_update ()
           end
         | None -> ());
        true
      end else if String.length key = 1 && not cmd then begin
        _self#ensure_snapshot ctx;
        Text_edit.insert s key;
        bump (); _self#sync_to_model ctx; ctx.request_update (); true
      end else false

  method draw_overlay (ctx : Canvas_tool.tool_context) cr =
    (* Drag-create preview *)
    (match session, drag_start, drag_end with
     | None, Some (sx, sy), Some (ex, ey) ->
       Cairo.set_source_rgba cr 0.4 0.4 0.4 1.0;
       Cairo.set_line_width cr 1.0;
       Cairo.set_dash cr [| 4.0; 4.0 |];
       let rx = min sx ex and ry = min sy ey in
       let rw = abs_float (ex -. sx) and rh = abs_float (ey -. sy) in
       Cairo.rectangle cr rx ry ~w:rw ~h:rh;
       Cairo.stroke cr;
       Cairo.set_dash cr [||]
     | _ -> ());
    (* Editing overlay: selection rects, bounding box, caret *)
    match _self#build_layout ctx with
    | None -> ()
    | Some (tr, lay) ->
      let s = match session with Some s -> s | None -> assert false in
      if Text_edit.has_selection s then begin
        let (lo, hi) = Text_edit.selection_range s in
        Cairo.set_source_rgba cr 0.529 0.808 0.980 0.45;
        Array.iteri (fun line_idx (line : Text_layout.line_info) ->
          let line_lo = max line.start lo in
          let line_hi = min line.end_ hi in
          if line_lo < line_hi then begin
            let glyph_x_for idx =
              let result = ref None in
              Array.iter (fun (g : Text_layout.glyph) ->
                if !result = None && g.idx = idx && g.line = line_idx then
                  result := Some g.x
              ) lay.glyphs;
              !result
            in
            let x_lo =
              if line_lo = line.start then 0.0
              else (match glyph_x_for line_lo with Some v -> v | None -> 0.0)
            in
            let x_hi =
              if line_hi = line.end_ then line.width
              else (match glyph_x_for line_hi with Some v -> v | None -> line.width)
            in
            Cairo.rectangle cr (tr.tr_x +. x_lo) (tr.tr_y +. line.top)
              ~w:(x_hi -. x_lo) ~h:line.height;
            Cairo.fill cr
          end
        ) lay.lines
      end;
      (* The bounding box around the edited text is not drawn here —
         the Type tool selects the element when it starts editing,
         so the selection overlay (see [draw_selection_overlays] /
         [draw_element_overlay]) is responsible for rendering the
         box. That keeps the rule "area text shows its bbox iff the
         element is selected" in a single place. *)
      if cursor_visible (Text_edit.blink_epoch_ms s) then begin
        let (cx, cy, ch) = Text_layout.cursor_xy lay (Text_edit.insertion s) in
        let color = match tr.tr_fill with
          | Some f -> f.fill_color
          | None -> match tr.tr_stroke with
            | Some st -> st.stroke_color
            | None -> Element.black
        in
        let (r, g, b, _) = Element.color_to_rgba color in
        Cairo.set_source_rgba cr r g b 1.0;
        Cairo.set_line_width cr 1.5;
        Cairo.move_to cr (tr.tr_x +. cx) (tr.tr_y +. cy -. ch *. 0.8);
        Cairo.line_to cr (tr.tr_x +. cx) (tr.tr_y +. cy +. ch *. 0.2);
        Cairo.stroke cr
      end
end
