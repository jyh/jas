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
  | _ -> false

(* ================================================================== *)
(* Token types                                                         *)
(* ================================================================== *)

type token_kind =
  | Tk_ident | Tk_number | Tk_string | Tk_color
  | Tk_true | Tk_false | Tk_null | Tk_not | Tk_and | Tk_or | Tk_in
  | Tk_eq | Tk_neq | Tk_lt | Tk_gt | Tk_lte | Tk_gte
  | Tk_question | Tk_colon | Tk_dot | Tk_comma
  | Tk_lparen | Tk_rparen | Tk_lbracket | Tk_rbracket
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
  | _ -> None

let tokenize (source : string) : token array =
  let n = String.length source in
  let result = ref [] in
  let add_token t = result := t :: !result in
  let i = ref 0 in
  while !i < n do
    let c = source.[!i] in
    if c = ' ' || c = '\t' then
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
    end else if c = '"' then begin
      (* String literal *)
      let j = ref (!i + 1) in
      let buf = Buffer.create 16 in
      while !j < n && source.[!j] <> '"' do
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
    end else if c >= '0' && c <= '9' ||
                (c = '-' && !i + 1 < n && source.[!i + 1] >= '0' && source.[!i + 1] <= '9') then begin
      (* Number *)
      let j = ref (if c = '-' then !i + 1 else !i) in
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
      (* Operators *)
      let two =
        if !i + 1 < n then String.sub source !i 2 else ""
      in
      if two = "==" then begin add_token (mk_tok Tk_eq); i := !i + 2 end
      else if two = "!=" then begin add_token (mk_tok Tk_neq); i := !i + 2 end
      else if two = "<=" then begin add_token (mk_tok Tk_lte); i := !i + 2 end
      else if two = ">=" then begin add_token (mk_tok Tk_gte); i := !i + 2 end
      else begin
        (match c with
         | '<' -> add_token (mk_tok Tk_lt)
         | '>' -> add_token (mk_tok Tk_gt)
         | '?' -> add_token (mk_tok Tk_question)
         | ':' -> add_token (mk_tok Tk_colon)
         | '.' -> add_token (mk_tok Tk_dot)
         | ',' -> add_token (mk_tok Tk_comma)
         | '(' -> add_token (mk_tok Tk_lparen)
         | ')' -> add_token (mk_tok Tk_rparen)
         | '[' -> add_token (mk_tok Tk_lbracket)
         | ']' -> add_token (mk_tok Tk_rbracket)
         | _ -> add_token (mk_tok_s Tk_error (String.make 1 c)));
        incr i
      end
    end
  done;
  add_token (mk_tok Tk_eof);
  Array.of_list (List.rev !result)

(* ================================================================== *)
(* AST                                                                 *)
(* ================================================================== *)

type ast =
  | Ast_literal of value
  | Ast_path of string list
  | Ast_func_call of string * ast list
  | Ast_index_access of ast * ast
  | Ast_dot_access of ast * string
  | Ast_binary of string * ast * ast
  | Ast_unary of string * ast
  | Ast_ternary of ast * ast * ast
  | Ast_logical of string * ast * ast

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

let rec parse_ternary p =
  let node = parse_or p in
  if parser_at p [Tk_question] then begin
    ignore (parser_advance p);
    let true_expr = parse_ternary p in
    ignore (parser_expect p Tk_colon);
    let false_expr = parse_ternary p in
    Ast_ternary (node, true_expr, false_expr)
  end else
    node

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
  end else
    parse_comparison p

and parse_comparison p =
  let node = parse_primary p in
  let op_kinds = [Tk_eq; Tk_neq; Tk_lt; Tk_gt; Tk_lte; Tk_gte; Tk_in] in
  if parser_at p op_kinds then begin
    let op_tok = parser_advance p in
    let op_str = match op_tok.kind with
      | Tk_eq -> "==" | Tk_neq -> "!=" | Tk_lt -> "<" | Tk_gt -> ">"
      | Tk_lte -> "<=" | Tk_gte -> ">=" | Tk_in -> "in"
      | _ -> "=="
    in
    let right = parse_primary p in
    Ast_binary (op_str, node, right)
  end else
    node

and parse_primary p =
  let node = ref (parse_atom p) in
  let continue_ = ref true in
  while !continue_ do
    if parser_at p [Tk_dot] then begin
      ignore (parser_advance p);
      let tok = parser_peek p in
      let is_ident_like = match tok.kind with
        | Tk_ident | Tk_true | Tk_false | Tk_null | Tk_not | Tk_and | Tk_or | Tk_in -> true
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
      let index_expr = parse_ternary p in
      ignore (parser_expect p Tk_rbracket);
      node := Ast_index_access (!node, index_expr)
    end else
      continue_ := false
  done;
  !node

and parse_atom p =
  let tok = parser_peek p in
  match tok.kind with
  | Tk_ident ->
    let _ = parser_advance p in
    let name = tok.str_val in
    if parser_at p [Tk_lparen] then begin
      (* Function call *)
      ignore (parser_advance p);
      let args = ref [] in
      if not (parser_at p [Tk_rparen]) then begin
        args := [parse_ternary p];
        while parser_at p [Tk_comma] do
          ignore (parser_advance p);
          args := !args @ [parse_ternary p]
        done
      end;
      ignore (parser_expect p Tk_rparen);
      Ast_func_call (name, !args)
    end else
      Ast_path [name]
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
    let node = parse_ternary p in
    ignore (parser_expect p Tk_rparen);
    node
  | _ ->
    raise (Parse_error (Printf.sprintf "Unexpected token: %s" tok.str_val))

