# Plugin Model v1

## Status

This document is the current source of truth for SJON's plugin model.
It defines how the four plugin layers fit together:

- static Zig plugin descriptors;
- portable `.sjon` manifests;
- optional WASM sidecars for expression-function bodies;
- host-owned lowering hooks.

Detailed sub-specs remain in place, but they are subordinate to this
model:

- `docs/portable-manifest-v1.md` defines manifest syntax.
- `docs/executable-plugin-abi.md` defines the WASM sidecar ABI.

If those documents appear to disagree with this one, this document is
authoritative and the older text should be corrected.

## Four Layers

SJON keeps substrate, vocabulary, execution, and host semantics on
separate layers.

| Layer | Artifact | Owned by | Carries code? | Purpose |
| --- | --- | --- | --- | --- |
| Static Zig plugin | `Plugin.Plugin` literal | Zig application or library | yes, through `ExprFunc.impl` | In-process schema and expression functions. |
| Portable manifest | `.sjon` `(plugin ...)` document | plugin package or project | no | Portable declarations for validators, LSPs, exporters, and hosts. |
| WASM sidecar | paired `.wasm` bytes | plugin package | yes, expression funcs only | Cross-host bodies for `:impl "wasm:<export>"`. |
| Host lowering | host-registered `LoweringRegistry` hook | embedding host | yes, host-side only | Turns declared surface forms into ordinary forms before final validation. |

The layers are additive. A plugin can be static Zig only, manifest only,
manifest plus WASM sidecar, manifest plus host lowering metadata, or
some combination of those declarations. A portable manifest never embeds
Zig, native code, WASM bytes, or lowering code.

## What Runs Where

| Host | Static Zig descriptors | Portable manifests | WASM sidecars | Host lowering |
| --- | --- | --- | --- | --- |
| Zig native | yes | yes | yes, when built with `-Dplugin-exec=true` (default); else declarative-only | yes, when `HostOptions.lowering_registry` is set |
| Web/WASM host | no direct Zig literals; uses compiled `sjon.wasm` plus resolver data | yes | yes, through browser `WebAssembly` | no generic lowering hooks today unless the embedding host supplies them |
| Rust host | no direct Zig literals; uses bundled SJON WASM plus Rust resolver | yes | yes, through wasmtime | no generic lowering hooks today unless the embedding host supplies them |
| TypeScript parity host | TypeScript model only | yes | no; declarative-only | no runtime lowering hook API |
| LSP/tooling | loaded project schema | yes | may ignore sidecars | should surface metadata; does not implement domain hooks by default |

The shared conformance surface is diagnostics by `(code, path)`. Prose,
spans, filesystem policy, resolver implementation, fuel, and timeout
policy remain host-specific.

## Static Zig Plugins

`src/Plugin.zig` defines the in-process plugin descriptor model. A
static plugin is a borrowed, long-lived `Plugin.Plugin` value:

- `name` is the namespace used by qualified heads like
  `(shapes/circle ...)`;
- `forms` declare data constructors and their keys, positional rules,
  defaults, variants, exclusive groups, and optional lowering metadata;
- `value_kinds` declare named refinements over the closed SJON value
  substrate;
- `expr_funcs` declare safe-expression functions, typed signatures,
  optional labels, optional overloads, and optional runtime bodies.

`Schema.init` aggregates static plugins supplied by the caller. That
static path has no runtime registration and no hot-loaded Zig code: the
caller chooses the plugin slice before validating or evaluating.

`ExprFunc.impl` is the static in-process execution hook. If it is
non-null, the evaluator calls it directly. If it is null, the function
can still be known to the validator but evaluating it returns
`PluginFuncNotImplemented`, unless it is one of the core special forms
handled by the evaluator itself.

### Worked example

```zig
pub const masagin_plugin = sjon.Plugin.Plugin{
    .name = "masagin", // namespace
    .forms = &.{
        .{ .name = "verb",   .keys = &.{ .{ .name = "ops" } } },
        .{
            .name = "fader",
            .keys = &.{
                .{ .name = "kind", .value_type = .{ .named = "fader-kind" } },
            },
        },
    },
    .expr_funcs = &.{
        .{ .name = "b",   .arity = .{ .fixed = 1 }, .impl = &beatsToSeconds },
        .{ .name = "deg", .arity = .{ .fixed = 1 }, .impl = &degreesToRadians },
    },
    .value_kinds = &.{
        .{
            .name = "duration",
            .underlying = .number,
            .unit = .{ .required = true, .allowed = &.{ "s", "ms", "b" } },
        },
        .{
            .name = "fader-kind",
            .underlying = .symbol,
            .members = .{ .values = &.{ "linear", "ease-in", "ease-out" } },
        },
    },
};
```

There is no `.keyword` slot type: source like `:kind :linear` parses as
two positional flags, not as a key/value pair. Use `.symbol` for a bare
label such as `(fader :kind linear)`, or a named `ValueKind` with
`.members` when the slot should be a closed enum.

