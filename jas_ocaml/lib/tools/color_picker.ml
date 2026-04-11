(** Color picker state and dialog. *)

(* ------------------------------------------------------------------ *)
(* Radio channel                                                       *)
(* ------------------------------------------------------------------ *)

type radio_channel = H | S | B | R | G | Blue

(* ------------------------------------------------------------------ *)
(* State                                                               *)
(* ------------------------------------------------------------------ *)

type state = {
  is_for_fill : bool;
  mutable r : float;
  mutable g : float;
  mutable b : float;
  mutable hue : float;
  mutable sat : float;
  mutable radio_channel : radio_channel;
  mutable is_web_only : bool;
}

let snap_web v =
  let steps = [| 0.0; 0.2; 0.4; 0.6; 0.8; 1.0 |] in
  let best = ref steps.(0) in
  Array.iter (fun s ->
    if abs_float (v -. s) < abs_float (v -. !best) then
      best := s
  ) steps;
  !best

let snap_to_web st =
  st.r <- snap_web st.r;
  st.g <- snap_web st.g;
  st.b <- snap_web st.b

let sync_hue_sat st =
  let (h, s, br, _) = Element.color_to_hsba (Element.color_rgb st.r st.g st.b) in
  if br > 0.001 && s > 0.001 then st.hue <- h;
  if br > 0.001 then st.sat <- s

let create_state (c : Element.color) (is_for_fill : bool) : state =
  let (r, g, b, _) = Element.color_to_rgba c in
  let (h, s, _, _) = Element.color_to_hsba c in
  { is_for_fill; r; g; b; hue = h; sat = s;
    radio_channel = H; is_web_only = false }

let for_fill st = st.is_for_fill

let color st = Element.color_rgb st.r st.g st.b

let set_rgb st ri gi bi =
  st.r <- float_of_int ri /. 255.0;
  st.g <- float_of_int gi /. 255.0;
  st.b <- float_of_int bi /. 255.0;
  if st.is_web_only then snap_to_web st;
  sync_hue_sat st

let set_hsb st h s b =
  st.hue <- h;
  st.sat <- s /. 100.0;
  let c = Element.color_hsb h (s /. 100.0) (b /. 100.0) in
  let (r, g, bl, _) = Element.color_to_rgba c in
  st.r <- r; st.g <- g; st.b <- bl;
  if st.is_web_only then snap_to_web st

let set_cmyk st c m y k =
  let col = Element.color_cmyk (c /. 100.0) (m /. 100.0) (y /. 100.0) (k /. 100.0) in
  let (r, g, b, _) = Element.color_to_rgba col in
  st.r <- r; st.g <- g; st.b <- b;
  if st.is_web_only then snap_to_web st;
  sync_hue_sat st

let set_hex st hex =
  match Element.color_from_hex hex with
  | Some c ->
    let (r, g, b, _) = Element.color_to_rgba c in
    st.r <- r; st.g <- g; st.b <- b;
    if st.is_web_only then snap_to_web st;
    sync_hue_sat st
  | None -> ()

let rgb_u8 st =
  let ri = int_of_float (Float.round (st.r *. 255.0)) in
  let gi = int_of_float (Float.round (st.g *. 255.0)) in
  let bi = int_of_float (Float.round (st.b *. 255.0)) in
  (ri, gi, bi)

let hsb_vals st =
  let (dh, ds, db, _) = Element.color_to_hsba (Element.color_rgb st.r st.g st.b) in
  let h = if db < 0.001 || ds < 0.001 then st.hue else dh in
  let s = if db < 0.001 then st.sat else ds in
  (h, s *. 100.0, db *. 100.0)

let cmyk_vals st =
  let (c, m, y, k, _) = Element.color_to_cmyka (Element.color_rgb st.r st.g st.b) in
  (c *. 100.0, m *. 100.0, y *. 100.0, k *. 100.0)

let hex_str st =
  Element.color_to_hex (Element.color_rgb st.r st.g st.b)

let set_radio st ch = st.radio_channel <- ch
let radio st = st.radio_channel

let set_web_only st v = st.is_web_only <- v
let web_only st = st.is_web_only

let clamp v = Float.max 0.0 (Float.min 1.0 v)

