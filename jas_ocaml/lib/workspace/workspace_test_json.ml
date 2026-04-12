(** Canonical Test JSON serialization for workspace layout cross-language
    equivalence testing.

    Follows the same conventions as {!Test_json}: sorted keys,
    normalized floats (4 decimals), all optional fields explicit (null),
    enums as lowercase strings.  Byte-for-byte comparison of the output
    is a valid equivalence check. *)

open Workspace_layout
open Pane

(* ------------------------------------------------------------------ *)
(* Float formatting (same as Test_json)                                *)
(* ------------------------------------------------------------------ *)

let fmt v =
  let rounded = Float.round (v *. 10000.0) /. 10000.0 in
  if rounded = Float.round rounded && Float.rem rounded 1.0 = 0.0 then
    Printf.sprintf "%.1f" rounded
  else begin
    let s = Printf.sprintf "%.4f" rounded in
    let len = ref (String.length s) in
    while !len > 0
          && s.[!len - 1] = '0'
          && !len >= 2
          && s.[!len - 2] <> '.' do
      decr len
    done;
    String.sub s 0 !len
  end

(* ------------------------------------------------------------------ *)
(* JSON building helpers (same as Test_json)                           *)
(* ------------------------------------------------------------------ *)

type json_obj = {
  mutable entries : (string * string) list;
}

let json_obj () = { entries = [] }

let json_str o key v =
  let escaped =
    v |> String.to_seq
      |> Seq.flat_map (fun c ->
        match c with
        | '\\' -> String.to_seq "\\\\"
        | '"'  -> String.to_seq "\\\""
        | c    -> Seq.return c)
      |> String.of_seq
  in
  o.entries <- (key, Printf.sprintf "\"%s\"" escaped) :: o.entries

let json_num o key v =
  o.entries <- (key, fmt v) :: o.entries

let json_int o key v =
  o.entries <- (key, string_of_int v) :: o.entries

let json_bool o key v =
  o.entries <- (key, if v then "true" else "false") :: o.entries

let json_null o key =
  o.entries <- (key, "null") :: o.entries

let json_raw o key v =
  o.entries <- (key, v) :: o.entries

let json_build o =
  let sorted = List.sort (fun (a, _) (b, _) -> String.compare a b) o.entries in
  let pairs = List.map (fun (k, v) -> Printf.sprintf "\"%s\":%s" k v) sorted in
  Printf.sprintf "{%s}" (String.concat "," pairs)

let json_array items =
  Printf.sprintf "[%s]" (String.concat "," items)

(* ------------------------------------------------------------------ *)
(* Enum -> lowercase string                                            *)
(* ------------------------------------------------------------------ *)

let dock_edge_str = function
  | Workspace_layout.Left -> "left"
  | Workspace_layout.Right -> "right"
  | Workspace_layout.Bottom -> "bottom"

let panel_kind_str = function
  | Layers -> "layers"
  | Color -> "color"
  | Stroke -> "stroke"
  | Properties -> "properties"

let pane_kind_str = function
  | Toolbar -> "toolbar"
  | Canvas -> "canvas"
  | Dock -> "dock"

let edge_side_str = function
  | Pane.Left -> "left"
  | Pane.Right -> "right"
  | Pane.Top -> "top"
  | Pane.Bottom -> "bottom"

let double_click_action_str = function
  | Maximize -> "maximize"
  | Redock -> "redock"
  | No_action -> "none"

(* ------------------------------------------------------------------ *)
(* Type serializers                                                    *)
(* ------------------------------------------------------------------ *)

let snap_target_json = function
  | Window_target edge ->
    let o = json_obj () in
    json_str o "window" (edge_side_str edge);
    json_build o
  | Pane_target (id, edge) ->
    let inner = json_obj () in
    json_str inner "edge" (edge_side_str edge);
    json_int inner "id" id;
    let o = json_obj () in
    json_raw o "pane" (json_build inner);
    json_build o

