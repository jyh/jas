(* Menu enabled/checked evaluation (TESTING_STRATEGY.md chrome seam).

   OCaml port of workspace_interpreter/menu_state.py. Pure, headless evaluation
   of every menubar item's [enabled_when] / [checked_when] predicate against a
   supplied context, producing a language-neutral per-item
   {path, action, enabled, checked} record. This is the cross-app byte-gate
   behind the menu's DYNAMIC state: all apps build the same context and evaluate
   the same bundle expressions to the same booleans, so a menu item that grays
   out (or shows a check mark) in one app does so in every app.

   Mirrors [Widget_tree]: every field is read straight from the compiled bundle
   [menubar]; the ONLY thing evaluated is each item's [enabled_when] /
   [checked_when] expression. A pre-order walk emits one record per action item;
   separators (a bare "separator" string) and submenu nodes themselves are
   skipped, but a separator still consumes its index and a submenu's CHILDREN are
   walked with an extended path. [enabled] defaults to true when there is no
   [enabled_when]; [checked] is the evaluated bool when [checked_when] is
   present, else null. *)

(* Field access over a Yojson object, returning Null for a missing key or a
   non-object node. Mirrors the [Widget_tree] helper of the same shape. *)
let mem (key : string) (n : Yojson.Safe.t) : Yojson.Safe.t =
  match n with
  | `Assoc fields ->
    (match List.assoc_opt key fields with Some v -> v | None -> `Null)
  | _ -> `Null

(* Whether an object node declares [key] at all (regardless of value type).
   Mirrors the Python ["items" in item] membership test, which gates the
   submenu-recurse branch independently of the value's shape. *)
let has_key (key : string) (n : Yojson.Safe.t) : bool =
  match n with `Assoc fields -> List.mem_assoc key fields | _ -> false

(* Evaluate [expr] against [ctx] and coerce to bool via the shared evaluator's
   truthiness ([Expr_eval.evaluate] never raises -- it returns [Null] on error,
   which [to_bool] reports as false). Mirrors the Python _eval_bool. *)
let eval_bool (expr : string) (ctx : Yojson.Safe.t) : bool =
  Expr_eval.to_bool (Expr_eval.evaluate expr ctx)

(* A present, non-empty string predicate field else None. Mirrors the Python
   truthiness of [item.get("enabled_when")] (missing -> None, "" -> falsy), so
   an empty predicate defaults rather than evaluates. *)
let opt_expr (key : string) (item : Yojson.Safe.t) : string option =
  match mem key item with `String s when s <> "" -> Some s | _ -> None

(* Walk the compiled [menubar] and evaluate each action item's [enabled_when] /
   [checked_when] against [ctx], returning a pre-order JSON array of
   {path, action, enabled, checked}. [menubar] is the bundle menubar array;
   [ctx] is the data scope (a Yojson object). *)
let menu_state (menubar : Yojson.Safe.t) (ctx : Yojson.Safe.t) : Yojson.Safe.t =
  let out = ref [] in
  let rec walk (items : Yojson.Safe.t list) (prefix : int list) : unit =
    List.iteri
      (fun i item ->
        let path = prefix @ [ i ] in
        match item with
        | `Assoc _ ->
          if has_key "items" item then
            (* submenu node: not emitted, but its children are recursed. *)
            (match mem "items" item with `List sub -> walk sub path | _ -> ())
          else begin
            (* action item: emit its evaluated state. *)
            let action =
              match mem "action" item with `String s -> s | _ -> "" in
            let enabled =
              match opt_expr "enabled_when" item with
              | Some ew -> eval_bool ew ctx
              | None -> true
            in
            let checked =
              match opt_expr "checked_when" item with
              | Some cw -> `Bool (eval_bool cw ctx)
              | None -> `Null
            in
            out :=
              `Assoc
                [ ("path", `List (List.map (fun n -> `Int n) path));
                  ("action", `String action);
                  ("enabled", `Bool enabled);
                  ("checked", checked) ]
              :: !out
          end
        | _ -> () (* bare "separator": consumes an index, emits nothing. *))
      items
  in
  (match menubar with
   | `List menus ->
     List.iteri
       (fun m menu ->
         match mem "items" menu with `List items -> walk items [ m ] | _ -> ())
       menus
   | _ -> ());
  `List (List.rev !out)
