# RECORDER — capture/replay fixture writer (Arc 1 S2)

The recorder turns live sessions in the Rust/wasm app into registered
cross-language conformance fixtures. v1 is a **fixture writer at the
existing seams emitting the existing corpus shapes** — it invents no new
replay format; everything it produces is replayed by the corpus runners
that already gate the active ports.

Code: `jas_dioxus/src/recorder/` (`core` capture buffers, `hooks`
wiring + activation, `replay` the shared corpus replay path, `fidelity`
the record-stop check). Ingest: `scripts/ingest_recording.py`. Pilot
driver: `scripts/record_pilot.py`.

## Seams

| Seam      | Captures at                                        | Emits (corpus shape)        |
|-----------|----------------------------------------------------|-----------------------------|
| `gesture` | the CanvasTool pointer seam (`on_press/move/release`, hooked in `workspace/app.rs` before tool dispatch) | `test_fixtures/gestures/` cases |
| `action`  | `dispatch_action` entry (depth-0 dispatches only — nested dispatches are the outer action's own effects) | `test_fixtures/actions/` cases |
| `key`     | the `resolve_key` chord site in `keyboard.rs`      | `test_fixtures/keys/` groups |
| `journal` | the committed Transaction journal (`journal()[start..head]` at stop) | `test_fixtures/operations/` txns-form |

One recording captures ONE seam (see v1 boundaries).

## Activation

The recorder is always compiled and dormant; it costs one thread-local
check per event until armed.

- **URL param**: `?record=<seam>:<family>` arms at app start.
  `run_dioxus_desktop.sh` owns the URL — `APP_QUERY='record=gesture:my_family'`.
- **Window API** (CDP-drivable): `window.jas_record_start(seam, family)`
  -> bool, `window.jas_record_stop()` -> the recording JSON (also
  triggers a `<family>.recording.json` browser download through the
  same path Save/PDF export use), `window.jas_record_status()` ->
  `"<seam>:<family>"` or `""`.
- `run_dioxus_desktop.sh` env: `CDP_PORT=9222` adds
  `--remote-debugging-port` (+ `--remote-allow-origins`), `HEADLESS=1`
  runs `--headless=new`, `PROFILE=<dir>` picks the Chrome profile — a
  FRESH profile gives the stock-defaults starting document.
- Scripted drives: `.venv/bin/python scripts/record_pilot.py <scenario>
  --out DIR` (websocket-client is installed in `.venv`).

`family` must be `[a-z0-9_]+`; it becomes the fixture file name and the
case-name prefix (`<family>_1`, `<family>_2`, …).

## Determinism laws (frozen)

- **(a) Screen->doc at write time, per event.** Every pointer event is
  converted using the model's live view AT THAT EVENT
  (`doc = (screen - view_offset) / zoom`), so mid-gesture pan/zoom is
  captured correctly. Fixture event x/y are therefore doc coords under
  an identity view — the existing corpus convention.
- **(b) Floats are bit-exact.** Event coordinates are serialized in
  serde's shortest round-trip form. They are deliberately NOT rounded
  to the goldens' 4 decimals: rounding does not commute with the
  canonical doc-JSON's own rounding of derived geometry (the pan/zoom
  pilot caught a committed height of 34.7222 live vs 34.7223 replayed
  from rounded events), and the fidelity check refuses such drift.
  Goldens keep their own 4-decimal canonical test-JSON format.
- **(c) The recorder mints no ids.** Draw commits mint none; op ids
  ride value-in-op; ids present in the setup document travel inside the
  captured setup SVG.

## v1 preconditions (enforced by the writer)

Captured at every case boundary and stamped into
`precondition_violations` (ingest refuses violated cases unless
`--allow-unfaithful`):

- **Stock model defaults** — record from a fresh profile/document;
  app-level state the tools consume is captured per case as `app_state`
  (the live canvas bridge map, `build_tool_state_map`).
- **Empty starting selection** (`selection_not_empty`) — SVG carries no
  selection, so replay always starts unselected.
- **The setup document must survive the SVG round-trip**
  (`svg_roundtrip_lossy`) — the writer round-trips
  `document_to_svg` -> `svg_to_document` and byte-compares the
  canonical JSON.
- Journal seam: ops-less transactions are flagged
  (`opaque_transaction_without_ops` — see v1 boundaries), and history
  navigation below the record-start baseline
  (`history_navigated_below_baseline`).

## Segmentation (frozen law)

One tool per gesture case. The current case ENDS (its fidelity oracle
is captured) and the next press starts a new case — with a fresh setup
snapshot — on any of:

- tool switch (observed at the next press);
- app-state change (the bridge map differs at the next press);
- any depth-0 `dispatch_action` (the action may mutate the document
  outside the pointer seam);
