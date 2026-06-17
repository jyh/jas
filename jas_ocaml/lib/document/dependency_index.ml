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
  topo_order : string list;
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

(* Compute the deterministic, DEPENDENCIES-FIRST topological ordering of
   the by-id reference graph (REFERENCE_GRAPH.md section 8 Phase 4a). The
   recompute schedule a future incremental phase walks: a reference's
   target always precedes the reference.

   THIS ALGORITHM IS LOCKED and must be byte-identical across all four
   apps. It is the highest cross-language desync risk in this module.

   Kahn's algorithm with SORTED-ID tie-breaking, processed LEVEL-BY-LEVEL:

   - NODES = the sorted set of all ids that are a [deps]-key OR an
     [rdeps]-key (every id that is a source or a PRESENT target of an
     edge). Dangling / operand-opaque targets (referenced but not
     present/targetable, i.e. they appear in [deps] values but are not
     nodes) are NOT nodes and create NO topo edge.
   - Each node dependency count = the number of its [deps] targets that
     ARE nodes (present). Edges to non-node targets are ignored.
   - Take the WHOLE current ready set (every un-emitted node whose
     remaining dependency count is 0), emit it in sorted-id order, and
     decrement the remaining count of every node that depends on an
     emitted node (its [rdeps]). Nodes freed during this level become
     ready only for the NEXT level — a node freed by emitting [a] is NOT
     eligible to slot in before the rest of [a]'s level. (This is what
     the LOCKED worked example pins: emitting {a,r3,r4} as one level
     frees r1,r2 for the next level, so the order is a,r3,r4,r1,r2 — NOT
     a,r1,r2,r3,r4.) Ties ALWAYS by sorted id.
   - Cycle remnants: any nodes that never reach dependency-count 0 are
     appended at the END in sorted-id order. These are the nodes blocked
     by a cycle: every cycle member (the [cycles] set) PLUS any node that
     transitively depends on a cycle (e.g. [tail -> c1] where c1<->c2 —
     [tail] never frees). [cycles] is therefore a SUBSET of the remnants,
     not the whole set; the operational rule is "any node that never
     reaches count 0".

   Result: dependencies before dependents, fully deterministic.

   [deps] / [rdeps] here are the already-built (sorted) SMaps. *)
