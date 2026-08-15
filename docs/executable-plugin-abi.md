# Executable Plugin ABI

> **Plugin Model v1 sub-spec.** This document defines the detailed WASM
> sidecar ABI under [`plugin-model-v1.md`](plugin-model-v1.md). It covers
> executable expression-function bodies only; static Zig plugins,
> portable manifest declarations, and host-owned lowering are separate
> layers.
>
> The wire-form for plugin-supplied expression-function bodies. A plugin
> ships a `.sjon` manifest *plus* a paired `.wasm` binary; the binary
> exports each function the manifest references via `:impl "wasm:<name>"`.
> The Web, Rust, and Zig-native hosts instantiate the binary, run
> pre-flight against the required export set, and dispatch each call
> through a shared binary wire format. The Zig-native CLI links
> libwasmtime when built with `-Dplugin-exec=true` (the default);
> passing `-Dplugin-exec=false` falls back to declarative-only loading,
> which raises `error.PluginFuncNotImplemented` on any wasm-backed
> dispatch (silently swallowed by the host's eval pass).
>
> Companion to `docs/portable-manifest-v1.md`, which covers the manifest
> wire-form. This document covers the binary wire-form for executable
> plugin bodies. Hosts that only validate (LSPs, doc tooling) MAY ignore
> this spec entirely; they continue to load manifests under the
> portable-manifest spec and treat `:impl` as opaque.

## Status

Current ABI version: **`2`**. The wire codec carries seven tags
(`number` / `boolean` / `nil` / `string` / `keyword` / `vector` /
`form`); `Tag.form = 0x07` is what makes plugin expr-funcs able to
accept or return forms (e.g. `(count-done [(todo …) …])`). SJON is 1.x;
the version-bump history in §8.1 records the v1 → v2 transition.

The seams the ABI builds on already exist in the tree
(`Plugin.ExprFunc.Impl`, `Resolver.Resolution`, `Expr.applyFunction`,
the framing convention in `wasm_common.zig`); the ABI-specific pieces
are the required export set, the binary value encoding, and the
loader/runtime layer that binds `:impl "wasm:<name>"` strings into
function pointers.

**Execution scope: Web + Rust + Zig native hosts.** All three run the
full pre-flight + dispatch loop end-to-end; cross-host parity is
exercised by the `conformance/cases/plugin-exec-*` corpus on every
host. The native runtime adapter (`src/PluginRuntime.zig` +
`src/runtimes/wasmtime.zig`) binds the same wasmtime C API the Rust
host uses, so trap semantics and per-frame caps are bit-identical.
TS-parity stays declarative-only by design (§15.5). Builds that pass
`-Dplugin-exec=false` opt back into declarative-only loading and skip
the `plugin-exec-*` cases — useful when libwasmtime isn't available
on the host system.

## 1. Scope and guarantees

### 1.1 In scope

- Expression-function bodies (`expr-func` declarations whose `:impl` is
  a `wasm:<name>` reference) supplied by a plugin's WASM binary.
- A small fixed export set on the plugin side, a fixed-shape allocator
  protocol, and a binary encoding for `Expr.Value` arguments and results.
- Per-host integration on Web (`WebAssembly`), Rust (wasmtime), and
  Zig native (libwasmtime via the C API, opt-in via `-Dplugin-exec`).
  See Status.
- A diagnostic taxonomy that surfaces ABI mismatches, missing exports,
  forbidden imports, traps, and post-call type errors at byte-identical
  `(code, path)` pairs across hosts.

### 1.2 Out of scope

- Form *lowering* by the WASM sidecar. Host-owned lowering exists as a
  separate Plugin Model v1 layer; manifests declare the contract and
  hosts register hooks.
- Computed defaults, executable validators, lifecycle hooks (`init`,
  `dispose`), document-execution semantics, side effects.
- Capability-aware sandboxing (filesystem / clock / randomness / network
  imports). The current ABI has zero plugin-visible capabilities.
- Plugins that mutate runtime state across calls.
- Hot reload, plugin upgrade across host sessions, cross-plugin calls.
- Plugins that extend the grammar at runtime — the manifest still owns
  every value-kind, form-head, and signature decision.

### 1.3 Why this exact boundary

Three constraints shaped the cut:

1. **`Schema.init` must stay pure** (`src/Schema.zig:35`). All plugin
   loading, including WASM instantiation and impl binding, lives upstream
   in the new loader layer. The schema layer never sees a runtime.
2. **`Expr.applyFunction` should stay unchanged** (`src/Expr.zig:1331`).
   Dispatch is already through `ExprFunc.impl`; the ABI fills that slot
   via host-built closures and the dispatcher is none the wiser.
3. **Runtime semantics SJON has not yet defined** (forms that "do"
   something, lifecycle, side effects) cannot be specified by an ABI.
   The current ABI stops exactly where today's evaluator stops: pure
   functions over `Expr.Value`.

## 2. What this builds on

| Seam | File:line | Role |
| --- | --- | --- |
| `Plugin.ExprFunc.Impl` | `src/Plugin.zig:319-322` | Function pointer slot. Used by Zig-host-builtin plugins; wasm-backed expr-funcs route through `wasm_export_name` instead and leave `impl == null`. |
| `Plugin.ExprFunc.wasm_export_name` | `src/Plugin.zig` | Set by the manifest loader when `:impl "wasm:<name>"` is parsed. `Expr.applyFunction` dispatches into the host adapter when this slot is non-null and `impl` is null. |
| `Resolver.Resolution.wasm_bytes` | `src/Resolver.zig:44-56` | Manifest envelope's optional wasm sidecar; pre-flighted by every executing host (Web, Rust, Zig native when `plugin_exec=true`). |
| `Expr.applyFunction` | `src/Expr.zig:1331-1347` | Branches: `impl` non-null → call directly; otherwise `wasm_export_name` non-null → invoke via `wasm_plugin_invoker` (wasm32 → host import; native + `plugin_exec=true` + non-null runtime → `PluginRuntime` dispatch); otherwise → `PluginFuncNotImplemented`. |
| `Schema.init` | `src/Schema.zig:35-39` | Unchanged. Receives fully-bound plugins. |
| `wasm_common.frame` | `src/wasm_common.zig:25-43` | `[u32 ok][u32 len][u8 payload]`. The plugin-side return frame uses the same shape (§9.4). |
| `wasm_host_resolver.zig` resolver bridge | `src/wasm_host_resolver.zig:139` | Routes resolver-supplied `wasm_bytes` to the host adapter for pre-flight + dispatch (Web + Rust). Native uses `Host.preflightWasmIfPresent` (`src/Host.zig`) against `PluginRuntime` directly; falls back to declarative-only when `plugin_exec=false`. |
| `PluginRuntime` | `src/PluginRuntime.zig` | Native instance pool keyed by manifest `:name`. Pre-flights wasm bytes, owns per-plugin wasmtime stores, dispatches §11 alloc/copy/call/copy/free for every `:impl "wasm:<name>"` call. Opt-in via `-Dplugin-exec` (default ON). |
| `runtimes/wasmtime.zig` | `src/runtimes/wasmtime.zig` | Thin `extern "c"` wrapper over the wasmtime C API used by `PluginRuntime`. Layout chosen so a second backend can ship as `src/runtimes/<name>.zig` without renaming. |
| `ManifestLoader` `:impl` parser | `src/ManifestLoader.zig:694-696` | Already accepts `:impl "wasm:..."` as a binding-ref string. The new behaviour is downstream. |

## 3. Plugin package shape: sidecar

A plugin is two files:

```
my-plugin/
  plugin.sjon    ;; manifest, parsed by ManifestLoader
  plugin.wasm    ;; binary, instantiated by the host runtime
```

Pairing rules:

- The manifest's `:impl "wasm:<name>"` references resolve against the
  paired binary's exports. There is no manifest field that names the
  binary path; pairing is the resolver's job (§4).
- One manifest, one binary. Multi-binary plugins are reserved for a
  future ABI bump.
- The manifest parses identically whether or not a binary is present.
  Hosts that only validate can ignore the binary; hosts that evaluate
  expressions must surface a diagnostic when the binary is missing
  (§4.3, §17 `plugin_wasm_required`).
- No magic auto-discovery. `FilesystemResolver` conventions (e.g.
  "look for `<manifest-stem>.wasm` next to the manifest") are defined
  alongside D7 in resolver-specific docs, not by this spec.

## 4. Resolver protocol

### 4.1 Envelope reshape

`Resolver.Resolution` is reshaped from a three-armed union into a
manifest envelope:

```zig
pub const Resolution = union(enum) {
    manifest: struct {
        source: []const u8,    ;; SJON manifest text
        wasm:   ?[]const u8,   ;; paired binary, or null for declarative-only
    },
    failure: ResolverFailure,
};
```

The variant has no in-tree consumers beyond the host-resolver bridge; the
shape change goes in directly with no parallel/deprecation tier.

### 4.2 Variant semantics

| Manifest declares | Resolver returns |
| --- | --- |
| only `host:*` impls or no impls | `manifest{source, wasm: null}` |
| any `wasm:*` impl | `manifest{source, wasm: <bytes>}` |
| anything but resolution failed | `failure{code, detail}` |

### 4.3 New diagnostic from the loader

If a manifest references one or more `wasm:*` impls but the resolver
returned `wasm: null`, the loader emits `plugin_wasm_required` at the
`:impl` reference's span. (See §17 for the full diagnostics table.)

### 4.4 What `:hash` hashes

`(use-plugin "x" :hash "sha256-<hex>")` pins the SHA-256 of the byte
sequence carried by `Resolution.manifest.wasm` — i.e. the entire,
unmodified content of the sidecar binary as the resolver handed it
back. The host (`Host.enforceHashPin` in `src/Host.zig`) does not
normalise, decompress, header-strip, or otherwise transform the
bytes before hashing.

- **Algorithm.** SHA-256 (NIST FIPS 180-4). The wire-format prefix is
  literally `sha256-`; no other algorithm name is currently accepted.
- **Subject.** The exact bytes in `Resolution.manifest.wasm`. For the
  Zig `FilesystemResolver` and the Node `createNodeFsResolver`, that is
  the on-disk `.wasm` file read whole. A resolver that fetches over
  HTTP, decompresses a stream, or pulls from a content-addressed store
  hashes whatever bytes it ultimately returns — pairing the hash with
  the *post-transformation* payload is the resolver's contract.
- **Format.** `sha256-` followed by exactly 64 lowercase hex digits
  (`[0-9a-f]`). Uppercase, mixed case, base64, length mismatch, or any
  other prefix all emit `plugin_hash_mismatch` with detail "malformed
  hash pin". Strict casing keeps reproducibility audits deterministic
  (a manifest with `sha256-DEADBEEF…` and one with `sha256-deadbeef…`
  must not be treated as interchangeable).
- **Equivalence.** The expected pin value is what these commands
  produce when run against the sidecar binary:
  ```
  shasum -a 256 plugin.wasm | cut -d' ' -f1     # → 64 hex chars
  openssl dgst -sha256 -hex plugin.wasm         # → "SHA2-256(plugin.wasm)= <hex>"
  sha256sum plugin.wasm                         # GNU coreutils
  ```
  Prepend `sha256-` to the hex digits and quote the result in
  `:hash "…"`.
- **Declarative-only manifests.** When `Resolution.manifest.wasm` is
  `null`, the host has no bytes to hash. A hash pin in that situation
  still emits `plugin_hash_mismatch`, with detail "pin set but the
  resolved manifest has no wasm to hash" — by design: pinning a hash
  on a manifest that has nothing to verify is a user error.
- **Order of operations.** The hash check runs *before*
  `loadResolvedManifest` parses the manifest source. A corrupted or
  swapped wasm fails fast, before name and version are even consulted;
  this keeps the diagnostic close to the file the user is auditing.

## 5. Plugin ABI — required exports

Every plugin binary MUST export the following:

### 5.1 `sjon_plugin_abi_version`

```wat
(func (export "sjon_plugin_abi_version") (result i32))
```

```zig
export fn sjon_plugin_abi_version() u32 { return 2; }
```

Returns the ABI version the plugin was compiled against. The host calls
this immediately after instantiation, before any function dispatch. A
mismatch is a load-time failure (§8).

### 5.2 `sjon_plugin_alloc`

```wat
(func (export "sjon_plugin_alloc") (param i32) (result i32))
```

```zig
export fn sjon_plugin_alloc(len: u32) u32 { ... }
```

Allocates `len` bytes inside the plugin's linear memory and returns a
pointer (offset). Returns `0` on failure. The host calls this to write
argument bytes into the plugin's address space (§11).

### 5.3 `sjon_plugin_free`

```wat
(func (export "sjon_plugin_free") (param i32) (param i32))
```

```zig
export fn sjon_plugin_free(ptr: u32, len: u32) void { ... }
```

Frees a buffer previously returned by `sjon_plugin_alloc`. The host
calls this for both the argument buffer and the result frame; sizes are
known to the host (`args_len` was passed in, `frame_len` is encoded in
the result frame's header, plus `HEADER = 8`).

### 5.4 One export per `wasm:` impl

```wat
(func (export "<name>") (param i32) (param i32) (result i32))
```

```zig
export fn <name>(args_ptr: u32, args_len: u32) u32 { ... }
```

For each `:impl "wasm:<name>"` the manifest declares, the binary MUST
export exactly that `<name>`. The function reads `args_len` bytes
starting at `args_ptr` (decoded per §9.3), runs the body, and returns a
pointer to a framed result buffer (§9.4) it allocated via
`sjon_plugin_alloc`. The host reads, copies into its own arena, and
frees the frame.

### 5.5 Cross-ref provider exports

A `(cross-ref-provider … :impl "wasm:<name>")` export is an ordinary
plugin export: same signature, same framing, same codec, same
capabilities. What is fixed is its *value contract*.

| direction | value | meaning |
| --- | --- | --- |
| host → plugin | one `.string` argument | the opaque source bytes read from the target instance's `:source-key` |
| plugin → host | a `.vector` whose every element is a `.string` | the extracted member names |

Elements are matched byte-for-byte against document symbols, exactly
like a `:name-key` name. Providers SHOULD emit valid symbol spellings; a
name no symbol can take (`"foo bar"`) is legal and simply never matches.
The host does **not** re-lex what a provider returns.

The element type is strict. A `.keyword` where a `.string` was promised
is a contract violation, not a convenience the host absorbs — a lenient
reader here is how two hosts start disagreeing about the same plugin.
Violations (non-vector result, non-string element, more than 4096 names
from one source) surface as `cross_ref_extraction_failed` against the
document's source value; they get no code of their own, because from the
document's side the provider simply did not answer.

**No ABI bump.** `PLUGIN_ABI_VERSION` stays 2. Nothing in the transport
changed: this section constrains what a particular export means, not how
exports are called. A host that predates providers and one that has them
run the same plugin binaries identically — a provider export it does not
know about is just an export it never calls.

**Determinism.** The §13 guarantee carries over unchanged and is what
makes the feature safe: a provider sees only bytes from the document it
is extracting, has no clock, no randomness, and no IO, and returns a
list of names. It cannot observe anything, so registering names from it
keeps the document a closed, reproducible artifact. Hosts extract once
per distinct `(provider, source)` pair and reuse the answer; a provider
that returned different names for the same bytes would be violating this
guarantee, not exposing a caching bug.

## 6. Plugin ABI — optional / future-reserved exports

`sjon_plugin_init` and `sjon_plugin_dispose` are reserved names for a
future lifecycle bump. Plugins MAY define them (the names are theirs
to spend); current hosts MUST NOT call them. Treating them as no-ops
keeps plugins forward-compatible with a future host that adopts
lifecycle.

No other reserved names. Plugins are free to use any other export name
that does not collide with the required set.

## 7. Host ABI — imports

### 7.1 Import set: empty

Plugin modules MUST declare no imports. The runtime baseline
(`memory`, `table`) is exported by the plugin, not imported. The host
instantiates with an empty imports object.

### 7.2 Reserved namespace

The `env.sjon_host_*` namespace is reserved for a future capabilities
bump. Current hosts MUST refuse to instantiate any plugin that imports
*any* name (regardless of namespace) and emit `plugin_import_forbidden`
at load time, naming the offending import.

The "no imports" stance is what makes the current ABI trivially
deterministic and trivially sandboxed (§13). When capabilities land
they will arrive with a manifest `:capabilities` declaration;
introducing them earlier would couple the ABI to a security model we
have not yet designed.

## 8. ABI version negotiation

- Current ABI version constant: **`2`**.
- Plugin reports via `sjon_plugin_abi_version()`.
- Host reads it once per instantiation, before dispatching any export.
- Mismatch policy: host refuses to load. Diagnostic
  `plugin_abi_mismatch` carries `expected: 2, got: <N>` in `detail`.
- A future bump is required for any change to the wire-format encoding,
  the required-export set, the diagnostic-code numbering surfaced by the
  ABI, or the import allowlist.

### 8.1 Version-bump history

- **v1 → v2**: added `Tag.form = 0x07` to the wire codec (§9.1) so
  plugin expr-funcs can accept or return forms (e.g. `(count-done
  [(todo …) …])`). Plugins built for the v1 ABI must be rebuilt
  against the new constant; the wire format is otherwise identical
  for tags `0x01` through `0x06`.

## 9. Wire format — `Expr.Value` binary encoding

This is a fresh encoding for the executable plugin ABI. It does not
reuse the JSON encoder in `src/wasm_common.zig:49-81` (which is one-way
and host-side only) and does not reuse the binary Tree IR (which
encodes parsed AST, not runtime values).

### 9.1 Value tags

Seven `Expr.Value` variants (`src/Expr.zig`), seven tags. All
multi-byte integers are little-endian.

| Tag | Variant  | Payload |
| --- | -------- | ------- |
| `0x01` | number   | `f64` (8 bytes, IEEE-754 raw bits) |
| `0x02` | boolean  | 1 byte: `0x00` false, `0x01` true |
| `0x03` | nil      | (no payload) |
| `0x04` | string   | `u32 len` + UTF-8 bytes |
| `0x05` | keyword  | `u32 len` + UTF-8 bytes |
| `0x06` | vector   | `u32 count` + `count` encoded values |
| `0x07` | form     | `u32 head_len` + head bytes + `u32 ns_len` + namespace bytes + `u32 child_count` + `count` encoded values + `u32 kv_count` + `count` `[u32 key_len][key…][value]` pairs |

Distinct tags for `string` vs `keyword` — no JSON-style `$kw` discriminator
hack. The plugin sees the same kind distinction the evaluator does.

NaN and ±inf cross verbatim via the `f64` raw bits; the encoder does
not special-case them. The JSON path's `"nan"` / `"inf"` strings are a
JSON-escape concession, not a value-model concession.

**Unit metadata: explicitly absent.** `Expr.Value` carries no unit (per
the project memory note: `number_with_unit` lives only in the AST,
runtime values are unit-free). If `Expr.Value` ever grows a unit
variant, that change bumps the ABI again.

**Form payload notes.** `namespace` is the empty byte sequence (`u32`
zero followed by zero bytes) when the form is bare (no `qualifier/`
prefix). `head` MUST be non-empty for a valid form. `children` is the
positional-child list in source order; `kvpairs` is the keyword-arg
list in source order. Each kvpair `key` is the bare keyword name
without the leading `:`. Form descent counts as a depth level for the
host's `MAX_VALUE_DEPTH` cap (same as vector).

### 9.2 Argument list (host → plugin)

```
[u32 LE arg_count][value][value]...
```

Written into the plugin buffer the host obtained via
`sjon_plugin_alloc`. Total length matches the `args_len` argument the
host passes to the export.

### 9.3 Result frame (plugin → host)

```
[u32 LE ok][u32 LE len][u8 payload[len]]
```

Same shape as `wasm_common.HEADER` (`src/wasm_common.zig:25-43`).
- `ok = 1`: `payload` is one encoded value (§9.1).
- `ok = 0`: `payload` is a structured error:
  ```
  [u32 LE code_len][code utf-8][u32 LE detail_len][detail utf-8]
  ```

The plugin allocates the frame via its own `sjon_plugin_alloc`. The host
reads `ok` and `len`, copies `payload`, then calls
`sjon_plugin_free(frame_ptr, 8 + len)` (the `8` is the header).

**Host-side cap.** Web and Rust hosts cap the reported `len` at
**16 MiB** before allocating the mirror buffer. A plugin that advertises
a larger `len` is rejected as `plugin_func_alloc_failed` with the size
and cap in the diagnostic detail; the bogus frame is not freed (the
host doesn't trust the size). The bound is per-call and comfortably
exceeds any realistic codec-encoded value.

### 9.4 Byte-level examples

`(double 21) → 42`:

- Args buffer (12 bytes): `01 00 00 00` (count=1) `01` (number tag)
  `00 00 00 00 00 00 35 40` (f64 21.0).
- Result frame (17 bytes): `01 00 00 00` (ok=1) `09 00 00 00` (len=9)
  `01` (number tag) `00 00 00 00 00 00 45 40` (f64 42.0).

Returning the keyword `:ok`:

- Result frame (15 bytes): `01 00 00 00` (ok=1) `07 00 00 00` (len=7)
  `05` (keyword tag) `02 00 00 00` (str_len=2) `6f 6b` ("ok").

Returning a 3-vector `[1 2 3]`:

- Result frame (40 bytes): `01 00 00 00` `20 00 00 00` (len=32)
  `06 03 00 00 00`
  `01 00…f0 3f` (1.0)  `01 00…00 40` (2.0)  `01 00…08 40` (3.0).

## 10. Error model

### 10.1 Plugin-reported errors (`ok = 0`)

The plugin returns a result frame with `ok = 0` and a `(code, detail)`
pair. Enumerated codes:

| Code | When |
| --- | --- |
| `type-mismatch`  | runtime type check the validator could not catch |
| `arity`          | argument count outside the plugin's expectation |
| `domain`         | value outside a plugin-defined domain (e.g. negative root) |
| `out-of-memory`  | plugin's own allocator failed |
| `internal`       | plugin's own assertion / bug |

The host maps a plugin-reported error to a diagnostic with code
`plugin_func_failed` and `detail` equal to the plugin-supplied
`(code, detail)` (encoded as `<code>: <detail>`).

### 10.2 Plugin trap

If the plugin runtime traps (`unreachable`, OOB memory, divide-by-zero
on `i32.div_s` with `INT_MIN/-1`, etc.), the host catches the trap and
maps it to `plugin_func_trapped` with the runtime-supplied trap message
in `detail`. The error is anchored at the `(expr ...)` call's span.

### 10.3 Result-type mismatch

If the plugin returns a value whose type does not match the manifest's
declared `:result`, the host emits `plugin_func_result_type` with
declared and actual types in `detail`.

### 10.4 Allocator failure

`sjon_plugin_alloc` returning `0` for the args buffer maps to
`plugin_func_alloc_failed` (host-side); plugin-side allocator failures
inside the body are reported by the plugin as `out-of-memory` (§10.1).

## 11. Memory ownership

Per-call. Plugins do not retain buffers across calls.

```
host -> plugin  (args)
  1. host computes args_len = encoded(args).len
  2. ptr = plugin.sjon_plugin_alloc(args_len)
  3. host writes encoded args into plugin memory[ptr..ptr+args_len]
  4. result_ptr = plugin.<fn>(ptr, args_len)
  5. host reads frame at result_ptr  (header tells it the length)
  6. host copies payload into its own arena
  7. host calls plugin.sjon_plugin_free(result_ptr, 8 + frame_len)
  8. host calls plugin.sjon_plugin_free(ptr, args_len)
```

Contract:

- Plugins MUST NOT retain pointers into the args buffer after the
  exported function returns.
- Plugins MUST NOT retain pointers into the result frame after it has
  been returned to the host.
- Hosts MUST free both buffers via `sjon_plugin_free` before discarding
  the call.
- The plugin's linear memory is the plugin's own; the host never
  imports memory and never asks the plugin to share.

## 12. Execution model

- **Load.** The host instantiates the WASM module once per host session
  per plugin. Re-instantiation between calls is forbidden.
- **Init.** Deferred. Plugins are stateless. Module-level globals MAY
  hold immutable lookup tables; mutable module state across calls is
  undefined behaviour in the current ABI (and a future capability tied
  to a manifest declaration).
- **Call.** Synchronous. The host blocks until the function returns or
  traps. Plugins cannot call back into the host (no host imports).
- **Determinism.** Required by contract. The empty import set makes
  nondeterminism nearly impossible: the plugin sees no clock, no
  randomness, no IO. The conformance harness enforces the contract by
  comparing host outputs byte-for-byte.
- **Limits.** Fuel and timeouts are host policy, not part of the ABI.
  Hosts SHOULD enforce a budget; the doc names recommended ranges and
  conformance fixtures stay well below any reasonable limit.

## 13. Capabilities and sandboxing

| Layer | Guarantee |
| --- | --- |
| Imports | empty. No `env.*`, no `wasi_*`. |
| Memory | per-plugin linear memory. Hosts do not share memory. |
| Determinism | no clock / random / IO accessible to the plugin. |
| Trap isolation | host catches traps; the SJON evaluator does not unwind. |
| Fuel | host-discretion (off by default in wasmtime; absent in browser engines). |

Per-host runtime differences:

- **wasmtime (Rust)**: `Engine::default()`; fuel optional; no WASI
  linkage. The Linker is empty. (Zig native has no Zig-side runtime
  adapter today; bringing one up is parked for a later milestone.)
- **WebAssembly (Web)**: `WebAssembly.instantiate(bytes, {})`. Engine
  provides no fuel knob; trap behaviour matches the WebAssembly spec.

The ABI does not promise that two engines will reject every invalid
plugin in identical ways at instantiation time. It does promise that a
plugin that *does* instantiate produces byte-identical results across
hosts when the conformance harness drives it.

## 14. Type-checking handshake

- **Pre-call.** The validator checks declared `:params` / `:rest`
  against the call site and, when a typed slot receives a form, checks
  the form's declared expression result type against the slot. Plugins
  receive only well-typed args.
- **Post-call.** The host re-checks the returned value against
  `:result`. Mismatch → `plugin_func_result_type` (§10.3).
- **Plugin-internal.** Plugins MAY do additional runtime checks the
  validator could not catch (domain constraints, runtime arity for
  variadic forms) and report them as `(type-mismatch | arity | domain)`
  via the structured error path (§10.1).

The handshake keeps the validator's contract intact: the validator does
not know or care whether an impl is a host function or a wasm export.

## 15. Per-host integration

The execution path runs on Web, Rust, and Zig native (opt-in via
`-Dplugin-exec`, default ON). TS-parity is declarative-only by design
(§15.5).

### 15.1 Zig native — execution path

- `src/PluginRuntime.zig` — owns the native plugin-instance pool. One
  `PluginRuntime` per `Host.validateDocument` / `Host.evalExpr` call,
  lazy-initialized when a wasm-bearing manifest first resolves. Holds
  a shared `wasmtime.Engine` + `wasmtime.Linker` and a
  `StringHashMap` keyed by manifest `:name`. `register()` runs the
  same pre-flight order Web + Rust use (compile → forbid imports →
  instantiate against empty linker → ABI version check →
  `sjon_plugin_alloc`/`_free`/`memory` exports → declared
  `wasm:<name>` exports); pre-flight failures collapse to the matching
  diagnostic code at the `(use-plugin …)` span.
- `src/runtimes/wasmtime.zig` — thin Zig wrapper over the wasmtime C
  API (engine/store/module/linker construction, `wasmtime_func_call_
  unchecked` dispatch keyed on `wasmtime_val_raw_t`, bounded memory
  read/write). Trap handling uses the out-parameter form — traps
  never longjmp through Zig.
- `src/Host.preflightWasmIfPresent` — pre-flight callsite, sits beside
  `enforceHashPin` on the wasm-bytes branch. On `error.Rejected` pops
  the plugin from `plugin_results` and appends the failure as a
  manifest-phase diagnostic; on success the plugin stays registered
  and `runEvalPass` dispatches through the runtime.
- `src/wasm_plugin_invoker.zig` — three-path dispatcher: wasm32 →
  `env.sjon_host_invoke_plugin` host import; native + `plugin_exec=
  true` + non-null `PluginRuntime` → `invokeViaNativeRuntime` (encodes
  args, calls `PluginRuntime.invoke`, decodes via the same
  `decodeResponseFrame` helper the wasm path uses); native +
  `plugin_exec=false` → `error.PluginFuncNotImplemented`. The
  PluginRuntime import is comptime-gated so the wasm artifact never
  pulls in libwasmtime.

Build: `-Dplugin-exec=true` (default on native) links libwasmtime via
the system path probe in `build.zig`'s `linkSystemWasmtime` helper.
`-Dplugin-exec=false` skips the link, compiles out the runtime
branches, and makes the dispatcher return `PluginFuncNotImplemented`
on any wasm-backed call — useful for contributors without a libwasmtime
install. Forced off on wasm32 targets regardless of the flag (the
WASM build dispatches through the host import, not a linked runtime).

### 15.2 Web/TS — execution path

- `hosts/web/SjonHost.ts` — owns the plugin-instance pool. The
  `env.sjon_host_resolve` bridge runs pre-flight inline when the
  resolver delivers wasm bytes (instantiate → check empty imports →
  call `sjon_plugin_abi_version()` → verify required + declared
  exports); pre-flight failures collapse to `Resolution::Failure` with
  the matching diagnostic code. The `env.sjon_host_invoke_plugin`
  handler does per-call alloc/copy/call/free across the two-instance
  memory boundary, frames the result back into sjon memory, and maps
  traps + null-pointer cases to synthetic `_internal_trap` / `_alloc`
  codes.

Memory-aliasing protections that already apply to host wasm
(`hosts/web/sjon-reader.ts`) extend to plugin wasm: views into
plugin memory are valid only for the immediate copy-out window, never
across another `instance.exports.*` call that might grow memory.

### 15.3 Rust — execution path

- `hosts/rust/src/wasm.rs` — same shape as Web. `StoreData` carries a
  shared `wasmtime::Engine` plus a `HashMap<String, PluginInstance>`
  pool keyed by manifest `:name`. The resolver bridge runs the same
  pre-flight order (compile → empty imports → instantiate → ABI version
  → required + declared exports). The `env.sjon_host_invoke_plugin`
  linker callback mirrors the Web flow, using per-plugin `Store<()>` +
  `TypedFunc` handles for the dispatch.

### 15.4 Common across hosts

The wire format, the export names, the version constant, the diagnostic
codes. The implementations differ; the contract does not. Web, Rust,
and Zig native (when `plugin_exec=true`) must produce byte-identical
`(code, path)` diagnostic streams across the conformance corpus.

### 15.5 TS-parity host

Out of scope for D7. The TS-parity host validates declarative plugins
only and stays that way. D7 cross-host execution parity is between the
WASM-running hosts: Web and Rust.

## 16. Manifest integration

The only `:impl` scheme this ABI binds is `wasm:<export-name>`.
`host:<binding-ref>` and other schemes stay reserved/declaration-only in
portable manifests; they are not bound by this ABI.

Loader pipeline (host-agnostic shape; per-host modules listed in §15):

```
resolver        Resolver returns .manifest{source, wasm}
   ↓
host bridge     Web/Rust + Zig native (plugin_exec=true): if wasm bytes
                present, instantiate + pre-flight (ABI version, required
                + declared exports — expr-funcs and cross-ref providers
                alike, §5.5 — empty imports). Failures collapse to
                Resolution::Failure (Web/Rust) or a manifest-phase
                diagnostic (Zig native) with the matching pre-flight
                code. Zig native (plugin_exec=false) + TS-parity:
                passes the envelope through unchanged, no instantiation.
   ↓
ManifestLoader  parses source → Plugin.Plugin. :impl "wasm:<name>" is
                stored in ExprFunc.wasm_export_name (Impl stays null),
                or in CrossRefProvider.wasm_export_name for a
                (cross-ref-provider …).
   ↓
loader checks   if any expr_func has :impl "wasm:..." but wasm is null
                → plugin_wasm_required.
   ↓
extraction      (all executing hosts) Before validation, the host runs
                every declared cross-ref provider over the sources the
                document supplies and hands the validator a finished
                table — see `src/ProviderExtraction.zig`. Same dispatch
                as below; the validator itself never executes anything.
   ↓
runtime         (Web/Rust) Dispatch via env.sjon_host_invoke_plugin →
                host plugin pool. (Zig native, plugin_exec=true) Dispatch
                via PluginRuntime → wasmtime instance pool. (Zig native,
                plugin_exec=false) Expr.applyFunction raises
                PluginFuncNotImplemented for the wasm branch; the host
                eval pass silently swallows it.
   ↓
schema layer    Schema.init(plugins[]) — unchanged, sees only the
                declarative Plugin records.
```

On Zig native with `plugin_exec=true` (the default), the runtime step
dispatches through PluginRuntime; with `plugin_exec=false` the step is
a compile-time no-op (the `env.sjon_host_invoke_plugin` import isn't
declared in the native build either) and `Expr.applyFunction` returns
`PluginFuncNotImplemented`. The loader always emits
`plugin_wasm_required` when wasm bytes are absent regardless of the
build option.
The host-bridge instantiation is a Web/Rust-only seam.

`Schema.init` still receives fully-bound plugins. The schema layer
never sees the runtime, never sees an instance. Diagnostics emitted by
the loader (§17) are produced *before* `Schema.init` is called.

## 17. Diagnostic taxonomy

| Code | Path shape | When | Emitter |
| --- | --- | --- | --- |
| `plugin_abi_mismatch`       | plugin reference | `sjon_plugin_abi_version()` ≠ current constant (§8) | PluginLoader |
| `plugin_export_missing`     | `:impl` reference | manifest declares `wasm:foo`, binary has no `foo` export | PluginLoader |
| `plugin_import_forbidden`   | plugin reference | binary declares any import | PluginLoader |
| `plugin_wasm_required`      | `:impl` reference | manifest references `wasm:*` but resolver returned `wasm: null` | PluginLoader |
| `plugin_describe_invalid`   | plugin reference | reserved for a future self-describing bump; declared but unused | PluginLoader |
| `plugin_func_trapped`       | `(expr ...)` call | runtime trap during dispatch | runtime trap mapper |
| `plugin_func_result_type`   | `(expr ...)` call | returned value's type ≠ declared `:result` | post-call validator |
| `plugin_func_failed`        | `(expr ...)` call | plugin returned `ok=0` frame | dispatcher |
| `plugin_func_alloc_failed`  | `(expr ...)` call | `sjon_plugin_alloc(args_len)` returned `0`, plugin export returned a null pointer, or plugin reported a frame size exceeding the host cap (§9.3) | dispatcher |

All codes participate in cross-host conformance. The harness asserts
byte-equal `(code, path)` pairs across:

- Web + Rust + Zig native (when `plugin_exec=true`, the default) —
  every code in the table. Pre-flight codes
  (`plugin_abi_mismatch`, `plugin_export_missing`,
  `plugin_import_forbidden`) emit from the resolver bridge (Web/Rust)
  or from `Host.preflightWasmIfPresent` (`src/Host.zig`, Zig native);
  dispatch-time codes (`plugin_func_trapped`, `plugin_func_result_type`,
  `plugin_func_failed`, `plugin_func_alloc_failed`) emit from
  `wasm_plugin_invoker.invoke`. Exercised end-to-end by the
  `conformance/cases/plugin-exec-*` corpus.
- Zig native (when `plugin_exec=false`) and TS-parity —
  `plugin_wasm_required` from `src/Host.zig` when a declarative
  manifest is missing the executable artifact. The `plugin-exec-*`
  fixtures are skipped on these runners since they don't dispatch
  wasm exports.

## 18. Conformance fixtures

Layout: `conformance/cases/plugin-exec-<name>/` with:

- `document.sjon` — entry-point document; `(use-plugin …)` plus any
  data forms that exercise the case.
- `expected.sjon` — expected diagnostics (`(diagnostics …)` form).
- `sjon-project.sjon` — project file pointing at the sidecar manifest.
- `manifests/<plugin-name>.sjon` — plugin manifest.
- `manifests/<plugin-name>.wasm` — plugin binary, checked in. Rebuilt
  by `zig build plugin-fixtures`.

Current corpus (under `conformance/cases/plugin-exec-*`):

1. **`plugin-exec-double-eval/`** — `(double 21) → 42`. Smallest e2e.
   Proves load, instantiate, marshal number, call, demarshal number,
   free.
2. **`plugin-exec-trap/`** — plugin runs `unreachable` →
   `plugin_func_trapped`.
3. **`plugin-exec-func-failed/`** — plugin returns `ok=0` structured
   error frame → `plugin_func_failed` carrying plugin code + detail.
4. **`plugin-exec-alloc-failed/`** — plugin returns a frame whose
   header advertises a payload larger than the host cap →
   `plugin_func_alloc_failed`.
5. **`plugin-exec-result-type/`** — manifest declares `:result symbol`;
   plugin returns number → `plugin_func_result_type` at decode time.
6. **`plugin-exec-abi-mismatch/`** — plugin returns ABI version `99`
   → `plugin_abi_mismatch` at load time.
7. **`plugin-exec-export-missing/`** — manifest declares `wasm:halve`,
   binary lacks `halve` → `plugin_export_missing`.
8. **`plugin-exec-import-forbidden/`** — plugin imports
   `env.host_helper` → `plugin_import_forbidden`.
9. **`plugin-exec-keyword-roundtrip/`** — `(echo-tag :hello)` round-
   trips a keyword through `wasm:tag` (identity export). Pins the
   `0x04` vs `0x05` codec tag distinction across the plugin boundary.
   The arg slot is declared `any` because `Plugin.ValueType` has no
   `keyword` kind (`src/Plugin.zig:260-276`); the result slot is
   `symbol` because the type-comparison layer labels `Value.keyword`
   as `"symbol"` (`src/wasm_plugin_invoker.zig:230`).
10. **`plugin-exec-vector-roundtrip/`** — `(vec3-length [3.0 4.0 0.0])`
    encodes a vector of three numbers (tag `0x06`, count=3, three tag
    `0x01` numbers) into the args payload, dispatches `wasm:vec3_length`,
    and decodes `sqrt(x²+y²+z²)` back as a number. Proves nested-value
    (vector-of-number) round-trip; the happy-path `double` only
    crosses bare numbers.
11. **`plugin-exec-large-vector/`** — `(vector-sum [0 1 … 9999])`
    sums a 10k-element vector. Encoded args ~90 KB; stress-tests the
    host-side encoder buffer growth and pins that the per-call mirror-
    buffer cap (16 MiB header per §10) accepts realistic payloads
    while still rejecting the synthetic ~4 GiB `huge` frame.
12. **`plugin-exec-arity-violation/`** — `(double 1 2 3)` against an
    `:arity (fixed 1)` manifest; validator emits `arity_mismatch` at
    the call head, evaluator short-circuits dispatch via the gate in
    `Expr.applyFunction`. Proves the arity error path stays in the
    validator — the plugin's `double` export is never invoked.
13. **`plugin-exec-form-roundtrip/`** — `(form-arity (point :x 1 …))`
    and `(forms-arity-sum [(point …) (vec …)])` cross a form (tag
    `0x07`) and a vector-of-form payload through the plugin boundary;
    the plugin reads each form's `head_len/head/ns_len/ns/child_count/
    kv_count` fields and frames back the summed arity. Proves the
    §9.1 form payload encodes and decodes correctly; the prior
    nested-value coverage in `vector-roundtrip` only crossed
    `Tag.vector` over numbers.

Value assertions (`(values (value :index N :result <lit>))` in
`expected.sjon`) apply to the four fixtures where the wasm runtime is
expected to complete evaluation and the round-trip value is the
contract: `plugin-exec-double-eval` (`42`), `plugin-exec-vector-
roundtrip` (`5.0`), `plugin-exec-keyword-roundtrip` (`:hello`), and
`plugin-exec-form-roundtrip` (`3` and `5`). A regression that returns
the wrong value now fails Web + Rust conformance with `value mismatch
at index N`. `plugin-exec-large-vector` is intentionally excluded:
pushing 10k positional eval frames trips `Expr`'s `MAX_FRAMES`
(`MAX_EVAL_DEPTH × 4 = 1024`), so `Expr.eval` returns
`error.DepthExceeded` and `runEvalPass` silently swallows it (no
diagnostic, no value). The fixture's purpose is the codec / args-
encoder stress at the ~90 KB payload boundary, not the runtime sum;
its `expected.sjon` carries `(diagnostics)` only and a comment
explaining the omission.

The plugin-exec corpus is filtered out on TS-parity (declarative-only
by design) and on Zig-native builds with `-Dplugin-exec=false`. Web,
Rust, and default-build Zig-native runners walk the full corpus and
execute every case.

Out of scope for v2: stateful plugins, async plugins,
multi-export-per-fn plugins, plugins that define `_init` / `_dispose`.

## 19. Version history and reserved names

### Shipped in v2

- `Tag.form = 0x07` in the wire codec (§9.1) — enables form values to
  cross the codec in either direction. Used by the web-todo
  `(count-done …)` selector, where the plugin walks a vector of
  `(todo …)` forms and reads each form's `:done` kvpair.
- **Native Zig runtime adapter.** `src/PluginRuntime.zig` +
  `src/runtimes/wasmtime.zig` close the Web/Rust/Zig-native parity gap.
  The Zig CLI now executes every `:impl "wasm:<name>"` body through
  libwasmtime (opt-in via `-Dplugin-exec=true`, default ON). The full
  `conformance/cases/plugin-exec-*` corpus runs end-to-end on Zig
  native with byte-identical `(code, path)` diagnostics to the Rust
  host.

### Reserved names with no ABI behaviour in v2

Reserved so a later ABI version can assign them behaviour without
breaking v2 plugins. The reservation is normative; the behaviour is
not specified here.

- `sjon_plugin_init` / `sjon_plugin_dispose` — optional exports. A v2
  host never calls them; a plugin may declare them but must treat
  them as no-ops (the names are not the plugin's to spend; see §6).
- `env.sjon_host_*` — reserved import namespace. A v2 host refuses
  any plugin that imports anything (§7.2).
- `plugin_describe_invalid` — diagnostic declared in §17, never
  emitted by a v2 host.
