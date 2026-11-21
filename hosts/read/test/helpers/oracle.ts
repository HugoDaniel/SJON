// Test-only engine oracle for the reader's parity legs.
//
// This helper owns the only door from the reader's tests to the Zig engine:
// the built `zig-out/bin/sjon.wasm`, called through its public exports
// (`sjon_node_table`, `sjon_to_json`). It never imports the engine's Zig
// sources, never reads them as text, and is not re-exported from the package.
//
// The artifact is mandatory. A missing, truncated, unbuilt, or source-stale
// `sjon.wasm` throws with the command that fixes it; the oracle never skips
// itself. "Stale-looking" is the mtime test the plan asks for: if any
// `src/**/*.zig`, `build.zig`, or `build.zig.zon` is newer than the artifact,
// this checkout's wasm may not be the tree the tests are reading.
//
// `sjon_to_json` is parsed with a bigint-aware reader because `JSON.parse`
// collapses integer-shaped tokens above `Number.MAX_SAFE_INTEGER` onto their
// nearest f64 neighbour. The oracle's exact-integer checks are only as strong
// as that parse: i64.max and u64.max must arrive bit-faithful.

import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/** Repository root, resolved from this helper rather than the process cwd. */
export const repoRoot = resolve(fileURLToPath(new URL('../../../..', import.meta.url)));

/** Every `*.sjon` input the oracle replays, discovered from the corpus. */
export const corpusRoot = join(repoRoot, 'conformance', 'cases');

/** The kitchen-sink artifact the oracle drives. */
export const wasmPath = join(repoRoot, 'zig-out', 'bin', 'sjon.wasm');

// A kitchen-sink build is hundreds of kilobytes. Anything smaller is a
// truncated/corrupt artifact, not a small document the oracle can still use.
const MIN_PLAUSIBLE_WASM_BYTES = 64 * 1024;
const WASM_MAGIC = [0x00, 0x61, 0x73, 0x6d] as const;
const WASM_VERSION = 1;

const decoder = new TextDecoder();
const encoder = new TextEncoder();

/** A half-open byte span as `sjon_node_table` serializes it. */
export type EngineSpan = readonly [number, number];

/** One `sjon_node_table` row. A kvpair never has a row of its own. */
export interface EngineRow {
  readonly i: number;
  readonly parent: number;
  readonly root: number;
  readonly seg: string | number | null;
  readonly kind: string;
  readonly span: EngineSpan;
  readonly head_span?: EngineSpan;
  readonly key_span?: EngineSpan;
}

/** One parse diagnostic as `sjon_node_table` serializes it. */
export interface EngineDiagnostic {
  readonly code: string;
  readonly severity: 'err' | 'warning';
  readonly span: { readonly start: number; readonly end: number };
  readonly message: string;
}

export interface EngineNodeTable {
  readonly nodes: readonly EngineRow[];
  readonly diagnostics: readonly EngineDiagnostic[];
}

/**
 * JSON value with exact integers.
 *
 * `bigint` appears only for integer-shaped tokens outside the JS safe range;
 * safe integers, fractions, and exponents are `number`, exactly as
 * `JSON.parse` would give them. This mirrors the web host's
 * `parseJsonWithBigInt`, duplicated here so the reader package's tests stay
 * self-contained and do not import another host's runtime.
 */
export type JsonValue =
  | null
  | boolean
  | number
  | bigint
  | string
  | readonly JsonValue[]
  | { readonly [key: string]: JsonValue };

export type ToJsonOutcome =
  | { readonly ok: true; readonly value: JsonValue }
  | { readonly ok: false; readonly error: string };

/** The engine surface the two oracle legs are allowed to use. */
export interface EngineOracle {
  /** Parse `source` and return its address table plus parse diagnostics. */
  nodeTable(source: Uint8Array): EngineNodeTable;
  /** Bridge one complete root's bytes through `sjon_to_json` (canonical). */
  toJson(source: Uint8Array): ToJsonOutcome;
  /**
   * True when the core schema treats `head` as an expression function, read
   * off the engine by asking it to bridge a zero-argument `(head)` form. Used
   * only to prove the `expression` exclusion still has its reason.
   */
  isExpressionHead(head: string, namespace: string | null): boolean;
}

/** A curated source and the exclusion each root is expected to need. */
export type RootExclusion = 'plain' | 'expression' | 'duplicate-key';

export interface CuratedCase {
  readonly name: string;
  readonly source: string;
  /** One entry per expected root, in source order. */
  readonly expected: readonly RootExclusion[];
}

