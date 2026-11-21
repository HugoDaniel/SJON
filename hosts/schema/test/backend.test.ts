// Backend seam: `runManifestValidation` is the single gate between the
// builder and a backend. A backend with no `validateWithManifest`
// capability must see the historical `manifest + "\n\n" + source`
// document — two LFs, byte for byte — so the native TypeScript validator
// keeps behaving exactly as it did. A backend with the capability must
// see the two arguments separate and never a composed string.
//
// `.parse`, `.parseValue`, `Form.validate`, and
// `FormDocument.save({validate:true})` all route through that gate.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  runManifestValidation,
  runParse,
  runParseValue,
  type ValidateBackend,
  type ValidateOutcome,
} from '../src/backend.ts';
import * as s from '../src/builder.ts';

const manifest = '(plugin :name p :version "1.0.0")';
const source = '(p/thing :n 1)';
const empty: ValidateOutcome = { diagnostics: [] };

test('runManifestValidation: a backend with no capability sees exactly two LFs', () => {
  const documents: string[] = [];
  const backend: ValidateBackend = {
    validate(document) {
      documents.push(document);
      return empty;
    },
  };

  const outcome = runManifestValidation(manifest, source, backend);

  assert.deepEqual(outcome, empty);
  assert.equal(documents.length, 1);
  assert.equal(documents[0], `${manifest}\n\n${source}`);
  // Two LFs, not one: this is the builder's historical separator, and P1's
  // one-LF `SjonHost.validateAgainst` is a different surface.
  assert.equal(documents[0]?.length, manifest.length + 2 + source.length);
});

test('runManifestValidation: a capability backend sees the manifest and source separately', () => {
  const pairs: { readonly manifest: string; readonly source: string }[] = [];
  const backend: ValidateBackend = {
    validate() {
      assert.fail('validate() must not be called when validateWithManifest exists');
    },
    validateWithManifest(manifestText, sourceText) {
      pairs.push({ manifest: manifestText, source: sourceText });
      return empty;
    },
  };

  const outcome = runManifestValidation(manifest, source, backend);

  assert.deepEqual(outcome, empty);
  assert.deepEqual(pairs, [{ manifest, source }]);
});

test('runParse and runParseValue keep toJson/fromValue source-only on the fallback path', () => {
  const documents: string[] = [];
  const toJsonSources: string[] = [];
  const backend: ValidateBackend = {
    validate(document) {
      documents.push(document);
      return empty;
    },
    toJson(text) {
      toJsonSources.push(text);
      return { $form: 'thing', $ns: 'p' };
    },
    fromValue() {
      return source;
    },
  };

  const parsed = runParse<{ $form: string; $ns: string }>(manifest, source, 'p', 'thing', backend);
  if (!parsed.success) assert.fail('expected the data parse to succeed');
  assert.equal(parsed.data.$form, 'thing');
  assert.equal(parsed.data.$ns, 'p');

  const value = { n: 1 };
  const parsedValue = runParseValue(manifest, value, backend);
  if (!parsedValue.success) assert.fail('expected the value parse to succeed');
  assert.deepEqual(parsedValue.data, value);

  assert.deepEqual(documents, [`${manifest}\n\n${source}`, `${manifest}\n\n${source}`]);
  assert.deepEqual(toJsonSources, [source]);
});

test('all four builder operations route through validateWithManifest when present', () => {
  const pairs: [string, string][] = [];
  const composed: string[] = [];
  const backend: ValidateBackend = {
    validate(document) {
      composed.push(document);
      return empty;
    },
    validateWithManifest(manifestText, sourceText) {
      pairs.push([manifestText, sourceText]);
      return empty;
    },
    toJson(text) {
      return { $form: 'thing', $ns: 'p', n: text.length };
    },
    fromValue() {
      return source;
    },
    applyEdit(text) {
      return text;
    },
  };
  const Thing = s.form('thing', { n: s.number() }, 'p');

  Thing.parse(source, { backend });
  Thing.parseValue({ $form: 'thing', $ns: 'p', n: 1 }, { backend });
  Thing.validate(source, { backend });
  Thing.open(source, { backend }).save({ validate: true });

  assert.equal(pairs.length, 4, `expected four manifest validations, got ${pairs.length}`);
  for (const [manifestText, sourceText] of pairs) {
    assert.equal(manifestText, Thing.manifest());
    assert.equal(sourceText, source);
  }
  assert.deepEqual(composed, [], 'no operation composed a document when the capability exists');
});
