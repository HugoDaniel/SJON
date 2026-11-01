//! Native `sjon-lsp` JSON-RPC scenarios.
//!
//! These tests drive the installed executable exactly as an editor would:
//! Content-Length-framed JSON-RPC over stdio, real temporary documents.
//! They never import `Handler` or call it directly — the transport is the
//! subject.
//!
//! Run through `zig build lsp-native-test`, or directly:
//!
//!     SJON_LSP_SERVER=/absolute/path/to/zig-out/bin/sjon-lsp \
//!       node --test tools/lsp_native_tests.mjs

import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import test from 'node:test';

import { spawnLspServer } from './lsp_rpc_harness.mjs';

const DOCUMENT_LANGUAGE = 'sjon';
const PUSH_METHOD = 'textDocument/publishDiagnostics';
const REGISTER_METHOD = 'client/registerCapability';
const REFRESH_METHOD = 'workspace/diagnostic/refresh';

/// Blog manifest: a closed member set with one deprecated member, so a
/// push report can carry both optional fields the first capability test
/// filters (`tags: [2]` and `codeDescription`).
const BLOG_SCHEMA = `(plugin :name blog :version "1.0.0"
  (value-kind :name status
    :underlying symbol
    :members (member-set
      (member :name draft :label "Draft")
      (member :name archived :deprecated true)))
  (form :name post
    (key :name status :type status :optional false)))
`;

/// Audio manifest: the cross-ref fixture from `src/lsp/wasm.zig`'s
/// navigation tests, reused so `not_cross_ref` has a nearby definition
/// (`p0`) to attach as related information.
const AUDIO_SCHEMA = `(plugin :name audio :version "1.0.0"
  (value-kind :name phrase-name :underlying symbol :cross-ref (cross-ref :target phrase))
  (form :name phrase (key :name name :type symbol :optional false))
  (form :name jump (key :name target :type phrase-name :optional false)))
`;

/// Task manifest v1: one required key, `title`. A schema swap to v2
/// renames the requirement so an unchanged document's diagnostic message
/// must move with the new schema generation.
const TASK_SCHEMA_V1 = `(plugin :name task :version "1.0.0"
  (form :name task
    (key :name title :type string :optional false)))
`;

/// Task manifest v2: the same form with `name` required instead. A
/// document carrying only `:title` gains both `missing_required_key`
/// (for `:name`) and `unknown_key` (for `:title`).
const TASK_SCHEMA_V2 = `(plugin :name task :version "1.0.0"
  (form :name task
    (key :name name :type string :optional false)))
`;

/** Absolute server path, or an immediate actionable failure. Never PATH. */
function requireServerPath() {
  const serverPath = process.env.SJON_LSP_SERVER;
  if (serverPath === undefined || serverPath.length === 0) {
    throw new Error(
      'SJON_LSP_SERVER is not set. Run `zig build lsp` to install the binary, then re-run with SJON_LSP_SERVER set to the absolute path of zig-out/bin/sjon-lsp.',
    );
  }
  return serverPath;
}

async function makeFixture() {
  const dir = await mkdtemp(join(tmpdir(), 'sjon-lsp-native-'));
  return {
    dir,
    rootUri: pathToFileURL(dir).href,
    uri: (name) => pathToFileURL(join(dir, name)).href,
  };
}

/// Fixture with a real `sjon-project.sjon` and one plugin manifest, the
/// same discovery path an editor workspace takes. The schema is written
/// before the server spawns, so `initialize` loads it.
async function makeProjectFixture(schema) {
  const fixture = await makeFixture();
  await writeFile(join(fixture.dir, 'sjon-project.sjon'), '(project :plugins ["schema.sjon"])\n');
  await writeFile(join(fixture.dir, 'schema.sjon'), schema);
  return fixture;
}

/// Every push report the client received, oldest first.
function pushReports(client) {
  return pushReportsSince(client, 0);
}

/// Every push report received after `startIndex` in the transcript.
/// Tests that need "the reports this reload produced" capture
/// `client.transcript().length` immediately before sending the
/// notification, so an earlier report with the same URI and version
/// cannot be mistaken for a post-reload one.
function pushReportsSince(client, startIndex) {
  return client
    .transcript()
    .slice(startIndex)
    .filter(
      (record) =>
        record.direction === 'received' &&
        record.kind === 'notification' &&
        record.message.method === PUSH_METHOD,
    )
    .map((record) => record.message.params);
}

/// Every server-initiated request `method` the client received, oldest
/// first.
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

/// A pull response is the causal barrier for absence assertions: the
/// server reads stdin in order, so anything `initialized` or a preceding
/// notification produced was already written when this answer arrives.
async function pullBarrier(client, uri) {
  const report = await client.request('textDocument/diagnostic', {
    textDocument: { uri },
  });
  return report;
}

function didOpen(client, uri, version, text) {
  client.notify('textDocument/didOpen', {
    textDocument: { uri, languageId: DOCUMENT_LANGUAGE, version, text },
  });
}

function didChange(client, uri, version, contentChanges) {
  client.notify('textDocument/didChange', {
    textDocument: { uri, version },
    contentChanges,
  });
}

function didClose(client, uri) {
  client.notify('textDocument/didClose', { textDocument: { uri } });
}

function didChangeWatchedFiles(client, uri) {
  client.notify('workspace/didChangeWatchedFiles', {
    changes: [{ uri, type: 2 }],
  });
}

function range(startLine, startCharacter, endLine, endCharacter) {
  return {
    start: { line: startLine, character: startCharacter },
    end: { line: endLine, character: endCharacter },
  };
}

function diagnosticCodes(params) {
  return params.diagnostics.map((diagnostic) => diagnostic.code);
}

