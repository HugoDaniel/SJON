//! Native `sjon-lsp` routing scenarios for editor schema bundles.
//!
//! These tests drive the installed executable exactly as an editor would:
//! Content-Length-framed JSON-RPC over stdio, real temporary workspaces, and
//! real `sjon-lsp.sjon` bundles. They import only plan 01's transport harness;
//! framing, initialization, request correlation, and cleanup stay in one
//! place.
//!
//! Run through `zig build lsp-native-test`, or directly:
//!
//!     SJON_LSP_SERVER=/absolute/path/to/zig-out/bin/sjon-lsp \
//!       node --test tools/lsp_bundle_tests.mjs

import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import test from 'node:test';

import { spawnLspServer } from './lsp_rpc_harness.mjs';

const DOCUMENT_LANGUAGE = 'sjon';
const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');

/// Absolute server path, or an immediate actionable failure. Never PATH.
function requireServerPath() {
  const serverPath = process.env.SJON_LSP_SERVER;
  if (serverPath === undefined || serverPath.length === 0) {
    throw new Error(
      'SJON_LSP_SERVER is not set. Run `zig build lsp` to install the binary, then re-run with SJON_LSP_SERVER set to the absolute path of zig-out/bin/sjon-lsp.',
    );
  }
  return serverPath;
}

function range(startLine, startCharacter, endLine, endCharacter) {
  return {
    start: { line: startLine, character: startCharacter },
    end: { line: endLine, character: endCharacter },
  };
}

async function makeRoot(prefix) {
  const dir = await mkdtemp(join(tmpdir(), prefix));
  return {
    dir,
    rootUri: pathToFileURL(dir).href,
    uri: (name) => pathToFileURL(join(dir, name)).href,
    write: async (name, data) => {
      const path = join(dir, name);
      await mkdir(join(path, '..'), { recursive: true });
      await writeFile(path, data);
    },
  };
}

/// One workspace with an ordered alpha bundle and a beta bundle. Both
/// manifests declare a form whose head completion can only come from that
/// bundle, plus the cross-ref vocabulary used by the navigation scenario.
async function makeTwoBundleFixture() {
  const fixture = await makeRoot('sjon-lsp-bundles-');
  await mkdir(join(fixture.dir, 'alpha'), { recursive: true });
  await mkdir(join(fixture.dir, 'beta'), { recursive: true });
  await fixture.write(
    'alpha.sjon',
    `(plugin :name alpha :version "1.0.0"
  (value-kind :name phrase-name :underlying symbol :cross-ref (cross-ref :target phrase))
  (form :name alpha-form
    (key :name alpha-key :type string :optional false :description "Alpha key."))
  (form :name phrase (key :name name :type symbol :optional false))
  (form :name jump (key :name target :type phrase-name :optional false)))
`,
  );
  await fixture.write(
    'beta.sjon',
    `(plugin :name beta :version "1.0.0"
  (form :name beta-form
    (key :name beta-key :type string :optional false)))
`,
  );
  await fixture.write(
    'sjon-lsp.sjon',
    `(sjon-lsp :version 1 :bundles [
  (bundle :name alpha :files ["alpha/**"] :manifests ["alpha.sjon"])
  (bundle :name beta :files ["beta/**"] :manifests ["beta.sjon"])
])
`,
  );
  return fixture;
}

/// Two bundles whose manifests declare the same `phrase` cross-ref form.
/// Used to prove that workspace symbol merging does not merge reference
/// scope: the same name in each document must stay independently renameable.
async function makeSharedSymbolFixture() {
  const fixture = await makeRoot('sjon-lsp-symbols-');
  await mkdir(join(fixture.dir, 'alpha'), { recursive: true });
  await mkdir(join(fixture.dir, 'beta'), { recursive: true });
  for (const name of ['alpha', 'beta']) {
    await fixture.write(
      `${name}.sjon`,
      `(plugin :name ${name} :version "1.0.0"
  (value-kind :name phrase-name :underlying symbol :cross-ref (cross-ref :target phrase))
  (form :name phrase (key :name name :type symbol :optional false)))
`,
    );
  }
  await fixture.write(
    'sjon-lsp.sjon',
    `(sjon-lsp :version 1 :bundles [
  (bundle :name alpha :files ["alpha/**"] :manifests ["alpha.sjon"])
  (bundle :name beta :files ["beta/**"] :manifests ["beta.sjon"])
])
`,
  );
  return fixture;
}

async function makeUnavailableFixture() {
  const fixture = await makeRoot('sjon-lsp-unavailable-');
  await mkdir(join(fixture.dir, 'broken'), { recursive: true });
  await fixture.write(
    'sjon-lsp.sjon',
    `(sjon-lsp :version 1 :bundles [
  (bundle :name broken :files ["broken/**"] :manifests ["missing.sjon"])
])
`,
  );
  return fixture;
}

function didOpen(client, uri, version, text) {
  client.notify('textDocument/didOpen', {
    textDocument: { uri, languageId: DOCUMENT_LANGUAGE, version, text },
  });
}

function didChange(client, uri, version, text) {
  client.notify('textDocument/didChange', {
    textDocument: { uri, version },
    contentChanges: [{ text }],
  });
}

