// `SjonHost.validateAgainst` — the P1 convenience path that composes
// `manifestSource + "\n" + documentSource` and runs the ordinary
// `validateDocument` pipeline with no project discovery. Six pinned
// behaviours, in the plan's order:
//
//   1. a document that is `unknown_form` alone validates through it;
//   2. its diagnostics equal the explicit composed-source control;
//   3. document spans shift by the manifest's UTF-8 byte length + one LF,
//      and a manifest already ending in LF gets that one LF, not a trim;
//   4. a malformed manifest returns `phase: 'manifest'` diagnostics rather
//      than throwing for user input;
//   5. `heldSymbol` reaches validation and the default policy stays lenient;
//   6. the public option type excludes the project fields (compile-time —
//      `tsc` is the gate; `node --test` strips the types).
//
// The compile-time probes live in `_optionsAreNarrowed` and
// `_optionsAreNameableFromTheEntry` below, following
// `hosts/schema/test/path-types.test.ts`: `@ts-expect-error` is the teeth,
// so a negative that starts compiling turns into an unused-directive error.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { SjonHost } from '../SjonHost.ts';
import type { ValidateAgainstOptions as EntryValidateAgainstOptions } from '../sjon-reader.ts';
import type { HostDiagnostic, HostOptions, ValidateAgainstOptions } from '../types.ts';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..', '..');
const wasmPath = path.join(root, 'zig-out/bin/sjon.wasm');

const base: HostOptions = { projectRoot: null, projectFile: null };
const codes = (diags: readonly HostDiagnostic[]): string[] => diags.map((d) => d.code);

// A real manifest and data form. `widget` is unknown without this
// declaration, so the same document pins both sides of the composition.
const manifest = `(plugin :name probe :version "1.0.0"
  (form :name widget
    (key :name name :type symbol :optional false)))`;

// Same manifest, with a non-ASCII string default: "é" and "☕" are
// multi-byte in UTF-8 and single UTF-16 units, so a `String.length`-based
// offset would land two bytes short of `TextEncoder().encode().byteLength`.
const nonAsciiManifest = `(plugin :name probe :version "1.0.0"
  (form :name widget
    (key :name name :type symbol :optional false)
    (key :name label :type string :optional true :default "café☕")))`;

// The held-position fixture used by `host-options.test.ts`: without
// `heldSymbol` the document reports on two refinement axes; with it the
// whole document is accepted.
const heldManifest = `(plugin :name hold :version "1.0.0"
  (form :name kernel
    (key :name name :type symbol))
  (form :name warp
    (key :name by :type kernel-ref)
    (key :name amount :type number))
  (value-kind :name kernel-ref
    :underlying symbol
    :cross-ref (cross-ref :target kernel :name-key name)))`;
const heldDocument = '(kernel :name flow)\n(warp :by _ :amount _)\n';

test('validateAgainst: a document that is unknown_form alone validates against the manifest', async () => {
  const host = await SjonHost.load(wasmPath);
  const document = '(widget :name w0)\n';

  const alone = host.validateDocument(document, base);
  assert.deepEqual(codes(alone.diagnostics), ['unknown_form']);

  const r = host.validateAgainst(manifest, document);
  assert.deepEqual(r.diagnostics, []);
  assert.equal(r.loadedPlugins.length, 1);
  assert.equal(r.loadedPlugins[0]!.name, 'probe');
});

test('validateAgainst: result equals the explicit composed-source control', async () => {
  const host = await SjonHost.load(wasmPath);
  const document = '(widget)\n';

  const control = host.validateDocument(`${manifest}\n${document}`, base);
  const against = host.validateAgainst(manifest, document);

  assert.deepEqual(against.diagnostics, control.diagnostics);
  assert.deepEqual(against.loadedPlugins, control.loadedPlugins);
  assert.deepEqual(codes(against.diagnostics), ['missing_required_key']);
  assert.equal(against.diagnostics[0]!.phase, 'validation');
});

