(** CLI tool for cross-language workspace layout testing.

    Usage:
      workspace_roundtrip default                       -- canonical JSON for default_layout()
      workspace_roundtrip default_with_panes <w> <h>    -- with pane layout at viewport size
      workspace_roundtrip parse <workspace.json>        -- parse, output canonical test JSON
      workspace_roundtrip apply <workspace.json>        -- parse, apply ops from stdin, output canonical test JSON *)

open Jas.Workspace_layout
open Jas.Pane

let read_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let buf = Bytes.create n in
  really_input ic buf 0 n;
  close_in ic;
  Bytes.to_string buf |> String.trim

let read_stdin () =
  let buf = Buffer.create 4096 in
  (try while true do
    Buffer.add_channel buf stdin 4096
  done with End_of_file -> ());
  Buffer.contents buf

let parse_panel_kind s = match s with
  | "color" -> Color | "stroke" -> Stroke | "properties" -> Properties | _ -> Layers

let parse_pane_kind s = match s with
  | "toolbar" -> Toolbar | "dock" -> Dock | _ -> Canvas

let apply_op layout op =
  let open Yojson.Safe.Util in
  let name = op |> member "op" |> to_string in
  match name with
  | "toggle_group_collapsed" ->
    let addr = { dock_id = op |> member "dock_id" |> to_int;
                 group_idx = op |> member "group_idx" |> to_int } in
    toggle_group_collapsed layout addr
  | "set_active_panel" ->
    let addr = { group = { dock_id = op |> member "dock_id" |> to_int;
                            group_idx = op |> member "group_idx" |> to_int };
                 panel_idx = op |> member "panel_idx" |> to_int } in
    set_active_panel layout addr
  | "close_panel" ->
    let addr = { group = { dock_id = op |> member "dock_id" |> to_int;
                            group_idx = op |> member "group_idx" |> to_int };
                 panel_idx = op |> member "panel_idx" |> to_int } in
    close_panel layout addr
  | "show_panel" ->
    let kind = op |> member "kind" |> to_string |> parse_panel_kind in
    show_panel layout kind
  | "reorder_panel" ->
    let group = { dock_id = op |> member "dock_id" |> to_int;
                  group_idx = op |> member "group_idx" |> to_int } in
    reorder_panel layout ~group
      ~from:(op |> member "from" |> to_int)
      ~to_:(op |> member "to" |> to_int)
  | "move_panel_to_group" ->
    let from = { group = { dock_id = op |> member "from_dock_id" |> to_int;
                            group_idx = op |> member "from_group_idx" |> to_int };
                 panel_idx = op |> member "from_panel_idx" |> to_int } in
    let to_ = { dock_id = op |> member "to_dock_id" |> to_int;
                group_idx = op |> member "to_group_idx" |> to_int } in
    move_panel_to_group layout ~from ~to_
  | "detach_group" ->
    let from = { dock_id = op |> member "dock_id" |> to_int;
                 group_idx = op |> member "group_idx" |> to_int } in
    ignore (detach_group layout ~from
      ~x:(op |> member "x" |> to_float)
      ~y:(op |> member "y" |> to_float))
  | "redock" ->
    let dock_id = op |> member "dock_id" |> to_int in
    redock layout dock_id
  | "set_pane_position" ->
    let pl = Option.get layout.pane_layout in
    let id = op |> member "pane_id" |> to_int in
    set_pane_position pl id
      ~x:(op |> member "x" |> to_float)
      ~y:(op |> member "y" |> to_float)
  | "tile_panes" ->
    let pl = Option.get layout.pane_layout in
    tile_panes pl ~collapsed_override:None
  | "toggle_canvas_maximized" ->
    let pl = Option.get layout.pane_layout in
    toggle_canvas_maximized pl
  | "resize_pane" ->
    let pl = Option.get layout.pane_layout in
    let id = op |> member "pane_id" |> to_int in
    resize_pane pl id
      ~width:(op |> member "width" |> to_float)
      ~height:(op |> member "height" |> to_float)
  | "hide_pane" ->
    let pl = Option.get layout.pane_layout in
    let kind = op |> member "kind" |> to_string |> parse_pane_kind in
    hide_pane pl kind
  | "show_pane" ->
    let pl = Option.get layout.pane_layout in
    let kind = op |> member "kind" |> to_string |> parse_pane_kind in
    show_pane pl kind
  | "bring_pane_to_front" ->
    let pl = Option.get layout.pane_layout in
    let id = op |> member "pane_id" |> to_int in
    bring_pane_to_front pl id
  | _ ->
    Printf.eprintf "Unknown workspace op: %s\n" name;
    exit 1

let () =
  if Array.length Sys.argv < 2 then begin
    Printf.eprintf "Usage: %s default|default_with_panes|parse|apply ...\n" Sys.argv.(0);
    exit 1
  end;
  let mode = Sys.argv.(1) in
  match mode with
  | "default" ->
    let layout = default_layout () in
    print_string (Jas.Workspace_test_json.workspace_to_test_json layout)
  | "default_with_panes" ->
    if Array.length Sys.argv < 4 then begin
      Printf.eprintf "Usage: %s default_with_panes <width> <height>\n" Sys.argv.(0);
      exit 1
    end;
    let w = float_of_string Sys.argv.(2) in
    let h = float_of_string Sys.argv.(3) in
    let layout = default_layout () in
    ensure_pane_layout layout ~viewport_w:w ~viewport_h:h;
    print_string (Jas.Workspace_test_json.workspace_to_test_json layout)
  | "parse" ->
    if Array.length Sys.argv < 3 then begin
      Printf.eprintf "Usage: %s parse <workspace.json>\n" Sys.argv.(0);
      exit 1
    end;
    let json_str = read_file Sys.argv.(2) in
    let layout = Jas.Workspace_test_json.test_json_to_workspace json_str in
    print_string (Jas.Workspace_test_json.workspace_to_test_json layout)
  | "apply" ->
    if Array.length Sys.argv < 3 then begin
      Printf.eprintf "Usage: %s apply <workspace.json>  (ops from stdin)\n" Sys.argv.(0);
      exit 1
    end;
    let json_str = read_file Sys.argv.(2) in
    let layout = Jas.Workspace_test_json.test_json_to_workspace json_str in
    let ops_str = read_stdin () in
    let ops = Yojson.Safe.from_string ops_str in
    List.iter (apply_op layout) (Yojson.Safe.Util.to_list ops);
    print_string (Jas.Workspace_test_json.workspace_to_test_json layout)
  | _ ->
    Printf.eprintf "Unknown mode: %s\n" mode;
    exit 1
