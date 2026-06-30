(* The single LAYOUT-op dispatcher [layout_apply] (OP_LOG.md section 12,
   Fork 5, Increment 3d-2). The layout analogue of the document op dispatcher.

   PROMOTED out of the cross-language test harness ([apply_workspace_op] in
   [test/cross_language_test.ml]) into this RUNTIME module so production layout
   mutations and the test harness share ONE dispatcher and ONE per-verb
   mutation body, exactly the unification 3b-B did for document ops. The
   harness shim now delegates here, and the production layout-mutation sites
   (menubar, dock panel, canvas pane handlers, per-panel hamburger menus)
   build a resolved op JSON via the [op_*] builders and call [layout_apply]
   instead of calling the [Workspace_layout]/[Pane] method directly. The
   mutation is byte-identical to the pre-3d-2 direct call (same args, now
   serialized then dispatched then parsed).

   LAYOUT STAYS NON-UNDOABLE (OP_LOG.md section 12, Option B): there is NO
   layout journal, NO layout undo, and NO checkpoint-vs-journal gate (that is
   Option C, deliberately NOT done). [layout_apply] is purely the shared
   parse then apply envelope; the per-verb [Workspace_layout] mutators already
   call [bump] internally (the dirty signal), which the production refresh
   path reads via [needs_save] to persist, unchanged. Pane-verb sites wrap the
   dispatch in [Workspace_layout.panes_mut] which bumps after the mutation.

   Production input must never panic, so every param read is hardened: numbers
   resolve with a default of 0 on missing/wrong type; a missing REQUIRED string
   (the verb name, a panel/pane [kind]) skips rather than raising; a malformed
   op skips. The harness fixtures (which always carry well-formed params) replay
   byte-identically. *)

open Workspace_layout

(* Co-located kind parse/serialize helpers. Mirrors the Rust [layout_apply.rs]
   which keeps its own copies so the producer ([op_*] builders) and the consumer
   (the dispatcher arms) cannot drift. {!Workspace_test_json} keeps its own
   identical copies for the canonical serializer; these are intentionally the
   layout-op side of the same mapping. *)

let parse_panel_kind_str s =
  match s with
  | "color" -> Color
  | "swatches" -> Swatches
  | "brushes" -> Brushes
  | "stroke" -> Stroke
  | "properties" -> Properties
  | "character" -> Character
  | "paragraph" -> Paragraph
  | "artboards" -> Artboards
  | "align" -> Align
  | "boolean" -> Boolean
  | "opacity" -> Opacity
  | "magic_wand" -> Magic_wand
  | "symbols" -> Symbols
  | _ -> Layers

let panel_kind_str = function
  | Layers -> "layers"
  | Color -> "color"
  | Swatches -> "swatches"
  | Brushes -> "brushes"
  | Stroke -> "stroke"
  | Properties -> "properties"
  | Character -> "character"
  | Paragraph -> "paragraph"
  | Artboards -> "artboards"
  | Align -> "align"
  | Boolean -> "boolean"
  | Opacity -> "opacity"
  | Magic_wand -> "magic_wand"
  | Symbols -> "symbols"

let parse_pane_kind_str s =
  match s with
  | "toolbar" -> Pane.Toolbar
  | "dock" -> Pane.Dock
  | _ -> Pane.Canvas

let pane_kind_str = function
  | Pane.Toolbar -> "toolbar"
  | Pane.Canvas -> "canvas"
  | Pane.Dock -> "dock"

(* ------------------------------------------------------------------ *)
(* Op-JSON builders (production -> dispatcher).                         *)
(*                                                                      *)
(* Production layout-mutation sites build their op via these typed       *)
(* constructors and pass the result to [layout_apply], so the JSON SHAPE *)
(* for each verb lives in exactly one place (alongside the dispatcher    *)
(* arm that reads it) and a shape drift between producer and consumer is *)
(* impossible. Each builder mirrors the field names the matching         *)
(* [layout_apply] arm reads.                                            *)
(* ------------------------------------------------------------------ *)

let op_toggle_group_collapsed (a : group_addr) : Yojson.Safe.t =
  `Assoc [ "op", `String "toggle_group_collapsed";
           "dock_id", `Int a.dock_id;
           "group_idx", `Int a.group_idx ]