let snap_constraint_json (s : snap_constraint) =
  let o = json_obj () in
  json_str o "edge" (edge_side_str s.edge);
  json_int o "pane" s.snap_pane;
  json_raw o "target" (snap_target_json s.target);
  json_build o

let pane_config_json (c : pane_config) =
  let o = json_obj () in
  (match c.collapsed_width with
   | Some w -> json_num o "collapsed_width" w
   | None -> json_null o "collapsed_width");
  json_str o "double_click_action" (double_click_action_str c.double_click_action);
  json_bool o "fixed_width" c.fixed_width;
  json_str o "label" c.label;
  json_num o "min_height" c.min_height;
  json_num o "min_width" c.min_width;
  json_build o

let pane_json (p : pane) =
  let o = json_obj () in
  json_raw o "config" (pane_config_json p.config);
  json_num o "height" p.height;
  json_int o "id" p.id;
  json_str o "kind" (pane_kind_str p.kind);
  json_num o "width" p.width;
  json_num o "x" p.x;
  json_num o "y" p.y;
  json_build o

let pane_layout_json (pl : pane_layout) =
  let o = json_obj () in
  json_bool o "canvas_maximized" pl.canvas_maximized;
  let hidden = List.map (fun k -> Printf.sprintf "\"%s\"" (pane_kind_str k)) pl.hidden_panes in
  json_raw o "hidden_panes" (json_array hidden);
  json_int o "next_pane_id" pl.next_pane_id;
  let panes = Array.to_list pl.panes |> List.map pane_json in
  json_raw o "panes" (json_array panes);
  let snaps = List.map snap_constraint_json pl.snaps in
  json_raw o "snaps" (json_array snaps);
  json_num o "viewport_height" pl.viewport_height;
  json_num o "viewport_width" pl.viewport_width;
  let z = List.map string_of_int pl.z_order in
  json_raw o "z_order" (json_array z);
  json_build o

let panel_group_json (g : panel_group) =
  let o = json_obj () in
  json_int o "active" g.active;
  json_bool o "collapsed" g.collapsed;
  (match g.height with
   | Some h -> json_num o "height" h
   | None -> json_null o "height");
  let panels = Array.to_list g.panels |> List.map (fun k -> Printf.sprintf "\"%s\"" (panel_kind_str k)) in
  json_raw o "panels" (json_array panels);
  json_build o

let dock_json (d : dock) =
  let o = json_obj () in
  json_bool o "auto_hide" d.auto_hide;
  json_bool o "collapsed" d.collapsed;
  let groups = Array.to_list d.groups |> List.map panel_group_json in
  json_raw o "groups" (json_array groups);
  json_int o "id" d.id;
  json_num o "min_width" d.min_width;
  json_num o "width" d.width;
  json_build o

let floating_dock_json (fd : floating_dock) =
  let o = json_obj () in
  json_raw o "dock" (dock_json fd.dock);
  json_num o "x" fd.x;
  json_num o "y" fd.y;
  json_build o

let group_addr_json (g : group_addr) =
  let o = json_obj () in
  json_int o "dock_id" g.dock_id;
  json_int o "group_idx" g.group_idx;
  json_build o

let panel_addr_json (a : panel_addr) =
  let o = json_obj () in
  json_raw o "group" (group_addr_json a.group);
  json_int o "panel_idx" a.panel_idx;
  json_build o

(* ------------------------------------------------------------------ *)
(* Toolbar structure (static data for cross-language fixture)           *)
(* ------------------------------------------------------------------ *)

