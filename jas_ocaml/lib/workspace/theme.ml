(* Theme — centralized appearance definitions. *)

type t = {
  window_bg : string;
  pane_bg : string;
  pane_bg_dark : string;
  title_bar_bg : string;
  title_bar_text : string;
  border : string;
  text : string;
  text_dim : string;
  text_body : string;
  text_hint : string;
  text_button : string;
  tab_active : string;
  tab_inactive : string;
  button_checked : string;
  accent : string;
}

type appearance_entry = {
  name : string;
  label : string;
}

let predefined_appearances = [
  { name = "dark_gray"; label = "Dark Gray" };
  { name = "medium_gray"; label = "Medium Gray" };
  { name = "light_gray"; label = "Light Gray" };
]

let default_appearance_name = "dark_gray"

let dark_gray = {
  window_bg = "#2e2e2e";
  pane_bg = "#3c3c3c";
  pane_bg_dark = "#333333";
  title_bar_bg = "#2a2a2a";
  title_bar_text = "#d9d9d9";
  border = "#555555";
  text = "#cccccc";
  text_dim = "#999999";
  text_body = "#aaaaaa";
  text_hint = "#777777";
  text_button = "#888888";
  tab_active = "#4a4a4a";
  tab_inactive = "#353535";
  button_checked = "#505050";
  accent = "#4a90d9";
}

let medium_gray = {
  window_bg = "#484848";
  pane_bg = "#565656";
  pane_bg_dark = "#4d4d4d";
  title_bar_bg = "#404040";
  title_bar_text = "#e0e0e0";
  border = "#6a6a6a";
  text = "#dddddd";
  text_dim = "#aaaaaa";
  text_body = "#bbbbbb";
  text_hint = "#888888";
  text_button = "#999999";
  tab_active = "#606060";
  tab_inactive = "#505050";
  button_checked = "#686868";
  accent = "#5a9ee6";
}

let light_gray = {
  window_bg = "#ececec";
  pane_bg = "#f0f0f0";
  pane_bg_dark = "#e6e6e6";
  title_bar_bg = "#e0e0e0";
  title_bar_text = "#1d1d1f";
  border = "#d1d1d1";
  text = "#1d1d1f";
  text_dim = "#86868b";
  text_body = "#3d3d3f";
  text_hint = "#aeaeb2";
  text_button = "#6e6e73";
  tab_active = "#ffffff";
  tab_inactive = "#e8e8e8";
  button_checked = "#d4d4d8";
  accent = "#007aff";
}

(** Parse "#rrggbb" to (r, g, b) floats in [0,1]. *)
let hex_to_rgb hex =
  let h = if String.length hex > 0 && hex.[0] = '#' then String.sub hex 1 (String.length hex - 1) else hex in
  let v = int_of_string ("0x" ^ h) in
  let r = float_of_int ((v lsr 16) land 0xFF) /. 255.0 in
  let g = float_of_int ((v lsr 8) land 0xFF) /. 255.0 in
  let b = float_of_int (v land 0xFF) /. 255.0 in
  (r, g, b)

let resolve name =
  match name with
  | "medium_gray" -> medium_gray
  | "light_gray" -> light_gray
  | _ -> dark_gray
