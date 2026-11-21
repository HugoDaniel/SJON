# sjon-host — Rust host wrapping `sjon.wasm`

Rust crate that wraps the same `sjon.wasm` artifact the JS web host
(`hosts/web/SjonHost`) and the typescript-parity reference use, exposing
`SjonHost::validate_document(source, options)` with byte-identical
`(code, path)` diagnostics. Built on top of [wasmtime].

This is the second WASM-backed host wrapper, after the JS host in
`hosts/web/`.

## Install

```sh
cargo add sjon-host@1.8.0
```

Requires Rust 1.92 or newer. The crate ships Rust sources and does not bundle
`sjon.wasm`. Download the matching artifact from the
[SJON 1.8.0 release](https://github.com/HugoDaniel/SJON/releases/tag/v1.8.0),
or build the matching source with Zig 0.16 using `zig build wasm`.
Pass its path to `SjonHost::load(Path::new("sjon.wasm"), None)`; the
`Path` type is `std::path::Path`. No Zig toolchain is needed when using a
prebuilt artifact. See the
[complete Rust quickstart](https://github.com/HugoDaniel/SJON/blob/v1.8.0/examples/quickstart-rust.rs).

The registry package excludes repository integration tests, conformance data,
and fuzz targets. Its build script skips conformance test generation when the
integration-test harness is absent. In a source checkout, missing corpus or
classifier files still fail the build.

## Layout

| File                                    | What it is                                           |
| --------------------------------------- | ---------------------------------------------------- |
| `src/lib.rs`                            | Public re-exports.                                   |
| `src/host.rs`                           | `SjonHost::load` + `validate_document`.              |
| `src/wasm.rs`                           | wasmtime instantiation + framed-protocol + bridge.   |
| `src/diagnostic.rs`                     | `HostDiagnostic` / `HostOptions` / `HostResult` etc. |
| `src/resolver.rs`                       | `Reference`, `Resolution`, `Resolver`, `FnResolver`. |
| `src/filesystem_resolver.rs`            | Default fs-backed resolver (project-file walker).    |
| `src/sjon_subset.rs`                    | ~150-line bootstrap parser (project + expected).     |
| `tests/smoke.rs`                        | Empty-document smoke test.                           |
| `tests/host_mock_resolver.rs`           | Mock-resolver coverage (11 tests).                   |
| `tests/host_d7_exec.rs`                 | Executable-plugin dispatch + host-result merging (14 tests). |
| `tests/host_eval_expr.rs`               | `SjonHost::eval_expr` coverage (5 tests).            |
| `tests/host_metadata.rs`                | Manifest-metadata smoke tests (4 tests).             |
| `tests/filesystem_resolver.rs`          | `FilesystemResolver` semantics (8 tests).            |
| `tests/conformance.rs`                  | 354 of 393 corpus fixtures (skips 38 `lowering-*` — Zig-host-only — and legacy `too-many-keys`). |
| `tests/export_schema.rs`                | `SjonHost::export_schema` round-trip coverage (3 tests). |
| `tests/diagnostic_snapshots.rs`         | `expect-test` HostResult JSON snapshots (4 cases).   |
| `tests/wasm_bridge.rs`                  | Explicit wasm-bridge invariants (3 tests).           |
| `tests/common/mod.rs`                   | Shared `wasm_path` / `err_codes` / `expected.sjon` reader. |
| `tests/common/wasm_builder.rs`          | Hand-assembled stub WASM modules for pre-flight tests. |
| `fuzz/`                                 | `cargo-fuzz` target for `sjon_subset::parse_single_form`. |
| `Cargo.toml`                            | Crate manifest (wasmtime / serde / anyhow / serde_json / thiserror). |
| `rust-toolchain.toml`                   | Pinned channel + components (rustfmt, clippy).       |

## Running it

```sh
zig build wasm                  # produce zig-out/bin/sjon.wasm
zig build rust-host-test        # cargo test from the build graph

# or directly from this dir:
cargo test --manifest-path hosts/rust/Cargo.toml
```

`zig build rust-host-test` requires `cargo` on `PATH`. It is **not**
part of `zig build test` so toolchains without Rust keep working.

### Fuzzing

The bootstrap parser at `src/sjon_subset.rs` consumes attacker-
influenced bytes (project files, manifests) before `sjon.wasm` is
loaded. A `cargo-fuzz` target lives under `fuzz/`:

```sh
cargo install cargo-fuzz                              # one-time
cd hosts/rust
cargo +nightly fuzz run parse_single_form -- -max_total_time=60
```

The seed corpus under `fuzz/corpus/parse_single_form/` mirrors the
`sjon-project.sjon` files from the conformance suite, so libfuzzer
starts from realistic inputs. The fuzz crate is intentionally outside
`zig build rust-host-test` because `libfuzzer-sys` requires nightly.

## Usage

### Validating a multi-plugin document

`SjonHost` runs the cross-host validating pipeline: parse → partition
top-level forms into `(plugin …)` declarations / `(use-plugin …)`
references / data → load each manifest → resolve each reference →
schema-aggregate → validate the data forest. The diagnostic stream is
byte-identical (`(code, path)`) to the Zig CLI, the typescript-parity
reference on overlapping supported fixtures, and the web host on the
WASM subset. See the [capability matrix](https://github.com/HugoDaniel/SJON/blob/v1.8.0/docs/INTEGRATION.md#capability-matrix)
and `conformance/classifier.json` for exclusions.

#### With the bundled `FilesystemResolver`

```rust
use std::path::Path;
use std::sync::Arc;

use sjon_host::{FilesystemResolver, HostOptions, Resolver, SjonHost};

fn main() -> anyhow::Result<()> {
    let project_root = Path::new("./examples/scene");
    let project_file = project_root.join("sjon-project.sjon");

    // Build the resolver: indexes manifests under (project :plugins […]),
    // captures any project-load diagnostics for the host to report.
    let (resolver, project_diagnostics) =
        FilesystemResolver::build(project_root, Some(project_file.as_path()));
    let resolver: Arc<dyn Resolver> = Arc::new(resolver);

    let mut host = SjonHost::load(std::path::Path::new("./zig-out/bin/sjon.wasm"), Some(resolver))?;

    let source = std::fs::read_to_string(project_root.join("scene.sjon"))?;
    let result = host.validate_document(
        &source,
        &HostOptions {
            project_root: Some(project_root.display().to_string()),
            project_file: Some(project_file.display().to_string()),
            project_diagnostics,
            ..HostOptions::default()
        },
    )?;

    for d in &result.diagnostics {
        if d.severity != sjon_host::Severity::Err {
            continue;
        }
        eprintln!(
            "[{:?}] {} at {}: {}",
            d.phase,
            d.code,
            d.path.join("."),
            d.message,
        );
    }
    Ok(())
}
```

#### With a custom `Resolver`

Implement the trait directly when state is involved (e.g. a pre-fetched
manifest cache, or a project-aware lockfile reader):

```rust
use std::collections::HashMap;
use std::sync::Arc;

use sjon_host::{HostOptions, Reference, Resolution, Resolver, SjonHost};

struct CachedResolver {
    manifests: HashMap<String, String>,
}

impl Resolver for CachedResolver {
    fn resolve(&self, reference: &Reference) -> Resolution {
        if reference.explicit_path.is_some() {
            return Resolution::Failure {
                code: "unresolved_plugin".to_string(),
                detail: "in-memory cache does not support :path".to_string(),
            };
        }
        match self.manifests.get(&reference.name) {
            Some(source) => Resolution::Manifest {
                source: source.clone(),
                wasm: None,
            },
            None => Resolution::Failure {
                code: "unresolved_plugin".to_string(),
                detail: format!("no manifest cached for `{}`", reference.name),
            },
        }
    }
}

fn validate(source: &str) -> anyhow::Result<()> {
    let resolver: Arc<dyn Resolver> = Arc::new(CachedResolver {
        manifests: HashMap::from([(
            "shapes".to_string(),
            r#"(plugin :name shapes :version "1.0.0")"#.to_string(),
        )]),
    });
    let mut host = SjonHost::load(std::path::Path::new("./zig-out/bin/sjon.wasm"), Some(resolver))?;
    let _ = host.validate_document(source, &HostOptions::default())?;
    Ok(())
}
```

`FnResolver(|r| Resolution::…)` is the closure adapter when a trait
impl is overkill (test resolvers, one-shot scripts).

### Resolver contract

The `Resolver` trait is **sync** — wasmtime imports return synchronously.
A consumer that needs async pre-fetching runs its own "discover refs →
resolve all async → validate sync" pre-pass and hands the resolver the
already-fetched bytes.

A resolver may panic; the bridge catches unwinds via
`std::panic::catch_unwind` and converts the panic into
`Resolution::Failure { code: "unresolved_plugin", detail: <message> }`.
Document validation always finishes cleanly.

`Resolution::Manifest { wasm: Some(..) }` is the executable-plugin
envelope. The host
instantiates the plugin inline via wasmtime, runs pre-flight (ABI
version, required + declared exports, empty import set), and registers
the instance in a per-host plugin pool. When the document later
evaluates a `:impl "wasm:…"` expr-func, the `env.sjon_host_invoke_plugin`
import bridges the call through the pool. Traps map to
`plugin_func_trapped`; plugin-reported errors to `plugin_func_failed`;
pre-flight failures collapse to `plugin_abi_mismatch` /
`plugin_export_missing` / `plugin_import_forbidden` at the
`(use-plugin …)` span.

### Preloaded schema handles — specified, not yet implemented

The kitchen-sink ABI ships a two-phase schema preload. `sjon_preload_schema`
takes one UTF-8 JSON array of standalone `(plugin …)` manifest source
strings and returns a framed report carrying a nonzero, never-reused,
instance-scoped `u32` handle;
`sjon_host_validate_document` and `sjon_host_eval_expr` accept
`preloadedHandle` for one synchronous borrow; `sjon_schema_free` releases it
and is idempotent. Manifest content problems are a successful report with
`hasErrors: true` and a usable partial handle; malformed JSON, handle
exhaustion, and OOM are ABI errors; zero, negative, and non-integral option
values are `InvalidOptions` at parse, a stale or unknown positive ID frames
`InvalidSchemaHandle` at use, while a foreign ID that collides with a live
local ID is indistinguishable to the raw ABI and only the wrapper's
per-instance owner token can reject it. Preloaded plugins are
additive and no span is rebased — preload diagnostics stay
manifest-source-local while document diagnostics index the document alone.
A second preload is an independent handle, never a replacement or a stack,
and there is no ambient schema. The domain is declarative only: an
`:impl "wasm:…"` plugin is not instantiated.

**This crate does not bind that surface yet.** There is no `SchemaHandle`,
`PreloadedSchema`, `SjonHost::preload_schema`, `SjonHost::free_schema`, or
`HostOptions::preloaded` here, and `hosts/rust` must not be described as
mirroring the Web host's handle API until they exist. The reason is the
toolchain, not a design choice: `cargo`/`rustc` were absent in every
environment this work was developed in, so no Rust code was written or
tested, and an untested binding would not be parity. The eventual shape is
fixed by the same contract as Web: an opaque handle carrying a per-host
owner token plus the live-ID set, explicit `free_schema`, and reclamation of
any remaining instance memory when the host is dropped (a handle does not
implement `Drop` because it does not own the wasmtime `Store`). No Rust
Binary IR or diagnostic-codec change, and no conformance-corpus obligation,
is owed by this surface.

### Identity rows — specified, not yet implemented

The kitchen-sink host result carries one additive `identities` array: one row
per declared, author-written cross-ref identity, sorted by registry, scope
prefix, then symbol, and always present (empty when none qualify). A row is
`{ registry, scope: [{ registry, symbol }…], symbol, status, address }`; its
key is the first three fields and nothing else. `status` is the snake-case tag
`resolved` or `ambiguous`; a resolved row carries `address: { root, path }`
using the same root/path an edit action takes (string path steps name keyword
values, unsigned numbers name positional or vector elements), while an
ambiguous row's address is `null`. The key does not contain a root, an AST
index, or a byte offset, so a name keeps its key when a sibling or the root
moves; the address is positional and must be refreshed by revalidating after
every edit.

**This crate does not bind that surface yet.** There is no `IdentityRow`,
`IdentityScope`, `IdentityAddress`, `IdentityStatus`, or
`HostResult.identities` here, and `hosts/rust` must not be described as
mirroring the Web host's identity API until they exist. The reason is the
toolchain, not a design choice: `cargo`/`rustc` were absent in every
environment this work was developed in, so no Rust code was written or tested,
and an untested binding would not be parity. The eventual shape is fixed by the
same contract as Web: a serde-decoded `IdentityScope`, `IdentityAddress`, and
`IdentityRow`, snake-case `resolved`/`ambiguous`, an `Option<IdentityAddress>`
that is `None` exactly for an ambiguous row, and `#[serde(default)]
identities: Vec<IdentityRow>` on the result. No Rust Binary IR or
diagnostic-codec change, and no conformance-corpus obligation, is owed by this
surface.

### Effective config: reading materialized defaults

The same worked example as the web host's
[README](https://github.com/HugoDaniel/SJON/blob/v1.8.0/hosts/web/README.md) — validate a document that omits defaulted
keys, then read the side-table to render the effective config without
writing into the user's file:

```rust
let src = r#"
(plugin :name config :version "1.0.0"
  (form :name server
    (key :name port :type number :default 8080)
    (key :name workers :type number :default (if true 4 1))))

(server)
"#;

let mut host = SjonHost::load(std::path::Path::new("./zig-out/bin/sjon.wasm"), None)?;
let result = host.validate_document(src, &HostOptions::default())?;

for d in &result.materialized_defaults {
    // d.path = ["server", "port"], d.key = "port",
    // d.origin = literal_default | expression_default,
    // d.value = 8080 / 4 (serde_json::Value)
    println!("{} defaults to {}", d.key, d.value);
}
```

`evaluated_results` is the sibling table for top-level expression
forms (`{ index, value }` per evaluated root); `sjon effective
doc.sjon` prints the same view as spliced source text.

## Wire-protocol notes

`sjon.wasm` exposes a C ABI: every output-returning export returns a
pointer to a `[u32 ok][u32 len][u8 payload…]` buffer in WASM linear
memory. `src/wasm.rs` reads the header, copies the payload into a
fresh `Vec<u8>`, and frees the WASM allocation before returning.

The resolver bridge uses the same framing in the opposite direction:
`env.sjon_host_resolve(ref_ptr, ref_len) -> u32` is wired through
wasmtime's `Linker::func_wrap`. The handler decodes the JSON
`Reference`, dispatches to the user resolver, JSON-encodes the
`Resolution`, allocates a framed buffer via `sjon_alloc`, and returns
its pointer. Returning 0 makes the Zig adapter fold the failure into
`unresolved_plugin`.

`HostOptions.project_diagnostics` are merged Rust-side — the WASM
payload is filesystem-agnostic. They land at the front of
`result.diagnostics` under `phase: Manifest`, mirroring how
`Host.zig` drains its `FilesystemResolver`'s project diagnostics.

## Out of scope

- **C-ABI binding.** The host is consumed as a Rust crate; it exposes
  no C surface.
- **Async resolvers.** Pre-fetch + sync resolver is the contract (see
  the resolver contract above).
- **Browser Rust/WASM target.** The Web host covers the browser.
- **`#[derive(SjonValidate)]` / proc-macro convenience.** Validation is
  schema-driven at runtime; the crate ships no proc-macros.

## Publishing

From a clean committed checkout, verify the packaged crate before uploading:

```sh
cargo publish --manifest-path hosts/rust/Cargo.toml --dry-run
cargo login
cargo publish --manifest-path hosts/rust/Cargo.toml
```

Use your crates.io API token at the `cargo login` prompt. The publication
is `sjon-host` version 1.8.0; Rust code imports it as `sjon_host`.
The dry run builds the extracted package without the repository corpus.
Run the repository's `zig build verify` separately to retain full host coverage.


[wasmtime]: https://wasmtime.dev/
