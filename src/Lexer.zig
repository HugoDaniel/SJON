//! SJON Lexer.
//!
//! Single-pass labeled-switch state machine over a sentinel-terminated
//! `[:0]const u8` source. Emits `Token { tag, start, end }`, never allocates.
//!
//! Invariants:
//!   * `source.len == 0 or source[source.len] == 0` (sentinel-terminated).
//!     The parser's `Parser.parse` upholds this contract for callers.
//!   * **Never allocates.** No `Allocator` parameter, no `try`. The token
//!     stream is produced directly off the source slice.
//!   * **Never aborts.** Any unclassifiable byte yields `.invalid`; the
//!     parser owns the diagnostic. There is no panic path on bad input.
//!   * **Forward-only index.** `self.index` only increases; once a byte is
//!     consumed the lexer never re-reads it.
//!   * **Steady-state EOF.** After the source is exhausted, `next` returns
//!     `.eof` with `start == end == source.len` indefinitely. Calling
//!     `next` past EOF is safe.
//!   * **end ≥ start** for every emitted token. The parser relies on this.
//!
//! Token kinds:
//!   `(` `)` `[` `]`
//!   `:keyword` — `:`-prefixed identifier (`:foo`, `:p+s`)
//!   number — integer or float, optional leading `-`, optional `e[±]NN`,
//!            optional unit suffix (one or more ASCII letters, or a single
//!            `%`). Examples: `4b`, `90deg`, `50%`, `250ms`, `1.5e2hz`.
//!            `e` / `E` is exponent only when the next char is digit / sign;
//!            otherwise it starts the unit (so `1em` lexes as one token).
//!   string — double-quoted with `\n \t \r \" \\ \u{NNNN}` escapes
//!   raw_string — triple-quoted `"""…"""`, body taken verbatim (no escape
//!                processing, no newline stripping, no dedent). Backslash
//!                and single `"` are literal; only three consecutive `"`
//!                close the token. Decoded value is exactly the bytes
//!                between the delimiters (`lexeme[3..len-3]`). Used for
//!                embedding multi-line payloads (shader code, templates)
//!                without escape-quoting.
//!   symbol — identifier OR operator-like; recognized literals
//!            `true` / `false` / `nil` are returned with their own tags.
//!            `#` is a continuation-only char (not a starter): inside a
//!            symbol body it joins (`C#4`, `F#m`); at token start it
//!            opens a block comment.
//!   `; …\n` — line comment (emitted; consumer chooses to keep/drop)
//!   `#| … |#` — block comment (nesting NOT supported in v0.1)
//!   `eof`
//!   `invalid` — any byte the lexer cannot classify; the parser owns the
//!               diagnostic. Lexer never aborts.
//!
//! Whitespace is skipped silently. Position reporting is byte-offset based;
//! consumers compute (line, col) on demand from spans.

const std = @import("std");

const Lexer = @This();

source: [:0]const u8,
index: u32,

/// One token produced by the lexer. `start` / `end` are byte offsets into
/// the source string; `tag` is the token kind.
///
/// Value type — passed by copy through every parser frame. Holds no
/// pointers; the `slice` helper recovers the source bytes by re-slicing
/// the caller's `source`, so a token can outlive the lexer instance
/// but not the source buffer it indexes.
pub const Token = struct {
    tag: Tag,
    start: u32,
    end: u32,

    /// Token kind. Internal discriminator — wire-stable within a Zig
    /// build but never serialized; the binary IR uses `Ast.Tag` (with
    /// its own stable variant ordering) instead.
    pub const Tag = enum(u8) {
        lparen,
        rparen,
        lbracket,
        rbracket,
        keyword,
        symbol,
        number,
        /// Calendar-date literal: exactly `YYYY-MM-DD` (10 ASCII chars,
        /// strict ISO 8601). Recognised via bounded lookahead from the
        /// `.number_int` state so it doesn't collide with arithmetic
        /// `1900-1899`. Parser interprets the lexeme via `Date.parse`
        /// and emits component-specific diagnostics on out-of-range
        /// values (year / month / day).
        date,
        /// Clock-time literal: `HH:MM:SS` (8 chars) or `HH:MM:SS.fff`
        /// (12 chars, exactly 3 fractional digits). Recognised via
        /// bounded lookahead from the `.number_int` state when `:`
        /// follows exactly two ASCII digits. Parser interprets the
        /// lexeme via `Time.parse` and emits component-specific
        /// diagnostics on out-of-range values (hour / minute / second).
        time,
        string,
        raw_string,
        true_lit,
        false_lit,
        nil_lit,
        comment_line,
        comment_block,
        invalid,
        eof,
    };

    /// Borrow the source bytes covered by this token. Returned slice
    /// aliases `source[self.start..self.end]` — no allocation, no
    /// copy. Valid for as long as `source` itself is.
    /// Complexity: O(1).
    pub fn slice(self: Token, source: [:0]const u8) []const u8 {
        return source[self.start..self.end];
    }
};

comptime {
    // `Token` is passed by value through every parser frame; pin its size
    // and discriminator size so a stdlib alignment change can't silently
    // bloat the parser's hot path.
    std.debug.assert(@sizeOf(Token.Tag) == 1);
    std.debug.assert(@sizeOf(Token) == 12);
}

/// Construct a lexer over `source`. The source must be sentinel-terminated
/// (`source.len == 0 or source[source.len] == 0`); the parser's
/// `Parser.parse` upholds this contract.
///
/// The returned `Lexer` borrows `source` — it must outlive the lexer.
/// No allocation. Complexity: O(1).
pub fn init(source: [:0]const u8) Lexer {
    // The `[:0]const u8` type guarantees this at compile time, but a
    // caller bypassing the type system (e.g. through @ptrCast) would
    // crash deep inside the `.start` switch on the missing sentinel.
    // Assert here so the wiring bug surfaces at the source.
    std.debug.assert(source.len == 0 or source[source.len] == 0);
    // Skip a leading UTF-8 BOM. It is an encoding marker, not content:
    // SJON is UTF-8 only, so the bytes carry no information, and every
    // editor that writes one writes it without being asked. Left in, they
    // lex as three separate invalid bytes and the file opens with three
    // `unspecified` diagnostics pointing at nothing an author can see.
    //
    // This is also the only spelling under which the four hosts agree.
    // The two TypeScript hosts read a document through a UTF-8 decoder,
    // which drops the BOM before the parser is reached — so a byte-
    // oriented lexer that kept it made the reference reject documents a
    // shipped host accepted silently. `conformance/cases/encoding-bom`
    // pins the agreement.
    //
    // Only at offset 0, and `index` moves rather than the slice, so every
    // span stays an absolute offset into the caller's bytes — an editor
    // mapping a diagnostic back to the file is unaffected.
    const bom = "\xEF\xBB\xBF";
    const start: u32 = if (std.mem.startsWith(u8, source, bom)) @intCast(bom.len) else 0;
    return .{ .source = source, .index = start };
}

/// State labels for the labeled-switch tokenizer.
const State = enum {
    start,
    minus,
    number_int,
    number_dot,
    number_frac,
    number_exp_sign,
    /// Just consumed an exponent sign (`+`/`-`); the next char MUST be a
    /// digit. Splits out from `.number_exp` so a unit suffix cannot follow
    /// a sign without intervening digits (`1e+x` stays invalid).
    number_exp_first_digit,
    number_exp,
    /// Accumulating a unit suffix after the numeric portion. Entered from
    /// `.number_int`, `.number_dot`, `.number_frac`, or `.number_exp` when
    /// the next char is an ASCII letter; consumes letters until a non-letter
    /// terminates the token. `%` is handled inline as a one-char unit; it
    /// is not part of this state's loop.
    number_unit,
    string_body,
    string_escape,
    /// Inside `"""…"""`. Body bytes pass through verbatim — no escape
    /// processing. Closes only on three consecutive `"`. Sentinel/EOF
    /// before close yields `.invalid`. Single and double `"` runs are
    /// content; the body is allowed to span any number of lines.
    raw_string_body,
    keyword_body,
    symbol_body,
    comment_line_body,
    block_hash,
    block_body,
    block_pipe,
};

