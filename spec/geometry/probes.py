"""WHERE TO ASK -- the two sampling lanes a region law rules over.

A sampled law is only as good as its sample, and a sample has two jobs that
pull in opposite directions. It must be REPRODUCIBLE, so that a red is the
same red tomorrow and on someone else's machine; and it must be FRESH, so
that CI grows confidence between commits instead of re-asking the same
questions forever. One stream cannot do both, so there are two:

  THE ANCHOR LANE -- `lattice`. A jittered grid over the sampling box,
  jittered by a hash of the family and vector name and nothing else. It
  carries no seed and never changes: the same probes today, next year, and on
  Windows. This is the lane a bisect can trust.

  THE GENERATIVE LANE -- `Stream`. A seeded PRNG, freshly seeded from the
  clock on every run, its seed PRINTED at the head of the run and on every
  failure, and replayable exactly by handing that seed back. This is the lane
  that finds what nobody thought to write down.

EVERY PROBE CARRIES ITS LANE. Both generators yield `(lane, (x, y))`, not
`(x, y)`. The two jobs above are different jobs, so a floor written for one
of them is not a floor for the other, and a caller that pools the two lanes
into one accumulator lets the GENERATIVE lane pay the ANCHOR lane's floor --
which is to say, lets the lane that varies run to run discharge the
obligation of the lane a bisect trusts. Keeping the label on the point is
what makes a per-lane floor possible at all, and it is deliberately not
recoverable from the point's index in a concatenated list; see the note on
`ANCHOR` / `GENERATIVE` below.

Standard library only, and no environment is read here: a seed is an
argument. The runner owns the policy (fresh nanoseconds by default,
`JAS_PROPERTY_SEED` to replay); this module owns the arithmetic.

WHY A JITTERED LATTICE AND NOT A PLAIN ONE. The geometry in this corpus is
axis-aligned small integers, so a plain grid over an integer box lands
probe after probe exactly ON edges and on the extensions of edges -- the one
place a membership question has no answer. Every one of those is then thrown
away by the epsilon rejection, and the ones that survive are systematically
the ones far from any boundary, which is where every implementation agrees.
A jittered lattice keeps the even coverage and destroys the alignment.

WHY SPLITMIX64. Adjacent raw seeds differ in one low bit and an unfinalised
generator started from them produces near-identical early draws, so "seed 1"
and "seed 2" would be nearly the same run. SplitMix64's finalizer avalanches
the seed before it is ever used, and it is also the per-stream derivation:
one run seed, per-(family, vector) streams derived from it, so replaying one
family's seed cannot perturb another's draws.
"""

_MASK64 = (1 << 64) - 1
_GOLDEN = 0x9E3779B97F4A7C15

# THE LANE NAMES, DECLARED HERE BECAUSE THE PRODUCER IS THE ONLY THING THAT
# KNOWS WHICH LANE A PROBE CAME FROM.
#
# A reader that recovers the lane from a probe's POSITION in a concatenated
# list -- `"anchor" if idx < side**2 else "generative"` -- is not reading the
# lane, it is MODELLING the list's layout, and it inherits every assumption
# that layout makes: that the anchor lane comes first, that it emitted exactly
# `side**2` points, that no third lane was inserted between them. Change the
# order or drop a degenerate cell and the label goes quietly wrong, which for
# a per-lane FLOOR means charging one lane's shortfall to the other. That is
# the shape declared in transcripts/CHECKER_RESIDUAL.md, arriving inside the
# instrument that was written to close its previous arrival.
#
# So the lane travels WITH the probe, from the function that drew it.
ANCHOR = "anchor"
GENERATIVE = "generative"

# Ordered, because every message that walks the lanes should walk them the
# same way, and because "the anchor lane first" is a statement about
# REPORTING, which is allowed to be a convention -- unlike attribution, which
# is not.
PROBE_LANES = (ANCHOR, GENERATIVE)


def splitmix64(state):
    """(next_state, output). The reference SplitMix64 step."""
    state = (state + _GOLDEN) & _MASK64
    z = state
    z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & _MASK64
    z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & _MASK64
    return state, (z ^ (z >> 31)) & _MASK64


