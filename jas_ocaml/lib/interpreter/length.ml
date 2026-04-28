(* Unit-aware length parser / formatter — see length.mli for spec. *)

let supported_units = ["pt"; "px"; "in"; "mm"; "cm"; "pc"]

let pt_per_unit unit =
  match String.lowercase_ascii unit with
  | "pt" -> Some 1.0
  (* CSS reference 96 dpi: 1 px = 1/96 in, 1 pt = 1/72 in
     ⇒ 1 px = 72/96 = 0.75 pt. *)
  | "px" -> Some 0.75
  | "in" -> Some 72.0
  | "mm" -> Some (72.0 /. 25.4)
  | "cm" -> Some (720.0 /. 25.4)
  | "pc" -> Some 12.0
  | _ -> None

let is_ws c = c = ' ' || c = '\t' || c = '\n' || c = '\r'

(* String.trim — but the stdlib version is sufficient. Keep alias for
   readability at call sites. *)
let strip s = String.trim s

let parse input ~default_unit =
  let s = strip input in
  let n = String.length s in
  if n = 0 then None
  else begin
    let i = ref 0 in
    let num_start = !i in
    (* Optional leading sign. *)
    if !i < n && (s.[!i] = '-' || s.[!i] = '+') then incr i;
    let saw_digit_before_dot = ref false in
    let saw_dot = ref false in
    let saw_digit_after_dot = ref false in
    let scanning = ref true in
    while !scanning && !i < n do
      let c = s.[!i] in
      if c >= '0' && c <= '9' then begin
        if !saw_dot then saw_digit_after_dot := true
        else saw_digit_before_dot := true;
        incr i
      end else if c = '.' && not !saw_dot then begin
        saw_dot := true;
        incr i
      end else
        scanning := false
    done;
    (* Reject lone -, ., -. (no digits at all). *)
    if not !saw_digit_before_dot && not !saw_digit_after_dot then None
    else begin
      let num_str = String.sub s num_start (!i - num_start) in
      match float_of_string_opt num_str with
      | None -> None
      | Some value ->
        (* Skip whitespace between number and unit. *)
        while !i < n && is_ws s.[!i] do incr i done;
        let unit_start = !i in
        let is_alpha c =
          (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        in
        while !i < n && is_alpha s.[!i] do incr i done;
        let unit_end = !i in
        (* Trailing whitespace permitted; anything else is garbage. *)
        let rest_ws = ref true in
        while !rest_ws && !i < n do
          if is_ws s.[!i] then incr i else rest_ws := false
        done;
        if !i < n then None
        else begin
          let unit_str =
            if unit_end > unit_start then
              String.sub s unit_start (unit_end - unit_start)
            else default_unit in
          match pt_per_unit unit_str with
          | None -> None
          | Some factor -> Some (value *. factor)
        end
    end
  end

(* Trim trailing zeros and a stranded trailing decimal point from a
   formatted decimal. "12.50" -> "12.5"; "12.00" -> "12"; "12" -> "12". *)
let trim_zeros s =
  if not (String.contains s '.') then s
  else begin
    let n = String.length s in
    let i = ref (n - 1) in
    while !i > 0 && s.[!i] = '0' do decr i done;
    if s.[!i] = '.' then decr i;
    String.sub s 0 (!i + 1)
  end

let format pt ~unit ~precision =
  match pt with
  | None -> ""
  | Some pt when not (Float.is_finite pt) -> ""
  | Some pt ->
    let display_unit, factor =
      match pt_per_unit unit with
      | Some f -> String.lowercase_ascii unit, f
      | None -> "pt", 1.0 in
    let value = pt /. factor in
    (* `+. 0.0` normalises -0.0 → 0.0 before formatting. *)
    let formatted = Printf.sprintf "%.*f" precision (value +. 0.0) in
    let trimmed = trim_zeros formatted in
    let normalized = if trimmed = "-0" then "0" else trimmed in
    Printf.sprintf "%s %s" normalized display_unit
