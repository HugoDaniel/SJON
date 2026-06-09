//! Tiny SJON-subset parser shared by `FilesystemResolver` (project-file
//! + manifest `:name` extraction, runs *before* WASM is loaded) and the
//!   conformance test runner (`expected.sjon` parsing — has to stand
//!   alone of the WASM artifact under test).
//!
//! Same surface as the JS embedded parsers in
//! `hosts/web/createNodeFsResolver.ts` and
//! `hosts/web/test/conformance.test.ts`. Handles forms, kvpairs (greedy
//! `:k v`), vectors, double-quoted strings with `\n`/`\r`/`\t` escapes,
//! bare symbols (numbers fall under this — they're textually compared),
//! line comments (`;`). No block comments, no raw strings, no comments
//! inside nested structures (the project files we walk don't use them).

/// One node in the parsed AST. Matches the JS embedded parser's shape
/// so cross-host fixtures can be diffed structurally.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Node {
    /// `(head child1 child2 …)` — children may include nested forms,
    /// kvpairs, vectors, strings, and symbols.
    Form {
        /// Form head symbol (the first token after `(`).
        head: String,
        /// Direct children, in source order.
        children: Vec<Node>,
    },
    /// `:key value` inside a form. Keys are bare symbols (no `:`);
    /// values are arbitrary nested nodes.
    Kvpair {
        /// Kvpair key (without the leading `:`).
        key: String,
        /// Kvpair value — any node.
        value: Box<Node>,
    },
    /// `[elem1 elem2 …]` — heterogeneous vector of arbitrary nodes.
    Vector {
        /// Vector elements, in source order.
        elements: Vec<Node>,
    },
    /// Double-quoted string literal with `\n` / `\r` / `\t` escapes.
    String(String),
    /// Bare symbol (numbers, identifiers, time literals — anything that
    /// isn't a form, vector, string, or kvpair).
    Symbol(String),
}

/// Parse a single top-level form. Returns `None` on whitespace-/comment-
/// only input. Errors out on a second top-level form or any structural
/// failure — the call sites only ever look at one `(project …)` /
/// `(plugin …)` / `(diagnostics …)` form.
pub fn parse_single_form(source: &str) -> Result<Option<Node>, String> {
    let mut c = Cursor::new(source);
    c.skip_trivia();
    if c.eof() {
        return Ok(None);
    }
    let node = c.parse_node()?;
    if !matches!(node, Node::Form { .. }) {
        return Err("expected a form at top level".into());
    }
    c.skip_trivia();
    if !c.eof() {
        return Err("expected a single top-level form".into());
    }
    Ok(Some(node))
}

/// Parse every top-level form in `source` into a flat vector. Used by
/// `expected.sjon` consumers that accept the optional `(values …)`
/// sibling alongside the required `(diagnostics …)` form. Errors out on
/// any structural failure, but accepts 1..=N top-level forms.
pub fn parse_top_level_forms(source: &str) -> Result<Vec<Node>, String> {
    let mut c = Cursor::new(source);
    let mut out = Vec::new();
    loop {
        c.skip_trivia();
        if c.eof() {
            break;
        }
        let node = c.parse_node()?;
        if !matches!(node, Node::Form { .. }) {
            return Err("expected a form at top level".into());
        }
        out.push(node);
    }
    Ok(out)
}

/// Find the first top-level form whose head matches `head`.
pub fn find_form_by_head<'a>(forms: &'a [Node], head: &str) -> Option<&'a Node> {
    for n in forms {
        if let Node::Form { head: h, .. } = n
            && h == head
        {
            return Some(n);
        }
    }
    None
}

/// Find the first kvpair child whose key matches `key`. Used to pull
/// `:name` out of `(plugin …)` and `:plugins` out of `(project …)`.
pub(crate) fn find_kvpair<'a>(children: &'a [Node], key: &str) -> Option<&'a Node> {
    for child in children {
        if let Node::Kvpair { key: k, value } = child
            && k == key
        {
            return Some(value);
        }
    }
    None
}

