(** YAML-interpreted panel body renderer for GTK.

    Walks a JSON element tree from the compiled workspace and creates
    corresponding GTK widgets. Uses the expression evaluator for
    bind values and the workspace loader for panel specs.

    {1 Panel architecture}

    This module is the generic renderer for {b every} panel. Adding a
    new panel typically requires no new OCaml — the panel YAML in
    [workspace/panels/] drives layout, bindings, and effects through
    this interpreter.

    Files in [lib/panels/] are reserved for irreducibly panel-specific
    logic that cannot live in YAML:

    - [layers_panel_state.ml] — singleton mutable state (isolation
      stack, drag-and-drop, search filter) that the YAML view layer
      reads but cannot itself own.
    - [panel_menu.ml] — per-panel hamburger-menu definitions plus
      menu-command dispatchers; centralized because menus span every
      panel kind.
    - [boolean_apply.ml] — the boolean compound-shape algorithm
      shared by Boolean panel actions; pure logic, not panel UI.

    The absence of [color_panel.ml] / [stroke_panel.ml] / etc. is by
    design: those panels are entirely YAML-driven and need no native
    helper. Reviewers comparing OCaml's [lib/panels/] count against
    Rust's [src/panels/] count will see a large asymmetry — that's
    architectural, not a parity gap. *)

open Workspace_layout

(** Module-level ref to the model accessor, set by create_panel_body.
    Hoisted above [update_color_panel_widgets] which reads it. *)
let _get_model_ref : (unit -> Model.model option) ref = ref (fun () -> None)

(** Module-level ref to the panel-local state store, set by
    create_panel_body. Widget renderers read it to register write-back
    callbacks; None means "no store threaded, skip write-back". *)
let _current_store : State_store.t option ref = ref None

(** Module-level ref to the active panel id (e.g. "character_panel",
    "stroke_panel"). Set by create_panel_body alongside
    [_current_store]. *)
let _current_panel_id : string option ref = ref None

(** Module-level rebuild hook. Set by dock_panel.create after each
    rebuild so widget click handlers (notably the color_swatch in
    the fill_stroke widget, whose z-order depends on
    [state.fill_on_top]) can force a structural re-render after
    state writes. Without this, [bind: { z_index: ... }] is
    evaluated only at render time and the swatch stack stays
    stale. *)
let panel_rerender_hook : (unit -> unit) ref = ref (fun () -> ())

(** Hook for menubar's Window-menu check-state resync. Set by
    [Menubar.create] (which itself depends on Yaml_panel_view via
    paragraph_panel_resync_from_active_model, so going the other
    way creates a cycle); called from [Dock_panel] after the panel-
    menu Close action so the Window menu reflects the change. *)
let panel_check_sync_hook : (unit -> unit) ref = ref (fun () -> ())

(** Hook for the reference-aware Layers-panel delete confirm. Given the
    count [n] (> 0) of live references a pending panel delete would
    orphan, returns [true] to proceed and [false] to abort. Set by
    [Menubar.create], which closes over the main window and forwards to
    [Menubar.confirm_delete_orphans] — the SAME modal confirm the main
    Delete/Cut use. Wired through a hook because Menubar depends on
    Yaml_panel_view (so this module cannot name Menubar directly without
    a cycle). The default proceeds unconditionally: it is overridden in
    headless runs (tests) and only ever consulted when the orphan set is
    non-empty, so the panel delete is never silently blocked before the
    real confirm is installed. *)
let confirm_delete_orphans_hook : (int -> bool) ref = ref (fun _ -> true)

(** Per-panel-body re-renderers, registered by dock_panel each time
    it builds a panel. The function tears down the body's existing
    children and re-runs create_panel_body inside the same body
    container — so the tab bar, chevron, and hamburger don't get
    rebuilt (and don't flash). [schedule_panel_rerender] fires
    these instead of the full dock rebuild when available. *)
let _panel_body_renderers :
  (Workspace_layout.panel_kind, (unit -> unit)) Hashtbl.t =
  Hashtbl.create 16

let register_panel_body_renderer kind render_fn =
  Hashtbl.replace _panel_body_renderers kind render_fn

let clear_panel_body_renderers () =
  Hashtbl.clear _panel_body_renderers

(** Targeted update slots for color-panel widgets that should react
    to selection-change without a body rebuild (the rebuild visibly
    pulses the hex entry as its Adwaita theming resolves). On
    document change, [update_color_panel_widgets] computes the new
    fill/stroke from the active selection and:
      - sets each swatch's color ref + queue_draws its drawing area
      - calls [set_text] on the hex entry
    Widgets are re-registered on every body rebuild. *)
type color_panel_slots = {
  mutable fill_swatch : (GMisc.drawing_area * string ref) option;
  mutable stroke_swatch : (GMisc.drawing_area * string ref) option;
  (* Event-box wrappers for the fill/stroke swatches — these are the
     widgets actually packed into the GtkFixed in
     [render_fill_stroke_widget], and what we need GdkWindow handles
     for to raise the active swatch above its sibling on a swap. *)
  mutable fill_swatch_evt : GBin.event_box option;
  mutable stroke_swatch_evt : GBin.event_box option;
  mutable hex_entry : GEdit.entry option;
  mutable recent_swatches : (GMisc.drawing_area * string ref) option array;
}
let _color_panel_slots : color_panel_slots = {
  fill_swatch = None;
  stroke_swatch = None;
  fill_swatch_evt = None;
  stroke_swatch_evt = None;
  hex_entry = None;
  recent_swatches = Array.make 10 None;
}

let clear_color_panel_slots () =
  _color_panel_slots.fill_swatch <- None;
  _color_panel_slots.stroke_swatch <- None;
  _color_panel_slots.fill_swatch_evt <- None;
  _color_panel_slots.stroke_swatch_evt <- None;
  _color_panel_slots.hex_entry <- None;
  Array.fill _color_panel_slots.recent_swatches 0
    (Array.length _color_panel_slots.recent_swatches) None

(** Refresh the 10 recent-color swatches from the panel store's
    [recent_colors] list. Called from the recent_colors bridge so a
    commit (Black/White/Recent click, hex Enter, slider release)
    repaints the recent strip in-place instead of needing a body
    rebuild. *)
let update_recent_color_widgets () =
  match !_current_store, !_current_panel_id with
  | Some store, Some pid ->
    let rc = match State_store.get_panel store pid "recent_colors" with
      | `List items ->
        Array.of_list
          (List.map (function
             | `String s -> s
             | _ -> "") items)
      | _ -> [||] in
    Array.iteri (fun i slot ->
      match slot with
      | None -> ()
      | Some (area, color_ref) ->
        let new_color = if i < Array.length rc then rc.(i) else "" in
        if !color_ref <> new_color then begin
          color_ref := new_color;
          area#misc#queue_draw ()
        end
    ) _color_panel_slots.recent_swatches
  | _ -> ()

let _hash_hex c = "#" ^ Element.color_to_hex c

(* Same per-element fill/stroke extraction as create_panel_body's
   selection_overrides — duplicated here so the listener can compute
   the new colors without invoking the full ctx-rebuild path. *)
let _elem_fill_color (e : Element.element) =
  match e with
  | Element.Rect { fill = Some f; _ }
  | Element.Circle { fill = Some f; _ }
  | Element.Ellipse { fill = Some f; _ }
  | Element.Polyline { fill = Some f; _ }
  | Element.Polygon { fill = Some f; _ }
  | Element.Path { fill = Some f; _ } -> Some f.Element.fill_color
  | _ -> None

let _elem_stroke_color (e : Element.element) =
  match e with
  | Element.Line { stroke = Some s; _ }
  | Element.Rect { stroke = Some s; _ }
  | Element.Circle { stroke = Some s; _ }
  | Element.Ellipse { stroke = Some s; _ }
  | Element.Polyline { stroke = Some s; _ }
  | Element.Polygon { stroke = Some s; _ }
  | Element.Path { stroke = Some s; _ } -> Some s.Element.stroke_color
  | _ -> None

(* Re-entry guard: writing [state.fill_color] inside this function
   fires [Effects.subscribe_active_color], which snapshots + writes
   the model's selection fill — triggering a model change → another
   on_document_changed → another call here → infinite loop /
   beachball. The flag short-circuits the second entry. *)
let _in_color_panel_update = ref false

(* True while [_write_back_bind] is forwarding a panel-channel
   write (h/s/b/r/g/bl/c/m/y/k) into [set_active_color_live]. The
   resulting on_document_changed → update_color_panel_widgets
   would otherwise recompute panel.h/s/b/... from RGB and clobber
   the just-typed channel (gray RGB has no defined hue → H
   collapses to 0 when the user drags S to 0). *)
let _panel_channel_edit_in_flight = ref false

(* True while [_write_back_bind]'s dialog branch is running the
   web_only snap pass (issuing set_field "r"/"g"/"bl"). The snap
   calls themselves are color-affecting dialog writes, so without
   this guard they would recurse and infinitely re-snap each
   channel. *)
