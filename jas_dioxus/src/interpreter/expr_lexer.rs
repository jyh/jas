//! Tokenizer for the expression language.

#[derive(Debug, Clone, PartialEq)]
pub enum TokenKind {
    Ident(String),
    Number(f64),
    Str(String),
    Color(String),
    True,
    False,
    Null,
    Not,
    And,
    Or,
    In,
    Fun,
    Let,
    If,
    Then,
    Else,
    Eq,        // ==
    Neq,       // !=
    Lt,        // <
    Gt,        // >
    Lte,       // <=
    Gte,       // >=
    Question,
    Colon,
    Dot,
    Comma,
    LParen,
    RParen,
    LBracket,
    RBracket,
    Plus,      // +
    Minus,     // -
    Star,      // *
    Slash,     // /
    Arrow,     // ->
    LArrow,    // <-
    Semicolon, // ;
    Equals,    // =
    Eof,
    Error(String),
}

#[derive(Debug, Clone)]
pub struct Token {
    pub kind: TokenKind,
}

pub fn tokenize(source: &str) -> Vec<Token> {
    let mut tokens = Vec::new();
    let chars: Vec<char> = source.chars().collect();
    let n = chars.len();
    let mut i = 0;

    while i < n {
        let c = chars[i];

        // Whitespace
        if c == ' ' || c == '\t' {
            i += 1;
            continue;
        }

        // Color literal: #rrggbb or #rgb
        if c == '#' {
            let mut j = i + 1;
            while j < n && chars[j].is_ascii_hexdigit() {
                j += 1;
            }
            let hex_len = j - i - 1;
            if hex_len == 3 || hex_len == 6 {
                let s: String = chars[i..j].iter().collect();
                tokens.push(Token { kind: TokenKind::Color(s.to_lowercase()) });
                i = j;
                continue;
            }
            let s: String = chars[i..j].iter().collect();
            tokens.push(Token { kind: TokenKind::Error(s) });
            i = j;
            continue;
        }

        // String literal
        if c == '"' {
            let mut j = i + 1;
            let mut parts = String::new();
            while j < n && chars[j] != '"' {
                if chars[j] == '\\' && j + 1 < n {
                    parts.push(chars[j + 1]);
                    j += 2;
                } else {
                    parts.push(chars[j]);
                    j += 1;
                }
            }
            if j < n { j += 1; } // consume closing "
            tokens.push(Token { kind: TokenKind::Str(parts) });
            i = j;
            continue;
        }

        // Number (digits only — unary minus handled as operator)
        if c.is_ascii_digit() {
            let start = i;
            while i < n && chars[i].is_ascii_digit() { i += 1; }
            if i < n && chars[i] == '.' {
                i += 1;
                while i < n && chars[i].is_ascii_digit() { i += 1; }
                let s: String = chars[start..i].iter().collect();
                tokens.push(Token { kind: TokenKind::Number(s.parse().unwrap_or(0.0)) });
            } else {
                let s: String = chars[start..i].iter().collect();
                tokens.push(Token { kind: TokenKind::Number(s.parse().unwrap_or(0.0)) });
            }
            continue;
        }

        // Identifier / keyword
        if c.is_ascii_alphabetic() || c == '_' {
            let start = i;
            while i < n && (chars[i].is_ascii_alphanumeric() || chars[i] == '_') { i += 1; }
            let word: String = chars[start..i].iter().collect();
            let kind = match word.as_str() {
                "true" => TokenKind::True,
                "false" => TokenKind::False,
                "null" => TokenKind::Null,
                "not" => TokenKind::Not,
                "and" => TokenKind::And,
                "or" => TokenKind::Or,
                "in" => TokenKind::In,
                "fun" => TokenKind::Fun,
                "let" => TokenKind::Let,
                "if" => TokenKind::If,
                "then" => TokenKind::Then,
                "else" => TokenKind::Else,
                _ => TokenKind::Ident(word),
            };
            tokens.push(Token { kind });
            continue;
        }

        // Two-character operators (order matters for greedy matching)
        if i + 1 < n {
            let next = chars[i + 1];
            match (c, next) {
                ('=', '=') => { tokens.push(Token { kind: TokenKind::Eq }); i += 2; continue; }
                ('!', '=') => { tokens.push(Token { kind: TokenKind::Neq }); i += 2; continue; }
                // <- must come before < alone (greedy)
                ('<', '-') => { tokens.push(Token { kind: TokenKind::LArrow }); i += 2; continue; }
                ('<', '=') => { tokens.push(Token { kind: TokenKind::Lte }); i += 2; continue; }
                ('>', '=') => { tokens.push(Token { kind: TokenKind::Gte }); i += 2; continue; }
                // -> must come before - alone (greedy)
                ('-', '>') => { tokens.push(Token { kind: TokenKind::Arrow }); i += 2; continue; }
                _ => {}
            }
        }

        // Single-character operators
        match c {
            '<' => tokens.push(Token { kind: TokenKind::Lt }),
            '>' => tokens.push(Token { kind: TokenKind::Gt }),
            '=' => tokens.push(Token { kind: TokenKind::Equals }),
            '?' => tokens.push(Token { kind: TokenKind::Question }),
            ':' => tokens.push(Token { kind: TokenKind::Colon }),
            '.' => tokens.push(Token { kind: TokenKind::Dot }),
            ',' => tokens.push(Token { kind: TokenKind::Comma }),
            ';' => tokens.push(Token { kind: TokenKind::Semicolon }),
            '(' => tokens.push(Token { kind: TokenKind::LParen }),
            ')' => tokens.push(Token { kind: TokenKind::RParen }),
            '[' => tokens.push(Token { kind: TokenKind::LBracket }),
            ']' => tokens.push(Token { kind: TokenKind::RBracket }),
            '+' => tokens.push(Token { kind: TokenKind::Plus }),
            '-' => tokens.push(Token { kind: TokenKind::Minus }),
            '*' => tokens.push(Token { kind: TokenKind::Star }),
            '/' => tokens.push(Token { kind: TokenKind::Slash }),
            _ => tokens.push(Token { kind: TokenKind::Error(c.to_string()) }),
        }
        i += 1;
    }

    tokens.push(Token { kind: TokenKind::Eof });
    tokens
}
