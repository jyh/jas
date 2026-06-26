(* Native-first routing for named workspace actions reaching the app from a
   name-driven caller (today: the test-only [--test-fifo] [action <name>]
   channel in bin/main.ml).

   WHY native-first: document-mutating menubar / edit actions ([select_all],
   [delete_selection], ...) are NATIVE-INTERCEPTED. Their actions.yaml
   [effects] are deliberate [log] / [if] STUBS — the real behavior lives in
   native OCaml code (the menubar [on_menu_action] closure and the keyboard
   delete path in bin/main.ml). So routing such a name through the GENERIC
   dispatcher ([Panel_menu.dispatch_yaml_action], which runs only an action
   YAML [effects]) logs-and-no-ops, while a real menu click / keystroke
   mutates the document. The FIFO [action] verb formerly went straight to the
   generic dispatcher and therefore silently dropped these mutations.

   This dispatcher routes the native-intercepted document mutations through
   the SAME native ops the menu / keyboard handlers use, then falls through
   to the generic dispatcher for genuine panel / generic-effect actions
   (e.g. [select_tool] panel toggles), whose real behavior IS their YAML
   effect. Mirrors the Python MainWindow._dispatch_action_by_name
   (jas/jas_app.py) for cross-app equivalence. *)

(* select_all: the SAME op the menubar Edit > Select All arm runs
   (menubar.ml [on_menu_action] [select_all] arm). Selection-only, not a
   journaled mutation (Controller#select_all writes via
   set_document_unbracketed). *)
let select_all (model : Model.model) : unit =
  (new Controller.controller ~model ())#select_all

(* delete_selection: route through the SHARED [Op_apply.op_apply] dispatcher
   exactly like the keyboard Delete path in bin/main.ml — a named transaction
   wrapping one [delete_selection] op, so the gesture journals ONE named undo
   step (the same [Document.delete_selection] body). The txn name matches the
   keyboard path ([delete_orphan_confirm_ok]) so a FIFO delete and a keyboard
   delete are byte-identical in the journal.

   Headless: the keyboard path also runs a GUI orphan-confirm BEFORE this
   mutation (a modal that needs a parent window). That confirm is a UI concern
   and is intentionally NOT replicated here — this dispatcher is a pure,
   testable, window-free seam. On a no-orphan selection the two paths are
   equivalent; an orphan-confirm gate, if ever wanted on the FIFO path, would
   wrap the call site in bin/main.ml, not this function. *)
let delete_selection (model : Model.model) : unit =
  let doc = model#document in
  if Document.PathMap.is_empty doc.Document.selection then ()
  else begin
    let ctrl = new Controller.controller ~model () in
    model#with_txn (fun () ->
      model#name_txn "delete_orphan_confirm_ok";
      Op_apply.op_apply model ctrl
        (`Assoc [ ("op", `String "delete_selection") ]))
  end

let dispatch
    ?(fallthrough :
        (params:(string * Yojson.Safe.t) list -> string -> Model.model -> unit) option)
    ?(params : (string * Yojson.Safe.t) list = [])
    (name : string) (model : Model.model) : unit =
  (* Default fall-through is the generic panel dispatcher. Injectable so a
     unit test can spy on it (mirrors the Python spy/replace of
     dock_panel._dispatch_yaml_action). *)
  let fallthrough =
    match fallthrough with
    | Some f -> f
    | None -> (fun ~params name model ->
        Panel_menu.dispatch_yaml_action ~params name model)
  in
  match name with
  | "select_all" -> select_all model
  | "delete_selection" -> delete_selection model
  | _ -> fallthrough ~params name model