let toolbar_structure_json () =
  let slots = [
    (0, 0, ["selection"]);
    (0, 1, ["direct_selection"; "group_selection"]);
    (1, 0, ["pen"; "add_anchor_point"; "delete_anchor_point"; "anchor_point"]);
    (1, 1, ["pencil"; "path_eraser"; "smooth"]);
    (2, 0, ["type"; "type_on_path"]);
    (2, 1, ["line"]);
    (3, 0, ["rect"; "rounded_rect"; "polygon"; "star"]);
    (3, 1, ["lasso"]);
  ] in
  let total = List.fold_left (fun acc (_, _, tools) -> acc + List.length tools) 0 slots in
  let slot_jsons = List.map (fun (row, col, tools) ->
    let o = json_obj () in
    json_int o "col" col;
    json_int o "row" row;
    let tool_strs = List.map (fun t -> Printf.sprintf "\"%s\"" t) tools in
    json_raw o "tools" (json_array tool_strs);
    json_build o
  ) slots in
  let o = json_obj () in
  json_raw o "slots" (json_array slot_jsons);
  json_int o "total_tools" total;
  json_build o

(* ------------------------------------------------------------------ *)
(* Menu structure (static data for cross-language fixture)              *)
(* ------------------------------------------------------------------ *)

(** Menu bar definition mirroring jas_dioxus/src/workspace/menu.rs *)
let menu_bar = [
  ("File", [
    ("New", "new", "\xE2\x8C\x98N");
    ("Open...", "open", "\xE2\x8C\x98O");
    ("Save", "save", "\xE2\x8C\x98S");
    ("---", "", "");
    ("Close Tab", "close", "\xE2\x8C\x98W");
  ]);
  ("Edit", [
    ("Undo", "undo", "\xE2\x8C\x98Z");
    ("Redo", "redo", "\xE2\x87\xA7\xE2\x8C\x98Z");
    ("---", "", "");
    ("Cut", "cut", "\xE2\x8C\x98X");
    ("Copy", "copy", "\xE2\x8C\x98C");
    ("Paste", "paste", "\xE2\x8C\x98V");
    ("Paste in Place", "paste_in_place", "\xE2\x87\xA7\xE2\x8C\x98V");
    ("---", "", "");
    ("Delete", "delete", "\xE2\x8C\xAB");
    ("Select All", "select_all", "\xE2\x8C\x98A");
  ]);
  ("Object", [
    ("Group", "group", "\xE2\x8C\x98G");
    ("Ungroup", "ungroup", "\xE2\x87\xA7\xE2\x8C\x98G");
    ("Ungroup All", "ungroup_all", "");
    ("---", "", "");
    ("Lock", "lock", "\xE2\x8C\x982");
    ("Unlock All", "unlock_all", "\xE2\x8C\xA5\xE2\x8C\x982");
    ("---", "", "");
    ("Hide", "hide", "\xE2\x8C\x983");
    ("Show All", "show_all", "\xE2\x8C\xA5\xE2\x8C\x983");
  ]);
  ("Window", [
    ("Workspace \xE2\x96\xB6", "workspace_submenu", "");
    ("---", "", "");
    ("Tile", "tile_panes", "");
    ("---", "", "");
    ("Toolbar", "toggle_pane_toolbar", "");
    ("Panels", "toggle_pane_dock", "");
    ("---", "", "");
    ("Layers", "toggle_panel_layers", "");
    ("Color", "toggle_panel_color", "");
    ("Stroke", "toggle_panel_stroke", "");
    ("Properties", "toggle_panel_properties", "");
  ]);
]

let menu_structure_json () =
  let total = List.fold_left (fun acc (_, items) -> acc + List.length items) 0 menu_bar in
  let menu_jsons = List.map (fun (title, items) ->
    let item_jsons = List.map (fun (label, cmd, shortcut) ->
      if label = "---" then begin
        let o = json_obj () in
        json_bool o "separator" true;
        json_build o
      end else begin
        let o = json_obj () in
        json_str o "command" cmd;
        json_str o "label" label;
        json_str o "shortcut" shortcut;
        json_build o
      end
    ) items in
    let o = json_obj () in
    json_raw o "items" (json_array item_jsons);
    json_str o "title" title;
    json_build o
  ) menu_bar in
  let o = json_obj () in
  json_raw o "menus" (json_array menu_jsons);
  json_int o "total_items" total;
  json_build o