/// Bytes that terminate a bare symbol scan in `read_symbol`. Lifts the
/// inline match-arm pattern into a single named slice so the symbol
/// boundary is defined in one place.
const SYMBOL_TERMINATORS: &[u8] = b"()[]\":; \t\n\r";

/// Hard ceiling on `parse_node` recursion. Mirrors the Zig substrate's
/// `Parser.MAX_PARSE_DEPTH`. Without it, a deep `(((…)))` input would
/// blow the host stack via recursive descent before the substrate even
/// sees the bytes — the fuzz target would treat that as a crash.
const MAX_PARSE_DEPTH: usize = 1024;

struct Cursor<'a> {
    src: &'a [u8],
    i: usize,
    depth: usize,
}

impl<'a> Cursor<'a> {
    fn new(s: &'a str) -> Self {
        Cursor {
            src: s.as_bytes(),
            i: 0,
            depth: 0,
        }
    }

    fn eof(&self) -> bool {
        self.i >= self.src.len()
    }

    fn peek(&self) -> u8 {
        self.src[self.i]
    }

    fn skip_trivia(&mut self) {
        while !self.eof() {
            match self.peek() {
                b' ' | b'\t' | b'\n' | b'\r' => self.i += 1,
                b';' => {
                    while !self.eof() && self.peek() != b'\n' {
                        self.i += 1;
                    }
                }
                _ => break,
            }
        }
    }

    fn parse_node(&mut self) -> Result<Node, String> {
        if self.depth >= MAX_PARSE_DEPTH {
            return Err(format!("parse depth exceeded ({MAX_PARSE_DEPTH})"));
        }
        self.depth += 1;
        let result = self.parse_node_inner();
        self.depth -= 1;
        result
    }

    fn parse_node_inner(&mut self) -> Result<Node, String> {
        self.skip_trivia();
        if self.eof() {
            return Err("unexpected end of input".into());
        }
        match self.peek() {
            b'(' => self.parse_form(),
            b'[' => self.parse_vector(),
            b'"' => self.parse_string(),
            b':' => {
                // Bare keyword outside kvpair context — uncommon; surface as
                // a symbol prefixed with `:` (matches the JS parser's
                // fallback so the few synthesized inline path entries
                // round-trip the same shape).
                self.i += 1;
                let key = self.read_symbol();
                Ok(Node::Symbol(format!(":{key}")))
            }
            _ => self.parse_atom(),
        }
    }

    fn parse_form(&mut self) -> Result<Node, String> {
        self.i += 1; // consume '('
        self.skip_trivia();
        let head = self.read_symbol();
        if head.is_empty() {
            return Err("expected form head after `(`".into());
        }
        let mut children: Vec<Node> = Vec::new();
        loop {
            self.skip_trivia();
            if self.eof() {
                return Err("unterminated form".into());
            }
            if self.peek() == b')' {
                self.i += 1;
                return Ok(Node::Form { head, children });
            }
            if self.peek() == b':' {
                self.i += 1;
                let key = self.read_symbol();
                if key.is_empty() {
                    return Err("expected key after `:`".into());
                }
                self.skip_trivia();
                let value = self.parse_node()?;
                children.push(Node::Kvpair {
                    key,
                    value: Box::new(value),
                });
                continue;
            }
            children.push(self.parse_node()?);
        }
    }

    fn parse_vector(&mut self) -> Result<Node, String> {
        self.i += 1; // consume '['
        let mut elements: Vec<Node> = Vec::new();
        loop {
            self.skip_trivia();
            if self.eof() {
                return Err("unterminated vector".into());
            }
            if self.peek() == b']' {
                self.i += 1;
                return Ok(Node::Vector { elements });
            }
            elements.push(self.parse_node()?);
        }
    }

