# Contributing to Jas

Thank you for your interest in Jas! This project is under active
development as a research artifact (see the paper linked in the README),
and its development process is unusual — features land across five
parallel implementations with cross-language differential tests. Please
read this before opening a pull request.

## Before you contribute

**Please open an issue first** for anything beyond a trivial fix. The
five-port parity discipline means most changes must land in multiple
implementations with matching tests, and the maintainer coordinates that
process. Unsolicited PRs may sit unmerged for a while — an issue
conversation first saves everyone time.

## Contribution terms

By submitting a contribution (pull request, patch, or otherwise), you
certify and agree to the following:

1. **Developer Certificate of Origin.** You certify the
   [Developer Certificate of Origin 1.1](https://developercertificate.org/):
   you have the right to submit the contribution under this project's
   license. Sign off each commit (`git commit -s`).

2. **Contributor license grant.** You grant the project maintainer
   (Jason Hickey) a perpetual, worldwide, non-exclusive, irrevocable,
   royalty-free license to use, reproduce, modify, distribute, and
   sublicense your contribution, **including the right to license it
   under terms other than the project's current license**. You retain
   copyright in your contribution.

Contributions that do not include DCO sign-off, or where these terms are
disclaimed, cannot be merged. For substantial contributions the
maintainer may additionally request a signed contributor license
agreement.

## Code expectations

- Match the port's existing style and module structure (see `ARCH.md`).
- Behavior changes must come with tests, and cross-port behavior changes
  must keep the differential harness green across all four native ports.
- The shared YAML spec (`SCHEMA.md`, `workspace/`) is the source of
  truth for behavior; spec changes are coordinated through issues.

Thank you — and enjoy the code. The transcripts in `transcripts/` tell
the story of how it was built.
