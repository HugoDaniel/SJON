# Binary pattern queries in Zig 0.16

Use the native Zig APIs when a consumer needs expression-valued patterns or
repeated queries over one binary payload. These additions do not add WASM
exports or Web/Rust wrapper methods. The released read-only WASM query keeps
the legacy expression-leaf behavior below.

## Choose an entry

All entries take an allocator, schema, window, and seed, and return an owning
`PatternQuery.Result`. Bind it with `var` and `defer result.deinit()`.

| Entries | `(pure <expression-form>)` | Input work per query |
|---|---|---|
| `queryBinary`, `queryBinaryWithBudget` | Silently becomes silence | Stream-compile bytes |
| `queryBinaryWithEnv`, `queryBinaryWithBudgetAndEnv` | Evaluate | Stream-compile, retain bytes/index when leaves need them |
| `queryPreparedBinary`, `queryPreparedBinaryWithEnv` | Evaluate | Compile/walk the prepared tree |
| `queryPreparedBinaryWithBudget`, `queryPreparedBinaryWithBudgetAndEnv` | Evaluate | Compile/walk the prepared tree with caller budget |

The **entry** selects semantics. A null environment on an eval-capable entry
means pattern-local bindings only, not legacy behavior. `cycle`, `tick`, and
`seed` shadow same-named outer bindings. Each query receives its environment
live; changing bindings between queries does not require preparing again.

## Decode once, query many

Save the following as `pattern-consumer.zig` in the repository root and run:

```sh
printf 'pub const plugin_exec = false; pub const wasm_plugin_host = false;\n' > /tmp/sjon-pattern-options.zig
zig test --dep sjon -Mroot=pattern-consumer.zig --dep build_options \
  -Msjon=src/root.zig -Mbuild_options=/tmp/sjon-pattern-options.zig
```

```zig
const std = @import("std");
const sjon = @import("sjon");

test "decode once, query two windows" {
    const gpa = std.testing.allocator;
    var tree = try sjon.parse(gpa, "[bd sn]");
    defer tree.deinit();
    const bytes = try sjon.toBinary(gpa, tree,
        sjon.Binary.ToBinaryOptions.forMode(.compact));
    var prepared = try sjon.prepareBinary(gpa, bytes.data);
    defer prepared.deinit();
    bytes.deinit(); // preparation owns all decoded strings

    const schema = sjon.Schema.Schema.init(&.{
        sjon.plugins.core.plugin, sjon.plugins.pattern.plugin,
    });
    for (0..2) |cycle| {
        const begin: i64 = @as(i64, @intCast(cycle)) * sjon.Pattern.PPC;
        var result = try sjon.PatternQuery.queryPreparedBinary(
            gpa, &prepared, schema,
            sjon.Pattern.Span.init(begin, begin + sjon.Pattern.PPC), 0);
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 2), result.haps.len);
    }
}
```

`sjon.prepareBinary(gpa, bytes)` composes the read-only
`sjon.BinaryDecoder.fromBinary(gpa, bytes, .{})` with
`PatternQuery.PreparedBinary.fromTree(tree)`. The decoder is also available as
its own namespace for consumers that want a tree without the write-side
`Binary` module. The resulting tree is owned and has `.deinit()`.

`PreparedBinary.fromTree` **consumes the tree on success and failure**. Do not
leave a second deferred tree deinit or use the old binding afterward. More
than one root returns `error.MultipleRoots`; zero roots prepares successfully
and every prepared query returns silence. Preparation allocates outside query
budgets: use a bounded allocator if the load itself needs a memory limit.

Prepared queries borrow the prepared object during the call. Results own their
returned data and survive freeing input bytes, environments, and the prepared
object. Keep the prepared tree read-only while sharing it between queries.
There is no compiled-spine cache: each query compiles and walks the tree.

## Failures and compatibility

Three channels remain distinct:

- Malformed wire and resource refusals are typed errors. One-shot binary
  entries return `BinaryError`; preparation decodes first and can also refuse
  multiple roots. Query limits can return `HapBudgetExceeded` or
  `MemoryBudgetExceeded`.
- Static expression defects found by the cycle-zero dry run become diagnostics
  at `[pure]`, and that leaf becomes silence.
- Expression failures in later cycles are counted in `result.dropped`.
  Always inspect diagnostics and drops alongside haps.

Prepared queries inherit tree traversal, diagnostic ordering, and query-budget
accounting. The legacy one-shot path remains frozen: its dry-run ordering can
differ, and its allocation profile can both accept and refuse payloads at
budgets where the tree/prepared paths make a different decision. Compact wire
may lack source spans, so diagnostic parity is checked at `(code, path)`.
Do not use one-shot allocation floors as prepared-query budget promises.

The full decoder retains its existing tail leniency: bytes beyond the decoded
payload are not required to be exhausted. This does not weaken streaming
`BinaryCursor.RootIter`: draining it consumes and validates the flag-set
trailing-comment block. A non-draining evaluator/query does not promise the
same trailing-comment checks as a draining validator.

## Carrying author subtrees during lowering

Lowering hooks execute Zig code and are Zig-only. A hook can read an author's
keyed subtree and carry it into an emitted form without evaluating or rebuilding
it from literals:

```zig
const node = (try input.subtree("value")) orelse return error.HookFailed;
const kvpairs = try arena.alloc(sjon.Lowering.EmittedKvpair, 1);
kvpairs[0] = .{ .key = "value", .value = .{ .carry = node } };
try out.append(arena, .{
    .head = "out",
    .kvpairs = kvpairs,
    .source_form_idx = input.form_idx,
});
```

This is the body of a hook receiving `arena`, `input`, and `out`; the tested
`carryValueHook` in `src/Lowering.zig` supplies the complete example. The node
index belongs to that invocation's input tree. Carry clones tags, spans, and
strings; it is not an originating `.form` checked against `:produces`. The
final forest validates the copy in its destination context. Read the
[plugin model](plugin-model-v1.md) for ownership and provenance rules.
