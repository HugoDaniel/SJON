// Integration contract for the `@sjon-lang/read` migration.
//
// These fixtures pin what the resolver does with *real* SJON, replacing the
// subset parser's refusal tests:
//
//   * a raw string is one string, not three nodes — so a manifest `:name`
//     keeps the value the author wrote;
//   * `#| … |#` is trivia — so a commented-out `:plugins` entry is not
//     configuration and cannot be indexed;
//   * malformed project/manifest input still fails loudly through the same
//     `invalid_manifest` channel (one root, project/manifest shape checks).
//
// The assertions are about reading, never about refusing valid syntax.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { createNodeFsResolver } from '../createNodeFsResolver.ts';
import type { Reference } from '../sjon-reader.ts';

function tmpProject(): { root: string; cleanup: () => void } {
  const root = mkdtempSync(path.join(tmpdir(), 'sjon-read-'));
  return { root, cleanup: () => rmSync(root, { recursive: true, force: true }) };
}

const REF_NO_PATH = (name: string): Reference => ({
  name,
  explicitPath: null,
  version: null,
  hash: null,
  span: { start: 0, end: 0 },
});

test('a raw-string manifest :name is one string and stays indexable', () => {
  const { root, cleanup } = tmpProject();
  try {
    writeFileSync(path.join(root, 'shapes.sjon'), '(plugin :name """shapes""" :version "1.0.0")\n');
    writeFileSync(path.join(root, 'sjon-project.sjon'), '(project :plugins ["shapes.sjon"])\n');

    const { resolver, projectDiagnostics } = createNodeFsResolver({
      projectRoot: root,
      projectFile: path.join(root, 'sjon-project.sjon'),
    });

    assert.deepEqual(projectDiagnostics, []);
    const resolved = resolver(REF_NO_PATH('shapes'));
    assert.equal(resolved.kind, 'manifest');
    if (resolved.kind === 'manifest') {
      assert.match(resolved.source, /"""shapes"""/);
    }
  } finally {
    cleanup();
  }
});

test('a raw-string :plugins entry names the manifest it spells', () => {
  const { root, cleanup } = tmpProject();
  try {
    writeFileSync(path.join(root, 'shapes.sjon'), '(plugin :name shapes :version "1.0.0")\n');
    writeFileSync(path.join(root, 'sjon-project.sjon'), '(project :plugins ["""shapes.sjon"""])\n');

    const { resolver, projectDiagnostics } = createNodeFsResolver({
      projectRoot: root,
      projectFile: path.join(root, 'sjon-project.sjon'),
    });

    assert.deepEqual(projectDiagnostics, []);
    assert.equal(resolver(REF_NO_PATH('shapes')).kind, 'manifest');
  } finally {
    cleanup();
  }
});

test('a block-commented :plugins entry is trivia, not configuration', () => {
  const { root, cleanup } = tmpProject();
  try {
    writeFileSync(path.join(root, 'active.sjon'), '(plugin :name active :version "1.0.0")\n');
    writeFileSync(path.join(root, 'disabled.sjon'), '(plugin :name disabled :version "1.0.0")\n');
    writeFileSync(
      path.join(root, 'sjon-project.sjon'),
      '(project\n  #| :plugins ["disabled.sjon"] |#\n  :plugins ["active.sjon"])\n',
    );

    const { resolver, projectDiagnostics } = createNodeFsResolver({
      projectRoot: root,
      projectFile: path.join(root, 'sjon-project.sjon'),
    });

    assert.deepEqual(projectDiagnostics, []);
    assert.equal(resolver(REF_NO_PATH('active')).kind, 'manifest');

    // The disabled file exists and is a valid manifest, so an indexed entry
    // would resolve here. It must not: text the author commented out is not
    // project configuration.
    const disabled = resolver(REF_NO_PATH('disabled'));
    assert.equal(disabled.kind, 'failure');
    if (disabled.kind === 'failure') {
      assert.match(disabled.detail, /no plugin named `disabled`/);
    }
  } finally {
    cleanup();
  }
});

