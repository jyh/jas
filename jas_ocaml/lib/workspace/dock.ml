(** Dock and panel infrastructure.

    A {!dock_layout} manages multiple docks: anchored docks snapped to screen
    edges and floating docks at arbitrary positions. Each {!dock} contains a
    vertical list of {!panel_group}s. Each group has tabbed {!panel_kind}
    entries, one of which is active at a time.

    This module contains only pure data types and state operations — no
    rendering code. *)

(* ------------------------------------------------------------------ *)
(* Constants                                                          *)
(* ------------------------------------------------------------------ *)

let min_dock_width = 150.0
let max_dock_width = 500.0
let min_group_height = 40.0
let _min_canvas_width = 200.0
let default_dock_width = 240.0
let default_floating_width = 220.0
let snap_distance = 20.0
let default_layout_name = "Default"

(* ------------------------------------------------------------------ *)
(* Core types                                                         *)
(* ------------------------------------------------------------------ *)

type dock_id = int

type dock_edge = Left | Right | Bottom

type panel_kind = Layers | Color | Stroke | Properties

type panel_group = {
  mutable panels : panel_kind array;
  mutable active : int;
  mutable collapsed : bool;
  mutable height : float option;
}

type dock = {
  id : dock_id;
  mutable groups : panel_group array;
  mutable collapsed : bool;
  mutable auto_hide : bool;
  mutable width : float;
  min_width : float;
}

type floating_dock = {
  dock : dock;
  mutable x : float;
  mutable y : float;
}

(* ------------------------------------------------------------------ *)
(* Addressing                                                         *)
(* ------------------------------------------------------------------ *)

type group_addr = {
  dock_id : dock_id;
  group_idx : int;
}

type panel_addr = {
  group : group_addr;
  panel_idx : int;
}

(* ------------------------------------------------------------------ *)
(* Drag state types                                                   *)
(* ------------------------------------------------------------------ *)

type drag_payload =
  | Drag_group of group_addr
  | Drag_panel of panel_addr

type drop_target =
  | Group_slot of { dock_id : dock_id; group_idx : int }
  | Tab_bar of { group : group_addr; index : int }
  | Edge of dock_edge

(* ------------------------------------------------------------------ *)
(* AppConfig                                                          *)
(* ------------------------------------------------------------------ *)

type app_config = {
  mutable active_layout : string;
  mutable saved_layouts : string list;
}

let default_app_config () = {
  active_layout = default_layout_name;
  saved_layouts = [default_layout_name];
}

let register_layout config name =
  if not (List.mem name config.saved_layouts) then
    config.saved_layouts <- config.saved_layouts @ [name]

(* ------------------------------------------------------------------ *)
(* Helpers                                                            *)
(* ------------------------------------------------------------------ *)

let make_panel_group panels = {
  panels = Array.of_list panels;
  active = 0;
  collapsed = false;
  height = None;
}

let active_panel g =
  if g.active < Array.length g.panels then Some g.panels.(g.active)
  else None

let make_dock id groups width = {
  id;
  groups = Array.of_list (List.map make_panel_group groups);
  collapsed = false;
  auto_hide = false;
  width;
  min_width = min_dock_width;
}

(* ------------------------------------------------------------------ *)
(* DockLayout                                                         *)
(* ------------------------------------------------------------------ *)

let layout_version = 2

type dock_layout = {
  mutable version : int;
  mutable name : string;
  mutable anchored : (dock_edge * dock) list;
  mutable floating : floating_dock list;
  mutable hidden_panels : panel_kind list;
  mutable z_order : dock_id list;
  mutable focused_panel : panel_addr option;
  mutable pane_layout : Pane.pane_layout option;
  mutable next_id : int;
  mutable generation : int;
  mutable saved_generation : int;
}

(* ------------------------------------------------------------------ *)
(* Construction                                                       *)
(* ------------------------------------------------------------------ *)

let named name = {
  version = layout_version;
  name;
  anchored = [(Right, make_dock 0 [[Layers]; [Color; Stroke; Properties]] default_dock_width)];
  floating = [];
  hidden_panels = [];
  z_order = [];
  focused_panel = None;
  pane_layout = None;
  next_id = 1;
  generation = 0;
  saved_generation = 0;
}

let default_layout () = named default_layout_name

let bump l = l.generation <- l.generation + 1
let needs_save l = l.generation <> l.saved_generation
let mark_saved l = l.saved_generation <- l.generation