/// Return the next token. Sentinel reaches a steady-state `.eof` after the
/// source is exhausted; calling `next` past EOF keeps returning `.eof`.
///
/// Complexity: amortised O(1) per call; worst case O(token-length) for
/// multi-character lexemes (strings, raw strings, numbers, comments).
/// Across a full parse, total work is O(source.len) — each byte is
/// visited at most once. Never allocates, never returns an error: bad
/// input becomes `.invalid` and the parser owns the diagnostic.
pub fn next(self: *Lexer) Token {
    // Forward-only scan: `self.index` advances or stays at `source.len`
    // (sentinel position). Out-of-range index would dereference past
    // the sentinel byte in the labeled-switch dispatch below.
    std.debug.assert(self.index <= self.source.len);
    var start: u32 = self.index;
    state: switch (State.start) {
        .start => {
            switch (self.source[self.index]) {
                0 => {
                    if (self.index == self.source.len) {
                        return mk(.eof, self.index, self.index);
                    }
                    self.index += 1;
                    return mk(.invalid, start, self.index);
                },
                ' ', '\t', '\r', '\n' => {
                    self.index += 1;
                    start = self.index;
                    continue :state .start;
                },
                '(' => {
                    self.index += 1;
                    return mk(.lparen, start, self.index);
                },
                ')' => {
                    self.index += 1;
                    return mk(.rparen, start, self.index);
                },
                '[' => {
                    self.index += 1;
                    return mk(.lbracket, start, self.index);
                },
                ']' => {
                    self.index += 1;
                    return mk(.rbracket, start, self.index);
                },
                ';' => {
                    self.index += 1;
                    continue :state .comment_line_body;
                },
                '#' => {
                    self.index += 1;
                    continue :state .block_hash;
                },
                '"' => {
                    self.index += 1;
                    // Triple-quote opener? `"""` enters raw-string mode; any
                    // other shape (including empty `""` and normal `"foo"`)
                    // falls through to the standard escape-aware body. Both
                    // peeks are safe: source is sentinel-terminated, so
                    // `source[index]` and `source[index + 1]` are both in
                    // range when we reach this branch (we just consumed `"`,
                    // so `self.index <= source.len`; at the boundary the
                    // sentinel byte 0 satisfies neither comparison).
                    if (self.source[self.index] == '"' and self.source[self.index + 1] == '"') {
                        self.index += 2;
                        continue :state .raw_string_body;
                    }
                    continue :state .string_body;
                },
                ':' => {
                    self.index += 1;
                    continue :state .keyword_body;
                },
                '-' => {
                    self.index += 1;
                    continue :state .minus;
                },
                '0'...'9' => {
                    self.index += 1;
                    continue :state .number_int;
                },
                'a'...'z', 'A'...'Z', '_', '+', '*', '/', '<', '>', '=', '!', '?', '.', '%', '&', '|', '^', '~', '$', '@' => {
                    self.index += 1;
                    continue :state .symbol_body;
                },
                else => {
                    self.index += 1;
                    return mk(.invalid, start, self.index);
                },
            }
        },

        // After a leading `-`. Could be a negative number or part of a symbol
        // like `route-move`. Disambiguate by the next char.
        .minus => {
            switch (self.source[self.index]) {
                '0'...'9' => {
                    self.index += 1;
                    continue :state .number_int;
                },
                else => continue :state .symbol_body,
            }
        },

        .number_int => {
            switch (self.source[self.index]) {
                '0'...'9', '_' => {
                    self.index += 1;
                    continue :state .number_int;
                },
                '.' => {
                    self.index += 1;
                    continue :state .number_dot;
                },
                '-' => {
                    // Date-literal lookahead. Triggers iff exactly 4 ASCII
                    // digits (no `_`, no leading `-`) precede `-`, and the
                    // 5 chars after the `-` match `[0-9][0-9]-[0-9][0-9]`.
                    // The source is sentinel-terminated, so the peek
                    // `source[index + 5]` is safe; the sentinel (`0`) is
                    // not in `'0'..'9'`, so it gates the match naturally.
                    if (matchDateTail(self.source, start, self.index)) {
                        self.index += 6;
                        return mk(.date, start, self.index);
                    }
                    return mk(.number, start, self.index);
                },
                ':' => {
                    // Time-literal lookahead. Triggers iff exactly 2 ASCII
                    // digits precede `:`, and `matchTimeTail` confirms a
                    // valid 8- or 12-char shape. Returns `.match12` for
                    // `HH:MM:SS.fff`, `.match8` for `HH:MM:SS` (also when
                    // a trailing `.` is followed by non-3-digits — the
                    // fractional component is all-or-nothing). `.miss`
                    // falls through to emit the number; the `:` will be
                    // handled by the next dispatch (likely a kwarg-start
                    // error, but that's the parser's problem).
                    switch (matchTimeTail(self.source, start, self.index)) {
                        .match12 => {
                            self.index += 10;
                            return mk(.time, start, self.index);
                        },
                        .match8 => {
                            self.index += 6;
                            return mk(.time, start, self.index);
                        },
                        .miss => return mk(.number, start, self.index),
                    }
                },
                'e', 'E' => {
                    // Lookahead: digit or sign starts an exponent; anything
                    // else (including a letter) starts a unit suffix. The
                    // source is sentinel-terminated so `index + 1` is safe.
                    switch (self.source[self.index + 1]) {
                        '0'...'9', '+', '-' => {
                            self.index += 1;
                            continue :state .number_exp_sign;
                        },
                        else => continue :state .number_unit,
                    }
                },
                'a'...'d', 'f'...'z', 'A'...'D', 'F'...'Z' => continue :state .number_unit,
                '%' => {
                    self.index += 1;
                    return mk(.number, start, self.index);
                },
                else => return mk(.number, start, self.index),
            }
        },

        .number_dot => {
            switch (self.source[self.index]) {
                '0'...'9' => {
                    self.index += 1;
                    continue :state .number_frac;
                },
                // `1.` with nothing fractional — accept as float anyway; the
                // parser can validate stricter shapes later if needed.
                'a'...'z', 'A'...'Z' => continue :state .number_unit,
                '%' => {
                    self.index += 1;
                    return mk(.number, start, self.index);
                },
                else => return mk(.number, start, self.index),
            }
        },

        .number_frac => {
            switch (self.source[self.index]) {
                '0'...'9', '_' => {
                    self.index += 1;
                    continue :state .number_frac;
                },
                'e', 'E' => {
                    switch (self.source[self.index + 1]) {
                        '0'...'9', '+', '-' => {
                            self.index += 1;
                            continue :state .number_exp_sign;
                        },
                        else => continue :state .number_unit,
                    }
                },
                'a'...'d', 'f'...'z', 'A'...'D', 'F'...'Z' => continue :state .number_unit,
                '%' => {
                    self.index += 1;
                    return mk(.number, start, self.index);
                },
                else => return mk(.number, start, self.index),
            }
        },

        .number_exp_sign => {
            switch (self.source[self.index]) {
                '+', '-' => {
                    self.index += 1;
                    continue :state .number_exp_first_digit;
                },
                '0'...'9' => continue :state .number_exp,
                else => return mk(.invalid, start, self.index),
            }
        },

        .number_exp_first_digit => {
            switch (self.source[self.index]) {
                '0'...'9' => continue :state .number_exp,
                else => return mk(.invalid, start, self.index),
            }
        },

        .number_exp => {
            switch (self.source[self.index]) {
                '0'...'9', '_' => {
                    self.index += 1;
                    continue :state .number_exp;
                },
                'a'...'z', 'A'...'Z' => continue :state .number_unit,
                '%' => {
                    self.index += 1;
                    return mk(.number, start, self.index);
                },
                else => return mk(.number, start, self.index),
            }
        },

        .number_unit => {
            switch (self.source[self.index]) {
                'a'...'z', 'A'...'Z' => {
                    self.index += 1;
                    continue :state .number_unit;
                },
                else => return mk(.number, start, self.index),
            }
        },

        // Inside `"..."`. Strings cannot span newlines unescaped — but for
        // simplicity v0.1 accepts any byte and lets the parser reject if it
        // wants to. Sentinel/EOF inside a string -> invalid token.
        .string_body => {
            switch (self.source[self.index]) {
                0 => {
                    if (self.index == self.source.len) {
                        return mk(.invalid, start, self.index);
                    }
                    self.index += 1;
                    continue :state .string_body;
                },
                '"' => {
                    self.index += 1;
                    return mk(.string, start, self.index);
                },
                '\\' => {
                    self.index += 1;
                    continue :state .string_escape;
                },
                else => {
                    self.index += 1;
                    continue :state .string_body;
                },
            }
        },

        .string_escape => {
            switch (self.source[self.index]) {
                0 => return mk(.invalid, start, self.index),
                else => {
                    self.index += 1;
                    continue :state .string_body;
                },
            }
        },

        // Inside `"""…"""`. Raw — no escape processing, every byte is
        // content. The body closes on three consecutive `"`. EOF before
        // close surfaces `.invalid`. Note: the close is greedy, so a
        // body ending in `"` is encoded as one or two `"` followed by
        // the closing `"""` — `""""abc"""` lexes as opener-content-close
        // with body `"abc`.
        .raw_string_body => {
            switch (self.source[self.index]) {
                0 => {
                    if (self.index == self.source.len) {
                        return mk(.invalid, start, self.index);
                    }
                    self.index += 1;
                    continue :state .raw_string_body;
                },
                '"' => {
                    // Need three consecutive `"` to close. The second peek
                    // is safe via short-circuit: if `source[index + 1]` is
                    // not `"` (or is the sentinel), we stop before reading
                    // `index + 2`.
                    if (self.source[self.index + 1] == '"' and self.source[self.index + 2] == '"') {
                        self.index += 3;
                        return mk(.raw_string, start, self.index);
                    }
                    self.index += 1;
                    continue :state .raw_string_body;
                },
                else => {
                    self.index += 1;
                    continue :state .raw_string_body;
                },
            }
        },

        .keyword_body => {
            switch (self.source[self.index]) {
                'a'...'z', 'A'...'Z', '0'...'9', '_', '+', '*', '/', '<', '>', '=', '!', '?', '.', '%', '&', '|', '^', '~', '$', '@', '-' => {
                    self.index += 1;
                    continue :state .keyword_body;
                },
                else => {
                    // `:` alone with nothing after is invalid.
                    if (self.index == start + 1) return mk(.invalid, start, self.index);
                    return mk(.keyword, start, self.index);
                },
            }
        },

        .symbol_body => {
            switch (self.source[self.index]) {
                'a'...'z', 'A'...'Z', '0'...'9', '_', '+', '-', '*', '/', '<', '>', '=', '!', '?', '.', '%', '&', '|', '^', '~', '$', '@', '#' => {
                    self.index += 1;
                    continue :state .symbol_body;
                },
                else => return classifySymbol(self.source, start, self.index),
            }
        },

        .comment_line_body => {
            switch (self.source[self.index]) {
                0 => {
                    if (self.index == self.source.len) return mk(.comment_line, start, self.index);
                    self.index += 1;
                    continue :state .comment_line_body;
                },
                '\n' => {
                    // Don't consume the newline; let .start re-skip it.
                    return mk(.comment_line, start, self.index);
                },
                else => {
                    self.index += 1;
                    continue :state .comment_line_body;
                },
            }
        },

        // After consuming a leading `#`. `#|` opens a block comment;
        // anything else is invalid for v0.1 (the parser owns the diagnostic).
        .block_hash => {
            switch (self.source[self.index]) {
                '|' => {
                    self.index += 1;
                    continue :state .block_body;
                },
                else => return mk(.invalid, start, self.index),
            }
        },

        .block_body => {
            switch (self.source[self.index]) {
                0 => {
                    if (self.index == self.source.len) return mk(.invalid, start, self.index);
                    self.index += 1;
                    continue :state .block_body;
                },
                '|' => {
                    self.index += 1;
                    continue :state .block_pipe;
                },
                else => {
                    self.index += 1;
                    continue :state .block_body;
                },
            }
        },

        .block_pipe => {
            switch (self.source[self.index]) {
                '#' => {
                    self.index += 1;
                    return mk(.comment_block, start, self.index);
                },
                else => continue :state .block_body,
            }
        },
    }
}

