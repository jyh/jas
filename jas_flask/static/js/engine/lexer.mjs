// Tokenizer for the workspace expression language (JS port).
//
// Mirrors `workspace_interpreter/expr_lexer.py`. Cross-language
// agreement is enforced by `workspace/tests/expressions.yaml`; any
// deviation here fails the cross-language fixture run.

// Token kinds — string constants for JSON serialization. The Python
// side uses an Enum with .name strings; matching keeps token traces
// diff-able across languages.
export const TK = Object.freeze({
  IDENT: "ident",
  NUMBER: "number",
  STRING: "string",
  COLOR: "color",
  TRUE: "true",
  FALSE: "false",
  NULL: "null",
  NOT: "not",
  AND: "and",
  OR: "or",
  IN: "in",
  FUN: "fun",
  LET: "let",
  IF: "if",
  THEN: "then",
  ELSE: "else",
  EQ: "eq",
  NEQ: "neq",
  LT: "lt",
  GT: "gt",
  LTE: "lte",
  GTE: "gte",
  QUESTION: "question",
  COLON: "colon",
  DOT: "dot",
  COMMA: "comma",
  LPAREN: "lparen",
  RPAREN: "rparen",
  LBRACKET: "lbracket",
  RBRACKET: "rbracket",
  PLUS: "plus",
  MINUS: "minus",
  STAR: "star",
  SLASH: "slash",
  ARROW: "arrow",
  LARROW: "larrow",
  SEMICOLON: "semicolon",
  EQUALS: "equals",
  EOF: "eof",
  ERROR: "error",
});

const KEYWORDS = {
  true: TK.TRUE,
  false: TK.FALSE,
  null: TK.NULL,
  not: TK.NOT,
  and: TK.AND,
  or: TK.OR,
  in: TK.IN,
  fun: TK.FUN,
  let: TK.LET,
  if: TK.IF,
  then: TK.THEN,
  else: TK.ELSE,
};

const HEX = "0123456789abcdefABCDEF";

function isDigit(c) {
  return c >= "0" && c <= "9";
}
function isAlpha(c) {
  return (c >= "a" && c <= "z") || (c >= "A" && c <= "Z");
}
function isAlnum(c) {
  return isDigit(c) || isAlpha(c);
}

function tok(kind, value) {
  return value === undefined ? { kind } : { kind, value };
}

/**
 * Tokenize an expression string into a list of tokens. Always
 * terminates with a TK.EOF token. Unrecognized characters emit TK.ERROR
 * rather than throwing — the parser decides whether to tolerate them
 * (typos in tool YAML flag loudly at compile time).
 */
export function tokenize(source) {
  const tokens = [];
  const n = source.length;
  let i = 0;

  while (i < n) {
    const c = source[i];

    // Whitespace.
    if (c === " " || c === "\t" || c === "\n" || c === "\r") {
      i++;
      continue;
    }

    // Color literal: #rrggbb or #rgb.
    if (c === "#") {
      let j = i + 1;
      while (j < n && HEX.includes(source[j])) j++;
      const hexLen = j - i - 1;
      if (hexLen === 3 || hexLen === 6) {
        tokens.push(tok(TK.COLOR, source.slice(i, j).toLowerCase()));
      } else {
        tokens.push(tok(TK.ERROR, source.slice(i, j)));
      }
      i = j;
      continue;
    }

    // String literal: "…" or '…' with backslash escapes.
    if (c === '"' || c === "'") {
      const quote = c;
      let j = i + 1;
      const parts = [];
      while (j < n && source[j] !== quote) {
        if (source[j] === "\\" && j + 1 < n) {
          parts.push(source[j + 1]);
          j += 2;
        } else {
          parts.push(source[j]);
          j++;
        }
      }
      if (j < n) j++; // consume closing quote
      tokens.push(tok(TK.STRING, parts.join("")));
      i = j;
      continue;
    }

    // Number. Decimals supported; unary minus is a separate operator.
    if (isDigit(c)) {
      let j = i;
      while (j < n && isDigit(source[j])) j++;
      let isFloat = false;
      if (j < n && source[j] === ".") {
        isFloat = true;
        j++;
        while (j < n && isDigit(source[j])) j++;
      }
      const num = isFloat
        ? parseFloat(source.slice(i, j))
        : parseInt(source.slice(i, j), 10);
      tokens.push(tok(TK.NUMBER, num));
      i = j;
      continue;
    }

    // Identifier / keyword.
    if (isAlpha(c) || c === "_") {
      let j = i + 1;
      while (j < n && (isAlnum(source[j]) || source[j] === "_")) j++;
      const word = source.slice(i, j);
      const kw = KEYWORDS[word];
      tokens.push(tok(kw || TK.IDENT, word));
      i = j;
      continue;
    }

    // Multi-character operators — order matters (longest match wins).
    if (c === "=" && source[i + 1] === "=") {
      tokens.push(tok(TK.EQ));
      i += 2; continue;
    }
    if (c === "!" && source[i + 1] === "=") {
      tokens.push(tok(TK.NEQ));
      i += 2; continue;
    }
    if (c === "<" && source[i + 1] === "-") {
      tokens.push(tok(TK.LARROW));
      i += 2; continue;
    }
    if (c === "<" && source[i + 1] === "=") {
      tokens.push(tok(TK.LTE));
      i += 2; continue;
    }
    if (c === ">" && source[i + 1] === "=") {
      tokens.push(tok(TK.GTE));
      i += 2; continue;
    }
    if (c === "-" && source[i + 1] === ">") {
      tokens.push(tok(TK.ARROW));
      i += 2; continue;
    }

    // Single-character operators.
    switch (c) {
      case "<": tokens.push(tok(TK.LT)); break;
      case ">": tokens.push(tok(TK.GT)); break;
      case "=": tokens.push(tok(TK.EQUALS)); break;
      case "?": tokens.push(tok(TK.QUESTION)); break;
      case ":": tokens.push(tok(TK.COLON)); break;
      case ".": tokens.push(tok(TK.DOT)); break;
      case ",": tokens.push(tok(TK.COMMA)); break;
      case ";": tokens.push(tok(TK.SEMICOLON)); break;
      case "(": tokens.push(tok(TK.LPAREN)); break;
      case ")": tokens.push(tok(TK.RPAREN)); break;
      case "[": tokens.push(tok(TK.LBRACKET)); break;
      case "]": tokens.push(tok(TK.RBRACKET)); break;
      case "+": tokens.push(tok(TK.PLUS)); break;
      case "-": tokens.push(tok(TK.MINUS)); break;
      case "*": tokens.push(tok(TK.STAR)); break;
      case "/": tokens.push(tok(TK.SLASH)); break;
      default: tokens.push(tok(TK.ERROR, c)); break;
    }
    i++;
  }

  tokens.push(tok(TK.EOF));
  return tokens;
}
