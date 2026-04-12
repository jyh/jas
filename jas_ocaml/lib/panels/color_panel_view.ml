(** Color panel body: swatches, fill/stroke widget, sliders, hex input, color bar. *)

open Workspace_layout

let apply_dark_css w css_str =
  let css = new GObj.css_provider (GtkData.CssProvider.create ()) in
  css#load_from_data css_str;
  w#misc#style_context#add_provider css 600

(** Panel-local mutable color state. *)
type panel_state = {
  mutable h : float;   (* 0..360 *)
  mutable s : float;   (* 0..100 *)
  mutable b : float;   (* 0..100 *)
  mutable r : float;   (* 0..255 *)
  mutable g : float;   (* 0..255 *)
  mutable bl : float;  (* 0..255 *)
  mutable c : float;   (* 0..100 *)
  mutable m : float;   (* 0..100 *)
  mutable y : float;   (* 0..100 *)
  mutable k : float;   (* 0..100 *)
  mutable hex : string;
}

let make_panel_state () =
  { h = 0.0; s = 0.0; b = 100.0;
    r = 255.0; g = 255.0; bl = 255.0;
    c = 0.0; m = 0.0; y = 0.0; k = 0.0;
    hex = "ffffff" }

let sync_from_color ps (color : Element.color) =
  let (rv, gv, bv, _) = Element.color_to_rgba color in
  ps.r <- Float.round (rv *. 255.0);
  ps.g <- Float.round (gv *. 255.0);
  ps.bl <- Float.round (bv *. 255.0);
  let (hv, sv, brv, _) = Element.color_to_hsba color in
  ps.h <- Float.round hv;
  ps.s <- Float.round (sv *. 100.0);
  ps.b <- Float.round (brv *. 100.0);
  let (cv, mv, yv, kv, _) = Element.color_to_cmyka color in
  ps.c <- Float.round (cv *. 100.0);
  ps.m <- Float.round (mv *. 100.0);
  ps.y <- Float.round (yv *. 100.0);
  ps.k <- Float.round (kv *. 100.0);
  ps.hex <- Element.color_to_hex color

let ps_to_color ps mode =
  match mode with
  | Hsb_mode -> Element.color_hsb ps.h (ps.s /. 100.0) (ps.b /. 100.0)
  | Rgb_mode | Web_safe_rgb -> Element.color_rgb (ps.r /. 255.0) (ps.g /. 255.0) (ps.bl /. 255.0)
  | Cmyk_mode -> Element.color_cmyk (ps.c /. 100.0) (ps.m /. 100.0) (ps.y /. 100.0) (ps.k /. 100.0)
  | Grayscale ->
    let v = 1.0 -. ps.k /. 100.0 in
    Element.color_rgb v v v

let get_field ps field =
  match field with
  | "h" -> ps.h | "s" -> ps.s | "b" -> ps.b
  | "r" -> ps.r | "g" -> ps.g | "bl" -> ps.bl
  | "c" -> ps.c | "m" -> ps.m | "y" -> ps.y | "k" -> ps.k
  | _ -> 0.0

let set_field ps field v =
  match field with
  | "h" -> ps.h <- v | "s" -> ps.s <- v | "b" -> ps.b <- v
  | "r" -> ps.r <- v | "g" -> ps.g <- v | "bl" -> ps.bl <- v
  | "c" -> ps.c <- v | "m" -> ps.m <- v | "y" -> ps.y <- v | "k" -> ps.k <- v
  | _ -> ()

(** Build the color panel body widgets into the given container.
    Returns a refresh function to call when external state changes. *)
