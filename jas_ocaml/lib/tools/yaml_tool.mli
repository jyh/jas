(** YAML-driven canvas tool. *)

(** Tool-overlay declaration. *)
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
  overlay : overlay_spec list;
  (** Overlay declarations. Most tools have zero or one entry;
      the transform-tool family (Scale / Rotate / Shear) uses
      multiple to layer the reference-point cross over the
      drag-time bbox ghost. Each entry's guard is evaluated
      independently. *)
}

(** Parse a workspace tool spec, typically from workspace.json
    under [tools.<id>]. Returns [None] if the required [id] field
    is missing. *)
val tool_spec_from_workspace : Yojson.Safe.t -> tool_spec option

(** Internal — exposed only for tests.

    Subset of CSS style properties the overlay renderer
    understands. Missing fields are [None]. *)
type overlay_style = {
  fill : string option;
  stroke : string option;
  stroke_width : float option;
  stroke_dasharray : float list option;
}

(** Internal — exposed only for tests. Parse a CSS-like
    ["key: value; key: value"] string. *)
val parse_style : string -> overlay_style

(** Internal — exposed only for tests. Parse a CSS color string
    (``#rrggbb`` / ``#rgb`` / ``rgb(...)`` / ``rgba(...)`` /
    ``black`` / ``white`` / ``none``) into ``(r, g, b, a)``
    normalized to ``[0.0, 1.0]``. Returns [None] for unparseable
    input or ``none``. *)
val parse_color : string -> (float * float * float * float) option

(** Fetch the handler list for an event name (e.g. ["on_mousedown"]).
    Returns [] when the event has no declared handler. *)
val handler : tool_spec -> string -> Yojson.Safe.t list

(** Build a [$event] scope dict for a pointer event. *)
val pointer_payload :
  ?dragging:bool -> string ->
  x:float -> y:float -> shift:bool -> alt:bool ->
  Yojson.Safe.t

(** YAML-driven tool class. Constructs with a parsed [tool_spec]
    and a private [State_store] seeded with the spec's defaults. *)
class yaml_tool : tool_spec -> object
  method spec : tool_spec

  (** Read a tool-local state value. Primary use: tests observing
      what a handler wrote to [$tool.<id>.<key>]. *)
  method tool_state : string -> Yojson.Safe.t

  method on_press :
    Canvas_tool.tool_context -> float -> float ->
    shift:bool -> alt:bool -> unit
  method on_move :
    Canvas_tool.tool_context -> float -> float ->
    shift:bool -> dragging:bool -> unit
  method on_release :
    Canvas_tool.tool_context -> float -> float ->
    shift:bool -> alt:bool -> unit
  method on_double_click :
    Canvas_tool.tool_context -> float -> float -> unit
  method on_key : Canvas_tool.tool_context -> int -> bool
  method on_key_release : Canvas_tool.tool_context -> int -> bool
  method activate : Canvas_tool.tool_context -> unit
  method deactivate : Canvas_tool.tool_context -> unit
  method on_key_event :
    Canvas_tool.tool_context -> string -> Canvas_tool.key_mods -> bool
  method captures_keyboard : unit -> bool
  method cursor_css_override : unit -> string option
  method is_editing : unit -> bool
  method paste_text : Canvas_tool.tool_context -> string -> bool
  method draw_overlay : Canvas_tool.tool_context -> Cairo.context -> unit
end

(** Convenience: parse + construct from a workspace tool spec. *)
val from_workspace_tool : Yojson.Safe.t -> yaml_tool option
