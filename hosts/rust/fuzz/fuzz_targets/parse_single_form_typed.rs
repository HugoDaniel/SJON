//! Typed fuzz target for `sjon_subset::parse_single_form`. Sibling to
//! `parse_single_form.rs` — that target feeds raw bytes through
//! `std::str::from_utf8` and discards non-UTF-8 inputs, which means
//! libfuzzer spends most of its budget rediscovering "must be UTF-8"
//! instead of exploring lexer state. This target sidesteps that gate
//! by generating tokens directly via the `arbitrary` crate: every
//! `Vec<Token>` always renders into a valid `String`, so 100% of the
//! corpus reaches the parser.
//!
//! The two targets are deliberately kept side-by-side. Raw-byte fuzzing
//! still has unique value (boundary cases around multi-byte UTF-8
//! sequences, BOMs in odd positions, isolated continuation bytes the
//! grammar wouldn't naturally produce). Typed fuzzing exercises the
//! grammar surface itself — kvpair `:`, line-comment `;`, nested
//! parens/brackets, escape sequences.
//!
//! Run with:
//!
//!   cd hosts/rust && cargo +nightly fuzz run parse_single_form_typed -- -max_total_time=60

#![no_main]

use arbitrary::Arbitrary;
use libfuzzer_sys::fuzz_target;

/// Curated set of multi-byte code points covering 2/3/4-byte UTF-8
/// lengths plus a BOM and an RTL marker. These specifically exercise
/// the `Lexer.read_symbol` / `parse_string` paths where byte indices
/// and `char` boundaries diverge.
#[derive(Arbitrary, Debug)]
enum MbChar {
    LatinAccent, // é — 2 bytes
    Cjk,         // 中 — 3 bytes
    Emoji,       // 🦀 — 4 bytes
    Bom,         // U+FEFF — 3 bytes
    Rtl,         // U+200F — 3 bytes
}

impl MbChar {
    fn as_str(&self) -> &'static str {
        match self {
            Self::LatinAccent => "é",
            Self::Cjk => "中",
            Self::Emoji => "🦀",
            Self::Bom => "\u{FEFF}",
            Self::Rtl => "\u{200F}",
        }
    }
}

/// One token in the synthesized SJON source. Every variant maps to a
/// byte sequence that's already valid UTF-8, so the rendered string
/// never gets rejected upstream of the parser.
#[derive(Arbitrary, Debug)]
enum Token {
    OpenParen,
    CloseParen,
    OpenBracket,
    CloseBracket,
    Colon,
    Semicolon,
    Quote,
    Backslash,
    EscapeN,
    EscapeR,
    EscapeT,
    Space,
    Newline,
    Letter(u8),
    Digit(u8),
    MultiByte(MbChar),
}

const MAX_RENDER_BYTES: usize = 4096;

fn render(tokens: &[Token]) -> String {
    let mut out = String::new();
    for tok in tokens {
        if out.len() >= MAX_RENDER_BYTES {
            break;
        }
        match tok {
            Token::OpenParen => out.push('('),
            Token::CloseParen => out.push(')'),
            Token::OpenBracket => out.push('['),
            Token::CloseBracket => out.push(']'),
            Token::Colon => out.push(':'),
            Token::Semicolon => out.push(';'),
            Token::Quote => out.push('"'),
            Token::Backslash => out.push('\\'),
            Token::EscapeN => out.push('n'),
            Token::EscapeR => out.push('r'),
            Token::EscapeT => out.push('t'),
            Token::Space => out.push(' '),
            Token::Newline => out.push('\n'),
            Token::Letter(b) => out.push((b'a' + (b % 26)) as char),
            Token::Digit(b) => out.push((b'0' + (b % 10)) as char),
            Token::MultiByte(mb) => out.push_str(mb.as_str()),
        }
    }
    out
}

fuzz_target!(|tokens: Vec<Token>| {
    let s = render(&tokens);
    let _ = sjon_host::__fuzz_only::parse_single_form(&s);
});
