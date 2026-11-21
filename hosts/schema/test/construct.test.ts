// Form.create / .toSjon / .toCanonicalSjon: tag-stamping, optional omission,
// composition with e.*/v.*, and the WASM-gated canonical path.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import * as s from '../src/builder.ts';
import * as e from '../src/expr.ts';
import * as v from '../src/value-ctor.ts';
import { serializeValue } from '../src/value.ts';
import type { ValidateBackend } from '../src/backend.ts';
import type { SjonValue } from '../src/value.ts';

function expectAssignableTo<Target>(_value: Target): void {
  void _value;
}

// ns defaults to head, so this form's $ns === 'point'. A form with a distinct
// plugin namespace is exercised below (Profile).
const Point = s.form('point', { x: s.number(), y: s.number(), label: s.string().optional() });
const Profile = s.form('profile', { handle: s.string(), age: s.number().optional() }, 'bounds');

test('create stamps $form/$ns from the schema and copies fields', () => {
  assert.deepEqual(Point.create({ x: 1, y: 2, label: 'a' }), {
    $form: 'point',
    $ns: 'point',
    x: 1,
    y: 2,
    label: 'a',
  });
  assert.deepEqual(Profile.create({ handle: 'h', age: 30 }), {
    $form: 'profile',
    $ns: 'bounds',
    handle: 'h',
    age: 30,
  });
});

test('create omits absent optionals (no undefined keys)', () => {
  const val = Point.create({ x: 1, y: 2 });
  assert.deepEqual(val, { $form: 'point', $ns: 'point', x: 1, y: 2 });
  assert.equal('label' in val, false);
});

test('create ignores any $form/$ns smuggled into the input (schema is authoritative)', () => {
  const sneaky = { x: 1, y: 2, $form: 'evil', $ns: 'evil' } as unknown as Parameters<
    typeof Point.create
  >[0];
  assert.deepEqual(Point.create(sneaky), { $form: 'point', $ns: 'point', x: 1, y: 2 });
});

test('toSjon serializes the constructed value — namespace-first (ns/head)', () => {
  // $ns is always stamped (FormOut requires it; plan-01 parse stamps it too),
  // so the head is qualified. A default-ns form reads as `head/head`.
  assert.equal(Point.toSjon({ x: 1, y: 2 }), '(point/point :x 1 :y 2)');
  assert.equal(Point.toSjon({ x: 1, y: 2, label: 'hi' }), '(point/point :x 1 :y 2 :label "hi")');
  // A distinct plugin namespace reads naturally.
  assert.equal(Profile.toSjon({ handle: 'h' }), '(bounds/profile :handle "h")');
});

test('constructed forms compose with e.* and v.* fields', () => {
  const Calc = s.form('calc', { value: s.expr() });
  assert.equal(Calc.toSjon({ value: e.add(1, e.mul(2, 3)) }), '(calc/calc :value (+ 1 (* 2 3)))');

  const Cfg = s.form('cfg', {
    tags: s.vector(s.string()),
    mode: s.symbolMembers(['a', 'b'] as const),
  });
  assert.equal(
    Cfg.toSjon({ tags: ['x', 'y'], mode: v.sym('a') }),
    '(cfg/cfg :tags ["x" "y"] :mode a)',
  );
});

test('a constructed form nests as another value (assignable to SjonValue)', () => {
  const inner = Profile.create({ handle: 'h' });
  assert.equal(
    serializeValue([inner, inner] as SjonValue),
    '[(bounds/profile :handle "h") (bounds/profile :handle "h")]',
  );
});

test('toCanonicalSjon routes through backend.fromValue', () => {
  const backend: ValidateBackend = {
    validate: () => ({ diagnostics: [] }),
    fromValue: (value) => `CANON:${serializeValue(value as SjonValue)}`,
  };
  assert.equal(Point.toCanonicalSjon({ x: 1, y: 2 }, { backend }), 'CANON:(point/point :x 1 :y 2)');
});

test('toCanonicalSjon throws on a backend without fromValue', () => {
  const validateOnly: ValidateBackend = { validate: () => ({ diagnostics: [] }) };
  assert.throws(
    () => Point.toCanonicalSjon({ x: 1, y: 2 }, { backend: validateOnly }),
    /no `fromValue`/,
  );
});

// --- Open forms and positional children ------------------------------------

const OpenNote = s.form('note', { text: s.string() }, { ns: 'studio', open: true });
const ClosedNote = s.form('note', { text: s.string() }, { ns: 'studio' });
const Item = s.form('item', { id: s.number(), done: s.boolean().default(false) }, 'kit');
const ItemList = s.form(
  'item-list',
  { title: s.string() },
  { ns: 'kit', positional: s.formOf(Item) },
);
const AnyList = s.form('any-list', { title: s.string() }, { ns: 'kit', positional: 'any' });
const Plain = s.form('plain', { title: s.string() }, 'kit');
const Lines = s.form('lines', { title: s.string() }, { ns: 'studio', positional: s.string() });
const AnyLines = s.form('any-lines', { title: s.string() }, { ns: 'studio', positional: 'any' });

type OpenNoteInput = Parameters<typeof OpenNote.create>[0];
type ClosedNoteInput = Parameters<typeof ClosedNote.create>[0];
type PlainInput = Parameters<typeof Plain.create>[0];

