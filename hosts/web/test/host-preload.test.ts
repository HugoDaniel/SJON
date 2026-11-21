// Public `SjonHost.preload` handle API — the Web half of P3 Task 3.
//
// The raw ABI (`sjon_preload_schema` / `sjon_schema_free` /
// `preloadedHandle`) is pinned separately in `host-preload-abi.test.ts`.
// This suite pins the wrapper's contract, in the plan's order:
//
//   1. one string source normalizes to a one-entry report;
//   2. one clean handle validates several documents with identical
//      results and document-local spans;
//   3. inline `(plugin …)` declarations compose additively, and a form
//      name collision surfaces `ambiguous_form` (not a silent winner);
//   4. a partial preload reports `hasErrors` while keeping the clean
//      first plugin usable;
//   5. a second preload is independent — no replacement, no stacking,
//      no ambient schema;
//   6. declarative expr-funcs resolve through a handle in `hostEvalExpr`;
//   7. `dispose` is idempotent and use afterwards is refused in JS;
//   8. a foreign host's handle (and a bare numeric ID) is refused in JS
//      even when the receiving instance has a live entry with the same
//      number;
//   9. disposal from inside an active host call raises `SchemaInUse`,
//      and the guard is released on both the success and throw paths;
//  10. host `asyncDispose` frees every live handle;
//  11. 100 preload/dispose cycles leave the live-handle set empty.
//
// No wall-clock or linear-memory assertion: the lifecycle contract is
// the live set, never a timing number.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { SjonHost } from '../SjonHost.ts';
import type { PreloadedSchemaHandle } from '../SjonHost.ts';
import type { HostDiagnostic, HostOptions } from '../types.ts';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..', '..');
const wasmPath = path.join(root, 'zig-out/bin/sjon.wasm');

const base: HostOptions = { projectRoot: null, projectFile: null };
const encoder = new TextEncoder();

const codes = (diags: readonly HostDiagnostic[]): string[] => diags.map((d) => d.code);

/** Run `fn`, returning the thrown `Error`; fail when it does not throw. */
function thrown(fn: () => unknown): Error {
  try {
    fn();
  } catch (err) {
    assert.ok(err instanceof Error, `expected an Error, got ${String(err)}`);
    return err;
  }
  assert.fail('expected the call to throw');
}

/** The JS-side refusal for a foreign, disposed, or otherwise unbranded handle. */
function assertInvalidHandle(err: Error, message: RegExp): void {
  assert.equal(err.name, 'InvalidSchemaHandle');
  assert.match(err.message, message);
}

const shapesManifest = `(plugin :name shapes :version "1.0.0"
  (form :name box
    (key :name w :type number :optional false)
    (key :name label :type string :optional true)))`;

const bystanderManifest = '(plugin :name bystander :version "1.0.0")';

// Two top-level roots: parses, then fails the loader's single-(plugin …)
// shape gate with `invalid_manifest`, anchored to input ordinal 1.
const twoRootsManifest = `(plugin :name a :version "1.0.0")
(plugin :name b :version "1.0.0")`;

// A declaration-only expr-func: the schema knows `double`'s signature but
// no `:impl` can execute it.
const declarativeEvalManifest = `(plugin :name ev :version "1.0.0"
  (expr-func :name double :arity (fixed 1) :params [number] :result number))`;

test('preload: one string source normalizes to a one-entry report', async () => {
  const host = await SjonHost.load(wasmPath);

  const fromString = host.preload(shapesManifest);
  const fromArray = host.preload([shapesManifest]);

  assert.equal(fromString.hasErrors, false);
  assert.deepEqual(fromString.diagnostics, []);
  assert.equal(fromString.sourceDiagnostics.length, 1);
  assert.deepEqual(fromString.sourceDiagnostics[0], []);
  assert.deepEqual(fromString.aggregateDiagnostics, []);
  assert.deepEqual(fromString.loadedPlugins, [{ name: 'shapes', version: null, formCount: 1 }]);

  // The array form is the same report; the two calls mint distinct live
  // handles rather than one replacing the other.
  assert.deepEqual(fromArray.loadedPlugins, fromString.loadedPlugins);
  assert.notEqual(fromArray, fromString);
  assert.equal(host._liveHandles.size, 2);

  for (const handle of [fromString, fromArray]) {
    const r = host.validateDocument('(box :w 1)\n', { ...base, preloaded: handle });
    assert.deepEqual(r.diagnostics, []);
    assert.deepEqual(
      r.loadedPlugins.map((p) => p.name),
      ['shapes'],
    );
  }

  fromString.dispose();
  fromArray.dispose();
  assert.equal(host._liveHandles.size, 0);
});

