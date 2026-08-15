// Tests for FilesystemResolver — mirror the in-source tests in
// `src/FilesystemResolver.zig`. Uses `node:fs.mkdtempSync` to scaffold
// per-test directories under the OS temp root.

import { test } from 'node:test';
import * as assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { FilesystemResolver } from '../src/FilesystemResolver.ts';

interface Tmp {
  readonly root: string;
  cleanup(): void;
  write(relPath: string, body: string): string;
}

function makeTmp(): Tmp {
  const root = mkdtempSync(join(tmpdir(), 'sjon-fsres-'));
  return {
    root,
    cleanup() {
      rmSync(root, { recursive: true, force: true });
    },
    write(relPath: string, body: string) {
      const abs = join(root, relPath);
      const dir = abs.slice(0, abs.lastIndexOf('/'));
      mkdirSync(dir, { recursive: true });
      writeFileSync(abs, body);
      return abs;
    },
  };
}

test('FilesystemResolver: no project file → empty index, resolves nothing by name', () => {
  const built = FilesystemResolver.load('/tmp', null);
  assert.equal(built.projectDiagnostics.length, 0);
  const res = built.resolver.resolve({
    name: 'shapes',
    explicitPath: null,
    version: null,
    hash: null,
    span: { start: 0, end: 0 },
  });
  assert.equal(res.kind, 'failure');
  if (res.kind === 'failure') assert.equal(res.code, 'unresolved_plugin');
});

test('FilesystemResolver: project file with one valid plugin indexes by :name', () => {
  const tmp = makeTmp();
  try {
    tmp.write('shapes.sjon', '(plugin :name shapes :version "1.0.0")');
    const projectFile = tmp.write('sjon-project.sjon', '(project :plugins ["shapes.sjon"])');

    const built = FilesystemResolver.load(tmp.root, projectFile);
    assert.equal(built.projectDiagnostics.length, 0);

    const res = built.resolver.resolve({
      name: 'shapes',
      explicitPath: null,
      version: null,
      hash: null,
      span: { start: 0, end: 0 },
    });
    assert.equal(res.kind, 'manifest');
    if (res.kind === 'manifest') {
      assert.match(res.source, /:name shapes/);
      assert.equal(res.wasm, null, 'this host pairs no sidecar');
    }
  } finally {
    tmp.cleanup();
  }
});

test('FilesystemResolver: duplicate :name across :plugins entries emits duplicate_plugin_name', () => {
  const tmp = makeTmp();
  try {
    tmp.write('a.sjon', '(plugin :name shapes :version "1.0.0")');
    tmp.write('b.sjon', '(plugin :name shapes :version "1.0.0")');
    const projectFile = tmp.write('sjon-project.sjon', '(project :plugins ["a.sjon" "b.sjon"])');

    const built = FilesystemResolver.load(tmp.root, projectFile);
    assert.equal(built.projectDiagnostics.length, 1);
    assert.equal(built.projectDiagnostics[0]!.code, 'duplicate_plugin_name');
  } finally {
    tmp.cleanup();
  }
});

test('FilesystemResolver: missing manifest path emits invalid_manifest at path span', () => {
  const tmp = makeTmp();
  try {
    const projectFile = tmp.write('sjon-project.sjon', '(project :plugins ["missing.sjon"])');

    const built = FilesystemResolver.load(tmp.root, projectFile);
    assert.equal(built.projectDiagnostics.length, 1);
    assert.equal(built.projectDiagnostics[0]!.code, 'invalid_manifest');
    assert.match(built.projectDiagnostics[0]!.message, /missing\.sjon/);
  } finally {
    tmp.cleanup();
  }
});

test('FilesystemResolver: explicit :path bypasses index', () => {
  const tmp = makeTmp();
  try {
    tmp.write('vendored.sjon', '(plugin :name vended :version "1.0.0")');

    const built = FilesystemResolver.load(tmp.root, null);
    const res = built.resolver.resolve({
      name: 'vended',
      explicitPath: 'vendored.sjon',
      version: null,
      hash: null,
      span: { start: 0, end: 0 },
    });
    assert.equal(res.kind, 'manifest');
    if (res.kind === 'manifest') {
      assert.match(res.source, /:name vended/);
      assert.equal(res.wasm, null, 'this host pairs no sidecar');
    }
  } finally {
    tmp.cleanup();
  }
});

test('FilesystemResolver: explicit :path that does not exist becomes unresolved_plugin', () => {
  const built = FilesystemResolver.load('/tmp', null);
  const res = built.resolver.resolve({
    name: 'x',
    explicitPath: '/definitely/does/not/exist.sjon',
    version: null,
    hash: null,
    span: { start: 0, end: 0 },
  });
  assert.equal(res.kind, 'failure');
  if (res.kind === 'failure') assert.equal(res.code, 'unresolved_plugin');
});

test('FilesystemResolver: project file with non-(project …) root reports invalid_manifest', () => {
  const tmp = makeTmp();
  try {
    const projectFile = tmp.write('sjon-project.sjon', '(not-project :plugins [])');
    const built = FilesystemResolver.load(tmp.root, projectFile);
    assert.equal(built.projectDiagnostics.length, 1);
    assert.equal(built.projectDiagnostics[0]!.code, 'invalid_manifest');
  } finally {
    tmp.cleanup();
  }
});

