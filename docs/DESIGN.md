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
| `Validator`            | Schema-driven walker producing diagnostics. Tree and Binary paths agree on `(code, path)` for cross-host conformance. `Plugin.ValueKind` grew a `numeric` refinement (range / integrality bounds) wired through `checkNumericBoundsValue`; `MatchExtras` grew a tag-true `numeric: ?NumericValue` so the binary path's exact-int comparison fires too. Later refinements followed the same dual-path pattern: a `repr` GPU-representation tag (`repr_out_of_range`), variable-arity vectors (`VectorShape.min_len`/`max_len` → `vector_too_short`/`vector_too_long`), and a unit `reject` flag (`unit_forbidden`) — each mirrored on the tree + binary walkers and locked by `expect*OnBoth` tests. `scalar-or-ref` needs no validator change at all: the loader desugars it to an ordinary `union_of`, and the arm-naming failure report (`Validator.determinedArm`) is the general union rule, which a scalar-or-ref's shape-disjoint arms simply always satisfy. |
| `Expr`                 | Closed-v1 safe-expression evaluator with an explicit frame stack.             |
| `Edit`                 | JSON-encoded structural-edit reducer (functional rebuild on `Tree`).          |
| `Binary`               | Wire format encoder / decoder.                                                |
| `BinaryCursor`         | Zero-allocation read cursor over a Binary IR buffer.                          |
| `Plugin`, `Schema`     | Comptime descriptor types + multi-plugin aggregator.                          |
| `ManifestLoader`       | Reads a v1 portable manifest (`docs/portable-manifest-v1.md`) into an in-memory `Plugin` after meta-validation. |
| `MetaSchema`           | The hardcoded bootstrap meta-plugin. Every conforming impl validates user manifests against this baseline. |
| `Host`                 | Cross-host contract over the schema pipeline: `validateDocument` (inline-manifest one-shot), `evalExpr`, schema/lowering export, and the two-phase `preloadSchema` + `HostOptions.preloaded` — compile an external schema once, then borrow it additively across many document validations instead of prepending it (and rebasing spans) every time. |
| `Pattern`, `PatternQuery` | Deterministic Strudel-style pattern types + windowed query producing `(haps …)` / `(diagnostics …)` over a tree or Binary IR. |
| `Lowering`, `LoweringGraph` | Host-registered lowering-hook registry + the graph a hook run emits (source forest → lowered forest). |
| `EffectiveView`, `MaterializedDefaults` | Read-only effective-value overlay: resolves schema `:default`s (literal or `(expr …)`) over an author tree without mutating it. |
| `Resolver`, `FilesystemResolver` | `(use-plugin …)` reference resolution; the default filesystem resolver reads a `sjon-project.sjon` project file. |
| `PluginRuntime`        | Executable-plugin ABI dispatch (`-Dplugin-exec`): instantiate sidecar wasm, pre-flight the import surface + ABI, invoke exports. |
| `EffectiveDocument`    | The whole-document counterpart to `EffectiveView`: schema defaults + lowering applied, ready to hand to a consumer. |
| `SchemaExport`         | Schema → JSON Schema 2020-12 / TypeScript `.d.ts` / an intermediate IR, plus (CLI-only, asked for by name) Markdown reference pages. Ported natively in `hosts/typescript-parity/src/schemaExport/`. |
| `Explanations`         | The prose behind each `Diagnostic.Code` — one entry per variant, completeness pinned at comptime. Feeds `sjon explain`, the REPL's `:explain`, and `landing-page/src/data/errors.json`. |
| `Lockfile`, `Sha256Pin` | `sjon-lock.sjon` parse/emit and the `sha256:…` pin format `(use-plugin …)` and the project file agree on. |
| `Glob`                 | The `:search-roots` / `:ignore` matcher. No filesystem access of its own — it decides, `FilesystemResolver` walks. |
| `StringFormats`, `StringEscape` | `:format` refinements (uuid, email, …) and the one escape/unescape pair the Lexer and Printer share. |
| `DidYouMean`           | Bounded edit-distance suggestion used by every "unknown X" diagnostic that can name a near miss. |
| `CappedRead`           | Read a file with a byte ceiling, so a hostile or accidental multi-gigabyte manifest is a diagnostic and not an OOM. |
| `PluginValueCodec`     | `Expr.Value` ↔ the executable-plugin ABI's wire encoding (depth-bounded; see `MAX_VALUE_DEPTH`). |
| `ProviderExtraction`   | Runs the pure `bytes → names` extractors behind provider-backed cross-refs into a content-addressed table. A host pre-pass in lowering's layer, so the validator still cannot execute anything. |
| `Date`, `Time`, `trig` | Calendar/clock scalar types (see below) and the vendored transcendentals that make `(pow)`, `(exp)`, `(log)` bit-reproducible native-vs-WASM. |
| `wasm_common`          | The framing protocol (`[u32 ok][u32 len][payload]`) and value encoder every artifact shares. |
| `ConformanceExpected`  | Parses a corpus `expected.sjon` — the reference runner's half of the four-host contract. |
| `Lowering_test_hooks`  | Test-only lowering hooks, `pub` because `src/fuzz.zig` is its own module root and must reach them through the `sjon` module. |
| `src/cli/`             | The `sjon` binary: verbs, diagnostic rendering (human / rich / json / github), REPL, completions, share links, and the structured `Hints` surface. CLI-local by design — see CLAUDE.md. |
| `src/lsp/`             | The language server: JSON-RPC dispatch over `Handler`, built for wasm as `sjon-lsp.wasm`. |
| `wasm` / `wasm_binary` / `lsp/wasm` | Three WASM artifacts — see below.                          |

