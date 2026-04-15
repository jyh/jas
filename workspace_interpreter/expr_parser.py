"""Recursive descent parser for the expression language.

Produces an AST from a token list. See SCHEMA.md, Expression Language Grammar.
"""

from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any

from workspace_interpreter.expr_lexer import Token, TokenKind, tokenize


# ── AST nodes ────────────────────────────────────────────────


@dataclass(slots=True)
class Literal:
    """A literal value: number, string, color, bool, or null."""
    value: Any
    kind: str  # "number", "string", "color", "bool", "null"


@dataclass(slots=True)
class Path:
    """A dot-separated path: state.fill_color, panel.recent_colors.0"""
    segments: list[str]


@dataclass(slots=True)
class FuncCall:
    """A function call: hsb_h(expr), rgb(expr, expr, expr)"""
    name: str
    args: list


@dataclass(slots=True)
class IndexAccess:
    """Dynamic indexing: path[expr]"""
    obj: Any  # AST node
    index: Any  # AST node


@dataclass(slots=True)
class DotAccess:
    """Property/method access on a computed value: expr.ident"""
    obj: Any  # AST node
    member: str


@dataclass(slots=True)
class BinaryOp:
    """Binary operation: ==, !=, <, >, <=, >=, in"""
    op: str
    left: Any
    right: Any


@dataclass(slots=True)
class UnaryOp:
    """Unary operation: not"""
    op: str
    operand: Any


@dataclass(slots=True)
class Ternary:
    """Ternary: condition ? true_expr : false_expr"""
    condition: Any
    true_expr: Any
    false_expr: Any


@dataclass(slots=True)
class LogicalOp:
    """Logical and/or with short-circuit semantics."""
    op: str  # "and" | "or"
    left: Any
    right: Any


@dataclass(slots=True)
class Lambda:
    """Lambda: fun x -> body  |  fun (x, y) -> body  |  fun () -> body"""
    params: list[str]
    body: Any


@dataclass(slots=True)
class Let:
    """Let binding: let x = e1 in e2"""
    name: str
    value: Any
    body: Any


@dataclass(slots=True)
class Assign:
    """Assignment: x <- expr (mutates state variable)"""
    target: str
    value: Any


@dataclass(slots=True)
class Sequence:
    """Sequencing: e1; e2 (evaluate left for side effects, return right)"""
    left: Any
    right: Any


# ── Parser ───────────────────────────────────────────────────


class ParseError(Exception):
    pass


