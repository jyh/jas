# X thread (12 tweets)

Each tweet ≤ 280 characters. Numbering for the markdown draft; X auto-threads
in practice, so the numbers can be stripped when posting.

---

**1/12**
N-version programming was abandoned in the 1980s because building N
implementations cost too much. With AI, it's back. I built 5 working
ports of a vector illustration app in 7 weeks of evenings. Here's what
made it possible. 🧵

---

**2/12**
5 platforms: Rust (Dioxus), Swift (SwiftUI), OCaml (GTK/Cairo), Python
(PySide6), Python+Flask (browser). 27 tools, 14 panels, 22 dialogs.
Vector paths, text, layers, transforms, PDF export. ~336K lines of code
total. Single developer.

---

**3/12**
For context: Adobe Illustrator has been developed since 1987. Inkscape
since 2003. Affinity Designer since the early 2010s. A vector
illustration app of this scope has always meant decades of team
development. Until recently.

---

**4/12**
My claim: AI is the productivity engine. But raw AI productivity
collapses into debugging unless two specific safeguards are in place.
Both are required. Either alone is not enough.

---

**5/12**
Safeguard 1: a precise executable specification. Not English docs — a
YAML spec that drives all 5 ports. 890 lines specified the Color Panel;
5 working color panels came out of it. Native code per port: 0 (OCaml),
59 (Swift), 123 (Python), 1,309 (Rust).

---

**6/12**
Safeguard 2: parallel implementations as differential testing. Five
ports producing different output reveals where the spec is
underspecified. Each port stress-tests the others. Bugs you can't see
in 1 implementation become obvious with 5.

---

**7/12**
This is the N-version programming idea from 1985, revived. The
original failed on cost — building N independent implementations was
too expensive. With AI handling per-port mechanical work, N=5 becomes
feasible for one developer. The economics inverted.

---

**8/12**
The workflow: prose design doc → analysis prompt (rank inconsistencies)
→ conversation → revised spec → YAML → implement across 5 ports →
manual tests catch divergence → refine spec. Memory persists across
sessions. 57 entries by end of project.

---

**9/12**
By the numbers: 1,807 commits across 48 days (7 weeks, 40 active days).
~120 evening hours total. 4,600 automated tests + 36 manual-test
transcripts. The Color Panel alone has 98 numbered manual test
scenarios.

---

**10/12**
What didn't work: AI confidently hallucinates file paths. Long sessions
drift. Subagents over-flag idiomatic patterns as bugs. Optimistic
completion summaries — always read the diff. Spec + N + tests catch
these.

---

**11/12**
Honest limits: one-developer case study (me). 35 years of vector
illustration background. AI capability snapshot (Claude Opus 4.6/4.7,
April–May 2026). Domain has to be describable declaratively — wouldn't
work for game engines or kernel code.

---

**12/12**
Full technical writeup: [arxiv link]. Blog with stories from the
field: [blog link]. Source code and methodology docs:
github.com/jyh/jas. Always open to talking with people building AI
tooling and developer productivity.

---

## Posting notes

- Tweet 1 includes 🧵 to signal a thread
- Numbering (1/12, 2/12, ...) is included in this draft for readability;
  X auto-threads when replies chain, so numbering is optional in practice
- Replace `[arxiv link]` and `[blog link]` with real URLs before posting
- Character counts are under 280 throughout; verify before posting
