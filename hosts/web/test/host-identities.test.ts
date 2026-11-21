// P5 Task 4 — typed `result.identities` on the Web host.
//
// The identities array rides on the one `sjon_host_validate_document`
// result that `validateDocument` already returns; this file pins that it
// is typed, deterministic, preserved through the project-diagnostic
// spread and the `validateAgainst` / preloaded convenience paths, and
// costs no second engine call. The task's RED is `tsc`: Task 3 already
// emits the field, so a runtime-only assertion would have passed before
// any Web edit.
//
// The fixtures mirror the Zig `Host identities` family in
// `src/Host_tests.zig`: a default `:name` registry, a custom `:name-key`
// registry, and lexical `music/piece` scopes. The compile-time probes at
// the bottom are gated by `pnpm --filter @sjon-lang/web typecheck`.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { SjonHost } from '../SjonHost.ts';
import type {
  HostDiagnostic,
  HostOptions,
  HostResult,
  IdentityAddress,
  IdentityRow,
  IdentityScope,
} from '../sjon-reader.ts';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..', '..');
const wasmPath = path.join(root, 'zig-out/bin/sjon.wasm');

const base: HostOptions = { projectRoot: null, projectFile: null };

// `probe/kernel` and `probe/cue` on the default `:name` key: a root
// target, a duplicate (ambiguous), and an open `wrap` form.
const NAME_MANIFEST = `(plugin :name probe :version "1.0.0"
  (value-kind :name kernel-ref :underlying symbol
    :cross-ref (cross-ref :target kernel))
  (value-kind :name cue-ref :underlying symbol
    :cross-ref (cross-ref :target cue))
  (form :name kernel (key :name name :type symbol :optional true))
  (form :name cue (key :name name :type symbol :optional false))
  (form :name wrap :open true))`;

// One custom `:name-key id` fixture: a root target, a keyword child, and
// a vector element, so the exact address path steps (empty, string,
// integer) are all observable through the public type.
const ID_MANIFEST = `(plugin :name probe :version "1.0.0"
  (value-kind :name kernel-id :underlying symbol
    :cross-ref (cross-ref :target kernel :name-key id :acyclic true))
  (form :name kernel
    (key :name id :type symbol :optional false)
    (key :name next :type kernel-id :optional true))
  (form :name wrap :open true))`;

// Lexical scopes: `music/phrase` names live inside a `music/piece`
// scope-opener; `piece-ref` itself scopes on `piece`, so pieces nest.
const SCOPE_MANIFEST = `(plugin :name music :version "1.0.0"
  (value-kind :name phrase-name :underlying symbol
    :cross-ref (cross-ref :target phrase :scope piece))
  (value-kind :name piece-ref :underlying symbol
    :cross-ref (cross-ref :target piece :name-key title :scope piece))
  (form :name phrase (key :name name :type symbol :optional false))
  (form :name piece :open true
    (key :name title :type symbol :optional true)
    (key :name name :type symbol :optional true)))`;

test('validateDocument: resolved and ambiguous identities have their exact public types', async () => {
  const host = await SjonHost.load(wasmPath);
  const src = `${NAME_MANIFEST}
(kernel :name flow)
(kernel :name flow)
(kernel :name other)
`;
  const result: HostResult = host.validateDocument(src, base);
  const rows: readonly IdentityRow[] = result.identities;

  // Exact public objects: the duplicate is one ambiguous row with a
  // literal null address, the unique author name one resolved row at its
  // actual root. Sorted by (registry, scope, symbol): `flow`, `other`.
  assert.deepEqual(rows, [
    {
      registry: 'probe/kernel',
      scope: [],
      symbol: 'flow',
      status: 'ambiguous',
      address: null,
    },
    {
      registry: 'probe/kernel',
      scope: [],
      symbol: 'other',
      status: 'resolved',
      address: { root: 3, path: [] },
    },
  ] satisfies readonly IdentityRow[]);

  // The narrowing itself, on the rows that came over the wire.
  const [duplicate, unique] = rows;
  assert.equal(duplicate!.status, 'ambiguous');
  assert.equal(duplicate!.address, null);
  assert.equal(unique!.status, 'resolved');
  assert.deepEqual(unique!.address, { root: 3, path: [] });
});