test('push client publishes open, incremental fix, schema error, and close', async () => {
  const fixture = await makeFixture();
  let client;
  try {
    client = await spawnLspServer({
      serverPath: requireServerPath(),
      cwd: fixture.dir,
    });
    await client.initialize({
      capabilities: {
        textDocument: { publishDiagnostics: { versionSupport: true } },
      },
      rootUri: fixture.rootUri,
    });

    const uri = fixture.uri('doc.sjon');

    // 1. Open with an unclosed delimiter: one full report, versioned.
    didOpen(client, uri, 1, '(+ 1 2');
    const opened = await client.waitForNotification(
      PUSH_METHOD,
      (params) => params.uri === uri && params.version === 1,
    );
    assert.equal(opened.uri, uri);
    assert.equal(opened.version, 1);
    const unclosed = opened.diagnostics.find((diagnostic) => diagnostic.code === 'unspecified');
    assert.ok(
      unclosed,
      `expected an unspecified parse diagnostic; got ${JSON.stringify(diagnosticCodes(opened))}`,
    );
    assert.equal(unclosed.severity, 1);
    assert.match(unclosed.message, /unclosed delimiter/);

    // 2. Incremental edit closes the delimiter: an empty report clears it.
    didChange(client, uri, 2, [{ range: range(0, 6, 0, 6), text: ')' }]);
    const fixed = await client.waitForNotification(
      PUSH_METHOD,
      (params) => params.uri === uri && params.version === 2,
    );
    assert.equal(fixed.version, 2);
    assert.deepEqual(fixed.diagnostics, []);

    // 3. A ranged replacement introduces a schema error at the current version.
    didChange(client, uri, 3, [{ range: range(0, 0, 0, 7), text: '(clmp 1 0 2)' }]);
    const invalid = await client.waitForNotification(
      PUSH_METHOD,
      (params) => params.uri === uri && params.version === 3,
    );
    assert.equal(invalid.version, 3);
    assert.equal(invalid.diagnostics.length, 1);
    const unknown = invalid.diagnostics[0];
    assert.equal(unknown.code, 'unknown_form');
    assert.match(unknown.message, /clmp/);
    assert.deepEqual(unknown.range, range(0, 1, 0, 5));

    // 4. Fixing the head clears the report at the new version.
    didChange(client, uri, 4, [{ range: range(0, 1, 0, 5), text: '+' }]);
    const repaired = await client.waitForNotification(
      PUSH_METHOD,
      (params) => params.uri === uri && params.version === 4,
    );
    assert.equal(repaired.version, 4);
    assert.deepEqual(repaired.diagnostics, []);

    // 5. Closing clears the last known report, carrying the captured version.
    didClose(client, uri);
    const cleared = await client.waitForNotification(
      PUSH_METHOD,
      (params) => params.uri === uri && params.version === 4,
    );
    assert.equal(cleared.version, 4);
    assert.deepEqual(cleared.diagnostics, []);
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('push diagnostics omit version without versionSupport', async () => {
  const fixture = await makeFixture();
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

    const uri = fixture.uri('doc.sjon');
    didOpen(client, uri, 1, '(clmp 1 0 2)');
    const report = await client.waitForNotification(PUSH_METHOD, (params) => params.uri === uri);

    assert.equal(Object.hasOwn(report, 'version'), false);
    assert.ok(report.diagnostics.length > 0);
    assert.ok(report.diagnostics.some((diagnostic) => diagnostic.code === 'unknown_form'));
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('pull-capable client does not receive unsolicited push', async () => {
  const fixture = await makeFixture();
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

    const uri = fixture.uri('doc.sjon');
    didOpen(client, uri, 1, '(clmp 1 0 2)');

    // A pull response is the causal barrier: the server handles stdin in
    // order, so any notification the open produced was already written.
    const report = await client.request('textDocument/diagnostic', {
      textDocument: { uri },
    });
    assert.equal(report.kind, 'full');
    assert.ok(report.items.length > 0);
    assert.ok(report.items.some((diagnostic) => diagnostic.code === 'unknown_form'));

    const publications = client
      .transcript()
      .filter(
        (record) =>
          record.direction === 'received' &&
          record.kind === 'notification' &&
          record.message.method === PUSH_METHOD,
      );
    assert.deepEqual(publications, []);
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('push diagnostics filter optional fields by publish capabilities', async () => {
  const fixture = await makeProjectFixture(BLOG_SCHEMA);
  const uri = fixture.uri('post.sjon');
  try {
    // Session 1: the client advertises the deprecated tag and code
    // descriptions, so both optional fields are carried.
    {
      const client = await spawnLspServer({
        serverPath: requireServerPath(),
        cwd: fixture.dir,
      });
      try {
        await client.initialize({
          capabilities: {
            textDocument: {
              publishDiagnostics: {
                versionSupport: true,
                tagSupport: { valueSet: [2] },
                codeDescriptionSupport: true,
              },
            },
          },
          rootUri: fixture.rootUri,
        });

        didOpen(client, uri, 1, '(post :status archived)');
        const report = await client.waitForNotification(
          PUSH_METHOD,
          (params) => params.uri === uri,
        );
        const deprecated = report.diagnostics.find(
          (diagnostic) => diagnostic.code === 'deprecated_member',
        );
        assert.ok(
          deprecated,
          `expected deprecated_member; got ${JSON.stringify(diagnosticCodes(report))}`,
        );
        assert.equal(deprecated.severity, 2);
        assert.match(deprecated.message, /archived/);
        assert.deepEqual(deprecated.tags, [2]);
        assert.ok(deprecated.codeDescription, 'expected codeDescription when supported');
        assert.match(deprecated.codeDescription.href, /deprecated_member/);
      } finally {
        await client.close();
      }
    }

    // Session 2: the same report, but neither optional field was
    // announced. False is the absence of support, not a denial of the
    // diagnostic itself.
    {
      const client = await spawnLspServer({
        serverPath: requireServerPath(),
        cwd: fixture.dir,
      });
      try {
        await client.initialize({
          capabilities: {
            textDocument: { publishDiagnostics: { versionSupport: true } },
          },
          rootUri: fixture.rootUri,
        });

        didOpen(client, uri, 1, '(post :status archived)');
        const report = await client.waitForNotification(
          PUSH_METHOD,
          (params) => params.uri === uri,
        );
        const deprecated = report.diagnostics.find(
          (diagnostic) => diagnostic.code === 'deprecated_member',
        );
        assert.ok(
          deprecated,
          `expected deprecated_member; got ${JSON.stringify(diagnosticCodes(report))}`,
        );
        assert.equal(deprecated.severity, 2);
        assert.match(deprecated.message, /archived/);
        assert.equal(Object.hasOwn(deprecated, 'tags'), false);
        assert.equal(Object.hasOwn(deprecated, 'codeDescription'), false);
      } finally {
        await client.close();
      }
    }
  } finally {
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('pull and push use mode-specific related-information capabilities', async () => {
  const fixture = await makeProjectFixture(AUDIO_SCHEMA);
  const uri = fixture.uri('audio.sjon');
  const text = '(phrase :name p0)\n(jump :target p1)';
  try {
    // Push reads `relatedInformation` from `publishDiagnostics`.
    {
      const client = await spawnLspServer({
        serverPath: requireServerPath(),
        cwd: fixture.dir,
      });
      try {
        await client.initialize({
          capabilities: {
            textDocument: { publishDiagnostics: { relatedInformation: true } },
          },
          rootUri: fixture.rootUri,
        });

        didOpen(client, uri, 1, text);
        const report = await client.waitForNotification(
          PUSH_METHOD,
          (params) => params.uri === uri,
        );
        const unresolved = report.diagnostics.find(
          (diagnostic) => diagnostic.code === 'not_cross_ref',
        );
        assert.ok(
          unresolved,
          `expected not_cross_ref; got ${JSON.stringify(diagnosticCodes(report))}`,
        );
        assert.ok(
          Array.isArray(unresolved.relatedInformation),
          'push report should carry relatedInformation',
        );
        assert.equal(unresolved.relatedInformation.length, 1);
        assert.equal(unresolved.relatedInformation[0].location.uri, uri);
        assert.deepEqual(unresolved.relatedInformation[0].location.range, range(0, 14, 0, 16));
      } finally {
        await client.close();
      }
    }

    // Pull reads the same optional field from `textDocument.diagnostic`.
    // A false flag there must strip it even though the client can pull.
    {
      const client = await spawnLspServer({
        serverPath: requireServerPath(),
        cwd: fixture.dir,
      });
      try {
        await client.initialize({
          capabilities: {
            textDocument: { diagnostic: { relatedInformation: false } },
          },
          rootUri: fixture.rootUri,
        });

        didOpen(client, uri, 1, text);
        const report = await pullBarrier(client, uri);
        assert.equal(report.kind, 'full');
        const unresolved = report.items.find((diagnostic) => diagnostic.code === 'not_cross_ref');
        assert.ok(
          unresolved,
          `expected not_cross_ref; got ${JSON.stringify(
            report.items.map((diagnostic) => diagnostic.code),
          )}`,
        );
        assert.equal(Object.hasOwn(unresolved, 'relatedInformation'), false);
        assert.deepEqual(pushReports(client), []);
      } finally {
        await client.close();
      }
    }
  } finally {
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('diagnostic ranges use UTF-8 byte offsets after non-ASCII text', async () => {
  const fixture = await makeFixture();
  let client;
  try {
    client = await spawnLspServer({
      serverPath: requireServerPath(),
      cwd: fixture.dir,
    });
    const result = await client.initialize({
      capabilities: { general: { positionEncodings: ['utf-8'] } },
      rootUri: fixture.rootUri,
    });
    assert.equal(result.capabilities.positionEncoding, 'utf-8');

    const uri = fixture.uri('doc.sjon');
    didOpen(client, uri, 1, '(+ "é" 1) (clmp 1 0 2)');
    const report = await client.waitForNotification(PUSH_METHOD, (params) => params.uri === uri);
    const unknown = report.diagnostics.find((diagnostic) => diagnostic.code === 'unknown_form');
    assert.ok(unknown, `expected unknown_form; got ${JSON.stringify(diagnosticCodes(report))}`);
    assert.deepEqual(unknown.range, range(0, 12, 0, 16));
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('diagnostic ranges use UTF-16 code units after non-ASCII text', async () => {
  const fixture = await makeFixture();
  let client;
  try {
    client = await spawnLspServer({
      serverPath: requireServerPath(),
      cwd: fixture.dir,
    });
    const result = await client.initialize({
      capabilities: { general: { positionEncodings: ['utf-16'] } },
      rootUri: fixture.rootUri,
    });
    assert.equal(result.capabilities.positionEncoding, 'utf-16');

    const uri = fixture.uri('doc.sjon');
    didOpen(client, uri, 1, '(+ "é" 1) (clmp 1 0 2)');
    const report = await client.waitForNotification(PUSH_METHOD, (params) => params.uri === uri);
    const unknown = report.diagnostics.find((diagnostic) => diagnostic.code === 'unknown_form');
    assert.ok(unknown, `expected unknown_form; got ${JSON.stringify(diagnosticCodes(report))}`);
    assert.deepEqual(unknown.range, range(0, 11, 0, 15));
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('diagnostic ranges default to UTF-16 and preserve CRLF lines', async () => {
  const fixture = await makeFixture();
  let client;
  try {
    client = await spawnLspServer({
      serverPath: requireServerPath(),
      cwd: fixture.dir,
    });
    const result = await client.initialize({
      capabilities: {},
      rootUri: fixture.rootUri,
    });
    assert.equal(result.capabilities.positionEncoding, 'utf-16');

    const uri = fixture.uri('doc.sjon');
    didOpen(client, uri, 1, '(+ "é" 1)\r\n(clmp 1 0 2)');
    const report = await client.waitForNotification(PUSH_METHOD, (params) => params.uri === uri);
    const unknown = report.diagnostics.find((diagnostic) => diagnostic.code === 'unknown_form');
    assert.ok(unknown, `expected unknown_form; got ${JSON.stringify(diagnosticCodes(report))}`);
    assert.deepEqual(unknown.range, range(1, 1, 1, 5));
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('empty pull capability selects pull even when dynamicRegistration is false', async () => {
  const fixture = await makeFixture();
  let client;
  try {
    client = await spawnLspServer({
      serverPath: requireServerPath(),
      cwd: fixture.dir,
    });
    await client.initialize({
      capabilities: {
        textDocument: { diagnostic: { dynamicRegistration: false } },
      },
      rootUri: fixture.rootUri,
    });

    const uri = fixture.uri('doc.sjon');
    didOpen(client, uri, 1, '(clmp 1 0 2)');
    const report = await pullBarrier(client, uri);
    assert.equal(report.kind, 'full');
    assert.ok(report.items.some((diagnostic) => diagnostic.code === 'unknown_form'));
    assert.deepEqual(pushReports(client), []);
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('watcher registration requires explicit dynamic-registration capability', async () => {
  const fixture = await makeFixture();
  try {
    // Capability object absent entirely.
    {
      const client = await spawnLspServer({
        serverPath: requireServerPath(),
        cwd: fixture.dir,
      });
      try {
        await client.initialize({ capabilities: {}, rootUri: fixture.rootUri });
        await pullBarrier(client, fixture.uri('barrier.sjon'));
        assert.deepEqual(serverRequests(client, REGISTER_METHOD), []);
      } finally {
        await client.close();
      }
    }

    // Capability object present but dynamic registration false.
    {
      const client = await spawnLspServer({
        serverPath: requireServerPath(),
        cwd: fixture.dir,
      });
      try {
        await client.initialize({
          capabilities: {
            workspace: { didChangeWatchedFiles: { dynamicRegistration: false } },
          },
          rootUri: fixture.rootUri,
        });
        await pullBarrier(client, fixture.uri('barrier.sjon'));
        assert.deepEqual(serverRequests(client, REGISTER_METHOD), []);
      } finally {
        await client.close();
      }
    }

    // True: exactly one registration, answered successfully.
    {
      const client = await spawnLspServer({
        serverPath: requireServerPath(),
        cwd: fixture.dir,
      });
      try {
        await client.initialize({
          capabilities: {
            workspace: { didChangeWatchedFiles: { dynamicRegistration: true } },
          },
          rootUri: fixture.rootUri,
        });
        const registration = await client.waitForRequest(REGISTER_METHOD);
        assert.equal(registration.registrations.length, 1);
        assert.equal(registration.registrations[0].method, 'workspace/didChangeWatchedFiles');
        await pullBarrier(client, fixture.uri('barrier.sjon'));
        assert.equal(serverRequests(client, REGISTER_METHOD).length, 1);
      } finally {
        await client.close();
      }
    }
  } finally {
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('rejected watcher registration does not break push delivery', async () => {
  const fixture = await makeFixture();
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
        workspace: { didChangeWatchedFiles: { dynamicRegistration: true } },
        textDocument: { publishDiagnostics: { versionSupport: true } },
      },
      rootUri: fixture.rootUri,
    });
    await client.waitForRequest(REGISTER_METHOD);

    const uri = fixture.uri('doc.sjon');
    didOpen(client, uri, 1, '(clmp 1 0 2)');
    const opened = await client.waitForNotification(
      PUSH_METHOD,
      (params) => params.uri === uri && params.version === 1,
    );
    assert.ok(opened.diagnostics.some((diagnostic) => diagnostic.code === 'unknown_form'));

    didChange(client, uri, 2, [{ text: '(+ 1 2)' }]);
    const fixed = await client.waitForNotification(
      PUSH_METHOD,
      (params) => params.uri === uri && params.version === 2,
    );
    assert.deepEqual(fixed.diagnostics, []);

    // Barrier: both pushes were written before this answer.
    await pullBarrier(client, fixture.uri('barrier.sjon'));
    assert.equal(serverRequests(client, REGISTER_METHOD).length, 1);
    const rejection = client
      .transcript()
      .find(
        (record) =>
          record.direction === 'sent' &&
          record.kind === 'response' &&
          record.message.error?.code === -32601,
      );
    assert.ok(rejection, 'expected the harness to answer -32601');
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('code actions carry the same capability-filtered current diagnostic as pull', async () => {
  const fixture = await makeFixture();
  let client;
  try {
    client = await spawnLspServer({
      serverPath: requireServerPath(),
      cwd: fixture.dir,
      timeoutMs: 5000,
    });
    await client.initialize({
      capabilities: {
        textDocument: { diagnostic: { codeDescriptionSupport: false } },
        workspace: { workspaceEdit: { documentChanges: true } },
      },
      rootUri: fixture.rootUri,
    });

    const uri = fixture.uri('doc.sjon');
    didOpen(client, uri, 3, '(clmp 1 0 2)');

    const report = await client.request('textDocument/diagnostic', {
      textDocument: { uri },
    });
    assert.equal(report.kind, 'full');
    assert.equal(report.items.length, 1);
    const pulled = report.items[0];
    assert.equal(pulled.code, 'unknown_form');
    assert.equal(Object.hasOwn(pulled, 'codeDescription'), false);

    const actions = await client.request('textDocument/codeAction', {
      textDocument: { uri },
      range: range(0, 0, 0, 12),
      context: { diagnostics: report.items },
    });
    const fix = actions.find((action) =>
      (action.diagnostics ?? []).some((diagnostic) => diagnostic.code === 'unknown_form'),
    );
    assert.ok(fix, 'expected a quick fix for unknown_form');
    assert.deepEqual(fix.diagnostics, report.items);
    assert.equal(Object.hasOwn(fix.diagnostics[0], 'codeDescription'), false);
    assert.equal(fix.edit.documentChanges.length, 1);
    assert.equal(fix.edit.documentChanges[0].textDocument.uri, uri);
    assert.equal(fix.edit.documentChanges[0].textDocument.version, 3);

    // Fix the head; the old quick fix must disappear from the current
    // document's actions, not linger against a stale diagnostic.
    didChange(client, uri, 4, [{ range: range(0, 1, 0, 5), text: '+' }]);
    const afterChange = await client.request('textDocument/diagnostic', {
      textDocument: { uri },
    });
    assert.deepEqual(afterChange.items, []);

    const actionsAfter = await client.request('textDocument/codeAction', {
      textDocument: { uri },
      range: range(0, 0, 0, 12),
      context: { diagnostics: [] },
    });
    assert.equal(
      actionsAfter.filter((action) =>
        (action.diagnostics ?? []).some((diagnostic) => diagnostic.code === 'unknown_form'),
      ).length,
      0,
    );
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('schema reload publishes every open document without cross-uri leakage', async () => {
  const fixture = await makeProjectFixture(TASK_SCHEMA_V1);
  let client;
  try {
    client = await spawnLspServer({
      serverPath: requireServerPath(),
      cwd: fixture.dir,
    });
    await client.initialize({
      capabilities: {
        textDocument: { publishDiagnostics: { versionSupport: true } },
        workspace: { diagnostics: { refreshSupport: true } },
      },
      rootUri: fixture.rootUri,
    });

    const aUri = fixture.uri('a.sjon');
    const bUri = fixture.uri('b.sjon');
    const cUri = fixture.uri('c.sjon');

    didOpen(client, aUri, 1, '(task)');
    const aBefore = await client.waitForNotification(PUSH_METHOD, (params) => params.uri === aUri);
    const missingTitle = aBefore.diagnostics.find(
      (diagnostic) => diagnostic.code === 'missing_required_key',
    );
    assert.ok(
      missingTitle,
      `expected missing_required_key for :title; got ${JSON.stringify(diagnosticCodes(aBefore))}`,
    );
    assert.match(missingTitle.message, /title/);

    didOpen(client, bUri, 1, '(task :title "ok")');
    const bBefore = await client.waitForNotification(PUSH_METHOD, (params) => params.uri === bUri);
    assert.deepEqual(bBefore.diagnostics, []);

    didOpen(client, cUri, 1, '(+ 1 2)');
    const cBefore = await client.waitForNotification(PUSH_METHOD, (params) => params.uri === cUri);
    assert.deepEqual(cBefore.diagnostics, []);

    // Reload against v2, then use a pull as the causal barrier: every
    // report the reload wrote is already in the transcript when this
    // answer arrives.
    const marker = client.transcript().length;
    await writeFile(join(fixture.dir, 'schema.sjon'), TASK_SCHEMA_V2);
    didChangeWatchedFiles(client, fixture.uri('schema.sjon'));
    await pullBarrier(client, cUri);

    const after = pushReportsSince(client, marker);
    const a = after.find((report) => report.uri === aUri);
    assert.ok(
      a,
      `expected a post-reload report for A; got ${JSON.stringify(after.map((report) => report.uri))}`,
    );
    assert.equal(a.version, 1);
    const missingName = a.diagnostics.find(
      (diagnostic) => diagnostic.code === 'missing_required_key',
    );
    assert.ok(
      missingName,
      `expected missing_required_key for :name; got ${JSON.stringify(diagnosticCodes(a))}`,
    );
    assert.match(missingName.message, /name/);
    assert.equal(
      a.diagnostics.some((diagnostic) => /title/.test(diagnostic.message ?? '')),
      false,
    );

    const b = after.find((report) => report.uri === bUri);
    assert.ok(b, 'expected a post-reload report for B');
    assert.equal(b.version, 1);
    const bCodes = diagnosticCodes(b);
    assert.ok(
      bCodes.includes('missing_required_key'),
      `expected missing_required_key; got ${JSON.stringify(bCodes)}`,
    );
    assert.ok(
      bCodes.includes('unknown_key'),
      `expected unknown_key; got ${JSON.stringify(bCodes)}`,
    );

    const cReports = after.filter((report) => report.uri === cUri);
    assert.equal(cReports.length, 1);
    assert.equal(cReports[0].version, 1);
    assert.deepEqual(cReports[0].diagnostics, []);

    // Push mode must never ask for a refresh, even though this client
    // announced workspace refresh support.
    assert.deepEqual(serverRequests(client, REFRESH_METHOD), []);
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('manifest reload failure publishes source and document errors then recovery clears both', async () => {
  const fixture = await makeProjectFixture(TASK_SCHEMA_V1);
  let client;
  try {
    client = await spawnLspServer({
      serverPath: requireServerPath(),
      cwd: fixture.dir,
    });
    await client.initialize({
      capabilities: {
        textDocument: { publishDiagnostics: { versionSupport: true } },
        workspace: { diagnostics: { refreshSupport: true } },
      },
      rootUri: fixture.rootUri,
    });

    const projectUri = fixture.uri('sjon-project.sjon');
    const docUri = fixture.uri('doc.sjon');
    didOpen(client, docUri, 1, '(task :title "ok")');
    const clean = await client.waitForNotification(PUSH_METHOD, (params) => params.uri === docUri);
    assert.deepEqual(clean.diagnostics, []);

    // Truncate the manifest so its root is no longer a `(plugin …)`
    // form: that shape gate is what emits `invalid_manifest`, rather
    // than an inner parse code.
    await writeFile(join(fixture.dir, 'schema.sjon'), '');
    didChangeWatchedFiles(client, fixture.uri('schema.sjon'));

    const brokenProject = await client.waitForNotification(
      PUSH_METHOD,
      (params) => params.uri === projectUri && diagnosticCodes(params).includes('invalid_manifest'),
    );
    assert.equal(Object.hasOwn(brokenProject, 'version'), false);

    const brokenDocument = await client.waitForNotification(
      PUSH_METHOD,
      (params) => params.uri === docUri && diagnosticCodes(params).includes('unspecified'),
    );
    const indicator = brokenDocument.diagnostics.find(
      (diagnostic) => diagnostic.code === 'unspecified',
    );
    assert.ok(indicator, 'expected the project-failure indicator');
    assert.equal(indicator.severity, 1);
    assert.deepEqual(indicator.range, range(0, 0, 0, 0));
    assert.equal(
      indicator.message,
      'workspace schema loading failed; see sjon-project.sjon diagnostics',
    );
    assert.ok(brokenDocument.diagnostics.length > 0);
    assert.deepEqual(serverRequests(client, REFRESH_METHOD), []);

    // Restore v1: both the project source report and the open document
    // must recover to empty full reports.
    const marker = client.transcript().length;
    await writeFile(join(fixture.dir, 'schema.sjon'), TASK_SCHEMA_V1);
    didChangeWatchedFiles(client, fixture.uri('schema.sjon'));
    await pullBarrier(client, docUri);
    const after = pushReportsSince(client, marker);

    const recoveredProject = after.find((report) => report.uri === projectUri);
    assert.ok(
      recoveredProject,
      `expected a project recovery report; got ${JSON.stringify(after.map((report) => report.uri))}`,
    );
    assert.deepEqual(recoveredProject.diagnostics, []);

    const recoveredDocument = after.find((report) => report.uri === docUri);
    assert.ok(recoveredDocument, 'expected a document recovery report');
    assert.deepEqual(recoveredDocument.diagnostics, []);
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('deleted manifest publishes invalid_manifest and restoration clears it', async () => {
  const fixture = await makeProjectFixture(TASK_SCHEMA_V1);
  let client;
  try {
    client = await spawnLspServer({
      serverPath: requireServerPath(),
      cwd: fixture.dir,
    });
    await client.initialize({
      capabilities: {
        textDocument: { publishDiagnostics: { versionSupport: true } },
        workspace: { diagnostics: { refreshSupport: true } },
      },
      rootUri: fixture.rootUri,
    });

    const projectUri = fixture.uri('sjon-project.sjon');
    const docUri = fixture.uri('doc.sjon');
    didOpen(client, docUri, 1, '(task :title "ok")');
    await client.waitForNotification(PUSH_METHOD, (params) => params.uri === docUri);

    await rm(join(fixture.dir, 'schema.sjon'));
    didChangeWatchedFiles(client, fixture.uri('schema.sjon'));

    const brokenProject = await client.waitForNotification(
      PUSH_METHOD,
      (params) => params.uri === projectUri && diagnosticCodes(params).includes('invalid_manifest'),
    );
    assert.equal(Object.hasOwn(brokenProject, 'version'), false);

    const brokenDocument = await client.waitForNotification(
      PUSH_METHOD,
      (params) => params.uri === docUri && diagnosticCodes(params).includes('unspecified'),
    );
    assert.ok(
      brokenDocument.diagnostics.some(
        (diagnostic) =>
          diagnostic.code === 'unspecified' &&
          diagnostic.message ===
            'workspace schema loading failed; see sjon-project.sjon diagnostics',
      ),
      'expected the project-failure indicator after manifest deletion',
    );
    assert.deepEqual(serverRequests(client, REFRESH_METHOD), []);

    const marker = client.transcript().length;
    await writeFile(join(fixture.dir, 'schema.sjon'), TASK_SCHEMA_V1);
    didChangeWatchedFiles(client, fixture.uri('schema.sjon'));
    await pullBarrier(client, docUri);
    const after = pushReportsSince(client, marker);

    const recoveredProject = after.find((report) => report.uri === projectUri);
    assert.ok(
      recoveredProject,
      `expected a project recovery report; got ${JSON.stringify(after.map((report) => report.uri))}`,
    );
    assert.deepEqual(recoveredProject.diagnostics, []);

    const recoveredDocument = after.find((report) => report.uri === docUri);
    assert.ok(recoveredDocument, 'expected a document recovery report');
    assert.deepEqual(recoveredDocument.diagnostics, []);
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('diagnostic refresh is requested only for pull clients with refresh support', async () => {
  // Pull half: exactly one refresh, no unsolicited push.
  {
    const fixture = await makeProjectFixture(TASK_SCHEMA_V1);
    let client;
    try {
      client = await spawnLspServer({
        serverPath: requireServerPath(),
        cwd: fixture.dir,
      });
      await client.initialize({
        capabilities: {
          textDocument: { diagnostic: {} },
          workspace: { diagnostics: { refreshSupport: true } },
        },
        rootUri: fixture.rootUri,
      });

      const uri = fixture.uri('doc.sjon');
      didOpen(client, uri, 1, '(task)');
      await writeFile(join(fixture.dir, 'schema.sjon'), TASK_SCHEMA_V2);
      didChangeWatchedFiles(client, fixture.uri('schema.sjon'));

      // The refresh request carries no params; awaiting it is the
      // assertion that the reload asked for one.
      await client.waitForRequest(REFRESH_METHOD);
      await pullBarrier(client, uri);
      assert.equal(serverRequests(client, REFRESH_METHOD).length, 1);
      assert.deepEqual(pushReports(client), []);
    } finally {
      if (client !== undefined) await client.close();
      await rm(fixture.dir, { recursive: true, force: true });
    }
  }

  // Push half: the same workspace capability must not turn a reload into
  // a refresh request; the reports themselves carry the new state.
  {
    const fixture = await makeProjectFixture(TASK_SCHEMA_V1);
    let client;
    try {
      client = await spawnLspServer({
        serverPath: requireServerPath(),
        cwd: fixture.dir,
      });
      await client.initialize({
        capabilities: {
          textDocument: { publishDiagnostics: { versionSupport: true } },
          workspace: { diagnostics: { refreshSupport: true } },
        },
        rootUri: fixture.rootUri,
      });

      const uri = fixture.uri('doc.sjon');
      didOpen(client, uri, 1, '(task)');
      await client.waitForNotification(PUSH_METHOD, (params) => params.uri === uri);

      const marker = client.transcript().length;
      await writeFile(join(fixture.dir, 'schema.sjon'), TASK_SCHEMA_V2);
      didChangeWatchedFiles(client, fixture.uri('schema.sjon'));
      await pullBarrier(client, uri);

      assert.deepEqual(serverRequests(client, REFRESH_METHOD), []);
      const after = pushReportsSince(client, marker);
      const report = after.find((candidate) => candidate.uri === uri);
      assert.ok(
        report,
        `expected a post-reload push report; got ${JSON.stringify(after.map((entry) => entry.uri))}`,
      );
      const missingName = report.diagnostics.find(
        (diagnostic) => diagnostic.code === 'missing_required_key',
      );
      assert.ok(
        missingName,
        `expected missing_required_key for :name; got ${JSON.stringify(diagnosticCodes(report))}`,
      );
      assert.match(missingName.message, /name/);
    } finally {
      if (client !== undefined) await client.close();
      await rm(fixture.dir, { recursive: true, force: true });
    }
  }
});

test('pull without refresh support invalidates result ids on edits and schema swaps', async () => {
  const fixture = await makeProjectFixture(TASK_SCHEMA_V1);
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

    const uri = fixture.uri('doc.sjon');
    didOpen(client, uri, 1, '(task)');

    const first = await client.request('textDocument/diagnostic', {
      textDocument: { uri },
    });
    assert.equal(first.kind, 'full');
    assert.ok(first.resultId);
    assert.ok(first.items.some((diagnostic) => diagnostic.code === 'missing_required_key'));

    const unchanged = await client.request('textDocument/diagnostic', {
      textDocument: { uri },
      previousResultId: first.resultId,
    });
    assert.equal(unchanged.kind, 'unchanged');
    assert.equal(unchanged.resultId, first.resultId);

    didChange(client, uri, 2, [{ text: '(task :title "ok")' }]);
    const edited = await client.request('textDocument/diagnostic', {
      textDocument: { uri },
      previousResultId: first.resultId,
    });
    assert.equal(edited.kind, 'full');
    assert.notEqual(edited.resultId, first.resultId);
    assert.match(edited.resultId, /^2:/);
    assert.deepEqual(edited.items, []);

    await writeFile(join(fixture.dir, 'schema.sjon'), TASK_SCHEMA_V2);
    didChangeWatchedFiles(client, fixture.uri('schema.sjon'));
    const swapped = await client.request('textDocument/diagnostic', {
      textDocument: { uri },
      previousResultId: edited.resultId,
    });
    assert.equal(swapped.kind, 'full');
    assert.notEqual(swapped.resultId, edited.resultId);
    const swappedCodes = swapped.items.map((diagnostic) => diagnostic.code);
    assert.ok(
      swappedCodes.includes('missing_required_key'),
      `expected missing_required_key; got ${JSON.stringify(swappedCodes)}`,
    );
    assert.ok(
      swappedCodes.includes('unknown_key'),
      `expected unknown_key; got ${JSON.stringify(swappedCodes)}`,
    );

    const repeated = await client.request('textDocument/diagnostic', {
      textDocument: { uri },
      previousResultId: swapped.resultId,
    });
    assert.equal(repeated.kind, 'unchanged');
    assert.equal(repeated.resultId, swapped.resultId);

    assert.deepEqual(serverRequests(client, REFRESH_METHOD), []);
    assert.deepEqual(pushReports(client), []);
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('project pull and workspace pull share the filtered source report', async () => {
  const fixture = await makeProjectFixture(TASK_SCHEMA_V1);
  let client;
  try {
    // Break the manifest before the server starts, so the initial
    // project load carries the failure the pull paths must report.
    await writeFile(join(fixture.dir, 'schema.sjon'), '');
    client = await spawnLspServer({
      serverPath: requireServerPath(),
      cwd: fixture.dir,
    });
    await client.initialize({
      capabilities: {
        textDocument: { diagnostic: { codeDescriptionSupport: false } },
      },
      rootUri: fixture.rootUri,
    });

    const projectUri = fixture.uri('sjon-project.sjon');
    const docUri = fixture.uri('doc.sjon');

    const projectPull = await client.request('textDocument/diagnostic', {
      textDocument: { uri: projectUri },
    });
    assert.equal(projectPull.kind, 'full');
    const invalid = projectPull.items.find((diagnostic) => diagnostic.code === 'invalid_manifest');
    assert.ok(
      invalid,
      `expected invalid_manifest; got ${JSON.stringify(projectPull.items.map((diagnostic) => diagnostic.code))}`,
    );
    assert.equal(Object.hasOwn(invalid, 'codeDescription'), false);

    const workspace = await client.request('workspace/diagnostic', {
      previousResultIds: [],
    });
    const projectReports = workspace.items.filter((item) => item.uri === projectUri);
    assert.equal(
      projectReports.length,
      1,
      `expected exactly one project report; got ${JSON.stringify(workspace.items.map((item) => item.uri))}`,
    );
    const projectReport = projectReports[0];
    assert.equal(projectReport.kind, 'full');
    assert.equal(projectReport.version ?? null, null);
    assert.equal(projectReport.resultId ?? null, null);
    assert.deepEqual(projectReport.items, projectPull.items);
    assert.equal(Object.hasOwn(projectReport, 'relatedDocuments'), false);

    // The same broken project must surface the actionable indicator on
    // an open document's pull, not only on the project file's report.
    didOpen(client, docUri, 1, '(task :title "ok")');
    const documentPull = await client.request('textDocument/diagnostic', {
      textDocument: { uri: docUri },
    });
    assert.equal(documentPull.kind, 'full');
    const indicator = documentPull.items.find((diagnostic) => diagnostic.code === 'unspecified');
    assert.ok(
      indicator,
      `expected the project-failure indicator; got ${JSON.stringify(documentPull.items.map((diagnostic) => diagnostic.code))}`,
    );
    assert.equal(indicator.severity, 1);
    assert.deepEqual(indicator.range, range(0, 0, 0, 0));
    assert.equal(
      indicator.message,
      'workspace schema loading failed; see sjon-project.sjon diagnostics',
    );
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('empty change republishes current diagnostics and failed change never clears them', async () => {
  const fixture = await makeFixture();
  let client;
  try {
    client = await spawnLspServer({
      serverPath: requireServerPath(),
      cwd: fixture.dir,
    });
    await client.initialize({
      capabilities: {
        textDocument: { publishDiagnostics: { versionSupport: true } },
      },
      rootUri: fixture.rootUri,
    });

    const docUri = fixture.uri('doc.sjon');
    didOpen(client, docUri, 1, '(+ 1 2');
    const opened = await client.waitForNotification(
      PUSH_METHOD,
      (params) => params.uri === docUri && params.version === 1,
    );
    const unclosed = opened.diagnostics.find((diagnostic) => diagnostic.code === 'unspecified');
    assert.ok(
      unclosed,
      `expected an unspecified parse diagnostic; got ${JSON.stringify(diagnosticCodes(opened))}`,
    );
    assert.match(unclosed.message, /unclosed delimiter/);

    // An empty batch is still a successfully applied change: it must move
    // the document to the supplied version and republish the current set,
    // not be dropped as a no-op.
    didChange(client, docUri, 2, []);
    const republished = await client.waitForNotification(
      PUSH_METHOD,
      (params) => params.uri === docUri && params.version === 2,
    );
    assert.equal(republished.version, 2);
    assert.deepEqual(republished.diagnostics, opened.diagnostics);

    // A change for a URI that was never opened is a client protocol
    // violation. The server must stay up and must not answer it with an
    // invented empty report for the unknown URI or for the open one.
    const marker = client.transcript().length;
    didChange(client, fixture.uri('ghost.sjon'), 1, [{ text: '(+ 1 2' }]);
    // Hover on the original document is the causal barrier: the server
    // reads stdin in order, so when this response arrives the failed
    // change has already been handled.
    await client.request('textDocument/hover', {
      textDocument: { uri: docUri },
      position: { line: 0, character: 1 },
    });
    assert.deepEqual(pushReportsSince(client, marker), []);
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});

test('shutdown suppresses further push notifications', async () => {
  const fixture = await makeFixture();
  let client;
  try {
    client = await spawnLspServer({
      serverPath: requireServerPath(),
      cwd: fixture.dir,
    });
    await client.initialize({
      capabilities: {
        textDocument: { publishDiagnostics: { versionSupport: true } },
      },
      rootUri: fixture.rootUri,
    });

    const docUri = fixture.uri('doc.sjon');
    didOpen(client, docUri, 1, '(+ 1 2');
    const opened = await client.waitForNotification(
      PUSH_METHOD,
      (params) => params.uri === docUri && params.version === 1,
    );
    assert.ok(
      opened.diagnostics.length > 0,
      `expected a nonempty initial report; got ${JSON.stringify(opened.diagnostics)}`,
    );

    const shutdownResponse = await client.request('shutdown');
    assert.equal(shutdownResponse, null);
    const afterShutdown = client.transcript().length;

    // A pending waiter is rejected by the harness when the child exits,
    // and the rejection names the exit status. That is the only exit
    // observation it exposes, and it is enough to pin "cleanly": a
    // server that hangs or has to be signalled times out or names the
    // signal instead of exit code 0.
    const exitObservation = client
      .waitForNotification('test/never', () => false)
      .then(
        () => new Error('expected the server to exit after the exit notification'),
        (error) => error,
      );

    // Both messages are queued after the shutdown response: the change
    // must update local state without publishing, and exit must end the
    // process cleanly.
    didChange(client, docUri, 2, [{ text: '(+ 1 2)' }]);
    client.notify('exit');

    const exitError = await exitObservation;
    assert.match(exitError.message, /server exited \(exit code 0\)/);

    // Give the child's stdout one bounded turn to drain after exit
    // before `close` detaches its listeners. A report written between
    // the shutdown response and exit is already on the pipe.
    await new Promise((resolve) => setTimeout(resolve, 100));

    assert.deepEqual(pushReportsSince(client, afterShutdown), []);
  } finally {
    if (client !== undefined) await client.close();
    await rm(fixture.dir, { recursive: true, force: true });
  }
});
