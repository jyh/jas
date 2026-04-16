"""Tree-walking evaluator for the expression language AST."""

from __future__ import annotations

from workspace_interpreter.expr_types import Value, ValueType
from workspace_interpreter.expr_parser import (
    Literal, Path, FuncCall, IndexAccess, DotAccess,
    BinaryOp, UnaryOp, Ternary, LogicalOp,
    Lambda, Let, Assign, Sequence,
)
from workspace_interpreter import color_util


def eval_node(node, ctx: dict) -> Value:
    """Evaluate an AST node against a context dict of namespaces.

    ctx is a dict like {"state": {...}, "panel": {...}, "theme": {...}, ...}.
    """
    if node is None:
        return Value.null()

    if isinstance(node, Literal):
        return _eval_literal(node, ctx)

    if isinstance(node, Path):
        return _eval_path(node.segments, ctx)

    if isinstance(node, FuncCall):
        return _eval_func(node, ctx)

    if isinstance(node, DotAccess):
        return _eval_dot_access(node, ctx)

    if isinstance(node, IndexAccess):
        return _eval_index_access(node, ctx)

    if isinstance(node, BinaryOp):
        return _eval_binary(node, ctx)

    if isinstance(node, UnaryOp):
        return _eval_unary(node, ctx)

    if isinstance(node, Ternary):
        return _eval_ternary(node, ctx)

    if isinstance(node, LogicalOp):
        return _eval_logical(node, ctx)

    if isinstance(node, Lambda):
        # Capture the current context as the closure's scope
        return Value(ValueType.CLOSURE, (node.params, node.body, dict(ctx)))

    if isinstance(node, Let):
        val = eval_node(node.value, ctx)
        child_ctx = dict(ctx)
        child_ctx[node.name] = val.value if val.type != ValueType.CLOSURE else val
        return eval_node(node.body, child_ctx)

    if isinstance(node, Assign):
        val = eval_node(node.value, ctx)
        # Write to the mutable store callback if provided
        store_cb = ctx.get("__store_cb__")
        if store_cb:
            store_cb(node.target, val)
        return val

    if isinstance(node, Sequence):
        eval_node(node.left, ctx)
        return eval_node(node.right, ctx)

    return Value.null()


# ── Literals ─────────────────────────────────────────────────


def _eval_literal(node: Literal, ctx: dict = None) -> Value:
    if node.kind == "number":
        return Value.number(node.value)
    if node.kind == "string":
        return Value.string(node.value)
    if node.kind == "color":
        return Value.color(node.value)
    if node.kind == "bool":
        return Value.bool_(node.value)
    if node.kind == "list":
        # List literal: items are AST nodes that need evaluation
        items = [eval_node(item, ctx or {}).value for item in node.value]
        return Value.list_(items)
    return Value.null()


# ── Path resolution ──────────────────────────────────────────


def _eval_path(segments: list[str], ctx: dict) -> Value:
    if not segments:
        return Value.null()

    namespace = segments[0]
    obj = ctx.get(namespace)
    if obj is None:
        return Value.null()

    for seg in segments[1:]:
        if isinstance(obj, dict):
            if seg in obj:
                obj = obj[seg]
            else:
                return Value.null()
        elif isinstance(obj, list):
            try:
                idx = int(seg)
                if 0 <= idx < len(obj):
                    obj = obj[idx]
                else:
                    return Value.null()
            except (ValueError, TypeError):
                # Check for list methods
                if seg == "length":
                    return Value.number(len(obj))
                return Value.null()
        elif isinstance(obj, str):
            if seg == "length":
                return Value.number(len(obj))
            return Value.null()
        else:
            return Value.null()

    return Value.from_python(obj)


# ── Dot access on computed values ────────────────────────────


def _eval_dot_access(node: DotAccess, ctx: dict) -> Value:
    obj_val = eval_node(node.obj, ctx)

    # Path computed properties (Phase 3 §6.2)
    if obj_val.type == ValueType.PATH:
        indices = obj_val.value  # tuple[int, ...]
        if node.member == "depth":
            return Value.number(len(indices))
        if node.member == "parent":
            if len(indices) == 0:
                return Value.null()
            return Value.path(indices[:-1])
        if node.member == "id":
            return Value.string(".".join(str(i) for i in indices))
        if node.member == "indices":
            return Value.list_(list(indices))
        return Value.null()

    # List methods
    if obj_val.type == ValueType.LIST and node.member == "length":
        return Value.number(len(obj_val.value))

    # String methods
    if obj_val.type == ValueType.STRING and node.member == "length":
        return Value.number(len(obj_val.value))

    # Dict property access
    if obj_val.value is not None and isinstance(obj_val.value, dict):
        val = obj_val.value.get(node.member)
        if val is not None:
            return Value.from_python(val)

    # List numeric index
    if obj_val.type == ValueType.LIST:
        try:
            idx = int(node.member)
            if 0 <= idx < len(obj_val.value):
                return Value.from_python(obj_val.value[idx])
        except (ValueError, TypeError):
            pass

    return Value.null()


