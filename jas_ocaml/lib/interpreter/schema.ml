(** Schema table for workspace state fields.

    Mirrors the field definitions in workspace/state.yaml for the
    schema-driven set: effect. Port of workspace_interpreter/schema.py. *)

(* ── Types ─────────────────────────────────────────────── *)

type field_type =
  | Bool
  | Number
  | Str
  | Color
  | Enum of string list
  | List
  | Object

type schema_entry = {
  field_type : field_type;
  nullable   : bool;
  writable   : bool;
}

type diagnostic = {
  level  : string;   (* "warning" or "error" *)
  key    : string;
  reason : string;
}

(* ── Schema table ───────────────────────────────────────── *)

let active_tool_values = [
  "selection"; "partial_selection"; "interior_selection";
  "pen"; "add_anchor"; "delete_anchor"; "anchor_point";
  "pencil"; "path_eraser"; "smooth";
  "type"; "type_on_path";
  "line"; "rect"; "rounded_rect"; "polygon"; "star"; "lasso";
]

let stroke_cap_values = ["butt"; "round"; "square"]
let stroke_join_values = ["miter"; "round"; "bevel"]
let stroke_align_values = ["center"; "inside"; "outside"]
let stroke_arrowhead_values = [
  "none"; "simple_arrow"; "open_arrow"; "closed_arrow"; "stealth_arrow";
  "barbed_arrow"; "half_arrow_upper"; "half_arrow_lower";
  "circle"; "open_circle"; "square"; "open_square";
  "diamond"; "open_diamond"; "slash";
]
let stroke_arrow_align_values = ["tip_at_end"; "center_at_end"]
let stroke_profile_values = [
  "uniform"; "taper_both"; "taper_start"; "taper_end"; "bulge"; "pinch";
]

let mk ?(nullable = false) ?(writable = true) field_type =
  { field_type; nullable; writable }

(** Look up the schema entry for a global state: field by name. *)
let get_entry (key : string) : schema_entry option =
  match key with
  | "active_tool"               -> Some (mk (Enum active_tool_values))
  | "fill_color"                -> Some (mk ~nullable:true Color)
  | "stroke_color"              -> Some (mk ~nullable:true Color)
  | "stroke_width"              -> Some (mk Number)
  | "stroke_cap"                -> Some (mk (Enum stroke_cap_values))
  | "stroke_join"               -> Some (mk (Enum stroke_join_values))
  | "stroke_miter_limit"        -> Some (mk Number)
  | "stroke_align"              -> Some (mk (Enum stroke_align_values))
  | "stroke_dashed"             -> Some (mk Bool)
  | "stroke_dash_1" | "stroke_gap_1"
                                -> Some (mk Number)
  | "stroke_dash_2" | "stroke_gap_2"
  | "stroke_dash_3" | "stroke_gap_3"
                                -> Some (mk ~nullable:true Number)
  | "stroke_start_arrowhead" | "stroke_end_arrowhead"
                                -> Some (mk (Enum stroke_arrowhead_values))
  | "stroke_start_arrowhead_scale" | "stroke_end_arrowhead_scale"
                                -> Some (mk Number)
  | "stroke_link_arrowhead_scale" -> Some (mk Bool)
  | "stroke_arrow_align"        -> Some (mk (Enum stroke_arrow_align_values))
  | "stroke_profile"            -> Some (mk (Enum stroke_profile_values))
  | "stroke_profile_flipped"    -> Some (mk Bool)
  | "fill_on_top" | "toolbar_visible" | "canvas_visible"
  | "dock_visible" | "canvas_maximized" | "dock_collapsed"
                                -> Some (mk Bool)
  | "active_tab" | "tab_count" -> Some (mk Number)
  (* Internal — writable: false *)
  | "_drag_pane"                -> Some (mk ~nullable:true ~writable:false Str)
  | "_drag_offset_x" | "_drag_offset_y"
  | "_resize_start_x" | "_resize_start_y"
                                -> Some (mk ~writable:false Number)
  | "_resize_pane" | "_resize_edge"
                                -> Some (mk ~nullable:true ~writable:false Str)
  | _ -> None

(* ── Coercion ───────────────────────────────────────────── *)

