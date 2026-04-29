(** Centralized appearance definitions: theme color records and the
    selection of predefined appearances. *)

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

val predefined_appearances : appearance_entry list
val default_appearance_name : string

(** Parse "#rrggbb" to (r, g, b) floats in [0,1]. *)
val hex_to_rgb : string -> float * float * float

(** Look up a theme by appearance name; falls back to dark_gray. *)
val resolve : string -> t
