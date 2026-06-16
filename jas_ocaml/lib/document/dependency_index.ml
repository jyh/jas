(** Derived DEPENDENCY INDEX over the by-id reference graph
    (REFERENCE_GRAPH.md section 3). See [dependency_index.mli] for the
    locked semantics: operands are OPAQUE to the by-id graph, everything
    is sorted for determinism, and the structure is a pure function of
    the [Document] (never stored, never in a codec). *)

open Element

module SMap = Map.Make (String)
module SSet = Set.Make (String)

type t = {
  deps : (string * string list) list;
  rdeps : (string * string list) list;
  dangling : string list;
  cycles : string list;
}

(* Out-edges of a single element: a [Reference]'s target, or empty for
   every other kind. [Live.dependencies] is empty for a [Compound_shape]
   (its operands are owned), so a compound contributes no out-edges even
   though it owns id-bearing operands. *)
let element_dependencies (elem : element) : element_ref list =
  match elem with
  | Live v -> Live.dependencies v
  | _ -> []

(* Walk [elem] in canonical pre-order, recursing into Group / Layer
   children ONLY (never a compound's operands — the operands-opaque
   rule). Records, for every id-bearing element, its id in [targetable]
   and its out-edges in [out_edges]. First-occurrence-wins on a duplicate
   id (matches the resolver and the import-time uniqueness invariant;
   duplicates do not occur in a well-formed document). *)
let rec walk elem (targetable : SSet.t ref) (out_edges : string list SMap.t ref) : unit =
  (match Element.id_of elem with
   | Some id ->
     if not (SSet.mem id !targetable) then begin
       targetable := SSet.add id !targetable;
       let edges = element_dependencies elem in
       if edges <> [] then out_edges := SMap.add id edges !out_edges
     end
   | None -> ());
  match elem with
  | Group { children; _ } | Layer { children; _ } ->
    Array.iter (fun child -> walk child targetable out_edges) children
  | _ -> ()

(* Sort + dedup a string list. *)
let sort_dedup (xs : string list) : string list =
  List.sort_uniq String.compare xs

(* DFS over the deps edges with SORTED neighbor iteration (for
   determinism), tracking the current recursion stack. When an edge
   reaches a node already on the stack, every node from that node to the
   top of the stack is a cycle member; they are collected. A self-target
   ([R -> R]) is detected the same way. Edges to non-deps ids (leaf or
   dangling targets) are skipped — they cannot start a cycle. *)
let rec dfs_cycles node (deps : string list SMap.t) (visited : SSet.t ref)
    (stack : string list ref) (on_cycle : SSet.t ref) : unit =
  visited := SSet.add node !visited;
  stack := node :: !stack;
  (match SMap.find_opt node deps with
   | Some neighbors ->
     (* [neighbors] is already sorted; iterate it directly for determinism. *)
     List.iter (fun next ->
       (* Find [next] on the current stack ([stack] is top-first). The
          portion from the head down to (and including) [next] is the
          cycle. *)
       let rec collect_until = function
         | [] -> false
         | x :: rest ->
           on_cycle := SSet.add x !on_cycle;
           if x = next then true else collect_until rest
       in
       if List.mem next !stack then
         (* Back-edge into the current stack: mark every member from the
            top down to [next] inclusive (covers self-target, where
            [next = node] is the head). *)
         ignore (collect_until !stack)
       else if not (SSet.mem next !visited) then
         dfs_cycles next deps visited stack on_cycle
       (* else: already fully explored, not on the current stack -> no
          cycle reachable through it that we have not already recorded. *)
     ) neighbors
   | None -> ());
  (* Pop. *)
  (match !stack with _ :: rest -> stack := rest | [] -> ())

(* Return the sorted, de-duplicated set of node ids that lie on a cycle
   in the [deps] graph (a node that can reach itself). *)