let _dialog_snap_in_flight = ref false
let update_color_panel_widgets () =
  if !_in_color_panel_update then () else
  match !_get_model_ref () with
  | None -> ()
  | Some m ->
    _in_color_panel_update := true;
    Fun.protect
      ~finally:(fun () -> _in_color_panel_update := false)
    @@ fun () ->
    let elem_opt =
      match Document.PathMap.bindings m#document.Document.selection with
      | (path, _) :: _ ->
        (try Some (Document.get_element m#document path) with _ -> None)
      | [] -> None in
    let fill_color = match elem_opt with
      | Some e -> _elem_fill_color e
      | None ->
        (match m#default_fill with
         | Some f -> Some f.Element.fill_color
         | None -> None) in
    let stroke_color = match elem_opt with
      | Some e -> _elem_stroke_color e
      | None ->
        (match m#default_stroke with
         | Some s -> Some s.Element.stroke_color
         | None -> None) in
    (* Also persist the new active colors into the store so widgets
       that DO go through a rebuild path later (mode switch, etc.)
       see the up-to-date values. *)
    (match !_current_store with
     | Some store ->
       (match fill_color with
        | Some c -> State_store.set store "fill_color" (`String (_hash_hex c))
        | None -> ());
       (match stroke_color with
        | Some c -> State_store.set store "stroke_color" (`String (_hash_hex c))
        | None -> ())
     | None -> ());
    (* Refresh panel.h / s / b / r / g / bl / c / m / y / k / hex
       from whichever side is active (fill_on_top). The YAML's
       init: expressions seed these only at panel mount; without
       refreshing them here, switching modes or selections leaves
       slider values stale at the panel-state defaults.

       Skipped when the change originated from a panel-channel edit
       (slider drag / number-input commit): the user-typed channel
       values are already authoritative, and round-tripping through
       RGB→HSB would clobber them (e.g. dragging S to 0 makes RGB
       gray, which has no defined hue → recomputed H snaps to 0
       and the H slider jumps away from the user-chosen 120°). The
       [_panel_channel_edit_in_flight] flag is set by
       [_write_back_bind] for the duration of the channel write. *)
    (match !_current_store, !_current_panel_id with
     | Some store, Some pid when pid = "color_panel_content"
                              && not !_panel_channel_edit_in_flight ->
       let fill_on_top = match State_store.get store "fill_on_top" with
         | `Bool b -> b | _ -> true in
       let active = if fill_on_top then fill_color else stroke_color in
       (match active with
        | Some c ->
          let (r, g, b) = Element.color_to_rgba c
            |> fun (r, g, b, _) ->
              (int_of_float (Float.round (r *. 255.0)),
               int_of_float (Float.round (g *. 255.0)),
               int_of_float (Float.round (b *. 255.0))) in
          let (h, s, br) = Color_util.rgb_to_hsb r g b in
          let (cy, mg, yl, k) = Color_util.rgb_to_cmyk r g b in
          let set_n k v =
            State_store.set_panel store pid k (`Float (float_of_int v)) in
          set_n "h" h; set_n "s" s; set_n "b" br;
          set_n "r" r; set_n "g" g; set_n "bl" b;
          set_n "c" cy; set_n "m" mg; set_n "y" yl; set_n "k" k;
          (* Color_util.rgb_to_hex prepends '#'; the YAML spec for
             panel.hex is "6 chars, no # prefix" and Expr_eval
             classifies leading-# strings as Color values, which
             render_text_input's [Expr_eval.Str s -> s | _ -> ""]
             match drops — producing an empty initial after a
             panel-body rebuild fires from the menu (Invert /
             Complement / mode switch). Strip the # so the value
             stays a plain string in the store. *)
          let hex_no_hash = Color_util.rgb_to_hex r g b in
          let hex_no_hash =
            if String.length hex_no_hash > 0 && hex_no_hash.[0] = '#'
            then String.sub hex_no_hash 1 (String.length hex_no_hash - 1)
            else hex_no_hash in
          State_store.set_panel store pid "hex" (`String hex_no_hash)
        | None -> ());
       (* Refresh panel.recent_colors from the active model. The
          recent-colors bridge updates the panel store on push, but
          a tab switch / new-document focus change doesn't push —
          without this sync the panel keeps showing the previous
          document's recents until the user commits a new color. *)
       State_store.set_panel store pid "recent_colors"
         (`List (List.map (fun s -> `String s) m#recent_colors))
     | _ -> ());
    let fc_str = match fill_color with
      | Some c -> _hash_hex c | None -> "" in
    let sc_str = match stroke_color with
      | Some c -> _hash_hex c | None -> "" in
    (match _color_panel_slots.fill_swatch with
     | Some (area, color_ref) ->
       color_ref := fc_str;
       area#misc#queue_draw ()
     | None -> ());
    (match _color_panel_slots.stroke_swatch with
     | Some (area, color_ref) ->
       color_ref := sc_str;
       area#misc#queue_draw ()
     | None -> ());
    (match _color_panel_slots.hex_entry with
     | Some entry ->
       let fill_on_top = match !_current_store with
         | Some store ->
           (match State_store.get store "fill_on_top" with
            | `Bool b -> b | _ -> true)
         | None -> true in
       let active = if fill_on_top then fill_color else stroke_color in
       let hex = match active with
         | Some c -> Element.color_to_hex c
         | None -> "" in
       if not entry#is_focus && entry#text <> hex then
         entry#set_text hex
     | None -> ());
    (* Repaint the recent-colors strip — the panel store's recent
       list was just refreshed from the active model above, but the
       cp_recent_* drawing areas hold their own color refs and need
       a queue_draw. Mirrors the bridge's call site so a tab switch
       updates the strip exactly the way a push_recent_color does. *)
    update_recent_color_widgets ()

(** Compute the current color from the color panel state and commit
    it through [Panel_menu.set_active_color] — i.e. the same path
    as a swatch click, including the recent-colors push. Used by
    the slider's button_release handler (drag end) and the
    number_input's commit handler (Enter/Tab on H/S/B/etc. value
    boxes) so each discrete edit produces one recent entry.
    Mid-drag and per-keystroke live updates go through
    [Panel_menu.set_active_color_live] instead (no recent push). *)
let commit_color_panel_to_recent (store : State_store.t) (panel_id : string) : unit =
  let pf name =
    match State_store.get_panel store panel_id name with
    | `Float f -> f
    | `Int i -> float_of_int i
    | _ -> 0.0 in
  let mode = match State_store.get_panel store panel_id "mode" with
    | `String s -> s | _ -> "hsb" in
  let color_opt =
    match mode with
    | "hsb" ->
      let (r, g, b) = Color_util.hsb_to_rgb (pf "h") (pf "s") (pf "b") in
      Some (Element.color_rgb
              (float_of_int r /. 255.0)
              (float_of_int g /. 255.0)
              (float_of_int b /. 255.0))
    | "rgb" | "web_safe_rgb" ->
      Some (Element.color_rgb
              (pf "r" /. 255.0) (pf "g" /. 255.0) (pf "bl" /. 255.0))
    | "grayscale" ->
      let v = 1.0 -. (pf "k") /. 100.0 in
      Some (Element.color_rgb v v v)
    | "cmyk" ->
      let c = pf "c" /. 100.0 in
      let m = pf "m" /. 100.0 in
      let y = pf "y" /. 100.0 in
      let k = pf "k" /. 100.0 in
      let r = (1.0 -. c) *. (1.0 -. k) in
      let g = (1.0 -. m) *. (1.0 -. k) in
      let b = (1.0 -. y) *. (1.0 -. k) in
      Some (Element.color_rgb r g b)
    | _ -> None in
  match color_opt, !_get_model_ref () with
  | Some color, Some m ->
    let fill_on_top = match State_store.get store "fill_on_top" with
      | `Bool b -> b | _ -> true in
    _panel_channel_edit_in_flight := true;
    Fun.protect
      ~finally:(fun () -> _panel_channel_edit_in_flight := false)
      (fun () -> Panel_menu.set_active_color color ~fill_on_top m)
  | _ -> ()

(** Schedule a panel rebuild to run after the current event handler
    returns. Calling the hook synchronously from inside an
    entry's [activate] / [focus_out] handler (cp_hex commit) tears
    down the entry while GTK is still operating on it →
    use-after-free + segfault. The Idle callback defers the
    rebuild to the next main-loop iteration, after the handler
    chain unwinds. Dedupes concurrent calls via [_rerender_pending]
    so a burst of state writes (or a flurry of on_document_changed
    fires during a drag) coalesces into a single rebuild.

    Prefers the per-panel body renderers (fast path — only the
    panel content reflows, dock title bars stay put) over the
    full dock rebuild. Falls back to [panel_rerender_hook] when
    no per-panel renderers are registered (e.g. before dock_panel
    has built the dock for the first time). *)
let _rerender_pending = ref false
let schedule_panel_rerender () =
  if not !_rerender_pending then begin
    _rerender_pending := true;
    ignore (GMain.Idle.add (fun () ->
      _rerender_pending := false;
      if Hashtbl.length _panel_body_renderers > 0 then
        Hashtbl.iter (fun _ render -> render ()) _panel_body_renderers
      else
        !panel_rerender_hook ();
      false
    ))
  end

(** Guard so we register the on_document_changed listener once per
    model instance (instead of once per panel rebuild, which would
    accumulate listeners). Reset when a different model appears so
    multi-document setups still get the listener wired. *)
let _doc_listener_registered_for : Model.model option ref = ref None

(* _get_model_ref / _current_store / _current_panel_id hoisted to top
   of file so [update_color_panel_widgets] can read them. *)

(** Hook fired by [paragraph_panel_resync_from_active_model] — set by
    [create_panel_body] when the Paragraph panel mounts. None when no
    Paragraph panel is open. Wiring callers (notably each canvas's
    [model#on_document_changed]) call the resync helper, which lets
    the panel widgets refresh whenever the active model's selection
    changes. *)
let _paragraph_panel_sync : (unit -> unit) option ref = ref None

(** Hook fired after a fill/stroke swatch click flips
    [state.fill_on_top]. Set by [render_fill_stroke_widget] with the
    captured parent [GPack.fixed] and per-child positions; rerunning
    [fixed#put] for both swatches in the active-on-top order pushes
    the active one to the tail of GtkFixed's paint list (= on top).
    No-op when no fill/stroke widget is currently mounted. *)
let fill_stroke_swap_hook : (unit -> unit) ref = ref (fun () -> ())

(** Hook for opening a YAML-defined dialog by id with raw params.
    Set in main.ml at startup using [Yaml_dialog_view.open_dialog]
    + [show_dialog] — going through Yaml_dialog_view directly here
    would create a Yaml_panel_view ↔ Yaml_dialog_view cycle. *)
let open_yaml_dialog_hook :
  (string -> (string * Yojson.Safe.t) list -> unit) ref =
  ref (fun _ _ -> ())

(** Hook for opening a NON-MODAL YAML-defined dialog as a flyout
    (``modal: false`` dialogs only). Set in main.ml using
    [Yaml_dialog_view.open_dialog] + [show_nonmodal_dialog]. Distinct
    from [open_yaml_dialog_hook] (which runs the blocking modal
    [show_dialog]) so the toolbar long-press tool-alternates flyout
    can pop a non-blocking popup that leaves the canvas/toolbar live.
    Same cycle-avoidance rationale as [open_yaml_dialog_hook]. *)
let open_nonmodal_dialog_hook :
  (string -> (string * Yojson.Safe.t) list -> unit) ref =
  ref (fun _ _ -> ())

(** Hook for switching the active canvas's toolbar tool from a YAML
    effect (``set: { active_tool: "<name>" }``). The color picker's
    eyedropper icon and other in-dialog tool-switch shortcuts need
    this to actually change the canvas tool — without it the [set:]
    effect is a silent no-op since the dialog scope has no store
    that owns active_tool. Wired in main.ml against the active
    canvas's toolbar. *)
let set_active_tool_hook : (string -> unit) ref = ref (fun _ -> ())

(** Current active-tool name, as the YAML toolbar's [bind.checked]
    expressions read it (``state.active_tool == "selection"`` etc.).
    The native toolbar / canvas own the real tool; this string mirrors
    it so the bundle-rendered toolbar can re-evaluate its highlight.
    Updated by [select_tool] click dispatch, the alternates flyout's
    ``set: { active_tool: ... }`` effect, and — via the toolbar's
    [tool_changed_hook] wired in main.ml — every native tool change
    (keyboard shortcuts, spacebar Hand). Toolbar STEP A. *)
let active_tool_name : string ref = ref "selection"

(** Rebuild the bundle-rendered toolbar pane in place. Wired in main.ml
    to re-run [mount_toolbar] so the tool-button highlight re-evaluates
    after [active_tool_name] changes. No-op until wired. *)
let toolbar_rerender_hook : (unit -> unit) ref = ref (fun () -> ())

(** Hook returning the active appearance's text color. Used by
    [render_text]'s default when [style.color] is unset, so labels
    re-skin when the user switches between Dark / Medium / Light
    Gray. Wired in main.ml at startup against [Dock_panel.theme_text]
    — referencing that ref directly would create a Yaml_panel_view ↔
    Dock_panel cycle. *)
let theme_text_hook : (unit -> string) ref = ref (fun () -> "#cccccc")

(** Resolve an integer size from a [style.size] JSON value that may be
    a plain number or a ``{{theme.base.sizes.tool_button}}`` token
    string. Walks the workspace [theme] tree by the dotted path inside
    the braces. Returns [None] when the value is neither a number nor a
    resolvable theme token. The toolbar's tool buttons declare
    ``size: "{{theme.sizes.tool_button}}"`` (32px); without this they
    fell back to the 20px default. Toolbar STEP A. *)
let resolve_size_token (v : Yojson.Safe.t) : int option =
  match v with
  | `Int n -> Some n
  | `Float f -> Some (int_of_float f)
  | `String s ->
    let s = String.trim s in
    let len = String.length s in
    if len > 4 && String.sub s 0 2 = "{{"
       && String.sub s (len - 2) 2 = "}}" then begin
      let path = String.trim (String.sub s 2 (len - 4)) in
      let segs = String.split_on_char '.' path in
      (* Drop a leading "theme." since we index from ws.data.theme. *)
      let segs = match segs with "theme" :: rest -> rest | rest -> rest in
      match Workspace_loader.load () with
      | None -> None
      | Some ws ->
        let theme = match Workspace_loader.json_member "theme" ws.Workspace_loader.data with
          | Some t -> t | None -> `Null in
        (* The compiled theme nests sizes under [base]; accept both the
           short ``sizes.tool_button`` and the explicit
           ``base.sizes.tool_button`` forms. *)
        let rec descend node = function
          | [] -> Some node
          | seg :: rest ->
            (match Workspace_loader.json_member seg node with
             | Some child -> descend child rest
             | None -> None) in
        let found = match descend theme segs with
          | Some r -> Some r
          | None -> descend theme ("base" :: segs) in
        (match found with
         | Some (`Int n) -> Some n
         | Some (`Float f) -> Some (int_of_float f)
         | _ -> None)
    end else
      (try Some (int_of_string s) with _ -> None)
  | _ -> None

(** Trigger a re-sync of the open Paragraph panel from the active
    model's current selection. No-op when no Paragraph panel is
    open. Safe to call from any model's [on_document_changed]
    listener — the sync resolves the active model lazily. *)
let paragraph_panel_resync_from_active_model () : unit =
  match !_paragraph_panel_sync with
  | Some f -> f ()
  | None -> ()


(** Iterate every registered panel store. Cross-panel bridges use
    this in [Panel_menu.add_recent_colors_listener] callbacks so a
    push reaches all visible panels in one pass. *)
let iter_panel_stores (f : string -> State_store.t -> unit) : unit =
  Panel_menu.iter_panel_stores f

(** Wire the recent_colors bridge listener that mirrors model
    recent_colors into every registered panel that defines a
    recent_colors key. Apps call this once at startup. Safe to call
    multiple times — the listener is idempotent and the registry
    in [Panel_menu] dedupes nothing, so subsequent calls would add
    duplicate listeners. The [_bridge_installed] guard prevents that. *)
let _bridge_installed = ref false

let install_recent_colors_bridge () =
  if !_bridge_installed then () else begin
    _bridge_installed := true;
    Panel_menu.add_recent_colors_listener (fun model _hex ->
      let rc_json =
        `List (List.map (fun s -> `String s) model#recent_colors) in
      iter_panel_stores (fun pid store ->
        if pid = "color_panel_content" || pid = "swatches_panel_content" then
          match State_store.get_panel store pid "recent_colors" with
          | `Null -> ()  (* panel hasn't seeded recent_colors *)
          | _ ->
            State_store.set_panel store pid "recent_colors" rc_json);
      (* Repaint the recent strip in-place using the just-updated
         panel.recent_colors values — without this the swatches'
         captured color_str stays stale and the new color doesn't
         appear until a body rebuild fires for some other reason. *)
      update_recent_color_widgets ();
      (* Also refresh the fill/stroke swatches + hex entry + slider
         state. set_active_color goes through this bridge for every
         commit (swatch click, hex commit, Invert/Complement menu,
         …); when there is no selection the model defaults change
         but on_document_changed never fires, so the panel widgets
         keep showing the previous color until update is called
         explicitly. *)
      update_color_panel_widgets ())
  end

(** Parse a bind expression like "panel.X" or "state.X" and write
    [value] into the appropriate scope of [_current_store]. Silent
    no-op when either ref is unset or the expression doesn't match
    a recognised scope+key pattern. Used by the widget renderers'
    change callbacks to flow user edits back to the store (where
    the subscription fires the apply pipeline). *)
let _write_back_bind (bind_expr : string) (value : Yojson.Safe.t) : unit =
  let parts = String.split_on_char '.' bind_expr in
  match parts with
  | "dialog" :: field :: _ ->
    (* YAML dialog widget bound to ``dialog.X``: route to the live
       dialog state so OK button params (resolved at click time)
       see the typed value. Without this the widget edit was a
       silent no-op for any dialog widget. *)
    Dialog_global.set_field field value;
    (* Color picker "Only Web Colors": while the toggle is on, snap
       each RGB channel of the current color to multiples of 51
       (0/51/102/153/204/255). Fires both on toggle-on and after any
       color-affecting edit (gradient, hue bar, hex commit, channel
       value boxes) so the snap is continuous. Writing through the
       r/g/bl setters rebuilds [color] via the rgb() lambda so all
       derived channels (HSB, CMYK, hex) and the preview swatch
       refresh from the snapped color. Reads route through
       [read_state] (= the YAML get-lambdas) so they see the
       canonical color, not stale init-only stored r/g/bl. The
       [_dialog_snap_in_flight] guard prevents the snap's own r/g/bl
       writes from re-triggering the snap pass. *)
    let color_affecting = match field with
      | "h" | "s" | "b" | "r" | "g" | "bl"
      | "c" | "m" | "y" | "k" | "hex" | "color" -> true
      | _ -> false in
    let web_only_on () =
      match List.assoc_opt "web_only" (Dialog_global.read_state ()) with
      | Some (`Bool b) -> b | _ -> false in
    let should_snap =
      (field = "web_only" && value = `Bool true)
      || (color_affecting && web_only_on ()) in
    if should_snap && not !_dialog_snap_in_flight then begin
      _dialog_snap_in_flight := true;
      Fun.protect
        ~finally:(fun () -> _dialog_snap_in_flight := false)
        (fun () ->
          let live = Dialog_global.read_state () in
          let read_i k =
            match List.assoc_opt k live with
            | Some (`Float f) -> int_of_float (Float.round f)
            | Some (`Int i) -> i
            | _ -> 0 in
          let snap x =
            let v = Float.round (float_of_int x /. 51.0) *. 51.0 in
            max 0.0 (min 255.0 v) in
          Dialog_global.set_field "r" (`Float (snap (read_i "r")));
          Dialog_global.set_field "g" (`Float (snap (read_i "g")));
          Dialog_global.set_field "bl" (`Float (snap (read_i "bl"))))
    end
  | _ ->
    match !_current_store, !_current_panel_id with
    | Some store, Some panel_id ->
      (match parts with
       | "panel" :: field :: _ ->
         (* Phase 4: paragraph writes route through the dedicated
            setter so mutual exclusion + sync + apply happen atomically.
            Skipped when no model is threaded (test harness). *)
         if panel_id = "paragraph_panel_content" then begin
           match !_get_model_ref () with
           | Some model ->
             let ctrl = new Controller.controller ~model () in
             Effects.set_paragraph_panel_field store ctrl field value
           | None ->
             State_store.set_panel store panel_id field value
         end
         (* Character writes route through the dedicated setter so
            font_size dispatches keep panel.leading tracking the
            Auto-derived value (= font_size * 1.2) while the
            element's line_height is empty. Without this, nudging
            font_size while in Auto mode turns Auto into a stale
            numeric override on the next apply. Mirrors Rust's
            character_panel_post_write. *)
         else if panel_id = "character_panel_content" then begin
           match !_get_model_ref () with
           | Some model ->
             let ctrl = new Controller.controller ~model () in
             Effects.set_character_panel_field store ctrl field value
           | None ->
             State_store.set_panel store panel_id field value
         end
         (* Color panel hex field: commit the parsed RGB through
            [Panel_menu.set_active_color] so the model's default
            fill/stroke, the canvas selection, and the recent-colors
            list all pick up the change. Mirrors the Rust
            [renderer.rs] PanelKind::Color/"hex" branch. Bail
            silently on unparseable input so the user's typed value
            isn't silently zeroed. *)
         else if panel_id = "color_panel_content" && field = "hex" then begin
           State_store.set_panel store panel_id field value;
           (match value with
            | `String s ->
              let trimmed = String.trim s in
              let trimmed = if String.length trimmed > 0 && trimmed.[0] = '#'
                then String.sub trimmed 1 (String.length trimmed - 1)
                else trimmed in
              (match Element.color_from_hex trimmed with
               | Some color ->
                 (* Web Safe RGB mode: snap each channel to the
                    nearest multiple of 51 on commit, per the YAML
                    description ("In Web Safe RGB mode, the entered
                    value is snapped to the nearest web-safe color
                    on commit"). Other modes pass through unchanged. *)
                 let color = match State_store.get_panel store panel_id "mode" with
                   | `String "web_safe_rgb" ->
                     let (r, g, b, _) = Element.color_to_rgba color in
                     let snap c =
                       let v = Float.round (c *. 255.0 /. 51.0) *. 51.0 in
                       max 0.0 (min 255.0 v) /. 255.0 in
                     Element.color_rgb (snap r) (snap g) (snap b)
                   | _ -> color
                 in
                 let fill_on_top = match State_store.get store "fill_on_top" with
                   | `Bool b -> b | _ -> true in
                 (match !_get_model_ref () with
                  | Some m ->
                    Panel_menu.set_active_color color ~fill_on_top m
                  | None -> ());
                 (* Also mirror the new color into [state.fill_color]
                    / [state.stroke_color] so the panel's fill_swatch
                    (bound to [color: state.fill_color]) reflects the
                    edit — Panel_menu.set_active_color only mutates the
                    model, not the panel's state store. The model
                    mutation triggers on_document_changed →
                    update_color_panel_widgets, which refreshes the
                    swatches, hex entry, and slider state in-place;
                    no body rebuild needed (would pulse the entry). *)
                 let snapped_hex = Element.color_to_hex color in
                 let hex_with_hash = "#" ^ snapped_hex in
                 let key = if fill_on_top then "fill_color" else "stroke_color" in
                 State_store.set store key (`String hex_with_hash);
                 (* Reflect the snapped hex back into the entry. The
                    on_document_changed path skips set_text while the
                    entry is focused (to avoid clobbering mid-typing),
                    but the user just pressed Enter / Tab so the
                    snapped value is the new authoritative state and
                    should replace what they typed. *)
                 (match _color_panel_slots.hex_entry with
                  | Some entry when entry#text <> snapped_hex ->
                    entry#set_text snapped_hex
                  | _ -> ())
               | None -> ())
            | _ -> ())
         end
         (* Color panel color channels (h, s, b, r, g, bl, c, m, y, k):
            compute the new color from the panel state with this one
            field changed, then push to the model via
            [Panel_menu.set_active_color_live]. Mirrors Rust's
            [compute_color_from_panel] + slider oninput handler. The
            model mutation triggers on_document_changed →
            update_color_panel_widgets, which writes back the recomputed
            channels (including the just-changed one, after RGB
            round-trip) and refreshes swatches + hex entry. *)
         else if panel_id = "color_panel_content"
                 && List.mem field ["h"; "s"; "b"; "r"; "g"; "bl"; "c"; "m"; "y"; "k"] then begin
           State_store.set_panel store panel_id field value;
           let new_val = match value with
             | `Float f -> f
             | `Int i -> float_of_int i
             | _ -> 0.0 in
           let pf name =
             if name = field then new_val
             else match State_store.get_panel store panel_id name with
               | `Float f -> f
               | `Int i -> float_of_int i
               | _ -> 0.0 in
           let mode = match State_store.get_panel store panel_id "mode" with
             | `String s -> s
             | _ -> "hsb" in
           let color_opt =
             match mode with
             | "hsb" ->
               let (r, g, b) = Color_util.hsb_to_rgb (pf "h") (pf "s") (pf "b") in
               Some (Element.color_rgb
                       (float_of_int r /. 255.0)
                       (float_of_int g /. 255.0)
                       (float_of_int b /. 255.0))
             | "rgb" | "web_safe_rgb" ->
               Some (Element.color_rgb
                       (pf "r" /. 255.0) (pf "g" /. 255.0) (pf "bl" /. 255.0))
             | "grayscale" ->
               let v = 1.0 -. (pf "k") /. 100.0 in
               Some (Element.color_rgb v v v)
             | "cmyk" ->
               let c = pf "c" /. 100.0 in
               let m = pf "m" /. 100.0 in
               let y = pf "y" /. 100.0 in
               let k = pf "k" /. 100.0 in
               let r = (1.0 -. c) *. (1.0 -. k) in
               let g = (1.0 -. m) *. (1.0 -. k) in
               let b = (1.0 -. y) *. (1.0 -. k) in
               Some (Element.color_rgb r g b)
             | _ -> None in
           (match color_opt, !_get_model_ref () with
            | Some color, Some m ->
              let fill_on_top = match State_store.get store "fill_on_top" with
                | `Bool b -> b | _ -> true in
              _panel_channel_edit_in_flight := true;
              Fun.protect
                ~finally:(fun () -> _panel_channel_edit_in_flight := false)
                (fun () ->
                  Panel_menu.set_active_color_live color ~fill_on_top m;
                  let hex_with_hash = "#" ^ Element.color_to_hex color in
                  let key = if fill_on_top then "fill_color" else "stroke_color" in
                  State_store.set store key (`String hex_with_hash))
            | _ -> ())
         end
         else
           State_store.set_panel store panel_id field value
       | "state" :: field :: _ ->
         State_store.set store field value
       | _ -> ())
    | _ -> ()

(** Dispatch a click on a YAML element by walking its [behavior]
    array. Supports the three patterns the color panel uses:
      1. [effects: [{ set: { key: <expr-or-literal> } }]] —
         fill_stroke widget swatches write [state.fill_on_top] to
         flip the active target.
      2. [action: <name>, params: { ... }] — recent / black / white
         swatches use [set_active_color] with a color expression;
         the None swatch uses [set_active_color_none].
      3. [condition: <expr>] gates the dispatch — recent slots use
         this so empty slots are no-ops.
    Mirrors the Rust [renderer.rs] color_swatch click handler.
    Used by both [render_color_swatch] and the icon_button branch
    of [render_button] (cp_none_swatch and the fill_stroke widget's
    swap / reset / mode icons).

    Returns true iff any [effects: [{set: ...}]] entries fired — the
    caller uses this to decide whether to schedule a panel
    re-render. Action-only dispatches (set_active_color* etc.)
    don't change panel-local state, so the canvas refresh from the
    model write is enough; skipping the dock rebuild avoids the
    visible flicker on every Black / White / Recent click. *)
let dispatch_click_behaviors (el : Yojson.Safe.t) (ctx : Yojson.Safe.t) : bool =
  let open Yojson.Safe.Util in
  let wrote_state = ref false in
  let behaviors = match el |> member "behavior" with
    | `List bs -> bs | _ -> [] in
  List.iter (fun b ->
    let event = b |> member "event" |> to_string_option
                |> Option.value ~default:"" in
    if event = "click" then begin
      let cond_passes = match b |> member "condition" |> to_string_option with
        | Some cond_expr ->
          (match Expr_eval.evaluate cond_expr ctx with
           | Expr_eval.Bool true -> true
           | Expr_eval.Bool false -> false
           | v -> Expr_eval.to_bool v)
        | None -> true in
      if cond_passes then begin
        let resolve_value v =
          match v with
          | `String expr_str ->
            (try Effects.value_to_json
                   (Expr_eval.evaluate expr_str ctx)
             with _ -> v)
          | _ -> v
        in
        (match b |> member "effects" with
         | `List effects ->
           List.iter (fun e ->
             match e |> member "set" with
             | `Assoc pairs ->
               List.iter (fun (k, v) ->
                 _write_back_bind ("state." ^ k) (resolve_value v);
                 wrote_state := true
               ) pairs
             | _ -> ()
           ) effects
         | _ -> ());
        (match b |> member "action" |> to_string_option with
         | Some action_name when action_name <> "" ->
           let params_list = match b |> member "params" with
             | `Assoc pairs ->
               List.map (fun (k, v) -> (k, resolve_value v)) pairs
             | _ -> [] in
           (match !_get_model_ref () with
            | None -> ()
            | Some m ->
              let fill_on_top = match !_current_store with
                | Some s ->
                  (match State_store.get s "fill_on_top" with
                   | `Bool b -> b | _ -> true)
                | None -> true in
              (* Direct routes for the color-panel actions —
                 dispatch_yaml_action's effects pipeline doesn't
                 wire the [set: { fill_color: ... }] target into
                 the model in non-layer panels, so the action
                 would otherwise no-op. Mirrors the click-handler
                 shortcuts the Rust / Swift ports take. *)
              match action_name with
              | "select_tool" ->
                (* Toolbar STEP A: a tool button was clicked. Mirror the
                   tool string into [active_tool_name] (so bind.checked
                   re-evaluates) and route through [set_active_tool_hook]
                   to switch the native toolbar + canvas. The hook calls
                   [toolbar#select_tool], whose [tool_changed_hook]
                   (wired in main.ml) does the string update + toolbar
                   rebuild — so this arm only needs to fire the hook. *)
                (match List.assoc_opt "tool" params_list with
                 | Some (`String tool) when tool <> "" ->
                   !set_active_tool_hook tool
                 | _ -> ())
              | "set_active_color" ->
                let color_opt =
                  match List.assoc_opt "color" params_list with
                  | Some (`String hex) ->
                    Element.color_from_hex
                      (if String.length hex > 0 && hex.[0] = '#'
                       then String.sub hex 1 (String.length hex - 1)
                       else hex)
                  | _ -> None
                in
                (match color_opt with
                 | Some color ->
                   Panel_menu.set_active_color color ~fill_on_top m;
                   (* on_document_changed only fires when there's a
                      selection; with nothing selected the
                      set_default_fill call doesn't reach the panel
                      widgets, so a recent-swatch click goes
                      invisible. Force a refresh here. *)
                   update_color_panel_widgets ()
                 | None -> ())
              | "set_active_color_none" ->
                if fill_on_top then begin
                  m#set_default_fill None;
                  if not (Document.PathMap.is_empty
                            m#document.Document.selection) then begin
                    (* The Controller mutator self-brackets via edit_document
                       (one undo step); no separate snapshot needed (OP_LOG.md
                       Increment 1). *)
                    let ctrl = Controller.create ~model:m () in
                    ctrl#set_selection_fill None
                  end
                end else begin
                  m#set_default_stroke None;
                  if not (Document.PathMap.is_empty
                            m#document.Document.selection) then begin
                    let ctrl = Controller.create ~model:m () in
                    ctrl#set_selection_stroke None
                  end
                end
              | "reset_fill_stroke" ->
                (* Reset to workspace defaults: white fill + black
                   stroke + fill_on_top. The YAML action [set:]
                   effect writes to state.fill_color /
                   state.stroke_color, but subscribe_active_color
                   only propagates the side matching fill_on_top —
                   so the other side stays stale. Apply both sides
                   to the model + selection directly. *)
                let new_fill = Some (Element.make_fill Element.white) in
                let new_stroke = Some (Element.make_stroke Element.black) in
                m#set_default_fill new_fill;
                m#set_default_stroke new_stroke;
                (match !_current_store with
                 | Some store ->
                   State_store.set store "fill_on_top" (`Bool true)
                 | None -> ());
                if not (Document.PathMap.is_empty
                          m#document.Document.selection) then begin
                  (* Fill + stroke as ONE undo step: with_txn opens the bracket,
                     the edit_document inside each Controller mutator JOINS it (OP_LOG.md
                     Increment 1). *)
                  let ctrl = Controller.create ~model:m () in
                  m#with_txn (fun () ->
                    ctrl#set_selection_fill new_fill;
                    ctrl#set_selection_stroke new_stroke)
                end;
                update_color_panel_widgets ();
                !fill_stroke_swap_hook ()
              | "swap_fill_stroke" ->
                (* Direct route. The YAML action [swap:] effect
                   only flips state.fill_color / state.stroke_color
                   in the store; subscribe_active_color then only
                   propagates the side matching fill_on_top to the
                   model, leaving the other side stale. Mirror the
                   toolbar's swap_fill_stroke logic and apply both
                   sides to the model + selection.

                   Read the source fill/stroke from the SELECTION
                   first (a selected rectangle may already have
                   fill=purple / stroke=green even though the model
                   defaults drifted away to black). Falls back to
                   the model defaults when nothing is selected. *)
                let elem_opt =
                  match Document.PathMap.bindings
                          m#document.Document.selection with
                  | (path, _) :: _ ->
                    (try Some (Document.get_element m#document path)
                     with _ -> None)
                  | [] -> None in
                let sel_fill = match elem_opt with
                  | Some e ->
                    (match e with
                     | Element.Rect { fill; _ }
                     | Element.Circle { fill; _ }
                     | Element.Ellipse { fill; _ }
                     | Element.Polyline { fill; _ }
                     | Element.Polygon { fill; _ }
                     | Element.Path { fill; _ } -> Some fill
                     | _ -> None)
                  | None -> None in
                let sel_stroke = match elem_opt with
                  | Some e ->
                    (match e with
                     | Element.Line { stroke; _ }
                     | Element.Rect { stroke; _ }
                     | Element.Circle { stroke; _ }
                     | Element.Ellipse { stroke; _ }
                     | Element.Polyline { stroke; _ }
                     | Element.Polygon { stroke; _ }
                     | Element.Path { stroke; _ } -> Some stroke
                     | _ -> None)
                  | None -> None in
                let old_fill = match sel_fill with
                  | Some f -> f
                  | None -> m#default_fill in
                let old_stroke = match sel_stroke with
                  | Some s -> s
                  | None -> m#default_stroke in
                let new_fill = match old_stroke with
                  | Some s ->
                    Some { Element.fill_color = s.Element.stroke_color;
                           fill_opacity = s.Element.stroke_opacity }
                  | None -> None in
                let new_stroke = match old_fill with
                  | Some f ->
                    let width = match old_stroke with
                      | Some s -> s.Element.stroke_width | None -> 1.0 in
                    Some (Element.make_stroke ~width
                            ~opacity:f.Element.fill_opacity
                            f.Element.fill_color)
                  | None -> None in
                m#set_default_fill new_fill;
                m#set_default_stroke new_stroke;
                if not (Document.PathMap.is_empty
                          m#document.Document.selection) then begin
                  (* Fill + stroke as ONE undo step: with_txn opens the bracket,
                     the edit_document inside each Controller mutator JOINS it (OP_LOG.md
                     Increment 1). *)
                  let ctrl = Controller.create ~model:m () in
                  m#with_txn (fun () ->
                    ctrl#set_selection_fill new_fill;
                    ctrl#set_selection_stroke new_stroke)
                end;
                update_color_panel_widgets ()
              (* Symbols panel (SYMBOLS.md section 8). These are native,
                 value-in-op arms (mint ids / snapshot / shared symbol
                 ops), so the shared YAML actions are [log] stubs and the
                 real work is intercepted here — exactly like the Rust
                 lead's dispatch_action symbol arms. Selection + the
                 three footer ops all write panel state (selection or the
                 master store), so each returns [wrote_state = true] to
                 drive a panel re-render (row highlight + button enabled
                 state refresh). *)
              | "symbols_panel_select" ->
                (match !_current_store,
                       List.assoc_opt "symbol_id" params_list with
                 | Some store, Some (`String id) when id <> "" ->
                   Symbols_panel.set_selected_symbol store id;
                   wrote_state := true
                 | _ -> ())
              | "new_symbol" ->
                (match !_current_store with
                 | Some store ->
                   Symbols_panel.new_symbol store m; wrote_state := true
                 | None -> ())
              | "place_instance" ->
                (match !_current_store with
                 | Some store ->
                   Symbols_panel.place_instance store m; wrote_state := true
                 | None -> ())
              | "place_concept_instance" ->
                (* concepts_panel_select is the generic set_panel_state; only the
                   place arm is native (mints + builds a Generated). Route the
                   placement through [Op_apply.op_apply] so it JOURNALS as a real
                   [place_concept_instance] op (value-in-op: concept id + resolved
                   default params + minted id), replayable like the sibling
                   structural verbs. [with_txn] brackets one undo; the arm both
                   mutates and records. *)
                (match !_current_store with
                 | Some store ->
                   (match Concepts_panel.place_concept_op store m with
                    | Some op ->
                      let ctrl = new Controller.controller ~model:m () in
                      m#with_txn (fun () ->
                        m#name_txn "place_concept_instance";
                        Op_apply.op_apply m ctrl op);
                      wrote_state := true
                    | None -> ())
                 | None -> ())
              | "apply_concept_operation" ->
                (* Apply a named concept operation (CONCEPTS.md section 9). The
                   operation's effect is RESOLVED here, at production time: the
                   op-builder looks the operation up in the registry, evaluates its
                   [set:] expressions over the instance's CURRENT params, and bakes
                   the resulting [changes] map into the op (value-in-op). Route
                   through [Op_apply.op_apply] so it JOURNALS; [with_txn] brackets
                   one undo. Replay merges [changes] and never re-evaluates. *)
                (match !_current_store,
                       List.assoc_opt "op_id" params_list with
                 | Some store, Some (`String op_id) ->
                   (match Concepts_panel.apply_concept_operation_op store m op_id with
                    | Some op ->
                      let ctrl = new Controller.controller ~model:m () in
                      m#with_txn (fun () ->
                        m#name_txn "apply_concept_operation";
                        Op_apply.op_apply m ctrl op);
                      wrote_state := true
                    | None -> ())
                 | _ -> ())
              | "promote_to_concept" ->
                (* Promote the single selected raw shape to a Generated concept
                   instance (CONCEPTS.md section 10 — the fitter / promote). The
                   op-builder extracts the element's world-space vertices, tries
                   each registered concept's [fitter] over [shape.points], and on
                   the first match bakes the recovered params + a placement
                   transform into the op (value-in-op). Route through
                   [Op_apply.op_apply] so it JOURNALS; [with_txn] brackets one
                   undo. A no-match yields no op and is a silent no-op. *)
                (match !_current_store with
                 | Some _ ->
                   (match Concepts_panel.promote_to_concept_op m with
                    | Some op ->
                      let ctrl = new Controller.controller ~model:m () in
                      m#with_txn (fun () ->
                        m#name_txn "promote_to_concept";
                        Op_apply.op_apply m ctrl op);
                      wrote_state := true
                    | None -> ())
                 | None -> ())
              | "delete_symbol_action" ->
                (match !_current_store with
                 | Some store ->
                   (* Reuse the reference-aware confirm hook — its body
                      ("Deleting will leave N live instance(s) empty.")
                      is the cross-language-pinned wording the shared
                      delete_symbol_orphan_confirm dialog also renders. *)
                   Symbols_panel.delete_symbol_action store m
                     ~confirm:(fun n -> !confirm_delete_orphans_hook n);
                   wrote_state := true
                 | None -> ())
              | _ ->
                Panel_menu.dispatch_yaml_action
                  ~params:params_list action_name m)
         | _ -> ())
      end
    end
  ) behaviors;
  !wrote_state

(** Dispatch a double-click on a YAML element by walking its
    [behavior] array for [event: double_click] entries. Currently
    used by the fill/stroke swatch's open_color_picker entry — a
    YAML action that fires [open_dialog] with the color_picker id.
    Falls through to [Panel_menu.dispatch_yaml_action] like the
    single-click action path so any future double_click action
    works without extra plumbing. *)
let dispatch_double_click_behaviors (el : Yojson.Safe.t) (ctx : Yojson.Safe.t) : unit =
  let open Yojson.Safe.Util in
  let behaviors = match el |> member "behavior" with
    | `List bs -> bs | _ -> [] in
  List.iter (fun b ->
    let event = b |> member "event" |> to_string_option
                |> Option.value ~default:"" in
    if event = "double_click" then begin
      (match b |> member "action" |> to_string_option with
       | Some action_name when action_name <> "" ->
         (* Don't replace bare-word values like [target: fill] with
            Null. resolve_value returns Null whenever the string
            isn't a bound identifier (Expr_eval treats undefined
            names as Null) — losing the literal would turn
            [param.target] into Null in the dialog and the picker's
            [if param.target == "fill"] branch always falls to else. *)
         let resolve_param v =
           match v with
           | `String s when String.contains s '.' ->
             (try Effects.value_to_json
                    (Expr_eval.evaluate s ctx)
              with _ -> v)
           | _ -> v
         in
         let params_list = match b |> member "params" with
           | `Assoc pairs ->
             List.map (fun (k, v) -> (k, resolve_param v)) pairs
           | _ -> [] in
         (* open_color_picker → open the YAML-defined color_picker
            dialog directly. The YAML action [open_dialog:] effect
            only initializes state in the store; the actual GTK
            dialog window is created via [open_yaml_dialog_hook]
            (set by main.ml from Yaml_dialog_view — going through
            Yaml_dialog_view directly here would form a cycle). *)
         (if action_name = "open_color_picker" then
            !open_yaml_dialog_hook "color_picker" params_list
          else
            match !_get_model_ref () with
            | None -> ()
            | Some m ->
              Panel_menu.dispatch_yaml_action
                ~params:params_list action_name m)
       | _ -> ())
    end
  ) behaviors

(** Dispatch a value-change commit on a YAML element by walking its [behavior]
    array for [event: change] entries. The committed [value] is injected as
    [event.value] (so params like [value: "event.value"] resolve) and action
    params are evaluated against that augmented context (so a Concepts-panel
    foreach [p.name] resolves to the row's parameter name). The
    [set_concept_param] native arm writes the value onto the single selected
    Generated instance; other actions fall through to
    [Panel_menu.dispatch_yaml_action]. Mirrors [dispatch_click_behaviors] for
    the change event. Returns true iff any panel-local state was written. *)
let dispatch_change_behaviors (el : Yojson.Safe.t) (ctx : Yojson.Safe.t)
    (value : float) : bool =
  let open Yojson.Safe.Util in
  let wrote_state = ref false in
  let behaviors = match el |> member "behavior" with
    | `List bs -> bs | _ -> [] in
  (* Expose the committed value under [event.value], overlaying any existing
     [event] binding, for param / effect resolution. *)
  let ctx_ev =
    let event_json = `Assoc [ ("value", `Float value) ] in
    match ctx with
    | `Assoc pairs ->
      `Assoc (("event", event_json) :: List.remove_assoc "event" pairs)
    | _ -> `Assoc [ ("event", event_json) ]
  in
  List.iter (fun b ->
    let event = b |> member "event" |> to_string_option
                |> Option.value ~default:"" in
    if event = "change" then begin
      let resolve_value v =
        match v with
        | `String expr_str ->
          (try Effects.value_to_json (Expr_eval.evaluate expr_str ctx_ev)
           with _ -> v)
        | _ -> v
      in
      (match b |> member "effects" with
       | `List effects ->
         List.iter (fun e ->
           match e |> member "set" with
           | `Assoc pairs ->
             List.iter (fun (k, v) ->
               _write_back_bind ("state." ^ k) (resolve_value v);
               wrote_state := true) pairs
           | _ -> ()) effects
       | _ -> ());
      (match b |> member "action" |> to_string_option with
       | Some action_name when action_name <> "" ->
         let params_list = match b |> member "params" with
           | `Assoc pairs -> List.map (fun (k, v) -> (k, resolve_value v)) pairs
           | _ -> [] in
         (match !_get_model_ref () with
          | None -> ()
          | Some m ->
            (match action_name with
             | "set_concept_param" ->
               (* Route the edit through [Op_apply.op_apply] so it JOURNALS as a
                  real [set_concept_param] op (value-in-op: the resolved path,
                  param name, and committed value), replayable like the sibling
                  property verbs. [with_txn] brackets one undo; the arm both
                  mutates and records. *)
               (match !_current_store,
                      List.assoc_opt "name" params_list,
                      List.assoc_opt "value" params_list with
                | Some store, Some (`String name), Some vjson ->
                  let v = match vjson with
                    | `Float f -> f
                    | `Int i -> float_of_int i
                    | `Intlit s -> (try float_of_string s with _ -> 0.0)
                    | _ -> 0.0 in
                  (match Concepts_panel.set_concept_param_op store m name v with
                   | Some op ->
                     let ctrl = new Controller.controller ~model:m () in
                     m#with_txn (fun () ->
                       m#name_txn "set_concept_param";
                       Op_apply.op_apply m ctrl op);
                     wrote_state := true
                   | None -> ())
                | _ -> ())
             | _ ->
               Panel_menu.dispatch_yaml_action
                 ~params:params_list action_name m))
       | _ -> ())
    end
  ) behaviors;
  !wrote_state

(** Layers-panel mutable state — collapsed rows, panel selection, rename
    state, drag source/target, search filter, hidden type filter, saved
    lock states for toggle-all, solo state, and the rerender callback —
    lives in the Layers_panel_state module so both this renderer and
    the panel-menu dispatcher can share it without a dep cycle. *)

(** Safely access a nested JSON member path (e.g. "style" -> "gap").
    Returns `Null if any intermediate value is not an object. *)
let safe_member (key : string) (j : Yojson.Safe.t) : Yojson.Safe.t =
  match j with
  | `Assoc _ -> Yojson.Safe.Util.member key j
  | _ -> `Null

(** Check if an element should be visible based on its bind.visible expression.
    Returns true if no bind.visible is present, or if the expression evaluates to truthy. *)
let is_visible (el : Yojson.Safe.t) (ctx : Yojson.Safe.t) : bool =
  let open Yojson.Safe.Util in
  match el |> member "bind" with
  | `Assoc _ as bind ->
    (match bind |> member "visible" |> to_string_option with
     | Some expr ->
       let result = Expr_eval.evaluate expr ctx in
       Expr_eval.to_bool result
     | None -> true)
  | _ -> true

(** Render a YAML element spec into GTK widgets.
    [packing] is the GTK packing function for the parent container.
    [ctx] is the evaluation context (JSON object with "state", "panel", "icons" keys). *)
let rec render_element ~packing ~ctx (el : Yojson.Safe.t) =
  if not (is_visible el ctx) then ()
  else
  let open Yojson.Safe.Util in
  (* Handle repeat directive: expand template for each item in source *)
  match el |> member "foreach", el |> member "do" with
  | `Assoc _, template when template <> `Null ->
    render_repeat ~packing ~ctx el
  | _ ->
  let etype = el |> member "type" |> to_string_option |> Option.value ~default:"placeholder" in
  (* Template-expanded fill_stroke_widget: post-expansion the node's
     [type] is [container] (the template's content type), but the
     compiler leaves the [_template] marker so renderers can intercept.
     Without this, the expanded container's children stack as a normal
     column and ignore their [style.position] hints — fill/stroke
     swatches render at full row width instead of overlapping 26x26. *)
  let template_marker = el |> member "_template" |> to_string_option in
  match template_marker, etype with
  | Some "fill_stroke_widget", _ -> render_fill_stroke_widget ~packing ~ctx el
  | _, etype ->
  match etype with
  | "container" | "row" | "col" -> render_container ~packing ~ctx el etype
  | "fill_stroke_widget" -> render_fill_stroke_widget ~packing ~ctx el
  | "color_bar" -> render_color_bar ~packing ~ctx el
  | "grid" -> render_grid ~packing ~ctx el
  | "text" -> render_text ~packing ~ctx el
  | "button" | "icon_button" -> render_button ~packing ~ctx el
  | "slider" -> render_slider ~packing ~ctx el
  | "number_input" -> render_number_input ~packing ~ctx el
  | "text_input" -> render_text_input ~packing ~ctx el
  | "length_input" -> render_length_input ~packing ~ctx el
  | "select" -> render_select ~packing ~ctx el
  | "toggle" | "checkbox" -> render_toggle ~packing ~ctx el
  | "combo_box" -> render_combo_box ~packing ~ctx el
  | "color_swatch" -> render_color_swatch ~packing ~ctx el
  | "color_gradient" -> render_color_gradient ~packing ~ctx el
  | "color_hue_bar" -> render_color_hue_bar ~packing ~ctx el
  | "radio_group" -> render_radio_group ~packing ~ctx el
  | "gradient_tile" -> render_gradient_tile ~packing ~ctx el
  | "gradient_slider" -> render_gradient_slider ~packing ~ctx el
  | "separator" -> render_separator ~packing el
  | "spacer" -> render_spacer ~packing ()
  | "disclosure" -> render_disclosure ~packing ~ctx el
  | "panel" -> render_panel ~packing ~ctx el
  | "tree_view" -> render_tree_view ~packing ~ctx el
  | "element_preview" -> render_element_preview ~packing el
  | "dropdown" -> render_layers_filter_dropdown ~packing el
  | "tabs" -> render_tabs ~packing ~ctx el
  | "icon" -> render_icon ~packing el
  | "icon_select" -> render_icon_select ~packing ~ctx el
  | _ -> render_placeholder ~packing el

and render_container ~packing ~ctx el etype =
  let open Yojson.Safe.Util in
  let layout_dir = el |> member "layout" |> to_string_option |> Option.value ~default:"column" in
  let is_row = layout_dir = "row" || etype = "row" in
  let gap = el |> member "style" |> safe_member "gap" |> to_int_option |> Option.value ~default:0 in
  (* Explicit [style.width] / [style.height] on the container itself —
     used by spacer containers (empty children, fixed width) inserted
     to align widgets across rows. Without honouring these, an empty
     container collapses to 0 px and adjacent widgets pack tight,
     breaking the column-alignment the spacer was meant to establish
     (e.g. cp_hex_row's 108-px spacer below the slider rows). *)
  let explicit_width =
    el |> member "style" |> safe_member "width" |> to_number_option
    |> Option.map int_of_float in
  let explicit_height =
    el |> member "style" |> safe_member "height" |> to_number_option
    |> Option.map int_of_float in
  if is_row then begin
    (* Bootstrap-style 12-column grid: when row children declare
       ``col: N`` weights, lay them out in a GtkGrid with
       column_homogeneous = true so each column is exactly 1/12 of
       the row's actual width. Children are attached with
       ``width = N`` so col-2 spans 2 grid columns, col-12 spans
       all 12, etc. Every row that uses the same col layout aligns
       its widgets at the same x positions across rows — that's
       the "all icons line up in column 1" property the dock
       panels rely on. Falls back to plain hbox for rows without
       any col-N children (toolbar-like adjacent buttons). *)
    let children = match el |> member "children" with
      | `List xs -> xs | _ -> [] in
    let weights = List.map (fun c ->
      c |> member "col" |> to_int_option |> Option.value ~default:0
    ) children in
    let any_weighted = List.exists (fun w -> w > 0) weights in
    if any_weighted then begin
      let grid = GPack.grid
        ~col_homogeneous:true
        ~col_spacings:gap
        ~packing:(packing) ()
      in
      (* Pin grid + cells to 1px minimum. Do NOT set hexpand on the
         grid: when the grid expands to fill parent, GTK reports the
         expanded width as its preferred size, which propagates up
         the chain (vbox → dock_box → pane_container) and pushes the
         dock pane open well past its set_size_request. Without
         hexpand the grid sizes to its natural request
         (≈ 12 × max(child natural / span)), and the parent vbox
         allocates each row that width — every row ends up the same
         width as the widest, giving the column alignment we want. *)
      grid#misc#set_size_request ~width:1 ();
      let col_cursor = ref 0 in
      List.iter2 (fun child weight ->
        let span = if weight > 0 then weight else 1 in
        let cell = GPack.hbox () in
        cell#misc#set_size_request ~width:1 ();
        (* Honour the per-cell `style.alignment` hint. "start" packs
           the rendered child without fill so it sits at its natural
           size on the left of the cell; otherwise the child fills
           the cell (default — its own halign decides). *)
        let child_align =
          child |> member "style" |> safe_member "alignment"
          |> to_string_option |> Option.value ~default:"" in
        let cell_pack =
          if child_align = "start"
          then cell#pack ~expand:false ~fill:false
          else cell#pack ~expand:true ~fill:true in
        render_element ~packing:cell_pack ~ctx child;
        grid#attach ~left:!col_cursor ~top:0 ~width:span cell#coerce;
        col_cursor := !col_cursor + span
      ) children weights;
      (* Pad to a full 12 columns when the row's weights sum to less.
         GtkGrid only counts columns that have a child; without this
         filler a partial row (e.g. col-1 + col-5 = 6) would render
         as a 6-column homogeneous grid, doubling each col's width
         and misaligning with rows that fill all 12. Attach a
         narrow visible label (an hbox alone may not be considered
         present for column-allocation purposes). *)
      if !col_cursor < 12 then begin
        let last = !col_cursor in
        let pad_span = 12 - last in
        let filler = GMisc.label ~text:"" () in
        filler#misc#set_size_request ~width:1 ();
        grid#attach ~left:last ~top:0 ~width:pad_span filler#coerce
      end
    end
    else begin
      let alignment =
        el |> member "style" |> safe_member "alignment" |> to_string_option
        |> Option.value ~default:"" in
      let hbox = GPack.hbox ~spacing:gap ~packing () in
      (match explicit_width, explicit_height with
       | Some w, Some h -> hbox#misc#set_size_request ~width:w ~height:h ()
       | Some w, None -> hbox#misc#set_size_request ~width:w ()
       | None, Some h -> hbox#misc#set_size_request ~width:1 ~height:h ()
       | None, None -> hbox#misc#set_size_request ~width:1 ());
      let row_expand = alignment = "space-between" in
      (* Per-child expand: when a child declares ``style.flex: N``
         (any positive number), it greedily fills any remaining row
         space — matches CSS flex: N semantics for the slider_row
         template (slider's flex:1 spans the gap between label and
         number_input). Other children pack at natural size. *)
      (* Pack all children flush at natural size — no flex.
         Sliders set their own width via set_size_request (~100px),
         and other widgets (label, number_input, unit text) keep
         their declared widths. expand=true centred a fixed-width
         slider inside its slack, leaving visible gaps between
         label and slider / slider and number_input. *)
      List.iter (fun child ->
        render_element ~packing:(hbox#pack ~expand:row_expand ~fill:false) ~ctx child
      ) (match el |> member "children" with
         | `List xs -> xs | _ -> [])
    end
  end else begin
    let vbox = GPack.vbox ~spacing:gap ~packing () in
    (match explicit_width, explicit_height with
     | Some w, Some h -> vbox#misc#set_size_request ~width:w ~height:h ()
     | Some w, None -> vbox#misc#set_size_request ~width:w ()
     | None, Some h -> vbox#misc#set_size_request ~width:(-1) ~height:h ()
     | None, None -> ());
    render_children ~packing:(vbox#pack ~expand:false ~fill:false) ~ctx el
  end

and render_grid ~packing ~ctx el =
  let open Yojson.Safe.Util in
  (* True 2-D grid: each child declares its cell via ``grid: { row, col }``
     and we attach it with [grid#attach ~left:col ~top:row]. The toolbar's
     [tool_grid] is the only ``type: grid`` node in the whole workspace, so
     this path is toolbar-isolated. ``cols`` defaults to 2; ``gap`` controls
     row/col spacing. Mirrors the Rust grid handling
     (jas_dioxus/src/interpreter/renderer.rs). *)
  let _cols = el |> member "cols" |> to_int_option |> Option.value ~default:2 in
  let gap = el |> member "gap" |> to_int_option |> Option.value ~default:2 in
  let grid = GPack.grid ~row_spacings:gap ~col_spacings:gap ~packing () in
  let children = match el |> member "children" with
    | `List xs -> xs | _ -> [] in
  let fallback = ref 0 in
  List.iter (fun child ->
    if is_visible child ctx then begin
      let cell = child |> member "grid" in
      let row = cell |> member "row" |> to_int_option in
      let col = cell |> member "col" |> to_int_option in
      let row, col = match row, col with
        | Some r, Some c -> r, c
        | _ ->
          (* No explicit cell — flow into the next slot left-to-right,
             top-to-bottom using the declared column count. *)
          let n = !fallback in
          incr fallback;
          (n / _cols), (n mod _cols)
      in
      let holder = GPack.hbox () in
      render_element ~packing:(holder#pack ~expand:false ~fill:false) ~ctx child;
      grid#attach ~left:col ~top:row holder#coerce
    end
  ) children

and render_text ~packing ~ctx el =
  let open Yojson.Safe.Util in
  let content = el |> member "content" |> to_string_option |> Option.value ~default:"" in
  let text = if String.length content > 0 && (try let _ = String.index content '{' in true with Not_found -> false)
    then Expr_eval.evaluate_text content ctx
    else content in
  let style = el |> member "style" in
  (* style.color may be a literal hex or a {{theme.colors.X}} token;
     evaluate_text resolves both. Default to the active appearance's
     text color when unspecified — without this, slider-row labels
     (slider_row template doesn't pass color) inherit the GTK
     theme's default label color and stay light against the Light
     Gray appearance's pale bg (CLR-262). Routed through
     [theme_text_hook] to avoid a Yaml_panel_view ↔ Dock_panel cycle. *)
  let color = match style |> safe_member "color" |> to_string_option with
    | Some s when String.length s > 0 ->
      (try Expr_eval.evaluate_text s ctx with _ -> s)
    | _ -> !theme_text_hook () in
  let font_size = style |> safe_member "font_size" |> to_number_option in
  let attr_color =
    (* Be defensive: evaluate_text on a {{theme.colors.X}} token can
       yield a non-#rrggbb string if the token doesn't resolve.
       Strip a leading # and accept 6-hex-digit input; otherwise
       fall back to the dark-theme text color. *)
    let raw = if String.length color > 0 && color.[0] = '#'
      then String.sub color 1 (String.length color - 1) else color in
    let raw = if String.length raw = 3 then
        let c0 = String.make 1 raw.[0] in
        let c1 = String.make 1 raw.[1] in
        let c2 = String.make 1 raw.[2] in
        c0 ^ c0 ^ c1 ^ c1 ^ c2 ^ c2
      else raw in
    let parsed =
      if String.length raw = 6 then
        try
          let r = int_of_string ("0x" ^ String.sub raw 0 2) in
          let g = int_of_string ("0x" ^ String.sub raw 2 2) in
          let b = int_of_string ("0x" ^ String.sub raw 4 2) in
          Some (r, g, b)
        with _ -> None
      else None
    in
    let (r, g, b) = match parsed with
      | Some t -> t
      | None -> (0xcc, 0xcc, 0xcc) in
    Printf.sprintf "color=\"#%02x%02x%02x\"" r g b
  in
  let attr_size = match font_size with
    | Some n -> Printf.sprintf " font_size=\"%d\"" (int_of_float n * 1024)
    | None -> ""
  in
  let escape s =
    let buf = Buffer.create (String.length s) in
    String.iter (fun c -> match c with
      | '<' -> Buffer.add_string buf "&lt;"
      | '>' -> Buffer.add_string buf "&gt;"
      | '&' -> Buffer.add_string buf "&amp;"
      | '"' -> Buffer.add_string buf "&quot;"
      | c -> Buffer.add_char buf c
    ) s;
    Buffer.contents buf
  in
  let markup = Printf.sprintf "<span %s%s>%s</span>" attr_color attr_size (escape text) in
  (* A [type: text] element may carry a [behavior] array (e.g. the
     Symbols / Artboards panel row labels select the row on click). The
     plain GMisc.label has no input window, so when behaviors are present
     wrap it in an event_box and dispatch the click behaviors — the same
     generic gesture the icon_button / color-swatch paths use. Labels
     without a behavior render exactly as before. *)
  let has_click_behavior =
    match el |> member "behavior" with
    | `List bs ->
      List.exists (fun b ->
        (b |> member "event" |> to_string_option) = Some "click") bs
    | _ -> false in
  if has_click_behavior && !_current_panel_id <> None then begin
    let evt = GBin.event_box ~packing () in
    let lbl = GMisc.label ~markup ~packing:evt#add () in
    lbl#set_xalign 0.0;
    evt#event#add [`BUTTON_PRESS];
    ignore (evt#event#connect#button_press ~callback:(fun ev ->
      if GdkEvent.Button.button ev = 1 then begin
        (* Rebuild panel/state from the live store before dispatch so
           the click sees current panel.selected_symbol (mirrors the
           color-swatch click_ctx refresh). *)
        let click_ctx =
          match !_current_store, !_current_panel_id, ctx with
          | Some store, Some pid, `Assoc pairs ->
            let live_panel = State_store.get_panel_state store pid in
            let live_state = State_store.get_all store in
            let pairs' = List.filter
              (fun (k, _) -> k <> "panel" && k <> "state") pairs in
            `Assoc (("panel", `Assoc live_panel)
                    :: ("state", `Assoc live_state) :: pairs')
          | _ -> ctx in
        let wrote_state = dispatch_click_behaviors el click_ctx in
        if wrote_state then schedule_panel_rerender ();
        true
      end else false))
  end else begin
    let lbl = GMisc.label ~markup ~packing () in
    lbl#set_xalign 0.0
  end

and render_icon ~packing el =
  let open Yojson.Safe.Util in
  let icon_name = el |> member "name" |> to_string_option |> Option.value ~default:"" in
  let style = el |> member "style" in
  let size = match style |> safe_member "width" |> to_number_option with
    | Some n -> int_of_float n
    | None -> (match style |> safe_member "size" |> to_number_option with
               | Some n -> int_of_float n | None -> 16) in
  let opacity = style |> safe_member "opacity" |> to_number_option |> Option.value ~default:1.0 in
  if icon_name = "" then ()
  else begin
    try
      let pb = Workspace_icon.pixbuf_for_name icon_name size "#cccccc" in
      let img = GMisc.image ~pixbuf:pb ~packing () in
      if opacity < 1.0 then img#set_opacity opacity
    with _ -> ()
  end

and render_icon_select ~packing ~ctx el =
  let open Yojson.Safe.Util in
  let icon_name = el |> member "icon" |> to_string_option |> Option.value ~default:"" in
  let style = el |> member "style" in
  let icon_size = match style |> safe_member "height" |> to_number_option with
    | Some n -> int_of_float n
    | None -> 20 in
  let btn_w = match style |> safe_member "width" |> to_number_option with
    | Some n -> int_of_float n | None -> 48 in
  let btn_h = match style |> safe_member "height" |> to_number_option with
    | Some n -> int_of_float n | None -> 26 in
  let options = match el |> member "options" with `List l -> l | _ -> [] in
  let bind_expr = el |> member "bind" |> safe_member "value" |> to_string_option in
  let disabled = match el |> member "bind" |> safe_member "disabled" |> to_string_option with
    | Some expr -> Expr_eval.to_bool (Expr_eval.evaluate expr ctx)
    | None -> false in
  let btn = GButton.button ~packing ~relief:`NONE () in
  btn#misc#set_sensitive (not disabled);
  btn#misc#set_size_request ~width:btn_w ~height:btn_h ();
  btn#set_valign `CENTER;
  (match (try Some (Workspace_icon.pixbuf_for_name icon_name icon_size "#cccccc") with _ -> None) with
   | Some pb ->
     let img = GMisc.image ~pixbuf:pb () in
     btn#set_image img#coerce
   | None -> ());
  let css =
    "button { min-width: 0; min-height: 0; padding: 2px; \
     border: 1px solid #555; border-radius: 3px; \
     background: #3a3a3a; box-shadow: none; }" in
  let provider = GObj.css_provider () in
  provider#load_from_data css;
  btn#misc#style_context#add_provider provider 800;
  ignore (btn#connect#clicked ~callback:(fun () ->
    let menu = GMenu.menu () in
    List.iter (fun opt ->
      let label, value = match opt with
        | `Assoc _ ->
          let glyph = opt |> member "glyph" |> to_string_option in
          let lbl = opt |> member "label" |> to_string_option |> Option.value ~default:"" in
          let display = match glyph with
            | Some g -> Printf.sprintf "%s  %s" g lbl
            | None -> lbl in
          let v = opt |> member "value" |> to_string_option |> Option.value ~default:"" in
          (display, v)
        | `String s -> (s, s)
        | _ -> ("", "") in
      let mi = GMenu.menu_item ~label ~packing:menu#append () in
      ignore (mi#connect#activate ~callback:(fun () ->
        match bind_expr with
        | Some expr -> _write_back_bind expr (`String value)
        | None -> ()))
    ) options;
    menu#misc#show_all ();
    menu#popup ~button:1 ~time:(GtkMain.Main.get_current_event_time ())))

and render_button ~packing ~ctx el =
  let open Yojson.Safe.Util in
  let etype = el |> member "type" |> to_string_option |> Option.value ~default:"button" in
  let static_label = el |> member "label" |> to_string_option
    |> Option.value ~default:(el |> member "summary" |> to_string_option |> Option.value ~default:"") in
  (* bind.label: expression whose evaluated string replaces the
     static label. op_make_mask uses this to flip between
     "Make Mask" and "Release" based on selection_has_mask per
     OPACITY.md §States. *)
  let label = match el |> member "bind" |> safe_member "label" |> to_string_option with
    | Some expr ->
      (match Expr_eval.evaluate expr ctx with
       | Expr_eval.Str s -> s
       | _ -> static_label)
    | None -> static_label in
  (* For ``icon_button`` widgets, try to render the SVG glyph from
     workspace icons.yaml. ``bind.icon`` is an expression returning
     the icon name (e.g. ``chain_linked`` / ``chain_broken``);
     ``icon`` is a static name. Falls back to the text-label button
     when the icon can't be resolved or the renderer doesn't support
     the icon's primitives. *)
  let icon_pixbuf : GdkPixbuf.pixbuf option =
    if etype <> "icon_button" then None
    else begin
      let icon_name = match el |> member "bind" |> safe_member "icon" |> to_string_option with
        | Some expr ->
          (match Expr_eval.evaluate expr ctx with
           | Expr_eval.Str s -> s
           | _ -> el |> member "icon" |> to_string_option |> Option.value ~default:"")
        | None -> el |> member "icon" |> to_string_option |> Option.value ~default:""
      in
      if icon_name = "" then None
      else begin
        let size =
          match resolve_size_token (el |> member "style" |> safe_member "size") with
          | Some n -> n
          | None -> 20
        in
        (* Hardcoded tint matches the Dark Gray theme's text color
           (#cccccc). Threading the active theme into yaml_panel_view
           is a future polish — would require either a separate
           Theme_active module or threading the color through every
           render_element call site. *)
        try Some (Workspace_icon.pixbuf_for_name icon_name size "#cccccc")
        with _ -> None
      end
    end
  in
  let btn = match icon_pixbuf with
    | Some pb ->
      let img = GMisc.image ~pixbuf:pb () in
      let b = GButton.button ~packing ~relief:`NONE () in
      b#set_image img#coerce;
      b#misc#set_tooltip_text label;
      b
    | None ->
      GButton.button ~label ~packing ()
  in
  (* Icon buttons declare a [style.size] (typically 16–24px). Without
     [set_size_request], the GtkButton inflates to the theme's natural
     button height (~30px on Adwaita) — visible in CLR-002 OCaml as
     the fill_stroke_widget swap/reset/mode buttons bursting out of
     their declared 19px / 15px boxes. Also drop the default theme
     padding via CSS so the icon image fills the requested size
     instead of leaving a ~6px frame around it. *)
  if etype = "icon_button" then begin
    let size =
      match resolve_size_token (el |> member "style" |> safe_member "size") with
      | Some n -> n
      | None -> 20
    in
    btn#misc#set_size_request ~width:size ~height:size ();
    (* bind.checked highlight: an icon_button with a truthy
       ``bind.checked`` expression renders with a filled background so
       the active state is visible. The toolbar's tool buttons use this
       to show which tool is selected (``state.active_tool == "..."``).
       The checked color comes from ``style.checked_bg`` when it resolves
       to a literal hex, else a sensible default. Toolbar STEP A. *)
    let checked = match el |> member "bind" |> safe_member "checked"
                        |> to_string_option with
      | Some expr -> Expr_eval.to_bool (Expr_eval.evaluate expr ctx)
      | None -> false in
    let checked_bg =
      match el |> member "style" |> safe_member "checked_bg"
            |> to_string_option with
      | Some s when String.length s > 0 && s.[0] = '#' -> s
      | _ -> "#4a4a4a" in
    let provider = GObj.css_provider () in
    let bg = if checked then checked_bg else "transparent" in
    provider#load_from_data
      (Printf.sprintf
         "button { padding: 0; margin: 0; min-width: 0; min-height: 0; \
          border: 0; background: %s; }" bg);
    btn#misc#style_context#add_provider provider 800
  end;
  (* style.opacity < 1.0 — render the button dimmed AND insensitive.
     Used by the color picker's "Color Swatches" button as a yaml
     placeholder (CLR-231). Mirrors the Rust placeholder rendering.
     lablgtk3's misc_ops doesn't expose set_opacity, so route through
     a CSS provider against the button's style context. *)
  (match el |> member "style" |> safe_member "opacity" |> to_number_option with
   | Some o when o < 1.0 ->
     let provider = GObj.css_provider () in
     provider#load_from_data
       (Printf.sprintf "button { opacity: %.3f; }" o);
     btn#misc#style_context#add_provider provider 900;
     btn#misc#set_sensitive false
   | _ -> ());
  (* Opacity panel: op_make_mask dispatches controller make or
     release based on selection_has_mask. The button has no
     ``action`` in yaml — routing is resolved here against the
     panel id and the element id. Mirrors the Rust and Swift
     special-cases. *)
  let id = el |> member "id" |> to_string_option |> Option.value ~default:"" in
  (* bind.disabled: grey the button out. Used by op_link_indicator
     to disable while the selection has no mask. *)
  let disabled = match el |> member "bind" |> safe_member "disabled" |> to_string_option with
    | Some expr -> Expr_eval.to_bool (Expr_eval.evaluate expr ctx)
    | None -> false in
  btn#misc#set_sensitive (not disabled);
  if !_current_panel_id = Some "opacity_panel_content" && id = "op_make_mask" then begin
    ignore (btn#connect#clicked ~callback:(fun () ->
      match !_get_model_ref () with
      | None -> ()
      | Some m ->
        let doc = m#document in
        let has_mask = Controller.selection_has_mask doc in
        let ctrl = new Controller.controller ~model:m () in
        if has_mask then ctrl#release_mask_on_selection
        else
          (* clip / invert come from the panel state store's
             new_masks_clipping / new_masks_inverted keys (seeded
             from the yaml defaults). *)
          let bool_of_store key default = match !_current_store with
            | Some s ->
              (match State_store.get_panel s "opacity_panel_content" key with
               | `Bool b -> b
               | _ -> default)
            | None -> default in
          let clip = bool_of_store "new_masks_clipping" true in
          let invert = bool_of_store "new_masks_inverted" false in
          ctrl#make_mask_on_selection ~clip ~invert))
  end;
  (* Opacity panel: op_link_indicator toggles mask.linked on every
     selected mask via Controller. OPACITY.md \167Document model.
     Mirrors the Rust and Swift special-cases. *)
  if !_current_panel_id = Some "opacity_panel_content" && id = "op_link_indicator" then begin
    ignore (btn#connect#clicked ~callback:(fun () ->
      match !_get_model_ref () with
      | None -> ()
      | Some m ->
        let ctrl = new Controller.controller ~model:m () in
        ctrl#toggle_mask_linked_on_selection))
  end;
  (* Behavior-array click dispatch (icon_buttons in panels: the color
     panel's cp_none_swatch uses ``behavior: [event: click, action:
     set_active_color_none]`` rather than the top-level ``action:``
     form below). Skip in dialog context — dialog buttons go through
     the top-level ``action:`` path which routes via Dialog_global. *)
  if etype = "icon_button" && !_current_panel_id <> None then begin
    ignore (btn#connect#clicked ~callback:(fun () ->
      let wrote_state = dispatch_click_behaviors el ctx in
      (* Only redraw if a [set:] effect actually changed panel-bound
         state; action-only dispatches let the model+canvas refresh
         pipeline do the work without a flickery dock rebuild. *)
      if wrote_state then schedule_panel_rerender ()))
  end;
  (* Long-press tool-alternates flyout (toolbar). A slot button declares
     [mouse_down] -> start_timer(250ms) -> open_dialog, and
     [mouse_up] -> cancel_timer. The [click] behavior (select_tool)
     still fires on a quick press+release because the press/release
     callbacks return [false] (don't consume the event), so the
     GtkButton's own [clicked] signal proceeds.
       - mouse_down arms the timer; if held 250ms the timer's nested
         [open_dialog: { id: <slot>_alternates }] fires.
       - The [open_dialog] platform handler below routes that to the
         non-modal flyout opener (the built-in Effects.open_dialog only
         seeds State_store). Scoped to the timer's effects run, so
         panels/dialogs that use the built-in open_dialog are
         unaffected.
       - mouse_up cancels a not-yet-fired timer, so a fast click never
         leaves a stray timer and never pops the flyout.
     Only wired when the element actually declares mouse_down/mouse_up
     behaviors, so ordinary panel buttons keep their plain click path. *)
  let behavior_for_event ev_name =
    match el |> member "behavior" with
    | `List bs ->
      List.filter_map (fun b ->
        if (b |> member "event" |> to_string_option) = Some ev_name then
          match b |> member "effects" with
          | `List effs -> Some effs
          | _ -> None
        else None) bs
      |> List.concat
    | _ -> []
  in
  let mouse_down_effects = behavior_for_event "mouse_down" in
  let mouse_up_effects = behavior_for_event "mouse_up" in
  if mouse_down_effects <> [] || mouse_up_effects <> [] then begin
    (* [open_dialog] platform handler: pop the flyout window for a
       NON-MODAL ([modal: false]) dialog via the hook (set in main.ml
       against Yaml_dialog_view.show_nonmodal_dialog). This handler is
       scoped to this slot button's mouse_down/up effects run only, so
       the built-in Effects.open_dialog used by panels/dialogs (modal
       color_picker / tool-options flows) is untouched. A toolbar
       long-press only ever targets a ``modal: false`` alternates
       dialog; were it ever to fire a modal one, this would no-op
       (rather than open it) — acceptable since that path is unused
       here. *)
    let open_dialog_h : Effects.platform_effect = fun value _ctx _store ->
      let dlg_id = match value with
        | `Assoc d ->
          (match List.assoc_opt "id" d with Some (`String s) -> s | _ -> "")
        | `String s -> s
        | _ -> "" in
      let is_non_modal =
        match Workspace_loader.load () with
        | Some ws ->
          (match Workspace_loader.dialog ws dlg_id with
           | Some (`Assoc dlg_def) ->
             (match List.assoc_opt "modal" dlg_def with
              | Some (`Bool b) -> not b
              | _ -> false)  (* dialogs default to modal *)
           | _ -> false)
        | None -> false in
      if dlg_id <> "" && is_non_modal then
        !open_nonmodal_dialog_hook dlg_id [];
      `Null
    in
    let live_store = match !_current_store with
      | Some s -> s | None -> State_store.create () in
    let ctx_pairs = match ctx with `Assoc p -> p | _ -> [] in
    let run effs =
      if effs <> [] then
        Effects.run_effects
          ~platform_effects:[("open_dialog", open_dialog_h)]
          effs ctx_pairs live_store
    in
    ignore (btn#event#connect#button_press ~callback:(fun ev ->
      if GdkEvent.Button.button ev = 1 then run mouse_down_effects;
      (* Return false: do NOT consume — the GtkButton still emits
         [clicked] for a quick press+release (select_tool). *)
      false));
    ignore (btn#event#connect#button_release ~callback:(fun ev ->
      if GdkEvent.Button.button ev = 1 then run mouse_up_effects;
      false))
  end;
  (* Inline behavior dispatch for buttons in dialogs (Color Picker
     OK button writes [if param.target == fill then set fill_color
     = dialog.color else set stroke_color = dialog.color; close_dialog]
     directly inline rather than naming an action). Route through
     Effects.run_effects so [if] / [set] / [close_dialog] all work,
     using the Color panel's store so its subscribe_active_color
     bridge picks up the fill_color / stroke_color writes and pushes
     them into the model + selection. *)
  if !Dialog_global.current_id <> None then begin
    match el |> member "behavior" with
    | `List behaviors when behaviors <> [] ->
      let rec has_close_dialog effects =
        List.exists (fun e ->
          match e with
          | `Assoc fields when List.mem_assoc "close_dialog" fields -> true
          | `Assoc fields ->
            (* close_dialog can also live inside if/then/else branches. *)
            (match List.assoc_opt "if" fields with
             | Some (`Assoc cond) ->
               let then_ = match List.assoc_opt "then" cond with
                 | Some (`List l) -> l | _ -> [] in
               let else_ = match List.assoc_opt "else" cond with
                 | Some (`List l) -> l | _ -> [] in
               has_close_dialog then_ || has_close_dialog else_
             | _ ->
               (match List.assoc_opt "then" fields with
                | Some (`List l) -> has_close_dialog l
                | _ -> false))
          | _ -> false
        ) effects in
      ignore (btn#connect#clicked ~callback:(fun () ->
        btn#misc#grab_focus ();
        List.iter (fun b ->
          let event = b |> member "event" |> to_string_option
                      |> Option.value ~default:"" in
          if event = "click" then begin
            (* Intercept any ``set: { active_tool: <expr> }`` effects
               and dispatch through [set_active_tool_hook] — the color
               picker's eyedropper writes the tool name this way to
               switch the canvas's active tool. The store-write done
               by [Effects.run_effects] would otherwise land in the
               Color panel's store, which doesn't drive the canvas. *)
            let live_ctx = !Dialog_global.current_build_ctx () in
            (match b |> member "effects" with
             | `List effects ->
               List.iter (fun e ->
                 match e with
                 | `Assoc fields ->
                   (match List.assoc_opt "set" fields with
                    | Some (`Assoc set_pairs) ->
                      (match List.assoc_opt "active_tool" set_pairs with
                       | Some (`String expr_str) ->
                         let v = Expr_eval.evaluate expr_str live_ctx in
                         let name = (match v with
                           | Expr_eval.Str s -> s
                           | _ -> "") in
                         if name <> "" then !set_active_tool_hook name
                       | _ -> ())
                    | _ -> ())
                 | _ -> ()
               ) effects
             | _ -> ());
            (match b |> member "effects" with
            | `List effects ->
              let ctx_pairs = match live_ctx with
                | `Assoc p -> p | _ -> [] in
              let store =
                match Panel_menu.lookup_panel_store "color_panel_content" with
                | Some s -> s
                | None -> State_store.create () in
              Effects.run_effects effects ctx_pairs store;
              (* Effects.run_effects's [close_dialog] handler only
                 clears State_store dialog state; the GTK dialog
                 window stays open without an explicit close. *)
              if has_close_dialog effects then Dialog_global.close ();
              (* Color picker OK: push the committed color into the
                 model's recent_colors list. The fill_color /
                 stroke_color set effect lands in
                 [subscribe_active_color] which updates the default
                 fill/stroke and selection but does NOT push to
                 recent — that lives in [Panel_menu.push_recent_color]
                 and is called by the panel own commit paths.
                 Without this, OK silently skips the recent strip.
                 Mirrors the Rust [renderer.rs] color picker OK
                 push_recent branch. *)
              if !Dialog_global.current_id = Some "color_picker" then begin
                let dialog_color =
                  Expr_eval.evaluate "dialog.color" live_ctx in
                let hex_opt = match dialog_color with
                  | Expr_eval.Color c -> Some c
                  | Expr_eval.Str s when String.length s > 0 && s.[0] = '#' ->
                    Some s
                  | _ -> None in
                match hex_opt, !_get_model_ref () with
                | Some hex, Some m ->
                  let hex_no_hash =
                    if String.length hex > 0 && hex.[0] = '#'
                    then String.sub hex 1 (String.length hex - 1)
                    else hex in
                  Panel_menu.push_recent_color hex_no_hash m
                | _ -> ()
              end;
              update_color_panel_widgets ()
            | _ -> ());
            (* Behavior-level ``action:`` — the eyedropper declares
               ``action: dismiss_dialog`` alongside its set-tool
               effect; the top-level ``action:`` handler below only
               sees element-level [el.action], so without this
               in-line dispatch the dialog stays open after the
               tool switch. *)
            (match b |> member "action" |> to_string_option with
             | Some "dismiss_dialog" -> Dialog_global.close ()
             | Some other when other <> "" ->
               Dialog_global.dispatch_action other []
                 (match !_get_model_ref () with
                  | Some m -> Some (new Controller.controller ~model:m ())
                  | None -> None)
                 (fun () -> Dialog_global.close ())
             | _ -> ())
          end
        ) behaviors))
    | _ -> ()
  end;
  (* Generic ``action: <name>`` dispatch — used by dialog buttons
     (OK / Done / Print / Cancel / icon-button toggles). Resolves
     ``params`` against the live dialog ctx (so values typed into
     number_input fields after the dialog rendered are reflected),
     then routes through [Yaml_dialog_view.dispatch_action], which
     special-cases ``dismiss_dialog`` and otherwise runs the named
     action's effects with the dialog-appropriate platform_effects
     (snapshot / doc.set_*_field / close_dialog / etc.). *)
  match el |> member "action" |> to_string_option with
  | Some action_name when action_name <> "" ->
    let raw_params = match el |> member "params" with
      | `Assoc pairs -> pairs
      | _ -> []
    in
    ignore (btn#connect#clicked ~callback:(fun () ->
      (* Force the currently-focused entry to commit BEFORE we read
         dialog/panel state. Without this, a user who types "60" into
         a number_input and clicks OK without tabbing out leaves the
         entry's typed value uncommitted — focus-out fires too late
         (after this clicked handler) so the action runs against the
         stale default value. Grabbing focus to the button forces any
         pending entry's focus-out commit handler to run synchronously
         right now. *)
      btn#misc#grab_focus ();
      let live_ctx = !Dialog_global.current_build_ctx () in
      let resolved = List.map (fun (k, v) ->
        match v with
        | `String expr_str ->
          let result = Expr_eval.evaluate expr_str live_ctx in
          (k, Effects.value_to_json result)
        | other -> (k, other)
      ) raw_params in
      let ctrl_opt = match !_get_model_ref () with
        | Some m -> Some (new Controller.controller ~model:m ())
        | None -> None
      in
      Dialog_global.dispatch_action action_name resolved ctrl_opt
        Dialog_global.close))
  | _ -> ()

and render_slider ~packing ~ctx el =
  let open Yojson.Safe.Util in
  let min_val = el |> member "min" |> to_number_option |> Option.value ~default:0.0 in
  let max_val = el |> member "max" |> to_number_option |> Option.value ~default:100.0 in
  let step = el |> member "step" |> to_number_option |> Option.value ~default:1.0 in
  let bind_expr = el |> member "bind" |> safe_member "value" |> to_string_option
                  |> Option.value ~default:"" in
  let initial = if bind_expr <> "" then
      match Expr_eval.evaluate bind_expr ctx with
      | Expr_eval.Number n -> n
      | _ -> min_val
    else min_val in
  (* lablgtk3's GData.adjustment defaults page_size to 10 (matching
     the GtkScrollbar conventions), which clamps the GtkScale's
     reachable max to (upper - page_size) — so an H slider with
     upper=359 stops at 349 unless we pin page_size:0. *)
  let adj = GData.adjustment ~lower:min_val ~upper:max_val
              ~step_incr:step ~page_size:0.0 ~value:initial () in
  let scale = GRange.scale `HORIZONTAL ~adjustment:adj ~draw_value:false ~packing () in

  (* Per-channel gradient on the trough. Channel comes from the
     panel.X bind expression (slider_row template wraps each color
     channel as bind: panel.h / panel.s / panel.b / panel.r / etc.).
     The gradients here are a simplified, channel-only ramp — Rust
     and Swift mix in the other channels' current values for a
     more accurate preview, but a fixed ramp still gives the
     "where am I in the channel range" cue that's the user's
     reason for wanting a track. *)
  let channel = match bind_expr with
    | s when String.length s > 6 && String.sub s 0 6 = "panel." ->
      String.sub s 6 (String.length s - 6)
    | _ -> ""
  in
  let gradient = match channel with
    | "h" -> "linear-gradient(to right, #f00, #ff0, #0f0, #0ff, #00f, #f0f, #f00)"
    | "s" -> "linear-gradient(to right, #888, #f00)"
    | "b" -> "linear-gradient(to right, #000, #fff)"
    | "r" -> "linear-gradient(to right, #000, #f00)"
    | "g" -> "linear-gradient(to right, #000, #0f0)"
    | "bl" -> "linear-gradient(to right, #000, #00f)"
    | "c" -> "linear-gradient(to right, #fff, #0ff)"
    | "m" -> "linear-gradient(to right, #fff, #f0f)"
    | "y" -> "linear-gradient(to right, #fff, #ff0)"
    | "k" -> "linear-gradient(to right, #fff, #000)"
    | _ -> "linear-gradient(to right, #888, #ccc)"
  in
  let css = Printf.sprintf
    "scale { padding: 0 5px; margin: 0 4px; min-height: 12px; } \
     scale trough { min-height: 8px; background-image: %s; \
       border: 1px solid #444; border-radius: 2px; } \
     scale trough highlight, scale highlight { \
       background-image: none; background-color: transparent; \
       border: 0; box-shadow: none; } \
     scale slider { min-width: 10px; min-height: 12px; \
       background: #ccc; border: 1px solid #222; \
       border-radius: 2px; margin: -2px 0; }"
    gradient in
  let provider = GObj.css_provider () in
  provider#load_from_data css;
  scale#misc#style_context#add_provider provider 800;
  (* Cap the slider at ~100px wide × 12px tall so the gradient track
     stays compact instead of expanding to the full row slack and
     wasting vertical space (CLR-002 OCaml — user feedback "slider
     too wide / too tall"). The row packs each child with
     expand=true, fill=false; the slider centres in its allocation
     at this size. *)
  scale#misc#set_size_request ~width:100 ~height:12 ();

  (* Value changes → live color update. Mirrors the Rust slider's
     oninput → set_active_color_live; final commit on release would
     normally pile through onchange / button-release, but GtkScale
     doesn't expose a "drag end" signal directly. Use [value_changed]
     for the live update; the panel's existing apply chain handles
     selection sync. *)
  let suppress = ref false in
  ignore (adj#connect#value_changed ~callback:(fun () ->
    if !suppress then () else begin
      suppress := true;
      let v = adj#value in
      (* Snap to step. GtkAdjustment's step_incr only governs keyboard
         arrow-key increments — drag motion is unsnapped. Web Safe
         RGB depends on snapping (step=51) to land on the safe palette
         entries. Round-to-nearest mirrors the Rust slider's snap. *)
      let v_snap =
        if step > 0.0 && step <> 1.0 then
          Float.round (v /. step) *. step
        else v in
      if v_snap <> v then adj#set_value v_snap;
      if bind_expr <> "" then
        _write_back_bind bind_expr (`Float v_snap);
      suppress := false
    end));

  (* Subscribe to panel-state updates so the slider thumb tracks
     selection-change / hex-commit / swatch-click updates to the
     active color (update_color_panel_widgets writes panel.h /
     panel.s / panel.b / panel.r / etc. — without this listener the
     slider stays parked at its initial value). [suppress] keeps
     the programmatic adjustment from re-firing the value_changed
     write-back. *)
  (match bind_expr, !_current_store, !_current_panel_id with
   | expr, Some store, Some pid
     when String.length expr > 6 && String.sub expr 0 6 = "panel." ->
     let field = String.sub expr 6 (String.length expr - 6) in
     State_store.subscribe_panel store pid (fun key v ->
       if key = field then begin
         let new_val = match v with
           | `Float f -> Some f
           | `Int i -> Some (float_of_int i)
           | _ -> None in
         match new_val with
         | Some v when v <> adj#value ->
           let prev = !suppress in
           suppress := true;
           Fun.protect ~finally:(fun () -> suppress := prev)
             (fun () -> adj#set_value v)
         | _ -> ()
       end)
   | _ -> ());

  (* Pointer-up commits the final color through
     [Panel_menu.set_active_color] (drag itself goes through
     set_active_color_live — see _write_back_bind for color channels)
     so the recent-colors strip gets exactly one entry per drag
     gesture instead of either zero (live-only) or hundreds
     (one per tick). Mirrors the Rust slider's onchange. Reads the
     current panel state directly so any of the 10 color channels
     can trigger the commit. *)
  (match bind_expr, !_current_store, !_current_panel_id with
   | expr, Some store, Some pid
     when pid = "color_panel_content"
          && String.length expr > 6 && String.sub expr 0 6 = "panel."
          && List.mem (String.sub expr 6 (String.length expr - 6))
               ["h"; "s"; "b"; "r"; "g"; "bl"; "c"; "m"; "y"; "k"] ->
     scale#event#add [`BUTTON_RELEASE];
     ignore (scale#event#connect#button_release ~callback:(fun _ev ->
       commit_color_panel_to_recent store pid;
       false))
   | _ -> ())

and render_number_input ~packing ~ctx el =
  let open Yojson.Safe.Util in
  let min_val = el |> member "min" |> to_number_option |> Option.value ~default:0.0 in
  let max_val = el |> member "max" |> to_number_option |> Option.value ~default:100.0 in
  (* [bind:] supports both forms: a bare string ("dialog.h") and an
     object ({ value: "dialog.h", disabled: "..." }). The color
     picker's number_inputs use the bare-string form via the
     radio_field_row template; without this fallback the picker's
     H/S/B fields never bound at all and never updated on state
     change. *)
  let bind_expr = match el |> member "bind" with
    | `String s -> Some s
    | obj -> obj |> safe_member "value" |> to_string_option in
  let initial = match bind_expr with
    | Some expr ->
      let v = Expr_eval.evaluate expr ctx in
      (match v with Expr_eval.Number n -> n | _ -> min_val)
    | None -> min_val in
  let in_panel = !_current_panel_id <> None in
  if in_panel then begin
    (* Panel context: render as a plain GtkEntry. The spin button's
       +/- steppers add ~50px of natural width which forces every
       Bootstrap-12 column to be that wide, making panels overflow
       the dock pane. The plain entry parses on every keystroke,
       clamps to min/max, and commits on focus-out / Enter — same
       semantics as the spin button minus the visible steppers. *)
    let entry = GEdit.entry ~packing ~text:(Printf.sprintf "%g" initial) () in
    entry#misc#set_size_request ~width:1 ();
    entry#set_width_chars 4;
    (* Slim down the Adwaita default ~30px-tall entry to match the
       12px slider track + slim swatches the row sits in. Without
       this CSS override the value boxes dominate the row height
       (user feedback during CLR-002 OCaml). *)
    let provider = GObj.css_provider () in
    provider#load_from_data
      "entry { min-height: 16px; padding: 1px 4px; }";
    entry#misc#style_context#add_provider provider 800;
    let suppress = ref false in
    let clamp v = max min_val (min max_val v) in
    let commit () =
      match bind_expr, float_of_string_opt (String.trim entry#text) with
      | Some expr, Some v ->
        let cv = clamp v in
        _write_back_bind expr (`Float cv);
        (* Reflect the clamped value back into the entry text so the
           user sees their out-of-range input snapped to a legal value
           (PG-162). [suppress] keeps the resulting [changed] /
           subscriber callbacks from re-firing the commit handlers. *)
        if Float.abs (cv -. v) > 1e-9 then begin
          suppress := true;
          entry#set_text (Printf.sprintf "%g" cv);
          suppress := false
        end;
        (* Color panel channel commit (Enter / Tab / focus-out on
           an H/S/B/etc. value box): _write_back_bind already routed
           the new value through set_active_color_live (no recent
           push). A discrete commit should also push to recent so
           the entry's value lands in the recent-colors strip,
           mirroring slider pointer-up and swatch click. *)
        (match !_current_store, !_current_panel_id with
         | Some st, Some pid
           when pid = "color_panel_content"
                && String.length expr > 6
                && String.sub expr 0 6 = "panel."
                && List.mem (String.sub expr 6 (String.length expr - 6))
                     ["h"; "s"; "b"; "r"; "g"; "bl"; "c"; "m"; "y"; "k"] ->
           commit_color_panel_to_recent st pid
         | _ -> ());
        (* Concepts param editor (and any number_input carrying a change
           behavior): dispatch it with the committed, clamped value as
           [event.value] so set_concept_param re-generates the instance live. *)
        ignore (dispatch_change_behaviors el ctx cv)
      | _ -> ()
    in
    (match bind_expr with
     | Some _ ->
       (* Commit only on Enter / focus-out. Reflowing on every
          keystroke (PG-054) would intermix partial values like
          "-" or "1" into the document and fight the user as they
          type the rest of the number. *)
       ignore (entry#connect#activate ~callback:(fun () ->
         if not !suppress then commit ()));
       ignore (entry#event#connect#focus_out ~callback:(fun _ ->
         if not !suppress then commit (); false))
     | None -> ());
    (* Subscribe to panel-state updates so the entry refreshes when
       the user changes selection or another widget writes the same
       field (PG-055). The [suppress] guard prevents the programmatic
       set_text from re-firing the commit handlers. *)
    let disabled_expr =
      el |> member "bind" |> safe_member "disabled" |> to_string_option in
    let initial_disabled = match disabled_expr with
      | Some expr -> Expr_eval.to_bool (Expr_eval.evaluate expr ctx)
      | None -> false in
    entry#misc#set_sensitive (not initial_disabled);
    (* Dialog scope: subscribe to dialog state changes so the entry
       text follows derived state (e.g. moving the color picker's
       2D gradient writes dialog.s + dialog.b which the H/S/B value
       boxes need to reflect; the s/b setters also rebuild
       dialog.color which the hex entry then reads via get:). *)
    (match bind_expr, !Dialog_global.current_id with
     | Some expr, Some _
       when String.length expr > 7 && String.sub expr 0 7 = "dialog." ->
       Dialog_global.add_state_change_listener (fun () ->
         if not entry#is_focus then begin
           let live_ctx = !Dialog_global.current_build_ctx () in
           let new_text = match Expr_eval.evaluate expr live_ctx with
             | Expr_eval.Number n -> Printf.sprintf "%g" n
             | Expr_eval.Str s -> s
             | _ -> entry#text in
           if entry#text <> new_text then begin
             suppress := true;
             entry#set_text new_text;
             suppress := false
           end
         end)
     | _ -> ());
    (match bind_expr, !_current_store, !_current_panel_id with
     | Some expr, Some store, Some pid
       when (let parts = String.split_on_char '.' expr in
             match parts with "panel" :: _ :: _ -> true | _ -> false) ->
       let field = match String.split_on_char '.' expr with
         | _ :: f :: _ -> f | _ -> "" in
       let _ = expr in
       let _ = pid in
       (* Re-evaluate [disabled] against the current panel state on
          every store change so PG-059 works: when the selection
          changes from area text to point text, the indent fields
          become non-interactive. *)
       let refresh_disabled () =
         match disabled_expr with
         | None -> ()
         | Some dexpr ->
           let panel_state = State_store.get_panel_state store pid in
           let panel_obj = `Assoc panel_state in
           let ctx' = match ctx with
             | `Assoc pairs ->
               `Assoc (("panel", panel_obj)
                       :: List.filter (fun (k, _) -> k <> "panel") pairs)
             | _ -> `Assoc [("panel", panel_obj)] in
           let dis = Expr_eval.to_bool (Expr_eval.evaluate dexpr ctx') in
           entry#misc#set_sensitive (not dis)
       in
       State_store.subscribe_panel store pid (fun key v ->
         if key = field && not entry#is_focus then begin
           let new_text = match v with
             | `Float f -> Printf.sprintf "%g" f
             | `Int i -> string_of_int i
             | `Null -> ""
             | _ -> entry#text in
           if entry#text <> new_text then begin
             suppress := true;
             entry#set_text new_text;
             suppress := false
           end
         end;
         refresh_disabled ())
     | _ -> ())
  end else begin
    let adj = GData.adjustment ~lower:min_val ~upper:max_val ~step_incr:1.0 ~value:initial () in
    let spin = GEdit.spin_button ~adjustment:adj ~digits:0 ~packing () in
    (* Write-back: commit on value change so the StateStore, and any
       subscription on the current panel scope, see the edit.
       ``value_changed`` fires when the adjustment value changes (arrow
       buttons, scroll wheel, programmatic set). On lablgtk3 the spin
       entry's typed text doesn't reach the adjustment until ``update``
       is called explicitly (default policy is ``IF_VALID`` on
       focus-out, but Tab in a dialog doesn't always trigger
       focus-out reliably) — so also wire focus_out_event and the
       entry's activate (Enter) signal to call spin#update first. *)
    (match bind_expr with
     | Some expr ->
       ignore (spin#connect#value_changed ~callback:(fun () ->
         _write_back_bind expr (`Float spin#value)));
       ignore (spin#event#connect#focus_out ~callback:(fun _ ->
         spin#update;
         _write_back_bind expr (`Float spin#value);
         false));
       ignore (spin#connect#activate ~callback:(fun () ->
         spin#update;
         _write_back_bind expr (`Float spin#value)));
       (* Per-keystroke backstop: spin#connect#value_changed only
          fires when the underlying adjustment moves, and on lablgtk3
          Tab in a dialog doesn't reliably trigger the focus-out
          commit that updates the adjustment. The entry's ``changed``
          signal fires on every keystroke; parse the text and write
          back so OK-after-typing-without-Enter sees the typed value. *)
       let entry_view : GEdit.entry =
         new GEdit.entry (Gobject.try_cast spin#as_widget "GtkEntry") in
       ignore (spin#connect#changed ~callback:(fun () ->
         match float_of_string_opt (String.trim entry_view#text) with
         | Some v -> _write_back_bind expr (`Float v)
         | None -> ()))
     | None -> ())
  end

and render_text_input ~packing ~ctx el =
  let open Yojson.Safe.Util in
  let placeholder = el |> member "placeholder" |> to_string_option |> Option.value ~default:"" in
  let bind_expr = match el |> member "bind" with
    | `String s -> Some s
    | obj -> obj |> safe_member "value" |> to_string_option in
  let initial = match bind_expr with
    | Some expr ->
      (match Expr_eval.evaluate expr ctx with
       | Expr_eval.Str s -> s
       | _ -> "")
    | None -> "" in
  let entry = GEdit.entry ~packing ~text:initial () in
  if placeholder <> "" then entry#set_placeholder_text placeholder;
  if !_current_panel_id <> None then begin
    (* Match render_number_input's sizing pattern exactly: shrinkable
       size_request width:1 paired with width_chars set to the input
       width converted from pixels to character columns (~8 px/char
       in the Adwaita label font). Passing a fixed pixel width via
       the GtkEntry constructor caused the hex field to "pulse"
       during selection-change rebuilds — the natural width
       reported by GTK kept disagreeing with the requested width
       across layout passes. width_chars-driven sizing stays stable. *)
    let style_width = el |> member "style" |> safe_member "width"
                      |> to_number_option |> Option.map int_of_float in
    entry#misc#set_size_request ~width:1 ();
    (match style_width with
     | Some w -> entry#set_width_chars (max 1 (w / 8))
     | None -> entry#set_width_chars 4);
    let provider = GObj.css_provider () in
    provider#load_from_data
      "entry { min-height: 16px; padding: 1px 4px; }";
    entry#misc#style_context#add_provider provider 800;
    (* Register the hex entry so document-change updates land here
       directly (avoids the pulse from a body rebuild). *)
    (match el |> member "id" |> to_string_option with
     | Some "cp_hex" -> _color_panel_slots.hex_entry <- Some entry
     | _ -> ())
  end;
  (* Write-back on focus-out / Enter (matches number_input's
     commit-on-change semantics rather than commit-per-keystroke). *)
  (match bind_expr with
   | Some expr ->
     ignore (entry#connect#activate ~callback:(fun () ->
       _write_back_bind expr (`String entry#text)));
     ignore (entry#event#connect#focus_out ~callback:(fun _ ->
       _write_back_bind expr (`String entry#text);
       false))
   | None -> ());

  (* Dialog scope: subscribe to dialog state changes so e.g. the
     color picker's hex field reflects the canonical [dialog.color]
     as the user moves the 2D gradient / hue bar / value boxes. *)
  (match bind_expr, !Dialog_global.current_id with
   | Some expr, Some _
     when String.length expr > 7 && String.sub expr 0 7 = "dialog." ->
     Dialog_global.add_state_change_listener (fun () ->
       if not entry#is_focus then begin
         let live_ctx = !Dialog_global.current_build_ctx () in
         let new_text = match Expr_eval.evaluate expr live_ctx with
           | Expr_eval.Str s -> s
           | _ -> entry#text in
         if entry#text <> new_text then entry#set_text new_text
       end)
   | _ -> ())

and render_length_input ~packing ~ctx el =
  let open Yojson.Safe.Util in
  let unit = el |> member "unit" |> to_string_option |> Option.value ~default:"pt" in
  let precision = el |> member "precision" |> to_int_option |> Option.value ~default:2 in
  let placeholder = el |> member "placeholder" |> to_string_option |> Option.value ~default:"" in
  let nullable = el |> member "nullable" |> to_bool_option |> Option.value ~default:false in
  let min_clamp = el |> member "min" |> to_number_option in
  let max_clamp = el |> member "max" |> to_number_option in
  let bind_expr = el |> member "bind" |> safe_member "value" |> to_string_option in
  let pt_value : float option = match bind_expr with
    | Some expr ->
      (match Expr_eval.evaluate expr ctx with
       | Expr_eval.Number n -> Some n
       | Expr_eval.Null -> None
       | _ -> None)
    | None -> None in
  let initial = Length.format pt_value ~unit ~precision in
  let entry = GEdit.entry ~packing ~text:initial () in
  if placeholder <> "" then entry#set_placeholder_text placeholder;
  (* Same shrinkable rationale as render_number_input — keep panel
     entries from forcing the dock pane wider than its slot. The
     entry's natural width is otherwise driven by initial text
     (e.g. "14.4 pt"), which under col_homogeneous=true pushes the
     whole grid 12× wider than that single cell. *)
  if !_current_panel_id <> None then begin
    entry#misc#set_size_request ~width:1 ();
    entry#set_width_chars 4
  end;
  let commit () =
    match bind_expr with
    | None -> ()
    | Some expr ->
      let entered = entry#text in
      let trimmed = String.trim entered in
      if trimmed = "" then begin
        if nullable then begin
          (* Character panel's [leading] is Auto when the element's
             line_height is empty; clearing the field re-derives the
             Auto-tracked value (font_size * 1.2) and the apply
             pipeline writes it back out as the empty element
             attribute. No other Character field is nullable yet.
             Mirrors Rust's render_length_input Character clear path. *)
          if expr = "panel.leading" &&
             !_current_panel_id = Some "character_panel_content" then begin
            let fs = match !_current_store with
              | Some s ->
                (match State_store.get_panel s "character_panel_content"
                         "font_size" with
                 | `Int n -> Float.of_int n
                 | `Float n -> n
                 | _ -> 12.0)
              | None -> 12.0 in
            _write_back_bind expr (`Float (fs *. 1.2));
            entry#set_text (Length.format (Some (fs *. 1.2)) ~unit ~precision)
          end else
            _write_back_bind expr `Null
        end
        (* Non-nullable empty: revert by re-displaying the bound value. *)
        else entry#set_text initial
      end else begin
        match Length.parse entered ~default_unit:unit with
        | None -> entry#set_text initial
        | Some v ->
          let v = match min_clamp with Some lo when v < lo -> lo | _ -> v in
          let v = match max_clamp with Some hi when v > hi -> hi | _ -> v in
          _write_back_bind expr (`Float v);
          (* Reflect the clamped / re-formatted value back. *)
          entry#set_text (Length.format (Some v) ~unit ~precision)
      end
  in
  ignore (entry#connect#activate ~callback:commit);
  ignore (entry#event#connect#focus_out ~callback:(fun _ -> commit (); false))

and render_select ~packing ~ctx el =
  let open Yojson.Safe.Util in
  let options = match el |> member "options" with `List l -> l | _ -> [] in
  let bind_expr = el |> member "bind" |> safe_member "value" |> to_string_option in
  (* Value strings parallel to the populated display rows — used to
     look up the selected row on change. *)
  let values = List.map (fun opt -> match opt with
    | `Assoc _ ->
      (match opt |> member "value" |> to_string_option with
       | Some v -> v
       | None -> Option.value ~default:"" (opt |> member "label" |> to_string_option))
    | `String s -> s
    | _ -> "") options in
  let (combo, (store, col)) = GEdit.combo_box_text ~packing () in
  (* In panel context, force the combo to be shrinkable: GTK's default
     natural size for a combo is the width of the longest option label
     (e.g. "Portuguese", "Bold Italic"), which can exceed the dock
     pane's width and push the panel wider than the user's intended
     layout. Set a tiny minimum, narrow the cellview/button via CSS,
     and let the cell's expand+fill packing decide the actual width.
     The popup itself continues to render full-width (GTK pops it up
     as a separate widget). *)
  if !_current_panel_id <> None then
    combo#misc#set_size_request ~width:1 ();
  List.iter (fun opt ->
    let label = match opt with
      | `Assoc _ ->
        let lbl = opt |> member "label" |> to_string_option in
        (* `value` can be a string ("range"), int (75), or bool — coerce
           to a display string for the fallback when label is absent. *)
        let value_str = match opt |> member "value" with
          | `String s -> Some s
          | `Int i -> Some (string_of_int i)
          | `Float f -> Some (string_of_float f)
          | `Bool b -> Some (string_of_bool b)
          | _ -> None in
        (match lbl with Some l -> l | None -> Option.value ~default:"" value_str)
      | `String s -> s
      | _ -> "" in
    let row = store#append () in
    store#set ~row ~column:col label
  ) options;
  (* Select the option whose value matches the current bound state,
     falling back to the first entry. *)
  let current = match bind_expr with
    | Some expr ->
      (match Expr_eval.evaluate expr ctx with
       | Expr_eval.Str s -> s
       | _ -> "")
    | None -> "" in
  let active_idx =
    match List.mapi (fun i v -> (i, v)) values |> List.find_opt (fun (_, v) -> v = current) with
    | Some (i, _) -> i
    | None -> 0 in
  if List.length options > 0 then combo#set_active active_idx;
  (* Write-back on selection change. *)
  (match bind_expr with
   | Some expr ->
     ignore (combo#connect#changed ~callback:(fun () ->
       let idx = combo#active in
       if idx >= 0 && idx < List.length values then
         _write_back_bind expr (`String (List.nth values idx))))
   | None -> ())

and render_toggle ~packing ~ctx el =
  let open Yojson.Safe.Util in
  let label = el |> member "label" |> to_string_option |> Option.value ~default:"" in
  let icon_name = el |> member "icon" |> to_string_option |> Option.value ~default:"" in
  (* Accept the bare-string form ("dialog.web_only"), bind.value (the
     panel-bool convention), or legacy bind.checked. The color
     picker's Only-Web-Colors toggle uses the bare-string form;
     without this fallback the toggle never bound and the snap
     branch in [_write_back_bind] never fired. *)
  let bind_expr = match el |> member "bind" with
    | `String s -> Some s
    | obj ->
      (match obj |> safe_member "value" |> to_string_option with
       | Some s -> Some s
       | None -> obj |> safe_member "checked" |> to_string_option) in
  let checked = match bind_expr with
    | Some expr -> Expr_eval.to_bool (Expr_eval.evaluate expr ctx)
    | None -> false in
  let disabled = match el |> member "bind" |> safe_member "disabled" |> to_string_option with
    | Some expr -> Expr_eval.to_bool (Expr_eval.evaluate expr ctx)
    | None -> false in
  let style = el |> member "style" in
  let icon_size = match style |> safe_member "width" |> to_number_option with
    | Some n -> int_of_float n
    | None -> 20 in
  let icon_pixbuf =
    if icon_name = "" then None
    else try Some (Workspace_icon.pixbuf_for_name icon_name icon_size "#cccccc")
         with _ -> None in
  (* Opacity panel selection-mask bindings route write-backs to the
     document controller (the flag lives on the selected element's
     mask, not on a panel-state key). See OPACITY.md §States.
     Mirrors the Rust and Swift special-cases. *)
  let mask_route =
    if !_current_panel_id = Some "opacity_panel_content" then
      match bind_expr with
      | Some "selection_mask_clip" -> Some `Clip
      | Some "selection_mask_invert" -> Some `Invert
      | _ -> None
    else None in
  let on_toggle_active is_active =
    match mask_route with
    | Some route ->
      (match !_get_model_ref () with
       | None -> ()
       | Some m ->
         let ctrl = new Controller.controller ~model:m () in
         (match route with
          | `Clip -> ctrl#set_mask_clip_on_selection is_active
          | `Invert -> ctrl#set_mask_invert_on_selection is_active))
    | None ->
      (match bind_expr with
       | Some expr -> _write_back_bind expr (`Bool is_active)
       | None -> ())
  in
  match icon_pixbuf with
  | Some pb ->
    (* Icon-toggle variant per CHARACTER.md: square 24×24 button with
       the icon glyph; pressed appearance when checked. Used by All
       Caps, Snap to Glyph, etc. The cell's `alignment: center` style
       keeps neighbouring buttons visually separated by leaving the
       cell's leftover width as gap on either side. *)
    let btn = GButton.toggle_button ~active:checked ~packing ~relief:`NONE () in
    btn#set_draw_indicator false;
    let img = GMisc.image ~pixbuf:pb () in
    btn#set_image img#coerce;
    btn#misc#set_sensitive (not disabled);
    btn#misc#set_size_request ~width:24 ~height:24 ();
    btn#set_halign `CENTER;
    btn#set_valign `CENTER;
    let css =
      "button { min-width: 0; min-height: 0; padding: 2px; \
       border: 1px solid #555; border-radius: 3px; \
       background: #3a3a3a; box-shadow: none; } \
       button:checked { background: #5a5a5a; border-color: #888; }" in
    let provider = GObj.css_provider () in
    provider#load_from_data css;
    btn#misc#style_context#add_provider provider 800;
    let suppress = ref false in
    ignore (btn#connect#toggled ~callback:(fun () ->
      if not !suppress then on_toggle_active btn#active));
    (* Subscribe to store changes so the visual state stays in sync
       with the panel-state — necessary for the paragraph alignment
       row's mutual-exclusion semantics: when the user clicks
       align_left, [Effects.apply_paragraph_panel_mutual_exclusion]
       writes the other six align/justify keys to false in the store,
       and those writes need to clear their buttons' visual state.
       Without the subscription a previously-clicked button stays
       highlighted forever. The [suppress] guard keeps the
       set_active call from re-firing the toggled write-back. *)
    (match bind_expr, !_current_store, !_current_panel_id with
     | Some expr, Some store, Some pid
       when (let parts = String.split_on_char '.' expr in
             match parts with "panel" :: _ :: _ -> true | _ -> false) ->
       let field = match String.split_on_char '.' expr with
         | _ :: f :: _ -> f | _ -> "" in
       State_store.subscribe_panel store pid (fun key v ->
         if key = field then begin
           let want = match v with `Bool b -> b | _ -> false in
           if btn#active <> want then begin
             suppress := true;
             btn#set_active want;
             suppress := false
           end
         end)
     | _ -> ())
  | None ->
    let btn = GButton.check_button ~label ~active:checked ~packing () in
    btn#misc#set_sensitive (not disabled);
    (* Match Dock_panel.theme_text (#cccccc on dark theme). Hardcoded
       rather than imported to avoid a Dock_panel ↔ Yaml_panel_view
       module cycle. *)
    let css = "checkbutton, checkbutton label { color: #cccccc; }" in
    let provider = GObj.css_provider () in
    provider#load_from_data css;
    btn#misc#style_context#add_provider provider 800;
    let suppress = ref false in
    ignore (btn#connect#toggled ~callback:(fun () ->
      if not !suppress then on_toggle_active btn#active));
    (* Subscribe to panel-state updates so the checkbox refreshes its
       active-state and its [bind.disabled] when selection or another
       widget changes the underlying field — same pattern as the
       icon-toggle branch and as render_number_input. *)
    (match bind_expr, !_current_store, !_current_panel_id with
     | Some expr, Some store, Some pid
       when (let parts = String.split_on_char '.' expr in
             match parts with "panel" :: _ :: _ -> true | _ -> false) ->
       let field = match String.split_on_char '.' expr with
         | _ :: f :: _ -> f | _ -> "" in
       let disabled_expr =
         el |> member "bind" |> safe_member "disabled" |> to_string_option in
       let refresh_disabled () =
         match disabled_expr with
         | None -> ()
         | Some dexpr ->
           let panel_state = State_store.get_panel_state store pid in
           let panel_obj = `Assoc panel_state in
           let ctx' = match ctx with
             | `Assoc pairs ->
               `Assoc (("panel", panel_obj)
                       :: List.filter (fun (k, _) -> k <> "panel") pairs)
             | _ -> `Assoc [("panel", panel_obj)] in
           let dis = Expr_eval.to_bool (Expr_eval.evaluate dexpr ctx') in
           btn#misc#set_sensitive (not dis)
       in
       State_store.subscribe_panel store pid (fun key v ->
         if key = field then begin
           let want = match v with `Bool b -> b | _ -> false in
           if btn#active <> want then begin
             suppress := true;
             btn#set_active want;
             suppress := false
           end
         end;
         refresh_disabled ())
     | _ -> ())

and render_combo_box ~packing ~ctx:_ el =
  let open Yojson.Safe.Util in
  let options = match el |> member "options" with `List l -> l | _ -> [] in
  let (combo, (store, col)) = GEdit.combo_box_text ~has_entry:true ~packing () in
  (* Same width clamp as render_select — without it the kerning combo
     ("Optical", "Metrics", "-100" etc) reports a wide natural and
     forces the homogeneous Bootstrap-12 grid open. *)
  if !_current_panel_id <> None then
    combo#misc#set_size_request ~width:1 ();
  List.iter (fun opt ->
    let label = match opt with
      | `Assoc _ ->
        let lbl = opt |> member "label" |> to_string_option in
        (* `value` can be a string ("range"), int (75), or bool — coerce
           to a display string for the fallback when label is absent. *)
        let value_str = match opt |> member "value" with
          | `String s -> Some s
          | `Int i -> Some (string_of_int i)
          | `Float f -> Some (string_of_float f)
          | `Bool b -> Some (string_of_bool b)
          | _ -> None in
        (match lbl with Some l -> l | None -> Option.value ~default:"" value_str)
      | `String s -> s
      | _ -> "" in
    let row = store#append () in
    store#set ~row ~column:col label
  ) options

and render_color_swatch ~packing ~ctx el =
  let open Yojson.Safe.Util in
  (* style.size may be encoded as either int or float depending on the
     YAML→JSON conversion. ``to_int_option`` raises on a float; lift via
     ``to_number_option`` and round so either form works. *)
  let size = el |> member "style" |> safe_member "size" |> to_number_option
             |> Option.map int_of_float |> Option.value ~default:16 in
  let color_bind_expr = el |> member "bind" |> safe_member "color" |> to_string_option in
  let initial_color = match color_bind_expr with
    | Some expr ->
      let v = Expr_eval.evaluate expr ctx in
      (match v with Expr_eval.Color c -> c | Expr_eval.Str s -> s | _ -> "")
    | None -> "" in
  (* Mutable color ref so [update_color_panel_widgets] can refresh
     the fill/stroke swatch without rebuilding the panel body — the
     draw callback dereferences this each frame. *)
  let color_ref = ref initial_color in
  let selected = is_selected_in_list el ctx in
  let hollow = el |> member "hollow" |> to_bool_option |> Option.value ~default:false in
  (* DrawingArea (not GtkButton) so the swatch sizes exactly to the
     declared [size] — Adwaita's themed button enforces a min-height
     of ~30px regardless of the CSS override and inflated 16x16
     swatches to 30x40 in the recent-color row (CLR-002 OCaml). The
     EventBox parent receives clicks for the behavior dispatch. *)
  let evt = GBin.event_box ~packing () in
  evt#misc#set_size_request ~width:size ~height:size ();
  let area = GMisc.drawing_area ~packing:evt#add () in
  area#misc#set_size_request ~width:size ~height:size ();

  (* Dialog scope: subscribe to dialog state changes so the swatch
     (e.g. color_picker's preview, bound to [dialog.color]) repaints
     when the user moves the gradient / hue bar / value boxes. *)
  (match color_bind_expr, !Dialog_global.current_id with
   | Some expr, Some _
     when String.length expr > 7 && String.sub expr 0 7 = "dialog." ->
     Dialog_global.add_state_change_listener (fun () ->
       let live_ctx = !Dialog_global.current_build_ctx () in
       (match Expr_eval.evaluate expr live_ctx with
        | Expr_eval.Color c -> color_ref := c
        | Expr_eval.Str s -> color_ref := s
        | _ -> ());
       area#misc#queue_draw ())
   | _ -> ());

  let parse_hex s =
    let s = if String.length s > 0 && s.[0] = '#' then String.sub s 1 (String.length s - 1) else s in
    let s = if String.length s = 3 then
        let c0 = String.make 1 s.[0] in
        let c1 = String.make 1 s.[1] in
        let c2 = String.make 1 s.[2] in
        c0 ^ c0 ^ c1 ^ c1 ^ c2 ^ c2
      else s in
    if String.length s <> 6 then (0, 0, 0)
    else
      try
        let h2 i = int_of_string ("0x" ^ String.sub s i 2) in
        (h2 0, h2 2, h2 4)
      with _ -> (0, 0, 0)
  in
  (* Dispatch the swatch's [behavior] array on click. Mirrors the
     Rust [renderer.rs] color_swatch click handler. *)
  evt#event#add [`BUTTON_PRESS];
  ignore (evt#event#connect#button_press ~callback:(fun ev ->
    if GdkEvent.Button.button ev = 1 then begin
      (* Rebuild the panel/state portions of ctx from the live store
         before dispatching. The ctx captured at widget creation
         time has stale panel.recent_colors etc. — the bridge writes
         new recent entries into the store but doesn't update the
         captured Yojson; a recent-swatch click using stale ctx
         resolves [panel.recent_colors.0] to null and the condition
         gate ([panel.recent_colors.0 != null]) fails silently. *)
      let click_ctx =
        match !_current_store, !_current_panel_id, ctx with
        | Some store, Some pid, `Assoc pairs ->
          let live_panel = State_store.get_panel_state store pid in
          let live_state = State_store.get_all store in
          let pairs' = List.filter
            (fun (k, _) -> k <> "panel" && k <> "state") pairs in
          `Assoc (("panel", `Assoc live_panel)
                  :: ("state", `Assoc live_state) :: pairs')
        | _ -> ctx in
      (* TWO_BUTTON_PRESS fires GTK's double-click after the second
         BUTTON_PRESS. Dispatch double_click behaviors (e.g. the
         fill_stroke_widget's open_color_picker action) and skip
         the single-click dispatch — the first half of the double
         already fired it. *)
      if GdkEvent.get_type ev = `TWO_BUTTON_PRESS then begin
        dispatch_double_click_behaviors el click_ctx;
        true
      end else
      let fill_on_top_before = match !_current_store with
        | Some store ->
          (match State_store.get store "fill_on_top" with
           | `Bool b -> b | _ -> true)
        | None -> true in
      let wrote_state = dispatch_click_behaviors el click_ctx in
      if wrote_state then begin
        update_color_panel_widgets ();
        (* Only re-order the fill/stroke swatches when fill_on_top
           actually flipped — the swap removes/re-adds both event
           boxes from the GtkFixed, and that reset of the gdk
           window apparently clears GTK3's double-click tracking,
           so a second click on the same swatch arrives as a fresh
           single BUTTON_PRESS instead of TWO_BUTTON_PRESS and the
           color-picker double-click never fires. *)
        let fill_on_top_after = match !_current_store with
          | Some store ->
            (match State_store.get store "fill_on_top" with
             | `Bool b -> b | _ -> true)
          | None -> true in
        if fill_on_top_before <> fill_on_top_after then
          !fill_stroke_swap_hook ()
      end;
      true
    end else false
  ));
  (* Register fill/stroke swatch + recent slots so document-change
     and recent-color-push updates land on them without a body
     rebuild. The id check picks the widgets we know how to update
     in place; cp_black / cp_white / other swatches stay through
     the rebuild path. *)
  (match el |> member "id" |> to_string_option with
   | Some "cp_fill_swatch" ->
     _color_panel_slots.fill_swatch <- Some (area, color_ref);
     _color_panel_slots.fill_swatch_evt <- Some evt
   | Some "cp_stroke_swatch" ->
     _color_panel_slots.stroke_swatch <- Some (area, color_ref);
     _color_panel_slots.stroke_swatch_evt <- Some evt
   | Some id_str
     when String.length id_str > 10
       && String.sub id_str 0 10 = "cp_recent_" ->
     let suffix = String.sub id_str 10 (String.length id_str - 10) in
     (match int_of_string_opt suffix with
      | Some i when i >= 0 && i < Array.length _color_panel_slots.recent_swatches ->
        _color_panel_slots.recent_swatches.(i) <- Some (area, color_ref)
      | _ -> ())
   | _ -> ());
  let widget_id =
    el |> member "id" |> to_string_option |> Option.value ~default:"" in
  let is_active_color_swatch =
    widget_id = "cp_fill_swatch" || widget_id = "cp_stroke_swatch" in
  ignore (area#misc#connect#draw ~callback:(fun cr ->
    let color_str = !color_ref in
    let s = float_of_int size in
    if String.length color_str = 0 then begin
      if is_active_color_swatch then begin
        (* "None" indicator on the fill/stroke widget. The solid
           fill variant paints a white square; the hollow stroke
           variant paints only a dark 6-px ring with a transparent
           center so the parent background shows through. Both
           overlay a red diagonal + gray border. Recent slots
           without a color keep the dashed-empty rendering below. *)
        if hollow then begin
          Cairo.set_source_rgb cr 0.2 0.2 0.2;
          Cairo.set_fill_rule cr Cairo.EVEN_ODD;
          Cairo.rectangle cr 0.0 0.0 ~w:s ~h:s;
          let inset = 6.0 in
          Cairo.rectangle cr inset inset ~w:(s -. 2.0 *. inset) ~h:(s -. 2.0 *. inset);
          Cairo.fill cr;
          Cairo.set_fill_rule cr Cairo.WINDING
        end else begin
          Cairo.set_source_rgb cr 1.0 1.0 1.0;
          Cairo.rectangle cr 0.0 0.0 ~w:s ~h:s;
          Cairo.fill cr
        end;
        Cairo.set_source_rgb cr 1.0 0.0 0.0;
        Cairo.set_line_width cr (max 1.5 (s /. 16.0));
        (* "None" diagonal runs upper-right -> lower-left, matching
           the cp_none_swatch icon's orientation. *)
        Cairo.move_to cr 0.0 s;
        Cairo.line_to cr s 0.0;
        Cairo.stroke cr;
        Cairo.set_source_rgb cr 0.4 0.4 0.4;
        Cairo.set_line_width cr 1.0;
        Cairo.rectangle cr 0.5 0.5 ~w:(s -. 1.0) ~h:(s -. 1.0);
        Cairo.stroke cr
      end else begin
        (* Empty slot: hollow dashed square *)
        Cairo.set_source_rgb cr 0.33 0.33 0.33;
        Cairo.set_line_width cr 1.0;
        Cairo.set_dash cr [| 2.0; 2.0 |];
        Cairo.rectangle cr 0.5 0.5 ~w:(s -. 1.0) ~h:(s -. 1.0);
        Cairo.stroke cr
      end
    end else begin
      let (r, g, b) = parse_hex color_str in
      let rf = float_of_int r /. 255.0 in
      let gf = float_of_int g /. 255.0 in
      let bf = float_of_int b /. 255.0 in
      if hollow then begin
        (* Hollow square: 6px ring of color, transparent center *)
        Cairo.set_source_rgb cr rf gf bf;
        Cairo.set_fill_rule cr Cairo.EVEN_ODD;
        Cairo.rectangle cr 0.0 0.0 ~w:s ~h:s;
        let inset = 6.0 in
        Cairo.rectangle cr inset inset ~w:(s -. 2.0 *. inset) ~h:(s -. 2.0 *. inset);
        Cairo.fill cr;
        Cairo.set_fill_rule cr Cairo.WINDING
      end else begin
        Cairo.set_source_rgb cr rf gf bf;
        Cairo.rectangle cr 0.0 0.0 ~w:s ~h:s;
        Cairo.fill cr
      end;
      (* Border *)
      if selected then begin
        Cairo.set_source_rgb cr 0.29 0.56 0.85;
        Cairo.set_line_width cr 2.0;
        Cairo.rectangle cr 1.0 1.0 ~w:(s -. 2.0) ~h:(s -. 2.0)
      end else begin
        Cairo.set_source_rgb cr 0.4 0.4 0.4;
        Cairo.set_line_width cr 1.0;
        Cairo.rectangle cr 0.5 0.5 ~w:(s -. 1.0) ~h:(s -. 1.0)
      end;
      Cairo.stroke cr
    end;
    true
  ));
  let _ = evt in ()

(** [fill_stroke_widget] template — render children with absolute
    positioning into a [GPack.fixed] box. The template declares each
    child's size and placement via [style.size] and
    [style.position.{x,y}], which the standard column layout in
    [render_container] discards (children stack vertically and
    inflate to row width, the symptom seen in CLR-002 OCaml). *)
and render_fill_stroke_widget ~packing ~ctx el =
  let open Yojson.Safe.Util in
  let style = el |> member "style" in
  let width = style |> safe_member "width" |> to_number_option
    |> Option.map int_of_float |> Option.value ~default:48 in
  let height = style |> safe_member "height" |> to_number_option
    |> Option.map int_of_float |> Option.value ~default:60 in
  let container = GPack.fixed ~packing () in
  container#misc#set_size_request ~width ~height ();
  let children = match el |> member "children" with
    | `List xs -> xs | _ -> [] in
  (* Sort children by [bind.z_index] so siblings with explicit
     stacking land in paint order (GtkFixed paints children in the
     order they're added — first child at the bottom, last on top).
     fill_swatch and stroke_swatch both bind z_index to expressions
     that depend on [state.fill_on_top]; without this sort the
     swatches always stack in document order and the active-swatch
     swap (CLR-141 / CLR-142) is visually a no-op. Children without
     a [z_index] bind default to 0 and keep their document order
     via a stable sort. *)
  let z_of child =
    match child |> member "bind" |> safe_member "z_index" with
    | `String expr ->
      (try
         match Expr_eval.evaluate expr ctx with
         | Expr_eval.Number n -> int_of_float n
         | _ -> 0
       with _ -> 0)
    | `Int n -> n
    | `Float f -> int_of_float f
    | _ -> 0
  in
  let indexed = List.mapi (fun i c -> (i, c)) children in
  let sorted = List.stable_sort (fun (_, a) (_, b) ->
    compare (z_of a) (z_of b)
  ) indexed in
  let fill_pos = ref (0, 0) in
  let stroke_pos = ref (0, 0) in
  List.iter (fun (_, child) ->
    let pos = child |> member "style" |> safe_member "position" in
    let x = pos |> safe_member "x" |> to_number_option
      |> Option.map int_of_float |> Option.value ~default:0 in
    let y = pos |> safe_member "y" |> to_number_option
      |> Option.map int_of_float |> Option.value ~default:0 in
    (match child |> member "id" |> to_string_option with
     | Some "cp_fill_swatch" -> fill_pos := (x, y)
     | Some "cp_stroke_swatch" -> stroke_pos := (x, y)
     | _ -> ());
    render_element ~packing:(container#put ~x ~y) ~ctx child
  ) sorted;

  (* Install the swap hook so subsequent fill/stroke clicks can
     restack the active swatch on top without a body rebuild. The
     hook captures [container] and the per-child positions in a
     closure; [render_color_swatch]'s button_press handler fires it
     after flipping [state.fill_on_top]. *)
  fill_stroke_swap_hook := (fun () ->
    let fill_on_top = match !_current_store with
      | Some store ->
        (match State_store.get store "fill_on_top" with
         | `Bool b -> b | _ -> true)
      | None -> true in
    match _color_panel_slots.fill_swatch_evt,
          _color_panel_slots.stroke_swatch_evt with
    | Some fill_evt, Some stroke_evt ->
      let (fx, fy) = !fill_pos in
      let (sx, sy) = !stroke_pos in
      (* Remove both, then re-add in the order that puts the
         active swatch last (= on top in GtkFixed's paint order). *)
      container#remove (fill_evt :> GObj.widget);
      container#remove (stroke_evt :> GObj.widget);
      if fill_on_top then begin
        container#put (stroke_evt :> GObj.widget) ~x:sx ~y:sy;
        container#put (fill_evt :> GObj.widget) ~x:fx ~y:fy
      end else begin
        container#put (fill_evt :> GObj.widget) ~x:fx ~y:fy;
        container#put (stroke_evt :> GObj.widget) ~x:sx ~y:sy
      end
    | _ -> ())

(** [color_bar] — 64px tall horizontal HSB gradient strip. Cairo-paint
    a hue ramp on the X axis × saturation/brightness band on the Y
    axis (top half white→full-saturation, bottom half full→black);
    click+drag picks the color at the cursor and routes it through
    [Panel_menu.set_active_color] (commit on release pushes to the
    recent strip). Mirrors the Rust [build_color_bar_data_uri] math. *)
and render_color_bar ~packing ~ctx el =
  let open Yojson.Safe.Util in
  let style = el |> member "style" in
  let height = style |> safe_member "height" |> to_number_option
    |> Option.map int_of_float |> Option.value ~default:64 in
  (* set_size_request width:1 keeps the colorbar's preferred width
     minimal. Wrap the drawing area in an event_box so the natural-
     width contribution stops at the event_box (with width:1) rather
     than propagating up through the column → dock pane → window
     chain. The event_box pins its own width to 1; halign:`FILL`
     lets it stretch when the parent gives extra space. *)
  let evt = GBin.event_box ~packing () in
  evt#misc#set_size_request ~width:1 ~height ();
  evt#set_hexpand false;
  evt#set_halign `FILL;
  let area = GMisc.drawing_area ~packing:evt#add () in
  area#misc#set_size_request ~width:1 ~height ();
  area#set_hexpand false;
  area#event#add [`BUTTON_PRESS; `BUTTON_RELEASE; `BUTTON1_MOTION];

  (* (x, y, width) → HSB color. Same convention as the Rust
     [build_color_bar_data_uri] / [xy_to_color]. *)
  let xy_to_rgb x y w h =
    let hue = if w <= 0.0 then 0.0 else 360.0 *. x /. w in
    let hue = max 0.0 (min 360.0 hue) in
    let mid_y = h /. 2.0 in
    let (sat, br) =
      if y <= mid_y then
        let t = if mid_y <= 0.0 then 0.0 else min 1.0 (max 0.0 (y /. mid_y)) in
        (t *. 100.0, 100.0 -. t *. 20.0)
      else
        let denom = h -. mid_y in
        let t = if denom <= 0.0 then 0.0
                else min 1.0 (max 0.0 ((y -. mid_y) /. denom)) in
        (100.0, 80.0 *. (1.0 -. t))
    in
    Color_util.hsb_to_rgb hue sat br
  in

  (* Paint the gradient one column at a time. ~1px columns are cheap
     and visually indistinguishable from per-pixel painting at this
     resolution; the more expensive cairo_pattern_create_mesh path
     isn't worth wrapping in OCaml for a one-off widget. *)
  ignore (area#misc#connect#draw ~callback:(fun cr ->
    let alloc = area#misc#allocation in
    let aw = float_of_int alloc.Gtk.width in
    let ah = float_of_int alloc.Gtk.height in
    let cols = int_of_float aw in
    for x = 0 to cols - 1 do
      (* Two-stop vertical gradient per column matching the spec:
         white at top → full-saturation pure hue at mid → black at
         bottom. *)
      let xf = float_of_int x +. 0.5 in
      let pat = Cairo.Pattern.create_linear ~x0:xf ~y0:0.0 ~x1:xf ~y1:ah in
      let mid = ah /. 2.0 in
      let (r0, g0, b0) = xy_to_rgb xf 0.0 aw ah in
      let (r1, g1, b1) = xy_to_rgb xf mid aw ah in
      let (r2, g2, b2) = xy_to_rgb xf ah aw ah in
      Cairo.Pattern.add_color_stop_rgb pat ~ofs:0.0
        (float_of_int r0 /. 255.0) (float_of_int g0 /. 255.0) (float_of_int b0 /. 255.0);
      Cairo.Pattern.add_color_stop_rgb pat ~ofs:0.5
        (float_of_int r1 /. 255.0) (float_of_int g1 /. 255.0) (float_of_int b1 /. 255.0);
      Cairo.Pattern.add_color_stop_rgb pat ~ofs:1.0
        (float_of_int r2 /. 255.0) (float_of_int g2 /. 255.0) (float_of_int b2 /. 255.0);
      Cairo.set_source cr pat;
      Cairo.rectangle cr (float_of_int x) 0.0 ~w:1.0 ~h:ah;
      Cairo.fill cr
    done;
    (* 1px border *)
    Cairo.set_source_rgb cr 0.33 0.33 0.33;
    Cairo.set_line_width cr 1.0;
    Cairo.rectangle cr 0.5 0.5 ~w:(aw -. 1.0) ~h:(ah -. 1.0);
    Cairo.stroke cr;
    true
  ));

  (* fill_on_top routes the picked color to fill or stroke. The
     workspace state store doesn't thread live values into the panel
     ctx in OCaml yet; default to fill (matches the YAML default and
     the expected first-test scenario). Color picker dialog can
     override per-target. *)
  let read_fill_on_top () =
    match Expr_eval.evaluate "state.fill_on_top" ctx with
    | Expr_eval.Bool b -> b
    | _ -> true
  in

  (* Click / drag → set_active_color. Live (no recent push) on press
     and motion; final commit (with recent push) on release. *)
  let pick_color_from_button ev =
    let alloc = area#misc#allocation in
    let aw = float_of_int alloc.Gtk.width in
    let ah = float_of_int alloc.Gtk.height in
    let x = GdkEvent.Button.x ev in
    let y = GdkEvent.Button.y ev in
    let (r, g, b) = xy_to_rgb x y aw ah in
    Element.color_rgb
      (float_of_int r /. 255.0)
      (float_of_int g /. 255.0)
      (float_of_int b /. 255.0)
  in
  let pick_color_from_motion ev =
    let alloc = area#misc#allocation in
    let aw = float_of_int alloc.Gtk.width in
    let ah = float_of_int alloc.Gtk.height in
    let x = GdkEvent.Motion.x ev in
    let y = GdkEvent.Motion.y ev in
    let (r, g, b) = xy_to_rgb x y aw ah in
    Element.color_rgb
      (float_of_int r /. 255.0)
      (float_of_int g /. 255.0)
      (float_of_int b /. 255.0)
  in
  (* [Model.set_default_fill] / [set_default_stroke] don't fire the
     on_document_changed listeners (only [set_document] does), so a
     color-bar pick that lands solely in the model defaults — i.e.
     no selection to also write through — never reaches
     [update_color_panel_widgets]. Call it explicitly after each
     set_active_color* so the hex entry, swatches, and slider state
     refresh whether or not a selection exists. *)
  ignore (area#event#connect#button_press ~callback:(fun ev ->
    (match !_get_model_ref () with
     | Some m -> Panel_menu.set_active_color_live (pick_color_from_button ev)
                   ~fill_on_top:(read_fill_on_top ()) m
     | None -> ());
    update_color_panel_widgets ();
    true));
  ignore (area#event#connect#button_release ~callback:(fun ev ->
    (match !_get_model_ref () with
     | Some m -> Panel_menu.set_active_color (pick_color_from_button ev)
                   ~fill_on_top:(read_fill_on_top ()) m
     | None -> ());
    update_color_panel_widgets ();
    true));
  ignore (area#event#connect#motion_notify ~callback:(fun ev ->
    (match !_get_model_ref () with
     | Some m -> Panel_menu.set_active_color_live (pick_color_from_motion ev)
                   ~fill_on_top:(read_fill_on_top ()) m
     | None -> ());
    update_color_panel_widgets ();
    true))

(** [radio_group] — a single radio button slot. The YAML repeats
    [radio_group] entries (one per channel: H, S, B, R, G, …) and
    binds them all to [dialog.radio_channel]; clicking writes the
    option's id ([h], [s], …) so only the matching slot renders as
    active. Mirrors the radio-row look from the Rust color picker
    (small circle, hollow when inactive, filled when active).

    Drawn as a 12 px GtkDrawingArea — using a real [GButton.radio_button]
    would group each instance in its own group (no mutual exclusion)
    AND inflate to the Adwaita ~30 px min-height. The drawing-area
    approach reads the bind value at paint time, so mutual exclusion
    falls out of the shared dialog state automatically. *)
and render_radio_group ~packing ~ctx el =
  let open Yojson.Safe.Util in
  let options = match el |> member "options" with `List l -> l | _ -> [] in
  let bind_expr = el |> member "bind" |> to_string_option
                  |> Option.value ~default:"" in
  let read_active () : string =
    if bind_expr = "" then ""
    else match Expr_eval.evaluate bind_expr ctx with
      | Expr_eval.Str s -> s
      | _ -> "" in
  let read_active_live () : string =
    (* Fresh read against the live dialog state — the captured ctx
       is a snapshot from render time. *)
    if bind_expr <> "" && !Dialog_global.current_state <> None then
      let live_ctx = !Dialog_global.current_build_ctx () in
      match Expr_eval.evaluate bind_expr live_ctx with
      | Expr_eval.Str s -> s
      | _ -> read_active ()
    else read_active () in
  let option_id_of opt =
    opt |> member "id" |> to_string_option |> Option.value ~default:"" in
  List.iter (fun opt ->
    let option_id = option_id_of opt in
    let size = 12 in
    let evt = GBin.event_box ~packing () in
    evt#misc#set_size_request ~width:size ~height:size ();
    let area = GMisc.drawing_area ~packing:evt#add () in
    area#misc#set_size_request ~width:size ~height:size ();
    ignore (area#misc#connect#draw ~callback:(fun cr ->
      let s = float_of_int size in
      let cx = s /. 2.0 and cy = s /. 2.0 in
      let r_outer = (s /. 2.0) -. 1.0 in
      Cairo.set_line_width cr 1.0;
      Cairo.set_source_rgb cr 0.35 0.35 0.35;
      Cairo.arc cr cx cy ~r:r_outer ~a1:0.0 ~a2:(2.0 *. Float.pi);
      Cairo.stroke cr;
      if read_active_live () = option_id then begin
        Cairo.set_source_rgb cr 0.2 0.5 0.95;
        Cairo.arc cr cx cy ~r:(r_outer -. 2.0)
          ~a1:0.0 ~a2:(2.0 *. Float.pi);
        Cairo.fill cr
      end;
      true));
    Dialog_global.add_state_change_listener (fun () ->
      area#misc#queue_draw ());
    evt#event#add [`BUTTON_PRESS];
    ignore (evt#event#connect#button_press ~callback:(fun ev ->
      if GdkEvent.Button.button ev = 1 then begin
        if bind_expr <> "" then
          _write_back_bind bind_expr (`String option_id);
        true
      end else false))
  ) options

(** [color_gradient] — square HSB-H 2D gradient. X = saturation, Y =
    brightness (top=100), tinted by the bound [hue]. Click/drag
    writes [saturation] + [brightness] to the dialog state; the
    current point is marked with a small circle indicator. Mirrors
    the Rust [color_picker] [color_gradient] math. *)
and render_color_gradient ~packing ~ctx:_ el =
  let open Yojson.Safe.Util in
  let style = el |> member "style" in
  let min_size = style |> safe_member "min_width" |> to_number_option
    |> Option.map int_of_float |> Option.value ~default:180 in
  let hue_expr = el |> member "bind" |> safe_member "hue"
    |> to_string_option |> Option.value ~default:"" in
  let sat_expr = el |> member "bind" |> safe_member "saturation"
    |> to_string_option |> Option.value ~default:"" in
  let br_expr = el |> member "bind" |> safe_member "brightness"
    |> to_string_option |> Option.value ~default:"" in
  let read_n expr =
    if expr = "" then 0.0
    else
      let live_ctx = !Dialog_global.current_build_ctx () in
      match Expr_eval.evaluate expr live_ctx with
      | Expr_eval.Number n -> n
      | _ -> 0.0
  in
  let evt = GBin.event_box ~packing () in
  evt#misc#set_size_request ~width:min_size ~height:min_size ();
  let area = GMisc.drawing_area ~packing:evt#add () in
  area#misc#set_size_request ~width:min_size ~height:min_size ();
  area#event#add [`BUTTON_PRESS; `BUTTON_RELEASE; `BUTTON1_MOTION];
  ignore (area#misc#connect#draw ~callback:(fun cr ->
    let alloc = area#misc#allocation in
    let aw = float_of_int alloc.Gtk.width in
    let ah = float_of_int alloc.Gtk.height in
    let hue = read_n hue_expr in
    let cols = int_of_float aw in
    for x = 0 to cols - 1 do
      let xf = float_of_int x +. 0.5 in
      let sat = if aw <= 0.0 then 0.0 else 100.0 *. xf /. aw in
      let pat = Cairo.Pattern.create_linear ~x0:xf ~y0:0.0 ~x1:xf ~y1:ah in
      let (r0, g0, b0) = Color_util.hsb_to_rgb hue sat 100.0 in
      let (r1, g1, b1) = Color_util.hsb_to_rgb hue sat 0.0 in
      Cairo.Pattern.add_color_stop_rgb pat ~ofs:0.0
        (float_of_int r0 /. 255.0)
        (float_of_int g0 /. 255.0)
        (float_of_int b0 /. 255.0);
      Cairo.Pattern.add_color_stop_rgb pat ~ofs:1.0
        (float_of_int r1 /. 255.0)
        (float_of_int g1 /. 255.0)
        (float_of_int b1 /. 255.0);
      Cairo.set_source cr pat;
      Cairo.rectangle cr (float_of_int x) 0.0 ~w:1.0 ~h:ah;
      Cairo.fill cr
    done;
    let sat = read_n sat_expr in
    let br = read_n br_expr in
    let cx = aw *. sat /. 100.0 in
    let cy = ah *. (1.0 -. br /. 100.0) in
    Cairo.set_source_rgb cr 1.0 1.0 1.0;
    Cairo.set_line_width cr 2.0;
    Cairo.arc cr cx cy ~r:6.0 ~a1:0.0 ~a2:(2.0 *. Float.pi);
    Cairo.stroke cr;
    Cairo.set_source_rgb cr 0.0 0.0 0.0;
    Cairo.set_line_width cr 1.0;
    Cairo.arc cr cx cy ~r:7.0 ~a1:0.0 ~a2:(2.0 *. Float.pi);
    Cairo.stroke cr;
    Cairo.set_source_rgb cr 0.33 0.33 0.33;
    Cairo.set_line_width cr 1.0;
    Cairo.rectangle cr 0.5 0.5 ~w:(aw -. 1.0) ~h:(ah -. 1.0);
    Cairo.stroke cr;
    true));
  Dialog_global.add_state_change_listener (fun () -> area#misc#queue_draw ());
  let pick_at x y =
    let alloc = area#misc#allocation in
    let aw = float_of_int alloc.Gtk.width in
    let ah = float_of_int alloc.Gtk.height in
    let x = max 0.0 (min aw x) in
    let y = max 0.0 (min ah y) in
    let sat = if aw <= 0.0 then 0.0 else 100.0 *. x /. aw in
    let br = if ah <= 0.0 then 0.0 else 100.0 *. (1.0 -. y /. ah) in
    if sat_expr <> "" then _write_back_bind sat_expr (`Float sat);
    if br_expr <> "" then _write_back_bind br_expr (`Float br)
  in
  ignore (area#event#connect#button_press ~callback:(fun ev ->
    pick_at (GdkEvent.Button.x ev) (GdkEvent.Button.y ev);
    true));
  ignore (area#event#connect#motion_notify ~callback:(fun ev ->
    pick_at (GdkEvent.Motion.x ev) (GdkEvent.Motion.y ev);
    true))

(** [color_hue_bar] — vertical ramp that re-tints per the active
    radio channel. H = rainbow hue, S = grey→hue saturation, B =
    black→hue brightness, R/G/B = black→primary, … . Click/drag
    writes the matching channel into the dialog state. Mirrors the
    Rust color picker's per-channel hue colorbar. *)
and render_color_hue_bar ~packing ~ctx:_ el =
  let open Yojson.Safe.Util in
  let style = el |> member "style" in
  let width = style |> safe_member "width" |> to_number_option
    |> Option.map int_of_float |> Option.value ~default:32 in
  let min_height = style |> safe_member "min_height" |> to_number_option
    |> Option.map int_of_float |> Option.value ~default:100 in
  let read_n key =
    let live_ctx = !Dialog_global.current_build_ctx () in
    match Expr_eval.evaluate ("dialog." ^ key) live_ctx with
    | Expr_eval.Number n -> n
    | _ -> 0.0
  in
  let read_str key =
    let live_ctx = !Dialog_global.current_build_ctx () in
    match Expr_eval.evaluate ("dialog." ^ key) live_ctx with
    | Expr_eval.Str s -> s
    | _ -> ""
  in
  (* Channel descriptors: target field name + range max + per-row
     RGB ramp. The pattern matches the Rust render_color_hue_bar's
     six branches and the spec's "per-channel ramp" semantics. *)
  let channel_spec () =
    match read_str "radio_channel" with
    | "s" ->
      let h = read_n "h" and b = read_n "b" in
      ("s", 100.0, (fun t ->
        Color_util.hsb_to_rgb h (t *. 100.0) b))
    | "b" ->
      let h = read_n "h" and s = read_n "s" in
      ("b", 100.0, (fun t ->
        Color_util.hsb_to_rgb h s (t *. 100.0)))
    | "r" ->
      let g = read_n "g" and bl = read_n "bl" in
      ("r", 255.0, (fun t ->
        (int_of_float (Float.round (t *. 255.0)),
         int_of_float g, int_of_float bl)))
    | "g" ->
      let r = read_n "r" and bl = read_n "bl" in
      ("g", 255.0, (fun t ->
        (int_of_float r,
         int_of_float (Float.round (t *. 255.0)),
         int_of_float bl)))
    | "bl" ->
      let r = read_n "r" and g = read_n "g" in
      ("bl", 255.0, (fun t ->
        (int_of_float r, int_of_float g,
         int_of_float (Float.round (t *. 255.0)))))
    | _ -> (* "h" default *)
      ("h", 360.0, (fun t -> Color_util.hsb_to_rgb (t *. 360.0) 100.0 100.0))
  in
  let evt = GBin.event_box ~packing () in
  evt#misc#set_size_request ~width ~height:min_height ();
  let area = GMisc.drawing_area ~packing:evt#add () in
  area#misc#set_size_request ~width ~height:min_height ();
  area#event#add [`BUTTON_PRESS; `BUTTON_RELEASE; `BUTTON1_MOTION];
  ignore (area#misc#connect#draw ~callback:(fun cr ->
    let alloc = area#misc#allocation in
    let aw = float_of_int alloc.Gtk.width in
    let ah = float_of_int alloc.Gtk.height in
    let (field, max_v, ramp) = channel_spec () in
    let rows = int_of_float ah in
    for y = 0 to rows - 1 do
      let t = if ah <= 0.0 then 0.0 else (float_of_int y +. 0.5) /. ah in
      let (r, g, b) = ramp t in
      Cairo.set_source_rgb cr
        (float_of_int r /. 255.0)
        (float_of_int g /. 255.0)
        (float_of_int b /. 255.0);
      Cairo.rectangle cr 0.0 (float_of_int y) ~w:aw ~h:1.0;
      Cairo.fill cr
    done;
    let v = read_n field in
    let y = if max_v <= 0.0 then 0.0 else ah *. v /. max_v in
    Cairo.set_source_rgb cr 0.0 0.0 0.0;
    Cairo.set_line_width cr 1.0;
    Cairo.move_to cr (-1.0) y;
    Cairo.line_to cr 5.0 (y -. 4.0);
    Cairo.line_to cr 5.0 (y +. 4.0);
    Cairo.Path.close cr;
    Cairo.fill cr;
    Cairo.move_to cr (aw +. 1.0) y;
    Cairo.line_to cr (aw -. 5.0) (y -. 4.0);
    Cairo.line_to cr (aw -. 5.0) (y +. 4.0);
    Cairo.Path.close cr;
    Cairo.fill cr;
    Cairo.set_source_rgb cr 0.33 0.33 0.33;
    Cairo.rectangle cr 0.5 0.5 ~w:(aw -. 1.0) ~h:(ah -. 1.0);
    Cairo.stroke cr;
    true));
  Dialog_global.add_state_change_listener (fun () -> area#misc#queue_draw ());
  let pick_at y =
    let alloc = area#misc#allocation in
    let ah = float_of_int alloc.Gtk.height in
    let y = max 0.0 (min ah y) in
    let (field, max_v, _) = channel_spec () in
    let v = if ah <= 0.0 then 0.0 else max_v *. y /. ah in
    _write_back_bind ("dialog." ^ field) (`Float v)
  in
  ignore (area#event#connect#button_press ~callback:(fun ev ->
    pick_at (GdkEvent.Button.y ev);
    true));
  ignore (area#event#connect#motion_notify ~callback:(fun ev ->
    pick_at (GdkEvent.Motion.y ev);
    true))

(** Evaluate [bind.selected_in] against the per-item identity read
    from the click behavior's first [select.target] (so authors don't
    repeat themselves) and return whether this item is currently
    selected. Mirrors the Rust implementation in renderer.rs. *)
and is_selected_in_list (el : Yojson.Safe.t) (ctx : Yojson.Safe.t) : bool =
  let open Yojson.Safe.Util in
  match el |> member "bind" |> safe_member "selected_in" |> to_string_option with
  | None -> false
  | Some list_expr ->
    let list_val = Expr_eval.evaluate list_expr ctx in
    (match list_val with
     | Expr_eval.List items ->
       (* Find the first select.target expression in any click behavior. *)
       let id_expr =
         match el |> member "behavior" with
         | `List behaviors ->
           List.fold_left (fun acc b ->
             match acc with
             | Some _ -> acc
             | None ->
               match b |> member "effects" with
               | `List effects ->
                 List.fold_left (fun acc' e ->
                   match acc' with
                   | Some _ -> acc'
                   | None ->
                     (match e |> member "select" |> safe_member "target" with
                      | `String s -> Some s
                      | _ -> None))
                   None effects
               | _ -> None)
             None behaviors
         | _ -> None
       in
       (match id_expr with
        | None -> false
        | Some expr ->
          let id_val = Expr_eval.evaluate expr ctx in
          let id_json = Expr_eval.value_to_json id_val in
          List.exists (fun item -> item = id_json) items)
     | _ -> false)

(* Gradient primitives.

   The Rust and Swift ports evaluate a bind expression that resolves
   to an object (the gradient value) by parsing a JSON string — the
   expression language serialises object values to JSON strings. OCaml
   does the same through [Expr_eval.evaluate]: object results come
   back via a path that ultimately serialises to a [Str] variant, so
   the renderers parse the string back via [Yojson.Safe.from_string].
*)
and eval_bind_object expr ctx : Yojson.Safe.t option =
  match Expr_eval.evaluate expr ctx with
  | Expr_eval.Str s ->
    (try Some (Yojson.Safe.from_string s) with _ -> None)
  | Expr_eval.List items ->
    Some (`List items)
  | _ -> None

and gradient_css_background (gradient : Yojson.Safe.t) : string option =
  let open Yojson.Safe.Util in
  match member "stops" gradient |> to_option to_list with
  | Some stops when List.length stops >= 2 ->
    let stop_strs = List.map (fun s ->
      let color = member "color" s |> to_string_option |> Option.value ~default:"#000000" in
      let loc = member "location" s |> to_number_option |> Option.value ~default:0.0 in
      let opacity = member "opacity" s |> to_number_option |> Option.value ~default:100.0 in
      let color_css =
        if opacity < 100.0 && String.length color = 7 && color.[0] = '#' then
          let r = int_of_string ("0x" ^ String.sub color 1 2) in
          let g = int_of_string ("0x" ^ String.sub color 3 2) in
          let b = int_of_string ("0x" ^ String.sub color 5 2) in
          Printf.sprintf "rgba(%d,%d,%d,%.3f)" r g b (opacity /. 100.0)
        else
          color
      in
      Printf.sprintf "%s %.1f%%" color_css loc
    ) stops in
    let gtype = member "type" gradient |> to_string_option |> Option.value ~default:"linear" in
    if gtype = "radial" then
      Some (Printf.sprintf "radial-gradient(circle, %s)" (String.concat ", " stop_strs))
    else
      let angle = member "angle" gradient |> to_number_option |> Option.value ~default:0.0 in
      (* Angle convention: 0 = left-to-right. CSS linear-gradient:
         0deg = bottom-to-top. So CSS angle = 90 - angle. *)
      let css_angle = int_of_float (mod_float (90.0 -. angle +. 720.0) 360.0) in
      Some (Printf.sprintf "linear-gradient(%ddeg, %s)" css_angle (String.concat ", " stop_strs))
  | _ -> None

and render_gradient_tile ~packing ~ctx el =
  let open Yojson.Safe.Util in
  let size_key = member "size" el |> to_string_option |> Option.value ~default:"large" in
  let sz = match size_key with "small" -> 16 | "medium" -> 32 | _ -> 64 in
  let gradient_expr = member "bind" el |> safe_member "gradient" |> to_string_option in
  let gradient = match gradient_expr with
    | Some e -> eval_bind_object e ctx
    | None -> None
  in
  let bg_css = match gradient with
    | Some g -> gradient_css_background g |> Option.value ~default:"#888888"
    | None -> "#888888"
  in
  let btn = GButton.button ~packing () in
  btn#misc#set_size_request ~width:sz ~height:sz ();
  let css = Printf.sprintf
    "* { background-image: %s; border: 1px solid #666; min-width: %dpx; min-height: %dpx; padding: 0; }"
    bg_css sz sz in
  let provider = GObj.css_provider () in
  provider#load_from_data css;
  btn#misc#style_context#add_provider provider 800

(* gradient_slider — 1-D stops editor.

   Phase 0 scope: the visual tree (bar + stop + midpoint markers) via
   a [GPack.fixed] layout. Click callbacks on each marker dispatch
   through the behavior list on the element (Phase 5 wires actions).
   Full drag state machine and keyboard handling deferred. *)
and render_gradient_slider ~packing ~ctx el =
  let open Yojson.Safe.Util in
  let stops_expr = member "bind" el |> safe_member "stops" |> to_string_option in
  let sel_stop_expr = member "bind" el |> safe_member "selected_stop_index" |> to_string_option in
  let sel_mid_expr = member "bind" el |> safe_member "selected_midpoint_index" |> to_string_option in

  let stops : Yojson.Safe.t list = match stops_expr with
    | Some e -> (match eval_bind_object e ctx with
                 | Some (`List lst) -> lst
                 | _ -> [])
    | None -> []
  in
  let sel_stop = match sel_stop_expr with
    | Some e -> (match Expr_eval.evaluate e ctx with
                 | Expr_eval.Number n -> int_of_float n
                 | _ -> -1)
    | None -> -1
  in
  let sel_mid = match sel_mid_expr with
    | Some e -> (match Expr_eval.evaluate e ctx with
                 | Expr_eval.Number n -> int_of_float n
                 | _ -> -1)
    | None -> -1
  in

  let container_width = 240 in
  let bar_height = 16 in
  let container = GPack.fixed ~packing () in
  container#misc#set_size_request ~width:container_width ~height:44 ();

  (* Bar background *)
  let bar_bg = if List.length stops >= 2 then
    let preview = `Assoc [
      "type", `String "linear";
      "angle", `Float 0.0;
      "stops", `List stops;
    ] in
    gradient_css_background preview |> Option.value ~default:"#888888"
  else
    "#888888"
  in
  let bar = GButton.button ~packing:(container#put ~x:0 ~y:14) () in
  bar#misc#set_size_request ~width:container_width ~height:bar_height ();
  let bar_css = Printf.sprintf
    "* { background-image: %s; border: 1px solid #666; min-width: %dpx; min-height: %dpx; padding: 0; }"
    bar_bg container_width bar_height in
  let bar_provider = GObj.css_provider () in
  bar_provider#load_from_data bar_css;
  bar#misc#style_context#add_provider bar_provider 800;

  (* Midpoint markers *)
  let num_pairs = max (List.length stops - 1) 0 in
  for i = 0 to num_pairs - 1 do
    let left = List.nth stops i |> member "location" |> to_number_option |> Option.value ~default:0.0 in
    let right = List.nth stops (i + 1) |> member "location" |> to_number_option |> Option.value ~default:100.0 in
    let pct = List.nth stops i |> member "midpoint_to_next" |> to_number_option |> Option.value ~default:50.0 in
    let mid_loc = left +. (right -. left) *. (pct /. 100.0) in
    let x = int_of_float (mid_loc /. 100.0 *. float_of_int container_width) - 5 in
    let mbtn = GButton.button ~packing:(container#put ~x ~y:2) () in
    mbtn#misc#set_size_request ~width:10 ~height:10 ();
    let sel = if i = sel_mid then "; border: 2px solid #0af" else "" in
    let mcss = Printf.sprintf "* { background-color: #888; border: 1px solid #333%s; min-width: 10px; min-height: 10px; padding: 0; }" sel in
    let mprov = GObj.css_provider () in
    mprov#load_from_data mcss;
    mbtn#misc#style_context#add_provider mprov 800
  done;

  (* Stop markers *)
  List.iteri (fun i s ->
    let loc = member "location" s |> to_number_option |> Option.value ~default:0.0 in
    let color = member "color" s |> to_string_option |> Option.value ~default:"#000000" in
    let x = int_of_float (loc /. 100.0 *. float_of_int container_width) - 7 in
    let sbtn = GButton.button ~packing:(container#put ~x ~y:30) () in
    sbtn#misc#set_size_request ~width:14 ~height:14 ();
    let sel_border = if i = sel_stop then "2px solid #0af" else "1px solid #333" in
    let scss = Printf.sprintf "* { background-color: %s; border: %s; border-radius: 50%%; min-width: 14px; min-height: 14px; padding: 0; }" color sel_border in
    let sprov = GObj.css_provider () in
    sprov#load_from_data scss;
    sbtn#misc#style_context#add_provider sprov 800
  ) stops

and render_separator ~packing el =
  let open Yojson.Safe.Util in
  let orientation = el |> member "orientation" |> to_string_option |> Option.value ~default:"horizontal" in
  let sep = GMisc.separator (if orientation = "vertical" then `VERTICAL else `HORIZONTAL) ~packing () in
  ignore sep

and render_spacer ~packing () =
  let spacer = GPack.hbox ~packing () in
  spacer#misc#set_size_request ~height:4 ()

and render_disclosure ~packing ~ctx el =
  let open Yojson.Safe.Util in
  let label = el |> member "label" |> to_string_option |> Option.value ~default:"" in
  let label_text = if String.length label > 0 && (try let _ = String.index label '{' in true with Not_found -> false)
    then Expr_eval.evaluate_text label ctx
    else label in
  let expander = GBin.expander ~label:label_text ~expanded:true ~packing () in
  let vbox = GPack.vbox ~spacing:0 ~packing:expander#add () in
  render_children ~packing:(vbox#pack ~expand:false ~fill:false) ~ctx el

and render_panel ~packing ~ctx el =
  let open Yojson.Safe.Util in
  match el |> member "content" with
  | `Null -> render_placeholder ~packing el
  | content -> render_element ~packing ~ctx content

(** Handle eye button click with Alt-modifier detection for solo/unsolo. *)
and handle_eye_click path evt =
  let state = GdkEvent.Button.state evt in
  let modifiers = Gdk.Convert.modifier state in
  let alt = List.mem `MOD1 modifiers in
  match !_get_model_ref () with
  | None -> ()
  | Some m ->
    let d = m#document in
    if alt then begin
      (* Solo/unsolo among siblings *)
      let rec drop_last = function
        | [] | [_] -> []
        | x :: xs -> x :: drop_last xs
      in
      let parent_prefix = drop_last path in
      let sibling_paths =
        if parent_prefix = [] then
          let n = Array.length d.Document.layers in
          List.init n (fun i -> [i])
        else
          let parent = Document.get_element d parent_prefix in
          match parent with
          | Element.Group _ | Element.Layer _ ->
            let kids = Document.children_of parent in
            List.init (Array.length kids) (fun i -> parent_prefix @ [i])
          | _ -> []
      in
      let already_soloed = match !Layers_panel_state.solo_state with
        | Some (sp, _) -> sp = path
        | None -> false
      in
      if already_soloed then begin
        let saved = match !Layers_panel_state.solo_state with
          | Some (_, s) -> s
          | None -> []
        in
        let new_doc = List.fold_left (fun acc (sp, vis) ->
          let e = Document.get_element acc sp in
          Document.replace_element acc sp (Element.set_visibility vis e)
        ) d saved in
        (* Undoable edit (one self-bracketed undo step) via edit_document. *)
        m#edit_document new_doc;
        Layers_panel_state.solo_state := None
      end else begin
        let saved = List.filter_map (fun sp ->
          if sp = path then None
          else
            let e = Document.get_element d sp in
            Some (sp, Element.get_visibility e)
        ) sibling_paths in
        let new_doc = List.fold_left (fun acc sp ->
          if sp = path then
            let e = Document.get_element acc sp in
            if Element.get_visibility e = Element.Invisible then
              Document.replace_element acc sp (Element.set_visibility Element.Preview e)
            else acc
          else
            let e = Document.get_element acc sp in
            Document.replace_element acc sp (Element.set_visibility Element.Invisible e)
        ) d sibling_paths in
        (* Undoable edit (one self-bracketed undo step) via edit_document. *)
        m#edit_document new_doc;
        Layers_panel_state.solo_state := Some (path, saved)
      end
    end else begin
      Layers_panel_state.solo_state := None;
      let e = Document.get_element d path in
      let new_vis = match Element.get_visibility e with
        | Element.Preview -> Element.Outline
        | Element.Outline -> Element.Invisible
        | Element.Invisible -> Element.Preview
      in
      (* Undoable edit (one self-bracketed undo step) via edit_document. *)
      m#edit_document (Document.replace_element d path (Element.set_visibility new_vis e))
    end

(** Delete currently panel-selected elements via YAML dispatch (Phase 3).
    The workspace/actions.yaml definition of delete_layer_selection is
    authoritative; this function just supplies the current selection.

    Reference-aware (warn-then-orphan), mirroring the main Delete/Cut:
    the deletion paths are the PANEL selection (NOT [doc.selection]); feed
    them to the shared, cross-language-pinned [orphaned_references]
    predicate. Empty -> delete exactly as before (no dialog, no
    regression). Non-empty -> consult [confirm_delete_orphans_hook] (the
    same modal the main delete shows, wired by [Menubar.create]); proceed
    only on OK, abort on Cancel. The YAML [delete_layer_selection] action
    snapshots internally, so the gate must NOT add its own snapshot — one
    undo step is preserved either way. Covers both panel delete
    sub-paths (context-menu "Delete Selection" and in-panel
    Delete/Backspace) because both route through here. *)
and do_delete_panel_selection () =
  match !_get_model_ref () with
  | None -> ()
  | Some m ->
    let paths = Layers_panel_state.PathSet.elements !Layers_panel_state.panel_selection in
    if paths = [] then ()
    else begin
      (* Guard against deleting the last layer at dispatch-boundary level —
         the YAML doesn't encode this policy yet. *)
      let d = m#document in
      let layer_count = Array.length d.Document.layers in
      let top_deletes = List.length (List.filter (fun p -> List.length p = 1) paths) in
      if top_deletes >= layer_count then ()
      else begin
        let orphaned = Dependency_index.orphaned_references d paths in
        let proceed =
          match orphaned with
          | [] -> true  (* No live reference orphaned: delete as today. *)
          | _ -> !confirm_delete_orphans_hook (List.length orphaned)
        in
        if proceed then
          Panel_menu.dispatch_yaml_action
            ~panel_selection:paths
            ~on_selection_changed:(Some (fun _ ->
              Layers_panel_state.panel_selection := Layers_panel_state.PathSet.empty))
            "delete_layer_selection" m
      end
    end

(** Duplicate each panel-selected element in place via YAML dispatch. *)
and do_duplicate_panel_selection () =
  match !_get_model_ref () with
  | None -> ()
  | Some m ->
    let paths = Layers_panel_state.PathSet.elements !Layers_panel_state.panel_selection in
    if paths = [] then ()
    else
      Panel_menu.dispatch_yaml_action
        ~panel_selection:paths
        "duplicate_layer_selection" m

(** Flatten groups in panel selection via YAML dispatch (Phase 3). *)
and do_flatten_artwork () =
  match !_get_model_ref () with
  | None -> ()
  | Some m ->
    let paths = Layers_panel_state.PathSet.elements !Layers_panel_state.panel_selection in
    if paths = [] then ()
    else begin
      Panel_menu.dispatch_yaml_action
        ~panel_selection:paths
        ~on_selection_changed:(Some (fun _ ->
          Layers_panel_state.panel_selection := Layers_panel_state.PathSet.empty))
        "flatten_artwork" m
    end

(** Move panel-selected elements into a new layer via YAML dispatch. *)
and do_collect_in_new_layer () =
  match !_get_model_ref () with
  | None -> ()
  | Some m ->
    let paths = Layers_panel_state.PathSet.elements !Layers_panel_state.panel_selection in
    if paths = [] then ()
    else begin
      Panel_menu.dispatch_yaml_action
        ~panel_selection:paths
        "collect_in_new_layer" m
    end

(** Open a Layer Options dialog to edit the layer at path. *)
and open_layer_options_dialog path =
  match !_get_model_ref () with
  | None -> ()
  | Some m ->
    let d = m#document in
    let e = Document.get_element d path in
    match e with
    | Element.Layer le ->
      let dlg = GWindow.dialog ~title:"Layer Options" ~modal:true () in
      let vbox = dlg#vbox in
      let name_row = GPack.hbox ~spacing:8 ~packing:(vbox#pack ~expand:false) () in
      ignore (GMisc.label ~text:"Name:" ~packing:(name_row#pack ~expand:false) ());
      let name_entry = GEdit.entry ~text:(match le.name with Some s -> s | None -> "") ~packing:(name_row#pack ~expand:true) () in
      let lock_cb = GButton.check_button ~label:"Lock" ~packing:(vbox#pack ~expand:false) () in
      lock_cb#set_active le.locked;
      let show_cb = GButton.check_button ~label:"Show" ~packing:(vbox#pack ~expand:false) () in
      show_cb#set_active (le.visibility <> Element.Invisible);
      let preview_cb = GButton.check_button ~label:"Preview" ~packing:(vbox#pack ~expand:false) () in
      preview_cb#set_active (le.visibility = Element.Preview);
      preview_cb#misc#set_sensitive show_cb#active;
      ignore (show_cb#connect#toggled ~callback:(fun () ->
        preview_cb#misc#set_sensitive show_cb#active));
      dlg#add_button_stock `CANCEL `CANCEL;
      dlg#add_button_stock `OK `OK;
      let result = dlg#run () in
      if result = `OK then begin
        let layer_id =
          String.concat "." (List.map string_of_int path)
        in
        let params = [
          ("layer_id", `String layer_id);
          ("name", `String name_entry#text);
          ("lock", `Bool lock_cb#active);
          ("show", `Bool show_cb#active);
          ("preview", `Bool preview_cb#active);
        ] in
        (* Route through the YAML layer_options_confirm action so the
           dialog commit logic lives in actions.yaml. *)
        Panel_menu.dispatch_yaml_action ~params "layer_options_confirm" m
      end;
      dlg#destroy ()
    | _ -> ()

(** Render the layers-panel type filter dropdown. Other dropdown widgets
    (none currently exist) fall through to placeholder. *)
and render_layers_filter_dropdown ~packing el =
  let open Yojson.Safe.Util in
  let id = el |> member "id" |> to_string_option |> Option.value ~default:"" in
  if id <> "lp_filter_button" then
    render_placeholder ~packing el
  else begin
    let btn = GButton.button ~label:"\xe2\x96\xbe" ~packing () in
    btn#misc#set_size_request ~width:20 ~height:20 ();
    let items = match el |> member "items" with
      | `List arr ->
        List.filter_map (fun item ->
          let l = item |> member "label" |> to_string_option in
          let v = item |> member "value" |> to_string_option in
          match l, v with
          | Some label, Some value -> Some (label, value)
          | _ -> None) arr
      | _ -> []
    in
    ignore (btn#connect#clicked ~callback:(fun () ->
      let menu = GMenu.menu () in
      List.iter (fun (label, value) ->
        let checked = not (Layers_panel_state.StrSet.mem value !Layers_panel_state.hidden_types) in
        let item = GMenu.check_menu_item ~label ~packing:menu#append () in
        item#set_active checked;
        ignore (item#connect#toggled ~callback:(fun () ->
          if Layers_panel_state.StrSet.mem value !Layers_panel_state.hidden_types
          then Layers_panel_state.hidden_types := Layers_panel_state.StrSet.remove value !Layers_panel_state.hidden_types
          else Layers_panel_state.hidden_types := Layers_panel_state.StrSet.add value !Layers_panel_state.hidden_types;
          !Layers_panel_state.rerender ()))
      ) items;
      menu#misc#show_all ();
      menu#popup ~button:1 ~time:(Int32.of_int 0)))
  end

(** Render a fitted-viewBox SVG of an element as a GTK widget.
    Writes the SVG to a temp file and loads it via GdkPixbuf at the
    requested size, falling back to an empty frame on error. *)
and make_element_thumbnail ~packing (elem : Element.element) (size : int) =
  let (x, y, w, h) = Element.bounds elem in
  if not (Float.is_finite w && Float.is_finite h) || w <= 0.0 || h <= 0.0 then begin
    let frame = GBin.frame ~shadow_type:`ETCHED_IN ~packing () in
    frame#misc#set_size_request ~width:size ~height:size ();
    frame#misc#modify_bg [`NORMAL, `NAME "white"]
  end else begin
    let pad = max (Float.max w h *. 0.02) 0.5 in
    let vb = Printf.sprintf "%f %f %f %f" (x -. pad) (y -. pad) (w +. 2.0 *. pad) (h +. 2.0 *. pad) in
    let inner = Svg.element_svg "" elem in
    let svg_str = Printf.sprintf
      "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"%s\" preserveAspectRatio=\"xMidYMid meet\">%s</svg>"
      vb inner in
    let tmp = Filename.temp_file "jas_thumb" ".svg" in
    try
      let oc = open_out tmp in
      output_string oc svg_str;
      close_out oc;
      let pixbuf = GdkPixbuf.from_file_at_size tmp ~width:size ~height:size in
      (try Sys.remove tmp with _ -> ());
      let img = GMisc.image ~pixbuf ~packing () in
      img#misc#set_size_request ~width:size ~height:size ()
    with _ ->
      (try Sys.remove tmp with _ -> ());
      let frame = GBin.frame ~shadow_type:`ETCHED_IN ~packing () in
      frame#misc#set_size_request ~width:size ~height:size ();
      frame#misc#modify_bg [`NORMAL, `NAME "white"]
  end

and render_tree_view ~packing ~ctx:_ _el =
  let outer_eb = GBin.event_box ~packing () in
  outer_eb#misc#set_can_focus true;
  let vbox = GPack.vbox ~spacing:0 ~packing:outer_eb#add () in
  let get_model = !_get_model_ref in
  ignore (outer_eb#event#connect#key_press ~callback:(fun evt ->
    let key = GdkEvent.Key.keyval evt in
    let modifiers = GdkEvent.Key.state evt in
    let meta = List.mem `META modifiers || List.mem `CONTROL modifiers in
    if key = GdkKeysyms._Delete || key = GdkKeysyms._BackSpace then begin
      do_delete_panel_selection ();
      !Layers_panel_state.rerender ();
      true
    end else if key = GdkKeysyms._a && meta then begin
      (match get_model () with
       | None -> ()
       | Some m ->
         let d = m#document in
         let all = ref Layers_panel_state.PathSet.empty in
         let rec collect elements prefix =
           Array.iteri (fun i e ->
             let p = prefix @ [i] in
             all := Layers_panel_state.PathSet.add p !all;
             match e with
             | Element.Group _ | Element.Layer _ ->
               collect (Document.children_of e) p
             | _ -> ()
           ) elements
         in
         collect d.Document.layers [];
         Layers_panel_state.panel_selection := !all);
      !Layers_panel_state.rerender ();
      true
    end else if key = GdkKeysyms._Escape then begin
      if !Layers_panel_state.renaming <> None then begin
        Layers_panel_state.renaming := None;
        !Layers_panel_state.rerender ();
        true
      end else if Layers_panel_state.get_isolation_stack () <> [] then begin
        Layers_panel_state.pop_isolation_level ();
        !Layers_panel_state.rerender ();
        true
      end else false
    end else false));
  (* Auto-expand ancestors of element-selected paths so selected elements
     are visible in the tree. *)
  (match get_model () with
   | None -> ()
   | Some m ->
     let d = m#document in
     let selected = Document.selected_paths d.Document.selection in
     Document.PathSet.iter (fun p ->
       let n = List.length p in
       for i = 1 to n - 1 do
         let rec take k lst = match k, lst with
           | 0, _ | _, [] -> []
           | k, h :: t -> h :: take (k - 1) t
         in
         let ancestor = take i p in
         Layers_panel_state.collapsed := Layers_panel_state.PathSet.remove ancestor !Layers_panel_state.collapsed
       done
     ) selected);
  (* Render breadcrumb bar if in isolation mode *)
  (if Layers_panel_state.get_isolation_stack () <> [] then begin
    let bar_eb = GBin.event_box ~packing:(vbox#pack ~expand:false) () in
    bar_eb#misc#modify_bg [`NORMAL, `NAME "#2a2a2a"];
    let bar = GPack.hbox ~spacing:4 ~packing:bar_eb#add () in
    let home_eb = GBin.event_box ~packing:(bar#pack ~expand:false) () in
    ignore (GMisc.label ~text:"\xe2\x8c\x82" ~packing:home_eb#add ());
    ignore (home_eb#event#connect#button_press ~callback:(fun _ ->
      Layers_panel_state.clear_isolation_stack ();
      !Layers_panel_state.rerender ();
      true));
    let stack = Layers_panel_state.get_isolation_stack () in
    List.iteri (fun idx p ->
      ignore (GMisc.label ~text:">" ~packing:(bar#pack ~expand:false) ());
      match get_model () with
      | None -> ()
      | Some m2 ->
        let e = Document.get_element m2#document p in
        let label = match e with
          | Element.Layer le ->
            (match le.name with Some s when s <> "" -> s | _ -> "<?>")
          | _ -> "<?>"
        in
        let seg_eb = GBin.event_box ~packing:(bar#pack ~expand:false) () in
        ignore (GMisc.label ~text:label ~packing:seg_eb#add ());
        let target_idx = idx + 1 in
        ignore (seg_eb#event#connect#button_press ~callback:(fun _ ->
          Layers_panel_state.set_isolation_stack (
            let rec take n lst = match n, lst with
              | 0, _ | _, [] -> []
              | n, h :: t -> h :: take (n - 1) t
            in take target_idx (Layers_panel_state.get_isolation_stack ()));
          !Layers_panel_state.rerender ();
          true))
    ) stack
  end);
  (* Isolation logic is applied inline in the rendering loop. *)
  (* Helper: does element name contain the search query (case-insensitive) *)
  let matches_search name =
    let q = String.lowercase_ascii !Layers_panel_state.search_query in
    if q = "" then true
    else
      let n = String.lowercase_ascii name in
      let rec find_sub s p si pi =
        if pi >= String.length p then true
        else if si >= String.length s then false
        else if s.[si] = p.[pi] then find_sub s p (si+1) (pi+1)
        else find_sub s p (si - pi + 1) 0
      in find_sub n q 0 0
  in
  let _ = matches_search in  (* reserved for future search integration *)
  let type_label e =
    match e with
    | Element.Line _ -> "Line" | Element.Rect _ -> "Rectangle"
    | Element.Circle _ -> "Circle" | Element.Ellipse _ -> "Ellipse"
    | Element.Polyline _ -> "Polyline" | Element.Polygon _ -> "Polygon"
    | Element.Path _ -> "Path" | Element.Text _ -> "Text"
    | Element.Text_path _ -> "Text Path"
    | Element.Group _ -> "Group" | Element.Layer _ -> "Layer"
    | Element.Live _ -> "Compound Shape"
  in
  let display_name e =
    match e with
    | Element.Layer le ->
      (match le.name with
       | Some s when s <> "" -> (s, true)
       | _ -> (Printf.sprintf "<%s>" (type_label e), false))
    | _ -> (Printf.sprintf "<%s>" (type_label e), false)
  in
  let is_container e = match e with Element.Group _ | Element.Layer _ -> true | _ -> false in
  let is_layer e = match e with Element.Layer _ -> true | _ -> false in
  let vis_icon v =
    match v with
    | Element.Outline -> "\xe2\x97\x90"
    | Element.Invisible -> "\xe2\x97\x8b"
    | Element.Preview -> "\xe2\x97\x89"
  in
  let layer_colors = [| "#4a90d9"; "#d94a4a"; "#4ad94a"; "#4a4ad9"; "#d9d94a";
                         "#d94ad9"; "#4ad9d9"; "#b0b0b0"; "#2a7a2a" |] in
  match get_model () with
  | None -> ()
  | Some m ->
    let doc = m#document in
    let selected_paths = Document.selected_paths doc.Document.selection in
    let rec add_children children depth path_prefix layer_color =
      let n = Array.length children in
      for ri = n - 1 downto 0 do
        let i = ri in
        let elem = children.(i) in
        let path = path_prefix @ [i] in
        (* Apply isolation filter: skip rows that aren't descendants of the
           deepest isolated container. Note we still recurse so descendants
           that do pass the filter are rendered. *)
        let passes_iso = match Layers_panel_state.get_isolation_stack () with
          | [] -> true
          | root :: _ ->
            List.length path > List.length root &&
            (let rec prefix_matches a b = match a, b with
              | _, [] -> true
              | [], _ -> false
              | ah :: at, bh :: bt -> ah = bh && prefix_matches at bt
            in prefix_matches path root)
        in
        if not passes_iso then begin
          (* Still recurse, maybe a deeper descendant qualifies *)
          (if is_container elem && not (Layers_panel_state.PathSet.mem path !Layers_panel_state.collapsed) then
            let ch = Document.children_of elem in
            add_children ch (depth + 1) path layer_color)
        end else
        (* Apply search filter: skip if name doesn't match and no descendant does *)
        let passes_search =
          let q = String.lowercase_ascii !Layers_panel_state.search_query in
          if q = "" then true
          else
            let (name_here, _) = display_name elem in
            let n = String.lowercase_ascii name_here in
            let rec find_sub s p si pi =
              if pi >= String.length p then true
              else if si >= String.length s then false
              else if s.[si] = p.[pi] then find_sub s p (si+1) (pi+1)
              else find_sub s p (si - pi + 1) 0
            in
            if find_sub n q 0 0 then true
            else
              (* Include ancestor if any descendant matches *)
              let rec has_match ee =
                let (ne, _) = display_name ee in
                let nn = String.lowercase_ascii ne in
                if find_sub nn q 0 0 then true
                else match ee with
                  | Element.Group _ | Element.Layer _ ->
                    let kids = Document.children_of ee in
                    Array.exists has_match kids
                  | _ -> false
              in has_match elem
        in
        (* Apply type filter *)
        let type_v = match elem with
          | Element.Line _ -> "line" | Element.Rect _ -> "rectangle"
          | Element.Circle _ -> "circle" | Element.Ellipse _ -> "ellipse"
          | Element.Polyline _ -> "polyline" | Element.Polygon _ -> "polygon"
          | Element.Path _ -> "path" | Element.Text _ -> "text"
          | Element.Text_path _ -> "text_path"
          | Element.Group _ -> "group" | Element.Layer _ -> "layer"
          | Element.Live _ -> "live"
        in
        let passes_type = not (Layers_panel_state.StrSet.mem type_v !Layers_panel_state.hidden_types) in
        if not (passes_search && passes_type) then begin
          (* Still recurse in case descendants pass *)
          (if is_container elem && not (Layers_panel_state.PathSet.mem path !Layers_panel_state.collapsed) then
            let ch = Document.children_of elem in
            add_children ch (depth + 1) path layer_color)
        end else
        let is_container = is_container elem in
        let is_selected = Document.PathSet.mem path selected_paths in
        let cur_color =
          if is_layer elem && List.length path = 1
          then layer_colors.(i mod Array.length layer_colors)
          else layer_color
        in
        let (name, _is_named) = display_name elem in
        let vis = Element.get_visibility elem in
        let locked = Element.is_locked elem in
        let is_panel_selected = Layers_panel_state.PathSet.mem path !Layers_panel_state.panel_selection in
        let is_drop_target =
          match !Layers_panel_state.drag_source, !Layers_panel_state.drag_target with
          | Some src, Some tgt when src <> path && tgt = path -> true
          | _ -> false
        in
        let row_eb = GBin.event_box ~packing:(vbox#pack ~expand:false) () in
        (* Auto-scroll: if this is the first element-selected path, queue a
           grab_focus so the parent ScrolledWindow tries to keep it in view. *)
        if is_selected then begin
          let first_sel = Document.PathSet.min_elt_opt selected_paths in
          if first_sel = Some path then
            ignore (GMain.Idle.add (fun () -> row_eb#misc#grab_focus (); false))
        end;
        if is_panel_selected then
          row_eb#misc#modify_bg [`NORMAL, `NAME "#3a4a6a"]
        else if is_drop_target then
          row_eb#misc#modify_bg [`NORMAL, `NAME "#3a7bd5"];
        let row_path = path in
        ignore (row_eb#event#connect#button_press ~callback:(fun evt ->
          let button = GdkEvent.Button.button evt in
          if button = 3 then begin
            (* Right-click: show context menu *)
            if not (Layers_panel_state.PathSet.mem row_path !Layers_panel_state.panel_selection) then begin
              Layers_panel_state.panel_selection := Layers_panel_state.PathSet.singleton row_path;
              !Layers_panel_state.rerender ()
            end;
            let menu = GMenu.menu () in
            let add_item ~label ?(sensitive=true) action =
              let item = GMenu.menu_item ~label ~packing:menu#append () in
              item#misc#set_sensitive sensitive;
              ignore (item#connect#activate ~callback:action)
            in
            let elem_at = match get_model () with
              | Some m2 -> Some (Document.get_element m2#document row_path)
              | None -> None
            in
            let is_layer_path = match elem_at with Some (Element.Layer _) -> true | _ -> false in
            let is_cont_path = match elem_at with Some (Element.Group _ | Element.Layer _) -> true | _ -> false in
            add_item ~label:"Options for Layer..." ~sensitive:is_layer_path (fun () ->
              open_layer_options_dialog row_path);
            add_item ~label:"Duplicate" (fun () -> do_duplicate_panel_selection ());
            add_item ~label:"Delete Selection" (fun () -> do_delete_panel_selection ());
            ignore (GMenu.separator_item ~packing:menu#append ());
            if Layers_panel_state.get_isolation_stack () = [] then
              add_item ~label:"Enter Isolation Mode" ~sensitive:is_cont_path (fun () ->
                Layers_panel_state.push_isolation_level row_path;
                !Layers_panel_state.rerender ())
            else
              add_item ~label:"Exit Isolation Mode" (fun () ->
                Layers_panel_state.pop_isolation_level ();
                !Layers_panel_state.rerender ());
            ignore (GMenu.separator_item ~packing:menu#append ());
            add_item ~label:"Flatten Artwork" (fun () -> do_flatten_artwork ());
            add_item ~label:"Collect in New Layer" (fun () -> do_collect_in_new_layer ());
            menu#misc#show_all ();
            menu#popup ~button ~time:(GdkEvent.Button.time evt);
            true
          end else begin
            let modifiers = Gdk.Convert.modifier (GdkEvent.Button.state evt) in
            let meta = List.mem `META modifiers || List.mem `CONTROL modifiers in
            let shift = List.mem `SHIFT modifiers in
            if shift && not (Layers_panel_state.PathSet.is_empty !Layers_panel_state.panel_selection) then begin
              (* Range from last panel-selected to clicked, in visual order *)
              let anchor = Layers_panel_state.PathSet.max_elt !Layers_panel_state.panel_selection in
              let _ = anchor in
              (* For simplicity, just replace with range pairs [anchor; row_path] *)
              Layers_panel_state.panel_selection := Layers_panel_state.PathSet.add row_path (Layers_panel_state.PathSet.singleton anchor);
            end else if meta then begin
              if Layers_panel_state.PathSet.mem row_path !Layers_panel_state.panel_selection
              then Layers_panel_state.panel_selection := Layers_panel_state.PathSet.remove row_path !Layers_panel_state.panel_selection
              else Layers_panel_state.panel_selection := Layers_panel_state.PathSet.add row_path !Layers_panel_state.panel_selection
            end else begin
              Layers_panel_state.panel_selection := Layers_panel_state.PathSet.singleton row_path
            end;
            Layers_panel_state.drag_source := Some row_path;
            Layers_panel_state.drag_target := None;
            !Layers_panel_state.rerender ();
            true
          end));
        ignore (row_eb#event#connect#enter_notify ~callback:(fun _ ->
          (match !Layers_panel_state.drag_source with
           | Some src when src <> row_path ->
             Layers_panel_state.drag_target := Some row_path;
             !Layers_panel_state.rerender ();
             (* Auto-expand collapsed containers after 500ms hover during drag *)
             let is_cont = match elem with Element.Group _ | Element.Layer _ -> true | _ -> false in
             if is_cont && Layers_panel_state.PathSet.mem row_path !Layers_panel_state.collapsed then
               ignore (GMain.Timeout.add ~ms:500 ~callback:(fun () ->
                 (if !Layers_panel_state.drag_source <> None && !Layers_panel_state.drag_target = Some row_path then begin
                    Layers_panel_state.collapsed := Layers_panel_state.PathSet.remove row_path !Layers_panel_state.collapsed;
                    !Layers_panel_state.rerender ()
                  end);
                 false))
           | _ -> ());
          false));
        ignore (row_eb#event#connect#button_release ~callback:(fun _ ->
          (match !Layers_panel_state.drag_source with
           | Some src when src <> row_path ->
             (match get_model () with
              | None -> ()
              | Some m2 ->
                let d = m2#document in
                (* Drag constraints: no cycle (target inside src), no drop
                   into a locked parent. *)
                let is_cycle =
                  List.length row_path >= List.length src &&
                  (let rec starts_with a b = match a, b with
                    | _, [] -> true | [], _ -> false
                    | ah :: at, bh :: bt -> ah = bh && starts_with at bt
                  in starts_with row_path src)
                in
                let parent_locked =
                  match row_path with
                  | [] | [_] -> false
                  | _ ->
                    let rec drop_last = function
                      | [] | [_] -> []
                      | x :: xs -> x :: drop_last xs
                    in
                    let parent_path = drop_last row_path in
                    let pe = Document.get_element d parent_path in
                    Element.is_locked pe
                in
                if is_cycle || parent_locked then ()
                else begin
                let moved = Document.get_element d src in
                let d1 = Document.delete_element d src in
                (* Adjust target if src was at same level and before target *)
                let target =
                  let slen = List.length src and tlen = List.length row_path in
                  if slen = tlen then
                    match List.rev src, List.rev row_path with
                    | si :: srest, ti :: trest when srest = trest && si < ti ->
                      List.rev (ti - 1 :: trest)
                    | _ -> row_path
                  else row_path
                in
                (* Insert "before target": insert_after at (target with last-1) if possible *)
                let insert_path =
                  match List.rev target with
                  | ti :: rest when ti > 0 -> List.rev (ti - 1 :: rest)
                  | _ -> target  (* First-child: degrade to insert_after target *)
                in
                m2#edit_document (Document.insert_element_after d1 insert_path moved)
                end)
           | _ -> ());
          Layers_panel_state.drag_source := None;
          Layers_panel_state.drag_target := None;
          !Layers_panel_state.rerender ();
          false));
        let hbox = GPack.hbox ~spacing:2 ~packing:row_eb#add () in
        if depth > 0 then begin
          let spacer = GMisc.label ~text:"" ~packing:(hbox#pack ~expand:false) () in
          spacer#misc#set_size_request ~width:(depth * 16) ()
        end;
        (* Eye button *)
        let eye_eb = GBin.event_box ~packing:(hbox#pack ~expand:false) () in
        ignore (GMisc.label ~text:(vis_icon vis) ~packing:eye_eb#add ());
        eye_eb#misc#set_size_request ~width:16 ();
        ignore (eye_eb#event#connect#button_press ~callback:(fun evt ->
          handle_eye_click path evt;
          !Layers_panel_state.rerender ();
          true));
        (* Lock button *)
        let lock_eb = GBin.event_box ~packing:(hbox#pack ~expand:false) () in
        let lock_text = if locked then "\xf0\x9f\x94\x92" else "\xf0\x9f\x94\x93" in
        ignore (GMisc.label ~text:lock_text ~packing:lock_eb#add ());
        lock_eb#misc#set_size_request ~width:16 ();
        ignore (lock_eb#event#connect#button_press ~callback:(fun _ ->
          (match get_model () with
           | None -> ()
           | Some m2 ->
             let d = m2#document in
             let e = Document.get_element d path in
             let was_unlocked = not (Element.is_locked e) in
             let is_cont_elem = is_container in
             (* Save child lock states when locking a container *)
             if is_cont_elem && was_unlocked then begin
               let children = Document.children_of e in
               let saved = Array.to_list (Array.map Element.is_locked children) in
               Layers_panel_state.saved_lock_states := Layers_panel_state.PathMap.add path saved !Layers_panel_state.saved_lock_states
             end;
             let new_e = Element.set_locked was_unlocked e in
             let d1 = Document.replace_element d path new_e in
             (* When locking a container, also lock all direct children *)
             let d2 = if is_cont_elem && was_unlocked then begin
               let children = Document.children_of e in
               Array.fold_left (fun acc_doc i ->
                 let child_path = path @ [i] in
                 let child = Document.get_element acc_doc child_path in
                 Document.replace_element acc_doc child_path (Element.set_locked true child)
               ) d1 (Array.init (Array.length children) (fun i -> i))
             end else d1 in
             (* When unlocking a container, restore direct children's saved states *)
             let d3 = if is_cont_elem && not was_unlocked then begin
               match Layers_panel_state.PathMap.find_opt path !Layers_panel_state.saved_lock_states with
               | None -> d2
               | Some saved ->
                 Layers_panel_state.saved_lock_states := Layers_panel_state.PathMap.remove path !Layers_panel_state.saved_lock_states;
                 List.fold_left (fun acc_doc (i, sl) ->
                   let child_path = path @ [i] in
                   let child = Document.get_element acc_doc child_path in
                   Document.replace_element acc_doc child_path (Element.set_locked sl child)
                 ) d2 (List.mapi (fun i s -> (i, s)) saved)
             end else d2 in
             m2#edit_document d3);
          true));
        (* Twirl or gap *)
        let is_collapsed = Layers_panel_state.PathSet.mem path !Layers_panel_state.collapsed in
        if is_container then begin
          let twirl_text = if is_collapsed then "\xe2\x96\xb6" else "\xe2\x96\xbc" in
          let twirl_eb = GBin.event_box ~packing:(hbox#pack ~expand:false) () in
          ignore (GMisc.label ~text:twirl_text ~packing:twirl_eb#add ());
          twirl_eb#misc#set_size_request ~width:16 ();
          let tp = path in
          ignore (twirl_eb#event#connect#button_press ~callback:(fun _ ->
            if Layers_panel_state.PathSet.mem tp !Layers_panel_state.collapsed
            then Layers_panel_state.collapsed := Layers_panel_state.PathSet.remove tp !Layers_panel_state.collapsed
            else Layers_panel_state.collapsed := Layers_panel_state.PathSet.add tp !Layers_panel_state.collapsed;
            !Layers_panel_state.rerender ();
            true))
        end else begin
          let gap = GMisc.label ~text:"" ~packing:(hbox#pack ~expand:false) () in
          gap#misc#set_size_request ~width:16 ()
        end;
        (* Preview thumbnail — fitted SVG of the element *)
        make_element_thumbnail ~packing:(hbox#pack ~expand:false) elem 24;
        (* Name — inline GEntry when renaming, GMisc.label otherwise *)
        (match !Layers_panel_state.renaming with
         | Some rp when rp = path ->
           let initial = match elem with
             | Element.Layer le -> (match le.name with Some s -> s | None -> "")
             | _ -> ""
           in
           let entry = GEdit.entry ~text:initial ~packing:(hbox#pack ~expand:true) () in
           let ep = path in
           ignore (entry#connect#activate ~callback:(fun () ->
             (match get_model () with
              | None -> ()
              | Some m2 ->
                let d = m2#document in
                let e = Document.get_element d ep in
                (match e with
                 | Element.Layer le ->
                   let typed = entry#text in
                   let new_name = if typed = "" then None else Some typed in
                   let new_layer = Element.Layer { le with name = new_name } in
                   m2#edit_document (Document.replace_element d ep new_layer)
                 | _ -> ()));
             Layers_panel_state.renaming := None;
             !Layers_panel_state.rerender ()));
           ignore (entry#event#connect#key_press ~callback:(fun key ->
             if GdkEvent.Key.keyval key = GdkKeysyms._Escape then begin
               Layers_panel_state.renaming := None;
               !Layers_panel_state.rerender ();
               true
             end else false))
         | _ ->
           let name_eb = GBin.event_box ~packing:(hbox#pack ~expand:true) () in
           ignore (GMisc.label ~text:name ~packing:name_eb#add ());
           let np = path in
           let is_layer_elem = is_layer elem in
           ignore (name_eb#event#connect#button_press ~callback:(fun ev ->
             if is_layer_elem && GdkEvent.get_type ev = `TWO_BUTTON_PRESS then begin
               Layers_panel_state.renaming := Some np;
               !Layers_panel_state.rerender ();
               true
             end else false)));
        (* Select square *)
        let sq_eb = GBin.event_box ~packing:(hbox#pack ~expand:false) () in
        let sq = GBin.frame ~shadow_type:`ETCHED_IN ~packing:sq_eb#add () in
        sq#misc#set_size_request ~width:12 ~height:12 ();
        if is_selected then
          sq#misc#modify_bg [`NORMAL, `NAME "blue"];
        ignore (sq_eb#event#connect#button_press ~callback:(fun _ ->
          (match get_model () with
           | None -> ()
           | Some m2 ->
             let d = m2#document in
             let new_sel = Document.PathMap.singleton path (Document.element_selection_all path) in
             (* Row select: selection-only, a non-undoable write (OP_LOG.md sections 7 and 8). *)
             m2#set_document_unbracketed { d with Document.selection = new_sel });
          true));
        (* Recurse into children (skip if collapsed) *)
        if is_container && not is_collapsed then begin
          let ch = Document.children_of elem in
          add_children ch (depth + 1) path cur_color
        end
      done
    in
    let n = Array.length doc.Document.layers in
    for ri = n - 1 downto 0 do
      let i = ri in
      let elem = doc.Document.layers.(i) in
      let path = [i] in
      let is_container = is_container elem in
      let is_selected = Document.PathSet.mem path selected_paths in
      let layer_color = layer_colors.(i mod Array.length layer_colors) in
      let (name, _is_named) = display_name elem in
      let vis = Element.get_visibility elem in
      let locked = Element.is_locked elem in
      let is_panel_selected = Layers_panel_state.PathSet.mem path !Layers_panel_state.panel_selection in
      let is_drop_target =
        match !Layers_panel_state.drag_source, !Layers_panel_state.drag_target with
        | Some src, Some tgt when src <> path && tgt = path -> true
        | _ -> false
      in
      let row_eb = GBin.event_box ~packing:(vbox#pack ~expand:false) () in
      if is_panel_selected then
        row_eb#misc#modify_bg [`NORMAL, `NAME "#3a4a6a"]
      else if is_drop_target then
        row_eb#misc#modify_bg [`NORMAL, `NAME "#3a7bd5"];
      let row_path = path in
      ignore (row_eb#event#connect#button_press ~callback:(fun _ ->
        Layers_panel_state.panel_selection := Layers_panel_state.PathSet.singleton row_path;
        Layers_panel_state.drag_source := Some row_path;
        Layers_panel_state.drag_target := None;
        !Layers_panel_state.rerender ();
        true));
      ignore (row_eb#event#connect#enter_notify ~callback:(fun _ ->
        (match !Layers_panel_state.drag_source with
         | Some src when src <> row_path ->
           Layers_panel_state.drag_target := Some row_path;
           !Layers_panel_state.rerender ();
           let is_cont = match elem with Element.Group _ | Element.Layer _ -> true | _ -> false in
           if is_cont && Layers_panel_state.PathSet.mem row_path !Layers_panel_state.collapsed then
             ignore (GMain.Timeout.add ~ms:500 ~callback:(fun () ->
               (if !Layers_panel_state.drag_source <> None && !Layers_panel_state.drag_target = Some row_path then begin
                  Layers_panel_state.collapsed := Layers_panel_state.PathSet.remove row_path !Layers_panel_state.collapsed;
                  !Layers_panel_state.rerender ()
                end);
               false))
         | _ -> ());
        false));
      ignore (row_eb#event#connect#button_release ~callback:(fun _ ->
        (match !Layers_panel_state.drag_source with
         | Some src when src <> row_path ->
           (match get_model () with
            | None -> ()
            | Some m2 ->
              let d = m2#document in
              let is_cycle =
                List.length row_path >= List.length src &&
                (let rec starts_with a b = match a, b with
                  | _, [] -> true | [], _ -> false
                  | ah :: at, bh :: bt -> ah = bh && starts_with at bt
                in starts_with row_path src)
              in
              let parent_locked =
                match row_path with
                | [] | [_] -> false
                | _ ->
                  let rec drop_last = function
                    | [] | [_] -> []
                    | x :: xs -> x :: drop_last xs
                  in
                  let parent_path = drop_last row_path in
                  let pe = Document.get_element d parent_path in
                  Element.is_locked pe
              in
              if is_cycle || parent_locked then ()
              else begin
              let moved = Document.get_element d src in
              let d1 = Document.delete_element d src in
              let target =
                let slen = List.length src and tlen = List.length row_path in
                if slen = tlen then
                  match List.rev src, List.rev row_path with
                  | si :: srest, ti :: trest when srest = trest && si < ti ->
                    List.rev (ti - 1 :: trest)
                  | _ -> row_path
                else row_path
              in
              let insert_path =
                match List.rev target with
                | ti :: rest when ti > 0 -> List.rev (ti - 1 :: rest)
                | _ -> target
              in
              m2#edit_document (Document.insert_element_after d1 insert_path moved)
              end)
         | _ -> ());
        Layers_panel_state.drag_source := None;
        Layers_panel_state.drag_target := None;
        !Layers_panel_state.rerender ();
        false));
      let hbox = GPack.hbox ~spacing:2 ~packing:row_eb#add () in
      (* Eye *)
      let eye_eb = GBin.event_box ~packing:(hbox#pack ~expand:false) () in
      ignore (GMisc.label ~text:(vis_icon vis) ~packing:eye_eb#add ());
      eye_eb#misc#set_size_request ~width:16 ();
      ignore (eye_eb#event#connect#button_press ~callback:(fun evt ->
        handle_eye_click path evt;
        !Layers_panel_state.rerender ();
        true));
      (* Lock *)
      let lock_eb = GBin.event_box ~packing:(hbox#pack ~expand:false) () in
      let lock_text = if locked then "\xf0\x9f\x94\x92" else "\xf0\x9f\x94\x93" in
      ignore (GMisc.label ~text:lock_text ~packing:lock_eb#add ());
      lock_eb#misc#set_size_request ~width:16 ();
      ignore (lock_eb#event#connect#button_press ~callback:(fun _ ->
        (match get_model () with
         | None -> ()
         | Some m2 ->
           let d = m2#document in
           let e = Document.get_element d path in
           let was_unlocked = not (Element.is_locked e) in
           let is_cont_elem = is_container in
           if is_cont_elem && was_unlocked then begin
             let children = Document.children_of e in
             let saved = Array.to_list (Array.map Element.is_locked children) in
             Layers_panel_state.saved_lock_states := Layers_panel_state.PathMap.add path saved !Layers_panel_state.saved_lock_states
           end;
           let new_e = Element.set_locked was_unlocked e in
           let d1 = Document.replace_element d path new_e in
           let d2 = if is_cont_elem && was_unlocked then begin
             let children = Document.children_of e in
             Array.fold_left (fun acc_doc i ->
               let child_path = path @ [i] in
               let child = Document.get_element acc_doc child_path in
               Document.replace_element acc_doc child_path (Element.set_locked true child)
             ) d1 (Array.init (Array.length children) (fun i -> i))
           end else d1 in
           let d3 = if is_cont_elem && not was_unlocked then begin
             match Layers_panel_state.PathMap.find_opt path !Layers_panel_state.saved_lock_states with
             | None -> d2
             | Some saved ->
               Layers_panel_state.saved_lock_states := Layers_panel_state.PathMap.remove path !Layers_panel_state.saved_lock_states;
               List.fold_left (fun acc_doc (i, sl) ->
                 let child_path = path @ [i] in
                 let child = Document.get_element acc_doc child_path in
                 Document.replace_element acc_doc child_path (Element.set_locked sl child)
               ) d2 (List.mapi (fun i s -> (i, s)) saved)
           end else d2 in
           m2#edit_document d3);
        true));
      (* Twirl or gap *)
      let is_collapsed = Layers_panel_state.PathSet.mem path !Layers_panel_state.collapsed in
      if is_container then begin
        let twirl_text = if is_collapsed then "\xe2\x96\xb6" else "\xe2\x96\xbc" in
        let twirl_eb = GBin.event_box ~packing:(hbox#pack ~expand:false) () in
        ignore (GMisc.label ~text:twirl_text ~packing:twirl_eb#add ());
        twirl_eb#misc#set_size_request ~width:16 ();
        let tp = path in
        ignore (twirl_eb#event#connect#button_press ~callback:(fun _ ->
          if Layers_panel_state.PathSet.mem tp !Layers_panel_state.collapsed
          then Layers_panel_state.collapsed := Layers_panel_state.PathSet.remove tp !Layers_panel_state.collapsed
          else Layers_panel_state.collapsed := Layers_panel_state.PathSet.add tp !Layers_panel_state.collapsed;
          !Layers_panel_state.rerender ();
          true))
      end else begin
        let gap = GMisc.label ~text:"" ~packing:(hbox#pack ~expand:false) () in
        gap#misc#set_size_request ~width:16 ()
      end;
      (* Preview thumbnail — fitted SVG of the element *)
      make_element_thumbnail ~packing:(hbox#pack ~expand:false) elem 24;
      (* Name — inline GEntry when renaming, GMisc.label otherwise *)
      (match !Layers_panel_state.renaming with
       | Some rp when rp = path ->
         let initial = match elem with
           | Element.Layer le -> (match le.name with Some s -> s | None -> "")
           | _ -> ""
         in
         let entry = GEdit.entry ~text:initial ~packing:(hbox#pack ~expand:true) () in
         let ep = path in
         ignore (entry#connect#activate ~callback:(fun () ->
           (match get_model () with
            | None -> ()
            | Some m2 ->
              let d = m2#document in
              let e = Document.get_element d ep in
              (match e with
               | Element.Layer le ->
                 let typed = entry#text in
                 let new_name = if typed = "" then None else Some typed in
                 let new_layer = Element.Layer { le with name = new_name } in
                 m2#edit_document (Document.replace_element d ep new_layer)
               | _ -> ()));
           Layers_panel_state.renaming := None;
           !Layers_panel_state.rerender ()));
         ignore (entry#event#connect#key_press ~callback:(fun key ->
           if GdkEvent.Key.keyval key = GdkKeysyms._Escape then begin
             Layers_panel_state.renaming := None;
             !Layers_panel_state.rerender ();
             true
           end else false))
       | _ ->
         let name_eb = GBin.event_box ~packing:(hbox#pack ~expand:true) () in
         ignore (GMisc.label ~text:name ~packing:name_eb#add ());
         let np = path in
         let is_layer_elem = is_layer elem in
         ignore (name_eb#event#connect#button_press ~callback:(fun ev ->
           if is_layer_elem && GdkEvent.get_type ev = `TWO_BUTTON_PRESS then begin
             Layers_panel_state.renaming := Some np;
             !Layers_panel_state.rerender ();
             true
           end else false)));
      (* Select square *)
      let sq_eb = GBin.event_box ~packing:(hbox#pack ~expand:false) () in
      let sq = GBin.frame ~shadow_type:`ETCHED_IN ~packing:sq_eb#add () in
      sq#misc#set_size_request ~width:12 ~height:12 ();
      if is_selected then
        sq#misc#modify_bg [`NORMAL, `NAME "blue"];
      ignore (sq_eb#event#connect#button_press ~callback:(fun _ ->
        (match get_model () with
         | None -> ()
         | Some m2 ->
           let d = m2#document in
           let new_sel = Document.PathMap.singleton path (Document.element_selection_all path) in
           (* Row select: selection-only, a non-undoable write (OP_LOG.md sections 7 and 8). *)
             m2#set_document_unbracketed { d with Document.selection = new_sel });
        true));
      (* Recurse (skip if collapsed) *)
      if is_container && not is_collapsed then begin
        let ch = Document.children_of elem in
        add_children ch 1 path layer_color
      end
    done

and render_element_preview ~packing _el =
  let frame = GBin.frame ~shadow_type:`ETCHED_IN ~packing () in
  frame#misc#set_size_request ~width:32 ~height:32 ()

(* PRINT.md §1B: tabs widget. Left-rail tab list + content area
   showing the active tab. Active tab read from [bind.value]
   (typically dialog.<field>); falls back to first tab when no bind
   or empty value. Click writes back the tab id (currently a no-op
   for non-panel binds — same dialog-write limitation as Swift's
   render_tabs and OCaml's other widgets). *)
and render_tabs ~packing ~ctx el =
  let open Yojson.Safe.Util in
  let tabs_arr = el |> member "tabs" |> to_list in
  let first_id = match tabs_arr with
    | t :: _ -> t |> member "id" |> to_string_option |> Option.value ~default:""
    | [] -> "" in
  let bind_expr = el |> member "bind" |> safe_member "value"
                   |> to_string_option in
  let active_id = match bind_expr with
    | None -> first_id
    | Some e ->
      (match Expr_eval.evaluate e ctx with
       | Expr_eval.Str s when s <> "" -> s
       | _ -> first_id) in
  let hbox = GPack.hbox ~spacing:0 ~packing () in
  (* Left rail. *)
  let rail = GPack.vbox ~spacing:0 ~packing:(hbox#pack ~expand:false) () in
  rail#misc#set_size_request ~width:140 ();
  List.iter (fun tab ->
    let tab_id = tab |> member "id" |> to_string_option |> Option.value ~default:"" in
    let label = tab |> member "label" |> to_string_option |> Option.value ~default:"" in
    let is_active = tab_id = active_id in
    let prefix = if is_active then "▸ " else "  " in
    let btn = GButton.button
      ~label:(prefix ^ label)
      ~relief:`NONE
      ~packing:(rail#pack ~expand:false) () in
    (* Click handler: dialog-state write goes here once the framework
       supports it. For now, a no-op for dialog binds. *)
    ignore (btn#connect#clicked ~callback:(fun () -> ()))
  ) tabs_arr;
  (* Content area. *)
  let content = GPack.vbox ~spacing:0 ~packing:(hbox#pack ~expand:true ~fill:true) () in
  let active_content =
    List.find_opt (fun t ->
      (t |> member "id" |> to_string_option) = Some active_id
    ) tabs_arr
    |> Option.map (fun t -> t |> member "content")
  in
  (match active_content with
   | Some c when c <> `Null -> render_element ~packing:(content#pack ~expand:true ~fill:true) ~ctx c
   | _ -> ())

and render_placeholder ~packing el =
  let open Yojson.Safe.Util in
  let summary = match el |> member "summary" |> to_string_option with
    | Some s -> s
    | None -> el |> member "type" |> to_string_option |> Option.value ~default:"?" in
  let id = el |> member "id" |> to_string_option |> Option.value ~default:"" in
  (* Opacity panel previews (OPACITY.md \167Preview interactions):
     op_preview / op_mask_preview handle click to switch the
     editing target and render a persistent highlight on the
     active target. Mirrors the Rust and Swift special-cases. *)
  let is_opacity_preview =
    !_current_panel_id = Some "opacity_panel_content"
    && (id = "op_preview" || id = "op_mask_preview") in
  if is_opacity_preview then begin
    let eb = GBin.event_box ~packing () in
    let frame = GBin.frame ~packing:eb#add () in
    frame#set_shadow_type `NONE;
    frame#misc#set_size_request ~height:30 ();
    let lbl = GMisc.label ~text:(Printf.sprintf "[%s]" summary)
                ~packing:frame#add () in
    ignore lbl;
    (* Highlight whichever preview matches the current editing
       target. *)
    let is_mask_preview = id = "op_mask_preview" in
    let editing_mask = match !_get_model_ref () with
      | Some m -> (match m#editing_target with Model.Mask _ -> true | Model.Content -> false)
      | None -> false in
    let highlight = editing_mask = is_mask_preview in
    if highlight then
      frame#set_shadow_type `OUT
    else
      frame#set_shadow_type `NONE;
    ignore (eb#event#connect#button_press ~callback:(fun evt ->
      match !_get_model_ref () with
      | None -> false
      | Some m ->
        let modifiers = Gdk.Convert.modifier (GdkEvent.Button.state evt) in
        let shift = List.mem `SHIFT modifiers in
        let alt = List.mem `MOD1 modifiers in
        if is_mask_preview && shift then begin
          (* Shift-click: toggle mask.disabled on every selected
             mask. OPACITY.md \167Preview interactions. *)
          let doc = m#document in
          if Controller.selection_has_mask doc then begin
            let ctrl = new Controller.controller ~model:m () in
            ctrl#toggle_mask_disabled_on_selection;
            !Layers_panel_state.rerender ()
          end
        end else if is_mask_preview && alt then begin
          (* Alt-click: toggle mask isolation — the canvas hides
             everything except the first selected element's mask
             subtree while isolation is active. *)
          let doc = m#document in
          (match m#mask_isolation_path with
           | Some _ -> m#set_mask_isolation_path None
           | None ->
             if Controller.selection_has_mask doc then
               match Document.PathMap.min_binding_opt doc.Document.selection with
               | Some (path, _) -> m#set_mask_isolation_path (Some path)
               | None -> ());
          !Layers_panel_state.rerender ()
        end else if is_mask_preview then begin
          let doc = m#document in
          if Controller.selection_has_mask doc then begin
            let first_path = match Document.PathMap.min_binding_opt doc.Document.selection with
              | Some (path, _) -> path
              | None -> [] in
            m#set_editing_target (Model.Mask first_path);
            !Layers_panel_state.rerender ()
          end
        end else begin
          m#set_editing_target Model.Content;
          !Layers_panel_state.rerender ()
        end;
        true))
  end else begin
    (* Placeholder for not-yet-implemented widget types (icon being
       the most common). Use a single dot rather than "[summary]"
       text — in dock panels the placeholder lands in a col-2 cell
       beside a col-4 input, and a 6-char "[icon]" placeholder
       (~50px natural) forces per-col-unit ≈ 25px, which inflates
       the col-4 cell to ~100px (~14 chars wide). The dot keeps
       its cell narrow so the value box stays the intended size. *)
    let display = if !_current_panel_id <> None then "·"
                  else Printf.sprintf "[%s]" summary in
    let lbl = GMisc.label ~text:display ~packing () in
    lbl#misc#set_size_request ~height:30 ()
  end

and render_children ~packing ~ctx el =
  let open Yojson.Safe.Util in
  match el |> member "children" with
  | `List children ->
    List.iter (fun child -> render_element ~packing ~ctx child) children
  | _ -> ()

and render_repeat ~packing ~ctx el =
  let open Yojson.Safe.Util in
  let repeat_obj = el |> member "foreach" in
  let template = el |> member "do" in
  let source_expr = repeat_obj |> member "source" |> to_string_option |> Option.value ~default:"" in
  let var_name = repeat_obj |> member "as" |> to_string_option |> Option.value ~default:"item" in
  (* Resolve the source expression to raw JSON (preserving lists/objects) *)
  let items_json = Expr_eval.evaluate_to_json source_expr ctx in
  (* Determine layout direction from the element *)
  let layout_dir = el |> member "layout" |> to_string_option |> Option.value ~default:"column" in
  let gap = el |> member "style" |> safe_member "gap" |> to_int_option |> Option.value ~default:0 in
  let is_row = layout_dir = "row" || layout_dir = "wrap" in
  let container = if is_row
    then (GPack.hbox ~spacing:gap ~packing () :> GPack.box)
    else (GPack.vbox ~spacing:gap ~packing () :> GPack.box) in
  if layout_dir = "wrap" then
    container#misc#set_size_request ~width:0 ();
  (* Build scope from context and iterate with child scopes *)
  let scope = Scope.from_json ctx in
  (match items_json with
   | `List items ->
     List.iteri (fun i item ->
       (* Build item data with _index *)
       let item_obj = match item with
         | `Assoc pairs -> `Assoc (("_index", `Int i) :: pairs)
         | other -> `Assoc [("_index", `Int i); ("value", other)]
       in
       (* Push a child scope with the loop variable — parent unchanged *)
       let child_scope = Scope.extend scope [(var_name, item_obj)] in
       let child_ctx = Scope.to_json child_scope in
       render_element ~packing:(container#pack ~expand:false) ~ctx:child_ctx template
     ) items
   | _ -> ())

(* [to_number_option] is provided by [Yojson.Safe.Util] (opened inside
   each render function) and also parses numeric strings — the former
   local definition here was shadowed everywhere and is gone. *)

(** Create a YAML-interpreted panel body in a GTK container.
    Returns unit. The panel content is rendered from the compiled
    workspace JSON. *)
let create_panel_body ~packing ~(kind : panel_kind) ?(get_model = fun () -> None) ?max_width:_ () =
  let content_id = Workspace_loader.panel_kind_to_content_id kind in
  match Workspace_loader.load () with
  | None -> ()
  | Some ws ->
    match Workspace_loader.panel_content ws content_id with
    | None -> ()
    | Some content ->
      let state_defaults = Workspace_loader.state_defaults ws in
      let panel_defaults = Workspace_loader.panel_state_defaults ws content_id in
      (* Reuse the previously-registered store across panel rebuilds
         so state writes survive a dock re-render. Without this every
         rebuild allocates a fresh store with default state, silently
         dropping any [state.X] / [panel.X] writes the user has made
         (e.g. fill_on_top toggled by clicking the fill/stroke swatch
         in the color panel). *)
      let store, is_new_store = match Panel_menu.lookup_panel_store content_id with
        | Some s -> s, false
        | None -> State_store.create (), true in
      if is_new_store then
        State_store.init_panel store content_id panel_defaults;
      (* Build [state] / [panel] objects in the render ctx as
         [defaults] overridden by the store's live entries. The
         renderer evaluates bind: expressions against this ctx once
         at element creation; reading live values here ensures the
         next rebuild sees the current state, not the static
         defaults. *)
      let merge_overrides defaults overrides =
        List.fold_left (fun acc (k, v) ->
          (k, v) :: List.filter (fun (k', _) -> k' <> k) acc
        ) defaults overrides
      in
      let live_state = State_store.get_all store in
      (* Sync state.fill_color / state.stroke_color from the active
         selection (or default fill/stroke if nothing's selected) so
         the color panel's fill_stroke widget tracks the canvas.
         Without this the fill/stroke swatches keep showing the
         last hex-committed value even after the user picks a
         different rectangle. *)
      let hash_hex c = "#" ^ Element.color_to_hex c in
      let elem_fill_color (e : Element.element) =
        match e with
        | Element.Rect { fill = Some f; _ }
        | Element.Circle { fill = Some f; _ }
        | Element.Ellipse { fill = Some f; _ }
        | Element.Polyline { fill = Some f; _ }
        | Element.Polygon { fill = Some f; _ }
        | Element.Path { fill = Some f; _ } -> Some f.Element.fill_color
        | _ -> None in
      let elem_stroke_color (e : Element.element) =
        match e with
        | Element.Line { stroke = Some s; _ }
        | Element.Rect { stroke = Some s; _ }
        | Element.Circle { stroke = Some s; _ }
        | Element.Ellipse { stroke = Some s; _ }
        | Element.Polyline { stroke = Some s; _ }
        | Element.Polygon { stroke = Some s; _ }
        | Element.Path { stroke = Some s; _ } -> Some s.Element.stroke_color
        | _ -> None in
      (* Build a fill/stroke override list. The override is intentionally
         tri-state per channel: emit a real color when we know one
         (selected element OR model default), an explicit [`Null] when
         the channel is "none" (selected element has [fill = None] —
         user clicked the None swatch on that side), and SKIP when we
         have no information (no selection AND no model default).
         Skipping lets the workspace state default (white fill / black
         stroke) flow through, which is what users expect when they
         haven't picked anything yet. Earlier this always wrote [`Null],
         which forced the fill swatch to render as a dashed empty slot
         on startup. *)
      let selection_overrides = match get_model () with
        | None -> []
        | Some m ->
          let elem_opt =
            match Document.PathMap.bindings m#document.Document.selection with
            | (path, _) :: _ ->
              (try Some (Document.get_element m#document path)
               with _ -> None)
            | [] -> None in
          let fc_override = match elem_opt with
            | Some e ->
              [("fill_color",
                match elem_fill_color e with
                | Some c -> `String (hash_hex c)
                | None -> `Null)]
            | None ->
              (match m#default_fill with
               | Some f -> [("fill_color",
                             `String (hash_hex f.Element.fill_color))]
               | None -> [])  (* let workspace default through *)
          in
          let sc_override = match elem_opt with
            | Some e ->
              [("stroke_color",
                match elem_stroke_color e with
                | Some c -> `String (hash_hex c)
                | None -> `Null)]
            | None ->
              (match m#default_stroke with
               | Some s -> [("stroke_color",
                             `String (hash_hex s.Element.stroke_color))]
               | None -> [])
          in
          fc_override @ sc_override in
      let state_pairs =
        merge_overrides
          (merge_overrides state_defaults live_state)
          selection_overrides in
      let state_obj = `Assoc state_pairs in
      let live_panel = State_store.get_panel_state store content_id in
      let panel_pairs = merge_overrides panel_defaults live_panel in
      let icons_obj = Workspace_loader.icons ws in
      let swatch_libs = Workspace_loader.swatch_libraries ws in
      let brush_libs = Workspace_loader.brush_libraries ws in
      let concepts = Workspace_loader.concepts_list ws in
      let data_obj = `Assoc [
        ("swatch_libraries", swatch_libs);
        ("brush_libraries", brush_libs);
        ("concepts", concepts);
      ] in
      let active_document_view =
        Active_document_view.build (get_model ())
      in
      (* OPACITY.md §States: surface the three selection predicates at
         top level so yaml expressions like `bind.checked:
         "selection_mask_clip"` and `bind.disabled:
         "!selection_has_mask"` resolve uniformly. Mirrors
         `build_selection_predicates` in jas_dioxus. *)
      let selection_preds =
        Active_document_view.build_selection_predicates (get_model ())
      in
      (* document namespace — exposes per-document fields the YAML
         reads but the StateStore has no native source for. Currently
         just recent_colors, used by panel init expressions (color,
         swatches) so the recent-color strip seeds with the model's
         actual recent colors rather than the YAML default of []. *)
      let document_view =
        match get_model () with
        | Some m ->
          `Assoc [
            ("recent_colors",
             `List (List.map (fun s -> `String s) m#recent_colors));
          ]
        | None -> `Assoc [("recent_colors", `List [])]
      in
      let ctx = `Assoc ([
        ("state", state_obj);
        ("panel", `Assoc panel_pairs);
        ("icons", icons_obj);
        ("data", data_obj);
        ("active_document", active_document_view);
        ("document", document_view);
        ("_get_model", `Null)  (* Placeholder; actual model passed via closure *)
      ] @ selection_preds) in
      _current_store := Some store;
      _current_panel_id := Some content_id;
      (* Register the panel store for cross-panel bridges
         (recent_colors etc.) AND for menu-command dispatchers that
         reach back into panel state (paragraph / opacity menus). The
         single registry replaces an earlier per-panel ref-cell pair.
         No-op if already registered (reusing the same store). *)
      Panel_menu.register_panel_store content_id store;
      (* Store get_model in a ref accessible from render_tree_view *)
      _get_model_ref := get_model;
      (* Register an on_document_changed listener so changing the
         canvas selection (or any other document mutation) triggers
         a panel rebuild. The selection-color overrides computed
         above re-read the (now-current) selection on each rebuild,
         so the fill/stroke widget tracks the canvas. Guarded by
         [_doc_listener_registered_for] so a panel rebuild doesn't
         keep stacking listeners — they'd accumulate without bound
         and fire N times per document change after N rebuilds. *)
      (* on_document_changed listener registration moved to [main.ml]'s
         dummy_model setup + add_canvas — see
         [update_color_panel_widgets]. Per-panel-body subscription was
         unreliable across tab switches. *)
      (* Wire the Character-panel apply pipeline. [get_model] is
         already a thunk returning the live model; we adapt it to
         yield a Controller when one is available. *)
      let make_ctrl_getter () () =
        match get_model () with
        | Some model -> Controller.create ~model ()
        | None -> failwith "no model available for panel apply"
      in
      (if kind = Character then
         Effects.subscribe_character_panel store (make_ctrl_getter ()));
      (* Stroke panel writes global [stroke_*] keys; subscribe via the
         global channel (filtered by [is_stroke_render_key]) so
         widget changes reach the selected element. *)
      (if kind = Stroke then
         Effects.subscribe_stroke_panel store (make_ctrl_getter ()));
      (* Active-color writes (set_active_color YAML action et al.)
         must also propagate to the selected element. The Color
         Panel calls Panel_menu.set_active_color directly; the YAML
         route writes through set: which lands in
         set_by_scoped_target. Subscribe via the global channel so
         the YAML route catches up. *)
      (if kind = Color || kind = Swatches then
         Effects.subscribe_active_color store (make_ctrl_getter ()));
      (* Paragraph panel — Phase 4. The hamburger-menu commands
         (toggle_hanging_punctuation, reset_paragraph_panel) and the
         Opacity-panel toggle commands reach into the panel store via
         Panel_menu.lookup_panel_store; the registration above already
         covers them. Paragraph also subscribes to document changes
         so the panel widgets refresh whenever the selection changes
         to a paragraph wrapper with different attrs (PG-055). *)
      (* Paragraph panel sync from selection: fires once at panel
         render time and registers a global hook so any subsequent
         document change on the active model also re-syncs. The hook
         re-resolves [get_model] each time so it always sees the
         currently active tab's model rather than capturing whatever
         was active when the panel was first rendered (typically the
         startup dummy model). *)
      (if kind = Paragraph then begin
         let sync () =
           match get_model () with
           | Some m ->
             let ctrl = new Controller.controller ~model:m () in
             Effects.sync_paragraph_panel_from_selection store ctrl
           | None -> ()
         in
         sync ();
         _paragraph_panel_sync := Some sync
       end);
      render_element ~packing ~ctx content

(** Toolbar STEP A: render the bundle's [layout → toolbar_pane → content]
    (the tool_grid + fill/stroke widget) through the generic element
    renderer, instead of the hand-built [Toolbar] GTK class. Wired in
    main.ml against the toolbar pane container; re-invoked by
    [toolbar_rerender_hook] after the active tool changes so the
    [bind.checked] highlight tracks.

    The render ctx exposes:
      - [state.active_tool] sourced from [active_tool_name] so each tool
        button's ``bind.checked`` re-evaluates against the live tool;
      - [icons] for the SVG glyphs;
      - [data] / [active_document] / [document] namespaces so the
        embedded fill/stroke widget resolves the same way it does in the
        Color panel.

    [_current_panel_id] is set to a sentinel ("toolbar_pane") so the
    icon_button click path in [render_button] fires
    [dispatch_click_behaviors] — that's where a tool button's
    ``action: select_tool`` lands.

    The long-press alternates flyout is wired in [render_button]: a slot
    button's ``mouse_down`` arms a 250ms timer whose ``open_dialog``
    effect routes (via an [open_dialog] platform handler scoped to that
    run) through [open_nonmodal_dialog_hook] to pop the ``modal: false``
    alternates dialog as a non-blocking flyout; ``mouse_up`` cancels the
    timer so a quick click selects the tool without popping the flyout.
    The flyout items' ``set: { active_tool } + close_dialog`` behaviors
    dispatch through the same Dialog_global path the modal dialogs use. *)
let mount_toolbar ~packing ?(get_model = fun () -> None) () =
  match Workspace_loader.load () with
  | None -> ()
  | Some ws ->
    (* layout → children → (id = toolbar_pane) → content *)
    let content =
      match Workspace_loader.json_member "layout" ws.Workspace_loader.data with
      | Some layout ->
        (match Workspace_loader.json_member "children" layout with
         | Some (`List children) ->
           let pane = List.find_opt (fun c ->
             match Workspace_loader.json_member "id" c with
             | Some (`String "toolbar_pane") -> true
             | _ -> false) children in
           (match pane with
            | Some p -> Workspace_loader.json_member "content" p
            | None -> None)
         | _ -> None)
      | None -> None
    in
    match content with
    | None -> ()
    | Some content ->
      (* Reuse a stable store across rebuilds so fill_on_top + any
         state.* writes survive a toolbar re-render. *)
      let content_id = "toolbar_pane" in
      let store = match Panel_menu.lookup_panel_store content_id with
        | Some s -> s
        | None ->
          let s = State_store.create () in
          Panel_menu.register_panel_store content_id s;
          s in
      let state_defaults = Workspace_loader.state_defaults ws in
      let merge_overrides defaults overrides =
        List.fold_left (fun acc (k, v) ->
          (k, v) :: List.filter (fun (k', _) -> k' <> k) acc
        ) defaults overrides in
      let live_state = State_store.get_all store in
      (* The active tool string drives every bind.checked. It lives in
         [active_tool_name], updated on every tool change. *)
      let state_pairs =
        merge_overrides
          (merge_overrides state_defaults live_state)
          [("active_tool", `String !active_tool_name)] in
      let icons_obj = Workspace_loader.icons ws in
      let swatch_libs = Workspace_loader.swatch_libraries ws in
      let brush_libs = Workspace_loader.brush_libraries ws in
      let concepts = Workspace_loader.concepts_list ws in
      let data_obj = `Assoc [
        ("swatch_libraries", swatch_libs);
        ("brush_libraries", brush_libs);
        ("concepts", concepts);
      ] in
      let active_document_view = Active_document_view.build (get_model ()) in
      let document_view =
        match get_model () with
        | Some m ->
          `Assoc [("recent_colors",
                   `List (List.map (fun s -> `String s) m#recent_colors))]
        | None -> `Assoc [("recent_colors", `List [])] in
      let selection_preds =
        Active_document_view.build_selection_predicates (get_model ()) in
      let ctx = `Assoc ([
        ("state", `Assoc state_pairs);
        ("icons", icons_obj);
        ("data", data_obj);
        ("active_document", active_document_view);
        ("document", document_view);
      ] @ selection_preds) in
      _current_store := Some store;
      _current_panel_id := Some content_id;
      _get_model_ref := get_model;
      render_element ~packing ~ctx content
