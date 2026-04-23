#!/usr/bin/env python3
"""Tests for scripts/genericity_check.py.

Run directly:
    python scripts/genericity_check_test.py

Or via unittest discover:
    python -m unittest scripts.genericity_check_test
"""

import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import genericity_check as g  # noqa: E402


class MeasureFilesKindTest(unittest.TestCase):
    def test_counts_matching_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            tools = repo / "app" / "tools"
            tools.mkdir(parents=True)
            (tools / "a_tool.rs").write_text("")
            (tools / "b_tool.rs").write_text("")
            (tools / "notatool.rs").write_text("")
            patterns = {
                "app": {
                    "tool_files": {
                        "kind": "files",
                        "glob": "app/tools/*_tool.rs",
                    }
                }
            }
            result = g.measure(repo=repo, patterns=patterns)
            self.assertEqual(result, {"app": {"tool_files": 2}})

    def test_exclude_pattern_drops_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            tools = repo / "app" / "tools"
            tools.mkdir(parents=True)
            (tools / "a_tool.rs").write_text("")
            (tools / "b_tool.rs").write_text("")
            (tools / "excluded_tool.rs").write_text("")
            patterns = {
                "app": {
                    "tool_files": {
                        "kind": "files",
                        "glob": "app/tools/*_tool.rs",
                        "exclude_pattern": r"/excluded_tool\.rs$",
                    }
                }
            }
            result = g.measure(repo=repo, patterns=patterns)
            self.assertEqual(result, {"app": {"tool_files": 2}})

    def test_no_files_returns_zero(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            patterns = {
                "app": {
                    "tool_files": {
                        "kind": "files",
                        "glob": "app/tools/*_tool.rs",
                    }
                }
            }
            result = g.measure(repo=repo, patterns=patterns)
            self.assertEqual(result, {"app": {"tool_files": 0}})


class MeasureRegexCountKindTest(unittest.TestCase):
    def test_sums_matches_across_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            panels = repo / "app" / "panels"
            panels.mkdir(parents=True)
            (panels / "a_panel.rs").write_text(
                "PanelMenuItem::Action\n"
                "PanelMenuItem::Toggle\n"
            )
            (panels / "b_panel.rs").write_text(
                "PanelMenuItem::Radio\n"
            )
            patterns = {
                "app": {
                    "menu_items": {
                        "kind": "regex_count",
                        "glob": "app/panels/*_panel.rs",
                        "regex": r"PanelMenuItem::(Action|Toggle|Radio)\b",
                    }
                }
            }
            result = g.measure(repo=repo, patterns=patterns)
            self.assertEqual(result, {"app": {"menu_items": 3}})

    def test_multiline_anchor_matches(self):
        """^\\s*pub const LABEL : ... patterns rely on MULTILINE mode."""
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            panels = repo / "app" / "panels"
            panels.mkdir(parents=True)
            (panels / "a_panel.rs").write_text(
                "// preamble\n"
                "    pub const LABEL: &str = \"A\";\n"
                "    pub const LABEL: &str = \"B\";\n"
            )
            patterns = {
                "app": {
                    "labels": {
                        "kind": "regex_count",
                        "glob": "app/panels/*_panel.rs",
                        "regex": r"^\s*pub const LABEL\s*:",
                    }
                }
            }
            result = g.measure(repo=repo, patterns=patterns)
            self.assertEqual(result, {"app": {"labels": 2}})

    def test_unreadable_file_is_skipped(self):
        """Binary / non-utf8 files should not crash measure()."""
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            panels = repo / "app" / "panels"
            panels.mkdir(parents=True)
            (panels / "binary_panel.rs").write_bytes(b"\xff\xfe\x00\x01\xff")
            (panels / "ok_panel.rs").write_text("PanelMenuItem::Action\n")
            patterns = {
                "app": {
                    "menu_items": {
                        "kind": "regex_count",
                        "glob": "app/panels/*_panel.rs",
                        "regex": r"PanelMenuItem::Action",
                    }
                }
            }
            result = g.measure(repo=repo, patterns=patterns)
            self.assertEqual(result, {"app": {"menu_items": 1}})


class DiffTest(unittest.TestCase):
    def test_regression_reported(self):
        regressions, improvements = g.diff(
            {"app": {"tool_files": 5}},
            {"app": {"tool_files": 3}},
        )
        self.assertEqual(len(regressions), 1)
        self.assertIn("3 → 5", regressions[0])
        self.assertIn("+2", regressions[0])
        self.assertEqual(improvements, [])

    def test_improvement_reported(self):
        regressions, improvements = g.diff(
            {"app": {"tool_files": 2}},
            {"app": {"tool_files": 5}},
        )
        self.assertEqual(regressions, [])
        self.assertEqual(len(improvements), 1)
        self.assertIn("5 → 2", improvements[0])
        self.assertIn("-3", improvements[0])

    def test_no_change_empty_results(self):
        regressions, improvements = g.diff(
            {"app": {"tool_files": 3}},
            {"app": {"tool_files": 3}},
        )
        self.assertEqual(regressions, [])
        self.assertEqual(improvements, [])

    def test_new_category_counts_as_regression_from_zero(self):
        regressions, improvements = g.diff(
            {"app": {"new_cat": 1, "old_cat": 2}},
            {"app": {"old_cat": 2}},
        )
        self.assertEqual(len(regressions), 1)
        self.assertIn("new_cat", regressions[0])
        self.assertIn("0 → 1", regressions[0])
        self.assertEqual(improvements, [])

    def test_removed_category_counts_as_improvement_to_zero(self):
        regressions, improvements = g.diff(
            {"app": {"kept_cat": 2}},
            {"app": {"kept_cat": 2, "gone_cat": 5}},
        )
        self.assertEqual(regressions, [])
        self.assertEqual(len(improvements), 1)
        self.assertIn("gone_cat", improvements[0])
        self.assertIn("5 → 0", improvements[0])

    def test_new_app_all_categories_are_regressions(self):
        regressions, improvements = g.diff(
            {"new_app": {"cat_a": 1, "cat_b": 2}},
            {},
        )
        self.assertEqual(len(regressions), 2)
        self.assertEqual(improvements, [])

    def test_mixed_regression_and_improvement(self):
        regressions, improvements = g.diff(
            {"app": {"a": 5, "b": 1}},
            {"app": {"a": 3, "b": 4}},
        )
        self.assertEqual(len(regressions), 1)
        self.assertEqual(len(improvements), 1)


class LivePatternsSelfTest(unittest.TestCase):
    """Smoke-test the real PATTERNS dict against the real repo. Guards
    against regex / glob typos in PATTERNS itself — a bad pattern would
    either crash here or drift the live baseline silently."""

    def test_all_apps_present_in_report(self):
        result = g.measure()
        self.assertEqual(set(result.keys()), set(g.PATTERNS.keys()))

    def test_all_counts_are_non_negative_ints(self):
        result = g.measure()
        for app, cats in result.items():
            for cat, value in cats.items():
                self.assertIsInstance(
                    value, int, f"{app}/{cat} expected int, got {type(value)}")
                self.assertGreaterEqual(
                    value, 0, f"{app}/{cat} expected >= 0, got {value}")

    def test_every_pattern_has_a_count(self):
        """measure() must emit a count for every declared (app, category)."""
        result = g.measure()
        for app, cats in g.PATTERNS.items():
            self.assertIn(app, result)
            for cat in cats:
                self.assertIn(
                    cat, result[app], f"{app}/{cat} missing from report")


if __name__ == "__main__":
    unittest.main()
