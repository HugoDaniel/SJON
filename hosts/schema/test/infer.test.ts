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
