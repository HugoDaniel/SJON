// The address surface: `sjon_address_of_span` and `sjon_node_table`,
// through `SjonEncoder`. Ask 25 wants a browser host to get from a byte
// to a §11.2 path and from a node to its span, off the same parse that
// validates the text — so these tests are written on the ask's own
// fixture and pin its byte offsets.
//
// Offsets here are UTF-8 bytes. The fixture's last line is deliberately
// past ASCII, so a UTF-16 reading of it would land somewhere else.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { pathOfRow, rowContaining, SjonEncoder } from '../sjon-reader.ts';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..', '..');
const wasmPath = path.join(root, 'zig-out/bin/sjon.wasm');

/** Ask 25's fixture: four roots, a nested expression, one line past ASCII. */
const fixture = [
  "; The spike's fixture: one declaration over time, one plain literal,",
  '; and a title in more than ASCII.',
  '(use-plugin "spike")',
  '',
  '(param :name heat :value (* 0.4 (sin (* time 0.2))))',
  '(param :name pace :value 0.25)',
  '(title :text "olá — ☀️ 日本")',
].join('\n');

/** The same document with the title's closing quote gone. */
const unterminated = fixture.replace('日本")', '日本)');

const enc = await SjonEncoder.load(wasmPath);

test('the fixture is the ask’s, byte for byte', () => {
  const bytes = new TextEncoder().encode(fixture);
  assert.equal(bytes.length, 247);
  assert.equal(Buffer.from(bytes).indexOf('0.4'), 153);
  // Transcript 7: the title's string is [222, 246) in bytes and would be
  // [222, 235) if anyone read it as UTF-16.
  assert.equal(Buffer.from(bytes).indexOf('"ol'), 222);
});

test('addressOfSpan: the 0.4 is {root: 1, path: ["value", 0]}', () => {
  const got = enc.addressOfSpan(fixture, 153, 156);
  assert.deepEqual(got, {
    root: 1,
    path: ['value', 0],
    span: [153, 156],
    kind: 'number',
  });
});

test('addressOfSpan: a caret inside the literal answers the same node', () => {
  assert.deepEqual(enc.addressOfSpan(fixture, 154, 154)?.path, ['value', 0]);
});

test('addressOfSpan: a span inside no root is null', () => {
  // The blank line between `(use-plugin …)` and the first `(param …)`.
  const between = fixture.indexOf('(param');
  assert.equal(enc.addressOfSpan(fixture, between - 1, between - 1), null);
  assert.equal(enc.addressOfSpan(fixture, 10_000, 10_000), null);
});

test('addressOfSpan: a span on the second param reports root 2', () => {
  const at = fixture.indexOf('0.25');
  const got = enc.addressOfSpan(fixture, at, at + 4);
  assert.equal(got?.root, 2);
  assert.deepEqual(got?.path, ['value']);
  assert.equal(got?.kind, 'number');
});

test('addressOfSpan: each root addresses itself with an empty path', () => {
  for (const [i, head] of ['use-plugin', 'param', 'param', 'title'].entries()) {
    const at = nthIndexOf(fixture, `(${head}`, head === 'param' ? i - 1 : 0);
    const got = enc.addressOfSpan(fixture, at, at + 1);
    assert.equal(got?.root, i, `root ${i} (${head})`);
    assert.deepEqual(got?.path, []);
    assert.equal(got?.kind, 'form');
  }
});

test('addressOfSpan: a whole keyword pair answers the enclosing form', () => {
  // §11.2 addresses a pair's value, so an edit over `:name heat` is a
  // `set_keyword` on the form, not an edit of the value.
  const at = fixture.indexOf(':name heat');
  const got = enc.addressOfSpan(fixture, at, at + ':name heat'.length);
  assert.equal(got?.kind, 'form');
  assert.deepEqual(got?.path, []);
  assert.equal(got?.root, 1);
});

test('addressOfSpan: a backwards range is refused, an empty one is a caret', () => {
  // Refused rather than normalised: swapping the ends would answer a
  // question nobody asked.
  assert.throws(() => enc.addressOfSpan(fixture, 156, 153), /InvalidSpan/);
  // The degenerate range is fine — that is what a caret is.
  assert.equal(enc.addressOfSpan(fixture, 153, 153)?.kind, 'number');
});

test('addressOfSpan: a document that does not parse still has addresses', () => {
  const at = unterminated.indexOf('0.4');
  assert.deepEqual(enc.addressOfSpan(unterminated, at, at + 3)?.path, ['value', 0]);
});

