# closed_doc: the doc=none guard's permanent driver (jas STATUS-flask 1057)

Captured on Windows, real input, at main `5b48ef2e`: a scratch input script
closes the last document tab by its id (`{"panel": "canvas_pane", "widget":
"canvas_tab_close_0", "event": "click"}`, then `{"read": "document"}`)
through `prove_e2e.ps1`.

* `probe.json` is the run's SB_PROBE body, byte for byte (`doc_state` `none`,
  `doc_sha` `NONE`, a null selection and document).
* `cert.txt` is the run's certificate line.

`harness_selftest.ps1` drives `Get-SbProbeDocRefusal` and
`Get-SbProbeSelectionCount` over the probe, and checks that the certificate
carries exactly that refusal. A second arm checks that `prove_e2e.ps1` calls
the guard, inside an `if` that exits, before it counts a selection or reads
back. Re-capture both files together, never one alone.
