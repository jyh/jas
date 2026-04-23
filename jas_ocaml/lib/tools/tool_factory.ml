(** Factory for creating tool instances from toolbar enum values. *)

(** Load a [Yaml_tool] by id from the compiled workspace.json.
    Returns [None] when the workspace can't be loaded or the tool
    spec is missing. *)
let load_yaml_tool (id : string) : Yaml_tool.yaml_tool option =
  match Workspace_loader.load () with
  | None -> None
  | Some ws ->
    match Workspace_loader.json_member "tools" ws.data with
    | Some (`Assoc tools) ->
      (match List.assoc_opt id tools with
       | Some spec -> Yaml_tool.from_workspace_tool spec
       | None -> None)
    | _ -> None

(** [load_yaml_tool_or_fail id] loads the YAML tool or raises if
    missing. Used for tools migrated per OCAML_TOOL_RUNTIME.md
    Phase 7 — a missing workspace.json means the whole app is
    non-functional anyway. *)
let load_yaml_tool_or_fail (id : string) : Yaml_tool.yaml_tool =
  match load_yaml_tool id with
  | Some t -> t
  | None ->
    failwith (Printf.sprintf
      "workspace.json missing or malformed — cannot load YAML tool %s" id)

let create_tool (tool : Toolbar.tool) : Canvas_tool.canvas_tool =
  match tool with
  | Toolbar.Selection -> (new Selection_tool.selection_tool :> Canvas_tool.canvas_tool)
  | Toolbar.Partial_selection -> (new Partial_selection_tool.partial_selection_tool :> Canvas_tool.canvas_tool)
  | Toolbar.Interior_selection -> (new Interior_selection_tool.interior_selection_tool :> Canvas_tool.canvas_tool)
  (* Phase 7.3 — Line migrated to YamlTool *)
  | Toolbar.Line -> (load_yaml_tool_or_fail "line" :> Canvas_tool.canvas_tool)
  (* Phase 7.1 — Rect migrated to YamlTool *)
  | Toolbar.Rect -> (load_yaml_tool_or_fail "rect" :> Canvas_tool.canvas_tool)
  (* Phase 7.2 — RoundedRect migrated *)
  | Toolbar.Rounded_rect -> (load_yaml_tool_or_fail "rounded_rect" :> Canvas_tool.canvas_tool)
  (* Phase 7.4 — Polygon migrated *)
  | Toolbar.Polygon -> (load_yaml_tool_or_fail "polygon" :> Canvas_tool.canvas_tool)
  (* Phase 7.5 — Star migrated *)
  | Toolbar.Star -> (load_yaml_tool_or_fail "star" :> Canvas_tool.canvas_tool)
  | Toolbar.Pen -> (new Pen_tool.pen_tool :> Canvas_tool.canvas_tool)
  | Toolbar.Add_anchor_point -> (new Add_anchor_point_tool.add_anchor_point_tool :> Canvas_tool.canvas_tool)
  | Toolbar.Delete_anchor_point -> (new Delete_anchor_point_tool.delete_anchor_point_tool :> Canvas_tool.canvas_tool)
  | Toolbar.Anchor_point -> (new Anchor_point_tool.anchor_point_tool :> Canvas_tool.canvas_tool)
  | Toolbar.Pencil -> (new Pencil_tool.pencil_tool :> Canvas_tool.canvas_tool)
  | Toolbar.Path_eraser -> (new Path_eraser_tool.path_eraser_tool :> Canvas_tool.canvas_tool)
  | Toolbar.Smooth -> (new Smooth_tool.smooth_tool :> Canvas_tool.canvas_tool)
  | Toolbar.Type_tool -> (new Type_tool.type_tool :> Canvas_tool.canvas_tool)
  | Toolbar.Type_on_path -> (new Type_on_path_tool.type_on_path_tool :> Canvas_tool.canvas_tool)
  | Toolbar.Lasso -> (new Lasso_tool.lasso_tool :> Canvas_tool.canvas_tool)
