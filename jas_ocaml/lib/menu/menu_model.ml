(** Menu bar render model — projected from the compiled workspace
    [menubar] (menubar.yaml).

    The menu bar is rendered (in [Menubar]) from [menu_bar_model], which
    projects the single source of truth — the compiled [menubar] — into a
    render model. This replaced a hand-maintained set of five hardcoded
    native menus that had drifted from the spec (e.g. the View menu was
    missing Actual Size / Fit Artboard / Fit All, Save and Save As both
    bound Ctrl+S). Projecting from the bundle means the OCaml menu bar can
    no longer diverge from menubar.yaml.

    The dynamic Workspace / Appearance submenus stay runtime-populated by
    bespoke code in [Menubar]; the model only carries their trigger label
    and identity. This module is GTK-free so it can be unit-tested
    headless. Mirrors the Rust menu.rs projector. *)

(** Which runtime-populated submenu a [Dynamic_submenu] entry drives. *)
type submenu_kind = Workspace | Appearance

(** One resolved menu entry. *)
type entry =
  | Separator
  | Dynamic_submenu of { label : string; kind : submenu_kind }
  | Action of {
      label : string;
      action : string;
      params : (string * Yojson.Safe.t) list;
      shortcut : string;
      enabled_when : string option;
    }

(** One top-level menu (e.g. "&File") and its entries. *)
type menu = { label : string; entries : entry list }

let str_member key j =
  match Workspace_loader.json_member key j with
  | Some (`String s) -> s
  | _ -> ""

let contains_sub (s : string) (sub : string) : bool =
  let n = String.length s and m = String.length sub in
  if m = 0 then true
  else
    let rec loop i =
      if i + m > n then false
      else if String.sub s i m = sub then true
      else loop (i + 1)
    in
    loop 0

let project_entry (item : Yojson.Safe.t) : entry =
  match item with
  (* A bare "separator" string. *)
  | `String "separator" -> Separator
  | _ ->
    (* A submenu carries nested "items"; the only ones today are the
       dynamic Workspace / Appearance submenus, rendered natively. *)
    (match Workspace_loader.json_member "items" item with
     | Some _ ->
       let label = str_member "label" item in
       let id = str_member "id" item in
       let kind =
         if contains_sub id "appearance" || contains_sub label "Appearance"
         then Appearance
         else Workspace
       in
       Dynamic_submenu { label; kind }
     | None ->
       let params =
         match Workspace_loader.json_member "params" item with
         | Some (`Assoc pairs) -> pairs
         | _ -> []
       in
       let enabled_when =
         match Workspace_loader.json_member "enabled_when" item with
         | Some (`String s) -> Some s
         | _ -> None
       in
       Action {
         label = str_member "label" item;
         action = str_member "action" item;
         params;
         shortcut = str_member "shortcut" item;
         enabled_when;
       })

let project_menu (menu : Yojson.Safe.t) : menu =
  let label = str_member "label" menu in
  let entries =
    match Workspace_loader.json_member "items" menu with
    | Some (`List items) -> List.map project_entry items
    | _ -> []
  in
  { label; entries }

let menu_bar_model () : menu list =
  match Workspace_loader.load () with
  | None -> []
  | Some ws -> List.map project_menu (Workspace_loader.menubar ws)

let strip_mnemonic (label : string) : string =
  let buf = Buffer.create (String.length label) in
  let n = String.length label in
  let i = ref 0 in
  while !i < n do
    let c = label.[!i] in
    if c = '&' then begin
      if !i + 1 < n && label.[!i + 1] = '&' then begin
        (* Escaped literal ampersand. *)
        Buffer.add_char buf '&';
        i := !i + 2
      end else
        (* Drop the mnemonic marker. *)
        incr i
    end else begin
      Buffer.add_char buf c;
      incr i
    end
  done;
  Buffer.contents buf
