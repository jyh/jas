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
  mutable hex_entry : GEdit.entry option;
  mutable recent_swatches : (GMisc.drawing_area * string ref) option array;
}
let _color_panel_slots : color_panel_slots = {
  fill_swatch = None;
  stroke_swatch = None;
  hex_entry = None;
  recent_swatches = Array.make 10 None;
}

let clear_color_panel_slots () =
  _color_panel_slots.fill_swatch <- None;
  _color_panel_slots.stroke_swatch <- None;
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
       let hex = match fill_color, stroke_color with
         | Some c, _ -> Element.color_to_hex c  (* fill_on_top default *)
         | None, Some c -> Element.color_to_hex c
         | None, None -> "" in
       if not entry#is_focus && entry#text <> hex then
         entry#set_text hex
     | None -> ())

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

(** Trigger a re-sync of the open Paragraph panel from the active
    model's current selection. No-op when no Paragraph panel is
    open. Safe to call from any model's [on_document_changed]
    listener — the sync resolves the active model lazily. *)
let paragraph_panel_resync_from_active_model () : unit =
  match !_paragraph_panel_sync with
  | Some f -> f ()
  | None -> ()


(** Look up a previously registered panel store by content id, or None
    if no panel with that id has mounted yet. Thin wrapper over the
    Panel_menu registry so callers in this module read symmetrically
    with everywhere else. *)