let set_from_gradient st x y =
  let x = clamp x and y = clamp y in
  (match st.radio_channel with
   | H ->
     st.sat <- x;
     let c = Element.color_hsb st.hue x (1.0 -. y) in
     let (r, g, b, _) = Element.color_to_rgba c in
     st.r <- r; st.g <- g; st.b <- b
   | S ->
     st.hue <- x *. 360.0;
     let c = Element.color_hsb (x *. 360.0) st.sat (1.0 -. y) in
     let (r, g, b, _) = Element.color_to_rgba c in
     st.r <- r; st.g <- g; st.b <- b
   | B ->
     st.hue <- x *. 360.0;
     st.sat <- 1.0 -. y;
     let (_, _, br, _) = Element.color_to_hsba (Element.color_rgb st.r st.g st.b) in
     let c = Element.color_hsb (x *. 360.0) (1.0 -. y) br in
     let (r, g, b, _) = Element.color_to_rgba c in
     st.r <- r; st.g <- g; st.b <- b
   | R ->
     st.b <- x;
     st.g <- 1.0 -. y;
     sync_hue_sat st
   | G ->
     st.b <- x;
     st.r <- 1.0 -. y;
     sync_hue_sat st
   | Blue ->
     st.r <- x;
     st.g <- 1.0 -. y;
     sync_hue_sat st);
  if st.is_web_only then snap_to_web st

let set_from_colorbar st t =
  let t = clamp t in
  (match st.radio_channel with
   | H ->
     st.hue <- t *. 360.0;
     let (_, _, br, _) = Element.color_to_hsba (Element.color_rgb st.r st.g st.b) in
     let c = Element.color_hsb (t *. 360.0) st.sat br in
     let (r, g, bl, _) = Element.color_to_rgba c in
     st.r <- r; st.g <- g; st.b <- bl
   | S ->
     st.sat <- 1.0 -. t;
     let (_, _, br, _) = Element.color_to_hsba (Element.color_rgb st.r st.g st.b) in
     let c = Element.color_hsb st.hue (1.0 -. t) br in
     let (r, g, bl, _) = Element.color_to_rgba c in
     st.r <- r; st.g <- g; st.b <- bl
   | B ->
     let c = Element.color_hsb st.hue st.sat (1.0 -. t) in
     let (r, g, bl, _) = Element.color_to_rgba c in
     st.r <- r; st.g <- g; st.b <- bl
   | R -> st.r <- 1.0 -. t; sync_hue_sat st
   | G -> st.g <- 1.0 -. t; sync_hue_sat st
   | Blue -> st.b <- 1.0 -. t; sync_hue_sat st);
  if st.is_web_only then snap_to_web st

let colorbar_pos st =
  match st.radio_channel with
  | H -> st.hue /. 360.0
  | S -> 1.0 -. st.sat
  | B ->
    let (_, _, br, _) = Element.color_to_hsba (Element.color_rgb st.r st.g st.b) in
    1.0 -. br
  | R -> 1.0 -. st.r
  | G -> 1.0 -. st.g
  | Blue -> 1.0 -. st.b

let gradient_pos st =
  let (_, _, db, _) = Element.color_to_hsba (Element.color_rgb st.r st.g st.b) in
  match st.radio_channel with
  | H -> (st.sat, 1.0 -. db)
  | S -> (st.hue /. 360.0, 1.0 -. db)
  | B -> (st.hue /. 360.0, 1.0 -. st.sat)
  | R -> (st.b, 1.0 -. st.g)
  | G -> (st.b, 1.0 -. st.r)
  | Blue -> (st.r, 1.0 -. st.g)

(* ------------------------------------------------------------------ *)
(* Cairo drawing helpers                                               *)
(* ------------------------------------------------------------------ *)

let gradient_size = 256
let colorbar_width = 20
let colorbar_height = 256