    fn parse_string(&mut self) -> Result<Node, String> {
        self.i += 1; // consume '"'
        let mut out: Vec<u8> = Vec::new();
        while !self.eof() {
            let ch = self.peek();
            if ch == b'"' {
                self.i += 1;
                return String::from_utf8(out)
                    .map(Node::String)
                    .map_err(|_| "invalid UTF-8 in string literal".into());
            }
            if ch == b'\\' {
                self.i += 1;
                if self.eof() {
                    return Err("unterminated string escape".into());
                }
                let esc = self.peek();
                match esc {
                    b'n' => out.push(b'\n'),
                    b'r' => out.push(b'\r'),
                    b't' => out.push(b'\t'),
                    other => out.push(other),
                }
                self.i += 1;
            } else {
                out.push(ch);
                self.i += 1;
            }
        }
        Err("unterminated string".into())
    }

    fn parse_atom(&mut self) -> Result<Node, String> {
        let mut value = self.read_symbol();
        if value.is_empty() {
            if self.eof() {
                return Err("unexpected character `?`".into());
            }
            // Decode the next codepoint for the message — `self.peek() as char`
            // would mojibake multi-byte UTF-8 leaders into Latin-1.
            let ch_msg = std::str::from_utf8(&self.src[self.i..])
                .ok()
                .and_then(|s| s.chars().next())
                .map_or_else(|| format!("\\x{:02x}", self.peek()), |c| c.to_string());
            return Err(format!("unexpected character `{ch_msg}`"));
        }
        // Time-literal continuation: `read_symbol` stops on `:`, so
        // `12:34:56` would decompose into [symbol "12", keyword "34",
        // keyword "56"] without this peek. The substrate parser
        // recognises the full lexeme as a single `Tag.time` token, so
        // the conformance mini-parser must too.
        if value.len() == 2
            && value.bytes().all(|b| b.is_ascii_digit())
            && !self.eof()
            && self.peek() == b':'
            && let Some(consumed) = self.try_consume_time_tail()
        {
            value.push_str(&consumed);
        }
        Ok(Node::Symbol(value))
    }

    /// Peek at the bytes following the `HH:` trigger; consume them
    /// only when the full `:MM:SS` or `:MM:SS.fff` shape is present.
    /// Returns the consumed slice (including the leading `:`) on
    /// match, `None` on miss — same all-or-nothing rule the substrate
    /// lexer's `matchTimeTail` uses.
    fn try_consume_time_tail(&mut self) -> Option<String> {
        let rest = &self.src[self.i..];
        if rest.len() < 6 {
            return None;
        }
        let bytes = rest;
        if bytes[0] != b':'
            || !bytes[1].is_ascii_digit()
            || !bytes[2].is_ascii_digit()
            || bytes[3] != b':'
            || !bytes[4].is_ascii_digit()
            || !bytes[5].is_ascii_digit()
        {
            return None;
        }
        let mut consumed = 6;
        if rest.len() >= 10
            && bytes[6] == b'.'
            && bytes[7].is_ascii_digit()
            && bytes[8].is_ascii_digit()
            && bytes[9].is_ascii_digit()
        {
            consumed = 10;
        }
        let out = std::str::from_utf8(&rest[..consumed]).ok()?.to_string();
        self.i += consumed;
        Some(out)
    }