# ── Index access ─────────────────────────────────────────────


def _eval_index_access(node: IndexAccess, ctx: dict) -> Value:
    obj_val = eval_node(node.obj, ctx)
    idx_val = eval_node(node.index, ctx)

    key = idx_val.to_string()

    if obj_val.value is not None and isinstance(obj_val.value, dict):
        val = obj_val.value.get(key)
        if val is not None:
            return Value.from_python(val)

    if obj_val.type == ValueType.LIST:
        try:
            idx = int(key)
            if 0 <= idx < len(obj_val.value):
                return Value.from_python(obj_val.value[idx])
        except (ValueError, TypeError):
            pass

    return Value.null()


# ── Function calls ───────────────────────────────────────────


def _color_arg(val: Value) -> str:
    """Extract a hex color string from a Value for color functions."""
    if val.type == ValueType.COLOR:
        return val.value
    if val.type == ValueType.NULL:
        return "#000000"
    if val.type == ValueType.STRING:
        return val.value
    return "#000000"


# Keys in ctx that are runtime-context namespaces, not user bindings.
# When a closure is applied, these are refreshed from the caller's ctx
# so that state/panel reads see current values; user bindings stay
# lexically captured.
_NAMESPACE_KEYS = frozenset({
    "state", "panel", "theme", "dialog", "param", "event", "node", "prop",
    "active_document", "workspace", "data",
})


def _apply_closure(closure: Value, args: list[Value], caller_ctx: dict) -> Value:
    """Invoke a closure with proper lexical scoping.

    Start from the captured env, refresh runtime-context namespaces from
    the caller (so state/panel reads are current), then bind parameters.
    """
    params, body, captured_ctx = closure.value
    if len(args) != len(params):
        return Value.null()
    call_ctx = dict(captured_ctx)
    for k in _NAMESPACE_KEYS:
        if k in caller_ctx:
            call_ctx[k] = caller_ctx[k]
    for p, a in zip(params, args):
        call_ctx[p] = a.value if a.type != ValueType.CLOSURE else a
    return eval_node(body, call_ctx)


_COLOR_DECOMPOSE = {
    "hsb_h": lambda r, g, b: color_util.rgb_to_hsb(r, g, b)[0],
    "hsb_s": lambda r, g, b: color_util.rgb_to_hsb(r, g, b)[1],
    "hsb_b": lambda r, g, b: color_util.rgb_to_hsb(r, g, b)[2],
    "rgb_r": lambda r, g, b: r,
    "rgb_g": lambda r, g, b: g,
    "rgb_b": lambda r, g, b: b,
    "cmyk_c": lambda r, g, b: color_util.rgb_to_cmyk(r, g, b)[0],
    "cmyk_m": lambda r, g, b: color_util.rgb_to_cmyk(r, g, b)[1],
    "cmyk_y": lambda r, g, b: color_util.rgb_to_cmyk(r, g, b)[2],
    "cmyk_k": lambda r, g, b: color_util.rgb_to_cmyk(r, g, b)[3],
}


