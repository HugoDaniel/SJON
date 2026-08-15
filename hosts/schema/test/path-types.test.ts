// Typed edit-path resolver — compile-time conformance. These assertions are
// verified by `tsc --noEmit` (the package `typecheck` script); `node --test`
// strips the types, so the probe lives in an uncalled function and only a
// runtime smoke test registers. The `@ts-expect-error` lines are the teeth:
// if a negative ever starts compiling, tsc reports an unused directive.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import * as s from '../src/builder.ts';
import type {
  FormNode,
  RemoveKeyPath,
  ReplacePath,
  ReplaceValue,
  SetKeyPath,
  SetKeyValue,
} from '../src/infer.ts';

function expectAssignableTo<T>(_v: T): void {
  void _v;
}
type ShapeOf<F> = F extends FormNode<string, string, infer Sh> ? Sh : never;

const Sub = s.form('sub', { flag: s.boolean() });
const Task = s.form('task', { name: s.string(), sub: s.formOf(Sub) });
const Todo = s.form('todo', {
  id: s.number(),
  text: s.string(),
  done: s.boolean(),
  tags: s.vector(s.string()),
});
const App = s.form('app', {
  title: s.string(),
  count: s.number(),
  draft: s.string().optional(),
  root: s.formOf(Todo),
  items: s.vector(s.formOf(Todo)),
  tasks: s.vector(s.formOf(Task)),
});
type AppSh = ShapeOf<typeof App>;

function _paths(): void {
  // --- Valid setKey paths (terminal key, deep descent, 4 levels) ---
  const p1: SetKeyPath<AppSh> = ['title'];
  const p2: SetKeyPath<AppSh> = ['items', 0, 'done'];
  const p3: SetKeyPath<AppSh> = ['root', 'id'];
  const p4: SetKeyPath<AppSh> = ['items', 0, 'tags'];
  const p5: SetKeyPath<AppSh> = ['tasks', 0, 'sub', 'flag'];
  void p1, p2, p3, p4, p5;

  // --- Resolved value types ---
  expectAssignableTo<string>(null as unknown as SetKeyValue<AppSh, ['title']>);
  expectAssignableTo<boolean>(null as unknown as SetKeyValue<AppSh, ['items', 0, 'done']>);
  expectAssignableTo<number>(null as unknown as SetKeyValue<AppSh, ['root', 'id']>);
  expectAssignableTo<string[]>(null as unknown as SetKeyValue<AppSh, ['items', 0, 'tags']>);
  expectAssignableTo<boolean>(null as unknown as SetKeyValue<AppSh, ['tasks', 0, 'sub', 'flag']>);

  // --- removeKey: only optional/defaulted terminal ---
  const r1: RemoveKeyPath<AppSh> = ['draft'];
  void r1;
  // @ts-expect-error 'title' is required — cannot be removed at the terminal
  const rBad: RemoveKeyPath<AppSh> = ['title'];
  void rBad;

  // --- replaceAt: a key, a vector element, or deeper ---
  const rp1: ReplacePath<AppSh> = ['title'];
  const rp2: ReplacePath<AppSh> = ['items', 0];
  const rp3: ReplacePath<AppSh> = ['items', 0, 'done'];
  void rp1, rp2, rp3;
  expectAssignableTo<boolean>(null as unknown as ReplaceValue<AppSh, ['items', 0, 'done']>);

  // --- Negatives ---
  // @ts-expect-error 'nope' is not a key
  const n1: SetKeyPath<AppSh> = ['nope'];
  void n1;
  // @ts-expect-error a scalar key has no descent
  const n2: SetKeyPath<AppSh> = ['title', 'x'];
  void n2;
  // @ts-expect-error a vector element needs a numeric index before the inner key
  const n3: SetKeyPath<AppSh> = ['items', 'done'];
  void n3;
  // @ts-expect-error wrong resolved value type
  const vBad: SetKeyValue<AppSh, ['items', 0, 'done']> = 'not-a-boolean';
  void vBad;
}
void _paths;

test('typed edit paths: runtime smoke (real gate is the typecheck script)', () => {
  // Types are stripped by node --test; this just ensures the module loads and
  // the schema builds. The compile-time probe above is checked by `tsc`.
  assert.equal(App._def.head, 'app');
  assert.equal(Todo._def.keys.length, 4);
});
