// Unit tests for `createNodeFsResolver`. Mirrors
// `hosts/typescript-parity/test/filesystem-resolver.test.ts`. Each
// test sets up a temp directory with a `sjon-project.sjon` + manifest
// files, builds the resolver, and asserts on `projectDiagnostics`
// and per-reference resolutions.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { createNodeFsResolver } from '../createNodeFsResolver.ts';
import type { Reference } from '../sjon-reader.ts';

function tmpProject(): { root: string; cleanup: () => void } {
  const root = mkdtempSync(path.join(tmpdir(), 'sjon-d5-'));
  return { root, cleanup: () => rmSync(root, { recursive: true, force: true }) };
}

const REF_NO_PATH = (name: string): Reference => ({
  name,
  explicitPath: null,
  version: null,
  hash: null,
  span: { start: 0, end: 0 },
});

test('no project file → empty index, resolves nothing by name', () => {
  const { root, cleanup } = tmpProject();
  try {
    const { resolver, projectDiagnostics } = createNodeFsResolver({
      projectRoot: root,
      projectFile: null,
    });
    assert.equal(projectDiagnostics.length, 0);
    const res = resolver(REF_NO_PATH('shapes'));
    assert.equal(res.kind, 'failure');
    assert.equal(res.code, 'unresolved_plugin');
  } finally {
    cleanup();
  }
});

test('project file with one valid plugin indexes by :name', () => {
  const { root, cleanup } = tmpProject();
  try {
    writeFileSync(path.join(root, 'shapes.sjon'), '(plugin :name shapes :version "1.0.0")\n');
    writeFileSync(path.join(root, 'sjon-project.sjon'), '(project :plugins ["shapes.sjon"])\n');
    const { resolver, projectDiagnostics } = createNodeFsResolver({
      projectRoot: root,
      projectFile: path.join(root, 'sjon-project.sjon'),
    });
    assert.equal(projectDiagnostics.length, 0);
    const res = resolver(REF_NO_PATH('shapes'));
    assert.equal(res.kind, 'manifest');
    if (res.kind === 'manifest') {
      assert.match(res.source, /:name shapes/);
      assert.equal(res.wasm, null);
    }
  } finally {
    cleanup();
  }
});

test('duplicate :name across :plugins entries emits duplicate_plugin_name', () => {
  const { root, cleanup } = tmpProject();
  try {
    writeFileSync(path.join(root, 'a.sjon'), '(plugin :name shapes :version "1.0.0")\n');
    writeFileSync(path.join(root, 'b.sjon'), '(plugin :name shapes :version "1.0.0")\n');
    writeFileSync(path.join(root, 'sjon-project.sjon'), '(project :plugins ["a.sjon" "b.sjon"])\n');
    const { projectDiagnostics } = createNodeFsResolver({
      projectRoot: root,
      projectFile: path.join(root, 'sjon-project.sjon'),
    });
    assert.equal(projectDiagnostics.length, 1);
    assert.equal(projectDiagnostics[0]!.code, 'duplicate_plugin_name');
    assert.equal(projectDiagnostics[0]!.phase, 'manifest');
    assert.deepEqual([...projectDiagnostics[0]!.path], ['project']);
  } finally {
    cleanup();
  }
});

test('missing manifest path emits invalid_manifest', () => {
  const { root, cleanup } = tmpProject();
  try {
    writeFileSync(path.join(root, 'sjon-project.sjon'), '(project :plugins ["missing.sjon"])\n');
    const { projectDiagnostics } = createNodeFsResolver({
      projectRoot: root,
      projectFile: path.join(root, 'sjon-project.sjon'),
    });
    assert.equal(projectDiagnostics.length, 1);
    assert.equal(projectDiagnostics[0]!.code, 'invalid_manifest');
    assert.match(projectDiagnostics[0]!.message, /missing\.sjon/);
  } finally {
    cleanup();
  }
});

test('explicit :path bypasses index', () => {
  const { root, cleanup } = tmpProject();
  try {
    writeFileSync(path.join(root, 'vendored.sjon'), '(plugin :name vended :version "1.0.0")\n');
    const { resolver } = createNodeFsResolver({
      projectRoot: root,
      projectFile: null,
    });
    const res = resolver({
      name: 'vended',
      explicitPath: 'vendored.sjon',
      version: null,
      hash: null,
      span: { start: 0, end: 0 },
    });
    assert.equal(res.kind, 'manifest');
    if (res.kind === 'manifest') {
      assert.match(res.source, /:name vended/);
      assert.equal(res.wasm, null);
    }
  } finally {
    cleanup();
  }
});

test('explicit :path that does not exist becomes unresolved_plugin', () => {
  const { root, cleanup } = tmpProject();
  try {
    const { resolver } = createNodeFsResolver({
      projectRoot: root,
      projectFile: null,
    });
    const res = resolver({
      name: 'x',
      explicitPath: 'definitely-missing.sjon',
      version: null,
      hash: null,
      span: { start: 0, end: 0 },
    });
    assert.equal(res.kind, 'failure');
    if (res.kind === 'failure') {
      assert.equal(res.code, 'unresolved_plugin');
    }
  } finally {
    cleanup();
  }
});

