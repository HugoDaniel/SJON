const std = @import("std");

const Lexer = @This();

source: [:0]const u8,
index: u32,

pub const Token = struct {
    tag: Tag,
    start: u32,
    end: u32,

    pub const Tag = enum(u8) {
        lparen,
        rparen,
        lbracket,
        rbracket,
        keyword,
        symbol,
        number,
        date,
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

    pub fn slice(self: Token, source: [:0]const u8) []const u8 {
        return source[self.start..self.end];
    }
};

comptime {
    std.debug.assert(@sizeOf(Token.Tag) == 1);
    std.debug.assert(@sizeOf(Token) == 12);
}

pub fn init(source: [:0]const u8) Lexer {
    std.debug.assert(source.len == 0 or source[source.len] == 0);
    return .{ .source = source, .index = 0 };
}

const State = enum {
    start,
    minus,
    number_int,
    number_dot,
    number_frac,
    number_exp_sign,
    number_exp_first_digit,
    number_exp,
    number_unit,
    string_body,
    string_escape,
    raw_string_body,
    keyword_body,
    symbol_body,
    comment_line_body,
    block_hash,
    block_body,
    block_pipe,
};

pub fn next(self: *Lexer) Token {
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
                    if (matchDateTail(self.source, start, self.index)) {
                        self.index += 6;
                        return mk(.date, start, self.index);
                    }
                    return mk(.number, start, self.index);
                },
                ':' => {
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
                    return mk(.comment_line, start, self.index);
                },
                else => {
                    self.index += 1;
                    continue :state .comment_line_body;
                },
            }
        },

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
    std.debug.assert(end >= start);
    return .{ .tag = tag, .start = start, .end = end };
}

const reserved_symbols = std.StaticStringMap(Token.Tag).initComptime(.{
    .{ "true", .true_lit },
    .{ "false", .false_lit },
    .{ "nil", .nil_lit },
});

fn classifySymbol(source: []const u8, start: u32, end: u32) Token {
    const tag = reserved_symbols.get(source[start..end]) orelse .symbol;
    return mk(tag, start, end);
}

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

const TimeTailMatch = enum { miss, match8, match12 };

fn matchTimeTail(source: [:0]const u8, start: u32, cursor: u32) TimeTailMatch {
    if (cursor - start != 2) return .miss;
    if (source[start] < '0' or source[start] > '9') return .miss;
    if (source[start + 1] < '0' or source[start + 1] > '9') return .miss;
    std.debug.assert(source[cursor] == ':');
    if (source[cursor + 1] < '0' or source[cursor + 1] > '9') return .miss;
    if (source[cursor + 2] < '0' or source[cursor + 2] > '9') return .miss;
    if (source[cursor + 3] != ':') return .miss;
    if (source[cursor + 4] < '0' or source[cursor + 4] > '9') return .miss;
    if (source[cursor + 5] < '0' or source[cursor + 5] > '9') return .miss;
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
