// Locating the sjon-lsp server executable. Kept free of any `vscode` import so
// the resolver is unit-testable in plain node (the PATH probe is injected).

import { existsSync } from 'node:fs';
import { delimiter, join } from 'node:path';

/// Resolve the sjon-lsp server command.
///
/// Precedence: an explicit `sjon.lsp.path` setting wins (trimmed — a
/// whitespace-only value counts as unset). Otherwise fall back to `lookup`, a
/// PATH probe. Returns null when neither yields a command; the caller surfaces
/// that to the user rather than starting a broken client.
///
/// Pure: the probe is a parameter, so this has no filesystem or environment
/// dependency of its own. O(1) beyond the injected lookup.
export function resolveServerPath(
  configured: string,
  lookup: (command: string) => string | null,
): string | null {
  const trimmed = configured.trim();
  if (trimmed.length > 0) {
    return trimmed;
  }
  return lookup('sjon-lsp');
}

/// The real PATH probe: the first directory on PATH holding an existing
/// `command` (plus `.exe` on Windows). Injected into resolveServerPath by the
/// extension; tests substitute a stub. Returns null on an unset or exhausted
/// PATH.
export function lookupOnPath(command: string): string | null {
  const raw = process.env['PATH'];
  if (raw === undefined) {
    return null;
  }
  const names = process.platform === 'win32' ? [command, `${command}.exe`] : [command];
  for (const dir of raw.split(delimiter)) {
    if (dir.length === 0) {
      continue;
    }
    for (const name of names) {
      const candidate = join(dir, name);
      if (existsSync(candidate)) {
        return candidate;
      }
    }
  }
  return null;
}