(** Draw the 2D gradient on a Cairo context for the given state. *)
let draw_gradient cr st =
  let w = gradient_size and h = gradient_size in
  let surface = Cairo.Image.create Cairo.Image.RGB24 ~w ~h in
  let data = Cairo.Image.get_data32 surface in
  for py = 0 to h - 1 do
    for px = 0 to w - 1 do
      let x = float_of_int px /. float_of_int (w - 1) in
      let y = float_of_int py /. float_of_int (h - 1) in
      let (r, g, b) = match st.radio_channel with
        | H ->
          let c = Element.color_hsb st.hue x (1.0 -. y) in
          let (r, g, b, _) = Element.color_to_rgba c in (r, g, b)
        | S ->
          let c = Element.color_hsb (x *. 360.0) st.sat (1.0 -. y) in
          let (r, g, b, _) = Element.color_to_rgba c in (r, g, b)
        | B ->
          let (_, _, br, _) = Element.color_to_hsba (Element.color_rgb st.r st.g st.b) in
          let c = Element.color_hsb (x *. 360.0) (1.0 -. y) br in
          let (r, g, b, _) = Element.color_to_rgba c in (r, g, b)
        | R ->
          (* x=Blue, y=Green, fixed Red *)
          (st.r, 1.0 -. y, x)
        | G ->
          (* x=Blue, y=Red, fixed Green *)
          (1.0 -. y, st.g, x)
        | Blue ->
          (* x=Red, y=Green, fixed Blue *)
          (x, 1.0 -. y, st.b)
      in
      let ri = int_of_float (Float.round (r *. 255.0)) in
      let gi = int_of_float (Float.round (g *. 255.0)) in
      let bi = int_of_float (Float.round (b *. 255.0)) in
      let pixel = (ri lsl 16) lor (gi lsl 8) lor bi in
      data.{py, px} <- Int32.of_int pixel
    done
  done;
  Cairo.set_source_surface cr surface ~x:0.0 ~y:0.0;
  Cairo.paint cr;
  (* Draw crosshair *)
  let (gx, gy) = gradient_pos st in
  let cx = gx *. float_of_int w and cy = gy *. float_of_int h in
  Cairo.set_line_width cr 1.5;
  Cairo.set_source_rgb cr 1.0 1.0 1.0;
  Cairo.arc cr cx cy ~r:5.0 ~a1:0.0 ~a2:(2.0 *. Float.pi);
  Cairo.stroke cr;
  Cairo.set_source_rgb cr 0.0 0.0 0.0;
  Cairo.arc cr cx cy ~r:6.0 ~a1:0.0 ~a2:(2.0 *. Float.pi);
  Cairo.stroke cr

(** Draw the vertical colorbar on a Cairo context for the given state. *)
let draw_colorbar cr st =
  let w = colorbar_width and h = colorbar_height in
  let surface = Cairo.Image.create Cairo.Image.RGB24 ~w ~h in
  let data = Cairo.Image.get_data32 surface in
  for py = 0 to h - 1 do
    let t = float_of_int py /. float_of_int (h - 1) in
    let (r, g, b) = match st.radio_channel with
      | H ->
        let c = Element.color_hsb (t *. 360.0) 1.0 1.0 in
        let (r, g, b, _) = Element.color_to_rgba c in (r, g, b)
      | S ->
        let c = Element.color_hsb st.hue (1.0 -. t) 1.0 in
        let (r, g, b, _) = Element.color_to_rgba c in (r, g, b)
      | B ->
        let c = Element.color_hsb st.hue st.sat (1.0 -. t) in
        let (r, g, b, _) = Element.color_to_rgba c in (r, g, b)
      | R -> (1.0 -. t, st.g, st.b)
      | G -> (st.r, 1.0 -. t, st.b)
      | Blue -> (st.r, st.g, 1.0 -. t)
    in
    let ri = int_of_float (Float.round (r *. 255.0)) in
    let gi = int_of_float (Float.round (g *. 255.0)) in
    let bi = int_of_float (Float.round (b *. 255.0)) in
    let pixel = (ri lsl 16) lor (gi lsl 8) lor bi in
    for px = 0 to w - 1 do
      data.{py, px} <- Int32.of_int pixel
    done
  done;
  Cairo.set_source_surface cr surface ~x:0.0 ~y:0.0;
  Cairo.paint cr;
  (* Draw slider arrow *)
  let pos = colorbar_pos st in
  let sy = pos *. float_of_int h in
  Cairo.set_line_width cr 1.5;
  Cairo.set_source_rgb cr 0.0 0.0 0.0;
  (* Left arrow *)
  Cairo.move_to cr 0.0 (sy -. 4.0);
  Cairo.line_to cr 0.0 (sy +. 4.0);
  Cairo.line_to cr 4.0 sy;
  Cairo.Path.close cr;
  Cairo.fill cr;
  (* Right arrow *)
  Cairo.move_to cr (float_of_int w) (sy -. 4.0);
  Cairo.line_to cr (float_of_int w) (sy +. 4.0);
  Cairo.line_to cr (float_of_int w -. 4.0) sy;
  Cairo.Path.close cr;
  Cairo.fill cr;
  (* Horizontal line *)
  Cairo.move_to cr 0.0 sy;
  Cairo.line_to cr (float_of_int w) sy;
  Cairo.stroke cr