test('open create copies undeclared values, stamps tags, and materializes declared keys', () => {
  const note = OpenNote.create({ text: 'hi', author: 'ada' });
  assert.deepEqual(note, { $form: 'note', $ns: 'studio', text: 'hi', author: 'ada' });
  assert.equal(
    OpenNote.toSjon({ text: 'hi', author: 'ada' }),
    '(studio/note :text "hi" :author "ada")',
  );

  // Structural keys are never copied: the schema's tags are authoritative and
  // a smuggled `$children` is not a positional child of this form.
  const sneaky = {
    text: 'hi',
    $form: 'evil',
    $ns: 'evil',
    $children: ['sneak'],
    author: 'ada',
  } as unknown as OpenNoteInput;
  assert.deepEqual(OpenNote.create(sneaky), {
    $form: 'note',
    $ns: 'studio',
    text: 'hi',
    author: 'ada',
  });

  // A declared nested form still goes through `materialize` on the open path.
  const OpenHolder = s.form('holder', { item: s.formOf(Item) }, { ns: 'kit', open: true });
  const held = OpenHolder.create({
    item: { $form: 'item', $ns: 'kit', id: 1 },
    extra: true,
  } as unknown as Parameters<typeof OpenHolder.create>[0]);
  assert.deepEqual(held.item, { $form: 'item', $ns: 'kit', id: 1, done: false });
  assert.equal((held as Record<string, unknown>)['extra'], true);
});

test('closed create keeps dropping undeclared values', () => {
  const closed = ClosedNote.create({ text: 'hi', author: 'ada' } as unknown as ClosedNoteInput);
  assert.deepEqual(closed, { $form: 'note', $ns: 'studio', text: 'hi' });
  assert.equal('author' in closed, false);
});

test('typed positional create maps $children through materialize', () => {
  const list = ItemList.create({
    title: 'list',
    $children: [{ $form: 'item', $ns: 'kit', id: 1 }],
  });
  assert.deepEqual(list.$children, [{ $form: 'item', $ns: 'kit', id: 1, done: false }]);
  assert.equal(
    ItemList.toSjon({
      title: 'list',
      $children: [{ $form: 'item', $ns: 'kit', id: 1 }],
    }),
    '(kit/item-list :title "list" (kit/item :id 1 :done false))',
  );
});

test('any positional create leaves $children untouched', () => {
  const children = [1, 'two', { $sym: 'three' }];
  const list = AnyList.create({ title: 'plain', $children: children });
  assert.equal(
    list.$children,
    children,
    'any-positional children are copied by reference, not mapped',
  );
  assert.equal(
    AnyList.toSjon({ title: 'plain', $children: [1, 'two'] }),
    '(kit/any-list :title "plain" 1 "two")',
  );
});

test('a none-positional form ignores a smuggled $children value', () => {
  const plain = Plain.create({ title: 'x', $children: ['sneak'] } as unknown as PlainInput);
  assert.deepEqual(plain, { $form: 'plain', $ns: 'kit', title: 'x' });
  assert.equal('$children' in plain, false);
});

// --- Open / positional compile-time probes ---------------------------------

function _extensionProbes(): void {
  // Open: arbitrary keys are accepted on construction and exposed as unknown.
  const open = OpenNote.create({ text: 'hi', author: 'ada' });
  const author: unknown = open['author'];
  void author;

  // Typed positional: `$children` is present and is exactly string[].
  const typed = Lines.create({ title: 'row', $children: ['a', 'b'] });
  const children: string[] | undefined = typed.$children;
  void children;
  // @ts-expect-error typed positional children are strings, not numbers
  Lines.create({ title: 'row', $children: [1] });
  // @ts-expect-error a typed positional's output children are strings
  const wrongChildren: number[] | undefined = typed.$children;
  void wrongChildren;

  // Any positional: `$children` is unknown[].
  const any = AnyLines.create({ title: 'row', $children: [1, 'a'] });
  const anyChildren: unknown[] | undefined = any.$children;
  void anyChildren;

  // Closed: no index signature, no `$children` capability.
  // @ts-expect-error closed forms reject undeclared keys (excess property check)
  ClosedNote.create({ text: 'hi', author: 'ada' });
  // @ts-expect-error a no-positional form has no `$children`
  ClosedNote.create({ text: 'hi', $children: ['a'] });
  // @ts-expect-error closed forms expose no arbitrary keys
  ClosedNote.create({ text: 'hi' })['author'];
  // @ts-expect-error a no-positional output has no `$children`
  Plain.create({ title: 'x' }).$children;
}
void _extensionProbes;

// --- Compile-time probes ----------------------------------------------------

function _probes(): void {
  const val = Point.create({ x: 1, y: 2 });
  expectAssignableTo<SjonValue>(val);
  expectAssignableTo<{
    readonly $form: 'point';
    readonly $ns: 'point';
    readonly x: number;
    readonly y: number;
    readonly label?: string;
  }>(val);
  // @ts-expect-error x is a required field
  Point.create({ y: 2 });
  // @ts-expect-error wrong field type
  Point.create({ x: 'no', y: 2 });
  // @ts-expect-error undeclared keys are rejected (excess property check)
  Point.create({ x: 1, y: 2, nope: true });
}
void _probes;