(* ------------------------------------------------------------------ *)
(* State defaults (must match workspace/state.yaml)                    *)
(* ------------------------------------------------------------------ *)

let state_defaults_json () =
  let vars = [
    ("active_tab", "number", "-1");
    ("active_tool", "enum", "\"selection\"");
    ("canvas_maximized", "bool", "false");
    ("canvas_visible", "bool", "true");
    ("color_visible", "bool", "true");
    ("dock_collapsed", "bool", "false");
    ("dock_group0_active", "number", "0");
    ("dock_group0_collapsed", "bool", "false");
    ("dock_group1_active", "number", "0");
    ("dock_group1_collapsed", "bool", "false");
    ("dock_visible", "bool", "true");
    ("fill_color", "color", "\"#ffffff\"");
    ("fill_on_top", "bool", "true");
    ("layers_visible", "bool", "true");
    ("properties_visible", "bool", "true");
    ("stroke_color", "color", "\"#000000\"");
    ("stroke_visible", "bool", "true");
    ("stroke_width", "number", "1");
    ("tab_count", "number", "0");
    ("toolbar_visible", "bool", "true");
  ] in
  let var_jsons = List.map (fun (name, stype, def_val) ->
    let o = json_obj () in
    json_raw o "default" def_val;
    json_str o "name" name;
    json_str o "type" stype;
    json_build o
  ) vars in
  let o = json_obj () in
  json_int o "count" (List.length vars);
  json_raw o "variables" (json_array var_jsons);
  json_build o

(* ------------------------------------------------------------------ *)
(* Shortcut structure (must match workspace/shortcuts.yaml)            *)
(* ------------------------------------------------------------------ *)

let shortcut_structure_json () =
  let shortcuts = [
    ("Ctrl+N", "new_document", None);
    ("Ctrl+O", "open_file", None);
    ("Ctrl+S", "save", None);
    ("Ctrl+Shift+S", "save_as", None);
    ("Ctrl+Q", "quit", None);
    ("Ctrl+Z", "undo", None);
    ("Ctrl+Shift+Z", "redo", None);
    ("Ctrl+X", "cut", None);
    ("Ctrl+C", "copy", None);
    ("Ctrl+V", "paste", None);
    ("Ctrl+Shift+V", "paste_in_place", None);
    ("Ctrl+A", "select_all", None);
    ("Delete", "delete_selection", None);
    ("Backspace", "delete_selection", None);
    ("Ctrl+G", "group", None);
    ("Ctrl+Shift+G", "ungroup", None);
    ("Ctrl+2", "lock", None);
    ("Ctrl+Alt+2", "unlock_all", None);
    ("Ctrl+3", "hide_selection", None);
    ("Ctrl+Alt+3", "show_all", None);
    ("Ctrl+=", "zoom_in", None);
    ("Ctrl+-", "zoom_out", None);
    ("Ctrl+0", "fit_in_window", None);
    ("V", "select_tool", Some ("tool", "selection"));
    ("A", "select_tool", Some ("tool", "direct_selection"));
    ("P", "select_tool", Some ("tool", "pen"));
    ("=", "select_tool", Some ("tool", "add_anchor"));
    ("-", "select_tool", Some ("tool", "delete_anchor"));
    ("T", "select_tool", Some ("tool", "type"));
    ("\\", "select_tool", Some ("tool", "line"));
    ("M", "select_tool", Some ("tool", "rect"));
    ("N", "select_tool", Some ("tool", "pencil"));
    ("Shift+E", "select_tool", Some ("tool", "path_eraser"));
    ("Q", "select_tool", Some ("tool", "lasso"));
    ("D", "reset_fill_stroke", None);
    ("X", "toggle_fill_on_top", None);
    ("Shift+X", "swap_fill_stroke", None);
  ] in
  let shortcut_jsons = List.map (fun (key, action, params) ->
    let o = json_obj () in
    json_str o "action" action;
    json_str o "key" key;
    (match params with
     | Some (pk, pv) ->
       let po = json_obj () in
       json_str po pk pv;
       json_raw o "params" (json_build po)
     | None -> json_null o "params");
    json_build o
  ) shortcuts in
  let o = json_obj () in
  json_int o "count" (List.length shortcuts);
  json_raw o "shortcuts" (json_array shortcut_jsons);
  json_build o