(* ------------------------------------------------------------------ *)
(* Dock lookup                                                        *)
(* ------------------------------------------------------------------ *)

let find_dock l id =
  match List.find_opt (fun (_, d) -> d.id = id) l.anchored with
  | Some (_, d) -> Some d
  | None ->
    match List.find_opt (fun fd -> fd.dock.id = id) l.floating with
    | Some fd -> Some fd.dock
    | None -> None

let anchored_dock l edge =
  match List.find_opt (fun (e, _) -> e = edge) l.anchored with
  | Some (_, d) -> Some d
  | None -> None

let floating_dock l id =
  List.find_opt (fun fd -> fd.dock.id = id) l.floating

let next_dock_id l =
  let id = l.next_id in
  l.next_id <- l.next_id + 1;
  id

(* ------------------------------------------------------------------ *)
(* Array helpers                                                      *)
(* ------------------------------------------------------------------ *)

let array_remove arr i =
  let n = Array.length arr in
  if i < 0 || i >= n then arr
  else Array.init (n - 1) (fun j -> if j < i then arr.(j) else arr.(j + 1))

let array_insert arr i v =
  let n = Array.length arr in
  let i = max 0 (min i n) in
  Array.init (n + 1) (fun j ->
    if j < i then arr.(j)
    else if j = i then v
    else arr.(j - 1))

(* ------------------------------------------------------------------ *)
(* Cleanup                                                            *)
(* ------------------------------------------------------------------ *)

let cleanup l dock_id =
  (match find_dock l dock_id with
   | Some d ->
     d.groups <- Array.of_list (Array.to_list d.groups |> List.filter (fun g -> Array.length g.panels > 0));
     Array.iter (fun g ->
       if g.active >= Array.length g.panels && Array.length g.panels > 0 then
         g.active <- Array.length g.panels - 1
     ) d.groups
   | None -> ());
  let removed = List.filter_map (fun fd ->
    if Array.length fd.dock.groups = 0 then Some fd.dock.id else None
  ) l.floating in
  l.floating <- List.filter (fun fd -> Array.length fd.dock.groups > 0) l.floating;
  l.z_order <- List.filter (fun id -> not (List.mem id removed)) l.z_order

(* ------------------------------------------------------------------ *)
(* Collapse                                                           *)
(* ------------------------------------------------------------------ *)

let toggle_dock_collapsed l id =
  (match find_dock l id with
   | Some d -> d.collapsed <- not d.collapsed
   | None -> ());
  bump l

let toggle_group_collapsed l addr =
  (match find_dock l addr.dock_id with
   | Some d when addr.group_idx < Array.length d.groups ->
     let g = d.groups.(addr.group_idx) in
     g.collapsed <- not g.collapsed
   | _ -> ());
  bump l

(* ------------------------------------------------------------------ *)
(* Active panel                                                       *)
(* ------------------------------------------------------------------ *)

let set_active_panel l addr =
  (match find_dock l addr.group.dock_id with
   | Some d when addr.group.group_idx < Array.length d.groups ->
     let g = d.groups.(addr.group.group_idx) in
     if addr.panel_idx < Array.length g.panels then
       g.active <- addr.panel_idx
   | _ -> ());
  bump l

(* ------------------------------------------------------------------ *)
(* Move group within dock                                             *)
(* ------------------------------------------------------------------ *)

let move_group_within_dock l dock_id ~from ~to_ =
  (match find_dock l dock_id with
   | Some d when from < Array.length d.groups ->
     let group = d.groups.(from) in
     let groups = array_remove d.groups from in
     let to_ = min to_ (Array.length groups) in
     d.groups <- array_insert groups to_ group
   | _ -> ());
  bump l

(* ------------------------------------------------------------------ *)
(* Move group between docks                                           *)
(* ------------------------------------------------------------------ *)

let move_group_to_dock l ~from ~to_dock ~to_idx =
  (match find_dock l from.dock_id with
   | Some src_d when from.group_idx < Array.length src_d.groups ->
     let group = src_d.groups.(from.group_idx) in
     src_d.groups <- array_remove src_d.groups from.group_idx;
     (match find_dock l to_dock with
      | Some dst_d ->
        let idx = min to_idx (Array.length dst_d.groups) in
        dst_d.groups <- array_insert dst_d.groups idx group;
        cleanup l from.dock_id;
        bump l
      | None ->
        (* Put it back *)
        let idx = min from.group_idx (Array.length src_d.groups) in
        src_d.groups <- array_insert src_d.groups idx group)
   | _ -> ())