let hex_color_re = Str.regexp {|^#[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$|}

let is_hex_color (s : string) : bool =
  try ignore (Str.string_match hex_color_re s 0); Str.string_match hex_color_re s 0
  with Not_found -> false

let number_string_re = Str.regexp {|^-?[0-9]+\(\.[0-9]+\)?$|}

let is_number_string (s : string) : bool =
  Str.string_match number_string_re s 0

(** Coerce a JSON value to match the schema entry's declared type.
    Returns Ok coerced on success, Error reason on failure. *)
let coerce_value (value : Yojson.Safe.t) (entry : schema_entry)
    : (Yojson.Safe.t, string) result =
  if value = `Null then
    if entry.nullable then Ok `Null
    else Error "null_on_non_nullable"
  else
    match entry.field_type with
    | Bool ->
      (match value with
       | `Bool b -> Ok (`Bool b)
       | `String "true"  -> Ok (`Bool true)
       | `String "false" -> Ok (`Bool false)
       | _ -> Error "type_mismatch")
    | Number ->
      (match value with
       | `Bool _ -> Error "type_mismatch"
       | `Int n  -> Ok (`Float (Float.of_int n))
       | `Float f -> Ok (`Float f)
       | `String s when is_number_string s ->
         (match float_of_string_opt s with
          | Some f -> Ok (`Float f)
          | None -> Error "type_mismatch")
       | _ -> Error "type_mismatch")
    | Str ->
      (match value with
       | `String s -> Ok (`String s)
       | _ -> Error "type_mismatch")
    | Color ->
      (match value with
       | `String s when is_hex_color s -> Ok (`String s)
       | _ -> Error "type_mismatch")
    | Enum allowed ->
      (match value with
       | `String s when List.mem s allowed -> Ok (`String s)
       | _ -> Error "enum_value_not_in_values")
    | List ->
      (match value with
       | `List _ as l -> Ok l
       | _ -> Error "type_mismatch")
    | Object ->
      (match value with
       | `Assoc _ as a -> Ok a
       | _ -> Error "type_mismatch")

(* ── Key resolution ─────────────────────────────────────── *)

type resolved_key =
  | NotFound
  | Ambiguous
  | Found of string * string * schema_entry  (* scope, field, entry *)

let resolve_key (key : string) (active_panel : string option)
    (store : State_store.t) : resolved_key =
  if String.contains key '.' then begin
    let dot = String.index key '.' in
    let prefix = String.sub key 0 dot in
    let rest = String.sub key (dot + 1) (String.length key - dot - 1) in
    let panel_id = if prefix = "panel" then active_panel else Some prefix in
    match panel_id with
    | None -> NotFound
    | Some pid ->
      (* Validate panel exists via store side-effect; look up global schema for type *)
      ignore (State_store.get_panel store pid rest);
      (match get_entry rest with
       | Some entry -> Found ("panel:" ^ pid, rest, entry)
       | None -> NotFound)
  end else begin
    let state_entry = get_entry key in
    (* For bare keys with an active panel, check both scopes for ambiguity *)
    match state_entry, active_panel with
    | Some e, Some _ ->
      (* Global schema is flat; bare keys always resolve to state scope *)
      Found ("state", key, e)
    | Some e, None -> Found ("state", key, e)
    | None, _ -> NotFound
  end

(* ── Schema-driven set: ─────────────────────────────────── *)

(** Apply a schema-driven set: effect from already-evaluated values.

    set_map values are native JSON types (not expression strings).
    Coercion and scope resolution happen here; expression evaluation
    is the caller's responsibility. *)
let apply_set_schemadriven
    ?(active_panel : string option = None)
    (set_map : (string * Yojson.Safe.t) list)
    (store : State_store.t)
    (diagnostics : diagnostic list ref) : unit =
  let resolved_panel = match active_panel with
    | Some _ -> active_panel
    | None -> State_store.get_active_panel_id store
  in
  let pending = ref [] in
  List.iter (fun (key, value) ->
    match resolve_key key resolved_panel store with
    | NotFound ->
      diagnostics := !diagnostics @ [{ level = "warning"; key; reason = "unknown_key" }]
    | Ambiguous ->
      diagnostics := !diagnostics @ [{ level = "error"; key; reason = "ambiguous_key" }]
    | Found (scope, field_name, entry) ->
      if not entry.writable then
        diagnostics := !diagnostics @ [{ level = "warning"; key; reason = "field_not_writable" }]
      else
        match coerce_value value entry with
        | Error reason ->
          diagnostics := !diagnostics @ [{ level = "error"; key; reason }]
        | Ok coerced ->
          pending := !pending @ [(scope, field_name, coerced)]
  ) set_map;
  (* Apply all successful writes as a batch *)
  List.iter (fun (scope, field_name, value) ->
    if scope = "state" then
      State_store.set store field_name value
    else
      let panel_id = String.sub scope 6 (String.length scope - 6) in
      State_store.set_panel store panel_id field_name value
  ) !pending