test('project file with non-(project …) root reports invalid_manifest', () => {
  const { root, cleanup } = tmpProject();
  try {
    writeFileSync(path.join(root, 'sjon-project.sjon'), '(not-project :plugins [])\n');
    const { projectDiagnostics } = createNodeFsResolver({
      projectRoot: root,
      projectFile: path.join(root, 'sjon-project.sjon'),
    });
    assert.equal(projectDiagnostics.length, 1);
    assert.equal(projectDiagnostics[0]!.code, 'invalid_manifest');
    assert.match(projectDiagnostics[0]!.message, /not-project|project/);
  } finally {
    cleanup();
  }
});

test('project file walking nested manifests directory', () => {
  const { root, cleanup } = tmpProject();
  try {
    mkdirSync(path.join(root, 'manifests'));
    writeFileSync(
      path.join(root, 'manifests/shapes.sjon'),
      '(plugin :name shapes :version "1.0.0")\n',
    );
    writeFileSync(
      path.join(root, 'sjon-project.sjon'),
      '(project :plugins ["./manifests/shapes.sjon"])\n',
    );
    const { resolver, projectDiagnostics } = createNodeFsResolver({
      projectRoot: root,
      projectFile: path.join(root, 'sjon-project.sjon'),
    });
    assert.equal(projectDiagnostics.length, 0);
    const res = resolver(REF_NO_PATH('shapes'));
    assert.equal(res.kind, 'manifest');
  } finally {
    cleanup();
  }
});

// `(plugin-entry …)` — the reference accepts it (`indexOneManifest` in
// `src/FilesystemResolver.zig`); this host rejected it outright until
// 2026-08-12, so a valid project file failed on three of the four hosts.

test('createNodeFsResolver: (plugin-entry :path …) indexes like a bare path string', () => {
  const { root, cleanup } = tmpProject();
  try {
    writeFileSync(path.join(root, 'shapes.sjon'), '(plugin :name shapes :version "1.0.0")\n');
    writeFileSync(
      path.join(root, 'sjon-project.sjon'),
      '(project :plugins [(plugin-entry :path "shapes.sjon")])\n',
    );
    const { resolver, projectDiagnostics } = createNodeFsResolver({
      projectRoot: root,
      projectFile: path.join(root, 'sjon-project.sjon'),
    });
    assert.deepEqual(projectDiagnostics, []);
    const res = resolver(REF_NO_PATH('shapes'));
    assert.equal(res.kind, 'manifest');
  } finally {
    cleanup();
  }
});

test('createNodeFsResolver: (plugin-entry …) pins and reserved keys are accepted and inert', () => {
  const { root, cleanup } = tmpProject();
  try {
    writeFileSync(path.join(root, 'shapes.sjon'), '(plugin :name shapes :version "1.0.0")\n');
    // `:version` / `:hash` are project-level pins the reference keeps for
    // its `pin_disagreement` cross-check — a FilesystemResolver-local
    // check (a deliberate parity boundary). Here they must
    // parse without complaint and change nothing.
    writeFileSync(
      path.join(root, 'sjon-project.sjon'),
      '(project :plugins [(plugin-entry :path "shapes.sjon" :version "9.9.9" ' +
        `:hash "sha256-${'0'.repeat(64)}" :optional true :as other)])\n`,
    );
    const { resolver, projectDiagnostics } = createNodeFsResolver({
      projectRoot: root,
      projectFile: path.join(root, 'sjon-project.sjon'),
    });
    assert.deepEqual(projectDiagnostics, []);
    const res = resolver(REF_NO_PATH('shapes'));
    assert.equal(res.kind, 'manifest', 'a disagreeing project pin is not this host’s check');
  } finally {
    cleanup();
  }
});

test('createNodeFsResolver: (plugin-entry …) without :path emits invalid_manifest', () => {
  const { root, cleanup } = tmpProject();
  try {
    writeFileSync(
      path.join(root, 'sjon-project.sjon'),
      '(project :plugins [(plugin-entry :version "1.0.0")])\n',
    );
    const { projectDiagnostics } = createNodeFsResolver({
      projectRoot: root,
      projectFile: path.join(root, 'sjon-project.sjon'),
    });
    assert.equal(projectDiagnostics.length, 1);
    assert.equal(projectDiagnostics[0]!.code, 'invalid_manifest');
    assert.match(projectDiagnostics[0]!.message, /requires a `:path` string/);
  } finally {
    cleanup();
  }
});

test('createNodeFsResolver: a form entry that is not (plugin-entry …) names the head it saw', () => {
  const { root, cleanup } = tmpProject();
  try {
    writeFileSync(
      path.join(root, 'sjon-project.sjon'),
      '(project :plugins [(plugin-entrie :path "shapes.sjon")])\n',
    );
    const { projectDiagnostics } = createNodeFsResolver({
      projectRoot: root,
      projectFile: path.join(root, 'sjon-project.sjon'),
    });
    assert.equal(projectDiagnostics.length, 1);
    assert.equal(projectDiagnostics[0]!.code, 'invalid_manifest');
    assert.match(projectDiagnostics[0]!.message, /got `\(plugin-entrie …\)`/);
  } finally {
    cleanup();
  }
});
