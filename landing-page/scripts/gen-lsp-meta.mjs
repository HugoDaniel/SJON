// Generate `sjon-lsp.meta.json` next to the staged `sjon-lsp.wasm`.
//
// Records the artifact's sha256 (+ a 12-char short hash) and the `serverInfo`
// its `initialize` handshake reports, so the playground can (a) cache-bust the
// wasm URL with the short hash and (b) warn when the running server's
// serverInfo drifts from what the build staged. Wired into the
// `landing-page-assets` build step, run *after* the wasm is copied into
// `landing-page/public/`.
//
// Run manually with `node scripts/gen-lsp-meta.mjs` from the landing-page dir,
// or `node landing-page/scripts/gen-lsp-meta.mjs` from the repo root — the
// paths resolve against this file, not the cwd.

import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = path.resolve(HERE, '..', 'public');
const WASM_PATH = path.join(PUBLIC_DIR, 'sjon-lsp.wasm');
const META_PATH = path.join(PUBLIC_DIR, 'sjon-lsp.meta.json');

const encoder = new TextEncoder();
const decoder = new TextDecoder();

// Instantiate the wasm, run the initialize handshake, return its serverInfo
// ({name, version}) — or null if the handshake shape is unexpected. Mirrors
// the pump in landing-page/src/playground/lsp-inline-backend.ts.
async function readServerInfo(bytes) {
  const mod = await WebAssembly.compile(bytes);
  const instance = await WebAssembly.instantiate(mod, {});
  const w = instance.exports;

  const encoded = encoder.encode(
    JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { capabilities: {} } }),
  );
  const ptr = w.sjon_lsp_alloc(encoded.length);
  if (!ptr) throw new Error('WASM alloc failed');
  new Uint8Array(w.memory.buffer, ptr, encoded.length).set(encoded);
  w.sjon_lsp_send(ptr, encoded.length);
  w.sjon_lsp_dealloc(ptr, encoded.length);

  for (;;) {
    const rptr = w.sjon_lsp_recv();
    if (!rptr) break;
    const len = new DataView(w.memory.buffer).getUint32(rptr, true);
    const text = decoder.decode(new Uint8Array(w.memory.buffer, rptr + 4, len));
    w.sjon_lsp_dealloc(rptr, len + 4);
    const r = JSON.parse(text);
    const info = r?.id === 1 ? r?.result?.serverInfo : undefined;
    if (info && typeof info.name === 'string' && typeof info.version === 'string') {
      return { name: info.name, version: info.version };
    }
  }
  return null;
}

async function main() {
  let bytes;
  try {
    bytes = await fs.readFile(WASM_PATH);
  } catch {
    console.error(
      `gen-lsp-meta: ${WASM_PATH} not found — run \`zig build landing-page-assets\` first`,
    );
    process.exit(1);
  }

  const sha256 = crypto.createHash('sha256').update(bytes).digest('hex');
  const serverInfo = await readServerInfo(bytes);
  if (!serverInfo) {
    console.error('gen-lsp-meta: could not read serverInfo from the wasm initialize handshake');
    process.exit(1);
  }

  const meta = { sha256, shortHash: sha256.slice(0, 12), serverInfo };
  await fs.writeFile(META_PATH, `${JSON.stringify(meta, null, 2)}\n`);
  console.log(
    `gen-lsp-meta: wrote ${path.relative(process.cwd(), META_PATH)} ` +
      `(${meta.shortHash}, ${serverInfo.name}@${serverInfo.version})`,
  );
}

main().catch((e) => {
  console.error('gen-lsp-meta: unexpected error', e);
  process.exit(1);
});
