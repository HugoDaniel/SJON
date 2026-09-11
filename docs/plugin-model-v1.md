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

### The layers are part of the result

`HostResult.lowering_stages` holds one entry per layer, in layer order:
that layer's tree, that layer's provenance table, and that layer's
defaults overlay. `lowered_tree`, `lowering_provenance` and
`lowered_materialized_defaults` are the terminal layer, and are aliases
into the last stage rather than a fourth thing to free.

A provenance table is **one hop**. Layer `i`'s table says which form in
layer `i-1` produced each of layer `i`'s forms and which hook did it, and
that is all it says. Both halves of an entry are `Ast.NodeIndex` values,
a `u32` each, but they index two *different* trees, so an entry read
against the wrong one lands on an unrelated node rather than failing.
`HostResult.provenanceChain` is the walk that composes the tables and
hands back hops that carry their own trees, source-first: hop 0 is the
authored form and the hook that first rewrote it. It allocates nothing —
a chain is at most one hop per layer, and the layer count is capped — so
the caller passes a buffer.

"Terminal" is per form, not per document. A hook that emits one form
which lowers again and one which does not leaves the second terminal in
an intermediate layer's tree; the final validated forest includes it and
`lowered_tree` does not. `provenanceChainFrom` takes the layer for
exactly that case.

Two things this makes answerable that a single hop cannot. An
explanation of "why does this look like this" can name every form and
hook that stood between the authored bytes and the final one, where a
span alone gives only the two ends. And **eject** — replacing a verb's
authored span with the text of what the verb wrote — reads layer 0, so a
verb that emits sugar ejects to that sugar rather than to the core the
sugar eventually becomes.

If a required hook is missing, fails, emits a head outside `:produces`,
or exceeds the output / staging limits, the host reports lowering
diagnostics. Emitting a form that is itself lowerable is *not* an error —
it simply lowers in the next layer; the produces-graph cycle check
(reported at schema load as `lowering_cycle`) is what proves staging
terminates. A generic SJON validator is not required to ship domain hooks
such as `pngine/pass-v1`.

### What `:produces` may name

`:produces` is the closed set of heads the hook may emit, and the contract
checks **every** emitted form against it, at every depth — a nested form
is checked exactly like a root, whether it hangs off a positional slot, a
kvpair value, or a vector element. Two checks read the list, and they
agree on what a head is:

