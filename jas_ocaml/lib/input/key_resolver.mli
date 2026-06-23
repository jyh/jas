(** Pure key-chord to action resolution (TESTING_STRATEGY.md section 5 rec 3).

    The framework key event is normalized into a framework-neutral {!chord}
    (the BINDING step, platform-specific, on the manual floor); RESOLUTION
    then looks the chord up against the compiled bundle [shortcuts] table to
    yield an action verb and its params. Resolution is PURE and framework-free,
    and is pinned cross-language by the key-resolution corpus so all four apps
    resolve a chord to byte-identical {action, params}.

    Wired into the GTK live keyboard path in Phase 2 of section 5 rec 3. *)

(** A normalized, framework-neutral key chord. [key] is the canonical token:
    an UPPERCASE ASCII letter ("V"), a digit ("0"), a symbol ("=", "-", "\\"),
    or a named key ("Delete", "Backspace"). [shift] is a SEPARATE flag, never
    folded into the character. *)
type chord = {
  key : string;
  ctrl : bool;
  shift : bool;
  alt : bool;
  meta : bool;
}

(** The resolved command: an action verb plus its resolved params (empty list
    when the matched shortcut entry carries none). *)
type resolved = {
  action : string;
  params : (string * Yojson.Safe.t) list;
}

(** Canonicalize a key token: a single ASCII letter is uppercased; every other
    token (digit, symbol, named key) is returned verbatim. *)
val canon_key : string -> string

(** Build a chord, canonicalizing the key token (missing modifier = [false])
    so live callers need not pre-normalize case. *)
val make_chord :
  key:string ->
  ?ctrl:bool -> ?shift:bool -> ?alt:bool -> ?meta:bool -> unit -> chord

(** Parse a bundle shortcut string ("Ctrl+Shift+S", "V", "Shift+E", "Delete",
    "\\") into a normalized chord. Tokens are split on [+]; all but the last
    are modifiers matched case-insensitively (ctrl/control, shift, alt/option,
    meta/cmd/command/super); the last token is the key. Returns [None] for an
    empty string. *)
val parse_shortcut : string -> chord option

(** Resolve against an explicit [shortcuts] array (the testable core). Returns
    the first entry whose parsed chord equals the input chord, or [None] if
    unmapped. *)
val resolve_key_in : chord -> Yojson.Safe.t list -> resolved option

(** Resolve a chord against the compiled bundle [shortcuts] table (loaded once
    per call). Returns the first matching {action, params}, or [None]. *)
val resolve_key : chord -> resolved option

(** The compiled bundle [shortcuts] table as entry JSON objects in declaration
    order; empty when the bundle is missing or ships no [shortcuts] key. *)
val bundle_shortcuts : unit -> Yojson.Safe.t list

(** Canonical JSON serializer (sorted object keys, document-order arrays,
    compact, standard string escaping) -- the shared cross-language
    canonicalization for the key corpus. *)
val canon_value : Yojson.Safe.t -> string

(** Wrap a resolved command as the canonical result value: [`Null] when
    unmapped, else [{action, params}]. *)
val result_value : resolved option -> Yojson.Safe.t
