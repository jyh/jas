# S-B RESIZE — MEASURED ON HARDWARE, 2026-08-28

**flask (kenai), ~15:5x PDT.** The number the 08/28 council recorded as
**UNMEASURABLE-ON-KENAI**. It is measurable, **with no machine change and SAC still at
ENFORCE.**

⛔ **CORRECTED 17:5x — I first wrote "Smart App Control stopped blocking this app." That is not
the mechanism.** Measured across five builds since: **SAC's verdict is per-ARTIFACT-CONTENT.** A
rebuild that reproduces the same bytes keeps the same verdict — which is why deleting the DLL
and doing a full clean rebuild of unchanged source **failed to clear it, twice.** A rebuild
whose content *differs* gets a fresh verdict and may pass; one source-changing rebuild cleared
it on the first attempt. ⇒ **An occasional build is dead on arrival and must be rebuilt from
changed source. That is weaker than "SAC stopped blocking" and much stronger than
"UNMEASURABLE" — neither of my earlier characterisations was right.** Detail:
the private record's 08-28 RCW/SAC finding (role reference; the path is not written in a public tree, per the 2026-08-25 firewall-at-paths ruling).

**Method is the 08/26 brief's, and it is binding here:** cross-session drift on this box is
**+24 %**, larger than the effect, so **CONTROL PAIRS OR NOTHING** — all four arms back to
back in one warm session, **twice**.

---

## 1 · WHAT THE RESIZE GESTURE COSTS — split three ways on purpose

| arm | rcw-release | ResizeBuffers | target-recreate |
|---|---:|---:|---:|
| sweep 1 · offscreen 1184x726 | 1.21 | 2.13 | 0.11 |
| sweep 1 · direct 1184x726 | 1.28 | 1.58 | 0.11 |
| sweep 1 · offscreen 1484x926 | **22.97** ⚠️ | 1.58 | 0.13 |
| sweep 1 · direct 1484x926 | 1.19 | 1.38 | 0.11 |
| sweep 2 · offscreen 1184x726 | 1.08 | 1.59 | 0.11 |
| sweep 2 · direct 1184x726 | 1.08 | 1.40 | 0.10 |
| sweep 2 · offscreen 1484x926 | 1.13 | 1.44 | 0.11 |
| sweep 2 · direct 1484x926 | 1.14 | 1.39 | 0.11 |

**A resize costs ~2.6–3.5 ms**, dominated by `ResizeBuffers` (~1.4–2.1 ms) and the RCW
release (~1.1–1.3 ms). **All milliseconds; one resize gesture, not per frame.**

### ⭐ THE ROUTES DO NOT SEPARATE ON RESIZE COST

`target-recreate` is **0.10–0.13 ms** — and **both routes pay it**, because `Resize` calls
`CreateOffscreenTarget()` unconditionally. ⇒ **The offscreen route's supposed extra resize
work is 0.11 ms and is not actually exclusive to it.**

⛔ **AND THAT IS A DEFECT I AM REPORTING, NOT FIXING MID-MEASUREMENT.** The **direct** route
allocates an offscreen target it never touches — on every resize, and in `Attach` before that.
It is small and it is waste, and it predates this branch. **Fixing it while the sweep was
running would have changed the instrument between arms**, which is the one thing the control-
pair method exists to prevent. Booked for a separate change.

### ⚠️ The 22.97 ms outlier, chased rather than reported or buried

One arm read **22.97 ms** on the RCW release against ~1.2 ms everywhere else. **"2 of 2 is not
a tail measurement"** is this spike's own banked lesson, so I re-ran that exact arm **six more
times**:

```
1.19  1.42  1.10  1.24  1.20  1.12   ms
```

⇒ ~~One outlier in ~15 observations, not reproduced in six targeted repeats.~~

⛔ **CORRECTED 08/29 05:3x — IT RECURRED, AND MY "NOT REPRODUCED" WAS THE WEAKER READING OF MY
OWN DATA.** A later run threw **18.20 ms** on the same field. That is **two outliers
(22.97, 18.20) in roughly twenty-odd observations — on the order of one in ten**, not one in
fifteen-and-never-again.

**What I got wrong was not the measurement but the inference.** Six clean repeats after one
outlier is *consistent with* a ~10 % tail — the probability of missing it six times running is
about a half. **I read "did not reproduce in six" as evidence of absence when it was barely
evidence at all**, which is the same error as quoting a max from 2 of 2, pointed the other way.

**What it changes and what it does not:**
* **The route decision: nothing.** The tail is in *my repair*, not in either route, and both
  routes pay the same collect.
* **How the repair must be described: everything.** Not *"~1.2 ms"* but ***"~1.2 ms typical
  with an 18–23 ms hitch at roughly one resize in ten."*** That is a user-visible stutter on a
  window drag.