export interface DiscoveredCase {
  readonly name: string;
  readonly source: string;
}

interface SjonExports {
  readonly memory: WasmMemory;
  readonly sjon_alloc: (length: number) => number;
  readonly sjon_free: (ptr: number, length: number) => void;
  readonly sjon_node_table: (srcPtr: number, srcLen: number) => number;
  readonly sjon_to_json: (
    srcPtr: number,
    srcLen: number,
    optsPtr: number,
    optsLen: number,
  ) => number;
}

interface Frame {
  readonly ok: boolean;
  readonly payload: Uint8Array;
}

// The package's strict tsconfig carries `lib: ["ES2022"]`, not `DOM`, so the
// WebAssembly globals are untyped here. This minimal declaration is erasable
// and matches the Node built-in the test actually runs on.
interface WasmMemory {
  readonly buffer: ArrayBuffer;
}

interface WasmInstance {
  readonly exports: Record<string, unknown>;
}

declare const WebAssembly: {
  instantiate(
    bytes: Uint8Array,
    imports: {
      readonly env: {
        readonly sjon_host_resolve: () => number;
        readonly sjon_host_invoke_plugin: () => number;
      };
    },
  ): Promise<{ readonly instance: WasmInstance }>;
};

/**
 * Load and fingerprint the built `sjon.wasm`.
 *
 * Throws, never skips: a missing artifact, a non-wasm header, a short file, a
 * null engine frame, or an artifact older than the Zig sources that produce it
 * all make the oracle unable to claim parity. The message names the fix.
 */
export async function loadOracle(): Promise<EngineOracle> {
  const bytes = readArtifact();
  const { instance } = await WebAssembly.instantiate(bytes, {
    env: {
      // The oracle never reaches either host bridge: node-table and to-json
      // are parse/render paths. Binding the stubs keeps instantiation honest.
      sjon_host_resolve: () => 0,
      sjon_host_invoke_plugin: () => 0,
    },
  });
  const exports = requireExports(instance);
  const expressionHeads = new Map<string, boolean>();

  function alloc(source: Uint8Array): number {
    if (source.length === 0) return 0;
    const ptr = exports.sjon_alloc(source.length);
    if (ptr === 0) throw new Error('sjon.wasm sjon_alloc returned null for a non-empty buffer');
    new Uint8Array(exports.memory.buffer, ptr, source.length).set(source);
    return ptr;
  }

  function free(ptr: number, length: number): void {
    if (ptr !== 0) exports.sjon_free(ptr, length);
  }

  function readFrame(outPtr: number): Frame {
    if (outPtr === 0) throw new Error('sjon.wasm returned a null frame pointer');
    const view = new DataView(exports.memory.buffer);
    const ok = view.getUint32(outPtr, true) !== 0;
    const length = view.getUint32(outPtr + 4, true);
    const end = outPtr + 8 + length;
    if (end > exports.memory.buffer.byteLength) {
      throw new Error(
        `sjon.wasm framed payload runs past linear memory (${end} > ${exports.memory.buffer.byteLength})`,
      );
    }
    // Copy before freeing: the payload borrows the engine's linear memory.
    const payload = new Uint8Array(exports.memory.buffer, outPtr + 8, length).slice();
    free(outPtr, 8 + length);
    return { ok, payload };
  }

  function nodeTable(source: Uint8Array): EngineNodeTable {
    const srcPtr = alloc(source);
    try {
      const frame = readFrame(exports.sjon_node_table(srcPtr, source.length));
      const text = decoder.decode(frame.payload);
      if (!frame.ok) throw new Error(`sjon_node_table failed: ${text}`);
      return JSON.parse(text) as EngineNodeTable;
    } finally {
      free(srcPtr, source.length);
    }
  }

  function toJson(source: Uint8Array): ToJsonOutcome {
    const srcPtr = alloc(source);
    try {
      const frame = readFrame(exports.sjon_to_json(srcPtr, source.length, 0, 0));
      const text = decoder.decode(frame.payload);
      if (!frame.ok) return { ok: false, error: text };
      try {
        return { ok: true, value: parseJsonWithBigInt(text) };
      } catch (error) {
        return { ok: false, error: `invalid JSON from sjon_to_json (${String(error)}): ${text}` };
      }
    } finally {
      free(srcPtr, source.length);
    }
  }

  function isExpressionHead(head: string, namespace: string | null): boolean {
    const qualified = namespace === null ? head : `${namespace}/${head}`;
    const cached = expressionHeads.get(qualified);
    if (cached !== undefined) return cached;
    const outcome = toJson(encoder.encode(`(${qualified})`));
    const value = outcome.ok ? outcome.value : null;
    const isExpression = isJsonObject(value) && Object.hasOwn(value, '$expr');
    expressionHeads.set(qualified, isExpression);
    return isExpression;
  }

  return { nodeTable, toJson, isExpressionHead };
}

