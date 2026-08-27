# Reference plugin: `shapes`

A small but complete plugin that exercises every plugin extension point
SJON exposes today. Treat it as both a learning aid (read alongside
`src/Plugin.zig`) and a copy-paste template for new plugins of your own.

## Files

| File                | What it is                                                                  |
| ------------------- | --------------------------------------------------------------------------- |
| `shapes.zig`        | Plugin descriptor + tests (schema lookup, validator, binary parity).        |
| `shapes-demo.zig`   | Runnable executable: parse → validate → print → binary → cursor → re-print. |
| `shapes-scene.sjon` | Sample input the demo + tests consume (baked in via `@embedFile`).          |

## Running it

```sh
zig build shapes-demo   # runs the executable, prints a walkthrough
zig build test          # runs the plugin's tests + demo regression test
```

## Anatomy of a plugin

A plugin is a comptime struct describing three kinds of vocabulary
extensions. The `shapes` plugin sets all three:

```zig
pub const plugin: Plugin.Plugin = .{
    .name = "shapes",
    .forms = &forms,            // (canvas …), (circle …), (rect …), (group …), (scene …)
    .expr_funcs = &expr_funcs,  // (tau), (deg …)
    .value_kinds = &value_kinds,// length (number), point (vector)
};
```

### Forms

Each `FormSpec` declares a constructor like `(circle …)`:

```zig
.{
    .name = "circle",
    .keys = &.{
        .{ .name = "center", .value_type = .{ .named = "point" } },
        .{ .name = "radius", .value_type = .{ .named = "length" } },
    },
    .positional = .none,        // disallow positional children
}
```

The validator emits an error when an unknown keyword appears under the
form (unless `.open = true`), and when a positional child appears under
a `.positional = .none` form. Set `.positional = .any` for forms that
contain shapes (e.g. `canvas`, `group`).

### Value kinds

`ValueKind` declares a typed scalar / vector that keys can reference:

```zig
.{ .name = "length", .underlying = .number },
.{ .name = "point",  .underlying = .vector },
```

Reference one from a key's `value_type`:

```zig
.{ .name = "radius", .value_type = .{ .named = "length" } }
```

Value kinds are looked up by name through `Schema.lookupValueKind` and
enforced by the validator. A named kind can pin vector element type and
length, require or restrict numeric unit suffixes, constrain symbol or
string members to a closed set, or restrict a form slot to a closed set
of allowed heads.

### Expression functions

`ExprFunc` declares a callable for safe-expression position:

```zig
.{ .name = "tau", .arity = .{ .fixed = 0 } },
.{ .name = "deg", .arity = .{ .fixed = 1 } },
```

The validator recognises declared funcs (so `(tau)` doesn't trigger
"unknown form"), and the schema lookup tells you which plugin owns each
name. Runtime evaluation requires `ExprFunc.impl`; declaration-only
funcs (`impl = null`) are valid for editor and validator recognition,
but evaluating one through `sjon.evalExpr` returns
`error.PluginFuncNotImplemented`.

## Bare vs. qualified resolution

Forms and expression functions can be referenced two ways in source:

| Surface form           | Resolution                                             |
| ---------------------- | ------------------------------------------------------ |
| `(circle …)`           | Bare lookup. Walks every plugin in schema order.       |
| `(shapes/circle …)`    | Qualified. Searches only inside the named plugin.      |

When two plugins both claim the same bare name, lookup returns
`.ambiguous` with the list of claimants, and `Validator` turns that into
a diagnostic suggesting the qualified form. The tests in `shapes.zig`
exercise both paths; see `"schema: ambiguous bare name when two plugins
claim it"`.

## Composing schemas

A `Schema` is a static aggregate over plugins:

```zig
const schema = sjon.Schema.Schema.init(&.{
    sjon.plugins.core.plugin,
    shapes.plugin,
});
```

Order matters only for bare-lookup precedence on collisions. Most
consumers will pass `core` (so safe expressions like `(+ 1 2)` resolve)
plus their domain plugin(s).

## Lifting this into a downstream package

Copy `shapes.zig` and adapt it. In your own project's `build.zig.zon`:

```zig
.{
    .name = .my_app,
    .version = "0.1.0",
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .sjon = .{ .path = "../sjon" }, // or `.url = "..." + .hash = "..."`
    },
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

In your `build.zig`:

```zig
const sjon_dep = b.dependency("sjon", .{ .target = target, .optimize = optimize });
const sjon_mod = sjon_dep.module("sjon");
exe.root_module.addImport("sjon", sjon_mod);
```

In source:

```zig
const sjon = @import("sjon");
const my_plugin = @import("my_plugin.zig");

const schema = sjon.Schema.Schema.init(&.{
    sjon.plugins.core.plugin,
    my_plugin.plugin,
});
```

## Source-syntax gotcha: `:kw :other-kw` doesn't pair

When a `:keyword`'s value is itself a `:keyword` token, the parser
does **not** pair them: the first becomes a positional "flag" and the
second becomes a separate positional value. Two consequences:

1. Forms with `.positional = .none` reject the flag, producing one
   diagnostic per flagged keyword.
2. Use a string (`"black"`) for keys whose declared value is a
   short symbolic label, unless you specifically want flag-style usage.

The tests `validator: unknown keyword on circle is flagged` and
`validator: a clean scene has no diagnostics` were both bitten by this
during development; the README and `shapes-scene.sjon` use string
values for `:bg` to keep the example clean.