(* ------------------------------------------------------------------ *)
(* Public API: workspace -> test JSON                                  *)
(* ------------------------------------------------------------------ *)

let workspace_to_test_json (layout : workspace_layout) =
  let o = json_obj () in

  (* anchored: array of {dock, edge} *)
  let anchored = List.map (fun (edge, d) ->
    let ao = json_obj () in
    json_raw ao "dock" (dock_json d);
    json_str ao "edge" (dock_edge_str edge);
    json_build ao
  ) layout.anchored in
  json_raw o "anchored" (json_array anchored);

  (* floating *)
  let floating = List.map floating_dock_json layout.floating in
  json_raw o "floating" (json_array floating);

  (* focused_panel *)
  (match layout.focused_panel with
   | Some a -> json_raw o "focused_panel" (panel_addr_json a)
   | None -> json_null o "focused_panel");

  (* hidden_panels *)
  let hidden = List.map (fun k -> Printf.sprintf "\"%s\"" (panel_kind_str k)) layout.hidden_panels in
  json_raw o "hidden_panels" (json_array hidden);

  (* name *)
  json_str o "name" layout.name;

  (* next_id *)
  json_int o "next_id" layout.next_id;

  (* pane_layout *)
  (match layout.pane_layout with
   | Some pl -> json_raw o "pane_layout" (pane_layout_json pl)
   | None -> json_null o "pane_layout");

  (* version *)
  json_int o "version" layout.version;

  (* z_order *)
  let z = List.map string_of_int layout.z_order in
  json_raw o "z_order" (json_array z);

  json_build o

(* ------------------------------------------------------------------ *)
(* Public API: test JSON -> workspace                                  *)
(* ------------------------------------------------------------------ *)

open Yojson.Safe.Util

let to_num j =
  try to_float j with _ -> float_of_int (to_int j)

let parse_dock_edge j =
  match to_string j with
  | "left" -> Workspace_layout.Left
  | "bottom" -> Workspace_layout.Bottom
  | _ -> Workspace_layout.Right

let parse_panel_kind_str s =
  match s with
  | "color" -> Color
  | "stroke" -> Stroke
  | "properties" -> Properties
  | _ -> Layers

let parse_panel_kind j = parse_panel_kind_str (to_string j)

let parse_pane_kind_str s =
  match s with
  | "toolbar" -> Toolbar
  | "dock" -> Dock
  | _ -> Canvas

let parse_pane_kind j = parse_pane_kind_str (to_string j)

let parse_edge_side j =
  match to_string j with
  | "right" -> Pane.Right
  | "top" -> Pane.Top
  | "bottom" -> Pane.Bottom
  | _ -> Pane.Left

let parse_double_click_action j =
  match to_string j with
  | "maximize" -> Maximize
  | "redock" -> Redock
  | _ -> No_action

let parse_snap_target j =
  try
    let edge_str = j |> member "window" in
    if edge_str <> `Null then
      Window_target (parse_edge_side edge_str)
    else raise Not_found
  with _ ->
    let pane_obj = j |> member "pane" in
    if pane_obj <> `Null then
      Pane_target (
        pane_obj |> member "id" |> to_int,
        parse_edge_side (pane_obj |> member "edge"))
    else
      Window_target Pane.Left

let parse_snap_constraint j =
  { snap_pane = j |> member "pane" |> to_int;
    edge = parse_edge_side (j |> member "edge");
    target = parse_snap_target (j |> member "target"); }