test('preload: one clean handle validates documents identically with document-local spans', async () => {
  const host = await SjonHost.load(wasmPath);
  const schema = host.preload(shapesManifest);

  const documents = [
    // multi-form clean document
    '(box :w 1)\n(box :w 2)\n',
    // missing required key
    '(box)\n',
    // wrong underlying type plus an unknown key
    '(box :w "nope" :bogus 1)\n',
  ];

  for (const document of documents) {
    const viaHandle = host.validateDocument(document, { ...base, preloaded: schema });
    const repeat = host.validateDocument(document, { ...base, preloaded: schema });

    // Repeated validation through one handle is deterministic.
    assert.deepEqual(repeat, viaHandle);

    // The composed-source convenience path (which prepends the manifest)
    // produces the same diagnostics semantically — phases, codes, paths —
    // while the handle path's spans index the document alone.
    const control = host.validateAgainst(shapesManifest, document);
    assert.deepEqual(codes(viaHandle.diagnostics), codes(control.diagnostics));
    assert.deepEqual(
      viaHandle.diagnostics.map((d) => d.phase),
      control.diagnostics.map((d) => d.phase),
    );
    assert.deepEqual(
      viaHandle.diagnostics.map((d) => d.path),
      control.diagnostics.map((d) => d.path),
    );

    const documentBytes = encoder.encode(document).byteLength;
    for (const d of viaHandle.diagnostics) {
      assert.ok(
        d.span.start <= documentBytes && d.span.end <= documentBytes,
        `${d.code} span ${d.span.start}..${d.span.end} leaves the document (${documentBytes} bytes)`,
      );
    }
  }

  assert.deepEqual(
    host
      .validateDocument(documents[0]!, { ...base, preloaded: schema })
      .loadedPlugins.map((p) => p.name),
    ['shapes'],
  );

  schema.dispose();
});

test('preload: inline declarations compose additively and name collisions surface ambiguous_form', async () => {
  const host = await SjonHost.load(wasmPath);
  const schema = host.preload(shapesManifest);

  // The document declares its own plugin AND uses the preloaded form.
  const additive = `(plugin :name extras :version "1.0.0"
  (form :name tag (key :name t :type symbol :optional false)))

(box :w 1)
(tag :t hello)
`;
  const r = host.validateDocument(additive, { ...base, preloaded: schema });
  assert.deepEqual(r.diagnostics, []);
  assert.deepEqual(
    r.loadedPlugins.map((p) => p.name),
    ['shapes', 'extras'],
  );

  // Both plugins declare `box`: a bare data form sees two claimants and
  // must report `ambiguous_form` rather than silently picking one.
  const collision = `(plugin :name rival :version "1.0.0"
  (form :name box (key :name w :type number :optional false)))

(box :w 1)
`;
  const c = host.validateDocument(collision, { ...base, preloaded: schema });
  const ambiguous = c.diagnostics.find((d) => d.code === 'ambiguous_form');
  assert.ok(ambiguous, `expected ambiguous_form, got ${codes(c.diagnostics).join(',')}`);
  assert.equal(ambiguous.phase, 'validation');
  assert.ok(ambiguous.span.end <= encoder.encode(collision).byteLength);

  schema.dispose();
});

test('preload: a partial preload keeps the clean first plugin usable', async () => {
  const host = await SjonHost.load(wasmPath);
  const schema = host.preload([shapesManifest, twoRootsManifest]);

  assert.equal(schema.hasErrors, true);
  // Input-index aligned: the failure at index 1 neither compacts the
  // slice nor shifts the clean first source.
  assert.equal(schema.sourceDiagnostics.length, 2);
  assert.deepEqual(schema.sourceDiagnostics[0], []);
  const second = schema.sourceDiagnostics[1]!;
  assert.equal(second.length, 1);
  assert.equal(second[0]!.code, 'invalid_manifest');
  assert.equal(second[0]!.phase, 'manifest');
  assert.ok(
    second[0]!.message.includes('source 1'),
    `message must name the input index: ${second[0]!.message}`,
  );
  // Flattened view: source reports in input order, then aggregate.
  assert.deepEqual(schema.diagnostics, second);
  assert.deepEqual(schema.aggregateDiagnostics, []);
  assert.deepEqual(
    schema.loadedPlugins.map((p) => p.name),
    ['shapes'],
  );

  // Native Host permits explicit partial use; the wrapper does too.
  const r = host.validateDocument('(box :w 1)\n', { ...base, preloaded: schema });
  assert.deepEqual(r.diagnostics, []);
  assert.deepEqual(
    r.loadedPlugins.map((p) => p.name),
    ['shapes'],
  );

  schema.dispose();
});