inline fn mk(tag: Token.Tag, start: u32, end: u32) Token {
    // Every token spans `[start, end)` with `end >= start`. A reversed
    // span would corrupt downstream consumers (Parser builds spans by
    // copying these, Printer slices the source by them).
    std.debug.assert(end >= start);
    return .{ .tag = tag, .start = start, .end = end };
}

/// Reserved symbol literals that promote a bare symbol to its own token tag.
/// Comptime perfect-hash table — O(1) lookup, no per-call branching.
const reserved_symbols = std.StaticStringMap(Token.Tag).initComptime(.{
    .{ "true", .true_lit },
    .{ "false", .false_lit },
    .{ "nil", .nil_lit },
});

fn classifySymbol(source: []const u8, start: u32, end: u32) Token {
    const tag = reserved_symbols.get(source[start..end]) orelse .symbol;
    return mk(tag, start, end);
}

/// True iff `source[start..cursor]` is exactly four ASCII digits and the
/// six bytes at `source[cursor..cursor + 6]` match `-[0-9][0-9]-[0-9][0-9]`.
/// Pre: `source[cursor] == '-'` (the caller is on the dash that triggered
/// the lookahead). Source is sentinel-terminated, so `cursor + 5` is in
/// range — the sentinel `0` byte is not in `'0'..'9'` and naturally fails
/// the digit comparisons past EOF.
fn matchDateTail(source: [:0]const u8, start: u32, cursor: u32) bool {
    if (cursor - start != 4) return false;
    var i: u32 = start;
    while (i < cursor) : (i += 1) {
        const c = source[i];
        if (c < '0' or c > '9') return false;
    }
    std.debug.assert(source[cursor] == '-');
    if (source[cursor + 1] < '0' or source[cursor + 1] > '9') return false;
    if (source[cursor + 2] < '0' or source[cursor + 2] > '9') return false;
    if (source[cursor + 3] != '-') return false;
    if (source[cursor + 4] < '0' or source[cursor + 4] > '9') return false;
    if (source[cursor + 5] < '0' or source[cursor + 5] > '9') return false;
    return true;
}

/// Outcome of the clock-time lookahead. `.match12` consumes the full
/// `HH:MM:SS.fff` shape; `.match8` consumes the `HH:MM:SS` prefix and
/// leaves any trailing `.X` for the next lex pass; `.miss` declines
/// the trigger entirely so the `:` is handled as a kwarg-start.
const TimeTailMatch = enum { miss, match8, match12 };

