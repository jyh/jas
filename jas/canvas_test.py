from absl.testing import absltest

from toolbar import Tool


class ToolbarTest(absltest.TestCase):

    def test_tool_enum_has_two_values(self):
        tools = list(Tool)
        self.assertEqual(len(tools), 2)
        self.assertIn(Tool.SELECTION, tools)
        self.assertIn(Tool.DIRECT_SELECTION, tools)

    def test_tool_selection_value(self):
        self.assertEqual(Tool.SELECTION.value, 1)

    def test_tool_direct_selection_value(self):
        self.assertEqual(Tool.DIRECT_SELECTION.value, 2)


if __name__ == "__main__":
    absltest.main()