test('preload: a second preload is independent — no replacement, no stacking, no ambient schema', async () => {
  const host = await SjonHost.load(wasmPath);
  const shapes = host.preload(shapesManifest);
  const bystander = host.preload(bystanderManifest);
  assert.equal(host._liveHandles.size, 2);

  // The first handle still resolves its own schema after the second
  // preload — and never gained the second's plugins.
  const viaShapes = host.validateDocument('(box :w 1)\n', { ...base, preloaded: shapes });
  assert.deepEqual(viaShapes.diagnostics, []);
  assert.deepEqual(
    viaShapes.loadedPlugins.map((p) => p.name),
    ['shapes'],
  );

  // The second handle works too, without the first's forms in scope.
  const viaBystander = host.validateDocument('(box :w 1)\n', { ...base, preloaded: bystander });
  assert.deepEqual(codes(viaBystander.diagnostics), ['unknown_form']);

  // There is no ambient/current schema: the same document without an
  // option sees nothing.
  const bare = host.validateDocument('(box :w 1)\n', base);
  assert.deepEqual(codes(bare.diagnostics), ['unknown_form']);

  shapes.dispose();
  bystander.dispose();
});

test('preload: declarative expr-func evaluation reaches the evaluator through a handle', async () => {
  const host = await SjonHost.load(wasmPath);
  const schema = host.preload(declarativeEvalManifest);

  // With the handle, `double` resolves as a declaration-only function and
  // fails at execution (`plugin_func_failed`) instead of evaluating as
  // form-as-data.
  const withHandle = host.hostEvalExpr('(double 21)', { ...base, preloaded: schema });
  assert.equal(withHandle.value, null);
  assert.deepEqual(codes(withHandle.diagnostics), ['plugin_func_failed']);
  assert.equal(withHandle.diagnostics[0]!.phase, 'validation');
  assert.deepEqual(
    withHandle.loadedPlugins.map((p) => p.name),
    ['ev'],
  );

  // Without the handle the same form is form-as-data — the contrast pins
  // that the handle, not the option parser, supplied the schema.
  const bare = host.hostEvalExpr('(double 21)', base);
  assert.deepEqual(bare.diagnostics, []);
  assert.deepEqual(bare.value, { $form: 'double', children: [21], kvpairs: {} });

  schema.dispose();
});

test('preload: dispose is idempotent and use afterwards is refused in JS', async () => {
  const host = await SjonHost.load(wasmPath);
  const schema = host.preload(shapesManifest);
  assert.equal(host._liveHandles.size, 1);

  schema.dispose();
  assert.equal(host._liveHandles.size, 0);
  // Idempotent: no throw, no double free.
  schema.dispose();
  assert.equal(host._liveHandles.size, 0);

  // The refusal is JS-side (`InvalidSchemaHandle`), not a WASM error name.
  for (const call of [
    () => host.validateDocument('(box :w 1)\n', { ...base, preloaded: schema }),
    () => host.hostEvalExpr('(+ 1 2)', { ...base, preloaded: schema }),
  ]) {
    assertInvalidHandle(thrown(call), /disposed/);
  }

  // Minting a new handle (even one that would reuse the freed numeric ID)
  // cannot resurrect the disposed object.
  const fresh = host.preload(shapesManifest);
  assert.equal(host._liveHandles.size, 1);
  assertInvalidHandle(
    thrown(() => host.validateDocument('(box :w 1)\n', { ...base, preloaded: schema })),
    /disposed/,
  );
  const r = host.validateDocument('(box :w 1)\n', { ...base, preloaded: fresh });
  assert.deepEqual(r.diagnostics, []);

  fresh.dispose();
});