function position(line, character) {
  return { line, character };
}

function completionLabels(result) {
  if (result === null || result === undefined) return [];
  const items = Array.isArray(result) ? result : (result.items ?? []);
  return items.map((item) => item.label);
}

async function pull(client, uri) {
  return client.request('textDocument/diagnostic', { textDocument: { uri } });
}

function diagnosticCodes(report) {
  return report.items.map((diagnostic) => diagnostic.code);
}

const PUSH_METHOD = 'textDocument/publishDiagnostics';
const REGISTER_METHOD = 'client/registerCapability';

function didSave(client, uri, text) {
  const params = { textDocument: { uri } };
  if (text !== undefined) params.text = text;
  client.notify('textDocument/didSave', params);
}

function didChangeWatchedFiles(client, uri, type) {
  client.notify('workspace/didChangeWatchedFiles', {
    changes: [{ uri, type }],
  });
}

function pushReports(client) {
  return client
    .transcript()
    .filter(
      (record) =>
        record.direction === 'received' &&
        record.kind === 'notification' &&
        record.message.method === PUSH_METHOD,
    )
    .map((record) => record.message.params);
}

function serverRequests(client, method) {
  return client
    .transcript()
    .filter(
      (record) =>
        record.direction === 'received' &&
        record.kind === 'request' &&
        record.message.method === method,
    )
    .map((record) => record.message);
}

/// Every replacement text an action offers against `uri`, regardless of
/// which WorkspaceEdit shape the client negotiated.
function actionEditTexts(action, uri) {
  const texts = [];
  const edit = action.edit ?? {};
  if (edit.changes !== undefined) {
    for (const [target, edits] of Object.entries(edit.changes)) {
      if (target !== uri) continue;
      for (const textEdit of edits) texts.push(textEdit.newText);
    }
  }
  for (const change of edit.documentChanges ?? []) {
    if (change.textDocument?.uri !== uri) continue;
    for (const textEdit of change.edits) texts.push(textEdit.newText);
  }
  return texts;
}

