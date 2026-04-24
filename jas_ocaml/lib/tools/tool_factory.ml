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
  (* Phase 7.6 — Selection migrated *)
  | Toolbar.Selection -> (load_yaml_tool_or_fail "selection" :> Canvas_tool.canvas_tool)
  (* Phase 7.7 — InteriorSelection migrated *)
  | Toolbar.Interior_selection -> (load_yaml_tool_or_fail "interior_selection" :> Canvas_tool.canvas_tool)
  (* Phase 7.14 — PartialSelection migrated *)
  | Toolbar.Partial_selection -> (load_yaml_tool_or_fail "partial_selection" :> Canvas_tool.canvas_tool)
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
  (* Phase 7.10 — Pen migrated *)
  | Toolbar.Pen -> (load_yaml_tool_or_fail "pen" :> Canvas_tool.canvas_tool)
  (* Phase 7.11-13 — AnchorPoint family migrated *)
  | Toolbar.Add_anchor_point -> (load_yaml_tool_or_fail "add_anchor_point" :> Canvas_tool.canvas_tool)
  | Toolbar.Delete_anchor_point -> (load_yaml_tool_or_fail "delete_anchor_point" :> Canvas_tool.canvas_tool)
  | Toolbar.Anchor_point -> (load_yaml_tool_or_fail "anchor_point" :> Canvas_tool.canvas_tool)
  (* Phase 7.9 — Pencil migrated *)
  | Toolbar.Pencil -> (load_yaml_tool_or_fail "pencil" :> Canvas_tool.canvas_tool)
  (* Paintbrush — shares Pencil's gesture shape + active-brush *)
  | Toolbar.Paintbrush -> (load_yaml_tool_or_fail "paintbrush" :> Canvas_tool.canvas_tool)
  (* Blob Brush — Pencil-style sweep that commits a filled region *)
  | Toolbar.Blob_brush -> (load_yaml_tool_or_fail "blob_brush" :> Canvas_tool.canvas_tool)
  (* Phase 7.15 — PathEraser migrated *)
  | Toolbar.Path_eraser -> (load_yaml_tool_or_fail "path_eraser" :> Canvas_tool.canvas_tool)
  (* Phase 7.16 — Smooth migrated *)
  | Toolbar.Smooth -> (load_yaml_tool_or_fail "smooth" :> Canvas_tool.canvas_tool)
  | Toolbar.Type_tool -> (new Type_tool.type_tool :> Canvas_tool.canvas_tool)
  | Toolbar.Type_on_path -> (new Type_on_path_tool.type_on_path_tool :> Canvas_tool.canvas_tool)
  (* Phase 7.8 — Lasso migrated *)
  | Toolbar.Lasso -> (load_yaml_tool_or_fail "lasso" :> Canvas_tool.canvas_tool)