test('validateDocument: same host and fresh host return identical identities', async () => {
  const source = `${SCOPE_MANIFEST}
(piece :title left (phrase :name p0))
(piece :title right (phrase :name p0))
(piece :title outer (piece :title inner (phrase :name p1)))
(piece :title left (phrase :name dup))
(piece :title left (phrase :name dup))
`;

  const host = await SjonHost.load(wasmPath);
  const first = host.validateDocument(source, base);
  const second = host.validateDocument(source, base);
  const fresh = (await SjonHost.load(wasmPath)).validateDocument(source, base);

  // Same host twice and a fresh instance over the same nested, multi-root
  // source: deterministic row order and identical addresses.
  assert.deepEqual(second.identities, first.identities);
  assert.deepEqual(fresh.identities, first.identities);
  assert.ok(first.identities.length > 0);

  // Sorted order pins ambiguity where the key sorts: the duplicate pair
  // (`dup`) precedes the duplicated scoped `p0` under `left`, and both
  // are the only address-free rows before the resolved scopes.
  const rows = first.identities;
  assert.deepEqual(rows[0], {
    registry: 'music/phrase',
    scope: [{ registry: 'music/piece', symbol: 'left' }],
    symbol: 'dup',
    status: 'ambiguous',
    address: null,
  });
  assert.deepEqual(rows[1], {
    registry: 'music/phrase',
    scope: [{ registry: 'music/piece', symbol: 'left' }],
    symbol: 'p0',
    status: 'ambiguous',
    address: null,
  });
  assert.deepEqual(rows[2], {
    registry: 'music/phrase',
    scope: [
      { registry: 'music/piece', symbol: 'outer' },
      { registry: 'music/piece', symbol: 'inner' },
    ],
    symbol: 'p1',
    status: 'resolved',
    address: { root: 3, path: [0, 0] },
  });
});

test('validateDocument: identities survive projectDiagnostics merging', async () => {
  const host = await SjonHost.load(wasmPath);
  const synthetic: HostDiagnostic = {
    phase: 'manifest',
    code: 'duplicate_plugin_name',
    severity: 'err',
    message: 'synthetic identity probe (testing)',
    span: { start: 0, end: 0 },
    path: ['project'],
    declarationSpan: null,
  };
  const src = `${ID_MANIFEST}
(kernel :id flow)
`;
  const result = host.validateDocument(src, { ...base, projectDiagnostics: [synthetic] });

  // The merge path spreads the WASM result and only overrides
  // `diagnostics`; identities must ride through that spread unchanged.
  assert.equal(result.diagnostics[0]!.code, 'duplicate_plugin_name');
  assert.deepEqual(result.identities, [
    {
      registry: 'probe/kernel',
      scope: [],
      symbol: 'flow',
      status: 'resolved',
      address: { root: 1, path: [] },
    },
  ] satisfies readonly IdentityRow[]);
});

test('validateDocument: one validation export and no identity reparse', async () => {
  const host = await SjonHost.load(wasmPath);

  // Wrap the existing public-internal export call, delegating to the real
  // method, so the count is the engine's own call path — not a replayed
  // helper. `_callBytesN` sits under `_callBytesTwo`, so it also catches
  // any export invoked around `_invokeHostExport`.
  const seenExports: string[] = [];
  const originalInvoke = host._invokeHostExport.bind(host);
  host._invokeHostExport = (fnName, source, wasmOptions) => {
    seenExports.push(fnName);
    return originalInvoke(fnName, source, wasmOptions);
  };
  const encodedCalls: string[] = [];
  const originalCallBytesN = host.encoder._callBytesN.bind(host.encoder);
  host.encoder._callBytesN = (fnName, parts) => {
    encodedCalls.push(fnName);
    return originalCallBytesN(fnName, parts);
  };

  const result = host.validateDocument(
    `${ID_MANIFEST}
(kernel :id flow)
`,
    base,
  );

  assert.deepEqual(seenExports, ['sjon_host_validate_document']);
  assert.deepEqual(encodedCalls, ['sjon_host_validate_document']);
  assert.equal(result.identities.length, 1);

  // No identity lookup method or export exists to be invoked: the field
  // is a projection of the validation result, never a second query.
  const surfaces = [
    Object.keys(host),
    Object.getOwnPropertyNames(Object.getPrototypeOf(host)),
    Object.keys(host.encoder),
    Object.getOwnPropertyNames(Object.getPrototypeOf(host.encoder)),
    Object.keys(host.encoder.exports),
  ];
  for (const surface of surfaces) {
    for (const name of surface) {
      assert.doesNotMatch(name, /identit/i);
    }
  }
});

