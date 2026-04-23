(** YAML tool-runtime effects. [Yaml_tool] (Phase 5) registers the
    effects returned by [build] before dispatching a handler. *)

(** Evaluate a JSON number field — literal or string expression.
    Missing / unparseable falls back to [0.0]. *)
val eval_number :
  Yojson.Safe.t option ->
  State_store.t ->
  (string * Yojson.Safe.t) list ->
  float

(** Evaluate a JSON bool field — literal or string expression.
    Missing / unparseable falls back to [false]. *)
val eval_bool :
  Yojson.Safe.t option ->
  State_store.t ->
  (string * Yojson.Safe.t) list ->
  bool

(** Pull a single element path out of a [doc.*] effect spec.
    Accepts raw arrays, [__path__] markers, [{path: expr}] dicts,
    or string expressions resolving to [Value.Path] / list. *)
val extract_path :
  Yojson.Safe.t ->
  State_store.t ->
  (string * Yojson.Safe.t) list ->
  int list option

(** Pull a list of paths out of a [{paths: [...]}] spec. Items
    that don't resolve to a path are dropped. *)
val extract_path_list :
  Yojson.Safe.t ->
  State_store.t ->
  (string * Yojson.Safe.t) list ->
  int list list

(** True when [path] indexes an existing element in [doc]. Guards
    the [doc.set_selection] filter. *)
val is_valid_path : Document.document -> int list -> bool

(** Normalize a [{x1, y1, x2, y2, additive}] spec to
    [(x, y, w, h, additive)] with x/y the min corner and w/h the
    absolute side lengths. *)
val normalize_rect_args :
  (string * Yojson.Safe.t) list ->
  State_store.t ->
  (string * Yojson.Safe.t) list ->
  float * float * float * float * bool

(** Build the full platform-effects map for [Yaml_tool]. Phase 2
    covers doc.snapshot, doc.clear_selection, doc.set_selection,
    doc.add_to_selection, doc.toggle_selection,
    doc.translate_selection, doc.copy_selection,
    doc.select_in_rect, doc.partial_select_in_rect. Later phases
    extend this list with buffer.* / anchor.* / doc.add_element /
    doc.path.*, registered by the same builder. *)
val build :
  Controller.controller ->
  (string * Effects.platform_effect) list