/**
 * Read every `*.sjon` file under `conformance/cases/`, sorted by path.
 *
 * The corpus is oracle *input*, never output: no case is written, skipped, or
 * classified by directory. Curated reader fixtures live under
 * `hosts/read/test/fixtures/`, not here.
 */
export function discoverCorpusCases(): DiscoveredCase[] {
  if (!existsSync(corpusRoot)) {
    throw new Error(`SJON oracle corpus not found at ${corpusRoot}; run from a full checkout`);
  }
  const paths: string[] = [];
  const walk = (dir: string): void => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) walk(path);
      else if (entry.isFile() && entry.name.endsWith('.sjon')) paths.push(path);
    }
  };
  walk(corpusRoot);
  paths.sort();
  return paths.map((path) => ({
    name: relative(repoRoot, path),
    source: readFileSync(path, 'utf8'),
  }));
}

function readArtifact(): Uint8Array {
  if (!existsSync(wasmPath)) {
    throw new Error(
      `SJON oracle artifact missing at ${wasmPath} — run \`zig build wasm-all\` before this test`,
    );
  }
  const stat = statSync(wasmPath);
  if (!stat.isFile()) {
    throw new Error(`SJON oracle artifact at ${wasmPath} is not a regular file`);
  }
  if (stat.size < MIN_PLAUSIBLE_WASM_BYTES) {
    throw new Error(
      `SJON oracle artifact at ${wasmPath} is only ${stat.size} bytes — truncated? run \`zig build wasm-all\``,
    );
  }
  const bytes = readFileSync(wasmPath);
  for (let i = 0; i < WASM_MAGIC.length; i += 1) {
    if (bytes[i] !== WASM_MAGIC[i]) {
      throw new Error(`SJON oracle artifact at ${wasmPath} has no WebAssembly magic header`);
    }
  }
  const version = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint32(4, true);
  if (version !== WASM_VERSION) {
    throw new Error(`SJON oracle artifact at ${wasmPath} declares wasm version ${version}, not 1`);
  }

  const newest = newestEngineSource();
  if (newest !== null && newest.mtimeMs > stat.mtimeMs) {
    throw new Error(
      `SJON oracle artifact at ${wasmPath} is older than ${relative(repoRoot, newest.path)} — ` +
        'run `zig build wasm-all` (or touch the artifact if the build reports it up to date)',
    );
  }
  return bytes;
}

function newestEngineSource(): { readonly path: string; readonly mtimeMs: number } | null {
  let newest: { path: string; mtimeMs: number } | null = null;
  const consider = (path: string): void => {
    const stat = statSync(path);
    if (newest === null || stat.mtimeMs > newest.mtimeMs) {
      newest = { path, mtimeMs: stat.mtimeMs };
    }
  };
  const walk = (dir: string): void => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) walk(path);
      else if (entry.isFile() && entry.name.endsWith('.zig')) consider(path);
    }
  };
  walk(join(repoRoot, 'src'));
  for (const name of ['build.zig', 'build.zig.zon']) {
    const path = join(repoRoot, name);
    if (existsSync(path)) consider(path);
  }
  return newest;
}

function requireExports(instance: WasmInstance): SjonExports {
  const exports = instance.exports;
  const memory = exports['memory'];
  if (!isWasmMemory(memory)) {
    throw new Error('sjon.wasm exports no memory; is this the kitchen-sink artifact?');
  }
  for (const name of ['sjon_alloc', 'sjon_free', 'sjon_node_table', 'sjon_to_json'] as const) {
    if (typeof exports[name] !== 'function') {
      throw new Error(`sjon.wasm does not export ${name}; run \`zig build wasm-all\``);
    }
  }
  return exports as unknown as SjonExports;
}

function isWasmMemory(value: unknown): value is WasmMemory {
  return (
    typeof value === 'object' &&
    value !== null &&
    'buffer' in value &&
    value.buffer instanceof ArrayBuffer
  );
}

