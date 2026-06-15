(** Generic panel-menu builder: reads each panel's [menu:] array from
    the compiled workspace bundle and constructs [panel_menu_item]
    values, replacing the hand-written per-panel native lists.

    The panel YAML [menu:] block is the single source of truth
    (review #15); [Panel_menu.panel_menu] now delegates here. Keeping
    the variant constructors in this module (rather than in
    [panel_menu.ml]) is deliberate: the genericity gate counts
    [Action|Toggle|Radio { label] literals in [panel_menu.ml], so the
    construction has to live elsewhere — exactly as the Rust reference
    builds in [panel_menu.rs] while the counter watches the per-panel
    files.

    The YAML menu entry shapes (in workspace.json, under each panel
    content id) map as follows:

    - the JSON string ["separator"]                 -> [Separator]
    - an object with [checked]/[checked_when] AND an
      [action] that recurs across the menu              -> [Radio]
    - an object with [checked]/[checked_when] (one-off)  -> [Toggle]
    - any other object (plain action, dynamic submenu,
      disabled placeholder)                             -> [Action]

    Radio grouping is expressed in the YAML by several entries sharing
    one [action] (e.g. every [set_color_panel_mode] row); there is no
    explicit [group:] key, so we detect a radio member by counting
    [action] occurrences. Radio members fold their [params] values
    into the command ([set_color_panel_mode:grayscale]) so the
    no-params menu dispatch can still tell them apart. *)

(** A menu item in a panel's hamburger menu. Mirror of the variant in
    [Panel_menu], which re-exports this type so existing callers and
    tests ([Panel_menu.Action {..}]) are unchanged. *)
type panel_menu_item =
  | Action of { label : string; command : string; shortcut : string }
  | Toggle of { label : string; command : string }
  | Radio of { label : string; command : string; group : string }
  | Separator

(** Build the runtime command for a menu entry: the [action] string
    with each [params] value appended as a [:value] segment, in the
    compiled JSON param order. Lets several radio members share one
    YAML [action] yet dispatch to distinct native commands without
    threading params through the menu view. Entries with no action
    yield an empty command (disabled placeholders). *)
let command_with_params (obj : (string * Yojson.Safe.t) list) : string =
  let action = match List.assoc_opt "action" obj with
    | Some (`String s) -> s | _ -> "" in
  match List.assoc_opt "params" obj with
  | Some (`Assoc params) ->
    List.fold_left (fun cmd (_, v) ->
      let seg = match v with
        | `String s -> s
        | `Int i -> string_of_int i
        | `Float f -> string_of_float f
        | `Bool b -> string_of_bool b
        | other -> Yojson.Safe.to_string other
      in
      cmd ^ ":" ^ seg
    ) action params
  | _ -> action

(** Cache the built item list per content id. The bundle is immutable
    for the process lifetime, so repeat menu opens reuse the parse. *)
let cache : (string, panel_menu_item list) Hashtbl.t = Hashtbl.create 16

let build (content_id : string) : panel_menu_item list =
  match Workspace_loader.load () with
  | None -> []
  | Some ws ->
    let menu = Workspace_loader.panel_menu ws content_id in
    (* Count how often each [action] recurs: a recurring action marks a
       radio group (the YAML expresses grouping by action sameness, not
       an explicit [group:] key). *)
    let action_counts : (string, int) Hashtbl.t = Hashtbl.create 8 in
    List.iter (fun e ->
      match e with
      | `Assoc obj ->
        (match List.assoc_opt "action" obj with
         | Some (`String a) ->
           Hashtbl.replace action_counts a
             (1 + (Option.value ~default:0 (Hashtbl.find_opt action_counts a)))
         | _ -> ())
      | _ -> ()
    ) menu;
    List.filter_map (fun e ->
      match e with
      | `String "separator" -> Some Separator
      | `Assoc obj ->
        (match List.assoc_opt "label" obj with
         | Some (`String label) ->
           let action = match List.assoc_opt "action" obj with
             | Some (`String s) -> Some s | _ -> None in
           let is_radio_member = match action with
             | Some a -> Option.value ~default:0 (Hashtbl.find_opt action_counts a) > 1
             | None -> false in
           (* Radio members share one action, so fold their params into
              the command to keep them distinguishable; every other
              entry keeps its action verbatim — folding params there
              would corrupt single-action commands like [close_panel]
              (params: { panel: ... }). *)
           let command =
             if is_radio_member then command_with_params obj
             else Option.value ~default:"" action in
           let has_checked =
             List.mem_assoc "checked" obj || List.mem_assoc "checked_when" obj in
           if has_checked && is_radio_member then
             Some (Radio { label; command;
                           group = Option.value ~default:"" action })
           else if has_checked then
             Some (Toggle { label; command })
           else
             (* Plain actions, dynamic submenus ([type: submenu], which
                carry an explicit [action:] so the menu view special-
                case keyed on the command still fires), and disabled
                placeholders (no [action:], gated off by the panel's
                enabled-state) all surface as [Action]. *)
             Some (Action { label; command; shortcut = "" })
         | _ -> None)
      | _ -> None
    ) menu

(** Build (or return the cached) menu items for a panel content id from
    the compiled bundle's [menu:] array. *)
let menu_items_from_yaml (content_id : string) : panel_menu_item list =
  match Hashtbl.find_opt cache content_id with
  | Some items -> items
  | None ->
    let items = build content_id in
    Hashtbl.replace cache content_id items;
    items