test('preload: foreign and unbranded handles are refused before WASM', async () => {
  const hostA = await SjonHost.load(wasmPath);
  const hostB = await SjonHost.load(wasmPath);

  const a = hostA.preload(shapesManifest);
  // Both instances start their table at 1, so B's first handle carries the
  // same numeric ID as A's. Raw IDs have no owner token: the JS brand is
  // the only thing that tells them apart.
  const b = hostB.preload(shapesManifest);

  assertInvalidHandle(
    thrown(() => hostB.validateDocument('(box :w 1)\n', { ...base, preloaded: a })),
    /different host/,
  );
  assertInvalidHandle(
    thrown(() => hostB.hostEvalExpr('(+ 1 2)', { ...base, preloaded: a })),
    /different host/,
  );

  // A bare numeric ID is not a handle even when the instance has a live
  // entry with that number; if it reached WASM it would validate.
  const bareNumber = 1 as unknown as PreloadedSchemaHandle;
  assertInvalidHandle(
    thrown(() => hostB.validateDocument('(box :w 1)\n', { ...base, preloaded: bareNumber })),
    /not a SjonHost\.preload handle/,
  );

  // Each host's own brand still works.
  assert.deepEqual(
    hostA.validateDocument('(box :w 1)\n', { ...base, preloaded: a }).diagnostics,
    [],
  );
  assert.deepEqual(
    hostB.validateDocument('(box :w 1)\n', { ...base, preloaded: b }).diagnostics,
    [],
  );

  a.dispose();
  b.dispose();
});

test('preload: disposal from inside an active host call raises SchemaInUse', async () => {
  let schema: PreloadedSchemaHandle | null = null;
  let disposeError: unknown = null;
  let hostDisposeError: unknown = null;
  let hostDisposePromise: Promise<void> | null = null;
  let host: SjonHost | null = null;

  host = await SjonHost.load(wasmPath, {
    resolver: () => {
      try {
        schema!.dispose();
      } catch (err) {
        disposeError = err;
      }
      // Host disposal while the same call is in flight must refuse too.
      hostDisposePromise = host![Symbol.asyncDispose]().then(
        () => {
          hostDisposeError = null;
        },
        (err: unknown) => {
          hostDisposeError = err;
        },
      );
      return { kind: 'failure', code: 'unresolved_plugin', detail: 'resolver placeholder' };
    },
  });
  schema = host.preload(shapesManifest);

  const r = host.validateDocument('(use-plugin "shapes")\n', base);
  await hostDisposePromise;

  // The resolver ran inside the host call: its failure surfaces as a
  // diagnostic, and neither disposal was allowed.
  assert.deepEqual(codes(r.diagnostics), ['unresolved_plugin']);
  assert.ok(disposeError instanceof Error);
  assert.equal(disposeError.name, 'SchemaInUse');
  assert.match(disposeError.message, /active host call/);
  assert.ok(hostDisposeError instanceof Error);
  assert.equal(hostDisposeError.name, 'SchemaInUse');
  assert.equal(host._liveHandles.size, 1);

  // After the call the guard is released: the handle disposes normally.
  schema.dispose();
  assert.equal(host._liveHandles.size, 0);
});

test('preload: a throwing host call still releases the active-call guard', async () => {
  const host = await SjonHost.load(wasmPath);
  const schema = host.preload(shapesManifest);

  // `JSON.stringify` throws on a BigInt inside `_invokeHostExport` — after
  // the call counter is incremented and before WASM is reached. The
  // `finally` must still decrement it.
  const err = thrown(() =>
    host.validateDocument('(box :w 1)\n', {
      ...base,
      preloaded: schema,
      heldSymbol: 1n as unknown as string,
    }),
  );
  assert.equal(err.name, 'TypeError');

  // If the counter leaked, this would throw SchemaInUse.
  schema.dispose();
  assert.equal(host._liveHandles.size, 0);
});

test('preload: host asyncDispose frees every live handle', async () => {
  const host = await SjonHost.load(wasmPath);
  const handles = [
    host.preload(shapesManifest),
    host.preload(bystanderManifest),
    host.preload(shapesManifest),
  ];
  assert.equal(host._liveHandles.size, 3);

  await host[Symbol.asyncDispose]();
  assert.equal(host._liveHandles.size, 0);

  for (const handle of handles) {
    // Already disposed by the host: each dispose is a no-op.
    handle.dispose();
    assertInvalidHandle(
      thrown(() => host.validateDocument('(box :w 1)\n', { ...base, preloaded: handle })),
      /disposed/,
    );
  }
});

test('preload: 100 preload/dispose cycles leave the live set empty', async () => {
  const host = await SjonHost.load(wasmPath);
  const seen = new Set<PreloadedSchemaHandle>();

  for (let i = 0; i < 100; i++) {
    const handle = host.preload(shapesManifest);
    seen.add(handle);
    assert.equal(host._liveHandles.size, 1);

    const r = host.validateDocument('(box :w 1)\n', { ...base, preloaded: handle });
    assert.deepEqual(r.diagnostics, []);

    handle.dispose();
    assert.equal(host._liveHandles.size, 0);
  }

  // Each cycle minted a distinct handle object — a new lifetime, not a
  // recycled JS object.
  assert.equal(seen.size, 100);
});