(* ------------------------------------------------------------------ *)
(* Dialog                                                              *)
(* ------------------------------------------------------------------ *)

let run_dialog ?parent st =
  let dialog = GWindow.dialog
    ~title:"Select Color"
    ~modal:true
    ?parent
    ~width:540 ~height:400
    ~resizable:false () in
  let main_hbox = GPack.hbox ~spacing:12
    ~packing:(dialog#vbox#pack ~expand:true ~fill:true) () in

  (* Left side: gradient + colorbar + Only Web Colors *)
  let left_vbox = GPack.vbox ~spacing:6
    ~packing:(main_hbox#pack ~expand:false) () in

  (* Title + eyedropper *)
  let title_hbox = GPack.hbox ~spacing:8
    ~packing:(left_vbox#pack ~expand:false) () in
  let _title_label = GMisc.label ~text:"Select Color:"
    ~packing:(title_hbox#pack ~expand:false) () in
  let eyedropper_btn = GButton.button ~label:"\240\159\146\167"
    ~packing:(title_hbox#pack ~expand:false) () in

  let gradient_hbox = GPack.hbox ~spacing:4
    ~packing:(left_vbox#pack ~expand:false) () in

  (* Gradient drawing area *)
  let gradient_area = GMisc.drawing_area
    ~packing:(gradient_hbox#pack ~expand:false) () in
  gradient_area#misc#set_size_request ~width:gradient_size ~height:gradient_size ();

  (* Colorbar drawing area *)
  let colorbar_area = GMisc.drawing_area
    ~packing:(gradient_hbox#pack ~expand:false) () in
  colorbar_area#misc#set_size_request ~width:(colorbar_width + 8) ~height:colorbar_height ();

  (* Right side: swatch + HSB/buttons + RGB/CMYK + hex *)
  let right_vbox = GPack.vbox ~spacing:4
    ~packing:(main_hbox#pack ~expand:true ~fill:true) () in

  (* Row 1: Swatch above HSB *)
  let swatch_area = GMisc.drawing_area
    ~packing:(right_vbox#pack ~expand:false) () in
  swatch_area#misc#set_size_request ~width:60 ~height:40 ();

  (* Row 2: HSB on left, OK/Cancel/Swatches on right *)
  let hsb_buttons_hbox = GPack.hbox ~spacing:12
    ~packing:(right_vbox#pack ~expand:false) () in

  (* HSB radio + entries *)
  let hsb_table = GPack.table ~rows:3 ~columns:3 ~row_spacings:4 ~col_spacings:4
    ~packing:(hsb_buttons_hbox#pack ~expand:false) () in

  let h_radio = GButton.radio_button ~label:"H:"
    ~packing:(hsb_table#attach ~left:0 ~top:0) () in
  let h_entry = GEdit.entry ~width_chars:5
    ~packing:(hsb_table#attach ~left:1 ~top:0) () in
  let _h_unit = GMisc.label ~text:"\194\176"
    ~packing:(hsb_table#attach ~left:2 ~top:0) () in

  let s_radio = GButton.radio_button ~group:h_radio#group ~label:"S:"
    ~packing:(hsb_table#attach ~left:0 ~top:1) () in
  let s_entry = GEdit.entry ~width_chars:5
    ~packing:(hsb_table#attach ~left:1 ~top:1) () in
  let _s_unit = GMisc.label ~text:"%"
    ~packing:(hsb_table#attach ~left:2 ~top:1) () in

  let b_radio = GButton.radio_button ~group:h_radio#group ~label:"B:"
    ~packing:(hsb_table#attach ~left:0 ~top:2) () in
  let b_entry = GEdit.entry ~width_chars:5
    ~packing:(hsb_table#attach ~left:1 ~top:2) () in
  let _b_unit = GMisc.label ~text:"%"
    ~packing:(hsb_table#attach ~left:2 ~top:2) () in

  (* OK / Cancel / Color Swatches buttons to the right of HSB *)
  let buttons_vbox = GPack.vbox ~spacing:4
    ~packing:(hsb_buttons_hbox#pack ~expand:false) () in
  let ok_btn = GButton.button ~label:"OK"
    ~packing:(buttons_vbox#pack ~expand:false) () in
  ok_btn#misc#set_size_request ~width:80 ();
  let cancel_btn = GButton.button ~label:"Cancel"
    ~packing:(buttons_vbox#pack ~expand:false) () in
  cancel_btn#misc#set_size_request ~width:80 ();
  let _swatches_btn = GButton.button ~label:"Color Swatches"
    ~packing:(buttons_vbox#pack ~expand:false) () in
  _swatches_btn#misc#set_sensitive false;

  (* RGB radio + entries *)
  let rgb_cmyk_table = GPack.table ~rows:4 ~columns:5 ~row_spacings:4 ~col_spacings:4
    ~packing:(right_vbox#pack ~expand:false) () in

  let r_radio = GButton.radio_button ~group:h_radio#group ~label:"R:"
    ~packing:(rgb_cmyk_table#attach ~left:0 ~top:0) () in
  let r_entry = GEdit.entry ~width_chars:5
    ~packing:(rgb_cmyk_table#attach ~left:1 ~top:0) () in

  let g_radio = GButton.radio_button ~group:h_radio#group ~label:"G:"
    ~packing:(rgb_cmyk_table#attach ~left:0 ~top:1) () in
  let g_entry = GEdit.entry ~width_chars:5
    ~packing:(rgb_cmyk_table#attach ~left:1 ~top:1) () in

  let blue_radio = GButton.radio_button ~group:h_radio#group ~label:"B:"
    ~packing:(rgb_cmyk_table#attach ~left:0 ~top:2) () in
  let blue_entry = GEdit.entry ~width_chars:5
    ~packing:(rgb_cmyk_table#attach ~left:1 ~top:2) () in

  (* CMYK entries (no radio buttons) *)
  let _c_label = GMisc.label ~text:"C:"
    ~packing:(rgb_cmyk_table#attach ~left:2 ~top:0) () in
  let c_entry = GEdit.entry ~width_chars:5
    ~packing:(rgb_cmyk_table#attach ~left:3 ~top:0) () in
  let _c_unit = GMisc.label ~text:"%"
    ~packing:(rgb_cmyk_table#attach ~left:4 ~top:0) () in

  let _m_label = GMisc.label ~text:"M:"
    ~packing:(rgb_cmyk_table#attach ~left:2 ~top:1) () in
  let m_entry = GEdit.entry ~width_chars:5
    ~packing:(rgb_cmyk_table#attach ~left:3 ~top:1) () in
  let _m_unit = GMisc.label ~text:"%"
    ~packing:(rgb_cmyk_table#attach ~left:4 ~top:1) () in

  let _y_label = GMisc.label ~text:"Y:"
    ~packing:(rgb_cmyk_table#attach ~left:2 ~top:2) () in
  let y_entry = GEdit.entry ~width_chars:5
    ~packing:(rgb_cmyk_table#attach ~left:3 ~top:2) () in
  let _y_unit = GMisc.label ~text:"%"
    ~packing:(rgb_cmyk_table#attach ~left:4 ~top:2) () in

  let _k_label = GMisc.label ~text:"K:"
    ~packing:(rgb_cmyk_table#attach ~left:2 ~top:3) () in
  let k_entry = GEdit.entry ~width_chars:5
    ~packing:(rgb_cmyk_table#attach ~left:3 ~top:3) () in
  let _k_unit = GMisc.label ~text:"%"
    ~packing:(rgb_cmyk_table#attach ~left:4 ~top:3) () in

  (* Web colors checkbox - below gradient *)
  let web_check = GButton.check_button ~label:"Only Web Colors"
    ~packing:(left_vbox#pack ~expand:false) () in

  (* Hex entry *)
  let hex_hbox = GPack.hbox ~spacing:4
    ~packing:(right_vbox#pack ~expand:false) () in
  let _hex_label = GMisc.label ~text:"#"
    ~packing:(hex_hbox#pack ~expand:false) () in
  let hex_entry = GEdit.entry ~width_chars:8
    ~packing:(hex_hbox#pack ~expand:false) () in

  (* Track whether we're mid-update to avoid feedback loops *)
  let updating = ref false in

  let redraw_all () =
    gradient_area#misc#queue_draw ();
    colorbar_area#misc#queue_draw ();
    swatch_area#misc#queue_draw ()
  in

  let update_entries () =
    if not !updating then begin
      updating := true;
      let (h_val, s_val, b_val) = hsb_vals st in
      h_entry#set_text (Printf.sprintf "%.0f" h_val);
      s_entry#set_text (Printf.sprintf "%.0f" s_val);
      b_entry#set_text (Printf.sprintf "%.0f" b_val);
      let (ri, gi, bi) = rgb_u8 st in
      r_entry#set_text (string_of_int ri);
      g_entry#set_text (string_of_int gi);
      blue_entry#set_text (string_of_int bi);
      let (cv, mv, yv, kv) = cmyk_vals st in
      c_entry#set_text (Printf.sprintf "%.0f" cv);
      m_entry#set_text (Printf.sprintf "%.0f" mv);
      y_entry#set_text (Printf.sprintf "%.0f" yv);
      k_entry#set_text (Printf.sprintf "%.0f" kv);
      hex_entry#set_text (hex_str st);
      updating := false
    end
  in

  let update_all () =
    update_entries ();
    redraw_all ()
  in

  (* Drawing callbacks *)
  gradient_area#misc#connect#draw ~callback:(fun cr ->
    draw_gradient cr st;
    true
  ) |> ignore;

  colorbar_area#misc#connect#draw ~callback:(fun cr ->
    Cairo.translate cr 4.0 0.0;
    draw_colorbar cr st;
    true
  ) |> ignore;

  swatch_area#misc#connect#draw ~callback:(fun cr ->
    let (r, g, b, _) = Element.color_to_rgba (color st) in
    let alloc = swatch_area#misc#allocation in
    let w = float_of_int alloc.Gtk.width in
    let h = float_of_int alloc.Gtk.height in
    Cairo.set_source_rgb cr r g b;
    Cairo.rectangle cr 0.0 0.0 ~w ~h;
    Cairo.fill cr;
    Cairo.set_source_rgb cr 0.0 0.0 0.0;
    Cairo.set_line_width cr 1.0;
    Cairo.rectangle cr 0.0 0.0 ~w ~h;
    Cairo.stroke cr;
    true
  ) |> ignore;

  (* Mouse events on gradient *)
  let gradient_dragging = ref false in
  gradient_area#event#add [`BUTTON_PRESS; `BUTTON_RELEASE; `POINTER_MOTION];
  gradient_area#event#connect#button_press ~callback:(fun ev ->
    if GdkEvent.Button.button ev = 1 then begin
      gradient_dragging := true;
      let x = GdkEvent.Button.x ev /. float_of_int gradient_size in
      let y = GdkEvent.Button.y ev /. float_of_int gradient_size in
      set_from_gradient st x y;
      update_all ();
      true
    end else false
  ) |> ignore;
  gradient_area#event#connect#button_release ~callback:(fun ev ->
    if GdkEvent.Button.button ev = 1 then begin
      gradient_dragging := false;
      true
    end else false
  ) |> ignore;
  gradient_area#event#connect#motion_notify ~callback:(fun ev ->
    if !gradient_dragging then begin
      let x = GdkEvent.Motion.x ev /. float_of_int gradient_size in
      let y = GdkEvent.Motion.y ev /. float_of_int gradient_size in
      set_from_gradient st x y;
      update_all ();
      true
    end else false
  ) |> ignore;

  (* Mouse events on colorbar *)
  let colorbar_dragging = ref false in
  colorbar_area#event#add [`BUTTON_PRESS; `BUTTON_RELEASE; `POINTER_MOTION];
  colorbar_area#event#connect#button_press ~callback:(fun ev ->
    if GdkEvent.Button.button ev = 1 then begin
      colorbar_dragging := true;
      let t = GdkEvent.Button.y ev /. float_of_int colorbar_height in
      set_from_colorbar st t;
      update_all ();
      true
    end else false
  ) |> ignore;
  colorbar_area#event#connect#button_release ~callback:(fun ev ->
    if GdkEvent.Button.button ev = 1 then begin
      colorbar_dragging := false;
      true
    end else false
  ) |> ignore;
  colorbar_area#event#connect#motion_notify ~callback:(fun ev ->
    if !colorbar_dragging then begin
      let t = GdkEvent.Motion.y ev /. float_of_int colorbar_height in
      set_from_colorbar st t;
      update_all ();
      true
    end else false
  ) |> ignore;

  (* Radio button callbacks *)
  let connect_radio radio ch =
    radio#connect#toggled ~callback:(fun () ->
      if radio#active then begin
        set_radio st ch;
        redraw_all ()
      end
    ) |> ignore
  in
  connect_radio h_radio H;
  connect_radio s_radio S;
  connect_radio b_radio B;
  connect_radio r_radio R;
  connect_radio g_radio G;
  connect_radio blue_radio Blue;

  (* Entry callbacks *)
  let connect_entry entry parse_and_set =
    entry#connect#activate ~callback:(fun () ->
      if not !updating then begin
        parse_and_set entry#text;
        update_all ()
      end
    ) |> ignore
  in

  connect_entry h_entry (fun txt ->
    let (_, s_val, b_val) = hsb_vals st in
    (try set_hsb st (float_of_string txt) s_val b_val with _ -> ()));
  connect_entry s_entry (fun txt ->
    let (h_val, _, b_val) = hsb_vals st in
    (try set_hsb st h_val (float_of_string txt) b_val with _ -> ()));
  connect_entry b_entry (fun txt ->
    let (h_val, s_val, _) = hsb_vals st in
    (try set_hsb st h_val s_val (float_of_string txt) with _ -> ()));
  connect_entry r_entry (fun txt ->
    let (_, gi, bi) = rgb_u8 st in
    (try set_rgb st (int_of_string txt) gi bi with _ -> ()));
  connect_entry g_entry (fun txt ->
    let (ri, _, bi) = rgb_u8 st in
    (try set_rgb st ri (int_of_string txt) bi with _ -> ()));
  connect_entry blue_entry (fun txt ->
    let (ri, gi, _) = rgb_u8 st in
    (try set_rgb st ri gi (int_of_string txt) with _ -> ()));
  connect_entry c_entry (fun txt ->
    let (_, mv, yv, kv) = cmyk_vals st in
    (try set_cmyk st (float_of_string txt) mv yv kv with _ -> ()));
  connect_entry m_entry (fun txt ->
    let (cv, _, yv, kv) = cmyk_vals st in
    (try set_cmyk st cv (float_of_string txt) yv kv with _ -> ()));
  connect_entry y_entry (fun txt ->
    let (cv, mv, _, kv) = cmyk_vals st in
    (try set_cmyk st cv mv (float_of_string txt) kv with _ -> ()));
  connect_entry k_entry (fun txt ->
    let (cv, mv, yv, _) = cmyk_vals st in
    (try set_cmyk st cv mv yv (float_of_string txt) with _ -> ()));
  connect_entry hex_entry (fun txt ->
    set_hex st txt);

  (* Web colors checkbox *)
  web_check#connect#toggled ~callback:(fun () ->
    set_web_only st web_check#active;
    if web_check#active then begin
      snap_to_web st;
      update_all ()
    end
  ) |> ignore;

  (* Eyedropper: not available in lablgtk3/macOS (no root window access) *)
  eyedropper_btn#misc#set_tooltip_text "Eyedropper (not available on this platform)";
  eyedropper_btn#misc#set_sensitive false;

  (* Initialize entries *)
  update_entries ();

  (* Add hidden response buttons so dialog#run works *)
  dialog#add_button_stock `OK `OK;
  dialog#add_button_stock `CANCEL `CANCEL;
  (* Hide the default action area since we have custom buttons *)
  dialog#action_area#misc#hide ();

  (* Wire custom OK/Cancel buttons to emit dialog response *)
  ignore (ok_btn#connect#clicked ~callback:(fun () ->
    dialog#response `OK));
  ignore (cancel_btn#connect#clicked ~callback:(fun () ->
    dialog#response `CANCEL));

  let response = dialog#run () in
  let result = (match response with
    | `OK -> Some (color st)
    | _ -> None) in
  dialog#destroy ();
  result
