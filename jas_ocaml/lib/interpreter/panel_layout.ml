(* Shared canonical panel widget-layout pass (Path B).

   OCaml port of jas_dioxus/src/interpreter/panel_layout.rs and
   jas/panels/panel_layout.py. A pure, integer-arithmetic layout of a compiled
   panel node into widget rects, byte-identical across all five apps. The full
   contract is PATH_B_DESIGN.md Appendix A.

   All arithmetic is integer (no float anywhere), so the native implementations
   are byte-identical and the corpus (test_fixtures/algorithms/panel_layout.json)
   needs no tolerance. Text widths use the deterministic stub measure
   (number of Unicode code points) times CHAR_WIDTH (= 10) and columns use the
   Bootstrap-12 rule cell_w = (2*inner_w*N + 12) / 24 (round-half-up, exact). *)

let char_width = 10

let disclosure_header_h = 24 (* canonical disclosure header bar height *)

let container_types = [ "container"; "row"; "col"; "panel" ]

(* A measured item with coordinates relative to its node origin. Each item also
   carries the source [node] it was produced from and the data scope [ctx] that
   node must be rendered with. For a container the root item carries the
   container node + the incoming scope; for a leaf the single item carries the
   leaf node + scope; foreach expansions carry their per-row child scope. The
   byte-gated [layout_panel] projection ignores [node] / [ctx] (rects only); the
   render-side [render_plan] projection reads them. *)
type mitem = {
  path : int list;
  mutable x : int;
  mutable y : int;
  mutable w : int;
  mutable h : int;
  node : Yojson.Safe.t;
  ctx : Yojson.Safe.t;
}

(* Field access over a Yojson object, returning Null for a missing key or a
   non-object node. *)
let mem (key : string) (n : Yojson.Safe.t) : Yojson.Safe.t =
  match n with
  | `Assoc fields -> (match List.assoc_opt key fields with Some v -> v | None -> `Null)
  | _ -> `Null

(* Numeric coercion mirroring the Rust as_i64().or(as_f64 as i64): only numeric
   nodes coerce; floats truncate toward zero. *)
let to_int_opt (v : Yojson.Safe.t) : int option =
  match v with
  | `Int i -> Some i
  | `Intlit s -> (try Some (int_of_string s) with _ -> None)
  | `Float f -> Some (int_of_float f)
  | _ -> None

let to_str_opt (v : Yojson.Safe.t) : string option =
  match v with `String s -> Some s | _ -> None

let node_type (n : Yojson.Safe.t) : string =
  match mem "type" n with `String s -> s | _ -> ""

let style (n : Yojson.Safe.t) : Yojson.Safe.t = mem "style" n

let style_i (n : Yojson.Safe.t) (key : string) : int option =
  to_int_opt (mem key (style n))

let is_container (n : Yojson.Safe.t) : bool =
  List.mem (node_type n) container_types