(* ------------------------------------------------------------------ *)
(* Detach group                                                       *)
(* ------------------------------------------------------------------ *)

let detach_group l ~from ~x ~y =
  match find_dock l from.dock_id with
  | Some src_d when from.group_idx < Array.length src_d.groups ->
    let group = src_d.groups.(from.group_idx) in
    src_d.groups <- array_remove src_d.groups from.group_idx;
    let id = next_dock_id l in
    let new_dock = { id; groups = [|group|]; collapsed = false; auto_hide = false;
                     width = default_floating_width; min_width = min_dock_width } in
    l.floating <- l.floating @ [{ dock = new_dock; x; y }];
    l.z_order <- l.z_order @ [id];
    cleanup l from.dock_id;
    bump l;
    Some id
  | _ -> None

(* ------------------------------------------------------------------ *)
(* Reorder panel within group                                         *)
(* ------------------------------------------------------------------ *)

let reorder_panel l ~group ~from ~to_ =
  (match find_dock l group.dock_id with
   | Some d when group.group_idx < Array.length d.groups ->
     let g = d.groups.(group.group_idx) in
     if from < Array.length g.panels then begin
       let panel = g.panels.(from) in
       let panels = array_remove g.panels from in
       let to_ = min to_ (Array.length panels) in
       g.panels <- array_insert panels to_ panel;
       g.active <- to_
     end
   | _ -> ());
  bump l

(* ------------------------------------------------------------------ *)
(* Move panel between groups                                          *)
(* ------------------------------------------------------------------ *)

let move_panel_to_group l ~from ~to_ =
  if from.group = to_ then ()
  else
    match find_dock l from.group.dock_id with
    | Some src_d when from.group.group_idx < Array.length src_d.groups ->
      let src_g = src_d.groups.(from.group.group_idx) in
      if from.panel_idx < Array.length src_g.panels then begin
        let panel = src_g.panels.(from.panel_idx) in
        src_g.panels <- array_remove src_g.panels from.panel_idx;
        match find_dock l to_.dock_id with
        | Some dst_d when to_.group_idx < Array.length dst_d.groups ->
          let dst_g = dst_d.groups.(to_.group_idx) in
          dst_g.panels <- Array.append dst_g.panels [|panel|];
          dst_g.active <- Array.length dst_g.panels - 1;
          cleanup l from.group.dock_id;
          bump l
        | _ ->
          (* Put it back *)
          let idx = min from.panel_idx (Array.length src_g.panels) in
          src_g.panels <- array_insert src_g.panels idx panel
      end
    | _ -> ()

(* ------------------------------------------------------------------ *)
(* Insert panel as new group                                          *)
(* ------------------------------------------------------------------ *)

let insert_panel_as_new_group l ~from ~to_dock ~at_idx =
  match find_dock l from.group.dock_id with
  | Some src_d when from.group.group_idx < Array.length src_d.groups ->
    let src_g = src_d.groups.(from.group.group_idx) in
    if from.panel_idx < Array.length src_g.panels then begin
      let panel = src_g.panels.(from.panel_idx) in
      src_g.panels <- array_remove src_g.panels from.panel_idx;
      match find_dock l to_dock with
      | Some dst_d ->
        let idx = min at_idx (Array.length dst_d.groups) in
        dst_d.groups <- array_insert dst_d.groups idx (make_panel_group [panel]);
        cleanup l from.group.dock_id;
        bump l
      | None ->
        let idx = min from.panel_idx (Array.length src_g.panels) in
        src_g.panels <- array_insert src_g.panels idx panel
    end
  | _ -> ()

(* ------------------------------------------------------------------ *)
(* Detach panel                                                       *)
(* ------------------------------------------------------------------ *)

let detach_panel l ~from ~x ~y =
  match find_dock l from.group.dock_id with
  | Some src_d when from.group.group_idx < Array.length src_d.groups ->
    let src_g = src_d.groups.(from.group.group_idx) in
    if from.panel_idx < Array.length src_g.panels then begin
      let panel = src_g.panels.(from.panel_idx) in
      src_g.panels <- array_remove src_g.panels from.panel_idx;
      let id = next_dock_id l in
      let g = make_panel_group [panel] in
      let new_dock = { id; groups = [|g|]; collapsed = false; auto_hide = false;
                       width = default_floating_width; min_width = min_dock_width } in
      l.floating <- l.floating @ [{ dock = new_dock; x; y }];
      l.z_order <- l.z_order @ [id];
      cleanup l from.group.dock_id;
      bump l;
      Some id
    end else None
  | _ -> None

