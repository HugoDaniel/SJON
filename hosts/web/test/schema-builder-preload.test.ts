// P3 Task 5 — the builder's cached-manifest fast path over the real WASM
// backend.
//
// The cache is keyed by the exact manifest text. A clean preload report
// retains its handle and every operation validates only the document, so
// the returned diagnostics are document-local. A report carrying *any*
// diagnostic has no usable fast path — handle-only validation cannot
// replay a manifest-phase warning, and it does not rerun the aggregate
// validators — so that handle is freed immediately, the text is
// remembered as rejected, and every later call keeps the historical
// `manifest + "\n\n" + source` composition, byte for byte.
//
// `host.preload` is wrapped, not mocked: the probe records the call and
// delegates to the real method, so every "exactly one" below counts real
// preloads. `_disposeHandle` is wrapped the same way
// (`PreloadedSchemaHandle.dispose` delegates there), so "freed exactly
// once" is observed at the ownership seam rather than inferred from the
// live set.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { s, SjonValidationError } from '@sjon-lang/schema';
import { SjonHost } from '../SjonHost.ts';
import type { PreloadedSchemaHandle } from '../SjonHost.ts';
import { createWasmBackend } from '../SjonSchemaBackend.ts';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..', '..');
const wasmPath = path.join(root, 'zig-out/bin/sjon.wasm');

const encoder = new TextEncoder();
const byteLength = (text: string): number => encoder.encode(text).byteLength;
const TWO_LF = '\n\n';

interface PreloadProbe {
  readonly host: SjonHost;
  /** Every argument handed to the real `host.preload`, in call order. */
  readonly calls: (string | readonly string[])[];
  /** Every handle the real `preload` minted. */
  readonly minted: PreloadedSchemaHandle[];
  /** Every handle the backend asked the host to release. */
  readonly freed: PreloadedSchemaHandle[];
}

async function probeHost(): Promise<PreloadProbe> {
  const host = await SjonHost.load(wasmPath);
  const calls: (string | readonly string[])[] = [];
  const minted: PreloadedSchemaHandle[] = [];
  const freed: PreloadedSchemaHandle[] = [];

  const realPreload = host.preload.bind(host);
  host.preload = (sources) => {
    calls.push(sources);
    const handle = realPreload(sources);
    minted.push(handle);
    return handle;
  };

  const realDisposeHandle = host._disposeHandle.bind(host);
  host._disposeHandle = (handle) => {
    freed.push(handle);
    realDisposeHandle(handle);
  };

  return { host, calls, minted, freed };
}

/** A manifest with no refinements, so the only diagnostics are the ones a test puts there. */
function profileSchema() {
  return s.form(
    'profile',
    {
      handle: s.string(),
      email: s.string(),
      score: s.number().min(0).max(100).optional(),
    },
    'bounds',
  );
}

function widgetSchema() {
  return s.form('widget', { label: s.string() }, 'ui');
}

/** A builder manifest the loader warns about: a fractional `:multiple-of`. */
function warnedSchema() {
  return s.form('warned', { offset: s.number().multipleOf(0.5) }, 'warn');
}

/** A builder manifest the aggregate pass rejects: a cross-ref to no known form. */
function danglingSchema() {
  return s.form('dangling', { target: s.crossRef('ghost') }, 'err');
}

const goodSource = '(bounds/profile :handle "ada" :email "ada@example.com")';
const badSource = '(bounds/profile :handle "ada" :email "ada@example.com" :score 999)';

test('builder: two .parse calls share one preload, and toJson sees only the source', async () => {
  const { host, calls } = await probeHost();
  const be = createWasmBackend(host);
  const Profile = profileSchema();

  const toJsonArgs: string[] = [];
  const realToJson = be.toJson;
  assert.ok(realToJson);
  be.toJson = (text) => {
    toJsonArgs.push(text);
    return realToJson(text);
  };

  const first = Profile.parse(goodSource, { backend: be });
  const second = Profile.parse(goodSource, { backend: be });

  assert.equal(first.handle, 'ada');
  assert.deepEqual(second, first);
  assert.equal(calls.length, 1, `expected exactly one host.preload call, got ${calls.length}`);
  assert.equal(calls[0], Profile.manifest());
  assert.deepEqual(toJsonArgs, [goodSource, goodSource]);
});

test('builder: .parse diagnostics are document-local under a retained handle', async () => {
  const { host, calls } = await probeHost();
  const be = createWasmBackend(host);
  const Profile = profileSchema();

  const result = Profile.safeParse(badSource, { backend: be });
  if (result.success) assert.fail('expected the out-of-range score to fail');

  assert.ok(result.error.errors.some((d) => d.code === 'number_above_max'));
  const sourceBytes = byteLength(badSource);
  for (const diagnostic of result.error.diagnostics) {
    assert.ok(diagnostic.span, `${diagnostic.code} should carry a span`);
    assert.ok(
      diagnostic.span.end <= sourceBytes,
      `${diagnostic.code} span ${diagnostic.span.start}..${diagnostic.span.end} escapes the ${sourceBytes}-byte document`,
    );
  }
  assert.equal(calls.length, 1);
});

test('builder: .parseValue reuses one preload for repeated validations', async () => {
  const { host, calls } = await probeHost();
  const be = createWasmBackend(host);
  const Profile = profileSchema();
  const value = {
    $form: 'profile',
    $ns: 'bounds',
    handle: 'ada',
    email: 'ada@example.com',
    score: 50,
  } as const;

  assert.deepEqual(Profile.parseValue(value, { backend: be }), value);
  assert.deepEqual(Profile.parseValue(value, { backend: be }), value);
  assert.equal(calls.length, 1, `expected exactly one host.preload call, got ${calls.length}`);
});