- **At schema load** (`Schema.validateLowering`), every entry must
  resolve to a declared form. A *bare* entry resolves **local-first**,
  the same order a form head takes at validation (LANGUAGE.md §6.3.1):
  it may name a **slot-local form reachable through the list** — one
  declared, at any depth and through either carrier (a `(key …)`'s inline
  locals or a form's positional locals, variant keys included), inside a
  form the same list resolves — or a **global form** across the loaded
  plugins, where a bare collision is `ambiguous_form` as before. A
  *qualified* entry (`<plugin>/<form>`) targets that plugin's global
  catalog and bypasses locals, exactly as a qualified head does at the
  site.
- **At lowering time** (`Lowering.validateEmittedForm`), every emitted
  head must be listed, by the same spelling.

"Reachable through the list" rather than "any local anywhere" because an
emitted form is either a root of a lowered layer or nested inside another
emitted form: an emitted local can only ever sit under its declaring
form, and the all-depths contract puts that declaring form in the same
list. The reachable set is therefore exactly the set of local heads a hook
can legally place. A local listed *without* its declaring form is a
manifest that cannot be right, and the `unknown_form` says which form the
list is missing (``leaf` is slot-local to `wrap` and resolves only through
a `:produces` entry naming that form`).

The shape this exists for — a bind group whose entries are slot-local, so
that `entry` collides with nothing global (S7's whole point):

```sjon
(form :name init                              ; the sugar
  :lowering (lowering :hook pngine/init-v1
    :produces [compute-pipeline bind-group entry compute-pass]))

(form :name bind-group                        ; what the hook emits
  (key :name name :type symbol :optional false)
  (form :name entry                           ; slot-local: no global `entry`
    (key :name binding :type number :optional false)
    (key :name buffer  :type symbol :optional false)))
```

The hook emits `(bind-group :name spawn-init-bg (entry :binding 0 :buffer
parts))`; `entry` is in the list because the walk will check it, and it
resolves because `bind-group` is in the list too. Nothing else is
required — no global `entry`, and no qualified spelling: `bind-group/entry`
would read as *plugin* `bind-group` (`lowering_target_plugin_absent`).

Two corollaries keep the list honest:

- **A slot-local form cannot declare `:lowering`.** Nothing would honour
  it — the aggregate check and the produces graph walk top-level forms,
  and the lowering worklist resolves a local head to its local body,
  never to a hook — so the loader rejects it (`invalid_manifest` at
  `[<local> lowering]`) rather than carry a declaration that is silently
  dead. Declare the sugar as a top-level `(form …)`, or leave the local as
  plain data. Because a local never lowers, a local head in `:produces`
  adds **no edge** to the graph the cycle check and `export-lowering-graph`
  consume; the graph resolves globally, and only a global lowerable form
  is an edge.
- **The lowering worklist resolves heads local-first, like the
  validator.** An authored or emitted `(bind-group (entry …))` resolves
  `entry` to `bind-group`'s local — even when a *global* lowerable
  `entry` exists — so the global's hook does not fire on it; a qualified
  `(bind-group (ns/entry))` bypasses the local and lowers the global. The
  nested-lowerable lint (`lowering_nested_lowerable`) follows the same
  resolution.

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

#### What the container's children may use

A container's children may use **any** value kind the language has,
including ones that name something the container does not contain. There
is no rule that a child must validate in isolation, and a container built
out of the ordinary forms of the language — the same `(color-attachment
…)` a hand-written pass carries, rather than a private sugar vocabulary —
is the shape this is written for.

The reason it needs saying is that the host does surface-validate the
container's sub-tree before invoking the hook, and gates on any error: a
malformed container should not reach a contract that assumes well-formed
input. That pass sees the form and its descendants and nothing else. It
would therefore be within its rights to reject a perfectly good document,
because a child naming a sibling elsewhere cannot resolve against a
sub-tree that does not contain the sibling.

It does not, and the rule is exact. The **only** thing that differs
between validating a form alone and validating it inside its document is
which names are registered. The schema is the same object, the defaults
overlay is the whole document's rather than a fragment of one, and the
effective axes are the same axes, so every other check decides
identically in both passes: underlying, member sets, numeric and string
bounds, `:requires`, exclusive groups, variants, head sets, positional
cardinality, repr ranges. So the sub-tree pass declines to adjudicate
cross-reference identity at all. A cross-reference matches whatever it
names, wherever the name is reached from — directly, through a
`(union-shape …)` alternative, through a vector element, or as a key's
default — and two same-named forms inside the container are not a
duplicate. Nothing is lost by the deferral: the whole-document pass that
follows owns cross-reference reporting, and it runs over whatever
survives lowering.

Which is the one thing to design around. A container that lowers is
*replaced* by what its hook emitted, and its children go with it, so a
child value nobody carried forward is a child value nobody validates
either. If a hook rejects one of its children, `out.fail`/`failAt` is how
it says so, and a span makes the message land on the child rather than on
the container head.

#### A container whose children share its head

Sometimes the thing a container holds is another container of the same
kind. A coordinate frame that may hold coordinate frames, a group that may
hold groups: nesting states one fact, the parent of what is inside, and the
nested spelling and the flat one are the same program.

That looks like the self-contradictory setup above — a `:lowering` form as
a positional child of a `:lowering` form, which fires both hooks in one
layer and gets `lowering_nested_lowerable` for it. It is not, because the
inner head does not have to resolve to the lowering form. Declare it as a
**slot-local form of the container**:

```sjon
(form :name space :open true
  (key :name name :type symbol)
  :lowering (lowering :hook anm/space-v1 :produces [coords text])

  ;; The same head, declared as this form's own positional local: plain
  ;; data, no :lowering, and free to differ from the global.
  (form :name space
    (key :name name :type symbol)
    (key :name parent :type space-ref)))
```

A head resolves local-first, at validation and in the lowering worklist
alike, so the nested `(space …)` takes the local body. A slot-local form
can never lower — `:lowering` on one is `invalid_manifest` at load — so
there is no second hook, no lint, and one invocation over the whole
subtree. The container's hook walks the nesting itself and emits the flat
result.

Three things to know before writing it:

- **It is spelled once per level.** A local that may hold a local declares
  one of its own, and nesting is capped at `MAX_LOCAL_FORM_DEPTH` (8).
  Nine levels is `invalid_manifest` at load.
- **The local is its own `FormSpec`, which is the point.** A nested `space`
  may want fewer keys than a root one, a required `:parent` where the root
  has none, a different default. Saying "the same form, but inert" is not
  available and is usually not what was wanted.
- **A qualified head bypasses the local**, at the site and in the
  worklist. `(space (anm/space …))` resolves the global, so both hooks
  fire and the lint says so. That is the escape hatch and the control
  case, in one.

A nested local instance is still a cross-reference target under its head.
The index canonicalises the *head*, not the slot it was written in, so
`(space :name poster (space :name title))` registers both names and a form
elsewhere in the document may name `title`.

#### Referencing a container that lowered

A container that lowers is replaced by its output, so a name declared on
the container is not in the final forest under the container's head. A
reference to it has to reach whatever the hook emitted in its place.

The convention is a **second head**, and a cross-reference kind that
targets both:

```sjon
(value-kind :name space-ref :underlying symbol
  :cross-ref (cross-ref :target [space coords]))
```

The hook emits a childless `(coords :name title …)` carrying the name, and
`:space title` resolves whether it lands on the author's `space` or the
emitted `coords`. Authors write `space`; only the lowered forest shows
`coords`.

Two heads rather than one because the same schema has to hold when nothing
lowers. Only a host with a registry runs a lowering pass — the CLI does
not, and neither do the JavaScript, Rust and TypeScript hosts — and in
those worlds `space` is in the forest and `coords` never appears. A
single-head target is right in one world and wrong in the other.

**The target list is the bucket key.** `:target space` and `:target [space
coords]` are two different namespaces, not a widening of one. So adding a
head is all-or-nothing across every value kind that named the old one: a
kind left on the short list keeps its own separate namespace, and nothing
reports it, because the two buckets genuinely differ.

#### Spans on a lifted child

Every form an invocation emits inherits the source form's span, which is
right for sugar: the container authored those bytes. A container that
lifts a child out of its own subtree is the case where it is not. The
author wrote `(text :name letters …)` on its own line, and a diagnostic
raised on the lowered `text` would point at the whole enclosing block —
worse than the flat spelling the nesting replaces.

`EmittedForm.source_span` is the override. Set it to the lifted child's
span and the child's diagnostics land on the child's bytes; leave it null
(the default) and the source form's span is used, unchanged. It covers the
form and its subtree, and a nested emitted form may narrow it further.

Provenance is a separate question and keeps its separate answer:
`source_form_idx` still names the container, because the container's hook
is what authored the form. "Who emitted this" and "which bytes should a
reader be shown" get one field each.

### Reading a form the hook does not own

A hook resolves a cross-reference key on its own form to the form that key
names, and then reads that form the way it reads itself:

```zig
const producer = (try input.resolveRef("from")) orelse
    return out.fail(arena, "`:from` names nothing this layer defines", .{});
const count = input.view.getEffectiveValue(producer, "count");
```

`resolveRef` takes a key **on the hook's own form**, not a free name. The
key's declared value kind supplies the cross-reference target set, so a hook
cannot look in the wrong bucket, and a multi-target `(cross-ref :target
[a b])` resolves without the hook spelling either target. What comes back is
the named form's node index, which is what `getEffectiveValue` already
takes, so a defaulted value on the neighbour arrives through the overlay
with no special casing in the hook.

This is what a *flat* vocabulary needs. Container lowering (above) puts
every form a hook reasons about inside its own subtree, which is available
whenever the grammar nests. A grammar whose forms sit at top level and name
each other by `:name` has no such subtree, and restating a neighbour's facts
on every form that needs them is duplication nothing checks.

**The bound: resolution sees this staging layer's input forest.** At layer 0
that is the author's data forest; at layer N it is what layer N-1 emitted. A
name that a later layer will define resolves to null, which is not an error.
The hook never adjudicates identity, and the whole-document forest pass that
follows resolves the reference there. A hook that does want to insist says
so with `out.fail` / `failAt`.

Null also covers an absent key and a value that is not symbol-shaped, which
is what lets a `(scalar-or-ref-shape …)` slot be asked without the hook
inspecting the tag first. `HookFailed` is reserved for the one thing no
document decides: a key whose declared type carries no cross-reference at
all, a hook bug of the same class as reading a number slot with `symbol`.

**A hand-rolled scan is not a supported substitute.** `input.view` spans the
whole document tree, so a hook can walk `view.tree.root` for a form whose
`:name` matches, and for a flat single-target vocabulary it will get the
right answer. It gets four things wrong as soon as the schema uses more of
the language, and gets them wrong silently:

- **Scope.** A `(cross-ref … :scope <form>)` resolves only inside the
  nearest enclosing instance of that form, so a scan over roots matches
  names the validator reports as `cross_ref_outside_scope`.
- **The shared bucket.** `(cross-ref :target [a b])` puts several heads in
  one namespace, and a scan hard-codes one head.
- **Provider-backed names.** Names produced by a `(cross-ref-provider …)`
  extraction are not in the tree to be scanned at all. `resolveRef` answers
  null for them, because provider extraction runs after the staging loop and
  no extracted name is resolvable from a hook.
- **Slot-local forms.** A local body's `:name` is scoped to its slot rather
  than to the document, so a document-wide scan can match a name the
  validator would not.

The index a hook asks is the validator's own, so those four rules stay in
step with the language for free.

Building that index costs one forest walk, paid at most once per staging
layer and only when a hook asks. A layer whose hooks resolve nothing builds
nothing.

### Emitting synthesized terminal forms

A hook may emit forms the author never wrote — resources *implied* by the
surface syntax rather than spelled out (a texture per pass, a default
sampler, an auto-blit step). A hook may only emit heads listed in
`:produces`, and every such head must resolve to a declared form (global,
or slot-local reachable through the list — see above), so declare each
synthesized resource kind once as a terminal form:

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

### Emitting a bare positional atom

A hook's `children` list accepts **scalars** as well as nested forms —
`symbol`, `number`, `string`, `keyword`, `boolean`, `nil`. A scalar child
is a *positional atom*: it has no head, so it is not checked against
`:produces`, and it materializes as a bare value child. That is the same
shape an author writes in `(module shader)` or
`(topology triangle-list)`, and a hook can synthesize it directly.

A nested `.form` child, by contrast, carries a head and **is**
`:produces`-checked at every depth, including inside vectors. The two
arms differ in exactly that: whether there is a head to check.

Reference: `Lowering.EmittedValue` for the union, and
`conformance/cases/lowering-positional-atom/` for the end-to-end shape.

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
