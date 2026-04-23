(** YAML-driven canvas tool — the OCaml analogue of
    [jas_dioxus/src/tools/yaml_tool.rs] and
    [JasSwift/Sources/Tools/YamlTool.swift].

    Parses a tool spec (typically from workspace.json under
    [tools.<id>]) into a [tool_spec], seeds a private [State_store]
    with its state defaults, and routes [canvas_tool] events
    through the declared handlers via [Effects.run_effects] +
    [Yaml_tool_effects.build].

    Phase 5 of the OCaml YAML tool-runtime migration: [canvas_tool]
    conformance + event dispatch. Overlay rendering is minimal
    for now (Phase 5b adds rect/line/polygon/star/buffer/pen/
    partial-selection renderers). *)

(** Tool-overlay declaration — guard expression plus a render
    JSON subtree. *)
type overlay_spec = {
  guard : string option;
  render : Yojson.Safe.t;
}

(** Parsed shape of a tool YAML spec. *)
type tool_spec = {
  id : string;
  cursor : string option;
  menu_label : string option;
  shortcut : string option;
  state_defaults : (string * Yojson.Safe.t) list;
  handlers : (string * Yojson.Safe.t list) list;
  overlay : overlay_spec option;
}

let parse_state_defaults (val_ : Yojson.Safe.t option)
  : (string * Yojson.Safe.t) list =
  match val_ with
  | Some (`Assoc pairs) ->
    List.map (fun (key, defn) ->
      match defn with
      | `Assoc d ->
        (match List.assoc_opt "default" d with
         | Some v -> (key, v)
         | None -> (key, `Null))
      | _ -> (key, defn)
    ) pairs
  | _ -> []

let parse_handlers (val_ : Yojson.Safe.t option)
  : (string * Yojson.Safe.t list) list =
  match val_ with
  | Some (`Assoc pairs) ->
    List.filter_map (fun (name, effects) ->
      match effects with
      | `List effs -> Some (name, effs)
      | _ -> None
    ) pairs
  | _ -> []

let parse_overlay (val_ : Yojson.Safe.t option) : overlay_spec option =
  match val_ with
  | Some (`Assoc pairs) ->
    (match List.assoc_opt "render" pairs with
     | Some render ->
       let guard = match List.assoc_opt "if" pairs with
         | Some (`String s) -> Some s
         | _ -> None
       in
       Some { guard; render }
     | None -> None)
  | _ -> None

(** Parse a single tool spec, typically loaded from workspace.json
    under [tools.<id>]. Returns [None] if the spec is missing its
    required [id] field. *)
let tool_spec_from_workspace (spec : Yojson.Safe.t) : tool_spec option =
  match spec with
  | `Assoc pairs ->
    (match List.assoc_opt "id" pairs with
     | Some (`String id) ->
       Some {
         id;
         cursor = (match List.assoc_opt "cursor" pairs with
                   | Some (`String s) -> Some s | _ -> None);
         menu_label = (match List.assoc_opt "menu_label" pairs with
                       | Some (`String s) -> Some s | _ -> None);
         shortcut = (match List.assoc_opt "shortcut" pairs with
                     | Some (`String s) -> Some s | _ -> None);
         state_defaults = parse_state_defaults
                            (List.assoc_opt "state" pairs);
         handlers = parse_handlers (List.assoc_opt "handlers" pairs);
         overlay = parse_overlay (List.assoc_opt "overlay" pairs);
       }
     | _ -> None)
  | _ -> None

(** Fetch a handler list by event name. Returns [] when the event
    has no declared handler — callers treat that as a no-op. *)
let handler (spec : tool_spec) (event_name : string) : Yojson.Safe.t list =
  match List.assoc_opt event_name spec.handlers with
  | Some effs -> effs
  | None -> []

(** Build the [$event] scope for a pointer event. *)
let pointer_payload ?(dragging : bool option) (event_type : string)
    ~x ~y ~shift ~alt : Yojson.Safe.t =
  let base : (string * Yojson.Safe.t) list = [
    ("type", `String event_type);
    ("x", `Float x); ("y", `Float y);
    ("modifiers", `Assoc [
      ("shift", `Bool shift); ("alt", `Bool alt);
      ("ctrl", `Bool false); ("meta", `Bool false);
    ]);
  ] in
  let pairs = match dragging with
    | Some d -> base @ [("dragging", `Bool d)]
    | None -> base
  in
  `Assoc pairs

(** YAML-driven tool. Holds a [tool_spec] and a private [State_store]
    seeded with the tool's state defaults. Each [canvas_tool] method
    builds the [$event] scope, registers the current document for
    doc-aware primitives, and dispatches the matching handler list
    through [Effects.run_effects]. *)
class yaml_tool (spec : tool_spec) = object (_self)
  val spec : tool_spec = spec
  val store : State_store.t = State_store.create ()

  initializer
    State_store.init_tool store spec.id spec.state_defaults

  method spec = spec

  method tool_state (key : string) : Yojson.Safe.t =
    State_store.get_tool store spec.id key

  method private dispatch
      (event_name : string) (event : Yojson.Safe.t)
      (ctrl : Controller.controller) : unit =
    let effects = handler spec event_name in
    if effects <> [] then begin
      let ctx = [("event", event)] in
      let guard = Doc_primitives.register_document ctrl#document in
      let platform_effects = Yaml_tool_effects.build ctrl in
      Effects.run_effects ~platform_effects effects ctx store;
      guard.restore ()
    end

  method on_press (ctx : Canvas_tool.tool_context)
      (x : float) (y : float) ~(shift : bool) ~(alt : bool) =
    _self#dispatch "on_mousedown"
      (pointer_payload "mousedown" ~x ~y ~shift ~alt)
      ctx.controller;
    ctx.request_update ()

  method on_move (ctx : Canvas_tool.tool_context)
      (x : float) (y : float) ~(shift : bool) ~(dragging : bool) =
    _self#dispatch "on_mousemove"
      (pointer_payload "mousemove" ~x ~y ~shift ~alt:false ~dragging)
      ctx.controller;
    ctx.request_update ()

  method on_release (ctx : Canvas_tool.tool_context)
      (x : float) (y : float) ~(shift : bool) ~(alt : bool) =
    _self#dispatch "on_mouseup"
      (pointer_payload "mouseup" ~x ~y ~shift ~alt)
      ctx.controller;
    ctx.request_update ()

  method on_double_click (ctx : Canvas_tool.tool_context)
      (x : float) (y : float) =
    let payload = `Assoc [
      ("type", `String "dblclick");
      ("x", `Float x); ("y", `Float y);
    ] in
    _self#dispatch "on_dblclick" payload ctx.controller;
    ctx.request_update ()

  method on_key (_ctx : Canvas_tool.tool_context) (_keycode : int) = false
  method on_key_release (_ctx : Canvas_tool.tool_context) (_keycode : int) =
    false

  method activate (ctx : Canvas_tool.tool_context) =
    (* Reset tool-local state to declared defaults, then fire on_enter. *)
    State_store.init_tool store spec.id spec.state_defaults;
    let payload = `Assoc [("type", `String "enter")] in
    _self#dispatch "on_enter" payload ctx.controller;
    ctx.request_update ()

  method deactivate (ctx : Canvas_tool.tool_context) =
    let payload = `Assoc [("type", `String "leave")] in
    _self#dispatch "on_leave" payload ctx.controller;
    ctx.request_update ()

  method on_key_event (ctx : Canvas_tool.tool_context)
      (key : string) (mods : Canvas_tool.key_mods) =
    if handler spec "on_keydown" = [] then false
    else begin
      let payload = `Assoc [
        ("type", `String "keydown");
        ("key", `String key);
        ("modifiers", `Assoc [
          ("shift", `Bool mods.shift);
          ("alt", `Bool mods.alt);
          ("ctrl", `Bool mods.ctrl);
          ("meta", `Bool mods.meta);
        ]);
      ] in
      _self#dispatch "on_keydown" payload ctx.controller;
      ctx.request_update ();
      true
    end

  method captures_keyboard () = false
  method cursor_css_override () = spec.cursor
  method is_editing () = false
  method paste_text (_ctx : Canvas_tool.tool_context) (_text : string) = false

  method draw_overlay (_ctx : Canvas_tool.tool_context) (_cr : Cairo.context)
    : unit =
    (* Phase 5a: overlay rendering stub. Phase 5b adds the
       rect / line / polygon / star / buffer / pen / partial_selection
       renderers, each matching the YAML render.type registry. *)
    ()
end

(** Convenience: parse the workspace tool dict and construct a
    [yaml_tool]. Returns [None] when the spec fails to parse
    (missing id). *)
let from_workspace_tool (spec : Yojson.Safe.t) : yaml_tool option =
  Option.map (fun s -> new yaml_tool s) (tool_spec_from_workspace spec)
