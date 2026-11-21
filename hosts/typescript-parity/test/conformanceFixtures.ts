// Conformance fixtures — builder schemas exercised by the conformance
// invariant: `s.infer<typeof Form>` must equal the `.d.ts` the schema
// exporter emits from `Form.manifest()`.
//
// One comprehensive form covering the manifest-expressible leaf table:
// bare + bounded number, bare + bounded/format/preset string, boolean,
// optionals, symbol/string enums, untyped + typed + fixed vectors,
// cross-ref, expr, and form-any.

import { s } from '@sjon-lang/schema';

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

/**
 * Open form: every declared key stays required, and the exporter adds a
 * `[key: string]: unknown` index signature — `open-form.d.ts`.
 */
export const Note = s.form('note', { text: s.string() }, { ns: 'studio', open: true });

export type Note = s.infer<typeof Note>;

/**
 * Typed positional form: a closed form with one required key and string
 * children — `positional-form.d.ts`.
 */
export const Lines = s.form(
  'lines',
  { title: s.string() },
  { ns: 'studio', positional: s.string() },
);

export type Lines = s.infer<typeof Lines>;

/**
 * GPU representation tag: a repr-only number hoists a value-kind whose
 * `.d.ts` slot is the exporter's branded `U32` alias — `gpu-number.d.ts`.
 */
export const GpuNumber = s.form('gpu-number', { bytes: s.number().repr('u32') }, 'studio');

export type GpuNumber = s.infer<typeof GpuNumber>;

/**
 * Unit-rejecting number: the manifest forbids any unit suffix, but the static
 * type stays plain `number` (no runtime wrapper) — `unitless-number.d.ts`.
 */
export const UnitlessNumber = s.form(
  'unitless-number',
  { count: s.number().rejectUnits() },
  'studio',
);

export type UnitlessNumber = s.infer<typeof UnitlessNumber>;

/** Fixtures keyed by the exporter's `<Plugin>_<Form>` interface name. */
export const FIXTURES = [
  { typeName: 'Bounds_Profile', form: Profile, golden: 'bounds.d.ts' },
  { typeName: 'Studio_Note', form: Note, golden: 'open-form.d.ts' },
  { typeName: 'Studio_Lines', form: Lines, golden: 'positional-form.d.ts' },
  { typeName: 'Studio_GpuNumber', form: GpuNumber, golden: 'gpu-number.d.ts' },
  { typeName: 'Studio_UnitlessNumber', form: UnitlessNumber, golden: 'unitless-number.d.ts' },
] as const;