## Public API entrypoints

Exposed at the top of `src/root.zig`. Every entrypoint walks the
canonical SoA `Ast.Tree` natively — one tree representation, one
canonical entrypoint per operation. Everything is arena-owned: each
result holds a `std.heap.ArenaAllocator`, and `result.deinit()`
releases the entire intermediate graph in one call.

| Symbol             | What it does                                                 |
| ------------------ | ------------------------------------------------------------ |
| `parse`            | source `[:0]const u8` → `Ast.Tree` (always succeeds)         |
| `print`            | `Tree → []u8` in canonical or lossless mode                  |
| `validate`         | `Tree × Schema → Validator.Result` (diagnostics)             |
| `evalExpr`         | `(*Tree, NodeIndex) × Env × Schema → Expr.Result`            |
| `toJson`           | `Tree → std.json.Value` (canonical / lossy)                  |
| `fromJson`         | `std.json.Value → Tree`                                      |
| `toJsonRoots`      | `Tree → {"$roots": [...]}` (multi-root)                      |
| `fromJsonRoots`    | `{"$roots": [...]} → Tree`                                   |
| `applyEdit`        | `source × action_json → []u8` (parse → mutate → print)       |
| `toBinary`         | `Tree → []u8` (Binary IR; flag-gated spans / comments)       |
| `fromBinary`       | `[]u8 → Tree` (self-contained, no aliasing)                  |
| `validateBinary`   | `[]u8 × Schema → Validator.Result` (streams via `BinaryCursor`, no `Tree` built) |
| `evalExprBinary`   | `[]u8 × Env × Schema → Expr.Result` (streams via `BinaryCursor`, no `Tree` built) |

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

Six flag bits gate which optional sections are emitted:

