// Inference: `s.infer<typeof Form>` must match the static shape the
// exporter's `.d.ts` describes. These are compile-time assertions
// (verified by `tsc --noEmit` via the package typecheck) wrapped in a
// runtime no-op so `node --test` also registers them.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import * as s from '../src/builder.ts';
import type { CrossRef, SjonExpr, Symbol_ } from '../src/infer.ts';

// Assignability probe: `expectAssignableTo<Target>(value)` compiles only
// when `value`'s type is assignable to `Target`. Calling it in both
// directions pins structural equality. Lives in an uncalled function —
// tsc checks it, node strips it.
function expectAssignableTo<Target>(_value: Target): void {
  void _value;
}

const Profile = s.form(
  'profile',
  {
    handle: s.slug(),
    email: s.email().optional(),
    score: s.number().min(0).max(100).optional(),
    bio: s.string().optional(),
    age: s.number(),
    active: s.boolean(),
    tags: s.vector(s.string()),
    coord: s.vector(s.number(), 3),
    status: s.stringMembers(['active', 'archived'] as const),
    role: s.symbolMembers(['admin', 'user'] as const),
    owner: s.crossRef('account'),
    formula: s.expr(),
  },
  'bounds',
);

type Profile = s.infer<typeof Profile>;

interface ExpectedProfile {
  readonly $form: 'profile';
  readonly $ns: 'bounds';
  readonly handle: string;
  readonly email?: string;
  readonly score?: number;
  readonly bio?: string;
  readonly age: number;
  readonly active: boolean;
  readonly tags: string[];
  readonly coord: readonly [number, number, number];
  readonly status: 'active' | 'archived';
  readonly role: Symbol_<'admin'> | Symbol_<'user'>;
  readonly owner: CrossRef<'account'>;
  readonly formula: SjonExpr;
}

// The load-bearing assertions (compile-time):
function _typeConformance(): void {
  expectAssignableTo<ExpectedProfile>(null as unknown as Profile);
  expectAssignableTo<Profile>(null as unknown as ExpectedProfile);
}
void _typeConformance;

test('inferred literal tags ($form/$ns) are present at the type level', () => {
  // Runtime smoke: the def carries the literal head/ns the type encodes.
  assert.equal(Profile._def.head, 'profile');
  assert.equal(Profile._def.ns, 'bounds');
});

test('optional keys are partitioned out of required keys', () => {
  const optional = Profile._def.keys.filter((k) => k.def.isOptional).map((k) => k.name);
  assert.deepEqual(optional.sort(), ['bio', 'email', 'score']);
});

// --- Open forms and positional `$children` inference -----------------------

const NoteForm = s.form('note', { text: s.string() }, { ns: 'studio', open: true });
const ClosedForm = s.form('closed', { title: s.string() }, { ns: 'studio' });
const LinesForm = s.form('lines', { title: s.string() }, { ns: 'studio', positional: s.string() });
const AnyLinesForm = s.form(
  'any-lines',
  { title: s.string() },
  { ns: 'studio', positional: 'any' },
);

type Note = s.infer<typeof NoteForm>;
type Closed = s.infer<typeof ClosedForm>;
type Lines = s.infer<typeof LinesForm>;
type AnyLines = s.infer<typeof AnyLinesForm>;
type NoteIn = s.input<typeof NoteForm>;

// Direct capability probes — the bidirectional assignability probes in
// `conformanceTypes.ts` do not pin an *absence* (never is assignable to
// anything), so the index signature and `$children` are asserted directly.
type NoteHasIndex = 'author' extends keyof Note ? true : false;
const noteHasIndex: NoteHasIndex = true;
type ClosedHasIndex = 'author' extends keyof Closed ? true : false;
const closedHasIndex: ClosedHasIndex = false;
type LinesHasChildren = '$children' extends keyof Lines ? true : false;
const linesHasChildren: LinesHasChildren = true;
type ClosedHasChildren = '$children' extends keyof Closed ? true : false;
const closedHasChildren: ClosedHasChildren = false;