Two surface forms, both supported:

- **Bare**: `(verb …)` — works when only one plugin claims `verb`.
- **Qualified**: `(masagin/verb …)` — explicit namespace; always works.

See [`examples/plugins/shapes.zig`](../examples/plugins/shapes.zig) for
a complete, runnable reference plugin (`zig build shapes-demo`).

## Portable Manifests

A portable manifest is a SJON document whose top-level `(plugin ...)`
form serializes the same declaration model as a static plugin. Hosts load
it through the meta-plugin and `ManifestLoader`, then aggregate it into a
normal schema.

Portable manifests carry declarations only:

- plugin metadata: `:name`, `:version`, `:description`;
- value kinds and refinements, including vector shape, units, numeric
  bounds, member sets, string bounds, head sets, cross-references, and
  unions;
- forms, keys, positional policy, defaults, variants, exclusive groups,
  and lowering metadata;
- expression-function arity, labels, typed parameters, overloads,
  result types, and symbolic `:impl` references.

Portable manifests do not choose the plugin set for an ordinary document.
Documents may contain inline `(plugin ...)` declarations and
`(use-plugin ...)` references, but resolution is a host concern. A
project file such as `sjon-project.sjon`, an explicit resolver, or
host-specific search roots decide which manifests are available.

`host:` references in manifests are reserved/declaration-only in the
current portable loader. Static Zig plugins can use `ExprFunc.impl` for
host functions, but a manifest cannot dynamically bind host-native code.
`wasm:` references are current only through the sidecar layer below.

## WASM Sidecars

A WASM sidecar supplies portable expression-function bodies for manifest
functions declared as `:impl "wasm:<export>"`. The package shape is a
manifest plus paired WASM bytes; the resolver returns both together as
one `Resolution.manifest` envelope.

The current executable ABI is version 2. A conforming plugin module:

- exports `sjon_plugin_abi_version`, `sjon_plugin_alloc`, and
  `sjon_plugin_free`;
- exports one function per `wasm:<export>` referenced by the manifest;
- declares no imports, including no WASI and no host capability imports;
- receives and returns `Expr.Value` payloads through the ABI's binary
  value codec and result frame.

Web, Rust, and Zig-native hosts (the latter when built with
`-Dplugin-exec=true`, the default) instantiate sidecars, run pre-flight
checks, and dispatch expression calls. TypeScript parity hosts — and
Zig-native builds with `-Dplugin-exec=false` — load the manifest
declarations but do not instantiate the sidecar. In those hosts,
validation can still proceed; evaluation of a WASM-backed expression
is declarative-only and does not run plugin code.

A sidecar is only for expression functions. It cannot add forms at
runtime, rewrite syntax, implement form lowering, import host services,
or mutate host state by contract.

## Host Lowering

Lowering is host-owned. A manifest can declare that a form is surface
syntax:

```sjon
(form :name pass
  :lowering (lowering :hook pngine/pass-v1 :produces [pipeline bind-group]))
```

That declaration names a versioned contract id and the closed set of form
heads the hook may emit. It does not contain the lowerer. Hosts that want
to support the contract register code in `LoweringRegistry` and pass it
through `HostOptions.lowering_registry`.

When enabled, the host runs lowering after default materialization and
before final validation. Lowering is *staged*: the forms a hook emits
become the next layer's input, so an emitted form that is itself a
declared surface form lowers in turn, up to a fixed layer ceiling (a
cumulative emitted-form budget bounds the total fan-out). The host
validates the source and every lowered layer as one final-document
forest, so cross-references resolve across the split. Lowered nodes keep
provenance back to the source form.

If a required hook is missing, fails, emits a head outside `:produces`,
or exceeds the output / staging limits, the host reports lowering
diagnostics. Emitting a form that is itself lowerable is *not* an error —
it simply lowers in the next layer; the produces-graph cycle check
(reported at schema load as `lowering_cycle`) is what proves staging
terminates. A generic SJON validator is not required to ship domain hooks
such as `pngine/pass-v1`.

### Group (container) lowering

A hook is attached to a form, but that form can be a *container* whose
children are the real units of work. Put `:lowering` on the container,
not on each child:

```sjon
(form :name render-graph :open true
  :lowering (lowering :hook webgpu/render-graph-v1
    :produces [gpu-render-pass gpu-texture gpu-auto-blit]))

(form :name pass                       ; plain data — no :lowering
  (key :name name :type symbol)
  (key :name multisample :type boolean :optional true))
```

The hook receives the container as its source form, and the read-side
view it is handed spans the whole document. It walks the container's
children and reads each child's effective values — author kvpairs and
defaults alike — through the same `getEffectiveValue(child, key)` it
would use on the container. One invocation therefore sees *every* child
at once, which is what lets it decide things no per-child hook could:
assigning ids that are coherent across the whole set, ordering the
children, threading a resource produced by one child into the child that
consumes it next.

