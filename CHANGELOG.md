# Changelog

All notable, breaking, or contract-affecting changes land here, documented
plainly. The stable surfaces — the binary wire format and the diagnostic-code
enum — are versioned and corpus-gated; nothing changes them silently.

## Unreleased

## 1.2.0 — 2026-08-17

The contract at a glance: no wire-format change (still v5), diagnostic codes
append-only (five new: `positional_too_many`, `positional_missing`,
`dependent_key_missing`, `union_ambiguous`, `number_not_multiple`), manifest
format 1.2 → 1.3, and the conformance corpus grown to 354 cases. Nine plans
answering a downstream host's (PNGine) adaptation asks, plus a same-day
long-tail audit across their interactions — `docs/plans/asks/README.md`
carries the full ledger, including where a plan and the shipped code
diverged.

### Added

- **Positional cardinality — `(head-set (head :name … :min … :max …))`.** A
  head inside a head-set may bound how many positional children carry it, not
  just which heads are allowed. Fewer than the floor trips
  `positional_missing`; more than the ceiling, `positional_too_many` — both
  counted per form instance, and inert on a head-set used anywhere other than
  a `:positional` slot (a keyed slot or a `vector-shape :element` have no
  count to bound). JSON Schema exports the bound as one `contains` +
  `minContains` / `maxContains` per bounded head (not `minItems` /
  `maxItems`, which bound the array's total length); the Markdown target
  gains a small Head/Count table beneath the existing positional-children
  sentence. Manifest format 1.2 → 1.3 (shared with `scalar-or-ref-shape`
  below — one bump, taken by whichever landed first).
- **Digit-leading enum members (`1d`, `2d`) and hyphen-joined units
  (`2d-array`, `ms-per-frame`).** A `member-set`'s `:values` may declare a
  numeric spelling directly (`[1d 2d 3d]`), and the lexer's unit alphabet now
  admits a hyphen followed by another letter run, so a previously
  undeclarable unit like `ms-per-frame` both lexes and can appear in a
  `member-set`. Matching is integer-keyed (not text- or float-keyed), so
  `2d`, `2.0d`, and `02d` collapse to one member at both load and match time,
  while `2.5d` cannot round into one. A digit-leading member is a
  `number_with_unit` on the wire, so the exported schema routes through the
  existing rich `oneOf` encoding (`{"$num": [2, "d"]}`) rather than a bare
  `$sym` enum — the encoding changed even though `Member.name` (and the
  Markdown rendering) did not. `@sjon/schema` can declare and serialize a
  digit-leading member. No wire-format change, no new diagnostic code, no
  format bump.
- **Hex integer literals (`0xFF`).** See "Behavior changes" below — this is
  the one ask in the series that changes what an existing document means.
- **Union match ambiguity — `union_ambiguous`.** A `warning`-severity
  diagnostic fires when a value matches more than one alternative's *name*
  (not just its shape) inside a union, naming every claimant. Emitted after a
  successful first-match dispatch (joining `deprecated_member` and
  `string_pattern_unsupported`'s existing after-the-match advisory family),
  so matcher dispatch itself is unchanged. A poisoned bucket (a failed
  cross-ref provider) is not a claimant, and two cross-ref kinds that resolve
  to the same target count as one claim, not two — both narrowings guard
  against warning on a union that is not actually ambiguous.
- **Multi-target cross-refs — `(cross-ref :target [a b])`.** A cross-ref may
  name several target forms as one namespace instead of one, registering
  into a single shared bucket rather than several independent ones. The
  bucket key is a sorted, de-duplicated set of canonical target names, so
  declaration order never changes behavior and a target named twice collapses
  to one key. A form may carry at most one provider-route registration, so
  `:provider` does not compose with a target group (a fourth
  `invalid_manifest` exclusion, alongside empty/duplicate/incoherent
  targets). JSON Schema emits `target-forms` (an array) for a group instead
  of the singular `target-form`; the TypeScript export emits a union of
  `CrossRef<…>` brands. `@sjon/schema`'s `s.crossRef` now accepts one target
  or a list. No new diagnostic code, no wire-format change; format bump
  shared with the two entries above.
- **Key dependency — `(key … :requires [b])`.** Presence of one key implies
  presence of another; violated on a tree or Binary IR document as
  `dependent_key_missing`. Exports to JSON Schema's native
  `dependentRequired`. Suppressed on an `:open true` form, consistent with
  every other end-of-form sweep (`missing_required_key`, the discriminant
  gate, exclusive groups) — the form's *declared* keys still get checked,
  but presence of an undeclared key is never assessed. A self-referential
  `:requires` is rejected at load with its own diagnostic rather than
  surfacing as a generic cycle.
- **`scalar-or-ref-shape :ref <kind>`.** Names the reference half of a
  scalar-or-ref shorthand explicitly, so a misspelled reference is caught
  (as a union match failure) instead of silently accepted as the bare
  scalar. Pure load-time desugar — no validator or wire change. Manifest
  format bump shared with the positional-cardinality entry above.
- **`(numeric-bounds :multiple-of N)` — divisibility bounds.** A number
  outside the multiple trips `number_not_multiple`; a manifest-declared
  non-integer divisor is accepted but validates approximately, reusing the
  existing `numeric_bounds_invalid` warning channel rather than spending a
  new wire-stable code on the nuance (the corpus asserts both severities
  side by side). Exports to JSON Schema's native `multipleOf`, and reaches
  the `--target=intermediate` IR and `@sjon/schema`'s `.multipleOf(n)`.
- **Head-set names resolving to slot-local forms, and emitted positional
  atoms.** Two asks in the series (`docs/plans/asks/07-…` and `09-…`)
  turned out to need no SJON change — both already worked as asked, and are
  now pinned by corpus cases (the former) and documented (the latter) so
  the behavior cannot silently regress.

### Behavior changes

- **`0x` now opens a hex integer, so `0xFF` is 255 where it used to be
  0.** This changes what an existing document *means*, which is why it is
  called out here rather than left to the release notes. Before, the lexer
  read `0xFF` as one number token with the value `0` and the unit `xFF`:
  loud in a slot whose value-kind rejected units, and **silent everywhere
  else** — a plain `:type number` slot accepted the zero without a
  diagnostic, and `(+ 0xFF 1)` evaluated to `1`. Any document that wrote a
  hex-looking literal was already wrong; it is now read the way it was
  written.

  Scope of the change is deliberately narrow. The prefix is recognised
  only when the numeric portion before it is exactly `0`, optionally
  signed, so `10x`, `00x`, `0_x`, `0.5x`, and `1X` all keep their unit and
  lex byte-identically. A hex literal carries no unit, no fraction, and no
  exponent, and reaches the existing `number_i64` / `number_u64` tags — so
  there is **no wire-format change, no new diagnostic code, and no
  validator change**; every `:numeric`, `:repr`, and `:unit` refinement
  judges a hex value exactly as it judges a decimal one.

  A `0x` prefix with no hex digit after it (`0x`, `0x_F`, `0xGG`) is now a
  parse diagnostic — `unspecified`, the same channel `1e+` already used —
  instead of the number zero with unit `x`. One diagnostic per typo: the
  token spans only the prefix, so `GG` still lexes as an ordinary symbol.

- **`sjon fmt` rewrites a hex literal to decimal.** `0xFFFFFFFF` comes
  back as `4294967295`. The printer formats from the decoded value and has
  no access to the source, so this is the same normalization that has
  always turned `1_000` into `1000` and `1e3` into `1000` — but it is
  visible on exactly the idiom hex exists to serve, so: values
  round-trip, spellings do not (`docs/LANGUAGE.md` §4.2). Preserving the
  spelling would need a new carrier for something the value already
  determines (a wire-bumped tag pair, or a tree-side table that drifts the
  moment anything builds a tree without the parser). If that ever proves
  intolerable, the tag pair is the honest fix and a deliberate,
  version-gated change.

### Fixed

Found by a same-day sweep of the nine asks' *interactions*, after each had
shipped and passed on its own — `docs/plans/asks/README.md`'s "Post-series
audit" section. None changed the wire format or the diagnostic-code enum;
both are corpus-gated and mirrored in `hosts/typescript-parity`.

- **A target group's bucket key was order-sensitive.** `[a b]` and `[b a]`
  declared one namespace but keyed two: a duplicated name was reported once
  per spelling, `cross_ref_target_collapse` went silent between them, and
  `union_ambiguous` could fire on a slot whose two readings picked the same
  entity. The key is now a sorted, de-duplicated set, so declaration order
  and repeated targets no longer change behavior; a single (non-group)
  target still keys on exactly the canonical form name.
- **A negative `:multiple-of` exported an invalid schema.** `-3` validated
  correctly at runtime but emitted `"multipleOf": -3`, which JSON Schema
  2020-12 forbids and ajv refuses to compile. Both the value's sign and the
  divisor's sign now share the same zero-arm handling on export.
- **The duplicate-member scan ran on one authoring shape only.** `(member
  …)` children were checked for byte-equal duplicates; the compact `:values
  [...]` spelling was not, so a set that looked smaller than it was — most
  visibly `[2d 2.0d]`, which canonicalises to one member — slipped through
  silently. Both shapes are checked the same way now.
- **`@sjon/schema` gained `.multipleOf(n)`.** The one host `:multiple-of`
  left behind (`hosts/schema` models numeric bounds already; the other three
  hosts got it in the same commit as the feature). Refuses a non-positive
  divisor at the call site, matching the loader.
- **OOM and fuzz coverage for the series' new allocating paths.** Five new
  OOM-stress loops (the loader, both validation walkers separately, and
  `validateCrossRefs`) and fuzz seeds for the 1.3 manifest vocabulary — the
  series itself had added none, leaving head-set entries, `:requires`
  lists, numeric member spellings, and the target-group bucket key
  unexercised under a failing allocator or the fuzz harness.

## 1.1.0 — 2026-08-15

The contract at a glance: binary wire format v5 (vectors carry their
trailing comments — the one wire change), diagnostic codes append-only
(value-kind refinements, slot-local forms, pattern queries, provider-backed
cross-references), and the conformance corpus grown to 321 cases replayed
bit-identically across the Zig, Node, Rust, and TypeScript hosts.

### Added

- **A lowering hook can explain its own failure
  (`LoweringOutput.fail` / `failAt`).** `HookFailed` previously collapsed
  every reason a hook had for refusing into one fixed sentence at the form's
  head span — by design ("without inspecting the cause"), which is right for a
  host bug and wrong for an author who wrote something the sugar cannot
  express. A hook may now set an optional `cause` (message, plus an optional
  span) through the output sink it already holds; the driver reports the
  message verbatim and prefers the hook's span. `failAt`'s span matters most
  for a *container* hook, whose failures belong to one child rather than to
  the whole construct. Additive and opt-in: `HookFn`'s signature is unchanged,
  a hook that returns a bare `HookFailed` produces the identical diagnostic it
  always did (pinned by test), and the diagnostic **code** stays
  `lowering_hook_failed` either way, so conformance consumers keying on codes
  are unaffected. No wire-format, WASM-ABI, or manifest surface.
- **`sjon_manifest_meta` WASM export.** Returns a structural summary of a
  well-formed `(plugin …)` manifest — its declared name and surface, read
  structurally rather than by byte-walking — so read-side hosts can describe a
  manifest without loading it into a schema. Additive export; no wire-format or
  diagnostic-code change.
- **`MAX_FILE_SIZE` read cap (256 MiB).** `CappedRead.readFile*` caps every
  input read at the binary IR's own `MAX_FILE_SIZE` (`1 << 28`) — the largest
  input any SJON stage accepts — so a file reaching the cap returns
  `error.StreamTooLong` instead of an unbounded allocation.
- **Schema preload API (`Host.preloadSchema` + `HostOptions.preloaded`).** A
  two-phase alternative to prepending an external schema onto every document.
  `preloadSchema` compiles a set of standalone `(plugin …)` manifest sources
  into a `PreloadedSchema` once (parse → load → aggregate-validate); pass the
  handle via `HostOptions.preloaded` and the document pipeline composes its
  plugins *additively* — before any inline `(plugin …)` the document declares —
  and *borrows* it (the handle must outlive each `HostResult`; a result's
  `deinit` never touches the preloaded arenas). Preload diagnostics are
  manifest-source-local and document diagnostics stay document-local, so no
  span rebasing is needed. Additive Zig-API surface only: no WASM handle
  exports or host wrappers, and — since document nodes are all that cross
  the Binary wire and no manifest is serialized — no wire-format,
  diagnostic-code, or host-parity change.
- **`HostResult.lowered_materialized_defaults`** — the terminal lowering
  layer's materialized-defaults overlay, exposed alongside `lowered_tree`.
  Hosts can now pair `lowered_tree` with this overlay in an `EffectiveView`
  to resolve schema `:default`s on hook-emitted forms; previously the
  overlay was built for re-validation and then dropped, so the source
  `materialized_defaults` (keyed on source NodeIndices) never matched a
  lowered form and defaults were dead for every hook-emitted form. Additive
  Zig-API surface only — like `lowered_tree` / `lowering_provenance`,
  lowering is not serialized across the WASM boundary, so no wire-format,
  diagnostic, or host-parity change.
- **Value-kind refinements.** Four axes on `:underlying` value kinds, each
  with wire-stable diagnostic codes emitted identically on the tree and
  Binary IR validation paths:
    - **`:repr <int-type>`** pins a number to an integer representation
      (`u8`, `i16`, …); values outside the range or with a fractional part
      trip `repr_out_of_range`.
    - **Variable-arity vectors** — `:min-len` / `:max-len` on a vector kind.
      A vector shorter than the floor trips `vector_too_short`; longer than
      the ceiling, `vector_too_long`; a manifest declaring an incoherent
      bound (min > max, negative) is rejected at load with
      `vector_bounds_invalid`.
    - **Unit `:reject`** — a numeric kind may reject *all* unit suffixes; a
      unit-bearing value in such a slot trips `unit_forbidden` (the
      complement of the existing require/allow unit modes).
    - **`scalar-or-ref` shorthand** on `:underlying` desugars to a union of
      the scalar kind and a symbol cross-reference, so a slot can accept
      either an inline literal or a named reference without hand-writing the
      union.
- **Slot-local forms (keyed and positional).** A `(key …)` slot can declare
  inline `(form …)` shapes local to that slot instead of promoting them to
  plugin-global heads; a `(form …)` can likewise declare inline `(form …)`
  children as **positional** slot-locals — the positional mirror. Inline
  positional locals imply `:positional any` when no explicit positional
  policy is given (otherwise they'd be unreachable), and pairing them with a
  `(flag-set …)` is rejected at load as `invalid_manifest`. A form value
  whose head is not a declared slot-local (nor a visible global form) trips
  `unknown_local_form` — at the slot for a keyed carrier, at the parent form
  for a positional one. Both carriers share `MAX_LOCAL_FORM_DEPTH` and
  compose (a positional local may carry key-locals and vice-versa).
  Resolution is honored identically on the tree and Binary IR paths; the
  schema exporter lowers either slot-local set to an inline union and the
  TypeScript parity host mirrors the resolution.
- **Provider-backed cross-references.** A `(cross-ref-provider …)` manifest
  catalog — name, `:impl "wasm:<export>"`, `:version` / `:hash` pinning —
  plus `:provider` / `:source-key` on `(cross-ref …)`: for every form
  resolving to `:target`, a pure, zero-import WASM extractor reads the
  string under `:source-key` and returns the member names the referencing
  slots resolve against. Providers see only document bytes (extraction is
  `f(source) → names | failure`), ride the existing plugin catalogs for
  namespacing, did-you-mean, pinning, and lockfile recording, and a host
  that cannot run one fails loudly with a wire-stable code instead of
  passing silently. Extraction width is capped at
  `MAX_EXTRACTED_NAMES = 4096`; over the cap is a failure, never a
  truncation. Manifest format 1.1 → 1.2. Six appended diagnostic codes:
  `unknown_cross_ref_provider`, `ambiguous_cross_ref_provider`,
  `cross_ref_source_key_unknown`, `cross_ref_extraction_failed`,
  `cross_ref_provider_unavailable`, `cross_ref_target_collapse`. A real
  provider ships in `examples/`: the uniforms WGSL extractor, driven by a
  manifest and three scenes and gated in the CLI tests.
- **PatternQuery.** A tick-time pattern-query walker over Strudel-style
  combinators (`pure` / `silence` / `seq` / `stack` / `fast` / `slow` /
  `cat` / `slowcat` / `euclid`, the last desugaring Bjorklund rhythms to
  `fastcat`), with Expr-valued `(pure …)` hap leaves; a host chains its own
  outer `Expr.Env` under those leaves via `queryTreeWithEnv`. Exposed
  across the four hosts via `sjon_query_*` WASM exports and their host
  wrappers, corpus-gated by dedicated `query.sjon` cases. Wire-stable
  diagnostic codes: `pattern_tick_overflow` (tick arithmetic exceeds the
  representable span), `pattern_value_eval_failed` (a hap's `(pure <expr>)`
  leaf failed to evaluate), `pattern_value_result_invalid` (it evaluated to
  a value the hap slot can't carry).
- **Cross-host bit-identical `exp` / `log` / `pow`.** `exp64`, `log64`, and
  `pow64` are now vendored in `src/trig.zig` alongside `sin`/`cos`/`tan`,
  so `(exp …)`, `(log …)`, and `(pow …)` produce bit-identical results
  across the Zig, Rust, and TypeScript hosts. Conformance pins the exact
  output bits.
- **`@sjon/highlight`.** A fourth TypeScript host — a reusable `.sjon`
  grammar for CodeMirror (stream parser) and TextMate, driving both the
  playground editor and static snippet highlighting on the landing page,
  with per-character CM/TextMate parity tests.
- **CLI verbs.** `sjon completions` (bash / zsh / fish), `sjon plugin init`
  (manifest scaffold), and `sjon project sync` (reconcile the project
  lockfile). Unknown-key diagnostics now suggest the nearest declared key
  (did-you-mean), and the rich diagnostic renderer prints hint footers.
- **LSP capability wave.** Goto-definition, document highlight, structural
  selection ranges, and workspace symbols over the cross-ref index. Hover
  renders the full value-kind constraint surface, declared defaults,
  declared expr result types, and the diagnostic explanation under the
  cursor. Duplicate-key, exclusive-group, and cross-ref diagnostics carry
  related information; deprecated members carry the Deprecated tag; every
  diagnostic links its documentation page. Both transports — native and
  WASM — emit all of it.
- **The LLM pack (`examples/llm/`).** A primer (`PRIMER.md`, mirrored
  verbatim as the site's `llms.txt`), ten diagnostic-driven repair flows
  (unknown key through provider-backed cross-references), and a measured
  token-cost comparison against JSON Schema + Ajv — all byte-gated by
  `zig build llm-pack-verify`.

### Behavior changes

- **Binary wire format v4 → v5.** Vectors carry their trailing comments on
  the wire, so a binary round-trip preserves them. Readers key on the
  version byte; a v4 reader rejects a v5 payload with
  `unsupported_version` rather than misreading it.
- **`(pow …)` is bit-different from the pre-vendor route.** Routing `(pow …)`
  through the vendored `pow64` changes some results in the last ULP versus
  the previous host-libm path. This is a deliberate reproducibility trade:
  the same input now yields the same bits on every host, at the cost of
  matching any single platform's libm exactly.

### Fixed

- **Dual-path convergence.** The tree and Binary IR validation paths agree
  on labeled expr calls, typed-vector element diagnostics, the warning
  surface, and union alternatives that lose resolution — each former
  divergence now pinned by a test that runs both paths.
- **Expr correctness.** Exact integer variants compare exactly instead of
  through `f64`; `evalBinary` considers every labeled signature, as `eval`
  does; tree children stream so width no longer costs depth; an inverted
  `(clamp …)` range is rejected instead of asserted on.
- **Never-panic hardening.** A leading UTF-8 BOM is skipped instead of
  lexed as garbage, extreme floats no longer panic three value renderers,
  and the fuzz corpus seeds actually reach every harness.
- **CLI contract.** Exit codes honor the documented contract, the verb
  table is complete and guarded, plugin JSON output is valid JSON, a query
  budget trip is an argument error rather than a crash, and
  `project lock` / `sync` cannot record a project that never existed.
- **LSP robustness.** Offset conversion counts every LSP line terminator;
  one file resolves to one document whatever the client's URI spelling; a
  failed sync drops the document instead of desynchronising it; refactors
  refuse parser-recovered documents and stamp document versions on every
  edit that can carry one.

### Internals

- **Gate hardening + repo hygiene (no contract change).** `audit_docs.sh` gained
  a fourth check reconciling the six dedicated-suite `test "…"` counts CLAUDE.md
  advertises against the live files (three had drifted); the biome allowlist now
  covers `landing-page/scripts/*.mjs` + `landing-page/plugins/*.mjs`; root-level
  assessment/audit scratch notes are globbed in `.gitignore`; the 12 copy-paste
  `double.wasm` fixture-staging blocks in `build.zig` collapsed to one dest-path
  loop; and `AGENTS.md` + `root.zig`'s memory-model header were brought current.
- **Conformance corpus policy — legacy shape frozen (no contract change).** The
  legacy split-file case shape (`schema.sjon` + `input.sjon`) is now documented
  as *frozen, not deprecated*: the 136 legacy cases stay (they double as F9
  preload coverage via `runLegacyCaseAsHost`), but new cases use `document.sjon`
  (inline) or `query.sjon`. A ratchet test (`conformance: legacy corpus is
  frozen at 136 cases`) pins the count so a deliberate legacy addition is a
  conscious bump.
- **Conformance case classifier single-sourced (`conformance/classifier.json`).**
  The marker filenames, dispatch precedence, and wasm-host skip families
  (`lowering-*`, `too-many-keys`) now live in one JSON data file instead of
  being hand-copied across the hosts. The shared TS module (`hosts/conformance-
  shared`) reads it at runtime — both TS hosts get markers + precedence
  transitively, and the web host's skip set materializes from it — and
  `hosts/rust/build.rs` parses it at build time (new `serde_json` build-dep).
  The typescript-parity port's larger, genuinely-different skip set stays
  host-local; the Zig runner remains the native reference and mirrors the file.
  The existing dead-family audits (TS + build.rs) stay as the drift net.
- **Gate inversions (no contract change).** The wasm-import audit became an
  allowlist — an unlisted import and a stale entry both fail; diagnostic
  coverage no longer accepts constructed codes; `sjon-lsp.wasm`'s
  zero-import invariant is asserted at build time; every corpus leg is
  pinned; and `zig fmt --check` (`audit-fmt`) plus a root-export
  completeness check joined `zig build verify`.
- **Expected-value siblings single-sourced (`expected.values.json`).** The
  value-carrying fixtures (39 at this release) carry a generated
  `expected.values.json` sibling —
  emitted from each fixture's `(values …)` block through `wasm_common.appendValue`
  (the same encoder the wire envelope uses) by `tools/gen_expected_values.zig`
  / `zig build gen-expected-values` (`-- --regen`), drift-gated inside `zig build
  test`. The Web and Rust hosts retired their hand-rolled literal→JSON decoders
  (web `readExpectedValues`/`nodeToJsonValue` + date/time regexes + inf/nan slop;
  rust `read_expected_values`/`node_to_json`/`value_equals`/`number_equals`/
  `is_iso_date`/`is_iso_time`) and now compare evaluated results against the
  sibling through their one JSON parser — exact by construction, since both sides
  parse the same encoder output. The decoder was extracted to
  `src/ConformanceExpected.zig`; the Zig runner keeps its native
  `Expr.Value.equals` leg as the independent check.

## 1.0.0 — 2026-06-02

### Conformance corpus

- Conformance harnesses (Zig + TypeScript) now run three diagnostic
  phases per case — manifest load, schema-aggregate cross-ref
  resolution, input validate — and concatenate err-severity diagnostics
  in that order before comparing to `expected.sjon`. New fixtures cover
  `too_many_keys` (load), `unknown_cross_ref_target`,
  `acyclic_without_self_edge`, `unknown_cross_ref_scope`
  (schema-aggregate). Audit script reports all four codes as `both` —
  test- *and* corpus-covered.

### Added

- **Exclusive-group cardinality** on `FormSpec` and `Variant` —
  declare "exactly one of" or "at most one of" key bundles directly
  in the plugin DSL instead of writing a per-form host hook. New
  `Plugin.ExclusiveGroup` / `Alternative` / `Cardinality` types;
  manifest surface is a child form `(exclusive-group :cardinality
  exactly-one (alt :keys [a]) (alt :keys [b]))` attached to `(form
  …)` or `(variant …)`. Wire-format-stable diagnostic codes:
  `mutually_exclusive_keys_present`, `required_one_of_missing`
  (validate-time), `exclusive_group_invalid` (manifest-time, covers
  fewer-than-two alternatives, alt naming an undeclared key, the
  same key in two groups, and a group naming the discriminant).
  Tree and Binary validator paths emit identical `(code, path)`
  pairs; the form/variant required-key sweeps skip slots in any
  exclusive group to avoid double-emission. `(phrase :notes …)` xor
  `(phrase :events …)` is now declarative rather than a per-form
  host hook.
- **Stdlib expansion (~32 new built-in expression functions).** The
  closed `core` vocabulary grows with batteries-included math,
  smoothing, vector ops, list ops, and a seeded-random suite. All
  funcs are pure, deterministic, and IEEE 754-faithful across hosts.
    - **Math (extended):** `abs`, `sign`, `floor`, `ceil`, `round`,
      `fract`, `sqrt`, `pow`, `sin`, `cos`, `tan`, `asin`, `acos`,
      `atan`, `atan2`, `radians`, `degrees`. Scalar `f64 → f64`.
      Domain errors (`(sqrt -1)`, `(asin 2)`, `(pow -1 0.5)`)
      propagate IEEE 754 `NaN`; no new error code.
    - **Constants:** `pi` and `tau` as 0-arity calls (`(pi)`, `(tau)`)
      so the closed-vocab contract holds — `expr_funcs` enumerates
      every callable.
    - **Smoothing:** `saturate`, `step`, `smoothstep`.
    - **WGSL conventions** for graphics-flavoured ops: `fract` may
      return exactly `1.0` for some near-integer negatives;
      `smoothstep` with `edge0 == edge1` is indeterminate; `reflect`
      requires caller-normalized `N`.
    - **Vector ops:** `normalize`, `distance`, `reflect`. Operate on
      vectors of any matching length; empty / zero-magnitude
      vectors raise `error.TypeMismatch`.
    - **List ops:** `nth` (0-indexed, OOB → error) and `count`.
      Vector-only for v1.
    - **Seeded random:** `hash`, `rand01`, `rand-range`, `rand-int`,
      `rand-bool`, `rand-choice`. Deterministic SplitMix64 mixer
      driven by `(seed, key)` arguments — same input produces the
      same output across runs, platforms, and Zig versions.
      Integer-valued seeds map identically to their `f64` form, so
      `(rand01 1 0)` and `(rand01 1.0 0.0)` produce the same stream.
  Doc updates: `docs/LANGUAGE.md §8.4` (vocabulary tables) and §8.6
  (NaN-on-domain-error policy); `docs/AUTHORING.md §10.2` and §14
  cheat-sheet; `docs/tutorial/07-safe-expressions.md`. The same
  pass also corrected a pre-existing claim that `lerp` / `clamp` /
  `min` / `max` were polymorphic across vector shapes — the actual
  impl is scalar-only, and a future `(vmap fn v)` op may layer
  broadcast on without breaking v1.
- **Cross-reference refinement axis** (`(cross-ref :target :name-key
  :acyclic :scope)`) on `:underlying symbol` value kinds. Every form
  whose head matches `:target` contributes its `:name-key` value to a
  registry; symbol values typed by the kind are checked against it.
  v1 enforces per-tree isolation by default; `:scope <form>` opts into
  a tighter lexical scope (each instance of `<form>` opens a fresh
  registry). `:acyclic true` opts into cycle detection over self-edge
  keys. Wire-format-stable diagnostic codes:
  `not_cross_ref`, `duplicate_cross_ref_target`,
  `unknown_cross_ref_target`, `ambiguous_cross_ref_target`,
  `cross_ref_name_key_unknown`, `unknown_cross_ref_scope`,
  `ambiguous_cross_ref_scope`, `cross_ref_outside_scope`,
  `cyclic_cross_ref`, `acyclic_without_self_edge`. Tree and Binary
  validator paths emit identical `(code, path)` pairs; the TypeScript
  reference host has full conformance parity. See
  `docs/LANGUAGE.md §7.6` and `docs/portable-manifest-v1.md §4.5`.
- **Namespace-threaded expr-func dispatch.** The evaluator now
  threads the head's namespace through `apply_form` / `form_walk`
  frames into `applyFunction`, so `(myns/foo …)` resolves through
  `myns`'s `foo` rather than aliasing whichever plugin happened to
  declare a bare `foo`. Bare ambiguity surfaces as
  `error.AmbiguousFunction`. JSON `$expr` gains an optional sibling
  `$ns` for qualified expression heads.
- **`too_many_keys` diagnostic.** A `(form …)` declaring more than
  `Plugin.MAX_FORM_KEYS` (= 64) keys is rejected at manifest-load time
  and the trailing keys are truncated. Validators `comptime`-assert
  the bitset coupling so the required-key tracker can never silently
  alias past index 63.
- **SJON LSP.** `zig build lsp` (native, `lsp-kit` over stdio) and
  `zig build wasm-lsp` (browser, hand-rolled JSON-RPC). Diagnostics,
  hover, completion (form-head snippets + key completion), signature
  help (multi-sig overload aware), folding ranges, inlay hints,
  document symbols, formatting, code actions for
  `ambiguous_form` / `missing_required_key` /
  `expr_kvpair_not_allowed`, find-references, prepare-rename, rename,
  and watched-file schema reloads via `sjon-project.sjon`.
- **`KeySpec.default`** for static defaults on omitted optional keys
  (loader type-checks the default against the key's declared type),
  and **`ExprFunc.signatures`** for multi-signature overloads
  (`lerp`, `clamp`, `min`, `max`, …) — the validator narrows the
  candidate set tag-wise per positional argument and surfaces the
  remaining candidates' types in the `expr_type_mismatch` message.
- **Identifiers may carry `#` after the first character** so `C#4`,
  `F#m`, `Bb3` lex as single identifiers and feed naturally into
  closed-`:members` symbol kinds.
- **Portable positional flag-sets.** A form's `:positional` slot can
  declare an ordered `(flag-set (flag :name done :description "…"
  :link "https://…") (flag :name archived))` of boolean keyword flags
  instead of a single positional type. Flags carry optional
  `:description` / `:link` metadata. Wire-format-stable diagnostic
  codes: a document writing an undeclared flag trips `not_flag_member`;
  repeating a declared flag on one form (`(task :done :done)`) trips
  `duplicate_positional_flag`; a duplicate `(flag …)` *declaration* is
  rejected at manifest-load. Tree and Binary validator paths emit
  identical `(code, path)` pairs; the schema exporter surfaces the set
  as `x-sjon-positional-flags` and the TypeScript host carries the
  metadata through. See `docs/portable-manifest-v1.md`.
- **Staged, cross-plugin host lowering.** The single-pass lowering hook
  generalized into a staged pipeline: a per-stage worklist resolves
  each form's `:lowering :produces` targets across the loaded plugin
  aggregate, so one plugin's form can lower into another's. A
  produces-graph cycle is rejected at schema-aggregate time
  (`lowering_cycle`) — before any hook runs — so lowering is guaranteed
  to terminate; a qualified `<plugin>/<form>` target whose plugin was
  never loaded trips `lowering_target_plugin_absent` (distinct from
  `unknown_form`). New `sjon export-lowering-graph` CLI verb,
  `sjon_export_lowering_graph` WASM export, and web-host
  `exportLoweringGraph` expose the resolved graph.
- **`:walk-opaque` on `(key …)`.** `:walk-opaque true` tells the
  validator not to descend into a form-shaped value paired with the
  key — the value's head and inner contents are treated as opaque to
  the surrounding schema, while the slot-level `:type` check still
  runs. Lets a schema carry expression- or DSL-shaped subtrees it does
  not own. Honored identically on the tree and Binary IR validation
  paths. See `docs/portable-manifest-v1.md §4.5`.
- **Cross-host bit-identical trig.** `sin` / `cos` / `tan` route through
  a vendored f64 implementation (`src/trig.zig`) instead of the host
  libm, so they produce bit-identical results across hosts, platforms,
  and Zig versions — the same reproducibility guarantee the
  seeded-random suite already carries. Conformance pins the exact output
  bits across the Zig, Rust, and TypeScript hosts.
- **Per-call expression memory budget.** The evaluator now polls a
  per-call result-arena byte ceiling (`MAX_EVAL_BYTES`, 64 MiB) via
  `ArenaAllocator.queryCapacity` each step and returns
  `error.MemoryBudgetExceeded` — distinct from `DepthExceeded` and
  `OutOfMemory` — so a memory-heavy, step-light expression fails
  gracefully instead of OOM-ing the host. `evalWithRuntimeBudget` /
  `evalBinaryWithRuntimeBudget` take the budget as a parameter so tests
  can drive the trip with a small cap. See `docs/LANGUAGE.md §8.6`.

### Breaking changes

- **`Ast.MutableTree` and the `*Mutable` API are gone.** Phase 14
  retired the legacy pointer-tree representation entirely. The 9
  `*Mutable` peers in `root.zig` (`parseMutable`, `printMutable`,
  `validateMutable`, `toJsonMutable`, `fromJsonMutable`,
  `toJsonRootsMutable`, `fromJsonRootsMutable`, `toBinaryMutable`,
  `fromBinaryMutable`) are deleted; every operation now ships in a
  single canonical form that walks `Ast.Tree` directly. The
  `Ast.MutableNode`, `MutableForm`, `MutableVector`,
  `MutableFormChild`, `MutableKeywordPair`, `MutableTree` types are
  deleted, along with `Ast.fromLegacy` and `TreeBuilder.addLegacy`.
  Consumers that held `Ast.MutableTree` should call the bare-named
  entrypoint (`sjon.parse`, `sjon.fromJson`, `sjon.fromBinary`) and
  use Tree accessors (`tagOf` / `formHeader` / `vectorElements` /
  `kvpairHeader` / `numberOf` / `numberWithUnitOf` / `stringSlice`
  / `commentTexts`).
- **`Edit.applyEdit` is now a functional rebuild on `Ast.Tree`.**
  Same input shape, same output shape, same diagnostics; the
  internal allocation profile dropped from "two trees per edit" to
  "one tree + one rebuild".

### Added

- **`Ast.TreeBuilder.cloneNode(src_tree, src_idx)`** plus
  convenience builders `addForm`, `addVector`, `addKvpair`,
  `cloneCommentRange`. Lets any consumer express tree-to-tree
  projections in SoA without bridging through a pointer tree. Used
  internally by `Edit.applyEdit`'s functional rebuild.

- **Unit-suffixed numbers** (`4b`, `90deg`, `50%`, `250ms`, `1.5e2hz`).
  The lexer accepts ASCII letters or a single `%` after the numeric
  portion; `e`/`E` remains an exponent only when followed by a digit
  or sign. The parser splits at the first non-numeric byte and stores
  `(value: f64, unit: ?[]const u8)`. The SoA `Tree` gains
  `Tag.number_with_unit` (zero overhead for unitless numbers).
  Round-trips through Printer (canonical + lossless), Binary IR, and
  JSON.
- **`{"$num": [value, "unit"]}` JSON discriminator** in canonical
  mode. Decoding accepts a strict 2-element array of `[JSON number,
  JSON string]`. Lossy mode emits a bare number and drops the unit.
- **Binary IR wire tag `0x0A`** (`number_with_unit`) with payload
  `[f64 LE 8] [varint unit_pool_idx]`. The unit string is interned in
  the existing per-tree string pool; two nodes sharing a unit share
  one pool entry. Introduced at wire version `0x01`; old decoders fail
  loud with `error.InvalidTag` on the new tag.
- **`BinaryCursor.NodeKind.number_with_unit`** and
  `readNumberWithUnit(view) -> { value: f64, unit: []const u8 }`. The
  unit slice borrows from the underlying bytes (consistent with
  `readString` semantics).
- **Binary IR value-kind tags `0x0B`–`0x0E`; wire version → `0x04`.**
  Three forward-incompatible wire bumps followed `0x0A`, each adding a
  value-kind tag and rejecting old decoders with `error.InvalidTag`:
    - **v2** — `number_i64` (`0x0B`) / `number_u64` (`0x0C`), exact-integer
      tags so integers beyond f64's 2⁵³ mantissa round-trip losslessly.
    - **v3** — `date` (`0x0D`), payload `[i16 LE year][u8 month][u8 day]`
      (4 raw bytes, no string-pool interning).
    - **v4** — `time` (`0x0E`), payload `[u8 hour][u8 minute][u8 second]
      [u16 LE millisecond]` (5 raw bytes). This is the current wire
      version (`Binary.wire_version = 0x04`).
  `BinaryCursor` gains a `NodeKind` variant and a `read*` accessor per tag
  (`readNumberI64` / `readNumberU64` / `readDate` / `readTime`); exhaustive
  `NodeKind` switches need a new arm for each. See `docs/DESIGN.md` for the
  per-tag layout.

### Behavior changes

- `1ex` (digits + `e` + non-digit/sign letter) previously emitted a
  lexer-level `.invalid` token. It now lexes as a number with unit
  `ex`. `1e9`, `1e+9`, and bare `1e` are unchanged. `1e+x` (sign with
  no exponent digit) becomes a lexer-level `.invalid` instead of a
  `.number` span (`1e+`) followed by a parse-time diagnostic; both
  rejected the input but the error site moved earlier.
- `BinaryCursor.NodeKind` adds a variant. Downstream callers that
  exhaustively switch on `NodeKind` need a new arm.

### Internals

- **Single-source plugin meta-schema.** The meta-schema that validates
  `(plugin …)` manifests is generated from `meta.sjon` (the canonical
  source) behind a build-time fidelity gate; `MetaSchema.zig` is now a
  thin re-export of the generated literal. No manifest-facing behavior
  change — the model is simply single-source now.
- `Ast.NumberValue { value, unit }` survives the `MutableTree`
  retirement as an internal helper used by `Json.numberValueToJson`
  to encode the `{"$num": [value, "unit"]}` discriminator object.
  Public consumers reach the same shape via
  `tree.numberWithUnitOf(idx)` (returns `NumberWithUnit { value: f64,
  unit: []const u8 }`, where `unit` is always present — for unitless
  numbers, the tag is `Tag.number` and `numberOf` returns `f64`).

## 0.2.0 — SoA AST migration (Zig mastery audit, phases 1–6)

### Breaking changes

- **`Ast.Tree` is now the SoA representation** (was `Tree2` during the
  migration). Every public entrypoint in `sjon` (`parse`, `print`,
  `toJson`, `validate`, `evalExpr`, `toBinary`, `fromBinary`,
  `applyEdit`, …) operates on `Ast.Tree`. The legacy mutable
  pointer-tree is renamed `Ast.MutableTree` and exposed publicly only
  via `*Mutable`-suffixed entrypoints (`sjon.parseMutable`,
  `sjon.printMutable`, …). Most callers should use the bare names.
- **`evalExpr` signature change.** The bare `evalExpr` now takes
  `(gpa, *const Ast.Tree, Ast.NodeIndex, *const Env, Schema)`. The
  legacy `(gpa, *const MutableNode, …)` form is available as
  `evalExprMutable`.
- **Wire format unchanged.** The Binary IR magic, header, and pool
  layout are byte-identical across 0.1.0 and 0.2.0. Existing binaries
  decode without re-emit. Internally the encoder/decoder were rewritten
  to walk the SoA tree natively (no legacy bridge round-trip).

### Internals

- **AST is now `std.MultiArrayList(Node)`** with a packed 16-byte
  `Node = (tag: Tag, span: Span, data: Data)` layout. Form / kvpair /
  vector payloads spill into a `[]u32 extra_data` buffer; strings live
  in a single concatenated pool indexed by `string_index[i]..[i+1]`.
  Comments are stored in a parallel SoA list keyed by
  `leading_comments_index[node]` and `trailing_comments_index[node]`.
- **Indices are typed enums** (`NodeIndex`, `StringIndex`,
  `ExtraIndex`) with `invalid = maxInt(u32)` sentinels. A
  default-zeroed index can never accidentally point at the root.
- **Iterative Expr evaluator.** `Expr.eval2` (the new bare `eval`)
  drives an explicit `Frame2` stack over `NodeIndex` values; no host
  recursion. Bounded by `MAX_FRAMES = MAX_DEPTH * 4`.
- **Parse-then-bridge pipeline.** `Parser.parseTree2` produces the
  SoA tree by parsing into the legacy mutable tree first, then
  bridging via `Ast.fromLegacy`. The bridge dupes comment text into
  the destination arena so the SoA tree is self-contained. A native
  one-pass producer is a follow-up optimisation.

### Mastery alignment

- `StaticStringMap` for keyword lookup (`Lexer.classifySymbol`).
- Comptime `@sizeOf` / `@alignOf` asserts on every wire-format-bearing
  struct in `Binary.zig`.
- `FailingAllocator` OOM regression tests for every public entrypoint
  (`src/oom_tests.zig`).
- `std.testing.fuzz` harnesses for Lexer / Parser / `Json.fromJson` /
  `Binary.fromBinary` panic-free invariants (`src/fuzz.zig`).
- `tests/` path entry in `build.zig.zon` removed (tests are in-source).
- Module / function doc comments cover invariants, complexity, and
  allocation behaviour.
- `docs/DESIGN.md` captures the architecture.

### WASM size

- `sjon-binary.wasm.gz` ≈ 21 KB (cap 30 KB).
- `sjon.wasm.gz` ≈ 72 KB (cap 80 KB).

## 0.1.0 — JSON bridge redesign (phases C1–C6)

### Breaking changes

- **Mode rename.** `Json.Mode.strict` is now `Json.Mode.canonical`;
  `Json.Mode.relaxed` is now `Json.Mode.lossy`. The WASM
  `sjon_to_json` mode strings rename correspondingly: `"strict"` →
  `"canonical"`, `"relaxed"` → `"lossy"`. No transitional aliases.
- **Symbols round-trip.** Symbols (e.g. `r` inside
  `(let [r 0.5] (vec3 r r r))`) now encode as `{"$sym": "name"}` in
  canonical mode and as bare strings in lossy mode. They previously
  collapsed to strings unconditionally, which broke re-evaluation of
  safe expressions after a JSON round-trip.
- **Reserved-key sigil escape.** User keys whose name starts with `$`
  encode as `$$name` and decode back to `$name`. Form heads literally
  starting with `$` are escaped the same way. Existing trees with no
  `$`-prefixed keys are unaffected.
- **Unknown discriminators are loud.** Decoding a JSON object that
  carries a `$`-prefixed key which is not a recognised discriminator
  (`$form`, `$ns`, `$children`, `$expr`, `$kw`, `$sym`, `$roots`) and
  is not a `$$`-prefixed user key now raises
  `error.UnknownDiscriminator`. Previously such keys were silently
  dropped, allowing misshapen encodings to round-trip with hidden data
  loss.
- **Multi-root via `$roots`.** Tree-level `Json.toJson` /
  `Json.fromJson` continue to require exactly one root and raise
  `error.MultipleRoots` otherwise. The new `Json.toJsonRoots` /
  `Json.fromJsonRoots` (also re-exported from `root.zig`) emit and
  consume `{"$roots": [...]}` for multi-root trees. A stray `$roots`
  key on the tree-level decode path raises `error.MultipleRoots` so
  the caller is steered to the wrapper API.

### Contract

The `canonical` mode now guarantees canonical-print byte equality
across `parse → toJson → fromJson`:

> `Printer.print(.canonical, parse(s))` ≡
> `Printer.print(.canonical, fromJson(toJson(parse(s), .canonical), .canonical))`

Spans, comments, and the original source bytes are explicitly out of
scope; for comment-preserving and span-preserving round-trip, use the
Binary IR (`Binary.toBinary` / `Binary.fromBinary` with the relevant
flag-gated presets).

### Tests

`fixtures/json_roundtrip.sjon` plus a property test in `src/Json.zig`
walk every top-level form in the fixture, encode → decode → canonical
print, and assert byte equality against the canonical print of the
original. Targeted regression tests pin the symbol round-trip,
reserved-key collisions (`(thing :$form "x")`, `($form a b)`),
unknown-discriminator rejection, comment dropping, and the
multi-root wrapper round-trip.