test('FilesystemResolver: project file with a bare value (no form root) is invalid_manifest', () => {
  const tmp = makeTmp();
  try {
    const projectFile = tmp.write('sjon-project.sjon', '42');
    const built = FilesystemResolver.load(tmp.root, projectFile);
    assert.equal(built.projectDiagnostics.length, 1);
    assert.equal(built.projectDiagnostics[0]!.code, 'invalid_manifest');
    assert.match(built.projectDiagnostics[0]!.message, /\(project …\)/);
  } finally {
    tmp.cleanup();
  }
});

test('FilesystemResolver: project file does not exist → invalid_manifest', () => {
  const built = FilesystemResolver.load('/tmp', '/tmp/definitely-not-a-project-file.sjon');
  assert.equal(built.projectDiagnostics.length, 1);
  assert.equal(built.projectDiagnostics[0]!.code, 'invalid_manifest');
});

test('FilesystemResolver: non-string, non-form :plugins entry emits invalid_manifest', () => {
  const tmp = makeTmp();
  try {
    const projectFile = tmp.write('sjon-project.sjon', '(project :plugins [42])');
    const built = FilesystemResolver.load(tmp.root, projectFile);
    assert.equal(built.projectDiagnostics.length, 1);
    assert.equal(built.projectDiagnostics[0]!.code, 'invalid_manifest');
    assert.match(built.projectDiagnostics[0]!.message, /path string or `\(plugin-entry …\)`/);
  } finally {
    tmp.cleanup();
  }
});

// `(plugin-entry …)` — the reference accepts it (`indexOneManifest` in
// `src/FilesystemResolver.zig`); this host rejected it outright until
// 2026-08-12, so a valid project file failed on three of the four hosts.

test('FilesystemResolver: (plugin-entry :path …) indexes exactly like a bare path string', () => {
  const tmp = makeTmp();
  try {
    tmp.write('shapes.sjon', '(plugin :name shapes :version "1.0.0")');
    const projectFile = tmp.write(
      'sjon-project.sjon',
      '(project :plugins [(plugin-entry :path "shapes.sjon")])',
    );

    const built = FilesystemResolver.load(tmp.root, projectFile);
    assert.deepEqual(built.projectDiagnostics, []);

    const res = built.resolver.resolve({
      name: 'shapes',
      explicitPath: null,
      version: null,
      hash: null,
      span: { start: 0, end: 0 },
    });
    assert.equal(res.kind, 'manifest');
    if (res.kind === 'manifest') assert.match(res.source, /:name shapes/);
  } finally {
    tmp.cleanup();
  }
});

test('FilesystemResolver: (plugin-entry …) pins and reserved keys are accepted and inert', () => {
  const tmp = makeTmp();
  try {
    tmp.write('shapes.sjon', '(plugin :name shapes :version "1.0.0")');
    // `:version` / `:hash` are project-level pins the reference keeps for
    // its `pin_disagreement` cross-check — a FilesystemResolver-local
    // check (a deliberate parity boundary). Here they must
    // parse without complaint and change nothing.
    const projectFile = tmp.write(
      'sjon-project.sjon',
      '(project :plugins [(plugin-entry :path "shapes.sjon" :version "9.9.9" ' +
        `:hash "sha256-${'0'.repeat(64)}" :optional true :as other)])`,
    );

    const built = FilesystemResolver.load(tmp.root, projectFile);
    assert.deepEqual(built.projectDiagnostics, []);

    const res = built.resolver.resolve({
      name: 'shapes',
      explicitPath: null,
      version: null,
      hash: null,
      span: { start: 0, end: 0 },
    });
    assert.equal(res.kind, 'manifest', 'a disagreeing project pin is not this host’s check');
  } finally {
    tmp.cleanup();
  }
});

test('FilesystemResolver: (plugin-entry …) without :path emits invalid_manifest', () => {
  const tmp = makeTmp();
  try {
    const projectFile = tmp.write(
      'sjon-project.sjon',
      '(project :plugins [(plugin-entry :version "1.0.0")])',
    );
    const built = FilesystemResolver.load(tmp.root, projectFile);
    assert.equal(built.projectDiagnostics.length, 1);
    assert.equal(built.projectDiagnostics[0]!.code, 'invalid_manifest');
    assert.match(built.projectDiagnostics[0]!.message, /requires a `:path` string/);
  } finally {
    tmp.cleanup();
  }
});

test('FilesystemResolver: a form entry that is not (plugin-entry …) names the head it saw', () => {
  const tmp = makeTmp();
  try {
    const projectFile = tmp.write(
      'sjon-project.sjon',
      '(project :plugins [(plugin-entrie :path "shapes.sjon")])',
    );
    const built = FilesystemResolver.load(tmp.root, projectFile);
    assert.equal(built.projectDiagnostics.length, 1);
    assert.equal(built.projectDiagnostics[0]!.code, 'invalid_manifest');
    assert.match(built.projectDiagnostics[0]!.message, /got `\(plugin-entrie …\)`/);
  } finally {
    tmp.cleanup();
  }
});
