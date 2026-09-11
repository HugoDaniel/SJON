// Plan-03 nested-form conformance (web / WASM side). Proves the host builder's
// emitted nested-form manifest (value-kind :underlying form :heads + hoisted
// inner forms + vector-of-form element) is accepted by the REAL Zig validator,
// that nested construct→serialize→parse round-trips, and that a deep typed
// setKey lands via the engine's positional descent.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { SjonHost } from '../SjonHost.ts';
import { createWasmBackend } from '../SjonSchemaBackend.ts';
import { s, v } from '@sjon-lang/schema';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..', '..');
const wasmPath = path.join(root, 'zig-out/bin/sjon.wasm');

let cached: ReturnType<typeof createWasmBackend> | null = null;
async function getBackend() {
  if (!cached) cached = createWasmBackend(await SjonHost.load(wasmPath));
  return cached;
}

// A web-todo-shaped nested schema. Nested forms share the container's ns (the
// plugin ns): both live under `todo-app`, so the manifest's `(form :name todo …)`
// resolves to `todo-app/todo` and the stamped data `(todo-app/todo …)` matches.
const Todo = s.form(
  'todo',
  {
    id: s.number(),
    text: s.string(),
    done: s.boolean().default(false),
  },
  'todo-app',
);
const TodoApp = s.form('todo-app', {
  filter: s.symbolMembers(['all', 'active', 'done'] as const),
  items: s.vector(s.formOf(Todo)),
});

function appDoc() {
  return TodoApp.toSjon({
    filter: v.sym('all'),
    items: [
      Todo.create({ id: 1, text: 'Buy milk', done: false }),
      Todo.create({ id: 2, text: 'Write tests', done: true }),
    ],
  });
}

test('the emitted nested-form manifest validates against the real Zig validator', async () => {
  const be = await getBackend();
  const errs = TodoApp.validate(appDoc(), { backend: be }).diagnostics.filter(
    (d) => d.severity === 'err',
  );
  assert.deepEqual(errs, [], `unexpected validation errors:\n${JSON.stringify(errs, null, 2)}`);
});

test('manifest-only declarations are well-formed (no err on the schema text alone)', async () => {
  const be = await getBackend();
  const errs = be.validate(TodoApp.manifest()).diagnostics.filter((d) => d.severity === 'err');
  assert.deepEqual(errs, [], `schema declarations rejected:\n${JSON.stringify(errs, null, 2)}`);
});

test('nested construct→serialize→parse round-trips; elements stay stamped', async () => {
  const be = await getBackend();
  const input = {
    filter: v.sym('active'),
    items: [Todo.create({ id: 7, text: 'x', done: false })],
  };
  const parsed = TodoApp.parse(TodoApp.toSjon(input), { backend: be });
  assert.deepEqual(parsed, TodoApp.create(input));
  assert.equal(parsed.items[0]?.$form, 'todo');
  assert.equal(parsed.items[0]?.done, false);
});

test('deep typed setKey(["items",0,"done"], …) lands via positional descent', async () => {
  const be = await getBackend();
  const edited = TodoApp.setKey(appDoc(), ['items', 0, 'done'], true, { backend: be });
  const parsed = TodoApp.parse(edited, { backend: be });
  assert.equal(parsed.items[0]?.done, true, 'first todo flipped to done');
  assert.equal(parsed.items[1]?.done, true, 'second todo untouched (was already true)');
  assert.equal(parsed.items[0]?.text, 'Buy milk', 'sibling key preserved');
});

test('deep typed replaceAt(["items",0], …) swaps a whole element', async () => {
  const be = await getBackend();
  const replacement = Todo.create({ id: 99, text: 'Replaced', done: true });
  const edited = TodoApp.replaceAt(appDoc(), ['items', 0], replacement, { backend: be });
  const parsed = TodoApp.parse(edited, { backend: be });
  assert.equal(parsed.items[0]?.id, 99);
  assert.equal(parsed.items[0]?.text, 'Replaced');
});