let has_col (n : Yojson.Safe.t) : bool =
  match mem "col" n with `Null -> false | _ -> true

let resolved_layout (n : Yojson.Safe.t) : string =
  match to_str_opt (mem "layout" n) with
  | Some "row" -> "row"
  | Some "column" -> "column"
  | _ -> if node_type n = "row" then "row" else "column"

(* Count Unicode code points in a UTF-8 string (continuation bytes have their
   top two bits set to 10, so every non-continuation byte starts a code point). *)
let utf8_length (s : string) : int =
  let n = ref 0 in
  String.iter (fun c -> if Char.code c land 0xC0 <> 0x80 then incr n) s;
  !n

(* Resolved text width: evaluate the text binding against the data scope [ctx]
   (a literal with no {{...}} passes through unchanged) then measure its length
   in Unicode code points times CHAR_WIDTH. Mirrors the Python _text_w. *)
let text_w (raw : string) (ctx : Yojson.Safe.t) : int =
  let resolved = Expr_eval.evaluate_text raw ctx in
  utf8_length resolved * char_width

let is_fill (kind : string) : bool =
  match kind with
  | "select" | "number_input" | "text_input" | "length_input" | "slider"
  | "placeholder" | "separator" | "combo_box" | "icon_select" | "spacer"
  (* composite / data-driven widgets: placed as a fixed box (fill width) *)
  | "color_bar" | "fill_stroke_widget" | "gradient_slider" | "gradient_tile"
  | "dropdown" | "tree_view" -> true
  | _ -> false

let kind_height (kind : string) : int =
  match kind with
  | "text" -> 20
  | "button" -> 24
  | "checkbox" -> 20
  | "icon_button" -> 24
  | "icon" -> 20
  | "select" -> 20
  | "number_input" -> 20
  | "text_input" -> 20
  | "length_input" -> 20
  | "slider" -> 12
  | "placeholder" -> 40
  | "separator" -> 1
  | "combo_box" -> 20
  | "icon_select" -> 20
  | "spacer" -> 0
  | "color_swatch" -> 16
  | "toggle" -> 20
  (* composite box heights (provisional) *)
  | "color_bar" -> 24
  | "fill_stroke_widget" -> 44
  | "gradient_slider" -> 24
  | "gradient_tile" -> 24
  | "dropdown" -> 20
  | "tree_view" -> 200
  | _ -> 20

let kind_fallback_w (kind : string) : int =
  match kind with
  | "select" -> 80
  | "number_input" -> 45
  | "text_input" -> 80
  | "length_input" -> 80
  | "slider" -> 100
  | "placeholder" -> 60
  | "combo_box" -> 80
  | "icon_select" -> 80
  | "spacer" -> 0
  | "fill_stroke_widget" -> 50
  | "gradient_tile" -> 32
  | "dropdown" -> 80
  | _ -> 0

(* Resolve a style dimension to integer px, or None to ignore. Numbers truncate
   toward zero; "N%" is (avail*N)/100 (ignored when avail <= 0, e.g. heights,
   which have no reference); a bare numeric string is that int; anything else
   (auto, junk) is ignored. *)
let resolve_dim (v : Yojson.Safe.t) (avail : int) : int option =
  match v with
  | `Null -> None
  | `Int i -> Some i
  | `Float f -> Some (int_of_float f)
  | `Intlit s -> (try Some (int_of_string s) with _ -> None)
  | `String raw ->
    let s = String.trim raw in
    let len = String.length s in
    if len > 0 && s.[len - 1] = '%' then begin
      let num = String.trim (String.sub s 0 (len - 1)) in
      let p_opt =
        try Some (int_of_string num)
        with _ -> (try Some (int_of_float (float_of_string num)) with _ -> None)
      in
      match p_opt with
      | Some p -> if avail > 0 then Some (avail * p / 100) else None
      | None -> None
    end else begin
      try Some (int_of_string s)
      with _ -> (try Some (int_of_float (float_of_string s)) with _ -> None)
    end
  | _ -> None

(* CSS 1/2/4-value shorthand to (top, right, bottom, left), ints. *)
let parse_padding (v : Yojson.Safe.t) : int * int * int * int =
  match v with
  | `Null -> (0, 0, 0, 0)
  | `Int n -> (n, n, n, n)
  | `Intlit s -> (let n = int_of_string s in (n, n, n, n))
  | `Float f -> (let n = int_of_float f in (n, n, n, n))
  | _ ->
    let parts =
      match v with
      | `String s ->
        Str.split (Str.regexp "[ \t\n\r]+") s |> List.filter_map (fun p ->
          try Some (int_of_string p) with _ -> None)
      | `List a -> List.filter_map to_int_opt a
      | _ -> []
    in
    (match parts with
     | [ n ] -> (n, n, n, n)
     | [ vv; hh ] -> (vv, hh, vv, hh)
     | a :: b :: c :: d :: _ -> (a, b, c, d)
     | _ -> (0, 0, 0, 0))

(* Visible children as (index, node) pairs: only object nodes, excluding any
   whose visible field is exactly false. *)
