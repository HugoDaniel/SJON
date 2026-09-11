// Conformance probe (compile-time half). `s.infer<typeof Profile>` — the
// builder's phantom inference — must be bidirectionally assignable to
// `Bounds_Profile`, the interface the schema exporter emits from the same
// form's manifest (committed at ./golden/bounds.d.ts). If inference drifts
// from the emitted `.d.ts`, this stops type-checking.
//
// Checked two ways: by the package `tsc --noEmit` (this file is in the
// include set) and by the spawned `tsc` in schema-conformance.test.ts.
// It is NOT a `.test.ts`, so the node:test glob never runs it.

import { Profile } from './conformanceFixtures.ts';
import type { Bounds_Profile } from './golden/bounds.d.ts';
import type { infer as Infer } from '@sjon-lang/schema';

type Built = Infer<typeof Profile>;

// Bidirectional assignability ⇒ structural equality (TS ignores readonly
// for object-type assignability, and both sides agree on optional keys).
function _conformance(): void {
  const builtToEmitted: Bounds_Profile = null as unknown as Built;
  const emittedToBuilt: Built = null as unknown as Bounds_Profile;
  void builtToEmitted;
  void emittedToBuilt;
}
void _conformance;
