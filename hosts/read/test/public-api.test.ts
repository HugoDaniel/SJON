// Task 1 pins the package's public contract: the manifest/publish shape, the
// empty-input behaviour, and the node vocabulary every later task fills in.
// The grammar is Tasks 2–5; passing this file does not mean SJON non-empty
// source parses yet.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

import {
  ReadError,
  fields,
  read,
  readResult,
  type BooleanNode,
  type DateNode,
  type FormNode,
  type KeywordNode,
  type KvpairNode,
  type NilNode,
  type Node,
  type NumberNode,
  type ReadDiagnostic,
  type ReadResult,
  type Span,
  type StringNode,
  type SymbolNode,
  type TimeNode,
  type VectorNode,
} from '../src/index.ts';

interface PackageManifest {
  readonly dependencies?: Record<string, string>;
  readonly scripts?: {
    readonly typecheck?: string;
    readonly test?: string;
    readonly prepack?: string;
  };
  readonly exports?: Record<string, unknown>;
  readonly publishConfig?: {
    readonly exports?: Record<string, unknown>;
  };
}

// Read from disk rather than importing JSON: `resolveJsonModule` is not in the
// host flag set, and this asserts the manifest Node actually publishes.
const packageJsonPath = fileURLToPath(new URL('../package.json', import.meta.url));
const manifest = JSON.parse(readFileSync(packageJsonPath, 'utf8')) as PackageManifest;

test('package manifest declares no runtime dependencies', () => {
  assert.equal(manifest.dependencies, undefined);
});

test('workspace and packed export maps name the same subpaths', () => {
  const sourceKeys = Object.keys(manifest.exports ?? {}).sort();
  const packedKeys = Object.keys(manifest.publishConfig?.exports ?? {}).sort();
  assert.deepEqual(sourceKeys, packedKeys);
  assert.deepEqual(sourceKeys, ['.']);
});

test('source exports resolve sources; the packed map resolves dist', () => {
  assert.equal(manifest.exports?.['.'], './src/index.ts');
  assert.deepEqual(manifest.publishConfig?.exports?.['.'], {
    types: './dist/index.d.ts',
    default: './dist/index.js',
  });
});

test('prepack compiles tsconfig.build.json and both workspace gates exist', () => {
  assert.match(manifest.scripts?.prepack ?? '', /tsconfig\.build\.json/);
  assert.equal(typeof manifest.scripts?.typecheck, 'string');
  assert.equal(typeof manifest.scripts?.test, 'string');
});

test("read('') returns an empty root list", () => {
  const roots: Node[] = read('');
  assert.deepEqual(roots, []);
});

test("readResult('') returns no roots and no diagnostics", () => {
  const result: ReadResult = readResult('');
  assert.deepEqual(result.roots, []);
  assert.deepEqual(result.diagnostics, []);
});

test('the node vocabulary is one tagged union carrying byte spans', () => {
  const span: Span = { start: 0, end: 0 };
  const nil: NilNode = { tag: 'nil', span };
  const form: FormNode = {
    tag: 'form',
    span,
    head: 'camera',
    namespace: null,
    headSpan: span,
    children: [],
  };
  const kvpair: KvpairNode = { tag: 'kvpair', span, key: 'zoom', keySpan: span, value: nil };
  const vector: VectorNode = { tag: 'vector', span, elements: [] };
  const number: NumberNode = { tag: 'number', span, value: 1.5, unit: null, integer: null };
  const date: DateNode = { tag: 'date', span, year: 2026, month: 5, day: 19 };
  const time: TimeNode = { tag: 'time', span, hour: 12, minute: 34, second: 56, millisecond: 0 };
  const string: StringNode = { tag: 'string', span, value: 'héllo' };
  const symbol: SymbolNode = { tag: 'symbol', span, value: 'a' };
  const keyword: KeywordNode = { tag: 'keyword', span, value: 'k' };
  const boolean: BooleanNode = { tag: 'boolean', span, value: true };

  const nodes: readonly Node[] = [
    form,
    kvpair,
    vector,
    number,
    date,
    time,
    string,
    symbol,
    keyword,
    boolean,
    nil,
  ];
  assert.deepEqual(
    nodes.map((node) => node.tag),
    [
      'form',
      'kvpair',
      'vector',
      'number',
      'date',
      'time',
      'string',
      'symbol',
      'keyword',
      'boolean',
      'nil',
    ],
  );
  assert.deepEqual(form.headSpan, { start: 0, end: 0 });
  assert.equal(kvpair.value, nil);
});

test('fields on a hand-built empty form is empty', () => {
  const span: Span = { start: 0, end: 7 };
  const emptyForm: FormNode = {
    tag: 'form',
    span,
    head: 'a',
    namespace: null,
    headSpan: { start: 1, end: 2 },
    children: [],
  };

  const view = fields(emptyForm);
  assert.deepEqual(view.pairs, []);
  assert.deepEqual(view.positionals, []);
  assert.equal(view.get('k'), undefined);
});

test('ReadError carries the result it was built from', () => {
  const diagnostic: ReadDiagnostic = {
    code: 'unexpected_end',
    severity: 'err',
    message: 'unexpected end of input',
    span: { start: 0, end: 0 },
    path: [],
  };
  const result: ReadResult = { roots: [], diagnostics: [diagnostic] };

  const error = new ReadError(result);
  assert.ok(error instanceof Error);
  assert.equal(error.name, 'ReadError');
  assert.equal(error.result, result);
  assert.match(error.message, /unexpected_end/);
});
