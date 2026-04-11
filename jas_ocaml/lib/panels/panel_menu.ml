(** Panel menu item types and per-panel lookup functions. *)

open Workspace_layout

(** A menu item in a panel's hamburger menu. *)
type panel_menu_item =
  | Action of { label : string; command : string; shortcut : string }
  | Toggle of { label : string; command : string }
  | Radio of { label : string; command : string; group : string }
  | Separator

(** All panel kinds, for iteration. *)
let all_panel_kinds = [| Layers; Color; Stroke; Properties |]

(** Human-readable label for a panel kind. *)
let panel_label = function
  | Layers -> "Layers"
  | Color -> "Color"
  | Stroke -> "Stroke"
  | Properties -> "Properties"

(** Menu items for a panel kind. *)
let panel_menu = function
  | Layers -> [Action { label = "Close Layers"; command = "close_panel"; shortcut = "" }]
  | Color -> [Action { label = "Close Color"; command = "close_panel"; shortcut = "" }]
  | Stroke -> [Action { label = "Close Stroke"; command = "close_panel"; shortcut = "" }]
  | Properties -> [Action { label = "Close Properties"; command = "close_panel"; shortcut = "" }]

(** Dispatch a menu command for a panel kind. *)
let panel_dispatch _kind cmd addr layout =
  match cmd with
  | "close_panel" -> close_panel layout addr
  | _ -> ()

(** Query whether a toggle/radio command is checked. *)
let panel_is_checked _kind _cmd _layout = false