test('a block-commented (plugin-entry …) inside :plugins is not indexed', () => {
  const { root, cleanup } = tmpProject();
  try {
    writeFileSync(path.join(root, 'active.sjon'), '(plugin :name active :version "1.0.0")\n');
    writeFileSync(path.join(root, 'disabled.sjon'), '(plugin :name disabled :version "1.0.0")\n');
    writeFileSync(
      path.join(root, 'sjon-project.sjon'),
      '(project :plugins ["active.sjon" #| (plugin-entry :path "disabled.sjon") |#])\n',
    );

    const { resolver, projectDiagnostics } = createNodeFsResolver({
      projectRoot: root,
      projectFile: path.join(root, 'sjon-project.sjon'),
    });

    assert.deepEqual(projectDiagnostics, []);
    assert.equal(resolver(REF_NO_PATH('active')).kind, 'manifest');
    assert.equal(resolver(REF_NO_PATH('disabled')).kind, 'failure');
  } finally {
    cleanup();
  }
});

test('a project file with two top-level forms is still rejected', () => {
  const { root, cleanup } = tmpProject();
  try {
    writeFileSync(
      path.join(root, 'sjon-project.sjon'),
      '(project :plugins [])\n(project :plugins [])\n',
    );

    const { projectDiagnostics } = createNodeFsResolver({
      projectRoot: root,
      projectFile: path.join(root, 'sjon-project.sjon'),
    });

    assert.equal(projectDiagnostics.length, 1);
    assert.equal(projectDiagnostics[0]!.code, 'invalid_manifest');
    assert.match(projectDiagnostics[0]!.message, /single top-level form/);
  } finally {
    cleanup();
  }
});

test('an unterminated project form is still rejected through invalid_manifest', () => {
  const { root, cleanup } = tmpProject();
  try {
    writeFileSync(path.join(root, 'sjon-project.sjon'), '(project :plugins ["a.sjon"]\n');

    const { projectDiagnostics } = createNodeFsResolver({
      projectRoot: root,
      projectFile: path.join(root, 'sjon-project.sjon'),
    });

    assert.equal(projectDiagnostics.length, 1);
    assert.equal(projectDiagnostics[0]!.code, 'invalid_manifest');
    assert.match(projectDiagnostics[0]!.message, /failed to parse/);
  } finally {
    cleanup();
  }
});

test('a non-project root and a namespaced project root are still refused', () => {
  const { root, cleanup } = tmpProject();
  try {
    for (const [source, expected] of [
      ['(not-project :plugins [])\n', /got `not-project`/],
      ['(ns/project :plugins [])\n', /got `ns\/project`/],
    ] as const) {
      writeFileSync(path.join(root, 'sjon-project.sjon'), source);
      const { projectDiagnostics } = createNodeFsResolver({
        projectRoot: root,
        projectFile: path.join(root, 'sjon-project.sjon'),
      });
      assert.equal(projectDiagnostics.length, 1);
      assert.equal(projectDiagnostics[0]!.code, 'invalid_manifest');
      assert.match(projectDiagnostics[0]!.message, expected);
    }
  } finally {
    cleanup();
  }
});

test('a malformed manifest is still rejected through invalid_manifest', () => {
  const { root, cleanup } = tmpProject();
  try {
    writeFileSync(path.join(root, 'broken.sjon'), '(plugin :name "broken"\n');
    writeFileSync(path.join(root, 'sjon-project.sjon'), '(project :plugins ["broken.sjon"])\n');

    const { projectDiagnostics } = createNodeFsResolver({
      projectRoot: root,
      projectFile: path.join(root, 'sjon-project.sjon'),
    });

    assert.equal(projectDiagnostics.length, 1);
    assert.equal(projectDiagnostics[0]!.code, 'invalid_manifest');
    assert.match(projectDiagnostics[0]!.message, /failed to parse/);
  } finally {
    cleanup();
  }
});
