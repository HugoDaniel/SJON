// SJON VS Code extension — data-only manifest tests.
//
// These assert the static contribution surface without importing `vscode`
// (only available inside the extension host at runtime):
//   1. the bundled TextMate grammar is byte-identical to @sjon-lang/highlight's
//      source of truth — the drift gate. VS Code needs the grammar file inside
//      the extension, so it is copied; this test is what keeps the copy honest.
//   2. the language contribution declares the `.sjon` extension and the `;`
//      line comment, so `.sjon` files light up and Toggle Line Comment works.
//   3. the extension actually activates when one of those files is opened.

import { describe, it } from 'node:test';
import { strict as assert } from 'node:assert';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const ext = resolve(here, '..');
const repoRoot = resolve(here, '../../..');

describe('bundled TextMate grammar', () => {
  it('is byte-identical to hosts/highlight source of truth', () => {
    const source = readFileSync(resolve(repoRoot, 'hosts/highlight/src/sjon.tmLanguage.json'));
    const bundled = readFileSync(resolve(ext, 'syntaxes/sjon.tmLanguage.json'));
    assert.ok(
      bundled.equals(source),
      'syntaxes/sjon.tmLanguage.json has drifted from hosts/highlight/src/sjon.tmLanguage.json — re-copy it (see editors/vscode/README.md).',
    );
  });
});

describe('language contribution', () => {
  const pkg = JSON.parse(readFileSync(resolve(ext, 'package.json'), 'utf8')) as {
    contributes: { languages: Array<{ id: string; extensions: string[] }> };
  };

  it('declares the .sjon extension for language id "sjon"', () => {
    const sjon = pkg.contributes.languages.find((l) => l.id === 'sjon');
    assert.ok(sjon, 'no language with id "sjon" contributed');
    assert.ok(sjon.extensions.includes('.sjon'), '.sjon not in language extensions');
  });

  it('declares ";" as the line comment', () => {
    const cfg = JSON.parse(readFileSync(resolve(ext, 'language-configuration.json'), 'utf8')) as {
      comments: { lineComment: string };
    };
    assert.equal(cfg.comments.lineComment, ';');
  });
});

describe('activation', () => {
  const pkg = JSON.parse(readFileSync(resolve(ext, 'package.json'), 'utf8')) as {
    activationEvents: string[];
  };

  // Contributing a language does not activate an extension — it only tells
  // VS Code which files get the grammar. Without this event, opening a
  // standalone `.sjon` file outside a project workspace got TextMate
  // highlighting and nothing else: the language server, which handles the
  // no-project case perfectly well, was never started and said nothing
  // about it.
  it('activates on the sjon language, not only inside a project', () => {
    assert.ok(
      pkg.activationEvents.includes('onLanguage:sjon'),
      'onLanguage:sjon missing — a .sjon file outside a workspace never starts the LSP',
    );
  });

  it('still activates for a project workspace with no file open', () => {
    assert.ok(pkg.activationEvents.includes('workspaceContains:**/sjon-project.sjon'));
  });
});
