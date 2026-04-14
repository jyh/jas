//! Recursive descent parser for the expression language.
//!
//! Produces an AST from a token list. See SCHEMA.md, Expression Language Grammar.
//!
//! Grammar (highest to lowest precedence):
//!   sequence       = let_expr (';' let_expr)*
//!   let_expr       = 'let' IDENT '=' sequence 'in' let_expr | assign
//!   assign         = ternary '<-' assign | ternary
//!   ternary        = or_expr ('?' ternary ':' ternary)?
//!   or_expr        = and_expr ('or' and_expr)*
//!   and_expr       = not_expr ('and' not_expr)*
//!   not_expr       = 'not' not_expr | '-' not_expr | comparison
//!   comparison     = addition (comp_op addition)?
//!   addition       = multiplication (('+' | '-') multiplication)*
//!   multiplication = primary (('*' | '/') primary)*
//!   primary        = atom accessor*
//!   atom           = 'fun' ... | IDENT | literal | '(' sequence ')' | '[' ... ']'

use super::expr_lexer::{tokenize, Token, TokenKind};

// -- AST nodes ---------------------------------------------------------------

/// Binary comparison operator.
#[derive(Debug, Clone, PartialEq)]
pub enum BinOp {
    Eq,
    Neq,
    Lt,
    Gt,
    Lte,
    Gte,
    // Arithmetic
    Add,
    Sub,
    Mul,
    Div,
}

/// Literal value kind.
#[derive(Debug, Clone, PartialEq)]
pub enum LiteralKind {
    Number(f64),
    Str(String),
    Color(String),
    Bool(bool),
    Null,
    /// List literal: items are AST nodes that need evaluation.
    List(Vec<Expr>),
}

/// Expression AST node.
#[derive(Debug, Clone, PartialEq)]
pub enum Expr {
    Literal(LiteralKind),
    Path(Vec<String>),
    FuncCall { name: String, args: Vec<Expr> },
    DotAccess { obj: Box<Expr>, member: String },
    IndexAccess { obj: Box<Expr>, index: Box<Expr> },
    BinaryOp { op: BinOp, left: Box<Expr>, right: Box<Expr> },
    UnaryNot(Box<Expr>),
    UnaryMinus(Box<Expr>),
    Ternary { cond: Box<Expr>, true_expr: Box<Expr>, false_expr: Box<Expr> },
    LogicalAnd(Box<Expr>, Box<Expr>),
    LogicalOr(Box<Expr>, Box<Expr>),
    /// Lambda: fun x -> body | fun (x, y) -> body | fun () -> body
    Lambda { params: Vec<String>, body: Box<Expr> },
    /// Let binding: let x = e1 in e2
    Let { name: String, value: Box<Expr>, body: Box<Expr> },
    /// Assignment: x <- expr (mutates state variable via store callback)
    Assign { target: String, value: Box<Expr> },
    /// Sequencing: e1; e2 (evaluate left for side effects, return right)
    Sequence { left: Box<Expr>, right: Box<Expr> },
}

// -- Parser ------------------------------------------------------------------

struct Parser {
    tokens: Vec<Token>,
    pos: usize,
}

impl Parser {
    fn new(tokens: Vec<Token>) -> Self {
        Self { tokens, pos: 0 }
    }

    fn peek(&self) -> &TokenKind {
        &self.tokens[self.pos].kind
    }

    fn advance(&mut self) -> &TokenKind {
        let kind = &self.tokens[self.pos].kind;
        self.pos += 1;
        kind
    }

    fn advance_clone(&mut self) -> TokenKind {
        let kind = self.tokens[self.pos].kind.clone();
        self.pos += 1;
        kind
    }