(* ------------------------------------------------------------------ *)
(* Floating position                                                  *)
(* ------------------------------------------------------------------ *)

let set_floating_position l id ~x ~y =
  List.iter (fun fd ->
    if fd.dock.id = id then begin fd.x <- x; fd.y <- y end
  ) l.floating;
  bump l

(* ------------------------------------------------------------------ *)
(* Resize                                                             *)
(* ------------------------------------------------------------------ *)

let resize_group l addr ~height =
  (match find_dock l addr.dock_id with
   | Some d when addr.group_idx < Array.length d.groups ->
     d.groups.(addr.group_idx).height <- Some (max height min_group_height)
   | _ -> ());
  bump l

let set_dock_width l id ~width =
  (match find_dock l id with
   | Some d ->
     d.width <- max d.min_width (min width max_dock_width)
   | None -> ());
  bump l

(* ------------------------------------------------------------------ *)
(* Labels                                                             *)
(* ------------------------------------------------------------------ *)

let panel_label = function
  | Layers -> "Layers"
  | Color -> "Color"
  | Stroke -> "Stroke"
  | Properties -> "Properties"

(* ------------------------------------------------------------------ *)
(* Close / show panels                                                *)
(* ------------------------------------------------------------------ *)

let close_panel l addr =
  (match find_dock l addr.group.dock_id with
   | Some d when addr.group.group_idx < Array.length d.groups ->
     let g = d.groups.(addr.group.group_idx) in
     if addr.panel_idx < Array.length g.panels then begin
       let panel = g.panels.(addr.panel_idx) in
       g.panels <- array_remove g.panels addr.panel_idx;
       if not (List.mem panel l.hidden_panels) then
         l.hidden_panels <- l.hidden_panels @ [panel]
     end
   | _ -> ());
  cleanup l addr.group.dock_id;
  bump l

let show_panel l kind =
  if List.mem kind l.hidden_panels then begin
    l.hidden_panels <- List.filter (fun k -> k <> kind) l.hidden_panels;
    (match l.anchored with
     | (_, d) :: _ ->
       if Array.length d.groups = 0 then
         d.groups <- [|make_panel_group [kind]|]
       else begin
         let g = d.groups.(0) in
         g.panels <- Array.append g.panels [|kind|];
         g.active <- Array.length g.panels - 1
       end
     | [] -> ());
    bump l
  end

let is_panel_visible l kind =
  not (List.mem kind l.hidden_panels)

let panel_menu_items l =
  let all = [Layers; Color; Stroke; Properties] in
  List.map (fun k -> (k, is_panel_visible l k)) all

(* ------------------------------------------------------------------ *)
(* Z-index                                                            *)
(* ------------------------------------------------------------------ *)

let bring_to_front l id =
  if List.mem id l.z_order then begin
    l.z_order <- List.filter (fun zid -> zid <> id) l.z_order;
    l.z_order <- l.z_order @ [id]
  end;
  bump l

let z_index_for l id =
  let rec find i = function
    | [] -> 0
    | hd :: _ when hd = id -> i
    | _ :: tl -> find (i + 1) tl
  in find 0 l.z_order

(* ------------------------------------------------------------------ *)
(* Snap & re-dock                                                     *)
(* ------------------------------------------------------------------ *)

let snap_to_edge l id edge =
  match List.find_opt (fun fd -> fd.dock.id = id) l.floating with
  | None -> ()
  | Some fdock ->
    l.floating <- List.filter (fun fd -> fd.dock.id <> id) l.floating;
    l.z_order <- List.filter (fun zid -> zid <> id) l.z_order;
    (match List.find_opt (fun (e, _) -> e = edge) l.anchored with
     | Some (_, d) ->
       d.groups <- Array.append d.groups fdock.dock.groups
     | None ->
       l.anchored <- l.anchored @ [(edge, fdock.dock)]);
    bump l

let redock l id = snap_to_edge l id Right

let is_near_edge ~x ~y ~viewport_w ~viewport_h =
  if x <= snap_distance then Some Left
  else if x >= viewport_w -. snap_distance then Some Right
  else if y >= viewport_h -. snap_distance then Some Bottom
  else None

(* ------------------------------------------------------------------ *)
(* Multi-edge                                                         *)
(* ------------------------------------------------------------------ *)