/// Match the bytes following a `:` that triggered the time lookahead.
/// Pre: `source[cursor] == ':'`, exactly 2 ASCII digits in
/// `source[start..cursor]`. Returns the kind of match; the caller
/// advances `index` accordingly (6 chars for `.match8`, 10 for
/// `.match12`, 0 for `.miss`). Source is sentinel-terminated, so
/// peeks up to `cursor + 9` are safe — the sentinel `0` byte is not
/// in `'0'..'9'` and naturally fails digit comparisons past EOF.
fn matchTimeTail(source: [:0]const u8, start: u32, cursor: u32) TimeTailMatch {
    if (cursor - start != 2) return .miss;
    if (source[start] < '0' or source[start] > '9') return .miss;
    if (source[start + 1] < '0' or source[start + 1] > '9') return .miss;
    std.debug.assert(source[cursor] == ':');
    // `HH:MM:SS` minimum — peek 6 bytes past the `:`.
    if (source[cursor + 1] < '0' or source[cursor + 1] > '9') return .miss;
    if (source[cursor + 2] < '0' or source[cursor + 2] > '9') return .miss;
    if (source[cursor + 3] != ':') return .miss;
    if (source[cursor + 4] < '0' or source[cursor + 4] > '9') return .miss;
    if (source[cursor + 5] < '0' or source[cursor + 5] > '9') return .miss;
    // Optional `.fff` — all-or-nothing. If `.` is present, the next 3
    // bytes must all be digits; otherwise we fall back to the 8-char
    // match and leave the `.` for the next lex pass.
    if (source[cursor + 6] == '.') {
        if (source[cursor + 7] >= '0' and source[cursor + 7] <= '9' and
            source[cursor + 8] >= '0' and source[cursor + 8] <= '9' and
            source[cursor + 9] >= '0' and source[cursor + 9] <= '9')
        {
            return .match12;
        }
    }
    return .match8;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectTokens(source: [:0]const u8, expected: []const Token.Tag) !void {
    var lex = Lexer.init(source);
    for (expected) |want| {
        const got = lex.next();
        try testing.expectEqual(want, got.tag);
    }
    const final = lex.next();
    try testing.expectEqual(Token.Tag.eof, final.tag);
}

test "empty input yields eof" {
    var lex = Lexer.init("");
    try testing.expectEqual(Token.Tag.eof, lex.next().tag);
}

test "punctuation" {
    try expectTokens("()[]", &.{ .lparen, .rparen, .lbracket, .rbracket });
}

test "whitespace skipped" {
    try expectTokens("  (\n\t)\r\n", &.{ .lparen, .rparen });
}

test "a leading UTF-8 BOM is skipped, and only at offset 0" {
    // Skipped: the document lexes as if the marker were not there.
    try expectTokens("\xEF\xBB\xBF(a)", &.{ .lparen, .symbol, .rparen });
    // Spans stay absolute — the first token starts at byte 3, not byte 0,
    // so an editor mapping a diagnostic back into the file still lands on
    // the right character.
    var lex = Lexer.init("\xEF\xBB\xBF(a)");
    const first = lex.next();
    try std.testing.expectEqual(Token.Tag.lparen, first.tag);
    try std.testing.expectEqual(@as(u32, 3), first.start);
    // Anywhere else it is exactly what it was: three invalid bytes.
    try expectTokens("(a) \xEF\xBB\xBF", &.{ .lparen, .symbol, .rparen, .invalid, .invalid, .invalid });
}

test "literals true false nil" {
    try expectTokens("true false nil", &.{ .true_lit, .false_lit, .nil_lit });
}

test "symbols include operators" {
    try expectTokens("+ - * / mod < <= >= = != and or not", &.{
        .symbol, .symbol, .symbol, .symbol, .symbol, .symbol, .symbol,
        .symbol, .symbol, .symbol, .symbol, .symbol, .symbol,
    });
}

test "negative numbers vs minus symbol" {
    var lex = Lexer.init("-1 -");
    const a = lex.next();
    try testing.expectEqual(Token.Tag.number, a.tag);
    try testing.expectEqualStrings("-1", a.slice("-1 -"));
    const b = lex.next();
    try testing.expectEqual(Token.Tag.symbol, b.tag);
    try testing.expectEqualStrings("-", b.slice("-1 -"));
}

test "numbers: int, float, exponent" {
    try expectTokens("0 42 3.14 -1.5 1e9 -1.5e-10 1_000", &.{
        .number, .number, .number, .number, .number, .number, .number,
    });
}

test "date: lex canonical YYYY-MM-DD" {
    const cases = .{
        "2026-05-19",
        "0001-01-01",
        "9999-12-31",
        "2024-02-29",
    };
    inline for (cases) |c| {
        var lex = Lexer.init(c);
        const t = lex.next();
        try testing.expectEqual(Token.Tag.date, t.tag);
        try testing.expectEqualStrings(c, t.slice(c));
        try testing.expectEqual(Token.Tag.eof, lex.next().tag);
    }
}

test "date: arithmetic-style 1900-1899 stays three tokens" {
    var lex = Lexer.init("1900-1899");
    const a = lex.next();
    try testing.expectEqual(Token.Tag.number, a.tag);
    try testing.expectEqualStrings("1900", a.slice("1900-1899"));
    const b = lex.next();
    try testing.expectEqual(Token.Tag.number, b.tag);
    try testing.expectEqualStrings("-1899", b.slice("1900-1899"));
}

test "date: 2026-5-19 (missing leading zero) is not a date" {
    var lex = Lexer.init("2026-5-19");
    const a = lex.next();
    try testing.expectEqual(Token.Tag.number, a.tag);
    try testing.expectEqualStrings("2026", a.slice("2026-5-19"));
}

test "date: 5-digit year is not a date" {
    var lex = Lexer.init("12345-06-07");
    const a = lex.next();
    try testing.expectEqual(Token.Tag.number, a.tag);
    try testing.expectEqualStrings("12345", a.slice("12345-06-07"));
}

test "date: leading minus blocks date lookahead" {
    var lex = Lexer.init("-2026-05-19");
    const a = lex.next();
    try testing.expectEqual(Token.Tag.number, a.tag);
    try testing.expectEqualStrings("-2026", a.slice("-2026-05-19"));
}

test "date: underscore-bearing year is not a date" {
    var lex = Lexer.init("2_026-05-19");
    const a = lex.next();
    try testing.expectEqual(Token.Tag.number, a.tag);
    try testing.expectEqualStrings("2_026", a.slice("2_026-05-19"));
}

test "date: date inside vector lexes as one token" {
    try expectTokens("[2026-05-19]", &.{ .lbracket, .date, .rbracket });
}

test "date: bad component (2026-13-01) still lexes as a date" {
    var lex = Lexer.init("2026-13-01");
    const t = lex.next();
    try testing.expectEqual(Token.Tag.date, t.tag);
    try testing.expectEqualStrings("2026-13-01", t.slice("2026-13-01"));
}

test "time: lex canonical HH:MM:SS" {
    const cases = .{
        "12:34:56",
        "00:00:00",
        "23:59:59",
        "01:02:03",
    };
    inline for (cases) |c| {
        var lex = Lexer.init(c);
        const t = lex.next();
        try testing.expectEqual(Token.Tag.time, t.tag);
        try testing.expectEqualStrings(c, t.slice(c));
        try testing.expectEqual(Token.Tag.eof, lex.next().tag);
    }
}

test "time: lex canonical HH:MM:SS.fff" {
    const cases = .{
        "12:34:56.789",
        "00:00:00.000",
        "23:59:59.999",
        "01:02:03.004",
    };
    inline for (cases) |c| {
        var lex = Lexer.init(c);
        const t = lex.next();
        try testing.expectEqual(Token.Tag.time, t.tag);
        try testing.expectEqualStrings(c, t.slice(c));
        try testing.expectEqual(Token.Tag.eof, lex.next().tag);
    }
}

test "time: 12:34 (missing seconds) leaves number then kwarg" {
    var lex = Lexer.init("12:34");
    const a = lex.next();
    try testing.expectEqual(Token.Tag.number, a.tag);
    try testing.expectEqualStrings("12", a.slice("12:34"));
    const b = lex.next();
    try testing.expectEqual(Token.Tag.keyword, b.tag);
    try testing.expectEqualStrings(":34", b.slice("12:34"));
}

test "time: 1:34:56 (1-digit hour) is not a time" {
    var lex = Lexer.init("1:34:56");
    const a = lex.next();
    try testing.expectEqual(Token.Tag.number, a.tag);
    try testing.expectEqualStrings("1", a.slice("1:34:56"));
}

test "time: 12:3:56 (1-digit minute) is not a time" {
    var lex = Lexer.init("12:3:56");
    const a = lex.next();
    try testing.expectEqual(Token.Tag.number, a.tag);
    try testing.expectEqualStrings("12", a.slice("12:3:56"));
}

test "time: 123:45:67 (3-digit hour) is not a time" {
    var lex = Lexer.init("123:45:67");
    const a = lex.next();
    try testing.expectEqual(Token.Tag.number, a.tag);
    try testing.expectEqualStrings("123", a.slice("123:45:67"));
}

test "time: fractional must be exactly 3 digits (.1 fails over)" {
    var lex = Lexer.init("12:34:56.1");
    const a = lex.next();
    try testing.expectEqual(Token.Tag.time, a.tag);
    try testing.expectEqualStrings("12:34:56", a.slice("12:34:56.1"));
}

test "time: fractional must be exactly 3 digits (.12 fails over)" {
    var lex = Lexer.init("12:34:56.12");
    const a = lex.next();
    try testing.expectEqual(Token.Tag.time, a.tag);
    try testing.expectEqualStrings("12:34:56", a.slice("12:34:56.12"));
}

test "time: 4 fractional digits stops at 3" {
    var lex = Lexer.init("12:34:56.1234");
    const a = lex.next();
    try testing.expectEqual(Token.Tag.time, a.tag);
    try testing.expectEqualStrings("12:34:56.123", a.slice("12:34:56.1234"));
}

test "time: time inside vector lexes as one token" {
    try expectTokens("[12:34:56]", &.{ .lbracket, .time, .rbracket });
    try expectTokens("[12:34:56.789]", &.{ .lbracket, .time, .rbracket });
}

test "time: bad component (24:00:00) still lexes as a time" {
    var lex = Lexer.init("24:00:00");
    const t = lex.next();
    try testing.expectEqual(Token.Tag.time, t.tag);
    try testing.expectEqualStrings("24:00:00", t.slice("24:00:00"));
}

test "time: 1_2:34:56 (underscore in hour) is not a time" {
    var lex = Lexer.init("1_2:34:56");
    const a = lex.next();
    try testing.expectEqual(Token.Tag.number, a.tag);
    try testing.expectEqualStrings("1_2", a.slice("1_2:34:56"));
}

test "time: lexes after whitespace inside form" {
    try expectTokens("(at 12:34:56 :note \"x\")", &.{
        .lparen, .symbol, .time, .keyword, .string, .rparen,
    });
}

test "numbers with unit suffix" {
    try expectTokens("4b 90deg 50% 250ms", &.{
        .number, .number, .number, .number,
    });
    try expectTokens("-50% 1.5e2hz 0.5em 1_000ms", &.{
        .number, .number, .number, .number,
    });
}

test "unit-suffix span equality" {
    const cases = .{
        .{ "90deg", "90deg" },
        .{ "0.5em", "0.5em" },
        .{ "1.5e2hz", "1.5e2hz" },
        .{ "50%", "50%" },
        .{ "-50%", "-50%" },
        .{ "1_000ms", "1_000ms" },
    };
    inline for (cases) |c| {
        var lex = Lexer.init(c[0]);
        const t = lex.next();
        try testing.expectEqual(Token.Tag.number, t.tag);
        try testing.expectEqualStrings(c[1], t.slice(c[0]));
    }
}

test "unit-suffix vs exponent disambiguation" {
    // `1e9` — pure exponent (no unit).
    {
        var lex = Lexer.init("1e9");
        const t = lex.next();
        try testing.expectEqual(Token.Tag.number, t.tag);
        try testing.expectEqualStrings("1e9", t.slice("1e9"));
    }
    // `1em` — `e` not followed by digit/sign, so the whole `em` is the unit.
    {
        var lex = Lexer.init("1em");
        const t = lex.next();
        try testing.expectEqual(Token.Tag.number, t.tag);
        try testing.expectEqualStrings("1em", t.slice("1em"));
    }
    // `1e9em` — exponent then unit.
    {
        var lex = Lexer.init("1e9em");
        const t = lex.next();
        try testing.expectEqual(Token.Tag.number, t.tag);
        try testing.expectEqualStrings("1e9em", t.slice("1e9em"));
    }
}

test "unit suffix requires no whitespace" {
    // `90 deg` — number then symbol, unchanged from pre-feature.
    try expectTokens("90 deg", &.{ .number, .symbol });
}

test "1e+x is still invalid" {
    // Once the lexer commits to .number_exp_sign it cannot reinterpret;
    // `1e+x` keeps emitting .invalid as before.
    var lex = Lexer.init("1e+x");
    try testing.expectEqual(Token.Tag.invalid, lex.next().tag);
}

test "leading-letter symbol still wins" {
    // `e10` starts with a letter — it's a symbol, not a number.
    var lex = Lexer.init("e10");
    try testing.expectEqual(Token.Tag.symbol, lex.next().tag);
}

test "uppercase exponent disambiguation matches lowercase" {
    // `E` is treated identically to `e` — exponent if followed by digit /
    // sign, unit otherwise. Previously only lowercase had assertions.
    {
        var lex = Lexer.init("1E9");
        const t = lex.next();
        try testing.expectEqual(Token.Tag.number, t.tag);
        try testing.expectEqualStrings("1E9", t.slice("1E9"));
    }
    {
        var lex = Lexer.init("1Em");
        const t = lex.next();
        try testing.expectEqual(Token.Tag.number, t.tag);
        try testing.expectEqualStrings("1Em", t.slice("1Em"));
    }
    {
        var lex = Lexer.init("1E-9em");
        const t = lex.next();
        try testing.expectEqual(Token.Tag.number, t.tag);
        try testing.expectEqualStrings("1E-9em", t.slice("1E-9em"));
    }
}

test "multi-letter and mixed-case units" {
    try expectTokens("1px 2rem 3REM 4PxRem 5dPi", &.{
        .number, .number, .number, .number, .number,
    });
    var lex = Lexer.init("4PxRem");
    const t = lex.next();
    try testing.expectEqualStrings("4PxRem", t.slice("4PxRem"));
}

test "fractional dot followed by unit" {
    // `1.em` — dot with no fractional digit, then unit. The parser may
    // tighten this; the lexer accepts it as a single number token.
    var lex = Lexer.init("1.em");
    const t = lex.next();
    try testing.expectEqual(Token.Tag.number, t.tag);
    try testing.expectEqualStrings("1.em", t.slice("1.em"));
}

test "leading-dot number is symbol, not number" {
    // SJON requires a leading digit; `.5` was always a symbol token. The
    // unit feature must not change that — pin it.
    var lex = Lexer.init(".5em");
    try testing.expectEqual(Token.Tag.symbol, lex.next().tag);
}

test "percent does not chain past one" {
    // `50%%` lexes as `50%` (number) then `%` (symbol). The `%` is part
    // of the symbol char set, so the second `%` is a fresh symbol token.
    try expectTokens("50%%", &.{ .number, .symbol });
}

test "percent after exponent" {
    var lex = Lexer.init("1e2%");
    const t = lex.next();
    try testing.expectEqual(Token.Tag.number, t.tag);
    try testing.expectEqualStrings("1e2%", t.slice("1e2%"));
}

test "adjacent unit-numbers without whitespace" {
    // Documented in docs/DESIGN.md: `90deg5px` lexes as two number tokens.
    // `5px` starts at the boundary because `5` is a digit and the unit
    // state only accepts ASCII letters.
    try expectTokens("90deg5px", &.{ .number, .number });
}

test "zero with unit" {
    var lex = Lexer.init("0% 0.0em 0e0hz");
    try testing.expectEqual(Token.Tag.number, lex.next().tag);
    try testing.expectEqual(Token.Tag.number, lex.next().tag);
    try testing.expectEqual(Token.Tag.number, lex.next().tag);
    try testing.expectEqual(Token.Tag.eof, lex.next().tag);
}

test "underscore-then-letter terminates number cleanly" {
    // `1_000ms` → `1000` value with `ms` unit (already covered).
    // Pin: `1_` (trailing underscore) followed by unit still works.
    var lex = Lexer.init("1_ms");
    const t = lex.next();
    try testing.expectEqual(Token.Tag.number, t.tag);
    try testing.expectEqualStrings("1_ms", t.slice("1_ms"));
}

test "unit token is forward-only — no backtrack across whitespace" {
    // The forward-only invariant in the file header means once a unit
    // begins, whitespace ends it cleanly without rescanning prior bytes.
    var lex = Lexer.init("1deg 2");
    const a = lex.next();
    try testing.expectEqualStrings("1deg", a.slice("1deg 2"));
    const b = lex.next();
    try testing.expectEqualStrings("2", b.slice("1deg 2"));
}

test "number at sentinel terminates without overrun" {
    // The lexer reaches index == source.len after consuming `2px` and
    // emits eof. Pin: no out-of-bounds read on the sentinel byte.
    var lex = Lexer.init("2px");
    try testing.expectEqual(Token.Tag.number, lex.next().tag);
    try testing.expectEqual(Token.Tag.eof, lex.next().tag);
}

test "strings simple and with escape" {
    try expectTokens(
        \\"hello" "with \"quote\"" "tab\tend"
    , &.{ .string, .string, .string });
}

test "keyword tokens" {
    try expectTokens(":foo :p+s :bar-baz", &.{ .keyword, .keyword, .keyword });
    var lex = Lexer.init(":");
    try testing.expectEqual(Token.Tag.invalid, lex.next().tag);
}

test "line comment ends at newline (newline not consumed)" {
    var lex = Lexer.init("; hi\n(");
    const c = lex.next();
    try testing.expectEqual(Token.Tag.comment_line, c.tag);
    try testing.expectEqualStrings("; hi", c.slice("; hi\n("));
    try testing.expectEqual(Token.Tag.lparen, lex.next().tag);
}

test "line comment to eof" {
    try expectTokens("; just a comment", &.{.comment_line});
}

test "block comment" {
    try expectTokens("#| block |# (", &.{ .comment_block, .lparen });
}

test "unterminated block comment is invalid" {
    var lex = Lexer.init("#| no end");
    try testing.expectEqual(Token.Tag.invalid, lex.next().tag);
}

test "unterminated string is invalid" {
    var lex = Lexer.init("\"oops");
    try testing.expectEqual(Token.Tag.invalid, lex.next().tag);
}

test "scene fixture mixed tokens" {
    const src =
        \\(scene :bpm 130
        \\  (canvas :name "main" :zoom (* 2 (b 1))))
    ;
    try expectTokens(src, &.{
        .lparen,  .symbol, .keyword, .number,
        .lparen,  .symbol, .keyword, .string,
        .keyword, .lparen, .symbol,  .number,
        .lparen,  .symbol, .number,  .rparen,
        .rparen,  .rparen, .rparen,
    });
}

test "vector literal" {
    try expectTokens("[[0 0] [1 0] [1 1]]", &.{
        .lbracket, .lbracket, .number,   .number,   .rbracket,
        .lbracket, .number,   .number,   .rbracket, .lbracket,
        .number,   .number,   .rbracket, .rbracket,
    });
}

// ---------------------------------------------------------------------------
// Long-tail edge cases — escapes, sentinel boundaries, reserved-word
// adjacency, sigil chars, and other lesser-trodden corners of the grammar.
// Pinned so a labeled-switch refactor that drops a branch trips immediately.
// ---------------------------------------------------------------------------

test "string: every escape sequence" {
    // Every two-char `\X` escape and one `\u{...}` sequence — the lexer
    // accepts them all uniformly via the `.string_escape` state. The
    // parser owns semantic validation; the lexer just must not abort.
    try expectTokens(
        \\"\n" "\t" "\r" "\\" "\"" "\u{1F600}"
    , &.{ .string, .string, .string, .string, .string, .string });
}

test "string: empty literal" {
    var lex = Lexer.init("\"\"");
    const t = lex.next();
    try testing.expectEqual(Token.Tag.string, t.tag);
    try testing.expectEqualStrings("\"\"", t.slice("\"\""));
}

test "string: backslash before sentinel is invalid" {
    // `.string_escape` reads exactly one byte; if that byte is the
    // sentinel (source.len), it surfaces `.invalid` instead of looping.
    var lex = Lexer.init("\"\\");
    try testing.expectEqual(Token.Tag.invalid, lex.next().tag);
}

test "string: unrecognized escape consumed without abort" {
    // `\q` is not a recognized escape — but the lexer is permissive: it
    // copies the next byte and re-enters .string_body. The parser owns
    // semantic rejection.
    var lex = Lexer.init("\"\\q\"");
    try testing.expectEqual(Token.Tag.string, lex.next().tag);
}

test "string: a raw invalid-UTF-8 byte is content, not an error" {
    // The lexer works on bytes, not codepoints, and nothing downstream
    // validates the encoding — so a stray 0xFF between quotes is simply
    // part of the string. Combined with the deliberate absence of
    // `\u{…}` escapes, raw bytes are the only way to write one, and they
    // survive all the way out through `wasm_common.appendValue` (pinned
    // there, with what that costs a JS consumer).
    var lex = Lexer.init("\"a\xFFb\"");
    const tok = lex.next();
    try testing.expectEqual(Token.Tag.string, tok.tag);
    try testing.expectEqual(Token.Tag.eof, lex.next().tag);
}

test "string: `\\u{...}` malformed shapes are accepted by lexer (parser owns)" {
    // The lexer's `.string_escape` state reads exactly ONE byte after
    // the backslash. Anything past that — the `{` body, the `}`, the
    // hex digits — re-enters `.string_body` and is consumed as content.
    // So `"\u"` (no body), `"\u{}"`, and `"\u{not-hex"` (sentinel) all
    // surface as `.string` (or `.invalid` on truncation). Pin: lexer
    // never aborts on these shapes.
    {
        var lex = Lexer.init("\"\\u\"");
        try testing.expectEqual(Token.Tag.string, lex.next().tag);
    }
    {
        var lex = Lexer.init("\"\\u{}\"");
        try testing.expectEqual(Token.Tag.string, lex.next().tag);
    }
    {
        var lex = Lexer.init("\"\\u{ZZZ}\"");
        try testing.expectEqual(Token.Tag.string, lex.next().tag);
    }
    {
        // Sentinel mid-`\u{...}` body still surfaces as `.invalid`
        // (unterminated string), not panic.
        var lex = Lexer.init("\"\\u{1F60");
        try testing.expectEqual(Token.Tag.invalid, lex.next().tag);
    }
}

test "string: tab and CR are accepted as content bytes" {
    // The lexer doesn't reject literal whitespace inside strings — only
    // the sentinel (EOF mid-string) trips `.invalid`.
    var lex = Lexer.init("\"a\tb\rc\"");
    try testing.expectEqual(Token.Tag.string, lex.next().tag);
}

test "block comment: `|` not followed by `#` continues body" {
    // The `.block_pipe` state falls back to `.block_body` when the byte
    // after `|` is anything but `#`. Pin: `#| a | b |# ` is one comment.
    try expectTokens("#| a | b |#", &.{.comment_block});
}

test "block comment: nested-looking sequence terminates at first |#" {
    // SJON v0.1 does NOT support nested block comments (documented in the
    // file header). `#| #| inner |# x` lexes as one comment terminating
    // at the first `|#`, then a bare symbol `x` — the trailing `|#` of a
    // would-be enclosing comment doesn't apply because the outer comment
    // already closed.
    var lex = Lexer.init("#| #| inner |# x");
    try testing.expectEqual(Token.Tag.comment_block, lex.next().tag);
    try testing.expectEqual(Token.Tag.symbol, lex.next().tag);
    try testing.expectEqual(Token.Tag.eof, lex.next().tag);
}

test "block comment: empty body" {
    try expectTokens("#||#", &.{.comment_block});
}

test "stray `#` not followed by `|` is invalid" {
    // The `.block_hash` state has only `|` as an accept; everything else
    // surfaces `.invalid`. Documented but not previously pinned.
    var lex = Lexer.init("#x");
    try testing.expectEqual(Token.Tag.invalid, lex.next().tag);
}

test "stray `#` at EOF is invalid" {
    var lex = Lexer.init("#");
    try testing.expectEqual(Token.Tag.invalid, lex.next().tag);
}

test "`#` is a symbol-body continuation char (sharp-note spellings)" {
    // `#` at token start dispatches to `.block_hash`, but inside an
    // already-running symbol body it joins. Lets `C#4`, `F#m`, `Bb3`
    // lex as single symbols — needed for MIDI-note enumerations.
    try expectTokens("C#4", &.{.symbol});
    try expectTokens("F#m", &.{.symbol});
    try expectTokens("C#4 D#4", &.{ .symbol, .symbol });

    var lex = Lexer.init("C#4");
    const t = lex.next();
    try testing.expectEqualStrings("C#4", t.slice("C#4"));
}

test "`#` mid-symbol: double-sharp is one token (semantics rejects later)" {
    // `C##4` lexes as a single symbol; the validator rejects unknown
    // members of a closed-`:members` kind. The lexer doesn't gatekeep
    // shape here — it only reports tokens.
    try expectTokens("C##4", &.{.symbol});
}

test "reserved literals don't bleed into longer symbols" {
    // `truefoo`, `falseish`, `nilish` must lex as plain `.symbol` —
    // `classifySymbol` only matches the EXACT three reserved spellings.
    var lex = Lexer.init("truefoo falseish nilish");
    try testing.expectEqual(Token.Tag.symbol, lex.next().tag);
    try testing.expectEqual(Token.Tag.symbol, lex.next().tag);
    try testing.expectEqual(Token.Tag.symbol, lex.next().tag);
}

test "reserved literal as keyword body keeps its keyword tag" {
    // `:true` is a keyword (NOT the boolean literal). Reserved-word
    // promotion only applies to bare-symbol classification.
    var lex = Lexer.init(":true :false :nil");
    try testing.expectEqual(Token.Tag.keyword, lex.next().tag);
    try testing.expectEqual(Token.Tag.keyword, lex.next().tag);
    try testing.expectEqual(Token.Tag.keyword, lex.next().tag);
}

test "double colon `::` lexes as keyword `:` followed by next" {
    // `:` followed by `:` — the inner `:` is not in the keyword body
    // alphabet, so `:` alone becomes invalid (`start + 1 == index`),
    // then `:foo` succeeds. Pin so the keyword body alphabet doesn't
    // accidentally grow `:`.
    var lex = Lexer.init("::foo");
    try testing.expectEqual(Token.Tag.invalid, lex.next().tag);
    try testing.expectEqual(Token.Tag.keyword, lex.next().tag);
}

test "sigil-prefixed symbols: $foo and @bar" {
    // `$` and `@` are in the symbol alphabet — pin them as symbol-body
    // starters, not invalid bytes.
    var lex = Lexer.init("$foo @bar $$baz");
    try testing.expectEqual(Token.Tag.symbol, lex.next().tag);
    try testing.expectEqual(Token.Tag.symbol, lex.next().tag);
    try testing.expectEqual(Token.Tag.symbol, lex.next().tag);
}

test "high-byte (non-ASCII) at start is invalid" {
    // The `.start` state's catch-all branches every non-classified byte
    // to `.invalid`. UTF-8 lead bytes (≥ 0x80) trip this directly — SJON
    // identifiers are ASCII-only by design.
    var lex = Lexer.init("\xC3\xA9foo"); // "éfoo" in UTF-8
    try testing.expectEqual(Token.Tag.invalid, lex.next().tag);
}

test "high-byte inside string body is accepted as content" {
    // In contrast to `.start`, `.string_body`'s default branch consumes
    // any byte that isn't `\\`, `"`, or sentinel — UTF-8 strings are OK.
    var lex = Lexer.init("\"\xC3\xA9\"");
    try testing.expectEqual(Token.Tag.string, lex.next().tag);
}

test "embedded NUL mid-source surfaces as one .invalid" {
    // The Lexer's sentinel check is `index == source.len`. A 0-byte
    // BEFORE that index is content — but the .start handler requires
    // `index == source.len` to emit eof, so it falls into the invalid
    // branch instead. Pin: 0 mid-source is a single invalid byte.
    const src: [:0]const u8 = "a\x00b";
    var lex = Lexer.init(src);
    try testing.expectEqual(Token.Tag.symbol, lex.next().tag); // "a"
    try testing.expectEqual(Token.Tag.invalid, lex.next().tag); // "\x00"
    try testing.expectEqual(Token.Tag.symbol, lex.next().tag); // "b"
}

test "many adjacent punctuation tokens" {
    // No whitespace between any pair of paren/bracket — every byte must
    // emit its own token cleanly without state bleed.
    try expectTokens("()()[][]", &.{
        .lparen,   .rparen,   .lparen,   .rparen,
        .lbracket, .rbracket, .lbracket, .rbracket,
    });
}

test "long symbol with every legal char" {
    // Sanity check that the symbol-body alphabet accepts all documented
    // chars in one token. If any char is dropped from the table, a fresh
    // token would split here. `#` joins the body but cannot start one,
    // so it appears mid-symbol after the leading `a`.
    var lex = Lexer.init("a#_b-c+d*e/f<g>h=i!j?k.l%m&n|o^p~q$r@s0");
    const t = lex.next();
    try testing.expectEqual(Token.Tag.symbol, t.tag);
    try testing.expectEqualStrings(
        "a#_b-c+d*e/f<g>h=i!j?k.l%m&n|o^p~q$r@s0",
        t.slice("a#_b-c+d*e/f<g>h=i!j?k.l%m&n|o^p~q$r@s0"),
    );
}

test "minus then EOF is bare `-` symbol" {
    // `.minus` falls to `.symbol_body` when the next char isn't a digit.
    // Sentinel terminates the symbol body cleanly.
    var lex = Lexer.init("-");
    const t = lex.next();
    try testing.expectEqual(Token.Tag.symbol, t.tag);
    try testing.expectEqualStrings("-", t.slice("-"));
    try testing.expectEqual(Token.Tag.eof, lex.next().tag);
}

test "minus before close-paren stays a symbol, not a number" {
    // Pin: `(- )` and `(-)` both treat `-` as a symbol; the lexer must
    // not look beyond the next byte after `-`.
    try expectTokens("(- )", &.{ .lparen, .symbol, .rparen });
    try expectTokens("(-)", &.{ .lparen, .symbol, .rparen });
}

test "number_dot followed by sentinel terminates as number" {
    // `1.` ends in `.number_dot`; the default branch accepts and returns.
    // Pin no overrun on sentinel.
    var lex = Lexer.init("1.");
    try testing.expectEqual(Token.Tag.number, lex.next().tag);
    try testing.expectEqual(Token.Tag.eof, lex.next().tag);
}

test "number_dot followed by `%` returns number with percent unit" {
    var lex = Lexer.init("1.%");
    const t = lex.next();
    try testing.expectEqual(Token.Tag.number, t.tag);
    try testing.expectEqualStrings("1.%", t.slice("1.%"));
}

test "number_exp_first_digit rejects sign-only sequences" {
    // `1e-` (exponent with sign but no digit) must hit `.invalid`.
    var lex = Lexer.init("1e-");
    try testing.expectEqual(Token.Tag.invalid, lex.next().tag);
}

test "number_exp_first_digit rejects double-sign sequences" {
    // The state machine consumes one sign only — `1e++1` must fail at
    // the second `+` (not a digit).
    var lex = Lexer.init("1e++1");
    try testing.expectEqual(Token.Tag.invalid, lex.next().tag);
}

test "underscore at start of number portion stays in body" {
    // `_` at the start of a top-level identifier is a symbol body char.
    // Pin: `_42` lexes as symbol, not number.
    var lex = Lexer.init("_42");
    try testing.expectEqual(Token.Tag.symbol, lex.next().tag);
}

test "deeply nested parens emit one token per byte" {
    // 100 `(` then 100 `)`. Pure structural sanity — confirms no batching
    // in the punctuation branches and no stack growth in the lexer.
    const src: [:0]const u8 = "((((((((((((((((((((((((((((((((((((((((((((((((((" ++
        "))))))))))))))))))))))))))))))))))))))))))))))))))";
    var lex = Lexer.init(src);
    var lparen_count: u32 = 0;
    var rparen_count: u32 = 0;
    var safety: u32 = 0;
    while (safety < 250) : (safety += 1) {
        const t = lex.next();
        if (t.tag == .eof) break;
        if (t.tag == .lparen) lparen_count += 1;
        if (t.tag == .rparen) rparen_count += 1;
    }
    try testing.expectEqual(@as(u32, 50), lparen_count);
    try testing.expectEqual(@as(u32, 50), rparen_count);
}

test "calling next past eof keeps returning eof" {
    // Steady-state EOF documented in the file header. Pin: 5 extra calls
    // all return eof with start == end == source.len.
    var lex = Lexer.init("x");
    try testing.expectEqual(Token.Tag.symbol, lex.next().tag);
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        const t = lex.next();
        try testing.expectEqual(Token.Tag.eof, t.tag);
        try testing.expectEqual(@as(u32, 1), t.start);
        try testing.expectEqual(@as(u32, 1), t.end);
    }
}