test('addressOfSpan: the address it returns is an action’s, verbatim', () => {
  const got = enc.addressOfSpan(fixture, 153, 156);
  assert.ok(got);
  const edited = enc.applyEdits(
    fixture,
    [{ op: 'replace', root: got.root, path: got.path, value: 0.5 }],
    { layout: 'preserve' },
  );
  assert.ok(edited.includes('(* 0.5 (sin'));
  // Preserve means every other byte is the author's: the title is still
  // the bytes it was, comments and all.
  assert.ok(edited.includes('(title :text "olá — ☀️ 日本")'));
});

/** The `n`th occurrence of `needle`, `n` clamped at zero. */
function nthIndexOf(haystack: string, needle: string, n: number): number {
  let at = haystack.indexOf(needle);
  for (let i = 0; i < n; i += 1) at = haystack.indexOf(needle, at + 1);
  return at;
}

test('nodeTable: a row for every literal the spike decorates', () => {
  const { nodes, diagnostics } = enc.nodeTable(fixture);
  assert.deepEqual(diagnostics, []);

  // The three numeric literals of the fixture, in source order, each one
  // a scrub handle: `0.4`, the `0.2` inside `(sin …)`, and `0.25`.
  const numbers = nodes.filter((n) => n.kind === 'number');
  assert.deepEqual(
    numbers.map((n) => fixture.slice(n.span[0], n.span[1])),
    ['0.4', '0.2', '0.25'],
  );
  // `0.4` is the ask's own pin.
  assert.deepEqual(numbers[0]?.span, [153, 156]);
});

test('nodeTable: byte 154 hit-tests to the 0.4, with no further call in', () => {
  const table = enc.nodeTable(fixture);
  const row = rowContaining(table, 154);
  assert.ok(row);
  assert.deepEqual(row.span, [153, 156]);
  assert.equal(row.kind, 'number');

  // And the row's path is the address, derived from the table alone.
  assert.deepEqual(pathOfRow(table, row), ['value', 0]);
  assert.equal(row.root, 1);

  // Which is the same answer the point export gives.
  assert.deepEqual(enc.addressOfSpan(fixture, 154, 154)?.path, ['value', 0]);
});

test('nodeTable: pre-order, so a parent is always an earlier row', () => {
  const { nodes } = enc.nodeTable(fixture);
  let roots = 0;
  for (const [i, row] of nodes.entries()) {
    assert.equal(row.i, i);
    if (row.parent < 0) {
      assert.equal(row.seg, null);
      assert.equal(row.root, roots);
      roots += 1;
    } else {
      assert.ok(row.parent < i, `row ${i} parent ${row.parent}`);
      assert.notEqual(row.seg, null);
    }
    // A kvpair is addressed through, never at: it gets no row.
    assert.notEqual(row.kind, 'kvpair');
    assert.equal(row.kind === 'form', row.head_span !== undefined);
  }
  assert.equal(roots, 4);
});

test('nodeTable: a key span rides on the value’s row', () => {
  const { nodes } = enc.nodeTable(fixture);
  const heat = nodes.find((n) => n.kind === 'symbol' && n.seg === 'name');
  assert.ok(heat);
  assert.equal(fixture.slice(heat.span[0], heat.span[1]), 'heat');
  assert.ok(heat.key_span);
  assert.equal(fixture.slice(heat.key_span[0], heat.key_span[1]), ':name');
});

test('nodeTable: a document that does not parse returns rows AND diagnostics', () => {
  const { nodes, diagnostics } = enc.nodeTable(unterminated);
  assert.ok(nodes.length > 0);
  assert.equal(diagnostics.length, 2);
  // The revision the parity parser throws on still addresses its literals.
  const at = unterminated.indexOf('0.4');
  const row = rowContaining(enc.nodeTable(unterminated), at + 1);
  assert.deepEqual(row?.span, [at, at + 3]);
});

test('nodeTable: the title’s span is UTF-8 bytes, not UTF-16 units', () => {
  const table = enc.nodeTable(fixture);
  const title = table.nodes.find((n) => n.kind === 'string' && n.seg === 'text');
  assert.ok(title);
  // Transcript 7: [222, 246) in bytes; a UTF-16 reading gives [222, 235).
  assert.deepEqual(title.span, [222, 246]);
  const bytes = new TextEncoder().encode(fixture);
  assert.equal(
    new TextDecoder().decode(bytes.slice(title.span[0], title.span[1])),
    '"olá — ☀️ 日本"',
  );
});

test('nodeTable: every row’s path resolves back to that row', () => {
  const table = enc.nodeTable(fixture);
  for (const row of table.nodes) {
    // The wasm host is the reference for what a path resolves to, so ask
    // it: the address the table spells must name a node whose span is
    // this row's.
    const back = enc.addressOfSpan(fixture, row.span[0], row.span[1]);
    assert.ok(back, `row ${row.i} addresses nothing`);
    assert.deepEqual(back.path, pathOfRow(table, row), `row ${row.i}`);
    assert.equal(back.root, row.root, `row ${row.i}`);
  }
});
