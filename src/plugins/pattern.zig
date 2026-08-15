//! Built-in `pattern` plugin — Strudel-style pattern combinators declared as
//! data forms.
//!
//! These `FormSpec`s exist for the **validator** (head recognition + accepting
//! positional children); the actual pattern semantics are executed by the
//! `PatternQuery` walker, not by any `ExprFunc`. This is the same
//! "declared-for-validation, executed-by-walker" split that `core`'s
//! `let` / `if` / `map` use.
//!
//! `positional = .any` because `PositionalSpec` is coarse and can't express
//! the precise per-form arity (`pure` wants exactly one, `fast` a factor + a
//! pattern, …). PatternQuery's compile step enforces arity, emitting the
//! existing `arity_mismatch` code — so adding these forms introduces no new
//! wire surface. Seed only in pattern-query paths, never in the default
//! document schema, so existing conformance is untouched.
//!
//! Declared: `pure` / `silence` / `stack` / `fast` / `slow` / `slowcat` /
//! `cat` (the MVP combinator set) plus `euclid` (Euclidean rhythms).

const Plugin = @import("../Plugin.zig");

/// The built-in `pattern` plugin. Pass it (alongside `core`) to
/// `Schema.init` only on the pattern-query path.
pub const plugin: Plugin.Plugin = .{
    .name = "pattern",
    .forms = &forms,
};

const forms = [_]Plugin.FormSpec{
    .{
        .name = "silence",
        .positional = .none,
        .description = "The empty pattern — queries to no haps.",
    },
    .{
        .name = "pure",
        .positional = .any,
        .description = "(pure v) — one hap per cycle carrying the literal v.",
    },
    .{
        .name = "stack",
        .positional = .any,
        .description = "(stack a b …) — layer patterns; all play together.",
    },
    .{
        .name = "fast",
        .positional = .any,
        .description = "(fast n pat) — play pat n× faster (n× per cycle).",
    },
    .{
        .name = "slow",
        .positional = .any,
        .description = "(slow n pat) — play pat n× slower (one play per n cycles).",
    },
    .{
        .name = "euclid",
        .positional = .any,
        .description = "(euclid n k pat) — pat at the n Bjorklund onsets of k steps; silence elsewhere.",
    },
    .{
        .name = "slowcat",
        .positional = .any,
        .description = "(slowcat a b …) — one child per cycle, round-robin.",
    },
    .{
        .name = "cat",
        .positional = .any,
        .description = "(cat a b …) — alias of slowcat.",
    },
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "pattern plugin declares the combinator heads" {
    try testing.expectEqualStrings("pattern", plugin.name);
    inline for (.{ "silence", "pure", "stack", "fast", "slow", "slowcat", "cat", "euclid" }) |want| {
        var saw = false;
        for (plugin.forms) |f| {
            if (std.mem.eql(u8, f.name, want)) saw = true;
        }
        try testing.expect(saw);
    }
}
