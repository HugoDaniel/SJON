// Recursive / self-referential forms (M4), web / WASM side. A form nests itself
// via the lazy-thunk `s.formOf(() => Self)` — no Zig change: the real validator
// and serializer already accept self-referential forms. This pins:
//   * the emitted recursive manifest declares the form exactly once and
//     validates against the real Zig validator,
//   * a depth-3 tree validates + round-trips (create → toSjon → parse), and
//   * deep nesting validates cleanly — `recursion_depth` is a data-KIND-depth
//     guard (nested vectors/values), not a form-instance-depth cap, so a
//     recursive form validates to the validator's frame ceiling.
// The file compiling at all is the tsc probe: the explicit-annotation pattern
// for a recursive form (documented on FormFieldNode in infer.ts) type-checks
// under strict mode with no "excessively deep" error.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { SjonHost } from '../SjonHost.ts';
import { createWasmBackend } from '../SjonSchemaBackend.ts';
import { s } from '@sjon-lang/schema';
import type {
  FormFieldNode,
  FormNode,
  FormOut,
  NumberNode,
  ShapeRecord,
  VectorNode,
  infer as Infer,
} from '@sjon-lang/schema';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..', '..');
const wasmPath = path.join(root, 'zig-out/bin/sjon.wasm');

let cached: ReturnType<typeof createWasmBackend> | null = null;
async function getBackend() {
  if (!cached) cached = createWasmBackend(await SjonHost.load(wasmPath));
  return cached;
}

// A self-referential `tree` form: each node has a value and a vector of child
// trees. The output type is value-circular, so the binding needs an explicit
// annotation (interfaces resolve recursive aliases lazily) to break TS's
// "references itself" error — see the FormFieldNode docs.
interface TreeShape extends ShapeRecord {
  value: NumberNode;
  children: VectorNode<
    FormFieldNode<'tree', 'tree', TreeShape>,
    FormOut<'tree', 'tree', TreeShape>[]
  >;
}
const Tree: FormNode<'tree', 'tree', TreeShape> = s.form('tree', {
  value: s.number(),
  children: s.vector(s.formOf(() => Tree)),
});

type TreeOut = Infer<typeof Tree>;
// `Infer` caps the recursive output (children past the budget resolve to
// `unknown` — the documented limit), so navigate deep nesting through this shape.
type DeepTree = { value: number; children: ReadonlyArray<DeepTree> };

/** Build a left-spine tree of `depth` nodes (1 → root only). */
function spine(depth: number): TreeOut {
  let node: TreeOut = Tree.create({ value: depth, children: [] });
  for (let v = depth - 1; v >= 1; v--) node = Tree.create({ value: v, children: [node] });
  return node;
}

test('the recursive-form manifest declares the form once and validates', async () => {
  const be = await getBackend();
  const manifest = Tree.manifest();
  assert.equal(
    (manifest.match(/\(form :name tree\b/g) ?? []).length,
    1,
    'self-referential form must be emitted exactly once (seedForm dedup)',
  );
  const errs = be.validate(manifest).diagnostics.filter((d) => d.severity === 'err');
  assert.deepEqual(errs, [], `recursive schema rejected:\n${JSON.stringify(errs, null, 2)}`);
});

test('a depth-3 tree validates and round-trips (create → toSjon → parse)', async () => {
  const be = await getBackend();
  const errs = Tree.validate(Tree.toSjon(spine(3)), { backend: be }).diagnostics.filter(
    (d) => d.severity === 'err',
  );
  assert.deepEqual(errs, [], `depth-3 tree rejected:\n${JSON.stringify(errs, null, 2)}`);

  const parsed = Tree.parse(Tree.toSjon(spine(3)), { backend: be });
  assert.deepEqual(parsed, Tree.create(spine(3)));
  // Nesting survives the round-trip (cast through DeepTree past the output cap).
  const deep = parsed as unknown as DeepTree;
  assert.equal(deep.value, 1);
  assert.equal(deep.children[0]?.value, 2);
  assert.equal(deep.children[0]?.children[0]?.value, 3);
});

test('deep nesting validates cleanly — recursion_depth is not a form-instance cap', async () => {
  const be = await getBackend();
  // The engine's recursion_depth guard (MAX_KIND_DEPTH = 8) caps nested data
  // *kinds* (vectors of vectors …), not recursive form instances, which validate
  // to the frame ceiling. A 12-deep spine therefore has zero errors.
  const errs = Tree.validate(Tree.toSjon(spine(12)), { backend: be }).diagnostics.filter(
    (d) => d.severity === 'err',
  );
  assert.deepEqual(errs, [], `deep tree unexpectedly rejected:\n${JSON.stringify(errs, null, 2)}`);
});