let topo_order (deps : string list SMap.t) (rdeps : string list SMap.t) : string list =
  (* NODES: sorted union of deps-keys and rdeps-keys. The SSet keeps it
     sorted and de-duplicated; iteration is deterministic. *)
  let nodes =
    SMap.fold (fun k _ acc -> SSet.add k acc)
      rdeps
      (SMap.fold (fun k _ acc -> SSet.add k acc) deps SSet.empty)
  in
  (* Remaining dependency count per node: number of its deps targets that
     are themselves nodes (present). Non-node (dangling/opaque) targets
     are ignored. *)
  let remaining = ref (
    SSet.fold (fun node acc ->
      let count =
        match SMap.find_opt node deps with
        | Some targets ->
          List.fold_left (fun n t -> if SSet.mem t nodes then n + 1 else n) 0 targets
        | None -> 0
      in
      SMap.add node count acc
    ) nodes SMap.empty
  ) in
  let emitted = ref SSet.empty in
  let order = ref [] in (* accumulated in reverse; reversed once at the end *)

  (* Level-by-level Kahn loop. Each pass snapshots the CURRENT ready set
     (all un-emitted nodes with remaining count 0), emits it in sorted-id
     order, and only then applies the decrements its emissions cause — so
     newly-freed nodes wait for the next level. Iterating the sorted
     [nodes] set yields the ready set already in sorted order. A node
     blocked by a cycle never reaches count 0, so the loop terminates when
     no node is ready. *)
  let rec loop () =
    (* Snapshot this level's ready set (sorted, since [nodes] is an SSet). *)
    let level =
      SSet.fold (fun n acc ->
        if (not (SSet.mem n !emitted)) && SMap.find_opt n !remaining = Some 0
        then n :: acc else acc
      ) nodes []
      |> List.rev (* SSet.fold is ascending; the cons-reverse restores it *)
    in
    if level = [] then ()
      (* no node ready -> remaining un-emitted are cyclic remnants *)
    else begin
      (* Emit the whole level in sorted order, marking each emitted first
         so decrements below cannot re-add a same-level node. *)
      List.iter (fun node ->
        order := node :: !order;
        emitted := SSet.add node !emitted
      ) level;
      (* Apply this level's decrements AFTER emitting the level, so a node
         freed now only becomes ready on the NEXT iteration. *)
      List.iter (fun node ->
        match SMap.find_opt node rdeps with
        | Some dependents ->
          List.iter (fun dep ->
            match SMap.find_opt dep !remaining with
            | Some c ->
              (* Saturating guard: a present dependent always had this
                 node counted, so c > 0 here; max 0 keeps it sound even on
                 a (impossible) double-count. *)
              remaining := SMap.add dep (max 0 (c - 1)) !remaining
            | None -> ()
          ) dependents
        | None -> ()
      ) level;
      loop ()
    end
  in
  loop ();

  (* Remnants: any node never emitted is blocked by a cycle — either it is
     ON a cycle (it is in [cycles]) OR it transitively DEPENDS on a cycle
     and so can never reach count 0 (e.g. [tail -> c1] where c1<->c2).
     Both kinds are appended at the END in sorted-id order. [cycles] is a
     SUBSET of these remnants, not necessarily the whole set; we therefore
     derive the remnants from the un-emitted nodes directly (the
     operational rule "any node that never reaches dependency-count 0"),
     which keeps the order deterministic and dependencies-first for the
     entire acyclic prefix. Iterating the sorted [nodes] set yields the
     remnants already in sorted-id order. *)
  let remnants =
    SSet.fold (fun node acc ->
      if SSet.mem node !emitted then acc else node :: acc
    ) nodes []
    |> List.rev
  in
  List.rev_append !order remnants

let build (doc : Document.document) : t =
  (* Phase 1: gather the node set (targetable ids) and raw out-edges by
     walking layers + Group/Layer children (operands stay opaque), THEN
     the master store (SYMBOLS.md section 6). Including doc.symbols puts
     master ids in the targetable set so an instance -> master is not
     dangling, and rdeps[master] lists the master's instances. Masters
     are walked with the SAME operands-opaque discipline as layers; their
     OWN id is targetable (a master is reached only through a reference).
     Sorted by id first for deterministic first-occurrence-wins on the
     (well-formed: impossible) duplicate-id case. *)
  let targetable = ref SSet.empty in
  let out_edges = ref SMap.empty in
  Array.iter (fun layer -> walk layer targetable out_edges) doc.Document.layers;
  let id_of m = match Element.id_of m with Some s -> s | None -> "" in
  let sorted_masters =
    Array.to_list doc.Document.symbols
    |> List.stable_sort (fun a b -> String.compare (id_of a) (id_of b))
  in
  List.iter (fun master -> walk master targetable out_edges) sorted_masters;
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

  (* Phase 4a: the dependencies-first topological ordering (recompute
     schedule). Computed from the same [deps] / [rdeps] graph; cycle
     remnants trail in sorted order. The algorithm is LOCKED across all
     four apps. *)
  let topo = topo_order deps rdeps in

  {
    deps = SMap.bindings deps;
    rdeps = SMap.bindings rdeps;
    dangling = SSet.elements !dangling;
    cycles;
    topo_order = topo;
  }

(* ------------------------------------------------------------------ *)
(* Reference-aware delete: orphaned-references predicate              *)
(* ------------------------------------------------------------------ *)
(*
   REFERENCE_GRAPH.md — the equivalence-critical core of reference-aware
   delete (the confirm dialog is a later step). A pure graph query over
   the same by-id reference graph the index exposes, so it lives here
   next to [rdeps]. *)

(* Collect every id-bearing element id within [elem]'s subtree,
   recursing into Group / Layer children ONLY — the SAME walk discipline
   as [walk]: a [Compound_shape]'s operands are opaque, so an id that
   exists only inside an operand is not a node and is not collected. The
   set de-dups inherently. *)
let rec collect_ids elem (ids : SSet.t ref) : unit =
  (match Element.id_of elem with
   | Some id -> ids := SSet.add id !ids
   | None -> ());
  match elem with
  | Group { children; _ } | Layer { children; _ } ->
    Array.iter (fun child -> collect_ids child ids) children
  | _ -> ()

(* Answer "if I delete these elements, which live references (instances)
   elsewhere would be orphaned — left pointing at a now-deleted target?".

   Returns the SORTED, de-duplicated ids of references that point at an
   id which is being deleted but are not themselves in the deletion set.

   Algorithm (REFERENCE_GRAPH.md, locked semantics):
   1. [deleted_ids] — the id-bearing ids within every deletion subtree.
      Each path is resolved via [Document.get_element] (invalid paths
      skipped), then walked with the operands-opaque discipline
      ([collect_ids]); an id only inside a [Compound_shape] operand is
      therefore NOT a deleted target.
   2. Build [idx = build doc]. For each deleted target [t], its referrers
      are [rdeps[t]] (only targetable ids ever get an rdeps entry, so an
      operand-nested target contributes none).
   3. [orphaned = { r in rdeps[t] for all deleted t : r not in deleted_ids }]
      — references whose target is being deleted but which survive the
      delete.

   Consequences: deleting an element with no external referrers returns
   []; deleting a target together with its only referrer returns [] for
   that pair; deleting an instance returns [] (an instance has no rdeps);
   deleting a group orphans the external referrers of any referenced
   element it contains. *)
let orphaned_references (doc : Document.document) (deletion_paths : int list list)
    : string list =
  (* Step 1: gather the id-bearing ids inside every deletion subtree. *)
  let deleted_ids = ref SSet.empty in
  List.iter (fun path ->
    (* [get_element] raises on an out-of-range / malformed path; an
       invalid path resolves to no element and is skipped. *)
    match (try Some (Document.get_element doc path) with _ -> None) with
    | Some elem -> collect_ids elem deleted_ids
    | None -> ()
  ) deletion_paths;

  (* Step 2/3: for each deleted target, collect its referrers that are
     NOT themselves being deleted. *)
  let idx = build doc in
  let orphaned = ref [] in
  SSet.iter (fun t ->
    match List.assoc_opt t idx.rdeps with
    | Some referrers ->
      List.iter (fun r ->
        if not (SSet.mem r !deleted_ids) then orphaned := r :: !orphaned
      ) referrers
    | None -> ()
  ) !deleted_ids;
  List.sort_uniq String.compare !orphaned

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

(* Render a string array verbatim (preserving the input list's order).
   Used for the already-sorted [cycles] / [dangling] arrays AND for
   [topo_order], whose order is deliberately the topological sequence (NOT
   sorted) — its order is the data, so it must be rendered as-is. *)
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
     deps, rdeps, topo_order. Only topo_order's array value is non-sorted
     (it is the topological sequence itself). *)
  Printf.sprintf
    "{\"cycles\":%s,\"dangling\":%s,\"deps\":%s,\"rdeps\":%s,\"topo_order\":%s}"
    (array_json idx.cycles)
    (array_json idx.dangling)
    (map_json idx.deps)
    (map_json idx.rdeps)
    (array_json idx.topo_order)
