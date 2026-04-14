(** Load and query the compiled workspace JSON.

    Provides access to panels, menus, content, and state defaults
    from the workspace.json file produced by the YAML compiler. *)

type workspace = {
  data : Yojson.Safe.t;
}

(** Try to load workspace.json from the project workspace directory.

    Searches for workspace/workspace.json relative to the executable
    location, then falls back to the current directory. *)
let load () : workspace option =
  let candidates = [
    (* Relative to executable *)
    Filename.concat (Filename.dirname Sys.executable_name) "workspace/workspace.json";
    (* Common development paths *)
    "workspace/workspace.json";
    "../workspace/workspace.json";
    "../../workspace/workspace.json";
  ] in
  let rec try_paths = function
    | [] -> None
    | path :: rest ->
      if Sys.file_exists path then
        (try
           let data = Yojson.Safe.from_file path in
           Some { data }
         with _ -> try_paths rest)
      else
        try_paths rest
  in
  try_paths candidates

(** Helper: get an association list member from JSON. *)
let json_member (key : string) (j : Yojson.Safe.t) : Yojson.Safe.t option =
  match j with
  | `Assoc pairs -> List.assoc_opt key pairs
  | _ -> None

(** Get a panel definition by content id (e.g. "color_panel_content"). *)
let panel (ws : workspace) (content_id : string) : Yojson.Safe.t option =
  match json_member "panels" ws.data with
  | Some panels -> json_member content_id panels
  | None -> None

(** Get the panel menu items for a panel content id.
    Returns a list of JSON menu item objects. *)
let panel_menu (ws : workspace) (content_id : string) : Yojson.Safe.t list =
  match panel ws content_id with
  | Some panel_json ->
    (match json_member "menu" panel_json with
     | Some (`List items) -> items
     | _ -> [])
  | None -> []

(** Get the panel content definition for a panel content id.
    Returns the "content" field of the panel definition. *)
let panel_content (ws : workspace) (content_id : string) : Yojson.Safe.t option =
  match panel ws content_id with
  | Some panel_json -> json_member "content" panel_json
  | None -> None

(** Extract default values from the top-level state definitions.
    Returns a list of (key, default_value) pairs. *)
let state_defaults (ws : workspace) : (string * Yojson.Safe.t) list =
  match json_member "state" ws.data with
  | Some (`Assoc pairs) ->
    List.filter_map (fun (key, def) ->
      match json_member "default" def with
      | Some default_val -> Some (key, default_val)
      | None -> None
    ) pairs
  | _ -> []

(** Extract default values from a panel's state definitions.
    Returns a list of (key, default_value) pairs. *)
let panel_state_defaults (ws : workspace) (content_id : string) : (string * Yojson.Safe.t) list =
  match panel ws content_id with
  | Some panel_json ->
    (match json_member "state" panel_json with
     | Some (`Assoc pairs) ->
       List.filter_map (fun (key, def) ->
         match json_member "default" def with
         | Some default_val -> Some (key, default_val)
         | None -> None
       ) pairs
     | _ -> [])
  | None -> []

(** Get the icons map from the workspace.
    Returns a JSON object mapping icon names to icon definitions. *)
let icons (ws : workspace) : Yojson.Safe.t =
  match json_member "icons" ws.data with
  | Some icons -> icons
  | None -> `Assoc []

(** Map a panel_kind variant to its workspace content id string. *)
let panel_kind_to_content_id (kind : Workspace_layout.panel_kind) : string =
  match kind with
  | Workspace_layout.Layers -> "layers_panel_content"
  | Workspace_layout.Color -> "color_panel_content"
  | Workspace_layout.Swatches -> "swatches_panel_content"
  | Workspace_layout.Stroke -> "stroke_panel_content"
  | Workspace_layout.Properties -> "properties_panel_content"
