// Conformance fixtures — builder schemas exercised by the conformance
// invariant: `s.infer<typeof Form>` must equal the `.d.ts` the schema
// exporter emits from `Form.manifest()`.
//
// One comprehensive form covering the manifest-expressible leaf table:
// bare + bounded number, bare + bounded/format/preset string, boolean,
// optionals, symbol/string enums, untyped + typed + fixed vectors,
// cross-ref, expr, and form-any.

import { s } from '@sjon/schema';

export const Profile = s.form(
  'profile',
  {
    handle: s.slug(),
    email: s.email(),
    age: s.number(),
    score: s.number().min(0).max(100).optional(),
    active: s.boolean(),
    bio: s.string().optional(),
    notes: s.vector(s.any()),
    tags: s.vector(s.string()),
    coord: s.vector(s.number(), 3),
    status: s.stringMembers(['active', 'archived'] as const),
    role: s.symbolMembers(['admin', 'user'] as const),
    owner: s.crossRef('account'),
    formula: s.expr(),
    meta: s.formAny().optional(),
  },
  'bounds',
);

export type Profile = s.infer<typeof Profile>;

/** Fixtures keyed by the exporter's `<Plugin>_<Form>` interface name. */
export const FIXTURES = [{ typeName: 'Bounds_Profile', form: Profile }] as const;