def _eval_func(node: FuncCall, ctx: dict) -> Value:
    name = node.name

    # __apply__: first arg is the callee expression result
    if name == "__apply__" and len(node.args) >= 1:
        callee = eval_node(node.args[0], ctx)
        if callee.type == ValueType.CLOSURE:
            args = [eval_node(a, ctx) for a in node.args[1:]]
            return _apply_closure(callee, args, ctx)
        return Value.null()

    # Check if name resolves to a closure in scope
    closure_val = ctx.get(name)
    if isinstance(closure_val, Value) and closure_val.type == ValueType.CLOSURE:
        args = [eval_node(a, ctx) for a in node.args]
        return _apply_closure(closure_val, args, ctx)

    # Color decomposition: single color argument → number
    if name in _COLOR_DECOMPOSE:
        if len(node.args) != 1:
            return Value.number(0)
        arg = eval_node(node.args[0], ctx)
        c = _color_arg(arg)
        r, g, b = color_util.parse_hex(c)
        return Value.number(_COLOR_DECOMPOSE[name](r, g, b))

    # hex: color → string
    if name == "hex":
        if len(node.args) != 1:
            return Value.string("")
        arg = eval_node(node.args[0], ctx)
        c = _color_arg(arg)
        r, g, b = color_util.parse_hex(c)
        return Value.string(f"{r:02x}{g:02x}{b:02x}")

    # rgb: (r, g, b) → color
    if name == "rgb":
        if len(node.args) != 3:
            return Value.null()
        args = [eval_node(a, ctx) for a in node.args]
        r = int(args[0].value) if args[0].type == ValueType.NUMBER else 0
        g = int(args[1].value) if args[1].type == ValueType.NUMBER else 0
        b = int(args[2].value) if args[2].type == ValueType.NUMBER else 0
        return Value.color(color_util.rgb_to_hex(r, g, b))

    # hsb: (h, s, b) → color
    if name == "hsb":
        if len(node.args) != 3:
            return Value.null()
        args = [eval_node(a, ctx) for a in node.args]
        h = float(args[0].value) if args[0].type == ValueType.NUMBER else 0
        s = float(args[1].value) if args[1].type == ValueType.NUMBER else 0
        bv = float(args[2].value) if args[2].type == ValueType.NUMBER else 0
        r, g, b = color_util.hsb_to_rgb(h, s, bv)
        return Value.color(color_util.rgb_to_hex(r, g, b))

    # cmyk: (c, m, y, k) → color
    if name == "cmyk":
        if len(node.args) != 4:
            return Value.null()
        args = [eval_node(a, ctx) for a in node.args]
        cv = float(args[0].value) / 100.0 if args[0].type == ValueType.NUMBER else 0
        mv = float(args[1].value) / 100.0 if args[1].type == ValueType.NUMBER else 0
        yv = float(args[2].value) / 100.0 if args[2].type == ValueType.NUMBER else 0
        kv = float(args[3].value) / 100.0 if args[3].type == ValueType.NUMBER else 0
        r = round((1 - cv) * (1 - kv) * 255)
        g = round((1 - mv) * (1 - kv) * 255)
        b = round((1 - yv) * (1 - kv) * 255)
        return Value.color(color_util.rgb_to_hex(r, g, b))

    # grayscale: (k) → color  (k is 0-100, 0=white, 100=black)
    if name == "grayscale":
        if len(node.args) != 1:
            return Value.null()
        arg = eval_node(node.args[0], ctx)
        kv = float(arg.value) if arg.type == ValueType.NUMBER else 0
        v = round((1 - kv / 100) * 255)
        return Value.color(color_util.rgb_to_hex(v, v, v))

    # invert: color → color
    if name == "invert":
        if len(node.args) != 1:
            return Value.null()
        arg = eval_node(node.args[0], ctx)
        c = _color_arg(arg)
        r, g, b = color_util.parse_hex(c)
        return Value.color(color_util.rgb_to_hex(255 - r, 255 - g, 255 - b))

    # complement: color → color
    if name == "complement":
        if len(node.args) != 1:
            return Value.null()
        arg = eval_node(node.args[0], ctx)
        c = _color_arg(arg)
        r, g, b = color_util.parse_hex(c)
        h, s, bv = color_util.rgb_to_hsb(r, g, b)
        if s == 0:
            return Value.color(color_util.rgb_to_hex(r, g, b))
        new_h = (h + 180) % 360
        nr, ng, nb = color_util.hsb_to_rgb(new_h, s, bv)
        return Value.color(color_util.rgb_to_hex(nr, ng, nb))

    # ── Higher-order functions (Phase 3 §6.1) ─────────────
    if name in ("any", "all", "map", "filter"):
        if len(node.args) != 2:
            return Value.null() if name in ("map", "filter") else Value.bool_(name == "all")
        lst = eval_node(node.args[0], ctx)
        callable_val = eval_node(node.args[1], ctx)
        if lst.type != ValueType.LIST or callable_val.type != ValueType.CLOSURE:
            return Value.null() if name in ("map", "filter") else Value.bool_(name == "all")
        # Apply the closure to each item; _apply_closure handles arity checks
        results = [_apply_closure(callable_val, [Value.from_python(item)], ctx)
                   for item in lst.value]
        if name == "any":
            return Value.bool_(any(r.to_bool() for r in results))
        if name == "all":
            return Value.bool_(all(r.to_bool() for r in results))
        if name == "map":
            return Value.list_([r.value if r.type != ValueType.CLOSURE else r for r in results])
        if name == "filter":
            kept = [lst.value[i] for i, r in enumerate(results) if r.to_bool()]
            return Value.list_(kept)

    # ── Path functions (Phase 3 §6.2) ─────────────────────
    if name == "path":
        indices = []
        for a in node.args:
            v = eval_node(a, ctx)
            if v.type != ValueType.NUMBER:
                return Value.null()
            indices.append(int(v.value))
        return Value.path(tuple(indices))

    if name == "path_child":
        if len(node.args) != 2:
            return Value.null()
        p = eval_node(node.args[0], ctx)
        i = eval_node(node.args[1], ctx)
        if p.type != ValueType.PATH or i.type != ValueType.NUMBER:
            return Value.null()
        return Value.path(p.value + (int(i.value),))

    if name == "path_from_id":
        if len(node.args) != 1:
            return Value.null()
        s = eval_node(node.args[0], ctx)
        if s.type != ValueType.STRING:
            return Value.null()
        if s.value == "":
            return Value.path(())
        try:
            parts = [int(p) for p in s.value.split(".")]
            if any(p < 0 for p in parts):
                return Value.null()
            return Value.path(tuple(parts))
        except ValueError:
            return Value.null()

    # mem: (element, list) → bool — list membership
    if name == "mem":
        if len(node.args) != 2:
            return Value.bool_(False)
        elem = eval_node(node.args[0], ctx)
        lst = eval_node(node.args[1], ctx)
        if lst.type != ValueType.LIST:
            return Value.bool_(False)
        for item in lst.value:
            if _strict_eq(elem, Value.from_python(item)):
                return Value.bool_(True)
        return Value.bool_(False)

    # Unknown function
    return Value.null()