| Bit | Flag                            | Default | Effect                                                  |
| --- | -------------------------------- | ------- | ------------------------------------------------------- |
|  0  | `with_spans`                    | on      | Emit per-`Node` `Span` (8 B inline)                     |
|  1  | `with_head_spans`               | on      | Emit per-`Form` `head_span` inline                      |
|  2  | `with_kvpair_key_spans`         | on      | Emit per-`KeywordPair` `key_span` inline                |
|  3  | `with_node_comments`            | off     | Emit `Node.leading_comments` + `Form.trailing_comments` |
|  4  | `with_kvpair_comments`          | off     | Emit `KeywordPair.leading_comments`                     |
|  5  | `with_tree_trailing_comments`   | off     | Emit `Tree.trailing_comments` block                     |

Two presets are exposed: `Binary.ToBinaryOptions.stripped()` clears every
flag (smallest output, ≈0.7× the canonical text size on a typical scene);
`Binary.ToBinaryOptions.lossless()` sets every flag (full round-trip).

### Worked trace: `(camera :ortho :zoom 2)` under `flags = 0x00`

After parsing into a tree and encoding with `stripped()` flags:

```
header   53 4A 31 0A 01 00 00 00 10 00 00 00 22 00 00 00
         ^magic       ^v ^fl ^reserved ^pool_off=16   ^roots_off=34

pool     03                              // entry_count = 3
         12                              // byte_size   = 18
         04 7A 6F 6F 6D                  // "zoom"  (idx 0)
         05 6F 72 74 68 6F               // "ortho" (idx 1)
         06 63 61 6D 65 72 61            // "camera"(idx 2)

roots    01                              // root_count  = 1
         08                              // tag: form-bare
         02                              // head_idx    = 2  ("camera")
         02                              // child_count = 2
         10                              // child-positional
         05                              // tag: keyword
         01                              // pool_idx    = 1  ("ortho")
         11                              // child-keyword
         00                              // key_idx     = 0  ("zoom")
         03                              // tag: number
         00 00 00 00 00 00 00 40         // f64 LE = 2.0
```

Total: 16 (header) + 20 (pool) + 18 (roots) = 54 bytes. The same form's
canonical text is 23 ASCII bytes. The binary is larger here because the
header + pool dominate on a one-form fixture; on realistic scenes (many
recurring identifiers) the binary settles at ≈0.7× the canonical text
size with `flags = 0x00`.

### Zero-allocation cursor

`BinaryCursor` walks `bytes` in a single linear pass without allocating.
All returned `[]const u8` slices borrow from the input buffer (which must
outlive the cursor). Use it when you need to validate or interpret a
binary tree without producing a `Tree`:

```zig
var cursor = try sjon.BinaryCursor.Cursor.init(bytes);
var roots  = try cursor.rootIter();
while (try roots.next()) |view| {
    switch (view.kind) {
        .number => {
            const x = try sjon.BinaryCursor.readNumber(&cursor, view);
            // use x
        },
        .form => {
            var fv = try sjon.BinaryCursor.readForm(&cursor, view);
            // fv.head, fv.namespace, fv.head_span
            while (try fv.children.next()) |child| {
                // recurse on child.value or skipBody(&cursor, child.value)
            }
        },
        else => try sjon.BinaryCursor.skipBody(&cursor, view),
    }
}
```

See [`examples/binary-ir-demo.zig`](../examples/binary-ir-demo.zig) for a
runnable end-to-end example (`zig build demo-binary`).

## Unit-suffixed numbers

Numbers can carry an optional unit suffix — `4b`, `90deg`, `50%`,
`250ms`, `1.5e2hz`, `2d-array`. The lexer's number FSM accepts ASCII
letters, a `-` joining two letter runs, or a single `%` after the numeric
portion; the parser splits at the first non-numeric byte and stores
`(value: f64, unit: ?[]const u8)` on the node.

**Lexer rule for `-` inside a unit.** A `-` continues the unit only when
the next byte is a letter, and it can never open one: a `-` reaching the
unit state always has a letter before it. So `2d-array` and
`5ms-per-frame` are one token each, while `1em-2` stays `1em` then `-2`
and `2d-` ends at `2d`. Subtraction between a unit-bearing number and a
number is unaffected, because its right operand starts with a digit.