test('validateAgainst and preloaded validation expose identities from their existing call', async () => {
  const host = await SjonHost.load(wasmPath);
  const document = '(kernel :id flow)\n';

  // The convenience path composes manifest + document into one source, so
  // the plugin occupies root 0 and the target root 1. Repeated calls must
  // agree exactly, addresses included.
  const first = host.validateAgainst(ID_MANIFEST, document);
  const second = host.validateAgainst(ID_MANIFEST, document);
  assert.deepEqual(second.identities, first.identities);
  assert.deepEqual(first.identities, [
    {
      registry: 'probe/kernel',
      scope: [],
      symbol: 'flow',
      status: 'resolved',
      address: { root: 1, path: [] },
    },
  ] satisfies readonly IdentityRow[]);

  // The preloaded path validates the document alone; its root index is
  // therefore layout-local. Compare the structural keys and statuses,
  // never the addresses, across the two layouts.
  const handle = host.preload(ID_MANIFEST);
  try {
    const fromPreload = host.validateDocument(document, { ...base, preloaded: handle });
    const repeated = host.validateDocument(document, { ...base, preloaded: handle });
    assert.deepEqual(repeated.identities, fromPreload.identities);
    assert.deepEqual(fromPreload.identities, [
      {
        registry: 'probe/kernel',
        scope: [],
        symbol: 'flow',
        status: 'resolved',
        address: { root: 0, path: [] },
      },
    ] satisfies readonly IdentityRow[]);

    const keys = (rows: readonly IdentityRow[]) =>
      rows.map((row) => ({
        registry: row.registry,
        scope: row.scope,
        symbol: row.symbol,
        status: row.status,
      }));
    assert.deepEqual(keys(fromPreload.identities), keys(first.identities));
  } finally {
    handle.dispose();
  }
});

test('IdentityRow narrows address through status', async () => {
  // Runtime half: both arms really appear on the wire.
  const host = await SjonHost.load(wasmPath);
  const rows = host.validateDocument(
    `${NAME_MANIFEST}
(kernel :name flow)
(kernel :name flow)
(kernel :name other)
`,
    base,
  ).identities;
  const resolved = rows.find((row) => row.status === 'resolved');
  const ambiguous = rows.find((row) => row.status === 'ambiguous');
  assert.ok(resolved);
  assert.ok(ambiguous);
  assert.equal(ambiguous.address, null);
  assert.deepEqual(resolved.address, { root: 3, path: [] });

  // Compile-time half (see the probes below): after `resolved` the
  // address needs no null-check; after `ambiguous` it is exactly null.
  assert.equal(_addressOrNull(resolved), resolved.address);
  assert.equal(_addressOrNull(ambiguous), null);
});

/** The type-level RED's positive half: this only compiles once the union narrows. */
function _addressOrNull(row: IdentityRow): IdentityAddress | null {
  switch (row.status) {
    case 'resolved':
      // No null-check: the discriminant is the whole guard.
      return row.address;
    case 'ambiguous':
      return row.address;
  }
}
void _addressOrNull;

/**
 * Positive narrowing proof that the first function cannot give: the
 * narrowed arm's address must satisfy the non-nullable type itself, else
 * the union is decorative and one of these returns is a type error.
 */
function _resolvedAddressIsNonNull(row: IdentityRow): IdentityAddress | null {
  if (row.status !== 'resolved') return null;
  return row.address;
}
function _ambiguousAddressIsNull(row: IdentityRow): null | undefined {
  if (row.status !== 'ambiguous') return undefined;
  return row.address;
}
void _resolvedAddressIsNonNull;
void _ambiguousAddressIsNull;

/**
 * Compile-time negative probes — `tsc --noEmit` is the gate, and an
 * unused `@ts-expect-error` is itself an error. A union that merely
 * carves out two names but leaves `address: IdentityAddress | null` on
 * both arms fails these.
 */
function _narrowingHasTeeth(row: IdentityRow): void {
  if (row.status === 'resolved') {
    const address: IdentityAddress = row.address;
    // @ts-expect-error a resolved row's address is never null
    const none: null = row.address;
    void address, none;
  } else {
    const none: null = row.address;
    // @ts-expect-error an ambiguous row's address is never an address
    const address: IdentityAddress = row.address;
    void none, address;
  }
}
void _narrowingHasTeeth;

/** The scope prefix is the stable public pair, not a ScopeId encoding. */
function _scopePrefixIsStable(link: IdentityScope): string {
  return `${link.registry}:${link.symbol}`;
}
void _scopePrefixIsStable;
