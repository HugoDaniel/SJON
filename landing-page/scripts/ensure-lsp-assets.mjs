// Ensure the playground's LSP wasm + sidecar are staged before dev / build.
//
// `zig build landing-page-assets` is the source of truth — it restages
// sjon-lsp.wasm and regenerates sjon-lsp.meta.json. This wrapper runs it when
// `zig` is on PATH, and degrades sensibly when it is not:
//
//   * zig present            → run it; a nonzero exit is fatal (a broken Zig
//                              build is a broken playground, surfaced loudly).
//   * no zig, staged wasm     → warn and continue (CI / contributor without a
//                              Zig toolchain builds against the last artifact).
//   * no zig, no staged wasm  → fail: a build with no language server at all.
//
// Wired as the `stage:lsp` npm script, chained ahead of `astro dev` /
// `astro build`. pnpm does NOT auto-run pre* scripts, so the chain is explicit.

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(HERE, '..', '..');
const STAGED_WASM = path.resolve(HERE, '..', 'public', 'sjon-lsp.wasm');

function hasZig() {
  return spawnSync('zig', ['version'], { stdio: 'ignore' }).status === 0;
}

if (hasZig()) {
  console.log('ensure-lsp-assets: staging via `zig build landing-page-assets`…');
  const r = spawnSync('zig', ['build', 'landing-page-assets'], {
    cwd: REPO_ROOT,
    stdio: 'inherit',
  });
  if (r.status !== 0) {
    console.error('ensure-lsp-assets: `zig build landing-page-assets` failed');
    process.exit(r.status ?? 1);
  }
} else if (fs.existsSync(STAGED_WASM)) {
  console.warn(
    'ensure-lsp-assets: `zig` not on PATH — using the already-staged sjon-lsp.wasm. ' +
      'Run `zig build landing-page-assets` after any Zig LSP change to refresh it.',
  );
} else {
  console.error(
    'ensure-lsp-assets: no `zig` on PATH and no staged sjon-lsp.wasm — the playground ' +
      'would have no language server. Install zig, or stage the wasm elsewhere and copy ' +
      'it to landing-page/public/sjon-lsp.wasm.',
  );
  process.exit(1);
}