* ⇒ And it makes §3's negative result **cost more than it looked like it did.** The collect is
  still the only repair available through this projection — but it is now a repair with a
  known, recurring tail, and that should be read as **a standing charge against the
  `out object` projection**, not as a solved problem.

## 2 · STEADY STATE — the copy is fixed-cost, confirmed at a THIRD scale

| arm | 1184x726 (0.86 Mpx) | 1484x926 (1.37 Mpx) |
|---|---:|---:|
| offscreen `paint+copy` | 1.13 / 1.10 | 1.25 / 1.25 |
| direct `paint` | 0.99 / 0.95 | 1.10 / 1.11 |
| **delta (the copy)** | **0.145** | **0.145** |

⇒ ***1.6× THE PIXELS. IDENTICAL COPY COST.*** The 08/24 and 08/26 findings reproduce at a
third pair of sizes, and the four deltas agree to **0.01 ms**. The area model is dead for the
third time.

## 3 · THE DEFECT THAT ONLY RUNNING COULD FIND

The first real run failed on **both** routes, every time:

```
RUSTFAIL resize: ResizeBuffers threw 0x887A0001 (DXGI_ERROR_INVALID_CALL)
```

`RenderFrame` calls `GetBuffer<IDXGISurface>`, which returns a managed **RCW**. The raw
interface pointer is released each frame; the RCW is released only when the GC finalizes it,
which had not happened by resize time. **DXGI refuses `ResizeBuffers` while any back-buffer
reference is outstanding.**

📌 `SwapChainHost`'s own comment predicted the cause and **got the symptom wrong**: it says
this "manifests as a resize that silently stops working" — written when no resize existed. It
does not fail silently; **it throws.** Only running it could tell those apart. **Two nights of
careful reading did not find this; one run did.**

**Fix at resize time, deliberately not in the frame path** — the README records
`ReleaseComObject` there corrupting the heap over sixty frames (`0xC0000374`) and
`FinalReleaseComObject` crashing by over-release. A collect per gesture is ~1.2 ms and never
touches the hot path.

⚠️ ~~**A better fix exists:** hold no RCW at all — take the raw pointer from `GetBuffer` and
release it.~~ ⛔ **TRIED 17:4x AND IT IS NOT AVAILABLE. This sentence did not survive contact.**

CsWin32 generates exactly one overload —
`GetBuffer(uint Buffer, Guid* riid, out object ppSurface)` — **`out object`. There is no
raw-pointer form to call**; the projection always materialises an RCW and you cannot ask it
not to. The remaining routes are `Marshal.ReleaseComObject` in the frame path (**the
documented heap-corruption path**, `0xC0000374` over sixty frames) or hand-rolled vtable
P/Invoke (**the wrong-interface-pointer class that caused both of this spike's original
defects**). Neither is worth ~1.2 ms of a once-per-gesture cost.

⇒ **The collect at resize time is not a placeholder; on this projection it is the answer.**
Attempt and revert recorded in
the private record's 08-28 RCW/SAC finding (role reference; the path is not written in a public tree, per the 2026-08-25 firewall-at-paths ruling); **the numbers
above are unaffected and were re-verified after the revert.**

## 4 · WHAT THIS DOES NOT SAY

* **Not a real device-lost.** Inducing a true TDR needs an adapter change this seat cannot
  make. What is measured is the **half-done state's behaviour** (a cross-device copy **removes
  the device**, `0x887A0020`), not a recovery.
* **Not an occlusion measurement.** The occlusion guard stayed **silent on every run above**,
  which is what licenses these numbers: the frames were visible. That is the guard working,
  not an absence of testing.
* **Not a 4K number.** These are 0.86 and 1.37 Mpx. `SB_SIZE` lives on
  `windows-sb-4k-remeasure` and is not on this branch.
* **Not a fidelity statement.** The DIP defect (#16) is untouched; the label now states DIP
  buffer vs physical pixels so a run cannot claim a surface it never rendered.

## 5 · WHAT IT DOES SAY, FOR THE ROUTE DECISION

The ruling chose **OFFSCREEN on risk**, the numbers having failed to separate the routes. **The
resize evidence does not change that and does not rescue the other side either:**

* the resize gesture is **~3 ms on both routes**, and the offscreen route's extra work is
  **0.11 ms**;
* the per-frame copy is **0.145 ms and flat in area**, now at three scales;
* the coupling the decision rested on is **real but still not adversarially exercised** —
  resize is now exercised; device-lost is characterized, not survived.

⇒ **The route decision stands, and it is now auditable on resize rather than resting on
mechanism alone.** That was the whole reason to build this.