// ---------------------------------------------------------------------------
// Raw multi-line strings — `"""…"""` token, no escape processing.
// ---------------------------------------------------------------------------

test "raw string: empty body" {
    var lex = Lexer.init("\"\"\"\"\"\"");
    const t = lex.next();
    try testing.expectEqual(Token.Tag.raw_string, t.tag);
    try testing.expectEqualStrings("\"\"\"\"\"\"", t.slice("\"\"\"\"\"\""));
    try testing.expectEqual(Token.Tag.eof, lex.next().tag);
}

test "raw string: single-line body" {
    const src: [:0]const u8 = "\"\"\"hello\"\"\"";
    var lex = Lexer.init(src);
    const t = lex.next();
    try testing.expectEqual(Token.Tag.raw_string, t.tag);
    try testing.expectEqualStrings(src, t.slice(src));
}

test "raw string: multi-line body with literal newlines" {
    const src: [:0]const u8 =
        \\"""
        \\@vertex
        \\fn vs() -> vec4f { return vec4f(0); }
        \\"""
    ;
    var lex = Lexer.init(src);
    const t = lex.next();
    try testing.expectEqual(Token.Tag.raw_string, t.tag);
    try testing.expectEqualStrings(src, t.slice(src));
    try testing.expectEqual(Token.Tag.eof, lex.next().tag);
}