let add_anchored_dock l edge =
  match List.find_opt (fun (e, _) -> e = edge) l.anchored with
  | Some (_, d) -> d.id
  | None ->
    let id = next_dock_id l in
    l.anchored <- l.anchored @ [(edge, { id; groups = [||]; collapsed = false;
                                         auto_hide = false; width = default_dock_width;
                                         min_width = min_dock_width })];
    bump l;
    id

let remove_anchored_dock l edge =
  match List.find_opt (fun (e, _) -> e = edge) l.anchored with
  | None -> None
  | Some (_, d) ->
    l.anchored <- List.filter (fun (e, _) -> e <> edge) l.anchored;
    if Array.length d.groups = 0 then None
    else begin
      let fid = next_dock_id l in
      let new_dock = { id = fid; groups = d.groups; collapsed = false;
                       auto_hide = false; width = d.width; min_width = min_dock_width } in
      l.floating <- l.floating @ [{ dock = new_dock; x = 100.0; y = 100.0 }];
      l.z_order <- l.z_order @ [fid];
      bump l;
      Some fid
    end

(* ------------------------------------------------------------------ *)
(* Context-sensitive                                                  *)
(* ------------------------------------------------------------------ *)

let panels_for_selection ~has_selection ~has_text:_ =
  let panels = [Layers] in
  if has_selection then panels @ [Properties; Color; Stroke]
  else panels

(* ------------------------------------------------------------------ *)
(* Persistence                                                        *)
(* ------------------------------------------------------------------ *)

let reset_to_default l =
  let n = l.name in
  let fresh = named n in
  l.version <- fresh.version;
  l.name <- fresh.name;
  l.anchored <- fresh.anchored;
  l.floating <- fresh.floating;
  l.hidden_panels <- fresh.hidden_panels;
  l.z_order <- fresh.z_order;
  l.focused_panel <- fresh.focused_panel;
  l.pane_layout <- None;
  l.next_id <- fresh.next_id;
  bump l

let storage_prefix = "jas_layout:"
let storage_key l = storage_prefix ^ l.name
let storage_key_for name = storage_prefix ^ name

let config_dir () =
  let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
  let dir = Filename.concat home ".config/jas" in
  (try Unix.mkdir (Filename.concat home ".config") 0o755 with Unix.Unix_error _ -> ());
  (try Unix.mkdir dir 0o755 with Unix.Unix_error _ -> ());
  dir

let layout_file_for name =
  Filename.concat (config_dir ()) (name ^ ".json")

let config_file () =
  Filename.concat (config_dir ()) "app_config.json"

(* -- JSON serialization -- *)

let edge_to_json = function Left -> "Left" | Right -> "Right" | Bottom -> "Bottom"
let edge_of_json = function "Left" -> Left | "Right" -> Right | _ -> Bottom

let kind_to_json = function
  | Layers -> "Layers" | Color -> "Color" | Stroke -> "Stroke" | Properties -> "Properties"
let kind_of_json = function
  | "Layers" -> Layers | "Color" -> Color | "Stroke" -> Stroke | _ -> Properties

let panel_group_to_json g : Yojson.Safe.t =
  `Assoc [
    "panels", `List (Array.to_list (Array.map (fun k -> `String (kind_to_json k)) g.panels));
    "active", `Int g.active;
    "collapsed", `Bool g.collapsed;
    "height", (match g.height with None -> `Null | Some h -> `Float h);
  ]

let panel_group_of_json (j : Yojson.Safe.t) =
  let open Yojson.Safe.Util in
  let panels = j |> member "panels" |> to_list |> List.map (fun s -> kind_of_json (to_string s)) in
  { panels = Array.of_list panels;
    active = j |> member "active" |> to_int;
    collapsed = j |> member "collapsed" |> to_bool;
    height = (match j |> member "height" with `Null -> None | h -> Some (to_float h)); }

let dock_to_json d : Yojson.Safe.t =
  `Assoc [
    "id", `Int d.id;
    "groups", `List (Array.to_list (Array.map panel_group_to_json d.groups));
    "collapsed", `Bool d.collapsed;
    "auto_hide", `Bool d.auto_hide;
    "width", `Float d.width;
  ]

let dock_of_json (j : Yojson.Safe.t) =
  let open Yojson.Safe.Util in
  { id = j |> member "id" |> to_int;
    groups = Array.of_list (j |> member "groups" |> to_list |> List.map panel_group_of_json);
    collapsed = j |> member "collapsed" |> to_bool;
    auto_hide = j |> member "auto_hide" |> to_bool;
    width = j |> member "width" |> to_float;
    min_width = min_dock_width; }