function _extensionInference(): void {
  const note = null as unknown as Note;
  // Open values expose arbitrary keys as `unknown`.
  const author: unknown = note['author'];
  void author;

  // Typed positionals expose `$children?: string[]`.
  const lines = null as unknown as Lines;
  const lineChildren: string[] | undefined = lines.$children;
  void lineChildren;
  // @ts-expect-error a typed positional's children are strings, not numbers
  const wrongChildren: number[] | undefined = lines.$children;
  void wrongChildren;

  // Any positionals expose `$children?: unknown[]`.
  const anyLines = null as unknown as AnyLines;
  const anyChildren: unknown[] | undefined = anyLines.$children;
  void anyChildren;

  // Closed/no-positional forms have neither capability.
  const closed = null as unknown as Closed;
  // @ts-expect-error closed forms have no positional children
  closed.$children;
  // @ts-expect-error closed forms have no open index signature
  closed['author'];

  // The input side carries the same configured surface.
  const noteIn: NoteIn = { $form: 'note', $ns: 'studio', text: 'hi', author: 'ada' };
  void noteIn;
}
void _extensionInference;

function _extensionConstructionProbes(): void {
  NoteForm.create({ text: 'hi', author: 'ada' });
  LinesForm.create({ title: 'row', $children: ['a'] });
  AnyLinesForm.create({ title: 'row', $children: [1, 'a'] });
  // @ts-expect-error typed positional input children are strings
  LinesForm.create({ title: 'row', $children: [1] });
  // @ts-expect-error closed forms reject undeclared keys
  ClosedForm.create({ title: 'row', author: 'ada' });
  // @ts-expect-error a no-positional form has no `$children`
  ClosedForm.create({ title: 'row', $children: ['a'] });
}
void _extensionConstructionProbes;

// --- Number representation brands -----------------------------------------

const GpuForm = s.form(
  'gpu-form',
  {
    bytes: s.number().repr('u32').rejectUnits().min(0).int(),
    plain: s.number(),
    count: s.number().rejectUnits(),
  },
  'gpu',
);

type GpuFormOut = s.infer<typeof GpuForm>;
type Bytes = GpuFormOut['bytes'];
type PlainNumber = GpuFormOut['plain'];
type Count = GpuFormOut['count'];

// The brand key is present only on the repr-tagged field; a plain number and a
// unit-reject-only number have no such key at all. (`keyof` is the direct
// probe: a bidirectional assignability check cannot pin an *absence*.)
type BytesHasReprKey = '__sjonRepr' extends keyof Bytes ? true : false;
const bytesHasReprKey: BytesHasReprKey = true;
type PlainHasReprKey = '__sjonRepr' extends keyof PlainNumber ? true : false;
const plainHasReprKey: PlainHasReprKey = false;
type CountHasReprKey = '__sjonRepr' extends keyof Count ? true : false;
const countHasReprKey: CountHasReprKey = false;

function _numberReprInference(): void {
  // `.repr` accepts exactly the five exporter tags.
  s.number().repr('f32');
  s.number().repr('u32');
  s.number().repr('i32');
  s.number().repr('u16');
  s.number().repr('f16');
  // @ts-expect-error `u8` is not a GPU representation tag
  s.number().repr('u8');

  const bytes = null as unknown as Bytes;
  // The brand narrows the value type; it does not stop it being a number.
  const asNumber: number = bytes;
  void asNumber;
  const tag: 'u32' | undefined = bytes.__sjonRepr;
  void tag;

  // Unit rejection leaves the static type `number` — no wrapper brand.
  const plain = null as unknown as PlainNumber;
  const stillNumber: number = plain;
  void stillNumber;
  const count = null as unknown as Count;
  const unitlessNumber: number = count;
  void unitlessNumber;
}
void _numberReprInference;

test('number repr is a phantom brand, not a runtime wrapper', () => {
  assert.equal(bytesHasReprKey, true);
  assert.equal(plainHasReprKey, false);
  assert.equal(countHasReprKey, false);
  const value = GpuForm.create({ bytes: 7, plain: 1, count: 2 });
  assert.equal(typeof value.bytes, 'number');
  assert.equal(value.bytes, 7);
});

test('configured forms carry their def-level openness and positional slot', () => {
  assert.equal(NoteForm._def.open, true);
  assert.equal(ClosedForm._def.open, false);
  assert.equal(LinesForm._def.positional.kind, 'typed');
  assert.deepEqual(AnyLinesForm._def.positional, { kind: 'any' });
});