test "raw string: backslash is literal (no escape)" {
    // `"""\n"""` is a body with a literal backslash followed by `n`,
    // not a newline. Pin: lexer does NOT enter `.string_escape`.
    const src: [:0]const u8 = "\"\"\"\\n\"\"\"";
    var lex = Lexer.init(src);
    const t = lex.next();
    try testing.expectEqual(Token.Tag.raw_string, t.tag);
    try testing.expectEqualStrings(src, t.slice(src));
}

test "raw string: single quote in body is content" {
    const src: [:0]const u8 = "\"\"\"a \"b\" c\"\"\"";
    var lex = Lexer.init(src);
    const t = lex.next();
    try testing.expectEqual(Token.Tag.raw_string, t.tag);
    try testing.expectEqualStrings(src, t.slice(src));
}

test "raw string: double quote in body is content" {
    // Two consecutive `"` are still content; only three close.
    const src: [:0]const u8 = "\"\"\"a \"\"b\"\"\"";
    var lex = Lexer.init(src);
    const t = lex.next();
    try testing.expectEqual(Token.Tag.raw_string, t.tag);
    try testing.expectEqualStrings(src, t.slice(src));
}

test "raw string: greedy close on body ending in quote" {
    // `""""abc"""` lexes as opener `"""` + body `"abc` + close `"""`.
    // The opener consumes the first three, the body's leading `"` is
    // content, and the trailing three close the token.
    const src: [:0]const u8 = "\"\"\"\"abc\"\"\"";
    var lex = Lexer.init(src);
    const t = lex.next();
    try testing.expectEqual(Token.Tag.raw_string, t.tag);
    try testing.expectEqualStrings(src, t.slice(src));
}