let op_set_active_panel (a : panel_addr) : Yojson.Safe.t =
  `Assoc [ "op", `String "set_active_panel";
           "dock_id", `Int a.group.dock_id;
           "group_idx", `Int a.group.group_idx;
           "panel_idx", `Int a.panel_idx ]

let op_close_panel (a : panel_addr) : Yojson.Safe.t =
  `Assoc [ "op", `String "close_panel";
           "dock_id", `Int a.group.dock_id;
           "group_idx", `Int a.group.group_idx;
           "panel_idx", `Int a.panel_idx ]

let op_show_panel (k : panel_kind) : Yojson.Safe.t =
  `Assoc [ "op", `String "show_panel"; "kind", `String (panel_kind_str k) ]

let op_reorder_panel (g : group_addr) ~from ~to_ : Yojson.Safe.t =
  `Assoc [ "op", `String "reorder_panel";
           "dock_id", `Int g.dock_id;
           "group_idx", `Int g.group_idx;
           "from", `Int from;
           "to", `Int to_ ]

let op_move_panel_to_group ~(from : panel_addr) ~(to_ : group_addr) : Yojson.Safe.t =
  `Assoc [ "op", `String "move_panel_to_group";
           "from_dock_id", `Int from.group.dock_id;
           "from_group_idx", `Int from.group.group_idx;
           "from_panel_idx", `Int from.panel_idx;
           "to_dock_id", `Int to_.dock_id;
           "to_group_idx", `Int to_.group_idx ]

let op_detach_group (g : group_addr) ~x ~y : Yojson.Safe.t =
  `Assoc [ "op", `String "detach_group";
           "dock_id", `Int g.dock_id;
           "group_idx", `Int g.group_idx;
           "x", `Float x;
           "y", `Float y ]

let op_redock (id : dock_id) : Yojson.Safe.t =
  `Assoc [ "op", `String "redock"; "dock_id", `Int id ]

let op_set_pane_position (id : Pane.pane_id) ~x ~y : Yojson.Safe.t =
  `Assoc [ "op", `String "set_pane_position";
           "pane_id", `Int id;
           "x", `Float x;
           "y", `Float y ]

(* [override] is the collapsed-dock fixed-width override the menu Tile handler
   may supply; absent for the plain corpus path. OCaml [Pane.tile_panes] clears
   [canvas_maximized] internally, so unlike the Rust builder there is no
   [set_canvas_maximized] param. *)
let op_tile_panes ?override () : Yojson.Safe.t =
  let base = [ "op", `String "tile_panes" ] in
  let fields = match override with
    | Some (pid, w) ->
      base @ [ "override_pane_id", `Int pid; "override_width", `Float w ]
    | None -> base
  in
  `Assoc fields

let op_toggle_canvas_maximized () : Yojson.Safe.t =
  `Assoc [ "op", `String "toggle_canvas_maximized" ]

let op_resize_pane (id : Pane.pane_id) ~width ~height : Yojson.Safe.t =
  `Assoc [ "op", `String "resize_pane";
           "pane_id", `Int id;
           "width", `Float width;
           "height", `Float height ]

let op_hide_pane (k : Pane.pane_kind) : Yojson.Safe.t =
  `Assoc [ "op", `String "hide_pane"; "kind", `String (pane_kind_str k) ]

let op_show_pane (k : Pane.pane_kind) : Yojson.Safe.t =
  `Assoc [ "op", `String "show_pane"; "kind", `String (pane_kind_str k) ]

let op_bring_pane_to_front (id : Pane.pane_id) : Yojson.Safe.t =
  `Assoc [ "op", `String "bring_pane_to_front"; "pane_id", `Int id ]

(* ------------------------------------------------------------------ *)
(* Hardened readers: a malformed production payload never raises.       *)
(* A missing/wrong-typed numeric field reads as 0, mirroring the        *)
(* document dispatcher discipline (the harness fixtures always carry     *)
(* well-formed params, so they replay byte-identically).               *)
(* ------------------------------------------------------------------ *)

