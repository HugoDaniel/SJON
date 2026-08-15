// Typed nested forms (`s.formOf`): inference + input recursion (compile-time),
// recursive `create` / `toSjon` (runtime), and the manifest fragments the Zig
// validator consumes (value-kind :underlying form :heads, vector-of-form
// element, hoisted inner form, dedup-by-head). All backend-free — the real
// validator acceptance is locked in `hosts/web/test/schema-nested.test.ts`.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import * as s from '../src/builder.ts';
import type { Symbol_ } from '../src/infer.ts';

function expectAssignableTo<Target>(_value: Target): void {
  void _value;
}

const Todo = s.form('todo', {
  id: s.number(),
  text: s.string(),
  done: s.boolean().default(false),
});
const TodoApp = s.form('todo-app', {
  filter: s.symbolMembers(['all', 'active', 'done'] as const),
  items: s.vector(s.formOf(Todo)),
  root: s.formOf(Todo).optional(),
});

// --- Inference recurses into the nested form (compile-time) -----------------

type App = s.infer<typeof TodoApp>;
interface ExpectedTodoOut {
  readonly $form: 'todo';
  readonly $ns: 'todo';
  readonly id: number;
  readonly text: string;
  readonly done: boolean; // defaulted ⇒ required in OUTPUT
}
interface ExpectedApp {
  readonly $form: 'todo-app';
  readonly $ns: 'todo-app';
  readonly filter: Symbol_<'all'> | Symbol_<'active'> | Symbol_<'done'>;
  readonly items: ExpectedTodoOut[];
  readonly root?: ExpectedTodoOut;
}
function _outConformance(): void {
  expectAssignableTo<ExpectedApp>(null as unknown as App);
  expectAssignableTo<App>(null as unknown as ExpectedApp);
}
void _outConformance;

// `s.input`: a *direct* nested-form field uses the inner INPUT type, so its
// defaulted `done` may be omitted; a *vector* element is the inner OUTPUT type
// (compose with `Inner.create`, which fills defaults — `VectorNode` is
// `Node<Out,Out>` by design, see plan 03 P1.2).
type AppIn = s.input<typeof TodoApp>;
function _inConformance(): void {
  expectAssignableTo<AppIn>({
    $form: 'todo-app',
    $ns: 'todo-app',
    filter: { $sym: 'all' },
    items: [Todo.create({ id: 1, text: 'a' })], // create fills the defaulted `done`
    root: { $form: 'todo', $ns: 'todo', id: 2, text: 'b' }, // direct field: `done` omittable
  });
}
void _inConformance;

// --- create / toSjon recurse (runtime) -------------------------------------

test('create recurses: inner $form/$ns stamped, inner defaults filled', () => {
  const app = TodoApp.create({
    filter: { $sym: 'all' },
    items: [
      Todo.create({ id: 1, text: 'a', done: true }),
      { $form: 'todo', $ns: 'todo', id: 2, text: 'b' } as never, // raw; done omitted
    ],
  });
  assert.deepEqual(app.items[0], { $form: 'todo', $ns: 'todo', id: 1, text: 'a', done: true });
  // The raw element is re-stamped and its defaulted `done` filled.
  assert.deepEqual(app.items[1], { $form: 'todo', $ns: 'todo', id: 2, text: 'b', done: false });
});

test('create omits an absent optional nested form', () => {
  const app = TodoApp.create({ filter: { $sym: 'all' }, items: [] });
  assert.equal('root' in app, false);
});

test('toSjon renders the nested forms inline', () => {
  const text = TodoApp.toSjon({
    filter: { $sym: 'active' },
    items: [Todo.create({ id: 9, text: 'x', done: false })],
  });
  assert.equal(
    text,
    '(todo-app/todo-app :filter active :items [(todo/todo :id 9 :text "x" :done false)])',
  );
});

// --- Manifest fragments (the validator-facing contract) ---------------------

test('manifest emits a :underlying form value-kind + vector-of-form element', () => {
  const manifest = TodoApp.manifest();
  assert.match(
    manifest,
    /\(value-kind :name todo-form :underlying form :heads \(head-set :names \[todo\]\)\)/,
  );
  assert.match(manifest, /:underlying vector :vector \(vector-shape :element todo-form\)\)/);
  // The inner form is hoisted as its own (form …) block.
  assert.match(manifest, /\(form :name todo\n/);
  // The top form references the vector value-kind, not a builtin.
  assert.match(manifest, /:name items :type vec-todo-form/);
});

test('a form used as a nested element in two slots is emitted once (dedup by head)', () => {
  const manifest = TodoApp.manifest(); // Todo appears in both `items` and `root`
  const todoForms = manifest.match(/\(form :name todo\n/g) ?? [];
  const todoKinds = manifest.match(/\(value-kind :name todo-form\b/g) ?? [];
  assert.equal(todoForms.length, 1, 'inner (form :name todo …) emitted exactly once');
  assert.equal(todoKinds.length, 1, '(value-kind :name todo-form …) emitted exactly once');
});

test('a top-level form also used as a nested element is not double-emitted (plugin pre-seed)', () => {
  const Plugin = s.plugin('todo-app', { forms: [Todo, TodoApp] });
  const manifest = Plugin.manifest();
  const todoForms = manifest.match(/\(form :name todo\n/g) ?? [];
  assert.equal(todoForms.length, 1, 'todo declared top-level is not re-emitted as nested');
});