/** Type guard for a JSON object (never a null or an array). */
export function isJsonObject(
  value: JsonValue | undefined,
): value is { readonly [key: string]: JsonValue } {
  return (
    value !== null && value !== undefined && typeof value === 'object' && !Array.isArray(value)
  );
}

const MAX_SAFE_BIGINT = BigInt(Number.MAX_SAFE_INTEGER);
const MIN_SAFE_BIGINT = BigInt(Number.MIN_SAFE_INTEGER);

/**
 * Parse RFC 8259 JSON, returning `bigint` for integer tokens outside the JS
 * safe range. Strings, arrays, objects, booleans, `null`, fractions, and
 * exponents decode exactly as `JSON.parse` would.
 */
function parseJsonWithBigInt(text: string): JsonValue {
  let index = 0;

  const skipWhitespace = (): void => {
    while (index < text.length) {
      const ch = text[index];
      if (ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r') index += 1;
      else break;
    }
  };

  const readString = (): string => {
    index += 1; // opening quote
    const start = index;
    let hasEscape = false;
    while (index < text.length) {
      const ch = text[index];
      if (ch === '"') {
        const raw = text.slice(start, index);
        index += 1;
        return hasEscape ? (JSON.parse(`"${raw}"`) as string) : raw;
      }
      if (ch === '\\') {
        hasEscape = true;
        index += 2;
        continue;
      }
      index += 1;
    }
    throw new SyntaxError('unterminated JSON string');
  };

  const readNumber = (): number | bigint => {
    const start = index;
    let isInteger = true;
    if (text[index] === '-') index += 1;
    while (index < text.length && isJsonDigit(text[index])) index += 1;
    if (text[index] === '.') {
      isInteger = false;
      index += 1;
      while (index < text.length && isJsonDigit(text[index])) index += 1;
    }
    if (text[index] === 'e' || text[index] === 'E') {
      isInteger = false;
      index += 1;
      if (text[index] === '+' || text[index] === '-') index += 1;
      while (index < text.length && isJsonDigit(text[index])) index += 1;
    }
    const lexeme = text.slice(start, index);
    if (!isInteger) return Number(lexeme);
    const exact = BigInt(lexeme);
    return exact > MAX_SAFE_BIGINT || exact < MIN_SAFE_BIGINT ? exact : Number(exact);
  };

  const readValue = (): JsonValue => {
    skipWhitespace();
    const ch = text[index];
    if (ch === '{') {
      index += 1;
      const object: Record<string, JsonValue> = {};
      skipWhitespace();
      if (text[index] === '}') {
        index += 1;
        return object;
      }
      while (true) {
        skipWhitespace();
        if (text[index] !== '"') throw new SyntaxError(`expected object key at ${index}`);
        const key = readString();
        skipWhitespace();
        if (text[index] !== ':') throw new SyntaxError(`expected ':' at ${index}`);
        index += 1;
        object[key] = readValue();
        skipWhitespace();
        if (text[index] === ',') {
          index += 1;
          continue;
        }
        if (text[index] === '}') {
          index += 1;
          return object;
        }
        throw new SyntaxError(`expected ',' or '}' at ${index}`);
      }
    }
    if (ch === '[') {
      index += 1;
      const array: JsonValue[] = [];
      skipWhitespace();
      if (text[index] === ']') {
        index += 1;
        return array;
      }
      while (true) {
        array.push(readValue());
        skipWhitespace();
        if (text[index] === ',') {
          index += 1;
          continue;
        }
        if (text[index] === ']') {
          index += 1;
          return array;
        }
        throw new SyntaxError(`expected ',' or ']' at ${index}`);
      }
    }
    if (ch === '"') return readString();
    if (ch === 't') {
      if (!text.startsWith('true', index)) throw new SyntaxError(`expected 'true' at ${index}`);
      index += 4;
      return true;
    }
    if (ch === 'f') {
      if (!text.startsWith('false', index)) throw new SyntaxError(`expected 'false' at ${index}`);
      index += 5;
      return false;
    }
    if (ch === 'n') {
      if (!text.startsWith('null', index)) throw new SyntaxError(`expected 'null' at ${index}`);
      index += 4;
      return null;
    }
    return readNumber();
  };

  const value = readValue();
  skipWhitespace();
  if (index !== text.length) throw new SyntaxError(`trailing JSON input at ${index}`);
  return value;
}

function isJsonDigit(ch: string | undefined): boolean {
  return ch !== undefined && ch >= '0' && ch <= '9';
}