class Parser:
    def __init__(self, tokens: list[Token]):
        self._tokens = tokens
        self._pos = 0

    def _peek(self) -> Token:
        return self._tokens[self._pos]

    def _advance(self) -> Token:
        tok = self._tokens[self._pos]
        self._pos += 1
        return tok

    def _expect(self, kind: TokenKind) -> Token:
        tok = self._advance()
        if tok.kind != kind:
            raise ParseError(f"Expected {kind.name}, got {tok.kind.name}")
        return tok

    def _at(self, *kinds: TokenKind) -> bool:
        return self._peek().kind in kinds

    def parse(self):
        """Parse the full expression. Returns an AST node or None."""
        if self._peek().kind == TokenKind.EOF:
            return None
        node = self._parse_sequence()
        if self._peek().kind != TokenKind.EOF:
            raise ParseError(f"Unexpected token after expression: {self._peek().kind.name}")
        return node

    def _parse_sequence(self):
        """sequence = let_expr (';' let_expr)*"""
        node = self._parse_let()
        while self._at(TokenKind.SEMICOLON):
            self._advance()
            right = self._parse_let()
            node = Sequence(node, right)
        return node

    def _parse_let(self):
        """let_expr = 'let' IDENT '=' sequence 'in' let_expr | assign"""
        if self._at(TokenKind.LET):
            self._advance()
            name_tok = self._expect(TokenKind.IDENT)
            self._expect(TokenKind.EQUALS)
            value = self._parse_sequence()
            self._expect(TokenKind.IN)
            body = self._parse_let()
            return Let(name_tok.value, value, body)
        return self._parse_assign()

    def _parse_assign(self):
        """assign = ternary '<-' assign | ternary"""
        node = self._parse_ternary()
        if self._at(TokenKind.LARROW):
            self._advance()
            # The left side must be an identifier (Path with one segment)
            if isinstance(node, Path) and len(node.segments) == 1:
                value = self._parse_assign()
                return Assign(node.segments[0], value)
            raise ParseError("Assignment target must be an identifier")
        return node

    def _parse_ternary(self):
        """ternary = 'if' expr 'then' expr 'else' expr | or_expr"""
        if self._at(TokenKind.IF):
            self._advance()
            condition = self._parse_sequence()
            self._expect(TokenKind.THEN)
            true_expr = self._parse_sequence()
            self._expect(TokenKind.ELSE)
            false_expr = self._parse_sequence()
            return Ternary(condition, true_expr, false_expr)
        return self._parse_or()

    def _parse_or(self):
        """or_expr = and_expr ( 'or' and_expr )*"""
        node = self._parse_and()
        while self._at(TokenKind.OR):
            self._advance()
            right = self._parse_and()
            node = LogicalOp("or", node, right)
        return node

    def _parse_and(self):
        """and_expr = not_expr ( 'and' not_expr )*"""
        node = self._parse_not()
        while self._at(TokenKind.AND):
            self._advance()
            right = self._parse_not()
            node = LogicalOp("and", node, right)
        return node

    def _parse_not(self):
        """not_expr = 'not' not_expr | '-' not_expr | comparison"""
        if self._at(TokenKind.NOT):
            self._advance()
            operand = self._parse_not()
            return UnaryOp("not", operand)
        if self._at(TokenKind.MINUS):
            self._advance()
            operand = self._parse_not()
            return UnaryOp("-", operand)
        return self._parse_comparison()

    def _parse_comparison(self):
        """comparison = addition ( comp_op addition )?"""
        node = self._parse_addition()
        op_map = {
            TokenKind.EQ: "==",
            TokenKind.NEQ: "!=",
            TokenKind.LT: "<",
            TokenKind.GT: ">",
            TokenKind.LTE: "<=",
            TokenKind.GTE: ">=",
        }
        if self._peek().kind in op_map:
            op_tok = self._advance()
            right = self._parse_addition()
            return BinaryOp(op_map[op_tok.kind], node, right)
        return node

    def _parse_addition(self):
        """addition = multiplication (('+' | '-') multiplication)*"""
        node = self._parse_multiplication()
        while self._at(TokenKind.PLUS, TokenKind.MINUS):
            op_tok = self._advance()
            op = "+" if op_tok.kind == TokenKind.PLUS else "-"
            right = self._parse_multiplication()
            node = BinaryOp(op, node, right)
        return node

    def _parse_multiplication(self):
        """multiplication = primary (('*' | '/') primary)*"""
        node = self._parse_primary()
        while self._at(TokenKind.STAR, TokenKind.SLASH):
            op_tok = self._advance()
            op = "*" if op_tok.kind == TokenKind.STAR else "/"
            right = self._parse_primary()
            node = BinaryOp(op, node, right)
        return node

    def _parse_primary(self):
        """primary = atom accessor*"""
        node = self._parse_atom()
        while True:
            if self._at(TokenKind.DOT):
                self._advance()
                # Could be IDENT or NUMBER (for list.0 indexing)
                tok = self._peek()
                if tok.kind == TokenKind.IDENT or tok.kind in (
                    TokenKind.TRUE, TokenKind.FALSE, TokenKind.NULL,
                    TokenKind.NOT, TokenKind.AND, TokenKind.OR, TokenKind.IN,
                ):
                    # Allow keywords as property names after dot
                    member = self._advance().value
                    # If the base is a simple Path, extend it
                    if isinstance(node, Path):
                        node.segments.append(str(member))
                    else:
                        node = DotAccess(node, str(member))
                elif tok.kind == TokenKind.NUMBER and isinstance(tok.value, int):
                    idx = self._advance().value
                    if isinstance(node, Path):
                        node.segments.append(str(idx))
                    else:
                        node = DotAccess(node, str(idx))
                else:
                    raise ParseError(f"Expected identifier after '.', got {tok.kind.name}")
            elif self._at(TokenKind.LBRACKET):
                self._advance()
                index_expr = self._parse_sequence()
                self._expect(TokenKind.RBRACKET)
                node = IndexAccess(node, index_expr)
            elif self._at(TokenKind.LPAREN):
                # Function application: expr(args)
                self._advance()
                args = []
                if not self._at(TokenKind.RPAREN):
                    args.append(self._parse_sequence())
                    while self._at(TokenKind.COMMA):
                        self._advance()
                        args.append(self._parse_sequence())
                self._expect(TokenKind.RPAREN)
                # If node is a Path with one segment, use FuncCall for compat
                if isinstance(node, Path) and len(node.segments) == 1:
                    node = FuncCall(node.segments[0], args)
                else:
                    node = FuncCall("__apply__", [node] + args)
            else:
                break
        return node

    def _parse_atom(self):
        """atom = 'fun' ... | IDENT '(' args? ')' | IDENT | literals | '(' expr ')'"""
        tok = self._peek()

        # Lambda: fun x -> body | fun (params) -> body | fun () -> body
        if tok.kind == TokenKind.FUN:
            self._advance()
            params = []
            if self._at(TokenKind.LPAREN):
                self._advance()
                if not self._at(TokenKind.RPAREN):
                    params.append(self._expect(TokenKind.IDENT).value)
                    while self._at(TokenKind.COMMA):
                        self._advance()
                        params.append(self._expect(TokenKind.IDENT).value)
                self._expect(TokenKind.RPAREN)
            elif self._at(TokenKind.IDENT):
                # Unary lambda without parens: fun x -> body
                params.append(self._advance().value)
            # else: fun -> is an error (caught by _expect below)
            self._expect(TokenKind.ARROW)
            body = self._parse_sequence()
            return Lambda(params, body)

        if tok.kind == TokenKind.IDENT:
            self._advance()
            name = tok.value
            # Check for function call: IDENT '('
            if self._at(TokenKind.LPAREN):
                self._advance()
                args = []
                if not self._at(TokenKind.RPAREN):
                    args.append(self._parse_sequence())
                    while self._at(TokenKind.COMMA):
                        self._advance()
                        args.append(self._parse_sequence())
                self._expect(TokenKind.RPAREN)
                return FuncCall(name, args)
            return Path([name])

        if tok.kind == TokenKind.NUMBER:
            self._advance()
            return Literal(tok.value, "number")

        if tok.kind == TokenKind.STRING:
            self._advance()
            return Literal(tok.value, "string")

        if tok.kind == TokenKind.COLOR:
            self._advance()
            return Literal(tok.value, "color")

        if tok.kind == TokenKind.TRUE:
            self._advance()
            return Literal(True, "bool")

        if tok.kind == TokenKind.FALSE:
            self._advance()
            return Literal(False, "bool")

        if tok.kind == TokenKind.NULL:
            self._advance()
            return Literal(None, "null")

        if tok.kind == TokenKind.LPAREN:
            self._advance()
            node = self._parse_sequence()
            self._expect(TokenKind.RPAREN)
            return node

        # List literal: [expr, expr, ...]
        if tok.kind == TokenKind.LBRACKET:
            self._advance()
            items = []
            if not self._at(TokenKind.RBRACKET):
                items.append(self._parse_sequence())
                while self._at(TokenKind.COMMA):
                    self._advance()
                    items.append(self._parse_sequence())
            self._expect(TokenKind.RBRACKET)
            return Literal(items, "list")

        raise ParseError(f"Unexpected token: {tok.kind.name} ({tok.value!r})")


def parse(source: str):
    """Parse an expression string into an AST node. Returns None for empty input."""
    tokens = tokenize(source)
    parser = Parser(tokens)
    return parser.parse()