test('builder: Form.validate reuses one preload for repeated validations', async () => {
  const { host, calls } = await probeHost();
  const be = createWasmBackend(host);
  const Profile = profileSchema();

  const first = Profile.validate(goodSource, { backend: be });
  const second = Profile.validate(goodSource, { backend: be });

  assert.deepEqual(first.diagnostics, []);
  assert.deepEqual(second, first);
  assert.equal(calls.length, 1, `expected exactly one host.preload call, got ${calls.length}`);
});

test('builder: save({ validate: true }) reuses one preload for repeated saves', async () => {
  const { host, calls } = await probeHost();
  const be = createWasmBackend(host);
  const Profile = profileSchema();
  const document = Profile.open(goodSource, { backend: be });

  assert.equal(document.save({ validate: true }), goodSource);
  assert.equal(document.save({ validate: true }), goodSource);
  assert.equal(calls.length, 1, `expected exactly one host.preload call, got ${calls.length}`);
});

test('builder: the cache key is the exact manifest text, not the Form object', async () => {
  const { host, calls } = await probeHost();
  const be = createWasmBackend(host);
  const first = profileSchema();
  const second = profileSchema();
  assert.equal(first.manifest(), second.manifest());

  first.parse(goodSource, { backend: be });
  second.parse(goodSource, { backend: be });
  assert.equal(calls.length, 1, `expected one preload for one manifest text, got ${calls.length}`);
});

test('builder: dispose frees each cached handle exactly once and clears the cache', async () => {
  const { host, calls, minted, freed } = await probeHost();
  const be = createWasmBackend(host);

  profileSchema().parse(goodSource, { backend: be });
  widgetSchema().parse('(ui/widget :label "ok")', { backend: be });
  assert.equal(calls.length, 2);
  assert.equal(minted.length, 2);
  assert.equal(freed.length, 0);
  assert.equal(host._liveHandles.size, 2);

  assert.ok(be.dispose, 'the WASM backend must expose dispose()');
  be.dispose();
  assert.equal(freed.length, 2, 'each cached handle is freed exactly once');
  assert.equal(new Set(freed).size, 2);
  assert.equal(host._liveHandles.size, 0);

  // Idempotent: the map is empty, so there is nothing to re-free.
  be.dispose();
  assert.equal(freed.length, 2);

  // The cache is cleared, so a later call preloads afresh rather than
  // borrowing a disposed handle.
  profileSchema().parse(goodSource, { backend: be });
  assert.equal(calls.length, 3);
  assert.equal(host._liveHandles.size, 1);
  be.dispose();
  assert.equal(freed.length, 3);
  assert.equal(new Set(freed).size, 3);
  assert.equal(host._liveHandles.size, 0);
});

test('builder: a warning manifest preloads once, frees at once, then keeps the two-LF fallback', async () => {
  const { host, calls, freed } = await probeHost();
  const be = createWasmBackend(host);
  const Warned = warnedSchema();
  const source = '(warn/warned :offset 1.3)';
  const control = be.validate(`${Warned.manifest()}${TWO_LF}${source}`);

  assert.ok(
    control.diagnostics.some(
      (d) => d.code === 'numeric_bounds_invalid' && d.severity === 'warning',
    ),
    'the control must carry the manifest-phase warning',
  );
  assert.ok(control.diagnostics.some((d) => d.code === 'number_not_multiple'));

  for (let call = 0; call < 3; call++) {
    assert.deepEqual(
      Warned.validate(source, { backend: be }),
      control,
      `fallback result ${call + 1} must equal the composed control`,
    );
    assert.equal(calls.length, 1, 'one preload per exact manifest text, never per call');
    assert.equal(freed.length, 1, 'the dirty handle is disposed immediately');
    assert.equal(host._liveHandles.size, 0, 'no unusable handle is retained');
  }
});

test('builder: an error manifest preloads once, frees at once, then keeps the two-LF fallback', async () => {
  const { host, calls, freed } = await probeHost();
  const be = createWasmBackend(host);
  const Dangling = danglingSchema();
  const source = '(err/dangling :target some)';
  const control = be.validate(`${Dangling.manifest()}${TWO_LF}${source}`);

  assert.ok(
    control.diagnostics.some((d) => d.code === 'unknown_cross_ref_target' && d.severity === 'err'),
    'the control must carry the aggregate-phase error',
  );

  for (let call = 0; call < 3; call++) {
    assert.deepEqual(
      Dangling.validate(source, { backend: be }),
      control,
      `fallback result ${call + 1} must equal the composed control`,
    );
    assert.equal(calls.length, 1, 'one preload per exact manifest text, never per call');
    assert.equal(freed.length, 1, 'the dirty handle is disposed immediately');
    assert.equal(host._liveHandles.size, 0, 'no unusable handle is retained');
  }
});

// Keep the import honest: the tests above assert on SjonValidationError's
// shape through `.safeParse`, and this file must not silently pass if the
// builder stops throwing it.
test('builder: .parse still throws SjonValidationError for a document error', async () => {
  const { host } = await probeHost();
  const be = createWasmBackend(host);
  assert.throws(
    () => profileSchema().parse(badSource, { backend: be }),
    (err: unknown) => err instanceof SjonValidationError,
  );
});