let find_cycle_members (deps : string list SMap.t) : string list =
  let on_cycle = ref SSet.empty in
  let visited = ref SSet.empty in
  (* Iterating the SMap keys yields sorted roots; each DFS visits in
     sorted neighbor order (deps values are pre-sorted in [build]). *)
  SMap.iter (fun start _ ->
    if not (SSet.mem start !visited) then begin
      let stack = ref [] in
      dfs_cycles start deps visited stack on_cycle
    end
  ) deps;
  SSet.elements !on_cycle

let build (doc : Document.document) : t =
  (* Phase 1: gather the node set (targetable ids) and raw out-edges by
     walking layers + Group/Layer children (operands stay opaque). *)
  let targetable = ref SSet.empty in
  let out_edges = ref SMap.empty in
  Array.iter (fun layer -> walk layer targetable out_edges) doc.Document.layers;
  let targetable = !targetable in

  (* Phase 2: build [deps] (sorted out-edges) and [rdeps] (reverse), and
     collect [dangling] (any out-edge target missing from [targetable]). *)
  let deps = ref SMap.empty in
  let rdeps = ref SMap.empty in
  let dangling = ref SSet.empty in
  SMap.iter (fun id edges ->
    let sorted = sort_dedup edges in
    List.iter (fun target ->
      if SSet.mem target targetable then begin
        (* Reverse edge: only targetable ids get an [rdeps] entry, so an
           absent / operand-nested target contributes none. *)
        let cur = match SMap.find_opt target !rdeps with Some l -> l | None -> [] in
        rdeps := SMap.add target (id :: cur) !rdeps
      end else
        (* Target not in the node walk -> this referencing id is dangling
           (absent target, or operand-nested = operands-opaque). *)
        dangling := SSet.add id !dangling
    ) sorted;
    deps := SMap.add id sorted !deps
  ) !out_edges;

  (* Normalize rdeps value lists to sorted + deduped. *)
  let rdeps = SMap.map sort_dedup !rdeps in
  let deps = !deps in

  (* Phase 3: cycles — every id that can reach itself in the deps graph. *)
  let cycles = find_cycle_members deps in

  {
    deps = SMap.bindings deps;
    rdeps = SMap.bindings rdeps;
    dangling = SSet.elements !dangling;
    cycles;
  }

(* ------------------------------------------------------------------ *)
(* Canonical JSON serializer                                          *)
(* ------------------------------------------------------------------ *)
(*
   Mirrors the hand-rolled canonical-JSON pattern used by
   [Workspace_test_json] / [Test_json] (sorted keys, sorted arrays).
   Deliberately NOT a generic JSON dumper: the sibling apps hand-roll the
   identical shape, and the output must be byte-identical. There are no
   floats here, but the object / array / string-escape conventions match
   the test_json serializer exactly (compact, sorted keys, backslash and
   double-quote escaped). *)

(* Escape a string for embedding in a canonical-JSON string literal.
   Matches [Workspace_test_json.json_str] (backslash then double-quote). *)
let escape (s : string) : string =
  s |> String.to_seq
    |> Seq.flat_map (fun c ->
      match c with
      | '\\' -> String.to_seq "\\\\"
      | '"'  -> String.to_seq "\\\""
      | c    -> Seq.return c)
    |> String.of_seq

let quote (s : string) : string = Printf.sprintf "\"%s\"" (escape s)

(* Render a sorted string array (the input list is already sorted). *)
let array_json (v : string list) : string =
  Printf.sprintf "[%s]" (String.concat "," (List.map quote v))

(* Render [{id: [sorted ids]}] with sorted keys (the binding list is
   already sorted; value lists are sorted at build time). *)
let map_json (m : (string * string list) list) : string =
  let entries =
    List.map (fun (k, v) -> Printf.sprintf "%s:%s" (quote k) (array_json v)) m
  in
  Printf.sprintf "{%s}" (String.concat "," entries)

let to_test_json (idx : t) : string =
  (* Keys emitted in sorted (alphabetical) order: cycles, dangling,
     deps, rdeps. *)
  Printf.sprintf "{\"cycles\":%s,\"dangling\":%s,\"deps\":%s,\"rdeps\":%s}"
    (array_json idx.cycles)
    (array_json idx.dangling)
    (map_json idx.deps)
    (map_json idx.rdeps)