test('validateAgainst: spans use the composed UTF-8 bytes and never trim a trailing LF', async () => {
  const host = await SjonHost.load(wasmPath);
  const document = '(widget)\n';

  // Both the unknown-form (document alone) and missing-required-key
  // (composed) diagnostics point at the `widget` head symbol, so its span
  // is the independent origin for the offset arithmetic.
  const documentHeadSpan = host.validateDocument(document, base).diagnostics[0]!.span;

  const shift = new TextEncoder().encode(nonAsciiManifest).byteLength + 1;
  const withoutLf = host.validateAgainst(nonAsciiManifest, document);
  assert.equal(withoutLf.diagnostics[0]!.code, 'missing_required_key');
  assert.equal(withoutLf.diagnostics[0]!.span.start, documentHeadSpan.start + shift);
  assert.equal(withoutLf.diagnostics[0]!.span.end, documentHeadSpan.end + shift);

  // A manifest that already ends in LF receives the separator in addition
  // to its own newline — one extra byte, never a trim.
  const manifestWithLf = `${nonAsciiManifest}\n`;
  const withLf = host.validateAgainst(manifestWithLf, document);
  const shiftWithLf = new TextEncoder().encode(manifestWithLf).byteLength + 1;
  assert.equal(shiftWithLf, shift + 1);
  assert.equal(withLf.diagnostics[0]!.span.start, documentHeadSpan.start + shiftWithLf);
  assert.equal(withLf.diagnostics[0]!.span.end, documentHeadSpan.end + shiftWithLf);
});

test('validateAgainst: a malformed manifest returns manifest-phase diagnostics', async () => {
  const host = await SjonHost.load(wasmPath);
  const malformed = '(plugin :name broken :version "1.0.0" (form))';

  // User SJON is diagnostics, never a throw and never a usage error.
  const r = host.validateAgainst(malformed, '(widget :name w0)\n');

  const manifestDiags = r.diagnostics.filter((d) => d.phase === 'manifest');
  assert.deepEqual(codes(manifestDiags), ['missing_required_key']);
  assert.deepEqual(manifestDiags[0]!.path, ['plugin', 'form']);
  assert.equal(r.loadedPlugins.length, 0);
});

test('validateAgainst: heldSymbol reaches validation and the default stays lenient', async () => {
  const host = await SjonHost.load(wasmPath);

  const held = host.validateAgainst(heldManifest, heldDocument);
  assert.deepEqual(codes(held.diagnostics), ['not_cross_ref', 'wrong_underlying']);

  // `failurePolicy` is a pass-through preference with no diagnostic effect
  // (pinned in `host-options.test.ts`), so "default is lenient" is the
  // equality of the omitted option with the explicit lenient control.
  const explicitLenient = host.validateAgainst(heldManifest, heldDocument, {
    failurePolicy: 'lenient',
  });
  assert.deepEqual(held.diagnostics, explicitLenient.diagnostics);

  const typed = host.validateAgainst(heldManifest, heldDocument, { heldSymbol: '_' });
  assert.deepEqual(typed.diagnostics, []);
});

test('validateAgainst: the narrowed option type admits heldSymbol and failurePolicy', async () => {
  const host = await SjonHost.load(wasmPath);
  const options: ValidateAgainstOptions = { failurePolicy: 'lenient', heldSymbol: '_' };
  const r = host.validateAgainst(heldManifest, heldDocument, options);
  assert.deepEqual(r.diagnostics, []);
});

/**
 * Compile-time conformance for `ValidateAgainstOptions` — `tsc --noEmit`
 * is the gate (`node --test` strips types). The wrapper owns project
 * discovery, so a caller-injected project source is not expressible: if
 * one of these ever starts compiling, tsc reports the unused directive.
 */
function _optionsAreNarrowed(): void {
  const ok: ValidateAgainstOptions = { failurePolicy: 'strict', heldSymbol: '_' };
  void ok;

  // @ts-expect-error projectRoot is forced null — not a caller option
  const withRoot: ValidateAgainstOptions = { projectRoot: '/tmp/plugins' };
  // @ts-expect-error projectFile is forced null — not a caller option
  const withFile: ValidateAgainstOptions = { projectFile: '/tmp/sjon-project.sjon' };
  // @ts-expect-error projectDiagnostics is not part of the two-source contract
  const withInjected: ValidateAgainstOptions = { projectDiagnostics: [] };
  void withRoot, withFile, withInjected;
}
void _optionsAreNarrowed;

/**
 * Compile-time conformance for the package entry: `@sjon-lang/web`'s `"."`
 * export maps to `sjon-reader.ts`, so the option type must be nameable from
 * there and not only from the internal `types.ts`. `tsc --noEmit` is the
 * gate; the type-only import above is the assertion.
 */
function _optionsAreNameableFromTheEntry(): void {
  const o: EntryValidateAgainstOptions = { heldSymbol: '_' };
  void o;
}
void _optionsAreNameableFromTheEntry;
