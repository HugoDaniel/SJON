# SJON

> SJON is a schema-constrained data language for domain tools and the
> agents that operate them.
>
> Domain tools grow config languages; agents write a growing share of
> the config. SJON gives both a shared substrate: an S-expression AST
> with the schema as data, validated identically in Zig, JS, and Rust.

Two layers, parsed by one front-end: deterministic S-expression data,
plus a pure, bounded, closed-vocabulary expression layer evaluated by
the consumer.

```sjon
(scene :bpm 130
  (canvas :name "main"
    (camera :ortho :zoom (* 2 (b 1)))
    (stack :mode :mask
      (shape :sdf :radius 0.5
        :delay (delay :p+s (b 4))
        :lifespan (b 16))
      (shape :path :points [[0 0] [1 0] [1 1]]))))
```

## Guarantees

Every claim below is machine-enforced, not asserted — each links the
gate that checks it.

- **Totality** — a tree always exists after parse; collection over
  abort. No parse can crash the caller.
- **Determinism** — bit-identical eval native vs. WASM (vendored
  `exp64`/`log64`/`pow64`), checked by byte-diffed goldens.
- **Boundedness** — no host-stack recursion anywhere in the Parser,
  Validator, or Expr evaluator; depth, step, and memory-budget
  ceilings, each with a test that trips it (`oom_tests.zig`).
- **Wire stability** — Binary IR is versioned and diagnostic codes are
  append-only, both gated by the conformance corpus. Full layout in
  [docs/DESIGN.md](docs/DESIGN.md#binary-ir-binaryzig).
- **Diagnostics as product** — every error carries `(code, severity,
  span, path)`, a 130-entry explanations catalogue, and LSP
  quick-fixes. See it below.

| Field     | Size | Value  |
| --------- | ---- | ------ |
| `version` | 1 B  | `0x05` |

393 fixtures in the shared corpus; each host replays its supported subset
(see the capability matrix below). 25 never-panic fuzz harnesses. 130 explained
diagnostic codes. Zero dependencies in the core library. Every number
here is drift-gated by `zig build audit-docs`; run `zig build verify`
to check all of it yourself.

## See it catch a mistake

```console
$ printf '(scene :w 800)\n' | sjon validate -
<stdin>:1:2: error: unknown_form: unknown form `scene`
  at scene (phase: validation)
1 error

$ sjon explain unknown_form
unknown_form
  A form's head name is not declared by any loaded plugin.
...
https://hugodaniel.com/pages/sjon/errors/unknown_form
```

Every diagnostic is a real error page, not a string — same code in
the CLI, the LSP's Problems panel, and `--format=github` CI
annotations. See [docs/TOOLING.md](docs/TOOLING.md) for the full CLI
and LSP capability list. The native server gives each document its own
schema from the nearest `sjon-lsp.sjon` bundle, composed with that
document's own plugin declarations, so multi-schema workspaces get
per-file diagnostics without separate server instances.

## Consuming

Every host shares the diagnostic vocabulary, the binary wire format,
and the conformance corpus. Supported surfaces agree on the replayed
fixtures; intentional boundaries and skip registries are documented in the
capability matrix and quickstarts:
[docs/INTEGRATION.md](docs/INTEGRATION.md).

**Zig** — the reference path, zero runtime dependencies:

```zig
// build.zig.zon
.dependencies = .{
    .sjon = .{ .path = "../sjon" },
},
```

```zig
// build.zig
const sjon_dep = b.dependency("sjon", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("sjon", sjon_dep.module("sjon"));
```

```zig
const sjon = @import("sjon");

var tree = try sjon.parse(gpa, source);
defer tree.deinit();

const text = try sjon.print(gpa, tree, .{ .mode = .canonical });
defer text.deinit();
```

**Node / Web (WASM)** — install `npm install @sjon-lang/web@1.6.0`.
Build matching artifacts from the 1.6.0 source with Zig 0.16 (`zig build
wasm-all`); the npm package does not bundle WASM. From the source root:

```js
import { SjonEncoder, SjonReader } from "@sjon-lang/web";

const encoder = await SjonEncoder.load("./zig-out/bin/sjon.wasm");
const reader = await SjonReader.load("./zig-out/bin/sjon-binary.wasm");
const binary = encoder.toBinary('(scene :bpm 130)');
const result = reader.validateBinary(binary);
```

See [`examples/quickstart-web.mjs`](examples/quickstart-web.mjs) and
[hosts/web/README.md](hosts/web/README.md).

**Rust** — `cargo add sjon-host@1.6.0`; wraps the matching external
`sjon.wasm` via `wasmtime` (the crate does not bundle it):

```rust
use std::path::Path;
use sjon_host::{HostOptions, SjonHost};

let mut host = SjonHost::load(Path::new("zig-out/bin/sjon.wasm"), None)?;
let result = host.validate_document(source, &HostOptions::default())?;
```

See [`examples/quickstart-rust.rs`](examples/quickstart-rust.rs) and
[hosts/rust/README.md](hosts/rust/README.md).

**TypeScript** — `hosts/typescript-parity/` is a hand-ported reference
for conformance verification, not for production; `@sjon-lang/schema`
(`hosts/schema/`) is the typed schema builder for TS-first projects.
See [hosts/schema/README.md](hosts/schema/README.md).

## Docs

- [docs/AUTHORING.md](docs/AUTHORING.md) — hands-on tutorial
- [docs/LANGUAGE.md](docs/LANGUAGE.md) — formal grammar, semantics, JSON bridge
- [docs/DESIGN.md](docs/DESIGN.md) — module map, SoA tree, binary wire format
- [docs/INTEGRATION.md](docs/INTEGRATION.md) — embedding from Zig, Node/Web, Rust, TypeScript
- [docs/BINARY_PATTERNS.md](docs/BINARY_PATTERNS.md) — decode once and query binary patterns
- [docs/TOOLING.md](docs/TOOLING.md) — editor setup, LSP capabilities, `sjon` CLI
- [docs/plugin-model-v1.md](docs/plugin-model-v1.md) — the plugin contract
- [examples/](examples/README.md) — runnable fixtures and demos, one per host

## Building

```sh
zig build test      # all test suites (all in-source)
zig build verify    # every local gate: tests, fuzz, audits, all hosts, biome, clippy
zig build wasm-all  # both WASM artifacts
zig build lsp       # native sjon-lsp
```

Requires Zig 0.16.x.

## Versioning & releases

The stable surfaces are the binary wire format and the diagnostic-code
enum — versioned, and gated by the conformance corpus plus `zig build
verify`. A change to either is deliberate and version-gated: the wire
bumps its format integer, diagnostic codes only append, and the corpus
lands updated in the same change.

Every package in this repo carries the one version declared in
`src/version.zig`; `zig build audit-format-versions` names any
manifest that falls out of step. The `@sjon-lang/*` packages carry full
registry metadata and are published through `scripts/publish-npm.sh`.
Use `pnpm pack` for local tarballs: pnpm rewrites the web package's
`workspace:*` dependency into the matching registry version. Workspace
and path dependencies remain supported. What each release changed
is in [CHANGELOG.md](CHANGELOG.md). The repeatable candidate and publication
checks are in [docs/RELEASING.md](docs/RELEASING.md).

## License

CC0 — public domain. See [LICENSE](LICENSE) for the legal text.