The children stay plain data forms with no `:lowering`. The container
consumes them, so the single container invocation does all the work —
there is no second pass and nothing to reconcile. When the container
lowers, it is replaced by the hook's output, and its children (never
document roots in their own right) go with it. Marking *both* a container
and its children `:lowering` is the one self-contradictory setup to
avoid: both would fire and emit overlapping output. In container lowering
the children are data; only the container lowers.

### Emitting synthesized terminal forms

A hook may emit forms the author never wrote — resources *implied* by the
surface syntax rather than spelled out (a texture per pass, a default
sampler, an auto-blit step). A hook may only emit heads listed in
`:produces`, and every such head must resolve to a declared form, so
declare each synthesized resource kind once as a terminal form:

```sjon
(form :name gpu-texture
  (key :name name :type symbol))
(form :name gpu-sampler :open true)
```

A terminal form carries no `:lowering`, so it is a sink in the
produces-graph the cycle check builds and cannot introduce a lowering
cycle. The hook then emits as many *instances* as the input implies —
zero, one, or many — none of which needs an authored counterpart
anywhere in the document. The synthesized instances flow through the
ordinary forest validation, cross-references included, exactly as
hand-written forms would; declaring the head is the entire cost, one line
per resource kind.

### Reading input values (eval-capable reads, host env)

A hook reads the surface form through `LoweringInput`, which wraps the
whole-document `EffectiveView` (so author kvpairs *and* materialized
defaults are visible). The typed read helpers — `symbol` / `string` /
`number` / `boolean` — accept only *literal* values; a non-literal returns
`HookFailed`. A number slot additionally has an **eval-capable** reader,
`numberEval`, which *evaluates* an author expression in value position
(`:count (* workgroup-size 1)`) instead of rejecting it, taking a literal
fast path for a plain number.

`numberEval` resolves any free variable in that expression against a
**host-supplied environment** the embedder injects at the Zig API boundary
via `HostOptions.lowering_env` (an `Expr.Env` of named constants such as
`workgroup-size = 16`). The environment defaults empty, so a free variable
with no host binding fails the hook (`UnknownBinding` → `lowering_hook_failed`),
and every document that injects no constants is byte-identical. This is
**Zig-API-only** — there is no manifest, wire-format, diagnostic, or WASM ABI
surface for it; a portable manifest cannot declare or observe the env. It is
the model's "embedding host's policy" applied at lowering time, the read-side
analogue of safe-expression evaluation.

A host constant is referenced *inside an expression*, never as a bare symbol:
a bare `:count workgroup-size` in a `:type number` slot is a static
`wrong_underlying`, because only an expression form defers to runtime
evaluation. So the lowering pass surface-validates each sugar form against the
same core-prepended schema the final forest validation uses — otherwise an
expression's core operators (`*`, `+`, …) would trip `unknown_form` at the
gate and silently suppress the hook.

### Reporting a failure (the hook's own cause)

A hook that cannot lower its form returns `HookFailed`, which the pass driver
turns into a `lowering_hook_failed` diagnostic at the form's head span. Bare,
that diagnostic says only *that* the hook failed — every reason a hook has for
refusing collapses into one sentence, which is fine for a host bug and useless
for an author who wrote something the sugar cannot express.

So the hook may supply the reason, through the output sink it already holds:

```zig
if (scan.count == 0)
    return out.fail(arena, "`{s}` declares no entry point", .{name});

// A container hook blames the child, not itself:
return out.failAt(arena, tree.formHeader(child).head_span,
    "pass `{s}` mixes @fragment and @compute", .{name});
```

The message replaces the generic text verbatim (the author is the audience;
provenance stays in the diagnostic's code, `path`, and span), and `failAt`'s
span replaces the head span — load-bearing for a container hook, whose
failures belong to one child rather than to the whole construct. Both are
opt-in: a hook that just `return error.HookFailed`s produces the same
diagnostic it always did, so no existing host changes behaviour. The
diagnostic **code** is unchanged either way, so conformance consumers keying
on `lowering_hook_failed` are unaffected.

## Intentionally Unsupported

Plugin Model v1 intentionally does not support:

- runtime grammar extensions or new reader syntax;
- macros or syntax rewriting by plugins;
- user-defined lazy control-flow forms beyond the built-in core forms;
- new concrete SJON value tags or new abstract value categories;
- manifest-loaded host-native code via `host:` or `native:`;
- plugin imports, WASI, filesystem, clock, randomness, network, or other
  capability imports;
- async plugin calls, lifecycle hooks, or mutable plugin instance state;
- hot reload, in-session plugin upgrades, or cross-plugin calls;
- self-describing plugins that derive declarations from the sidecar;
- document-level side-effect execution semantics beyond safe-expression
  evaluation under an embedding host's policy.

These limits keep SJON parseable, validatable, portable across hosts, and
predictable for tooling.
