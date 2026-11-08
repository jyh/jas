"""G11 step 4: the marquee is scoped to the isolation root.

The arms are the design's (seat brief 2026-11-08 "g11-marquee-scope", section 4)
on a hand-built twin of `test_fixtures/layers/hit_test_root.json` without its
transformed branch: the reference's flat walk takes no parent frame, so the frame
arms (4/5) live in the ports, which carry the S6 transform law.

Tree: L[0] holds G[0,0] = {R1 at 0-10, R2 at 20-30} and R3[0,1] at 40-50, all
10x10 and filled, so a band strictly inside one rect hits it.
"""
import dataclasses

from absl.testing import absltest

from document.controller import Controller
from document.document import Document, ElementSelection
from document.model import Model
from document.op_apply import op_apply
from geometry.element import Fill, Group, Layer, Rect, RgbColor, Visibility


def _rect(x):
    return Rect(x=x, y=0, width=10, height=10, fill=Fill(color=RgbColor(1, 0, 0)))


def _doc(*, r1_locked=False, g_hidden=False):
    r1 = dataclasses.replace(_rect(0), locked=r1_locked)
    g = Group(children=(r1, _rect(20)))
    if g_hidden:
        g = dataclasses.replace(g, visibility=Visibility.INVISIBLE)
    return Document(layers=(Layer(children=(g, _rect(40)), name="L"),))


def _ctrl(doc=None):
    return Controller(model=Model(document=doc or _doc()))


def _paths(ctrl):
    return sorted(es.path for es in ctrl.document.selection)


class SelectRectRootTest(absltest.TestCase):

    def test_1_inside_the_root_a_member_answers_for_itself(self):
        # A post-filter of the layer walk answers [] here: the layer walk
        # returns the group [0,0], which is not under the root.
        c = _ctrl()
        c.select_rect(2, 2, 1, 1, root=(0, 0))
        self.assertEqual(_paths(c), [(0, 0, 0)])

    def test_2_a_band_outside_the_root_selects_nothing(self):
        # The defect: the layer walk answers R3 [0,1].
        c = _ctrl()
        c.select_rect(45, 5, 0, 0, root=(0, 0))
        self.assertEqual(_paths(c), [])

    def test_3_a_wide_band_selects_every_member_it_touches(self):
        c = _ctrl()
        c.select_rect(0, 0, 30, 10, root=(0, 0))
        self.assertEqual(_paths(c), [(0, 0, 0), (0, 0, 1)])

    def test_6_no_root_is_the_layer_walk(self):
        for root in (None, ()):
            c = _ctrl()
            c.select_rect(2, 2, 1, 1, root=root)
            self.assertEqual(_paths(c), [(0, 0)], f"root={root!r}")

    def test_7_a_root_that_does_not_name_a_container_selects_nothing(self):
        # Never a fallback to the layer walk, which would answer [0,0] or [0,1].
        for root in ((9,), (0, 1), (0, 0, 7)):
            c = _ctrl()
            c.select_rect(2, 2, 1, 1, root=root)
            self.assertEqual(_paths(c), [], f"root={root!r}")
            c.select_rect(45, 5, 0, 0, root=root)
            self.assertEqual(_paths(c), [], f"root={root!r}")

    def test_8_a_locked_member_inside_the_root_is_skipped(self):
        c = _ctrl(_doc(r1_locked=True))
        c.select_rect(2, 2, 1, 1, root=(0, 0))
        self.assertEqual(_paths(c), [])
        c.select_rect(22, 2, 1, 1, root=(0, 0))
        self.assertEqual(_paths(c), [(0, 0, 1)], "the control: R2 is free")

    def test_9_a_hidden_root_selects_nothing(self):
        c = _ctrl(_doc(g_hidden=True))
        c.select_rect(2, 2, 1, 1, root=(0, 0))
        self.assertEqual(_paths(c), [])

    def test_10_extend_toggles_within_the_root(self):
        c = _ctrl()
        c.select_rect(22, 2, 1, 1, root=(0, 0))
        c.select_rect(2, 2, 1, 1, root=(0, 0), extend=True)
        self.assertEqual(_paths(c), [(0, 0, 0), (0, 0, 1)])

    def test_op_apply_reads_root(self):
        m = Model(document=_doc())
        op_apply(m, {"op": "select_rect", "x": 45, "y": 5, "width": 0,
                     "height": 0, "extend": False, "root": [0, 0]})
        self.assertEqual(sorted(es.path for es in m.document.selection), [])
        op_apply(m, {"op": "select_rect", "x": 2, "y": 2, "width": 1,
                     "height": 1, "extend": False, "root": [0, 0]})
        self.assertEqual(sorted(es.path for es in m.document.selection), [(0, 0, 0)])

    def test_a_negative_root_index_selects_nothing(self):
        # Python would read (-1,) as the LAST layer.
        c = _ctrl()
        c.select_rect(2, 2, 1, 1, root=(-1, 0))
        self.assertEqual(_paths(c), [])

    def test_op_apply_skips_a_malformed_root(self):
        # Never an unscoped marquee: the prior selection stands.
        m = Model(document=_doc())
        Controller(model=m).select_rect(22, 2, 1, 1, root=(0, 0))
        for bad in ("0,0", [0, "a"], [True], None):
            op_apply(m, {"op": "select_rect", "x": 45, "y": 5, "width": 0,
                         "height": 0, "extend": False, "root": bad})
            self.assertEqual(sorted(es.path for es in m.document.selection),
                             [(0, 0, 1)], f"root={bad!r}")

    def test_op_apply_without_root_is_unchanged(self):
        m = Model(document=_doc())
        op_apply(m, {"op": "select_rect", "x": 45, "y": 5, "width": 0,
                     "height": 0, "extend": False})
        self.assertEqual(sorted(es.path for es in m.document.selection), [(0, 1)])


if __name__ == "__main__":
    absltest.main()
