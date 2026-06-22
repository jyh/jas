(** Menu bar render model — projected from the compiled workspace
    [menubar] (menubar.yaml). GTK-free so it can be unit-tested headless.
    Mirrors the Rust menu.rs projector. *)

(** Which runtime-populated submenu a [Dynamic_submenu] entry drives. *)
type submenu_kind = Workspace | Appearance

(** One resolved menu entry. *)
type entry =
  | Separator
  | Dynamic_submenu of { label : string; kind : submenu_kind }
  | Action of {
      label : string;
      action : string;
      params : (string * Yojson.Safe.t) list;
      shortcut : string;
      enabled_when : string option;
    }

(** One top-level menu (e.g. "&File") and its entries. *)
type menu = { label : string; entries : entry list }

(** Project the compiled [menubar] (menubar.yaml) into the render model.
    Returns [[]] if the bundle is missing/corrupt (never raises). *)
val menu_bar_model : unit -> menu list

(** Strip Windows/GTK-style [&] mnemonic markers from a label for
    display. [&&] is an escaped literal ampersand -> [&]. *)
val strip_mnemonic : string -> string