test "raw string: unterminated is invalid" {
    // Opens `"""` then sentinel before close.
    var lex = Lexer.init("\"\"\"oops");
    try testing.expectEqual(Token.Tag.invalid, lex.next().tag);
}

test "raw string: bare `\"\"\"` (no body, no close) is invalid" {
    var lex = Lexer.init("\"\"\"");
    try testing.expectEqual(Token.Tag.invalid, lex.next().tag);
}

test "raw string: opener without close, only two trailing quotes" {
    // `"""ab""` — body `ab""`, sentinel at position 7 → invalid.
    var lex = Lexer.init("\"\"\"ab\"\"");
    try testing.expectEqual(Token.Tag.invalid, lex.next().tag);
}

test "raw string: empty `\"\"` still lexes as standard empty string" {
    // Two quotes is not enough for a raw opener; falls through to
    // `.string_body` which closes immediately on the second `"`.
    var lex = Lexer.init("\"\"");
    const t = lex.next();
    try testing.expectEqual(Token.Tag.string, t.tag);
    try testing.expectEqualStrings("\"\"", t.slice("\"\""));
}

test "raw string: adjacent to other tokens" {
    // No whitespace between a raw string and surrounding tokens.
    const src: [:0]const u8 = "(s\"\"\"x\"\"\")";
    try expectTokens(src, &.{
        .lparen, .symbol, .raw_string, .rparen,
    });
}

test "raw string: containing backtick / hash / sigils that elsewhere matter" {
    // The raw body is a black hole for byte classes the rest of the
    // grammar reserves: `;`, `#|`, `(`, `[`, etc. Pin nothing leaks.
    const src: [:0]const u8 =
        \\"""; not a comment
        \\#| also not |#
        \\( [ : ; etc
        \\"""
    ;
    var lex = Lexer.init(src);
    try testing.expectEqual(Token.Tag.raw_string, lex.next().tag);
    try testing.expectEqual(Token.Tag.eof, lex.next().tag);
}

test "raw string: token size unchanged" {
    // Tag is still u8; new variant doesn't bloat the token. The
    // top-of-file comptime assert pins this, but a fixture-level
    // re-statement here trips a Tag-bloat regression visibly.
    try testing.expectEqual(@as(usize, 1), @sizeOf(Token.Tag));
    try testing.expectEqual(@as(usize, 12), @sizeOf(Token));
}

test "raw string: every byte has end >= start (boundary scan)" {
    // Property pinning across a fixture that mixes raw and regular
    // strings, plus comments and structural tokens — the new state
    // must satisfy the same invariant as every other state.
    const src: [:0]const u8 =
        \\(scene
        \\  :a "regular"
        \\  :b """raw
        \\multi
        \\line"""
        \\  :c "")
    ;
    var lex = Lexer.init(src);
    var safety: u32 = 0;
    while (safety < 200) : (safety += 1) {
        const t = lex.next();
        try testing.expect(t.end >= t.start);
        try testing.expect(t.end <= src.len);
        if (t.tag == .eof) break;
    }
}

test "raw string: UTF-8 multi-byte content passes through verbatim" {
    // Body holds CJK + accented + emoji bytes. The state machine reads
    // one byte at a time and only treats `"` and 0 as significant, so
    // continuation bytes (0x80–0xBF) are content like any other.
    const src: [:0]const u8 = "\"\"\"héllo 你好 🦀\"\"\"";
    var lex = Lexer.init(src);
    const t = lex.next();
    try testing.expectEqual(Token.Tag.raw_string, t.tag);
    try testing.expectEqualStrings(src, t.slice(src));
    try testing.expectEqual(Token.Tag.eof, lex.next().tag);
}