    fn expect(&mut self, expected: &TokenKind) -> bool {
        if std::mem::discriminant(self.peek()) == std::mem::discriminant(expected) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn at(&self, kind: &TokenKind) -> bool {
        std::mem::discriminant(self.peek()) == std::mem::discriminant(kind)
    }

    // -- Grammar rules -------------------------------------------------------

    fn parse(&mut self) -> Option<Expr> {
        if matches!(self.peek(), TokenKind::Eof) {
            return None;
        }
        let node = self.parse_sequence();
        // Ignore trailing tokens rather than failing hard.
        Some(node)
    }

    /// sequence = let_expr (';' let_expr)*
    fn parse_sequence(&mut self) -> Expr {
        let mut node = self.parse_let();
        while matches!(self.peek(), TokenKind::Semicolon) {
            self.pos += 1;
            let right = self.parse_let();
            node = Expr::Sequence {
                left: Box::new(node),
                right: Box::new(right),
            };
        }
        node
    }

    /// let_expr = 'let' IDENT '=' sequence 'in' let_expr | assign
    fn parse_let(&mut self) -> Expr {
        if matches!(self.peek(), TokenKind::Let) {
            self.pos += 1;
            // Expect IDENT
            let name = match self.advance_clone() {
                TokenKind::Ident(n) => n,
                _ => return Expr::Literal(LiteralKind::Null), // error fallback
            };
            self.expect(&TokenKind::Equals);
            let value = self.parse_sequence();
            self.expect(&TokenKind::In);
            let body = self.parse_let();
            return Expr::Let {
                name,
                value: Box::new(value),
                body: Box::new(body),
            };
        }
        self.parse_assign()
    }

    /// assign = ternary '<-' assign | ternary
    fn parse_assign(&mut self) -> Expr {
        let node = self.parse_ternary();
        if matches!(self.peek(), TokenKind::LArrow) {
            self.pos += 1;
            // Left side must be an identifier (Path with one segment)
            if let Expr::Path(ref segs) = node {
                if segs.len() == 1 {
                    let target = segs[0].clone();
                    let value = self.parse_assign();
                    return Expr::Assign {
                        target,
                        value: Box::new(value),
                    };
                }
            }
            // Error: assignment target must be an identifier
            return Expr::Literal(LiteralKind::Null);
        }
        node
    }

    /// ternary = or_expr ( '?' ternary ':' ternary )?
    fn parse_ternary(&mut self) -> Expr {
        let node = self.parse_or();
        if matches!(self.peek(), TokenKind::Question) {
            self.pos += 1;
            let true_expr = self.parse_ternary();
            self.expect(&TokenKind::Colon);
            let false_expr = self.parse_ternary();
            return Expr::Ternary {
                cond: Box::new(node),
                true_expr: Box::new(true_expr),
                false_expr: Box::new(false_expr),
            };
        }
        node
    }

    /// or_expr = and_expr ( 'or' and_expr )*
    fn parse_or(&mut self) -> Expr {
        let mut node = self.parse_and();
        while matches!(self.peek(), TokenKind::Or) {
            self.pos += 1;
            let right = self.parse_and();
            node = Expr::LogicalOr(Box::new(node), Box::new(right));
        }
        node
    }

    /// and_expr = not_expr ( 'and' not_expr )*
    fn parse_and(&mut self) -> Expr {
        let mut node = self.parse_not();
        while matches!(self.peek(), TokenKind::And) {
            self.pos += 1;
            let right = self.parse_not();
            node = Expr::LogicalAnd(Box::new(node), Box::new(right));
        }
        node
    }

    /// not_expr = 'not' not_expr | '-' not_expr | comparison
    fn parse_not(&mut self) -> Expr {
        if matches!(self.peek(), TokenKind::Not) {
            self.pos += 1;
            let operand = self.parse_not();
            return Expr::UnaryNot(Box::new(operand));
        }
        if matches!(self.peek(), TokenKind::Minus) {
            self.pos += 1;
            let operand = self.parse_not();
            return Expr::UnaryMinus(Box::new(operand));
        }
        self.parse_comparison()
    }

    /// comparison = addition ( comp_op addition )?
    /// Note: 'in' is NOT a comparison operator (use mem() function instead).
    fn parse_comparison(&mut self) -> Expr {
        let node = self.parse_addition();
        let op = match self.peek() {
            TokenKind::Eq => Some(BinOp::Eq),
            TokenKind::Neq => Some(BinOp::Neq),
            TokenKind::Lt => Some(BinOp::Lt),
            TokenKind::Gt => Some(BinOp::Gt),
            TokenKind::Lte => Some(BinOp::Lte),
            TokenKind::Gte => Some(BinOp::Gte),
            _ => None,
        };
        if let Some(op) = op {
            self.pos += 1;
            let right = self.parse_addition();
            return Expr::BinaryOp {
                op,
                left: Box::new(node),
                right: Box::new(right),
            };
        }
        node
    }

    /// addition = multiplication (('+' | '-') multiplication)*
    fn parse_addition(&mut self) -> Expr {
        let mut node = self.parse_multiplication();
        loop {
            let op = match self.peek() {
                TokenKind::Plus => Some(BinOp::Add),
                TokenKind::Minus => Some(BinOp::Sub),
                _ => None,
            };
            if let Some(op) = op {
                self.pos += 1;
                let right = self.parse_multiplication();
                node = Expr::BinaryOp {
                    op,
                    left: Box::new(node),
                    right: Box::new(right),
                };
            } else {
                break;
            }
        }
        node
    }

    /// multiplication = primary (('*' | '/') primary)*
    fn parse_multiplication(&mut self) -> Expr {
        let mut node = self.parse_primary();
        loop {
            let op = match self.peek() {
                TokenKind::Star => Some(BinOp::Mul),
                TokenKind::Slash => Some(BinOp::Div),
                _ => None,
            };
            if let Some(op) = op {
                self.pos += 1;
                let right = self.parse_primary();
                node = Expr::BinaryOp {
                    op,
                    left: Box::new(node),
                    right: Box::new(right),
                };
            } else {
                break;
            }
        }
        node
    }

    /// primary = atom accessor*
    ///
    /// accessor = '.' IDENT | '.' NUMBER | '[' sequence ']' | '(' args ')'
    fn parse_primary(&mut self) -> Expr {
        let mut node = self.parse_atom();
        loop {
            if matches!(self.peek(), TokenKind::Dot) {
                self.pos += 1;
                match self.peek().clone() {
                    TokenKind::Ident(name) => {
                        self.pos += 1;
                        node = self.extend_or_dot(node, name);
                    }
                    // Allow keywords as property names after dot
                    TokenKind::True => {
                        self.pos += 1;
                        node = self.extend_or_dot(node, "true".to_string());
                    }
                    TokenKind::False => {
                        self.pos += 1;
                        node = self.extend_or_dot(node, "false".to_string());
                    }
                    TokenKind::Null => {
                        self.pos += 1;
                        node = self.extend_or_dot(node, "null".to_string());
                    }
                    TokenKind::Not => {
                        self.pos += 1;
                        node = self.extend_or_dot(node, "not".to_string());
                    }
                    TokenKind::And => {
                        self.pos += 1;
                        node = self.extend_or_dot(node, "and".to_string());
                    }
                    TokenKind::Or => {
                        self.pos += 1;
                        node = self.extend_or_dot(node, "or".to_string());
                    }
                    TokenKind::In => {
                        self.pos += 1;
                        node = self.extend_or_dot(node, "in".to_string());
                    }
                    TokenKind::Number(n) => {
                        // Integer index after dot (e.g. list.0)
                        self.pos += 1;
                        let seg = format!("{}", n as i64);
                        node = self.extend_or_dot(node, seg);
                    }
                    _ => break, // unexpected token after dot
                }
            } else if matches!(self.peek(), TokenKind::LBracket) {
                self.pos += 1;
                let index_expr = self.parse_sequence();
                self.expect(&TokenKind::RBracket);
                node = Expr::IndexAccess {
                    obj: Box::new(node),
                    index: Box::new(index_expr),
                };
            } else if matches!(self.peek(), TokenKind::LParen) {
                // Function application: expr(args)
                self.pos += 1;
                let mut args = Vec::new();
                if !matches!(self.peek(), TokenKind::RParen) {
                    args.push(self.parse_sequence());
                    while matches!(self.peek(), TokenKind::Comma) {
                        self.pos += 1;
                        args.push(self.parse_sequence());
                    }
                }
                self.expect(&TokenKind::RParen);
                // If node is a Path with one segment, use FuncCall for compat
                if let Expr::Path(ref segs) = node {
                    if segs.len() == 1 {
                        node = Expr::FuncCall {
                            name: segs[0].clone(),
                            args,
                        };
                        continue;
                    }
                }
                // General application: first arg is the callee
                let mut apply_args = vec![node];
                apply_args.extend(args);
                node = Expr::FuncCall {
                    name: "__apply__".to_string(),
                    args: apply_args,
                };
            } else {
                break;
            }
        }
        node
    }

    /// If node is a Path, extend it; otherwise create a DotAccess.
    fn extend_or_dot(&self, node: Expr, member: String) -> Expr {
        if let Expr::Path(mut segs) = node {
            segs.push(member);
            Expr::Path(segs)
        } else {
            Expr::DotAccess {
                obj: Box::new(node),
                member,
            }
        }
    }

    /// atom = 'fun' ... | IDENT | literal | '(' sequence ')' | '[' ... ']'
    fn parse_atom(&mut self) -> Expr {
        match self.peek().clone() {
            // Lambda: fun x -> body | fun (params) -> body | fun () -> body
            TokenKind::Fun => {
                self.pos += 1;
                let mut params = Vec::new();
                if matches!(self.peek(), TokenKind::LParen) {
                    self.pos += 1;
                    if !matches!(self.peek(), TokenKind::RParen) {
                        if let TokenKind::Ident(name) = self.advance_clone() {
                            params.push(name);
                        }
                        while matches!(self.peek(), TokenKind::Comma) {
                            self.pos += 1;
                            if let TokenKind::Ident(name) = self.advance_clone() {
                                params.push(name);
                            }
                        }
                    }
                    self.expect(&TokenKind::RParen);
                } else if let TokenKind::Ident(_) = self.peek().clone() {
                    // Unary lambda without parens: fun x -> body
                    if let TokenKind::Ident(name) = self.advance_clone() {
                        params.push(name);
                    }
                }
                self.expect(&TokenKind::Arrow);
                let body = self.parse_sequence();
                Expr::Lambda {
                    params,
                    body: Box::new(body),
                }
            }

            TokenKind::Ident(name) => {
                self.pos += 1;
                Expr::Path(vec![name])
            }

            TokenKind::Number(n) => {
                self.pos += 1;
                Expr::Literal(LiteralKind::Number(n))
            }

            TokenKind::Str(s) => {
                self.pos += 1;
                Expr::Literal(LiteralKind::Str(s))
            }

            TokenKind::Color(c) => {
                self.pos += 1;
                Expr::Literal(LiteralKind::Color(c))
            }

            TokenKind::True => {
                self.pos += 1;
                Expr::Literal(LiteralKind::Bool(true))
            }

            TokenKind::False => {
                self.pos += 1;
                Expr::Literal(LiteralKind::Bool(false))
            }

            TokenKind::Null => {
                self.pos += 1;
                Expr::Literal(LiteralKind::Null)
            }

            TokenKind::LParen => {
                self.pos += 1;
                let node = self.parse_sequence();
                self.expect(&TokenKind::RParen);
                node
            }

            // List literal: [expr, expr, ...]
            TokenKind::LBracket => {
                self.pos += 1;
                let mut items = Vec::new();
                if !matches!(self.peek(), TokenKind::RBracket) {
                    items.push(self.parse_sequence());
                    while matches!(self.peek(), TokenKind::Comma) {
                        self.pos += 1;
                        items.push(self.parse_sequence());
                    }
                }
                self.expect(&TokenKind::RBracket);
                Expr::Literal(LiteralKind::List(items))
            }

            _ => {
                // Unexpected token -- return null literal as fallback.
                Expr::Literal(LiteralKind::Null)
            }
        }
    }
}

// -- Public API --------------------------------------------------------------

/// Parse an expression string into an AST node. Returns `None` for empty input.
pub fn parse(source: &str) -> Option<Expr> {
    let tokens = tokenize(source);
    let mut parser = Parser::new(tokens);
    parser.parse()
}

// -- Tests -------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_input() {
        assert!(parse("").is_none());
    }

    #[test]
    fn literal_number() {
        let ast = parse("42").unwrap();
        assert_eq!(ast, Expr::Literal(LiteralKind::Number(42.0)));
    }

    #[test]
    fn literal_string() {
        let ast = parse("\"hello\"").unwrap();
        assert_eq!(ast, Expr::Literal(LiteralKind::Str("hello".to_string())));
    }

    #[test]
    fn literal_color() {
        let ast = parse("#ff0000").unwrap();
        assert_eq!(ast, Expr::Literal(LiteralKind::Color("#ff0000".to_string())));
    }

    #[test]
    fn literal_bool_true() {
        let ast = parse("true").unwrap();
        assert_eq!(ast, Expr::Literal(LiteralKind::Bool(true)));
    }

    #[test]
    fn literal_null() {
        let ast = parse("null").unwrap();
        assert_eq!(ast, Expr::Literal(LiteralKind::Null));
    }

    #[test]
    fn simple_path() {
        let ast = parse("state.fill_color").unwrap();
        assert_eq!(
            ast,
            Expr::Path(vec!["state".to_string(), "fill_color".to_string()])
        );
    }

    #[test]
    fn path_with_numeric_index() {
        let ast = parse("panel.colors.0").unwrap();
        assert_eq!(
            ast,
            Expr::Path(vec![
                "panel".to_string(),
                "colors".to_string(),
                "0".to_string()
            ])
        );
    }

    #[test]
    fn function_call_no_args() {
        let ast = parse("foo()").unwrap();
        assert_eq!(
            ast,
            Expr::FuncCall {
                name: "foo".to_string(),
                args: vec![]
            }
        );
    }

    #[test]
    fn function_call_one_arg() {
        let ast = parse("hsb_h(state.color)").unwrap();
        assert_eq!(
            ast,
            Expr::FuncCall {
                name: "hsb_h".to_string(),
                args: vec![Expr::Path(vec![
                    "state".to_string(),
                    "color".to_string()
                ])]
            }
        );
    }

    #[test]
    fn function_call_multi_args() {
        let ast = parse("rgb(255, 0, 128)").unwrap();
        assert_eq!(
            ast,
            Expr::FuncCall {
                name: "rgb".to_string(),
                args: vec![
                    Expr::Literal(LiteralKind::Number(255.0)),
                    Expr::Literal(LiteralKind::Number(0.0)),
                    Expr::Literal(LiteralKind::Number(128.0)),
                ]
            }
        );
    }

    #[test]
    fn comparison_eq() {
        let ast = parse("state.mode == \"fill\"").unwrap();
        assert_eq!(
            ast,
            Expr::BinaryOp {
                op: BinOp::Eq,
                left: Box::new(Expr::Path(vec![
                    "state".to_string(),
                    "mode".to_string()
                ])),
                right: Box::new(Expr::Literal(LiteralKind::Str("fill".to_string()))),
            }
        );
    }

    #[test]
    fn logical_and() {
        let ast = parse("a and b").unwrap();
        assert_eq!(
            ast,
            Expr::LogicalAnd(
                Box::new(Expr::Path(vec!["a".to_string()])),
                Box::new(Expr::Path(vec!["b".to_string()])),
            )
        );
    }

    #[test]
    fn logical_or() {
        let ast = parse("a or b").unwrap();
        assert_eq!(
            ast,
            Expr::LogicalOr(
                Box::new(Expr::Path(vec!["a".to_string()])),
                Box::new(Expr::Path(vec!["b".to_string()])),
            )
        );
    }

    #[test]
    fn unary_not() {
        let ast = parse("not x").unwrap();
        assert_eq!(
            ast,
            Expr::UnaryNot(Box::new(Expr::Path(vec!["x".to_string()])))
        );
    }

    #[test]
    fn unary_minus() {
        let ast = parse("-x").unwrap();
        assert_eq!(
            ast,
            Expr::UnaryMinus(Box::new(Expr::Path(vec!["x".to_string()])))
        );
    }

    #[test]
    fn ternary() {
        let ast = parse("cond ? 1 : 2").unwrap();
        assert_eq!(
            ast,
            Expr::Ternary {
                cond: Box::new(Expr::Path(vec!["cond".to_string()])),
                true_expr: Box::new(Expr::Literal(LiteralKind::Number(1.0))),
                false_expr: Box::new(Expr::Literal(LiteralKind::Number(2.0))),
            }
        );
    }

    #[test]
    fn index_access() {
        let ast = parse("data[key]").unwrap();
        assert_eq!(
            ast,
            Expr::IndexAccess {
                obj: Box::new(Expr::Path(vec!["data".to_string()])),
                index: Box::new(Expr::Path(vec!["key".to_string()])),
            }
        );
    }

    #[test]
    fn dot_access_on_func() {
        let ast = parse("foo().length").unwrap();
        assert_eq!(
            ast,
            Expr::DotAccess {
                obj: Box::new(Expr::FuncCall {
                    name: "foo".to_string(),
                    args: vec![]
                }),
                member: "length".to_string(),
            }
        );
    }

    #[test]
    fn keyword_after_dot() {
        let ast = parse("state.in").unwrap();
        assert_eq!(
            ast,
            Expr::Path(vec!["state".to_string(), "in".to_string()])
        );
    }

    #[test]
    fn parenthesized_expr() {
        let ast = parse("(a or b) and c").unwrap();
        assert_eq!(
            ast,
            Expr::LogicalAnd(
                Box::new(Expr::LogicalOr(
                    Box::new(Expr::Path(vec!["a".to_string()])),
                    Box::new(Expr::Path(vec!["b".to_string()])),
                )),
                Box::new(Expr::Path(vec!["c".to_string()])),
            )
        );
    }

    #[test]
    fn precedence_and_binds_tighter_than_or() {
        // a or b and c  =>  a or (b and c)
        let ast = parse("a or b and c").unwrap();
        assert_eq!(
            ast,
            Expr::LogicalOr(
                Box::new(Expr::Path(vec!["a".to_string()])),
                Box::new(Expr::LogicalAnd(
                    Box::new(Expr::Path(vec!["b".to_string()])),
                    Box::new(Expr::Path(vec!["c".to_string()])),
                )),
            )
        );
    }

    #[test]
    fn nested_ternary() {
        // a ? b ? c : d : e  =>  a ? (b ? c : d) : e
        let ast = parse("a ? b ? c : d : e").unwrap();
        assert_eq!(
            ast,
            Expr::Ternary {
                cond: Box::new(Expr::Path(vec!["a".to_string()])),
                true_expr: Box::new(Expr::Ternary {
                    cond: Box::new(Expr::Path(vec!["b".to_string()])),
                    true_expr: Box::new(Expr::Path(vec!["c".to_string()])),
                    false_expr: Box::new(Expr::Path(vec!["d".to_string()])),
                }),
                false_expr: Box::new(Expr::Path(vec!["e".to_string()])),
            }
        );
    }

    #[test]
    fn addition() {
        let ast = parse("1 + 2").unwrap();
        assert_eq!(
            ast,
            Expr::BinaryOp {
                op: BinOp::Add,
                left: Box::new(Expr::Literal(LiteralKind::Number(1.0))),
                right: Box::new(Expr::Literal(LiteralKind::Number(2.0))),
            }
        );
    }

    #[test]
    fn subtraction() {
        let ast = parse("5 - 3").unwrap();
        assert_eq!(
            ast,
            Expr::BinaryOp {
                op: BinOp::Sub,
                left: Box::new(Expr::Literal(LiteralKind::Number(5.0))),
                right: Box::new(Expr::Literal(LiteralKind::Number(3.0))),
            }
        );
    }

    #[test]
    fn multiplication() {
        let ast = parse("2 * 3").unwrap();
        assert_eq!(
            ast,
            Expr::BinaryOp {
                op: BinOp::Mul,
                left: Box::new(Expr::Literal(LiteralKind::Number(2.0))),
                right: Box::new(Expr::Literal(LiteralKind::Number(3.0))),
            }
        );
    }

    #[test]
    fn division() {
        let ast = parse("10 / 2").unwrap();
        assert_eq!(
            ast,
            Expr::BinaryOp {
                op: BinOp::Div,
                left: Box::new(Expr::Literal(LiteralKind::Number(10.0))),
                right: Box::new(Expr::Literal(LiteralKind::Number(2.0))),
            }
        );
    }

    #[test]
    fn precedence_mul_over_add() {
        // 1 + 2 * 3 => 1 + (2 * 3)
        let ast = parse("1 + 2 * 3").unwrap();
        assert_eq!(
            ast,
            Expr::BinaryOp {
                op: BinOp::Add,
                left: Box::new(Expr::Literal(LiteralKind::Number(1.0))),
                right: Box::new(Expr::BinaryOp {
                    op: BinOp::Mul,
                    left: Box::new(Expr::Literal(LiteralKind::Number(2.0))),
                    right: Box::new(Expr::Literal(LiteralKind::Number(3.0))),
                }),
            }
        );
    }

    #[test]
    fn lambda_unary() {
        let ast = parse("fun x -> x").unwrap();
        assert_eq!(
            ast,
            Expr::Lambda {
                params: vec!["x".to_string()],
                body: Box::new(Expr::Path(vec!["x".to_string()])),
            }
        );
    }

    #[test]
    fn lambda_multi_params() {
        let ast = parse("fun (a, b) -> a").unwrap();
        assert_eq!(
            ast,
            Expr::Lambda {
                params: vec!["a".to_string(), "b".to_string()],
                body: Box::new(Expr::Path(vec!["a".to_string()])),
            }
        );
    }

    #[test]
    fn lambda_no_params() {
        let ast = parse("fun () -> 42").unwrap();
        assert_eq!(
            ast,
            Expr::Lambda {
                params: vec![],
                body: Box::new(Expr::Literal(LiteralKind::Number(42.0))),
            }
        );
    }

    #[test]
    fn let_binding() {
        let ast = parse("let x = 1 in x").unwrap();
        assert_eq!(
            ast,
            Expr::Let {
                name: "x".to_string(),
                value: Box::new(Expr::Literal(LiteralKind::Number(1.0))),
                body: Box::new(Expr::Path(vec!["x".to_string()])),
            }
        );
    }

    #[test]
    fn assign() {
        let ast = parse("x <- 42").unwrap();
        assert_eq!(
            ast,
            Expr::Assign {
                target: "x".to_string(),
                value: Box::new(Expr::Literal(LiteralKind::Number(42.0))),
            }
        );
    }

    #[test]
    fn sequence() {
        let ast = parse("1; 2; 3").unwrap();
        assert_eq!(
            ast,
            Expr::Sequence {
                left: Box::new(Expr::Sequence {
                    left: Box::new(Expr::Literal(LiteralKind::Number(1.0))),
                    right: Box::new(Expr::Literal(LiteralKind::Number(2.0))),
                }),
                right: Box::new(Expr::Literal(LiteralKind::Number(3.0))),
            }
        );
    }

    #[test]
    fn list_literal_empty() {
        let ast = parse("[]").unwrap();
        assert_eq!(ast, Expr::Literal(LiteralKind::List(vec![])));
    }

    #[test]
    fn list_literal() {
        let ast = parse("[1, 2, 3]").unwrap();
        assert_eq!(
            ast,
            Expr::Literal(LiteralKind::List(vec![
                Expr::Literal(LiteralKind::Number(1.0)),
                Expr::Literal(LiteralKind::Number(2.0)),
                Expr::Literal(LiteralKind::Number(3.0)),
            ]))
        );
    }

    #[test]
    fn application_on_expr() {
        // (fun x -> x)(42) => FuncCall { name: "__apply__", args: [Lambda, 42] }
        let ast = parse("(fun x -> x)(42)").unwrap();
        assert_eq!(
            ast,
            Expr::FuncCall {
                name: "__apply__".to_string(),
                args: vec![
                    Expr::Lambda {
                        params: vec!["x".to_string()],
                        body: Box::new(Expr::Path(vec!["x".to_string()])),
                    },
                    Expr::Literal(LiteralKind::Number(42.0)),
                ],
            }
        );
    }

    #[test]
    fn arrow_token() {
        // Verify -> is tokenized correctly
        let tokens = tokenize("fun x -> x");
        assert!(tokens.iter().any(|t| t.kind == TokenKind::Arrow));
    }

    #[test]
    fn larrow_token() {
        // Verify <- is tokenized correctly
        let tokens = tokenize("x <- 5");
        assert!(tokens.iter().any(|t| t.kind == TokenKind::LArrow));
    }
}