(* -- Pane layout JSON -- *)

let pane_kind_to_json = function
  | Pane.Toolbar -> "Toolbar" | Pane.Canvas -> "Canvas" | Pane.Dock -> "Dock"

let pane_kind_of_json = function
  | "Toolbar" -> Pane.Toolbar | "Canvas" -> Pane.Canvas | "Dock" -> Pane.Dock
  | _ -> Pane.Canvas

let edge_side_to_json = function
  | Pane.Left -> "Left" | Pane.Right -> "Right" | Pane.Top -> "Top" | Pane.Bottom -> "Bottom"

let edge_side_of_json = function
  | "Left" -> Pane.Left | "Right" -> Pane.Right | "Top" -> Pane.Top | "Bottom" -> Pane.Bottom
  | _ -> Pane.Left

let tile_width_to_json : Pane.tile_width -> Yojson.Safe.t = function
  | Fixed w -> `Assoc ["Fixed", `Float w]
  | Keep_current -> `String "KeepCurrent"
  | Flex -> `String "Flex"

let tile_width_of_json (j : Yojson.Safe.t) : Pane.tile_width =
  match j with
  | `String "KeepCurrent" -> Keep_current
  | `String "Flex" -> Flex
  | `Assoc [("Fixed", `Float w)] -> Fixed w
  | _ -> Flex

