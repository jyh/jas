"""Tokenizer for the expression language."""

from __future__ import annotations
from enum import Enum, auto
from dataclasses import dataclass


class TokenKind(Enum):
    # Literals
    IDENT = auto()
    NUMBER = auto()
    STRING = auto()
    COLOR = auto()
    # Keywords
    TRUE = auto()
    FALSE = auto()
    NULL = auto()
    NOT = auto()
    AND = auto()
    OR = auto()
    IN = auto()
    # Operators
    EQ = auto()       # ==
    NEQ = auto()      # !=
    LT = auto()       # <
    GT = auto()       # >
    LTE = auto()      # <=
    GTE = auto()      # >=
    QUESTION = auto() # ?
    COLON = auto()    # :
    DOT = auto()      # .
    COMMA = auto()    # ,
    LPAREN = auto()   # (
    RPAREN = auto()   # )
    LBRACKET = auto() # [
    RBRACKET = auto() # ]
    # Control
    EOF = auto()
    ERROR = auto()


_KEYWORDS = {
    "true": TokenKind.TRUE,
    "false": TokenKind.FALSE,
    "null": TokenKind.NULL,
    "not": TokenKind.NOT,
    "and": TokenKind.AND,
    "or": TokenKind.OR,
    "in": TokenKind.IN,
}


@dataclass(slots=True)
class Token:
    kind: TokenKind
    value: str | float | None = None


def tokenize(source: str) -> list[Token]:
    """Tokenize an expression string into a list of Tokens."""
    tokens: list[Token] = []
    i = 0
    n = len(source)

    while i < n:
        c = source[i]

        # Whitespace
        if c in " \t":
            i += 1
            continue

        # Color literal: #rrggbb or #rgb
        if c == "#":
            j = i + 1
            while j < n and source[j] in "0123456789abcdefABCDEF":
                j += 1
            hex_len = j - i - 1
            if hex_len in (3, 6):
                tokens.append(Token(TokenKind.COLOR, source[i:j].lower()))
                i = j
                continue
            tokens.append(Token(TokenKind.ERROR, source[i:j]))
            i = j
            continue

        # String literal
        if c == '"':
            j = i + 1
            parts = []
            while j < n and source[j] != '"':
                if source[j] == "\\" and j + 1 < n:
                    parts.append(source[j + 1])
                    j += 2
                else:
                    parts.append(source[j])
                    j += 1
            if j < n:
                j += 1  # consume closing "
            tokens.append(Token(TokenKind.STRING, "".join(parts)))
            i = j
            continue

        # Number (including negative)
        if c.isdigit() or (c == "-" and i + 1 < n and source[i + 1].isdigit()):
            j = i + 1 if c == "-" else i
            while j < n and source[j].isdigit():
                j += 1
            if j < n and source[j] == ".":
                j += 1
                while j < n and source[j].isdigit():
                    j += 1
                tokens.append(Token(TokenKind.NUMBER, float(source[i:j])))
            else:
                tokens.append(Token(TokenKind.NUMBER, int(source[i:j])))
            i = j
            continue

        # Identifier / keyword
        if c.isalpha() or c == "_":
            j = i + 1
            while j < n and (source[j].isalnum() or source[j] == "_"):
                j += 1
            word = source[i:j]
            kind = _KEYWORDS.get(word, TokenKind.IDENT)
            tokens.append(Token(kind, word))
            i = j
            continue

        # Two-character operators
        if i + 1 < n:
            two = source[i:i+2]
            if two == "==":
                tokens.append(Token(TokenKind.EQ))
                i += 2
                continue
            if two == "!=":
                tokens.append(Token(TokenKind.NEQ))
                i += 2
                continue
            if two == "<=":
                tokens.append(Token(TokenKind.LTE))
                i += 2
                continue
            if two == ">=":
                tokens.append(Token(TokenKind.GTE))
                i += 2
                continue

        # Single-character operators
        if c == "<":
            tokens.append(Token(TokenKind.LT))
        elif c == ">":
            tokens.append(Token(TokenKind.GT))
        elif c == "?":
            tokens.append(Token(TokenKind.QUESTION))
        elif c == ":":
            tokens.append(Token(TokenKind.COLON))
        elif c == ".":
            tokens.append(Token(TokenKind.DOT))
        elif c == ",":
            tokens.append(Token(TokenKind.COMMA))
        elif c == "(":
            tokens.append(Token(TokenKind.LPAREN))
        elif c == ")":
            tokens.append(Token(TokenKind.RPAREN))
        elif c == "[":
            tokens.append(Token(TokenKind.LBRACKET))
        elif c == "]":
            tokens.append(Token(TokenKind.RBRACKET))
        else:
            tokens.append(Token(TokenKind.ERROR, c))
        i += 1

    tokens.append(Token(TokenKind.EOF))
    return tokens
