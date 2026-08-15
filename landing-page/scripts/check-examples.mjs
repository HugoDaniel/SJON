#!/usr/bin/env node
/**
 * Gate: every curated playground example still validates the way it claims to.
 *
 * The playground's examples exist to *demonstrate* the server. An example that
 * quietly rots into a wall of `unknown_form` is worse than no example at all,
 * and nothing else notices: the registry is plain data, so typecheck and the
 * unit tests both stay green while the content goes wrong. This runs each
 * entry through the same `sjon-lsp.wasm` the page loads and compares the
 * diagnostics against what the entry declares.
 *
 * An entry with no `expectDiagnostics` must produce no errors and no warnings.
 * An entry with `expectDiagnostics` must produce exactly that set of codes —
 * both directions, so a demo that stops demonstrating its diagnostic fails too.
 *
 * Run: `node --experimental-strip-types landing-page/scripts/check-examples.mjs`
 * (from the repo root, or anywhere — paths resolve off this file). Wired into
 * `zig build check-examples`, which stages a fresh wasm first.
 */

import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { PLAYGROUND_EXAMPLES } from '../src/playground/examples.ts';

const HERE = dirname(fileURLToPath(import.meta.url));
const WASM_PATH = join(HERE, '..', 'public', 'sjon-lsp.wasm');

const encoder = new TextEncoder();
const decoder = new TextDecoder();

let bytes;
try {
  bytes = await readFile(WASM_PATH);
} catch {
  console.error(
    `check-examples: no wasm at ${WASM_PATH}\n` +
      '  Build it first: `zig build landing-page-assets`',
  );
  process.exit(2);
}

const instance = await WebAssembly.instantiate(await WebAssembly.compile(bytes), {});
const w = instance.exports;

let nextId = 100;

/** Send one JSON-RPC message and drain every response the server queued. */
function pump(message) {
  const encoded = encoder.encode(JSON.stringify(message));
  const ptr = w.sjon_lsp_alloc(encoded.length);
  if (!ptr) throw new Error('WASM alloc failed');
  new Uint8Array(w.memory.buffer, ptr, encoded.length).set(encoded);
  w.sjon_lsp_send(ptr, encoded.length);
  w.sjon_lsp_dealloc(ptr, encoded.length);

  const out = [];
  for (;;) {
    const rptr = w.sjon_lsp_recv();
    if (!rptr) break;
    const len = new DataView(w.memory.buffer).getUint32(rptr, true);
    out.push(JSON.parse(decoder.decode(new Uint8Array(w.memory.buffer, rptr + 4, len))));
    w.sjon_lsp_dealloc(rptr, len + 4);
  }
  return out;
}

function request(method, params) {
  const id = nextId++;
  return pump({ jsonrpc: '2.0', id, method, params }).find((r) => r.id === id)?.result;
}

function notify(method, params) {
  pump({ jsonrpc: '2.0', method, params });
}

pump({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { capabilities: {} } });
notify('initialized', {});

const DOC_URI = 'file:///playground/document.sjon';
const SEVERITY = { 1: 'error', 2: 'warning', 3: 'info', 4: 'hint' };

let version = 0;

/** Install an example's schemas, open its document, and pull the report. */
function diagnose(example) {
  const schemaReports =
    request('sjon/setSchemas', {
      schemas: example.schemas.map((text, i) => ({
        uri: `file:///playground/schema-${i}.sjon`,
        text,
      })),
    })?.reports ?? [];

  notify('textDocument/didOpen', {
    textDocument: { uri: DOC_URI, languageId: 'sjon', version: ++version, text: example.doc },
  });
  const items = request('textDocument/diagnostic', { textDocument: { uri: DOC_URI } })?.items ?? [];
  notify('textDocument/didClose', { textDocument: { uri: DOC_URI } });

  return { schemaReports, items };
}

function describe(d) {
  const where = `L${d.range.start.line + 1}:${d.range.start.character + 1}`;
  return `    ${SEVERITY[d.severity] ?? d.severity} ${d.code} at ${where} — ${d.message}`;
}

const failures = [];

for (const example of PLAYGROUND_EXAMPLES) {
  const { schemaReports, items } = diagnose(example);

  // A schema pane that does not parse breaks the example regardless of what
  // the document does, and the document's own report would not mention it.
  for (const report of schemaReports) {
    const bad = (report.items ?? []).filter((d) => d.severity <= 2);
    if (bad.length > 0) {
      failures.push(
        `${example.id}: schema pane "${report.name || report.uri}" is not clean\n` +
          bad.map(describe).join('\n'),
      );
    }
  }

  const loud = items.filter((d) => d.severity <= 2);
  const expected = example.expectDiagnostics ?? null;
  const before = failures.length;
  let note;

  if (expected === null) {
    if (loud.length > 0) {
      failures.push(
        `${example.id}: expected a clean document, got ${loud.length} diagnostic(s)\n` +
          loud.map(describe).join('\n'),
      );
    }
    note = 'clean';
  } else {
    const got = [...new Set(loud.map((d) => d.code))].sort();
    const want = [...new Set(expected)].sort();
    if (got.join(',') !== want.join(',')) {
      failures.push(
        `${example.id}: declared diagnostics [${want.join(', ')}], got [${got.join(', ')}]\n` +
          loud.map(describe).join('\n'),
      );
    }
    note = `demonstrates ${got.join(', ') || '(nothing)'}`;
  }

  const verdict = failures.length === before ? '  ok  ' : ' FAIL ';
  console.log(`${verdict} ${example.id.padEnd(14)} ${note}`);
}

if (failures.length > 0) {
  console.error(`\ncheck-examples: ${failures.length} example(s) failed\n`);
  for (const f of failures) console.error(f + '\n');
  process.exit(1);
}

console.log(`\ncheck-examples: ${PLAYGROUND_EXAMPLES.length} examples ok`);