- history navigation (undo/redo);
- pointer traffic on a permanently native tool (Type / Type-on-Path —
  no YAML replay path).

Hover traffic is filtered: only events inside a press..release window
are recorded, and multiple gestures with the same tool + app state
share one case (that is how the blob merge fixture holds two strokes).

## The record-stop fidelity check (frozen clause)

Before emitting, every captured case is REPLAYED through
`recorder::replay` — the **same code path the corpus runners execute**
(`cross_language_test.rs` delegates its gesture/action/key runners to
that module, so the two can never drift) — and the result is
byte-compared against the live document's canonical test-JSON captured
at the case boundary. A mismatch stamps the case and the envelope with
a loud `UNFAITHFUL` marker (the mismatching replay is attached as
`replayed_doc_json`); the ingest script refuses such cases. This is the
first automated corpus-vs-production fidelity probe: anything that
mutates the document outside the recorded seam, or any replay-semantics
gap, is caught at the source. The key seam is a pure resolution and
stamps `PURE`.

## Ingest flow

```
scripts/ingest_recording.py <family>.recording.json [--register]
    [--allow-unfaithful] [--fixtures-root DIR]
scripts/ingest_recording.py --self-test
```

1. Validates the envelope (version, seam, family, fidelity stamps,
   precondition flags).
2. Materializes the embedded setup SVGs into `test_fixtures/svg/`
   (content-deduplicated against existing files; an existing file with
   different bytes is an error — corpus bytes are never modified) and
   the corpus-shaped fixture into the seam's family directory.
3. Mints the `*_expected.json` goldens by replaying the on-disk fixture
   through the `corpus_replay` bin (the shared replay path), and
   cross-checks each golden against the recording's live oracle — a
   second fidelity pin at ingest time.
4. Prints the registration lines for BOTH active ports' fixture lists,
   or patches them with `--register` (gesture/action/key lists; the
   operations corpus registers per-test helper calls, printed only).
   The corpus-manifest gate (`scripts/check_corpus_manifest.py`)
   polices the port symmetry either way.

## Pilots (landed)

1. **Plumbing** — a CDP-scripted rect draw recorded, ingested,
   registered, byte-green in Rust AND Swift
   (`gestures/recorded_rect.json`). Immediately caught a real
   corpus-runner asymmetry: Swift's fixture `app_state` staging treated
   `fill_color: "#ffffff"` as a real white default fill, where the
   production bridge publishes `"#ffffff"` as the defaultFill-NIL
   fallback — fall-through commits (rect.yaml deliberately omits
   fill/stroke) diverged. The Swift runner now applies the exact
   inverse of the production bridge.
2. **Worst corner** — the same draw under nonzero pan AND zoom 1.44
   (`gestures/recorded_rect_panzoom.json`): the fixture's events are
   doc-space, replay is byte-identical in both ports. The first run
   exposed the float-rounding non-commutativity fixed as law (b).
3. **Value** — three previously-uncovered Blob Brush transcript items
   (`transcripts/BLOB_BRUSH_TOOL_TESTS.md`), each a registered
   both-port-green fixture: `recorded_blob_dot` (BB-015 zero-length
   click), `recorded_blob_merge` (BB-070/073 overlapping strokes merge
   to one path), `recorded_blob_separate` (BB-071 stays two paths).

## v1 boundaries (FROZEN)

- **One seam per recording; multi-seam interleaved sessions are v2** —
  aligned with OP_LOG's multi-document envelope deferral.
- **Drawing captures at the GESTURE seam** because the op vocabulary
  has no creation verbs (draw commits journal named-but-EMPTY
  transactions — the journal seam flags them as opaque). Extending the
  op vocabulary with creation verbs is a named future decision, not
  Arc 1.
- **Swift capture is deferred** — Rust/wasm is the authoring host per
  the ratified S2 ruling (capture lives where the demo and future AI
  live). Swift consumes recorded fixtures through the corpus gate.
- **The 38-transcript conversion campaign is follow-on volume**, not
  part of this stone; the pilots prove the pipeline.
- **Fall-through fill/stroke recordings with a non-default panel
  color are refused**: the gesture `app_state` bridge expresses
  store-read keys (`state.*`); a live edit that changed
  `model.default_fill` and drew a fall-through tool shape fails the
  record-stop fidelity check (the Rust replay bridge is store-only).
  Unifying the panel-default bridge semantics across ports is a named
  future decision (adjacent to S4's port-side panel-seeding deferral).
- Double-clicks, Esc/Enter mid-gesture, and native-tool (Type /
  Type-on-Path) traffic are not representable in the v1 gesture shape;
  the RECT fill-wiring/Esc transcript items stay manual.
- Action-seam recording captures depth-0 dispatches; bespoke-native
  menu verbs that bypass `dispatch_action` are invisible to it (the
  fidelity check refuses the recording if they mutated the document).