let visible_children (n : Yojson.Safe.t) : (int * Yojson.Safe.t) list =
  match mem "children" n with
  | `List ch ->
    List.mapi (fun i c -> (i, c)) ch
    |> List.filter (fun (_, c) ->
      match c with
      | `Assoc _ -> (match mem "visible" c with `Bool false -> false | _ -> true)
      | _ -> false)
  | _ -> []

(* Mirror Python int(c.get("col") or 1): 0 and null both become 1. *)
let col_span (n : Yojson.Safe.t) : int =
  let raw = match to_int_opt (mem "col" n) with Some i -> i | None -> 0 in
  if raw <> 0 then raw else 1

(* Flex weight: style.flex (int), with a spacer with no explicit flex getting
   an implicit weight of 1. Mirrors the Python _flex. *)
let flex (n : Yojson.Safe.t) : int =
  let w = match style_i n "flex" with Some f -> f | None -> 0 in
  if w = 0 && node_type n = "spacer" then 1 else w

(* Return (w, h, fill) for a leaf widget. Text bindings (content / label) are
   resolved against the data scope [ctx] before measuring. *)
let leaf_size (n : Yojson.Safe.t) (avail_w : int) (ctx : Yojson.Safe.t)
  : int * int * bool =
  let t = node_type n in
  let st = style n in
  let h =
    match resolve_dim (mem "height" st) 0 with Some v -> v | None -> kind_height t
  in
  let fill = is_fill t in
  let w =
    if fill then (if avail_w > 0 then avail_w else kind_fallback_w t)
    else
      match t with
      | "text" -> text_w (match to_str_opt (mem "content" n) with Some s -> s | None -> "") ctx
      | "button" -> text_w (match to_str_opt (mem "label" n) with Some s -> s | None -> "") ctx + 16
      | "checkbox" | "toggle" -> 16 + 4 + text_w (match to_str_opt (mem "label" n) with Some s -> s | None -> "") ctx
      | "color_swatch" -> 16
      | "icon_button" -> 24
      | "icon" -> 20
      | _ -> 0
  in
  let w = match resolve_dim (mem "width" st) avail_w with Some x -> x | None -> w in
  let w = match resolve_dim (mem "min_width" st) avail_w with Some m -> max w m | None -> w in
  (w, h, fill)

(* Group (index, node) children into Bootstrap-12 lines by their col span. Each
   line is a list of (index, node, span) whose spans sum to at most 12. Mirrors
   the Python _grid_lines (the same wrapping the grid layout itself performs). *)
let grid_lines (children : (int * Yojson.Safe.t) list)
  : (int * Yojson.Safe.t * int) list list =
  let lines = ref [] in
  let cur = ref [] in
  let cur_span = ref 0 in
  List.iter (fun (i, c) ->
    let span = col_span c in
    if !cur <> [] && !cur_span + span > 12 then begin
      lines := !lines @ [ List.rev !cur ];
      cur := [];
      cur_span := 0
    end;
    cur := (i, c, span) :: !cur;
    cur_span := !cur_span + span)
    children;
  if !cur <> [] then lines := !lines @ [ List.rev !cur ];
  !lines

(* Min-content width a node wants, ignoring the width available to it. A leaf
   reports its own intrinsic width (measured with the unbounded sentinel so fill
   widgets fall back to their default width); a container reports the width its
   content needs: a row sums children plus gaps, a column takes the widest child,
   a grid takes the widest 12-col line, a foreach reports its do template, and a
   disclosure takes the widest child. Used so a row can grow cells / columns to
   fit nested content and shrink-to-fit deterministically when over-subscribed,
   instead of letting a wide label or input overrun its neighbour. Mirrors the
   Python _natural_w. *)
let rec natural_w (n : Yojson.Safe.t) (ctx : Yojson.Safe.t) : int =
  if not (is_container n || node_type n = "disclosure") then
    let w, _h, _fill = leaf_size n (-1) ctx in
    w
  else begin
    let st = style n in
    let _pt, pr, _pb, pl = parse_padding (mem "padding" st) in
    let gap = match style_i n "gap" with Some g -> g | None -> 0 in
    if node_type n = "disclosure" then begin
      let kids = visible_children n in
      let inner =
        List.fold_left (fun acc (_, c) -> max acc (natural_w c ctx)) 0 kids
      in
      inner + pl + pr
    end
    else
      match (mem "foreach" n, mem "do" n) with
      | (`Assoc _, (`Assoc _ as template)) -> natural_w template ctx + pl + pr
      | _ ->
        let kids = visible_children n in
        let lay = resolved_layout n in
        if lay = "row" && List.exists (fun (_, c) -> has_col c) kids then begin
          let best = ref 0 in
          List.iter (fun line ->
            let m = List.length line in
            let line_w =
              List.fold_left
                (fun acc (_, c, _span) -> acc + natural_w c ctx) 0 line
              + (if m > 0 then gap * (m - 1) else 0)
            in
            if line_w > !best then best := line_w)
            (grid_lines kids);
          !best + pl + pr
        end
        else if lay = "row" then begin
          let n_kids = List.length kids in
          let tot =
            List.fold_left (fun acc (_, c) -> acc + natural_w c ctx) 0 kids
            + (if n_kids > 0 then gap * (n_kids - 1) else 0)
          in
          tot + pl + pr
        end
        else begin
          let inner =
            List.fold_left (fun acc (_, c) -> max acc (natural_w c ctx)) 0 kids
          in
          inner + pl + pr
        end
  end

(* Returns (w, h, items) with item coords RELATIVE to this node origin.
   [avail_h] drives vertical flex for columns (0 = content height, no flex).
   [ctx] is the data scope used to evaluate foreach sources + text bindings. *)
let rec measure (n : Yojson.Safe.t) (path : int list) (avail_w : int)
  (avail_h : int) (ctx : Yojson.Safe.t) : int * int * mitem list =
  let st = style n in
  let pt, pr, pb, pl = parse_padding (mem "padding" st) in
  let gap = match style_i n "gap" with Some g -> g | None -> 0 in
  let inner_w = avail_w - pl - pr in
  let inner_h = if avail_h > 0 then avail_h - pt - pb else 0 in
  if is_container n || node_type n = "disclosure" then begin
    let ch_items, content_h =
      if node_type n = "disclosure" then disclosure n path inner_w gap ctx
      else
      match (mem "foreach" n, mem "do" n) with
      | (`Assoc _, `Assoc _) -> foreach n path inner_w gap ctx
      | _ ->
        let children = visible_children n in
        let lay = resolved_layout n in
        if lay = "row" && List.exists (fun (_, c) -> has_col c) children then
          grid children path inner_w gap ctx
        else if lay = "row" then
          flow children path inner_w gap ctx
        else
          column children path inner_w gap inner_h ctx
    in
    (* Fill the width given; with no constraint (avail_w <= 0) report the
       container natural content width so a parent row can size it. *)
    let w = if avail_w > 0 then avail_w else natural_w n ctx in
    (* An explicit style.height overrides the content-derived height. *)
    let h =
      match resolve_dim (mem "height" st) 0 with
      | Some v -> v
      | None -> content_h + pt + pb
    in
    let root = { path; x = 0; y = 0; w; h; node = n; ctx } in
    List.iter (fun it -> it.x <- it.x + pl; it.y <- it.y + pt) ch_items;
    (w, h, root :: ch_items)
  end else begin
    let w, h, _fill = leaf_size n avail_w ctx in
    (* A leaf renders at its own width regardless of its slot; clamp it to the
       width available so it cannot overrun a neighbour (text labels may clip). *)
    let w = if avail_w > 0 && w > avail_w then avail_w else w in
    (w, h, [ { path; x = 0; y = 0; w; h; node = n; ctx } ])
  end

and column children path inner_w gap avail_h ctx : mitem list * int =
  let measured =
    Array.of_list
      (List.map (fun (i, c) ->
         let _cw, ch, cit = measure c (path @ [ i ]) inner_w 0 ctx in
         (c, ch, cit))
         children)
  in
  let n = Array.length measured in
  let natural =
    Array.fold_left (fun acc (_, ch, _) -> acc + ch) 0 measured
    + (if n > 0 then gap * (n - 1) else 0)
  in
  let extra = Array.make n 0 in
  (* Vertical flex: distribute the leftover dock height to flex-weighted
     children (integer floor, remainder to the earliest flex children). *)
  if avail_h > 0 then begin
    let leftover = avail_h - natural in
    if leftover > 0 then begin
      let weights = Array.map (fun (c, _, _) -> flex c) measured in
      let sumw = Array.fold_left ( + ) 0 weights in
      if sumw > 0 then begin
        for k = 0 to n - 1 do
          extra.(k) <- leftover * weights.(k) / sumw
        done;
        let used = Array.fold_left ( + ) 0 extra in
        let rem = ref (leftover - used) in
        (try
           for k = 0 to n - 1 do
             if !rem <= 0 then raise Exit;
             if weights.(k) > 0 then begin
               extra.(k) <- extra.(k) + 1;
               decr rem
             end
           done
         with Exit -> ())
      end
    end
  end;
  let items = ref [] in
  let cy = ref 0 in
  Array.iteri (fun k (_c, ch, cit) ->
    let hk = ch + extra.(k) in
    List.iter (fun it -> it.y <- it.y + !cy) cit;
    (if extra.(k) <> 0 then
       match cit with first :: _ -> first.h <- hk | [] -> ());
    items := !items @ cit;
    cy := !cy + hk + gap)
    measured;
  (!items, if n > 0 then !cy - gap else 0)

and flow children path inner_w gap ctx : mitem list * int =
  let children_arr = Array.of_list children in
  let n = Array.length children_arr in
  (* Each child wants its min-content (natural) width. *)
  let nat = Array.map (fun (_i, c) -> natural_w c ctx) children_arr in
  let weights = Array.map (fun (_i, c) -> flex c) children_arr in
  let sumw = Array.fold_left ( + ) 0 weights in
  let fixed =
    Array.fold_left ( + ) 0 nat + (if n > 0 then gap * (n - 1) else 0)
  in
  let widths = Array.copy nat in
  if inner_w > 0 && fixed > inner_w then begin
    (* Over-subscribed: shrink every cell proportionally to fit the row, then
       hand out the rounding remainder one pixel at a time (deterministic). *)
    let avail = inner_w - (if n > 0 then gap * (n - 1) else 0) in
    let total = Array.fold_left ( + ) 0 nat in
    if total > 0 && avail > 0 then begin
      for k = 0 to n - 1 do
        widths.(k) <- nat.(k) * avail / total
      done;
      let used = Array.fold_left ( + ) 0 widths in
      let rem = ref (avail - used) in
      let k = ref 0 in
      while !rem > 0 && n > 0 do
        widths.(!k) <- widths.(!k) + 1;
        decr rem;
        k := (!k + 1) mod n
      done
    end
  end
  else if inner_w > 0 && sumw > 0 then begin
    (* Fits: distribute the leftover width to flex-weighted children. *)
    let leftover = inner_w - fixed in
    if leftover > 0 then begin
      let base = Array.make n 0 in
      for k = 0 to n - 1 do
        base.(k) <- leftover * weights.(k) / sumw
      done;
      let used = Array.fold_left ( + ) 0 base in
      let rem = ref (leftover - used) in
      (try
         for k = 0 to n - 1 do
           if !rem <= 0 then raise Exit;
           if weights.(k) > 0 then begin
             base.(k) <- base.(k) + 1;
             decr rem
           end
         done
       with Exit -> ());
      for k = 0 to n - 1 do
        widths.(k) <- nat.(k) + base.(k)
      done
    end
  end;
  (* Lay each child out at its final width; a leaf already clamps itself to the
     width it is given (see measure), so nothing overruns the next cell. *)
  let placed = Array.make n ([], 0) in
  let row_h = ref 0 in
  Array.iteri (fun k (i, c) ->
    let _cw, ch, cit = measure c (path @ [ i ]) widths.(k) 0 ctx in
    (match cit with
     | first :: _ -> if first.w > widths.(k) then first.w <- widths.(k)
     | [] -> ());
    placed.(k) <- (cit, ch);
    if ch > !row_h then row_h := ch)
    children_arr;
  let items = ref [] in
  let cx = ref 0 in
  Array.iteri (fun k (cit, ch) ->
    let dy = (!row_h - ch) / 2 in
    List.iter (fun it -> it.x <- it.x + !cx; it.y <- it.y + dy) cit;
    items := !items @ cit;
    cx := !cx + widths.(k) + gap)
    placed;
  (!items, !row_h)

and grid children path inner_w gap ctx : mitem list * int =
  (* Wrap into lines so each line column span sums to at most 12. *)
  let lines = grid_lines children in
  let items = ref [] in
  let line_y = ref 0 in
  List.iter (fun line ->
    let line_arr = Array.of_list line in
    let n = Array.length line_arr in
    (* Each cell wants at least its Bootstrap-12 share, grown to fit its content
       intrinsic width: a leaf renders at its own width regardless of how narrow
       its column is, so a wide label / icon must not overrun its neighbour.
       Layout containers fill their cell, so they contribute no intrinsic minimum
       (they shrink / grow with the cell). *)
    let desired =
      Array.map (fun (_i, c, span) ->
        let bw = (2 * inner_w * span + 12) / 24 in
        max bw (natural_w c ctx))
        line_arr
    in
    let avail = inner_w - gap * (n - 1) in
    let total = Array.fold_left ( + ) 0 desired in
    let widths =
      if total <= avail || total <= 0 then desired
      else begin
        (* Over-subscribed row: shrink cells proportionally to fit, then hand the
           rounding remainder out one pixel at a time (deterministic so every app
           produces byte-identical rects). *)
        let w = Array.make n 0 in
        for k = 0 to n - 1 do
          w.(k) <- desired.(k) * avail / total
        done;
        let used = Array.fold_left ( + ) 0 w in
        let rem = ref (avail - used) in
        let k = ref 0 in
        while !rem > 0 do
          w.(!k) <- w.(!k) + 1;
          decr rem;
          k := (!k + 1) mod n
        done;
        w
      end
    in
    let cx = ref 0 in
    let line_h = ref 0 in
    let cells = ref [] in
    Array.iteri (fun idx (i, c, _span) ->
      let cell_w = widths.(idx) in
      let _cw, ch, cit = measure c (path @ [ i ]) cell_w 0 ctx in
      (* Clamp the child to its cell so it cannot overrun the next column. *)
      (match cit with
       | first :: _ -> if first.w > cell_w then first.w <- cell_w
       | [] -> ());
      cells := !cells @ [ (cit, ch, !cx) ];
      if ch > !line_h then line_h := ch;
      cx := !cx + cell_w + gap)
      line_arr;
    List.iter (fun (cit, ch, cell_x) ->
      let dy = (!line_h - ch) / 2 in
      List.iter (fun it -> it.x <- it.x + cell_x; it.y <- it.y + !line_y + dy) cit;
      items := !items @ cit)
      !cells;
    line_y := !line_y + !line_h + gap)
    lines;
  (!items, if lines <> [] then !line_y - gap else 0)

(* A disclosure is a header bar (the bound label) plus a body. The body is its
   children laid out as a column below a fixed-height header (assumed expanded);
   the header is drawn by the widget itself, so no separate rect is emitted. The
   body inner foreach (swatch / brush grids) expands through the normal
   recursion. content_h = header_h + body_column_height. *)
and disclosure n path inner_w gap ctx : mitem list * int =
  let children = visible_children n in
  let ch_items, body_h = column children path inner_w gap 0 ctx in
  List.iter (fun it -> it.y <- it.y + disclosure_header_h) ch_items;
  (ch_items, disclosure_header_h + body_h)

(* Expand a foreach container's [do] template once per item of
   evaluate(foreach.source, ctx), laid out per the container [layout] field:
   [column] (vertical stack, default), [row] (horizontal single line), or
   [wrap] (horizontal, wrapping at inner_w). Each item is bound as [foreach.as]
   (plus [_index]) in a child scope.

   Column measures each expansion at avail = inner_w (fills, as for a normal
   column). Row and wrap measure at avail = -1 (intrinsic): for those the item
   width is the subtree extent (max over produced rects of rect.x + rect.w),
   and the item own root rect width is corrected to that extent so a container
   item carries its content width rather than the unbounded sentinel. *)
and foreach n path inner_w gap ctx : mitem list * int =
  let spec = mem "foreach" n in
  let src = match to_str_opt (mem "source" spec) with Some s -> s | None -> "" in
  let var = match to_str_opt (mem "as" spec) with Some s -> s | None -> "item" in
  let template = mem "do" n in
  let lay = match to_str_opt (mem "layout" n) with Some s -> s | None -> "column" in
  let items =
    match Expr_eval.evaluate src ctx with
    | Expr_eval.List l -> l
    | _ -> []
  in
  (* Measure every expansion (column fills inner_w; row/wrap are intrinsic). *)
  let avail = if lay = "column" then inner_w else -1 in
  let measured = ref [] in
  List.iteri (fun i item ->
    let item_data =
      match item with
      | `Assoc fs -> `Assoc (List.remove_assoc "_index" fs @ [ ("_index", `Int i) ])
      | other -> `Assoc [ ("_value", other); ("_index", `Int i) ]
    in
    let child_ctx =
      match ctx with
      | `Assoc fields -> `Assoc (List.remove_assoc var fields @ [ (var, item_data) ])
      | _ -> `Assoc [ (var, item_data) ]
    in
    let w, h, cit = measure template (path @ [ i ]) avail 0 child_ctx in
    let w =
      if lay <> "column" then begin
        (* Mirror Python max((it.x + it.w for it in cit), default=0): the 0 is
           only the empty-list default, NOT a floor, so a container tile that
           returns the -1 intrinsic sentinel keeps its negative extent. *)
        let iw =
          match cit with
          | [] -> 0
          | first :: rest ->
            List.fold_left (fun acc it -> max acc (it.x + it.w))
              (first.x + first.w) rest
        in
        (match cit with first :: _ -> first.w <- iw | [] -> ());
        iw
      end else w
    in
    measured := (w, h, cit) :: !measured)
    items;
  let measured = List.rev !measured in
  let out = ref [] in
  if lay = "row" then begin
    let row_h = List.fold_left (fun acc (_, h, _) -> max acc h) 0 measured in
    let cx = ref 0 in
    List.iter (fun (w, h, cit) ->
      let dy = (row_h - h) / 2 in
      List.iter (fun it -> it.x <- it.x + !cx; it.y <- it.y + dy) cit;
      out := !out @ cit;
      cx := !cx + w + gap)
      measured;
    (!out, row_h)
  end
  else if lay = "wrap" then begin
    let cx = ref 0 in
    let line_y = ref 0 in
    let line_h = ref 0 in
    List.iter (fun (w, h, cit) ->
      if !cx > 0 && !cx + w > inner_w then begin
        line_y := !line_y + !line_h + gap;
        cx := 0;
        line_h := 0
      end;
      List.iter (fun it -> it.x <- it.x + !cx; it.y <- it.y + !line_y) cit;
      out := !out @ cit;
      cx := !cx + w + gap;
      line_h := max !line_h h)
      measured;
    (!out, if measured <> [] then !line_y + !line_h else 0)
  end
  else begin
    (* column *)
    let cy = ref 0 in
    List.iter (fun (_w, h, cit) ->
      List.iter (fun it -> it.y <- it.y + !cy) cit;
      out := !out @ cit;
      cy := !cy + h + gap)
      measured;
    (!out, if measured <> [] then !cy - gap else 0)
  end

(* Lay out a compiled panel node ({"type":"panel","content":<root>}) into a
   JSON array of {"path":[..],"rect":{x,y,w,h}}, pre-order, panel-relative.
   [avail_h] drives vertical flex (0 = none); [ctx] is the data scope used to
   evaluate foreach sources and text bindings. *)
let layout_panel (panel_node : Yojson.Safe.t) (avail_w : int) (avail_h : int)
  (ctx : Yojson.Safe.t) : Yojson.Safe.t =
  match mem "content" panel_node with
  | `Assoc _ as root ->
    let _w, _h, items = measure root [] avail_w avail_h ctx in
    `List
      (List.map (fun it ->
         `Assoc
           [ ("path", `List (List.map (fun i -> `Int i) it.path));
             ("rect",
              `Assoc
                [ ("x", `Int it.x); ("y", `Int it.y);
                  ("w", `Int it.w); ("h", `Int it.h) ]) ])
        items)
  | _ -> `List []

(* Node types that are layout-only: they position their children but draw no
   widget of their own in the absolute render (their children are the rendered
   leaves), so they are omitted from the render plan leaves. Mirrors the Python
   _LAYOUT_CONTAINER_TYPES; note it includes grid and disclosure. *)
let layout_only_types =
  [ "container"; "row"; "col"; "grid"; "panel"; "disclosure" ]

(* Key presence test over a Yojson object, mirroring Python [key in dict]: true
   when the assoc carries [key] (regardless of its value), false for a missing
   key or a non-object node. *)
let has_key (key : string) (n : Yojson.Safe.t) : bool =
  match n with `Assoc fields -> List.mem_assoc key fields | _ -> false

(* A layout-only container still worth drawing in the absolute render because it
   carries chrome: a static [style.border] / [style.background] / [style.bg], or
   a [bind.background] (for example a selected-row highlight). Mirrors the Python
   _has_chrome. Such containers are emitted into the render plan [chrome] list so
   the swap can draw the container border / background BEHIND its leaves. *)
let has_chrome (n : Yojson.Safe.t) : bool =
  let st = style n in
  has_key "border" st || has_key "background" st || has_key "bg" st
  || has_key "background" (mem "bind" n)

(* Render-side projection of the same layout pass. Returns the JSON object
   {"height": <panel content height>, "chrome": [...], "leaves": [...]} where each
   entry is {"rect","node","ctx"}: [leaves] are renderable widgets (each carrying
   the per-row child scope, so a foreach-expanded leaf resolves against its own
   scope) and [chrome] are layout-only containers that carry a border / background
   to draw BEHIND the leaves (for example a selected-row highlight). [height] is
   the canonical panel content height (root item height). Layout-only containers
   without chrome are omitted entirely. The cross-app byte-gate consumes
   [layout_panel] (rects only) so it stays byte-exact; the render swaps consume
   this. One traversal, two projections. *)
let render_plan (panel_node : Yojson.Safe.t) (avail_w : int) (avail_h : int)
  (ctx : Yojson.Safe.t) : Yojson.Safe.t =
  match mem "content" panel_node with
  | `Assoc _ as root ->
    let _w, _h, items = measure root [] avail_w avail_h ctx in
    let height = match items with it :: _ -> it.h | [] -> 0 in
    let entry it =
      `Assoc
        [ ("rect",
           `Assoc
             [ ("x", `Int it.x); ("y", `Int it.y);
               ("w", `Int it.w); ("h", `Int it.h) ]);
          ("node", it.node);
          ("ctx", it.ctx) ]
    in
    let chrome = ref [] in
    let leaves = ref [] in
    List.iter (fun it ->
      match it.node with
      | `Assoc _ ->
        if List.mem (node_type it.node) layout_only_types then begin
          if has_chrome it.node then chrome := entry it :: !chrome
        end else
          leaves := entry it :: !leaves
      | _ -> ())
      items;
    `Assoc
      [ ("height", `Int height);
        ("chrome", `List (List.rev !chrome));
        ("leaves", `List (List.rev !leaves)) ]
  | _ -> `Assoc [ ("height", `Int 0); ("chrome", `List []); ("leaves", `List []) ]