    #[allow(clippy::expect_used)]
    fn read_symbol(&mut self) -> String {
        // `start..self.i` is always a UTF-8-boundary-aligned slice of
        // the input `&str`: callers can only enter through a `&str`, so
        // `self.src` is valid UTF-8, and `SYMBOL_TERMINATORS` is all
        // ASCII (every terminator is a single byte at a boundary).
        let start = self.i;
        while !self.eof() && !SYMBOL_TERMINATORS.contains(&self.peek()) {
            self.i += 1;
        }
        std::str::from_utf8(&self.src[start..self.i])
            .expect("invariant: subset input is &str, terminators are ASCII")
            .to_string()
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    #[test]
    fn parses_empty_to_none() {
        assert!(parse_single_form("").unwrap().is_none());
        assert!(
            parse_single_form("  \n; only a comment\n")
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn parses_project_with_plugins_vector() {
        let src = r#"(project :plugins ["a.sjon" "b.sjon"])"#;
        let node = parse_single_form(src).unwrap().expect("got a form");
        let Node::Form { head, children } = node else {
            panic!("expected form");
        };
        assert_eq!(head, "project");
        let plugins = find_kvpair(&children, "plugins").expect("has :plugins kvpair");
        let Node::Vector { elements } = plugins else {
            panic!("expected vector");
        };
        assert_eq!(elements.len(), 2);
        assert!(matches!(&elements[0], Node::String(s) if s == "a.sjon"));
    }

    #[test]
    fn parses_plugin_with_name_symbol() {
        let src = r#"(plugin :name shapes :version "1.0.0")"#;
        let Node::Form { head, children } = parse_single_form(src).unwrap().unwrap() else {
            panic!()
        };
        assert_eq!(head, "plugin");
        let name = find_kvpair(&children, "name").unwrap();
        assert!(matches!(name, Node::Symbol(s) if s == "shapes"));
    }

    #[test]
    fn errors_on_unterminated_form() {
        assert!(parse_single_form("(plugin :name shapes").is_err());
    }

    #[test]
    fn errors_on_two_top_level_forms() {
        assert!(parse_single_form("(a) (b)").is_err());
    }

    #[test]
    fn parses_diagnostics_form_with_path_vector() {
        let src = r"(diagnostics
  (diagnostic :code unknown_form :path [widget name]))";
        let Node::Form { head, children } = parse_single_form(src).unwrap().unwrap() else {
            panic!()
        };
        assert_eq!(head, "diagnostics");
        assert_eq!(children.len(), 1);
        let Node::Form {
            head: inner_head,
            children: inner_kids,
        } = &children[0]
        else {
            panic!()
        };
        assert_eq!(inner_head, "diagnostic");
        let path = find_kvpair(inner_kids, "path").unwrap();
        let Node::Vector { elements } = path else {
            panic!()
        };
        assert_eq!(elements.len(), 2);
    }

    #[test]
    fn parse_top_level_forms_accepts_multiple() {
        let forms =
            parse_top_level_forms("(diagnostics) (values (value :index 0 :result 42))").unwrap();
        assert_eq!(forms.len(), 2);
        let diag = find_form_by_head(&forms, "diagnostics").expect("has diagnostics");
        assert!(matches!(diag, Node::Form { head, .. } if head == "diagnostics"));
        let values = find_form_by_head(&forms, "values").expect("has values");
        assert!(matches!(values, Node::Form { head, .. } if head == "values"));
    }

    #[test]
    fn parse_top_level_forms_accepts_empty() {
        let forms = parse_top_level_forms("; comment only\n").unwrap();
        assert!(forms.is_empty());
    }

    #[test]
    fn deep_nesting_hits_depth_ceiling_without_stack_overflow() {
        // Wrap a value in `[]` `MAX_PARSE_DEPTH + 10` deep; each level
        // recurses through `parse_node` once. Without the ceiling this
        // would blow the host stack; with it, the parser cleanly
        // returns a depth error.
        let depth = MAX_PARSE_DEPTH + 10;
        // Outer form has a head + one nested-vector child; each `[`
        // is one more level of `parse_node` recursion.
        let mut src = String::with_capacity(depth * 2 + 8);
        src.push_str("(top ");
        for _ in 0..depth {
            src.push('[');
        }
        src.push('x');
        for _ in 0..depth {
            src.push(']');
        }
        src.push(')');
        let err = parse_single_form(&src).unwrap_err();
        assert!(
            err.contains("parse depth exceeded"),
            "expected depth error, got: {err}"
        );
    }

    #[test]
    fn parses_multibyte_utf8_string_literal() {
        // Round-trips multi-byte UTF-8 (é = 0xC3 0xA9, → = 0xE2 0x86 0x92).
        // The pre-fix accumulator (`out.push(byte as char)`) would split
        // each leader byte into a Latin-1 codepoint and mojibake.
        let src = r#"(meta :label "é→ ok")"#;
        let Node::Form { children, .. } = parse_single_form(src).unwrap().unwrap() else {
            panic!("expected form")
        };
        let label = find_kvpair(&children, "label").unwrap();
        assert!(matches!(label, Node::String(s) if s == "é→ ok"));
    }
}
