// v1.1 manifest-metadata coverage for the second-host TS loader. Mirrors
// the field-cluster tests in `src/ManifestLoader.zig` so the two ports
// stay in lockstep on the new metadata surface.

import test from 'node:test';
import assert from 'node:assert';

import { parse } from '../src/parser.ts';
import { loadManifest } from '../src/loader.ts';
import { validateDocument } from '../src/Host.ts';
import type { Diagnostic } from '../src/diagnostics.ts';

function manifestRootsOrThrow(src: string) {
  const diags: Diagnostic[] = [];
  const roots = parse(src, diags);
  const parseErrs = diags.filter((d) => d.severity === 'err');
  assert.strictEqual(parseErrs.length, 0, `parse errors: ${JSON.stringify(parseErrs)}`);
  return roots;
}

test('loader v1.1: :wasm-file captured on plugin', () => {
  const r = loadManifest(
    manifestRootsOrThrow('(plugin :name x :version "1.0.0" :wasm-file "plugin.wasm")'),
  );
  assert.strictEqual(r.errors.length, 0);
  assert.strictEqual(r.plugin.wasmFile, 'plugin.wasm');
});

test('loader v1.1: well-formed :wasm-sha256 captured, no diagnostic', () => {
  const r = loadManifest(
    manifestRootsOrThrow(
      '(plugin :name x :version "1.0.0" :wasm-sha256 "sha256-0000000000000000000000000000000000000000000000000000000000000000")',
    ),
  );
  assert.strictEqual(r.errors.length, 0);
  assert.strictEqual(r.plugin.wasmSha256?.startsWith('sha256-'), true);
  assert.strictEqual(
    r.diagnostics.find((d) => d.code === 'plugin_wasm_self_hash_malformed'),
    undefined,
  );
});

test('loader v1.1: malformed :wasm-sha256 emits plugin_wasm_self_hash_malformed', () => {
  const r = loadManifest(
    manifestRootsOrThrow('(plugin :name x :version "1.0.0" :wasm-sha256 "not-a-hash")'),
  );
  const codes = r.diagnostics.map((d) => d.code);
  assert.ok(
    codes.includes('plugin_wasm_self_hash_malformed'),
    `expected plugin_wasm_self_hash_malformed in ${JSON.stringify(codes)}`,
  );
});

test('loader v1.1: :authors accepts mixed string/symbol vector', () => {
  const r = loadManifest(
    manifestRootsOrThrow(
      '(plugin :name x :version "1.0.0" :authors ["Ada" Babbage "Grace Hopper"])',
    ),
  );
  assert.deepStrictEqual(r.plugin.authors, ['Ada', 'Babbage', 'Grace Hopper']);
});

test('loader v1.1: canonical SPDX :license accepted without warning', () => {
  const r = loadManifest(
    manifestRootsOrThrow('(plugin :name x :version "1.0.0" :license "CC0-1.0")'),
  );
  assert.strictEqual(r.plugin.license, 'CC0-1.0');
  assert.strictEqual(
    r.diagnostics.find((d) => d.code === 'license_unrecognized'),
    undefined,
  );
});

test('loader v1.1: non-SPDX :license emits license_unrecognized warning', () => {
  const r = loadManifest(
    manifestRootsOrThrow('(plugin :name x :version "1.0.0" :license "WTFPL")'),
  );
  const d = r.diagnostics.find((x) => x.code === 'license_unrecognized');
  assert.ok(d, 'expected license_unrecognized');
  assert.strictEqual(d!.severity, 'warning');
});

test('loader v1.1: :homepage / :repository captured verbatim', () => {
  const r = loadManifest(
    manifestRootsOrThrow(
      '(plugin :name x :version "1.0.0" :homepage "https://example.com" :repository "https://github.com/x/y")',
    ),
  );
  assert.strictEqual(r.plugin.homepage, 'https://example.com');
  assert.strictEqual(r.plugin.repository, 'https://github.com/x/y');
});

test('loader v1.1: :keywords stored as string array, in order', () => {
  const r = loadManifest(
    manifestRootsOrThrow('(plugin :name x :version "1.0.0" :keywords [graphics two-d shapes])'),
  );
  assert.deepStrictEqual(r.plugin.keywords, ['graphics', 'two-d', 'shapes']);
  assert.strictEqual(
    r.diagnostics.find((d) => d.code === 'too_many_keywords'),
    undefined,
  );
});

test('loader v1.1: >16 :keywords emits too_many_keywords warning, list still captured', () => {
  const r = loadManifest(
    manifestRootsOrThrow(
      '(plugin :name x :version "1.0.0" :keywords [a b c d e f g h i j k l m n o p q r])',
    ),
  );
  const d = r.diagnostics.find((x) => x.code === 'too_many_keywords');
  assert.ok(d, 'expected too_many_keywords');
  assert.strictEqual(d!.severity, 'warning');
  assert.strictEqual(r.plugin.keywords.length, 18);
});

