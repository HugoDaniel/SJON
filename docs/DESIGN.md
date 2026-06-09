# SJON design overview

This document captures the architecture as of SJON 1.0, after the SoA AST
migration. It is the standing reference for the module layout, the SoA
tree, and the frozen binary wire format.

## Pipeline

```
                           ┌──────────┐
   text source  ──parse──▶ │   Tree   │ ──print──▶  text
                           │  (SoA)   │
                           └────┬─────┘
                                │
              ┌──── toJson  ────┼────  fromJson  ────┐
              ▼                 ▼                    ▼
         std.json.Value      Validator           std.json.Value
                             diagnostics
              ┌──── toBinary ───┼────  fromBinary  ──┐
              ▼                 ▼                    ▼
            bytes              Expr              bytes
              │             (eval result)            ▲
              │                  ▲                   │
              │                  │                   │
              └─── evalBinary ───┴───────────────────┘
                  (streaming over BinaryCursor — no Tree)
```

`evalBinary` is the **lazy seam**: it walks `bytes` directly via
`BinaryCursor` and produces an `Expr.Value` without ever materialising
a `Tree`. `sjon.evalExprBinary` and `sjon-binary.wasm`'s
`sjon_eval_expr_binary` both route through it.

Every public entrypoint in `src/root.zig` (`sjon.parse`, `sjon.print`,
`sjon.toJson`, `sjon.toBinary`, `sjon.applyEdit`, …) operates on the
canonical SoA `Ast.Tree`. There is one tree representation; phase 14
retired the legacy mutable pointer-tree representation entirely.
`Edit.applyEdit` does a functional rebuild: walk the source tree,
emit unchanged subtrees via `TreeBuilder.cloneNode`, transform at
the edit's path.

## Worked parse trace

To ground the pipeline, here's what happens to the source
`(let [x 2] (+ x 3))` as it flows from text to an `Expr.Value`.
Diagnostics that *could* fire at each stage are listed in the right
column; the happy path emits none.

**1. Lex** (`Lexer.zig`, single-pass labeled-switch). Source bytes →
flat token stream:

```
LPAREN  SYMBOL("let")
LBRACK  SYMBOL("x")  NUMBER(2)  RBRACK
LPAREN  SYMBOL("+")  SYMBOL("x")  NUMBER(3)  RPAREN
RPAREN
```

Potential diagnostics: `unterminated_string`, `bad_number`,
`bad_escape`, `bad_identifier` (none fire here — every token is
well-formed).

**2. Parse** (`Parser.zig`, iterative descent with a heap frame
stack). The token stream becomes an `Ast.Tree`. Nodes are indices
into the SoA arrays:

```
idx 0  form        head="let"       children=[1, 4]
idx 1  vector                       children=[2, 3]
idx 2  symbol      "x"
idx 3  number      2
idx 4  form        head="+"         children=[5, 6]
idx 5  symbol      "x"
idx 6  number      3
```

Tree depth here is 2; the parser's `MAX_PARSE_DEPTH = 1024` ceiling is
nowhere close. Potential diagnostics: `expected_close_paren`,
`expected_close_bracket`, `nesting_too_deep`, `unexpected_root_kvpair`.

**3. Validate** (`Validator.zig`, frame-stack walker). Only fires
when a schema is loaded; for raw safe-expression eval the validator is
skipped. With a schema declaring `let`, the validator would check the
binding-vector shape (length 2, first child symbol) and emit
`wrong_kind` if a literal sat in the binding slot. With no schema,
`unknown_form` would fire on `let`.

**4. Evaluate** (`Expr.zig`, closed-v1 evaluator with explicit frame
stack — `MAX_EVAL_DEPTH = 256`, `MAX_STEPS = 1 << 20`). Frames push as
the walker descends; each frame holds bindings + remaining children.

