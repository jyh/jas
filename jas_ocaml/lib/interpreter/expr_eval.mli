(** Combined expression types, lexer, parser, and evaluator.

    Evaluates the workspace expression language against a [Yojson.Safe.t]
    context.  Never raises exceptions — returns [Null] on error. *)

(** The value produced by expression evaluation. *)
type value =
  | Null
  | Bool of bool
  | Number of float
  | Str of string
  | Color of string  (** normalized [#rrggbb] *)
  | List of Yojson.Safe.t list
  | Path of int list  (** Phase 3 §6.2: opaque document path *)
  | Closure of string list * ast * env  (** params, body, captured environment *)

(** Local environment for [let] bindings and closures.
    Separate from the JSON namespace context. *)
and env = (string * value) list

(** Parsed expression AST. *)
and ast =
  | Ast_literal of value
  | Ast_path of string list
  | Ast_func_call of string * ast list
  | Ast_index_access of ast * ast
  | Ast_dot_access of ast * string
  | Ast_binary of string * ast * ast
  | Ast_unary of string * ast
  | Ast_ternary of ast * ast * ast
  | Ast_logical of string * ast * ast
  | Ast_lambda of string list * ast
  | Ast_let of string * ast * ast
  | Ast_assign of string * ast
  | Ast_sequence of ast * ast
  | Ast_list_literal of ast list

(** Callback for [<-] assignments: [(target_name, value) -> unit]. *)
type store_cb = string -> value -> unit

(** Convert raw JSON into a value. *)
val value_of_json : Yojson.Safe.t -> value

(** Convert a value back to JSON for storage. *)
val value_to_json : value -> Yojson.Safe.t

(** Coerce a value to bool using truthy/falsy semantics. *)
val to_bool : value -> bool

(** Evaluate a pre-parsed AST. [local_env] provides [let]/lambda bindings;
    [store_cb] handles [<-] assignment side effects. *)
val eval_node :
  ?local_env:env ->
  ?store_cb:store_cb ->
  ast ->
  Yojson.Safe.t ->
  value

(** Parse and evaluate an expression string.  Returns [Null] on parse or
    runtime error (no exceptions). *)
val evaluate :
  ?local_env:env ->
  ?store_cb:store_cb ->
  string ->
  Yojson.Safe.t ->
  value

(** Parse and evaluate an expression, returning raw JSON (preserves
    [`Assoc] / [`List] structure that [evaluate] would collapse). *)
val evaluate_to_json : string -> Yojson.Safe.t -> Yojson.Safe.t

(** Interpolate [{{expr}}] regions in [text] with evaluated string values.
    Text outside [{{...}}] is preserved literally. *)
val evaluate_text : string -> Yojson.Safe.t -> string