let double_click_action_to_json = function
  | Pane.Maximize -> `String "Maximize"
  | Pane.Redock -> `String "Redock"
  | Pane.No_action -> `String "None"

let double_click_action_of_json = function
  | `String "Maximize" -> Pane.Maximize
  | `String "Redock" -> Pane.Redock
  | _ -> Pane.No_action

let pane_config_to_json (c : Pane.pane_config) : Yojson.Safe.t =
  let base = [
    "label", `String c.label;
    "min_width", `Float c.min_width; "min_height", `Float c.min_height;
    "fixed_width", `Bool c.fixed_width;
    "double_click_action", double_click_action_to_json c.double_click_action;
    "tile_order", `Int c.tile_order; "tile_width", tile_width_to_json c.tile_width;
  ] in
  let with_cw = match c.collapsed_width with
    | Some w -> base @ ["collapsed_width", `Float w]
    | None -> base
  in
  `Assoc with_cw

let pane_config_of_json (j : Yojson.Safe.t) : Pane.pane_config =
  let open Yojson.Safe.Util in
  { label = j |> member "label" |> to_string;
    min_width = j |> member "min_width" |> to_float;
    min_height = j |> member "min_height" |> to_float;
    fixed_width = j |> member "fixed_width" |> to_bool;
    collapsed_width = (try Some (j |> member "collapsed_width" |> to_float) with _ -> None);
    double_click_action = (try double_click_action_of_json (j |> member "double_click_action") with _ -> Pane.No_action);
    tile_order = j |> member "tile_order" |> to_int;
    tile_width = tile_width_of_json (j |> member "tile_width"); }

let pane_to_json (p : Pane.pane) : Yojson.Safe.t =
  `Assoc [
    "id", `Int p.id; "kind", `String (pane_kind_to_json p.kind);
    "config", pane_config_to_json p.config;
    "x", `Float p.x; "y", `Float p.y;
    "width", `Float p.width; "height", `Float p.height;
  ]

let pane_of_json (j : Yojson.Safe.t) : Pane.pane =
  let open Yojson.Safe.Util in
  let kind = pane_kind_of_json (j |> member "kind" |> to_string) in
  { id = j |> member "id" |> to_int;
    kind;
    config = (try pane_config_of_json (j |> member "config")
              with _ -> Pane.config_for_kind kind);
    x = j |> member "x" |> to_float; y = j |> member "y" |> to_float;
    width = j |> member "width" |> to_float; height = j |> member "height" |> to_float; }

let snap_target_to_json : Pane.snap_target -> Yojson.Safe.t = function
  | Window_target e -> `Assoc ["Window", `String (edge_side_to_json e)]
  | Pane_target (id, e) -> `Assoc ["Pane", `List [`Int id; `String (edge_side_to_json e)]]

let snap_target_of_json (j : Yojson.Safe.t) : Pane.snap_target =
  match j with
  | `Assoc [("Window", `String e)] -> Window_target (edge_side_of_json e)
  | `Assoc [("Pane", `List [`Int id; `String e])] -> Pane_target (id, edge_side_of_json e)
  | _ -> Window_target Left

let snap_to_json (s : Pane.snap_constraint) : Yojson.Safe.t =
  `Assoc [
    "pane", `Int s.snap_pane;
    "edge", `String (edge_side_to_json s.edge);
    "target", snap_target_to_json s.target;
  ]

let snap_of_json (j : Yojson.Safe.t) : Pane.snap_constraint =
  let open Yojson.Safe.Util in
  { snap_pane = j |> member "pane" |> to_int;
    edge = edge_side_of_json (j |> member "edge" |> to_string);
    target = snap_target_of_json (j |> member "target"); }

let pane_layout_to_json (pl : Pane.pane_layout) : Yojson.Safe.t =
  `Assoc [
    "panes", `List (Array.to_list (Array.map pane_to_json pl.panes));
    "snaps", `List (List.map snap_to_json pl.snaps);
    "z_order", `List (List.map (fun id -> `Int id) pl.z_order);
    "hidden_panes", `List (List.map (fun k -> `String (pane_kind_to_json k)) pl.hidden_panes);
    "canvas_maximized", `Bool pl.canvas_maximized;
    "viewport_width", `Float pl.viewport_width;
    "viewport_height", `Float pl.viewport_height;
    "next_pane_id", `Int pl.next_pane_id;
  ]

let pane_layout_of_json (j : Yojson.Safe.t) : Pane.pane_layout =
  let open Yojson.Safe.Util in
  { panes = Array.of_list (j |> member "panes" |> to_list |> List.map pane_of_json);
    snaps = j |> member "snaps" |> to_list |> List.map snap_of_json;
    z_order = j |> member "z_order" |> to_list |> List.map to_int;
    hidden_panes = j |> member "hidden_panes" |> to_list |> List.map (fun s -> pane_kind_of_json (to_string s));
    canvas_maximized = j |> member "canvas_maximized" |> to_bool;
    viewport_width = j |> member "viewport_width" |> to_float;
    viewport_height = j |> member "viewport_height" |> to_float;
    next_pane_id = j |> member "next_pane_id" |> to_int; }

(* -- Dock layout JSON -- *)

let layout_to_json l : Yojson.Safe.t =
  let base = [
    "version", `Int l.version;
    "name", `String l.name;
    "anchored", `List (List.map (fun (e, d) ->
      `Assoc ["edge", `String (edge_to_json e); "dock", dock_to_json d]) l.anchored);
    "floating", `List (List.map (fun fd ->
      `Assoc ["dock", dock_to_json fd.dock; "x", `Float fd.x; "y", `Float fd.y]) l.floating);
    "hidden_panels", `List (List.map (fun k -> `String (kind_to_json k)) l.hidden_panels);
    "z_order", `List (List.map (fun id -> `Int id) l.z_order);
    "next_id", `Int l.next_id;
  ] in
  let with_pane = match l.pane_layout with
    | Some pl -> base @ ["pane_layout", pane_layout_to_json pl]
    | None -> base
  in
  `Assoc with_pane

let layout_of_json (j : Yojson.Safe.t) =
  let open Yojson.Safe.Util in
  { version = (try j |> member "version" |> to_int with _ -> 0);
    name = j |> member "name" |> to_string;
    anchored = j |> member "anchored" |> to_list |> List.map (fun a ->
      (edge_of_json (a |> member "edge" |> to_string),
       dock_of_json (a |> member "dock")));
    floating = j |> member "floating" |> to_list |> List.map (fun f ->
      { dock = dock_of_json (f |> member "dock");
        x = f |> member "x" |> to_float;
        y = f |> member "y" |> to_float });
    hidden_panels = j |> member "hidden_panels" |> to_list |> List.map (fun s -> kind_of_json (to_string s));
    z_order = j |> member "z_order" |> to_list |> List.map to_int;
    focused_panel = None;
    pane_layout = (try Some (pane_layout_of_json (j |> member "pane_layout")) with _ -> None);
    next_id = j |> member "next_id" |> to_int;
    generation = 0;
    saved_generation = 0; }

(* -- File I/O -- *)

let save_layout l =
  try
    let json = layout_to_json l in
    let file = layout_file_for l.name in
    Yojson.Safe.to_file file json;
    l.saved_generation <- l.generation
  with _ -> ()

let load_layout name =
  try
    let file = layout_file_for name in
    let json = Yojson.Safe.from_file file in
    let l = layout_of_json json in
    if l.version <> layout_version then named name
    else l
  with _ -> named name

let save_layout_if_needed l =
  if needs_save l then save_layout l

let save_app_config config =
  try
    let json : Yojson.Safe.t = `Assoc [
      "active_layout", `String config.active_layout;
      "saved_layouts", `List (List.map (fun s -> `String s) config.saved_layouts);
    ] in
    Yojson.Safe.to_file (config_file ()) json
  with _ -> ()

let load_app_config () =
  try
    let json = Yojson.Safe.from_file (config_file ()) in
    let open Yojson.Safe.Util in
    { active_layout = json |> member "active_layout" |> to_string;
      saved_layouts = json |> member "saved_layouts" |> to_list |> List.map to_string }
  with _ -> default_app_config ()

(* ------------------------------------------------------------------ *)
(* Focus                                                              *)
(* ------------------------------------------------------------------ *)

let set_focused_panel l addr = l.focused_panel <- addr

let all_panel_addrs l =
  let addrs = ref [] in
  List.iter (fun (_, d) ->
    Array.iteri (fun gi g ->
      Array.iteri (fun pi _ ->
        addrs := { group = { dock_id = d.id; group_idx = gi }; panel_idx = pi } :: !addrs
      ) g.panels
    ) d.groups
  ) l.anchored;
  List.iter (fun fd ->
    Array.iteri (fun gi g ->
      Array.iteri (fun pi _ ->
        addrs := { group = { dock_id = fd.dock.id; group_idx = gi }; panel_idx = pi } :: !addrs
      ) g.panels
    ) fd.dock.groups
  ) l.floating;
  List.rev !addrs

let focus_next_panel l =
  let addrs = all_panel_addrs l in
  match addrs with
  | [] -> l.focused_panel <- None
  | _ ->
    let cur_idx = match l.focused_panel with
      | None -> None
      | Some fp ->
        let rec find i = function
          | [] -> None
          | hd :: _ when hd = fp -> Some i
          | _ :: tl -> find (i + 1) tl
        in find 0 addrs
    in
    let next = match cur_idx with
      | Some i -> (i + 1) mod List.length addrs
      | None -> 0
    in
    l.focused_panel <- Some (List.nth addrs next)

let focus_prev_panel l =
  let addrs = all_panel_addrs l in
  match addrs with
  | [] -> l.focused_panel <- None
  | _ ->
    let cur_idx = match l.focused_panel with
      | None -> None
      | Some fp ->
        let rec find i = function
          | [] -> None
          | hd :: _ when hd = fp -> Some i
          | _ :: tl -> find (i + 1) tl
        in find 0 addrs
    in
    let n = List.length addrs in
    let prev = match cur_idx with
      | Some 0 -> n - 1
      | Some i -> i - 1
      | None -> n - 1
    in
    l.focused_panel <- Some (List.nth addrs prev)

(* ------------------------------------------------------------------ *)
(* Safety                                                             *)
(* ------------------------------------------------------------------ *)

let clamp_floating_docks l ~viewport_w ~viewport_h =
  let min_visible = 50.0 in
  List.iter (fun fd ->
    fd.x <- max (-.fd.dock.width +. min_visible) (min fd.x (viewport_w -. min_visible));
    fd.y <- max 0.0 (min fd.y (viewport_h -. min_visible))
  ) l.floating;
  (match l.pane_layout with
   | Some pl -> Pane.clamp_panes pl ~viewport_w ~viewport_h
   | None -> ());
  bump l

(* ------------------------------------------------------------------ *)
(* Pane layout integration                                            *)
(* ------------------------------------------------------------------ *)

let ensure_pane_layout l ~viewport_w ~viewport_h =
  (match l.pane_layout with
   | Some _ -> ()
   | None ->
     l.pane_layout <- Some (Pane.default_three_pane ~viewport_w ~viewport_h);
     bump l);
  (* Sync PaneConfig for panes deserialized from old format *)
  match l.pane_layout with
  | Some pl ->
    Array.iter (fun (p : Pane.pane) ->
      let expected = Pane.config_for_kind p.kind in
      if p.config.label <> expected.label then
        p.config <- expected
    ) pl.panes
  | None -> ()

let panes l = l.pane_layout

let panes_mut l f =
  match l.pane_layout with
  | Some pl -> f pl; bump l
  | None -> ()

(* ------------------------------------------------------------------ *)

let set_auto_hide l id ~auto_hide =
  (match find_dock l id with
   | Some d -> d.auto_hide <- auto_hide
   | None -> ());
  bump l
