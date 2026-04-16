(** Combined expression types, lexer, parser, and evaluator.

    Evaluates the workspace expression language against a Yojson.Safe.t context.
    Never raises exceptions — returns Null on error. *)

(* ================================================================== *)
(* Value type                                                          *)
(* ================================================================== *)

type value =
  | Null
  | Bool of bool
  | Number of float
  | Str of string
  | Color of string  (** normalized #rrggbb *)
  | List of Yojson.Safe.t list
  | Path of int list  (** Phase 3 §6.2: opaque document path *)
  | Closure of string list * ast * env  (** params, body, captured environment *)

(** Local environment for let bindings and closures.
    Separate from the JSON namespace context. *)
and env = (string * value) list

(* Forward declaration — the ast type is defined here with value (mutually recursive for Closure) *)
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

let value_of_json (j : Yojson.Safe.t) : value =
  match j with
  | `Null -> Null
  | `Bool b -> Bool b
  | `Int i -> Number (float_of_int i)
  | `Float f -> Number f
  | `String s ->
    let len = String.length s in
    if len >= 4 && s.[0] = '#' then
      let hex = String.sub s 1 (len - 1) in
      let hex_len = String.length hex in
      if (hex_len = 3 || hex_len = 6) &&
         String.for_all (fun c ->
           (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
         ) hex
      then
        let normalized = String.lowercase_ascii s in
        if hex_len = 3 then
          let expand i = String.make 2 (String.get (String.lowercase_ascii hex) i) in
          Color ("#" ^ expand 0 ^ expand 1 ^ expand 2)
        else
          Color normalized
      else
        Str s
    else
      Str s
  | `List lst -> List lst
  | `Assoc [("__path__", `List idx_list)] ->
    (* Round-trip path from JSON (Phase 3 §6.2) *)
    let idx_opt = List.fold_right (fun jv acc ->
      match acc, jv with
      | Some lst, `Int i when i >= 0 -> Some (i :: lst)
      | _ -> None
    ) idx_list (Some []) in
    (match idx_opt with Some lst -> Path lst | None -> Str (Yojson.Safe.to_string j))
  | `Assoc _ -> Str "__dict__"  (* keep reference via special marker *)
  | `Intlit s -> (try Number (float_of_string s) with _ -> Null)

let to_bool (v : value) : bool =
  match v with
  | Null -> false
  | Bool b -> b
  | Number n -> n <> 0.0
  | Str s -> String.length s > 0
  | Color _ -> true
  | List l -> List.length l > 0
  | Path p -> p <> []
  | Closure _ -> true

let to_string_coerce (v : value) : string =
  match v with
  | Null -> ""
  | Bool true -> "true"
  | Bool false -> "false"
  | Number n ->
    if Float.is_integer n then string_of_int (Float.to_int n)
    else string_of_float n
  | Str s -> s
  | Color c -> c
  | List _ -> "[list]"
  | Path p -> String.concat "." (List.map string_of_int p)
  | Closure _ -> "[closure]"

let strict_eq (a : value) (b : value) : bool =
  match a, b with
  | Null, Null -> true
  | Bool a, Bool b -> a = b
  | Number a, Number b -> a = b
  | Str a, Str b -> a = b
  | Color a, Color b ->
    let normalize c =
      let c = String.lowercase_ascii c in
      if String.length c = 4 then
        let expand i = String.make 2 c.[i] in
        "#" ^ expand 1 ^ expand 2 ^ expand 3
      else c
    in
    normalize a = normalize b
  | Path a, Path b -> a = b
  | Closure _, Closure _ -> false  (* closures are never equal *)
  | _ -> false

(** Convert a value to JSON for storing in context. Path uses a reserved
    __path__ key so it can round-trip through JSON and back to Value.Path. *)
let value_to_json (v : value) : Yojson.Safe.t =
  match v with
  | Null -> `Null
  | Bool b -> `Bool b
  | Number n ->
    if Float.is_integer n then `Int (Float.to_int n) else `Float n
  | Str s -> `String s
  | Color c -> `String c
  | List items -> `List items
  | Path indices ->
    `Assoc [("__path__", `List (List.map (fun i -> `Int i) indices))]
  | Closure _ -> `Null  (* closures cannot be serialized to JSON *)

(* ================================================================== *)
(* Token types                                                         *)
(* ================================================================== *)

type token_kind =
  | Tk_ident | Tk_number | Tk_string | Tk_color
  | Tk_true | Tk_false | Tk_null | Tk_not | Tk_and | Tk_or | Tk_in
  | Tk_fun | Tk_let | Tk_if | Tk_then | Tk_else
  | Tk_eq | Tk_neq | Tk_lt | Tk_gt | Tk_lte | Tk_gte
  | Tk_question | Tk_colon | Tk_dot | Tk_comma
  | Tk_lparen | Tk_rparen | Tk_lbracket | Tk_rbracket
  | Tk_plus | Tk_minus | Tk_star | Tk_slash
  | Tk_arrow | Tk_larrow | Tk_semicolon | Tk_equals
  | Tk_eof | Tk_error

type token = {
  kind : token_kind;
  str_val : string;
  num_val : float;
}

let mk_tok kind = { kind; str_val = ""; num_val = 0.0 }
let mk_tok_s kind s = { kind; str_val = s; num_val = 0.0 }
let mk_tok_n kind n = { kind; str_val = ""; num_val = n }

(* ================================================================== *)
(* Lexer                                                               *)
(* ================================================================== *)

let is_hex_char c =
  (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')

let keyword_kind = function
  | "true" -> Some Tk_true
  | "false" -> Some Tk_false
  | "null" -> Some Tk_null
  | "not" -> Some Tk_not
  | "and" -> Some Tk_and
  | "or" -> Some Tk_or
  | "in" -> Some Tk_in
  | "fun" -> Some Tk_fun
  | "let" -> Some Tk_let
  | "if" -> Some Tk_if
  | "then" -> Some Tk_then
  | "else" -> Some Tk_else
  | _ -> None

let tokenize (source : string) : token array =
  let n = String.length source in
  let result = ref [] in
  let add_token t = result := t :: !result in
  let i = ref 0 in
  while !i < n do
    let c = source.[!i] in
    if c = ' ' || c = '\t' || c = '\n' || c = '\r' then
      incr i
    else if c = '#' then begin
      (* Color literal *)
      let j = ref (!i + 1) in
      while !j < n && is_hex_char source.[!j] do incr j done;
      let hex_len = !j - !i - 1 in
      if hex_len = 3 || hex_len = 6 then begin
        add_token (mk_tok_s Tk_color (String.lowercase_ascii (String.sub source !i (!j - !i))));
        i := !j
      end else begin
        add_token (mk_tok_s Tk_error (String.sub source !i (!j - !i)));
        i := !j
      end
    end else if c = '"' || c = '\'' then begin
      (* String literal: double or single quotes — matches Python/Rust/Swift *)
      let quote = c in
      let j = ref (!i + 1) in
      let buf = Buffer.create 16 in
      while !j < n && source.[!j] <> quote do
        if source.[!j] = '\\' && !j + 1 < n then begin
          Buffer.add_char buf source.[!j + 1];
          j := !j + 2
        end else begin
          Buffer.add_char buf source.[!j];
          incr j
        end
      done;
      if !j < n then incr j;  (* consume closing quote *)
      add_token (mk_tok_s Tk_string (Buffer.contents buf));
      i := !j
    end else if c >= '0' && c <= '9' then begin
      (* Number — unary minus is handled as an operator *)
      let j = ref !i in
      while !j < n && source.[!j] >= '0' && source.[!j] <= '9' do incr j done;
      if !j < n && source.[!j] = '.' then begin
        incr j;
        while !j < n && source.[!j] >= '0' && source.[!j] <= '9' do incr j done;
        add_token (mk_tok_n Tk_number (float_of_string (String.sub source !i (!j - !i))));
      end else begin
        add_token (mk_tok_n Tk_number (float_of_int (int_of_string (String.sub source !i (!j - !i)))));
      end;
      i := !j
    end else if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_' then begin
      (* Identifier / keyword *)
      let j = ref (!i + 1) in
      while !j < n &&
            let ch = source.[!j] in
            (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
            (ch >= '0' && ch <= '9') || ch = '_'
      do incr j done;
      let word = String.sub source !i (!j - !i) in
      (match keyword_kind word with
       | Some k -> add_token (mk_tok_s k word)
       | None -> add_token (mk_tok_s Tk_ident word));
      i := !j
    end else begin
      (* Operators — multi-char first, order matters *)
      let next = if !i + 1 < n then source.[!i + 1] else '\x00' in
      if c = '=' && next = '=' then begin add_token (mk_tok Tk_eq); i := !i + 2 end
      else if c = '!' && next = '=' then begin add_token (mk_tok Tk_neq); i := !i + 2 end
      (* <- must come before <= check: greedy on < followed by - *)
      else if c = '<' && next = '-' then begin add_token (mk_tok Tk_larrow); i := !i + 2 end
      else if c = '<' && next = '=' then begin add_token (mk_tok Tk_lte); i := !i + 2 end
      else if c = '>' && next = '=' then begin add_token (mk_tok Tk_gte); i := !i + 2 end
      (* -> must come before single - *)
      else if c = '-' && next = '>' then begin add_token (mk_tok Tk_arrow); i := !i + 2 end
      else begin
        (match c with
         | '<' -> add_token (mk_tok Tk_lt)
         | '>' -> add_token (mk_tok Tk_gt)
         | '=' -> add_token (mk_tok Tk_equals)
         | '?' -> add_token (mk_tok Tk_question)
         | ':' -> add_token (mk_tok Tk_colon)
         | '.' -> add_token (mk_tok Tk_dot)
         | ',' -> add_token (mk_tok Tk_comma)
         | ';' -> add_token (mk_tok Tk_semicolon)
         | '(' -> add_token (mk_tok Tk_lparen)
         | ')' -> add_token (mk_tok Tk_rparen)
         | '[' -> add_token (mk_tok Tk_lbracket)
         | ']' -> add_token (mk_tok Tk_rbracket)
         | '+' -> add_token (mk_tok Tk_plus)
         | '-' -> add_token (mk_tok Tk_minus)
         | '*' -> add_token (mk_tok Tk_star)
         | '/' -> add_token (mk_tok Tk_slash)
         | _ -> add_token (mk_tok_s Tk_error (String.make 1 c)));
        incr i
      end
    end
  done;
  add_token (mk_tok Tk_eof);
  Array.of_list (List.rev !result)

(* ================================================================== *)
(* Parser                                                              *)
(* ================================================================== *)

exception Parse_error of string

type parser_state = {
  tokens : token array;
  mutable pos : int;
}

let parser_peek p = p.tokens.(p.pos)
let parser_advance p =
  let tok = p.tokens.(p.pos) in
  p.pos <- p.pos + 1;
  tok
let parser_expect p kind =
  let tok = parser_advance p in
  if tok.kind <> kind then
    raise (Parse_error (Printf.sprintf "Expected token kind, got another"));
  tok
let parser_at p kinds = List.mem (parser_peek p).kind kinds

(** sequence = let_expr (';' let_expr)* *)
let rec parse_sequence p =
  let node = parse_let p in
  if parser_at p [Tk_semicolon] then begin
    ignore (parser_advance p);
    let right = parse_let p in
    let result = ref (Ast_sequence (node, right)) in
    while parser_at p [Tk_semicolon] do
      ignore (parser_advance p);
      let r = parse_let p in
      result := Ast_sequence (!result, r)
    done;
    !result
  end else
    node

(** let_expr = 'let' IDENT '=' sequence 'in' let_expr | assign *)
and parse_let p =
  if parser_at p [Tk_let] then begin
    ignore (parser_advance p);
    let name_tok = parser_expect p Tk_ident in
    ignore (parser_expect p Tk_equals);
    let value = parse_sequence p in
    ignore (parser_expect p Tk_in);
    let body = parse_let p in
    Ast_let (name_tok.str_val, value, body)
  end else
    parse_assign p

(** assign = ternary '<-' assign | ternary *)
and parse_assign p =
  let node = parse_ternary p in
  if parser_at p [Tk_larrow] then begin
    ignore (parser_advance p);
    match node with
    | Ast_path [name] ->
      let value = parse_assign p in
      Ast_assign (name, value)
    | _ -> raise (Parse_error "Assignment target must be an identifier")
  end else
    node

and parse_ternary p =
  if parser_at p [Tk_if] then begin
    ignore (parser_advance p);
    let cond = parse_sequence p in
    ignore (parser_expect p Tk_then);
    let true_expr = parse_sequence p in
    ignore (parser_expect p Tk_else);
    let false_expr = parse_sequence p in
    Ast_ternary (cond, true_expr, false_expr)
  end else
    parse_or p

and parse_or p =
  let node = ref (parse_and p) in
  while parser_at p [Tk_or] do
    ignore (parser_advance p);
    let right = parse_and p in
    node := Ast_logical ("or", !node, right)
  done;
  !node

and parse_and p =
  let node = ref (parse_not p) in
  while parser_at p [Tk_and] do
    ignore (parser_advance p);
    let right = parse_not p in
    node := Ast_logical ("and", !node, right)
  done;
  !node

and parse_not p =
  if parser_at p [Tk_not] then begin
    ignore (parser_advance p);
    let operand = parse_not p in
    Ast_unary ("not", operand)
  end else if parser_at p [Tk_minus] then begin
    ignore (parser_advance p);
    let operand = parse_not p in
    Ast_unary ("-", operand)
  end else
    parse_comparison p

and parse_comparison p =
  let node = parse_addition p in
  let op_kinds = [Tk_eq; Tk_neq; Tk_lt; Tk_gt; Tk_lte; Tk_gte] in
  if parser_at p op_kinds then begin
    let op_tok = parser_advance p in
    let op_str = match op_tok.kind with
      | Tk_eq -> "==" | Tk_neq -> "!=" | Tk_lt -> "<" | Tk_gt -> ">"
      | Tk_lte -> "<=" | Tk_gte -> ">="
      | _ -> "=="
    in
    let right = parse_addition p in
    Ast_binary (op_str, node, right)
  end else
    node

(** addition = multiplication (('+' | '-') multiplication)* *)
and parse_addition p =
  let node = ref (parse_multiplication p) in
  while parser_at p [Tk_plus; Tk_minus] do
    let op_tok = parser_advance p in
    let op = if op_tok.kind = Tk_plus then "+" else "-" in
    let right = parse_multiplication p in
    node := Ast_binary (op, !node, right)
  done;
  !node

(** multiplication = primary (('*' | '/') primary)* *)
and parse_multiplication p =
  let node = ref (parse_primary p) in
  while parser_at p [Tk_star; Tk_slash] do
    let op_tok = parser_advance p in
    let op = if op_tok.kind = Tk_star then "*" else "/" in
    let right = parse_primary p in
    node := Ast_binary (op, !node, right)
  done;
  !node

and parse_primary p =
  let node = ref (parse_atom p) in
  let continue_ = ref true in
  while !continue_ do
    if parser_at p [Tk_dot] then begin
      ignore (parser_advance p);
      let tok = parser_peek p in
      let is_ident_like = match tok.kind with
        | Tk_ident | Tk_true | Tk_false | Tk_null | Tk_not | Tk_and | Tk_or | Tk_in
        | Tk_if | Tk_then | Tk_else -> true
        | _ -> false
      in
      if is_ident_like then begin
        let member = (parser_advance p).str_val in
        (match !node with
         | Ast_path segs -> node := Ast_path (segs @ [member])
         | _ -> node := Ast_dot_access (!node, member))
      end else if tok.kind = Tk_number then begin
        let idx = string_of_int (Float.to_int (parser_advance p).num_val) in
        (match !node with
         | Ast_path segs -> node := Ast_path (segs @ [idx])
         | _ -> node := Ast_dot_access (!node, idx))
      end else
        raise (Parse_error "Expected identifier after '.'")
    end else if parser_at p [Tk_lbracket] then begin
      ignore (parser_advance p);
      let index_expr = parse_sequence p in
      ignore (parser_expect p Tk_rbracket);
      node := Ast_index_access (!node, index_expr)
    end else if parser_at p [Tk_lparen] then begin
      (* Function application: expr(args) *)
      ignore (parser_advance p);
      let args = ref [] in
      if not (parser_at p [Tk_rparen]) then begin
        args := [parse_sequence p];
        while parser_at p [Tk_comma] do
          ignore (parser_advance p);
          args := !args @ [parse_sequence p]
        done
      end;
      ignore (parser_expect p Tk_rparen);
      (* If node is a simple path with one segment, use Ast_func_call for compat *)
      (match !node with
       | Ast_path [name] -> node := Ast_func_call (name, !args)
       | _ -> node := Ast_func_call ("__apply__", !node :: !args))
    end else
      continue_ := false
  done;
  !node

and parse_atom p =
  let tok = parser_peek p in
  match tok.kind with
  | Tk_fun ->
    (* Lambda: fun x -> body | fun (params) -> body | fun () -> body *)
    let _ = parser_advance p in
    let params = ref [] in
    if parser_at p [Tk_lparen] then begin
      ignore (parser_advance p);
      if not (parser_at p [Tk_rparen]) then begin
        params := [(parser_expect p Tk_ident).str_val];
        while parser_at p [Tk_comma] do
          ignore (parser_advance p);
          params := !params @ [(parser_expect p Tk_ident).str_val]
        done
      end;
      ignore (parser_expect p Tk_rparen)
    end else if parser_at p [Tk_ident] then begin
      params := [(parser_advance p).str_val]
    end;
    ignore (parser_expect p Tk_arrow);
    let body = parse_sequence p in
    Ast_lambda (!params, body)
  | Tk_ident ->
    let _ = parser_advance p in
    let _name = tok.str_val in
    (* Don't parse func call here — parse_primary handles Tk_lparen in accessor loop *)
    Ast_path [tok.str_val]
  | Tk_number ->
    let _ = parser_advance p in
    Ast_literal (Number tok.num_val)
  | Tk_string ->
    let _ = parser_advance p in
    Ast_literal (Str tok.str_val)
  | Tk_color ->
    let _ = parser_advance p in
    (* Normalize color *)
    let c = String.lowercase_ascii tok.str_val in
    let c = if String.length c = 4 then
      let expand i = String.make 2 c.[i] in
      "#" ^ expand 1 ^ expand 2 ^ expand 3
    else c
    in
    Ast_literal (Color c)
  | Tk_true ->
    let _ = parser_advance p in
    Ast_literal (Bool true)
  | Tk_false ->
    let _ = parser_advance p in
    Ast_literal (Bool false)
  | Tk_null ->
    let _ = parser_advance p in
    Ast_literal Null
  | Tk_lparen ->
    let _ = parser_advance p in
    let node = parse_sequence p in
    ignore (parser_expect p Tk_rparen);
    node
  | Tk_lbracket ->
    (* List literal: [expr, expr, ...] *)
    let _ = parser_advance p in
    let items = ref [] in
    if not (parser_at p [Tk_rbracket]) then begin
      items := [parse_sequence p];
      while parser_at p [Tk_comma] do
        ignore (parser_advance p);
        items := !items @ [parse_sequence p]
      done
    end;
    ignore (parser_expect p Tk_rbracket);
    Ast_list_literal !items
  | _ ->
    raise (Parse_error (Printf.sprintf "Unexpected token: %s" tok.str_val))

let parse (source : string) : ast option =
  let tokens = tokenize (String.trim source) in
  let p = { tokens; pos = 0 } in
  if (parser_peek p).kind = Tk_eof then None
  else
    let node = parse_sequence p in
    if (parser_peek p).kind <> Tk_eof then
      raise (Parse_error "Unexpected token after expression");
    Some node

(* ================================================================== *)
(* Evaluator                                                           *)
(* ================================================================== *)

(* Drill into a scope-bound value using a sequence of segments.
   Handles Path properties (.depth/.parent/.id/.indices). *)
let drill_value_by_segs (v : value) (segs : string list) : value =
  match v, segs with
  | Path indices, [member] ->
    (match member with
     | "depth" -> Number (float_of_int (List.length indices))
     | "parent" ->
       if indices = [] then Null
       else
         let rec drop_last = function
           | [] | [_] -> []
           | x :: xs -> x :: drop_last xs
         in Path (drop_last indices)
     | "id" -> Str (String.concat "." (List.map string_of_int indices))
     | "indices" -> List (List.map (fun i -> `Int i) indices)
     | _ -> Null)
  | _ -> Null

let resolve_path (segments : string list) (ctx : Yojson.Safe.t) : value =
  match segments with
  | [] -> Null
  | namespace :: rest ->
    let obj = match ctx with
      | `Assoc pairs -> (match List.assoc_opt namespace pairs with Some v -> v | None -> `Null)
      | _ -> `Null
    in
    let rec walk current segs =
      match segs with
      | [] -> value_of_json current
      | seg :: rest' ->
        (match current with
         | `Assoc pairs ->
           (match List.assoc_opt seg pairs with
            | Some v -> walk v rest'
            | None -> Null)
         | `List lst ->
           (match int_of_string_opt seg with
            | Some idx when idx >= 0 && idx < List.length lst ->
              walk (List.nth lst idx) rest'
            | _ ->
              if seg = "length" && rest' = [] then Number (float_of_int (List.length lst))
              else Null)
         | `String s ->
           if seg = "length" && rest' = [] then Number (float_of_int (String.length s))
           else Null
         | _ -> Null)
    in
    walk obj rest

(** Extract a hex color string from a value for color functions. *)
let color_arg (v : value) : string =
  match v with
  | Color c -> c
  | Str s -> s
  | Null -> "#000000"
  | _ -> "#000000"

(** Evaluate a color decomposition function. *)
let eval_color_decompose (name : string) (r : int) (g : int) (b : int) : float =
  match name with
  | "hsb_h" -> let (h, _, _) = Color_util.rgb_to_hsb r g b in float_of_int h
  | "hsb_s" -> let (_, s, _) = Color_util.rgb_to_hsb r g b in float_of_int s
  | "hsb_b" -> let (_, _, bv) = Color_util.rgb_to_hsb r g b in float_of_int bv
  | "rgb_r" -> float_of_int r
  | "rgb_g" -> float_of_int g
  | "rgb_b" -> float_of_int b
  | "cmyk_c" -> let (c, _, _, _) = Color_util.rgb_to_cmyk r g b in float_of_int c
  | "cmyk_m" -> let (_, m, _, _) = Color_util.rgb_to_cmyk r g b in float_of_int m
  | "cmyk_y" -> let (_, _, y, _) = Color_util.rgb_to_cmyk r g b in float_of_int y
  | "cmyk_k" -> let (_, _, _, k) = Color_util.rgb_to_cmyk r g b in float_of_int k
  | _ -> 0.0

let is_color_decompose = function
  | "hsb_h" | "hsb_s" | "hsb_b"
  | "rgb_r" | "rgb_g" | "rgb_b"
  | "cmyk_c" | "cmyk_m" | "cmyk_y" | "cmyk_k" -> true
  | _ -> false

(** Store callback type for assignments. *)
type store_cb = string -> value -> unit

(** Main evaluator — walks the AST.
    env: local bindings from let/lambda (can hold closures).
    ctx: JSON namespace context (state, panel, etc).
    store_cb: optional callback for <- assignments. *)
let rec eval_node ?(local_env : env = []) ?(store_cb : store_cb option)
    (node : ast) (ctx : Yojson.Safe.t) : value =
  match node with
  | Ast_literal v -> v
  | Ast_path segs ->
    (* Check local env first — single-segment or multi-segment (drill into
       a scope-bound value, e.g. lambda param `l` bound to a JSON dict). *)
    (match segs with
     | [] -> Null
     | name :: rest ->
       match List.assoc_opt name local_env with
       | Some v ->
         if rest = [] then v
         else drill_value_by_segs v rest
       | None -> resolve_path segs ctx)
  | Ast_func_call (name, args) -> eval_func ~local_env ?store_cb name args ctx
  | Ast_dot_access (obj, member) -> eval_dot_access ~local_env ?store_cb obj member ctx
  | Ast_index_access (obj, index) -> eval_index_access ~local_env ?store_cb obj index ctx
  | Ast_binary (op, left, right) -> eval_binary ~local_env ?store_cb op left right ctx
  | Ast_unary (op, operand) -> eval_unary ~local_env ?store_cb op operand ctx
  | Ast_ternary (cond, t, f) -> eval_ternary ~local_env ?store_cb cond t f ctx
  | Ast_logical (op, left, right) -> eval_logical ~local_env ?store_cb op left right ctx
  | Ast_lambda (params, body) ->
    Closure (params, body, local_env)
  | Ast_let (name, value_node, body) ->
    let v = eval_node ~local_env ?store_cb value_node ctx in
    let child_env = (name, v) :: local_env in
    eval_node ~local_env:child_env ?store_cb body ctx
  | Ast_assign (target, value_node) ->
    let v = eval_node ~local_env ?store_cb value_node ctx in
    (match store_cb with
     | Some cb -> cb target v
     | None -> ());
    v
  | Ast_sequence (left, right) ->
    ignore (eval_node ~local_env ?store_cb left ctx);
    eval_node ~local_env ?store_cb right ctx
  | Ast_list_literal items ->
    let vals = List.map (fun item ->
      let v = eval_node ~local_env ?store_cb item ctx in
      value_to_json v
    ) items in
    List vals

and eval_func ?(local_env : env = []) ?(store_cb : store_cb option)
    (name : string) (args : ast list) (ctx : Yojson.Safe.t) : value =
  (* __apply__: first arg is the callee expression result *)
  if name = "__apply__" && List.length args >= 1 then begin
    let callee = eval_node ~local_env ?store_cb (List.hd args) ctx in
    match callee with
    | Closure (params, body, captured_env) ->
      let arg_vals = List.map (fun a -> eval_node ~local_env ?store_cb a ctx) (List.tl args) in
      if List.length arg_vals <> List.length params then Null
      else begin
        let call_env = List.combine params arg_vals @ captured_env @ local_env in
        eval_node ~local_env:call_env ?store_cb body ctx
      end
    | _ -> Null
  end

  else begin
    (* Check if name resolves to a closure in the local env *)
    let closure_val = List.assoc_opt name local_env in
    match closure_val with
    | Some (Closure (params, body, captured_env)) ->
      let arg_vals = List.map (fun a -> eval_node ~local_env ?store_cb a ctx) args in
      if List.length arg_vals <> List.length params then Null
      else begin
        let call_env = List.combine params arg_vals @ captured_env @ local_env in
        eval_node ~local_env:call_env ?store_cb body ctx
      end
    | _ ->

    (* Color decomposition: single color argument -> number *)
    if is_color_decompose name then begin
      if List.length args <> 1 then Number 0.0
      else
        let arg = eval_node ~local_env ?store_cb (List.hd args) ctx in
        let c = color_arg arg in
        let (r, g, b) = Color_util.parse_hex c in
        Number (eval_color_decompose name r g b)
    end

    (* hex: color -> string (6 hex digits without #) *)
    else if name = "hex" then begin
      if List.length args <> 1 then Str ""
      else
        let arg = eval_node ~local_env ?store_cb (List.hd args) ctx in
        let c = color_arg arg in
        let (r, g, b) = Color_util.parse_hex c in
        Str (Printf.sprintf "%02x%02x%02x" r g b)
    end

    (* rgb: (r, g, b) -> color *)
    else if name = "rgb" then begin
      if List.length args <> 3 then Null
      else
        let vals = List.map (fun a -> eval_node ~local_env ?store_cb a ctx) args in
        let get_int v = match v with Number n -> Float.to_int n | _ -> 0 in
        let r = get_int (List.nth vals 0) in
        let g = get_int (List.nth vals 1) in
        let b = get_int (List.nth vals 2) in
        Color (Color_util.rgb_to_hex r g b)
    end

    (* hsb: (h, s, b) -> color *)
    else if name = "hsb" then begin
      if List.length args <> 3 then Null
      else
        let vals = List.map (fun a -> eval_node ~local_env ?store_cb a ctx) args in
        let get_float v = match v with Number n -> n | _ -> 0.0 in
        let h = get_float (List.nth vals 0) in
        let s = get_float (List.nth vals 1) in
        let bv = get_float (List.nth vals 2) in
        let (r, g, b) = Color_util.hsb_to_rgb h s bv in
        Color (Color_util.rgb_to_hex r g b)
    end

    (* invert: color -> color *)
    else if name = "invert" then begin
      if List.length args <> 1 then Null
      else
        let arg = eval_node ~local_env ?store_cb (List.hd args) ctx in
        let c = color_arg arg in
        let (r, g, b) = Color_util.parse_hex c in
        Color (Color_util.rgb_to_hex (255 - r) (255 - g) (255 - b))
    end

    (* complement: color -> color *)
    else if name = "complement" then begin
      if List.length args <> 1 then Null
      else
        let arg = eval_node ~local_env ?store_cb (List.hd args) ctx in
        let c = color_arg arg in
        let (r, g, b) = Color_util.parse_hex c in
        let (h, s, bv) = Color_util.rgb_to_hsb r g b in
        if s = 0 then
          Color (Color_util.rgb_to_hex r g b)
        else
          let new_h = (h + 180) mod 360 in
          let (nr, ng, nb) = Color_util.hsb_to_rgb (float_of_int new_h)
                               (float_of_int s) (float_of_int bv) in
          Color (Color_util.rgb_to_hex nr ng nb)
    end

    (* Higher-order functions (Phase 3 §6.1) *)
    else if name = "any" || name = "all" || name = "map" || name = "filter" then begin
      if List.length args <> 2 then
        (match name with "map" | "filter" -> Null | "all" -> Bool true | _ -> Bool false)
      else
        let lst = eval_node ~local_env ?store_cb (List.nth args 0) ctx in
        let callable = eval_node ~local_env ?store_cb (List.nth args 1) ctx in
        (match lst, callable with
         | List items, Closure (params, body, captured_env) when List.length params = 1 ->
           let param = List.hd params in
           let results = List.map (fun item ->
             (* Inject item into ctx as a top-level namespace so that
                multi-segment paths like `l.common.locked` resolve via
                JSON drilling. Lexical closure preserved via captured_env. *)
             let new_ctx = match ctx with
               | `Assoc pairs ->
                 `Assoc ((param, item) :: List.filter (fun (k,_) -> k <> param) pairs)
               | _ -> `Assoc [(param, item)]
             in
             eval_node ~local_env:captured_env ?store_cb body new_ctx
           ) items in
           (match name with
            | "any" -> Bool (List.exists to_bool results)
            | "all" -> Bool (List.for_all to_bool results)
            | "map" -> List (List.map value_to_json results)
            | "filter" ->
              let kept = List.filter_map (fun (item, r) ->
                if to_bool r then Some item else None
              ) (List.combine items results) in
              List kept
            | _ -> Null)
         | _ ->
           (match name with "map" | "filter" -> Null | "all" -> Bool true | _ -> Bool false))
    end

    (* Path functions (Phase 3 §6.2) *)
    else if name = "path" then begin
      let result = List.fold_left (fun acc a ->
        match acc with
        | None -> None
        | Some lst ->
          (match eval_node ~local_env ?store_cb a ctx with
           | Number n when n >= 0.0 -> Some (lst @ [Float.to_int n])
           | _ -> None)
      ) (Some []) args in
      match result with Some indices -> Path indices | None -> Null
    end

    else if name = "path_child" then begin
      if List.length args <> 2 then Null
      else
        let p = eval_node ~local_env ?store_cb (List.nth args 0) ctx in
        let i = eval_node ~local_env ?store_cb (List.nth args 1) ctx in
        match p, i with
        | Path indices, Number n when n >= 0.0 ->
          Path (indices @ [Float.to_int n])
        | _ -> Null
    end

    else if name = "path_from_id" then begin
      if List.length args <> 1 then Null
      else
        let s = eval_node ~local_env ?store_cb (List.hd args) ctx in
        match s with
        | Str "" -> Path []
        | Str str ->
          let parts = String.split_on_char '.' str in
          let idx_opt = List.fold_right (fun part acc ->
            match acc with
            | None -> None
            | Some lst ->
              match int_of_string_opt part with
              | Some n when n >= 0 -> Some (n :: lst)
              | _ -> None
          ) parts (Some []) in
          (match idx_opt with Some lst -> Path lst | None -> Null)
        | _ -> Null
    end

    (* mem: (element, list) -> bool — list membership *)
    else if name = "mem" then begin
      if List.length args <> 2 then Bool false
      else
        let elem = eval_node ~local_env ?store_cb (List.nth args 0) ctx in
        let lst = eval_node ~local_env ?store_cb (List.nth args 1) ctx in
        match lst with
        | List items ->
          let found = List.exists (fun item ->
            strict_eq elem (value_of_json item)
          ) items in
          Bool found
        | _ -> Bool false
    end

    (* Unknown function *)
    else Null
  end

(** JSON-preserving evaluator — used internally by dot/index access
    to avoid losing Assoc structure. *)
and eval_node_json_inner (node : ast) (ctx : Yojson.Safe.t) : Yojson.Safe.t =
  match node with
  | Ast_path segs ->
    (match segs with
     | [] -> `Null
     | namespace :: rest ->
       let obj = match ctx with
         | `Assoc pairs -> (match List.assoc_opt namespace pairs with Some v -> v | None -> `Null)
         | _ -> `Null
       in
       let rec walk current s =
         match s with
         | [] -> current
         | seg :: rest' ->
           (match current with
            | `Assoc pairs ->
              (match List.assoc_opt seg pairs with
               | Some v -> walk v rest'
               | None -> `Null)
            | `List lst ->
              (match int_of_string_opt seg with
               | Some idx when idx >= 0 && idx < List.length lst ->
                 walk (List.nth lst idx) rest'
               | _ -> `Null)
            | _ -> `Null)
       in
       walk obj rest)
  | Ast_index_access (obj_node, index_node) ->
    let obj_json = eval_node_json_inner obj_node ctx in
    let idx_val = eval_node index_node ctx in
    let key = to_string_coerce idx_val in
    (match obj_json with
     | `Assoc pairs ->
       (match List.assoc_opt key pairs with
        | Some v -> v
        | None -> `Null)
     | `List lst ->
       (match int_of_string_opt key with
        | Some idx when idx >= 0 && idx < List.length lst ->
          List.nth lst idx
        | _ -> `Null)
     | _ -> `Null)
  | Ast_dot_access (obj_node, member) ->
    let obj_json = eval_node_json_inner obj_node ctx in
    (match obj_json with
     | `Assoc pairs ->
       (match List.assoc_opt member pairs with
        | Some v -> v
        | None -> `Null)
     | `List lst ->
       (match int_of_string_opt member with
        | Some idx when idx >= 0 && idx < List.length lst ->
          List.nth lst idx
        | _ -> `Null)
     | _ -> `Null)
  | _ ->
    (* For non-path expressions, evaluate and convert to JSON *)
    let v = eval_node node ctx in
    value_to_json v

and eval_dot_access ?(local_env : env = []) ?(store_cb : store_cb option)
    (obj_node : ast) (member : string) (ctx : Yojson.Safe.t) : value =
  (* Check for Path value first — pre-eval so we catch path-producing
     expressions (path(...), path_child(...), foreach-bound paths). *)
  let obj_val_for_path = eval_node ~local_env ?store_cb obj_node ctx in
  (match obj_val_for_path with
   | Path indices ->
     (match member with
      | "depth" -> Number (float_of_int (List.length indices))
      | "parent" ->
        if indices = [] then Null
        else
          let rec drop_last = function
            | [] | [_] -> []
            | x :: xs -> x :: drop_last xs
          in
          Path (drop_last indices)
      | "id" -> Str (String.concat "." (List.map string_of_int indices))
      | "indices" -> List (List.map (fun i -> `Int i) indices)
      | _ -> Null)
   | _ ->
  (* Try JSON-preserving path first for path/accessor chains *)
  let obj_json = eval_node_json_inner obj_node ctx in
  (match obj_json with
   | `Assoc pairs ->
     (match List.assoc_opt member pairs with
      | Some v -> value_of_json v
      | None -> Null)
   | `List lst ->
     if member = "length" then Number (float_of_int (List.length lst))
     else begin
       match int_of_string_opt member with
       | Some idx when idx >= 0 && idx < List.length lst ->
         value_of_json (List.nth lst idx)
       | _ -> Null
     end
   | `String s ->
     if member = "length" then Number (float_of_int (String.length s))
     else Null
   | _ ->
     (* Fallback to value-based eval for computed expressions *)
     let obj_val = eval_node ~local_env ?store_cb obj_node ctx in
     (match obj_val with
      | List l ->
        if member = "length" then Number (float_of_int (List.length l))
        else begin
          match int_of_string_opt member with
          | Some idx when idx >= 0 && idx < List.length l ->
            value_of_json (List.nth l idx)
          | _ -> Null
        end
      | Str s ->
        if member = "length" then Number (float_of_int (String.length s))
        else Null
      | _ -> Null)))

and eval_index_access ?(local_env : env = []) ?(store_cb : store_cb option)
    (obj_node : ast) (index_node : ast) (ctx : Yojson.Safe.t) : value =
  let idx_val = eval_node ~local_env ?store_cb index_node ctx in
  let key = to_string_coerce idx_val in
  (* Try JSON-preserving path first for dict indexing *)
  let obj_json = eval_node_json_inner obj_node ctx in
  (match obj_json with
   | `Assoc pairs ->
     (match List.assoc_opt key pairs with
      | Some v -> value_of_json v
      | None -> Null)
   | `List lst ->
     (match int_of_string_opt key with
      | Some idx when idx >= 0 && idx < List.length lst ->
        value_of_json (List.nth lst idx)
      | _ -> Null)
   | _ ->
     let obj_val = eval_node ~local_env ?store_cb obj_node ctx in
     (match obj_val with
      | List l ->
        (match int_of_string_opt key with
         | Some idx when idx >= 0 && idx < List.length l ->
           value_of_json (List.nth l idx)
         | _ -> Null)
      | _ -> Null))

and eval_binary ?(local_env : env = []) ?(store_cb : store_cb option)
    (op : string) (left_node : ast) (right_node : ast) (ctx : Yojson.Safe.t) : value =
  let left = eval_node ~local_env ?store_cb left_node ctx in
  let right = eval_node ~local_env ?store_cb right_node ctx in
  match op with
  | "==" -> Bool (strict_eq left right)
  | "!=" -> Bool (not (strict_eq left right))
  | "<" -> numeric_cmp left right ( < )
  | ">" -> numeric_cmp left right ( > )
  | "<=" -> numeric_cmp left right ( <= )
  | ">=" -> numeric_cmp left right ( >= )
  | "in" -> eval_in left right
  | "+" ->
    (match left, right with
     | Number a, Number b -> Number (a +. b)
     | _ -> Str (to_string_coerce left ^ to_string_coerce right))
  | "-" ->
    (match left, right with
     | Number a, Number b -> Number (a -. b)
     | _ -> Null)
  | "*" ->
    (match left, right with
     | Number a, Number b -> Number (a *. b)
     | _ -> Null)
  | "/" ->
    (match left, right with
     | Number a, Number b ->
       if b = 0.0 then Null
       else Number (a /. b)
     | _ -> Null)
  | _ -> Null

and numeric_cmp (left : value) (right : value) (cmp : float -> float -> bool) : value =
  match left, right with
  | Number a, Number b -> Bool (cmp a b)
  | _ -> Bool false

and eval_in (left : value) (right : value) : value =
  match right with
  | List lst ->
    let found = List.exists (fun item ->
      strict_eq left (value_of_json item)
    ) lst in
    Bool found
  | _ -> Bool false

and eval_unary ?(local_env : env = []) ?(store_cb : store_cb option)
    (op : string) (operand_node : ast) (ctx : Yojson.Safe.t) : value =
  match op with
  | "not" ->
    let v = eval_node ~local_env ?store_cb operand_node ctx in
    Bool (not (to_bool v))
  | "-" ->
    let v = eval_node ~local_env ?store_cb operand_node ctx in
    (match v with
     | Number n -> Number (-.n)
     | _ -> Null)
  | _ -> Null

and eval_ternary ?(local_env : env = []) ?(store_cb : store_cb option)
    (cond_node : ast) (true_node : ast) (false_node : ast) (ctx : Yojson.Safe.t) : value =
  let cond = eval_node ~local_env ?store_cb cond_node ctx in
  if to_bool cond then eval_node ~local_env ?store_cb true_node ctx
  else eval_node ~local_env ?store_cb false_node ctx

and eval_logical ?(local_env : env = []) ?(store_cb : store_cb option)
    (op : string) (left_node : ast) (right_node : ast) (ctx : Yojson.Safe.t) : value =
  let left = eval_node ~local_env ?store_cb left_node ctx in
  match op with
  | "and" ->
    if not (to_bool left) then left
    else eval_node ~local_env ?store_cb right_node ctx
  | "or" ->
    if to_bool left then left
    else eval_node ~local_env ?store_cb right_node ctx
  | _ -> Null

(* ================================================================== *)
(* Public API                                                          *)
(* ================================================================== *)

let evaluate ?(local_env : env = []) ?(store_cb : store_cb option)
    (expr_str : string) (ctx : Yojson.Safe.t) : value =
  if String.length expr_str = 0 then Null
  else
    try
      match parse (String.trim expr_str) with
      | None -> Null
      | Some ast -> eval_node ~local_env ?store_cb ast ctx
    with _ -> Null

(** Resolve a dot-separated path through a JSON context, returning raw JSON.
    Unlike resolve_path, this preserves Assoc/List structure. *)
let resolve_path_json (segments : string list) (ctx : Yojson.Safe.t) : Yojson.Safe.t =
  match segments with
  | [] -> `Null
  | namespace :: rest ->
    let obj = match ctx with
      | `Assoc pairs -> (match List.assoc_opt namespace pairs with Some v -> v | None -> `Null)
      | _ -> `Null
    in
    let rec walk current segs =
      match segs with
      | [] -> current
      | seg :: rest' ->
        (match current with
         | `Assoc pairs ->
           (match List.assoc_opt seg pairs with
            | Some v -> walk v rest'
            | None -> `Null)
         | `List lst ->
           (match int_of_string_opt seg with
            | Some idx when idx >= 0 && idx < List.length lst ->
              walk (List.nth lst idx) rest'
            | _ -> `Null)
         | _ -> `Null)
    in
    walk obj rest

(** Walk an AST node returning raw Yojson.Safe.t, preserving objects and arrays.
    Falls back to value-to-json conversion for non-path expressions. *)
let rec eval_node_json (node : ast) (ctx : Yojson.Safe.t) : Yojson.Safe.t =
  match node with
  | Ast_path segs -> resolve_path_json segs ctx
  | Ast_index_access (obj_node, index_node) ->
    let obj_json = eval_node_json obj_node ctx in
    let idx_val = eval_node index_node ctx in
    let key = to_string_coerce idx_val in
    (match obj_json with
     | `Assoc pairs ->
       (match List.assoc_opt key pairs with
        | Some v -> v
        | None -> `Null)
     | `List lst ->
       (match int_of_string_opt key with
        | Some idx when idx >= 0 && idx < List.length lst ->
          List.nth lst idx
        | _ -> `Null)
     | _ -> `Null)
  | Ast_dot_access (obj_node, member) ->
    let obj_json = eval_node_json obj_node ctx in
    (match obj_json with
     | `Assoc pairs ->
       (match List.assoc_opt member pairs with
        | Some v -> v
        | None -> `Null)
     | `List lst ->
       (match int_of_string_opt member with
        | Some idx when idx >= 0 && idx < List.length lst ->
          List.nth lst idx
        | _ -> `Null)
     | _ -> `Null)
  | _ ->
    (* For non-path expressions, evaluate and convert back to JSON *)
    let v = eval_node node ctx in
    value_to_json v

(** Evaluate an expression and return the result as raw Yojson.Safe.t,
    preserving objects and arrays. Used by the repeat directive. *)
let evaluate_to_json (expr_str : string) (ctx : Yojson.Safe.t) : Yojson.Safe.t =
  if String.length expr_str = 0 then `Null
  else
    try
      match parse (String.trim expr_str) with
      | None -> `Null
      | Some ast -> eval_node_json ast ctx
    with _ -> `Null

let evaluate_text (text : string) (ctx : Yojson.Safe.t) : string =
  if String.length text = 0 || not (try ignore (Str.search_forward (Str.regexp_string "{{") text 0); true with Not_found -> false) then
    text
  else
    let re = Str.regexp "{{\\([^}]+\\)}}" in
    let result = ref text in
    (* Use Str.global_substitute for replacement *)
    (try
       result := Str.global_substitute re (fun s ->
         let expr = String.trim (Str.matched_group 1 s) in
         let v = evaluate expr ctx in
         to_string_coerce v
       ) !result
     with _ -> ());
    !result
