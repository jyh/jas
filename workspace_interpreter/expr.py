"""Public API for the expression evaluator."""

from __future__ import annotations
import re

from workspace_interpreter.expr_types import Value
from workspace_interpreter.expr_parser import parse, ParseError
from workspace_interpreter.expr_eval import eval_node


_INTERP_RE = re.compile(r"\{\{(.+?)\}\}")


def evaluate(expr_str: str, ctx: dict) -> Value:
    """Evaluate an expression string in expression context (no {{}}).

    Returns a typed Value. Never raises — returns Value.null() on error.
    """
    if not expr_str or not isinstance(expr_str, str):
        return Value.null()
    try:
        ast = parse(expr_str.strip())
        return eval_node(ast, ctx)
    except (ParseError, Exception):
        return Value.null()


def evaluate_text(text: str, ctx: dict) -> str:
    """Evaluate a text string with embedded {{expr}} regions.

    Returns the string with each {{expr}} replaced by its evaluated
    value coerced to a string. Text outside {{}} is literal.
    """
    if not text or not isinstance(text, str) or "{{" not in text:
        return text if isinstance(text, str) else ""

    def _replace(match):
        expr_str = match.group(1).strip()
        val = evaluate(expr_str, ctx)
        return val.to_string()

    return _INTERP_RE.sub(_replace, text)
