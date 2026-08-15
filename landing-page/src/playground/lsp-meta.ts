/**
 * Staleness helpers for the playground's LSP wasm artifact.
 *
 * Pure — no DOM, no wasm, no transport. The build stages a
 * `sjon-lsp.meta.json` sidecar next to `sjon-lsp.wasm`
 * (`landing-page/scripts/gen-lsp-meta.mjs`) recording the artifact's sha256
 * and the `serverInfo` its `initialize` reports. The client fetches the
 * sidecar, cache-busts the wasm URL with the short hash, and — once the
 * server is up — compares the recorded serverInfo against the running one.
 *
 * A drift means the staged wasm and the running one disagree (a developer
 * edited Zig but skipped `zig build landing-page-assets`, or a proxy served a
 * stale copy). It is surfaced as a visible badge, never a boot failure: every
 * degraded path here returns `null` / `'unknown'` so the guard can only ever
 * add a warning, not block the editor.
 */

import type { ServerInfo } from './lsp-types';

export type { ServerInfo };

export interface WasmMeta {
  /** Full lowercase-hex sha256 of the staged `sjon-lsp.wasm`. */
  sha256: string;
  /** First 12 hex chars of `sha256` — the cache-busting query value. */
  shortHash: string;
  /** The `serverInfo` the staged artifact reports from `initialize`. */
  serverInfo: ServerInfo;
}

export type IdentityVerdict = 'match' | 'mismatch' | 'unknown';

function isRecord(x: unknown): x is Record<string, unknown> {
  return typeof x === 'object' && x !== null;
}

function isServerInfo(x: unknown): x is ServerInfo {
  return isRecord(x) && typeof x['name'] === 'string' && typeof x['version'] === 'string';
}

/**
 * Validate a raw `serverInfo` value (from an `initialize` result) into a
 * `ServerInfo`, or null when the shape is off. Shared by the inline + worker
 * backends, which each capture serverInfo during their handshake.
 */
export function parseServerInfo(raw: unknown): ServerInfo | null {
  return isServerInfo(raw) ? { name: raw.name, version: raw.version } : null;
}

/**
 * Validate a parsed `sjon-lsp.meta.json` payload. Returns null on any
 * malformed field so a corrupt, truncated, or absent sidecar degrades to
 * "no guard" rather than throwing.
 */
export function parseWasmMeta(raw: unknown): WasmMeta | null {
  if (!isRecord(raw)) return null;
  const sha256 = raw['sha256'];
  const shortHash = raw['shortHash'];
  const serverInfo = raw['serverInfo'];
  if (typeof sha256 !== 'string' || typeof shortHash !== 'string') return null;
  if (!isServerInfo(serverInfo)) return null;
  return {
    sha256,
    shortHash,
    serverInfo: { name: serverInfo.name, version: serverInfo.version },
  };
}

/**
 * Append the artifact's short hash as a `?v=` query so a byte-changed wasm
 * gets a fresh URL and dodges any HTTP / proxy cache. The base is returned
 * unchanged when meta is null (nothing to bust with).
 */
export function wasmUrlWithVersion(baseUrl: string, meta: WasmMeta | null): string {
  if (meta === null) return baseUrl;
  const sep = baseUrl.includes('?') ? '&' : '?';
  return `${baseUrl}${sep}v=${meta.shortHash}`;
}

/**
 * Compare the build's recorded serverInfo against the running server's.
 * `'unknown'` whenever either side is absent — the guard degrades quietly and
 * never reports a false `'mismatch'` from a missing read.
 */
export function compareWasmIdentity(
  expected: WasmMeta | null,
  live: ServerInfo | null,
): IdentityVerdict {
  if (expected === null || live === null) return 'unknown';
  return expected.serverInfo.name === live.name && expected.serverInfo.version === live.version
    ? 'match'
    : 'mismatch';
}

/**
 * Fetch + parse the sidecar. `cache:'no-store'` so the meta itself is always
 * fresh (it is what decides whether the *wasm* cache is stale). Every failure
 * path — network error, non-OK status, bad JSON, malformed shape — returns
 * null.
 */
export async function fetchWasmMeta(url: string): Promise<WasmMeta | null> {
  try {
    const res = await fetch(url, { cache: 'no-store' });
    if (!res.ok) return null;
    const raw: unknown = await res.json();
    return parseWasmMeta(raw);
  } catch {
    return null;
  }
}
