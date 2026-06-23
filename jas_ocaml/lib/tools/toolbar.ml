(** Tool-state controller for the workspace.

    Originally a hand-drawn GTK toolbar widget; the visible toolbar now
    renders from the compiled bundle [tool_grid] via [Yaml_panel_view]
    (see STEP A in bin/main.ml). The native widget — Cairo icon drawing,
    the GTK drawing-area grid, the long-press [GMenu] alternates menus,
    and the long-press timers — has been removed (STEP B). What remains
    is the live tool-state controller that the canvas, the keyboard
    shortcuts, and the bundle toolbar highlight all read and drive:
    the [tool] type, [current_tool], [select_tool], [tool_changed_hook],
    plus the fill/stroke default-color state ([fill_on_top] and its
    mutators) that [bin/main.ml]'s [get_fill_on_top] surfaces to the
    bundle fill/stroke widget. *)

type tool = Selection | Partial_selection | Interior_selection | Magic_wand | Pen | Add_anchor_point | Delete_anchor_point | Anchor_point | Pencil | Paintbrush | Blob_brush | Path_eraser | Smooth | Type_tool | Type_on_path | Line | Rect | Rounded_rect | Ellipse | Polygon | Star | Lasso | Scale | Rotate | Shear | Hand | Zoom | Artboard | Eyedropper

(** Map a tool variant to its workspace/tools/*.yaml filename stem.
    Returns [None] for native-only tools without a YAML spec. *)
let tool_yaml_id = function
  | Selection -> Some "selection"
  | Partial_selection -> Some "partial_selection"
  | Interior_selection -> Some "interior_selection"
  | Magic_wand -> Some "magic_wand"
  | Pen -> Some "pen"
  | Add_anchor_point -> Some "add_anchor_point"
  | Delete_anchor_point -> Some "delete_anchor_point"
  | Anchor_point -> Some "anchor_point"
  | Pencil -> Some "pencil"
  | Paintbrush -> Some "paintbrush"
  | Blob_brush -> Some "blob_brush"
  | Path_eraser -> Some "path_eraser"
  | Smooth -> Some "smooth"
  | Line -> Some "line"
  | Rect -> Some "rect"
  | Rounded_rect -> Some "rounded_rect"
  | Ellipse -> Some "ellipse"
  | Polygon -> Some "polygon"
  | Star -> Some "star"
  | Lasso -> Some "lasso"
  | Scale -> Some "scale"
  | Rotate -> Some "rotate"
  | Shear -> Some "shear"
  | Hand -> Some "hand"
  | Zoom -> Some "zoom"
  | Artboard -> Some "artboard"
  | Eyedropper -> Some "eyedropper"
  | Type_tool | Type_on_path -> None

(** Look up a tool's [tool_options_dialog] field in workspace.json.
    Returns the dialog id when set, [None] otherwise. *)
let tool_options_dialog_id (t : tool) : string option =
  let open Option in
  bind (tool_yaml_id t) (fun yaml_id ->
    bind (Workspace_loader.load ()) (fun ws ->
      bind (Workspace_loader.json_member "tools" ws.data) (function
        | `Assoc tools ->
          bind (List.assoc_opt yaml_id tools) (function
            | `Assoc fields ->
              bind (List.assoc_opt "tool_options_dialog" fields) (function
                | `String s -> Some s
                | _ -> None)
            | _ -> None)
        | _ -> None)))

(* Fired at the end of [select_tool] with the newly-active tool. The
   bundle-rendered toolbar (Yaml_panel_view) wires this to mirror the
   tool into a string the YAML [bind.checked] expressions read, then
   rebuild itself so the highlight tracks the active tool — regardless
   of whether the change came from a toolbar click, a keyboard shortcut,
   or the spacebar Hand pass-through. *)
let tool_changed_hook : (tool -> unit) ref = ref (fun _ -> ())

class toolbar ?(get_model : (unit -> Model.model) option) () =
  object (_self)
    val mutable current_tool = Selection
    val mutable fill_on_top = true

    method current_tool = current_tool
    method fill_on_top = fill_on_top
    method set_fill_on_top v = fill_on_top <- v

    method toggle_fill_on_top =
      fill_on_top <- not fill_on_top

    method reset_defaults =
      (match get_model with
       | Some gm ->
         let m = gm () in
         m#set_default_fill None;
         m#set_default_stroke (Some (Element.make_stroke Element.black))
       | None -> ())

    method swap_fill_stroke =
      (match get_model with
       | Some gm ->
         let m = gm () in
         let old_fill = m#default_fill in
         let old_stroke = m#default_stroke in
         (* Convert fill color to stroke, stroke color to fill *)
         let new_fill = (match old_stroke with
           | Some s -> Some { Element.fill_color = s.Element.stroke_color;
                              fill_opacity = s.Element.stroke_opacity }
           | None -> None) in
         let new_stroke = (match old_fill with
           | Some f -> Some (Element.make_stroke ~opacity:f.Element.fill_opacity
                               f.Element.fill_color)
           | None -> None) in
         m#set_default_fill new_fill;
         m#set_default_stroke new_stroke
       | None -> ())

    method select_tool t =
      current_tool <- t;
      (* Notify the bundle toolbar so its highlight tracks. *)
      !tool_changed_hook t
  end

let create ?get_model () =
  new toolbar ?get_model ()
