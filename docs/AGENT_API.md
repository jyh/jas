# The agent API: proposals, then the server that carries them

**Status: DESIGN, increment A1 (the proposal protocol and its laws).** This is `docs/ROADMAP.md` §3.1, the open half
of "Claude Code, but for drawing". Under the R0 boundary (`docs/ROADMAP.md`, *The boundary this document sits inside*)
this page describes **the API surface and nothing above it**. What an assistant says, remembers or decides is not part of
this repository. **There is nothing missing from this page on that account.**

It extends `OP_LOG.md` §8 item 4, which has designed the accept path since the journal was laid down. This page turns
that paragraph into laws a test can fail.

---

## 1. Why proposals, not commands

In jas, an operation from an agent is **proposed**. The artist sees it on the canvas and accepts or rejects it. Only an
accepted proposal enters the document's history, and it enters as one named, undoable transaction that
`checkpoint_equivalence` replays like any other (`VISION.md` §6.10, artist primacy: *review happens before commit*).

A server that runs commands directly makes the artist an auditor of edits that have already happened. **The proposal
step is the product's posture, so it is built into the model, below any transport.**

## 2. The protocol

A proposal is `{id, actor, name, ops}`:
- `ops` are primitive ops from the existing `op_apply` vocabulary;
- `name` is an `actions.yaml` verb;
- `actor` is the journal's existing `Transaction.actor` value (`artist` · `ai` · `peer:<id>`, `OP_LOG.md` §5).

| call | effect on the document | effect on the journal |
|---|---|---|
| `propose(p)` | the canvas shows `p` applied (a **preview**). The pre-proposal document is held aside | **none.** A pending proposal is in no transaction |
| `accept(id)` | the preview is replaced by the **real** edit: the held document is restored, then `p.ops` run through `begin_txn`/`commit_txn` | **one** transaction, named `p.name`, with `actor = p.actor` |
| `reject(id)` | the held document is restored | none |
| any artist edit while `p` is pending | `p` is **withdrawn first** (the held document is restored), then the artist's edit applies | the artist's transaction only |
| `accept` of a withdrawn, rejected, accepted or unknown id | nothing | nothing. It is **refused by name** |

**At most one proposal is pending at a time.** A second `propose` while one is pending is refused by name. Queuing and
merging proposals are deliberately out of scope for A1. A queue would need a rule for proposals that touch the same
element, and that rule should come from use, not from this page.

### Why an artist edit withdraws, and never rebases

Rebasing a proposal over the artist's edit would apply ops the artist never saw, to a document the proposer never saw.
**Withdrawal costs one re-proposal; a silent rebase costs the artist's trust.** A transport (§4) tells the proposer its
proposal was withdrawn, so it can propose again against the document as it now is.

## 3. The laws (`test_fixtures/operations/proposal_laws.json`)

These are **relational**: each case names the steps it must equal, never a typed golden.
- `steps` and `equals_steps` must produce byte-identical canonical documents.
- Their journals must be identical, except for the `actor` values listed in `expect_actors`. A case with a pending
  proposal names a separate `journal_equals_steps` (empty), because its canvas equals the edit while its journal does not.
- The `checkpoint_equivalence` replay of the journal must equal the live document (`OP_LOG.md` §6). In the
  pending-proposal case it equals the **held** document, because the preview is not history.

| law | it fails when |
|---|---|
| `accept_equals_hand` | an accepted proposal differs from the same edit made by hand, or is journaled as `artist` |
| `reject_is_identity` | a rejected proposal leaves any trace in the document or the journal |
| `pending_is_previewed_not_journaled` | the preview is not visible, or it was journaled |
| `artist_edit_withdraws` | a proposal survives an artist edit, or is rebased over it |
| `accepted_is_one_undo_step` | an accepted proposal of several ops takes more than one undo to remove |
| `accept_is_once` | a proposal can be accepted twice |

Both active ports run the same file (POLICY.md §1).

## 4. What comes after A1 (the roadmap's nodes; none is built by this page)

- **A3, the transport: an MCP server, two-way from the start.**
  - Its tool schemas are generated from `actions.yaml`, so the callable surface is the same data the apps are built from.
  - Its edit tools return proposal ids and never commit.
  - It needs a reader beside its request loop, so it can **notify** the client when the document changes, including
    when a proposal is withdrawn by an artist edit, and so it can ask the artist to accept.
  - Perception is the canonical document JSON plus an offscreen raster.
- **A4, accept in the app:** the preview drawn as an overlay, with Accept and Reject. This is ROADMAP §3.1's first
  observable.
- **A7, the intent ledger's schema:** open by R0. What a ledger entry records is not part of this repository.

## 5. What this page does not decide

- **Where an accept is answered** (in the app, or by the client on the artist's behalf). A3 and A4 decide that. The model
  only requires that `accept` is a separate call from `propose`.
- **Proposals spanning documents, or concurrent proposers.** `targets: [common.id]` (`OP_LOG.md` §8 item 2) is what a
  later conflict rule would read.
