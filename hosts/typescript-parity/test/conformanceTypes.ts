// Conformance probe (compile-time half). `s.infer<typeof Profile>` — the
// builder's phantom inference — must be bidirectionally assignable to
// `Bounds_Profile`, the interface the schema exporter emits from the same
// form's manifest (committed at ./golden/bounds.d.ts). If inference drifts
// from the emitted `.d.ts`, this stops type-checking.
//
// Checked two ways: by the package `tsc --noEmit` (this file is in the
// include set) and by the spawned `tsc` in schema-conformance.test.ts.
// It is NOT a `.test.ts`, so the node:test glob never runs it.
//
// Open / positional fixtures get the same probe, but a bidirectional
// assignability check cannot pin the *absence* of an index signature or
// `$children` (a bare type is assignable to an indexed one). The direct
// probes live in `hosts/schema/test/infer.test.ts`.

import { GpuNumber, Lines, Note, Profile, UnitlessNumber } from './conformanceFixtures.ts';
import type { Bounds_Profile } from './golden/bounds.d.ts';
import type { Studio_GpuNumber } from './golden/gpu-number.d.ts';
import type { Studio_Lines } from './golden/positional-form.d.ts';
import type { Studio_Note } from './golden/open-form.d.ts';
import type { Studio_UnitlessNumber } from './golden/unitless-number.d.ts';
import type { infer as Infer } from '@sjon-lang/schema';

type Built = Infer<typeof Profile>;
type BuiltNote = Infer<typeof Note>;
type BuiltLines = Infer<typeof Lines>;
type BuiltGpu = Infer<typeof GpuNumber>;
type BuiltUnitless = Infer<typeof UnitlessNumber>;

// Bidirectional assignability ⇒ structural equality (TS ignores readonly
// for object-type assignability, and both sides agree on optional keys).
function _conformance(): void {
  const builtToEmitted: Bounds_Profile = null as unknown as Built;
  const emittedToBuilt: Built = null as unknown as Bounds_Profile;
  void builtToEmitted;
  void emittedToBuilt;

  const noteToEmitted: Studio_Note = null as unknown as BuiltNote;
  const noteToBuilt: BuiltNote = null as unknown as Studio_Note;
  void noteToEmitted;
  void noteToBuilt;

  const linesToEmitted: Studio_Lines = null as unknown as BuiltLines;
  const linesToBuilt: BuiltLines = null as unknown as Studio_Lines;
  void linesToEmitted;
  void linesToBuilt;

  const gpuToEmitted: Studio_GpuNumber = null as unknown as BuiltGpu;
  const gpuToBuilt: BuiltGpu = null as unknown as Studio_GpuNumber;
  void gpuToEmitted;
  void gpuToBuilt;

  const unitlessToEmitted: Studio_UnitlessNumber = null as unknown as BuiltUnitless;
  const unitlessToBuilt: BuiltUnitless = null as unknown as Studio_UnitlessNumber;
  void unitlessToEmitted;
  void unitlessToBuilt;
}
void _conformance;