**Lexer rule for `e`/`E`.** When the lexer encounters `e`/`E` from
inside `.number_int` or `.number_frac`, it peeks the next byte: if it's
a digit or sign, the path is exponent (`1e9`, `1.5e-10`); otherwise
the `e`/`E` is the first character of a unit (`1em`, `0.5em`). The
sentinel-terminated source guarantees the lookahead is always safe.
A new `.number_exp_first_digit` state requires at least one digit
after a sign — `1e+x` stays invalid.

**Hex integers.** `x`/`X` from `.number_int` opens a hex literal, but only
when the numeric portion so far is exactly `0`, optionally signed. So
`0xFF` and `-0x10` are hex, while `10x`, `00x`, `0_x`, and `0.5x` keep
their unit and lex byte-identically to before. A hex literal is
`[0-9a-fA-F_]+` with no fraction, no exponent, and no unit, so `0xFFp2` is
`0xFF` then `p2`. A prefix with no hex digit after it (`0x`, `0xGG`) is
`.invalid`, which routes to `handleInvalidToken` the way `1e+` already
does, rather than yielding the number zero with unit `x`. The parser reads
the digit run in base 16 through the same `i64` → `u64` ladder decimal
integers take, so a hex literal lands on the existing number tags: no new
tag, no wire change, and every `:numeric` / `:repr` / `:unit` refinement
judges it as it judges a decimal. `Parser.parseNumberAs` carries the same
branch, because it is the `pub` re-read behind `:repr` and works from the
source lexeme rather than the decoded value; its float arm goes through
hex-float syntax (`0xFFp0`) so the value is correctly rounded rather than
accumulated digit-by-digit. The printer has no source access and formats
from the value, so `sjon fmt` writes a hex literal back as decimal (§4.2
of LANGUAGE.md): values round-trip, spellings do not.

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
nodes sharing a unit share one pool entry. This tag was introduced at
wire version `0x01` — old decoders return `error.InvalidTag` for `0x0A`,
the desired forward-incompat behavior. (The wire version has since
advanced to `0x05` across four further bumps: exact-integer tags
`0x0B`/`0x0C` at v2, `date` `0x0D` at v3, `time` `0x0E` at v4, and at v5
a trailing-comment field on `vector` payloads — symmetric with forms,
gated by `with_node_comments` — so lossless round-trips preserve a
comment wedged before a vector's closing `]`.) The cursor exposes
`NodeKind.number_with_unit`
and `readNumberWithUnit`.

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

Three artifacts ship. The first two share the `wasm_common` framing and
are what a host embeds; the third is a language server and is embedded by
an editor instead.

- `sjon-binary.wasm` — read-only: validate / eval over a binary IR
  buffer. `sjon_eval_expr_binary` streams via `Expr.evalBinary` (no
  `Tree` materialisation); `sjon_validate_binary` walks the binary IR
  through a streaming validator that emits diagnostics with the same
  `(code, path)` shape as the tree path. Its import closure is an
  enforced allowlist (`zig build audit-wasm-imports`) — the whole point
  is to ship the IR consumer without the parser, printer, or `std.json`.
- `sjon.wasm` — kitchen-sink: parse / print / validate / toJson /
  fromJson / toBinary / fromBinary / applyEdit / evalExpr /
  evalExprBinary / exportSchema.
- `sjon-lsp.wasm` — the language server (`src/lsp/`), driven by a
  JSON-RPC byte pump (`sjon_lsp_alloc` / `_send` / `_recv` / `_dealloc`)
  rather than the `[u32 ok][u32 len]` envelope. It declares **zero**
  imports — it is instantiated with `{}`, so it has no host surface to
  disagree about — and `zig build audit-lsp-wasm-imports` asserts that.
  The playground is its consumer; see CLAUDE.md's landing-page section.

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
  drift from the implementation without a `zig build test` failure.
