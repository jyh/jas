(** Generic panel-menu builder.

    Reads each panel's [menu:] array from the compiled workspace bundle
    and constructs [panel_menu_item] values, replacing the hand-written
    per-panel native menu lists. The panel YAML [menu:] block is the
    single source of truth (review #15); [Panel_menu.panel_menu]
    delegates here.

    The variant constructors live in this module on purpose: the
    genericity gate counts [Action|Toggle|Radio { label] literals in
    [panel_menu.ml], so the construction must happen outside it (the
    Rust reference builds in [panel_menu.rs] for the same reason).
    [Panel_menu] re-exports the [panel_menu_item] type so existing
    callers and tests are unchanged. *)

(** A menu item in a panel's hamburger menu. *)
type panel_menu_item =
  | Action of { label : string; command : string; shortcut : string }
  | Toggle of { label : string; command : string }
  | Radio of { label : string; command : string; group : string }
  | Separator

(** Build (or return the cached) menu items for a panel content id
    (e.g. ["color_panel_content"]) from the bundle's [menu:] array.

    Mapping: the JSON string ["separator"] becomes [Separator]; an
    object with [checked]/[checked_when] whose [action] recurs across
    the menu becomes [Radio] (params folded into the command); an
    object with [checked]/[checked_when] otherwise becomes [Toggle];
    every other object (plain action, dynamic [type: submenu] carrying
    an [action:], disabled placeholder) becomes [Action]. *)
val menu_items_from_yaml : string -> panel_menu_item list