let parse_pane_config j =
  let collapsed_width =
    let cw = j |> member "collapsed_width" in
    if cw = `Null then None else Some (to_num cw)
  in
  { label = j |> member "label" |> to_string;
    min_width = j |> member "min_width" |> to_num;
    min_height = j |> member "min_height" |> to_num;
    fixed_width = j |> member "fixed_width" |> to_bool;
    collapsed_width;
    double_click_action = parse_double_click_action (j |> member "double_click_action"); }

let parse_pane j =
  { id = j |> member "id" |> to_int;
    kind = parse_pane_kind (j |> member "kind");
    config = parse_pane_config (j |> member "config");
    x = j |> member "x" |> to_num;
    y = j |> member "y" |> to_num;
    width = j |> member "width" |> to_num;
    height = j |> member "height" |> to_num; }

let parse_pane_layout j =
  let panes = j |> member "panes" |> to_list |> List.map parse_pane |> Array.of_list in
  let snaps = j |> member "snaps" |> to_list |> List.map parse_snap_constraint in
  let z_order = j |> member "z_order" |> to_list |> List.map to_int in
  let hidden_panes = j |> member "hidden_panes" |> to_list |> List.map parse_pane_kind in
  { panes;
    snaps;
    z_order;
    hidden_panes;
    canvas_maximized = j |> member "canvas_maximized" |> to_bool;
    viewport_width = j |> member "viewport_width" |> to_num;
    viewport_height = j |> member "viewport_height" |> to_num;
    next_pane_id = j |> member "next_pane_id" |> to_int; }

let parse_panel_group j =
  let panels = j |> member "panels" |> to_list |> List.map parse_panel_kind |> Array.of_list in
  let height_j = j |> member "height" in
  { panels;
    active = j |> member "active" |> to_int;
    collapsed = j |> member "collapsed" |> to_bool;
    height = if height_j = `Null then None else Some (to_num height_j); }

let parse_dock j =
  let groups = j |> member "groups" |> to_list |> List.map parse_panel_group |> Array.of_list in
  { id = j |> member "id" |> to_int;
    groups;
    collapsed = j |> member "collapsed" |> to_bool;
    auto_hide = j |> member "auto_hide" |> to_bool;
    width = j |> member "width" |> to_num;
    min_width = j |> member "min_width" |> to_num; }

let parse_floating_dock j =
  { dock = parse_dock (j |> member "dock");
    x = j |> member "x" |> to_num;
    y = j |> member "y" |> to_num; }

let parse_group_addr j =
  { dock_id = j |> member "dock_id" |> to_int;
    group_idx = j |> member "group_idx" |> to_int; }

let parse_panel_addr j =
  { group = parse_group_addr (j |> member "group");
    panel_idx = j |> member "panel_idx" |> to_int; }

let test_json_to_workspace json_str =
  let j = Yojson.Safe.from_string json_str in

  let anchored = j |> member "anchored" |> to_list |> List.map (fun a ->
    (parse_dock_edge (a |> member "edge"),
     parse_dock (a |> member "dock"))
  ) in

  let floating = j |> member "floating" |> to_list |> List.map parse_floating_dock in

  let hidden_panels = j |> member "hidden_panels" |> to_list |> List.map parse_panel_kind in

  let z_order = j |> member "z_order" |> to_list |> List.map to_int in

  let focused_panel_j = j |> member "focused_panel" in
  let focused_panel =
    if focused_panel_j = `Null then None
    else Some (parse_panel_addr focused_panel_j)
  in

  let pane_layout_j = j |> member "pane_layout" in
  let pane_layout =
    if pane_layout_j = `Null then None
    else Some (parse_pane_layout pane_layout_j)
  in

  let name = j |> member "name" |> to_string in
  let version = j |> member "version" |> to_int in
  let next_id = j |> member "next_id" |> to_int in

  { version;
    name;
    anchored;
    floating;
    hidden_panels;
    z_order;
    focused_panel;
    pane_layout;
    next_id;
    generation = 0;
    saved_generation = 0; }
