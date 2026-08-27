// Manifest-metadata smoke tests for the Web (Node + WASM) host.
// The diagnostics here originate in src/ManifestLoader.zig and travel
// out via the JSON envelope from sjon.wasm — this file confirms they
// land verbatim on the JS side, with the codes the TS-parity port also
// mirrors.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { SjonHost } from '../SjonHost.ts';
import type { HostDiagnostic } from '../sjon-reader.ts';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..', '..');
const wasmPath = path.join(root, 'zig-out/bin/sjon.wasm');

const codes = (diags: readonly HostDiagnostic[]): string[] => diags.map((d) => d.code);

test('manifest metadata: fully-decorated (plugin …) validates cleanly', async () => {
  const host = await SjonHost.load(wasmPath);
  const src = `
(plugin :name probe :version "1.0.0"
  :authors ["Ada" Babbage]
  :license "CC0-1.0"
  :homepage "https://example.com"
  :repository "https://github.com/x/y"
  :keywords [graphics shapes]
  (form :name widget
    (key :name name :type symbol :optional false)))

(widget :name w0)
`;
  const r = host.validateDocument(src, { projectRoot: null, projectFile: null });
  assert.deepEqual(
    r.diagnostics.filter((d) => d.severity === 'err'),
    [],
  );
  // No advisories either — every field is canonical.
  assert.deepEqual(
    r.diagnostics.filter((d) =>
      ['license_unrecognized', 'too_many_keywords', 'plugin_wasm_self_hash_malformed'].includes(
        d.code,
      ),
    ),
    [],
  );
});

test('manifest metadata: non-SPDX :license surfaces license_unrecognized (warning) via WASM', async () => {
  const host = await SjonHost.load(wasmPath);
  const src = `(plugin :name x :version "1.0.0" :license "WTFPL")\n`;
  const r = host.validateDocument(src, { projectRoot: null, projectFile: null });
  const d = r.diagnostics.find((x) => x.code === 'license_unrecognized');
  assert.ok(d, `expected license_unrecognized in ${JSON.stringify(codes(r.diagnostics))}`);
  assert.equal(d.severity, 'warning');
});

test('manifest metadata: >16 :keywords surfaces too_many_keywords (warning)', async () => {
  const host = await SjonHost.load(wasmPath);
  const src = `(plugin :name x :version "1.0.0" :keywords [a b c d e f g h i j k l m n o p q r])\n`;
  const r = host.validateDocument(src, { projectRoot: null, projectFile: null });
  const d = r.diagnostics.find((x) => x.code === 'too_many_keywords');
  assert.ok(d, `expected too_many_keywords in ${JSON.stringify(codes(r.diagnostics))}`);
  assert.equal(d.severity, 'warning');
});

test('manifest metadata: malformed :wasm-sha256 surfaces plugin_wasm_self_hash_malformed (err)', async () => {
  const host = await SjonHost.load(wasmPath);
  const src = `(plugin :name x :version "1.0.0" :wasm-sha256 "not-a-hash")\n`;
  const r = host.validateDocument(src, { projectRoot: null, projectFile: null });
  const d = r.diagnostics.find((x) => x.code === 'plugin_wasm_self_hash_malformed');
  assert.ok(
    d,
    `expected plugin_wasm_self_hash_malformed in ${JSON.stringify(codes(r.diagnostics))}`,
  );
  assert.equal(d.severity, 'err');
});
