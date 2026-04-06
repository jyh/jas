---
name: Python tests use absltest
description: All Python tests must use absl.testing.absltest, not unittest
type: feedback
---

All Python test files must use `from absl.testing import absltest` and `absltest.TestCase`, not `unittest.TestCase`.

**Why:** Project convention — every existing test file uses absltest consistently.

**How to apply:** When creating new Python test files, import `from absl.testing import absltest`, subclass `absltest.TestCase`, and use `absltest.main()`.
