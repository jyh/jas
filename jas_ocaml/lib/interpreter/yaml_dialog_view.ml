(** YAML-interpreted dialog component for GTK3.

    Renders a modal dialog from workspace YAML definitions, reusing the
    existing element renderer for the content tree. *)

(** Dialog state. *)
type dialog_state = {
  id : string;
  state : (string * Yojson.Safe.t) list;
  params : (string * Yojson.Safe.t) list;
}

(** Read the live dialog state list (forwards to [Dialog_global]). *)
let current_dialog_state () : (string * Yojson.Safe.t) list =
  Dialog_global.read_state ()

(** Set [key] in the live dialog state. *)
let set_dialog_field (key : string) (value : Yojson.Safe.t) : unit =
  Dialog_global.set_field key value

(** Close the active dialog widget. *)
let close_current_dialog () : unit = Dialog_global.close ()

(** Build a fresh evaluation context against the live dialog state. *)
let current_dialog_ctx () : Yojson.Safe.t =
  !Dialog_global.current_build_ctx ()

(** Open a dialog by ID, initializing its state from the workspace
    definition. ``outer_scope`` exposes top-level keys (like
    ``active_document``) to init expressions. *)
let open_dialog ?(outer_scope : (string * Yojson.Safe.t) list = [])
    (dialog_id : string)
    (raw_params : (string * Yojson.Safe.t) list)
    (live_state : (string * Yojson.Safe.t) list) : dialog_state option =
  match Workspace_loader.load () with
  | None -> None
  | Some ws ->
    match Workspace_loader.dialog ws dialog_id with
    | None -> None
    | Some (`Assoc dlg_def) ->
      let defaults = match List.assoc_opt "state" dlg_def with
        | Some defs -> Effects.state_defaults defs
        | None -> []
      in
      let state_ctx = `Assoc (
        ("state", `Assoc live_state) :: outer_scope
      ) in
      (* Resolve params only when the value is an expression
         (contains a dot — identifier path access). Bare-word values
         like [target: fill] are already literal at this point — the
         caller's click-behavior resolver attempted to evaluate them
         and fell back to the raw string when the identifier wasn't
         bound. Re-evaluating "fill" here would return Null (Expr_eval
         treats undefined identifiers as Null) and the dialog's
         [if param.target == "fill"] branch would silently fall
         through to the else branch. *)
      let resolved_params = List.map (fun (k, v) ->
        match v with
        | `String s when String.contains s '.' ->
          let result = Expr_eval.evaluate s state_ctx in
          (k, Effects.value_to_json result)
        | _ -> (k, v)
      ) raw_params in
      let dialog_state = ref defaults in
      let init_ctx_for () : Yojson.Safe.t =
        `Assoc (
          ("state", `Assoc live_state) ::
          ("dialog", `Assoc !dialog_state) ::
          ("param", `Assoc resolved_params) ::
          outer_scope)
      in
      (match List.assoc_opt "init" dlg_def with
       | Some (`Assoc init_map) ->
         let deferred = ref [] in
         List.iter (fun (key, expr) ->
           let expr_str = match expr with `String s -> s | _ -> "" in
           if (try ignore (Str.search_forward
                             (Str.regexp_string "dialog.") expr_str 0); true
               with Not_found -> false) then
             deferred := (key, expr) :: !deferred
           else begin
             let result = Expr_eval.evaluate expr_str (init_ctx_for ()) in
             dialog_state := (key, Effects.value_to_json result) ::
               List.filter (fun (k, _) -> k <> key) !dialog_state
           end
         ) init_map;
         List.iter (fun (key, expr) ->
           let expr_str = match expr with `String s -> s | _ -> "" in
           let result = Expr_eval.evaluate expr_str (init_ctx_for ()) in
           dialog_state := (key, Effects.value_to_json result) ::
             List.filter (fun (k, _) -> k <> key) !dialog_state
         ) (List.rev !deferred)
       | _ -> ());
      Some {
        id = dialog_id;
        state = !dialog_state;
        params = resolved_params;
      }
    | _ -> None

(** Dispatch a YAML action by name (forwards to [Dialog_global]). *)
let dispatch_action = Dialog_global.dispatch_action

(** Show a YAML dialog as a GTK modal dialog. *)
let show_dialog ?(parent : GWindow.window option)
    ?(outer_scope : (string * Yojson.Safe.t) list = [])
    (ds : dialog_state) : unit =
  match Workspace_loader.load () with
  | None -> ()
  | Some ws ->
    match Workspace_loader.dialog ws ds.id with
    | Some (`Assoc dlg_def) ->
      let summary = match List.assoc_opt "summary" dlg_def with
        | Some (`String s) -> s
        | _ -> ds.id
      in
      let width = match List.assoc_opt "width" dlg_def with
        | Some (`Int w) -> w
        | _ -> 400
      in
      let dialog = GWindow.dialog
        ?parent
        ~title:summary
        ~width
        ~modal:true
        ~destroy_with_parent:true
        () in
      let vbox = dialog#vbox in
      (* Theme the modal dialog window with the active appearance pane
         background so it matches the dock / panels (GTK otherwise draws a
         default LIGHT dialog). GtkBox / GtkLabel / GtkFrame are no-window
         widgets that show the window background through; inputs / buttons /
         labels theme their own colors via the render_element theme hooks.
         Mirrors the flyout background in show_nonmodal_dialog. *)
      (let dialog_bg = !(Yaml_panel_view.dialog_pane_bg_hook) () in
       let dialog_css = new GObj.css_provider (GtkData.CssProvider.create ()) in
       dialog_css#load_from_data (Printf.sprintf
         "window, dialog, box, grid { background-color: %s; }" dialog_bg);
       dialog#misc#style_context#add_provider dialog_css 600;
       vbox#misc#style_context#add_provider dialog_css 600);
      let state_defaults = Workspace_loader.state_defaults ws in
      let icons = Workspace_loader.icons ws in
      let live_state = ref ds.state in
      (* Parse state get/set props from the YAML so dialog widgets'
         write-backs run the declared setter (e.g. color_picker's
         h-setter rebuilds [color] from the new h + existing s/b).
         Without props, channel edits would be silent no-ops on the
         canonical color and the preview swatch / hue bar wouldn't
         follow the typed value. *)
      let props = match List.assoc_opt "state" dlg_def with
        | Some (`Assoc state_defs) ->
          List.filter_map (fun (key, def) ->
            match def with
            | `Assoc fields ->
              let get = match List.assoc_opt "get" fields with
                | Some (`String s) -> Some s | _ -> None in
              let set = match List.assoc_opt "set" fields with
                | Some (`String s) -> Some s | _ -> None in
              if get = None && set = None then None
              else Some (key, { Dialog_global.prop_get = get; prop_set = set })
            | _ -> None
          ) state_defs
        | _ -> []
      in
      Dialog_global.current_state := Some live_state;
      Dialog_global.current_id := Some ds.id;
      Dialog_global.current_outer_scope := outer_scope;
      Dialog_global.current_props := props;
      Dialog_global.clear_state_change_listeners ();
      Dialog_global.current_close := (fun () -> dialog#destroy ());
      Dialog_global.current_build_ctx := (fun () ->
        `Assoc (
          ("state", `Assoc state_defaults) ::
          ("dialog", `Assoc (Dialog_global.read_state ())) ::
          ("param", `Assoc ds.params) ::
          ("icons", icons) ::
          outer_scope
        ));
      let ctx = !Dialog_global.current_build_ctx () in
      (match List.assoc_opt "content" dlg_def with
       | Some content ->
         Yaml_panel_view.render_element
           ~packing:(vbox#pack ~expand:false)
           ~ctx content
       | None -> ());
      dialog#show ();
      ignore (dialog#run ());
      (try dialog#destroy () with _ -> ());
      Dialog_global.current_state := None;
      Dialog_global.current_id := None;
      Dialog_global.current_outer_scope := [];
      Dialog_global.current_props := [];
      Dialog_global.clear_state_change_listeners ();
      Dialog_global.current_close := (fun () -> ());
      Dialog_global.current_build_ctx := (fun () -> `Assoc [])
    | _ -> ()

(** Show a [modal: false] YAML dialog as a non-blocking GTK flyout.

    Unlike [show_dialog] (which is modal and runs a blocking
    [dialog#run] loop), this opens an undecorated top-level window
    that does NOT grab the main loop — so the canvas / toolbar stay
    live and the popup dismisses itself on a click outside or when an
    item's [close_dialog] effect fires. Used by the toolbar's
    long-press tool-alternates flyout.

    The window is positioned at the current pointer location so it
    appears next to the slot button the user is holding. The same
    [Dialog_global] wiring [show_dialog] installs is reused, so an
    item button's [set: { active_tool: ... }] + [close_dialog]
    behavior dispatches through the identical render-button path. *)
let show_nonmodal_dialog (ds : dialog_state) : unit =
  match Workspace_loader.load () with
  | None -> ()
  | Some ws ->
    match Workspace_loader.dialog ws ds.id with
    | Some (`Assoc dlg_def) ->
      (* If a prior flyout is still open, dismiss it first so two
         long-presses don't stack windows. *)
      Dialog_global.close ();
      let win = GWindow.window
        ~type_hint:`POPUP_MENU
        ~decorated:false
        ~resizable:false
        ~show:false
        () in
      win#set_skip_taskbar_hint true;
      win#set_skip_pager_hint true;
      (* Accept + grab focus on map so the focus-out dismissal below is
         reliable: the popup holds focus, and the user's next click
         elsewhere moves focus away and closes it (menu semantics). *)
      win#set_accept_focus true;
      win#set_focus_on_map true;
      (* Anchor the flyout at the pointer (the slot button the user is
         long-pressing). [window_at_pointer] gives the window under the
         cursor plus pointer-relative coords; that window's root origin
         converts them to absolute screen coords. Offset a touch so the
         popup sits below-right of the cursor rather than under it.
         Best-effort: a centered popup if the pointer can't be read. *)
      (try
        match Gdk.Display.window_at_pointer () with
        | Some (gwin, rx, ry) ->
          let (ox, oy) = Gdk.Window.get_origin gwin in
          win#move ~x:(ox + rx + 4) ~y:(oy + ry + 4)
        | None -> ()
      with _ -> ());
      (* Dark popup chrome so the flyout matches the dark toolbar/menu:
         GTK's default popup background is light, which makes the
         #cccccc-tinted tool icons read as gray. A dark bg makes the
         same icons pop bright/white like they do on the toolbar. Use
         [`NONE] shadow on the frame so GTK's light 3D bevel doesn't
         fight the dark fill, and paint a subtle border + radius via a
         CSS provider (mirrors how menubar.ml builds + adds a provider).
         The bg color comes from [dialog_bg_hook] (wired in main.ml to
         the active appearance's dark pane background). *)
      let frame = GBin.frame ~shadow_type:`NONE ~packing:win#add () in
      let vbox = GPack.vbox ~packing:frame#add () in
      let flyout_bg = !(Yaml_panel_view.dialog_bg_hook) () in
      let flyout_css = new GObj.css_provider (GtkData.CssProvider.create ()) in
      flyout_css#load_from_data (Printf.sprintf
        "window, frame, frame > border, box { background-color: %s; } \
         frame, frame > border { border: 1px solid #5a5a5a; border-radius: 4px; padding: 2px; }"
        flyout_bg);
      win#misc#style_context#add_provider flyout_css 600;
      frame#misc#style_context#add_provider flyout_css 600;
      vbox#misc#style_context#add_provider flyout_css 600;
      let state_defaults = Workspace_loader.state_defaults ws in
      let icons = Workspace_loader.icons ws in
      let live_state = ref ds.state in
      let props = match List.assoc_opt "state" dlg_def with
        | Some (`Assoc state_defs) ->
          List.filter_map (fun (key, def) ->
            match def with
            | `Assoc fields ->
              let get = match List.assoc_opt "get" fields with
                | Some (`String s) -> Some s | _ -> None in
              let set = match List.assoc_opt "set" fields with
                | Some (`String s) -> Some s | _ -> None in
              if get = None && set = None then None
              else Some (key, { Dialog_global.prop_get = get; prop_set = set })
            | _ -> None
          ) state_defs
        | _ -> []
      in
      Dialog_global.current_state := Some live_state;
      Dialog_global.current_id := Some ds.id;
      Dialog_global.current_outer_scope := [];
      Dialog_global.current_props := props;
      Dialog_global.clear_state_change_listeners ();
      (* close_dialog / dismiss_dialog and the outside-click handler
         all route through this. Tear down the Dialog_global wiring on
         destroy so a closed flyout leaves no stale state behind. *)
      let teardown () =
        Dialog_global.current_state := None;
        Dialog_global.current_id := None;
        Dialog_global.current_outer_scope := [];
        Dialog_global.current_props := [];
        Dialog_global.clear_state_change_listeners ();
        Dialog_global.current_close := (fun () -> ());
        Dialog_global.current_build_ctx := (fun () -> `Assoc [])
      in
      Dialog_global.current_close := (fun () ->
        teardown ();
        (try win#destroy () with _ -> ()));
      Dialog_global.current_build_ctx := (fun () ->
        `Assoc (
          ("state", `Assoc state_defaults) ::
          ("dialog", `Assoc (Dialog_global.read_state ())) ::
          ("param", `Assoc ds.params) ::
          ("icons", icons) :: []
        ));
      let ctx = !Dialog_global.current_build_ctx () in
      (* Render the flyout's tool icons larger than the 20px panel
         default — close to the 32px toolbar so the alternates read as
         prominent tool buttons, not shrunken glyphs. The items in
         tool_alternates.yaml declare no [style.size], so they pick up
         this scoped override. Restored to [None] in a finally so panels
         and modal dialogs keep their 20px default even if render raises. *)
      Yaml_panel_view.nonmodal_icon_size := Some 28;
      (match List.assoc_opt "content" dlg_def with
       | Some content ->
         (match Yaml_panel_view.render_element
            ~packing:(vbox#pack ~expand:false)
            ~ctx content
          with
          | () -> Yaml_panel_view.nonmodal_icon_size := None
          | exception e ->
            Yaml_panel_view.nonmodal_icon_size := None;
            raise e)
       | None -> Yaml_panel_view.nonmodal_icon_size := None);
      (* Dismiss on focus-out (a click anywhere outside the popup moves
         focus away, so the flyout closes — matching menu semantics:
         the next click either lands on an item (running its
         close_dialog) or dismisses the popup). *)
      ignore (win#event#connect#focus_out ~callback:(fun _ ->
        Dialog_global.close (); false));
      win#show ();
      win#present ()
    | _ -> ()