let panel_store_of_id (id : string) : State_store.t option =
  Panel_menu.lookup_panel_store id

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
      update_recent_color_widgets ())
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
    Dialog_global.set_field field value
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
                 let fill_on_top = match State_store.get store "fill_on_top" with
                   | `Bool b -> b | _ -> true in
                 (match !_get_model_ref () with
                  | Some m ->
                    Panel_menu.set_active_color color ~fill_on_top m
                  | None -> ());
                 (* Also mirror the new color into [state.fill_color]
                    / [state.stroke_color] so the panel's fill_swatch
                    (bound to [color: state.fill_color]) reflects the
                    edit on the next rebuild — Panel_menu.set_active_color
                    only mutates the model, not the panel's state store. *)
                 let hex_with_hash = "#" ^ Element.color_to_hex color in
                 let key = if fill_on_top then "fill_color" else "stroke_color" in
                 State_store.set store key (`String hex_with_hash);
                 schedule_panel_rerender ()
               | None -> ())
            | _ -> ())
         end else
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
                 | Some color -> Panel_menu.set_active_color color ~fill_on_top m
                 | None -> ())
              | "set_active_color_none" ->
                if fill_on_top then begin
                  m#set_default_fill None;
                  if not (Document.PathMap.is_empty
                            m#document.Document.selection) then begin
                    m#snapshot;
                    let ctrl = Controller.create ~model:m () in
                    ctrl#set_selection_fill None
                  end
                end else begin
                  m#set_default_stroke None;
                  if not (Document.PathMap.is_empty
                            m#document.Document.selection) then begin
                    m#snapshot;
                    let ctrl = Controller.create ~model:m () in
                    ctrl#set_selection_stroke None
                  end
                end
              | _ ->
                Panel_menu.dispatch_yaml_action
                  ~params:params_list action_name m)
         | _ -> ())
      end
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
  let _cols = el |> member "cols" |> to_int_option |> Option.value ~default:2 in
  (* GTK grid approximated with an HBox *)
  let hbox = GPack.hbox ~spacing:2 ~packing () in
  render_children ~packing:(hbox#pack ~expand:false ~fill:false) ~ctx el

and render_text ~packing ~ctx el =
  let open Yojson.Safe.Util in
  let content = el |> member "content" |> to_string_option |> Option.value ~default:"" in
  let text = if String.length content > 0 && (try let _ = String.index content '{' in true with Not_found -> false)
    then Expr_eval.evaluate_text content ctx
    else content in
  let style = el |> member "style" in
  (* style.color may be a literal hex or a {{theme.colors.X}} token;
     evaluate_text resolves both. Default to the dark-theme text
     color (#cccccc) when unspecified — without this, slider-row
     labels (slider_row template doesn't pass color) inherit the
     GTK theme's default label color, which goes dark when the
     panel has focus and renders unreadable on the dark backdrop. *)
  let color = match style |> safe_member "color" |> to_string_option with
    | Some s when String.length s > 0 ->
      (try Expr_eval.evaluate_text s ctx with _ -> s)
    | _ -> "#cccccc" in
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
  let lbl = GMisc.label ~markup ~packing () in
  lbl#set_xalign 0.0

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
        let size = match el |> member "style" |> safe_member "size" |> to_number_option with
          | Some n -> int_of_float n
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
    let size = match el |> member "style" |> safe_member "size" |> to_number_option with
      | Some n -> int_of_float n
      | None -> 20
    in
    btn#misc#set_size_request ~width:size ~height:size ();
    let provider = GObj.css_provider () in
    provider#load_from_data
      "button { padding: 0; margin: 0; min-width: 0; min-height: 0; border: 0; background: transparent; }";
    btn#misc#style_context#add_provider provider 800
  end;
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
  let adj = GData.adjustment ~lower:min_val ~upper:max_val ~step_incr:step ~value:initial () in
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
      if bind_expr <> "" then
        _write_back_bind bind_expr (`Float v);
      suppress := false
    end))

and render_number_input ~packing ~ctx el =
  let open Yojson.Safe.Util in
  let min_val = el |> member "min" |> to_number_option |> Option.value ~default:0.0 in
  let max_val = el |> member "max" |> to_number_option |> Option.value ~default:100.0 in
  let bind_expr = el |> member "bind" |> safe_member "value" |> to_string_option in
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
        end
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
  let bind_expr = el |> member "bind" |> safe_member "value" |> to_string_option in
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
   | None -> ())

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
  (* Accept either bind.value (the panel-bool convention) or the
     legacy bind.checked. Mirrors the Rust render_toggle dispatch. *)
  let bind_expr =
    match el |> member "bind" |> safe_member "value" |> to_string_option with
    | Some s -> Some s
    | None -> el |> member "bind" |> safe_member "checked" |> to_string_option in
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
  let initial_color = match el |> member "bind" |> safe_member "color" |> to_string_option with
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
      let wrote_state = dispatch_click_behaviors el ctx in
      if wrote_state then schedule_panel_rerender ();
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
     _color_panel_slots.fill_swatch <- Some (area, color_ref)
   | Some "cp_stroke_swatch" ->
     _color_panel_slots.stroke_swatch <- Some (area, color_ref)
   | Some id_str
     when String.length id_str > 10
       && String.sub id_str 0 10 = "cp_recent_" ->
     let suffix = String.sub id_str 10 (String.length id_str - 10) in
     (match int_of_string_opt suffix with
      | Some i when i >= 0 && i < Array.length _color_panel_slots.recent_swatches ->
        _color_panel_slots.recent_swatches.(i) <- Some (area, color_ref)
      | _ -> ())
   | _ -> ());
  ignore (area#misc#connect#draw ~callback:(fun cr ->
    let color_str = !color_ref in
    let s = float_of_int size in
    if String.length color_str = 0 then begin
      (* Empty slot: hollow dashed square *)
      Cairo.set_source_rgb cr 0.33 0.33 0.33;
      Cairo.set_line_width cr 1.0;
      Cairo.set_dash cr [| 2.0; 2.0 |];
      Cairo.rectangle cr 0.5 0.5 ~w:(s -. 1.0) ~h:(s -. 1.0);
      Cairo.stroke cr
    end else begin
      let (r, g, b) = parse_hex color_str in
      let rf = float_of_int r /. 255.0 in
      let gf = float_of_int g /. 255.0 in
      let bf = float_of_int b /. 255.0 in
      if hollow then begin
        (* Hollow square: 3px ring of color, white center *)
        Cairo.set_source_rgb cr rf gf bf;
        Cairo.rectangle cr 0.0 0.0 ~w:s ~h:s;
        Cairo.fill cr;
        Cairo.set_source_rgb cr 1.0 1.0 1.0;
        let inset = 3.0 in
        Cairo.rectangle cr inset inset ~w:(s -. 2.0 *. inset) ~h:(s -. 2.0 *. inset);
        Cairo.fill cr
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
  List.iter (fun (_, child) ->
    let pos = child |> member "style" |> safe_member "position" in
    let x = pos |> safe_member "x" |> to_number_option
      |> Option.map int_of_float |> Option.value ~default:0 in
    let y = pos |> safe_member "y" |> to_number_option
      |> Option.map int_of_float |> Option.value ~default:0 in
    render_element ~packing:(container#put ~x ~y) ~ctx child
  ) sorted

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
  ignore (area#event#connect#button_press ~callback:(fun ev ->
    (match !_get_model_ref () with
     | Some m -> Panel_menu.set_active_color_live (pick_color_from_button ev)
                   ~fill_on_top:(read_fill_on_top ()) m
     | None -> ());
    true));
  ignore (area#event#connect#button_release ~callback:(fun ev ->
    (match !_get_model_ref () with
     | Some m -> Panel_menu.set_active_color (pick_color_from_button ev)
                   ~fill_on_top:(read_fill_on_top ()) m
     | None -> ());
    true));
  ignore (area#event#connect#motion_notify ~callback:(fun ev ->
    (match !_get_model_ref () with
     | Some m -> Panel_menu.set_active_color_live (pick_color_from_motion ev)
                   ~fill_on_top:(read_fill_on_top ()) m
     | None -> ());
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
        m#snapshot;
        let new_doc = List.fold_left (fun acc (sp, vis) ->
          let e = Document.get_element acc sp in
          Document.replace_element acc sp (Element.set_visibility vis e)
        ) d saved in
        m#set_document new_doc;
        Layers_panel_state.solo_state := None
      end else begin
        let saved = List.filter_map (fun sp ->
          if sp = path then None
          else
            let e = Document.get_element d sp in
            Some (sp, Element.get_visibility e)
        ) sibling_paths in
        m#snapshot;
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
        m#set_document new_doc;
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
      m#snapshot;
      m#set_document (Document.replace_element d path (Element.set_visibility new_vis e))
    end

(** Delete currently panel-selected elements via YAML dispatch (Phase 3).
    The workspace/actions.yaml definition of delete_layer_selection is
    authoritative; this function just supplies the current selection. *)
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
      else
        Panel_menu.dispatch_yaml_action
          ~panel_selection:paths
          ~on_selection_changed:(Some (fun _ ->
            Layers_panel_state.panel_selection := Layers_panel_state.PathSet.empty))
          "delete_layer_selection" m
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
                m2#snapshot;
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
                m2#set_document (Document.insert_element_after d1 insert_path moved)
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
             m2#snapshot;
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
             m2#set_document d3);
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
                   m2#snapshot;
                   m2#set_document (Document.replace_element d ep new_layer)
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
             m2#set_document { d with Document.selection = new_sel });
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
              m2#snapshot;
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
              m2#set_document (Document.insert_element_after d1 insert_path moved)
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
           m2#snapshot;
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
           m2#set_document d3);
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
                 m2#snapshot;
                 m2#set_document (Document.replace_element d ep new_layer)
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
           m2#set_document { d with Document.selection = new_sel });
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

(** Helper to convert number from JSON safely. *)
and to_number_option (j : Yojson.Safe.t) : float option =
  match j with
  | `Int n -> Some (float_of_int n)
  | `Float f -> Some f
  | _ -> None

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
      let data_obj = `Assoc [
        ("swatch_libraries", swatch_libs);
        ("brush_libraries", brush_libs);
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