test('loader v1.1: :sjon "1.0" captured, no error', () => {
  const r = loadManifest(manifestRootsOrThrow('(plugin :name x :version "1.0.0" :sjon "1.0")'));
  assert.strictEqual(r.plugin.sjonFormat, '1.0');
  assert.strictEqual(
    r.diagnostics.find((d) => d.code === 'sjon_format_unsupported'),
    undefined,
  );
});

test('loader v1.1: :sjon "99.0" emits sjon_format_unsupported error', () => {
  const r = loadManifest(manifestRootsOrThrow('(plugin :name x :version "1.0.0" :sjon "99.0")'));
  const d = r.diagnostics.find((x) => x.code === 'sjon_format_unsupported');
  assert.ok(d, 'expected sjon_format_unsupported');
  assert.strictEqual(d!.severity, 'err');
});

test('loader v1.1: SUPPORTED_SJON_FORMAT == "1.2" — bumping requires Zig+TS sync', () => {
  // If you bump this, also bump src/Plugin.zig:SUPPORTED_SJON_FORMAT.
  // `1.2` added the (cross-ref-provider …) form and the :provider /
  // :source-key cross-ref keys; `1.1` manifests keep loading, since the
  // check is "declared > supported", not "declared != supported".
  // (Imported indirectly via the loader's check.)
  for (const declared of ['1.1', '1.2']) {
    const r = loadManifest(
      manifestRootsOrThrow(`(plugin :name x :version "1.0.0" :sjon "${declared}")`),
    );
    assert.strictEqual(r.plugin.sjonFormat, declared);
    assert.strictEqual(
      r.diagnostics.find((d) => d.code === 'sjon_format_unsupported'),
      undefined,
    );
  }
});

test('loader v1.1: v1 manifest (no metadata) parses with empty metadata defaults', () => {
  const r = loadManifest(manifestRootsOrThrow('(plugin :name x :version "1.0.0")'));
  assert.strictEqual(r.errors.length, 0);
  assert.deepStrictEqual(r.plugin.authors, []);
  assert.strictEqual(r.plugin.license, '');
  assert.strictEqual(r.plugin.homepage, '');
  assert.strictEqual(r.plugin.repository, '');
  assert.deepStrictEqual(r.plugin.keywords, []);
  assert.strictEqual(r.plugin.sjonFormat, '');
  assert.strictEqual(r.plugin.wasmFile, undefined);
  assert.strictEqual(r.plugin.wasmSha256, undefined);
});

// ── `:optional` defaulting (spec §5.1) ──────────────────────────────────
//
// An unwritten `:optional` is false without a `:default` and true with one.
// This port used to hardcode `true`, so a key omitting `:optional` was
// required on Zig / Web / Rust and unrequired here. Every corpus fixture
// writes `:optional` explicitly, which is why nothing caught it.

test('loader: a key with no :optional and no :default is required', () => {
  const r = loadManifest(
    manifestRootsOrThrow(
      '(plugin :name p :version "1.0.0" (form :name f (key :name a :type symbol)))',
    ),
  );
  assert.strictEqual(r.plugin.forms[0]?.keys[0]?.optional, false);
});

test('loader: a key with no :optional but a :default is optional', () => {
  const r = loadManifest(
    manifestRootsOrThrow(
      '(plugin :name p :version "1.0.0" (form :name f (key :name a :type symbol :default x)))',
    ),
  );
  assert.strictEqual(r.plugin.forms[0]?.keys[0]?.optional, true);
});

test('loader: an explicit :optional wins over both defaults', () => {
  const both = loadManifest(
    manifestRootsOrThrow(
      '(plugin :name p :version "1.0.0" (form :name f (key :name a :type symbol :optional false :default x)))',
    ),
  );
  assert.strictEqual(both.plugin.forms[0]?.keys[0]?.optional, false);
  const bare = loadManifest(
    manifestRootsOrThrow(
      '(plugin :name p :version "1.0.0" (form :name f (key :name a :type symbol :optional true)))',
    ),
  );
  assert.strictEqual(bare.plugin.forms[0]?.keys[0]?.optional, true);
});

test('validator: an unadorned key is now reported missing, as on every other host', () => {
  const r = validateDocument(
    '(plugin :name p :version "1.0.0" (form :name f (key :name a :type symbol)))\n(f)\n',
    { projectRoot: null, resolver: null, projectFile: null },
  );
  assert.deepStrictEqual(
    r.diagnostics.filter((d) => d.severity === 'err').map((d) => d.code),
    ['missing_required_key'],
  );
});
