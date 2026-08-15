// Type-level regression tests for the schema-exporter public surface.
//
// `pnpm test` runs this file via node:test, but the actual assertions
// here are compile-time — Equal<X, Y> evaluates at type-check time and
// the file fails to typecheck if the WarningCode union or
// ModelValueShape variant set drifts. The runtime test is a smoke test
// that the file gets parsed.
//
// Why hand-rolled Equal<X, Y> instead of expectTypeOf / tsd: this
// package's zero-runtime-dep stance is intentional (single
// devDependency: typescript). Equal<X, Y> is 6 lines and covers what
// we need.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import type { WarningCode, WarningSeverity } from '../src/schemaExport/warnings.ts';
import type { ModelValueShape } from '../src/schemaExport/model.ts';

// ---------------------------------------------------------------------------
// Type-level helpers
// ---------------------------------------------------------------------------

// Standard "strict equality" trick: two conditional-type wrappers that
// distribute identically only when X and Y unify exactly. Catches
// structural mismatches that `extends` would let through.
type Equal<X, Y> = (<T>() => T extends X ? 1 : 2) extends <T>() => T extends Y ? 1 : 2
  ? true
  : false;

type Expect<T extends true> = T;

// ---------------------------------------------------------------------------
// WarningCode — exact-set assertion
// ---------------------------------------------------------------------------
//
// Lists every code the exporter is allowed to emit. Adding a code:
// append to ExpectedWarningCodes AND warnings.ts. Removing or renaming
// requires the same change in both files, plus consumer updates.

type ExpectedWarningCodes =
  | 'cross_ref_unenforceable'
  | 'expression_default_annotation_only'
  | 'expression_slot_annotation_only'
  | 'exclusive_group_unenforceable'
  | 'acyclic_unenforceable'
  | 'deferred_construct'
  | 'ts_name_collision'
  | 'exact_int_overflow'
  | 'string_pattern_engine_mismatch'
  | 'string_format_unknown_to_jsonschema'
  | 'aggregate_phase_error'
  | 'variants_emitted_via_if_then'
  | 'union_emitted_via_anyof'
  | 'head_set_emitted_via_oneof_refs'
  | 'local_forms_emitted_inline'
  | 'rich_members_emitted_with_annotations'
  | 'numeric_bounds_emitted_via_min_max'
  | 'numeric_bound_exceeds_double_range'
  | 'number_with_unit_emitted_via_prefix_items'
  | 'string_bounds_emitted_via_keywords'
  | 'cross_ref_annotation_only'
  | 'multi_key_exclusive_emitted';

// Const-value declarations force the Expect<Equal<...>> to evaluate;
// if WarningCode drifts, the equality flips to `false` and TS reports
// a `false` is not assignable to `true` error. The runtime values are
// inert.
const _warningCodesUnchanged: Expect<Equal<WarningCode, ExpectedWarningCodes>> = true;

const _warningSeverityUnchanged: Expect<Equal<WarningSeverity, 'info' | 'warn' | 'err'>> = true;

// ---------------------------------------------------------------------------
// ModelValueShape — exact-discriminator assertion
// ---------------------------------------------------------------------------
//
// We test the discriminator union ('any' | 'nil' | …) rather than the
// full payload shapes — the payloads carry nested types that are easier
// to evolve, but the discriminator set is the wire-stable surface.
// Mismatches surface as test-file compile errors.

type ModelValueShapeKind = ModelValueShape['kind'];

type ExpectedModelValueShapeKinds =
  | 'any'
  | 'nil'
  | 'boolean'
  | 'number'
  | 'number_i64'
  | 'number_u64'
  | 'number_bounded'
  | 'number_with_unit'
  | 'string'
  | 'string_with_bounds'
  | 'symbol'
  | 'symbol_members'
  | 'symbol_members_rich'
  | 'string_members'
  | 'string_members_rich'
  | 'date'
  | 'time'
  | 'keyword'
  | 'vector'
  | 'form_any'
  | 'form_heads'
  | 'form_locals'
  | 'expr'
  | 'cross_ref'
  | 'union_of'
  | 'unresolved_named';

const _modelValueShapeKindsUnchanged: Expect<
  Equal<ModelValueShapeKind, ExpectedModelValueShapeKinds>
> = true;

// ---------------------------------------------------------------------------
// Runtime smoke test — confirms node:test reached this file.
// ---------------------------------------------------------------------------

test('schemaExport type-level tests: file compiles', () => {
  // The real assertions are the three Expect<Equal<...>> const
  // assignments above. If any of them fails to typecheck, this file
  // refuses to load and the test runner reports the compile error.
  // The runtime body confirms the assertions evaluated to true.
  assert.equal(_warningCodesUnchanged, true);
  assert.equal(_warningSeverityUnchanged, true);
  assert.equal(_modelValueShapeKindsUnchanged, true);
});
