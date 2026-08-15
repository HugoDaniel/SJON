// Unit tests for the server-path resolver — a pure function, so it needs
// neither `vscode` nor a real filesystem (the PATH probe is injected).

import { describe, it } from 'node:test';
import { strict as assert } from 'node:assert';
import { resolveServerPath } from '../src/serverPath.ts';

describe('resolveServerPath', () => {
  it('prefers the configured sjon.lsp.path setting over PATH', () => {
    const result = resolveServerPath('/opt/sjon/sjon-lsp', () => {
      throw new Error('PATH lookup must not run when a path is configured');
    });
    assert.equal(result, '/opt/sjon/sjon-lsp');
  });

  it('trims the configured path and treats whitespace-only as unset', () => {
    assert.equal(
      resolveServerPath('   ', (cmd) => `/usr/local/bin/${cmd}`),
      '/usr/local/bin/sjon-lsp',
    );
    assert.equal(
      resolveServerPath('  /x/sjon-lsp  ', () => null),
      '/x/sjon-lsp',
    );
  });

  it('falls back to the PATH lookup when unset, propagating a miss as null', () => {
    assert.equal(
      resolveServerPath('', () => '/found/sjon-lsp'),
      '/found/sjon-lsp',
    );
    assert.equal(
      resolveServerPath('', () => null),
      null,
    );
  });
});