def finalize(seed):
    """Avalanche a seed so that adjacent seeds are unrelated streams."""
    return splitmix64(seed & _MASK64)[1]


def fnv1a64(text):
    """FNV-1a over UTF-8. Used only to turn a NAME into a stream offset."""
    h = 0xCBF29CE484222325
    for byte in text.encode("utf-8"):
        h = ((h ^ byte) * 0x100000001B3) & _MASK64
    return h


def derive(run_seed, *names):
    """The seed for one named stream under one run seed.

    `finalize(run_seed XOR fnv1a(name))`, per docs/CHECKERS.md section 5.1:
    one run seed, per-family derived streams, so a single
    `JAS_PROPERTY_SEED` replays the family you asked for without moving any
    other family's draws.
    """
    return finalize(run_seed ^ fnv1a64("|".join(str(n) for n in names)))


class Stream:
    """A SplitMix64 draw sequence. Deterministic in its seed, and nothing
    else -- no global state, no clock, no environment."""

    def __init__(self, seed):
        self.seed = seed & _MASK64
        self._state = self.seed

    def next_u64(self):
        self._state, out = splitmix64(self._state)
        return out

    def unit(self):
        """A double in [0, 1). 53 bits, the mantissa's width -- taking fewer
        would quantise the probes onto a grid, which is the alignment the
        jitter exists to destroy."""
        return (self.next_u64() >> 11) * (1.0 / (1 << 53))

    def between(self, lo, hi):
        return lo + (hi - lo) * self.unit()


def sampling_box(box, margin_fraction=0.25, margin_floor=1.0):
    """Grow `box` so that OUTSIDE the region is sampled too, and so that a
    degenerate box still has area.

    A law that probes only the region's own interior cannot tell a correct
    result from one that also covers the plane around it, so the margin buys
    the NEGATIVE half of the membership question: points the spec says are
    outside, which the result must agree are outside. And a zero-height box
    (three collinear vertices, a two-vertex ring) would otherwise admit no
    probe at all that is not on the line the epsilon rejection throws away.
    The margin is a fraction of the larger side with an absolute floor, so
    both cases are covered by one rule.

    WHAT THE MARGIN DOES NOT BUY, stated because the opposite was written
    here and it was FALSE. It does not catch a result that LEAKS. Growing the
    box around whatever the output happens to span means a runaway coordinate
    moves the box instead of being caught by it: the probes follow the
    runaway, land in empty plane far from the subject, agree with the spec
    that the empty plane is empty, and the lane goes green having asked
    nothing. Measured: a 1pt spurious ring 100pt from
    `union_overlapping_squares` left every probe accepted and NONE of them
    inside the region under test. A leak is caught EXACTLY, by
    `region.containment_defect`, and never by widening a sample.
    """
    x0, y0, x1, y1 = box
    margin = max(margin_fraction * max(x1 - x0, y1 - y0), margin_floor)
    return (x0 - margin, y0 - margin, x1 + margin, y1 + margin)


def lattice(box, side, *names):
    """THE ANCHOR LANE: `side` x `side` jittered cell samples over `box`.

    Deterministic forever: the jitter comes from `fnv1a` over the names plus
    the cell index, with no seed anywhere. Yields `(ANCHOR, (x, y))` in
    row-major order so a failure's probe index means the same thing on every
    run -- and so the LANE is read from the producer rather than inferred
    from where the point later ended up in a list.
    """
    x0, y0, x1, y1 = box
    w, h = (x1 - x0) / side, (y1 - y0) / side
    for j in range(side):
        for i in range(side):
            s = Stream(derive(0, *names, "lattice", i, j))
            yield (ANCHOR, (x0 + (i + s.unit()) * w, y0 + (j + s.unit()) * h))


def scatter(box, count, stream):
    """THE GENERATIVE LANE: `count` uniform samples over `box` from
    `stream`, each labelled `(GENERATIVE, (x, y))`. Fresh every run;
    replayable from the run seed alone."""
    x0, y0, x1, y1 = box
    for _ in range(count):
        yield (GENERATIVE, (stream.between(x0, x1), stream.between(y0, y1)))