# ── Binary operators ─────────────────────────────────────────


def _eval_binary(node: BinaryOp, ctx: dict) -> Value:
    left = eval_node(node.left, ctx)
    right = eval_node(node.right, ctx)

    if node.op == "==":
        return Value.bool_(_strict_eq(left, right))
    if node.op == "!=":
        return Value.bool_(not _strict_eq(left, right))
    if node.op == "<":
        return _numeric_cmp(left, right, lambda a, b: a < b)
    if node.op == ">":
        return _numeric_cmp(left, right, lambda a, b: a > b)
    if node.op == "<=":
        return _numeric_cmp(left, right, lambda a, b: a <= b)
    if node.op == ">=":
        return _numeric_cmp(left, right, lambda a, b: a >= b)
    # Arithmetic
    if node.op == "+":
        if left.type == ValueType.NUMBER and right.type == ValueType.NUMBER:
            return Value.number(left.value + right.value)
        # String concatenation
        return Value.string(left.to_string() + right.to_string())
    if node.op == "-":
        if left.type == ValueType.NUMBER and right.type == ValueType.NUMBER:
            return Value.number(left.value - right.value)
        return Value.null()
    if node.op == "*":
        if left.type == ValueType.NUMBER and right.type == ValueType.NUMBER:
            return Value.number(left.value * right.value)
        return Value.null()
    if node.op == "/":
        if left.type == ValueType.NUMBER and right.type == ValueType.NUMBER:
            if right.value == 0:
                return Value.null()
            return Value.number(left.value / right.value)
        return Value.null()

    return Value.null()


def _strict_eq(left: Value, right: Value) -> bool:
    """Strict typed equality. Different types → false."""
    if left.type != right.type:
        return False
    if left.type == ValueType.NULL:
        return True
    if left.type == ValueType.COLOR:
        # Normalize both to 6-digit lowercase for comparison
        return _normalize_color(left.value) == _normalize_color(right.value)
    return left.value == right.value


def _normalize_color(c: str) -> str:
    c = c.lower()
    if len(c) == 4:
        return "#" + c[1]*2 + c[2]*2 + c[3]*2
    return c


def _numeric_cmp(left: Value, right: Value, op) -> Value:
    if left.type != ValueType.NUMBER or right.type != ValueType.NUMBER:
        return Value.bool_(False)
    return Value.bool_(op(left.value, right.value))


def _eval_in(left: Value, right: Value) -> Value:
    if right.type != ValueType.LIST:
        return Value.bool_(False)
    for item in right.value:
        item_val = Value.from_python(item)
        if _strict_eq(left, item_val):
            return Value.bool_(True)
    return Value.bool_(False)


# ── Unary operators ──────────────────────────────────────────


def _eval_unary(node: UnaryOp, ctx: dict) -> Value:
    if node.op == "not":
        val = eval_node(node.operand, ctx)
        return Value.bool_(not val.to_bool())
    if node.op == "-":
        val = eval_node(node.operand, ctx)
        if val.type == ValueType.NUMBER:
            return Value.number(-val.value)
        return Value.null()
    return Value.null()


# ── Ternary ──────────────────────────────────────────────────


def _eval_ternary(node: Ternary, ctx: dict) -> Value:
    cond = eval_node(node.condition, ctx)
    if cond.to_bool():
        return eval_node(node.true_expr, ctx)
    return eval_node(node.false_expr, ctx)


# ── Logical operators ────────────────────────────────────────


def _eval_logical(node: LogicalOp, ctx: dict) -> Value:
    left = eval_node(node.left, ctx)
    if node.op == "and":
        if not left.to_bool():
            return left
        return eval_node(node.right, ctx)
    if node.op == "or":
        if left.to_bool():
            return left
        return eval_node(node.right, ctx)
    return Value.null()
