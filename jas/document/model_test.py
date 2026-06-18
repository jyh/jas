from absl.testing import absltest

from document.document import Document
from geometry.element import Layer, Rect
from document.model import Model


class ModelTest(absltest.TestCase):

    def test_default_document(self):
        model = Model()
        self.assertTrue(model.filename.startswith("Untitled-"))
        self.assertEqual(len(model.document.layers), 1)

    def test_initial_document(self):
        model = Model(filename="Test")
        self.assertEqual(model.filename, "Test")

    def test_set_document_notifies(self):
        model = Model()
        received = []
        model.on_document_changed(lambda doc: received.append(len(doc.layers)))
        model.document = Document(layers=())
        self.assertEqual(received, [0])

    def test_multiple_listeners(self):
        model = Model()
        a, b = [], []
        model.on_document_changed(lambda doc: a.append(len(doc.layers)))
        model.on_document_changed(lambda doc: b.append(len(doc.layers)))
        model.document = Document(layers=())
        self.assertEqual(a, [0])
        self.assertEqual(b, [0])

    def test_listener_called_on_each_change(self):
        model = Model()
        count = []
        model.on_document_changed(lambda doc: count.append(len(doc.layers)))
        layer = Layer(children=(), name="L1")
        model.document = Document(layers=(layer,))
        model.document = Document(layers=(layer, layer))
        self.assertEqual(count, [1, 2])

    def test_immutability(self):
        model = Model()
        before = model.document
        model.document = Document(layers=())
        after = model.document
        self.assertEqual(len(before.layers), 1)
        self.assertEqual(len(after.layers), 0)

    def test_filename(self):
        model = Model()
        self.assertTrue(model.filename.startswith("Untitled-"))
        model.filename = "drawing.jas"
        self.assertEqual(model.filename, "drawing.jas")

    def test_undo_redo(self):
        model = Model()
        self.assertFalse(model.can_undo)
        model.snapshot()
        model.document = Document(layers=())
        self.assertTrue(model.can_undo)
        self.assertFalse(model.can_redo)
        model.undo()
        self.assertEqual(len(model.document.layers), 1)
        self.assertTrue(model.can_redo)
        model.redo()
        self.assertEqual(len(model.document.layers), 0)

    def test_undo_clears_redo_on_new_edit(self):
        model = Model()
        layer = Layer(children=(), name="L1")
        model.snapshot()
        model.document = Document(layers=(layer,))
        model.snapshot()
        model.document = Document(layers=(layer, layer))
        model.undo()
        self.assertEqual(len(model.document.layers), 1)
        self.assertTrue(model.can_redo)
        model.snapshot()
        model.document = Document(layers=())
        self.assertFalse(model.can_redo)

    def test_undo_empty_stack(self):
        model = Model()
        model.undo()
        self.assertEqual(len(model.document.layers), 1)

    def test_redo_empty_stack(self):
        model = Model()
        model.redo()
        self.assertEqual(len(model.document.layers), 1)

    # OP_LOG.md Increment 2: is_modified is the journal-head cursor
    # (journal_head != saved_journal_head), so undo back to the saved
    # point reads as not-modified.

    def test_is_modified_default_false(self):
        self.assertFalse(Model().is_modified)

    def test_is_modified_after_committed_edit(self):
        model = Model()
        model.snapshot()
        model.document = Document(layers=())
        self.assertTrue(model.is_modified)

    def test_is_modified_false_after_undo_back_to_saved(self):
        model = Model()
        model.mark_saved()  # saved at journal_head 0
        model.snapshot()
        model.document = Document(layers=())
        self.assertTrue(model.is_modified)
        model.undo()
        self.assertFalse(
            model.is_modified, "undo back to the saved point is not modified")
        model.redo()
        self.assertTrue(
            model.is_modified, "redo past the saved point is modified again")

    def test_is_modified_false_after_mark_saved(self):
        model = Model()
        model.snapshot()
        model.document = Document(layers=())
        self.assertTrue(model.is_modified)
        model.mark_saved()
        self.assertFalse(model.is_modified)

    # OP_LOG.md Increment 2 (full journal): begin_txn/commit_txn build the
    # typed Transaction journal with deterministic txn-N ids + the no-op rule.

    def test_commit_journals_one_transaction_per_net_change(self):
        model = Model()
        model.with_txn(lambda: setattr(model, "document", Document(layers=())))
        self.assertEqual(len(model.journal), 1)
        self.assertEqual(model.journal_head, 1)
        self.assertEqual(model.journal[0].txn_id, "txn-0")

    def test_no_op_transaction_is_not_journaled(self):
        model = Model()
        model.begin_txn()
        model.commit_txn()  # no edit
        self.assertEqual(len(model.journal), 0)
        self.assertEqual(model.journal_head, 0)
        self.assertFalse(model.can_undo)

    def test_journal_cursor_and_redo_tail_drop(self):
        model = Model()
        l = Layer(children=(), name="L1")
        model.with_txn(lambda: setattr(model, "document", Document(layers=(l,))))   # txn-0
        model.with_txn(lambda: setattr(model, "document", Document(layers=(l, l))))  # txn-1
        self.assertEqual([t.txn_id for t in model.journal], ["txn-0", "txn-1"])
        self.assertEqual(model.journal[1].parent, "txn-0")
        model.undo()
        self.assertEqual(model.journal_head, 1)
        # New commit after undo drops the redo tail and appends.
        model.with_txn(lambda: setattr(model, "document", Document(layers=())))
        self.assertEqual(len(model.journal), 2)
        self.assertEqual(model.journal[1].txn_id, "txn-2")
        self.assertFalse(model.can_redo)


class EditingTargetTest(absltest.TestCase):
    """Test the mask-editor UI state on Model (OPACITY.md §Preview
    interactions)."""

    def test_defaults_to_content(self):
        # Default editing target is the document's normal content —
        # mask-editing mode is entered explicitly via the
        # MASK_PREVIEW click.
        from document.model import EditingTarget
        model = Model()
        self.assertEqual(model.editing_target, EditingTarget.content())
        self.assertFalse(model.editing_target.is_mask)

    def test_round_trips_through_mask_mode(self):
        from document.model import EditingTarget
        model = Model()
        model.editing_target = EditingTarget.mask([0, 2, 1])
        self.assertTrue(model.editing_target.is_mask)
        self.assertEqual(model.editing_target.mask_path, (0, 2, 1))
        model.editing_target = EditingTarget.content()
        self.assertFalse(model.editing_target.is_mask)
        self.assertIsNone(model.editing_target.mask_path)

    def test_defaults_to_no_mask_isolation(self):
        # Mask-isolation is entered explicitly via Alt-click on
        # MASK_PREVIEW. OPACITY.md §Preview interactions.
        model = Model()
        self.assertIsNone(model.mask_isolation_path)

    def test_mask_isolation_path_round_trips(self):
        model = Model()
        model.mask_isolation_path = (0, 3)
        self.assertEqual(model.mask_isolation_path, (0, 3))
        model.mask_isolation_path = None
        self.assertIsNone(model.mask_isolation_path)


if __name__ == "__main__":
    absltest.main()