test('native routing: two bundles complete different forms in either open order', async () => {
  const fixture = await makeTwoBundleFixture();
  let client;
  try {
    client = await spawnLspServer({
      serverPath: requireServerPath(),
      cwd: fixture.dir,
    });
    await client.initialize({ capabilities: {}, rootUri: fixture.rootUri });

    const alphaUri = fixture.uri('alpha/doc.sjon');
    const betaUri = fixture.uri('beta/doc.sjon');

    // Beta first: the first-opened document must not determine the schema
    // every later document sees.
    didOpen(client, betaUri, 1, '(');
    const beta = await client.request('textDocument/completion', {
      textDocument: { uri: betaUri },
      position: position(0, 1),
    });
    const betaLabels = completionLabels(beta);
    assert.ok(
      betaLabels.includes('beta-form'),
      `beta bundle should complete beta-form; got ${JSON.stringify(betaLabels)}`,
    );
    assert.equal(
      betaLabels.includes('alpha-form'),
      false,
      `beta completion leaked alpha-form: ${JSON.stringify(betaLabels)}`,
    );

    didOpen(client, alphaUri, 1, '(');
    const alpha = await client.request('textDocument/completion', {
      textDocument: { uri: alphaUri },
      position: position(0, 1),
    });
    const alphaLabels = completionLabels(alpha);
    assert.ok(
      alphaLabels.includes('alpha-form'),
      `alpha bundle should complete alpha-form; got ${JSON.stringify(alphaLabels)}`,
    );
    assert.equal(
      alphaLabels.includes('beta-form'),
      false,
      `alpha completion leaked beta-form: ${JSON.stringify(alphaLabels)}`,
    );
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('native routing: diagnostics hover and code action use the completion context', async () => {
  const fixture = await makeTwoBundleFixture();
  let client;
  try {
    client = await spawnLspServer({
      serverPath: requireServerPath(),
      cwd: fixture.dir,
    });
    await client.initialize({ capabilities: {}, rootUri: fixture.rootUri });

    const uri = fixture.uri('alpha/doc.sjon');
    didOpen(client, uri, 1, '(alpha-frm)\n');

    const report = await pull(client, uri);
    assert.equal(report.kind, 'full');
    const unknown = report.items.find((diagnostic) => diagnostic.code === 'unknown_form');
    assert.ok(
      unknown,
      `expected unknown_form from the alpha schema; got ${JSON.stringify(diagnosticCodes(report))}`,
    );

    const actions = await client.request('textDocument/codeAction', {
      textDocument: { uri },
      range: range(0, 0, 0, 11),
      context: { diagnostics: report.items },
    });
    const fix = actions.find((action) => actionEditTexts(action, uri).includes('alpha-form'));
    assert.ok(fix, `expected a quick fix to alpha-form; got ${JSON.stringify(actions)}`);
    assert.ok(
      (fix.diagnostics ?? []).some((diagnostic) => diagnostic.code === 'unknown_form'),
      'quick fix should carry the diagnostic it repairs',
    );

    // The same handler must answer hover for the corrected head and
    // validate the document against alpha, not core or beta.
    didChange(client, uri, 2, '(alpha-form :alpha-key "x")\n');
    const fixed = await pull(client, uri);
    assert.deepEqual(fixed.items, []);

    const hover = await client.request('textDocument/hover', {
      textDocument: { uri },
      position: position(0, 1),
    });
    assert.ok(hover, 'expected hover for the alpha-form head');
    assert.match(hover.contents.value, /alpha-form/);
    assert.match(hover.contents.value, /alpha/);
    assert.match(hover.contents.value, /alpha-key/);
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('native routing: negative completion does not leak another bundle', async () => {
  const fixture = await makeTwoBundleFixture();
  let client;
  try {
    client = await spawnLspServer({
      serverPath: requireServerPath(),
      cwd: fixture.dir,
    });
    await client.initialize({ capabilities: {}, rootUri: fixture.rootUri });

    const alphaUri = fixture.uri('alpha/doc.sjon');
    const betaUri = fixture.uri('beta/doc.sjon');
    didOpen(client, alphaUri, 1, '(');
    didOpen(client, betaUri, 1, '(');

    const alpha = completionLabels(
      await client.request('textDocument/completion', {
        textDocument: { uri: alphaUri },
        position: position(0, 1),
      }),
    );
    assert.ok(alpha.includes('alpha-form'), `expected alpha-form; got ${JSON.stringify(alpha)}`);
    assert.equal(alpha.includes('beta-form'), false);

    const beta = completionLabels(
      await client.request('textDocument/completion', {
        textDocument: { uri: betaUri },
        position: position(0, 1),
      }),
    );
    assert.ok(beta.includes('beta-form'), `expected beta-form; got ${JSON.stringify(beta)}`);
    assert.equal(beta.includes('alpha-form'), false);
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('native routing: definition reference and rename targets resolve source by target URI', async () => {
  const fixture = await makeTwoBundleFixture();
  let client;
  try {
    client = await spawnLspServer({
      serverPath: requireServerPath(),
      cwd: fixture.dir,
    });
    await client.initialize({ capabilities: {}, rootUri: fixture.rootUri });

    // Cross-ref scope is per-tree, so the definition and its use live in
    // one document. The returned location still names a target URI, and
    // every range is resolved against that target document's own bytes,
    // not the request document's.
    const docUri = fixture.uri('alpha/doc.sjon');
    didOpen(client, docUri, 1, '(phrase :name p0)\n(jump :target p0)\n');

    const definition = await client.request('textDocument/definition', {
      textDocument: { uri: docUri },
      position: position(1, 14),
    });
    assert.ok(definition, 'expected a definition for p0');
    assert.equal(definition.uri, docUri);
    assert.deepEqual(definition.range, range(0, 14, 0, 16));

    const references = await client.request('textDocument/references', {
      textDocument: { uri: docUri },
      position: position(1, 14),
      context: { includeDeclaration: true },
    });
    assert.ok(Array.isArray(references), 'expected reference locations');
    const ranges = references
      .filter((location) => location.uri === docUri)
      .map((location) => location.range);
    assert.ok(
      ranges.some((candidate) => candidate.start.line === 0 && candidate.start.character === 14),
      `missing definition site in ${JSON.stringify(ranges)}`,
    );
    assert.ok(
      ranges.some((candidate) => candidate.start.line === 1 && candidate.start.character === 14),
      `missing use site in ${JSON.stringify(ranges)}`,
    );

    const rename = await client.request('textDocument/rename', {
      textDocument: { uri: docUri },
      position: position(1, 14),
      newName: 'p1',
    });
    assert.ok(rename, 'expected a workspace edit');
    const changedUris = Object.keys(rename.changes ?? {});
    assert.ok(
      changedUris.includes(docUri),
      `rename missed the document: ${JSON.stringify(changedUris)}`,
    );
    const edits = rename.changes[docUri];
    assert.equal(edits.length, 2, `expected both sites renamed; got ${JSON.stringify(edits)}`);
    for (const edit of edits) {
      assert.equal(edit.newText, 'p1');
    }
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('native routing: unavailable suppresses completion hover actions tokens signatures references rename definition highlight and inlay hints', async () => {
  const fixture = await makeUnavailableFixture();
  let client;
  try {
    client = await spawnLspServer({
      serverPath: requireServerPath(),
      cwd: fixture.dir,
    });
    await client.initialize({ capabilities: {}, rootUri: fixture.rootUri });

    const uri = fixture.uri('broken/doc.sjon');
    didOpen(client, uri, 1, '(broken-form\n  (child :x 1))\n');

    const report = await pull(client, uri);
    assert.ok(
      report.items.some((diagnostic) => diagnostic.code === 'sjon-lsp/bundle-unavailable'),
      `expected the editor-local unavailable diagnostic; got ${JSON.stringify(diagnosticCodes(report))}`,
    );

    const completion = await client.request('textDocument/completion', {
      textDocument: { uri },
      position: position(0, 1),
    });
    assert.deepEqual(completionLabels(completion), []);

    const hover = await client.request('textDocument/hover', {
      textDocument: { uri },
      position: position(0, 1),
    });
    assert.equal(hover, null);

    const actions = await client.request('textDocument/codeAction', {
      textDocument: { uri },
      range: range(0, 0, 1, 14),
      context: { diagnostics: report.items },
    });
    assert.ok(
      actions === null || actions.length === 0,
      `unavailable code actions: ${JSON.stringify(actions)}`,
    );

    const tokens = await client.request('textDocument/semanticTokens/full', {
      textDocument: { uri },
    });
    assert.ok(
      tokens === null || tokens.data.length === 0,
      `unavailable tokens: ${JSON.stringify(tokens)}`,
    );

    const signature = await client.request('textDocument/signatureHelp', {
      textDocument: { uri },
      position: position(0, 1),
    });
    assert.equal(signature, null);

    const references = await client.request('textDocument/references', {
      textDocument: { uri },
      position: position(0, 1),
      context: { includeDeclaration: true },
    });
    assert.equal(references, null);

    const rename = await client.request('textDocument/rename', {
      textDocument: { uri },
      position: position(0, 1),
      newName: 'other',
    });
    assert.equal(rename, null);

    const definition = await client.request('textDocument/definition', {
      textDocument: { uri },
      position: position(0, 1),
    });
    assert.equal(definition, null);

    const highlight = await client.request('textDocument/documentHighlight', {
      textDocument: { uri },
      position: position(0, 1),
    });
    assert.equal(highlight, null);

    const hints = await client.request('textDocument/inlayHint', {
      textDocument: { uri },
      range: range(0, 0, 1, 14),
    });
    assert.ok(
      hints === null || hints.length === 0,
      `unavailable inlay hints: ${JSON.stringify(hints)}`,
    );
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('native routing: unavailable still supplies formatting folding symbols and selection ranges', async () => {
  const fixture = await makeUnavailableFixture();
  let client;
  try {
    client = await spawnLspServer({
      serverPath: requireServerPath(),
      cwd: fixture.dir,
    });
    await client.initialize({ capabilities: {}, rootUri: fixture.rootUri });

    const uri = fixture.uri('broken/doc.sjon');
    const text = '(broken-form   (child :x 1))\n';
    didOpen(client, uri, 1, text);

    const formatting = await client.request('textDocument/formatting', {
      textDocument: { uri },
      options: { tabSize: 2, insertSpaces: true },
    });
    assert.ok(Array.isArray(formatting), 'unavailable documents still format');

    const folding = await client.request('textDocument/foldingRange', {
      textDocument: { uri },
    });
    assert.ok(Array.isArray(folding), 'unavailable documents still fold');

    const symbols = await client.request('textDocument/documentSymbol', {
      textDocument: { uri },
    });
    assert.ok(
      Array.isArray(symbols) && symbols.length > 0,
      'unavailable documents still have symbols',
    );

    const selection = await client.request('textDocument/selectionRange', {
      textDocument: { uri },
      positions: [position(0, 1)],
    });
    assert.ok(
      Array.isArray(selection) && selection.length === 1,
      'unavailable documents still select',
    );
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('native routing: document result ID changes after association movement', async () => {
  const fixture = await makeTwoBundleFixture();
  let client;
  try {
    client = await spawnLspServer({
      serverPath: requireServerPath(),
      cwd: fixture.dir,
    });
    await client.initialize({ capabilities: {}, rootUri: fixture.rootUri });

    const uri = fixture.uri('alpha/doc.sjon');
    didOpen(client, uri, 1, '(alpha-form)\n');
    const baseline = await pull(client, uri);
    assert.equal(baseline.kind, 'full');
    assert.match(baseline.resultId, /^v2:/);

    // A document-local declaration moves the same buffer to a new
    // one-document schema context. Even at the same version, the identity
    // must move so a client cannot answer `unchanged`.
    didChange(
      client,
      uri,
      1,
      '(plugin :name inline :version "1.0.0" (form :name inline-form))\n(alpha-form)\n',
    );
    const declared = await pull(client, uri);
    assert.equal(declared.kind, 'full');
    assert.notEqual(declared.resultId, baseline.resultId);
    assert.match(declared.resultId, /^v2:/);
    assert.match(declared.resultId, /declaration:/);

    didChange(client, uri, 1, '(alpha-form)\n');
    const restored = await pull(client, uri);
    assert.equal(restored.kind, 'full');
    assert.notEqual(restored.resultId, declared.resultId);
    assert.equal(/declaration:/.test(restored.resultId), false);
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('native routing: initialization retains all workspace folders without dynamic-change support', async () => {
  const first = await makeRoot('sjon-lsp-folder-a-');
  const second = await makeRoot('sjon-lsp-folder-b-');
  let client;
  try {
    await mkdir(join(first.dir, 'docs'), { recursive: true });
    await mkdir(join(second.dir, 'docs'), { recursive: true });
    await first.write(
      'a.sjon',
      '(plugin :name alpha :version "1.0.0" (form :name a-form (key :name x :type string :optional true)))\n',
    );
    await first.write(
      'sjon-lsp.sjon',
      '(sjon-lsp :version 1 :bundles [(bundle :name alpha :files ["docs/**"] :manifests ["a.sjon"])])\n',
    );
    await second.write(
      'b.sjon',
      '(plugin :name beta :version "1.0.0" (form :name b-form (key :name y :type string :optional true)))\n',
    );
    await second.write(
      'sjon-lsp.sjon',
      '(sjon-lsp :version 1 :bundles [(bundle :name beta :files ["docs/**"] :manifests ["b.sjon"])])\n',
    );

    client = await spawnLspServer({
      serverPath: requireServerPath(),
      cwd: first.dir,
    });
    const initialized = await client.initialize({
      capabilities: {},
      workspaceFolders: [
        { uri: first.rootUri, name: 'first' },
        { uri: second.rootUri, name: 'second' },
      ],
    });
    assert.equal(initialized.capabilities.workspace?.workspaceFolders, undefined);

    const aUri = first.uri('docs/doc.sjon');
    const bUri = second.uri('docs/doc.sjon');
    didOpen(client, aUri, 1, '(');
    didOpen(client, bUri, 1, '(');

    const aLabels = completionLabels(
      await client.request('textDocument/completion', {
        textDocument: { uri: aUri },
        position: position(0, 1),
      }),
    );
    assert.ok(
      aLabels.includes('a-form'),
      `first folder should complete a-form; got ${JSON.stringify(aLabels)}`,
    );
    assert.equal(aLabels.includes('b-form'), false);

    const bLabels = completionLabels(
      await client.request('textDocument/completion', {
        textDocument: { uri: bUri },
        position: position(0, 1),
      }),
    );
    assert.ok(
      bLabels.includes('b-form'),
      `second folder should complete b-form; got ${JSON.stringify(bLabels)}`,
    );
    assert.equal(bLabels.includes('a-form'), false);
  } finally {
    if (client !== undefined) await client.close();
    await rm(first.dir, { recursive: true, force: true });
    await rm(second.dir, { recursive: true, force: true });
  }
});

test('native routing: workspace diagnostics merge bundles in stable URI order', async () => {
  const fixture = await makeTwoBundleFixture();
  let client;
  try {
    client = await spawnLspServer({
      serverPath: requireServerPath(),
      cwd: fixture.dir,
    });
    await client.initialize({
      capabilities: { textDocument: { diagnostic: {} } },
      rootUri: fixture.rootUri,
    });

    const alphaUri = fixture.uri('alpha/doc.sjon');
    const betaUri = fixture.uri('beta/doc.sjon');
    // Open the later-sorting document first: report order must not follow
    // context creation or scan order.
    didOpen(client, betaUri, 1, '(beta-form :beta-key "b")\n');
    didOpen(client, alphaUri, 1, '(alpha-form :alpha-key "a")\n');

    const report = await client.request('workspace/diagnostic', {
      previousResultIds: [],
    });
    const uris = report.items.map((item) => item.uri);
    const alphaIndex = uris.indexOf(alphaUri);
    const betaIndex = uris.indexOf(betaUri);
    assert.ok(alphaIndex >= 0, `missing alpha workspace report: ${JSON.stringify(uris)}`);
    assert.ok(betaIndex >= 0, `missing beta workspace report: ${JSON.stringify(uris)}`);
    assert.ok(alphaIndex < betaIndex, `workspace reports not URI-sorted: ${JSON.stringify(uris)}`);

    const alpha = report.items[alphaIndex];
    const beta = report.items[betaIndex];
    assert.equal(alpha.kind, 'full');
    assert.equal(beta.kind, 'full');
    assert.match(alpha.resultId, /^v2:/);
    assert.match(beta.resultId, /^v2:/);
    assert.match(alpha.resultId, /alpha/);
    assert.match(beta.resultId, /beta/);
    assert.notEqual(alpha.resultId, beta.resultId);
    assert.deepEqual(alpha.items, []);
    assert.deepEqual(beta.items, []);
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('native routing: same-name symbols in two bundles do not share references or rename', async () => {
  const fixture = await makeSharedSymbolFixture();
  let client;
  try {
    client = await spawnLspServer({
      serverPath: requireServerPath(),
      cwd: fixture.dir,
    });
    await client.initialize({ capabilities: {}, rootUri: fixture.rootUri });

    const alphaUri = fixture.uri('alpha/doc.sjon');
    const betaUri = fixture.uri('beta/doc.sjon');
    const source = '(phrase :name p0)\n';
    didOpen(client, betaUri, 1, source);
    didOpen(client, alphaUri, 1, source);

    const symbols = await client.request('workspace/symbol', { query: 'p0' });
    assert.equal(symbols.length, 2, `expected both p0 definitions; got ${JSON.stringify(symbols)}`);
    const symbolUris = symbols.map((symbol) => symbol.location.uri);
    assert.ok(symbolUris.includes(alphaUri), `missing alpha symbol: ${JSON.stringify(symbolUris)}`);
    assert.ok(symbolUris.includes(betaUri), `missing beta symbol: ${JSON.stringify(symbolUris)}`);

    const references = await client.request('textDocument/references', {
      textDocument: { uri: alphaUri },
      position: position(0, 14),
      context: { includeDeclaration: true },
    });
    assert.ok(Array.isArray(references), 'expected alpha references');
    assert.deepEqual(
      references.map((location) => location.uri),
      [alphaUri],
      'references from alpha leaked into beta',
    );

    const rename = await client.request('textDocument/rename', {
      textDocument: { uri: alphaUri },
      position: position(0, 14),
      newName: 'p1',
    });
    assert.ok(rename, 'expected an alpha rename edit');
    assert.deepEqual(Object.keys(rename.changes ?? {}), [alphaUri]);
    assert.equal(rename.changes[alphaUri].length, 1);
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('reload: didSave is advertised with includeText false and rereads disk', async () => {
  const fixture = await makeTwoBundleFixture();
  let client;
  try {
    client = await spawnLspServer({
      serverPath: requireServerPath(),
      cwd: fixture.dir,
    });
    const initialized = await client.initialize({
      capabilities: { textDocument: { publishDiagnostics: { versionSupport: true } } },
      rootUri: fixture.rootUri,
    });
    const sync = initialized.capabilities.textDocumentSync;
    assert.equal(sync.save?.includeText, false, `save options: ${JSON.stringify(sync.save)}`);

    const uri = fixture.uri('alpha/doc.sjon');
    didOpen(client, uri, 1, '(alpha-form :alpha-key "x")\n');
    const opened = await client.waitForNotification(
      PUSH_METHOD,
      (params) => params.uri === uri && params.version === 1,
    );
    assert.deepEqual(opened.diagnostics, []);

    await fixture.write(
      'alpha.sjon',
      `(plugin :name alpha :version "1.0.0"
  (form :name alpha-v2
    (key :name alpha-key :type string :optional false)))
`,
    );

    // The client's optional text is deliberately stale: saved disk bytes are
    // the authority, and includeText is false so the server must ignore it.
    didSave(
      client,
      fixture.uri('alpha.sjon'),
      '(plugin :name alpha :version "1.0.0" (form :name alpha-form :open true))\n',
    );

    const after = await client.waitForNotification(
      PUSH_METHOD,
      (params) =>
        params.uri === uri &&
        params.diagnostics.some((diagnostic) => diagnostic.code === 'unknown_form'),
    );
    assert.ok(
      after.diagnostics.some((diagnostic) => diagnostic.code === 'unknown_form'),
      `didSave must reread the saved manifest; got ${JSON.stringify(after.diagnostics.map((diagnostic) => diagnostic.code))}`,
    );
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('reload: open dirty source publishes live parse only and no misaligned saved spans', async () => {
  const fixture = await makeTwoBundleFixture();
  let client;
  try {
    // The saved manifest is malformed in a way that yields a manifest-load
    // diagnostic at a saved byte span. The dirty buffer is malformed in a
    // different place; mixing the two would publish a span that indexes the
    // wrong byte stream.
    await fixture.write('alpha.sjon', '(plugin :name alpha (form :name alpha-form :open true))\n');

    client = await spawnLspServer({
      serverPath: requireServerPath(),
      cwd: fixture.dir,
    });
    await client.initialize({
      capabilities: { textDocument: { publishDiagnostics: { versionSupport: true } } },
      rootUri: fixture.rootUri,
    });

    const docUri = fixture.uri('alpha/doc.sjon');
    didOpen(client, docUri, 1, '(alpha-form)\n');
    await client.waitForNotification(PUSH_METHOD, (params) => params.uri === docUri);

    const sourceUri = fixture.uri('alpha.sjon');
    const dirty = '(plugin :name alpha\n';
    didOpen(client, sourceUri, 1, dirty);
    const report = await client.waitForNotification(
      PUSH_METHOD,
      (params) => params.uri === sourceUri,
    );

    assert.ok(report.diagnostics.length > 0, 'dirty source must publish its live parse errors');
    assert.equal(
      report.diagnostics.some((diagnostic) => diagnostic.code === 'missing_required_key'),
      false,
      `dirty source leaked saved-byte diagnostics: ${JSON.stringify(report.diagnostics)}`,
    );
    for (const diagnostic of report.diagnostics) {
      assert.ok(
        diagnostic.range.end.character <= dirty.split('\n')[diagnostic.range.end.line].length,
        `diagnostic range does not index the live buffer: ${JSON.stringify(diagnostic.range)}`,
      );
    }
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('reload: recovery publishes clears for previous document and source reports', async () => {
  const fixture = await makeRoot('sjon-lsp-recovery-');
  let client;
  try {
    await mkdir(join(fixture.dir, 'docs'), { recursive: true });
    await fixture.write(
      'alpha.sjon',
      '(plugin :name alpha :version "1.0.0" (form :name alpha-form :open true))\n',
    );
    await fixture.write(
      'sjon-lsp.sjon',
      '(sjon-lsp :version 1 :bundles [(bundle :name alpha :files ["docs/**"] :manifests ["alpha.sjon"])])\n',
    );

    client = await spawnLspServer({
      serverPath: requireServerPath(),
      cwd: fixture.dir,
    });
    await client.initialize({
      capabilities: { textDocument: { publishDiagnostics: { versionSupport: true } } },
      rootUri: fixture.rootUri,
    });

    const docUri = fixture.uri('docs/doc.sjon');
    const sourceUri = fixture.uri('alpha.sjon');
    const configUri = fixture.uri('sjon-lsp.sjon');
    didOpen(client, docUri, 1, '(alpha-form)\n');
    const opened = await client.waitForNotification(
      PUSH_METHOD,
      (params) => params.uri === docUri && params.version === 1,
    );
    assert.deepEqual(opened.diagnostics, []);

    await rm(join(fixture.dir, 'alpha.sjon'));
    didChangeWatchedFiles(client, sourceUri, 3);

    const brokenDoc = await client.waitForNotification(
      PUSH_METHOD,
      (params) =>
        params.uri === docUri &&
        params.diagnostics.some((diagnostic) => diagnostic.code === 'sjon-lsp/bundle-unavailable'),
    );
    assert.ok(brokenDoc.diagnostics.length > 0);

    const brokenSource = await client.waitForNotification(
      PUSH_METHOD,
      (params) =>
        params.uri === configUri &&
        params.diagnostics.some((diagnostic) => diagnostic.code === 'sjon-lsp/bundle-source-read'),
    );
    assert.ok(
      brokenSource.diagnostics.some(
        (diagnostic) => diagnostic.code === 'sjon-lsp/bundle-source-read',
      ),
    );

    await fixture.write(
      'alpha.sjon',
      '(plugin :name alpha :version "1.0.0" (form :name alpha-form :open true))\n',
    );
    didChangeWatchedFiles(client, sourceUri, 2);

    const recoveredSource = await client.waitForNotification(
      PUSH_METHOD,
      (params) => params.uri === configUri && params.diagnostics.length === 0,
    );
    assert.deepEqual(recoveredSource.diagnostics, []);

    const recoveredDoc = await client.waitForNotification(
      PUSH_METHOD,
      (params) => params.uri === docUri && params.diagnostics.length === 0,
    );
    assert.deepEqual(recoveredDoc.diagnostics, []);
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('reload: watcher absence sends no registration', async () => {
  const fixture = await makeTwoBundleFixture();
  let client;
  try {
    client = await spawnLspServer({
      serverPath: requireServerPath(),
      cwd: fixture.dir,
    });
    await client.initialize({
      capabilities: { textDocument: { publishDiagnostics: {} } },
      rootUri: fixture.rootUri,
    });

    const uri = fixture.uri('alpha/doc.sjon');
    didOpen(client, uri, 1, '(alpha-form)\n');
    await client.waitForNotification(PUSH_METHOD, (params) => params.uri === uri);
    assert.deepEqual(
      serverRequests(client, REGISTER_METHOD),
      [],
      'a client without dynamicRegistration must not be asked to watch',
    );
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('reload: rejected watcher registration does not retry poll or crash', async () => {
  const fixture = await makeTwoBundleFixture();
  let client;
  try {
    client = await spawnLspServer({
      serverPath: requireServerPath(),
      cwd: fixture.dir,
      rejectServerRequests: [
        { method: REGISTER_METHOD, code: -32601, message: 'method not found' },
      ],
    });
    await client.initialize({
      capabilities: {
        textDocument: { publishDiagnostics: { versionSupport: true } },
        workspace: { didChangeWatchedFiles: { dynamicRegistration: true } },
      },
      rootUri: fixture.rootUri,
    });
    await client.waitForRequest(REGISTER_METHOD);

    const uri = fixture.uri('alpha/doc.sjon');
    didOpen(client, uri, 1, '(alpha-form)\n');
    await client.waitForNotification(
      PUSH_METHOD,
      (params) => params.uri === uri && params.version === 1,
    );

    await fixture.write(
      'alpha.sjon',
      '(plugin :name alpha :version "1.0.0" (form :name alpha-v2 :open true))\n',
    );
    didChangeWatchedFiles(client, fixture.uri('alpha.sjon'), 2);

    await client.waitForNotification(
      PUSH_METHOD,
      (params) =>
        params.uri === uri &&
        params.diagnostics.some((diagnostic) => diagnostic.code === 'unknown_form'),
    );

    assert.equal(
      serverRequests(client, REGISTER_METHOD).length,
      1,
      'rejection must not be retried',
    );
    assert.ok(
      client
        .transcript()
        .some(
          (record) =>
            record.direction === 'sent' &&
            record.kind === 'response' &&
            record.message.error?.code === -32601,
        ),
      'the harness must have delivered the registration rejection',
    );
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('native routing: non-file behavior remains in-memory', async () => {
  const fixture = await makeRoot('sjon-lsp-untitled-');
  let client;
  try {
    client = await spawnLspServer({
      serverPath: requireServerPath(),
      cwd: fixture.dir,
    });
    await client.initialize({ capabilities: {}, rootUri: fixture.rootUri });

    const uri = 'untitled:Untitled-1';
    didOpen(client, uri, 1, '(unknown-form)\n');

    const report = await pull(client, uri);
    assert.equal(report.kind, 'full');
    assert.ok(
      report.items.some((diagnostic) => diagnostic.code === 'unknown_form'),
      `non-file documents keep core validation; got ${JSON.stringify(diagnosticCodes(report))}`,
    );

    const completion = completionLabels(
      await client.request('textDocument/completion', {
        textDocument: { uri },
        position: position(0, 1),
      }),
    );
    assert.ok(completion.length > 0, 'non-file documents keep core completion');

    const formatting = await client.request('textDocument/formatting', {
      textDocument: { uri },
      options: { tabSize: 2, insertSpaces: true },
    });
    assert.ok(Array.isArray(formatting), 'non-file documents still format');
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('reload: workspace pull returns one current report per ingested declaration file', async () => {
  // A never-opened file whose declarations changed on disk. Each
  // `workspace/diagnostic` rescans disk, so the second and third pulls
  // observe the edited bytes: the report must be recomputed from them,
  // never duplicated with the stale declaration context's copy.
  const fixture = await makeRoot('sjon-lsp-ingest-decl-');
  let client;
  try {
    await fixture.write(
      'base.sjon',
      '(plugin :name base :version "1.0.0" (form :name base-form :open true))\n',
    );
    await fixture.write(
      'extra.sjon',
      '(plugin :name extra :version "1.0.0" (form :name extra-form :open true))\n',
    );
    await fixture.write(
      'sjon-lsp.sjon',
      '(sjon-lsp :version 1 :bundles [\n' +
        '  (bundle :name base :files ["**/*.sjon"] :manifests ["base.sjon"])\n' +
        '])\n',
    );
    const declared = '(use-plugin "extra" :path "extra.sjon")\n(base-form)\n';
    await fixture.write('doc.sjon', declared);

    client = await spawnLspServer({
      serverPath: requireServerPath(),
      cwd: fixture.dir,
    });
    await client.initialize({
      capabilities: { textDocument: { diagnostic: {} } },
      rootUri: fixture.rootUri,
    });

    const docUri = fixture.uri('doc.sjon');
    const workspaceItems = async () => {
      const report = await client.request('workspace/diagnostic', {
        previousResultIds: [],
      });
      return report.items.filter((item) => item.uri === docUri);
    };

    const first = await workspaceItems();
    assert.equal(first.length, 1, `expected one report for the ingested file; got ${first.length}`);
    assert.deepEqual(first[0].items, []);
    assert.match(first[0].resultId, /declaration/);

    // The declaration now names a manifest that does not exist: the one
    // report for this URI must carry that failure, not the previous
    // declaration's clean schema.
    await fixture.write('doc.sjon', '(use-plugin "missing" :path "missing.sjon")\n(base-form)\n');
    const second = await workspaceItems();
    assert.equal(
      second.length,
      1,
      `expected exactly one report after the declaration edit; got ${second.length}`,
    );
    assert.ok(
      second[0].items.some((diagnostic) => diagnostic.code === 'unresolved_plugin'),
      `expected unresolved_plugin from the recomputed declaration; got ${JSON.stringify(
        second[0].items.map((diagnostic) => diagnostic.code),
      )}`,
    );

    // The directive disappears: the file shares the baseline again and the
    // old declaration context must not survive as a duplicate report.
    await fixture.write('doc.sjon', '(base-form)\n');
    const third = await workspaceItems();
    assert.equal(
      third.length,
      1,
      `expected exactly one report after the declaration removal; got ${third.length}`,
    );
    assert.deepEqual(third[0].items, []);
    assert.doesNotMatch(third[0].resultId, /declaration/);
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

// The shipped example is documentation a reader copies. Pin it to the server
// behavior it claims: each folder resolves its own bundle, the bad documents
// raise exactly the advertised code, and completion does not leak the other
// folder's forms.
test('native routing: the shipped editor-bundles example keeps both schemas separate', async () => {
  const root = join(REPO_ROOT, 'examples', 'editor-bundles');
  let client;
  try {
    client = await spawnLspServer({
      serverPath: requireServerPath(),
      cwd: root,
    });
    await client.initialize({
      capabilities: { textDocument: { diagnostic: {} } },
      rootUri: pathToFileURL(root).href,
    });

    const expected = [
      ['gpu/texture.sjon', []],
      ['gpu/texture-typo.sjon', ['not_member']],
      ['geometry/shape.sjon', []],
      ['geometry/shape-typo.sjon', ['unit_not_allowed']],
    ];
    for (const [relative, codes] of expected) {
      const uri = pathToFileURL(join(root, relative)).href;
      didOpen(client, uri, 1, await readFile(join(root, relative), 'utf8'));
      const report = await pull(client, uri);
      assert.deepEqual(
        diagnosticCodes(report),
        codes,
        `${relative} diagnostics: ${JSON.stringify(report.items.map((d) => d.message))}`,
      );
    }

    // An unsaved buffer is discovered from its directory, so the probe proves
    // the schema is per-folder and not a merged list of every bundle.
    for (const folder of ['gpu', 'geometry']) {
      const uri = pathToFileURL(join(root, folder, 'probe.sjon')).href;
      didOpen(client, uri, 1, '(');
      const completion = await client.request('textDocument/completion', {
        textDocument: { uri },
        position: position(0, 1),
      });
      const labels = completionLabels(completion);
      assert.ok(
        labels.includes(folder === 'gpu' ? 'texture' : 'shape'),
        `${folder} should complete its own form; got ${JSON.stringify(labels.slice(0, 10))}`,
      );
      assert.equal(
        labels.includes(folder === 'gpu' ? 'shape' : 'texture'),
        false,
        `${folder} completion leaked the other bundle's form: ${JSON.stringify(labels.slice(0, 10))}`,
      );
    }
  } finally {
    if (client !== undefined) await client.close();
  }
});