let parse (source : string) : ast option =
  let tokens = tokenize (String.trim source) in
  let p = { tokens; pos = 0 } in
  if (parser_peek p).kind = Tk_eof then None
  else
    let node = parse_ternary p in
    if (parser_peek p).kind <> Tk_eof then
      raise (Parse_error "Unexpected token after expression");
    Some node

(* ================================================================== *)
(* Evaluator                                                           *)
(* ================================================================== *)

(** Resolve a dot-separated path through a JSON context. *)
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

(** Main evaluator — walks the AST. *)
let rec eval_node (node : ast) (ctx : Yojson.Safe.t) : value =
  match node with
  | Ast_literal v -> v
  | Ast_path segs -> resolve_path segs ctx
  | Ast_func_call (name, args) -> eval_func name args ctx
  | Ast_dot_access (obj, member) -> eval_dot_access obj member ctx
  | Ast_index_access (obj, index) -> eval_index_access obj index ctx
  | Ast_binary (op, left, right) -> eval_binary op left right ctx
  | Ast_unary (op, operand) -> eval_unary op operand ctx
  | Ast_ternary (cond, t, f) -> eval_ternary cond t f ctx
  | Ast_logical (op, left, right) -> eval_logical op left right ctx

and eval_func (name : string) (args : ast list) (ctx : Yojson.Safe.t) : value =
  (* Color decomposition: single color argument -> number *)
  if is_color_decompose name then begin
    if List.length args <> 1 then Number 0.0
    else
      let arg = eval_node (List.hd args) ctx in
      let c = color_arg arg in
      let (r, g, b) = Color_util.parse_hex c in
      Number (eval_color_decompose name r g b)
  end

  (* hex: color -> string (6 hex digits without #) *)
  else if name = "hex" then begin
    if List.length args <> 1 then Str ""
    else
      let arg = eval_node (List.hd args) ctx in
      let c = color_arg arg in
      let (r, g, b) = Color_util.parse_hex c in
      Str (Printf.sprintf "%02x%02x%02x" r g b)
  end

  (* rgb: (r, g, b) -> color *)
  else if name = "rgb" then begin
    if List.length args <> 3 then Null
    else
      let vals = List.map (fun a -> eval_node a ctx) args in
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
      let vals = List.map (fun a -> eval_node a ctx) args in
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
      let arg = eval_node (List.hd args) ctx in
      let c = color_arg arg in
      let (r, g, b) = Color_util.parse_hex c in
      Color (Color_util.rgb_to_hex (255 - r) (255 - g) (255 - b))
  end

  (* complement: color -> color *)
  else if name = "complement" then begin
    if List.length args <> 1 then Null
    else
      let arg = eval_node (List.hd args) ctx in
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

  (* Unknown function *)
  else Null

and eval_dot_access (obj_node : ast) (member : string) (ctx : Yojson.Safe.t) : value =
  let obj_val = eval_node obj_node ctx in
  (* List methods *)
  (match obj_val with
   | List l ->
     if member = "length" then Number (float_of_int (List.length l))
     else begin
       (* Numeric index on list *)
       match int_of_string_opt member with
       | Some idx when idx >= 0 && idx < List.length l ->
         value_of_json (List.nth l idx)
       | _ -> Null
     end
   | Str s ->
     if member = "length" then Number (float_of_int (String.length s))
     else Null
   | _ -> Null)

and eval_index_access (obj_node : ast) (index_node : ast) (ctx : Yojson.Safe.t) : value =
  let obj_val = eval_node obj_node ctx in
  let idx_val = eval_node index_node ctx in
  let key = to_string_coerce idx_val in
  (match obj_val with
   | List l ->
     (match int_of_string_opt key with
      | Some idx when idx >= 0 && idx < List.length l ->
        value_of_json (List.nth l idx)
      | _ -> Null)
   | _ -> Null)

and eval_binary (op : string) (left_node : ast) (right_node : ast) (ctx : Yojson.Safe.t) : value =
  let left = eval_node left_node ctx in
  let right = eval_node right_node ctx in
  match op with
  | "==" -> Bool (strict_eq left right)
  | "!=" -> Bool (not (strict_eq left right))
  | "<" -> numeric_cmp left right ( < )
  | ">" -> numeric_cmp left right ( > )
  | "<=" -> numeric_cmp left right ( <= )
  | ">=" -> numeric_cmp left right ( >= )
  | "in" -> eval_in left right
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

and eval_unary (op : string) (operand_node : ast) (ctx : Yojson.Safe.t) : value =
  match op with
  | "not" ->
    let v = eval_node operand_node ctx in
    Bool (not (to_bool v))
  | _ -> Null

and eval_ternary (cond_node : ast) (true_node : ast) (false_node : ast) (ctx : Yojson.Safe.t) : value =
  let cond = eval_node cond_node ctx in
  if to_bool cond then eval_node true_node ctx
  else eval_node false_node ctx

and eval_logical (op : string) (left_node : ast) (right_node : ast) (ctx : Yojson.Safe.t) : value =
  let left = eval_node left_node ctx in
  match op with
  | "and" ->
    if not (to_bool left) then left
    else eval_node right_node ctx
  | "or" ->
    if to_bool left then left
    else eval_node right_node ctx
  | _ -> Null

(* ================================================================== *)
(* Public API                                                          *)
(* ================================================================== *)

let evaluate (expr_str : string) (ctx : Yojson.Safe.t) : value =
  if String.length expr_str = 0 then Null
  else
    try
      match parse (String.trim expr_str) with
      | None -> Null
      | Some ast -> eval_node ast ctx
    with _ -> Null

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
