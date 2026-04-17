(** Schema table for workspace state fields.

    Mirrors the field definitions in [workspace/state.yaml] for the
    schema-driven [set:] effect.  Port of [workspace_interpreter/schema.py]. *)

(** Field types recognized by the schema.  [List] and [Object] are
    declared but not yet used by any schema entry. *)
type field_type =
  | Bool
  | Number
  | Str
  | Color
  | Enum of string list
  | List
  | Object

(** A schema entry describes a single writable state field. *)
type schema_entry = {
  field_type : field_type;
  nullable   : bool;
  writable   : bool;
}

(** Look up the schema entry for a top-level state key. *)
val get_entry : string -> schema_entry option

(** Coerce a raw JSON value to the type declared by [entry].  Returns
    [Ok coerced] on success or [Error reason] on mismatch. *)
val coerce_value :
  Yojson.Safe.t -> schema_entry -> (Yojson.Safe.t, string) result

(** Diagnostic emitted when a schema-validated write fails. *)
type diagnostic = {
  level  : string;  (** ["warning"] or ["error"] *)
  key    : string;
  reason : string;
}

(** Result of resolving a (possibly namespaced) key against the schema
    and the current panel scope.  [Ambiguous] is reserved for a
    cross-namespace collision case that the current [resolve_key] does
    not yet emit. *)
type resolved_key =
  | NotFound
  | Ambiguous
  | Found of string * string * schema_entry
      (** scope (["state"] or ["panel:<id>"]), field name, entry *)

(** Apply a schema-validated [set:] effect.  Validates each key
    against the schema, coerces values, and writes to [store].
    Unknown keys, ambiguous keys, non-writable fields, and type
    mismatches are accumulated into [diagnostics] as a batch. *)
val apply_set_schemadriven :
  ?active_panel:string option ->
  (string * Yojson.Safe.t) list ->
  State_store.t ->
  diagnostic list ref ->
  unit