```
push  Frame(let)        bindings={}                   → walk binding vector
push  Frame(bind x=?)   bind name = "x", value = 2    → bind, pop
      Frame(let)        bindings={x: 2}               → walk body
push  Frame(call "+")   args=[<sym x>, <num 3>]       → resolve args
        resolve "x"     env lookup → 2
        resolve 3       → 3
        apply +(2, 3)   → 5
pop   Frame(call "+")   → 5
pop   Frame(let)        → 5
```

Result: `Expr.Value{ .number = 5 }`. Potential diagnostics:
`expr_unbound_symbol` (if `x` weren't bound), `expr_unknown_function`
(if `+` weren't in the core vocabulary), `expr_arity` (if `+` were
called with the wrong number of args), `expr_kind_mismatch` (if one of
the args were a string), `expr_steps_exceeded` (for runaway recursion).

The same `(let [x 2] (+ x 3))` evaluated via `evalBinary` skips step 2
(no Tree materialised). Step 1 produces tokens; the producer routes
them through `Binary.toBinary` to a byte buffer; `evalBinary` then
walks the buffer with `BinaryCursor` and produces the same
`Expr.Value{ .number = 5 }` via the streaming evaluator described in
`§ Safe-expression evaluator → evalBinary`.

## Modules

| Module                 | Role                                                                          |
|------------------------|-------------------------------------------------------------------------------|
| `Lexer`                | Single-pass labeled-switch tokenizer. `[:0]const u8` → token stream.          |
| `Parser`               | Iterative-descent parser. `parse` → `Ast.Tree` (SoA). Diagnostics carry stable codes + semantic paths. |
| `Ast`                  | Tree types + `TreeBuilder` (incremental SoA construction + cloneNode). Owns the `Diagnostic.Code` enum. |
| `Printer`              | Canonical / lossless emitter. Walks `Ast.Tree`.                               |
| `Json`                 | `Tree ↔ std.json.Value` bridge with a tagged-object encoding.                 |
| `Validator`            | Schema-driven walker producing diagnostics. Tree and Binary paths agree on `(code, path)` for cross-host conformance. `Plugin.ValueKind` grew a `numeric` refinement (range / integrality bounds) wired through `checkNumericBoundsValue`; `MatchExtras` grew a tag-true `numeric: ?NumericValue` so the binary path's exact-int comparison fires too. Later refinements followed the same dual-path pattern: a `repr` GPU-representation tag (`repr_out_of_range`), variable-arity vectors (`VectorShape.min_len`/`max_len` → `vector_too_short`/`vector_too_long`), and a unit `reject` flag (`unit_forbidden`) — each mirrored on the tree + binary walkers and locked by `expect*OnBoth` tests. `scalar-or-ref` needs no validator change: the loader desugars it to an ordinary `union_of`. |
| `Expr`                 | Closed-v1 safe-expression evaluator with an explicit frame stack.             |
| `Edit`                 | JSON-encoded structural-edit reducer (functional rebuild on `Tree`).          |
| `Binary`               | Wire format encoder / decoder.                                                |
| `BinaryCursor`         | Zero-allocation read cursor over a Binary IR buffer.                          |
| `Plugin`, `Schema`     | Comptime descriptor types + multi-plugin aggregator.                          |
| `ManifestLoader`       | Reads a v1 portable manifest (`docs/portable-manifest-v1.md`) into an in-memory `Plugin` after meta-validation. |
| `MetaSchema`           | The hardcoded bootstrap meta-plugin. Every conforming impl validates user manifests against this baseline. |
| `wasm` / `wasm_binary` | Two WASM artifacts (kitchen-sink + read-only).                                |

## SoA AST (`Ast.Tree`)

Each node is a fixed 16-byte layout stored in `std.MultiArrayList(Node)`
(three parallel arrays: `tag`, `span`, `data`). Form / kvpair / vector
payloads spill into a `[]u32 extra_data` buffer; strings live in a
single concatenated `[]const u8 strings` indexed by
`string_index[i]..string_index[i+1]`. Comments are stored in a
parallel SoA list keyed by `leading_comments_index[node]` and
`trailing_comments_index[node]`.

Indices are typed enums (`NodeIndex`, `StringIndex`, `ExtraIndex`)
with an `invalid = maxInt(u32)` sentinel — so a stray default-zeroed
index can never accidentally point at the root node.

Trees are self-contained: the arena owns every backing slice
(including dup'd comment text), so `tree.deinit()` releases everything
in one operation. The parser builds the tree directly via
`TreeBuilder` (post phase 14 — there is no longer a legacy
intermediate tree).

See [`src/Ast.zig`](../src/Ast.zig) for the full `Node` type definitions
and `extra_data` layouts.

## Binary IR (`Binary.zig`)

Wire format header (16 bytes, little-endian):

```
+----+----+----+----+----+----+----+----+
|  S |  J |  1 | \n | ver| fl | reserv. |
+----+----+----+----+----+----+----+----+
|     pool_offset   |    roots_offset   |
+----+----+----+----+----+----+----+----+
```

`pool_offset` is always `16` (immediately after the header);
`roots_offset` skips past the string pool and the comment-text pool.
After the header come the string pool, the comment-text pool (only
when any `with_*_comments` flag is set), the roots block (varint
`root_count` + that many encoded nodes), and an optional
tree-trailing-comments block (only when `with_tree_trailing_comments`
is set). Each pool is `[varint entry_count][varint byte_size][entries]`,
where each entry is `[varint len][len bytes]` and the entry list is
sorted by `(length, bytes)`. See `src/Binary.zig` for the full layout.

`Binary.toBinary` walks the SoA tree natively and emits wire bytes.
`Binary.fromBinary` builds a `Tree` directly via `TreeBuilder`,
deep-copying string and comment text into its own arena so the
result is self-contained and does not borrow from the input buffer.
`Validator.validateBinary` and `Expr.evalBinary` skip the tree
build entirely and stream the same bytes through `BinaryCursor`.

## Unit-suffixed numbers

Numbers can carry an optional unit suffix — `4b`, `90deg`, `50%`,
`250ms`, `1.5e2hz`. The lexer's number FSM accepts ASCII letters or a
single `%` after the numeric portion; the parser splits at the first
non-numeric byte and stores `(value: f64, unit: ?[]const u8)` on the
node.

**Lexer rule for `e`/`E`.** When the lexer encounters `e`/`E` from
inside `.number_int` or `.number_frac`, it peeks the next byte: if it's
a digit or sign, the path is exponent (`1e9`, `1.5e-10`); otherwise
the `e`/`E` is the first character of a unit (`1em`, `0.5em`). The
sentinel-terminated source guarantees the lookahead is always safe.
A new `.number_exp_first_digit` state requires at least one digit
after a sign — `1e+x` stays invalid.

**AST representation.** The SoA `Tree` distinguishes the two cases via
`Tag`: `Tag.number` keeps the existing `Data.immediate = @bitCast(f64)`
zero-overhead path, and `Tag.number_with_unit` spills three `u32`s into
`extra_data` (`f64_lo`, `f64_hi`, `unit StringIndex`). Trees with no
units pay nothing extra. `Ast.NumberValue { value, unit }` survives as
an internal helper used by `Json.numberValueToJson` to encode the
discriminator-object form.

**JSON encoding.** Canonical mode emits
`{"$num": [<value>, "<unit>"]}` for unit-bearing numbers and a bare
JSON number for unitless. `$num` decodes to a `NumberValue` strictly
from a 2-element array `[number, string]` with a non-empty unit.
Lossy mode emits a bare JSON number and drops the unit (one-way, like
`$kw` / `$sym`).

**Wire format.** Binary IR introduces tag byte `0x0A`
(`number_with_unit`) with payload `[f64 LE 8] [varint unit_pool_idx]`.
The unit string lives in the existing per-tree string pool, so two
nodes sharing a unit share one pool entry. Wire version stays `0x01`
— old decoders return `error.InvalidTag` for `0x0A`, the desired
forward-incompat behavior. The cursor exposes
`NodeKind.number_with_unit` and `readNumberWithUnit`.

**Adjacent tokens.** `90deg5px` lexes as two number tokens (`90deg`
then `5px`), consistent with how `12foo` lexes today as `.number
.symbol`. Use whitespace to separate adjacent unit numbers when the
ambiguity would matter.

### Calendar dates

The 10th value kind (§3.2.1 of `LANGUAGE.md`) is the calendar date
— proleptic Gregorian `(year, month, day)`, no time, no zone.

**Lex.** A `.number_int` state lookahead matches `YYYY-MM-DD`
exactly (10 chars, four digits, hyphen, two digits, hyphen, two
digits), emitting `Token.Tag.date`. The lookahead is bounded
(6-byte peek past the dash), the source is sentinel-terminated, and
non-matching inputs fall through to the existing number / symbol /
sign paths — `1900-1899` still lexes as three tokens.

**AST.** `Tag.date` packs the validated triple into the 8-byte
`Data.immediate` slot via `Date.pack` (`u16` year in low 16 bits,
`u8` month, `u8` day). Out-of-range components emit
`date_invalid_year` / `date_invalid_month` / `date_invalid_day`
diagnostics and a defaulted `0001-01-01` node so downstream walks
stay well-formed.

**Wire format.** Binary IR adds tag byte `0x0D` with payload
`[i16 LE year][u8 month][u8 day]` (4 raw bytes, no string-pool
interning). Wire version bumps from `0x02` → `0x03`; pre-v3
decoders raise `error.InvalidTag` on `0x0D`, the desired
forward-incompat behavior. The cursor exposes `NodeKind.date`
and `readDate`.

**JSON.** Canonical / full emit `{"$date": "YYYY-MM-DD"}` (a sibling
to `$num` / `$kw` / `$sym`); compact emits a bare 10-char string. The
decoder only re-ingests the `$date`-tagged shape — strings that
happen to look like dates stay strings.

### Clock times

The 11th value kind (§3.2.2 of `LANGUAGE.md`) is the clock time —
`(hour, minute, second, millisecond)`, no date, no zone, no leap
seconds.

**Lex.** A `.number_int` state lookahead matches one of two shapes:
`HH:MM:SS` (8 chars) or `HH:MM:SS.fff` (12 chars). After exactly 2
ASCII digits and a `:`, the lookahead peeks `[0-9][0-9]:[0-9][0-9]`
(`matchTimeTail`); on hit, it also peeks for `.[0-9][0-9][0-9]` and
treats the fractional as all-or-nothing. Non-matching inputs fall
through — `12:34` lexes as `12`, `:34` (number + kwarg-shape).

**AST.** `Tag.time` packs the validated quad into the low 40 bits
of `Data.immediate` via `Time.pack` (`u8` hour, `u8` minute,
`u8` second, `u16` millisecond). Out-of-range components emit
`time_invalid_hour` / `time_invalid_minute` / `time_invalid_second`
diagnostics and a defaulted `00:00:00.000` node — millisecond range
is enforced at the lex level so no fourth code is needed.

**Wire format.** Binary IR adds tag byte `0x0E` with payload
`[u8 hour][u8 minute][u8 second][u16 LE millisecond]` (5 raw bytes,
no string-pool interning). Wire version bumps from `0x03` → `0x04`;
pre-v4 decoders raise `error.InvalidTag` on `0x0E`, the desired
forward-incompat behavior. The cursor exposes `NodeKind.time` and
`readTime`.

**JSON.** Canonical / full emit `{"$time": "HH:MM:SS"}` or
`{"$time": "HH:MM:SS.fff"}` (sibling to `$num` / `$kw` / `$sym` /
`$date`); compact emits a bare 8- or 12-char string. The decoder
only re-ingests the `$time`-tagged shape. Print form is shortest —
`millisecond == 0` collapses to 8 chars, so `12:34:56.000`
round-trips byte-for-byte to `12:34:56`.

## Safe-expression evaluator (`Expr.zig`)

The evaluator is iterative — `Expr.eval` drives an explicit frame
stack (`Frame` union) over `NodeIndex` values, with an explicit
`MAX_FRAMES = MAX_EVAL_DEPTH * 4` bound. Operations:

- `eval` — push the value of a node onto the value stack.
- `apply_form` — pop N argument values and dispatch to a plugin.
- `let_commit`, `if_select`, `cond_select` — short-circuiting control.
- `vec_collect` — assemble N values into a vector.

Plugins register via the `Plugin` descriptor type; `Schema` aggregates
multiple plugins at comptime. The closed-v1 vocabulary lives in
`plugins/core.zig` (`+`, `-`, `*`, `/`, `<`, `>`, `=`, `vec*`,
`clamp`, `lerp`, `let`, `if`, `cond`, `and`, `or`).

### `evalBinary` — streaming over Binary IR

`Expr.evalBinary(gpa, bytes, env, schema)` evaluates a single-root
binary IR buffer **without building a `Tree`**. It mirrors `Expr.eval`'s
iterative architecture but uses a `FrameBinary` union whose walk
frames carry `BinaryCursor` iterators directly. The cursor is
monotonic; each frame fully consumes its node's bytes, so when a
parent walk-frame yields to a child eval, the child consumes the
child's bytes and the parent resumes with the cursor at the next
byte its iter expects — no position save/restore is required.

Result strings/keywords/vectors are deep-copied from the binary
buffer into the result arena, so the caller may free `bytes`
immediately. `sjon.evalExprBinary` (in `root.zig`) and
`sjon_eval_expr_binary` (in `sjon-binary.wasm`) route through
`evalBinary`. `applyFunction`, `Value`, `Env`, `Result`, `Error` are
shared with `Expr.eval`.

## WASM exports

Two artifacts ship:

- `sjon-binary.wasm` — read-only: validate / eval over a binary IR
  buffer. `sjon_eval_expr_binary` streams via `Expr.evalBinary` (no
  `Tree` materialisation); `sjon_validate_binary` walks the binary IR
  through a streaming validator that emits diagnostics with the same
  `(code, path)` shape as the tree path.
- `sjon.wasm` — kitchen-sink: parse / print / validate / toJson /
  fromJson / toBinary / fromBinary / applyEdit / evalExpr /
  evalExprBinary.

## Editor integration & lossless round-trip

The lossless print mode preserves every comment in source order,
keyed by node index. Comments survive every round-trip:

- `parse → print` (lossless mode) is byte-identical for canonical input.
- `parse → toBinary(.lossless) → fromBinary → print(.lossless)` round-trips.
- `parse → toJson → fromJson → print(.canonical)` keeps form structure
  but drops trivia (canonical-only — JSON has no comment encoding).
- `applyEdit` (any structural-edit op) preserves trivia outside the
  affected subtree.

## Vocabulary as data — portable plugin manifests

The top-level plugin contract lives in
[`plugin-model-v1.md`](plugin-model-v1.md). This section summarizes the
portable-manifest slice of that model.

Plugin descriptors are pure data (`FormSpec`, `KeySpec`, `ValueKind`,
`ExprFunc` — no code fields beyond the optional `ExprFunc.Impl`
function pointer), so the same descriptors that drive the Zig
in-process validator also serialise to a portable, on-disk format.
The wire-form is itself SJON:

- `docs/plugin-model-v1.md` — the current source of truth for static
  Zig plugins, portable manifests, WASM sidecars, and host lowering.
- `docs/portable-manifest-v1.md` — the v1 spec (declarations, type
  references, diagnostic surface, conformance contract) for manifest
  syntax.
- `docs/executable-plugin-abi.md` — the WASM sidecar ABI for
  `:impl "wasm:..."` expression-function bodies.
- `manifests/meta.sjon` — the bootstrap meta-plugin that describes
  the structure of v1 manifests. Self-validating: validating
  `meta.sjon` against `MetaSchema.schema` produces zero diagnostics.
- `src/ManifestLoader.zig` — Zig loader. Pipeline: `parse → validate
  against MetaSchema.schema → walk → owned Plugin`.
- `conformance/cases/<name>/{schema,input,expected}.sjon` — the
  cross-host conformance corpus. `src/conformance_tests.zig` is the
  reference runner; `hosts/typescript-parity/` is the second-host
  implementation that consumes the same fixtures unchanged.

The split is *substrate vs vocabulary, validation vs evaluation*: the
parser, AST, and binary IR stay closed in Zig; vocabularies (forms,
value kinds, expr signatures) ride as portable manifests; expression
*implementations* are either static `ExprFunc.impl` hooks or WASM
sidecar exports. Hosts that only need linting / completion / error
messages (LSPs, web playgrounds) consume manifests and stop there.

## Diagnostic surface

Every diagnostic carries a stable machine-matched `code` plus a
semantic `path` (`[]const []const u8` of head / key / index steps)
identifying the slot in the document. `(code, path)` is the
cross-host conformance anchor; `span` and `message` prose are
host-flavoured. The 19 v1 codes live in `Ast.Diagnostic.Code` —
LANGUAGE.md §7.6 documents the surface. Parser, Tree validator, and
Binary validator all emit paths and agree on `(code, path)` for every
parity-tested case.

### Slot-local forms — dual-path seam

Slot-local forms (LANGUAGE.md §6.3.1) reuse the same seam `walk_opaque`
already runs on: the parent form's matched `KeySpec` is threaded onto the
child value frame. When that `KeySpec` carries `local_forms`, the local
registry **and** the slot path ride onto the child form frame; the form
handler then resolves the head **local-first once** — a local hit shadows
the global catalog, a bare miss falls back to `Schema.lookupForm`, and a
miss against both emits the new `unknown_local_form` code at the *slot*
path (suppressing the generic `unknown_form`). Both walkers carry it:
`validateOneTree`'s kvpair handler + `validateFormHead` on the tree side,
`processFormWalkValidate` + `scheduleFormWalkValidate` on the binary side,
locked in lockstep by `expect*OnBoth` tests (the dual-path invariant). A
local hit validates contents by reusing the ordinary form-key machinery,
so no new recursion or ceiling is introduced beyond `MAX_VALIDATE_FRAMES`.

The **document binary wire format is unchanged**: schemas are in-memory
`FormSpec` structs (static or manifest-loaded), never serialized into the
document IR, so `local_forms` adds no bytes and no `Binary.FORMAT_VERSION`
bump. Schema *export* lowers such a slot to an inline anonymous union
(see SCHEMA_EXPORT.md).

## Testing

- 1170+ in-source unit + integration tests run under `zig build test`.
- OOM regression tests (`src/oom_tests.zig`) fuzz every public
  entrypoint via `std.testing.FailingAllocator`.
- Property tests:
  `parse(print(parse(s))) ≡ parse(s)` (canonical idempotence) over
  every form in `fixtures/json_roundtrip.sjon`.
  `validate(parse(s)) ≡ validateBinary(toBinary(parse(s)))` parity
  on every example fixture.
- Cross-host conformance: `src/conformance_tests.zig` runs the
  shared corpus on the Zig path; `zig build ts-conformance-test`
  runs it through `hosts/typescript-parity/` against the same fixtures.
- `zig build fuzz` runs `std.testing.fuzz` harnesses against Lexer,
  Parser, `Json.fromJson`, and `Binary.fromBinary` for never-panic
  invariants (token end ≥ start, returns Tree, errors are in the
  known set).
- `examples/binary-ir-demo.zig` and `examples/plugins/shapes-demo.zig`
  are wired into `zig build test` so the public-API examples can't
  drift from the implementation without a CI failure.