test "raw string: tabs and high-byte content preserved by lexer" {
    // Tabs, vertical tab, form feed, and a high byte (0xFE — invalid
    // UTF-8 lead). The lexer is byte-transparent: anything that isn't a
    // closing `"""` is body.
    const src: [:0]const u8 = "\"\"\"\tA\x0bB\x0cC\xFE\"\"\"";
    var lex = Lexer.init(src);
    const t = lex.next();
    try testing.expectEqual(Token.Tag.raw_string, t.tag);
    try testing.expectEqualStrings(src, t.slice(src));
}

test "raw string: two raw strings in a row, no whitespace between" {
    // Pin: lexer state resets cleanly between adjacent raw tokens.
    // After the first close, the next byte is another `"""` opener —
    // no leftover counter or partial state from the previous token.
    const src: [:0]const u8 = "\"\"\"a\"\"\"\"\"\"b\"\"\"";
    var lex = Lexer.init(src);
    const a = lex.next();
    try testing.expectEqual(Token.Tag.raw_string, a.tag);
    try testing.expectEqualStrings("\"\"\"a\"\"\"", a.slice(src));
    const b = lex.next();
    try testing.expectEqual(Token.Tag.raw_string, b.tag);
    try testing.expectEqualStrings("\"\"\"b\"\"\"", b.slice(src));
    try testing.expectEqual(Token.Tag.eof, lex.next().tag);
}

test "raw string: trailing extra quotes after close start a fresh token" {
    // `"""abc""""""` — the first close consumes the earliest three
    // consecutive `"`, leaving three more that begin a new (unterminated)
    // raw-string opener. Pin both halves so that the greedy-close edge
    // does not silently swallow a malformed neighbour.
    const src: [:0]const u8 = "\"\"\"abc\"\"\"\"\"\"";
    var lex = Lexer.init(src);
    const a = lex.next();
    try testing.expectEqual(Token.Tag.raw_string, a.tag);
    try testing.expectEqualStrings("\"\"\"abc\"\"\"", a.slice(src));
    // The trailing three quotes open a raw string that immediately hits
    // EOF without a body. That surfaces as `.invalid`.
    try testing.expectEqual(Token.Tag.invalid, lex.next().tag);
}

test "raw string: large body (4 KiB of payload) lexes in one token" {
    // Stress the body loop without provoking the close path. Build
    // 4096 bytes of `'x'` between delimiters; the lexer must walk the
    // whole body without claiming `.invalid` or splitting tokens.
    const a = testing.allocator;
    const body_len: usize = 4096;
    const total = body_len + 6; // three `"` on each side
    const buf = try a.allocSentinel(u8, total, 0);
    defer a.free(buf);
    @memcpy(buf[0..3], "\"\"\"");
    @memset(buf[3 .. 3 + body_len], 'x');
    @memcpy(buf[3 + body_len ..][0..3], "\"\"\"");
    var lex = Lexer.init(buf);
    const t = lex.next();
    try testing.expectEqual(Token.Tag.raw_string, t.tag);
    try testing.expectEqual(@as(u32, 0), t.start);
    try testing.expectEqual(@as(u32, @intCast(total)), t.end);
    try testing.expectEqual(Token.Tag.eof, lex.next().tag);
}

test "raw string: token loc spans the full lexeme including delimiters" {
    // The token's [start, end) covers all of `"""…"""`. Downstream
    // consumers slice with `slice(src)` and expect to see the
    // delimiters; the parser decodes via `lexeme[3..len-3]`, so
    // tightening the span here would corrupt the decoded body.
    const src: [:0]const u8 = "  \"\"\"hi\"\"\"  ";
    var lex = Lexer.init(src);
    const t = lex.next();
    try testing.expectEqual(Token.Tag.raw_string, t.tag);
    try testing.expectEqual(@as(u32, 2), t.start);
    // 2 leading spaces + `"""` + `hi` + `"""` = 10.
    try testing.expectEqual(@as(u32, 10), t.end);
    try testing.expectEqualStrings("\"\"\"hi\"\"\"", t.slice(src));
}

test "raw string: NUL byte inside body before close is content, not EOF" {
    // The sentinel-vs-content rule: `0` only terminates when at
    // `source.len`. A NUL inside the buffer (e.g. a binary blob being
    // hand-written into a fixture) advances like any other byte.
    // Constructed via direct buffer because the `\\` heredoc cannot
    // express a NUL inline.
    const a = testing.allocator;
    const buf = try a.allocSentinel(u8, 9, 0);
    defer a.free(buf);
    @memcpy(buf[0..3], "\"\"\"");
    buf[3] = 'a';
    buf[4] = 0;
    buf[5] = 'b';
    @memcpy(buf[6..9], "\"\"\"");
    var lex = Lexer.init(buf);
    const t = lex.next();
    try testing.expectEqual(Token.Tag.raw_string, t.tag);
    try testing.expectEqual(@as(u32, 9), t.end);
}

// ---------------------------------------------------------------------------
// Numeric corners — pin behaviour at boundaries the plan calls out so a
// future tweak to the number / unit state machine surfaces a typed test
// failure rather than silent semantic drift. Every token here is a
// deliberate choice: SJON's grammar is permissive (the parser owns
// numeric semantics), so each case asserts the lexer's actual decision,
// not the *intuitive* one.
// ---------------------------------------------------------------------------

test "leading `+` digits stay one symbol — no implicit number sign" {
    // The `.minus` start-state branch handles `-` specifically (so `-1`
    // becomes a negative number); there is NO symmetric `.plus` branch.
    // `+` enters `.symbol_body`, and digits are symbol-body continuation
    // chars, so `+0` is one symbol token (text `+0`), not symbol then
    // number. Pin so a future symmetry refactor that adds `+` as a
    // number sign is loud and must update this fixture.
    var lex = Lexer.init("+0");
    const t = lex.next();
    try testing.expectEqual(Token.Tag.symbol, t.tag);
    try testing.expectEqualStrings("+0", t.slice("+0"));
    try testing.expectEqual(Token.Tag.eof, lex.next().tag);
}

test "`0x` lexes as number-with-unit, not hex prefix" {
    // SJON has no hex literal grammar; `0x` is a digit-then-letter
    // sequence, which the unit suffix grammar consumes wholesale. The
    // result is one `.number` token spanning `0x` (value 0, unit "x").
    // Pin actual behaviour: the parser will accept the token and
    // interpret it as a unit number — it does NOT reject `0x...` as
    // malformed. A consumer that wants hex must wrap the document.
    var lex = Lexer.init("0x");
    const t = lex.next();
    try testing.expectEqual(Token.Tag.number, t.tag);
    try testing.expectEqualStrings("0x", t.slice("0x"));
    try testing.expectEqual(Token.Tag.eof, lex.next().tag);
}

test "`0xFF` chains into the unit suffix as `xFF`" {
    // Same path as above — once `x` enters `.number_unit`, the loop
    // accepts ASCII letters/digits-after-letters per the unit alphabet.
    // Confirm `0xFF` is still one token, not two.
    var lex = Lexer.init("0xFF");
    const t = lex.next();
    try testing.expectEqual(Token.Tag.number, t.tag);
    try testing.expectEqualStrings("0xFF", t.slice("0xFF"));
}

test "max-finite f64 exponent `1e308` lexes as one number" {
    // The lexer is purely structural — it never converts to f64. Pin
    // that the largest finite-magnitude IEEE-754 exponent is one token
    // so that downstream conversion (`Parser.makeLeaf`) sees a clean
    // number to feed `parseFloat`.
    var lex = Lexer.init("1e308");
    const t = lex.next();
    try testing.expectEqual(Token.Tag.number, t.tag);
    try testing.expectEqualStrings("1e308", t.slice("1e308"));
}

test "16-digit integer at f64 precision boundary lexes as one number" {
    // f64 has 52 mantissa bits → ~15-17 decimal digits of significand.
    // `9999999999999999` (16 nines) sits on the boundary; lex-time it
    // is one number token regardless. Parser-side precision loss is a
    // separate test (see `parse: 16-digit boundary integer`).
    var lex = Lexer.init("9999999999999999");
    const t = lex.next();
    try testing.expectEqual(Token.Tag.number, t.tag);
    try testing.expectEqualStrings("9999999999999999", t.slice("9999999999999999"));
}

test "every token has end >= start" {
    // Property restated as a fixture-level test alongside the fuzz
    // harness. Catches a regression on the canonical inputs without
    // needing to run `zig build fuzz`.
    const src: [:0]const u8 =
        \\(scene :bpm 130 (canvas :name "main" [1 2 3 nil true false]))
        \\; trailing
    ;
    var lex = Lexer.init(src);
    var safety: u32 = 0;
    while (safety < 200) : (safety += 1) {
        const t = lex.next();
        try testing.expect(t.end >= t.start);
        try testing.expect(t.end <= src.len);
        if (t.tag == .eof) break;
    }
}
