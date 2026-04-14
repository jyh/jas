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
        node = self._parse_ternary()
        if self._peek().kind != TokenKind.EOF:
            raise ParseError(f"Unexpected token after expression: {self._peek().kind.name}")
        return node

    def _parse_ternary(self):
        """ternary = or_expr ( '?' expr ':' expr )?"""
        node = self._parse_or()
        if self._at(TokenKind.QUESTION):
            self._advance()
            true_expr = self._parse_ternary()
            self._expect(TokenKind.COLON)
            false_expr = self._parse_ternary()
            return Ternary(node, true_expr, false_expr)
        return node

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
        """not_expr = 'not' not_expr | comparison"""
        if self._at(TokenKind.NOT):
            self._advance()
            operand = self._parse_not()
            return UnaryOp("not", operand)
        return self._parse_comparison()

    def _parse_comparison(self):
        """comparison = primary ( comp_op primary )?"""
        node = self._parse_primary()
        op_map = {
            TokenKind.EQ: "==",
            TokenKind.NEQ: "!=",
            TokenKind.LT: "<",
            TokenKind.GT: ">",
            TokenKind.LTE: "<=",
            TokenKind.GTE: ">=",
            TokenKind.IN: "in",
        }
        if self._peek().kind in op_map:
            op_tok = self._advance()
            right = self._parse_primary()
            return BinaryOp(op_map[op_tok.kind], node, right)
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
                index_expr = self._parse_ternary()
                self._expect(TokenKind.RBRACKET)
                node = IndexAccess(node, index_expr)
            else:
                break
        return node

    def _parse_atom(self):
        """atom = IDENT '(' args? ')' | IDENT | STRING | COLOR | NUMBER | null | true | false | '(' expr ')'"""
        tok = self._peek()

        if tok.kind == TokenKind.IDENT:
            self._advance()
            name = tok.value
            # Check for function call: IDENT '('
            if self._at(TokenKind.LPAREN):
                self._advance()
                args = []
                if not self._at(TokenKind.RPAREN):
                    args.append(self._parse_ternary())
                    while self._at(TokenKind.COMMA):
                        self._advance()
                        args.append(self._parse_ternary())
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
            node = self._parse_ternary()
            self._expect(TokenKind.RPAREN)
            return node

        raise ParseError(f"Unexpected token: {tok.kind.name} ({tok.value!r})")


def parse(source: str):
    """Parse an expression string into an AST node. Returns None for empty input."""
    tokens = tokenize(source)
    parser = Parser(tokens)
    return parser.parse()
