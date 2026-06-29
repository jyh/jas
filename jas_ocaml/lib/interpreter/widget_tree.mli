(* Shared canonical panel widget-TREE snapshot pass (TESTING_STRATEGY.md section 4).

   The structural sibling of [Panel_layout.layout_panel]: where the layout pass
   computes per-widget rects, this pass walks a compiled panel node
   ({"type":"panel","content":<root>}) into a pre-order, panel-relative JSON array
   of structural records, byte-identical across all native apps. Each record is
   {"path":[..], "type", "id", "kind", "col", "visible", "dyn_visible",
    "bind":[sorted keys], "style":[sorted keys]}, where [kind] is [type] when it
   is in the canonical widget vocabulary else placeholder, and [dyn_visible] flags
   a dynamic visibility (a string visible expression or a bind.visible).

   [widget_tree panel_node ctx]: [ctx] is the data scope (a Yojson object) used
   ONLY to evaluate foreach sources so the expansion count matches the layout
   pass -- the same evaluation [Panel_layout] performs; an empty object expands
   nothing. *)

val widget_tree : Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t
