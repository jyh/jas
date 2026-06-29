(* Shared canonical panel widget-TREE snapshot pass (TESTING_STRATEGY.md section 4).

   OCaml port of workspace_interpreter/widget_tree.py, the structural sibling of
   [Panel_layout.layout_panel]. Where the layout pass computes per-widget rects,
   this pass emits a per-widget STRUCTURAL record, byte-identical across all
   native apps, so the panel widget tree itself -- its shape, its kinds, and
   which widgets dispatch versus fall to a placeholder -- becomes a cross-app
   byte-gate instead of several framework renderings eyeballed side by side.

   Determinism, the same contract as [Panel_layout]: every field is read straight
   from the compiled bundle; the ONLY expression evaluated is a foreach source
   (to learn how many expansions), the exact same evaluation [Panel_layout]
   foreach already performs and the panel_layout corpus already pins, so no new
   cross-language eval surface is introduced. The [bind] and [style] records carry
   the SORTED KEY SETS, not the expressions or the values, so the snapshot
   captures structure without depending on per-value formatting.

   Output is a pre-order list of records; [path] is the node tree path relative to
   the panel content root (root = empty, its i-th declared child appends i, a
   foreach i-th expansion appends i) -- the same path scheme as [Panel_layout]
   except that statically-hidden children are kept and recorded. *)

(* Canonical widget-kind vocabulary: the union of kinds rendered by at least one
   app panel or dialog dispatch. The Python copy is the single source of truth
   (the widget-kind coverage gate imports it); this baked copy is kept in sync by
   the panel_widget_tree.json golden -- a drifted copy flips a [kind] from its
   [type] to placeholder (or back) and reddens the cross-app gate. *)
let canonical_widget_kinds =
  [ "container"; "row"; "col"; "grid";
    "text"; "button"; "icon"; "icon_button"; "icon_select";
    "slider"; "number_input"; "text_input"; "length_input";
    "toggle"; "checkbox"; "select"; "combo_box"; "dropdown";
    "color_swatch"; "color_gradient"; "color_hue_bar"; "color_bar";
    "radio_group"; "radio"; "gradient_tile"; "gradient_slider";
    "separator"; "spacer"; "disclosure"; "panel";
    "fill_stroke_widget"; "tree_view"; "element_preview"; "tabs";
    "icon_button_group"; "reference_point_widget";
    "placeholder" ]

(* Field access over a Yojson object, returning Null for a missing key or a
   non-object node. Mirrors the [Panel_layout] helper of the same shape. *)
let mem (key : string) (n : Yojson.Safe.t) : Yojson.Safe.t =
  match n with
  | `Assoc fields ->
    (match List.assoc_opt key fields with Some v -> v | None -> `Null)
  | _ -> `Null

(* The lexicographically sorted key set of an object node as a JSON array of
   string keys; a non-object node yields the empty array. Mirrors the Python
   sorted(d.keys()) used for [bind] and [style]. *)
let sorted_keys (n : Yojson.Safe.t) : Yojson.Safe.t =
  match n with
  | `Assoc fields ->
    `List (List.map (fun k -> `String k) (List.sort compare (List.map fst fields)))
  | _ -> `List []

(* The structural record for one widget node (no recursion). Mirrors the Python
   _record: [type] / [id] are the string fields or empty; [kind] is [type] when
   it is in the canonical vocabulary else placeholder; [col] is the int of a
   numeric [col] field else 0; [visible] is false only when the literal field is
   exactly Bool false; [dyn_visible] flags a dynamic visibility (a string visible
   expression OR a bind.visible). *)
let record (node : Yojson.Safe.t) (path : int list) : Yojson.Safe.t =
  let t = match mem "type" node with `String s -> s | _ -> "" in
  let nid = match mem "id" node with `String s -> s | _ -> "" in
  let kind = if List.mem t canonical_widget_kinds then t else "placeholder" in
  let col =
    match mem "col" node with
    | `Int i -> i
    | `Float f -> int_of_float f
    | _ -> 0
  in
  let v = mem "visible" node in
  let visible = match v with `Bool false -> false | _ -> true in
  let bind = mem "bind" node in
  let style = mem "style" node in
  let dyn_visible =
    (match v with `String _ -> true | _ -> false)
    || (match bind with
        | `Assoc fields -> List.mem_assoc "visible" fields
        | _ -> false)
  in
  `Assoc
    [ ("path", `List (List.map (fun i -> `Int i) path));
      ("type", `String t);
      ("id", `String nid);
      ("kind", `String kind);
      ("col", `Int col);
      ("visible", `Bool visible);
      ("dyn_visible", `Bool dyn_visible);
      ("bind", sorted_keys bind);
      ("style", sorted_keys style) ]

(* Walk a node into [out] (reverse-accumulated): record it, then recurse. A
   foreach container expands its [do] template once per item of
   [Expr_eval.evaluate foreach.source ctx] -- the same evaluation [Panel_layout]
   foreach performs, so the expansion count (and thus the path set) matches the
   rects. Each item is bound as [foreach.as] (plus [_index]) in a child scope. A
   plain container recurses its declared children; unlike the layout pass every
   object child is kept and recorded (so a wrongly-hidden widget is catchable),
   and non-object entries occupy their index but emit nothing. *)
let rec walk (node : Yojson.Safe.t) (path : int list) (ctx : Yojson.Safe.t)
    (out : Yojson.Safe.t list ref) : unit =
  out := record node path :: !out;
  match (mem "foreach" node, mem "do" node) with
  | (`Assoc _, `Null) -> walk_children node path ctx out
  | ((`Assoc _ as spec), template) ->
    let src = match mem "source" spec with `String s -> s | _ -> "" in
    let var = match mem "as" spec with `String s -> s | _ -> "item" in
    let items =
      match Expr_eval.evaluate src ctx with
      | Expr_eval.List l -> l
      | _ -> []
    in
    List.iteri (fun i item ->
      let item_data =
        match item with
        | `Assoc fs ->
          `Assoc (List.remove_assoc "_index" fs @ [ ("_index", `Int i) ])
        | other -> `Assoc [ ("_value", other); ("_index", `Int i) ]
      in
      let child_ctx =
        match ctx with
        | `Assoc fields -> `Assoc (List.remove_assoc var fields @ [ (var, item_data) ])
        | _ -> `Assoc [ (var, item_data) ]
      in
      match template with
      | `Assoc _ -> walk template (path @ [ i ]) child_ctx out
      | _ -> ())
      items
  | _ -> walk_children node path ctx out

and walk_children (node : Yojson.Safe.t) (path : int list) (ctx : Yojson.Safe.t)
    (out : Yojson.Safe.t list ref) : unit =
  match mem "children" node with
  | `List cs ->
    List.iteri (fun i child ->
      match child with
      | `Assoc _ -> walk child (path @ [ i ]) ctx out
      | _ -> ())
      cs
  | _ -> ()

(* Walk a compiled panel node ({"type":"panel","content":<root>}) into a
   pre-order JSON array of structural records, panel-relative. [ctx] is the data
   scope used only to evaluate foreach sources (an empty object expands nothing).
   A panel with no object content yields the empty array. *)
let widget_tree (panel_node : Yojson.Safe.t) (ctx : Yojson.Safe.t) : Yojson.Safe.t =
  match mem "content" panel_node with
  | `Assoc _ as root ->
    let out = ref [] in
    walk root [] ctx out;
    `List (List.rev !out)
  | _ -> `List []