let create
    ~(packing : GObj.widget -> unit)
    ~(layout : workspace_layout)
    ~(get_model : unit -> Model.model)
    ~(get_fill_on_top : unit -> bool)
    ~(rebuild : unit -> unit)
    ~theme_text ~theme_text_dim ~theme_bg_dark ~theme_border
    () =
  let ps = make_panel_state () in
  let last_synced_hex = ref "" in

  let vbox = GPack.vbox ~spacing:4 ~packing () in
  apply_dark_css vbox (Printf.sprintf "box { padding: 4px; }");

  let mode () = layout.color_panel_mode in
  let fill_on_top () = get_fill_on_top () in
  let active_color () =
    let m = get_model () in
    if fill_on_top () then
      Option.map (fun (f : Element.fill) -> f.fill_color) m#default_fill
    else
      Option.map (fun (s : Element.stroke) -> s.stroke_color) m#default_stroke
  in

  (* Sync panel state from active color *)
  let sync () =
    let hex = match active_color () with Some c -> Element.color_to_hex c | None -> "" in
    if hex <> !last_synced_hex then begin
      (match active_color () with Some c -> sync_from_color ps c | None -> ());
      last_synced_hex := hex
    end
  in
  sync ();

  (* ── Row 1: Swatches ── *)
  let swatches_box = GPack.hbox ~spacing:2 ~packing:(vbox#pack ~expand:false) () in

  (* None shortcut *)
  let none_btn = GButton.button ~label:"\xE2\x88\x85" ~packing:(swatches_box#pack ~expand:false) () in
  apply_dark_css none_btn (Printf.sprintf "button { font-size: 12px; color: red; background: %s; border: 1px solid %s; min-width: 16px; min-height: 16px; padding: 0; }" !theme_bg_dark !theme_border);
  none_btn#connect#clicked ~callback:(fun () ->
    let m = get_model () in
    if fill_on_top () then begin
      m#set_default_fill None;
      if not (Document.PathMap.is_empty m#document.Document.selection) then begin
        m#snapshot;
        let ctrl = Controller.create ~model:m () in
        ctrl#set_selection_fill None
      end
    end else begin
      m#set_default_stroke None;
      if not (Document.PathMap.is_empty m#document.Document.selection) then begin
        m#snapshot;
        let ctrl = Controller.create ~model:m () in
        ctrl#set_selection_stroke None
      end
    end;
    rebuild ()
  ) |> ignore;

  (* Black shortcut *)
  let black_btn = GButton.button ~packing:(swatches_box#pack ~expand:false) () in
  apply_dark_css black_btn "button { background: #000000; min-width: 16px; min-height: 16px; padding: 0; border: 1px solid #888; }";
  black_btn#connect#clicked ~callback:(fun () ->
    Panel_menu.set_active_color Element.black ~fill_on_top:(fill_on_top ()) (get_model ());
    rebuild ()
  ) |> ignore;

  (* White shortcut *)
  let white_btn = GButton.button ~packing:(swatches_box#pack ~expand:false) () in
  apply_dark_css white_btn "button { background: #ffffff; min-width: 16px; min-height: 16px; padding: 0; border: 1px solid #888; }";
  white_btn#connect#clicked ~callback:(fun () ->
    Panel_menu.set_active_color Element.white ~fill_on_top:(fill_on_top ()) (get_model ());
    rebuild ()
  ) |> ignore;

  (* Separator *)
  let _sep = GMisc.separator `VERTICAL ~packing:(swatches_box#pack ~expand:false) () in

  (* Recent color slots *)
  let recent_btns = Array.init 10 (fun _i ->
    let btn = GButton.button ~packing:(swatches_box#pack ~expand:false) () in
    apply_dark_css btn (Printf.sprintf "button { background: transparent; min-width: 16px; min-height: 16px; padding: 0; border: 1px solid %s; }" !theme_border);
    btn
  ) in

  let update_recent_swatches () =
    let m = get_model () in
    let rc = m#recent_colors in
    Array.iteri (fun i btn ->
      match List.nth_opt rc i with
      | Some hex ->
        apply_dark_css btn (Printf.sprintf "button { background: #%s; min-width: 16px; min-height: 16px; padding: 0; border: 1px solid #888; }" hex)
      | None ->
        apply_dark_css btn (Printf.sprintf "button { background: transparent; min-width: 16px; min-height: 16px; padding: 0; border: 1px solid %s; }" !theme_border)
    ) recent_btns
  in
  update_recent_swatches ();

  Array.iteri (fun i btn ->
    btn#connect#clicked ~callback:(fun () ->
      let m = get_model () in
      match List.nth_opt m#recent_colors i with
      | Some hex ->
        (match Element.color_from_hex hex with
         | Some c ->
           Panel_menu.set_active_color c ~fill_on_top:(fill_on_top ()) m;
           rebuild ()
         | None -> ())
      | None -> ()
    ) |> ignore
  ) recent_btns;

  (* ── Row 2: Sliders ── *)
  let sliders_box = GPack.vbox ~spacing:2 ~packing:(vbox#pack ~expand:false) () in

  let slider_rows = ref [] in

  let add_slider_row label field min_val max_val step suffix =
    let row = GPack.hbox ~spacing:4 () in
    let _lbl = GMisc.label ~text:label ~packing:(row#pack ~expand:false) () in
    apply_dark_css _lbl (Printf.sprintf "label { color: %s; font-size: 10px; min-width: 10px; }" !theme_text);
    let adj = GData.adjustment ~value:(get_field ps field) ~lower:min_val ~upper:max_val ~step_incr:step ~page_incr:(step *. 10.0) () in
    let scale = GRange.scale `HORIZONTAL ~adjustment:adj ~draw_value:false ~packing:(row#pack ~expand:true ~fill:true) () in
    scale#misc#set_size_request ~height:18 ();
    apply_dark_css scale (Printf.sprintf "scale { min-height: 14px; }");
    let val_label = GMisc.label ~text:(string_of_int (int_of_float (get_field ps field)))
      ~packing:(row#pack ~expand:false) () in
    apply_dark_css val_label (Printf.sprintf "label { color: %s; font-size: 10px; min-width: 30px; }" !theme_text);
    (match suffix with
     | Some sfx ->
       let _sfx_lbl = GMisc.label ~text:sfx ~packing:(row#pack ~expand:false) () in
       apply_dark_css _sfx_lbl (Printf.sprintf "label { color: %s; font-size: 10px; }" !theme_text_dim)
     | None -> ());
    adj#connect#value_changed ~callback:(fun () ->
      let v = adj#value in
      set_field ps field v;
      let color = ps_to_color ps (mode ()) in
      sync_from_color ps color;
      let m2 = mode () in
      set_field ps field v;
      ignore m2;
      last_synced_hex := Element.color_to_hex color;
      val_label#set_text (string_of_int (int_of_float v));
      Panel_menu.set_active_color_live color ~fill_on_top:(fill_on_top ()) (get_model ())
    ) |> ignore;
    slider_rows := (row, field, adj, val_label) :: !slider_rows;
    row
  in

  let rebuild_sliders () =
    List.iter (fun w -> w#destroy ()) sliders_box#children;
    slider_rows := [];
    (match mode () with
     | Grayscale ->
       sliders_box#pack ~expand:false (add_slider_row "K" "k" 0.0 100.0 1.0 (Some "%"))#coerce
     | Hsb_mode ->
       sliders_box#pack ~expand:false (add_slider_row "H" "h" 0.0 360.0 1.0 (Some "\xC2\xB0"))#coerce;
       sliders_box#pack ~expand:false (add_slider_row "S" "s" 0.0 100.0 1.0 (Some "%"))#coerce;
       sliders_box#pack ~expand:false (add_slider_row "B" "b" 0.0 100.0 1.0 (Some "%"))#coerce
     | Rgb_mode ->
       sliders_box#pack ~expand:false (add_slider_row "R" "r" 0.0 255.0 1.0 None)#coerce;
       sliders_box#pack ~expand:false (add_slider_row "G" "g" 0.0 255.0 1.0 None)#coerce;
       sliders_box#pack ~expand:false (add_slider_row "B" "bl" 0.0 255.0 1.0 None)#coerce
     | Cmyk_mode ->
       sliders_box#pack ~expand:false (add_slider_row "C" "c" 0.0 100.0 1.0 (Some "%"))#coerce;
       sliders_box#pack ~expand:false (add_slider_row "M" "m" 0.0 100.0 1.0 (Some "%"))#coerce;
       sliders_box#pack ~expand:false (add_slider_row "Y" "y" 0.0 100.0 1.0 (Some "%"))#coerce;
       sliders_box#pack ~expand:false (add_slider_row "K" "k" 0.0 100.0 1.0 (Some "%"))#coerce
     | Web_safe_rgb ->
       sliders_box#pack ~expand:false (add_slider_row "R" "r" 0.0 255.0 51.0 None)#coerce;
       sliders_box#pack ~expand:false (add_slider_row "G" "g" 0.0 255.0 51.0 None)#coerce;
       sliders_box#pack ~expand:false (add_slider_row "B" "bl" 0.0 255.0 51.0 None)#coerce);
    sliders_box#misc#show_all ()
  in
  rebuild_sliders ();

  (* ── Row 3: Hex input ── *)
  let hex_box = GPack.hbox ~spacing:2 ~packing:(vbox#pack ~expand:false) () in
  let _hash = GMisc.label ~text:"#" ~packing:(hex_box#pack ~expand:false) () in
  apply_dark_css _hash (Printf.sprintf "label { color: %s; font-size: 10px; }" !theme_text);
  let hex_entry = GEdit.entry ~text:ps.hex ~width_chars:8 ~packing:(hex_box#pack ~expand:false) () in
  apply_dark_css hex_entry (Printf.sprintf "entry { font-size: 10px; font-family: monospace; background: %s; color: %s; border: 1px solid %s; }" !theme_bg_dark !theme_text !theme_border);
  hex_entry#connect#activate ~callback:(fun () ->
    let raw = String.trim hex_entry#text in
    let raw = if String.length raw > 0 && raw.[0] = '#' then String.sub raw 1 (String.length raw - 1) else raw in
    if String.length raw = 6 then
      match Element.color_from_hex raw with
      | Some color ->
        sync_from_color ps color;
        last_synced_hex := Element.color_to_hex color;
        Panel_menu.set_active_color color ~fill_on_top:(fill_on_top ()) (get_model ());
        rebuild ()
      | None -> ()
  ) |> ignore;

  (* ── Color bar ── *)
  let bar_area = GMisc.drawing_area ~packing:(vbox#pack ~expand:false) () in
  bar_area#misc#set_size_request ~height:64 ();
  bar_area#event#add [`BUTTON_PRESS; `BUTTON_RELEASE; `BUTTON_MOTION];

  bar_area#misc#connect#draw ~callback:(fun cr ->
    let alloc = bar_area#misc#allocation in
    let w = alloc.Gtk.width in
    let h = alloc.Gtk.height in
    if w > 0 && h > 0 then begin
      let surface = Cairo.Image.create Cairo.Image.RGB24 ~w ~h in
      let data = Cairo.Image.get_data32 surface in
      let mid_y = float_of_int h /. 2.0 in
      for y = 0 to h - 1 do
        let yf = float_of_int y in
        let (sat, br) = if yf <= mid_y then
          let t = yf /. mid_y in
          (t, 1.0 -. t *. 0.2)
        else
          let t = (yf -. mid_y) /. (float_of_int h -. mid_y) in
          (1.0, 0.8 *. (1.0 -. t))
        in
        for x = 0 to w - 1 do
          let hue = 360.0 *. float_of_int x /. float_of_int w in
          let c = Element.color_hsb hue sat br in
          let (rv, gv, bv, _) = Element.color_to_rgba c in
          let ri = int_of_float (rv *. 255.0) in
          let gi = int_of_float (gv *. 255.0) in
          let bi = int_of_float (bv *. 255.0) in
          data.{y, x} <- Int32.of_int (ri lsl 16 lor gi lsl 8 lor bi)
        done
      done;
      Cairo.set_source_surface cr surface ~x:0.0 ~y:0.0;
      Cairo.paint cr
    end;
    true
  ) |> ignore;

  let apply_bar_point ev commit =
    let alloc = bar_area#misc#allocation in
    let w = float_of_int alloc.Gtk.width in
    let h = float_of_int alloc.Gtk.height in
    let x = Float.max 0.0 (Float.min (GdkEvent.Button.x ev) (w -. 1.0)) in
    let y = Float.max 0.0 (Float.min (GdkEvent.Button.y ev) (h -. 1.0)) in
    let mid_y = h /. 2.0 in
    let hue = 360.0 *. x /. w in
    let (sat, br) = if y <= mid_y then
      let t = y /. mid_y in
      (t *. 100.0, 100.0 -. t *. 20.0)
    else
      let t = (y -. mid_y) /. (h -. mid_y) in
      (100.0, 80.0 *. (1.0 -. t))
    in
    let color = Element.color_hsb hue (sat /. 100.0) (br /. 100.0) in
    sync_from_color ps color;
    ps.h <- Float.round hue;
    ps.s <- Float.round sat;
    ps.b <- Float.round br;
    last_synced_hex := Element.color_to_hex color;
    if commit then
      Panel_menu.set_active_color color ~fill_on_top:(fill_on_top ()) (get_model ())
    else
      Panel_menu.set_active_color_live color ~fill_on_top:(fill_on_top ()) (get_model ());
    rebuild ()
  in

  bar_area#event#connect#button_press ~callback:(fun ev ->
    if GdkEvent.Button.button ev = 1 then begin
      apply_bar_point ev false;
      true
    end else false
  ) |> ignore;

  bar_area#event#connect#button_release ~callback:(fun ev ->
    if GdkEvent.Button.button ev = 1 then begin
      apply_bar_point ev true;
      true
    end else false
  ) |> ignore;

  (* Return a refresh function *)
  let refresh () =
    sync ();
    hex_entry#set_text ps.hex;
    update_recent_swatches ();
    rebuild_sliders ();
    bar_area#misc#queue_draw ()
  in
  refresh
