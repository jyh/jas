(** Knuth-Plass every-line line-breaking composer.

    Pure-OCaml port of [jas_dioxus/src/algorithms/knuth_plass.rs]
    and [JasSwift/Sources/Algorithms/KnuthPlass.swift]. Phase 10. *)

(** One item in the paragraph stream. KP models text as alternating
    boxes (immutable glyph clusters), glue (stretchable / shrinkable
    inter-word space), and penalties (potential break points with
    an associated cost). *)
type item =
  | Box of { width : float; char_idx : int }
  | Glue of { width : float; stretch : float; shrink : float; char_idx : int }
  | Penalty of { width : float; value : float; flagged : bool; char_idx : int }

let item_width = function
  | Box { width; _ } -> width
  | Glue { width; _ } -> width
  | Penalty _ -> 0.0  (* contributes only on break *)

let item_char_idx = function
  | Box { char_idx; _ }
  | Glue { char_idx; _ }
  | Penalty { char_idx; _ } -> char_idx

(** Composer tuning. Defaults match Knuth's original paper. *)
type opts = {
  line_penalty : float;
  flagged_demerit : float;
  max_ratio : float;
}

let default_opts = {
  line_penalty = 10.0;
  flagged_demerit = 3000.0;
  max_ratio = 10.0;
}

(** Penalty value above which a candidate is treated as forbidden. *)
let penalty_infinity = 10000.0

(** One line's break decision. *)
type brk = {
  item_idx : int;
  ratio : float;
  flagged : bool;
}

(** Run the Knuth-Plass DP composer.

    [items] is the linear paragraph stream. [line_widths] reuses
    its last element when the paragraph wants more lines than the
    array provides. Returns [None] when no feasible composition
    exists (caller falls back to greedy first-fit).

    The returned breaks always end at the final item, which the
    caller must terminate with a forced penalty
    ([Penalty { value = -.penalty_infinity; ... }]). *)
let compose ?(opts = default_opts) (items : item array)
    (line_widths : float array) : brk list option =
  let n = Array.length items in
  if n = 0 || Array.length line_widths = 0 then Some []
  else begin
    (* Prefix sums of width / stretch / shrink for O(1) line eval. *)
    let sum_w = Array.make (n + 1) 0.0 in
    let sum_y = Array.make (n + 1) 0.0 in
    let sum_z = Array.make (n + 1) 0.0 in
    for i = 0 to n - 1 do
      sum_w.(i + 1) <- sum_w.(i) +. item_width items.(i);
      (match items.(i) with
       | Glue { stretch; shrink; _ } ->
         sum_y.(i + 1) <- sum_y.(i) +. stretch;
         sum_z.(i + 1) <- sum_z.(i) +. shrink
       | _ ->
         sum_y.(i + 1) <- sum_y.(i);
         sum_z.(i + 1) <- sum_z.(i))
    done;

    (* DP node: a candidate "we broke at this item" record. *)
    let nodes : (int * int * float * float * bool * int option) array ref =
      ref [|
        (* item_idx, line, total_demerits, ratio, flagged, prev *)
        (0, 0, 0.0, 0.0, false, None)
      |] in

    let nat_width from to_ =
      let w = ref (sum_w.(to_ + 1) -. sum_w.(from)) in
      let y = ref (sum_y.(to_ + 1) -. sum_y.(from)) in
      let z = ref (sum_z.(to_ + 1) -. sum_z.(from)) in
      (match items.(to_) with
       | Glue { width; stretch; shrink; _ } ->
         w := !w -. width; y := !y -. stretch; z := !z -. shrink
       | Penalty { width; _ } ->
         w := !w +. width
       | Box _ -> ());
      (!w, !y, !z)
    in

    let line_width_for line =
      let lw = Array.length line_widths in
      if line < lw then line_widths.(line)
      else line_widths.(lw - 1)
    in

    for j = 0 to n - 1 do
      let legal =
        match items.(j) with
        | Glue _ ->
          j > 0 && (match items.(j - 1) with Box _ -> true | _ -> false)
        | Penalty { value; _ } -> value < penalty_infinity
        | Box _ -> false
      in
      if legal then begin
        let best : (int * float * float) option ref = ref None in
        let cur_nodes = !nodes in
        Array.iteri (fun ni (item_idx, line, total_d, _r, flagged, prev) ->
          let from =
            if prev = None && ni = 0 then 0 else item_idx + 1 in
          if from <= j then begin
            let (nat, stretch, shrink) = nat_width from j in
            let line_w = line_width_for line in
            let ratio =
              if Float.abs (nat -. line_w) < 1e-9 then 0.0
              else if nat < line_w then
                if stretch > 0.0 then (line_w -. nat) /. stretch
                else infinity
              else
                if shrink > 0.0 then (line_w -. nat) /. shrink
                else neg_infinity
            in
            if ratio >= -1.0 && ratio <= opts.max_ratio then begin
              let badness = 100.0 *. (Float.abs ratio) ** 3.0 in
              let (pen_value, pen_flagged) = match items.(j) with
                | Penalty { value; flagged; _ } -> (value, flagged)
                | _ -> (0.0, false)
              in
              let line_demerit =
                if pen_value >= 0.0 then
                  (opts.line_penalty +. badness +. pen_value) ** 2.0
                else if pen_value > -. penalty_infinity then
                  (opts.line_penalty +. badness) ** 2.0 -. pen_value ** 2.0
                else
                  (opts.line_penalty +. badness) ** 2.0
              in
              let demerits =
                let base = total_d +. line_demerit in
                if flagged && pen_flagged
                then base +. opts.flagged_demerit
                else base
              in
              (match !best with
               | None -> best := Some (ni, demerits, ratio)
               | Some (_, d_best, _) when demerits < d_best ->
                 best := Some (ni, demerits, ratio)
               | _ -> ())
            end
          end
        ) cur_nodes;
        (match !best with
         | Some (prev, d, r) ->
           let (_, prev_line, _, _, _, _) = cur_nodes.(prev) in
           let pen_flagged =
             match items.(j) with
             | Penalty { flagged; _ } -> flagged
             | _ -> false
           in
           let new_node = (j, prev_line + 1, d, r, pen_flagged, Some prev) in
           nodes := Array.append cur_nodes [| new_node |]
         | None -> ())
      end
    done;

    (* Find lowest-demerit node ending at item n-1. *)
    let best = ref None in
    let best_d = ref infinity in
    Array.iteri (fun ni (item_idx, _, total_d, _, _, _) ->
      if item_idx = n - 1 && total_d < !best_d then begin
        best_d := total_d;
        best := Some ni
      end
    ) !nodes;

    match !best with
    | None -> None
    | Some start ->
      let out = ref [] in
      let cur = ref start in
      let stop = ref false in
      while not !stop do
        let (item_idx, _, _, ratio, flagged, prev) = (!nodes).(!cur) in
        if prev = None && !cur = 0 then stop := true
        else begin
          out := { item_idx; ratio; flagged } :: !out;
          (match prev with
           | Some p -> cur := p
           | None -> stop := true)
        end
      done;
      Some !out  (* already in correct order: head=first break *)
  end
