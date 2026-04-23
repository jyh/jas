"""Public API for the expression evaluator.

Parsed ASTs are cached per source string in a process-wide dict:
re-evaluating the same expression (e.g. a [bind:] clause inside a
216-iteration foreach) skips the tokenize+parse step entirely. The
cache is unbounded — fine for workspace YAML, where the set of
distinct expression strings is finite and bounded by the spec.

Diagnostics: parse failures are logged at WARNING; non-empty
expressions that evaluate to null are logged at DEBUG (legit for
e.g. $selection.fill with nothing selected, but also flags typos
during development when debug logging is enabled).
"""

from __future__ import annotations
import logging
import re

from workspace_interpreter.expr_types import Value, ValueType
from workspace_interpreter.expr_parser import parse, ParseError
from workspace_interpreter.expr_eval import eval_node


_INTERP_RE = re.compile(r"\{\{(.+?)\}\}")

# Cache of parsed ASTs keyed by source string. ``None`` cached for
# unparseable input so we don't reparse known-bad strings.
_AST_CACHE: dict = {}

_log = logging.getLogger(__name__)


def evaluate(expr_str: str, ctx: dict) -> Value:
    """Evaluate an expression string in expression context (no {{}}).

    Returns a typed Value. Never raises — returns Value.null() on error.
    """
    if not expr_str or not isinstance(expr_str, str):
        return Value.null()
    source = expr_str.strip()
    if source in _AST_CACHE:
        ast = _AST_CACHE[source]
    else:
        try:
            ast = parse(source)
        except (ParseError, Exception) as e:
            _log.warning("parse failed: %r: %s", source, e)
            ast = None
        _AST_CACHE[source] = ast
    if ast is None:
        return Value.null()
    try:
        result = eval_node(ast, ctx)
    except Exception as e:
        _log.warning("eval raised: %r: %s", source, e)
        return Value.null()
    if result.type == ValueType.NULL:
        _log.debug("null result: %r", source)
    return result


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
