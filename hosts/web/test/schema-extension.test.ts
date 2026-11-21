// End-to-end extension recipe (Web / WASM side): a two-form `studio` plugin
// authored with the builder, composed beside a hand-authored host manifest,
// and validated document-first through the real Zig validator.
//
// The discriminator is the pair of extension roots: with the extension the
// open `note` accepts an undeclared key, the closed `lines` rejects one, its
// typed positional accepts string children, and `host/scene` still validates.
// Without the extension both roots are `unknown_form` — so a green composed
// run cannot pass merely because the extension was never loaded.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { SjonHost } from '../SjonHost.ts';
import { s } from '@sjon-lang/schema';
import type { HostDiagnostic, HostResult } from '../sjon-reader.ts';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..', '..');
const wasmPath = path.join(root, 'zig-out/bin/sjon.wasm');

// A small extension vocabulary: open `note` (required `text`, plus a
// repr-tagged unitless `bytes` number), closed `lines` (required `title`,
// string positional children).
const Note = s.form(
  'note',
  { text: s.string(), bytes: s.number().repr('u32').rejectUnits() },
  { ns: 'studio', open: true },
);
const Lines = s.form('lines', { title: s.string() }, { ns: 'studio', positional: s.string() });
const Extension = s.plugin('studio', { version: '1.0.0', forms: [Note, Lines] });

// A hand-authored host schema, exactly the kind a host ships beside its
// manifest — one form, one required key.
const hostManifest = `(plugin :name host :version "1.0.0"
  (form :name scene
    (key :name title :type string :optional false)))`;

const cleanDocument = `(host/scene :title "opening")
(studio/note :text "hello" :author "ada" :bytes 7)
(studio/lines :title "row" "a" "b")`;

let cached: SjonHost | null = null;
async function getHost(): Promise<SjonHost> {
  if (!cached) cached = await SjonHost.load(wasmPath);
  return cached;
}

function composed(documentSource: string, withExtension = true): string {
  return withExtension
    ? `${hostManifest}\n${Extension.manifest()}\n${documentSource}`
    : `${hostManifest}\n${documentSource}`;
}

function errs(result: HostResult): HostDiagnostic[] {
  return result.diagnostics.filter((d) => d.severity === 'err');
}

test('extension recipe: composed manifest + document validates cleanly', async () => {
  const host = await getHost();
  const result = host.validateDocument(composed(cleanDocument), {
    projectRoot: null,
    projectFile: null,
  });
  assert.deepEqual(
    errs(result),
    [],
    `unexpected validation errors:\n${JSON.stringify(errs(result), null, 2)}`,
  );
});

test('extension recipe: the no-extension control reports unknown_form for both roots', async () => {
  const host = await getHost();
  const result = host.validateDocument(composed(cleanDocument, false), {
    projectRoot: null,
    projectFile: null,
  });
  const unknown = errs(result).filter((d) => d.code === 'unknown_form');
  assert.equal(unknown.length, 2, `got ${JSON.stringify(errs(result), null, 2)}`);
  assert.ok(
    unknown.some((d) => d.message.includes('studio/note')),
    `no unknown_form for studio/note: ${JSON.stringify(unknown, null, 2)}`,
  );
  assert.ok(
    unknown.some((d) => d.message.includes('studio/lines')),
    `no unknown_form for studio/lines: ${JSON.stringify(unknown, null, 2)}`,
  );
});

test('extension recipe: a non-string positional child reports wrong_underlying', async () => {
  const host = await getHost();
  const documentSource = `(host/scene :title "opening")
(studio/note :text "hello" :bytes 7)
(studio/lines :title "row" 7)`;
  const result = host.validateDocument(composed(documentSource), {
    projectRoot: null,
    projectFile: null,
  });
  const wrong = errs(result).filter((d) => d.code === 'wrong_underlying');
  assert.equal(wrong.length, 1, `got ${JSON.stringify(errs(result), null, 2)}`);
  assert.equal(wrong[0]!.path[0], 'lines');
});

test('extension recipe: an undeclared key on closed lines reports unknown_key', async () => {
  const host = await getHost();
  const documentSource = `(host/scene :title "opening")
(studio/note :text "hello" :bytes 7)
(studio/lines :title "row" :colour "red" "a")`;
  const result = host.validateDocument(composed(documentSource), {
    projectRoot: null,
    projectFile: null,
  });
  const unknown = errs(result).filter((d) => d.code === 'unknown_key');
  assert.equal(unknown.length, 1, `got ${JSON.stringify(errs(result), null, 2)}`);
  assert.deepEqual(unknown[0]!.path, ['lines', 'colour']);
});

test('extension recipe: the same key on open note does not report', async () => {
  const host = await getHost();
  const documentSource = `(host/scene :title "opening")
(studio/note :text "hello" :colour "red" :bytes 7)
(studio/lines :title "row" "a")`;
  const result = host.validateDocument(composed(documentSource), {
    projectRoot: null,
    projectFile: null,
  });
  assert.deepEqual(
    errs(result),
    [],
    `unexpected validation errors:\n${JSON.stringify(errs(result), null, 2)}`,
  );
});

test('extension recipe: a fractional value under :repr u32 reports repr_out_of_range', async () => {
  const host = await getHost();
  const documentSource = `(host/scene :title "opening")
(studio/note :text "hello" :bytes 1.5)
(studio/lines :title "row" "a" "b")`;
  const result = host.validateDocument(composed(documentSource), {
    projectRoot: null,
    projectFile: null,
  });
  const repr = errs(result).filter((d) => d.code === 'repr_out_of_range');
  assert.equal(repr.length, 1, `got ${JSON.stringify(errs(result), null, 2)}`);
  assert.deepEqual(repr[0]!.path, ['note', 'bytes']);
});

test('extension recipe: a unit-suffixed value under unit rejection reports unit_forbidden', async () => {
  const host = await getHost();
  const documentSource = `(host/scene :title "opening")
(studio/note :text "hello" :bytes 7px)
(studio/lines :title "row" "a" "b")`;
  const result = host.validateDocument(composed(documentSource), {
    projectRoot: null,
    projectFile: null,
  });
  const unit = errs(result).filter((d) => d.code === 'unit_forbidden');
  assert.equal(unit.length, 1, `got ${JSON.stringify(errs(result), null, 2)}`);
  assert.deepEqual(unit[0]!.path, ['note', 'bytes']);
});
