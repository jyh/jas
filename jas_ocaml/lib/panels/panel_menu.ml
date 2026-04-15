(** Panel menu item types and per-panel lookup functions. *)

open Workspace_layout

(** A menu item in a panel's hamburger menu. *)
type panel_menu_item =
  | Action of { label : string; command : string; shortcut : string }
  | Toggle of { label : string; command : string }
  | Radio of { label : string; command : string; group : string }
  | Separator

(** All panel kinds, for iteration. *)
let all_panel_kinds = [| Layers; Color; Swatches; Stroke; Properties |]

(** Human-readable label for a panel kind. *)
let panel_label = function
  | Layers -> "Layers"
  | Color -> "Color"
  | Swatches -> "Swatches"
  | Stroke -> "Stroke"
  | Properties -> "Properties"

(** Menu items for a panel kind. *)
let panel_menu = function
  | Layers ->
    [ Action { label = "New Layer..."; command = "new_layer"; shortcut = "" };
      Action { label = "New Group"; command = "new_group"; shortcut = "" };
      Separator;
      Action { label = "Hide All Layers"; command = "toggle_all_layers_visibility"; shortcut = "" };
      Action { label = "Outline All Layers"; command = "toggle_all_layers_outline"; shortcut = "" };
      Action { label = "Lock All Layers"; command = "toggle_all_layers_lock"; shortcut = "" };
      Separator;
      Action { label = "Enter Isolation Mode"; command = "enter_isolation_mode"; shortcut = "" };
      Action { label = "Exit Isolation Mode"; command = "exit_isolation_mode"; shortcut = "" };
      Separator;
      Action { label = "Flatten Artwork"; command = "flatten_artwork"; shortcut = "" };
      Action { label = "Collect in New Layer"; command = "collect_in_new_layer"; shortcut = "" };
      Separator;
      Action { label = "Close Layers"; command = "close_panel"; shortcut = "" } ]
  | Color ->
    [ Radio { label = "Grayscale"; command = "mode_grayscale"; group = "color_mode" };
      Radio { label = "RGB"; command = "mode_rgb"; group = "color_mode" };
      Radio { label = "HSB"; command = "mode_hsb"; group = "color_mode" };
      Radio { label = "CMYK"; command = "mode_cmyk"; group = "color_mode" };
      Radio { label = "Web Safe RGB"; command = "mode_web_safe_rgb"; group = "color_mode" };
      Separator;
      Action { label = "Invert"; command = "invert_color"; shortcut = "" };
      Action { label = "Complement"; command = "complement_color"; shortcut = "" };
      Separator;
      Action { label = "Close Color"; command = "close_panel"; shortcut = "" } ]
  | Swatches -> [Action { label = "Close Swatches"; command = "close_panel"; shortcut = "" }]
  | Stroke -> [Action { label = "Close Stroke"; command = "close_panel"; shortcut = "" }]
  | Properties -> [Action { label = "Close Properties"; command = "close_panel"; shortcut = "" }]

(** Set the active color (fill or stroke per fill_on_top), push to recent colors. *)
let set_active_color color ~fill_on_top (m : Model.model) =
  if fill_on_top then begin
    m#set_default_fill (Some (Element.make_fill color));
    if not (Document.PathMap.is_empty m#document.Document.selection) then begin
      m#snapshot;
      let ctrl = Controller.create ~model:m () in
      ctrl#set_selection_fill (Some (Element.make_fill color))
    end
  end else begin
    let width = match m#default_stroke with Some s -> s.stroke_width | None -> 1.0 in
    m#set_default_stroke (Some (Element.make_stroke ~width color));
    if not (Document.PathMap.is_empty m#document.Document.selection) then begin
      m#snapshot;
      let ctrl = Controller.create ~model:m () in
      ctrl#set_selection_stroke (Some (Element.make_stroke ~width color))
    end
  end;
  let hex = Element.color_to_hex color in
  let rc = List.filter (fun c -> c <> hex) m#recent_colors in
  let rc = hex :: rc in
  let rc = if List.length rc > 10 then List.filteri (fun i _ -> i < 10) rc else rc in
  m#set_recent_colors rc

(** Set the active color without pushing to recent colors (live slider drag). *)
let set_active_color_live color ~fill_on_top (m : Model.model) =
  if fill_on_top then
    m#set_default_fill (Some (Element.make_fill color))
  else begin
    let width = match m#default_stroke with Some s -> s.stroke_width | None -> 1.0 in
    m#set_default_stroke (Some (Element.make_stroke ~width color))
  end

(** Dispatch a menu command for a panel kind. *)
let panel_dispatch kind cmd addr layout ~fill_on_top ~get_model =
  (* Mode changes *)
  (match color_panel_mode_of_command cmd with
   | Some mode -> layout.color_panel_mode <- mode
   | None -> ());
  match cmd with
  | "close_panel" -> close_panel layout addr
  | "new_layer" | "new_group"
  | "toggle_all_layers_visibility" | "toggle_all_layers_outline"
  | "toggle_all_layers_lock"
  | "enter_isolation_mode" | "exit_isolation_mode"
  | "flatten_artwork" | "collect_in_new_layer"
    when kind = Layers -> ()  (* Tier-3 stubs *)
  | "invert_color" when kind = Color ->
    let m = get_model () in
    let color = if fill_on_top then
      Option.map (fun (f : Element.fill) -> f.fill_color) m#default_fill
    else
      Option.map (fun (s : Element.stroke) -> s.stroke_color) m#default_stroke
    in
    (match color with
     | Some c ->
       let (r, g, b, _) = Element.color_to_rgba c in
       let inverted = Element.color_rgb (1.0 -. r) (1.0 -. g) (1.0 -. b) in
       set_active_color inverted ~fill_on_top m
     | None -> ())
  | "complement_color" when kind = Color ->
    let m = get_model () in
    let color = if fill_on_top then
      Option.map (fun (f : Element.fill) -> f.fill_color) m#default_fill
    else
      Option.map (fun (s : Element.stroke) -> s.stroke_color) m#default_stroke
    in
    (match color with
     | Some c ->
       let (h, s, br, _) = Element.color_to_hsba c in
       if s > 0.001 then begin
         let new_h = Float.rem (h +. 180.0) 360.0 in
         let complemented = Element.color_hsb new_h s br in
         set_active_color complemented ~fill_on_top m
       end
     | None -> ())
  | _ -> ()

(** Query whether a toggle/radio command is checked. *)
let panel_is_checked _kind cmd layout =
  match color_panel_mode_of_command cmd with
  | Some mode -> layout.color_panel_mode = mode
  | None -> false