(* [Yojson.Safe.Util.member] RAISES [Type_error] when [op] is not an object,
   so look the field up by hand: a non-object envelope (or a missing key) reads
   as [`Null], which every typed reader below treats as absent. This is the
   crucial hardening for a non-object op envelope (e.g. a bare string/null). *)
let mem op key =
  match op with
  | `Assoc fields -> (try List.assoc key fields with Not_found -> `Null)
  | _ -> `Null

let str_opt op key =
  match mem op key with
  | `String s -> Some s
  | _ -> None

let i op key =
  match mem op key with
  | `Int n -> n
  | `Intlit s -> (try int_of_string s with _ -> 0)
  | `Float f -> int_of_float f
  | _ -> 0

let f op key =
  match mem op key with
  | `Float v -> v
  | `Int n -> float_of_int n
  | `Intlit s -> (try float_of_string s with _ -> 0.0)
  | _ -> 0.0

(* Apply one primitive LAYOUT op to [layout]. The SINGLE per-verb mutation body
   shared by production and the cross-language harness. Hardened: an unknown
   verb or a missing required [kind]/[op] string SKIPS (no raise, no mutation). *)
let layout_apply (layout : workspace_layout) (op : Yojson.Safe.t) : unit =
  match str_opt op "op" with
  | None -> ()  (* malformed op envelope: skip *)
  | Some name ->
    match name with
    (* ---- Panel / dock operations (mutate Workspace_layout directly; each
       verb mutator calls [bump] internally so the dirty signal is preserved) -- *)
    | "toggle_group_collapsed" ->
      toggle_group_collapsed layout
        { dock_id = i op "dock_id"; group_idx = i op "group_idx" }
    | "set_active_panel" ->
      set_active_panel layout
        { group = { dock_id = i op "dock_id"; group_idx = i op "group_idx" };
          panel_idx = i op "panel_idx" }
    | "close_panel" ->
      close_panel layout
        { group = { dock_id = i op "dock_id"; group_idx = i op "group_idx" };
          panel_idx = i op "panel_idx" }
    | "show_panel" ->
      (match str_opt op "kind" with
       | None -> ()  (* required field missing: skip *)
       | Some s -> show_panel layout (parse_panel_kind_str s))
    | "reorder_panel" ->
      reorder_panel layout
        ~group:{ dock_id = i op "dock_id"; group_idx = i op "group_idx" }
        ~from:(i op "from") ~to_:(i op "to")
    | "move_panel_to_group" ->
      move_panel_to_group layout
        ~from:{ group = { dock_id = i op "from_dock_id";
                          group_idx = i op "from_group_idx" };
                panel_idx = i op "from_panel_idx" }
        ~to_:{ dock_id = i op "to_dock_id"; group_idx = i op "to_group_idx" }
    | "detach_group" ->
      ignore (detach_group layout
        ~from:{ dock_id = i op "dock_id"; group_idx = i op "group_idx" }
        ~x:(f op "x") ~y:(f op "y"))
    | "redock" ->
      redock layout (i op "dock_id")
    (* ---- Pane operations (mutate the inner Pane.pane_layout). Each guards on
       [pane_layout] being present, matching the production handlers which all
       go through [Workspace_layout.panes/panes_mut]. The dirty signal is
       preserved by the production caller wrapping the dispatch in
       [panes_mut]; the corpus harness compares serialization directly. ---- *)
    | "set_pane_position" ->
      (match layout.pane_layout with
       | Some pl -> Pane.set_pane_position pl (i op "pane_id") ~x:(f op "x") ~y:(f op "y")
       | None -> ())
    | "tile_panes" ->
      (match layout.pane_layout with
       | Some pl ->
         (* Optional collapsed-dock override; absent in the corpus path. *)
         let override =
           match mem op "override_pane_id" with
           | `Int _ | `Intlit _ -> Some (i op "override_pane_id", f op "override_width")
           | _ -> None
         in
         Pane.tile_panes pl ~collapsed_override:override
       | None -> ())
    | "toggle_canvas_maximized" ->
      (match layout.pane_layout with
       | Some pl -> Pane.toggle_canvas_maximized pl
       | None -> ())
    | "resize_pane" ->
      (match layout.pane_layout with
       | Some pl -> Pane.resize_pane pl (i op "pane_id")
                      ~width:(f op "width") ~height:(f op "height")
       | None -> ())
    | "hide_pane" ->
      (match layout.pane_layout, str_opt op "kind" with
       | Some pl, Some s -> Pane.hide_pane pl (parse_pane_kind_str s)
       | _ -> ())  (* no pane layout or required field missing: skip *)
    | "show_pane" ->
      (match layout.pane_layout, str_opt op "kind" with
       | Some pl, Some s -> Pane.show_pane pl (parse_pane_kind_str s)
       | _ -> ())
    | "bring_pane_to_front" ->
      (match layout.pane_layout with
       | Some pl -> Pane.bring_pane_to_front pl (i op "pane_id")
       | None -> ())
    (* Unknown verb: skip rather than raise (a malformed/forward-compat op must
       not crash production; the corpus only ever sends known verbs). *)
    | _ -> ()
