(* Pure key-chord to action resolution (TESTING_STRATEGY.md section 5 rec 3).

   A keyboard shortcut becomes an application command in two steps:
     1. BINDING -- the framework key event (GTK GdkEvent.Key, AppKit NSEvent,
        Dioxus KeyboardData, Qt QKeyEvent) is normalized into a
        framework-neutral [chord]. This is platform-specific and stays on the
        MANUAL floor.
     2. RESOLUTION -- the chord is looked up against the compiled bundle
        [shortcuts] table (workspace/shortcuts.yaml) to yield an action verb
        and its params. This step is PURE and framework-free, and is the
        refactor target of section 5 rec 3: it is pinned cross-language by the
        key corpus in test/cross_language_test.ml so all four apps resolve a
        chord to byte-identical {action, params}.

   [shortcuts] is the single authoritative key-to-action table; it carries
   both menu actions (Ctrl+N -> new_document) and tool selections
   (V -> select_tool {tool: selection}), already disambiguated (no duplicate
   chords). Resolution is therefore a first-match lookup -- the list order is
   a deterministic tie-break that the present table never exercises.

   These functions are exercised today by the key-resolution corpus and get
   wired into the GTK live keyboard path in Phase 2 of section 5 rec 3. *)

(* A normalized, framework-neutral key chord. [key] is the canonical token:
   an UPPERCASE ASCII letter ("V"), a digit ("0"), a symbol ("=", "-", "\\"),
   or a named key ("Delete", "Backspace"). [shift] is carried as a SEPARATE
   flag and is never folded into the character. *)
type chord = {
  key : string;
  ctrl : bool;
  shift : bool;
  alt : bool;
  meta : bool;
}

(* The resolved command: an action verb plus its resolved params (defaults to
   the empty list when the entry carries none). *)
type resolved = {
  action : string;
  params : (string * Yojson.Safe.t) list;
}

(* Canonicalize a key token: a single ASCII letter is uppercased; every other
   token (digit, symbol, named key) is returned verbatim. This makes the chord
   comparison case-insensitive for letters while leaving "Delete", "=", "\\"
   untouched. *)
let canon_key (key : string) : string =
  if String.length key = 1 then
    let c = key.[0] in
    if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') then
      String.uppercase_ascii key
    else key
  else key

(* Build a chord, canonicalizing the key token so live callers need not
   pre-normalize case. *)
let make_chord ~key ?(ctrl = false) ?(shift = false) ?(alt = false)
    ?(meta = false) () : chord =
  { key = canon_key key; ctrl; shift; alt; meta }

(* Split [s] on the separator character [sep]. *)
let split_on_char sep s =
  String.split_on_char sep s

(* Parse a bundle shortcut string ("Ctrl+Shift+S", "V", "Shift+E", "Delete",
   "\\") into a normalized chord. Tokens are split on [+]; all but the last are
   modifiers (matched case-insensitively: ctrl/control, shift, alt/option,
   meta/cmd/command/super), and the last token is the key. Returns [None] for
   an empty string. (No shortcut in the table uses [+] as its key, so splitting
   on [+] is unambiguous here.) *)
let parse_shortcut (s : string) : chord option =
  if String.length s = 0 then None
  else begin
    let tokens = split_on_char '+' s in
    (* split_on_char never returns an empty list, so [tokens] has at least one
       element; the last is the key, the rest are modifiers. *)
    match List.rev tokens with
    | [] -> None
    | key_tok :: rev_mods ->
      let ctrl = ref false and shift = ref false in
      let alt = ref false and meta = ref false in
      List.iter (fun m ->
        match String.lowercase_ascii m with
        | "ctrl" | "control" -> ctrl := true
        | "shift" -> shift := true
        | "alt" | "option" -> alt := true
        | "meta" | "cmd" | "command" | "super" -> meta := true
        (* Unknown modifier token: ignore (keeps parsing total). *)
        | _ -> ()
      ) rev_mods;
      Some {
        key = canon_key key_tok;
        ctrl = !ctrl;
        shift = !shift;
        alt = !alt;
        meta = !meta;
      }
  end

(* Equality on normalized chords (all five components). *)
let chord_equal (a : chord) (b : chord) : bool =
  a.key = b.key && a.ctrl = b.ctrl && a.shift = b.shift
  && a.alt = b.alt && a.meta = b.meta

(* Pull a string member out of a JSON object, [None] when absent / wrong type. *)
let str_member key (j : Yojson.Safe.t) : string option =
  match j with
  | `Assoc pairs ->
    (match List.assoc_opt key pairs with
     | Some (`String s) -> Some s
     | _ -> None)
  | _ -> None

(* Resolve against an explicit [shortcuts] array (the testable core, so the
   corpus can resolve every case against one loaded bundle). Returns the first
   entry whose parsed chord equals [chord], or [None] if unmapped. *)
let resolve_key_in (chord : chord) (shortcuts : Yojson.Safe.t list)
  : resolved option =
  let rec loop = function
    | [] -> None
    | entry :: rest ->
      (match str_member "key" entry with
       | None -> loop rest
       | Some key ->
         (match parse_shortcut key with
          | None -> loop rest
          | Some parsed ->
            if chord_equal parsed chord then begin
              let action =
                match str_member "action" entry with
                | Some a -> a
                | None -> ""
              in
              let params =
                match entry with
                | `Assoc pairs ->
                  (match List.assoc_opt "params" pairs with
                   | Some (`Assoc p) -> p
                   | _ -> [])
                | _ -> []
              in
              Some { action; params }
            end else loop rest))
  in
  loop shortcuts

(* The compiled bundle [shortcuts] table as a list of entry JSON objects in
   declaration order. Empty when the bundle ships no [shortcuts] key. Mirrors
   how Menu_model reads the [menubar] key from the same bundle. *)
let bundle_shortcuts () : Yojson.Safe.t list =
  match Workspace_loader.load () with
  | None -> []
  | Some ws -> Workspace_loader.shortcuts ws

(* Resolve a chord against the compiled bundle [shortcuts] table. Returns the
   first entry whose parsed chord equals [chord], or [None] if unmapped. This
   is the entry point the GTK live keyboard path calls in Phase 2. *)
let resolve_key (chord : chord) : resolved option =
  resolve_key_in chord (bundle_shortcuts ())

(* Canonical JSON serializer for the key corpus: object keys are emitted in
   sorted order, arrays in document order, scalars via Yojson (correct string
   escaping). This is the shared cross-language canonicalization -- every app
   must produce byte-identical output for the same resolved commands. *)
let rec canon_value (v : Yojson.Safe.t) : string =
  match v with
  | `Assoc pairs ->
    let sorted = List.sort (fun (a, _) (b, _) -> compare a b) pairs in
    let body =
      List.map (fun (k, value) ->
        Printf.sprintf "%s:%s"
          (Yojson.Safe.to_string (`String k))
          (canon_value value))
        sorted
    in
    "{" ^ String.concat "," body ^ "}"
  | `List items ->
    "[" ^ String.concat "," (List.map canon_value items) ^ "]"
  | other -> Yojson.Safe.to_string other

(* Wrap a resolved command (or its absence) as the canonical result value:
   [`Null] when unmapped, else {action, params}. *)
let result_value (cmd : resolved option) : Yojson.Safe.t =
  match cmd with
  | None -> `Null
  | Some c -> `Assoc [ ("action", `String c.action); ("params", `Assoc c.params) ]
